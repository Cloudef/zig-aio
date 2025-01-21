// Sanity checks the aio.EventSource for major bottlenecks / bugs

const std = @import("std");
const coro = @import("coro");
const aio = @import("aio");

const Ticker = struct {
    start: aio.EventSource,
    end: aio.EventSource,
    running: std.atomic.Value(bool) = .init(true),

    pub fn init() !@This() {
        return .{
            .start = try aio.EventSource.init(),
            .end = try aio.EventSource.init(),
        };
    }

    pub fn deinit(self: *@This()) void {
        self.start.deinit();
        self.end.deinit();
        self.* = undefined;
    }
};

const Region = struct {
    id: u16,
    thread: std.Thread,
    ticker: *Ticker,
    ready: std.atomic.Value(bool) = .init(false),

    // thread local
    gpa: std.heap.GeneralPurposeAllocator(.{}) = undefined,
    scheduler: coro.Scheduler = undefined,

    pub fn init(self: *@This(), id: u16, ticker: *Ticker) !void {
        self.* = .{
            .id = id,
            .ticker = ticker,
            .thread = try std.Thread.spawn(.{}, @This().run, .{self}),
        };
    }

    pub fn deinit(self: *@This()) void {
        self.thread.join();
    }

    pub fn run(self: *@This()) !void {
        self.gpa = .init;
        defer _ = self.gpa.deinit();
        self.scheduler = try .init(self.gpa.allocator(), .{});
        defer self.scheduler.deinit();
        _ = try self.scheduler.spawn(tickerLoop, .{self}, .{ .detached = true });
        try self.scheduler.run(.wait);
    }

    fn tickerLoop(self: *@This()) !void {
        var other = try self.scheduler.spawn(otherWork, .{self}, .{});
        defer other.cancel();
        while (self.ticker.running.load(.acquire)) {
            if (!self.ready.load(.acquire)) {
                // we were too fast, do something else
                try coro.io.single(aio.Timeout{ .ns = 1 });
                continue;
            }
            try coro.io.single(aio.WaitEventSource{ .source = &self.ticker.start });
            self.ready.store(false, .release);
            std.log.debug("{d: >2}: tick", .{self.id});
            try coro.io.single(aio.NotifyEventSource{ .source = &self.ticker.end });
        }
    }

    fn otherWork(self: *@This()) !void {
        while (self.ticker.running.load(.acquire)) {
            // simulate other work
            try coro.io.single(aio.Timeout{ .ns = 1 * std.time.ns_per_s });
        }
    }
};

fn RegionScheduler(comptime num_regions: u16) type {
    return struct {
        thread: std.Thread,
        region: [num_regions]Region,
        ticker: Ticker,

        pub fn init(self: *@This()) void {
            errdefer @panic("welp, lets not even try");
            self.ticker = try .init();
            for (&self.region, 0..) |*region, id| try region.init(@intCast(id + 1), &self.ticker);
            self.thread = try .spawn(.{}, @This().run, .{self});
        }

        pub fn deinit(self: *@This()) void {
            for (&self.region) |*region| region.deinit();
            self.thread.join();
            self.ticker.deinit();
            self.* = undefined;
        }

        fn run(self: *@This()) void {
            defer self.ticker.running.store(false, .release);
            for (1..100 + 1) |n| {
                std.log.debug("tick {} start", .{n});
                for (&self.region) |*region| {
                    std.debug.assert(!region.ready.load(.acquire));
                    region.ready.store(true, .release);
                    self.ticker.start.notify();
                }
                for (0..num_regions) |_| self.ticker.end.wait();
                std.log.debug("tick {} end", .{n});
            }
        }
    };
}

pub fn main() !void {
    var rs: RegionScheduler(16) = undefined;
    rs.init();
    defer rs.deinit();
}
