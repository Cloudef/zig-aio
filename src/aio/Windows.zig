const builtin = @import("builtin");
const std = @import("std");
const aio = @import("../aio.zig");
const Operation = @import("ops.zig").Operation;
const DynamicThreadPool = @import("minilib").DynamicThreadPool;
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
const INVALID_HANDLE = std.os.windows.INVALID_HANDLE_VALUE;
const HANDLE = win32.foundation.HANDLE;
const CloseHandle = win32.foundation.CloseHandle;
const INFINITE = win32.system.windows_programming.INFINITE;
const io = win32.system.io;
const fs = win32.storage.file_system;
const win_sock = win32.networking.win_sock;
const INVALID_SOCKET = win_sock.INVALID_SOCKET;

const IoContext = struct {
    overlapped: io.OVERLAPPED = std.mem.zeroes(io.OVERLAPPED),

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
ovls: []IoContext, // iocp overlapped structs
posix_pool: DynamicThreadPool, // thread pool for performing non iocp operations
tqueue: TimerQueue, // timer queue implementing linux -like timers
signaled: bool = false, // some operations have signaled immediately, optimization to polling iocp when not required
uringlator: Uringlator,

pub fn isSupported(ops: []const type) bool {
    for (ops) |op| {
        if (op == aio.Poll) return false;
    }
    return true;
}

pub fn init(allocator: std.mem.Allocator, n: u16) aio.Error!@This() {
    // need at least 2 threads, 1 iocp thread and 1 non-iocp blocking task thread
    const num_threads: u32 = @max(2, aio.options.max_threads orelse @as(u32, @intCast(std.Thread.getCpuCount() catch 1)));
    var iocp = try Iocp.init(1);
    errdefer iocp.deinit();
    var tqueue = try TimerQueue.init(allocator);
    errdefer tqueue.deinit();
    var posix_pool = DynamicThreadPool.init(allocator, .{
        .max_threads = num_threads / 2,
        .name = "aio:POSIX",
        .stack_size = @import("posix/posix.zig").stack_size,
    }) catch |err| return switch (err) {
        error.TimerUnsupported => error.Unsupported,
        else => |e| e,
    };
    errdefer posix_pool.deinit();
    const ovls = try allocator.alloc(IoContext, n);
    errdefer allocator.free(ovls);
    var uringlator = try Uringlator.init(allocator, n);
    errdefer uringlator.deinit(allocator);
    return .{
        .iocp = iocp,
        .tqueue = tqueue,
        .posix_pool = posix_pool,
        .ovls = ovls,
        .uringlator = uringlator,
    };
}

pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    self.uringlator.shutdown(self);
    self.iocp.deinit();
    self.tqueue.deinit();
    self.posix_pool.deinit();
    allocator.free(self.ovls);
    self.uringlator.deinit(allocator);
    self.* = undefined;
}

pub fn queue(self: *@This(), comptime len: u16, work: anytype, handler: anytype) aio.Error!void {
    try self.uringlator.queue(len, work, self, handler);
}

fn werr() Operation.Error {
    _ = try wtry(@as(i32, 0));
    return error.Success;
}

fn poll(self: *@This(), mode: aio.Dynamic.CompletionMode, comptime safety: Uringlator.Safety) error{Shutdown}!void {
    var transferred: u32 = undefined;
    var key: Iocp.Key = undefined;
    var maybe_ovl: ?*io.OVERLAPPED = null;
    const res = io.GetQueuedCompletionStatus(self.iocp.port, &transferred, @ptrCast(&key), &maybe_ovl, switch (mode) {
        .blocking => INFINITE,
        .nonblocking => 0,
    });
    if (res != 1 and maybe_ovl == null) return;

    const id: u16 = switch (key.type) {
        .nop => return, // non iocp operation finished
        .shutdown, .event_source, .child_exit => key.id,
        .overlapped => blk: {
            const parent: *IoContext = @fieldParentPtr("overlapped", maybe_ovl.?);
            break :blk @intCast((@intFromPtr(parent) - @intFromPtr(self.ovls.ptr)) / @sizeOf(IoContext));
        },
    };

    Uringlator.debug("iocp: {}", .{key.type});

    if (res == 1) {
        switch (key.type) {
            .nop => unreachable, // already handled
            .shutdown => return error.Shutdown,
            .event_source => {
                const source: *EventSource = @ptrCast(@alignCast(maybe_ovl.?));
                source.waitNonBlocking() catch {};
            },
            .child_exit => {
                switch (transferred) {
                    win32.system.system_services.JOB_OBJECT_MSG_EXIT_PROCESS, win32.system.system_services.JOB_OBJECT_MSG_ABNORMAL_EXIT_PROCESS => {},
                    else => return, // not the event we care about
                }
                const op = &self.uringlator.ops.nodes[id].used.child_exit;
                if (op.out_term) |term| {
                    var code: u32 = undefined;
                    if (win32.system.threading.GetExitCodeProcess(op.child, &code) == 0) {
                        term.* = .{ .Unknown = 0 };
                    } else {
                        term.* = .{ .Exited = @truncate(code) };
                    }
                }
            },
            .overlapped => self.ovls[id].res = transferred,
        }
        self.uringlator.finish(self, id, error.Success, safety);
    } else {
        std.debug.assert(key.type == .overlapped);
        self.uringlator.finish(self, id, werr(), safety);
    }
}

