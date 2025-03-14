//! Basic io-uring -like asynchronous IO API
//! It is possible to both dynamically and statically queue IO work to be executed in a asynchronous fashion
//! On linux this is a very shim wrapper around `io_uring`, on other systems there might be more overhead

const builtin = @import("builtin");
const std = @import("std");
const build_options = @import("build_options");

const root = @import("root");
pub const options: Options = if (@hasDecl(root, "aio_options")) root.aio_options else .{};

pub const Options = struct {
    /// Enable debug logs and tracing.
    debug: bool = build_options.debug,
    /// Custom backend.
    backend_override: ?type = null,
    /// Max thread count for a thread pool if a backend requires one.
    /// By default use the cpu core count.
    /// Use 0 to disable threading in multi-threaded builds.
    /// In single-threaded builds this option is ignored.
    max_threads: ?u32 = null,
    /// Operations that the main backend must support.
    /// If the operations are not supported by a main backend then a posix backend will be used instead.
    /// This is unused if posix backend is disabled, in that case you should check for a support manually.
    /// On windows this is never used, check for a support manually.
    required_ops: []const Operation = std.enums.values(Operation),
    /// Choose a posix fallback mode.
    /// Posix backend is never used on windows
    posix: enum { auto, force, disable } = @enumFromInt(@intFromEnum(build_options.posix)),
    /// Wasi support
    wasi: enum { wasi, wasix } = @enumFromInt(@intFromEnum(build_options.wasi)),
};

/// This is mostly std compatible, but contains also stuff that std does not have such a msghdr for all the supported platforms
pub const posix = @import("aio/posix/posix.zig");

/// Use this instead of std.posix.socket to get async sockets on windows ... :)
/// Unfortunately there is no `ReOpenFile` equivalent for sockets.
pub inline fn socket(domain: u32, socket_type: u32, protocol: u32) std.posix.SocketError!std.posix.socket_t {
    return posix.socket(domain, socket_type, protocol);
}

/// IO backend
const IO = if (options.backend_override) |backend| backend else switch (builtin.target.os.tag) {
    .linux => @import("aio/linux.zig").IO,
    .windows => @import("aio/Windows.zig"),
    else => @import("aio/Posix.zig"),
};

/// Checks if the current backend supports the operations
pub fn isSupported(operations: []const Operation) bool {
    return IO.isSupported(operations);
}

pub const EventSource = struct {
    native: IO.EventSource,

    pub const Error = error{
        ProcessFdQuotaExceeded,
        SystemFdQuotaExceeded,
        SystemResources,
        Unexpected,
    };

    pub fn init() @This().Error!@This() {
        return .{ .native = try IO.EventSource.init() };
    }

    pub fn deinit(self: *@This()) void {
        self.native.deinit();
        self.* = undefined;
    }

    pub fn notify(self: *@This()) void {
        self.native.notify();
    }

    pub fn wait(self: *@This()) void {
        self.native.wait();
    }

    pub fn waitNonBlocking(self: *@This()) error{WouldBlock}!void {
        return self.native.waitNonBlocking();
    }
};

/// Initialize a single operation for a IO function
pub fn op(comptime op_type: Operation, values: Operation.map.getAssertContains(op_type), comptime link: Link) struct {
    op: @TypeOf(values),
    comptime tag: Operation = op_type,
    comptime link: Link = link,
    pub const MAGIC_AIO_OP = 0xdeadbeef;
} {
    return .{ .op = values };
}

pub inline fn sanityCheck(pairs: anytype) void {
    @setEvalBranchQuota(pairs.len * 1024);
    const ti = @typeInfo(@TypeOf(pairs));
    if (comptime (ti == .@"struct" and ti.@"struct".is_tuple) or ti == .array) {
        if (comptime pairs.len == 0) @compileError("no work to be done");
        inline for (pairs, 0..) |pair, idx| {
            if (!@hasDecl(@TypeOf(pair), "MAGIC_AIO_OP")) {
                @compileError("Pass ops using the aio.op function");
            }
            if (comptime pair.tag == .link_timeout) {
                if (comptime idx == 0) {
                    @compileError("aio.LinkTimeout is not linked to any operation");
                } else {
                    inline for (pairs, 0..) |pair2, idx2| {
                        if (idx2 == idx - 1 and pair2.link == .unlinked) {
                            @compileError("aio.LinkTimeout is not linked to any operation");
                        }
                    }
                }
            }
            if (comptime idx == pairs.len - 1 and pair.link != .unlinked) {
                @compileError("Last operation is not .unlinked");
            }
        }
    } else {
        @compileError("Expected a tuple or array of operations");
    }
}

