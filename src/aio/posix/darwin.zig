const std = @import("std");
const bsd = @import("bsd.zig");

pub const EventSource = bsd.EventSource;
pub const ChildWatcher = bsd.ChildWatcher;

pub const msghdr = extern struct {
    /// Optional address.
    msg_name: ?*std.posix.sockaddr,
    /// Size of address.
    msg_namelen: std.posix.socklen_t,
    /// Scatter/gather array.
    msg_iov: [*]std.posix.iovec,
    /// Number of elements in msg_iov.
    msg_iovlen: i32,
    /// Ancillary data.
    msg_control: ?*anyopaque,
    /// Ancillary data buffer length.
    msg_controllen: std.posix.socklen_t,
    /// Flags on received message.
    msg_flags: i32,
};

pub const msghdr_const = extern struct {
    /// Optional address.
    msg_name: ?*const std.posix.sockaddr,
    /// Size of address.
    msg_namelen: std.posix.socklen_t,
    /// Scatter/gather array.
    msg_iov: [*]std.posix.iovec_const,
    /// Number of elements in msg_iov.
    msg_iovlen: i32,
    /// Ancillary data.
    msg_control: ?*anyopaque,
    /// Ancillary data buffer length.
    msg_controllen: std.posix.socklen_t,
    /// Flags on received message.
    msg_flags: i32,
};
