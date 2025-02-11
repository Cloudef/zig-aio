const std = @import("std");
const aio = @import("aio");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var dyn = try aio.Dynamic.init(allocator, 16);
    defer dyn.deinit(allocator);

    var socket: std.posix.socket_t = undefined;
    try dyn.queue(aio.op(.socket, .{
        .out_socket = &socket,
        .domain = std.posix.AF.INET,
        .flags = std.posix.SOCK.DGRAM | std.posix.SOCK.NONBLOCK,
        .protocol = std.posix.IPPROTO.UDP,
    }, .unlinked), {});
    {
        const res = try dyn.complete(.blocking, {}); // complete Socket op
        if (res.num_errors != 0) return error.BadResult;
        if (res.num_completed != 1) return error.BadResult;
    }

    const address = try std.net.Address.parseIp4("127.0.0.1", 0);
    try std.posix.bind(socket, &address.any, address.getOsSockLen());

    var buffer: [48]u8 = undefined;
    var read: usize = 0;
    var iov = [1]std.posix.iovec{.{
        .base = &buffer,
        .len = buffer.len,
    }};
    var name: aio.posix.sockaddr = undefined;
    var msghdr: aio.posix.msghdr = .{
        .name = &name,
        .namelen = @sizeOf(aio.posix.sockaddr),
        .iov = &iov,
        .iovlen = 1,
        .control = null,
        .controllen = 0,
        .flags = 0,
    };
    try dyn.queue(aio.op(.recv_msg, .{
        .socket = socket,
        .out_msg = &msghdr,
        .out_read = &read,
    }, .unlinked), {});
    {
        const res = try dyn.complete(.nonblocking, {});
        if (res.num_errors != 0) return error.Mismatch;
        if (res.num_completed != 0) return error.Mismatch;
    }
    try dyn.queue(aio.op(.close_socket, .{
        .socket = socket,
    }, .unlinked), {});
    {
        const res = try dyn.complete(.blocking, {}); // complete CloseSocket op
        if (res.num_completed == 2) {
            if (res.num_errors != 1) return error.Mismatch;
            return; // OK
        } else {
            if (res.num_errors != 0) return error.Mismatch;
            if (res.num_completed != 1) return error.Mismatch;
        }
    }
    {
        // Here is where the problem happens
        // posix: works
        // io_uring: fails
        const res = try dyn.complete(.nonblocking, {}); // receive error result
        if (res.num_errors != 1) return error.Mismatch;
        if (res.num_completed != 1) return error.Mismatch;
    }
}
