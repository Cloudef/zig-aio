// reference for flow.zig
// this uses optimal (as far I know) io_uring code

const std = @import("std");
const log = std.log.scoped(.flow_uring);

pub const std_options: std.Options = .{
    .log_level = .debug,
};

const QUEUE_DEPTH = 64;
const CQES = QUEUE_DEPTH * 16;
const NUM_PACKETS = 1_000_000;
const NUM_BUFFERS = CQES;
const BUFSZ = 1500;

fn setupRecv(ring: *std.os.linux.IoUring) !void {
    const local = struct {
        var addr: std.posix.sockaddr.storage = undefined;
        var msg: std.posix.msghdr = .{
            .name = @ptrCast(&addr),
            .namelen = @sizeOf(@TypeOf(addr)),
            .iov = undefined,
            .iovlen = 0,
            .control = null,
            .controllen = 0,
            .flags = 0,
        };
    };
    var sqe = try ring.recvmsg(0, 0, &local.msg, 0);
    sqe.flags |= std.os.linux.IOSQE_BUFFER_SELECT | std.os.linux.IOSQE_FIXED_FILE;
    sqe.ioprio |= std.os.linux.IORING_RECV_MULTISHOT;
    sqe.buf_index = 0;
    _ = try ring.submit();
}

fn server(startup: *std.Thread.ResetEvent) !void {
    var ring = try std.os.linux.IoUring.init(QUEUE_DEPTH, std.os.linux.IORING_SETUP_SINGLE_ISSUER | std.os.linux.IORING_SETUP_COOP_TASKRUN);
    defer ring.deinit();

    var mega_buffer: [NUM_BUFFERS * BUFSZ]u8 = undefined;
    var buf_ring = try std.os.linux.IoUring.BufferGroup.init(&ring, 0, &mega_buffer, BUFSZ, NUM_BUFFERS);

    defer buf_ring.deinit();
    const socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM | std.posix.SOCK.CLOEXEC, std.posix.IPPROTO.UDP);
    defer std.posix.close(socket);

    try ring.register_files(&.{socket});

    const address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 3232);
    try std.posix.bind(socket, &address.any, address.getOsSockLen());

    try setupRecv(&ring);
    startup.set();

    var total_received: u64 = 0;
    var total_packets: u64 = 0;
    var cqes: [CQES]std.os.linux.io_uring_cqe = undefined;
    const start_time = try std.time.Instant.now();

    while (total_packets < NUM_PACKETS) {
        const n = try ring.copy_cqes(&cqes, 1);
        var was_resetup: bool = false;
        for (cqes[0..n]) |*cqe| {
            if (cqe.flags & std.os.linux.IORING_CQE_F_MORE == 0) {
                if (!was_resetup) {
                    log.err("no CQE_F_MORE", .{});
                    try setupRecv(&ring);
                    was_resetup = true;
                }
            }
            if (cqe.res < 0) {
                log.err("cqe: {}", .{cqe.res});
                std.posix.abort();
            }
            // release buffer
            buf_ring.put(cqe.buffer_id() catch unreachable);
            total_received += @intCast(cqe.res);
        }
        total_packets += n;
    }

    const end_time = try std.time.Instant.now();

    const elapsed: f64 = @as(f64, @floatFromInt(end_time.since(start_time))) / 1e9;
    const bytes_s: f64 = @as(f64, @floatFromInt(total_received)) / elapsed;
    const pps: f64 = @as(f64, @floatFromInt(total_packets)) / elapsed;
    log.info("{d:.2} megabytes/s", .{bytes_s / 1e6});
    log.info("{d:.2} Mpps", .{pps / 1e6});
    log.info("{d:.2} seconds total", .{elapsed});
}

const ClientMode = enum {
    local,
    remote,
};

fn client(startup: *std.Thread.ResetEvent, mode: ClientMode) !void {
    var ring = try std.os.linux.IoUring.init(QUEUE_DEPTH, std.os.linux.IORING_SETUP_SINGLE_ISSUER | std.os.linux.IORING_SETUP_COOP_TASKRUN);
    defer ring.deinit();

    const socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM | std.posix.SOCK.CLOEXEC, std.posix.IPPROTO.UDP);
    defer std.posix.close(socket);

    try ring.register_files(&.{socket});

    const address = std.net.Address.initIp4(switch (mode) {
        .local => .{ 127, 0, 0, 1 },
        .remote => .{ 0, 0, 0, 0 },
    }, 0);
    try std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.BROADCAST, std.mem.asBytes(&@as(c_int, 1)));
    try std.posix.bind(socket, &address.any, address.getOsSockLen());

    var buf: [BUFSZ]u8 = undefined;
    @memset(&buf, 'P');

    var send_iovec = [_]std.posix.iovec_const{.{
        .base = &buf,
        .len = buf.len,
    }};

    // Prepare message header with destination address
    const send_addr = std.net.Address.initIp4(.{ 255, 255, 255, 255 }, 3232);
    var msg: std.posix.msghdr_const = .{
        .name = @ptrCast(&send_addr.any),
        .namelen = send_addr.getOsSockLen(),
        .iov = &send_iovec,
        .iovlen = 1,
        .control = null,
        .controllen = 0,
        .flags = 0,
    };

    startup.wait();

    var total_packets: u64 = 0;
    var cqes: [CQES]std.os.linux.io_uring_cqe = undefined;

    while (total_packets < NUM_PACKETS * 2) {
        for (0..QUEUE_DEPTH) |_| {
            var sqe = try ring.sendmsg(0, 0, &msg, 0);
            sqe.flags |= std.os.linux.IOSQE_FIXED_FILE;
        }
        _ = try ring.submit();
        const n = try ring.copy_cqes(&cqes, 1);
        for (cqes[0..n]) |*cqe| {
            if (cqe.res < 0) {
                log.err("cqe: {}", .{cqe.res});
                std.posix.abort();
            }
        }
        total_packets += n;
    }

    log.info("sent {} packets", .{NUM_PACKETS * 2});
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const mode = if (args.len > 1) args[1] else "both";
    if (!std.mem.eql(u8, mode, "client") and !std.mem.eql(u8, mode, "server") and !std.mem.eql(u8, mode, "both")) {
        std.debug.print("Usage: {s} <client|server|both>\n", .{args[0]});
        return error.InvalidArguments;
    }

    var thread: ?std.Thread = null;
    var startup: std.Thread.ResetEvent = .{};
    if (std.mem.eql(u8, mode, "server")) {
        startup.set();
        try server(&startup);
    } else if (std.mem.eql(u8, mode, "both")) {
        thread = try std.Thread.spawn(.{}, server, .{&startup});
    }

    if (std.mem.eql(u8, mode, "client") or std.mem.eql(u8, mode, "both")) {
        const cmode: ClientMode = if (std.mem.eql(u8, mode, "both")) .local else .remote;
        if (cmode == .remote) startup.set();
        try client(&startup, cmode);
    }

    if (thread) |thrd| thrd.join();
}