pub const Error = error{
    OutOfMemory,
    CompletionQueueOvercommitted,
    SubmissionQueueFull,
    NoDevice,
    PermissionDenied,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    UserResourceLimitReached,
    ThreadQuotaExceeded,
    LockedMemoryLimitExceeded,
    SystemOutdated,
    Unsupported,
    Unexpected,
};

pub const CompletionResult = struct {
    num_completed: u16 = 0,
    num_errors: u16 = 0,
};

pub const CompletionMode = enum {
    /// Call to `complete` will block until at least one operation completes
    blocking,
    /// Call to `complete` will only complete the currently ready operations if any
    nonblocking,
};

/// Queue operations dynamically and complete them on demand
pub const Dynamic = struct {
    io: IO,

    pub fn init(allocator: std.mem.Allocator, n: u16) Error!@This() {
        return .{ .io = try IO.init(allocator, n) };
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.io.deinit(allocator);
        self.* = undefined;
    }

    /// Queue operations for future completion
    /// The call is atomic, if any of the operations fail to queue, then the given operations are reverted
    pub inline fn queue(self: *@This(), pairs: anytype, handler: anytype) Error!void {
        const ti = @typeInfo(@TypeOf(pairs));
        if (comptime (ti == .@"struct" and ti.@"struct".is_tuple) or ti == .array) {
            sanityCheck(pairs);
            return self.io.queue(pairs, handler);
        } else {
            sanityCheck(.{pairs});
            return self.io.queue(.{pairs}, handler);
        }
    }

    /// Complete operations
    /// Returns the number of completed operations, `0` if no operations were completed
    pub fn complete(self: *@This(), mode: CompletionMode, handler: anytype) Error!CompletionResult {
        return self.io.complete(mode, handler);
    }

    /// Block until all opreations are complete
    /// Returns the number of errors occured, 0 if there were no errors
    pub fn completeAll(self: *@This(), handler: anytype) Error!u16 {
        var num_errors: u16 = 0;
        while (true) {
            const res = try self.io.complete(.blocking, handler);
            num_errors += res.num_errors;
            if (res.num_completed == 0) break;
        }
        return num_errors;
    }
};

/// Completes a list of operations immediately, blocks until complete
/// For error handling you must check the `out_error` field in the operation
/// Returns the number of errors occured, 0 if there were no errors
pub inline fn complete(pairs: anytype) Error!u16 {
    sanityCheck(pairs);
    return IO.immediate(pairs);
}

/// Completes a list of operations immediately, blocks until complete
/// Returns `error.SomeOperationFailed` if any operation failed
pub inline fn multi(pairs: anytype) (Error || error{SomeOperationFailed})!void {
    if (try complete(pairs) > 0) return error.SomeOperationFailed;
}

/// Completes a single operation immediately, blocks until complete
pub inline fn single(comptime op_type: Operation, values: Operation.map.getAssertContains(op_type)) (Error || @TypeOf(values).Error)!void {
    var cpy: @TypeOf(values) = values;
    var err: @TypeOf(values).Error = error.Success;
    cpy.out_error = &err;
    if (try complete(.{op(op_type, cpy, .unlinked)}) > 0) return err;
}

const ops = @import("aio/ops.zig");
pub const Operation = ops.Operation;
pub const Id = ops.Id;
pub const Link = ops.Link;
pub const Nop = ops.Nop;
pub const Fsync = ops.Fsync;
pub const Poll = ops.Poll;
pub const ReadTty = ops.ReadTty;
pub const Read = ops.Read;
pub const Write = ops.Write;
pub const Accept = ops.Accept;
pub const Connect = ops.Connect;
pub const Recv = ops.Recv;
pub const RecvMsg = ops.RecvMsg;
pub const Send = ops.Send;
pub const SendMsg = ops.SendMsg;
pub const OpenAt = ops.OpenAt;
pub const Shutdown = ops.Shutdown;
pub const CloseFile = ops.CloseFile;
pub const CloseDir = ops.CloseDir;
pub const Timeout = ops.Timeout;
pub const LinkTimeout = ops.LinkTimeout;
pub const Cancel = ops.Cancel;
pub const RenameAt = ops.RenameAt;
pub const UnlinkAt = ops.UnlinkAt;
pub const MkDirAt = ops.MkDirAt;
pub const SymlinkAt = ops.SymlinkAt;
pub const ChildExit = ops.ChildExit;
pub const Socket = ops.Socket;
pub const CloseSocket = ops.CloseSocket;
pub const NotifyEventSource = ops.NotifyEventSource;
pub const WaitEventSource = ops.WaitEventSource;
pub const CloseEventSource = ops.CloseEventSource;
pub const Splice = ops.Splice;

