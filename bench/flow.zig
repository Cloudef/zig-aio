const builtin = @import("builtin");
const std = @import("std");
const aio = @import("aio");
const coro = @import("coro");
const log = std.log.scoped(.flow);

pub const std_options: std.Options = .{
    .log_level = .debug,
};

const CQES = 4096 * 2;
const NUM_PACKETS = 1_000_000;
const NUM_BUFFERS = switch (builtin.target.os.tag) {
    .linux => 64, // GSO/GRO
    else => 1,
};
const BUFSZ = 512;

const UDP_SEGMENT = 103;
const UDP_GRO = 104;

const VALIDATE: bool = false;

fn server(startup: *coro.ResetEvent) !void {
    var socket: std.posix.socket_t = undefined;
    try coro.io.single(.socket, .{
        .domain = std.posix.AF.INET,
        .flags = std.posix.SOCK.DGRAM | std.posix.SOCK.CLOEXEC,
        .protocol = std.posix.IPPROTO.UDP,
        .out_socket = &socket,
    });
    defer coro.io.single(.close_socket, .{ .socket = socket }) catch {};

    if (NUM_BUFFERS > 1) {
        try std.posix.setsockopt(socket, std.posix.IPPROTO.UDP, UDP_GRO, std.mem.asBytes(&@as(c_int, BUFSZ)));
    }

    const address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 3232);
    try std.posix.bind(socket, &address.any, address.getOsSockLen());

    startup.set();

    var total_received: u64 = 0;
    var total_packets: u64 = 0;
    const start_time = try std.time.Instant.now();

    while (total_packets < NUM_PACKETS) {
        var buf: [BUFSZ * NUM_BUFFERS]u8 = undefined;
        var addr: std.posix.sockaddr.storage = undefined;
        var recv_iovec: [1]std.posix.iovec = .{.{
            .base = &buf,
            .len = buf.len,
        }};
        var recv_msg: aio.posix.msghdr = .{
            .name = @ptrCast(&addr),
            .namelen = @sizeOf(@TypeOf(addr)),
            .iov = &recv_iovec,
            .iovlen = 1,
            .control = null,
            .controllen = 0,
            .flags = 0,
        };

        // Receive the request
        var size: usize = undefined;
        coro.io.single(.recv_msg, .{
            .socket = socket,
            .out_msg = &recv_msg,
            .out_read = &size,
        }) catch |err| {
            log.err("Error in serverRecv: {any}", .{err});
            return err;
        };

        if (comptime VALIDATE) {
            for (0..size / BUFSZ) |idx| {
                const off = idx * BUFSZ;
                if (buf[off + 1] != buf[off] ^ 32) {
                    log.err("parity validation failed ({} != {})", .{ buf[off + 1], buf[off] ^ 32 });
                    return error.ValidationFailure;
                }
                if (!std.mem.allEqual(u8, buf[off + 2 .. BUFSZ - 1], 'P')) {
                    log.err("packet validation failed", .{});
                    return error.ValidationFailure;
                }
            }
        }

        total_received += size;
        total_packets += size / BUFSZ;
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

fn client(startup: *coro.ResetEvent, mode: ClientMode) !void {
    var socket: std.posix.socket_t = undefined;
    try coro.io.single(.socket, .{
        .domain = std.posix.AF.INET,
        .flags = std.posix.SOCK.DGRAM | std.posix.SOCK.CLOEXEC,
        .protocol = std.posix.IPPROTO.UDP,
        .out_socket = &socket,
    });
    defer coro.io.single(.close_socket, .{ .socket = socket }) catch {};

    const address = std.net.Address.initIp4(switch (mode) {
        .local => .{ 127, 0, 0, 1 },
        .remote => .{ 0, 0, 0, 0 },
    }, 0);
    try std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.BROADCAST, std.mem.asBytes(&@as(c_int, 1)));

    if (NUM_BUFFERS > 1) {
        try std.posix.setsockopt(socket, std.posix.IPPROTO.UDP, UDP_SEGMENT, std.mem.asBytes(&@as(c_int, BUFSZ)));
    }

    try std.posix.bind(socket, &address.any, address.getOsSockLen());

    var buf: [BUFSZ * NUM_BUFFERS]u8 = undefined;
    @memset(&buf, 'P');

    const send_iovec: []const std.posix.iovec_const = &.{.{
        .base = &buf,
        .len = buf.len,
    }};

    const send_addr = std.net.Address.initIp4(.{ 255, 255, 255, 255 }, 3232);
    var send_msg: aio.posix.msghdr_const = .{
        .name = @ptrCast(&send_addr.any),
        .namelen = send_addr.getOsSockLen(),
        .iov = send_iovec.ptr,
        .iovlen = 1,
        .control = null,
        .controllen = 0,
        .flags = 0,
    };

    try startup.wait();
    var total_packets: u64 = 0;
    var total_sent: u64 = 0;
    const start_time = try std.time.Instant.now();

    // use higher multiplier on VALIDATE as it slows down receiver and udp packets may be dropped
    const MULTIPLIER = if (VALIDATE) 4 else 2;
    while (total_packets < NUM_PACKETS * MULTIPLIER) {
        if (comptime VALIDATE) {
            for (total_packets..total_packets + NUM_BUFFERS) |idx| {
                const parity: u8 = @intCast(idx % 255);
                buf[(idx - total_packets) * BUFSZ] = parity;
                buf[(idx - total_packets) * BUFSZ + 1] = parity ^ 32;
            }
        }
        var size: usize = 0;
        coro.io.single(.send_msg, .{
            .socket = socket,
            .msg = &send_msg,
            .out_written = &size,
        }) catch |err| {
            if (err == error.SystemResources) {
                try coro.io.single(.timeout, .{ .ns = 50 });
                continue;
            } else {
                log.err("Error in clientSend: {any}", .{err});
                return err;
            }
        };
        total_packets += size / BUFSZ;
        total_sent += size;
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

    var scheduler = try coro.Scheduler.init(allocator, .{ .io_queue_entries = CQES });
    defer scheduler.deinit();

    var startup: coro.ResetEvent = .{};
    if (std.mem.eql(u8, mode, "server") or std.mem.eql(u8, mode, "both")) {
        _ = try scheduler.spawn(server, .{&startup}, .{ .detached = true });
    } else {
        startup.set();
    }

    if (std.mem.eql(u8, mode, "client") or std.mem.eql(u8, mode, "both")) {
        const cmode: ClientMode = if (std.mem.eql(u8, mode, "both")) .local else .remote;
        _ = try scheduler.spawn(client, .{ &startup, cmode }, .{ .detached = true });
    }

    try scheduler.run(.wait);
}
