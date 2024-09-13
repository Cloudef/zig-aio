const std = @import("std");
const aio = @import("aio");
const io = @import("io.zig");
const Scheduler = @import("Scheduler.zig");
const Task = @import("Task.zig");
const Frame = @import("Frame.zig");
const DynamicThreadPool = @import("minilib").DynamicThreadPool;
const MixErrorUnionWithErrorSet = @import("minilib").MixErrorUnionWithErrorSet;

pool: DynamicThreadPool,
source: aio.EventSource,
num_tasks: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

pub const InitError = DynamicThreadPool.InitError || aio.EventSource.Error;

/// `allocator` is used to allocate the tasks
pub fn init(allocator: std.mem.Allocator, options: DynamicThreadPool.Options) InitError!@This() {
    var pool = try DynamicThreadPool.init(allocator, options);
    errdefer pool.deinit();
    var source = try aio.EventSource.init();
    errdefer source.deinit();
    return .{ .pool = pool, .source = source };
}

pub fn deinit(self: *@This()) void {
    self.pool.deinit();
    self.source.deinit();
    self.* = undefined;
}

pub const CancellationToken = struct {
    canceled: bool = false,
};

fn hasToken(comptime func: anytype) bool {
    const fun_info = @typeInfo(@TypeOf(func)).Fn;
    return fun_info.params.len > 0 and fun_info.params[0].type.? == *const CancellationToken;
}

fn entrypoint(self: *@This(), completed: *std.atomic.Value(bool), token: *CancellationToken, comptime func: anytype, res: anytype, args: anytype) void {
    if (comptime hasToken(func)) {
        res.* = @call(.auto, func, .{token} ++ args);
    } else {
        res.* = @call(.auto, func, args);
    }
    completed.store(true, .release);
    const n = self.num_tasks.load(.acquire);
    for (0..n) |_| self.source.notify();
}

pub const YieldError = DynamicThreadPool.SpawnError;

/// Yield until `func` finishes on another thread
pub fn yieldForCompletition(self: *@This(), func: anytype, args: anytype, config: DynamicThreadPool.SpawnConfig) MixErrorUnionWithErrorSet(@TypeOf(@call(.auto, func, if (comptime hasToken(func)) .{&CancellationToken{}} ++ args else args)), YieldError) {
    var completed = std.atomic.Value(bool).init(false);
    _ = self.num_tasks.fetchAdd(1, .monotonic);
    defer _ = self.num_tasks.fetchSub(1, .release);
    var token: CancellationToken = .{};
    var res: @TypeOf(@call(.auto, func, if (comptime hasToken(func)) .{&token} ++ args else args)) = undefined;
    try self.pool.spawn(entrypoint, .{ self, &completed, &token, func, &res, args }, config);
    while (!completed.load(.acquire)) {
        const nerr = io.do(.{
            aio.WaitEventSource{ .source = &self.source },
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
pub fn spawnAnyForCompletition(self: *@This(), scheduler: *Scheduler, Result: type, func: anytype, args: anytype, config: DynamicThreadPool.SpawnConfig) Scheduler.SpawnError!Task {
    return scheduler.spawnAny(Result, yieldForCompletition, .{ self, func, args, config }, .{ .stack = .{ .managed = 1024 * 24 } });
}

/// Helper for getting the Task.Generic when using spawnForCompletition tasks.
pub fn Generic2(comptime func: anytype) type {
    const ReturnTypeMixedWithErrorSet = @import("minilib").ReturnTypeMixedWithErrorSet;
    return Task.Generic(ReturnTypeMixedWithErrorSet(func, YieldError));
}

/// Spawn a new coroutine which will immediately call `yieldForCompletition` for later collection of the result
pub fn spawnForCompletition(self: *@This(), scheduler: *Scheduler, func: anytype, args: anytype, config: DynamicThreadPool.SpawnConfig) Scheduler.SpawnError!Task.Generic(MixErrorUnionWithErrorSet(@TypeOf(@call(.auto, func, if (comptime hasToken(func)) .{&CancellationToken{}} ++ args else args)), YieldError)) {
    const RT = @TypeOf(@call(.auto, func, args));
    const Result = MixErrorUnionWithErrorSet(RT, YieldError);
    const task = try self.spawnAnyForCompletition(scheduler, Result, func, args, config);
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
            const ret = try pool.yieldForCompletition(blocking, .{}, .{});
            try std.testing.expectEqual(69, ret);
        }

        fn blockingCanceled(token: *const CancellationToken) u32 {
            while (!token.canceled) {
                std.time.sleep(1 * std.time.ns_per_s);
            }
            return if (token.canceled) 666 else 69;
        }

        fn task2(pool: *ThreadPool) !u32 {
            return try pool.yieldForCompletition(blockingCanceled, .{}, .{});
        }
    };

    var scheduler = try Scheduler.init(std.testing.allocator, .{});
    defer scheduler.deinit();

    var pool: ThreadPool = try ThreadPool.init(std.testing.allocator, .{});
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
