//! Mimics linux's timerfd timers
//! Used on platforms where native timers aren't accurate enough or have other limitations
//! Requires threading support

const builtin = @import("builtin");
const std = @import("std");

const root = @import("root");
pub const options: Options = if (@hasDecl(root, "timer_queue_options")) root.timer_queue_options else .{};

pub const Options = struct {
    /// Force the use of foreign backend even if the target platform is linux
    /// Mostly useful for testing
    force_foreign_backend: bool = false,
};

pub const Closure = struct {
    pub const Callback = *const fn (context: *anyopaque, user_data: usize) void;
    context: *anyopaque,
    callback: Callback,
};

pub const Clock = enum {
    monotonic,
    boottime,
    realtime,
};

pub const TimeoutOptions = struct {
    // repeats?
    repeat: ?u32 = null,
    // absolute value?
    abs: bool = false,
    // callback
    closure: Closure,
};

const Timeout = struct {
    ns: u128,
    start: u128,
    opts: TimeoutOptions,
    user_data: usize,

    pub fn sort(_: void, a: @This(), b: @This()) std.math.Order {
        return std.math.order(a.ns, b.ns);
    }
};

/// The 3 queues share lots of similarities, so use a mixin
fn Mixin(T: type) type {
    return struct {
        pub fn init(allocator: std.mem.Allocator) !T {
            _ = try T.now(); // check that we can get time
            return .{ .queue = std.PriorityQueue(Timeout, void, Timeout.sort).init(allocator, {}) };
        }

        pub fn deinit(self: *T) void {
            if (self.thread) |thrd| {
                {
                    self.mutex.lock();
                    defer self.mutex.unlock();
                    while (self.queue.removeOrNull()) |_| {}
                    self.thread = null; // to prevent thread from detaching
                }
                self.cond.broadcast();
                thrd.join();
            }
            self.queue.deinit();
            self.* = undefined;
        }

        pub fn schedule(self: *T, timeout: Timeout) !void {
            {
                self.mutex.lock();
                defer self.mutex.unlock();
                try self.queue.add(timeout);
            }
            self.cond.broadcast();
            {
                self.mutex.lock();
                defer self.mutex.unlock();
                if (self.thread == null) try self.start();
            }
        }

        fn start(self: *T) !void {
            @setCold(true);
            if (self.thread) |_| unreachable;
            self.thread = try std.Thread.spawn(.{ .allocator = self.queue.allocator }, T.threadMain, .{self});
        }

        pub fn disarm(self: *T, user_data: usize) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            for (self.queue.items, 0..) |*to, idx| {
                if (to.user_data != user_data) continue;
                _ = self.queue.removeIndex(idx);
                break;
            }
        }
    };
}

/// Monotonic timers by linux definition do not count the suspend time
/// This is the simplest one to implement, as we don't have to register suspend callbacks from the OS
const MonotonicQueue = struct {
    thread: ?std.Thread = null,
    queue: std.PriorityQueue(Timeout, void, Timeout.sort),
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    usingnamespace Mixin(@This());

    pub fn now() !u128 {
        const clock_id = switch (builtin.os.tag) {
            .windows => {
                // TODO: make this equivalent to linux MONOTONIC
                // <https://stackoverflow.com/questions/24330496/how-do-i-create-monotonic-clock-on-windows-which-doesnt-tick-during-suspend>
                const qpc = std.os.windows.QueryPerformanceCounter();
                const qpf = std.os.windows.QueryPerformanceFrequency();

                // 10Mhz (1 qpc tick every 100ns) is a common enough QPF value that we can optimize on it.
                // https://github.com/microsoft/STL/blob/785143a0c73f030238ef618890fd4d6ae2b3a3a0/stl/inc/chrono#L694-L701
                const common_qpf = 10_000_000;
                if (qpf == common_qpf) {
                    return qpc * (std.time.ns_per_s / common_qpf);
                }

                // Convert to ns using fixed point.
                const scale = @as(u64, std.time.ns_per_s << 32) / @as(u32, @intCast(qpf));
                const result = (@as(u96, qpc) * scale) >> 32;
                return result;
            },
            .wasi => {
                var ns: std.os.wasi.timestamp_t = undefined;
                const rc = std.os.wasi.clock_time_get(.MONOTONIC, 1, &ns);
                if (rc != .SUCCESS) return error.Unsupported;
                return ns;
            },
            .macos, .ios, .tvos, .watchos, .visionos => std.posix.CLOCK.MONOTONIC_RAW,
            .linux => std.posix.CLOCK.MONOTONIC,
            .uefi => @panic("unsupported"),
            else => std.posix.CLOCK.BOOTTIME,
        };
        var ts: std.posix.timespec = undefined;
        std.posix.clock_gettime(clock_id, &ts) catch return error.Unsupported;
        return @abs((@as(i128, ts.tv_sec) * std.time.ns_per_s) + ts.tv_nsec);
    }

    fn threadMain(self: *@This()) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.thread.?.setName("MonotonicQueue") catch {};

        while (self.queue.peek()) |timeout| {
            {
                const rn = now() catch unreachable;
                if (rn < timeout.start + timeout.ns) {
                    self.cond.timedWait(&self.mutex, @truncate(timeout.start + timeout.ns - rn)) catch {};
                }
            }
            const rn = now() catch unreachable;
            while (self.queue.peek()) |to| {
                if (rn >= to.start + to.ns) {
                    to.opts.closure.callback(to.opts.closure.context, to.user_data);
                    _ = self.queue.removeOrNull();
                } else break; // all other timeouts are later
            }
        }

        if (self.thread) |thrd| {
            thrd.detach();
            self.thread = null;
        }
    }
};

