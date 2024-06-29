const builtin = @import("builtin");
const std = @import("std");
const aio = @import("../aio.zig");
const posix = @import("posix.zig");
const Operation = @import("ops.zig").Operation;
const ItemPool = @import("minilib").ItemPool;
const FixedArrayList = @import("minilib").FixedArrayList;
const DoubleBufferedFixedArrayList = @import("minilib").DoubleBufferedFixedArrayList;
const DynamicThreadPool = @import("minilib").DynamicThreadPool;
const log = std.log.scoped(.aio_fallback);

// This tries to emulate io_uring functionality.
// If something does not match how it works on io_uring on linux, it should be change to match.
// While this uses readiness before performing the requests, the io_uring model is not particularily
// suited for readiness, thus don't expect this fallback to be particularily effecient.
// However it might be still more pleasant experience than (e)poll/kqueueing away as the behaviour should be
// more or less consistent.

comptime {
    if (builtin.single_threaded) {
        @compileError(
            \\Fallback backend requires building with threads as otherwise it may block the whole program.
            \\To only target linux and io_uring, set `aio_options.fallback = .disable` in your root .zig file.
        );
    }
}

pub const EventSource = posix.EventSource;

const Result = struct { failure: Operation.Error, id: u16 };

ops: ItemPool(Operation.Union, u16),
prev_id: ?u16 = null, // for linking operations
next: []u16, // linked operation, points to self if none
readiness: []posix.Readiness, // readiness fd that gets polled before we perform the operation
link_lock: std.DynamicBitSetUnmanaged, // operation is waiting for linked operation to finish first
pending: std.DynamicBitSetUnmanaged, // operation is pending on readiness fd (poll)
started: std.DynamicBitSetUnmanaged, // operation has been queued, it's being performed if pending is false
pfd: FixedArrayList(posix.pollfd, u32), // current fds that we must poll for wakeup
tpool: DynamicThreadPool, // thread pool for performing operations, not all operations will be performed here
kludge_tpool: DynamicThreadPool, // thread pool for performing operations which can't be polled for readiness
source: EventSource, // when threads finish, they signal it using this event source
finished: DoubleBufferedFixedArrayList(Result, u16), // operations that are finished, double buffered to be thread safe

pub fn isSupported(_: []const type) bool {
    return true; // very optimistic :D
}

pub fn init(allocator: std.mem.Allocator, n: u16) aio.Error!@This() {
    var ops = try ItemPool(Operation.Union, u16).init(allocator, n);
    errdefer ops.deinit(allocator);
    const next = try allocator.alloc(u16, n);
    errdefer allocator.free(next);
    const readiness = try allocator.alloc(posix.Readiness, n);
    errdefer allocator.free(readiness);
    var link_lock = try std.DynamicBitSetUnmanaged.initEmpty(allocator, n);
    errdefer link_lock.deinit(allocator);
    var pending = try std.DynamicBitSetUnmanaged.initEmpty(allocator, n);
    errdefer pending.deinit(allocator);
    var started = try std.DynamicBitSetUnmanaged.initEmpty(allocator, n);
    errdefer started.deinit(allocator);
    var pfd = try FixedArrayList(posix.pollfd, u32).init(allocator, n + 1);
    errdefer pfd.deinit(allocator);
    var tpool = DynamicThreadPool.init(allocator, .{ .max_threads = aio.options.max_threads }) catch |err| return switch (err) {
        error.TimerUnsupported => error.SystemOutdated,
        else => |e| e,
    };
    errdefer tpool.deinit();
    var kludge_tpool = DynamicThreadPool.init(allocator, .{ .max_threads = aio.options.fallback_max_kludge_threads }) catch |err| return switch (err) {
        error.TimerUnsupported => error.SystemOutdated,
        else => |e| e,
    };
    errdefer kludge_tpool.deinit();
    var source = try EventSource.init();
    errdefer source.deinit();
    var finished = try DoubleBufferedFixedArrayList(Result, u16).init(allocator, n);
    errdefer finished.deinit(allocator);
    return .{
        .ops = ops,
        .next = next,
        .readiness = readiness,
        .link_lock = link_lock,
        .pending = pending,
        .started = started,
        .pfd = pfd,
        .tpool = tpool,
        .kludge_tpool = kludge_tpool,
        .source = source,
        .finished = finished,
    };
}

pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    self.tpool.deinit();
    self.kludge_tpool.deinit();
    var iter = self.ops.iterator();
    while (iter.next()) |e| uopUnwrapCall(e.v, posix.closeReadiness, .{self.readiness[e.k]});
    self.ops.deinit(allocator);
    allocator.free(self.next);
    allocator.free(self.readiness);
    self.link_lock.deinit(allocator);
    self.pending.deinit(allocator);
    self.started.deinit(allocator);
    self.pfd.deinit(allocator);
    self.source.deinit();
    self.finished.deinit(allocator);
    self.* = undefined;
}

fn initOp(op: anytype, id: u16) void {
    if (op.out_id) |p_id| p_id.* = @enumFromInt(id);
    if (op.out_error) |out_error| out_error.* = error.Success;
}

fn addOp(self: *@This(), uop: Operation.Union, linked_to: ?u16, readiness: posix.Readiness) !u16 {
    const id = try self.ops.add(uop);
    if (linked_to) |ln| {
        self.next[ln] = id;
        self.link_lock.set(id);
    } else {
        self.link_lock.unset(id);
    }
    // to account a mistake where link is set without a next op
    self.next[id] = id;
    self.readiness[id] = readiness;
    self.started.unset(id);
    self.pending.unset(id);
    uopUnwrapCall(&self.ops.nodes[id].used, initOp, .{id});
    return id;
}

fn removeOp(self: *@This(), id: u16) void {
    uopUnwrapCall(&self.ops.nodes[id].used, posix.closeReadiness, .{self.readiness[id]});
    self.readiness[id] = .{};
    self.next[id] = id;
    self.ops.remove(id);
}

inline fn queueOperation(self: *@This(), op: anytype) aio.Error!u16 {
    const tag = @tagName(comptime Operation.tagFromPayloadType(@TypeOf(op.*)));
    const uop = @unionInit(Operation.Union, tag, op.*);
    const id = try self.addOp(uop, self.prev_id, try posix.openReadiness(op));
    debug("queue: {}: {}, {s} ({?})", .{ id, std.meta.activeTag(uop), @tagName(op.link), self.prev_id });
    if (op.link != .unlinked) self.prev_id = id else self.prev_id = null;
    return id;
}

pub fn queue(self: *@This(), comptime len: u16, work: anytype, cb: ?aio.Dynamic.QueueCallback) aio.Error!void {
    if (comptime len == 1) {
        const id = try self.queueOperation(&work.ops[0]);
        if (cb) |f| f(self.ops.nodes[id].used, @enumFromInt(id));
    } else {
        var ids: std.BoundedArray(u16, len) = .{};
        errdefer for (ids.constSlice()) |id| self.removeOp(id);
        inline for (&work.ops) |*op| ids.append(try self.queueOperation(op)) catch return error.SubmissionQueueFull;
        if (cb) |f| for (ids.constSlice()) |id| f(self.ops.nodes[id].used, @enumFromInt(id));
    }
}

pub fn complete(self: *@This(), mode: aio.Dynamic.CompletionMode, cb: ?aio.Dynamic.CompletionCallback) aio.Error!aio.CompletionResult {
    if (!try self.submit()) return .{};
    defer self.pfd.reset();

    // I was thinking if we should use epoll/kqueue if available
    // The pros is that we don't have to iterate the self.pfd.items
    // However, the self.pfd.items changes frequently so we have to keep re-registering fds anyways
    // Poll is pretty much anywhere, so poll it is. This is fallback backend anyways.
    const n = posix.poll(self.pfd.items[0..self.pfd.len], if (mode == .blocking) -1 else 0) catch |err| return switch (err) {
        error.NetworkSubsystemFailed => unreachable,
        else => |e| e,
    };
    if (n == 0) return .{};

    var res: aio.CompletionResult = .{};
    for (self.pfd.items[0..self.pfd.len]) |pfd| {
        if (pfd.revents == 0) continue;
        if (pfd.fd == self.source.fd) {
            std.debug.assert(pfd.revents & std.posix.POLL.NVAL == 0);
            std.debug.assert(pfd.revents & std.posix.POLL.ERR == 0);
            std.debug.assert(pfd.revents & std.posix.POLL.HUP == 0);
            self.source.wait();
            res = self.handleFinished(cb);
        } else {
            var iter = self.ops.iterator();
            while (iter.next()) |e| if (pfd.fd == self.readiness[e.k].fd) {
                if (pfd.revents & std.posix.POLL.ERR != 0 or pfd.revents & std.posix.POLL.HUP != 0 or pfd.revents & std.posix.POLL.NVAL != 0) {
                    self.finish(e.k, error.Unexpected);
                    continue;
                }
                // canceled
                if (!self.pending.isSet(e.k)) continue;
                // reset started bit, the operation will spawn next cycle
                self.started.unset(e.k);
            };
        }
    }

    return res;
}

