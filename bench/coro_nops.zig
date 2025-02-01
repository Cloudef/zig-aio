const std = @import("std");
const aio = @import("aio");
const coro = @import("coro");
const log = std.log.scoped(.coro_nops);

pub const std_options: std.Options = .{
    .log_level = .debug,
};

const TOTAL_NOPS = 2_500_000_00;

fn nopLoop(total: usize) !void {
    var i: usize = 0;
    while (i < total) {
        const batch = 32;
        try coro.io.multi(.{aio.op(.nop, .{}, .unlinked)} ** batch);
        i += batch;
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const queue_size: u16 = 32_768;
    var scheduler = try coro.Scheduler.init(allocator, .{ .io_queue_entries = queue_size });
    defer scheduler.deinit();

    _ = try scheduler.spawn(nopLoop, .{TOTAL_NOPS}, .{});

    const start_time = try std.time.Instant.now();
    try scheduler.run(.wait);
    const end_time = try std.time.Instant.now();

    const elapsed: f64 = @floatFromInt(end_time.since(start_time));
    const nops_s: f64 = @as(f64, @floatFromInt(TOTAL_NOPS)) / (elapsed / 1e9);
    log.info("{d:.2} nops/s", .{nops_s});
    log.info("{d:.2} seconds total", .{elapsed / 1e9});
}
