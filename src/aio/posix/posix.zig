const std = @import("std");
const builtin = @import("builtin");
const ops = @import("../ops.zig");
const Operation = ops.Operation;
const linux = @import("linux.zig");
const bsd = @import("bsd.zig");
const darwin = @import("darwin.zig");
const windows = @import("windows.zig");
const wasi = @import("wasi.zig");

// Minimum stack size for the `perform` function
pub const stack_size = 512000; // 512KB

// This file implements stuff that's not in std, not implement properly or not
// abstracted for all the platforms that we want to support

/// Used as last resort
pub const PipeEventSource = struct {
    fd: std.posix.fd_t,
    wfd: std.posix.fd_t,

    pub fn init() !@This() {
        const fds = if (@hasField(std.posix.O, "CLOEXEC"))
            try std.posix.pipe2(.{ .CLOEXEC = true })
        else
            try pipe();
        return .{ .fd = fds[0], .wfd = fds[1] };
    }

    pub fn deinit(self: *@This()) void {
        std.posix.close(self.fd);
        std.posix.close(self.wfd);
        self.* = undefined;
    }

    pub fn notify(self: *@This()) void {
        _ = std.posix.write(self.wfd, "1") catch @panic("EventSource.notify failed");
    }

    pub fn notifyReadiness(self: *@This()) Readiness {
        return .{ .fd = self.wfd, .mode = .out };
    }

    pub fn wait(self: *@This()) void {
        var trash: [1]u8 = undefined;
        _ = std.posix.read(self.fd, &trash) catch @panic("EventSource.wait failed");
    }

    pub fn waitReadiness(self: *@This()) Readiness {
        return .{ .fd = self.fd, .mode = .in };
    }
};

pub const EventSource = switch (builtin.target.os.tag) {
    .linux => linux.EventSource,
    .windows => windows.EventSource,
    .freebsd, .openbsd, .dragonfly, .netbsd => bsd.EventSource,
    .macos, .ios, .watchos, .visionos, .tvos => darwin.EventSource,
    .wasi => wasi.EventSource,
    else => PipeEventSource,
};

const DummyChildWatcher = struct {
    id: std.process.Child.Id,
    fd: std.posix.fd_t,

    pub fn init(_: std.process.Child.Id) !@This() {
        @panic("platform does not support posix ChildWatcher");
    }

    pub fn wait(_: *@This()) std.process.Child.Term {
        @panic("platform does not support posix ChildWatcher");
    }

    pub fn deinit(_: *@This()) void {
        @panic("platform does not support posix ChildWatcher");
    }
};

pub const ChildWatcher = switch (builtin.target.os.tag) {
    .linux => linux.ChildWatcher,
    .freebsd, .openbsd, .dragonfly, .netbsd => bsd.ChildWatcher,
    .macos, .ios, .watchos, .visionos, .tvos => darwin.ChildWatcher,
    else => DummyChildWatcher,
};

pub fn convertOpenFlags(flags: std.fs.File.OpenFlags) std.posix.O {
    var os_flags: std.posix.O = .{
        .ACCMODE = switch (flags.mode) {
            .read_only => .RDONLY,
            .write_only => .WRONLY,
            .read_write => .RDWR,
        },
    };
    if (@hasField(std.posix.O, "CLOEXEC")) os_flags.CLOEXEC = true;
    if (@hasField(std.posix.O, "LARGEFILE")) os_flags.LARGEFILE = true;
    if (@hasField(std.posix.O, "NOCTTY")) os_flags.NOCTTY = !flags.allow_ctty;

    // Use the O locking flags if the os supports them to acquire the lock
    // atomically.
    const has_flock_open_flags = @hasField(std.posix.O, "EXLOCK");
    if (has_flock_open_flags) {
        // Note that the NONBLOCK flag is removed after the openat() call
        // is successful.
        switch (flags.lock) {
            .none => {},
            .shared => {
                os_flags.SHLOCK = true;
                os_flags.NONBLOCK = flags.lock_nonblocking;
            },
            .exclusive => {
                os_flags.EXLOCK = true;
                os_flags.NONBLOCK = flags.lock_nonblocking;
            },
        }
    }
    return os_flags;
}