test "shared outputs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var f = try tmp.dir.createFile("test", .{});
    defer f.close();
    var id1: Id = .{ .slot = 69, .generation = 69 };
    var id2: Id = undefined;
    var id3: Id = undefined;
    var dynamic = try Dynamic.init(std.testing.allocator, 16);
    defer dynamic.deinit(std.testing.allocator);
    try dynamic.queue(.{
        op(.fsync, .{ .file = f, .out_id = &id1 }, .unlinked),
        op(.fsync, .{ .file = f, .out_id = &id2 }, .unlinked),
        op(.fsync, .{ .file = f, .out_id = &id3 }, .unlinked),
    }, {});
    try std.testing.expect(id1 != Id{ .slot = 69, .generation = 69 });
    try std.testing.expect(id1 != id2);
    try std.testing.expect(id1 != id3);
    try std.testing.expect(id2 != id3);
    std.debug.print("{}\n", .{id1});
    std.debug.print("{}\n", .{id2});
    std.debug.print("{}\n", .{id3});
    _ = try dynamic.completeAll({});
    std.debug.print("{}\n", .{id1});
    std.debug.print("{}\n", .{id2});
    std.debug.print("{}\n", .{id3});
}

test "Nop" {
    var dynamic = try Dynamic.init(std.testing.allocator, 16);
    defer dynamic.deinit(std.testing.allocator);
    const Handler = struct {
        pub fn aio_queue(_: @This(), _: Id, userdata: usize) void {
            std.debug.assert(42 == userdata);
        }

        pub fn aio_complete(_: @This(), _: Id, userdata: usize, failed: bool) void {
            std.debug.assert(42 == userdata);
            std.debug.assert(!failed);
        }
    };
    const handler: Handler = .{};
    try dynamic.queue(op(.nop, .{ .userdata = 42 }, .unlinked), handler);
    try std.testing.expectEqual(0, dynamic.completeAll(handler));
}

test "Fsync" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var f = try tmp.dir.createFile("test", .{});
    defer f.close();
    try single(.fsync, .{ .file = f });
}

test "Poll" {
    if (builtin.os.tag == .windows) {
        return error.SkipZigTest;
    }
    {
        var source = try EventSource.init();
        try multi(.{
            op(.notify_event_source, .{ .source = &source }, .soft),
            op(.poll, .{ .fd = source.native.fd, .events = .{ .in = true } }, .soft),
            op(.close_event_source, .{ .source = &source }, .unlinked),
        });
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var f = try tmp.dir.createFile("test", .{ .read = true });
        defer f.close();
        try single(.poll, .{ .fd = f.handle, .events = .{ .out = true } });
    }
    {
        var f = try tmp.dir.createFile("test", .{ .read = true });
        defer f.close();
        try single(.poll, .{ .fd = f.handle, .events = .{ .in = true, .out = true } });
    }
}

test "Read" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [64]u8 = undefined;
    var len: usize = undefined;
    {
        var f = try tmp.dir.createFile("test", .{ .read = true });
        defer f.close();
        try f.writeAll("foobar");
        try single(.read, .{ .file = f, .buffer = &buf, .out_read = &len });
        try std.testing.expectEqual("foobar".len, len);
        try std.testing.expectEqualSlices(u8, "foobar", buf[0..len]);
    }
    {
        var f = try tmp.dir.createFile("test", .{});
        defer f.close();
        try std.testing.expectError(
            error.NotOpenForReading,
            single(.read, .{ .file = f, .buffer = &buf, .out_read = &len }),
        );
    }
}

