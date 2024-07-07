//! Mimics linux's io_uring timeouts
//! Used on platforms where native timers aren't accurate enough or have other limitations
//! Requires threading support

const builtin = @import("builtin");
const std = @import("std");
const build_options = @import("build_options");

const root = @import("root");
pub const options: Options = if (@hasDecl(root, "timer_queue_options")) root.timer_queue_options else .{};

pub const Options = struct {
    /// Force the use of foreign backend even if the target platform is linux
    /// Mostly useful for testing
    force_foreign_backend: bool = build_options.force_foreign_timer_queue,
};

comptime {
    if (builtin.single_threaded) {
        @compileError("TimerQueue requires threads to support all the platforms.");
    }
}

pub const Clock = enum {
    monotonic,
    boottime,
    realtime,
};

pub const Closure = struct {
    pub const Callback = *const fn (context: *anyopaque, user_data: usize) void;
    context: *anyopaque,
    callback: Callback,
};

pub const TimeoutOptions = struct {
    /// 0 == repeats forever
    expirations: u16 = 1,
    /// Is the time absolute?
    absolute: bool = false,
    /// Callback when the timer expires
    closure: Closure,
};

const ForeignTimeout = struct {
    ns_abs: u128,
    // used only if repeats, otherwise 0
    // absolute times can't repeat
    ns_interval: u64,
    expirations: u16,
    closure: Closure,
    user_data: usize,

    pub fn sort(_: void, a: @This(), b: @This()) std.math.Order {
        return std.math.order(a.ns_abs, b.ns_abs);
    }
};

/// The 3 queues share lots of similarities, so use a mixin
fn Mixin(T: type) type {
    return struct {
        pub fn init(allocator: std.mem.Allocator) !T {
            _ = try T.now(); // check that we can get time
            return .{ .queue = std.PriorityQueue(ForeignTimeout, void, ForeignTimeout.sort).init(allocator, {}) };
        }

        pub fn deinit(self: *T) void {
            self.mutex.lock();
            if (self.thread) |thrd| {
                while (self.queue.removeOrNull()) |_| {}
                self.thread = null; // to prevent thread from detaching
                self.mutex.unlock();
                self.cond.broadcast();
                thrd.join();
            } else self.mutex.unlock();
            self.queue.deinit();
            self.* = undefined;
        }

        pub fn schedule(self: *T, timeout: ForeignTimeout) !void {
            {
                self.mutex.lock();
                defer self.mutex.unlock();
                try self.queue.add(timeout);
            }
            self.cond.broadcast();
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.thread == null) try self.start();
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

        fn start(self: *T) !void {
            @setCold(true);
            if (self.thread) |_| unreachable;
            self.thread = try std.Thread.spawn(.{ .allocator = self.queue.allocator, .stack_size = 1024 * 8 }, T.threadMain, .{self});
            self.thread.?.setName(T.Name) catch {};
        }

        fn threadMain(self: *T) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.onThreadSleepLoop();
            if (self.thread) |thrd| {
                thrd.detach();
                self.thread = null;
            }
        }

        fn onThreadProcessExpired(self: *T) void {
            const ns_now = T.now() catch unreachable;
            while (self.queue.items.len > 0) {
                var to = &self.queue.items[0];
                if (ns_now >= to.ns_abs) {
                    // copy the expired in case we remove it
                    // this allows callbacks to disarm the timer without side effects
                    const expired: ForeignTimeout = blk: {
                        if (to.expirations == 1) break :blk self.queue.removeOrNull().?;
                        // the timer repats and needs to be rearmed
                        to.expirations -|= 1;
                        to.ns_abs = ns_now + to.ns_interval;
                        break :blk to.*;
                    };
                    self.mutex.unlock();
                    defer self.mutex.lock();
                    expired.closure.callback(expired.closure.context, expired.user_data);
                } else break; // all other timeouts are later
            }
        }
    };
}

/// Monotonic timers by linux definition do not count the suspend time
/// This is the simplest one to implement, as we don't have to register suspend callbacks from the OS
const MonotonicQueue = struct {
    pub const Name = "MonotonicQueue";
    thread: ?std.Thread = null,
    queue: std.PriorityQueue(ForeignTimeout, void, ForeignTimeout.sort),
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
            .uefi => {
                var value: std.os.uefi.Time = undefined;
                std.debug.assert(std.os.uefi.system_table.runtime_services.getTime(&value, null) == .Success);
                return value.toEpoch();
            },
            .wasi => {
                var ns: std.os.wasi.timestamp_t = undefined;
                const rc = std.os.wasi.clock_time_get(.MONOTONIC, 1, &ns);
                if (rc != .SUCCESS) return error.Unsupported;
                return ns;
            },
            .macos, .ios, .tvos, .watchos, .visionos => std.posix.CLOCK.UPTIME_RAW,
            .linux => std.posix.CLOCK.MONOTONIC,
            else => std.posix.CLOCK.BOOTTIME,
        };
        var ts: std.posix.timespec = undefined;
        std.posix.clock_gettime(clock_id, &ts) catch return error.Unsupported;
        return (@as(u128, @intCast(ts.tv_sec)) * std.time.ns_per_s) + @as(u128, @intCast(ts.tv_nsec));
    }

    fn onThreadSleepLoop(self: *@This()) void {
        while (self.queue.peek()) |timeout| {
            const ns_now = now() catch unreachable;
            if (ns_now < timeout.ns_abs) self.cond.timedWait(&self.mutex, @truncate(timeout.ns_abs - ns_now)) catch {};
            self.onThreadProcessExpired();
        }
    }
};

