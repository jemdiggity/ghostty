const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const ProcessInfo = @import("../pty.zig").ProcessInfo;

// The preallocation size for the write request pool. This should be big
// enough to satisfy most write requests. It must be a power of 2.
const WRITE_REQ_PREALLOC = std.math.pow(usize, 2, 5);

/// The kinds of backends.
pub const Kind = enum { exec, external };

pub const External = struct {
    userdata: ?*anyopaque,
    write_cb: ?*const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void,

    pub fn initTerminal(self: *External, t: *terminal.Terminal) void {
        _ = self;
        _ = t;
    }

    pub fn threadEnter(self: *External, _: Allocator, _: *termio.Termio, td: *termio.Termio.ThreadData) !void {
        td.backend = .{ .external = {} };
        _ = self;
    }

    pub fn threadExit(_: *External, _: *termio.Termio.ThreadData) void {}
    pub fn focusGained(_: *External, _: *termio.Termio.ThreadData, _: bool) !void {}
    pub fn resize(_: *External, _: renderer.GridSize, _: renderer.ScreenSize) !void {}

    pub fn queueWrite(self: *External, _: Allocator, _: *termio.Termio.ThreadData, data: []const u8, _: bool) !void {
        if (self.write_cb) |callback| callback(self.userdata, data.ptr, data.len);
    }

    pub fn deinit(_: *External) void {}
};

/// Configuration for the various backend types.
pub const Config = union(Kind) {
    /// Exec uses posix exec to run a command with a pty.
    exec: termio.Exec.Config,
    external: External,
};

/// Backend implementations. A backend is responsible for owning the pty
/// behavior and providing read/write capabilities.
pub const Backend = union(Kind) {
    exec: termio.Exec,
    external: External,

    pub fn deinit(self: *Backend) void {
        switch (self.*) {
            .exec => |*exec| exec.deinit(),
            .external => |*external| external.deinit(),
        }
    }

    pub fn initTerminal(self: *Backend, t: *terminal.Terminal) void {
        switch (self.*) {
            .exec => |*exec| exec.initTerminal(t),
            .external => |*external| external.initTerminal(t),
        }
    }

    pub fn threadEnter(
        self: *Backend,
        alloc: Allocator,
        io: *termio.Termio,
        td: *termio.Termio.ThreadData,
    ) !void {
        switch (self.*) {
            .exec => |*exec| try exec.threadEnter(alloc, io, td),
            .external => |*external| try external.threadEnter(alloc, io, td),
        }
    }

    pub fn threadExit(self: *Backend, td: *termio.Termio.ThreadData) void {
        switch (self.*) {
            .exec => |*exec| exec.threadExit(td),
            .external => |*external| external.threadExit(td),
        }
    }

    pub fn focusGained(
        self: *Backend,
        td: *termio.Termio.ThreadData,
        focused: bool,
    ) !void {
        switch (self.*) {
            .exec => |*exec| try exec.focusGained(td, focused),
            .external => |*external| try external.focusGained(td, focused),
        }
    }

    pub fn resize(
        self: *Backend,
        grid_size: renderer.GridSize,
        screen_size: renderer.ScreenSize,
    ) !void {
        switch (self.*) {
            .exec => |*exec| try exec.resize(grid_size, screen_size),
            .external => |*external| try external.resize(grid_size, screen_size),
        }
    }

    pub fn queueWrite(
        self: *Backend,
        alloc: Allocator,
        td: *termio.Termio.ThreadData,
        data: []const u8,
        linefeed: bool,
    ) !void {
        switch (self.*) {
            .exec => |*exec| try exec.queueWrite(alloc, td, data, linefeed),
            .external => |*external| try external.queueWrite(alloc, td, data, linefeed),
        }
    }

    pub fn queueResponse(
        self: *Backend,
        alloc: Allocator,
        td: *termio.Termio.ThreadData,
        data: []const u8,
        linefeed: bool,
    ) !void {
        switch (self.*) {
            .exec => |*exec| try exec.queueWrite(alloc, td, data, linefeed),
            .external => {},
        }
    }

    pub fn childExitedAbnormally(
        self: *Backend,
        gpa: Allocator,
        t: *terminal.Terminal,
        exit_code: u32,
        runtime_ms: u64,
    ) !void {
        switch (self.*) {
            .exec => |*exec| try exec.childExitedAbnormally(
                gpa,
                t,
                exit_code,
                runtime_ms,
            ),
            .external => {},
        }
    }

    /// Get information about the process(es) attached to the backend. Returns
    /// `null` if there was an error getting the information or the information
    /// is not available on a particular platform.
    pub fn getProcessInfo(self: *Backend, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
        return switch (self.*) {
            .exec => |*exec| exec.getProcessInfo(info),
            .external => null,
        };
    }
};

/// Termio thread data. See termio.ThreadData for docs.
pub const ThreadData = union(Kind) {
    exec: termio.Exec.ThreadData,
    external: void,

    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        switch (self.*) {
            .exec => |*exec| exec.deinit(alloc),
            .external => {},
        }
    }

    pub fn changeConfig(self: *ThreadData, config: *termio.DerivedConfig) void {
        _ = self;
        _ = config;
    }
};

var external_test_bytes: [16]u8 = undefined;
var external_test_len: usize = 0;

fn externalTestWrite(_: ?*anyopaque, bytes: [*]const u8, len: usize) callconv(.c) void {
    @memcpy(external_test_bytes[0..len], bytes[0..len]);
    external_test_len = len;
}

test "external backend forwards input and discards terminal responses" {
    const testing = std.testing;
    external_test_len = 0;
    var backend: Backend = .{ .external = .{
        .userdata = null,
        .write_cb = externalTestWrite,
    } };
    var td: termio.Termio.ThreadData = undefined;

    try backend.queueWrite(testing.allocator, &td, "input", false);
    try testing.expectEqualStrings("input", external_test_bytes[0..external_test_len]);
    try backend.queueResponse(testing.allocator, &td, "reply", false);
    try testing.expectEqual(@as(usize, 5), external_test_len);
}
