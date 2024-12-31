const std = @import("std");
const bsd = @import("bsd.zig");

pub const EventSource = bsd.EventSource;
pub const ChildWatcher = bsd.ChildWatcher;

pub const msghdr = extern struct {
    /// Optional address.
    name: ?*std.posix.sockaddr,
    /// Size of address.
    namelen: std.posix.socklen_t,
    /// Scatter/gather array.
    iov: [*]std.posix.iovec,
    /// Number of elements in iov.
    iovlen: i32,
    /// Ancillary data.
    control: ?*anyopaque,
    /// Ancillary data buffer length.
    controllen: std.posix.socklen_t,
    /// Flags on received message.
    flags: i32,
};

pub const msghdr_const = extern struct {
    /// Optional address.
    name: ?*const std.posix.sockaddr,
    /// Size of address.
    namelen: std.posix.socklen_t,
    /// Scatter/gather array.
    iov: [*]std.posix.iovec_const,
    /// Number of elements in iov.
    iovlen: i32,
    /// Ancillary data.
    control: ?*anyopaque,
    /// Ancillary data buffer length.
    controllen: std.posix.socklen_t,
    /// Flags on received message.
    flags: i32,
};
