//! Mimics linux's io_uring timeouts
//! Used on platforms where native timers aren't accurate enough or have other limitations

const builtin = @import("builtin");
const std = @import("std");

const clockid_t = switch (builtin.target.os.tag) {
    .linux, .emscripten => enum(u32) {
        REALTIME = 0,
        MONOTONIC = 1,
        PROCESS_CPUTIME_ID = 2,
        THREAD_CPUTIME_ID = 3,
        MONOTONIC_RAW = 4,
        REALTIME_COARSE = 5,
        MONOTONIC_COARSE = 6,
        BOOTTIME = 7,
        REALTIME_ALARM = 8,
        BOOTTIME_ALARM = 9,
        _,
    },
    .wasi => std.os.wasi.clockid_t,
    .macos, .ios, .tvos, .watchos, .visionos => enum(u32) {
        REALTIME = 0,
        MONOTONIC = 6,
        MONOTONIC_RAW = 4,
        MONOTONIC_RAW_APPROX = 5,
        UPTIME_RAW = 8,
        UPTIME_RAW_APPROX = 9,
        PROCESS_CPUTIME_ID = 12,
        THREAD_CPUTIME_ID = 16,
        _,
    },
    .haiku => enum(i32) {
        /// system-wide monotonic clock (aka system time)
        MONOTONIC = 0,
        /// system-wide real time clock
        REALTIME = -1,
        /// clock measuring the used CPU time of the current process
        PROCESS_CPUTIME_ID = -2,
        /// clock measuring the used CPU time of the current thread
        THREAD_CPUTIME_ID = -3,
    },
    .freebsd => enum(u32) {
        REALTIME = 0,
        VIRTUAL = 1,
        PROF = 2,
        MONOTONIC = 4,
        UPTIME = 5,
        UPTIME_PRECISE = 7,
        UPTIME_FAST = 8,
        REALTIME_PRECISE = 9,
        REALTIME_FAST = 10,
        MONOTONIC_PRECISE = 11,
        MONOTONIC_FAST = 12,
        SECOND = 13,
        THREAD_CPUTIME_ID = 14,
        PROCESS_CPUTIME_ID = 15,
    },
    .solaris, .illumos => enum(u32) {
        VIRTUAL = 1,
        THREAD_CPUTIME_ID = 2,
        REALTIME = 3,
        MONOTONIC = 4,
        PROCESS_CPUTIME_ID = 5,
    },
    .netbsd => enum(u32) {
        REALTIME = 0,
        VIRTUAL = 1,
        PROF = 2,
        MONOTONIC = 3,
        THREAD_CPUTIME_ID = 0x20000000,
        PROCESS_CPUTIME_ID = 0x40000000,
    },
    .dragonfly => enum(u32) {
        REALTIME = 0,
        VIRTUAL = 1,
        PROF = 2,
        MONOTONIC = 4,
        UPTIME = 5,
        UPTIME_PRECISE = 7,
        UPTIME_FAST = 8,
        REALTIME_PRECISE = 9,
        REALTIME_FAST = 10,
        MONOTONIC_PRECISE = 11,
        MONOTONIC_FAST = 12,
        SECOND = 13,
        THREAD_CPUTIME_ID = 14,
        PROCESS_CPUTIME_ID = 15,
    },
    .openbsd => enum(u32) {
        REALTIME = 0,
        PROCESS_CPUTIME_ID = 2,
        MONOTONIC = 3,
        THREAD_CPUTIME_ID = 4,
    },
    else => void,
};

