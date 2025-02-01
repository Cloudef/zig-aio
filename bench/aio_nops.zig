const std = @import("std");
const aio = @import("aio");
const log = std.log.scoped(.aio_nops);

pub const std_options: std.Options = .{
    .log_level = .debug,
};

const TOTAL_NOPS = 2_500_000;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const queue_size: u16 = 32_768;
    var io = try aio.Dynamic.init(allocator, queue_size);
    defer io.deinit(allocator);

    const start_time = try std.time.Instant.now();
    var i: usize = 0;
    while (i < TOTAL_NOPS) {
        for (0..queue_size) |_| {
            try io.queue(aio.op(.nop, .{}, .unlinked), {});
        }
        const res = try io.complete(.blocking, {});
        i += res.num_completed;
    }
    const end_time = try std.time.Instant.now();

    const elapsed: f64 = @floatFromInt(end_time.since(start_time));
    const nops_s: f64 = @as(f64, @floatFromInt(TOTAL_NOPS)) / (elapsed / 1e9);
    log.info("{d:.2} nops/s", .{nops_s});
    log.info("{d:.2} seconds total", .{elapsed / 1e9});
}
