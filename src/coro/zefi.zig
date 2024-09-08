// MIT License
//
// Copyright (c) 2023 kprotty
// Modified by Cloudef (2024)
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Fiber = @This();

pub const stack_alignment = 16;
pub const Stack = []align(stack_alignment) u8;

pub const Error = error{
    /// The stack space provided to the fiber is not large enough to contain required metadata.
    StackTooSmall,
};

/// Intrusively allocates a Fiber object (and auxiliary data) inside (specifically, and the end of) the given stack memory.
/// Then, execution of the fiber is setup to invoke the given function with the args on the next call to `switchTo`.''
pub fn init(stack: Stack, user_data: usize, comptime func: anytype, args: anytype) Error!*Fiber {
    const Args = @TypeOf(args);
    const state = try State.init(stack, user_data, @sizeOf(Args), struct {
        fn entry() callconv(.C) noreturn {
            const state = tls_state orelse unreachable;

            // Call the functions with the args.
            const args_ptr: *align(1) Args = @ptrFromInt(@intFromPtr(state) - @sizeOf(Args));
            @call(.auto, func, args_ptr.*);

            // Mark the fiber as completed and do one last
            zefi_stack_swap(&state.stack_context, &state.caller_context);
            unreachable;
        }
    }.entry);

    const args_ptr: *align(1) Args = @ptrFromInt(@intFromPtr(state) - @sizeOf(Args));
    args_ptr.* = args;

    return @ptrCast(state);
}

threadlocal var tls_state: ?*State = null;

/// Get the currently running fiber of the caller, if any.
pub inline fn current() ?*Fiber {
    return @ptrCast(tls_state);
}

/// Given a fiber, return the user_data used to initialize it.
/// A pointer to the user_data is returned to give the caller the ability to modify it on the Fiber.
/// Calling getUserDataPtr() on a fiber which has completed is unspecified behavior.
pub fn getUserDataPtr(fiber: *Fiber) *usize {
    const state: *State = @ptrCast(@alignCast(fiber));
    return &state.user_data;
}

/// Switches the current thread's execution state from the caller's to the fiber's.
/// The fiber will return back to this caller either through yield or completing its init function.
/// The fiber must either be newly initialized or previously yielded.
///
/// Switching to a fiber that is currently executing is undefined behavior.
/// Switching to a fiber that has completed is illegal behavior.
pub fn switchTo(fiber: *Fiber) void {
    const state: *State = @ptrCast(@alignCast(fiber));

    // Temporarily set the current fiber to the one passed in for the duration of the stack swap.
    const old_state = tls_state;
    assert(old_state != state);
    tls_state = state;
    defer tls_state = old_state;

    zefi_stack_swap(&state.caller_context, &state.stack_context);
}

/// Switches the current thread's execution back to the most recent switchTo() called on the currently running fiber.
/// Calling yield from outside a fiber context (`current() == null`) is illegal behavior.
/// Once execution is yielded back, switchTo() on the (now previous) current fiber can be called again
/// to continue the fiber from this yield point.
pub fn yield() void {
    const state = tls_state orelse unreachable;
    zefi_stack_swap(&state.stack_context, &state.caller_context);
}

const State = extern struct {
    caller_context: *anyopaque,
    stack_context: *anyopaque,
    user_data: usize,

    fn init(stack: Stack, user_data: usize, args_size: usize, entry_point: *const fn () callconv(.C) noreturn) Error!*State {
        const stack_base = @intFromPtr(stack.ptr);
        const stack_end = @intFromPtr(stack.ptr + stack.len);

        // Push the State onto the state.
        var stack_ptr = std.mem.alignBackward(usize, stack_end - @sizeOf(State), stack_alignment);
        if (stack_ptr < stack_base) return error.StackTooSmall;

        const state: *State = @ptrFromInt(stack_ptr);

        // Push enough bytes for the args onto the stack.
        stack_ptr = std.mem.alignBackward(usize, stack_ptr - args_size, stack_alignment);
        if (stack_ptr < stack_base) return error.StackTooSmall;

        // Reserve data for the StackContext.
        stack_ptr = std.mem.alignBackward(usize, stack_ptr - @sizeOf(usize) * StackContext.word_count, stack_alignment);
        assert(std.mem.isAligned(stack_ptr, stack_alignment));
        if (stack_ptr < stack_base) return error.StackTooSmall;

        // Write the entry point into the StackContext.
        var entry: [*]@TypeOf(entry_point) = @ptrFromInt(stack_ptr);
        entry[StackContext.entry_offset] = entry_point;

        state.* = .{
            .caller_context = undefined,
            .stack_context = @ptrFromInt(stack_ptr),
            .user_data = user_data,
        };

        return state;
    }
};

extern fn zefi_stack_swap(
    noalias current_context_ptr: **anyopaque,
    noalias new_context_ptr: **anyopaque,
) void;
comptime {
    asm (StackContext.assembly);
}

