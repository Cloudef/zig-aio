const builtin = @import("builtin");
const std = @import("std");
const aio = @import("../aio.zig");
const Operation = @import("ops.zig").Operation;
const ItemPool = @import("minilib").ItemPool;
const DynamicThreadPool = @import("minilib").DynamicThreadPool;
const DoubleBufferedFixedArrayList = @import("minilib").DoubleBufferedFixedArrayList;
const TimerQueue = @import("minilib").TimerQueue;
const Uringlator = @import("Uringlator.zig");
const Iocp = @import("posix/windows.zig").Iocp;
const wposix = @import("posix/windows.zig");
const win32 = @import("win32");

// Optimized for Windows and uses IOCP operations whenever possible.
// <https://int64.org/2009/05/14/io-completion-ports-made-easy/>

pub const EventSource = Uringlator.EventSource;

comptime {
    if (builtin.single_threaded) {
        @compileError(
            \\Windows backend requires building with threads as otherwise it may block the whole program.
        );
    }
}

const checked = wposix.checked;
const wtry = wposix.wtry;
const werr = wposix.werr;
const GetLastError = win32.foundation.GetLastError;
const INVALID_HANDLE = std.os.windows.INVALID_HANDLE_VALUE;
const HANDLE = win32.foundation.HANDLE;
const CloseHandle = win32.foundation.CloseHandle;
const INFINITE = win32.system.windows_programming.INFINITE;
const io = win32.system.io;
const fs = win32.storage.file_system;
const win_sock = win32.networking.win_sock;
const WSAGetLastError = win_sock.WSAGetLastError;
const INVALID_SOCKET = win_sock.INVALID_SOCKET;
const threading = win32.system.threading;

const IoContext = struct {
    overlapped: io.OVERLAPPED = undefined,

    // needs to be cleaned up
    owned: union(enum) {
        handle: HANDLE,
        job: HANDLE,
        none: void,
    } = .none,

    // operation specific return value
    res: usize = 0,

    pub fn deinit(self: *@This()) void {
        switch (self.owned) {
            inline .handle, .job => |h| checked(CloseHandle(h)),
            .none => {},
        }
        self.* = undefined;
    }
};

iocp: Iocp,
tqueue: TimerQueue, // timer queue implementing linux -like timers
tpool: DynamicThreadPool, // thread pool for performing iocp and non iocp operations
iocp_threads_spawned: bool = false, // iocp needs own poll threads
ovls: []IoContext,
uringlator: Uringlator,

pub fn isSupported(_: []const type) bool {
    return true; // very optimistic :D
}

pub fn init(allocator: std.mem.Allocator, n: u16) aio.Error!@This() {
    // need at least 2 threads, 1 iocp thread and 1 non-iocp blocking task thread
    const num_threads: u32 = @max(2, aio.options.max_threads orelse @as(u32, @intCast(std.Thread.getCpuCount() catch 1)));
    var iocp = try Iocp.init(num_threads / 2);
    errdefer iocp.deinit();
    var tqueue = try TimerQueue.init(allocator);
    errdefer tqueue.deinit();
    var tpool = DynamicThreadPool.init(allocator, .{ .max_threads = num_threads }) catch |err| return switch (err) {
        error.TimerUnsupported => error.Unsupported,
        else => |e| e,
    };
    errdefer tpool.deinit();
    const ovls = try allocator.alloc(IoContext, n);
    errdefer allocator.free(ovls);
    var uringlator = try Uringlator.init(allocator, n);
    errdefer uringlator.deinit(allocator);
    return .{
        .iocp = iocp,
        .tqueue = tqueue,
        .tpool = tpool,
        .ovls = ovls,
        .uringlator = uringlator,
    };
}

pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    self.uringlator.shutdown(*@This(), self, cancel);
    self.iocp.deinit();
    self.tqueue.deinit();
    self.tpool.deinit();
    allocator.free(self.ovls);
    self.uringlator.deinit(allocator);
    self.* = undefined;
}

fn queueCallback(self: *@This(), id: u16, uop: *Operation.Union) aio.Error!void {
    self.ovls[id] = .{};
    switch (uop.*) {
        .wait_event_source => |*op| op._ = .{ .id = id, .iocp = &self.iocp },
        .accept => |*op| op.out_socket.* = INVALID_SOCKET,
        inline .recv, .send => |*op| op._ = .{.{ .buf = @constCast(@ptrCast(op.buffer.ptr)), .len = @intCast(op.buffer.len) }},
        else => {},
    }
}

