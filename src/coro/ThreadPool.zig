const std = @import("std");
const aio = @import("aio");
const io = @import("io.zig");
const Frame = @import("Frame.zig");
const ReturnTypeWithError = @import("common.zig").ReturnTypeWithError;
const ReturnType = @import("common.zig").ReturnType;

pool: std.Thread.Pool = undefined,
source: aio.EventSource = undefined,
num_tasks: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

/// Spin up the pool, `allocator` is used to allocate the tasks
/// If `num_jobs` is zero, the thread count for the current CPU is used
pub fn start(self: *@This(), allocator: std.mem.Allocator, num_jobs: u32) !void {
    self.* = .{ .pool = .{ .allocator = undefined, .threads = undefined }, .source = try aio.EventSource.init() };
    errdefer self.source.deinit();
    try self.pool.init(.{ .allocator = allocator, .n_jobs = if (num_jobs == 0) null else num_jobs });
}

pub fn deinit(self: *@This()) void {
    self.pool.deinit();
    self.source.deinit();
    self.* = undefined;
}

inline fn entrypoint(self: *@This(), completed: *bool, cancellation: *bool, comptime func: anytype, res: anytype, args: anytype) void {
    _ = cancellation; // TODO
    res.* = @call(.auto, func, args);
    completed.* = true;
    const n = self.num_tasks.load(.acquire);
    for (0..n) |_| self.source.notify();
}

/// Yield until `func` finishes on another thread
pub fn yieldForCompletition(self: *@This(), func: anytype, args: anytype) ReturnTypeWithError(func, std.Thread.SpawnError) {
    var completed: bool = false;
    var res: ReturnType(func) = undefined;
    _ = self.num_tasks.fetchAdd(1, .monotonic);
    defer _ = self.num_tasks.fetchSub(1, .release);
    var cancellation: bool = false;
    try self.pool.spawn(entrypoint, .{ self, &completed, &cancellation, func, &res, args });
    while (!completed) {
        const nerr = io.do(.{
            aio.WaitEventSource{ .source = &self.source, .link = .soft },
        }, if (cancellation) .io_cancel else .io) catch 1;
        if (nerr > 0) {
            if (Frame.current()) |frame| {
                if (frame.canceled) {
                    cancellation = true;
                    continue;
                }
            }
            // it's possible to end up here if aio implementation ran out of resources
            // in case of io_uring the application managed to fill up the submission queue
            // normally this should not happen, but as to not crash the program do a blocking wait
            self.source.wait();
        }
    }
    return res;
}

const ThreadPool = @This();
const Scheduler = @import("Scheduler.zig");

test "ThreadPool" {
    const Test = struct {
        fn blocking() u32 {
            std.time.sleep(1 * std.time.ns_per_s);
            return 69;
        }
        fn task(pool: *ThreadPool) !void {
            const ret = try pool.yieldForCompletition(blocking, .{});
            try std.testing.expectEqual(69, ret);
        }
    };
    var scheduler = try Scheduler.init(std.testing.allocator, .{});
    defer scheduler.deinit();
    var pool: ThreadPool = .{};
    try pool.start(std.testing.allocator, 0);
    defer pool.deinit();
    for (0..10) |_| _ = try scheduler.spawn(Test.task, .{&pool}, .{});
    try scheduler.run();
}
