const std = @import("../index.zig");
const os = std.os;
const assert = std.debug.assert;
const io = std.io;

const a = std.debug.global_allocator;

const builtin = @import("builtin");
const AtomicRmwOp = builtin.AtomicRmwOp;
const AtomicOrder = builtin.AtomicOrder;

test "makePath, put some files in it, deleteTree" {
    try os.makePath(a, "os_test_tmp" ++ os.path.sep_str ++ "b" ++ os.path.sep_str ++ "c");
    try io.writeFile("os_test_tmp" ++ os.path.sep_str ++ "b" ++ os.path.sep_str ++ "c" ++ os.path.sep_str ++ "file.txt", "nonsense");
    try io.writeFile("os_test_tmp" ++ os.path.sep_str ++ "b" ++ os.path.sep_str ++ "file2.txt", "blah");
    try os.deleteTree(a, "os_test_tmp");
    if (os.Dir.open(a, "os_test_tmp")) |dir| {
        @panic("expected error");
    } else |err| {
        assert(err == error.FileNotFound);
    }
}

test "access file" {
    try os.makePath(a, "os_test_tmp");
    if (os.File.access("os_test_tmp" ++ os.path.sep_str ++ "file.txt")) |ok| {
        @panic("expected error");
    } else |err| {
        assert(err == error.FileNotFound);
    }

    try io.writeFile("os_test_tmp" ++ os.path.sep_str ++ "file.txt", "");
    try os.File.access("os_test_tmp" ++ os.path.sep_str ++ "file.txt");
    try os.deleteTree(a, "os_test_tmp");
}

fn testThreadIdFn(thread_id: *os.Thread.Id) void {
    thread_id.* = os.Thread.getCurrentId();
}

test "std.os.Thread.getCurrentId" {
    var thread_current_id: os.Thread.Id = undefined;
    const thread = try os.spawnThread(&thread_current_id, testThreadIdFn);
    const thread_id = thread.handle();
    thread.wait();
    switch (builtin.os) {
        builtin.Os.windows => assert(os.Thread.getCurrentId() != thread_current_id),
        else => {
            assert(thread_current_id == thread_id);
        },
    }
}

test "spawn threads" {
    var shared_ctx: i32 = 1;

    const thread1 = try std.os.spawnThread({}, start1);
    const thread2 = try std.os.spawnThread(&shared_ctx, start2);
    const thread3 = try std.os.spawnThread(&shared_ctx, start2);
    const thread4 = try std.os.spawnThread(&shared_ctx, start2);

    thread1.wait();
    thread2.wait();
    thread3.wait();
    thread4.wait();

    assert(shared_ctx == 4);
}

fn start1(ctx: void) u8 {
    return 0;
}

fn start2(ctx: *i32) u8 {
    _ = @atomicRmw(i32, ctx, AtomicRmwOp.Add, 1, AtomicOrder.SeqCst);
    return 0;
}

test "cpu count" {
    const cpu_count = try std.os.cpuCount(a);
    assert(cpu_count >= 1);
}
