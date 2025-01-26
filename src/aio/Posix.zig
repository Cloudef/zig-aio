const builtin = @import("builtin");
const std = @import("std");
const aio = @import("../aio.zig");
const posix = @import("posix/posix.zig");
const Operation = @import("ops.zig").Operation;
const FixedArrayList = @import("minilib").FixedArrayList;
const TimerQueue = @import("minilib").TimerQueue;
const DynamicThreadPool = @import("minilib").DynamicThreadPool;
const Uringlator = @import("Uringlator.zig");

// This tries to emulate io_uring functionality.
// If something does not match how it works on io_uring on linux, it should be change to match.
// While this uses readiness before performing the requests, the io_uring model is not particularily
// suited for readiness, thus don't expect this backend to be particularily effecient.
// However it might be still more pleasant experience than (e)poll/kqueueing away as the behaviour should be
// more or less consistent.

comptime {
    if (builtin.single_threaded) {
        @compileError(
            \\Posix backend requires building with threads as otherwise it may block the whole program.
            \\To only target linux and io_uring, set `aio_options.posix = .disable` in your root .zig file.
        );
    }
}

pub const EventSource = posix.EventSource;

tqueue: TimerQueue, // timer queue implementing linux -like timers
readiness: []posix.Readiness, // readiness fd that gets polled before we perform the operation
pfd: FixedArrayList(std.posix.pollfd, u32), // current fds that we must poll for wakeup
posix_pool: DynamicThreadPool, // thread pool for performing operations, not all operations will be performed here
kludge_pool: if (posix.needs_kludge) DynamicThreadPool else void, // thread pool for performing operations which can't be polled for readiness
pending: std.DynamicBitSetUnmanaged, // operation is pending on readiness fd (poll)
source: EventSource, // when threaded operations finish, they signal it using this event source
signaled: bool = false, // some operations have signaled immediately, optimization to avoid running poll when not required
uringlator: Uringlator,

pub fn isSupported(_: []const type) bool {
    return true; // very optimistic :D
}

pub fn init(allocator: std.mem.Allocator, n: u16) aio.Error!@This() {
    var tqueue = try TimerQueue.init(allocator);
    errdefer tqueue.deinit();
    const readiness = try allocator.alloc(posix.Readiness, n);
    errdefer allocator.free(readiness);
    var pfd = try FixedArrayList(std.posix.pollfd, u32).init(allocator, n + 1);
    errdefer pfd.deinit(allocator);
    var posix_pool = DynamicThreadPool.init(allocator, .{
        .max_threads = aio.options.max_threads,
        .name = "aio:POSIX",
        .stack_size = posix.stack_size,
    }) catch |err| return switch (err) {
        error.TimerUnsupported => error.Unsupported,
        else => |e| e,
    };
    errdefer posix_pool.deinit();
    var kludge_pool = switch (posix.needs_kludge) {
        true => DynamicThreadPool.init(allocator, .{
            .max_threads = aio.options.posix_max_kludge_threads,
            .name = "aio:KLUDGE",
            .stack_size = posix.stack_size,
        }) catch |err| return switch (err) {
            error.TimerUnsupported => error.Unsupported,
            else => |e| e,
        },
        false => {},
    };
    errdefer if (posix.needs_kludge) kludge_pool.deinit();
    var pending_set = try std.DynamicBitSetUnmanaged.initEmpty(allocator, n);
    errdefer pending_set.deinit(allocator);
    var uringlator = try Uringlator.init(allocator, n);
    errdefer uringlator.deinit(allocator);
    var source = try EventSource.init();
    errdefer source.deinit();
    pfd.add(.{ .fd = source.fd, .events = std.posix.POLL.IN, .revents = 0 }) catch unreachable;
    return .{
        .tqueue = tqueue,
        .readiness = readiness,
        .pfd = pfd,
        .posix_pool = posix_pool,
        .kludge_pool = kludge_pool,
        .pending = pending_set,
        .source = source,
        .uringlator = uringlator,
    };
}

pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    self.uringlator.shutdown(self);
    self.tqueue.deinit();
    self.posix_pool.deinit();
    if (posix.needs_kludge) self.kludge_pool.deinit();
    allocator.free(self.readiness);
    self.pfd.deinit(allocator);
    self.pending.deinit(allocator);
    self.source.deinit();
    self.uringlator.deinit(allocator);
    self.* = undefined;
}

pub fn queue(self: *@This(), comptime len: u16, uops: []Operation.Union, handler: anytype) aio.Error!void {
    try self.uringlator.queue(len, uops, self, handler);
}

