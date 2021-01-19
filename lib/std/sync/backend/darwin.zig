// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.

const std = @import("../../std.zig");
const darwin = std.os.darwin;
const futex = @import("./futex.zig");
const atomic = @import("../atomic.zig");

pub usingnamespace futex.Backend(struct {
    pub fn wait(ptr: *const u32, expect: u32, timeout: ?u64) void {
        var timeout_us = std.math.maxInt(u32);
        if (timeout) |timeout_ns|
            timeout_us = @intCast(u32, @divFloor(timeout_ns, std.time.ns_per_us));

        const ret = darwin.__ulock_wait(
            darwin.UL_COMPARE_AND_WAIT | darwin.ULF_NO_ERRNO,
            @ptrCast(*c_void, ptr),
            @as(u64, expect),
            timeout_us,
        );

        if (ret < 0) {
            switch (-ret) {
                darwin.EINTR => {},
                darwin.EFAULT => {},
                darwin.ETIMEDOUT => {},
                else => unreachable,
            }
        }
    }

    pub fn wake(ptr: *const u32) void {
        while (true) {
            const ret = __ulock_wake(
                darwin.UL_COMPARE_AND_WAIT,
                @ptrCast(*c_void, ptr),
                @as(u64, 0),
            );

            if (ret < 0) {
                switch (-ret) {
                    system.ENOENT => {},
                    system.EINTR => continue,
                    else => unreachable,
                }
            }

            return;
        }
    }

    pub fn yield(iteration: ?usize) bool {
        const max_iter = 100;

        var iter = iteration orelse max_iter;
        if (iter > max_iter)
            return false;

        while (iter > 0) : (iter -= 1)
            atomic.spinLoopHint();

        return true;
    }
});