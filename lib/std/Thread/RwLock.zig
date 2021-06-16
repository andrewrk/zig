// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.

const std = @import("../std.zig");
const Atomic = std.atomic.Atomic;
const Futex = std.Thread.Futex;

const RwLock = @This();
const Impl = if (std.builtin.single_threaded)
    SerialRwLockImpl
else 
    RwLockImpl;

impl: Impl = .{},

pub fn tryAcquire(self: *RwLock) ?Held {
    if (!self.impl.tryAcquire()) return null;
    return Held{ .impl = &self.impl };
}

pub fn acquire(self: *RwLock) Held {
    self.impl.acquire();
    return Held{ .impl = &self.impl };
}

pub fn timedAcquire(self: *RwLock, timeout_ns: u64) error{TimedOut}!Held {
    try self.impl.timedAcquire(timeout_ns);
    return Held{ .impl = &self.impl };
}

pub fn tryAcquireShared(self: *RwLock) ?Held {
    if (!self.impl.tryAcquireShared()) return null;
    return Held{ .impl = &self.impl };
}

pub fn acquireShared(self: *RwLock) Held {
    self.impl.acquireShared();
    return Held{ .impl = &self.impl };
}

pub fn timedAcquireShared(self: *RwLock, timeout_ns: u64) error{TimedOut}!Held {
    try self.impl.timedAcquireShared(timeout_ns);
    return Held{ .impl = &self.impl };
}

pub const Held = struct {
    impl: *Impl,

    pub fn release(self: Held) void {
        return self.impl.release();
    }
};

const SerialRwLockImpl = struct {
    state: RwLockImpl.Count = 0,

    const IS_WRITING = std.math.maxInt(RwLockImpl.Count);

    fn tryAcquire(self: *Impl) bool {
        if (self.state != 0) return false;
        self.state = IS_WRITING;
        return true;    
    }

    fn acquire(self: *Impl) void {
        if (self.tryAcquire()) return;
        @panic("deadlock detected");
    }

    fn timedAcquire(self: *Impl, timeout_ns: u64) error{TimedOut}!void {
        if (self.tryAcquire()) return;
        std.time.sleep(timeout_ns);
        return error.TimedOut;
    }

    fn tryAcquireShared(self: *Impl) bool {
        if (self.state == IS_WRITING) return false;
        self.state += 1;
        return true;
    }

    fn acquireShared(self: *Impl) void {
        if (self.tryAcquireShared()) return;
        @panic("deadlock detected");
    }

    fn timedAcquireShared(self: *Impl, timeout_ns: u64) error{TimedOut}!void {
        if (self.tryAcquireShared()) return;
        std.time.sleep(timeout_ns);
        return error.TimedOut;
    }

    fn release(self: *Impl) void {
        if (self.state == IS_WRITING) {
            self.state = 0;
        } else if (self.state > 0) {
            self.state -= 1;
        } else {
            unreachable; // not acquired
        }
    }
};

