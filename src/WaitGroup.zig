// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2020 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.
const std = @import("std");
const WaitGroup = @This();

counter: usize = 0,
mutex: std.Thread.Mutex = .{},
cond: std.Thread.Condvar = .{},

pub fn init(self: *WaitGroup) !void {
    self.* = .{};
}

pub fn deinit(self: *WaitGroup) void {
    self.* = undefined;
}

pub fn start(self: *WaitGroup) void {
    const held = self.mutex.acquire();
    defer held.release();

    self.counter += 1;
}

pub fn finish(self: *WaitGroup) void {
    const held = self.mutex.acquire();
    defer held.release();

    self.counter -= 1;
    if (self.counter == 0) {
        self.cond.signal();
    }
}

pub fn wait(self: *WaitGroup) void {
    var held = self.mutex.acquire();
    defer held.release();

    while (self.counter != 0) {
        self.cond.wait(&held);
    }
}

pub fn reset(self: *WaitGroup) void {
    const held = self.mutex.acquire();
    defer held.release();

    self.counter = 0;
}