pub fn statusToTerm(status: u32) std.process.Child.Term {
    return if (std.posix.W.IFEXITED(status))
        .{ .Exited = std.posix.W.EXITSTATUS(status) }
    else if (std.posix.W.IFSIGNALED(status))
        .{ .Signal = std.posix.W.TERMSIG(status) }
    else if (std.posix.W.IFSTOPPED(status))
        .{ .Stopped = std.posix.W.STOPSIG(status) }
    else
        .{ .Unknown = status };
}

pub fn readTty(fd: std.posix.fd_t, buf: []u8, mode: ops.ReadTty.Mode) ops.ReadTty.Error!usize {
    return switch (builtin.target.os.tag) {
        .windows => windows.readTty(fd, buf, mode),
        else => std.posix.read(fd, buf),
    };
}

pub fn readUring(fd: std.posix.fd_t, buf: []u8, off: usize) ops.Read.Error!usize {
    const res = blk: {
        if (off == ops.OFFSET_CURRENT_POS) {
            break :blk std.posix.read(fd, buf);
        } else {
            break :blk std.posix.pread(fd, buf, off) catch |err| switch (err) {
                // matches io_uring behaviour
                error.Unseekable => |e| if (off == 0) std.posix.read(fd, buf) else e,
                else => |e| return e,
            };
        }
    };
    return res catch |err| switch (err) {
        error.Unexpected => |e| if (builtin.target.os.tag == .windows) error.NotOpenForReading else e,
        else => |e| e,
    };
}

pub fn writeUring(fd: std.posix.fd_t, buf: []const u8, off: usize) ops.Write.Error!usize {
    const res = blk: {
        if (off == ops.OFFSET_CURRENT_POS) {
            break :blk std.posix.write(fd, buf);
        } else {
            break :blk std.posix.pwrite(fd, buf, off) catch |err| switch (err) {
                // matches io_uring behaviour
                error.Unseekable => |e| if (off == 0) std.posix.write(fd, buf) else e,
                else => |e| e,
            };
        }
    };
    return res catch |err| switch (err) {
        error.Unexpected => |e| if (builtin.target.os.tag == .windows) error.NotOpenForWriting else e,
        else => |e| e,
    };
}

pub fn openAtUring(dir: std.fs.Dir, path: [*:0]const u8, flags: std.fs.File.OpenFlags) ops.OpenAt.Error!std.fs.File {
    if (builtin.target.os.tag == .windows or builtin.target.os.tag == .wasi) {
        return dir.openFileZ(path, flags);
    } else {
        const fd = try std.posix.openatZ(dir.fd, path, convertOpenFlags(flags), 0);
        return .{ .handle = fd };
    }
}

pub fn renameAtUring(
    old_dir: std.fs.Dir,
    old_path: [*:0]const u8,
    new_dir: std.fs.Dir,
    new_path: [*:0]const u8,
) ops.RenameAt.Error!void {
    switch (builtin.target.os.tag) {
        .linux => try linux.renameat2(old_dir.fd, old_path, new_dir.fd, new_path, linux.RENAME_NOREPLACE),
        else => { // the racy method :(
            // access is weird on windows
            if (new_dir.openFileZ(new_path, .{ .mode = .read_write })) |f| {
                f.close();
                return error.PathAlreadyExists;
            } else |err| switch (err) {
                error.FileNotFound => {}, // ok
                else => return error.Unexpected,
            }
            try std.posix.renameatZ(old_dir.fd, old_path, new_dir.fd, new_path);
        },
    }
}

