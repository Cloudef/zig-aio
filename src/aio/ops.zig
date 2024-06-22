const std = @import("std");
const builtin = @import("builtin");
const aio = @import("../aio.zig");

// Virtual linked actions are possible with `nop` under io_uring :thinking:

pub const Id = enum(usize) { _ };

pub const Link = enum {
    unlinked,
    /// If the operation fails the next operation in the chain will fail as well
    soft,
    /// If the operation fails, the failure is ignored and next operation is started regardless
    hard,
};

// Counter that either increases or decreases a value in a given address
// Reserved when using the coroutines API
const Counter = union(enum) {
    inc: *u16,
    dec: *u16,
    nop: void,
};

const SharedError = error{
    Success,
    OperationCanceled,
    Unexpected,
};

/// std.fs.File.sync
pub const Fsync = struct {
    pub const Error = std.fs.File.SyncError || SharedError;
    file: std.fs.File,
    out_id: ?*Id = null,
    out_error: ?*Error = null,
    counter: Counter = .nop,
    link: Link = .unlinked,
};

/// std.fs.File.read
pub const Read = struct {
    pub const Error = std.posix.PReadError || SharedError;
    file: std.fs.File,
    buffer: []u8,
    offset: u64 = 0,
    out_read: *usize,
    out_id: ?*Id = null,
    out_error: ?*Error = null,
    counter: Counter = .nop,
    link: Link = .unlinked,
};

/// std.fs.File.write
pub const Write = struct {
    pub const Error = std.posix.PWriteError || SharedError;
    file: std.fs.File,
    buffer: []const u8,
    offset: u64 = 0,
    out_written: ?*usize = null,
    out_id: ?*Id = null,
    out_error: ?*Error = null,
    counter: Counter = .nop,
    link: Link = .unlinked,
};

/// std.posix.accept
pub const Accept = struct {
    pub const Error = std.posix.AcceptError || SharedError;
    socket: std.posix.socket_t,
    addr: ?*std.posix.sockaddr = null,
    inout_addrlen: ?*std.posix.socklen_t = null,
    out_socket: *std.posix.socket_t,
    out_id: ?*Id = null,
    out_error: ?*Error = null,
    counter: Counter = .nop,
    link: Link = .unlinked,
};

/// std.posix.connect
pub const Connect = struct {
    pub const Error = std.posix.ConnectError || SharedError;
    socket: std.posix.socket_t,
    addr: *const std.posix.sockaddr,
    addrlen: std.posix.socklen_t,
    out_id: ?*Id = null,
    out_error: ?*Error = null,
    counter: Counter = .nop,
    link: Link = .unlinked,
};

/// std.posix.recv
pub const Recv = struct {
    pub const Error = std.posix.RecvFromError || SharedError;
    socket: std.posix.socket_t,
    buffer: []u8,
    out_read: *usize,
    out_id: ?*Id = null,
    out_error: ?*Error = null,
    counter: Counter = .nop,
    link: Link = .unlinked,
};

/// std.posix.send
pub const Send = struct {
    pub const Error = std.posix.SendError || SharedError;
    socket: std.posix.socket_t,
    buffer: []const u8,
    out_written: ?*usize = null,
    out_id: ?*Id = null,
    out_error: ?*Error = null,
    counter: Counter = .nop,
    link: Link = .unlinked,
};

// TODO: recvmsg, sendmsg

/// std.fs.Dir.openFile
pub const OpenAt = struct {
    pub const Error = std.fs.File.OpenError || SharedError;
    dir: std.fs.Dir,
    path: [*:0]const u8,
    flags: std.fs.File.OpenFlags = .{},
    out_file: *std.fs.File,
    out_id: ?*Id = null,
    out_error: ?*Error = null,
    counter: Counter = .nop,
    link: Link = .unlinked,
};

/// std.fs.File.close
pub const CloseFile = struct {
    pub const Error = SharedError;
    file: std.fs.File,
    out_id: ?*Id = null,
    out_error: ?*Error = null,
    counter: Counter = .nop,
    link: Link = .unlinked,
};

/// std.fs.Dir.Close
pub const CloseDir = struct {
    pub const Error = SharedError;
    dir: std.fs.Dir,
    out_id: ?*Id = null,
    out_error: ?*Error = null,
    counter: Counter = .nop,
    link: Link = .unlinked,
};

/// std.time.Timer.start
pub const Timeout = struct {
    pub const Error = SharedError;
    ns: u128,
    out_id: ?*Id = null,
    out_error: ?*Error = null,
    counter: Counter = .nop,
    link: Link = .unlinked,
};

/// Timeout linked to a operation
/// This must be linked last and the operation before must have set `link` to either `soft` or `hard`
/// If the operation finishes before the timeout the timeout will be canceled
pub const LinkTimeout = struct {
    pub const Error = error{Expired} || SharedError;
    ns: u128,
    out_id: ?*Id = null,
    out_error: ?*Error = null,
    counter: Counter = .nop,
    link: Link = .unlinked,
};

/// Cancel a operation
pub const Cancel = struct {
    pub const Error = error{ Success, InProgress, NotFound };
    id: Id,
    out_error: ?*Error = null,
    counter: Counter = .nop,
    link: Link = .unlinked,
};

/// std.fs.rename
pub const RenameAt = struct {
    pub const Error = std.fs.Dir.RenameError || SharedError;
    old_dir: std.fs.Dir,
    old_path: [*:0]const u8,
    new_dir: std.fs.Dir,
    new_path: [*:0]const u8,
    out_id: ?*Id = null,
    out_error: ?*Error = null,
    counter: Counter = .nop,
    link: Link = .unlinked,
};