pub fn queue(self: *@This(), comptime len: u16, work: anytype, cb: ?aio.Dynamic.QueueCallback) aio.Error!void {
    try self.uringlator.queue(len, work, cb, *@This(), self, queueCallback);
}

fn iocpDrainThread(self: *@This()) void {
    while (true) {
        var transferred: u32 = undefined;
        var key: Iocp.Key = undefined;
        var maybe_ovl: ?*io.OVERLAPPED = null;
        const res = io.GetQueuedCompletionStatus(self.iocp.port, &transferred, @ptrCast(&key), &maybe_ovl, INFINITE);
        if (res == 1) {
            switch (key.type) {
                .shutdown => break,
                .event_source => {
                    const source: *EventSource = @ptrCast(@alignCast(maybe_ovl.?));
                    source.wait();
                },
                .child_exit => {
                    switch (transferred) {
                        win32.system.system_services.JOB_OBJECT_MSG_EXIT_PROCESS, win32.system.system_services.JOB_OBJECT_MSG_ABNORMAL_EXIT_PROCESS => {},
                        else => continue,
                    }
                    const op = &self.uringlator.ops.nodes[key.id].used.child_exit;
                    if (op.out_term) |term| {
                        var code: u32 = undefined;
                        if (win32.system.threading.GetExitCodeProcess(op.child, &code) == 0) {
                            term.* = .{ .Unknown = 0 };
                        } else {
                            term.* = .{ .Exited = @truncate(code) };
                        }
                    }
                },
                .overlapped => self.ovls[key.id].res = transferred,
            }
            self.uringlator.finish(key.id, error.Success);
        } else if (maybe_ovl) |_| {
            std.debug.assert(key.type != .shutdown);
            self.uringlator.finish(key.id, werr(0));
        } else {
            break;
        }
    }
}

fn spawnIocpThreads(self: *@This()) !void {
    @setCold(true);
    for (0..self.iocp.num_threads) |_| try self.tpool.spawn(iocpDrainThread, .{self}, .{ .stack_size = 1024 * 16 });
    self.iocp_threads_spawned = true;
}

pub fn complete(self: *@This(), mode: aio.Dynamic.CompletionMode, cb: ?aio.Dynamic.CompletionCallback) aio.Error!aio.CompletionResult {
    if (!self.iocp_threads_spawned) try self.spawnIocpThreads(); // iocp threads must be first
    if (!try self.uringlator.submit(*@This(), self, start, cancel)) return .{};

    const num_finished = self.uringlator.finished.len();
    if (mode == .blocking and num_finished == 0) {
        self.uringlator.source.wait();
    } else if (num_finished == 0) {
        return .{};
    }

    return self.uringlator.complete(cb, *@This(), self, completion);
}

pub fn immediate(comptime len: u16, work: anytype) aio.Error!u16 {
    const Static = struct {
        threadlocal var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    };
    const allocator = Static.arena.allocator();
    defer _ = Static.arena.reset(.retain_capacity);
    var wrk = try init(allocator, len);
    defer wrk.deinit(allocator);
    try wrk.queue(len, work, null);
    var n: u16 = len;
    var num_errors: u16 = 0;
    while (n > 0) {
        const res = try wrk.complete(.blocking, null);
        n -= res.num_completed;
        num_errors += res.num_errors;
    }
    return num_errors;
}

fn onThreadPosixExecutor(self: *@This(), id: u16, uop: *Operation.Union) void {
    const posix = @import("posix/posix.zig");
    var failure: Operation.Error = error.Success;
    Uringlator.uopUnwrapCall(uop, posix.perform, .{undefined}) catch |err| {
        failure = err;
    };
    self.uringlator.finish(id, failure);
}

fn onThreadTimeout(ctx: *anyopaque, user_data: usize) void {
    var self: *@This() = @ptrCast(@alignCast(ctx));
    self.uringlator.finish(@intCast(user_data), error.Success);
}

fn ovlOff(offset: u64) io.OVERLAPPED {
    return .{
        .Internal = undefined,
        .InternalHigh = undefined,
        .Anonymous = .{ .Anonymous = @bitCast(offset) },
        .hEvent = undefined,
    };
}