/// Similar to monotonic queue but needs to be woken up when PC wakes up from suspend
/// and check if any timers got expired
const BoottimeQueue = struct {
    thread: ?std.Thread = null,
    queue: std.PriorityQueue(Timeout, void, Timeout.sort),
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    usingnamespace Mixin(@This());

    pub fn now() !u128 {
        const clock_id = switch (builtin.os.tag) {
            .windows => {
                const qpc = std.os.windows.QueryPerformanceCounter();
                const qpf = std.os.windows.QueryPerformanceFrequency();

                // 10Mhz (1 qpc tick every 100ns) is a common enough QPF value that we can optimize on it.
                // https://github.com/microsoft/STL/blob/785143a0c73f030238ef618890fd4d6ae2b3a3a0/stl/inc/chrono#L694-L701
                const common_qpf = 10_000_000;
                if (qpf == common_qpf) {
                    return qpc * (std.time.ns_per_s / common_qpf);
                }

                // Convert to ns using fixed point.
                const scale = @as(u64, std.time.ns_per_s << 32) / @as(u32, @intCast(qpf));
                const result = (@as(u96, qpc) * scale) >> 32;
                return result;
            },
            .wasi => {
                var ns: std.os.wasi.timestamp_t = undefined;
                const rc = std.os.wasi.clock_time_get(.MONOTONIC, 1, &ns);
                if (rc != .SUCCESS) return error.Unsupported;
                return ns;
            },
            .macos, .ios, .tvos, .watchos, .visionos => std.posix.CLOCK.UPTIME_RAW,
            .linux => std.posix.CLOCK.BOOTTIME,
            .uefi => @panic("unsupported"),
            else => std.posix.CLOCK.MONOTONIC,
        };
        var ts: std.posix.timespec = undefined;
        std.posix.clock_gettime(clock_id, &ts) catch return error.Unsupported;
        return @abs((@as(i128, ts.tv_sec) * std.time.ns_per_s) + ts.tv_nsec);
    }

    fn threadMain(self: *@This()) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.thread.?.setName("BoottimeQueue") catch {};

        while (self.queue.peek()) |timeout| {
            // TODO: wakeup if coming out from suspend
            {
                const rn = now() catch unreachable;
                if (rn < timeout.start + timeout.ns) {
                    self.cond.timedWait(&self.mutex, @truncate(timeout.start + timeout.ns - rn)) catch {};
                }
            }
            const rn = now() catch unreachable;
            while (self.queue.peek()) |to| {
                if (rn >= to.start + to.ns) {
                    to.opts.closure.callback(to.opts.closure.context, to.user_data);
                    _ = self.queue.removeOrNull();
                } else break; // all other timeouts are later
            }
        }

        if (self.thread) |thrd| {
            thrd.detach();
            self.thread = null;
        }
    }
};

/// Checks every second whether any timers has been expired.
/// Not great accuracy, and every second lets us do implementation without much facilities needed from the OS.
const RealtimeQueue = struct {
    thread: ?std.Thread = null,
    queue: std.PriorityQueue(Timeout, void, Timeout.sort),
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    usingnamespace Mixin(@This());

    pub fn now() !u128 {
        return @abs(std.time.nanoTimestamp());
    }

    fn threadMain(self: *@This()) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.thread.?.setName("RealtimeQueue") catch {};

        while (self.queue.peek()) |_| {
            self.cond.timedWait(&self.mutex, std.time.ns_per_s) catch {};
            const rn = now() catch unreachable;
            while (self.queue.peek()) |to| {
                if (rn >= to.start + to.ns) {
                    to.opts.closure.callback(to.opts.closure.context, to.user_data);
                    _ = self.queue.removeOrNull();
                } else break; // all other timeouts are later
            }
        }

        if (self.thread) |thrd| {
            thrd.detach();
            self.thread = null;
        }
    }
};

