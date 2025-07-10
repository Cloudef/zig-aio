const builtin = @import("builtin");
const std = @import("std");
const coro = @import("coro");

pub const std_options: std.Options = .{
    .log_level = .debug,
};

// Just for fun, try returning a error from one of these tasks

fn getWeather(completed: *std.atomic.Value(u32), allocator: std.mem.Allocator, city: []const u8, lang: []const u8) anyerror![]const u8 {
    defer _ = completed.fetchAdd(1, .monotonic);
    var url_buf: [256]u8 = undefined;
    var url_writer: std.Io.Writer = .fixed(&url_buf);
    if (builtin.target.os.tag == .windows) {
        try url_writer.print("https://wttr.in/{s}?AFT&lang={s}", .{ city, lang });
    } else {
        try url_writer.print("https://wttr.in/{s}?AF&lang={s}", .{ city, lang });
    }
    var body_writer: std.Io.Writer.Allocating = .init(allocator);
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();
    _ = try client.fetch(.{
        .location = .{ .url = url_writer.buffered() },
        .response_writer = &body_writer.writer,
    });
    return try body_writer.toOwnedSlice();
}

fn getLatestZig(completed: *std.atomic.Value(u32), allocator: std.mem.Allocator) anyerror![]const u8 {
    defer _ = completed.fetchAdd(1, .monotonic);
    var body_writer: std.Io.Writer.Allocating = .init(allocator);
    defer body_writer.deinit();
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();
    _ = try client.fetch(.{
        .location = .{ .url = "https://ziglang.org/download/index.json" },
        .response_writer = &body_writer.writer,
    });
    const Index = struct {
        master: struct { version: []const u8 },
    };
    var parsed = try std.json.parseFromSlice(Index, allocator, body_writer.written(), .{ .ignore_unknown_fields = true });
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
        try coro.io.single(.timeout, .{ .ns = 80 * std.time.ns_per_ms });
        std.debug.print("  {s} {}/{} loading that juicy info\r", .{ frames[idx % frames.len], completed.load(.acquire), max.* });
    }
}

pub fn main() !void {
    if (builtin.target.os.tag == .wasi) return error.UnsupportedPlatform;
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

    var tasks: std.ArrayList(coro.Task.Generic(anyerror![]const u8)) = .empty;
    defer tasks.deinit(allocator);

    try tasks.append(allocator, try tpool.spawnForCompletion(&scheduler, getWeather, .{ &completed, allocator, "oulu", "fi" }));
    try tasks.append(allocator, try tpool.spawnForCompletion(&scheduler, getWeather, .{ &completed, allocator, "tokyo", "ja" }));
    try tasks.append(allocator, try tpool.spawnForCompletion(&scheduler, getWeather, .{ &completed, allocator, "portland", "en" }));
    try tasks.append(allocator, try tpool.spawnForCompletion(&scheduler, getLatestZig, .{ &completed, allocator }));

    max = @intCast(tasks.items.len);
    while (completed.load(.acquire) < tasks.items.len) {
        _ = try scheduler.tick(.blocking);
    }

    // don't really have to call this, but I want the defer that cleans the progress bar to run
    ltask.cancel();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    var stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    for (tasks.items, 0..) |task, idx| {
        if (task.complete(.wait)) |body| {
            defer allocator.free(body);
            if (idx == 3) {
                try stdout.print("\nAaand the current master zig version is... ", .{});
            }
            try stdout.writeAll(body);
            try stdout.writeAll("\n");
        } else |err| {
            try stdout.print("request {} failed with: {}\n", .{ idx, err });
        }
    }

    try stdout.print("\nThat's all folks\n", .{});
}