const AccessInfo = packed struct {
    read: bool,
    write: bool,
    append: bool,
};

fn getHandleAccessInfo(handle: HANDLE) !fs.FILE_ACCESS_FLAGS {
    var io_status_block: std.os.windows.IO_STATUS_BLOCK = undefined;
    var access: std.os.windows.FILE_ACCESS_INFORMATION = undefined;
    const rc = std.os.windows.ntdll.NtQueryInformationFile(handle, &io_status_block, &access, @sizeOf(std.os.windows.FILE_ACCESS_INFORMATION), .FileAccessInformation);
    switch (rc) {
        .SUCCESS => {},
        .INVALID_PARAMETER => unreachable,
        else => return error.Unexpected,
    }
    return @bitCast(access.AccessFlags);
}

fn start(self: *@This(), id: u16, uop: *Operation.Union) !void {
    var trash: u32 = undefined;
    switch (uop.*) {
        .read => |*op| {
            const flags = try getHandleAccessInfo(op.file.handle);
            if (flags.FILE_READ_DATA != 1) return self.uringlator.finish(id, error.NotOpenForReading);
            const h = fs.ReOpenFile(op.file.handle, flags, .{ .READ = 1, .WRITE = 1 }, fs.FILE_FLAG_OVERLAPPED);
            wtry(h != null and h.? != INVALID_HANDLE) catch |err| return self.uringlator.finish(id, err);
            self.iocp.associateHandle(id, h.?) catch |err| return self.uringlator.finish(id, err);
            self.ovls[id] = .{ .overlapped = ovlOff(op.offset), .owned = .{ .handle = h.? } };
            wtry(fs.ReadFile(h.?, op.buffer.ptr, @intCast(op.buffer.len), &trash, &self.ovls[id].overlapped)) catch |err| return self.uringlator.finish(id, err);
        },
        .write => |*op| {
            const flags = try getHandleAccessInfo(op.file.handle);
            if (flags.FILE_WRITE_DATA != 1) return self.uringlator.finish(id, error.NotOpenForWriting);
            const h = fs.ReOpenFile(op.file.handle, flags, .{ .READ = 1, .WRITE = 1 }, fs.FILE_FLAG_OVERLAPPED);
            wtry(h != null and h.? != INVALID_HANDLE) catch |err| return self.uringlator.finish(id, err);
            self.iocp.associateHandle(id, h.?) catch |err| return self.uringlator.finish(id, err);
            self.ovls[id] = .{ .overlapped = ovlOff(op.offset), .owned = .{ .handle = h.? } };
            wtry(fs.WriteFile(h.?, op.buffer.ptr, @intCast(op.buffer.len), &trash, &self.ovls[id].overlapped)) catch |err| return self.uringlator.finish(id, err);
        },
        .accept => |*op| {
            self.iocp.associateSocket(id, op.socket) catch |err| return self.uringlator.finish(id, err);
            op.out_socket.* = aio.socket(std.posix.AF.INET, 0, 0) catch |err| return self.uringlator.finish(id, err);
            wtry(win_sock.AcceptEx(op.socket, op.out_socket.*, &op._, 0, @sizeOf(std.posix.sockaddr) + 16, @sizeOf(std.posix.sockaddr) + 16, &trash, &self.ovls[id].overlapped) == 1) catch |err| return self.uringlator.finish(id, err);
        },
        .recv => |*op| {
            self.iocp.associateSocket(id, op.socket) catch |err| return self.uringlator.finish(id, err);
            _ = wposix.recvEx(op.socket, &op._, 0, &self.ovls[id].overlapped) catch |err| return self.uringlator.finish(id, err);
        },
        .send => |*op| {
            self.iocp.associateSocket(id, op.socket) catch |err| return self.uringlator.finish(id, err);
            _ = wposix.sendEx(op.socket, &op._, 0, &self.ovls[id].overlapped) catch |err| return self.uringlator.finish(id, err);
        },
        .send_msg => |*op| {
            self.iocp.associateSocket(id, op.socket) catch |err| return self.uringlator.finish(id, err);
            _ = wposix.sendmsgEx(op.socket, @constCast(op.msg), 0, &self.ovls[id].overlapped) catch |err| return self.uringlator.finish(id, err);
        },
        .recv_msg => |*op| {
            self.iocp.associateSocket(id, op.socket) catch |err| return self.uringlator.finish(id, err);
            _ = wposix.recvmsgEx(op.socket, op.out_msg, 0, &self.ovls[id].overlapped) catch |err| return self.uringlator.finish(id, err);
        },
        inline .timeout, .link_timeout => |*op| {
            const closure: TimerQueue.Closure = .{ .context = self, .callback = onThreadTimeout };
            self.tqueue.schedule(.monotonic, op.ns, id, .{ .closure = closure }) catch return self.uringlator.finish(id, error.Unexpected);
        },
        .child_exit => |*op| {
            const job = win32.system.job_objects.CreateJobObjectW(null, null);
            wtry(job != null and job.? != INVALID_HANDLE) catch |err| return self.uringlator.finish(id, err);
            errdefer checked(CloseHandle(job.?));
            wtry(win32.system.job_objects.AssignProcessToJobObject(job.?, op.child)) catch return self.uringlator.finish(id, error.Unexpected);
            const key: Iocp.Key = .{ .type = .child_exit, .id = id };
            var assoc: win32.system.job_objects.JOBOBJECT_ASSOCIATE_COMPLETION_PORT = .{
                .CompletionKey = @ptrFromInt(@as(usize, @bitCast(key))),
                .CompletionPort = self.iocp.port,
            };
            self.ovls[id] = .{ .owned = .{ .job = job.? } };
            errdefer self.ovls[id] = .{};
            wtry(win32.system.job_objects.SetInformationJobObject(
                job.?,
                win32.system.job_objects.JobObjectAssociateCompletionPortInformation,
                @ptrCast(&assoc),
                @sizeOf(@TypeOf(assoc)),
            )) catch return self.uringlator.finish(id, error.Unexpected);
        },
        .wait_event_source => |*op| op.source.native.addWaiter(&op._.link),
        // can be performed without a thread
        .notify_event_source, .close_event_source => self.onThreadPosixExecutor(id, uop),
        else => {
            // perform non IOCP supported operation on a thread
            try self.tpool.spawn(onThreadPosixExecutor, .{ self, id, uop }, .{ .stack_size = 4096 * 16 });
        },
    }
}

