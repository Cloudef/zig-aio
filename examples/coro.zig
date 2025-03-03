const builtin = @import("builtin");
const std = @import("std");
const aio = @import("aio");
const coro = @import("coro");
const log = std.log.scoped(.coro_aio);

pub const std_options: std.Options = .{
    .log_level = .debug,
};

fn server(startup: *coro.ResetEvent) !void {
    var socket: std.posix.socket_t = undefined;
    try coro.io.single(.socket, .{
        .domain = std.posix.AF.INET,
        .flags = std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
        .protocol = std.posix.IPPROTO.TCP,
        .out_socket = &socket,
    });

    const address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 1327);
    try std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    if (@hasDecl(std.posix.SO, "REUSEPORT")) {
        try std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
    }
    try std.posix.bind(socket, &address.any, address.getOsSockLen());
    try std.posix.listen(socket, 128);

    startup.set();

    var client_sock: std.posix.socket_t = undefined;
    try coro.io.single(.accept, .{ .socket = socket, .out_socket = &client_sock });

    var buf: [1024]u8 = undefined;
    var len: usize = 0;
    try coro.io.multi(.{
        aio.op(.send, .{ .socket = client_sock, .buffer = "hey " }, .soft),
        aio.op(.send, .{ .socket = client_sock, .buffer = "I'm doing multiple IO ops at once " }, .soft),
        aio.op(.send, .{ .socket = client_sock, .buffer = "how cool is that?" }, .soft),
        aio.op(.recv, .{ .socket = client_sock, .buffer = &buf, .out_read = &len }, .unlinked),
    });

    log.warn("got reply from client: {s}", .{buf[0..len]});
    try coro.io.multi(.{
        aio.op(.send, .{ .socket = client_sock, .buffer = "ok bye" }, .soft),
        aio.op(.close_socket, .{ .socket = client_sock }, .soft),
        aio.op(.close_socket, .{ .socket = socket }, .unlinked),
    });
}

fn client(startup: *coro.ResetEvent) !void {
    var socket: std.posix.socket_t = undefined;
    try coro.io.single(.socket, .{
        .domain = std.posix.AF.INET,
        .flags = std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
        .protocol = std.posix.IPPROTO.TCP,
        .out_socket = &socket,
    });

    try startup.wait();

    const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 1327);
    try coro.io.single(.connect, .{
        .socket = socket,
        .addr = &address.any,
        .addrlen = address.getOsSockLen(),
    });

    while (true) {
        var buf: [1024]u8 = undefined;
        var len: usize = 0;
        try coro.io.single(.recv, .{ .socket = socket, .buffer = &buf, .out_read = &len });
        log.warn("got reply from server: {s}", .{buf[0..len]});
        if (std.mem.indexOf(u8, buf[0..len], "how cool is that?")) |_| break;
    }

    try coro.io.single(.send, .{ .socket = socket, .buffer = "dude, I don't care" });

    var buf: [1024]u8 = undefined;
    var len: usize = 0;
    try coro.io.single(.recv, .{ .socket = socket, .buffer = &buf, .out_read = &len });
    log.warn("got final words from server: {s}", .{buf[0..len]});
}

pub fn main() !void {
    if (builtin.target.os.tag == .wasi) return error.UnsupportedPlatform;
    // var mem: [4096 * 1024]u8 = undefined;
    // var fba = std.heap.FixedBufferAllocator.init(&mem);
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    var scheduler = try coro.Scheduler.init(gpa.allocator(), .{});
    defer scheduler.deinit();
    var startup: coro.ResetEvent = .{};
    _ = try scheduler.spawn(client, .{&startup}, .{});
    _ = try scheduler.spawn(server, .{&startup}, .{});
    try scheduler.run(.wait);
}
