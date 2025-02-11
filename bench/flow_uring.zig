// reference for flow.zig
// this uses optimal (as far I know) io_uring code

const std = @import("std");
const log = std.log.scoped(.flow_uring);

pub const std_options: std.Options = .{
    .log_level = .debug,
};

// PR to zig std
// RECVSEND_BUNDLE's don't work with recvmsg/sendmsg :(
const IORING_RECVSEND_BUNDLE = 1 << 4;

const CQES = 4096;
const NUM_PACKETS = 1_000_000;
const NUM_BUFFERS = 64;
const BUFSZ = 512;

const UDP_SEGMENT = 103;
const UDP_GRO = 104;

const VALIDATE: bool = false;

fn setupRecv(ring: *std.os.linux.IoUring) !void {
    const local = struct {
        var msg: std.posix.msghdr = .{
            .name = null,
            .namelen = 0,
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
    var ring = try std.os.linux.IoUring.init(CQES, std.os.linux.IORING_SETUP_SINGLE_ISSUER | std.os.linux.IORING_SETUP_COOP_TASKRUN);
    defer ring.deinit();

    const HDR_BUFSZ = BUFSZ + @sizeOf(std.os.linux.io_uring_recvmsg_out);
    var mega_buffer: [NUM_BUFFERS * NUM_BUFFERS * HDR_BUFSZ]u8 = undefined;
    var buf_ring = try std.os.linux.IoUring.BufferGroup.init(&ring, 0, &mega_buffer, HDR_BUFSZ * NUM_BUFFERS, NUM_BUFFERS);
    defer buf_ring.deinit();

    const socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM | std.posix.SOCK.CLOEXEC, std.posix.IPPROTO.UDP);
    defer std.posix.close(socket);
    try std.posix.setsockopt(socket, std.posix.IPPROTO.UDP, UDP_GRO, std.mem.asBytes(&@as(c_int, BUFSZ)));

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
                    try setupRecv(&ring);
                    was_resetup = true;
                    continue;
                }
            }
            if (cqe.res < 0) {
                log.err("recv cqe: {}", .{cqe.res});
                std.posix.abort();
            } else {
                const size: usize = @intCast(cqe.res);

                if (comptime VALIDATE) {
                    const buf = buf_ring.get_cqe(cqe.*) catch unreachable;
                    const hdr = std.mem.bytesAsValue(std.os.linux.io_uring_recvmsg_out, buf[0..]);
                    var off = @sizeOf(std.os.linux.io_uring_recvmsg_out) + hdr.namelen + hdr.controllen;
                    while (off < size) {
                        if (buf[off + 1] != buf[off] ^ 32) {
                            log.err("parity validation failed ({} != {})", .{ buf[off + 1], buf[off] ^ 32 });
                            return error.ValidationFailure;
                        }
                        if (!std.mem.allEqual(u8, buf[off + 2 .. off + BUFSZ], 'P')) {
                            log.err("packet validation failed", .{});
                            return error.ValidationFailure;
                        }
                        off += BUFSZ;
                    }
                }

                // release buffer
                buf_ring.put(cqe.buffer_id() catch unreachable);
                const actual_size = size - @sizeOf(std.os.linux.io_uring_recvmsg_out);
                total_received += actual_size;
                total_packets += actual_size / BUFSZ;
            }
        }
    }

    const end_time = try std.time.Instant.now();

    if (total_received != total_packets * BUFSZ) {
        log.err("mismatch: {} != {}", .{ total_received, total_packets * BUFSZ });
    }

    const elapsed: f64 = @as(f64, @floatFromInt(end_time.since(start_time))) / 1e9;
    const bytes_s: f64 = @as(f64, @floatFromInt(total_received)) / elapsed;
    const pps: f64 = @as(f64, @floatFromInt(total_packets)) / elapsed;
    log.info("received {} packets", .{total_packets});
    log.info("{d:.2} megabytes/s", .{bytes_s / 1e6});
    log.info("{d:.2} Mpps", .{pps / 1e6});
    log.info("{d:.2} seconds total", .{elapsed});
}

const ClientMode = enum {
    local,
    remote,
};