pub fn complete(self: *@This(), mode: aio.Dynamic.CompletionMode, handler: anytype) aio.Error!aio.CompletionResult {
    if (!try self.uringlator.submit(self)) return .{};
    var res: aio.CompletionResult = .{};
    while (res.num_completed == 0 and res.num_errors == 0) {
        if (!self.signaled) self.poll(mode, .thread_unsafe) catch unreachable;
        self.signaled = false;
        res = self.uringlator.complete(self, handler);
        if (mode == .nonblocking) break;
    }
    return res;
}

pub fn immediate(comptime len: u16, work: anytype) aio.Error!u16 {
    const Static = struct {
        threadlocal var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    };
    const allocator = Static.arena.allocator();
    defer _ = Static.arena.reset(.retain_capacity);
    var wrk = try init(allocator, len);
    defer wrk.deinit(allocator);
    try wrk.queue(len, work, {});
    var n: u16 = len;
    var num_errors: u16 = 0;
    while (n > 0) {
        const res = try wrk.complete(.blocking, {});
        n -= res.num_completed;
        num_errors += res.num_errors;
    }
    return num_errors;
}

fn onThreadPosixExecutor(self: *@This(), op: anytype, id: u16, comptime safety: Uringlator.Safety) void {
    const posix = @import("posix/posix.zig");
    var failure: Operation.Error = error.Success;
    while (true) {
        posix.perform(op, undefined) catch |err| {
            if (err == error.WouldBlock) continue;
            failure = err;
        };
        break;
    }
    self.uringlator.finish(self, id, failure, safety);
}

fn onThreadTimeout(ctx: *anyopaque, user_data: usize) void {
    var self: *@This() = @ptrCast(@alignCast(ctx));
    self.uringlator.finish(self, @intCast(user_data), error.Success, .thread_safe);
}

fn ovlOff(offset: u64) io.OVERLAPPED {
    return .{
        .Internal = 0,
        .InternalHigh = 0,
        .Anonymous = .{ .Anonymous = @bitCast(offset) },
        .hEvent = null,
    };
}

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

pub fn uringlator_queue(self: *@This(), op: anytype, id: u16) aio.Error!void {
    self.ovls[id] = .{};
    switch (comptime Operation.tagFromPayloadType(@TypeOf(op.*))) {
        .poll => return aio.Error.Unsupported,
        .wait_event_source => op._ = .{ .id = id, .iocp = &self.iocp },
        .accept => op.out_socket.* = INVALID_SOCKET,
        inline .recv, .send => op._ = .{.{ .buf = @constCast(@ptrCast(op.buffer.ptr)), .len = @intCast(op.buffer.len) }},
        else => {},
    }
}

pub fn uringlator_dequeue(_: *@This(), _: anytype, _: u16) void {}

