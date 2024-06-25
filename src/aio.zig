//! Basic io-uring -like asynchronous IO API
//! It is possible to both dynamically and statically queue IO work to be executed in a asynchronous fashion
//! On linux this is a very shim wrapper around `io_uring`, on other systems there might be more overhead

const std = @import("std");
const build_options = @import("build_options");

const root = @import("root");
pub const options: Options = if (@hasDecl(root, "aio_options")) root.aio_options else .{};

pub const Options = struct {
    /// Enable debug logs and tracing.
    debug: bool = false,
    /// Num threads for a thread pool, if a backend requires one.
    /// By default use the cpu code count.
    num_threads: ?u32 = null,
    /// Completition event buffer size for the io_uring backend.
    io_uring_cqe_sz: u16 = 64,
    /// Operations that the main backend must support.
    /// If the operations are not supported by a main backend then a fallback backend will be used instead.
    /// This is unused if fallback is disabled, in that case you should check for a support manually.
    required_ops: []const type = @import("aio/ops.zig").Operation.Types,
    /// Choose a fallback mode.
    fallback: enum {
        auto,
        force,
        disable,
    } = if (build_options.fallback) .force else .auto,
};

pub const Error = error{
    OutOfMemory,
    CompletionQueueOvercommitted,
    SubmissionQueueFull,
    NoDevice,
    PermissionDenied,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    SystemOutdated,
    Unexpected,
};

pub const CompletionResult = struct {
    num_completed: u16 = 0,
    num_errors: u16 = 0,
};

/// Queue operations dynamically and complete them on demand
pub const Dynamic = struct {
    pub const Uop = ops.Operation.Union;
    pub const QueueCallback = *const fn (uop: Uop, id: Id) void;
    pub const CompletionCallback = *const fn (uop: Uop, id: Id, failed: bool) void;

    io: IO,

    /// Used by the coro implementation
    queue_callback: ?QueueCallback = null,
    completion_callback: ?CompletionCallback = null,

    pub inline fn init(allocator: std.mem.Allocator, n: u16) Error!@This() {
        return .{ .io = try IO.init(allocator, n) };
    }

    pub inline fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.io.deinit(allocator);
        self.* = undefined;
    }

    /// Queue operations for future completion
    /// The call is atomic, if any of the operations fail to queue, then the given operations are reverted
    pub inline fn queue(self: *@This(), operations: anytype) Error!void {
        const ti = @typeInfo(@TypeOf(operations));
        if (comptime ti == .Struct and ti.Struct.is_tuple) {
            if (comptime operations.len == 0) @compileError("no work to be done");
            var work = struct { ops: @TypeOf(operations) }{ .ops = operations };
            return self.io.queue(operations.len, &work, self.queue_callback);
        } else if (comptime ti == .Array) {
            if (comptime operations.len == 0) @compileError("no work to be done");
            var work = struct { ops: @TypeOf(operations) }{ .ops = operations };
            return self.io.queue(operations.len, &work, self.queue_callback);
        } else {
            var work = struct { ops: @TypeOf(.{operations}) }{ .ops = .{operations} };
            return self.io.queue(1, &work, self.queue_callback);
        }
    }

    pub const CompletionMode = enum {
        /// Call to `complete` will block until at least one operation completes
        blocking,
        /// Call to `complete` will only complete the currently ready operations if any
        nonblocking,
    };

    /// Complete operations
    /// Returns the number of completed operations, `0` if no operations were completed
    pub inline fn complete(self: *@This(), mode: CompletionMode) Error!CompletionResult {
        return self.io.complete(mode, self.completion_callback);
    }

    /// Block until all opreations are complete
    /// Returns the number of errors occured, 0 if there were no errors
    pub inline fn completeAll(self: *@This()) Error!u16 {
        var num_errors: u16 = 0;
        while (true) {
            const res = try self.io.complete(.blocking, self.completion_callback);
            num_errors += res.num_errors;
            if (res.num_completed == 0) break;
        }
        return num_errors;
    }
};

