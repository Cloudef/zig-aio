// port of tokio's benches/fs.rs : async_read_buf

const std = @import("std");
const aio = @import("aio");
const log = std.log.scoped(.fs);

pub const std_options: std.Options = .{
    .log_level = .debug,
};

const BLOCK_COUNT: usize = 1_000;
const BUFFER_SIZE: usize = 4096;
const DEV_ZERO = "/dev/zero";

pub fn main() !void {
    var f = std.fs.openFileAbsolute(DEV_ZERO, .{}) catch {
        log.info("test is not available on this platform. {s} is required on the filesystem", .{DEV_ZERO});
        return;
    };
    defer f.close();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var dynamic = try aio.Dynamic.init(allocator, 4096);
    defer dynamic.deinit(allocator);

    const start_time = try std.time.Instant.now();

    var buf: [BUFFER_SIZE]u8 = undefined;
    var rlen: usize = 0;

    for (0..BLOCK_COUNT) |_| {
        try dynamic.queue(.{
            aio.op(.read, .{ .file = f, .buffer = &buf, .out_read = &rlen }, .unlinked),
        }, {});
        const num_err = try dynamic.completeAll({});
        std.debug.assert(num_err == 0);
        if (rlen == 0) break;
    }

    const end_time = try std.time.Instant.now();

    const elapsed: f64 = @floatFromInt(end_time.since(start_time));
    const iops_s: f64 = @as(f64, @floatFromInt(BLOCK_COUNT)) / (elapsed / 1e9);
    log.info("{d:.2} Miops/s", .{iops_s / 1e6});
    log.info("{d:.2} milliseconds total", .{elapsed / std.time.ns_per_ms});
}
