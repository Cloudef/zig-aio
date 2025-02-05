const builtin = @import("builtin");
const std = @import("std");
const aio = @import("../aio.zig");
const posix = @import("posix/posix.zig");
const Operation = @import("ops.zig").Operation;
const FixedArrayList = @import("minilib").FixedArrayList;
const TimerQueue = @import("minilib").TimerQueue;
const DynamicThreadPool = @import("minilib").DynamicThreadPool;
const Uringlator = @import("uringlator.zig").Uringlator(PosixOperation);

// This tries to emulate io_uring functionality.
// If something does not match how it works on io_uring on linux, it should be changed to match.

pub const EventSource = posix.EventSource;

const PosixOperation = struct {
    readiness: posix.Readiness,
};

const needs_kludge = switch (builtin.target.os.tag) {
    .macos, .ios, .watchos, .visionos, .tvos => true,
    else => false,
};

const single_threaded = builtin.single_threaded or aio.options.max_threads == 1;
const needs_source = !single_threaded or (needs_kludge and !builtin.single_threaded);

tqueue: TimerQueue, // timer queue implementing linux -like timers
pfd: if (needs_source) FixedArrayList(std.posix.pollfd, u32) else FixedArrayList(std.posix.pollfd, u16), // current fds that we must poll for wakeup
pid: FixedArrayList(aio.Id, u16), // maps pfd to id
posix_pool: if (!single_threaded) DynamicThreadPool else void, // thread pool for performing operations, not all operations will be performed here
kludge_pool: if (needs_kludge and !builtin.single_threaded) DynamicThreadPool else void, // thread pool for performing operations which can't be polled for readiness
pending: std.DynamicBitSetUnmanaged, // operation is pending on readiness fd (poll)
in_flight: std.DynamicBitSetUnmanaged, // operation is executing and can't be canceled
source: if (needs_source) EventSource else void, // when threaded operations finish, they signal it using this event source
signaled: bool = false, // some operations have signaled immediately, optimization to avoid running poll when not required
uringlator: Uringlator,

pub fn isSupported(_: []const Operation) bool {
    return true; // very optimistic :D
}

pub fn init(allocator: std.mem.Allocator, n: u16) aio.Error!@This() {
    var tqueue = try TimerQueue.init(allocator);
    errdefer tqueue.deinit();
    var pfd = switch (needs_source) {
        true => try FixedArrayList(std.posix.pollfd, u32).init(allocator, @as(u32, @intCast(n)) + 1),
        false => try FixedArrayList(std.posix.pollfd, u16).init(allocator, n),
    };
    errdefer pfd.deinit(allocator);
    var pid = try FixedArrayList(aio.Id, u16).init(allocator, n);
    errdefer pid.deinit(allocator);
    var posix_pool = switch (single_threaded) {
        true => {},
        false => DynamicThreadPool.init(allocator, .{
            .max_threads = aio.options.max_threads,
            .name = "aio:POSIX",
            .stack_size = posix.stack_size,
        }) catch |err| return switch (err) {
            error.TimerUnsupported => error.Unsupported,
            else => |e| e,
        },
    };
    errdefer if (!single_threaded) posix_pool.deinit();
    var kludge_pool = switch (needs_kludge and !builtin.single_threaded) {
        // Kludge threads are used when operation cannot be polled for readiness.
        // One example is macos's /dev/tty which can only be queried for readiness using select/pselect.
        // <https://lists.apple.com/archives/Darwin-dev/2006/Apr/msg00066.html>
        // <https://nathancraddock.com/blog/macos-dev-tty-polling/>
        // Only used on platforms that need this hack (darwin)
        true => DynamicThreadPool.init(allocator, .{
            .max_threads = 16,
            .name = "aio:KLUDGE",
            .stack_size = posix.stack_size,
        }) catch |err| return switch (err) {
            error.TimerUnsupported => error.Unsupported,
            else => |e| e,
        },
        false => {},
    };
    errdefer if (needs_kludge and !builtin.single_threaded) kludge_pool.deinit();
    var pending_set = try std.DynamicBitSetUnmanaged.initEmpty(allocator, n);
    errdefer pending_set.deinit(allocator);
    var in_flight_set = try std.DynamicBitSetUnmanaged.initEmpty(allocator, n);
    errdefer in_flight_set.deinit(allocator);
    var uringlator = try Uringlator.init(allocator, n);
    errdefer uringlator.deinit(allocator);
    var source = if (needs_source) try EventSource.init() else {};
    errdefer if (needs_source) source.deinit();
    if (needs_source) {
        pfd.add(.{ .fd = source.fd, .events = std.posix.POLL.IN, .revents = 0 }) catch unreachable;
    }
    return .{
        .tqueue = tqueue,
        .pfd = pfd,
        .pid = pid,
        .posix_pool = posix_pool,
        .kludge_pool = kludge_pool,
        .pending = pending_set,
        .in_flight = in_flight_set,
        .source = source,
        .uringlator = uringlator,
    };
}

pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    self.uringlator.shutdown(self);
    self.tqueue.deinit();
    if (!single_threaded) self.posix_pool.deinit();
    if (needs_kludge and !builtin.single_threaded) self.kludge_pool.deinit();
    self.pfd.deinit(allocator);
    self.pid.deinit(allocator);
    self.pending.deinit(allocator);
    self.in_flight.deinit(allocator);
    if (needs_source) self.source.deinit();
    self.uringlator.deinit(allocator);
    self.* = undefined;
}

pub fn queue(self: *@This(), pairs: anytype, handler: anytype) aio.Error!void {
    try self.uringlator.queue(pairs, self, handler);
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

pub fn onTimeout(self: *@This(), user_data: usize) void {
    self.uringlator.finish(self, aio.Id.init(user_data), error.Success, .thread_unsafe);
}

pub fn complete(self: *@This(), mode: aio.Dynamic.CompletionMode, handler: anytype) aio.Error!aio.CompletionResult {
    if (!try self.uringlator.submit(self)) return .{};

    var res: aio.CompletionResult = .{};
    while (res.num_completed == 0 and res.num_errors == 0) {
        // TODO: poll in macos is very slow, write "better poll" interface that uses kqueue/epoll/poll
        const wait_time = std.math.cast(i32, self.tqueue.tick(self)) orelse -1;
        const should_block = mode == .blocking and !self.signaled;
        const n = posix.poll(self.pfd.slice(), if (should_block) wait_time else 0) catch |err| return switch (err) {
            error.NetworkSubsystemFailed => unreachable,
            else => |e| e,
        };

        var off: usize = 0;
        var handled: usize = 0;
        again: while (off < self.pfd.len and handled < n) {
            for (self.pfd.constSlice()[off..], off..) |pfd, pid| {
                if (pfd.revents == 0) continue;

                off = pid;
                handled += 1;

                if (needs_source and pfd.fd == self.source.fd) {
                    std.debug.assert(pid == 0);
                    std.debug.assert(pfd.revents & std.posix.POLL.NVAL == 0);
                    std.debug.assert(pfd.revents & std.posix.POLL.ERR == 0);
                    std.debug.assert(pfd.revents & std.posix.POLL.HUP == 0);
                    self.source.waitNonBlocking() catch break;
                    self.signaled = true; // threaded operation finished
                } else {
                    std.debug.assert(pid >= @intFromBool(needs_source));
                    const id = self.pid.constSlice()[pid - @intFromBool(needs_source)];
                    const readiness = self.uringlator.ops.getOne(.readiness, id);
                    std.debug.assert(pfd.fd == readiness.fd);
                    std.debug.assert(pfd.events == readinessToPollEvents(readiness));
                    std.debug.assert(self.pending.isSet(id.slot));

                    // do not poll this fd again
                    self.pfd.swapRemove(@truncate(pid));
                    self.pid.swapRemove(@truncate(pid - @intFromBool(needs_source)));

                    const op_type = self.uringlator.ops.getOne(.type, id);
                    if (pfd.revents & std.posix.POLL.ERR != 0 or pfd.revents & std.posix.POLL.NVAL != 0) {
                        if (pfd.revents & std.posix.POLL.ERR != 0) {
                            switch (op_type) {
                                inline else => |tag| {
                                    if (hasField(Operation.map.getAssertContains(tag).Error, "BrokenPipe")) {
                                        Uringlator.debug("poll: {}: {} => ERR (BrokenPipe)", .{ id, op_type });
                                        self.uringlator.finish(self, id, error.BrokenPipe, .thread_unsafe);
                                    } else {
                                        Uringlator.debug("poll: {}: {} => ERR (Unexpected)", .{ id, op_type });
                                        self.uringlator.finish(self, id, error.Unexpected, .thread_unsafe);
                                    }
                                    continue :again;
                                },
                            }
                        } else {
                            Uringlator.debug("poll: {}: {} => NVAL (Unexpected)", .{ id, op_type });
                            self.uringlator.finish(self, id, error.Unexpected, .thread_unsafe);
                            continue :again;
                        }
                    }

                    // start it for real this time
                    if (self.uringlator.ops.getOne(.next, id) != id) {
                        Uringlator.debug("ready: {}: {} => {}", .{ id, op_type, self.uringlator.ops.getOne(.next, id) });
                    } else {
                        Uringlator.debug("ready: {}: {}", .{ id, op_type });
                    }

                    try self.uringlator_start(id, op_type);
                    continue :again;
                }
            }
            break;
        }

        while (self.signaled) {
            self.signaled = false;
            const tmp = self.uringlator.complete(self, handler);
            res.num_errors += tmp.num_errors;
            res.num_completed += tmp.num_completed;
        }

        if (mode == .nonblocking) break;
    }

    return res;
}

pub fn immediate(pairs: anytype) aio.Error!u16 {
    const Static = struct {
        threadlocal var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    };
    const allocator = if (builtin.target.os.tag == .wasi) std.heap.wasm_allocator else Static.arena.allocator();
    defer if (builtin.target.os.tag != .wasi) {
        _ = Static.arena.reset(.retain_capacity);
    };
    var wrk = try init(allocator, pairs.len);
    defer wrk.deinit(allocator);
    try wrk.queue(pairs, {});
    var n: u16 = pairs.len;
    var num_errors: u16 = 0;
    while (n > 0) {
        const res = try wrk.complete(.blocking, {});
        n -= res.num_completed;
        num_errors += res.num_errors;
    }
    return num_errors;
}

fn blockingPosixExecutor(self: *@This(), comptime op_type: Operation, op: Operation.map.getAssertContains(op_type), id: aio.Id, readiness: posix.Readiness, comptime safety: Uringlator.Safety) void {
    var failure: Operation.Error = error.Success;
    while (true) {
        posix.perform(op_type, op, readiness) catch |err| {
            if (err == error.WouldBlock) continue;
            failure = err;
        };
        break;
    }
    self.uringlator.finish(self, id, failure, safety);
}

fn posixPerform(self: *@This(), comptime op_type: Operation, op: Operation.map.getAssertContains(op_type), id: aio.Id, readiness: posix.Readiness) !void {
    if (single_threaded) {
        self.blockingPosixExecutor(op_type, op, id, readiness, .thread_unsafe);
    } else {
        try self.posix_pool.spawn(blockingPosixExecutor, .{ self, op_type, op, id, readiness, .thread_safe });
    }
}

fn nonBlockingPosixExecutor(self: *@This(), comptime op_type: Operation, op: Operation.map.getAssertContains(op_type), id: aio.Id, readiness: posix.Readiness) error{WouldBlock}!void {
    var failure: Operation.Error = error.Success;
    posix.perform(op_type, op, readiness) catch |err| {
        if (err == error.WouldBlock) return error.WouldBlock;
        failure = err;
    };
    self.uringlator.finish(self, id, failure, .thread_unsafe);
}

fn nonBlockingPosixExecutorFcntl(self: *@This(), comptime op_type: Operation, op: Operation.map.getAssertContains(op_type), id: aio.Id, readiness: posix.Readiness) error{ WouldBlock, FcntlFailed }!void {
    const NONBLOCK = 1 << @bitOffsetOf(std.posix.O, "NONBLOCK");
    const old: struct { usize, bool } = blk: {
        if (readiness.fd != posix.invalid_fd) {
            const flags = std.posix.fcntl(readiness.fd, std.posix.F.GETFL, 0) catch return error.FcntlFailed;
            if (flags & NONBLOCK == NONBLOCK) break :blk .{ flags, false };
            _ = std.posix.fcntl(readiness.fd, std.posix.F.SETFL, flags | NONBLOCK) catch return error.FcntlFailed;
            break :blk .{ flags, true };
        }
        break :blk .{ 0, false };
    };
    defer if (old[1]) {
        _ = std.posix.fcntl(readiness.fd, std.posix.F.SETFL, old[0]) catch {};
    };

    var failure: Operation.Error = error.Success;
    posix.perform(op_type, op, readiness) catch |err| {
        if (err == error.WouldBlock) return error.WouldBlock;
        failure = err;
    };

    self.uringlator.finish(self, id, failure, .thread_unsafe);
}

fn openReadiness(comptime op_type: Operation, op: Operation.map.getAssertContains(op_type)) !posix.Readiness {
    return switch (op_type) {
        .nop => .{},
        .fsync => .{},
        .poll => .{ .fd = op.fd, .events = op.events },
        .write => .{ .fd = op.file.handle, .events = .{ .out = true } },
        .read_tty => switch (builtin.target.os.tag) {
            .macos, .ios, .watchos, .visionos, .tvos => .{},
            else => .{ .fd = op.tty.handle, .events = .{ .in = true } },
        },
        .read => .{ .fd = op.file.handle, .events = .{ .in = true } },
        .accept, .recv, .recv_msg => .{ .fd = op.socket, .events = .{ .in = true } },
        .socket, .connect, .shutdown => .{},
        .send, .send_msg => .{ .fd = op.socket, .events = .{ .out = true } },
        .open_at, .close_file, .close_dir, .close_socket => .{},
        .timeout, .link_timeout => .{},
        .cancel, .rename_at, .unlink_at, .mkdir_at, .symlink_at => .{},
        .child_exit => .{ .fd = (try posix.ChildWatcher.init(op.child)).fd, .events = .{ .in = true } },
        .wait_event_source => op.source.native.waitReadiness(),
        .notify_event_source => op.source.native.notifyReadiness(),
        .close_event_source => .{},
    };
}

pub fn uringlator_queue(self: *@This(), id: aio.Id, comptime op_type: Operation, op: Operation.map.getAssertContains(op_type)) aio.Error!PosixOperation {
    comptime {
        if (needs_kludge and builtin.single_threaded and op_type == .read_tty) {
            @compileError(
                \\Posix backend requires building with threads as otherwise it may block the whole program.
                \\Unfortunately, on MacOS it is not possible to poll /dev/tty so you need threads.
            );
        }
    }

    const readiness = openReadiness(op_type, op) catch |err| {
        self.pending.set(id.slot);
        self.uringlator.finish(self, id, err, .thread_unsafe);
        return .{ .readiness = .{} };
    };

    if (op_type == .poll) {
        self.pending.unset(id.slot);
    } else {
        if (@as(i16, @bitCast(readiness.events)) == 0) {
            self.pending.set(id.slot);
        } else {
            self.pending.unset(id.slot);
        }
    }

    self.in_flight.unset(id.slot);
    return .{ .readiness = readiness };
}

pub fn uringlator_dequeue(self: *@This(), id: aio.Id, comptime op_type: Operation, op: Operation.map.getAssertContains(op_type)) void {
    switch (op_type) {
        .child_exit => {
            const readiness = self.uringlator.ops.getOne(.readiness, id);
            var watcher: posix.ChildWatcher = .{ .id = op.child, .fd = readiness.fd };
            watcher.deinit();
        },
        else => {},
    }
}

pub fn uringlator_start(self: *@This(), id: aio.Id, op_type: Operation) !void {
    if (self.pending.isSet(id.slot)) {
        self.in_flight.set(id.slot);
        std.debug.assert(std.mem.indexOfScalar(aio.Id, self.pid.constSlice(), id) == null);
        switch (op_type) {
            .poll => self.uringlator.finish(self, id, error.Success, .thread_unsafe),
            .timeout => {
                const state = self.uringlator.ops.getOnePtr(.state, id);
                self.tqueue.schedule(.monotonic, state.timeout.ns, id.cast(usize), .{}) catch self.uringlator.finish(self, id, error.Unexpected, .thread_unsafe);
            },
            .link_timeout => {
                const state = self.uringlator.ops.getOnePtr(.state, id);
                self.tqueue.schedule(.monotonic, state.link_timeout.ns, id.cast(usize), .{}) catch self.uringlator.finish(self, id, error.Unexpected, .thread_unsafe);
            },
            // can be performed here, doesn't have to be dispatched to thread
            inline .child_exit,
            .wait_event_source,
            .notify_event_source,
            .close_event_source,
            .send,
            .recv,
            .send_msg,
            .recv_msg,
            => |tag| {
                const state = self.uringlator.ops.getOnePtr(.state, id);
                const result = self.uringlator.ops.getOne(.out_result, id);
                const readiness = self.uringlator.ops.getOne(.readiness, id);
                self.nonBlockingPosixExecutor(tag, state.toOp(tag, result), id, readiness) catch {
                    if (readiness.fd != posix.invalid_fd) {
                        // poll lied to us, or somebody else raced us, poll again
                        self.pending.unset(id.slot);
                    } else {
                        unreachable; // non pollable ops should not fail here
                    }
                };
            },
            inline else => |tag| {
                const state = self.uringlator.ops.getOnePtr(.state, id);
                const result = self.uringlator.ops.getOne(.out_result, id);
                const readiness = self.uringlator.ops.getOne(.readiness, id);
                if (needs_kludge and !builtin.single_threaded and tag == .read_tty) {
                    @branchHint(.unlikely);
                    try self.kludge_pool.spawn(blockingPosixExecutor, .{ self, tag, state.toOp(tag, result), id, readiness, .thread_safe });
                }
                if (comptime builtin.target.os.tag == .wasi) {
                    try self.posixPerform(tag, state.toOp(tag, result), id, readiness);
                } else if (readiness.fd != posix.invalid_fd) {
                    self.nonBlockingPosixExecutorFcntl(tag, state.toOp(tag, result), id, readiness) catch |err| switch (err) {
                        // poll lied to us, or somebody else raced us, poll again
                        error.WouldBlock => self.pending.unset(id.slot),
                        // perform blockingly or on thread
                        error.FcntlFailed => try self.posixPerform(tag, state.toOp(tag, result), id, readiness),
                    };
                } else {
                    try self.posixPerform(tag, state.toOp(tag, result), id, readiness);
                }
            },
        }
    }

    if (!self.pending.isSet(id.slot)) {
        // try non-blocking send/recv first
        // TODO: might want to not do this if the buffer is large
        if (switch (op_type) {
            inline .wait_event_source,
            .send,
            .recv,
            .send_msg,
            .recv_msg,
            => |tag| blk: {
                const state = self.uringlator.ops.getOnePtr(.state, id);
                const result = self.uringlator.ops.getOne(.out_result, id);
                const readiness = self.uringlator.ops.getOne(.readiness, id);
                self.nonBlockingPosixExecutor(tag, state.toOp(tag, result), id, readiness) catch break :blk false;
                break :blk true;
            },
            else => false,
        }) {
            // operation was completed immediately
            return;
        }

        if (comptime builtin.target.os.tag == .wasi) {
            switch (op_type) {
                .read => {
                    var stat: std.os.wasi.fdstat_t = undefined;
                    const state = self.uringlator.ops.getOnePtr(.state, id);
                    std.debug.assert(std.os.wasi.fd_fdstat_get(state.read.file.handle, &stat) == .SUCCESS);
                    if (!stat.fs_rights_base.FD_READ) {
                        return self.uringlator.finish(self, id, error.NotOpenForReading, .thread_unsafe);
                    }
                },
                .write => {
                    var stat: std.os.wasi.fdstat_t = undefined;
                    const state = self.uringlator.ops.getOnePtr(.state, id);
                    std.debug.assert(std.os.wasi.fd_fdstat_get(state.write.file.handle, &stat) == .SUCCESS);
                    if (!stat.fs_rights_base.FD_WRITE) {
                        return self.uringlator.finish(self, id, error.NotOpenForWriting, .thread_unsafe);
                    }
                },
                else => {},
            }
        }

        // pending for readiness, perform the operation later
        if (self.uringlator.ops.getOne(.next, id) != id) {
            Uringlator.debug("pending: {}: {} => {}", .{ id, op_type, self.uringlator.ops.getOne(.next, id) });
        } else {
            Uringlator.debug("pending: {}: {}", .{ id, op_type });
        }

        const readiness = self.uringlator.ops.getOne(.readiness, id);
        std.debug.assert(readiness.fd != posix.invalid_fd);

        self.pfd.add(.{
            .fd = readiness.fd,
            .events = readinessToPollEvents(readiness),
            .revents = 0,
        }) catch unreachable;
        self.pid.add(id) catch unreachable;

        self.in_flight.unset(id.slot);
        self.pending.set(id.slot);
    }
}

pub fn uringlator_cancel(self: *@This(), id: aio.Id, op_type: Operation, err: Operation.Error) bool {
    switch (op_type) {
        .timeout, .link_timeout => {
            self.tqueue.disarm(.monotonic, id.cast(usize)) catch return false; // raced
            self.uringlator.finish(self, id, err, .thread_unsafe);
            return true;
        },
        else => if (self.pending.isSet(id.slot) and !self.in_flight.isSet(id.slot)) {
            const readiness = self.uringlator.ops.getOnePtr(.readiness, id);
            const off = @intFromBool(needs_source);
            for (self.pfd.constSlice()[off..], self.pid.constSlice(), off..) |pfd, pid, idx| {
                if (pid != id) continue;
                std.debug.assert(pfd.fd == readiness.fd);
                std.debug.assert(pfd.events == readinessToPollEvents(readiness.*));
                self.pfd.swapRemove(@truncate(idx));
                self.pid.swapRemove(@truncate(idx - 1));
                break;
            }
            std.debug.assert(std.mem.indexOfScalar(aio.Id, self.pid.constSlice(), id) == null);
            self.uringlator.finish(self, id, err, .thread_unsafe);
            return true;
        },
    }
    return false;
}

pub fn uringlator_complete(self: *@This(), id: aio.Id, op_type: Operation, _: Operation.Error) void {
    const readiness = self.uringlator.ops.getOnePtr(.readiness, id);
    switch (op_type) {
        .child_exit => {
            const state = self.uringlator.ops.getOnePtr(.state, id);
            var watcher: posix.ChildWatcher = .{ .id = state.child_exit.child, .fd = readiness.fd };
            watcher.deinit();
        },
        else => {},
    }
    std.debug.assert(std.mem.indexOfScalar(aio.Id, self.pid.constSlice(), id) == null);
    readiness.* = .{};
}

pub fn uringlator_notify(self: *@This(), comptime safety: Uringlator.Safety) void {
    switch (safety) {
        .thread_safe => self.source.notify(),
        .thread_unsafe => self.signaled = true,
    }
}
