// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2020 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.
const std = @import("std");
const ThreadPool = @This();

mutex: std.Thread.Mutex = .{},
cond: std.Thread.Condvar = .{},
is_running: bool = true,
allocator: *std.mem.Allocator,
workers: []Worker,
run_queue: RunQueue = .{},

const RunQueue = std.SinglyLinkedList(Runnable);
const Runnable = struct {
    runFn: fn (*Runnable) void,
};

const Worker = struct {
    pool: *ThreadPool,
    thread: std.Thread,

    fn run(worker: *Worker) void {
        while (true) {
            const run_node = blk: {
                var held = worker.pool.mutex.acquire();
                defer held.release();

                while (worker.pool.is_running) {
                    break :blk worker.pool.run_queue.popFirst() orelse {
                        worker.pool.cond.wait(&held);
                        continue;
                    };
                }

                return;
            };

            const runnable = &run_node.data;
            (runnable.runFn)(runnable);
        }
    }
};

pub fn init(self: *ThreadPool, allocator: *std.mem.Allocator) !void {
    self.* = .{
        .allocator = allocator,
        .workers = &[_]Worker{},
    };
    if (std.builtin.single_threaded)
        return;

    const worker_count = std.math.max(1, std.Thread.getCpuCount() catch 1);
    self.workers = try allocator.alloc(Worker, worker_count);
    errdefer allocator.free(self.workers);

    var worker_index: usize = 0;
    errdefer self.destroyWorkers(worker_index);
    while (worker_index < worker_count) : (worker_index += 1) {
        const worker = &self.workers[worker_index];
        worker.pool = self;
        worker.thread = try std.Thread.spawn(.{}, Worker.run, .{worker});
    }
}

fn destroyWorkers(self: *ThreadPool, spawned: usize) void {
    for (self.workers[0..spawned]) |*worker| {
        worker.thread.join();
    }
}

pub fn deinit(self: *ThreadPool) void {
    {
        const held = self.mutex.acquire();
        defer held.release();

        self.is_running = false;
        self.cond.broadcast();
    }

    self.destroyWorkers(self.workers.len);
    self.allocator.free(self.workers);
}

pub fn spawn(self: *ThreadPool, comptime func: anytype, args: anytype) !void {
    if (std.builtin.single_threaded) {
        @call(.{}, func, args);
        return;
    }

    const Args = @TypeOf(args);
    const Closure = struct {
        arguments: Args,
        pool: *ThreadPool,
        run_node: RunQueue.Node = .{ .data = .{ .runFn = runFn } },

        fn runFn(runnable: *Runnable) void {
            const run_node = @fieldParentPtr(RunQueue.Node, "data", runnable);
            const closure = @fieldParentPtr(@This(), "run_node", run_node);
            @call(.{}, func, closure.arguments);

            const held = closure.pool.mutex.acquire();
            defer held.release();

            closure.pool.allocator.destroy(closure);
        }
    };

    const held = self.mutex.acquire();
    defer held.release();

    const closure = try self.allocator.create(Closure);
    closure.* = .{
        .arguments = args,
        .pool = self,
    };

    self.run_queue.prepend(&closure.run_node);
    self.cond.signal();
}