pub fn symlinkAtUring(target: [*:0]const u8, dir: std.fs.Dir, link_path: [*:0]const u8) ops.SymlinkAt.Error!void {
    return switch (builtin.target.os.tag) {
        .windows => dir.symLinkZ(target, link_path, .{}) catch |err| return switch (err) {
            error.NetworkNotFound => error.Unexpected,
            error.NoDevice => error.Unexpected,
            else => |e| e,
        },
        else => try std.posix.symlinkatZ(target, dir.fd, link_path),
    };
}

pub inline fn perform(op: anytype, readiness: Readiness) Operation.Error!void {
    switch (comptime Operation.tagFromPayloadType(@TypeOf(op.*))) {
        .fsync => _ = try fsync(op.file.handle),
        .poll => {},
        .read_tty => op.out_read.* = try readTty(op.tty.handle, op.buffer, op.mode),
        .read => op.out_read.* = try readUring(op.file.handle, op.buffer, @intCast(op.offset)),
        .write => {
            const written = try writeUring(op.file.handle, op.buffer, @intCast(op.offset));
            if (op.out_written) |w| w.* = written;
        },
        .accept => op.out_socket.* = try accept(op.socket, op.out_addr, op.inout_addrlen, 0),
        .connect => _ = try connect(op.socket, op.addr, op.addrlen),
        .recv => op.out_read.* = try recv(op.socket, op.buffer, MSG.DONTWAIT),
        .send => {
            const written = try send(op.socket, op.buffer, MSG.DONTWAIT);
            if (op.out_written) |w| w.* = written;
        },
        .recv_msg => _ = try recvmsg(op.socket, op.out_msg, MSG.DONTWAIT),
        .send_msg => _ = try sendmsg(op.socket, op.msg, MSG.DONTWAIT),
        .shutdown => try shutdown(op.socket, op.how),
        .open_at => op.out_file.* = try openAtUring(op.dir, op.path, op.flags),
        .close_file => std.posix.close(op.file.handle),
        .close_dir => std.posix.close(op.dir.fd),
        .rename_at => try renameAtUring(op.old_dir, op.old_path, op.new_dir, op.new_path),
        .unlink_at => try std.posix.unlinkatZ(op.dir.fd, op.path, 0),
        .mkdir_at => try std.posix.mkdiratZ(op.dir.fd, op.path, op.mode),
        .symlink_at => try symlinkAtUring(op.target, op.dir, op.link_path),
        .child_exit => {
            var watcher: ChildWatcher = .{ .id = op.child, .fd = readiness.fd };
            const term = watcher.wait();
            if (op.out_term) |ot| ot.* = term;
        },
        .socket => op.out_socket.* = try socket(op.domain, op.flags, op.protocol),
        .close_socket => std.posix.close(op.socket),
        // backend can perform these without a thread
        .notify_event_source => op.source.notify(),
        .wait_event_source => op.source.wait(),
        .close_event_source => op.source.deinit(),
        // these must be implemented by the backend
        .nop, .timeout, .link_timeout, .cancel => unreachable,
    }
}

pub const Readiness = struct {
    fd: std.posix.fd_t = invalid_fd,
    mode: enum { nopoll, in, out, kludge } = .nopoll,
};

pub const OpenReadinessError = error{
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    NoDevice,
    SystemResources,
    Unexpected,
};

pub inline fn openReadiness(op: anytype) OpenReadinessError!Readiness {
    return switch (comptime Operation.tagFromPayloadType(@TypeOf(op.*))) {
        .nop => .{},
        .fsync => .{},
        .poll => .{
            .fd = op.fd,
            .mode = switch (op.events) {
                .in => .in,
                .out => .out,
            },
        },
        .write => .{ .fd = op.file.handle, .mode = .out },
        .read_tty => switch (builtin.target.os.tag) {
            .macos, .ios, .watchos, .visionos, .tvos => .{ .mode = .kludge },
            else => .{ .fd = op.tty.handle, .mode = .in },
        },
        .read => .{ .fd = op.file.handle, .mode = .in },
        .accept, .recv, .recv_msg => .{ .fd = op.socket, .mode = .in },
        .socket, .connect, .shutdown => .{},
        .send, .send_msg => .{ .fd = op.socket, .mode = .out },
        .open_at, .close_file, .close_dir, .close_socket => .{},
        .timeout, .link_timeout => .{},
        .cancel, .rename_at, .unlink_at, .mkdir_at, .symlink_at => .{},
        .child_exit => .{ .fd = (try ChildWatcher.init(op.child)).fd, .mode = .in },
        .wait_event_source => op.source.native.waitReadiness(),
        .notify_event_source => op.source.native.notifyReadiness(),
        .close_event_source => .{},
    };
}

