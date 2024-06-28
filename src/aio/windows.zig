const std = @import("std");
const aio = @import("../aio.zig");
const Fallback = @import("Fallback.zig");
const windows = @import("posix/windows.zig");
const log = std.log.scoped(.aio_windows);

const Windows = @This();

pub const IO = switch (aio.options.fallback) {
    .auto => Fallback, // Fallback until Windows backend is complete
    .force => Fallback, // use only the fallback backend
    .disable => Windows, // use only the Windows backend
};

pub const EventSource = windows.EventSource;

pub fn init(allocator: std.mem.Allocator, n: u16) aio.Error!@This() {
    _ = allocator; // autofix
    _ = n; // autofix
    if (true) @panic("fixme");
    return .{};
}

pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    _ = allocator; // autofix
    self.* = undefined;
}

pub fn queue(self: *@This(), comptime len: u16, work: anytype, cb: ?aio.Dynamic.QueueCallback) aio.Error!void {
    _ = self; // autofix
    _ = work; // autofix
    _ = cb; // autofix
    if (comptime len == 1) {} else {}
}

pub fn complete(self: *@This(), mode: aio.Dynamic.CompletionMode, cb: ?aio.Dynamic.CompletionCallback) aio.Error!aio.CompletionResult {
    _ = self; // autofix
    _ = mode; // autofix
    _ = cb; // autofix
    return .{};
}

pub fn immediate(comptime len: u16, work: anytype) aio.Error!u16 {
    _ = len; // autofix
    _ = work; // autofix
    return 0;
}
