//! Basic io-uring -like asynchronous IO API
//! It is possible to both dynamically and statically queue IO work to be executed in a asynchronous fashion
//! On linux this is a very shim wrapper around `io_uring`, on other systems there might be more overhead

const std = @import("std");

pub const InitError = error{
    Overflow,
    OutOfMemory,
    PermissionDenied,
    ProcessQuotaExceeded,
    SystemQuotaExceeded,
    SystemResources,
    SystemOutdated,
    Unexpected,
};

pub const QueueError = error{
    Overflow,
    SubmissionQueueFull,
};

pub const CompletionError = error{
    CompletionQueueOvercommitted,
    SubmissionQueueEntryInvalid,
    SystemResources,
    Unexpected,
};

pub const ImmediateError = InitError || QueueError || CompletionError;

pub const CompletionResult = struct {
    num_completed: u16 = 0,
    num_errors: u16 = 0,
};

/// Queue operations dynamically and complete them on demand
pub const Dynamic = struct {
    io: IO,

    pub inline fn init(allocator: std.mem.Allocator, n: u16) InitError!@This() {
        return .{ .io = try IO.init(allocator, n) };
    }

    pub inline fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.io.deinit(allocator);
        self.* = undefined;
    }

    /// Queue operations for future completion
    /// The call is atomic, if any of the operations fail to queue, then the given operations are reverted
    pub inline fn queue(self: *@This(), operations: anytype) QueueError!void {
        const ti = @typeInfo(@TypeOf(operations));
        if (comptime ti == .Struct and ti.Struct.is_tuple) {
            var work = struct { ops: @TypeOf(operations) }{ .ops = operations };
            return self.io.queue(operations.len, &work);
        } else if (comptime ti == .Array) {
            var work = struct { ops: @TypeOf(operations) }{ .ops = operations };
            return self.io.queue(operations.len, &work);
        } else {
            return self.io.queue(1, &struct { ops: @TypeOf(.{operations}) }{ .ops = .{operations} });
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
    pub inline fn complete(self: *@This(), mode: CompletionMode) CompletionError!CompletionResult {
        return self.io.complete(mode);
    }
};

/// Completes a list of operations immediately, blocks until complete
/// For error handling you must check the `out_error` field in the operation
/// Returns the number of errors occured, 0 if there were no errors
pub inline fn complete(operations: anytype) ImmediateError!u16 {
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
pub inline fn multi(operations: anytype) (ImmediateError || error{SomeOperationFailed})!void {
    if (try complete(operations) > 0) return error.SomeOperationFailed;
}

/// Completes a single operation immediately, blocks until complete
pub inline fn single(operation: anytype) (ImmediateError || OperationError)!void {
    var op: @TypeOf(operation) = operation;
    var err: @TypeOf(operation).Error = error.Success;
    op.out_error = &err;
    _ = try complete(.{op});
    if (err != error.Success) return err;
}

const IO = switch (@import("builtin").target.os.tag) {
    .linux => @import("aio/linux.zig"),
    else => @compileError("unsupported os"),
};

const ops = @import("aio/ops.zig");
pub const Id = ops.Id;
pub const OperationError = ops.Operation.Error;
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

test "shared outputs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var f = try tmp.dir.createFile("test", .{});
    defer f.close();
    var id1: Id = @enumFromInt(69);
    var id2: Id = undefined;
    var id3: Id = undefined;
    var counter1: u16 = 0;
    var counter2: u16 = 2;
    try multi(.{
        Fsync{ .file = f, .out_id = &id1, .counter = .{ .inc = &counter1 } },
        Fsync{ .file = f, .out_id = &id2, .counter = .{ .inc = &counter1 } },
        Fsync{ .file = f, .out_id = &id3, .counter = .{ .dec = &counter2 } },
    });
    try std.testing.expect(id1 != @as(Id, @enumFromInt(69)));
    try std.testing.expect(id1 != id2);
    try std.testing.expect(id1 != id3);
    try std.testing.expect(id2 != id3);
    try std.testing.expect(counter1 == 2);
    try std.testing.expect(counter2 == 1);
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
        try std.testing.expectEqual(len, "foobar".len);
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
        try std.testing.expectEqual(len, "foobar".len);
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
    var err: Timeout.Error = undefined;
    var expired: bool = undefined;
    const res = try complete(.{
        Timeout{ .ns = 2 * std.time.ns_per_s, .out_error = &err, .link_next = true },
        LinkTimeout{ .ns = 1 * std.time.ns_per_s, .out_expired = &expired },
    });
    try std.testing.expectEqual(2, res.num_completed);
    try std.testing.expectEqual(1, res.num_errors);
    try std.testing.expectEqual(error.OperationCanceled, err);
    try std.testing.expectEqual(true, expired);
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
    const res = try dynamic.complete(.blocking);
    try std.testing.expectEqual(1, res.num_errors);
    try std.testing.expectEqual(2, res.num_completed);
    try std.testing.expectEqual(error.OperationCanceled, err);
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
    try tmp.dir.access("new_test", .{});
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
    try tmp.dir.access("test", .{});
    try std.testing.expectError(error.PathAlreadyExists, single(MkDirAt{ .dir = tmp.dir, .path = "test" }));
}

test "SymlinkAt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try single(SymlinkAt{ .dir = tmp.dir, .target = "target", .link_path = "test" });
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
    if (@import("builtin").target.os.tag != .linux) {
        return error.SkipZigTest;
    }
    const pid = try std.posix.fork();
    if (pid == 0) {
        std.time.sleep(1 * std.time.ns_per_s);
        std.posix.exit(69);
    }
    var term: std.process.Child.Term = undefined;
    try single(ChildExit{ .child = pid, .out_term = &term });
    try std.testing.expectEqual(69, term.Signal);
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
