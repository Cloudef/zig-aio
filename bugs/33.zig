const std = @import("std");
const aio = @import("aio");
const coro = @import("coro");

pub fn main() !void {
    try coro.io.multi(.{
        aio.op(.timeout, .{ .ns = 1 * std.time.ns_per_s }, .unlinked),
    });
}
