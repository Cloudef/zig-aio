const Frame = @import("Frame.zig");

fn wakeupWaiters(list: *Frame.WaitList, status: anytype) void {
    var next = list.first;
    while (next) |node| {
        next = node.next;
        node.data.cast().wakeup(status);
    }
}

/// Cooperatively scheduled thread unsafe Semaphore
pub const Semaphore = struct {
    waiters: Frame.WaitList = .{},
    used: bool = false,

    pub const Error = error{Canceled};

    pub fn lock(self: *@This()) Error!void {
        if (Frame.current()) |frame| {
            if (frame.canceled) return error.Canceled;

            if (!self.used) {
                self.used = true;
                return;
            }

            self.waiters.prepend(&frame.wait_link);
            defer self.waiters.remove(&frame.wait_link);

            while (!frame.canceled) {
                Frame.yield(.semaphore);
                if (!self.used) {
                    self.used = true;
                    break;
                }
            }

            if (frame.canceled) return error.Canceled;
        } else unreachable; // can only be used in tasks
    }

    pub fn unlock(self: *@This()) void {
        if (!self.used) return;
        self.used = false;
        wakeupWaiters(&self.waiters, .semaphore);
    }
};

/// Cooperatively scheduled thread unsafe ResetEvent
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
