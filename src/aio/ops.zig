const std = @import("std");
const builtin = @import("builtin");
const aio = @import("../aio.zig");
const posix = @import("posix/posix.zig");

pub const Id = @import("minilib").Id(u16, u8);

pub const Link = enum {
    unlinked,
    /// If the operation fails the next operation in the chain will fail as well
    soft,
    /// If the operation fails, the failure is ignored and next operation is started regardless
    hard,
};

const SharedError = error{
    Success,
    Canceled,
    Unexpected,
};

// TODO: Support rest of the ops from <https://unixism.net/loti/ref-iouring/io_uring_enter.html>
//       Even linux/io_uring only ops

/// Can be used to wakeup the backend, custom notifications, etc...
pub const Nop = struct {
    pub const Error = SharedError;
    out_id: ?*Id = null,
    out_error: ?*Error = null,
    userdata: usize = 0,
};

/// std.fs.File.sync
pub const Fsync = struct {
    pub const Error = std.fs.File.SyncError || SharedError;
    file: std.fs.File,
    out_id: ?*Id = null,
    out_error: ?*Error = null,
    userdata: usize = 0,
};

/// std.io.poll
pub const Poll = struct {
    // Matches Linux structure
    pub const Events = packed struct(u16) {
        in: bool = false,
        pri: bool = false,
        out: bool = false,
        _: u13 = 0,
    };

    pub const Error = std.posix.PollError || SharedError;
    fd: std.posix.fd_t,
    events: Events = .{ .in = true },
    out_id: ?*Id = null,
    out_error: ?*Error = null,
    userdata: usize = 0,
};

/// Special variant of read meant for reading a TTY fd/HANDLE
/// - Uses workarounds on broken platforms such as MacOS where aio.Read would return EINVAL,
///   <https://lists.apple.com/archives/Darwin-dev/2006/Apr/msg00066.html>
///   <https://nathancraddock.com/blog/macos-dev-tty-polling/>
/// - Translates Windows ReadConsoleInputW into Kitty/VT escape sequences (!)
pub const ReadTty = struct {
    pub const TranslationState = switch (builtin.target.os.tag) {
        .windows => struct {
            /// Needed for accurate resize information
            stdout: std.fs.File,
            last_mouse_button_press: u16 = 0,

            pub fn init(stdout: std.fs.File) @This() {
                return .{ .stdout = stdout };
            }
        },
        else => struct {
            pub fn init(_: std.fs.File) @This() {
                return .{};
            }
        },
    };

    pub const Mode = union(enum) {
        /// On windows buffer will contain INPUT_RECORD structs.
        /// The length of the buffer must be able to hold at least one such struct.
        direct: void,
        /// Translate windows console input into ANSI/VT/Kitty compatible input.
        /// Pass reference of the TranslationState, for correct translation a unique reference per stdin handle must be used.
        translation: *TranslationState,
    };

    pub const Error = std.posix.PReadError || error{NoSpaceLeft} || SharedError;
    tty: std.fs.File,
    buffer: []u8,
    out_read: *usize,
    mode: Mode = .direct,
    out_id: ?*Id = null,
    out_error: ?*Error = null,
    userdata: usize = 0,
};

/// See IORING_FEAT_RW_CUR_POS
pub const OFFSET_CURRENT_POS = std.math.maxInt(u64);

/// std.fs.File.read
pub const Read = struct {
    pub const Error = std.posix.PReadError || SharedError;
    file: std.fs.File,
    buffer: []u8,
    offset: u64 = 0,
    out_read: *usize,
    out_id: ?*Id = null,
    out_error: ?*Error = null,
    userdata: usize = 0,
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
    userdata: usize = 0,
};

/// std.posix.accept
pub const Accept = struct {
    pub const Error = std.posix.AcceptError || SharedError;
    socket: std.posix.socket_t,
    out_addr: ?*posix.sockaddr = null,
    inout_addrlen: ?*posix.socklen_t = null,
    out_socket: *std.posix.socket_t,
    out_id: ?*Id = null,
    out_error: ?*Error = null,
    userdata: usize = 0,
};

/// std.posix.connect
pub const Connect = struct {
    pub const Error = std.posix.ConnectError || SharedError;
    socket: std.posix.socket_t,
    addr: *const posix.sockaddr,
    addrlen: posix.socklen_t,
    out_id: ?*Id = null,
    out_error: ?*Error = null,
    userdata: usize = 0,
};