pub fn immediate(comptime len: u16, work: anytype) aio.Error!u16 {
    var sfb = std.heap.stackFallback(len * 1024, std.heap.page_allocator);
    const allocator = sfb.get();
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

fn finish(self: *@This(), id: u16, failure: Operation.Error) void {
    debug("finish: {} {}", .{ id, failure });
    self.finished.add(.{ .id = id, .failure = failure }) catch unreachable;
    self.source.notify();
}

fn cancel(self: *@This(), id: u16) enum { in_progress, not_found, ok } {
    if (self.started.isSet(id) and !self.pending.isSet(id)) {
        return .in_progress;
    }
    if (self.ops.nodes[id] != .used) {
        return .not_found;
    }
    // collect the result later
    self.finish(id, error.Canceled);
    return .ok;
}

fn onThreadExecutor(self: *@This(), id: u16, uop: *Operation.Union, readiness: posix.Readiness) void {
    var failure: Operation.Error = error.Success;
    uopUnwrapCall(uop, posix.perform, .{readiness}) catch |err| {
        failure = err;
    };
    self.finish(id, failure);
}

fn start(self: *@This(), id: u16) !void {
    // previous op hasn't finished yet, or already started
    if (self.link_lock.isSet(id)) return;

    self.started.set(id);
    if (self.readiness[id].mode == .nopoll or self.readiness[id].mode == .kludge or self.pending.isSet(id)) {
        if (self.next[id] != id) {
            debug("perform: {}: {} => {}", .{ id, std.meta.activeTag(self.ops.nodes[id].used), self.next[id] });
        } else {
            debug("perform: {}: {}", .{ id, std.meta.activeTag(self.ops.nodes[id].used) });
        }
        self.pending.unset(id);
        self.link_lock.set(id); // prevent restarting
        switch (self.ops.nodes[id].used) {
            .nop => self.finish(id, error.Success),
            .cancel => |op| {
                switch (self.cancel(@intCast(@intFromEnum(op.id)))) {
                    .ok => self.finish(id, error.Success),
                    .in_progress => self.finish(id, error.InProgress),
                    .not_found => self.finish(id, error.NotFound),
                }
            },
            .timeout => self.finish(id, error.Success),
            .link_timeout => {
                var iter = self.ops.iterator();
                const res = blk: {
                    while (iter.next()) |e| {
                        if (e.k != id and self.next[e.k] == id) {
                            const res = self.cancel(e.k);
                            // invalidate child's next since we expired first
                            if (res == .ok) self.next[e.k] = e.k;
                            break :blk res;
                        }
                    }
                    break :blk .not_found;
                };
                if (res == .ok) {
                    self.finish(id, error.Expired);
                } else {
                    self.finish(id, error.Success);
                }
            },
            // can be performed here, doesn't have to be dispatched to thread
            inline .child_exit, .notify_event_source, .wait_event_source, .close_event_source => |*op| {
                var failure: Operation.Error = error.Success;
                _ = posix.perform(op, self.readiness[id]) catch |err| {
                    failure = err;
                };
                self.finish(id, failure);
            },
            else => {
                // perform on thread
                if (self.readiness[id].mode != .kludge) {
                    self.tpool.spawn(onThreadExecutor, .{ self, id, &self.ops.nodes[id].used, self.readiness[id] }) catch return error.SystemResources;
                } else {
                    self.kludge_tpool.spawn(onThreadExecutor, .{ self, id, &self.ops.nodes[id].used, self.readiness[id] }) catch return error.SystemResources;
                }
            },
        }
    } else {
        // pending for readiness, starts later
        if (self.next[id] != id) {
            debug("pending: {}: {} => {}", .{ id, std.meta.activeTag(self.ops.nodes[id].used), self.next[id] });
        } else {
            debug("pending: {}: {}", .{ id, std.meta.activeTag(self.ops.nodes[id].used) });
        }
        try uopUnwrapCall(&self.ops.nodes[id].used, posix.armReadiness, .{self.readiness[id]});
        self.pending.set(id);
    }

    // we need to start linked timeout immediately as well if there's one
    if (self.next[id] != id and self.ops.nodes[self.next[id]].used == .link_timeout) {
        self.link_lock.unset(self.next[id]);
        if (!self.started.isSet(self.next[id])) {
            try self.start(self.next[id]);
        }
    }
}

fn submit(self: *@This()) !bool {
    if (self.ops.empty()) return false;
    defer self.prev_id = null;
    self.pfd.add(.{ .fd = self.source.fd, .events = std.posix.POLL.IN, .revents = 0 }) catch unreachable;
    var iter = self.ops.iterator();
    while (iter.next()) |e| {
        if (!self.started.isSet(e.k)) {
            try self.start(e.k);
        }
        if (self.pending.isSet(e.k)) {
            std.debug.assert(self.readiness[e.k].fd != posix.invalid_fd);
            self.pfd.add(.{
                .fd = self.readiness[e.k].fd,
                .events = switch (self.readiness[e.k].mode) {
                    .nopoll, .kludge => unreachable,
                    .in => std.posix.POLL.IN,
                    .out => std.posix.POLL.OUT,
                },
                .revents = 0,
            }) catch unreachable;
        }
    }
    return true;
}

fn completition(op: anytype, self: *@This(), res: Result) void {
    if (op.out_error) |err| err.* = @errorCast(res.failure);
    if (op.link != .unlinked and self.next[res.id] != res.id) {
        if (self.ops.nodes[self.next[res.id]].used == .link_timeout) {
            switch (op.link) {
                .unlinked => unreachable,
                .soft => std.debug.assert(self.cancel(self.next[res.id]) == .ok),
                .hard => self.finish(self.next[res.id], error.Success),
            }
        } else if (res.failure != error.Success and op.link == .soft) {
            _ = self.cancel(self.next[res.id]);
        } else {
            self.link_lock.unset(self.next[res.id]);
        }
    }
}

fn handleFinished(self: *@This(), cb: ?aio.Dynamic.CompletionCallback) aio.CompletionResult {
    const finished = self.finished.swap();
    var num_errors: u16 = 0;
    for (finished) |res| {
        if (res.failure != error.Success) {
            debug("complete: {}: {} [FAIL] {}", .{ res.id, std.meta.activeTag(self.ops.nodes[res.id].used), res.failure });
        } else {
            debug("complete: {}: {} [OK]", .{ res.id, std.meta.activeTag(self.ops.nodes[res.id].used) });
        }

        if (self.ops.nodes[res.id].used == .link_timeout and res.failure == error.Canceled) {
            // special case
        } else {
            num_errors += @intFromBool(res.failure != error.Success);
        }

        uopUnwrapCall(&self.ops.nodes[res.id].used, completition, .{ self, res });

        const uop = self.ops.nodes[res.id].used;
        self.removeOp(res.id);
        if (cb) |f| f(uop, @enumFromInt(res.id), res.failure != error.Success);
    }
    return .{ .num_completed = @intCast(finished.len), .num_errors = num_errors };
}

fn uopUnwrapCall(uop: *Operation.Union, comptime func: anytype, args: anytype) @typeInfo(@TypeOf(func)).Fn.return_type.? {
    switch (uop.*) {
        inline else => |*op| return @call(.auto, func, .{op} ++ args),
    }
    unreachable;
}

fn debug(comptime fmt: []const u8, args: anytype) void {
    if (@import("builtin").is_test) {
        std.debug.print("fallback: " ++ fmt ++ "\n", args);
    } else {
        if (comptime !aio.options.debug) return;
        log.debug(fmt, args);
    }
}