const ForeignTimerQueue = struct {
    mq: MonotonicQueue,
    bq: BoottimeQueue,
    rq: RealtimeQueue,

    pub fn init(allocator: std.mem.Allocator) !@This() {
        return .{
            .mq = try MonotonicQueue.init(allocator),
            .bq = try BoottimeQueue.init(allocator),
            .rq = try RealtimeQueue.init(allocator),
        };
    }

    pub fn deinit(self: *@This()) void {
        self.mq.deinit();
        self.bq.deinit();
        self.rq.deinit();
        self.* = undefined;
    }

    pub fn schedule(self: *@This(), clock: Clock, ns: u128, user_data: usize, opts: TimeoutOptions) !void {
        if (opts.repeat != null and opts.abs) unreachable; // repeats can't be used with abs
        try switch (clock) {
            .monotonic => self.mq.schedule(.{ .ns = ns, .start = if (!opts.abs) MonotonicQueue.now() catch unreachable else 0, .opts = opts, .user_data = user_data }),
            .boottime => self.bq.schedule(.{ .ns = ns, .start = if (!opts.abs) BoottimeQueue.now() catch unreachable else 0, .opts = opts, .user_data = user_data }),
            .realtime => self.rq.schedule(.{ .ns = ns, .start = if (!opts.abs) RealtimeQueue.now() catch unreachable else 0, .opts = opts, .user_data = user_data }),
        };
    }

    pub fn disarm(self: *@This(), clock: Clock, user_data: usize) void {
        switch (clock) {
            .monotonic => self.mq.disarm(user_data),
            .boottime => self.bq.disarm(user_data),
            .realtime => self.rq.disarm(user_data),
        }
    }
};