/// std.posix.recv
pub const Recv = struct {
    pub const Error = std.posix.RecvFromError || SharedError;
    socket: std.posix.socket_t,
    buffer: []u8,
    out_read: *usize,
    out_id: ?*Id = null,
    out_error: ?*Error = null,
    userdata: usize = 0,
};

/// std.posix.send
pub const Send = struct {
    pub const Error = std.posix.SendError || SharedError;
    socket: std.posix.socket_t,
    buffer: []const u8,
    out_written: ?*usize = null,
    out_id: ?*Id = null,
    out_error: ?*Error = null,
    userdata: usize = 0,
};

/// recvmsg(2)
pub const RecvMsg = struct {
    pub const Error = error{
        ConnectionRefused,
        ConnectionTimedOut,
        ConnectionResetByPeer,
        SystemResources,
        SocketNotConnected,
    } || SharedError;
    socket: std.posix.socket_t,
    out_msg: *posix.msghdr,
    out_read: *usize,
    out_id: ?*Id = null,
    out_error: ?*Error = null,
    userdata: usize = 0,
};

/// std.posix.sendmsg
pub const SendMsg = struct {
    pub const Error = std.posix.SendMsgError || SharedError;
    socket: std.posix.socket_t,
    msg: *const posix.msghdr_const,
    out_written: ?*usize = null,
    out_id: ?*Id = null,
    out_error: ?*Error = null,
    userdata: usize = 0,
};

/// std.posix.shutdown
pub const Shutdown = struct {
    pub const Error = std.posix.ShutdownError || SharedError;
    socket: std.posix.socket_t,
    how: std.posix.ShutdownHow,
    out_id: ?*Id = null,
    out_error: ?*Error = null,
    userdata: usize = 0,
};

/// std.fs.Dir.openFile
pub const OpenAt = struct {
    pub const Error = std.fs.File.OpenError || SharedError;
    dir: std.fs.Dir,
    path: [*:0]const u8,
    flags: std.fs.File.OpenFlags = .{},
    out_file: *std.fs.File,
    out_id: ?*Id = null,
    out_error: ?*Error = null,
    userdata: usize = 0,
};

/// std.fs.File.close
pub const CloseFile = struct {
    pub const Error = SharedError;
    file: std.fs.File,
    out_id: ?*Id = null,
    out_error: ?*Error = null,
    userdata: usize = 0,
};

/// std.fs.Dir.Close
pub const CloseDir = struct {
    pub const Error = SharedError;
    dir: std.fs.Dir,
    out_id: ?*Id = null,
    out_error: ?*Error = null,
    userdata: usize = 0,
};

/// std.time.Timer.start
pub const Timeout = struct {
    pub const Error = SharedError;
    ns: u128,
    out_id: ?*Id = null,
    out_error: ?*Error = null,
    userdata: usize = 0,
};

/// Timeout linked to a operation
/// This must be linked last and the operation before must have set `link` to either `soft` or `hard`
/// If the operation finishes before the timeout the timeout will be canceled
pub const LinkTimeout = struct {
    pub const Error = error{Expired} || SharedError;
    ns: u128,
    out_id: ?*Id = null,
    out_error: ?*Error = null,
    userdata: usize = 0,
};

/// Cancel a operation
pub const Cancel = struct {
    pub const Error = error{ InProgress, NotFound } || SharedError;
    id: Id,
    out_id: ?*Id = null,
    out_error: ?*Error = null,
    userdata: usize = 0,
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
    userdata: usize = 0,
};

/// std.fs.Dir.deleteFile
pub const UnlinkAt = struct {
    pub const Error = std.posix.UnlinkatError || SharedError;
    dir: std.fs.Dir,
    path: [*:0]const u8,
    out_id: ?*Id = null,
    out_error: ?*Error = null,
    userdata: usize = 0,
};

/// std.fs.Dir.makeDir
pub const MkDirAt = struct {
    pub const Error = std.fs.Dir.MakeError || SharedError;
    dir: std.fs.Dir,
    path: [*:0]const u8,
    mode: std.posix.mode_t = std.fs.Dir.default_mode,
    out_id: ?*Id = null,
    out_error: ?*Error = null,
    userdata: usize = 0,
};