fn hasField(T: type, comptime name: []const u8) bool {
    inline for (comptime std.meta.fields(T)) |field| {
        if (std.mem.eql(u8, field.name, name)) return true;
    }
    return false;
}

fn readinessToPollEvents(readiness: posix.Readiness) i16 {
    var events: i16 = 0;
    if (readiness.events.in) events |= std.posix.POLL.IN;
    if (readiness.events.out) events |= std.posix.POLL.OUT;
    if (@hasDecl(std.posix.POLL, "PRI") and readiness.events.pri) events |= std.posix.POLL.PRI;
    return events;
}

pub fn complete(self: *@This(), mode: aio.Dynamic.CompletionMode, handler: anytype) aio.Error!aio.CompletionResult {
    if (!try self.uringlator.submit(self)) return .{};

    var res: aio.CompletionResult = .{};
    while (res.num_completed == 0 and res.num_errors == 0) {
        if (self.signaled) {
            self.signaled = false;
            res = self.uringlator.complete(self, handler);
            if (mode == .blocking) continue;
            return res;
        }

        // I was thinking if we should use epoll/kqueue if available
        // The pros is that we don't have to iterate the self.pfd.items
        // However, the self.pfd.items changes frequently so we have to keep re-registering fds anyways
        // Poll is pretty much anywhere, so poll it is. This is a posix backend anyways.
        const n = posix.poll(self.pfd.items[0..self.pfd.len], if (mode == .blocking) -1 else 0) catch |err| return switch (err) {
            error.NetworkSubsystemFailed => unreachable,
            else => |e| e,
        };
        if (n == 0) {
            if (mode == .blocking) continue; // should not happen in practice
            return .{};
        }

        var off: usize = 0;
        again: while (off < self.pfd.len) {
            for (self.pfd.items[off..self.pfd.len], 0..) |*pfd, pid| {
                off = pid;
                if (pfd.revents == 0) continue;
                if (pfd.fd == self.source.fd) {
                    std.debug.assert(pfd.revents & std.posix.POLL.NVAL == 0);
                    std.debug.assert(pfd.revents & std.posix.POLL.ERR == 0);
                    std.debug.assert(pfd.revents & std.posix.POLL.HUP == 0);
                    self.source.waitNonBlocking() catch {};
                    res = self.uringlator.complete(self, handler);
                } else {
                    var iter = self.pending.iterator(.{});
                    while (iter.next()) |id| {
                        if (pfd.fd != self.readiness[id].fd) continue;
                        if (pfd.events != readinessToPollEvents(self.readiness[id])) continue;
                        defer {
                            // do not poll this fd again
                            self.pfd.swapRemove(@truncate(pid));
                            self.pending.unset(id);
                        }
                        if (pfd.revents & std.posix.POLL.ERR != 0 or pfd.revents & std.posix.POLL.NVAL != 0) {
                            if (pfd.revents & std.posix.POLL.ERR != 0) {
                                const uop = &self.uringlator.ops.nodes[id].used;
                                switch (uop.*) {
                                    inline else => |*op| {
                                        if (hasField(@TypeOf(op.*).Error, "BrokenPipe")) {
                                            self.uringlator.finish(self, @intCast(id), error.BrokenPipe, .thread_unsafe);
                                        } else {
                                            self.uringlator.finish(self, @intCast(id), error.Unexpected, .thread_unsafe);
                                        }
                                        break :again;
                                    },
                                }
                            } else {
                                self.uringlator.finish(self, @intCast(id), error.Unexpected, .thread_unsafe);
                                break :again;
                            }
                        }
                        // start it for real this time
                        switch (self.uringlator.ops.nodes[id].used) {
                            inline else => |*op| {
                                if (self.uringlator.next[id] != id) {
                                    Uringlator.debug("ready: {}: {} => {}", .{ id, comptime Operation.tagFromPayloadType(@TypeOf(op.*)), self.uringlator.next[id] });
                                } else {
                                    Uringlator.debug("ready: {}: {}", .{ id, comptime Operation.tagFromPayloadType(@TypeOf(op.*)) });
                                }
                                try self.uringlator_start(op, @intCast(id));
                            },
                        }
                        break :again;
                    }
                }
            }
            break;
        }

        if (mode == .nonblocking) break;
    }

    return res;
}

pub fn immediate(comptime len: u16, uops: []Operation.Union) aio.Error!u16 {
    const Static = struct {
        threadlocal var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    };
    const allocator = if (builtin.target.os.tag == .wasi) std.heap.wasm_allocator else Static.arena.allocator();
    defer if (builtin.target.os.tag != .wasi) {
        _ = Static.arena.reset(.retain_capacity);
    };
    var wrk = try init(allocator, len);
    defer wrk.deinit(allocator);
    try wrk.queue(len, uops, {});
    var n: u16 = len;
    var num_errors: u16 = 0;
    while (n > 0) {
        const res = try wrk.complete(.blocking, {});
        n -= res.num_completed;
        num_errors += res.num_errors;
    }
    return num_errors;
}

