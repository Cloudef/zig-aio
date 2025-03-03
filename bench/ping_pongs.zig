// provided by mrjbq7

const builtin = @import("builtin");
const std = @import("std");
const aio = @import("aio");
const coro = @import("coro");
const log = std.log.scoped(.ping_pongs);

pub const std_options: std.Options = .{
    .log_level = .debug,
};

const PING_PONG_COUNT = 500_000;

fn server(startup: *coro.ResetEvent) !void {
    var socket: std.posix.socket_t = undefined;
    try coro.io.single(.socket, .{
        .domain = std.posix.AF.INET,
        .flags = std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
        .protocol = std.posix.IPPROTO.TCP,
        .out_socket = &socket,
    });
    defer coro.io.single(.close_socket, .{ .socket = socket }) catch {};

    const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 3131);
    try std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    if (@hasDecl(std.posix.SO, "REUSEPORT")) {
        try std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
    }
    try std.posix.bind(socket, &address.any, address.getOsSockLen());
    try std.posix.listen(socket, 128);

    startup.set();

    var client_sock: std.posix.socket_t = undefined;
    try coro.io.single(.accept, .{ .socket = socket, .out_socket = &client_sock });
    defer coro.io.single(.close_socket, .{ .socket = client_sock }) catch {};

    var buf: [1024]u8 = undefined;
    var len: usize = 0;
    while (true) {
        try coro.io.single(.recv, .{ .socket = client_sock, .buffer = &buf, .out_read = &len });
        if (len == 0) break;
        try coro.io.single(.send, .{ .socket = client_sock, .buffer = buf[0..len] });
    }
}

fn client(startup: *coro.ResetEvent) !void {
    var socket: std.posix.socket_t = undefined;
    try coro.io.single(.socket, .{
        .domain = std.posix.AF.INET,
        .flags = std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
        .protocol = std.posix.IPPROTO.TCP,
        .out_socket = &socket,
    });
    defer coro.io.single(.close_socket, .{ .socket = socket }) catch {};

    try startup.wait();

    const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 3131);
    try coro.io.single(.connect, .{
        .socket = socket,
        .addr = &address.any,
        .addrlen = address.getOsSockLen(),
    });

    const start_time = try std.time.Instant.now();

    var state: usize = 0;
    var pongs: u64 = 0;

    while (pongs < PING_PONG_COUNT) {
        var buf: [1024]u8 = undefined;
        var len: usize = 0;
        try coro.io.multi(.{
            aio.op(.send, .{ .socket = socket, .buffer = "PING" }, .soft),
            aio.op(.recv, .{ .socket = socket, .buffer = &buf, .out_read = &len }, .unlinked),
        });

        state += len;
        pongs += (state / 4);
        state = (state % 4);
    }

    const end_time = try std.time.Instant.now();

    const elapsed = @as(f64, @floatFromInt(end_time.since(start_time))) / 1e9;
    const roundtrips = @as(f64, @floatFromInt(pongs)) / elapsed;
    log.info("{d:.2} Mroundtrips/s", .{roundtrips / 1e6});
    log.info("{d:.2} seconds total", .{elapsed});

    try coro.io.single(.send, .{ .socket = socket, .buffer = "" });
}

pub fn main() !void {
    if (builtin.target.os.tag == .wasi) return error.UnsupportedPlatform;
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    var scheduler = try coro.Scheduler.init(gpa.allocator(), .{});
    defer scheduler.deinit();
    var startup: coro.ResetEvent = .{};
    _ = try scheduler.spawn(client, .{&startup}, .{});
    _ = try scheduler.spawn(server, .{&startup}, .{});
    try scheduler.run(.wait);
}
