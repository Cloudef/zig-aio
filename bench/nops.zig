const std = @import("std");

const coro = @import("coro");
const aio = @import("aio");

var nops: usize = 0;

fn nopLoop() !void {
    while (true) {
        try coro.io.single(.nop, .{});
        nops += 1;
    }
}

fn printNops() !void {
    while (true) {
        try coro.io.single(.timeout, .{ .ns = std.time.ns_per_s });
        std.debug.print("Nops: {d}\n", .{nops});
        nops = 0;
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var scheduler = try coro.Scheduler.init(allocator, .{});
    defer scheduler.deinit();

    _ = try scheduler.spawn(nopLoop, .{}, .{});
    _ = try scheduler.spawn(printNops, .{}, .{});

    try scheduler.run(.wait);
}