fn blockingPosixExecutor(self: *@This(), op: anytype, id: u16, readiness: posix.Readiness, comptime safety: Uringlator.Safety) void {
    var failure: Operation.Error = error.Success;
    while (true) {
        posix.perform(op, readiness) catch |err| {
            if (err == error.WouldBlock) continue;
            failure = err;
        };
        break;
    }
    self.uringlator.finish(self, id, failure, safety);
}

fn nonBlockingPosixExecutor(self: *@This(), op: anytype, id: u16, readiness: posix.Readiness) error{WouldBlock}!void {
    var failure: Operation.Error = error.Success;
    posix.perform(op, readiness) catch |err| {
        if (err == error.WouldBlock) return error.WouldBlock;
        failure = err;
    };
    self.uringlator.finish(self, id, failure, .thread_unsafe);
}

fn nonBlockingPosixExecutorFcntl(self: *@This(), op: anytype, id: u16, readiness: posix.Readiness) error{ WouldBlock, FcntlFailed }!void {
    const NONBLOCK = 1 << @bitOffsetOf(std.posix.O, "NONBLOCK");
    const old: struct { usize, bool } = blk: {
        if (readiness.fd != posix.invalid_fd) {
            const flags = std.posix.fcntl(readiness.fd, std.posix.F.GETFL, 0) catch return error.FcntlFailed;
            if ((flags & NONBLOCK) == 0) break :blk .{ flags, false };
            _ = std.posix.fcntl(readiness.fd, std.posix.F.SETFL, flags | NONBLOCK) catch return error.FcntlFailed;
            break :blk .{ flags, true };
        }
        break :blk .{ 0, false };
    };

    var failure: Operation.Error = error.Success;
    posix.perform(op, readiness) catch |err| {
        if (err == error.WouldBlock) return error.WouldBlock;
        failure = err;
    };

    if (old[1]) _ = std.posix.fcntl(readiness.fd, std.posix.F.SETFL, old[0]) catch {};
    self.uringlator.finish(self, id, failure, .thread_unsafe);
}

fn onThreadTimeout(ctx: *anyopaque, user_data: usize) void {
    var self: *@This() = @ptrCast(@alignCast(ctx));
    self.uringlator.finish(self, @intCast(user_data), error.Success, .thread_safe);
}

pub fn uringlator_queue(self: *@This(), op: anytype, id: u16) aio.Error!void {
    self.readiness[id] = posix.openReadiness(op) catch |err| {
        self.pending.set(id);
        self.uringlator.finish(self, id, err, .thread_unsafe);
        return;
    };
    if (@as(i16, @bitCast(self.readiness[id].events)) == 0) {
        self.pending.set(id);
    } else {
        self.pending.unset(id);
    }
}

pub fn uringlator_dequeue(self: *@This(), op: anytype, id: u16) void {
    posix.closeReadiness(op, self.readiness[id]);
    self.pending.unset(id);
}

