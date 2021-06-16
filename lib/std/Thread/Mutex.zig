// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.

const std = @import("../std.zig");
const Atomic = std.atomic.Atomic;
const Futex = std.Thread.Futex;

const Mutex = @This();
const Impl = if (std.builtin.single_threaded and std.debug.runtime_safety) 
    SafeSerialMutexImpl
else if (std.builtin.single_threaded)
    FastSerialMutexImpl
else 
    MutexImpl;

impl: Impl = .{},

pub fn tryAcquire(self: *Mutex) ?Held {
    if (!self.impl.tryAcquire()) return null;
    return Held{ .impl = &self.impl };
}

pub fn acquire(self: *Mutex) Held {
    self.impl.acquire();
    return Held{ .impl = &self.impl };
}

pub fn timedAcquire(self: *Mutex, timeout_ns: u64) error{TimedOut}!Held {
    try self.impl.timedAcquire(timeout_ns);
    return Held{ .impl = &self.impl };
}

pub const Held = struct {
    impl: *Impl,
    
    pub fn release(self: Held) void {
        return self.impl.release();
    }
};

const FastSerialMutexImpl = struct {
    fn tryAcquire(self: *Impl) bool {
        return true;
    }

    fn acquire(self: *Impl) void {
        // no-op
    }

    fn timedAcquire(self: *Impl, timeout_ns: u64) error{TimedOut}!void {
        // no-op
    }

    fn release(self: *Impl) void {
        // no-op
    }
};

const SafeSerialMutexImpl = struct {
    is_acquired: bool = false,

    fn tryAcquire(self: *Impl) bool {
        if (self.is_acquired) return false;
        self.is_acquired = true;
        return true;
    }

    fn acquire(self: *Impl) void {
        if (self.is_acquired) @panic("deadlock detected");
        self.is_acquired = true;
    }

    fn timedAcquire(self: *Impl, timeout_ns: u64) error{TimedOut}!void {
        if (self.is_acquired) return;
        std.time.sleep(timeout_ns);
        return error.TimedOut;
    }

    fn release(self: *Impl) void {
        if (!self.is_acquired) @panic("unlocked an unlocked mutex");
        self.is_acquired = false;
    }
};

const MutexImpl = struct {
    state: Atomic(u32) = Atomic(u32).init(UNLOCKED),

    const UNLOCKED: u32 = 0;
    const LOCKED: u32 = 1;
    const CONTENDED: u32 = 2;

    fn tryAcquire(self: *Impl) bool {
        return self.state.compareAndSwap(
            UNLOCKED,
            LOCKED,
            .Acquire,
            .Monotonic,
        ) == null;
    }

    fn acquire(self: *Impl) void {
        if (self.acquireFast()) return;
        return self.acquireSlow(null) catch unreachable;
    }

    fn timedAcquire(self: *Impl, timeout_ns: u64) error{TimedOut}!void {
        if (self.acquireFast()) return;
        return self.acquireSlow(timeout_ns);
    }

    fn acquireFast(self: *Impl) callconv(.Inline) bool {
        return self.state.tryCompareAndSwap(
            UNLOCKED,
            LOCKED,
            .Acquire,
            .Monotonic,
        ) == null;
    }

    fn acquireSlow(self: *Impl, maybe_timeout_ns: ?u64) error{TimedOut}!void {
        @setCold(true);
        
        // true if the cpu's atomic swap instruction should be preferred
        const has_fast_swap = blk: {
            const arch = std.Target.current.cpu.arch;
            break :blk arch.isX86() or arch.isRISCV();
        };

        // create a deadline in which the timeout actually expires
        const maybe_deadline = blk: {
            const timeout_ns = maybe_timeout_ns orelse break :blk null;
            break :blk std.time.now() + timeout_ns;
        };

        var acquire_state = LOCKED;
        var state = self.state.load(.Monotonic);
        var spin: u8 = if (has_fast_swap) 100 else 10;

        while (true) {
            // Try to lock the Mutex if its unlocked.
            // acquire_state is changed to CONTENDED if this thread goes to sleep.
            //
            // We acquire with CONTENDED instead of LOCKED in that scenario 
            // to make sure that we wake another thread sleeping in release()
            // which didn't see the transition to UNLOCKED since it was asleep.
            //
            // A CONTENDED acquire unfortunately results in one extra wake() 
            // if there were no other sleeping threads at the time of the acquire.
            if (state == UNLOCKED) {
                state = self.state.tryCompareAndSwap(
                    state,
                    acquire_state,
                    .Acquire,
                    .Monotonic,
                ) orelse return;
                continue;
            }

            if (state != CONTENDED) uncontended: {
                // If there's no pending threads, try to spin on the Mutex a few times.
                // This makes the throughput close to a spinlock when under micro-contention.
                if (spin > 0) {
                    spin -= 1;
                    std.atomic.spinLoopHint();
                    state = self.state.load(.Monotonic);
                    continue;
                }

                // Indicate that there will be a waiting thread by updating to CONTENDED.
                // Acquire barrier as this swap could also possibly lock the Mutex.
                if (has_fast_swap) {
                    state = self.state.swap(CONTENDED, .Acquire);
                    if (state == UNLOCKED) return;
                    break :uncontended;
                }

                // For other platforms, mark the Mutex as CONTENDED if it's not already.
                // This just indicates that there's waiting threads so no Acquire barrier needed.
                if (self.state.tryCompareAndSwap(
                    state,
                    CONTENDED,
                    .Monotonic,
                    .Monotonic,
                )) |updated| {
                    state = updated;
                    continue;
                }
            }

            try Futex.wait(&self.state, CONTENDED, blk: {
                const deadline = maybe_deadline orelse break :blk null;
                const timestamp = std.time.now();
                if (timestamp >= deadline) return error.TimedOut;
                break :blk deadline - timestamp;
            });

            state = self.state.load(.Monotonic);
            acquire_state = CONTENDED;
        }
    }

    fn release(self: *Impl) void {
        const state = self.state.swap(UNLOCKED, .Release);
        
        // Wake up a sleeping thread if it was previously CONTENDED.
        // The woken up thread would acquire by updating the state to CONTENDED again.
        // This is to make sure a future release() wouldn't miss waking up threads that 
        // don't see the reset to UNLOCKED above due to them being asleep.
        switch (state) {
            UNLOCKED => unreachable, // unlocked an unlocked mutex
            LOCKED => {},
            CONTENDED => self.releaseSlow(),
            else => unreachable, // invalid mutex state
        }
    }

    fn releaseSlow(self: *Impl) void {
        @setCold(true);

        const num_waiters = 1;
        Futex.wake(&self.state, num_waiters);
    }
};