pub const Clock = enum {
    monotonic,
    boottime,
    realtime,

    pub fn fromPosix(clock: clockid_t) @This() {
        return switch (builtin.target.os.tag) {
            .linux => switch (clock) {
                .MONOTONIC => .monotonic,
                .BOOTTIME => .boottime,
                .REALTIME => .realtime,
                else => unreachable, // clock unsupported
            },
            .macos, .ios, .tvos, .watchos, .visionos => switch (clock) {
                .UPTIME_RAW => .monotonic,
                .MONOTONIC_RAW => .boottime,
                .REALTIME => .realtime,
                else => unreachable, // clock unsupported
            },
            .wasi => switch (clock) {
                .MONOTONIC => .monotonic,
                .BOOTTIME => .monotonic,
                .REALTIME => .realtime,
                else => unreachable, // clock unsupported
            },
            else => switch (clock) {
                .UPTIME => .monotonic,
                .MONOTONIC => .boottime,
                .REALTIME => .realtime,
                else => unreachable, // clock unsupported
            },
        };
    }

    pub fn toPosix(clock: @This()) clockid_t {
        return switch (builtin.target.os.tag) {
            .linux => switch (clock) {
                .monotonic => .MONOTONIC,
                .boottime => .BOOTTIME,
                .realtime => .REALTIME,
            },
            .macos, .ios, .tvos, .watchos, .visionos => switch (clock) {
                .monotonic => .UPTIME_RAW,
                .boottime => .MONOTONIC_RAW,
                .realtime => .REALTIME,
            },
            .wasi => switch (clock) {
                .monotonic => .MONOTONIC,
                .boottime => .MONOTONIC,
                .realtime => .REALTIME,
            },
            else => switch (clock) {
                .monotonic => .UPTIME,
                .boottime => .MONOTONIC,
                .realtime => .REALTIME,
            },
        };
    }
};

fn now(clock: Clock) !u128 {
    return switch (builtin.target.os.tag) {
        .windows => switch (clock) {
            .monotonic, .boottime => D: {
                // TODO: this is equivalent to linux BOOTTIME
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
                break :D result;
            },
            .realtime => D: {
                // FileTime has a granularity of 100 nanoseconds and uses the NTFS/Windows epoch,
                // which is 1601-01-01.
                const epoch_adj = std.time.epoch.windows * (std.time.ns_per_s / 100);
                var ft: std.os.windows.FILETIME = undefined;
                std.os.windows.kernel32.GetSystemTimeAsFileTime(&ft);
                const ft64 = (@as(u64, ft.dwHighDateTime) << 32) | ft.dwLowDateTime;
                const adjusted = @as(i64, @bitCast(ft64)) + epoch_adj;
                std.debug.assert(adjusted > 0);
                break :D @as(u128, @intCast(adjusted)) * 100;
            },
        },
        .uefi => D: {
            var value: std.os.uefi.Time = undefined;
            if (std.os.uefi.system_table.runtime_services.getTime(&value, null) != .Success) return error.Unsupported;
            break :D value.toEpoch();
        },
        .wasi => D: {
            var ns: std.os.wasi.timestamp_t = undefined;
            const rc = std.os.wasi.clock_time_get(clock.toPosix(), 1, &ns);
            if (rc != .SUCCESS) return error.Unsupported;
            break :D ns;
        },
        else => D: {
            var ts: std.posix.timespec = undefined;
            std.posix.clock_gettime(@intCast(@intFromEnum(clock.toPosix())), &ts) catch return error.Unsupported;
            break :D (@as(u128, @intCast(ts.tv_sec)) * std.time.ns_per_s) + @as(u128, @intCast(ts.tv_nsec));
        },
    };
}

const Timeout = struct {
    ns_abs: u128,
    // used only if repeats, otherwise 0
    // absolute times can't repeat
    ns_interval: u64,
    expirations: u16,
    userdata: usize,
};

const TimeoutMap = std.enums.EnumMap(Clock, std.MultiArrayList(Timeout));
timeouts: TimeoutMap = TimeoutMap.initFull(.{}),
allocator: std.mem.Allocator,

pub const InitError = error{Unsupported};

pub fn init(allocator: std.mem.Allocator) InitError!@This() {
    inline for (std.meta.fields(Clock)) |field| _ = try now(@enumFromInt(field.value));
    return .{ .allocator = allocator };
}