pub fn uringlator_start(self: *@This(), op: anytype, id: u16) !void {
    if (self.pending.isSet(id)) {
        switch (comptime Operation.tagFromPayloadType(@TypeOf(op.*))) {
            .poll => self.uringlator.finish(self, id, error.Success, .thread_unsafe),
            inline .timeout, .link_timeout => {
                const closure: TimerQueue.Closure = .{ .context = self, .callback = onThreadTimeout };
                self.tqueue.schedule(.monotonic, op.ns, id, .{ .closure = closure }) catch self.uringlator.finish(self, id, error.Unexpected, .thread_unsafe);
            },
            // can be performed here, doesn't have to be dispatched to thread
            .child_exit,
            .wait_event_source,
            .notify_event_source,
            .close_event_source,
            .send,
            .recv,
            .send_msg,
            .recv_msg,
            => self.nonBlockingPosixExecutor(op, id, self.readiness[id]) catch {
                // poll lied to us, or somebody else raced us, poll again
                self.pending.unset(id);
            },
            inline else => |tag| {
                if (posix.needs_kludge and tag == .read_tty) {
                    @branchHint(.unlikely);
                    try self.kludge_pool.spawn(blockingPosixExecutor, .{ self, op, id, self.readiness[id], .thread_safe });
                }
                if (comptime builtin.target.os.tag == .wasi) {
                    // perform on thread
                    try self.posix_pool.spawn(blockingPosixExecutor, .{ self, op, id, self.readiness[id], .thread_safe });
                } else if (self.readiness[id].fd != posix.invalid_fd) {
                    self.nonBlockingPosixExecutorFcntl(op, id, self.readiness[id]) catch |err| switch (err) {
                        // poll lied to us, or somebody else raced us, poll again
                        error.WouldBlock => self.pending.unset(id),
                        // perform on thread
                        error.FcntlFailed => try self.posix_pool.spawn(blockingPosixExecutor, .{ self, op, id, self.readiness[id], .thread_safe }),
                    };
                } else {
                    // perform on thread
                    try self.posix_pool.spawn(blockingPosixExecutor, .{ self, op, id, self.readiness[id], .thread_safe });
                }
            },
        }
    }

    if (!self.pending.isSet(id)) {
        // try non-blocking send/recv first
        // TODO: might want to not do this if the buffer is large
        if (switch (comptime Operation.tagFromPayloadType(@TypeOf(op.*))) {
            .wait_event_source,
            .send,
            .recv,
            .send_msg,
            .recv_msg,
            => blk: {
                self.nonBlockingPosixExecutor(op, id, self.readiness[id]) catch break :blk false;
                break :blk true;
            },
            else => false,
        }) {
            // operation was completed immediately
            return;
        }

        if (comptime builtin.target.os.tag == .wasi) {
            switch (comptime Operation.tagFromPayloadType(@TypeOf(op.*))) {
                .read => {
                    var stat: std.os.wasi.fdstat_t = undefined;
                    std.debug.assert(std.os.wasi.fd_fdstat_get(op.file.handle, &stat) == .SUCCESS);
                    if (!stat.fs_rights_base.FD_READ) {
                        return self.uringlator.finish(self, id, error.NotOpenForReading, .thread_unsafe);
                    }
                },
                .write => {
                    var stat: std.os.wasi.fdstat_t = undefined;
                    std.debug.assert(std.os.wasi.fd_fdstat_get(op.file.handle, &stat) == .SUCCESS);
                    if (!stat.fs_rights_base.FD_WRITE) {
                        return self.uringlator.finish(self, id, error.NotOpenForWriting, .thread_unsafe);
                    }
                },
                else => {},
            }
        }

        // pending for readiness, perform the operation later
        if (self.uringlator.next[id] != id) {
            Uringlator.debug("pending: {}: {} => {}", .{ id, comptime Operation.tagFromPayloadType(@TypeOf(op.*)), self.uringlator.next[id] });
        } else {
            Uringlator.debug("pending: {}: {}", .{ id, comptime Operation.tagFromPayloadType(@TypeOf(op.*)) });
        }

        std.debug.assert(self.readiness[id].fd != posix.invalid_fd);

        self.pfd.add(.{
            .fd = self.readiness[id].fd,
            .events = readinessToPollEvents(self.readiness[id]),
            .revents = 0,
        }) catch unreachable;

        self.pending.set(id);
    }
}

pub fn uringlator_cancel(self: *@This(), op: anytype, id: u16) bool {
    if (self.pending.isSet(id)) {
        self.uringlator.finish(self, id, error.Canceled, .thread_unsafe);
        return true;
    }
    switch (comptime Operation.tagFromPayloadType(@TypeOf(op.*))) {
        .timeout, .link_timeout => {
            self.tqueue.disarm(.monotonic, id);
            self.uringlator.finish(self, id, error.Canceled, .thread_unsafe);
            return true;
        },
        else => {},
    }
    return false;
}

pub fn uringlator_complete(self: *@This(), op: anytype, id: u16, _: Operation.Error) void {
    switch (comptime Operation.tagFromPayloadType(@TypeOf(op.*))) {
        .timeout, .link_timeout => self.tqueue.disarm(.monotonic, id),
        else => {},
    }
    if (self.readiness[id].fd != posix.invalid_fd) {
        if (self.pending.isSet(id)) {
            for (self.pfd.items[0..self.pfd.len], 0..) |pfd, idx| {
                if (pfd.fd != self.readiness[id].fd) continue;
                if (pfd.events != readinessToPollEvents(self.readiness[id])) continue;
                self.pfd.swapRemove(@truncate(idx));
                break;
            }
            self.pending.unset(id);
        }
        posix.closeReadiness(op, self.readiness[id]);
        self.readiness[id] = .{};
    }
}

pub fn uringlator_notify(self: *@This(), comptime safety: Uringlator.Safety) void {
    switch (safety) {
        .thread_safe => self.source.notify(),
        .thread_unsafe => self.signaled = true,
    }
}
