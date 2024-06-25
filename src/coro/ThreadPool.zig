const std = @import("std");
const aio = @import("aio");
const io = @import("io.zig");
const Scheduler = @import("Scheduler.zig");
const Task = @import("Task.zig");
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

pub const CancellationToken = struct {
    canceled: bool = false,
};

inline fn entrypoint(self: *@This(), completed: *bool, token: *CancellationToken, comptime func: anytype, res: anytype, args: anytype) void {
    const fun_info = @typeInfo(@TypeOf(func)).Fn;
    if (fun_info.params.len > 0 and fun_info.params[0].type.? == *const CancellationToken) {
        res.* = @call(.auto, func, .{token} ++ args);
    } else {
        res.* = @call(.auto, func, args);
    }
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
    var token: CancellationToken = .{};
    try self.pool.spawn(entrypoint, .{ self, &completed, &token, func, &res, args });
    while (!completed) {
        const nerr = io.do(.{
            aio.WaitEventSource{ .source = &self.source, .link = .soft },
        }, if (token.canceled) .io_cancel else .io) catch 1;
        if (nerr > 0) {
            if (Frame.current()) |frame| {
                if (frame.canceled) {
                    token.canceled = true;
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

/// Spawn a new coroutine which will immediately call `yieldForCompletition` for later collection of the result
/// Normally one would use the `spawnForCompletition` method, but in case a generic functions return type can't be deduced, use this any variant.
pub fn spawnAnyForCompletition(self: *@This(), scheduler: *Scheduler, Result: type, func: anytype, args: anytype, opts: Scheduler.SpawnOptions) Scheduler.SpawnError!Task {
    return scheduler.spawnAny(Result, yieldForCompletition, .{ self, func, args }, opts);
}

/// Spawn a new coroutine which will immediately call `yieldForCompletition` for later collection of the result
pub fn spawnForCompletition(self: *@This(), scheduler: *Scheduler, func: anytype, args: anytype, opts: Scheduler.SpawnOptions) Scheduler.SpawnError!Task.Generic(ReturnTypeWithError(func, std.Thread.SpawnError)) {
    const Result = ReturnTypeWithError(func, std.Thread.SpawnError);
    const task = try self.spawnAnyForCompletition(scheduler, Result, func, args, opts);
    return task.generic(Result);
}

const ThreadPool = @This();

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

        fn blockingCanceled(token: *const CancellationToken) u32 {
            while (!token.canceled) {
                std.time.sleep(1 * std.time.ns_per_s);
            }
            return if (token.canceled) 666 else 69;
        }

        fn task2(pool: *ThreadPool) !u32 {
            return try pool.yieldForCompletition(blockingCanceled, .{});
        }
    };

    var scheduler = try Scheduler.init(std.testing.allocator, .{});
    defer scheduler.deinit();

    var pool: ThreadPool = .{};
    try pool.start(std.testing.allocator, 0);
    defer pool.deinit();

    for (0..10) |_| _ = try scheduler.spawn(Test.task, .{&pool}, .{});

    {
        var task = try scheduler.spawn(Test.task2, .{&pool}, .{});
        const res = task.complete(.cancel);
        try std.testing.expectEqual(666, res);
    }

    {
        var task = try pool.spawnForCompletition(&scheduler, Test.blocking, .{}, .{});
        const res = task.complete(.wait);
        try std.testing.expectEqual(69, res);
    }

    try scheduler.run(.wait);
}
