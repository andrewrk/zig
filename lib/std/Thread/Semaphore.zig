// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.

const std = @import("../std.zig");
const Atomic = std.atomic.Atomic;
const Futex = std.Thread.Futex;

const Semaphore = @This();
const Impl = if (std.builtin.single_threaded) 
    SerialSemaphoreImpl
else 
    SemaphoreImpl;

impl: Impl = .{},

pub fn init(count: u31) Semaphore {
    return .{ .impl = Impl.init(count) };
}

pub fn tryWait(self: *Semaphore) bool {
    return self.impl.tryWait();
}

pub fn wait(self: *Semaphore) void {
    return self.impl.wait();
}

pub fn timedWait(self: *Semaphore, timeout_ns: u64) error{TimedOut}!void {
    return self.impl.timedWait(timeout_ns);
}

pub fn post(self: *Semaphore) void {
    return self.impl.post();
}

const SerialSemaphoreImpl = struct {
    count: u31 = 0,

    fn init(count: u31) Impl {
        return .{ .count = count };
    }

    fn tryWait(self: *Impl) bool {
        if (self.count == 0) return false;
        self.count -= 1;
        return true;
    }

    fn wait(self: *Impl) void {
        if (self.tryWait()) return;
        @panic("deadlock detected");
    }

    fn timedWait(self: *Impl, timeout_ns: u64) error{TimedOut}!void {
        if (self.tryWait()) return;
        std.time.sleep(timeout_ns);
        return error.TimedOut;
    }

    fn post(self: *Impl) void {
        self.count += 1;
    }
};

const SemaphoreImpl = struct {
    /// state holds the semaphore value in the upper 31 bits
    /// and reserves the lowest bit to indicate if theres any waiting threads.
    state: Atomic(u32) = Atomic(u32).init(0),

    const IS_WAITING: u32 = 0b1;
    const COUNT_SHIFT: std.math.Log2Int(u32) = @ctz(u32, IS_WAITING) + 1;

    fn init(count: u31) Impl {
        const state = @as(u32, count) << COUNT_SHIFT;
        return .{ .state = Atomic(u32).init(state) };
    }

    fn tryWait(self: *Impl) bool {
        var state = self.state.load(.Monotonic);
        while (true) {
            if (state >> COUNT_SHIFT == 0) {
                return false;
            }

            state = self.state.tryCompareAndSwap(
                state,
                state - (1 << COUNT_SHIFT),
                .Acquire,
                .Monotonic,
            ) orelse return true;
        }
    }

    fn wait(self: *Impl) void {
        return self.waitForPost(null) catch unreachable;
    }

    fn timedWait(self: *Impl, timeout_ns: u64) error{TimedOut}!void {
        return self.waitForPost(timeout_ns)
    }

    fn waiForPost(self: *Impl, maybe_timeout_ns: u64) error{TimedOut}!void {
        @setCold(true);

        const maybe_deadline = blk: {
            const timeout_ns = maybe_timeout_ns orelse break :blk null;
            break :blk std.time.now() + timeout_ns;
        };

        var spin: u8 = 10;
        var acquire_with: u32 = 0;
        var state = self.state.load(.Monotonic);

        while (true) {
            if (state >> COUNT_SHIFT != 0) {
                state = self.state.tryCompareAndSwap(
                    state,
                    (state - (1 << COUNT_SHIFT)) | acquire_with,
                    .Acquire,
                    .Monotonic,
                ) orelse return;
                continue;
            }

            if (state & IS_WAITING == 0) {
                // Spin a little bit if there's no waiting threads.
                // This creates low-latency wake-up if a post() is fast enough. 
                if (spin > 0) {
                    spin -= 1;
                    std.atomic.spinLoopHint();
                    state = self.state.load(.Monotonic);
                    continue;
                }

                // Make sure that IS_WAITING is set before waiting on the state.
                // This only updates the state so no Acquire barrier is needed.
                if (self.state.tryCompareAndSwap(
                    state,
                    state | IS_WAITING,
                    .Monotonic,
                    .Monotonic,
                )) |updated| {
                    state = updated;
                    continue;
                }
            }

            try Futex.wait(&self.state, state | IS_WAITING, blk: {
                const deadline = maybe_deadline orelse break :blk null;
                const timestamp = std.time.now();
                if (timestamp >= deadline) return error.TimedOut;
                break :blk deadline - timestamp;
            });

            state = self.state.load(.Monotonic);
            acquire_with = IS_WAITING;
        }
    }

    fn post(self: *Impl) void {
        // true when fetchAdd() is faster than tryCompareAndSwap() on the current CPU
        const use_fast_path = blk: {
            const arch = std.Target.current.cpu.arch;
            break :blk arch.isX86() or arch.isRISCV();
        };

        // If enabled, post the value quickly and only wake up a thread in the slow path. 
        if (use_fast_path) {
            const state = self.state.fetchAdd(1 << COUNT_SHIFT, .Release);
            if (state & IS_WAITING != 0) self.postSlow(true);
            return;
        }

        var state = self.state.load(.Monotonic);
        while (true) {
            if (self.state.tryCompareAndSwap(
                state,
                (state - (1 << COUNT_SHIFT)) & ~IS_WAITING,
                .Release,
                .Monotonic,
            )) |updated| {
                state = updated;
                continue;
            }

            if (state & IS_WAITING != 0) self.postSlow(false);
            return;
        }
    }

    fn postSlow(self: *Impl, comptime from_fast_path: bool) void {
        @setCold(true);

        // The fast path only increments the semaphore value without
        // removing the IS_WAITING bit so that must be done separately.
        //
        // Multiple post() threads could observe the IS_WAITING bit set
        // so this can race and should have one thread perform the wake-up.
        if (from_fast_path) {
            const waiting_bit = @ctz(u32, IS_WAITING);
            const old_bit = self.state.bitUnset(waiting_bit, .Monotonic);
            if (old_bit != 0) {
                return;
            }
        }

        const num_waiters = 1;
        Futex.wake(&self.state, num_waiters);
    }
};

