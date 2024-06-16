const std = @import("std");
const builtin = @import("builtin");

// Virtual linked actions are possible with `nop` under io_uring :thinking:

pub const Id = enum(usize) { _ };

/// std.fs.File.sync
pub const Fsync = Define(struct {
    file: std.fs.File,
}, std.fs.File.SyncError);

/// std.fs.File.read
pub const Read = Define(struct {
    file: std.fs.File,
    buffer: []u8,
    offset: u64 = 0,
    out_read: *usize,
}, std.fs.File.ReadError);

/// std.fs.File.write
pub const Write = Define(struct {
    file: std.fs.File,
    buffer: []const u8,
    offset: u64 = 0,
    out_written: ?*usize = null,
}, std.fs.File.WriteError);

// For whatever reason the posix.sockaddr crashes the compiler, so use this
const sockaddr = anyopaque;

/// std.posix.accept
pub const Accept = Define(struct {
    socket: std.posix.socket_t,
    addr: ?*sockaddr = null,
    inout_addrlen: ?*std.posix.socklen_t = null,
    out_socket: *std.posix.socket_t,
}, std.posix.AcceptError);

/// std.posix.connect
pub const Connect = Define(struct {
    socket: std.posix.socket_t,
    addr: *const sockaddr,
    addrlen: std.posix.socklen_t,
}, std.posix.ConnectError);

/// std.posix.recv
pub const Recv = Define(struct {
    socket: std.posix.socket_t,
    buffer: []u8,
    out_read: *usize,
}, std.posix.RecvFromError);

/// std.posix.send
pub const Send = Define(struct {
    socket: std.posix.socket_t,
    buffer: []const u8,
    out_written: ?*usize = null,
}, std.posix.SendError);

// TODO: recvmsg, sendmsg

/// std.fs.Dir.openFile
pub const OpenAt = Define(struct {
    dir: std.fs.Dir,
    path: [*:0]const u8,
    flags: std.fs.File.OpenFlags,
    out_file: *std.fs.File,
}, std.fs.File.OpenError);

/// std.fs.File.close
pub const Close = Define(struct {
    file: std.fs.File,
}, error{});

/// std.time.Timer.start
pub const Timeout = Define(struct {
    ts: struct { sec: i64 = 0, nsec: i64 = 0 },
}, error{});

/// std.time.Timer.cancel (if it existed)
/// XXX: Overlap with `Cancel`, is this even needed? (io_uring)
pub const TimeoutRemove = Define(struct {
    id: Id,
}, error{ InProgress, NotFound });

/// Timeout linked to a operation
/// This must be linked last and the operation before must have set `link_next` to `true`
/// If the operation finishes before the timeout the timeout will be canceled
pub const LinkTimeout = Define(struct {
    ts: struct { sec: i64 = 0, nsec: i64 = 0 },
    out_expired: ?*bool = null,
}, error{InProgress});

/// Cancel a operation
pub const Cancel = Define(struct {
    id: Id,
}, error{ InProgress, NotFound });

/// std.fs.rename
pub const RenameAt = Define(struct {
    old_dir: std.fs.Dir,
    old_path: [*:0]const u8,
    new_dir: std.fs.Dir,
    new_path: [*:0]const u8,
}, std.fs.Dir.RenameError);

/// std.fs.Dir.deleteFile
pub const UnlinkAt = Define(struct {
    dir: std.fs.Dir,
    path: [*:0]const u8,
}, std.posix.UnlinkatError);

/// std.fs.Dir.makeDir
pub const MkDirAt = Define(struct {
    dir: std.fs.Dir,
    path: [*:0]const u8,
    mode: u32 = std.fs.Dir.default_mode,
}, std.fs.Dir.MakeError);

/// std.fs.Dir.symlink
pub const SymlinkAt = Define(struct {
    dir: std.fs.Dir,
    target: [*:0]const u8,
    link_path: [*:0]const u8,
}, std.posix.SymLinkError);

// TODO: linkat

/// std.process.Child.wait
/// TODO: Crashes compiler, doesn't like the std.process fields wut?
pub const WaitId = Define(struct {
    child: std.process.Child.Id,
    out_term: *std.process.Child.Term,
    _: switch (builtin.target.os.tag) {
        .linux => std.os.linux.siginfo_t,
        else => @compileError("unsupported os"),
    },
}, error{});

/// std.posix.socket
pub const Socket = Define(struct {
    /// std.posix.AF
    domain: u32,
    /// std.posix.SOCK
    flags: u32,
    /// std.posix.IPPROTO
    protocol: u32,
    out_socket: *std.posix.socket_t,
}, std.posix.SocketError);

/// std.posix.close
pub const CloseSocket = Define(struct {
    socket: std.posix.socket_t,
}, error{});

pub const Operation = union(enum) {
    fsync: Fsync,
    read: Read,
    write: Write,
    accept: Accept,
    connect: Connect,
    recv: Recv,
    send: Send,
    open_at: OpenAt,
    close: Close,
    timeout: Timeout,
    timeout_remove: TimeoutRemove,
    link_timeout: LinkTimeout,
    cancel: Cancel,
    rename_at: RenameAt,
    unlink_at: UnlinkAt,
    mkdir_at: MkDirAt,
    symlink_at: SymlinkAt,
    // waitid: WaitId,
    socket: Socket,
    close_socket: CloseSocket,

    pub fn tagFromPayloadType(Op: type) std.meta.Tag(Operation) {
        inline for (std.meta.fields(Operation)) |field| {
            if (Op == field.type) {
                @setEvalBranchQuota(1_000_0);
                return std.meta.stringToEnum(std.meta.Tag(Operation), field.name) orelse unreachable;
            }
        }
        unreachable;
    }
};

const SharedError = error{
    Success,
    OperationCanceled,
};

pub const ErrorUnion = SharedError ||
    std.fs.File.SyncError ||
    std.fs.File.ReadError ||
    std.fs.File.WriteError ||
    std.posix.AcceptError ||
    std.posix.ConnectError ||
    std.posix.RecvFromError ||
    std.posix.SendError ||
    std.fs.File.OpenError ||
    error{ InProgress, NotFound } ||
    std.fs.Dir.RenameError ||
    std.posix.UnlinkatError ||
    std.fs.Dir.MakeError ||
    std.posix.SymLinkError ||
    std.process.Child.SpawnError ||
    std.posix.SocketError;

fn Define(T: type, E: type) type {
    // Counter that either increases or decreases a value in a given address
    // Reserved when using the coroutines API
    const Counter = union(enum) {
        inc: *u16,
        dec: *u16,
        nop: void,
    };

    const Super = struct {
        out_id: ?*Id = null,
        out_error: ?*(E || SharedError) = null,
        counter: Counter = .nop,
        link_next: bool = false,
    };

    return @Type(.{
        .Struct = .{
            .layout = .auto,
            .fields = std.meta.fields(T) ++ std.meta.fields(Super),
            .decls = &.{},
            .is_tuple = false,
        },
    });
}