test "Write" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [64]u8 = undefined;
    var len: usize = undefined;
    {
        var f = try tmp.dir.createFile("test", .{ .read = true });
        defer f.close();
        try single(.write, .{ .file = f, .buffer = "foobar", .out_written = &len });
        try std.testing.expectEqual("foobar".len, len);
        try f.seekTo(0); // required for windows
        const read = try f.readAll(&buf);
        try std.testing.expectEqualSlices(u8, "foobar", buf[0..read]);
    }
    {
        var f = try tmp.dir.openFile("test", .{});
        defer f.close();
        try std.testing.expectError(
            error.NotOpenForWriting,
            single(.write, .{ .file = f, .buffer = "foobar", .out_written = &len }),
        );
    }
}

test "OpenAt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var f: std.fs.File = undefined;
    try std.testing.expectError(
        error.FileNotFound,
        single(.open_at, .{ .dir = tmp.dir, .path = "test", .out_file = &f }),
    );
    var f2 = try tmp.dir.createFile("test", .{});
    f2.close();
    try single(.open_at, .{ .dir = tmp.dir, .path = "test", .out_file = &f });
    f.close();
}

test "CloseFile" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile("test", .{});
    try single(.close_file, .{ .file = f });
}

test "CloseDir" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = try tmp.dir.makeOpenPath("test", .{});
    try single(.close_dir, .{ .dir = d });
}

test "Timeout" {
    var timer = try std.time.Timer.start();
    try single(.timeout, .{ .ns = 2 * std.time.ns_per_s });
    try std.testing.expect(timer.lap() > std.time.ns_per_s);
}

test "LinkTimeout" {
    {
        var err: Timeout.Error = undefined;
        var err2: LinkTimeout.Error = undefined;
        const num_errors = try complete(.{
            op(.timeout, .{ .ns = 2 * std.time.ns_per_s, .out_error = &err }, .soft),
            op(.link_timeout, .{ .ns = 1 * std.time.ns_per_s, .out_error = &err2 }, .unlinked),
        });
        try std.testing.expectEqual(2, num_errors);
        try std.testing.expectEqual(error.Canceled, err);
        try std.testing.expectEqual(error.Expired, err2);
    }
    {
        const num_errors = try complete(.{
            op(.timeout, .{ .ns = 2 * std.time.ns_per_s }, .soft),
            op(.link_timeout, .{ .ns = 1 * std.time.ns_per_s }, .soft),
            op(.timeout, .{ .ns = 1 * std.time.ns_per_s }, .unlinked),
        });
        try std.testing.expectEqual(3, num_errors);
    }
    {
        const num_errors = try complete(.{
            op(.timeout, .{ .ns = 1 * std.time.ns_per_s }, .soft),
            op(.link_timeout, .{ .ns = 2 * std.time.ns_per_s }, .unlinked),
        });
        try std.testing.expectEqual(0, num_errors);
    }
    {
        const num_errors = try complete(.{
            op(.timeout, .{ .ns = 1 * std.time.ns_per_s }, .soft),
            op(.link_timeout, .{ .ns = 2 * std.time.ns_per_s }, .soft),
            op(.timeout, .{ .ns = 1 * std.time.ns_per_s }, .unlinked),
        });
        try std.testing.expectEqual(0, num_errors);
    }
    {
        const num_errors = try complete(.{
            op(.timeout, .{ .ns = 2 * std.time.ns_per_s }, .soft),
            op(.link_timeout, .{ .ns = 1 * std.time.ns_per_s }, .hard),
            op(.timeout, .{ .ns = 1 * std.time.ns_per_s }, .unlinked),
        });
        try std.testing.expectEqual(3, num_errors);
    }
    {
        const num_errors = try complete(.{
            op(.timeout, .{ .ns = 1 * std.time.ns_per_s }, .hard),
            op(.link_timeout, .{ .ns = 2 * std.time.ns_per_s }, .soft),
            op(.timeout, .{ .ns = 1 * std.time.ns_per_s }, .unlinked),
        });
        try std.testing.expectEqual(0, num_errors);
    }
}

