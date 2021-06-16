// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.

const std = @import("../std.zig");
const Atomic = std.atomic.Atomic;
const Futex = std.Thread.Futex;
const Mutex = std.Thread.Mutex;

const Condvar = @This();
const Impl = if (std.builtin.single_threaded) 
    SerialCondvarImpl
else 
    CondvarImpl;

impl: Impl = .{},

pub fn wait(noalias self: *Condvar, noalias held: *Mutex.Held) void {
    return self.impl.wait(held);
}

pub fn timedWait(noalias self: *Condvar, noalias held: *Mutex.Held, timeout_ns: u64) error{TimedOut}!void {
    return self.impl.timedWait(held, timeout_ns);
}

pub fn signal(self: *Condvar) void {
    return self.impl.signal();
}

pub fn broadcast(self: *Condvar) void {
    return self.impl.broadcast();
}

const SerialCondvarImpl = struct {
    fn wait(noalias self: *Impl, noalias held: *Mutex.Held) void {
        @panic("deadlock detected");
    }

    fn timedWait(noalias self: *Impl, noalias held: *Mutex.Held, timeout_ns: u64) error{TimedOut}!void {
        std.time.sleep(timeout_ns);
        return error.TimedOut;
    }

    fn signal(self: *Impl) void {
        // no-op
    }

    fn broadcast(self: *Impl) void {
        // no-op
    }
};

const CondvarImpl = struct {
    sequence: Atomic(u32) = Atomic(u32).init(0),

    fn wait(noalias self: *Impl, noalias held: *Mutex.Held) void {
        return self.waitOn(held, null) catch unreachable;
    }

    fn timedWait(noalias self: *Impl, noalias held: *Mutex.Held, timeout_ns: u64) error{TimedOut}!void {
        return self.waitOn(held, timeout_ns);
    }

    fn waitOn(noalias self: *Impl, noalias held: *Mutex.Held, maybe_timeout_ns: ?u64) error{TimedOut}!void {
        const ticket = self.sequence.load(.Monotonic);

        held.release();
        defer held.* = held.impl.acquire();

        const maybe_deadline = blk: {
            const timeout_ns = maybe_timeout_ns orelse break :blk null;
            break :blk std.time.now() + timeout_ns;
        };

        while (true) {
            if (self.sequence.load(.Monotonic) != ticket) {
                return;
            }

            try Futex.wait(&self.sequence, ticket, blk: {
                const deadline = maybe_deadline orelse break :blk null;
                const timestamp = std.time.now();
                if (timestamp >= deadline) return error.TimedOut;
                break :blk deadline - timestamp;
            });
        }
    }

    fn signal(self: *Impl) void {
        _ = self.sequence.fetchAdd(1, .Monotonic);

        const num_waiters = 1;
        Futex.wake(&self.sequence, num_waiters);
    }

    fn broadcast(self: *Impl) void {
        _ = self.sequence.fetchAdd(1, .Monotonic);

        const num_waiters = std.math.maxInt(u32);
        Futex.wake(&self.sequence, num_waiters);
    }
};

test "Condvar" {
    return error.TODO;
}
