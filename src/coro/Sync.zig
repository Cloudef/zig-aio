const Frame = @import("Frame.zig");

fn wakeupWaiters(list: *Frame.WaitList, status: anytype) void {
    var next = list.first;
    while (next) |node| {
        next = node.next;
        node.data.cast().wakeup(status);
    }
}

pub const Semaphore = struct {
    waiters: Frame.WaitList = .{},
    counter: u32 = 0,

    pub const Error = error{Canceled};

    pub fn lock(self: *@This()) Error!void {
        if (Frame.current()) |frame| {
            if (frame.canceled) return error.Canceled;
            self.counter += 1;
            self.waiters.prepend(&frame.wait_link);
            defer self.waiters.remove(&frame.wait_link);
            while (self.counter > 0 and !frame.canceled) Frame.yield(.semaphore);
            if (frame.canceled) return error.Canceled;
        } else unreachable; // can only be used in tasks
    }

    pub fn unlock(self: *@This()) void {
        if (self.counter == 0) return;
        self.counter -= 1;
        wakeupWaiters(&self.waiters, .semaphore);
    }
};

pub const ResetEvent = struct {
    waiters: Frame.WaitList = .{},
    is_set: bool = false,

    pub const Error = error{Canceled};

    pub fn wait(self: *@This()) Error!void {
        if (Frame.current()) |frame| {
            if (frame.canceled) return error.Canceled;
            if (self.is_set) return;
            self.waiters.prepend(&frame.wait_link);
            defer self.waiters.remove(&frame.wait_link);
            while (!self.is_set and !frame.canceled) Frame.yield(.reset_event);
            if (frame.canceled) return error.Canceled;
        } else unreachable; // can only be used in tasks
    }

    pub fn set(self: *@This()) void {
        self.is_set = true;
        wakeupWaiters(&self.waiters, .reset_event);
    }

    pub fn reset(self: *@This()) void {
        self.is_set = false;
    }
};
