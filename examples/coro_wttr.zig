const builtin = @import("builtin");
const std = @import("std");
const aio = @import("aio");
const coro = @import("coro");

// Just for fun, try returning a error from one of these tasks

fn getWeather(completed: *std.atomic.Value(u32), allocator: std.mem.Allocator, city: []const u8, lang: []const u8) anyerror![]const u8 {
    defer _ = completed.fetchAdd(1, .monotonic);
    var url: std.BoundedArray(u8, 256) = .{};
    if (builtin.target.os.tag == .windows) {
        try url.writer().print("https://wttr.in/{s}?AFT&lang={s}", .{ city, lang });
    } else {
        try url.writer().print("https://wttr.in/{s}?AF&lang={s}", .{ city, lang });
    }
    var body = std.ArrayList(u8).init(allocator);
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();
    _ = try client.fetch(.{
        .location = .{ .url = url.constSlice() },
        .response_storage = .{ .dynamic = &body },
    });
    return body.toOwnedSlice();
}

fn getLatestZig(completed: *std.atomic.Value(u32), allocator: std.mem.Allocator) anyerror![]const u8 {
    defer _ = completed.fetchAdd(1, .monotonic);
    var body = std.ArrayList(u8).init(allocator);
    defer body.deinit();
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();
    _ = try client.fetch(.{
        .location = .{ .url = "https://ziglang.org/download/index.json" },
        .response_storage = .{ .dynamic = &body },
    });
    const Index = struct {
        master: struct { version: []const u8 },
    };
    var parsed = try std.json.parseFromSlice(Index, allocator, body.items, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    return allocator.dupe(u8, parsed.value.master.version);
}

fn loader(completed: *std.atomic.Value(u32), max: *const u32) !void {
    const frames: []const []const u8 = &.{
        "▰▱▱▱▱▱▱",
        "▰▰▱▱▱▱▱",
        "▰▰▰▱▱▱▱",
        "▰▰▰▰▱▱▱",
        "▰▰▰▰▰▱▱",
        "▰▰▰▰▰▰▱",
        "▰▰▰▰▰▰▰",
        "▰▱▱▱▱▱▱",
    };

    defer std.debug.print("                                     \r", .{});
    var idx: usize = 0;
    while (true) : (idx +%= 1) {
        try coro.io.single(aio.Timeout{ .ns = 80 * std.time.ns_per_ms });
        std.debug.print("  {s} {}/{} loading that juicy info\r", .{ frames[idx % frames.len], completed.load(.acquire), max.* });
    }
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    if (builtin.target.os.tag == .windows) {
        const utf8_codepage: c_uint = 65001;
        _ = std.os.windows.kernel32.SetConsoleOutputCP(utf8_codepage);
    }

    var scheduler = try coro.Scheduler.init(allocator, .{});
    defer scheduler.deinit();

    var max: u32 = 0;
    var completed = std.atomic.Value(u32).init(0);
    const ltask = try scheduler.spawn(loader, .{ &completed, &max }, .{});

    var tpool: coro.ThreadPool = try coro.ThreadPool.init(gpa.allocator(), .{});
    defer tpool.deinit();

    var tasks = std.ArrayList(coro.Task.Generic(anyerror![]const u8)).init(allocator);
    defer tasks.deinit();

    try tasks.append(try tpool.spawnForCompletion(&scheduler, getWeather, .{ &completed, allocator, "oulu", "fi" }, .{}));
    try tasks.append(try tpool.spawnForCompletion(&scheduler, getWeather, .{ &completed, allocator, "tokyo", "ja" }, .{}));
    try tasks.append(try tpool.spawnForCompletion(&scheduler, getWeather, .{ &completed, allocator, "portland", "en" }, .{}));
    try tasks.append(try tpool.spawnForCompletion(&scheduler, getLatestZig, .{ &completed, allocator }, .{}));

    max = @intCast(tasks.items.len);
    while (completed.load(.acquire) < tasks.items.len) {
        _ = try scheduler.tick(.blocking);
    }

    // don't really have to call this, but I want the defer that cleans the progress bar to run
    ltask.cancel();

    for (tasks.items, 0..) |task, idx| {
        const body = try task.complete(.wait);
        defer allocator.free(body);
        if (idx == 3) {
            try std.io.getStdOut().writer().print("\nAaand the current master zig version is... ", .{});
        }
        try std.io.getStdOut().writeAll(body);
        try std.io.getStdOut().writeAll("\n");
    }

    try std.io.getStdOut().writer().print("\nThat's all folks\n", .{});
}