fn cancel(self: *@This(), id: u16, uop: *Operation.Union) bool {
    switch (uop.*) {
        .read, .write => {
            return io.CancelIoEx(self.ovls[id].owned.handle, &self.ovls[id].overlapped) != 0;
        },
        inline .accept, .recv, .send, .send_msg, .recv_msg => |*op| {
            return io.CancelIoEx(@ptrCast(op.socket), &self.ovls[id].overlapped) != 0;
        },
        .child_exit => {
            self.ovls[id].deinit();
            self.ovls[id] = .{};
            self.uringlator.finish(id, error.Canceled);
            return true;
        },
        .timeout, .link_timeout, .wait_event_source => {
            self.tqueue.disarm(.monotonic, id);
            self.uringlator.finish(id, error.Canceled);
            return true;
        },
        else => {},
    }
    return false;
}

fn completion(self: *@This(), id: u16, uop: *Operation.Union, failure: Operation.Error) void {
    defer self.ovls[id].deinit();
    if (failure == error.Success) {
        switch (uop.*) {
            .timeout, .link_timeout => self.tqueue.disarm(.monotonic, id),
            .wait_event_source => |*op| op.source.native.removeWaiter(&op._.link),
            .accept => |*op| {
                if (op.out_addr) |a| @memcpy(std.mem.asBytes(a), op._[@sizeOf(std.posix.sockaddr) + 16 .. @sizeOf(std.posix.sockaddr) * 2 + 16]);
            },
            inline .read, .recv => |*op| op.out_read.* = self.ovls[id].res,
            inline .write, .send => |*op| {
                if (op.out_written) |w| w.* = self.ovls[id].res;
            },
            else => {},
        }
    } else {
        switch (uop.*) {
            .timeout, .link_timeout => self.tqueue.disarm(.monotonic, id),
            .wait_event_source => |*op| op.source.native.removeWaiter(&op._.link),
            .accept => |*op| if (op.out_socket.* != INVALID_SOCKET) checked(CloseHandle(op.out_socket.*)),
            else => {},
        }
    }
}