test "Cancel" {
    var dynamic = try Dynamic.init(std.testing.allocator, 16);
    defer dynamic.deinit(std.testing.allocator);
    var timer = try std.time.Timer.start();
    var id: Id = undefined;
    var err: Timeout.Error = undefined;
    try dynamic.queue(op(.timeout, .{
        .ns = 2 * std.time.ns_per_s,
        .out_id = &id,
        .out_error = &err,
    }, .unlinked), {});
    const tmp = try dynamic.complete(.nonblocking, {});
    try std.testing.expectEqual(0, tmp.num_errors);
    try std.testing.expectEqual(0, tmp.num_completed);

    {
        try dynamic.queue(op(.cancel, .{ .id = id }, .unlinked), {});
        const num_errors = try dynamic.completeAll({});
        try std.testing.expectEqual(1, num_errors);
        try std.testing.expectEqual(error.Canceled, err);
        try std.testing.expect(timer.lap() < std.time.ns_per_s);
    }

    {
        var cancel_err: Cancel.Error = undefined;
        try dynamic.queue(op(.cancel, .{ .id = id, .out_error = &cancel_err }, .unlinked), {});
        const num_errors = try dynamic.completeAll({});
        try std.testing.expectEqual(1, num_errors);
        try std.testing.expectEqual(error.NotFound, cancel_err);
    }
}

test "RenameAt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectError(
        error.FileNotFound,
        single(.rename_at, .{ .old_dir = tmp.dir, .old_path = "test", .new_dir = tmp.dir, .new_path = "new_test" }),
    );
    var f1 = try tmp.dir.createFile("test", .{});
    f1.close();
    try single(.rename_at, .{ .old_dir = tmp.dir, .old_path = "test", .new_dir = tmp.dir, .new_path = "new_test" });
    if (builtin.target.os.tag == .windows) {
        // TODO: wtf? (using openFile instead causes deadlock)
    } else {
        try tmp.dir.access("new_test", .{});
    }
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("test", .{}));
    var f2 = try tmp.dir.createFile("test", .{});
    f2.close();
    try std.testing.expectError(error.PathAlreadyExists, single(.rename_at, .{ .old_dir = tmp.dir, .old_path = "test", .new_dir = tmp.dir, .new_path = "new_test" }));
}

test "UnlinkAt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectError(
        error.FileNotFound,
        single(.unlink_at, .{ .dir = tmp.dir, .path = "test" }),
    );
    var f = try tmp.dir.createFile("test", .{});
    f.close();
    try single(.unlink_at, .{ .dir = tmp.dir, .path = "test" });
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("test", .{}));
}

test "MkDirAt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try single(.mkdir_at, .{ .dir = tmp.dir, .path = "test" });
    if (builtin.target.os.tag == .windows) {
        // TODO: need to update the directory handle on windows? weird shit
    } else {
        try tmp.dir.access("test", .{});
    }
    try std.testing.expectError(error.PathAlreadyExists, single(.mkdir_at, .{ .dir = tmp.dir, .path = "test" }));
}

test "SymlinkAt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    if (builtin.target.os.tag == .windows) {
        const res = single(.symlink_at, .{ .dir = tmp.dir, .target = "target", .link_path = "test" });
        // likely NTSTATUS=0xc00000bb (UNSUPPORTED)
        if (res == error.Unexpected) return error.SkipZigTest;
    } else {
        try single(.symlink_at, .{ .dir = tmp.dir, .target = "target", .link_path = "test" });
    }
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.access("test", .{}),
    );
    var f = try tmp.dir.createFile("target", .{});
    f.close();
    try tmp.dir.access("test", .{});
    try std.testing.expectError(error.PathAlreadyExists, single(.symlink_at, .{ .dir = tmp.dir, .target = "target", .link_path = "test" }));
}

test "ChildExit" {
    const pid = switch (builtin.target.os.tag) {
        .linux, .freebsd, .openbsd, .dragonfly, .netbsd, .macos, .ios, .watchos, .visionos, .tvos => blk: {
            const pid = try std.posix.fork();
            if (pid == 0) {
                std.time.sleep(1 * std.time.ns_per_s);
                std.posix.exit(69);
            }
            break :blk pid;
        },
        .windows => blk: {
            var child = std.process.Child.init(&.{ "cmd.exe", "/c", "exit 69" }, std.heap.page_allocator);
            try child.spawn();
            break :blk child.id;
        },
        else => return error.SkipZigTest,
    };
    var term: std.process.Child.Term = undefined;
    try single(.child_exit, .{ .child = pid, .out_term = &term });
    if (term == .Signal) {
        try std.testing.expectEqual(69, term.Signal);
    } else if (term == .Exited) {
        try std.testing.expectEqual(69, term.Exited);
    } else {
        unreachable;
    }
}

