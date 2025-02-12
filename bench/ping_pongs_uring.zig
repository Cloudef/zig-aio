// reference for ping_pongs.zig
// this uses optimal (as far I know) io_uring code

const std = @import("std");
const log = std.log.scoped(.ping_pongs_uring);

pub const std_options: std.Options = .{
    .log_level = .debug,
};

// PR to zig std
// RECVSEND_BUNDLE's don't work with recvmsg/sendmsg :(
const IORING_RECVSEND_BUNDLE = 1 << 4;

const CQES = 4096;
const PING_PONG_COUNT = 500_000;
const NUM_BUFFERS = 64;
const BUFSZ = "PING".len;

fn setupRecv(ring: *std.os.linux.IoUring) !void {
    var sqe = try ring.recv(0, 0, .{ .buffer = "" }, 0);
    sqe.flags |= std.os.linux.IOSQE_BUFFER_SELECT | std.os.linux.IOSQE_FIXED_FILE;
    sqe.ioprio |= std.os.linux.IORING_RECV_MULTISHOT | IORING_RECVSEND_BUNDLE;
    sqe.buf_index = 0;
}

fn server(startup: *std.Thread.ResetEvent) !void {
    var ring = try std.os.linux.IoUring.init(CQES, std.os.linux.IORING_SETUP_SINGLE_ISSUER | std.os.linux.IORING_SETUP_COOP_TASKRUN);
    defer ring.deinit();

    var recv_mega_buffer: [NUM_BUFFERS * BUFSZ]u8 = undefined;
    var recv_buf_ring = try std.os.linux.IoUring.BufferGroup.init(&ring, 0, &recv_mega_buffer, BUFSZ, NUM_BUFFERS);
    defer recv_buf_ring.deinit();

    const socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, std.posix.IPPROTO.TCP);
    defer std.posix.close(socket);

    const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 3131);
    try std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    if (@hasDecl(std.posix.SO, "REUSEPORT")) {
        try std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
    }
    try std.posix.bind(socket, &address.any, address.getOsSockLen());
    try std.posix.listen(socket, 1);

    startup.set();

    const client_socket = try std.posix.accept(socket, null, null, 0);
    defer std.posix.close(client_socket);
    try ring.register_files(&.{client_socket});

    try setupRecv(&ring);

    var cqes: [CQES]std.os.linux.io_uring_cqe = undefined;

    main: while (true) {
        _ = try ring.submit();
        const n = try ring.copy_cqes(&cqes, 1);
        var was_resetup: bool = false;
        for (cqes[0..n]) |*cqe| {
            if (cqe.user_data == 0 and cqe.flags & std.os.linux.IORING_CQE_F_MORE == 0) {
                if (!was_resetup) {
                    try setupRecv(&ring);
                    was_resetup = true;
                    continue;
                }
            }
            if (cqe.res < 0) {
                log.err("server cqe: {}, {}", .{ cqe.res, cqe.user_data });
                std.posix.abort();
            } else {
                if (cqe.res == 1) break :main;
                const size: usize = @intCast(cqe.res);
                const off: u16 = cqe.buffer_id() catch unreachable;
                for (0..size / BUFSZ) |idx| {
                    recv_buf_ring.put(@intCast(off + idx));
                    var sqe = try ring.send(1, 0, "PONG", 0);
                    sqe.flags |= std.os.linux.IOSQE_FIXED_FILE | std.os.linux.IOSQE_CQE_SKIP_SUCCESS;
                }
            }
        }
    }
}

fn client(startup: *std.Thread.ResetEvent) !void {
    var ring = try std.os.linux.IoUring.init(CQES, std.os.linux.IORING_SETUP_SINGLE_ISSUER | std.os.linux.IORING_SETUP_COOP_TASKRUN);
    defer ring.deinit();

    const socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, std.posix.IPPROTO.TCP);
    defer std.posix.close(socket);

    try ring.register_files(&.{socket});

    var recv_mega_buffer: [NUM_BUFFERS * BUFSZ]u8 = undefined;
    var recv_buf_ring = try std.os.linux.IoUring.BufferGroup.init(&ring, 0, &recv_mega_buffer, BUFSZ, NUM_BUFFERS);
    defer recv_buf_ring.deinit();

    startup.wait();

    const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 3131);
    try std.posix.connect(socket, &address.any, address.getOsSockLen());

    try setupRecv(&ring);

    var pongs: u64 = 0;
    var cqes: [CQES]std.os.linux.io_uring_cqe = undefined;
    const start_time = try std.time.Instant.now();

    {
        var sqe = try ring.send(1, 0, "PING", 0);
        sqe.flags |= std.os.linux.IOSQE_FIXED_FILE | std.os.linux.IOSQE_CQE_SKIP_SUCCESS;
    }

    while (pongs < PING_PONG_COUNT) {
        _ = try ring.submit();
        const n = try ring.copy_cqes(&cqes, 1);
        var was_resetup: bool = false;
        for (cqes[0..n]) |*cqe| {
            if (cqe.user_data == 0 and cqe.flags & std.os.linux.IORING_CQE_F_MORE == 0) {
                if (!was_resetup) {
                    try setupRecv(&ring);
                    was_resetup = true;
                    continue;
                }
            }
            if (cqe.res < 0) {
                log.err("client cqe: {}, {}", .{ cqe.res, cqe.user_data });
                std.posix.abort();
            } else {
                const size: usize = @intCast(cqe.res);
                const off: u16 = cqe.buffer_id() catch unreachable;
                for (0..size / BUFSZ) |idx| {
                    recv_buf_ring.put(@intCast(off + idx));
                    pongs += 1;
                    var sqe = try ring.send(1, 0, "PING", 0);
                    sqe.flags |= std.os.linux.IOSQE_FIXED_FILE | std.os.linux.IOSQE_CQE_SKIP_SUCCESS;
                }
            }
        }
    }

    const end_time = try std.time.Instant.now();

    const elapsed = @as(f64, @floatFromInt(end_time.since(start_time))) / 1e9;
    const roundtrips = @as(f64, @floatFromInt(pongs)) / elapsed;
    log.info("{d:.2} Mroundtrips/s", .{roundtrips / 1e6});
    log.info("{d:.2} seconds total", .{elapsed});

    _ = try std.posix.send(socket, "0", 0);
}

pub fn main() !void {
    var startup: std.Thread.ResetEvent = .{};
    const thread = try std.Thread.spawn(.{}, server, .{&startup});
    try client(&startup);
    thread.join();
}
