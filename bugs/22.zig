// Inconsistency in coro io.Timeout, sometimes it pauses execution indefinitely
// <https://github.com/Cloudef/zig-aio/issues/22>
//
// Fixed in <https://github.com/Cloudef/zig-aio/pull/30>

const std = @import("std");
const coro = @import("coro");

pub fn sleep(ns: u64) void {
    coro.io.single(.timeout, .{ .ns = @intCast(ns) }) catch @panic("Unable to sleep");
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var scheduler = try coro.Scheduler.init(gpa.allocator(), .{});
    defer scheduler.deinit();

    _ = try scheduler.spawn(asyncMain, .{&scheduler}, .{});
    try scheduler.run(.wait);
}

pub fn asyncMain(scheduler: *coro.Scheduler) !void {
    std.debug.print("begin asyncMain\n", .{});
    defer std.debug.print("end asyncMain\n", .{});
    var frame = try scheduler.spawn(sleep, .{1 * std.time.ns_per_ms}, .{});
    std.debug.print("frame.isComplete = {any}\n", .{frame.isComplete()});
    frame.complete(.wait);
}
