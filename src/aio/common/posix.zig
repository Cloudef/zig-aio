const std = @import("std");
const builtin = @import("builtin");
const Operation = @import("../ops.zig").Operation;
const windows = @import("windows.zig");

pub const RENAME_NOREPLACE = 1 << 0;
pub const O_NONBLOCK = @as(usize, 1 << @bitOffsetOf(std.posix.O, "NONBLOCK"));

const EventFd = struct {
    fd: std.posix.fd_t,

    pub inline fn init() !@This() {
        return .{ .fd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.SEMAPHORE) };
    }

    pub inline fn deinit(self: *@This()) void {
        std.posix.close(self.fd);
        self.* = undefined;
    }

    pub inline fn notify(self: *@This()) void {
        while (true) {
            _ = std.posix.write(self.fd, &std.mem.toBytes(@as(u64, 1))) catch continue;
            break;
        }
    }

    pub inline fn notifyReadiness(self: *@This()) Readiness {
        return .{ .fd = self.fd, .mode = .out };
    }

    pub inline fn wait(self: *@This()) void {
        while (true) {
            var v: u64 = undefined;
            _ = std.posix.read(self.fd, std.mem.asBytes(&v)) catch continue;
            break;
        }
    }

    pub inline fn waitReadiness(self: *@This()) Readiness {
        return .{ .fd = self.fd, .mode = .in };
    }
};

const Kqueue = struct {
    fd: std.posix.fd_t,
    counter: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub inline fn init() !@This() {
        return .{ .fd = try std.posix.kqueue() };
    }

    pub inline fn deinit(self: *@This()) void {
        std.posix.close(self.fd);
        self.* = undefined;
    }

    pub inline fn notify(self: *@This()) void {
        while (true) {
            _ = std.posix.kevent(self.fd, &.{.{
                .ident = self.counter.fetchAdd(1, .monotonic),
                .filter = std.posix.system.EVFILT_USER,
                .flags = std.posix.system.EV_ADD | std.posix.system.EV_ENABLE | std.posix.system.EV_ONESHOT,
                .fflags = std.posix.system.NOTE_TRIGGER,
                .data = 0,
                .udata = 0,
            }}, &.{}, null) catch continue;
            break;
        }
    }

    pub inline fn notifyReadiness(_: *@This()) Readiness {
        return .{};
    }

    pub inline fn wait(self: *@This()) void {
        while (true) {
            var ev: [1]std.posix.Kevent = undefined;
            _ = std.posix.kevent(self.fd, &.{}, &ev, null) catch |err| switch (err) {
                error.EventNotFound => unreachable,
                error.ProcessNotFound => unreachable,
                error.AccessDenied => unreachable,
                else => continue,
            };
            break;
        }
    }

    pub inline fn waitReadiness(self: *@This()) Readiness {
        return .{ .fd = self.fd, .mode = .in };
    }
};

