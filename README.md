# zig-aio

zig-aio provides io_uring like asynchronous API and coroutine powered IO tasks for zig

* [Documentation](https://cloudef.github.io/zig-aio)

---

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Project is tested on zig version 0.14.0-dev.32+4aa15440c

## Example

```zig
const std = @import("std");
const aio = @import("aio");
const coro = @import("coro");
const log = std.log.scoped(.coro_aio);

pub const aio_options: aio.Options = .{
    .debug = false, // set to true to enable debug logs
};

pub const coro_options: coro.Options = .{
    .debug = false, // set to true to enable debug logs
};

pub const std_options: std.Options = .{
    .log_level = .debug,
};

fn server(startup: *coro.ResetEvent) !void {
    var socket: std.posix.socket_t = undefined;
    try coro.io.single(aio.Socket{
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
    try coro.io.single(aio.Accept{ .socket = socket, .out_socket = &client_sock });

    var buf: [1024]u8 = undefined;
    var len: usize = 0;
    try coro.io.multi(.{
        aio.Send{ .socket = client_sock, .buffer = "hey ", .link = .soft },
        aio.Send{ .socket = client_sock, .buffer = "I'm doing multiple IO ops at once ", .link = .soft },
        aio.Send{ .socket = client_sock, .buffer = "how cool is that? ", .link = .soft },
        aio.Recv{ .socket = client_sock, .buffer = &buf, .out_read = &len },
    });

    log.warn("got reply from client: {s}", .{buf[0..len]});
    try coro.io.multi(.{
        aio.Send{ .socket = client_sock, .buffer = "ok bye", .link = .soft },
        aio.CloseSocket{ .socket = client_sock, .link = .soft },
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

    const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 1327);
    try coro.io.single(aio.Connect{
        .socket = socket,
        .addr = &address.any,
        .addrlen = address.getOsSockLen(),
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
```

## Perf

`strace -c` output from the `examples/coro.zig` without `std.log` output and with `std.heap.FixedBufferAllocator`.
This is using the `io_uring` backend. `fallback` backend emulates `io_uring` like interface by using a traditional
readiness event loop, thus it will have larger syscall overhead.

```
% time     seconds  usecs/call     calls    errors syscall
------ ----------- ----------- --------- --------- ------------------
  0.00    0.000000           0         2           close
  0.00    0.000000           0         4           mmap
  0.00    0.000000           0         4           munmap
  0.00    0.000000           0         5           rt_sigaction
  0.00    0.000000           0         1           bind
  0.00    0.000000           0         1           listen
  0.00    0.000000           0         2           setsockopt
  0.00    0.000000           0         1           execve
  0.00    0.000000           0         1           arch_prctl
  0.00    0.000000           0         1           gettid
  0.00    0.000000           0         2           prlimit64
  0.00    0.000000           0         2           io_uring_setup
  0.00    0.000000           0         6           io_uring_enter
  0.00    0.000000           0         1           io_uring_register
------ ----------- ----------- --------- --------- ------------------
100.00    0.000000           0        33           total
```