fn client(startup: *std.Thread.ResetEvent, mode: ClientMode) !void {
    var ring = try std.os.linux.IoUring.init(CQES, std.os.linux.IORING_SETUP_SINGLE_ISSUER | std.os.linux.IORING_SETUP_COOP_TASKRUN);
    defer ring.deinit();

    const socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM | std.posix.SOCK.CLOEXEC, std.posix.IPPROTO.UDP);
    defer std.posix.close(socket);

    try ring.register_files(&.{socket});

    const address = std.net.Address.initIp4(switch (mode) {
        .local => .{ 127, 0, 0, 1 },
        .remote => .{ 0, 0, 0, 0 },
    }, 0);
    try std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.BROADCAST, std.mem.asBytes(&@as(c_int, 1)));
    try std.posix.setsockopt(socket, std.posix.IPPROTO.UDP, UDP_SEGMENT, std.mem.asBytes(&@as(c_int, BUFSZ)));
    try std.posix.bind(socket, &address.any, address.getOsSockLen());

    var buf: [BUFSZ * NUM_BUFFERS]u8 = undefined;
    @memset(&buf, 'P');

    const send_iovec: []const std.posix.iovec_const = &.{.{
        .base = &buf,
        .len = buf.len,
    }};

    const send_addr = std.net.Address.initIp4(.{ 255, 255, 255, 255 }, 3232);
    var msg: std.posix.msghdr_const = .{
        .name = @ptrCast(&send_addr.any),
        .namelen = send_addr.getOsSockLen(),
        .iov = send_iovec.ptr,
        .iovlen = 1,
        .control = null,
        .controllen = 0,
        .flags = 0,
    };

    var msgs: [NUM_BUFFERS]std.os.linux.mmsghdr_const = @splat(.{ .hdr = msg, .len = 0 });
    startup.wait();

    var total_packets: u64 = 0;
    var total_sent: u64 = 0;
    var cqes: [CQES]std.os.linux.io_uring_cqe = undefined;
    const start_time = try std.time.Instant.now();

    // use higher multiplier on VALIDATE as it slows down receiver and udp packets may be dropped
    const MULTIPLIER = if (VALIDATE) 4 else 2;
    while (total_packets < NUM_PACKETS * MULTIPLIER) {
        if (false) { // flip for uring vs sendmmsg
            if (comptime VALIDATE) @compileError(":(");
            const r = std.os.linux.sendmmsg(socket, &msgs, @intCast(msgs.len), 0);
            switch (std.os.linux.E.init(r)) {
                .SUCCESS => {},
                .AGAIN, .INTR, .CONNREFUSED => continue,
                else => |err| return std.posix.unexpectedErrno(err),
            }
            const n: usize = @intCast(r);
            for (msgs[0..n]) |*rmsg| {
                total_sent += rmsg.len;
                rmsg.hdr.flags = 0;
                rmsg.len = 0;
            }
            total_packets += n * NUM_BUFFERS;
        } else {
            if (comptime VALIDATE) {
                for (total_packets..total_packets + NUM_BUFFERS) |idx| {
                    const parity: u8 = @intCast(idx % 255);
                    buf[(idx - total_packets) * BUFSZ] = parity;
                    buf[(idx - total_packets) * BUFSZ + 1] = parity ^ 32;
                }
            }
            var sqe = try ring.sendmsg(0, 0, &msg, 0);
            sqe.flags |= std.os.linux.IOSQE_FIXED_FILE;
            _ = try ring.submit();
            const n = try ring.copy_cqes(&cqes, 1);
            for (cqes[0..n]) |*cqe| {
                if (cqe.res < 0) {
                    log.err("send cqe: {}", .{cqe.res});
                    std.posix.abort();
                } else {
                    const sz: usize = @intCast(cqe.res);
                    total_sent += sz;
                    total_packets += sz / BUFSZ;
                }
            }
        }
    }

    const end_time = try std.time.Instant.now();

    if (total_sent != total_packets * BUFSZ) {
        log.err("mismatch: {} != {}", .{ total_sent, total_packets * BUFSZ });
    }

    const elapsed: f64 = @as(f64, @floatFromInt(end_time.since(start_time))) / 1e9;
    const bytes_s: f64 = @as(f64, @floatFromInt(total_sent)) / elapsed;
    const pps: f64 = @as(f64, @floatFromInt(total_packets)) / elapsed;
    log.info("sent {} packets", .{total_packets});
    log.info("{d:.2} megabytes/s", .{bytes_s / 1e6});
    log.info("{d:.2} Mpps", .{pps / 1e6});
    log.info("{d:.2} seconds total", .{elapsed});
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
