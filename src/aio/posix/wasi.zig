const std = @import("std");

// Requires EventSource to be able to do anything useful though
// No idea how to implement that on top of wasi yet

pub const BIGGEST_ALIGNMENT = 16;

pub const sa_family_t = u16;

pub const sockaddr = extern struct {
    sa_family: sa_family_t align(BIGGEST_ALIGNMENT),
    sa_data: [*]u8,
};

pub const socklen_t = u32;

pub const msghdr = extern struct {
    msg_name: *anyopaque,
    msg_namelen: socklen_t,
    msg_iov: std.posix.iovec,
    msg_iovlen: i32,
    msg_control: *anyopaque,
    msg_controllen: socklen_t,
    msg_flags: i32,
};

pub const msghdr_const = extern struct {
    msg_name: *const anyopaque,
    msg_namelen: socklen_t,
    msg_iov: std.posix.iovec,
    msg_iovlen: i32,
    msg_control: *anyopaque,
    msg_controllen: socklen_t,
    msg_flags: i32,
};
