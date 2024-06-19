const std = @import("std");
const aio = @import("aio");
const coro = @import("coro");
const log = std.log.scoped(.coro_aio);

pub const aio_coro_options: coro.Options = .{
    .debug = false, // set to true to enable debug logs
};

const Yield = enum {
    server_ready,
};

fn server(client_task: coro.Task) !void {
    var socket: std.posix.socket_t = undefined;
    try coro.io.single(aio.Socket{
        .domain = std.posix.AF.INET,
        .flags = std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
        .protocol = std.posix.IPPROTO.TCP,
        .out_socket = &socket,
    });

    const address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 1327);
    try std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
    try std.posix.bind(socket, &address.any, address.getOsSockLen());
    try std.posix.listen(socket, 128);

    coro.wakeupFromState(client_task, Yield.server_ready);

    var client_sock: std.posix.socket_t = undefined;
    try coro.io.single(aio.Accept{ .socket = socket, .out_socket = &client_sock });

    var buf: [1024]u8 = undefined;
    var len: usize = 0;
    try coro.io.multi(.{
        aio.Send{ .socket = client_sock, .buffer = "hey ", .link_next = true },
        aio.Send{ .socket = client_sock, .buffer = "I'm doing multiple IO ops at once ", .link_next = true },
        aio.Send{ .socket = client_sock, .buffer = "how cool is that? ", .link_next = true },
        aio.Recv{ .socket = client_sock, .buffer = &buf, .out_read = &len },
    });

    log.warn("got reply from client: {s}", .{buf[0..len]});
    try coro.io.multi(.{
        aio.Send{ .socket = client_sock, .buffer = "ok bye", .link_next = true },
        aio.CloseSocket{ .socket = client_sock, .link_next = true },
        aio.CloseSocket{ .socket = socket },
    });
}

fn client() !void {
    var socket: std.posix.socket_t = undefined;
    try coro.io.single(aio.Socket{
        .domain = std.posix.AF.INET,
        .flags = std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
        .protocol = std.posix.IPPROTO.TCP,
        .out_socket = &socket,
    });

    coro.yield(Yield.server_ready);

    const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 1327);
    try coro.io.single(aio.Connect{
        .socket = socket,
        .addr = &address.any,
        .addrlen = address.getOsSockLen(),
        .link_next = true,
    });

    while (true) {
        var buf: [1024]u8 = undefined;
        var len: usize = 0;
        try coro.io.single(aio.Recv{ .socket = socket, .buffer = &buf, .out_read = &len });
        log.warn("got reply from server: {s}", .{buf[0..len]});
        if (std.mem.indexOf(u8, buf[0..len], "how cool is that?")) |_| break;
    }

    try coro.io.single(aio.Send{ .socket = socket, .buffer = "dude, I don't care" });

    var buf: [1024]u8 = undefined;
    var len: usize = 0;
    try coro.io.single(aio.Recv{ .socket = socket, .buffer = &buf, .out_read = &len });
    log.warn("got final words from server: {s}", .{buf[0..len]});
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    var scheduler = try coro.Scheduler.init(gpa.allocator(), .{});
    defer scheduler.deinit();
    const client_task = try scheduler.spawn(client, .{}, .{});
    _ = try scheduler.spawn(server, .{client_task}, .{});
    try scheduler.run();
}
