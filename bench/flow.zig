const std = @import("std");
const aio = @import("aio");
const coro = @import("coro");
const log = std.log.scoped(.flow);

pub const std_options: std.Options = .{
    .log_level = .debug,
};

const BYTES_RECEIVED = 500_000_000;

fn server(startup: *coro.ResetEvent) !void {
    var socket: std.posix.socket_t = undefined;
    try coro.io.single(.socket, .{
        .domain = std.posix.AF.INET,
        .flags = std.posix.SOCK.DGRAM | std.posix.SOCK.CLOEXEC,
        .protocol = std.posix.IPPROTO.UDP,
        .out_socket = &socket,
    });

    const address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 3232);
    try std.posix.bind(socket, &address.any, address.getOsSockLen());

    startup.set();

    const start_time = try std.time.Instant.now();

    var total_received: u64 = 0;

    while (true) {
        var buf: [1500]u8 = undefined;
        var addr: std.posix.sockaddr.storage = undefined;
        var recv_iovec = [_]std.posix.iovec{.{
            .base = &buf,
            .len = buf.len,
        }};
        var recv_msg = aio.posix.msghdr{
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

        total_received += size;

        // If we're done then exit
        if (total_received > BYTES_RECEIVED) {
            break;
        }
    }

    const end_time = try std.time.Instant.now();

    const elapsed: f64 = @floatFromInt(end_time.since(start_time));
    const bytes_s: f64 = @as(f64, @floatFromInt(total_received)) / (elapsed / 1e9);
    log.info("{d:.2} megabytes/s", .{bytes_s / 1e6});
    log.info("{d:.2} seconds total", .{elapsed / 1e9});

    try coro.io.single(.close_socket, .{ .socket = socket });

    std.posix.exit(0);
}

fn client(startup: *coro.ResetEvent) !void {
    var socket: std.posix.socket_t = undefined;
    try coro.io.single(.socket, .{
        .domain = std.posix.AF.INET,
        .flags = std.posix.SOCK.DGRAM | std.posix.SOCK.CLOEXEC,
        .protocol = std.posix.IPPROTO.UDP,
        .out_socket = &socket,
    });

    const address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
    try std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.BROADCAST, std.mem.asBytes(&@as(c_int, 1)));
    try std.posix.bind(socket, &address.any, address.getOsSockLen());

    try startup.wait();

    var buf: [1472]u8 = undefined;
    @memset(&buf, 'P');

    var send_iovec = [_]std.posix.iovec_const{.{
        .base = &buf,
        .len = buf.len,
    }};

    // Prepare message header with destination address
    const send_addr = std.net.Address.initIp4(.{ 255, 255, 255, 255 }, 3232);
    var send_msg = aio.posix.msghdr_const{
        .name = @ptrCast(&send_addr.any),
        .namelen = send_addr.getOsSockLen(),
        .iov = &send_iovec,
        .iovlen = 1,
        .control = null,
        .controllen = 0,
        .flags = 0,
    };

    while (true) {
        // Send the ping
        coro.io.single(.send_msg, .{
            .socket = socket,
            .msg = &send_msg,
        }) catch |err| {
            if (err == error.SystemResources) {
                try coro.io.single(.timeout, .{ .ns = 50 });
                continue;
            } else {
                log.err("Error in clientSend: {any}", .{err});
                return err;
            }
        };
    }

    try coro.io.single(.close_socket, .{ .socket = socket });
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

    var scheduler = try coro.Scheduler.init(allocator, .{});
    defer scheduler.deinit();

    var startup: coro.ResetEvent = .{};
    if (std.mem.eql(u8, mode, "server") or std.mem.eql(u8, mode, "both")) {
        _ = try scheduler.spawn(server, .{&startup}, .{});
    } else {
        startup.set();
    }

    if (std.mem.eql(u8, mode, "client") or std.mem.eql(u8, mode, "both")) {
        _ = try scheduler.spawn(client, .{&startup}, .{});
    }

    try scheduler.run(.wait);
}