test "Socket/TCP" {
    if (builtin.target.os.tag == .wasi) {
        return error.SkipZigTest;
    }

    var server: std.posix.socket_t = undefined;
    try single(.socket, .{
        .domain = std.posix.AF.INET,
        .flags = std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
        .protocol = std.posix.IPPROTO.TCP,
        .out_socket = &server,
    });

    try std.posix.setsockopt(server, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    if (@hasDecl(std.posix.SO, "REUSEPORT")) {
        try std.posix.setsockopt(server, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
    }

    var client: std.posix.socket_t = undefined;
    try single(.socket, .{
        .domain = std.posix.AF.INET,
        .flags = std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
        .protocol = std.posix.IPPROTO.TCP,
        .out_socket = &client,
    });

    const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 3131);
    try std.posix.bind(server, &address.any, address.getOsSockLen());
    try std.posix.listen(server, 1);

    var client_comm: std.posix.socket_t = undefined;
    var client_addr: std.net.Address = undefined;
    var client_addr_len: posix.socklen_t = address.getOsSockLen();
    try multi(.{
        op(.accept, .{
            .socket = server,
            .out_socket = &client_comm,
            .out_addr = &client_addr.any,
            .inout_addrlen = &client_addr_len,
        }, .unlinked),
        op(.connect, .{
            .socket = client,
            .addr = &address.any,
            .addrlen = address.getOsSockLen(),
        }, .unlinked),
    });

    try std.testing.expectEqual(client_addr.getOsSockLen(), client_addr_len);
    try std.testing.expectEqual(address.in.sa.addr, client_addr.in.sa.addr);

    var buf1: [32]u8 = undefined;
    var wlen1: usize = 0;
    var rlen1: usize = 0;
    var buf2: [32]u8 = undefined;
    var wlen2: usize = 0;
    var rlen2: usize = 0;
    try multi(.{
        op(.send, .{ .socket = client_comm, .buffer = "PING", .out_written = &wlen1 }, .soft),
        op(.recv, .{ .socket = client, .buffer = &buf1, .out_read = &rlen1 }, .soft),
        op(.send, .{ .socket = client, .buffer = "PONG", .out_written = &wlen2 }, .soft),
        op(.recv, .{ .socket = client_comm, .buffer = &buf2, .out_read = &rlen2 }, .unlinked),
    });

    try std.testing.expectEqual(wlen1, 4);
    try std.testing.expectEqual(rlen1, 4);
    try std.testing.expectEqual(wlen1, wlen2);
    try std.testing.expectEqual(rlen1, rlen2);
    try std.testing.expectEqualSlices(u8, buf1[0..rlen1], "PING");
    try std.testing.expectEqualSlices(u8, buf2[0..rlen2], "PONG");

    try single(.shutdown, .{ .socket = client, .how = .both });
    try single(.close_socket, .{ .socket = client });
    try single(.close_socket, .{ .socket = server });
}

test "Socket/UDP" {
    if (builtin.target.os.tag == .wasi) {
        return error.SkipZigTest;
    }

    var server: std.posix.socket_t = undefined;
    try single(.socket, .{
        .domain = std.posix.AF.INET,
        .flags = std.posix.SOCK.DGRAM | std.posix.SOCK.CLOEXEC,
        .protocol = std.posix.IPPROTO.UDP,
        .out_socket = &server,
    });

    try std.posix.setsockopt(server, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    if (@hasDecl(std.posix.SO, "REUSEPORT")) {
        try std.posix.setsockopt(server, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
    }

    var client: std.posix.socket_t = undefined;
    try single(.socket, .{
        .domain = std.posix.AF.INET,
        .flags = std.posix.SOCK.DGRAM | std.posix.SOCK.CLOEXEC,
        .protocol = std.posix.IPPROTO.UDP,
        .out_socket = &client,
    });

    try std.posix.setsockopt(client, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    if (@hasDecl(std.posix.SO, "REUSEPORT")) {
        try std.posix.setsockopt(client, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
    }

    const saddress = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 3131);
    const caddress = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 3232);
    try std.posix.bind(server, &saddress.any, saddress.getOsSockLen());
    try std.posix.bind(client, &caddress.any, caddress.getOsSockLen());

    var ping_msg: posix.msghdr_const = .{
        .name = @ptrCast(&caddress.any),
        .namelen = caddress.getOsSockLen(),
        .iov = &.{
            .{
                .base = "PING",
                .len = "PING".len,
            },
        },
        .iovlen = 1,
        .control = null,
        .controllen = 0,
        .flags = 0,
    };

    var pong_msg: posix.msghdr_const = .{
        .name = @ptrCast(&saddress.any),
        .namelen = saddress.getOsSockLen(),
        .iov = &.{
            .{
                .base = "PONG",
                .len = "PONG".len,
            },
        },
        .iovlen = 1,
        .control = null,
        .controllen = 0,
        .flags = 0,
    };

    var buf1: [32]u8 = undefined;
    var recv_addr1: std.net.Address = undefined;
    var recv_iovec1: [1]posix.iovec = .{.{
        .base = &buf1,
        .len = buf1.len,
    }};
    var recv_msg1: posix.msghdr = .{
        .name = &recv_addr1.any,
        .namelen = caddress.getOsSockLen(),
        .iov = &recv_iovec1,
        .iovlen = 1,
        .control = null,
        .controllen = 0,
        .flags = 0,
    };

    var buf2: [32]u8 = undefined;
    var recv_addr2: std.net.Address = undefined;
    var recv_iovec2: [1]posix.iovec = .{.{
        .base = &buf2,
        .len = buf2.len,
    }};
    var recv_msg2: posix.msghdr = .{
        .name = &recv_addr2.any,
        .namelen = saddress.getOsSockLen(),
        .iov = &recv_iovec2,
        .iovlen = 1,
        .control = null,
        .controllen = 0,
        .flags = 0,
    };

    var wlen1: usize = 0;
    var rlen1: usize = 0;
    var wlen2: usize = 0;
    var rlen2: usize = 0;
    try multi(.{
        op(.send_msg, .{ .socket = server, .msg = &ping_msg, .out_written = &wlen1 }, .soft),
        op(.recv_msg, .{ .socket = client, .out_msg = &recv_msg1, .out_read = &rlen1 }, .soft),
        op(.send_msg, .{ .socket = client, .msg = &pong_msg, .out_written = &wlen2 }, .soft),
        op(.recv_msg, .{ .socket = server, .out_msg = &recv_msg2, .out_read = &rlen2 }, .unlinked),
    });

    try std.testing.expect(recv_addr1.eql(saddress));
    try std.testing.expect(recv_addr2.eql(caddress));

    try std.testing.expectEqual(wlen1, 4);
    try std.testing.expectEqual(rlen1, 4);
    try std.testing.expectEqual(wlen1, wlen2);
    try std.testing.expectEqual(rlen1, rlen2);
    try std.testing.expectEqualSlices(u8, buf1[0..rlen1], "PING");
    try std.testing.expectEqualSlices(u8, buf2[0..rlen2], "PONG");

    try single(.close_socket, .{ .socket = client });
    try single(.close_socket, .{ .socket = server });
}

test "EventSource" {
    var source = try EventSource.init();
    try multi(.{
        op(.notify_event_source, .{ .source = &source }, .unlinked),
        op(.wait_event_source, .{ .source = &source }, .hard),
        op(.close_event_source, .{ .source = &source }, .unlinked),
    });
}

test "Splice" {
    if (builtin.target.os.tag != .linux or options.posix != .disable) {
        return error.SkipZigTest;
    }

    const out = try std.posix.memfd_create("out", 0);
    defer std.posix.close(out);

    const pfd = try std.posix.pipe();
    defer for (pfd) |fd| std.posix.close(fd);

    _ = try std.posix.write(pfd[1], "hello world");

    var wlen: usize = 0;
    try single(.splice, .{
        .in = .{ .pipe = pfd[0] },
        .out = .{ .other = .{ .fd = out } },
        .len = "hello world".len,
        .out_written = &wlen,
    });

    try std.testing.expectEqual("hello world".len, wlen);

    var buf: [32]u8 = undefined;
    const rlen = try std.posix.pread(out, &buf, 0);
    try std.testing.expectEqual("hello world".len, rlen);
    try std.testing.expectEqualSlices(u8, "hello world", buf[0..rlen]);
}

test {
    std.testing.refAllDecls(@This());
}
