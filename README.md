# zig-aio

zig-aio provides io_uring like asynchronous API and coroutine powered IO tasks for zig

* [Documentation](https://cloudef.github.io/zig-aio)

---

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Project is tested on zig version 0.13.0

## Support matrix

| OS      | AIO             | CORO            |
|---------|-----------------|-----------------|
| Linux   | io_uring, posix | x86_64, aarch64 |
| Windows | iocp            | x86_64, aarch64 |
| Darwin  | posix           | x86_64, aarch64 |
| *BSD    | posix           | x86_64, aarch64 |
| WASI    | posix           | ❌              |

* io_uring AIO backend is a light wrapper, where most of the code is error mapping
* WASI may eventually get coro support [Stack Switching Proposal](https://github.com/WebAssembly/stack-switching/blob/main/proposals/stack-switching/Explainer.md)

## Example

```zig
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
```

## Syscall overhead

`strace -c` output from the `examples/coro.zig` without `std.log` output and with `std.heap.FixedBufferAllocator`.
This is using the `io_uring` backend. `posix` backend emulates `io_uring` like interface by using a traditional
readiness event loop, thus it will have larger syscall overhead. Posix backend may still be faster than io_uring
depending on usage.

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
