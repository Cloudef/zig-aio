// port of tokio's benches/spawn.rs : basic_scheduler_spawn10

const std = @import("std");
const aio = @import("aio");
const coro = @import("coro");
const log = std.log.scoped(.spawn_managed);

pub const std_options: std.Options = .{
    .log_level = .debug,
};

const TASK_COUNT = 10;

const Yield = enum {
    reserved,
    wake_me_up,
};

fn work() usize {
    var val: usize = 1 + 1;
    coro.yield(Yield.wake_me_up) catch unreachable;
    std.mem.doNotOptimizeAway(&val);
    return val;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var scheduler = try coro.Scheduler.init(allocator, .{});
    defer scheduler.deinit();

    const start_time = try std.time.Instant.now();

    var tasks: [TASK_COUNT]coro.Task.Generic2(work) = undefined;
    for (&tasks) |*task| task.* = try scheduler.spawn(work, .{}, .{});
    for (&tasks) |*task| {
        task.wakeupIf(Yield.wake_me_up);
        const res = task.complete(.wait);
        if (res != 2) @panic("welp");
    }

    const end_time = try std.time.Instant.now();

    const elapsed: f64 = @floatFromInt(end_time.since(start_time));
    const tasks_s: f64 = @as(f64, @floatFromInt(TASK_COUNT)) / (elapsed / 1e9);
    log.info("{d:.2} Mtasks/s", .{tasks_s / 1e6});
    log.info("{d:.2} microseconds total", .{elapsed / std.time.ns_per_us});
}