/// Completes a list of operations immediately, blocks until complete
/// For error handling you must check the `out_error` field in the operation
/// Returns the number of errors occured, 0 if there were no errors
pub inline fn complete(operations: anytype) Error!u16 {
    const ti = @typeInfo(@TypeOf(operations));
    if (comptime ti == .Struct and ti.Struct.is_tuple) {
        if (comptime operations.len == 0) @compileError("no work to be done");
        var work = struct { ops: @TypeOf(operations) }{ .ops = operations };
        return IO.immediate(operations.len, &work);
    } else if (comptime ti == .Array) {
        if (comptime operations.len == 0) @compileError("no work to be done");
        var work = struct { ops: @TypeOf(operations) }{ .ops = operations };
        return IO.immediate(operations.len, &work);
    } else {
        @compileError("expected a tuple or array of operations");
    }
}

/// Completes a list of operations immediately, blocks until complete
/// Returns `error.SomeOperationFailed` if any operation failed
pub inline fn multi(operations: anytype) (Error || error{SomeOperationFailed})!void {
    if (try complete(operations) > 0) return error.SomeOperationFailed;
}

/// Completes a single operation immediately, blocks until complete
pub inline fn single(operation: anytype) (Error || @TypeOf(operation).Error)!void {
    var op: @TypeOf(operation) = operation;
    var err: @TypeOf(operation).Error = error.Success;
    if (@hasField(@TypeOf(op), "out_error")) op.out_error = &err;
    if (try complete(.{op}) > 0) return err;
}

/// Checks if the current backend supports the operations
pub inline fn isSupported(operations: []const type) bool {
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

    pub inline fn init() @This().Error!@This() {
        return .{ .native = try IO.EventSource.init() };
    }

    pub inline fn deinit(self: *@This()) void {
        self.native.deinit();
        self.* = undefined;
    }

    pub inline fn notify(self: *@This()) void {
        self.native.notify();
    }

    pub inline fn wait(self: *@This()) void {
        self.native.wait();
    }
};

const IO = switch (@import("builtin").target.os.tag) {
    .linux => @import("aio/linux.zig").IO,
    else => @import("aio/Fallback.zig"),
};

const ops = @import("aio/ops.zig");
pub const Id = ops.Id;
pub const Nop = ops.Nop;
pub const Fsync = ops.Fsync;
pub const Read = ops.Read;
pub const Write = ops.Write;
pub const Accept = ops.Accept;
pub const Connect = ops.Connect;
pub const Recv = ops.Recv;
pub const Send = ops.Send;
pub const OpenAt = ops.OpenAt;
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

test "shared outputs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var f = try tmp.dir.createFile("test", .{});
    defer f.close();
    var id1: Id = @enumFromInt(69);
    var id2: Id = undefined;
    var id3: Id = undefined;
    try multi(.{
        Fsync{ .file = f, .out_id = &id1 },
        Fsync{ .file = f, .out_id = &id2 },
        Fsync{ .file = f, .out_id = &id3 },
    });
    try std.testing.expect(id1 != @as(Id, @enumFromInt(69)));
    try std.testing.expect(id1 != id2);
    try std.testing.expect(id1 != id3);
    try std.testing.expect(id2 != id3);
}

test "Nop" {
    var dynamic = try Dynamic.init(std.testing.allocator, 16);
    defer dynamic.deinit(std.testing.allocator);
    try dynamic.queue(Nop{ .domain = @enumFromInt(255), .ident = 69, .userdata = 42 });
    const Lel = struct {
        fn queue(uop: Dynamic.Uop, _: Id) void {
            switch (uop) {
                .nop => |*op| {
                    std.debug.assert(255 == @intFromEnum(op.domain));
                    std.debug.assert(69 == op.ident);
                    std.debug.assert(42 == op.userdata);
                },
                else => @panic("nope"),
            }
        }

        fn completion(uop: Dynamic.Uop, _: Id, failed: bool) void {
            switch (uop) {
                .nop => |*op| {
                    std.debug.assert(!failed);
                    std.debug.assert(255 == @intFromEnum(op.domain));
                    std.debug.assert(69 == op.ident);
                    std.debug.assert(42 == op.userdata);
                },
                else => @panic("nope"),
            }
        }
    };
    dynamic.queue_callback = Lel.queue;
    dynamic.completion_callback = Lel.completion;
    try std.testing.expectEqual(0, dynamic.completeAll());
}