pub const ArmReadinessError = error{
    SystemResources,
    Unexpected,
};

pub inline fn closeReadiness(op: anytype, readiness: Readiness) void {
    if (readiness.fd == invalid_fd) return;
    switch (comptime Operation.tagFromPayloadType(@TypeOf(op.*))) {
        .child_exit => {
            var watcher: ChildWatcher = .{ .id = op.child, .fd = readiness.fd };
            watcher.deinit();
        },
        else => {},
    }
}

pub const invalid_fd = switch (builtin.target.os.tag) {
    .windows => std.os.windows.INVALID_HANDLE_VALUE,
    else => -1,
};

pub const socket = switch (builtin.target.os.tag) {
    .windows => windows.socket,
    .wasi => wasi.socket,
    else => std.posix.socket,
};

pub const MSG = switch (builtin.target.os.tag) {
    .freebsd,
    .openbsd,
    .dragonfly,
    .netbsd,
    .macos,
    .ios,
    .watchos,
    .visionos,
    .tvos,
    => struct {
        pub const DONTWAIT = 0x0080;
    },
    .windows, .wasi => struct {
        pub const DONTWAIT = 0x0;
    },
    else => std.posix.MSG,
};

pub const msghdr = switch (builtin.target.os.tag) {
    .windows => windows.msghdr,
    .macos, .ios, .tvos, .watchos, .visionos => darwin.msghdr,
    .wasi => wasi.msghdr,
    else => std.posix.msghdr,
};

pub const msghdr_const = switch (builtin.target.os.tag) {
    .windows => windows.msghdr_const,
    .macos, .ios, .tvos, .watchos, .visionos => darwin.msghdr_const,
    .freebsd, .openbsd, .dragonfly, .netbsd => bsd.msghdr_const,
    .wasi => wasi.msghdr_const,
    else => std.posix.msghdr_const,
};

pub const RecvMsgError = error{
    ConnectionRefused,
    SystemResources,
    SocketNotConnected,
    Unexpected,
};

fn recvmsgPosix(sockfd: std.posix.socket_t, msg: *msghdr, flags: u32) RecvMsgError!usize {
    const c = struct {
        pub extern "c" fn recvmsg(sockfd: std.c.fd_t, msg: *msghdr, flags: u32) isize;
    };
    while (true) {
        switch (builtin.target.os.tag) {
            .linux => {
                const res = std.os.linux.recvmsg(sockfd, msg, flags);
                return switch (linux.errnoFromSyscall(res)) {
                    .SUCCESS => @intCast(res),
                    .INVAL, .BADF, .NOTSOCK => unreachable,
                    .INTR, .AGAIN => continue,
                    .CONNREFUSED => error.ConnectionRefused,
                    .FAULT => error.Unexpected,
                    .NOMEM => error.SystemResources,
                    .NOTCONN => error.SocketNotConnected,
                    else => |e| std.posix.unexpectedErrno(e),
                };
            },
            else => {
                const res = c.recvmsg(sockfd, msg, flags);
                return switch (std.posix.errno(res)) {
                    .SUCCESS => @intCast(res),
                    .INVAL, .BADF, .NOTSOCK => unreachable,
                    .INTR, .AGAIN => continue,
                    .CONNREFUSED => error.ConnectionRefused,
                    .FAULT => error.Unexpected,
                    .NOMEM => error.SystemResources,
                    .NOTCONN => error.SocketNotConnected,
                    else => |e| std.posix.unexpectedErrno(e),
                };
            },
        }
    }
    unreachable;
}

