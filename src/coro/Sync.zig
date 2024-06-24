const Frame = @import("Frame.zig");

pub const Semaphore = struct {
    waiters: Frame.WaitList = .{},
    counter: u32 = 0,

    pub fn lock(self: *@This()) void {
        self.counter += 1;
        if (Frame.current()) |frame| {
            self.waiters.prepend(&frame.wait_link);
            while (self.counter > 0) Frame.yield(.semaphore);
        } else unreachable; // can only be used in tasks
    }

    pub fn unlock(self: *@This()) void {
        if (self.counter == 0) return;
        self.counter -= 1;
        while (self.waiters.popFirst()) |node| node.data.cast().wakeup(.semaphore);
    }
};

pub const ResetEvent = struct {
    waiters: Frame.WaitList = .{},
    is_set: bool = false,

    pub fn wait(self: *@This()) void {
        if (self.is_set) return;
        if (Frame.current()) |frame| {
            self.waiters.prepend(&frame.wait_link);
            while (!self.is_set) Frame.yield(.reset_event);
        } else unreachable; // can only be used in tasks
    }

    pub fn set(self: *@This()) void {
        self.is_set = true;
        while (self.waiters.popFirst()) |node| node.data.cast().wakeup(.reset_event);
    }

    pub fn reset(self: *@This()) void {
        self.is_set = false;
    }
};