const LinuxTimerQueue = struct {
    const Context = struct {
        fd: std.posix.fd_t,
        repeat: ?u32,
        closure: Closure,
    };

    allocator: std.mem.Allocator,
    fds: std.AutoHashMapUnmanaged(usize, Context) = .{},
    efd: std.posix.fd_t,
    epoll: std.posix.fd_t,
    mutex: std.Thread.Mutex = .{},
    thread: ?std.Thread = null,

    pub fn init(allocator: std.mem.Allocator) !@This() {
        const epoll = try std.posix.epoll_create1(std.os.linux.EPOLL.CLOEXEC);
        errdefer std.posix.close(epoll);
        const efd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
        errdefer std.posix.close(efd);
        var ev: std.os.linux.epoll_event = .{ .data = .{ .ptr = 0xDEADBEEF }, .events = std.os.linux.EPOLL.IN };
        std.posix.epoll_ctl(epoll, std.os.linux.EPOLL.CTL_ADD, efd, &ev) catch |err| return switch (err) {
            error.FileDescriptorAlreadyPresentInSet => unreachable,
            error.OperationCausesCircularLoop => unreachable,
            error.FileDescriptorNotRegistered => unreachable,
            error.FileDescriptorIncompatibleWithEpoll => unreachable,
            else => |e| e,
        };
        return .{
            .allocator = allocator,
            .efd = efd,
            .epoll = epoll,
        };
    }

    pub fn deinit(self: *@This()) void {
        _ = std.posix.write(self.efd, &std.mem.toBytes(@as(u64, 1))) catch unreachable;
        if (self.thread) |thrd| thrd.join();
        std.posix.close(self.epoll);
        var iter = self.fds.iterator();
        while (iter.next()) |e| std.posix.close(e.value_ptr.fd);
        self.fds.deinit(self.allocator);
        std.posix.close(self.efd);
        self.* = undefined;
    }

    pub fn schedule(self: *@This(), clock: Clock, ns: u128, user_data: usize, opts: TimeoutOptions) !void {
        if (opts.repeat != null and opts.abs) unreachable; // repeats can't be used with abs
        const fd = switch (clock) {
            .monotonic => std.posix.timerfd_create(std.posix.CLOCK.MONOTONIC, .{ .CLOEXEC = true, .NONBLOCK = true }),
            .boottime => std.posix.timerfd_create(std.posix.CLOCK.BOOTTIME, .{ .CLOEXEC = true, .NONBLOCK = true }),
            .realtime => std.posix.timerfd_create(std.posix.CLOCK.REALTIME, .{ .CLOEXEC = true, .NONBLOCK = true }),
        } catch |err| return switch (err) {
            error.AccessDenied => unreachable,
            else => |e| e,
        };
        errdefer std.posix.close(fd);
        const ts: std.os.linux.itimerspec = .{
            .it_value = .{
                .tv_sec = @intCast(ns / std.time.ns_per_s),
                .tv_nsec = @intCast(ns % std.time.ns_per_s),
            },
            .it_interval = .{ .tv_sec = 0, .tv_nsec = 0 },
        };
        std.posix.timerfd_settime(fd, .{ .ABSTIME = opts.abs }, &ts, null) catch |err| return switch (err) {
            error.Canceled, error.InvalidHandle => unreachable,
            error.Unexpected => |e| e,
        };
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.fds.putNoClobber(self.allocator, user_data, .{ .fd = fd, .repeat = opts.repeat, .closure = opts.closure });
        errdefer _ = self.fds.remove(user_data);
        var ev: std.os.linux.epoll_event = .{ .data = .{ .ptr = user_data }, .events = std.os.linux.EPOLL.IN };
        std.posix.epoll_ctl(self.epoll, std.os.linux.EPOLL.CTL_ADD, fd, &ev) catch |err| return switch (err) {
            error.FileDescriptorAlreadyPresentInSet => unreachable,
            error.OperationCausesCircularLoop => unreachable,
            error.FileDescriptorNotRegistered => unreachable,
            error.FileDescriptorIncompatibleWithEpoll => unreachable,
            else => |e| e,
        };
        if (self.thread == null) try self.start();
    }

    fn disarmInternal(self: *@This(), _: Clock, user_data: usize, lock: bool) void {
        if (lock) self.mutex.lock();
        defer if (lock) self.mutex.unlock();
        if (self.fds.fetchRemove(user_data)) |e| {
            var ev: std.os.linux.epoll_event = .{ .data = .{ .ptr = user_data }, .events = std.os.linux.EPOLL.IN };
            std.posix.epoll_ctl(self.epoll, std.os.linux.EPOLL.CTL_DEL, e.value.fd, &ev) catch unreachable;
            std.posix.close(e.value.fd);
        }
    }

    pub fn disarm(self: *@This(), _: Clock, user_data: usize) void {
        self.disarmInternal(undefined, user_data, true);
    }

    fn start(self: *@This()) !void {
        @setCold(true);
        if (self.thread) |_| unreachable;
        self.thread = try std.Thread.spawn(.{ .allocator = self.allocator }, threadMain, .{self});
    }

    fn threadMain(self: *@This()) void {
        self.thread.?.setName("TimerQueue Thread") catch {};
        outer: while (true) {
            var events: [32]std.os.linux.epoll_event = undefined;
            const n = std.posix.epoll_wait(self.epoll, &events, -1);
            for (events[0..n]) |ev| {
                if (ev.data.ptr == 0xDEADBEEF) {
                    // quit signal
                    break :outer;
                }
                self.mutex.lock();
                defer self.mutex.unlock();
                if (self.fds.get(ev.data.ptr)) |v| {
                    var exp: usize = undefined;
                    std.debug.assert(std.posix.read(v.fd, std.mem.asBytes(&exp)) catch unreachable == @sizeOf(usize));
                    if (v.repeat == null or v.repeat.? <= exp) {
                        v.closure.callback(v.closure.context, ev.data.ptr);
                        self.disarmInternal(undefined, ev.data.ptr, false);
                    }
                }
            }
        }
    }
};

const NativeTimerQueue = switch (builtin.target.os.tag) {
    .linux => if (options.force_foreign_backend) ForeignTimerQueue else LinuxTimerQueue,
    else => ForeignTimerQueue,
};

impl: NativeTimerQueue,

pub fn init(allocator: std.mem.Allocator) !@This() {
    return .{ .impl = try NativeTimerQueue.init(allocator) };
}

pub fn deinit(self: *@This()) void {
    self.impl.deinit();
    self.* = undefined;
}

pub fn schedule(self: *@This(), clock: Clock, ns: u128, user_data: usize, opts: TimeoutOptions) !void {
    return self.impl.schedule(clock, ns, user_data, opts);
}

pub fn disarm(self: *@This(), clock: Clock, user_data: usize) void {
    return self.impl.disarm(clock, user_data);
}