pub const recvmsg = switch (builtin.target.os.tag) {
    .windows => windows.recvmsg,
    .wasi => wasi.recvmsg,
    else => recvmsgPosix,
};

fn sendmsgPosix(sockfd: std.posix.socket_t, msg: *const msghdr_const, flags: u32) std.posix.SendMsgError!usize {
    const c = struct {
        pub extern "c" fn sendmsg(sockfd: std.c.fd_t, msg: *const msghdr_const, flags: u32) isize;
    };
    while (true) {
        const res = c.sendmsg(sockfd, msg, flags);
        const e = std.posix.errno(res);
        return switch (e) {
            .SUCCESS => @intCast(res),
            .INVAL, .BADF, .NOTSOCK => unreachable,
            .ACCES => error.AccessDenied,
            .AGAIN => error.WouldBlock,
            .ALREADY => error.FastOpenAlreadyInProgress,
            .CONNRESET => error.ConnectionResetByPeer,
            .DESTADDRREQ => unreachable, // The socket is not connection-mode, and no peer address is set.
            .FAULT => unreachable, // An invalid user space address was specified for an argument.
            .INTR => continue,
            .ISCONN => unreachable, // connection-mode socket was connected already but a recipient was specified
            .MSGSIZE => error.MessageTooBig,
            .NOBUFS => error.SystemResources,
            .NOMEM => error.SystemResources,
            .OPNOTSUPP => unreachable, // Some bit in the flags argument is inappropriate for the socket type.
            .PIPE => error.BrokenPipe,
            .AFNOSUPPORT => error.AddressFamilyNotSupported,
            .LOOP => error.SymLinkLoop,
            .NAMETOOLONG => error.NameTooLong,
            .NOENT => error.FileNotFound,
            .NOTDIR => error.NotDir,
            .HOSTUNREACH => error.NetworkUnreachable,
            .NETUNREACH => error.NetworkUnreachable,
            .NOTCONN => error.SocketNotConnected,
            .NETDOWN => error.NetworkSubsystemFailed,
            else => std.posix.unexpectedErrno(e),
        };
    }
    unreachable;
}

pub const sendmsg = switch (builtin.target.os.tag) {
    .windows => windows.sendmsg,
    .macos, .ios, .tvos, .watchos, .visionos => sendmsgPosix,
    .dragonfly => sendmsgPosix,
    .wasi => wasi.sendmsg,
    else => std.posix.sendmsg,
};

pub const sockaddr = switch (builtin.target.os.tag) {
    .wasi => wasi.sockaddr,
    else => std.posix.sockaddr,
};

pub const socklen_t = switch (builtin.target.os.tag) {
    .wasi => wasi.socklen_t,
    else => std.posix.socklen_t,
};

pub const accept = switch (builtin.target.os.tag) {
    .wasi => wasi.accept,
    else => std.posix.accept,
};

pub const connect = switch (builtin.target.os.tag) {
    .wasi => wasi.connect,
    else => std.posix.connect,
};

pub const recv = switch (builtin.target.os.tag) {
    .wasi => wasi.recv,
    else => std.posix.recv,
};

pub const send = switch (builtin.target.os.tag) {
    .wasi => wasi.send,
    else => std.posix.send,
};

pub const shutdown = switch (builtin.target.os.tag) {
    .wasi => wasi.shutdown,
    else => std.posix.shutdown,
};

pub const fsync = switch (builtin.target.os.tag) {
    .wasi => wasi.fsync,
    else => std.posix.fsync,
};

pub const pipe = switch (builtin.target.os.tag) {
    .wasi => wasi.pipe,
    else => std.posix.pipe,
};

pub const poll = switch (builtin.target.os.tag) {
    .wasi => wasi.poll,
    else => std.posix.poll,
};
