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
const log = std.log.scoped(.aio_immediate);

pub fn main() !void {
    var f = try std.fs.cwd().openFile("flake.nix", .{});
    defer f.close();
    var buf: [4096]u8 = undefined;
    var len: usize = 0;

    var f2 = try std.fs.cwd().openFile("build.zig.zon", .{});
    defer f2.close();
    var buf2: [4096]u8 = undefined;
    var len2: usize = 0;

    const num_errors = try aio.complete(.{
        aio.Read{
            .file = f,
            .buffer = &buf,
            .out_read = &len,
        },
        aio.Read{
            .file = f2,
            .buffer = &buf2,
            .out_read = &len2,
        },
    });

    log.info("{s}", .{buf[0..len]});
    log.info("{s}", .{buf2[0..len2]});
    log.info("{}", .{num_errors});
}
```

## Perf

`strace -c` output from the `examples/coro.zig` without `std.log` output and with `std.heap.FixedBufferAllocator`.
This is using the `io_uring` backend. `fallback` backend emulates `io_uring` like interface by using a traditional
readiness event loop, thus it will have larger syscall overhead.

```
% time     seconds  usecs/call     calls    errors syscall
------ ----------- ----------- --------- --------- ------------------
 45.31    0.000087          14         6           io_uring_enter
 24.48    0.000047          23         2           io_uring_setup
  9.38    0.000018           4         4           mmap
  6.77    0.000013           3         4           munmap
  5.73    0.000011           5         2           close
  2.60    0.000005           5         1           bind
  2.08    0.000004           4         1           listen
  1.56    0.000003           1         2           setsockopt
  1.56    0.000003           3         1           io_uring_register
  0.52    0.000001           1         1           gettid
  0.00    0.000000           0         5           rt_sigaction
  0.00    0.000000           0         1           execve
  0.00    0.000000           0         1           arch_prctl
  0.00    0.000000           0         2           prlimit64
------ ----------- ----------- --------- --------- ------------------
100.00    0.000192           5        33           total
```