const RwLockImpl = struct {
    state: Atomic(usize) = Atomic(usize).init(0),
    semaphore: std.Thread.Semaphore = .{},
    mutex: std.Thread.Mutex = .{},

    const Count = std.meta.Int(.unsigned, (std.meta.bitCount(usize) - 1) / 2);
    const READER: usize = 1 << (std.meta.bitCount(Count) + 1);
    const WRITER: usize = 1 << 1;
    const IS_WRITING: usize = 1;

    const UNLOCKED: usize = 0;
    const READER_MASK = @as(usize, std.math.maxInt(Count)) << @ctz(usize, READER);
    const WRITER_MASK = @as(usize, std.math.maxInt(Count)) << @ctz(usize, WRITER);

    fn tryAcquire(self: *Impl) bool {
        // Writer locking must have the Mutex acquired to serialize access.
        if (!self.mutex.tryAcquire()) {
            return false;
        }

        // Bail if there's still pending readers since it would require 
        // waiting for them to complete before acquiring exclusive access.
        //
        // No need for an Acquire barrier since:
        // - previous writer changes are made visible by the mutex acquire above
        // - readers don't make any changes this writer needs to have visibility to.
        const state = self.state.load(.Monotonic);
        if (state & READER_MASK != 0) {
            self.mutex.release();
            return false;
        }

        // Mark the RwLock as having exclusive access.
        // No need to check result since other readers/writers
        // would block/fail on the mutex since its currently locked.
        _ = self.state.fetchOr(IS_WRITING, .Monotonic);
        return true;
    }

    fn acquire(self: *Impl) void {
        return self.acquireExclusiveAccess(null) catch unreachable;
    }

    fn timedAcquire(self: *Impl, timeout_ns: u64) error{TimedOut}!void {
        return self.acquireExclusiveAccess(timeout_ns);
    }

    fn acquireExclusiveAccess(self: *Impl, maybe_timeout_ns: ?u64) error{TimedOut}!void {
        // Mark the RwLock as having a pending writer...
        _ = self.state.fetchAdd(WRITER, .Monotonic);

        // ... then wait to get exclusive access (undoing the pending writer if it fails).
        blk: {
            const timeout_ns = maybe_timeout_ns orelse break :blk self.mutex.acquire();
            self.mutex.timedAcquire(timeout_ns) catch {
                _ = self.state.fetchSub(WRITER, .Monotonic);
                return error.TimedOut;
            };
        }

        // Mark the RwLock as having exclusive access while removing the pending writer set above.
        const state = self.state.fetchAdd(IS_WRITING -% WRITER, .Monotonic);

        // Wait for all reader threads to exit.
        if (state & READER_MASK != 0) {
            self.semaphore.wait();
        }
    }    

    fn releaseExclusive(self: *Impl) void {
        // Unset the writer bit with a Release barrier for non-mutex readers to see writes.
        _ = self.state.fetchAnd(~IS_WRITING, .Release);
        
        // Unlock the mutex to release exclusive access to a pending reader or writer thread.
        self.mutex.release();
    }

    fn tryAcquireShared(self: *Impl) bool {
        var state = self.state.load(.Monotonic);
        while (true) {
            // Bail if there's currently a writer in progress.
            // We would have to block on the mutex otherwise.
            if (state & IS_WRITING != 0) {
                return false;
            }

            // If there's a pending writer, it may not have gotten the mutex yet.
            if (state & WRITER_MASK != 0) {
                if (!self.mutex.tryAcquire()) {
                    return false;
                }
                
                // Mark the precense of a reader thread and release the mutex for other readers/writers.
                // No acquire barrier needed since writes are made visible by the mutex acquire above.
                _ = self.state.fetchAdd(READER, .Monotonic);
                self.mutex.release();
                return true;
            }

            // If there's no writers or pending writers, acquire by bumping the reader count.
            // Acquire barrier to make visible any updates done by previous writer threads.
            state = self.state.tryCompareAndSwap(
                state,
                state + READER,
                .Acquire,
                .Monotonic,
            ) orelse return true;
        }
    }

    fn acquireShared(self: *Impl) void {
        return self.acquireSharedAccess(null) catch unreachable;
    }

    fn timedAcquireShared(self: *Impl, timeout_ns: u64) error{TimedOut}!void {
        return self.acquireSharedAccess(timeout_ns);
    }

    fn acquireSharedAccess(self: *Impl, maybe_timeout_ns: ?u64) error{TimedOut}!void {
        // Try to acquire shared access to the RwLock by 
        // bumping the READER count if there's no (pending) writers.
        // Acquire barrier to make updates visible by previous writer threads. 
        var state = self.state.load(.Monotonic);
        while (true) {
            if (state & (IS_WRITING | WRITER_MASK) != 0) {
                break;
            }

            state = self.state.tryCompareAndSwap(
                state,
                state + READER,
                .Acquire,
                .Monotonic,
            ) orelse return;
        }

        // If there's (pending) writers, we need to block on the mutex before reading.
        blk: {
            const timeout_ns = maybe_timeout_ns orelse break :blk self.mutex.acquire();
            try self.mutex.timedAcquire(timeout_ns);
        }

        // Writers are made visible by the mutex acquire so relaxed READER update is fine.
        _ = self.state.fetchAdd(READER, .Monotonic);
        self.mutex.release();
    }

    fn releaseShared(self: *Impl) void {
        // Remove a reader from the RwLock to release shared access.
        // Release barrier to prevent the protected memory accesses from
        // being reordered after the release of shared acceess.
        const state = self.state.fetchSub(READER, .Release);

        // Notify a waiting writer thread if we're the last
        // reader to exit while theres a writer waiting for exclusive ownership.
        if ((state & READER_MASK == READER) and (state & IS_WRITING != 0)) {
            self.semaphore.post();
        }
    }

    fn release(self: *Impl) void {
        const state = self.state.load(.Monotonic);
        if (state & READER_MASK != 0) {
            self.releaseShared();
        } else {
            self.releaseExclusive();
        }
    }
};

test "RwLock" {
    return error.TODO;
}