/// Similar to monotonic queue but needs to be woken up when PC wakes up from suspend
/// and check if any timers got expired
const BoottimeQueue = struct {
    pub const Name = "BoottimeQueue";
    thread: ?std.Thread = null,
    queue: std.PriorityQueue(ForeignTimeout, void, ForeignTimeout.sort),
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
            .uefi => {
                var value: std.os.uefi.Time = undefined;
                std.debug.assert(std.os.uefi.system_table.runtime_services.getTime(&value, null) == .Success);
                return value.toEpoch();
            },
            .wasi => {
                var ns: std.os.wasi.timestamp_t = undefined;
                const rc = std.os.wasi.clock_time_get(.MONOTONIC, 1, &ns);
                if (rc != .SUCCESS) return error.Unsupported;
                return ns;
            },
            .macos, .ios, .tvos, .watchos, .visionos => std.posix.CLOCK.MONOTONIC_RAW,
            .linux => std.posix.CLOCK.BOOTTIME,
            else => std.posix.CLOCK.MONOTONIC,
        };
        var ts: std.posix.timespec = undefined;
        std.posix.clock_gettime(clock_id, &ts) catch return error.Unsupported;
        return (@as(u128, @intCast(ts.tv_sec)) * std.time.ns_per_s) + @as(u128, @intCast(ts.tv_nsec));
    }

    fn onThreadSleepLoop(self: *@This()) void {
        while (self.queue.peek()) |timeout| {
            // TODO: wakeup if coming out from suspend
            const ns_now = now() catch unreachable;
            if (ns_now < timeout.ns_abs) self.cond.timedWait(&self.mutex, @truncate(timeout.ns_abs - ns_now)) catch {};
            self.onThreadProcessExpired();
        }
    }
};

