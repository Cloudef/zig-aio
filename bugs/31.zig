// Posix backend silently drops some IO operations #31
// <https://github.com/Cloudef/zig-aio/issues/31>

const std = @import("std");
const aio = @import("aio");
const coro = @import("coro");

pub const aio_options: aio.Options = .{
    .debug = false, // set to true to enable debug logs
};

pub const coro_options: coro.Options = .{
    .debug = false, // set to true to enable debug logs
};

var scheduler: coro.Scheduler = undefined;

fn protection(comptime func: anytype, args: anytype) void {
    //i know the task can capture error, this is for ease of debugging
    @call(.always_inline, func, args) catch |err| {
        logErr("Task FAILED with: {s}\n", .{@errorName(err)});
    };
}

pub fn logInfo(comptime format: []const u8, args: anytype) void {
    std.io.getStdOut().writer().print(format, args) catch return;
}

pub fn logErr(comptime format: []const u8, args: anytype) void {
    std.io.getStdErr().writer().print(format, args) catch return;
}

pub fn delay(ns: u128) !void {
    try coro.io.single(aio.Timeout{ .ns = ns });
}

pub fn main() !void {
    logInfo("\nStarted!\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const tmp: []usize = try allocator.alloc(usize, 500);
    defer allocator.free(tmp);

    //in theory not necessary, but for the good meassure
    for (tmp) |*index| {
        index.* = 0;
    }

    scheduler = try coro.Scheduler.init(allocator, .{});
    defer scheduler.deinit();

    _ = try scheduler.spawn(protection, .{ spawner, .{tmp} }, .{});

    try scheduler.run(.wait);

    logInfo("\nProgram finished correctly!\n", .{});
}

pub fn spawner(tmp: []usize) !void {
    for (0..500) |i| {
        _ = try scheduler.spawn(protection, .{ logger, .{ i, tmp } }, .{});
    }
    try delay(std.time.ns_per_s * 25); // logging takes 20s + 5s for safety
    for (tmp, 0..) |value, index| {
        logInfo("{}. {}\n", .{ index + 1, value });
    }
    //just test for protection layer
    return error.Unexpected;
}

pub fn logger(index: usize, tmp: []usize) !void {
    for (0..100) |i| {
        try delay(std.time.ns_per_ms * 200);
        tmp[index] = i + 1;
    }
    logInfo("{}. Finished\n", .{index + 1});
}