const StackContext = switch (builtin.cpu.arch) {
    .x86_64 => switch (builtin.os.tag) {
        .windows => Intel_Microsoft,
        else => Intel_SysV,
    },
    .aarch64 => Arm_64,
    else => @compileError("platform not currently supported"),
};

const Intel_Microsoft = struct {
    pub const word_count = 31;

    pub const entry_offset = word_count - 1;

    pub const assembly =
        \\.global zefi_stack_swap
        \\zefi_stack_swap:
        \\  pushq %gs:0x10
        \\  pushq %gs:0x08
        \\
        \\  pushq %rbx
        \\  pushq %rbp
        \\  pushq %rdi
        \\  pushq %rsi
        \\  pushq %r12
        \\  pushq %r13
        \\  pushq %r14
        \\  pushq %r15
        \\
        \\  subq $160, %rsp
        \\  movups %xmm6, 0x00(%rsp)
        \\  movups %xmm7, 0x10(%rsp)
        \\  movups %xmm8, 0x20(%rsp)
        \\  movups %xmm9, 0x30(%rsp)
        \\  movups %xmm10, 0x40(%rsp)
        \\  movups %xmm11, 0x50(%rsp)
        \\  movups %xmm12, 0x60(%rsp)
        \\  movups %xmm13, 0x70(%rsp)
        \\  movups %xmm14, 0x80(%rsp)
        \\  movups %xmm15, 0x90(%rsp)
        \\
        \\  movq %rsp, (%rcx)
        \\  movq (%rdx), %rsp
        \\
        \\  movups 0x00(%rsp), %xmm6
        \\  movups 0x10(%rsp), %xmm7
        \\  movups 0x20(%rsp), %xmm8
        \\  movups 0x30(%rsp), %xmm9
        \\  movups 0x40(%rsp), %xmm10
        \\  movups 0x50(%rsp), %xmm11
        \\  movups 0x60(%rsp), %xmm12
        \\  movups 0x70(%rsp), %xmm13
        \\  movups 0x80(%rsp), %xmm14
        \\  movups 0x90(%rsp), %xmm15
        \\  addq $160, %rsp
        \\
        \\  popq %r15
        \\  popq %r14
        \\  popq %r13
        \\  popq %r12
        \\  popq %rsi
        \\  popq %rdi
        \\  popq %rbp
        \\  popq %rbx
        \\
        \\  popq %gs:0x08
        \\  popq %gs:0x10
        \\
        \\  retq
    ;
};

const symbol = switch (builtin.target.os.tag) {
    .macos => "_zefi_stack_swap",
    else => "zefi_stack_swap",
};

const Intel_SysV = struct {
    pub const word_count = 7;

    pub const entry_offset = word_count - 1;

    pub const assembly =
        std.fmt.comptimePrint(
        \\.global {[symbol]s}
        \\{[symbol]s}:
        \\  pushq %rbx
        \\  pushq %rbp
        \\  pushq %r12
        \\  pushq %r13
        \\  pushq %r14
        \\  pushq %r15
        \\
        \\  movq %rsp, (%rdi)
        \\  movq (%rsi), %rsp
        \\
        \\  popq %r15
        \\  popq %r14
        \\  popq %r13
        \\  popq %r12
        \\  popq %rbp
        \\  popq %rbx
        \\
        \\  retq
    , .{ .symbol = symbol });
};

const Arm_64 = struct {
    pub const word_count = 20;

    pub const entry_offset = 0;

    pub const assembly =
        std.fmt.comptimePrint(
        \\.global {[symbol]s}
        \\{[symbol]s}:
        \\  stp lr, fp, [sp, #-20*8]!
        \\  stp d8, d9, [sp, #2*8]
        \\  stp d10, d11, [sp, #4*8]
        \\  stp d12, d13, [sp, #6*8]
        \\  stp d14, d15, [sp, #8*8]
        \\  stp x19, x20, [sp, #10*8]
        \\  stp x21, x22, [sp, #12*8]
        \\  stp x23, x24, [sp, #14*8]
        \\  stp x25, x26, [sp, #16*8]
        \\  stp x27, x28, [sp, #18*8]
        \\
        \\  mov x9, sp
        \\  str x9, [x0]
        \\  ldr x9, [x1]
        \\  mov sp, x9
        \\
        \\  ldp x27, x28, [sp, #18*8]
        \\  ldp x25, x26, [sp, #16*8]
        \\  ldp x23, x24, [sp, #14*8]
        \\  ldp x21, x22, [sp, #12*8]
        \\  ldp x19, x20, [sp, #10*8]
        \\  ldp d14, d15, [sp, #8*8]
        \\  ldp d12, d13, [sp, #6*8]
        \\  ldp d10, d11, [sp, #4*8]
        \\  ldp d8, d9, [sp, #2*8]
        \\  ldp lr, fp, [sp], #20*8
        \\
        \\  ret
    , .{ .symbol = symbol });
};