/// std.fs.Dir.symlink
pub const SymlinkAt = struct {
    pub const Error = std.posix.SymLinkError || error{UnrecognizedVolume} || SharedError;
    dir: std.fs.Dir,
    target: [*:0]const u8,
    link_path: [*:0]const u8,
    out_id: ?*Id = null,
    out_error: ?*Error = null,
    userdata: usize = 0,
};

/// std.process.Child.wait
pub const ChildExit = struct {
    pub const Error = error{NotFound} || SharedError;
    child: std.process.Child.Id,
    out_term: ?*std.process.Child.Term = null,
    out_id: ?*Id = null,
    out_error: ?*Error = null,
    userdata: usize = 0,
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
    userdata: usize = 0,
};

/// std.posix.close
pub const CloseSocket = struct {
    pub const Error = std.posix.SocketError || SharedError;
    socket: std.posix.socket_t,
    out_id: ?*Id = null,
    out_error: ?*Error = null,
    userdata: usize = 0,
};

pub const NotifyEventSource = struct {
    pub const Error = SharedError;
    source: *aio.EventSource,
    out_id: ?*Id = null,
    out_error: ?*Error = null,
    userdata: usize = 0,
};

pub const WaitEventSource = struct {
    pub const Error = SharedError;
    source: *aio.EventSource,
    out_id: ?*Id = null,
    out_error: ?*Error = null,
    userdata: usize = 0,
};

pub const CloseEventSource = struct {
    pub const Error = SharedError;
    source: *aio.EventSource,
    out_id: ?*Id = null,
    out_error: ?*Error = null,
    userdata: usize = 0,
};

pub const Operation = enum {
    nop,
    fsync,
    poll,
    read_tty,
    read,
    write,
    accept,
    connect,
    recv,
    send,
    recv_msg,
    send_msg,
    shutdown,
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
        .nop = Nop,
        .fsync = Fsync,
        .poll = Poll,
        .read_tty = ReadTty,
        .read = Read,
        .write = Write,
        .accept = Accept,
        .connect = Connect,
        .recv = Recv,
        .send = Send,
        .recv_msg = RecvMsg,
        .send_msg = SendMsg,
        .shutdown = Shutdown,
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

    pub const Error = blk: {
        var set = error{};
        for (Operation.map.values) |v| set = set || v.Error;
        break :blk set;
    };

    pub const anyresult = opaque {
        pub fn cast(self: *@This(), T: type) T {
            return @alignCast(@ptrCast(self));
        }

        pub fn init(comptime op_type: Operation, op: map.getAssertContains(op_type)) *@This() {
            @setRuntimeSafety(false);
            return switch (op_type) {
                .nop,
                .poll,
                .connect,
                .shutdown,
                .fsync,
                .cancel,
                .timeout,
                .link_timeout,
                .mkdir_at,
                .close_dir,
                .rename_at,
                .unlink_at,
                .close_file,
                .symlink_at,
                .close_socket,
                .wait_event_source,
                .close_event_source,
                .notify_event_source,
                => undefined,
                .read, .read_tty, .recv, .recv_msg => @ptrCast(op.out_read),
                .write, .send, .send_msg => @ptrCast(op.out_written),
                .socket, .accept => @ptrCast(op.out_socket),
                .open_at => @ptrCast(op.out_file),
                .child_exit => @ptrCast(op.out_term),
            };
        }

        pub fn restore(self: *@This(), comptime op_type: Operation, op: *map.getAssertContains(op_type)) void {
            @setRuntimeSafety(false);
            return switch (op_type) {
                .nop,
                .poll,
                .connect,
                .shutdown,
                .fsync,
                .cancel,
                .timeout,
                .link_timeout,
                .mkdir_at,
                .close_dir,
                .rename_at,
                .unlink_at,
                .close_file,
                .symlink_at,
                .close_socket,
                .wait_event_source,
                .close_event_source,
                .notify_event_source,
                => undefined,
                .read, .read_tty, .recv, .recv_msg => op.out_read = self.cast(*usize),
                .write, .send, .send_msg => op.out_written = self.cast(?*usize),
                .socket, .accept => op.out_socket = self.cast(*std.posix.socket_t),
                .open_at => op.out_file = self.cast(*std.fs.File),
                .child_exit => op.out_term = self.cast(?*std.process.Child.Term),
            };
        }
    };
};