test "Fsync" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var f = try tmp.dir.createFile("test", .{});
    defer f.close();
    try single(Fsync{ .file = f });
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
        try single(Read{ .file = f, .buffer = &buf, .out_read = &len });
        try std.testing.expectEqual("foobar".len, len);
        try std.testing.expectEqualSlices(u8, "foobar", buf[0..len]);
    }
    {
        var f = try tmp.dir.createFile("test", .{});
        defer f.close();
        try std.testing.expectError(
            error.NotOpenForReading,
            single(Read{ .file = f, .buffer = &buf, .out_read = &len }),
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
        try single(Write{ .file = f, .buffer = "foobar", .out_written = &len });
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
            single(Write{ .file = f, .buffer = "foobar", .out_written = &len }),
        );
    }
}

test "OpenAt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var f: std.fs.File = undefined;
    try std.testing.expectError(
        error.FileNotFound,
        single(OpenAt{ .dir = tmp.dir, .path = "test", .out_file = &f }),
    );
    var f2 = try tmp.dir.createFile("test", .{});
    f2.close();
    try single(OpenAt{ .dir = tmp.dir, .path = "test", .out_file = &f });
    f.close();
}

test "CloseFile" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile("test", .{});
    try single(CloseFile{ .file = f });
}

test "CloseDir" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = try tmp.dir.makeOpenPath("test", .{});
    try single(CloseDir{ .dir = d });
}

test "Timeout" {
    var timer = try std.time.Timer.start();
    try single(Timeout{ .ns = 2 * std.time.ns_per_s });
    try std.testing.expect(timer.lap() > std.time.ns_per_s);
}

test "LinkTimeout" {
    {
        var err: Timeout.Error = undefined;
        var err2: LinkTimeout.Error = undefined;
        const num_errors = try complete(.{
            Timeout{ .ns = 2 * std.time.ns_per_s, .out_error = &err, .link = .soft },
            LinkTimeout{ .ns = 1 * std.time.ns_per_s, .out_error = &err2 },
        });
        try std.testing.expectEqual(2, num_errors);
        try std.testing.expectEqual(error.Canceled, err);
        try std.testing.expectEqual(error.Expired, err2);
    }
    {
        const num_errors = try complete(.{
            Timeout{ .ns = 2 * std.time.ns_per_s, .link = .soft },
            LinkTimeout{ .ns = 1 * std.time.ns_per_s, .link = .soft },
            Timeout{ .ns = 1 * std.time.ns_per_s, .link = .soft },
        });
        try std.testing.expectEqual(3, num_errors);
    }
    {
        const num_errors = try complete(.{
            Timeout{ .ns = 1 * std.time.ns_per_s, .link = .soft },
            LinkTimeout{ .ns = 2 * std.time.ns_per_s },
        });
        try std.testing.expectEqual(0, num_errors);
    }
    {
        const num_errors = try complete(.{
            Timeout{ .ns = 1 * std.time.ns_per_s, .link = .soft },
            LinkTimeout{ .ns = 2 * std.time.ns_per_s, .link = .soft },
            Timeout{ .ns = 1 * std.time.ns_per_s, .link = .soft },
        });
        try std.testing.expectEqual(1, num_errors);
    }
    {
        const num_errors = try complete(.{
            Timeout{ .ns = 1 * std.time.ns_per_s, .link = .hard },
            LinkTimeout{ .ns = 2 * std.time.ns_per_s, .link = .soft },
            Timeout{ .ns = 1 * std.time.ns_per_s, .link = .soft },
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
    try dynamic.queue(Timeout{ .ns = 2 * std.time.ns_per_s, .out_id = &id, .out_error = &err });
    const tmp = try dynamic.complete(.nonblocking);
    try std.testing.expectEqual(0, tmp.num_errors);
    try std.testing.expectEqual(0, tmp.num_completed);
    try dynamic.queue(Cancel{ .id = id });
    const num_errors = try dynamic.completeAll();
    try std.testing.expectEqual(1, num_errors);
    try std.testing.expectEqual(error.Canceled, err);
    try std.testing.expect(timer.lap() < std.time.ns_per_s);
}

test "RenameAt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectError(
        error.FileNotFound,
        single(RenameAt{ .old_dir = tmp.dir, .old_path = "test", .new_dir = tmp.dir, .new_path = "new_test" }),
    );
    var f1 = try tmp.dir.createFile("test", .{});
    f1.close();
    try single(RenameAt{ .old_dir = tmp.dir, .old_path = "test", .new_dir = tmp.dir, .new_path = "new_test" });
    if (@import("builtin").target.os.tag == .windows) {
        // TODO: wtf? (using openFile instead causes deadlock)
    } else {
        try tmp.dir.access("new_test", .{});
    }
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("test", .{}));
    var f2 = try tmp.dir.createFile("test", .{});
    f2.close();
    try std.testing.expectError(error.PathAlreadyExists, single(RenameAt{ .old_dir = tmp.dir, .old_path = "test", .new_dir = tmp.dir, .new_path = "new_test" }));
}