/// std.fs.Dir.deleteFile
pub const UnlinkAt = struct {
    pub const Error = std.posix.UnlinkatError || SharedError;
    dir: std.fs.Dir,
    path: [*:0]const u8,
    out_id: ?*Id = null,
    out_error: ?*Error = null,
    counter: Counter = .nop,
    link: Link = .unlinked,
};

/// std.fs.Dir.makeDir
pub const MkDirAt = struct {
    pub const Error = std.fs.Dir.MakeError || SharedError;
    dir: std.fs.Dir,
    path: [*:0]const u8,
    mode: u32 = std.fs.Dir.default_mode,
    out_id: ?*Id = null,
    out_error: ?*Error = null,
    counter: Counter = .nop,
    link: Link = .unlinked,
};

/// std.fs.Dir.symlink
pub const SymlinkAt = struct {
    pub const Error = std.posix.SymLinkError || SharedError;
    dir: std.fs.Dir,
    target: [*:0]const u8,
    link_path: [*:0]const u8,
    out_id: ?*Id = null,
    out_error: ?*Error = null,
    counter: Counter = .nop,
    link: Link = .unlinked,
};

// TODO: linkat

/// std.process.Child.wait
pub const ChildExit = struct {
    pub const Error = error{ NotFound, Unexpected } || SharedError;
    child: std.process.Child.Id,
    out_term: ?*std.process.Child.Term = null,
    _: switch (builtin.target.os.tag) {
        .linux => std.posix.siginfo_t, // only required for io_uring
        else => void,
    } = undefined,
    out_id: ?*Id = null,
    out_error: ?*Error = null,
    counter: Counter = .nop,
    link: Link = .unlinked,
};

/// std.posix.socket
pub const Socket = struct {
    pub const Error = std.posix.SocketError || SharedError;
    /// std.posix.AF
    domain: u32,
    /// std.posix.SOCK
    flags: u32,
    /// std.posix.IPPROTO
    protocol: u32,
    out_socket: *std.posix.socket_t,
    out_id: ?*Id = null,
    out_error: ?*Error = null,
    counter: Counter = .nop,
    link: Link = .unlinked,
};

/// std.posix.close
pub const CloseSocket = struct {
    pub const Error = std.posix.SocketError || SharedError;
    socket: std.posix.socket_t,
    out_id: ?*Id = null,
    out_error: ?*Error = null,
    counter: Counter = .nop,
    link: Link = .unlinked,
};

pub const NotifyEventSource = struct {
    pub const Error = SharedError;
    source: aio.EventSource,
    out_error: ?*Error = null,
    counter: Counter = .nop,
    link: Link = .unlinked,
};

pub const WaitEventSource = struct {
    pub const Error = SharedError;
    source: aio.EventSource,
    out_error: ?*Error = null,
    counter: Counter = .nop,
    link: Link = .unlinked,
};

pub const CloseEventSource = struct {
    pub const Error = SharedError;
    source: aio.EventSource,
    out_error: ?*Error = null,
    counter: Counter = .nop,
    link: Link = .unlinked,
};

pub const Operation = enum {
    fsync,
    read,
    write,
    accept,
    connect,
    recv,
    send,
    open_at,
    close_file,
    close_dir,
    timeout,
    link_timeout,
    cancel,
    rename_at,
    unlink_at,
    mkdir_at,
    symlink_at,
    child_exit,
    socket,
    close_socket,
    notify_event_source,
    wait_event_source,
    close_event_source,

    pub const map = std.enums.EnumMap(@This(), type).init(.{
        .fsync = Fsync,
        .read = Read,
        .write = Write,
        .accept = Accept,
        .connect = Connect,
        .recv = Recv,
        .send = Send,
        .open_at = OpenAt,
        .close_file = CloseFile,
        .close_dir = CloseDir,
        .timeout = Timeout,
        .link_timeout = LinkTimeout,
        .cancel = Cancel,
        .rename_at = RenameAt,
        .unlink_at = UnlinkAt,
        .mkdir_at = MkDirAt,
        .symlink_at = SymlinkAt,
        .child_exit = ChildExit,
        .socket = Socket,
        .close_socket = CloseSocket,
        .notify_event_source = NotifyEventSource,
        .wait_event_source = WaitEventSource,
        .close_event_source = CloseEventSource,
    });

    pub fn tagFromPayloadType(comptime Op: type) @This() {
        inline for (map.values, 0..) |v, idx| {
            if (Op == v) {
                @setEvalBranchQuota(1_000_0);
                return @enumFromInt(idx);
            }
        }
        unreachable;
    }

    pub const Types = blk: {
        var types: []const type = &.{};
        for (Operation.map.values) |v| types = types ++ .{v};
        break :blk types;
    };

    pub const Union = blk: {
        var fields: []const std.builtin.Type.UnionField = &.{};
        for (Operation.map.values, 0..) |v, idx| fields = fields ++ .{.{
            .name = @tagName(@as(Operation, @enumFromInt(idx))),
            .type = v,
            .alignment = 0,
        }};
        break :blk @Type(.{
            .Union = .{
                .layout = .auto,
                .tag_type = Operation,
                .fields = fields,
                .decls = &.{},
            },
        });
    };

    pub const Error = blk: {
        var set = error{};
        for (Operation.map.values) |v| set = set || v.Error;
        break :blk set;
    };
};
