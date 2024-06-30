const builtin = @import("builtin");
const std = @import("std");
const aio = @import("../aio.zig");
const posix = @import("posix.zig");
const Operation = @import("ops.zig").Operation;
const ItemPool = @import("minilib").ItemPool;
const FixedArrayList = @import("minilib").FixedArrayList;
const DoubleBufferedFixedArrayList = @import("minilib").DoubleBufferedFixedArrayList;
const DynamicThreadPool = @import("minilib").DynamicThreadPool;
const Uringlator = @import("Uringlator.zig");
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

readiness: []posix.Readiness, // readiness fd that gets polled before we perform the operation
pfd: FixedArrayList(posix.pollfd, u32), // current fds that we must poll for wakeup
tpool: DynamicThreadPool, // thread pool for performing operations, not all operations will be performed here
kludge_tpool: DynamicThreadPool, // thread pool for performing operations which can't be polled for readiness
pending: std.DynamicBitSetUnmanaged, // operation is pending on readiness fd (poll)
uringlator: Uringlator,

pub fn isSupported(_: []const type) bool {
    return true; // very optimistic :D
}

pub fn init(allocator: std.mem.Allocator, n: u16) aio.Error!@This() {
    const readiness = try allocator.alloc(posix.Readiness, n);
    errdefer allocator.free(readiness);
    @memset(readiness, .{});
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
    var pending_set = try std.DynamicBitSetUnmanaged.initEmpty(allocator, n);
    errdefer pending_set.deinit(allocator);
    var uringlator = try Uringlator.init(allocator, n);
    errdefer uringlator.deinit(allocator);
    pfd.add(.{ .fd = uringlator.source.fd, .events = std.posix.POLL.IN, .revents = 0 }) catch unreachable;
    return .{
        .readiness = readiness,
        .pfd = pfd,
        .tpool = tpool,
        .kludge_tpool = kludge_tpool,
        .pending = pending_set,
        .uringlator = uringlator,
    };
}

pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    self.tpool.deinit();
    self.kludge_tpool.deinit();
    var iter = self.pending.iterator(.{});
    while (iter.next()) |id| {
        switch (self.uringlator.ops.nodes[id]) {
            .used => |*uop| Uringlator.uopUnwrapCall(uop, posix.closeReadiness, .{self.readiness[id]}),
            .free => {},
        }
    }
    allocator.free(self.readiness);
    self.pfd.deinit(allocator);
    self.pending.deinit(allocator);
    self.uringlator.deinit(allocator);
    self.* = undefined;
}

fn queueCallback(self: *@This(), id: u16, uop: *Operation.Union) aio.Error!void {
    self.pending.unset(id);
    self.readiness[id] = try Uringlator.uopUnwrapCall(uop, posix.openReadiness, .{});
}

pub fn queue(self: *@This(), comptime len: u16, uops: []Operation.Union, cb: ?aio.Dynamic.QueueCallback) aio.Error!void {
    try self.uringlator.queue(len, uops, cb, *@This(), self, queueCallback);
}

pub fn complete(self: *@This(), mode: aio.Dynamic.CompletionMode, cb: ?aio.Dynamic.CompletionCallback) aio.Error!aio.CompletionResult {
    if (!try self.uringlator.submit(*@This(), self, start, cancelable)) return .{};

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
        if (pfd.fd == self.uringlator.source.fd) {
            std.debug.assert(pfd.revents & std.posix.POLL.NVAL == 0);
            std.debug.assert(pfd.revents & std.posix.POLL.ERR == 0);
            std.debug.assert(pfd.revents & std.posix.POLL.HUP == 0);
            self.uringlator.source.wait();
            res = self.uringlator.complete(cb, *@This(), self, completion);
        } else {
            var iter = self.pending.iterator(.{});
            while (iter.next()) |id| if (pfd.fd == self.readiness[id].fd) {
                defer self.pending.unset(id);
                if (pfd.revents & std.posix.POLL.ERR != 0 or pfd.revents & std.posix.POLL.HUP != 0 or pfd.revents & std.posix.POLL.NVAL != 0) {
                    self.uringlator.finish(@intCast(id), error.Unexpected);
                    continue;
                }
                // start it for real this time
                const uop = &self.uringlator.ops.nodes[id].used;
                if (self.uringlator.next[id] != id) {
                    Uringlator.debug("ready: {}: {} => {}", .{ id, std.meta.activeTag(uop.*), self.uringlator.next[id] });
                } else {
                    Uringlator.debug("ready: {}: {}", .{ id, std.meta.activeTag(uop.*) });
                }
                try self.start(@intCast(id), uop);
            };
        }
    }

    return res;
}

