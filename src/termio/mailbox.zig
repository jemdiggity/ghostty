const std = @import("std");
const Allocator = std.mem.Allocator;
const global = @import("../global.zig");
const xev = global.xev;
const renderer = @import("../renderer.zig");
const termio = @import("../termio.zig");
const BlockingQueue = @import("../datastruct/main.zig").BlockingQueue;

const log = std.log.scoped(.io_writer);

/// A queue used for storing messages that is periodically drained.
/// Typically used by a multi-threaded application. The capacity is
/// hardcoded to a value that empirically has made sense for Ghostty usage
/// but I'm open to changing it with good arguments.
const Queue = BlockingQueue(termio.Message, 64);

/// The location to where write-related messages are sent.
pub const Mailbox = union(enum) {
    // /// Write messages to an unbounded list backed by an allocator.
    // /// This is useful for single-threaded applications where you're not
    // /// afraid of running out of memory. You should be careful that you're
    // /// processing this in a timely manner though since some heavy workloads
    // /// will produce a LOT of messages.
    // ///
    // /// At the time of authoring this, the primary use case for this is
    // /// testing more than anything, but it probably will have a use case
    // /// in libghostty eventually.
    // unbounded: std.ArrayList(termio.Message),

    /// Write messages to a SPSC queue for multi-threaded applications.
    spsc: struct {
        queue: *Queue,
        wakeup: xev.Async,
        alloc: Allocator,

        /// The thread that drains the queue. It must never wait for room in
        /// its own queue: nothing else would make room. With external I/O
        /// it parses output itself, and the stream handler's messages
        /// (synchronized output, mode changes, responses) are sends to self.
        owner: std.atomic.Value(std.Thread.Id) = .init(0),

        /// Messages the owner sent while the queue was full, drained first.
        /// Only the owner thread touches it.
        overflow: std.ArrayList(termio.Message) = .empty,
    },

    /// Init the SPSC writer.
    pub fn initSPSC(alloc: Allocator) !Mailbox {
        var queue = try Queue.create(alloc);
        errdefer queue.destroy(alloc);

        var wakeup = try xev.Async.init();
        errdefer wakeup.deinit();

        return .{ .spsc = .{ .queue = queue, .wakeup = wakeup, .alloc = alloc } };
    }

    pub fn deinit(self: *Mailbox, alloc: Allocator) void {
        switch (self.*) {
            .spsc => |*v| {
                while (v.queue.pop(global.io())) |msg| msg.deinit();
                for (v.overflow.items) |msg| msg.deinit();
                v.overflow.deinit(v.alloc);
                v.queue.destroy(alloc);
                v.wakeup.deinit();
            },
        }
    }

    /// Sends the given message without notifying there are messages.
    ///
    /// If the optional mutex is given, it must already be LOCKED. If the
    /// send would block, we'll unlock this mutex, resend the message, and
    /// lock it again. This handles an edge case where queues are full.
    /// This may not apply to all writer types.
    pub fn send(
        self: *Mailbox,
        msg: termio.Message,
        mutex: ?*std.Io.Mutex,
    ) void {
        switch (self.*) {
            .spsc => |*mb| send: {
                // Try to write to the queue with an instant timeout. This is the
                // fast path because we can queue without a lock.
                if (mb.queue.push(global.io(), msg, .{ .instant = {} }) > 0) break :send;

                if (mb.owner.load(.acquire) == std.Thread.getCurrentId()) {
                    mb.overflow.append(mb.alloc, msg) catch {
                        log.warn("out of memory queueing a message to self, dropped", .{});
                        msg.deinit();
                    };
                    break :send;
                }

                // If we enter this conditional, the queue is full. We wake up
                // the writer thread so that it can process messages to clear up
                // space. However, the writer thread may require the renderer
                // lock so we need to unlock.
                mb.wakeup.notify() catch |err| {
                    log.warn("failed to wake up writer, data will be dropped err={}", .{err});
                    msg.deinit();
                    return;
                };

                // Unlock the renderer state so the writer thread can acquire it.
                // Then try to queue our message before continuing. This is a very
                // slow path because we are having a lot of contention for data.
                // But this only gets triggered in certain pathological cases.
                //
                // Note that writes themselves don't require a lock, but there
                // are other messages in the writer queue (resize, focus) that
                // could acquire the lock. This is why we have to release our lock
                // here.
                if (mutex) |m| m.unlock(global.io());
                defer if (mutex) |m| m.lockUncancelable(global.io());
                if (mb.queue.push(global.io(), msg, .{ .forever = {} }) == 0) msg.deinit();
            },
        }
    }

    /// Queue a message without waiting for space. The caller retains
    /// ownership when this returns false.
    pub fn trySend(self: *Mailbox, msg: termio.Message) bool {
        return switch (self.*) {
            .spsc => |*mb| mb.queue.push(global.io(), msg, .{ .instant = {} }) > 0,
        };
    }

    /// Marks the calling thread as the one that drains this mailbox.
    pub fn setOwner(self: *Mailbox) void {
        switch (self.*) {
            .spsc => |*v| v.owner.store(std.Thread.getCurrentId(), .release),
        }
    }

    /// The next message for the owner: what it sent itself while the queue
    /// was full comes first, since it followed the message being handled.
    pub fn pop(self: *Mailbox) ?termio.Message {
        return switch (self.*) {
            .spsc => |*v| if (v.overflow.items.len > 0) v.overflow.orderedRemove(0) else v.queue.pop(global.io()),
        };
    }

    /// Notify that there are new messages. This may be a noop depending
    /// on the writer type.
    pub fn notify(self: *Mailbox) void {
        switch (self.*) {
            .spsc => |*v| v.wakeup.notify() catch |err| {
                log.warn("failed to notify writer, data will be dropped err={}", .{err});
            },
        }
    }
};

test "the owner thread never waits for room in its own mailbox" {
    const testing = std.testing;
    var mailbox = try Mailbox.initSPSC(testing.allocator);
    defer mailbox.deinit(testing.allocator);
    mailbox.setOwner();

    for (0..64) |_| try testing.expect(mailbox.trySend(.{ .inspector = false }));
    // Full: a non-owner would block here; the owner keeps the message aside.
    mailbox.send(.{ .inspector = true }, null);
    for (0..10) |_| mailbox.send(.{ .linefeed_mode = true }, null);

    // Self-sent messages come first, in order, then the queue.
    const first = mailbox.pop().?;
    try testing.expect(first == .inspector and first.inspector);
    for (0..10) |_| try testing.expect(mailbox.pop().? == .linefeed_mode);
    var queued: usize = 0;
    while (mailbox.pop()) |msg| : (queued += 1) try testing.expect(msg == .inspector and !msg.inspector);
    try testing.expectEqual(@as(usize, 64), queued);
}

test "trySend drops work instead of waiting for a full mailbox" {
    const testing = std.testing;
    var mailbox = try Mailbox.initSPSC(testing.allocator);
    defer mailbox.deinit(testing.allocator);

    for (0..64) |_| {
        try testing.expect(mailbox.trySend(.{ .crash = {} }));
    }
    try testing.expect(!mailbox.trySend(.{ .crash = {} }));
}
