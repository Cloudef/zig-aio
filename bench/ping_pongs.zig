// provided by mrjbq7

const std = @import("std");
const aio = @import("aio");
const coro = @import("coro");
const log = std.log.scoped(.ping_pongs);

pub const aio_options: aio.Options = .{
    .debug = false, // set to true to enable debug logs
};

pub const coro_options: coro.Options = .{
    .debug = false, // set to true to enable debug logs
};

pub const std_options: std.Options = .{
    .log_level = .debug,
};

const PING_PONG_COUNT = 500_000;

fn server(startup: *coro.ResetEvent) !void {
    var socket: std.posix.socket_t = undefined;
    try coro.io.single(aio.Socket{
        .domain = std.posix.AF.INET,
        .flags = std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
        .protocol = std.posix.IPPROTO.TCP,
        .out_socket = &socket,
    });

    const address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 3131);
    try std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    if (@hasDecl(std.posix.SO, "REUSEPORT")) {
        try std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
    }
    try std.posix.bind(socket, &address.any, address.getOsSockLen());
    try std.posix.listen(socket, 128);

    startup.set();

    var client_sock: std.posix.socket_t = undefined;
    try coro.io.single(aio.Accept{ .socket = socket, .out_socket = &client_sock });

    var buf: [1024]u8 = undefined;
    var len: usize = 0;
    while (true) {
        try coro.io.single(aio.Recv{ .socket = client_sock, .buffer = &buf, .out_read = &len });
        if (len == 0) break;
        try coro.io.single(aio.Send{ .socket = client_sock, .buffer = buf[0..len] });
    }

    try coro.io.multi(.{
        aio.CloseSocket{ .socket = client_sock, .link = .hard },
        aio.CloseSocket{ .socket = socket },
    });
}

fn client(startup: *coro.ResetEvent) !void {
    var socket: std.posix.socket_t = undefined;
    try coro.io.single(aio.Socket{
        .domain = std.posix.AF.INET,
        .flags = std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
        .protocol = std.posix.IPPROTO.TCP,
        .out_socket = &socket,
    });

    try startup.wait();

    const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 3131);
    try coro.io.single(aio.Connect{
        .socket = socket,
        .addr = &address.any,
        .addrlen = address.getOsSockLen(),
    });

    const start_time = try std.time.Instant.now();

    var state: usize = 0;
    var pongs: u64 = 0;

    while (true) {
        var buf: [1024]u8 = undefined;
        var len: usize = 0;
        try coro.io.multi(.{
            aio.Send{ .socket = socket, .buffer = "PING", .link = .hard },
            aio.Recv{ .socket = socket, .buffer = &buf, .out_read = &len },
        });

        state += len;
        pongs += (state / 4);
        state = (state % 4);

        // If we're done then exit
        if (pongs > PING_PONG_COUNT) {
            break;
        }
    }

    const end_time = try std.time.Instant.now();

    const elapsed = @as(f64, @floatFromInt(end_time.since(start_time)));
    log.info("{d:.2} roundtrips/s", .{@as(f64, @floatFromInt(pongs)) / (elapsed / 1e9)});
    log.info("{d:.2} seconds total", .{elapsed / 1e9});

    try coro.io.multi(.{
        aio.Send{ .socket = socket, .buffer = "", .link = .hard },
        aio.CloseSocket{ .socket = socket },
    });
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    var scheduler = try coro.Scheduler.init(gpa.allocator(), .{});
    defer scheduler.deinit();
    var startup: coro.ResetEvent = .{};
    _ = try scheduler.spawn(client, .{&startup}, .{});
    _ = try scheduler.spawn(server, .{&startup}, .{});
    try scheduler.run(.wait);
}
