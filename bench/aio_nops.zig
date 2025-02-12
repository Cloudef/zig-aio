const std = @import("std");
const aio = @import("aio");
const log = std.log.scoped(.aio_nops);

pub const std_options: std.Options = .{
    .log_level = .debug,
};

const TOTAL_NOPS = 2_500_000_00;

fn nopLoop(io: *aio.Dynamic, total: usize) !void {
    var i: usize = 0;
    while (i < total) {
        const batch = 32;
        try io.queue(.{aio.op(.nop, .{}, .unlinked)} ** batch, {});
        const res = try io.complete(.blocking, {});
        i += res.num_completed;
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const queue_size: u16 = 32_768;
    var io = try aio.Dynamic.init(allocator, queue_size);
    defer io.deinit(allocator);

    var total: usize = TOTAL_NOPS;
    std.mem.doNotOptimizeAway(&total);
    const start_time = try std.time.Instant.now();
    try nopLoop(&io, total);
    const end_time = try std.time.Instant.now();

    const elapsed: f64 = @floatFromInt(end_time.since(start_time));
    const nops_s: f64 = @as(f64, @floatFromInt(TOTAL_NOPS)) / (elapsed / 1e9);
    log.info("{d:.2} Mnops/s", .{nops_s / 1e6});
    log.info("{d:.2} seconds total", .{elapsed / 1e9});
}