/// Checks every second whether any timers has been expired.
/// Not great accuracy but every second lets us do the implementation without needing any facilities from the OS.
const RealtimeQueue = struct {
    pub const Name = "RealtimeQueue";
    thread: ?std.Thread = null,
    queue: std.PriorityQueue(ForeignTimeout, void, ForeignTimeout.sort),
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    usingnamespace Mixin(@This());

    pub fn now() !u128 {
        switch (builtin.os.tag) {
            .windows => {
                // FileTime has a granularity of 100 nanoseconds and uses the NTFS/Windows epoch,
                // which is 1601-01-01.
                const epoch_adj = std.time.epoch.windows * (std.time.ns_per_s / 100);
                var ft: std.os.windows.FILETIME = undefined;
                std.os.windows.kernel32.GetSystemTimeAsFileTime(&ft);
                const ft64 = (@as(u64, ft.dwHighDateTime) << 32) | ft.dwLowDateTime;
                const adjusted = @as(i64, @bitCast(ft64)) + epoch_adj;
                std.debug.assert(adjusted > 0);
                return @as(u128, @intCast(adjusted)) * 100;
            },
            .wasi => {
                var ns: std.os.wasi.timestamp_t = undefined;
                std.debug.assert(std.os.wasi.clock_time_get(.REALTIME, 1, &ns) == .SUCCESS);
                return ns;
            },
            .uefi => {
                var value: std.os.uefi.Time = undefined;
                std.debug.assert(std.os.uefi.system_table.runtime_services.getTime(&value, null) == .Success);
                return value.toEpoch();
            },
            else => {
                var ts: std.posix.timespec = undefined;
                std.posix.clock_gettime(std.posix.CLOCK.REALTIME, &ts) catch return error.Unsupported;
                return (@as(u128, @intCast(ts.tv_sec)) * std.time.ns_per_s) + @as(u128, @intCast(ts.tv_nsec));
            },
        }
    }

    fn onThreadSleepLoop(self: *@This()) void {
        while (self.queue.peek()) |_| {
            self.cond.timedWait(&self.mutex, std.time.ns_per_s) catch {};
            self.onThreadProcessExpired();
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
        if (opts.expirations != 0 and opts.absolute) unreachable; // expirations must be 1 with absolute time
        try switch (clock) {
            .monotonic => self.mq.schedule(.{
                .ns_abs = if (!opts.absolute) (MonotonicQueue.now() catch unreachable) + ns else ns,
                .ns_interval = if (!opts.absolute) @intCast(ns) else 0,
                .expirations = opts.expirations,
                .closure = opts.closure,
                .user_data = user_data,
            }),
            .boottime => self.bq.schedule(.{
                .ns_abs = if (!opts.absolute) (BoottimeQueue.now() catch unreachable) + ns else ns,
                .ns_interval = if (!opts.absolute) @intCast(ns) else 0,
                .expirations = opts.expirations,
                .closure = opts.closure,
                .user_data = user_data,
            }),
            .realtime => self.rq.schedule(.{
                .ns_abs = if (!opts.absolute) (RealtimeQueue.now() catch unreachable) + ns else ns,
                .ns_interval = if (!opts.absolute) @intCast(ns) else 0,
                .expirations = opts.expirations,
                .closure = opts.closure,
                .user_data = user_data,
            }),
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
    const LinuxTimeout = struct {
        fd: std.posix.fd_t,
        expirations: u16,
        closure: Closure,
    };

    allocator: std.mem.Allocator,
    fds: std.AutoHashMapUnmanaged(usize, LinuxTimeout) = .{},
    efd: std.posix.fd_t,
    epoll: std.posix.fd_t,
    mutex: std.Thread.Mutex = .{},
    thread: ?std.Thread = null,
    exiting: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(allocator: std.mem.Allocator) !@This() {
        const epoll = try std.posix.epoll_create1(std.os.linux.EPOLL.CLOEXEC);
        errdefer std.posix.close(epoll);
        const efd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
        errdefer std.posix.close(efd);
        var ev: std.os.linux.epoll_event = .{ .data = .{ .ptr = std.math.maxInt(usize) }, .events = std.os.linux.EPOLL.IN };
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
        self.exiting.store(true, .release);
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
        if (opts.expirations != 0 and opts.absolute) unreachable; // expirations must be 1 with absolute time
        const fd = switch (clock) {
            .monotonic => std.posix.timerfd_create(std.posix.CLOCK.MONOTONIC, .{ .CLOEXEC = true, .NONBLOCK = true }),
            .boottime => std.posix.timerfd_create(std.posix.CLOCK.BOOTTIME, .{ .CLOEXEC = true, .NONBLOCK = true }),
            .realtime => std.posix.timerfd_create(std.posix.CLOCK.REALTIME, .{ .CLOEXEC = true, .NONBLOCK = true }),
        } catch |err| return switch (err) {
            error.AccessDenied => unreachable,
            else => |e| e,
        };
        errdefer std.posix.close(fd);
        const interval: std.os.linux.timespec = .{
            .tv_sec = @intCast(ns / std.time.ns_per_s),
            .tv_nsec = @intCast(ns % std.time.ns_per_s),
        };
        const ts: std.os.linux.itimerspec = .{
            .it_value = interval,
            .it_interval = if (opts.expirations != 1) interval else .{ .tv_sec = 0, .tv_nsec = 0 },
        };
        std.posix.timerfd_settime(fd, .{ .ABSTIME = opts.absolute }, &ts, null) catch |err| return switch (err) {
            error.Canceled, error.InvalidHandle => unreachable,
            error.Unexpected => |e| e,
        };
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.fds.putNoClobber(self.allocator, user_data, .{
            .fd = fd,
            .expirations = opts.expirations,
            .closure = opts.closure,
        });
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
        self.thread = try std.Thread.spawn(.{ .allocator = self.allocator, .stack_size = 1024 * 8 }, threadMain, .{self});
        self.thread.?.setName("TimerQueue Thread") catch {};
    }

    fn threadMain(self: *@This()) void {
        outer: while (true) {
            var events: [32]std.os.linux.epoll_event = undefined;
            const n = std.posix.epoll_wait(self.epoll, &events, -1);
            for (events[0..n]) |ev| {
                if (self.exiting.load(.acquire) and ev.data.ptr == std.math.maxInt(usize)) {
                    // quit signal
                    break :outer;
                }
                self.mutex.lock();
                defer self.mutex.unlock();
                if (self.fds.getPtr(ev.data.ptr)) |v| {
                    const expired: LinuxTimeout = blk: {
                        const expired = v.*;
                        if (v.expirations == 1) {
                            self.disarmInternal(undefined, ev.data.ptr, false);
                        } else {
                            v.expirations -|= 1;
                            var trash: usize = undefined;
                            std.debug.assert(std.posix.read(v.fd, std.mem.asBytes(&trash)) catch unreachable == @sizeOf(usize));
                        }
                        break :blk expired;
                    };
                    self.mutex.unlock();
                    defer self.mutex.lock();
                    expired.closure.callback(expired.closure.context, ev.data.ptr);
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

pub const InitError = error{
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    UserResourceLimitReached,
    Unsupported,
    Unexpected,
};

pub fn init(allocator: std.mem.Allocator) InitError!@This() {
    return .{ .impl = try NativeTimerQueue.init(allocator) };
}

pub fn deinit(self: *@This()) void {
    self.impl.deinit();
    self.* = undefined;
}

pub const ScheduleError = error{
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    UserResourceLimitReached,
    NoDevice,
} || std.Thread.SpawnError;

pub fn schedule(self: *@This(), clock: Clock, ns: u128, user_data: usize, opts: TimeoutOptions) ScheduleError!void {
    return self.impl.schedule(clock, ns, user_data, opts);
}

pub fn disarm(self: *@This(), clock: Clock, user_data: usize) void {
    return self.impl.disarm(clock, user_data);
}