test "UnlinkAt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectError(
        error.FileNotFound,
        single(UnlinkAt{ .dir = tmp.dir, .path = "test" }),
    );
    var f = try tmp.dir.createFile("test", .{});
    f.close();
    try single(UnlinkAt{ .dir = tmp.dir, .path = "test" });
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("test", .{}));
}

test "MkDirAt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try single(MkDirAt{ .dir = tmp.dir, .path = "test" });
    if (@import("builtin").target.os.tag != .windows) {
        // TODO: need to update the directory handle on windows? weird shit
    } else {
        try tmp.dir.access("test", .{});
    }
    try std.testing.expectError(error.PathAlreadyExists, single(MkDirAt{ .dir = tmp.dir, .path = "test" }));
}

test "SymlinkAt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    if (@import("builtin").target.os.tag == .windows) {
        const res = single(SymlinkAt{ .dir = tmp.dir, .target = "target", .link_path = "test" });
        // likely NTSTATUS=0xc00000bb (UNSUPPORTED)
        if (res == error.Unexpected) return error.SkipZigTest;
    } else {
        try single(SymlinkAt{ .dir = tmp.dir, .target = "target", .link_path = "test" });
    }
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.access("test", .{}),
    );
    var f = try tmp.dir.createFile("target", .{});
    f.close();
    try tmp.dir.access("test", .{});
    try std.testing.expectError(error.PathAlreadyExists, single(SymlinkAt{ .dir = tmp.dir, .target = "target", .link_path = "test" }));
}

test "ChildExit" {
    if (@import("builtin").target.os.tag == .windows) {
        return error.SkipZigTest;
    }

    const pid = try std.posix.fork();
    if (pid == 0) {
        std.time.sleep(1 * std.time.ns_per_s);
        std.posix.exit(69);
    }
    var term: std.process.Child.Term = undefined;
    try single(ChildExit{ .child = pid, .out_term = &term });
    if (term == .Signal) {
        try std.testing.expectEqual(69, term.Signal);
    } else if (term == .Exited) {
        try std.testing.expectEqual(69, term.Exited);
    } else {
        unreachable;
    }
}

test "Socket" {
    var socket: std.posix.socket_t = undefined;
    try single(Socket{
        .domain = std.posix.AF.INET,
        .flags = std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
        .protocol = std.posix.IPPROTO.TCP,
        .out_socket = &socket,
    });
    try single(CloseSocket{ .socket = socket });
}

test "EventSource" {
    var source = try EventSource.init();
    try multi(.{
        NotifyEventSource{ .source = &source },
        WaitEventSource{ .source = &source, .link = .hard },
        CloseEventSource{ .source = &source },
    });
}