pub fn deinit(self: *@This()) void {
    var iter = self.timeouts.iterator();
    while (iter.next()) |e| e.value.deinit(self.allocator);
    self.* = undefined;
}

fn sort(self: *@This(), clock: Clock) void {
    const SortContext = struct {
        items: []u128,
        pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            return ctx.items[a] > ctx.items[b];
        }
    };
    var list = self.timeouts.getPtr(clock) orelse unreachable;
    const ctx: SortContext = .{ .items = list.items(.ns_abs) };
    list.sortUnstable(ctx);
}

pub const ScheduleError = error{OutOfMemory};

pub const ScheduleOptions = struct {
    /// 0 == repeats forever
    expirations: u16 = 1,
    /// Is the time absolute?
    absolute: bool = false,
};

pub fn schedule(self: *@This(), clock: Clock, ns: u128, userdata: usize, opts: ScheduleOptions) ScheduleError!void {
    if (opts.expirations != 0 and opts.absolute) unreachable; // expirations must be 1 with absolute time
    var list = self.timeouts.getPtr(clock) orelse unreachable;
    try list.append(self.allocator, .{
        .ns_abs = if (!opts.absolute) (now(clock) catch unreachable) + ns else ns,
        .ns_interval = if (!opts.absolute) @intCast(ns) else 0,
        .expirations = opts.expirations,
        .userdata = userdata,
    });
    self.sort(clock);
}

pub fn disarm(self: *@This(), clock: Clock, userdata: usize) error{NotFound}!void {
    var list = self.timeouts.getPtr(clock) orelse unreachable;
    var idx: usize = 0;
    const items = list.items(.userdata);
    while (idx < list.len) {
        if (items[idx] != userdata) {
            idx += 1;
            continue;
        }
        list.swapRemove(idx);
    }
    self.sort(clock);
}

pub fn tick(self: *@This(), handler: anytype) u64 {
    var wait_time: u64 = std.math.maxInt(u64);
    inline for (std.meta.fields(Clock)) |field| {
        const clock: Clock = @enumFromInt(field.value);
        const list = self.timeouts.getPtr(clock) orelse unreachable;
        if (list.len > 0) {
            const ns_now = now(clock) catch unreachable;

            const timeouts = list.items(.ns_abs);
            const intervals = list.items(.ns_interval);
            const expirations = list.items(.expirations);
            const userdatas = list.items(.userdata);
            while (list.len > 0 and timeouts[list.len - 1] < ns_now) {
                const userdata = userdatas[list.len - 1];
                if (expirations[list.len - 1] == 1) {
                    list.len -= 1;
                } else {
                    expirations[list.len - 1] -|= 1;
                    timeouts[list.len - 1] = ns_now + intervals[list.len - 1];
                    self.sort(clock);
                }
                if (comptime @TypeOf(handler) != void) {
                    handler.onTimeout(userdata);
                }
            }

            if (list.len > 0) {
                wait_time = @min(wait_time, (timeouts[list.len - 1] - ns_now) / std.time.ns_per_ms);
            }
        }
    }
    return wait_time;
}

const TimerQueue = @This();

test {
    var queue = try TimerQueue.init(std.testing.allocator);
    defer queue.deinit();
    try queue.schedule(.monotonic, std.time.ns_per_s, 0, .{});
    try queue.schedule(.monotonic, std.time.ns_per_s * 2, 1, .{});

    const handler = struct {
        var times: usize = 0;
        fn onTimeout(userdata: usize) void {
            std.debug.assert(userdata == times);
            times += 1;
        }
    };

    while (handler.times < 2) {
        const wt = queue.tick(handler);
        if (handler.times < 2) {
            std.debug.assert(wt <= std.time.ns_per_s * 2);
        } else {
            std.debug.assert(wt > std.time.ns_per_s * 2);
        }
    }
}