pub fn immediate(comptime len: u16, uops: []Operation.Union) aio.Error!u16 {
    var sfb = std.heap.stackFallback(len * 1024, std.heap.page_allocator);
    const allocator = sfb.get();
    var wrk = try init(allocator, len);
    defer wrk.deinit(allocator);
    try wrk.queue(len, uops, null);
    var n: u16 = len;
    var num_errors: u16 = 0;
    while (n > 0) {
        const res = try wrk.complete(.blocking, null);
        n -= res.num_completed;
        num_errors += res.num_errors;
    }
    return num_errors;
}

fn onThreadExecutor(self: *@This(), id: u16, uop: *Operation.Union, readiness: posix.Readiness) void {
    var failure: Operation.Error = error.Success;
    Uringlator.uopUnwrapCall(uop, posix.perform, .{readiness}) catch |err| {
        failure = err;
    };
    self.uringlator.finish(id, failure);
}

fn start(self: *@This(), id: u16, uop: *Operation.Union) !void {
    if (self.readiness[id].mode == .nopoll or self.readiness[id].mode == .kludge or self.pending.isSet(id)) {
        switch (uop.*) {
            .timeout => self.uringlator.finish(id, error.Success),
            .link_timeout => self.uringlator.finishLinkTimeout(id),
            // can be performed here, doesn't have to be dispatched to thread
            inline .child_exit, .notify_event_source, .wait_event_source, .close_event_source => |*op| {
                var failure: Operation.Error = error.Success;
                _ = posix.perform(op, self.readiness[id]) catch |err| {
                    failure = err;
                };
                self.uringlator.finish(id, failure);
            },
            else => {
                // perform on thread
                if (self.readiness[id].mode != .kludge) {
                    self.tpool.spawn(onThreadExecutor, .{ self, id, uop, self.readiness[id] }) catch return error.SystemResources;
                } else {
                    self.kludge_tpool.spawn(onThreadExecutor, .{ self, id, uop, self.readiness[id] }) catch return error.SystemResources;
                }
            },
        }
    } else {
        // pending for readiness, perform the operation later
        if (self.uringlator.next[id] != id) {
            Uringlator.debug("pending: {}: {} => {}", .{ id, std.meta.activeTag(uop.*), self.uringlator.next[id] });
        } else {
            Uringlator.debug("pending: {}: {}", .{ id, std.meta.activeTag(uop.*) });
        }
        std.debug.assert(self.readiness[id].fd != posix.invalid_fd);
        try Uringlator.uopUnwrapCall(uop, posix.armReadiness, .{self.readiness[id]});
        self.pfd.add(.{
            .fd = self.readiness[id].fd,
            .events = switch (self.readiness[id].mode) {
                .nopoll, .kludge => unreachable,
                .in => std.posix.POLL.IN,
                .out => std.posix.POLL.OUT,
            },
            .revents = 0,
        }) catch unreachable;
        self.pending.set(id);
    }
}

fn cancelable(self: *@This(), id: u16, _: *Operation.Union) bool {
    return self.pending.isSet(id);
}

fn completion(self: *@This(), id: u16, uop: *Operation.Union) void {
    if (self.readiness[id].fd != posix.invalid_fd) {
        for (self.pfd.items[0..self.pfd.len], 0..) |pfd, idx| {
            if (pfd.fd == self.readiness[id].fd) {
                self.pfd.swapRemove(@truncate(idx));
                break;
            }
        }
        Uringlator.uopUnwrapCall(uop, posix.closeReadiness, .{self.readiness[id]});
        self.pending.unset(id);
        self.readiness[id] = .{};
    }
}