pub fn uringlator_start(self: *@This(), op: anytype, id: u16) !void {
    switch (comptime Operation.tagFromPayloadType(@TypeOf(op.*))) {
        .poll => unreachable,
        .read => {
            const flags = try getHandleAccessInfo(op.file.handle);
            if (flags.FILE_READ_DATA != 1) return self.uringlator.finish(self, id, error.NotOpenForReading, .thread_unsafe);
            const h = fs.ReOpenFile(op.file.handle, flags, .{ .READ = 1, .WRITE = 1 }, fs.FILE_FLAG_OVERLAPPED);
            _ = wtry(h != null and h.? != INVALID_HANDLE) catch |err| return self.uringlator.finish(self, id, err, .thread_unsafe);
            self.iocp.associateHandle(id, h.?) catch |err| return self.uringlator.finish(self, id, err, .thread_unsafe);
            self.ovls[id] = .{ .overlapped = ovlOff(op.offset), .owned = .{ .handle = h.? } };
            var read: u32 = undefined;
            const ret = wtry(fs.ReadFile(h.?, op.buffer.ptr, @intCast(op.buffer.len), &read, &self.ovls[id].overlapped)) catch |err| return self.uringlator.finish(self, id, err, .thread_unsafe);
            if (ret != 0) {
                self.ovls[id].res = read;
                self.uringlator.finish(self, id, error.Success, .thread_unsafe);
            }
        },
        .write => {
            const flags = try getHandleAccessInfo(op.file.handle);
            if (flags.FILE_WRITE_DATA != 1) return self.uringlator.finish(self, id, error.NotOpenForWriting, .thread_unsafe);
            const h = fs.ReOpenFile(op.file.handle, flags, .{ .READ = 1, .WRITE = 1 }, fs.FILE_FLAG_OVERLAPPED);
            _ = wtry(h != null and h.? != INVALID_HANDLE) catch |err| return self.uringlator.finish(self, id, err, .thread_unsafe);
            self.iocp.associateHandle(id, h.?) catch |err| return self.uringlator.finish(self, id, err, .thread_unsafe);
            self.ovls[id] = .{ .overlapped = ovlOff(op.offset), .owned = .{ .handle = h.? } };
            var written: u32 = undefined;
            const ret = wtry(fs.WriteFile(h.?, op.buffer.ptr, @intCast(op.buffer.len), &written, &self.ovls[id].overlapped)) catch |err| return self.uringlator.finish(self, id, err, .thread_unsafe);
            if (ret != 0) {
                self.ovls[id].res = written;
                self.uringlator.finish(self, id, error.Success, .thread_unsafe);
            }
        },
        .accept => {
            self.iocp.associateSocket(id, op.socket) catch |err| return self.uringlator.finish(self, id, err, .thread_unsafe);
            op.out_socket.* = aio.socket(std.posix.AF.INET, 0, 0) catch |err| return self.uringlator.finish(self, id, err, .thread_unsafe);
            var read: u32 = undefined;
            if (wtry(win_sock.AcceptEx(op.socket, op.out_socket.*, &op._, 0, @sizeOf(std.posix.sockaddr) + 16, @sizeOf(std.posix.sockaddr) + 16, &read, &self.ovls[id].overlapped) == 1) catch |err| return self.uringlator.finish(self, id, err, .thread_unsafe)) {
                self.ovls[id].res = read;
                self.uringlator.finish(self, id, error.Success, .thread_unsafe);
            }
        },
        .recv => {
            self.iocp.associateSocket(id, op.socket) catch |err| return self.uringlator.finish(self, id, err, .thread_unsafe);
            switch (wposix.recvEx(op.socket, &op._, 0, &self.ovls[id].overlapped) catch |err| return self.uringlator.finish(self, id, err, .thread_unsafe)) {
                .pending => {},
                .transmitted => |bytes| {
                    self.ovls[id].res = bytes;
                    self.uringlator.finish(self, id, error.Success, .thread_unsafe);
                },
            }
        },
        .send => {
            self.iocp.associateSocket(id, op.socket) catch |err| return self.uringlator.finish(self, id, err, .thread_unsafe);
            switch (wposix.sendEx(op.socket, &op._, 0, &self.ovls[id].overlapped) catch |err| return self.uringlator.finish(self, id, err, .thread_unsafe)) {
                .pending => {},
                .transmitted => |bytes| {
                    self.ovls[id].res = bytes;
                    self.uringlator.finish(self, id, error.Success, .thread_unsafe);
                },
            }
        },
        .recv_msg => {
            self.iocp.associateSocket(id, op.socket) catch |err| return self.uringlator.finish(self, id, err, .thread_unsafe);
            switch (wposix.recvmsgEx(op.socket, op.out_msg, 0, &self.ovls[id].overlapped) catch |err| return self.uringlator.finish(self, id, err, .thread_unsafe)) {
                .pending => {},
                .transmitted => |bytes| {
                    self.ovls[id].res = bytes;
                    self.uringlator.finish(self, id, error.Success, .thread_unsafe);
                },
            }
        },
        .send_msg => {
            self.iocp.associateSocket(id, op.socket) catch |err| return self.uringlator.finish(self, id, err, .thread_unsafe);
            switch (wposix.sendmsgEx(op.socket, @constCast(op.msg), 0, &self.ovls[id].overlapped) catch |err| return self.uringlator.finish(self, id, err, .thread_unsafe)) {
                .pending => {},
                .transmitted => |bytes| {
                    self.ovls[id].res = bytes;
                    self.uringlator.finish(self, id, error.Success, .thread_unsafe);
                },
            }
        },
        inline .timeout, .link_timeout => {
            const closure: TimerQueue.Closure = .{ .context = self, .callback = onThreadTimeout };
            self.tqueue.schedule(.monotonic, op.ns, id, .{ .closure = closure }) catch return self.uringlator.finish(self, id, error.Unexpected, .thread_unsafe);
        },
        .child_exit => {
            const job = win32.system.job_objects.CreateJobObjectW(null, null);
            _ = wtry(job != null and job.? != INVALID_HANDLE) catch |err| return self.uringlator.finish(self, id, err, .thread_unsafe);
            errdefer checked(CloseHandle(job.?));
            _ = wtry(win32.system.job_objects.AssignProcessToJobObject(job.?, op.child)) catch return self.uringlator.finish(self, id, error.Unexpected, .thread_unsafe);
            const key: Iocp.Key = .{ .type = .child_exit, .id = id };
            var assoc: win32.system.job_objects.JOBOBJECT_ASSOCIATE_COMPLETION_PORT = .{
                .CompletionKey = @ptrFromInt(@as(usize, @bitCast(key))),
                .CompletionPort = self.iocp.port,
            };
            self.ovls[id] = .{ .owned = .{ .job = job.? } };
            errdefer self.ovls[id] = .{};
            _ = wtry(win32.system.job_objects.SetInformationJobObject(
                job.?,
                win32.system.job_objects.JobObjectAssociateCompletionPortInformation,
                @ptrCast(&assoc),
                @sizeOf(@TypeOf(assoc)),
            )) catch return self.uringlator.finish(self, id, error.Unexpected, .thread_unsafe);
        },
        .wait_event_source => op.source.native.addWaiter(&op._.link),
        // can be performed without a thread
        .notify_event_source, .close_event_source => self.onThreadPosixExecutor(op, id, .thread_unsafe),
        else => {
            // perform non IOCP supported operation on a thread
            try self.posix_pool.spawn(onThreadPosixExecutor, .{ self, op, id, .thread_safe });
        },
    }
}