pub const EventSource = switch (builtin.target.os.tag) {
    .windows => windows.EventSource,
    .macos, .ios, .watchos, .visionos, .tvos, .freebsd => Kqueue,
    else => EventFd,
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

pub inline fn statusToTerm(status: u32) std.process.Child.Term {
    return if (std.posix.W.IFEXITED(status))
        .{ .Exited = std.posix.W.EXITSTATUS(status) }
    else if (std.posix.W.IFSIGNALED(status))
        .{ .Signal = std.posix.W.TERMSIG(status) }
    else if (std.posix.W.IFSTOPPED(status))
        .{ .Stopped = std.posix.W.STOPSIG(status) }
    else
        .{ .Unknown = status };
}

fn read(op: anytype) !void {
    op.out_read.* = std.posix.pread(op.file.handle, op.buffer, op.offset) catch |err| switch (err) {
        error.Unseekable => |e| if (op.offset == 0) try std.posix.read(op.file.handle, op.buffer) else return e,
        else => |e| return e,
    };
}

fn write(op: anytype) !void {
    const written = std.posix.pwrite(op.file.handle, op.buffer, op.offset) catch |err| switch (err) {
        error.Unseekable => |e| if (op.offset == 0) try std.posix.write(op.file.handle, op.buffer) else return e,
        else => |e| return e,
    };
    if (op.out_written) |w| w.* = written;
}

pub inline fn perform(op: anytype, readiness: Readiness) Operation.Error!void {
    while (true) { // for handling INTR
        switch (comptime Operation.tagFromPayloadType(@TypeOf(op.*))) {
            .fsync => _ = try std.posix.fsync(op.file.handle),
            .read => read(op) catch |err| switch (err) {
                error.Unexpected => |e| return if (builtin.target.os.tag == .windows) error.NotOpenForReading else e,
                else => |e| return e,
            },
            .write => write(op) catch |err| switch (err) {
                error.Unexpected => |e| return if (builtin.target.os.tag == .windows) error.NotOpenForWriting else e,
                else => |e| return e,
            },
            .accept => op.out_socket.* = try std.posix.accept(op.socket, op.addr, op.inout_addrlen, 0),
            .connect => _ = try std.posix.connect(op.socket, op.addr, op.addrlen),
            .recv => op.out_read.* = try std.posix.recv(op.socket, op.buffer, 0),
            .send => {
                const written = try std.posix.send(op.socket, op.buffer, 0);
                if (op.out_written) |w| w.* = written;
            },
            .recv_msg => {
                const e = std.posix.errno(recvmsg(op.socket, op.out_msg, 0));
                if (e != .SUCCESS) return switch (e) {
                    .SUCCESS, .INVAL, .BADF, .NOTSOCK => unreachable,
                    .INTR, .AGAIN => continue,
                    .CONNREFUSED => error.ConnectionRefused,
                    .FAULT => error.Unexpected,
                    .NOMEM => error.SystemResources,
                    .NOTCONN => error.SocketNotConnected,
                    else => std.posix.unexpectedErrno(e),
                };
            },
            .send_msg => {
                if (@hasDecl(std.posix.system, "msghdr_const")) {
                    _ = try std.posix.sendmsg(op.socket, op.msg, 0);
                } else {
                    const e = std.posix.errno(sendmsg(op.socket, op.msg, 0));
                    if (e != .SUCCESS) return switch (e) {
                        .SUCCESS, .INVAL, .BADF, .NOTSOCK => unreachable,
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
            },
            .shutdown => try std.posix.shutdown(op.socket, op.how),
            .open_at => if (builtin.target.os.tag == .windows) {
                op.out_file.* = try op.dir.openFileZ(op.path, op.flags);
            } else {
                op.out_file.handle = try std.posix.openatZ(op.dir.fd, op.path, convertOpenFlags(op.flags), 0);
            },
            .close_file => std.posix.close(op.file.handle),
            .close_dir => std.posix.close(op.dir.fd),
            .rename_at => {
                if (@hasDecl(std.posix.system, "renameat2")) {
                    const res = std.posix.system.renameat2(op.old_dir.fd, op.old_path, op.new_dir.fd, op.new_path, RENAME_NOREPLACE);
                    const e = std.posix.errno(res);
                    if (e != .SUCCESS) return switch (e) {
                        .SUCCESS, .INVAL => unreachable,
                        .INTR, .AGAIN => continue,
                        .CANCELED => error.Canceled,
                        .ACCES => error.AccessDenied,
                        .PERM => error.AccessDenied,
                        .BUSY => error.FileBusy,
                        .DQUOT => error.DiskQuota,
                        .FAULT => unreachable,
                        .ISDIR => error.IsDir,
                        .LOOP => error.SymLinkLoop,
                        .MLINK => error.LinkQuotaExceeded,
                        .NAMETOOLONG => error.NameTooLong,
                        .NOENT => error.FileNotFound,
                        .NOTDIR => error.NotDir,
                        .NOMEM => error.SystemResources,
                        .NOSPC => error.NoSpaceLeft,
                        .EXIST => error.PathAlreadyExists,
                        .NOTEMPTY => error.PathAlreadyExists,
                        .ROFS => error.ReadOnlyFileSystem,
                        .XDEV => error.RenameAcrossMountPoints,
                        else => std.posix.unexpectedErrno(e),
                    };
                } else {
                    // this is racy :(
                    if (builtin.target.os.tag == .windows) {
                        // access is weird on windows
                        if (op.new_dir.openFileZ(op.new_path, .{ .mode = .read_write })) |f| {
                            f.close();
                            return error.PathAlreadyExists;
                        } else |err| switch (err) {
                            error.FileNotFound => {}, // ok
                            else => |e| return e,
                        }
                    } else {
                        if (op.new_dir.accessZ(op.new_path, .{ .mode = .read_write })) {
                            return error.PathAlreadyExists;
                        } else |err| switch (err) {
                            error.FileNotFound => {}, // ok
                            else => |e| return e,
                        }
                    }
                    try std.posix.renameatZ(op.old_dir.fd, op.old_path, op.new_dir.fd, op.new_path);
                }
            },
            .unlink_at => try std.posix.unlinkatZ(op.dir.fd, op.path, 0),
            .mkdir_at => try std.posix.mkdiratZ(op.dir.fd, op.path, op.mode),
            .symlink_at => if (builtin.target.os.tag == .windows) {
                try op.dir.symLinkZ(op.target, op.link_path, .{});
            } else {
                try std.posix.symlinkatZ(op.target, op.dir.fd, op.link_path);
            },
            .child_exit => {
                if (builtin.target.os.tag == .windows) {
                    @panic("fixme");
                } else if (comptime @hasDecl(std.posix.system, "waitid")) {
                    var siginfo: std.posix.siginfo_t = undefined;
                    _ = std.posix.system.waitid(.PIDFD, readiness.fd, &siginfo, std.posix.W.EXITED | std.posix.W.NOHANG);
                    if (op.out_term) |term| term.* = statusToTerm(@intCast(siginfo.fields.common.second.sigchld.status));
                } else {
                    const res = std.posix.waitpid(op.child, std.posix.W.NOHANG);
                    if (op.out_term) |term| term.* = statusToTerm(res.status);
                }
            },
            .socket => op.out_socket.* = try std.posix.socket(op.domain, op.flags, op.protocol),
            .close_socket => std.posix.close(op.socket),
            .notify_event_source => op.source.notify(),
            .wait_event_source => op.source.wait(),
            .close_event_source => op.source.deinit(),
            // this function is meant for execution on a thread, it makes no sense to execute these on a thread
            .nop, .timeout, .link_timeout, .cancel => unreachable,
        }
        break;
    }
}

pub const Readiness = struct {
    fd: std.posix.fd_t = if (builtin.target.os.tag == .windows) std.os.windows.INVALID_HANDLE_VALUE else 0,
    mode: enum { noop, in, out } = .noop,
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
        .write => blk: {
            if (builtin.target.isDarwin() and std.posix.isatty(op.file.handle)) {
                return .{}; // nice :D will block one thread
            }
            break :blk .{ .fd = op.file.handle, .mode = .out };
        },
        .read => blk: {
            if (builtin.target.isDarwin() and std.posix.isatty(op.file.handle)) {
                return .{}; // nice :D will block one thread
            }
            break :blk .{ .fd = op.file.handle, .mode = .in };
        },
        .accept, .recv, .recv_msg => .{ .fd = op.socket, .mode = .in },
        .socket, .connect, .shutdown => .{},
        .send, .send_msg => .{ .fd = op.socket, .mode = .out },
        .open_at, .close_file, .close_dir, .close_socket => .{},
        .timeout, .link_timeout => blk: {
            if (builtin.target.os.tag == .windows) {
                break :blk .{ .fd = windows.CreateWaitableTimerExW(null, null, 0, windows.TIMER_ALL_ACCESS), .mode = .in };
            } else if (comptime @hasDecl(std.posix.system, "timerfd_create")) {
                const fd = std.posix.timerfd_create(std.posix.CLOCK.MONOTONIC, .{ .CLOEXEC = true, .NONBLOCK = true }) catch |err| return switch (err) {
                    error.AccessDenied => unreachable,
                    else => |e| e,
                };
                break :blk .{ .fd = fd, .mode = .in };
            } else if (comptime @hasDecl(std.posix.system, "kqueue")) {
                break :blk .{ .fd = try std.posix.kqueue(), .mode = .in };
            } else {
                @panic("unsupported");
            }
        },
        .cancel, .rename_at, .unlink_at, .mkdir_at, .symlink_at => .{},
        .child_exit => blk: {
            if (builtin.target.os.tag == .windows) {
                @panic("fixme");
            } else if (comptime @hasDecl(std.posix.system, "pidfd_open")) {
                const res = std.posix.system.pidfd_open(op.child, O_NONBLOCK);
                const e = std.posix.errno(res);
                if (e != .SUCCESS) return switch (e) {
                    .INVAL, .SRCH => unreachable,
                    .MFILE => error.ProcessFdQuotaExceeded,
                    .NFILE => error.SystemFdQuotaExceeded,
                    .NODEV => error.NoDevice,
                    .NOMEM => error.SystemResources,
                    else => std.posix.unexpectedErrno(e),
                };
                break :blk .{ .fd = @intCast(res), .mode = .in };
            } else if (comptime @hasDecl(std.posix.system, "kqueue")) {
                const fd = try std.posix.kqueue();
                _ = std.posix.kevent(fd, &.{.{
                    .ident = @intCast(op.child),
                    .filter = std.posix.system.EVFILT_PROC,
                    .flags = std.posix.system.EV_ADD | std.posix.system.EV_ENABLE | std.posix.system.EV_ONESHOT,
                    .fflags = std.posix.system.NOTE_EXIT,
                    .data = 0,
                    .udata = 0,
                }}, &.{}, null) catch |err| return switch (err) {
                    error.EventNotFound => unreachable,
                    error.ProcessNotFound => unreachable,
                    error.AccessDenied => unreachable,
                    error.SystemResources => |e| e,
                    else => error.Unexpected,
                };
                break :blk .{ .fd = fd, .mode = .in };
            } else {
                @panic("unsupported");
            }
        },
        .wait_event_source => op.source.native.waitReadiness(),
        .notify_event_source => op.source.native.notifyReadiness(),
        .close_event_source => .{},
    };
}

pub const ArmReadinessError = error{
    SystemResources,
    Unexpected,
};

pub inline fn armReadiness(op: anytype, readiness: Readiness) ArmReadinessError!void {
    switch (comptime Operation.tagFromPayloadType(@TypeOf(op.*))) {
        .timeout, .link_timeout => {
            if (builtin.target.os.tag == .windows) {
                const rel_time: i128 = @intCast(op.ns);
                const li = windows.nanoSecondsToTimerTime(-rel_time);
                std.debug.assert(windows.SetWaitableTimer(readiness.fd, &li, 0, null, null, 0) != 0);
            } else if (comptime @hasDecl(std.posix.system, "timerfd_create")) {
                const ts: std.os.linux.itimerspec = .{
                    .it_value = .{
                        .tv_sec = @intCast(op.ns / std.time.ns_per_s),
                        .tv_nsec = @intCast(op.ns % std.time.ns_per_s),
                    },
                    .it_interval = .{
                        .tv_sec = 0,
                        .tv_nsec = 0,
                    },
                };
                _ = std.posix.timerfd_settime(readiness.fd, .{}, &ts, null) catch |err| return switch (err) {
                    error.Canceled, error.InvalidHandle => unreachable,
                    error.Unexpected => |e| e,
                };
            } else if (comptime @hasDecl(std.posix.system, "kqueue")) {
                _ = std.posix.kevent(readiness.fd, &.{.{
                    .ident = @intCast(readiness.fd),
                    .filter = std.posix.system.EVFILT_TIMER,
                    .flags = std.posix.system.EV_ADD | std.posix.system.EV_ENABLE | std.posix.system.EV_ONESHOT,
                    .fflags = std.posix.system.NOTE_NSECONDS,
                    .data = @intCast(op.ns), // :sadface:
                    .udata = 0,
                }}, &.{}, null) catch |err| return switch (err) {
                    error.EventNotFound => unreachable,
                    error.ProcessNotFound => unreachable,
                    error.AccessDenied => unreachable,
                    error.SystemResources => |e| e,
                    else => error.Unexpected,
                };
            } else {
                @panic("unsupported");
            }
        },
        .nop => {},
        .fsync, .read, .write => {},
        .socket, .accept, .connect, .recv, .send, .recv_msg, .send_msg, .shutdown => {},
        .open_at, .close_file, .close_dir, .close_socket => {},
        .cancel, .rename_at, .unlink_at, .mkdir_at, .symlink_at => {},
        .notify_event_source, .wait_event_source, .close_event_source => {},
        .child_exit => {},
    }
}

pub inline fn closeReadiness(op: anytype, readiness: Readiness) void {
    const needs_close = switch (comptime Operation.tagFromPayloadType(@TypeOf(op.*))) {
        .timeout, .link_timeout, .child_exit => true,
        .nop => false,
        .fsync, .read, .write => false,
        .socket, .accept, .connect, .recv, .send, .recv_msg, .send_msg, .shutdown => false,
        .open_at, .close_file, .close_dir, .close_socket => false,
        .cancel, .rename_at, .unlink_at, .mkdir_at, .symlink_at => false,
        .notify_event_source, .wait_event_source, .close_event_source => false,
    };
    if (needs_close) std.posix.close(readiness.fd);
}

pub const invalid_fd = if (builtin.target.os.tag == .windows) std.os.windows.INVALID_HANDLE_VALUE else 0;
pub const pollfd = if (builtin.target.os.tag == .windows) windows.pollfd else std.posix.pollfd;

pub fn poll(pfds: []pollfd, timeout: i32) std.posix.PollError!usize {
    if (builtin.target.os.tag == .windows) {
        return windows.poll(pfds, timeout);
    } else {
        return std.posix.poll(pfds, timeout);
    }
}

const darwin_msghdr = extern struct {
    /// Optional address.
    msg_name: ?*std.posix.sockaddr,
    /// Size of address.
    msg_namelen: std.posix.socklen_t,
    /// Scatter/gather array.
    msg_iov: [*]std.posix.iovec,
    /// Number of elements in msg_iov.
    msg_iovlen: i32,
    /// Ancillary data.
    msg_control: ?*anyopaque,
    /// Ancillary data buffer length.
    msg_controllen: std.posix.socklen_t,
    /// Flags on received message.
    msg_flags: i32,
};

const darwin_msghdr_const = extern struct {
    /// Optional address.
    msg_name: ?*const std.posix.sockaddr,
    /// Size of address.
    msg_namelen: std.posix.socklen_t,
    /// Scatter/gather array.
    msg_iov: [*]std.posix.iovec_const,
    /// Number of elements in msg_iov.
    msg_iovlen: i32,
    /// Ancillary data.
    msg_control: ?*anyopaque,
    /// Ancillary data buffer length.
    msg_controllen: std.posix.socklen_t,
    /// Flags on received message.
    msg_flags: i32,
};

pub const msghdr = if (builtin.target.isDarwin()) darwin_msghdr else std.c.msghdr;
pub const msghdr_const = if (builtin.target.isDarwin()) darwin_msghdr_const else std.c.msghdr_const;

const c = struct {
    pub extern "c" fn recvmsg(sockfd: std.c.fd_t, msg: *msghdr, flags: u32) isize;
    pub extern "c" fn sendmsg(sockfd: std.c.fd_t, msg: *const msghdr_const, flags: u32) isize;
};

const recvmsg = if (@hasDecl(std.posix.system, "msghdr")) std.posix.system.recvmsg else c.recvmsg;
const sendmsg = if (@hasDecl(std.posix.system, "msghdr_const")) std.posix.system.sendmsg else c.sendmsg;
