//! Mimics linux's io_uring timeouts
//! Used on platforms where native timers aren't accurate enough or have other limitations

const builtin = @import("builtin");
const std = @import("std");

pub const Clock = enum {
    monotonic,
    boottime,
    realtime,

    pub fn fromPosix(clock: std.posix.clockid_t) @This() {
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

    pub fn toPosix(clock: @This()) std.posix.clockid_t {
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
            std.debug.assert(std.os.uefi.system_table.runtime_services.getTime(&value, null) == .Success);
            break :D value.toEpoch();
        },
        .wasi => D: {
            var ns: std.os.wasi.timestamp_t = undefined;
            const rc = std.os.wasi.clock_time_get(clock.toPosix(), 1, &ns);
            if (rc != .SUCCESS) return error.Unsupported;
            break :D ns;
        },
        else => D: {
            const ts = std.posix.clock_gettime(clock.toPosix()) catch return error.Unsupported;
            break :D (@as(u128, @intCast(ts.sec)) * std.time.ns_per_s) + @as(u128, @intCast(ts.nsec));
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
                handler.onTimeout(userdata);
            }

            if (list.len > 0) {
                wait_time = @min(wait_time, (timeouts[list.len - 1] - ns_now) / std.time.ns_per_ms);
            }
        }
    }
    return wait_time;
}