pub fn uringlator_cancel(self: *@This(), op: anytype, id: u16) bool {
    switch (comptime Operation.tagFromPayloadType(@TypeOf(op.*))) {
        .read, .write => {
            return io.CancelIoEx(self.ovls[id].owned.handle, &self.ovls[id].overlapped) != 0;
        },
        inline .accept, .recv, .send, .send_msg, .recv_msg => {
            return io.CancelIoEx(@ptrCast(op.socket), &self.ovls[id].overlapped) != 0;
        },
        .child_exit => {
            self.ovls[id].deinit();
            self.ovls[id] = .{};
            self.uringlator.finish(self, id, error.Canceled, .thread_unsafe);
            return true;
        },
        .timeout, .link_timeout => {
            self.tqueue.disarm(.monotonic, id);
            self.uringlator.finish(self, id, error.Canceled, .thread_unsafe);
            return true;
        },
        .wait_event_source => {
            op.source.native.removeWaiter(&op._.link);
            self.uringlator.finish(self, id, error.Canceled, .thread_unsafe);
            return true;
        },
        else => {},
    }
    return false;
}

pub fn uringlator_complete(self: *@This(), op: anytype, id: u16, failure: Operation.Error) void {
    defer self.ovls[id].deinit();
    if (failure == error.Success) {
        switch (comptime Operation.tagFromPayloadType(@TypeOf(op.*))) {
            .timeout, .link_timeout => self.tqueue.disarm(.monotonic, id),
            .wait_event_source => op.source.native.removeWaiter(&op._.link),
            .accept => {
                if (op.out_addr) |a| @memcpy(std.mem.asBytes(a), op._[@sizeOf(std.posix.sockaddr) + 16 .. @sizeOf(std.posix.sockaddr) * 2 + 16]);
            },
            inline .read, .recv => op.out_read.* = self.ovls[id].res,
            inline .write, .send => {
                if (op.out_written) |w| w.* = self.ovls[id].res;
            },
            else => {},
        }
    } else {
        switch (comptime Operation.tagFromPayloadType(@TypeOf(op.*))) {
            .timeout, .link_timeout => self.tqueue.disarm(.monotonic, id),
            .wait_event_source => op.source.native.removeWaiter(&op._.link),
            .accept => if (op.out_socket.* != INVALID_SOCKET) checked(CloseHandle(op.out_socket.*)),
            else => {},
        }
    }
}

pub fn uringlator_notify(self: *@This(), comptime safety: Uringlator.Safety) void {
    switch (safety) {
        .thread_unsafe => self.signaled = true,
        .thread_safe => self.iocp.notify(.{ .type = .nop, .id = undefined }, null),
    }
}
