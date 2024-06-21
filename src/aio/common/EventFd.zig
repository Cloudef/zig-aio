const std = @import("std");

fd: std.posix.fd_t,

pub inline fn init() !@This() {
    return .{
        .fd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC),
    };
}

pub inline fn deinit(self: *@This()) void {
    std.posix.close(self.fd);
    self.* = undefined;
}

pub inline fn notify(self: *@This()) void {
    _ = std.posix.write(self.fd, &std.mem.toBytes(@as(u64, 1))) catch unreachable;
}

pub inline fn wait(self: *@This()) void {
    var v: u64 = undefined;
    _ = std.posix.read(self.fd, std.mem.asBytes(&v)) catch unreachable;
}
