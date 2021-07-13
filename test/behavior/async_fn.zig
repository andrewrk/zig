const std = @import("std");
const builtin = @import("builtin");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

var global_x: i32 = 1;

test "simple coroutine suspend and resume" {
    var frame = async simpleAsyncFn();
    try expectEqual(global_x, 2);
    resume frame;
    try expectEqual(global_x, 3);
    const af: anyframe->void = &frame;
    _ = af;
    resume frame;
    try expectEqual(global_x, 4);
}
fn simpleAsyncFn() void {
    global_x += 1;
    suspend {}
    global_x += 1;
    suspend {}
    global_x += 1;
}

var global_y: i32 = 1;

test "pass parameter to coroutine" {
    var p = async simpleAsyncFnWithArg(2);
    try expectEqual(global_y, 3);
    resume p;
    try expectEqual(global_y, 5);
}
fn simpleAsyncFnWithArg(delta: i32) void {
    global_y += delta;
    suspend {}
    global_y += delta;
}

test "suspend at end of function" {
    const S = struct {
        var x: i32 = 1;

        fn doTheTest() !void {
            try expectEqual(x, 1);
            const p = async suspendAtEnd();
            _ = p;
            try expectEqual(x, 2);
        }

        fn suspendAtEnd() void {
            x += 1;
            suspend {}
        }
    };
    try S.doTheTest();
}

test "local variable in async function" {
    const S = struct {
        var x: i32 = 0;

        fn doTheTest() !void {
            try expectEqual(x, 0);
            var p = async add(1, 2);
            try expectEqual(x, 0);
            resume p;
            try expectEqual(x, 0);
            resume p;
            try expectEqual(x, 0);
            resume p;
            try expectEqual(x, 3);
        }

        fn add(a: i32, b: i32) void {
            var accum: i32 = 0;
            suspend {}
            accum += a;
            suspend {}
            accum += b;
            suspend {}
            x = accum;
        }
    };
    try S.doTheTest();
}

test "calling an inferred async function" {
    const S = struct {
        var x: i32 = 1;
        var other_frame: *@Frame(other) = undefined;

        fn doTheTest() !void {
            _ = async first();
            try expectEqual(x, 1);
            resume other_frame.*;
            try expectEqual(x, 2);
        }

        fn first() void {
            other();
        }
        fn other() void {
            other_frame = @frame();
            suspend {}
            x += 1;
        }
    };
    try S.doTheTest();
}

test "@frameSize" {
    if (builtin.target.cpu.arch == .thumb or builtin.target.cpu.arch == .thumbeb)
        return error.SkipZigTest;

    const S = struct {
        fn doTheTest() !void {
            {
                var ptr = @ptrCast(fn (i32) callconv(.Async) void, other);
                const size = @frameSize(ptr);
                try expectEqual(size, @sizeOf(@Frame(other)));
            }
            {
                var ptr = @ptrCast(fn () callconv(.Async) void, first);
                const size = @frameSize(ptr);
                try expectEqual(size, @sizeOf(@Frame(first)));
            }
        }

        fn first() void {
            other(1);
        }
        fn other(param: i32) void {
            _ = param;
            var local: i32 = undefined;
            _ = local;
            suspend {}
        }
    };
    try S.doTheTest();
}

test "coroutine suspend, resume" {
    const S = struct {
        var frame: anyframe = undefined;

        fn doTheTest() !void {
            _ = async amain();
            seq('d');
            resume frame;
            seq('h');

            try expect(std.mem.eql(u8, &points, "abcdefgh"));
        }

        fn amain() void {
            seq('a');
            var f = async testAsyncSeq();
            seq('c');
            await f;
            seq('g');
        }

        fn testAsyncSeq() void {
            defer seq('f');

            seq('b');
            suspend {
                frame = @frame();
            }
            seq('e');
        }
        var points = [_]u8{'x'} ** "abcdefgh".len;
        var index: usize = 0;

        fn seq(c: u8) void {
            points[index] = c;
            index += 1;
        }
    };
    try S.doTheTest();
}

test "coroutine suspend with block" {
    const p = async testSuspendBlock();
    _ = p;
    try expect(!global_result);
    resume a_promise;
    try expect(global_result);
}

var a_promise: anyframe = undefined;
var global_result = false;
fn testSuspendBlock() callconv(.Async) void {
    suspend {
        comptime expectEqual(@TypeOf(@frame()), *@Frame(testSuspendBlock)) catch unreachable;
        a_promise = @frame();
    }

    // Test to make sure that @frame() works as advertised (issue #1296)
    // var our_handle: anyframe = @frame();
    expect(a_promise == @as(anyframe, @frame())) catch @panic("test failed");

    global_result = true;
}

var await_a_promise: anyframe = undefined;
var await_final_result: i32 = 0;

test "coroutine await" {
    await_seq('a');
    var p = async await_amain();
    _ = p;
    await_seq('f');
    resume await_a_promise;
    await_seq('i');
    try expectEqual(await_final_result, 1234);
    try expect(std.mem.eql(u8, &await_points, "abcdefghi"));
}
fn await_amain() callconv(.Async) void {
    await_seq('b');
    var p = async await_another();
    await_seq('e');
    await_final_result = await p;
    await_seq('h');
}
fn await_another() callconv(.Async) i32 {
    await_seq('c');
    suspend {
        await_seq('d');
        await_a_promise = @frame();
    }
    await_seq('g');
    return 1234;
}

var await_points = [_]u8{0} ** "abcdefghi".len;
var await_seq_index: usize = 0;

fn await_seq(c: u8) void {
    await_points[await_seq_index] = c;
    await_seq_index += 1;
}

var early_final_result: i32 = 0;

test "coroutine await early return" {
    early_seq('a');
    var p = async early_amain();
    _ = p;
    early_seq('f');
    try expectEqual(early_final_result, 1234);
    try expect(std.mem.eql(u8, &early_points, "abcdef"));
}
fn early_amain() callconv(.Async) void {
    early_seq('b');
    var p = async early_another();
    early_seq('d');
    early_final_result = await p;
    early_seq('e');
}
fn early_another() callconv(.Async) i32 {
    early_seq('c');
    return 1234;
}

var early_points = [_]u8{0} ** "abcdef".len;
var early_seq_index: usize = 0;

fn early_seq(c: u8) void {
    early_points[early_seq_index] = c;
    early_seq_index += 1;
}

test "async function with dot syntax" {
    const S = struct {
        var y: i32 = 1;
        fn foo() callconv(.Async) void {
            y += 1;
            suspend {}
        }
    };
    const p = async S.foo();
    _ = p;
    try expectEqual(S.y, 2);
}

test "async fn pointer in a struct field" {
    var data: i32 = 1;
    const Foo = struct {
        bar: fn (*i32) callconv(.Async) void,
    };
    var foo = Foo{ .bar = simpleAsyncFn2 };
    var bytes: [64]u8 align(16) = undefined;
    const f = @asyncCall(&bytes, {}, foo.bar, .{&data});
    comptime try expectEqual(@TypeOf(f), anyframe->void);
    try expectEqual(data, 2);
    resume f;
    try expectEqual(data, 4);
    _ = async doTheAwait(f);
    try expectEqual(data, 4);
}

fn doTheAwait(f: anyframe->void) void {
    await f;
}
fn simpleAsyncFn2(y: *i32) callconv(.Async) void {
    defer y.* += 2;
    y.* += 1;
    suspend {}
}

test "@asyncCall with return type" {
    const Foo = struct {
        bar: fn () callconv(.Async) i32,

        var global_frame: anyframe = undefined;
        fn middle() callconv(.Async) i32 {
            return afunc();
        }

        fn afunc() i32 {
            global_frame = @frame();
            suspend {}
            return 1234;
        }
    };
    var foo = Foo{ .bar = Foo.middle };
    var bytes: [150]u8 align(16) = undefined;
    var aresult: i32 = 0;
    _ = @asyncCall(&bytes, &aresult, foo.bar, .{});
    try expectEqual(aresult, 0);
    resume Foo.global_frame;
    try expectEqual(aresult, 1234);
}

test "async fn with inferred error set" {
    const S = struct {
        var global_frame: anyframe = undefined;

        fn doTheTest() !void {
            var frame: [1]@Frame(middle) = undefined;
            var fn_ptr = middle;
            var result: @typeInfo(@typeInfo(@TypeOf(fn_ptr)).Fn.return_type.?).ErrorUnion.error_set!void = undefined;
            _ = @asyncCall(std.mem.sliceAsBytes(frame[0..]), &result, fn_ptr, .{});
            resume global_frame;
            try std.testing.expectError(error.Fail, result);
        }
        fn middle() callconv(.Async) !void {
            var f = async middle2();
            return await f;
        }

        fn middle2() !void {
            return failing();
        }

        fn failing() !void {
            global_frame = @frame();
            suspend {}
            return error.Fail;
        }
    };
    try S.doTheTest();
}

test "error return trace across suspend points - early return" {
    const p = nonFailing();
    resume p;
    const p2 = async printTrace(p);
    _ = p2;
}

test "error return trace across suspend points - async return" {
    const p = nonFailing();
    const p2 = async printTrace(p);
    _ = p2;
    resume p;
}

fn nonFailing() (anyframe->anyerror!void) {
    const Static = struct {
        var frame: @Frame(suspendThenFail) = undefined;
    };
    Static.frame = async suspendThenFail();
    return &Static.frame;
}
fn suspendThenFail() callconv(.Async) anyerror!void {
    suspend {}
    return error.Fail;
}
fn printTrace(p: anyframe->(anyerror!void)) callconv(.Async) void {
    (await p) catch |e| {
        std.testing.expectEqual(e, error.Fail) catch @panic("test failure");
        if (@errorReturnTrace()) |trace| {
            expectEqual(trace.index, 1) catch @panic("test failure");
        } else switch (builtin.mode) {
            .Debug, .ReleaseSafe => @panic("expected return trace"),
            .ReleaseFast, .ReleaseSmall => {},
        }
    };
}

test "break from suspend" {
    var my_result: i32 = 1;
    const p = async testBreakFromSuspend(&my_result);
    _ = p;
    try std.testing.expectEqual(my_result, 2);
}
fn testBreakFromSuspend(my_result: *i32) callconv(.Async) void {
    suspend {
        resume @frame();
    }
    my_result.* += 1;
    suspend {}
    my_result.* += 1;
}

test "heap allocated async function frame" {
    const S = struct {
        var x: i32 = 42;

        fn doTheTest() !void {
            const frame = try std.testing.allocator.create(@Frame(someFunc));
            defer std.testing.allocator.destroy(frame);

            try expectEqual(x, 42);
            frame.* = async someFunc();
            try expectEqual(x, 43);
            resume frame;
            try expectEqual(x, 44);
        }

        fn someFunc() void {
            x += 1;
            suspend {}
            x += 1;
        }
    };
    try S.doTheTest();
}

test "async function call return value" {
    const S = struct {
        var frame: anyframe = undefined;
        var pt = Point{ .x = 10, .y = 11 };

        fn doTheTest() !void {
            try expectEqual(pt.x, 10);
            try expectEqual(pt.y, 11);
            _ = async first();
            try expectEqual(pt.x, 10);
            try expectEqual(pt.y, 11);
            resume frame;
            try expectEqual(pt.x, 1);
            try expectEqual(pt.y, 2);
        }

        fn first() void {
            pt = second(1, 2);
        }

        fn second(x: i32, y: i32) Point {
            return other(x, y);
        }

        fn other(x: i32, y: i32) Point {
            frame = @frame();
            suspend {}
            return Point{
                .x = x,
                .y = y,
            };
        }

        const Point = struct {
            x: i32,
            y: i32,
        };
    };
    try S.doTheTest();
}

test "suspension points inside branching control flow" {
    const S = struct {
        var result: i32 = 10;

        fn doTheTest() !void {
            try expectEqual(result, 10);
            var frame = async func(true);
            try expectEqual(result, 10);
            resume frame;
            try expectEqual(result, 11);
            resume frame;
            try expectEqual(result, 12);
            resume frame;
            try expectEqual(result, 13);
        }

        fn func(b: bool) void {
            while (b) {
                suspend {}
                result += 1;
            }
        }
    };
    try S.doTheTest();
}

test "call async function which has struct return type" {
    const S = struct {
        var frame: anyframe = undefined;

        fn doTheTest() void {
            _ = async atest();
            resume frame;
        }

        fn atest() void {
            const result = func();
            expectEqual(result.x, 5) catch @panic("test failed");
            expectEqual(result.y, 6) catch @panic("test failed");
        }

        const Point = struct {
            x: usize,
            y: usize,
        };

        fn func() Point {
            suspend {
                frame = @frame();
            }
            return Point{
                .x = 5,
                .y = 6,
            };
        }
    };
    S.doTheTest();
}

test "pass string literal to async function" {
    const S = struct {
        var frame: anyframe = undefined;
        var ok: bool = false;

        fn doTheTest() !void {
            _ = async hello("hello");
            resume frame;
            try expect(ok);
        }

        fn hello(msg: []const u8) void {
            frame = @frame();
            suspend {}
            expectEqualStrings("hello", msg) catch @panic("test failed");
            ok = true;
        }
    };
    try S.doTheTest();
}

test "await inside an errdefer" {
    const S = struct {
        var frame: anyframe = undefined;

        fn doTheTest() !void {
            _ = async amainWrap();
            resume frame;
        }

        fn amainWrap() !void {
            var foo = async func();
            errdefer await foo;
            return error.Bad;
        }

        fn func() void {
            frame = @frame();
            suspend {}
        }
    };
    try S.doTheTest();
}

test "try in an async function with error union and non-zero-bit payload" {
    const S = struct {
        var frame: anyframe = undefined;
        var ok = false;

        fn doTheTest() !void {
            _ = async amain();
            resume frame;
            try expect(ok);
        }

        fn amain() void {
            std.testing.expectError(error.Bad, theProblem()) catch @panic("test failed");
            ok = true;
        }

        fn theProblem() ![]u8 {
            frame = @frame();
            suspend {}
            const result = try other();
            return result;
        }

        fn other() ![]u8 {
            return error.Bad;
        }
    };
    try S.doTheTest();
}

test "returning a const error from async function" {
    const S = struct {
        var frame: anyframe = undefined;
        var ok = false;

        fn doTheTest() !void {
            _ = async amain();
            resume frame;
            try expect(ok);
        }

        fn amain() !void {
            var download_frame = async fetchUrl(10, "a string");
            const download_text = try await download_frame;
            _ = download_text;

            @panic("should not get here");
        }

        fn fetchUrl(unused: i32, url: []const u8) ![]u8 {
            _ = unused;
            _ = url;
            frame = @frame();
            suspend {}
            ok = true;
            return error.OutOfMemory;
        }
    };
    try S.doTheTest();
}

test "async/await typical usage" {
    inline for ([_]bool{ false, true }) |b1| {
        inline for ([_]bool{ false, true }) |b2| {
            inline for ([_]bool{ false, true }) |b3| {
                inline for ([_]bool{ false, true }) |b4| {
                    testAsyncAwaitTypicalUsage(b1, b2, b3, b4).doTheTest();
                }
            }
        }
    }
}

fn testAsyncAwaitTypicalUsage(
    comptime simulate_fail_download: bool,
    comptime simulate_fail_file: bool,
    comptime suspend_download: bool,
    comptime suspend_file: bool,
) type {
    return struct {
        fn doTheTest() void {
            _ = async amainWrap();
            if (suspend_file) {
                resume global_file_frame;
            }
            if (suspend_download) {
                resume global_download_frame;
            }
        }
        fn amainWrap() void {
            if (amain()) |_| {
                expect(!simulate_fail_download) catch @panic("test failure");
                expect(!simulate_fail_file) catch @panic("test failure");
            } else |e| switch (e) {
                error.NoResponse => expect(simulate_fail_download) catch @panic("test failure"),
                error.FileNotFound => expect(simulate_fail_file) catch @panic("test failure"),
                else => @panic("test failure"),
            }
        }

        fn amain() !void {
            const allocator = std.testing.allocator;
            var download_frame = async fetchUrl(allocator, "https://example.com/");
            var download_awaited = false;
            errdefer if (!download_awaited) {
                if (await download_frame) |x| allocator.free(x) else |_| {}
            };

            var file_frame = async readFile(allocator, "something.txt");
            var file_awaited = false;
            errdefer if (!file_awaited) {
                if (await file_frame) |x| allocator.free(x) else |_| {}
            };

            download_awaited = true;
            const download_text = try await download_frame;
            defer allocator.free(download_text);

            file_awaited = true;
            const file_text = try await file_frame;
            defer allocator.free(file_text);

            try expect(std.mem.eql(u8, "expected download text", download_text));
            try expect(std.mem.eql(u8, "expected file text", file_text));
        }

        var global_download_frame: anyframe = undefined;
        fn fetchUrl(allocator: *std.mem.Allocator, url: []const u8) anyerror![]u8 {
            _ = url;
            const result = try std.mem.dupe(allocator, u8, "expected download text");
            errdefer allocator.free(result);
            if (suspend_download) {
                suspend {
                    global_download_frame = @frame();
                }
            }
            if (simulate_fail_download) return error.NoResponse;
            return result;
        }

        var global_file_frame: anyframe = undefined;
        fn readFile(allocator: *std.mem.Allocator, filename: []const u8) anyerror![]u8 {
            _ = filename;
            const result = try std.mem.dupe(allocator, u8, "expected file text");
            errdefer allocator.free(result);
            if (suspend_file) {
                suspend {
                    global_file_frame = @frame();
                }
            }
            if (simulate_fail_file) return error.FileNotFound;
            return result;
        }
    };
}

test "alignment of local variables in async functions" {
    const S = struct {
        fn doTheTest() !void {
            var y: u8 = 123;
            _ = y;
            var x: u8 align(128) = 1;
            try expectEqual(@ptrToInt(&x) % 128, 0);
        }
    };
    try S.doTheTest();
}

test "no reason to resolve frame still works" {
    _ = async simpleNothing();
}
fn simpleNothing() void {
    var x: i32 = 1234;
    _ = x;
}

test "async call a generic function" {
    const S = struct {
        fn doTheTest() !void {
            var f = async func(i32, 2);
            const result = await f;
            try expectEqual(result, 3);
        }

        fn func(comptime T: type, inc: T) T {
            var x: T = 1;
            suspend {
                resume @frame();
            }
            x += inc;
            return x;
        }
    };
    _ = async S.doTheTest();
}

test "return from suspend block" {
    const S = struct {
        fn doTheTest() !void {
            expectEqual(func(), 1234) catch @panic("test failure");
        }
        fn func() i32 {
            suspend {
                return 1234;
            }
        }
    };
    _ = async S.doTheTest();
}

test "struct parameter to async function is copied to the frame" {
    const S = struct {
        const Point = struct {
            x: i32,
            y: i32,
        };

        var frame: anyframe = undefined;

        fn doTheTest() void {
            _ = async atest();
            resume frame;
        }

        fn atest() void {
            var f: @Frame(foo) = undefined;
            bar(&f);
            clobberStack(10);
        }

        fn clobberStack(x: i32) void {
            if (x == 0) return;
            clobberStack(x - 1);
            var y: i32 = x;
            _ = y;
        }

        fn bar(f: *@Frame(foo)) void {
            var pt = Point{ .x = 1, .y = 2 };
            f.* = async foo(pt);
            var result = await f;
            expectEqual(result, 1) catch @panic("test failure");
        }

        fn foo(point: Point) i32 {
            suspend {
                frame = @frame();
            }
            return point.x;
        }
    };
    S.doTheTest();
}

test "cast fn to async fn when it is inferred to be async" {
    const S = struct {
        var frame: anyframe = undefined;
        var ok = false;

        fn doTheTest() void {
            var ptr: fn () callconv(.Async) i32 = undefined;
            ptr = func;
            var buf: [100]u8 align(16) = undefined;
            var result: i32 = undefined;
            const f = @asyncCall(&buf, &result, ptr, .{});
            _ = await f;
            expectEqual(result, 1234) catch @panic("test failure");
            ok = true;
        }

        fn func() i32 {
            suspend {
                frame = @frame();
            }
            return 1234;
        }
    };
    _ = async S.doTheTest();
    resume S.frame;
    try expect(S.ok);
}

test "cast fn to async fn when it is inferred to be async, awaited directly" {
    const S = struct {
        var frame: anyframe = undefined;
        var ok = false;

        fn doTheTest() void {
            var ptr: fn () callconv(.Async) i32 = undefined;
            ptr = func;
            var buf: [100]u8 align(16) = undefined;
            var result: i32 = undefined;
            _ = await @asyncCall(&buf, &result, ptr, .{});
            expectEqual(result, 1234) catch @panic("test failure");
            ok = true;
        }

        fn func() i32 {
            suspend {
                frame = @frame();
            }
            return 1234;
        }
    };
    _ = async S.doTheTest();
    resume S.frame;
    try expect(S.ok);
}

test "await does not force async if callee is blocking" {
    const S = struct {
        fn simple() i32 {
            return 1234;
        }
    };
    var x = async S.simple();
    try expectEqual(await x, 1234);
}

test "recursive async function" {
    try expectEqual(recursiveAsyncFunctionTest(false).doTheTest(), 55);
    try expectEqual(recursiveAsyncFunctionTest(true).doTheTest(), 55);
}

fn recursiveAsyncFunctionTest(comptime suspending_implementation: bool) type {
    return struct {
        fn fib(allocator: *std.mem.Allocator, x: u32) error{OutOfMemory}!u32 {
            if (x <= 1) return x;

            if (suspending_implementation) {
                suspend {
                    resume @frame();
                }
            }

            const f1 = try allocator.create(@Frame(fib));
            defer allocator.destroy(f1);

            const f2 = try allocator.create(@Frame(fib));
            defer allocator.destroy(f2);

            f1.* = async fib(allocator, x - 1);
            var f1_awaited = false;
            errdefer if (!f1_awaited) {
                _ = await f1;
            };

            f2.* = async fib(allocator, x - 2);
            var f2_awaited = false;
            errdefer if (!f2_awaited) {
                _ = await f2;
            };

            var sum: u32 = 0;

            f1_awaited = true;
            sum += try await f1;

            f2_awaited = true;
            sum += try await f2;

            return sum;
        }

        fn doTheTest() u32 {
            if (suspending_implementation) {
                var result: u32 = undefined;
                _ = async amain(&result);
                return result;
            } else {
                return fib(std.testing.allocator, 10) catch unreachable;
            }
        }

        fn amain(result: *u32) void {
            var x = async fib(std.testing.allocator, 10);
            result.* = (await x) catch unreachable;
        }
    };
}

test "@asyncCall with comptime-known function, but not awaited directly" {
    const S = struct {
        var global_frame: anyframe = undefined;

        fn doTheTest() !void {
            var frame: [1]@Frame(middle) = undefined;
            var result: @typeInfo(@typeInfo(@TypeOf(middle)).Fn.return_type.?).ErrorUnion.error_set!void = undefined;
            _ = @asyncCall(std.mem.sliceAsBytes(frame[0..]), &result, middle, .{});
            resume global_frame;
            try std.testing.expectError(error.Fail, result);
        }
        fn middle() callconv(.Async) !void {
            var f = async middle2();
            return await f;
        }

        fn middle2() !void {
            return failing();
        }

        fn failing() !void {
            global_frame = @frame();
            suspend {}
            return error.Fail;
        }
    };
    try S.doTheTest();
}

test "@asyncCall with actual frame instead of byte buffer" {
    const S = struct {
        fn func() i32 {
            suspend {}
            return 1234;
        }
    };
    var frame: @Frame(S.func) = undefined;
    var result: i32 = undefined;
    const ptr = @asyncCall(&frame, &result, S.func, .{});
    resume ptr;
    try expectEqual(result, 1234);
}

test "@asyncCall using the result location inside the frame" {
    const S = struct {
        fn simple2(y: *i32) callconv(.Async) i32 {
            defer y.* += 2;
            y.* += 1;
            suspend {}
            return 1234;
        }
        fn getAnswer(f: anyframe->i32, out: *i32) void {
            out.* = await f;
        }
    };
    var data: i32 = 1;
    const Foo = struct {
        bar: fn (*i32) callconv(.Async) i32,
    };
    var foo = Foo{ .bar = S.simple2 };
    var bytes: [64]u8 align(16) = undefined;
    const f = @asyncCall(&bytes, {}, foo.bar, .{&data});
    comptime try expectEqual(@TypeOf(f), anyframe->i32);
    try expectEqual(data, 2);
    resume f;
    try expectEqual(data, 4);
    _ = async S.getAnswer(f, &data);
    try expectEqual(data, 1234);
}

test "@TypeOf an async function call of generic fn with error union type" {
    const S = struct {
        fn func(comptime x: anytype) anyerror!i32 {
            const T = @TypeOf(async func(x));
            comptime try expectEqual(T, @typeInfo(@TypeOf(@frame())).Pointer.child);
            return undefined;
        }
    };
    _ = async S.func(i32);
}

test "using @TypeOf on a generic function call" {
    const S = struct {
        var global_frame: anyframe = undefined;
        var global_ok = false;

        var buf: [100]u8 align(16) = undefined;

        fn amain(x: anytype) void {
            if (x == 0) {
                global_ok = true;
                return;
            }
            suspend {
                global_frame = @frame();
            }
            const F = @TypeOf(async amain(x - 1));
            const frame = @intToPtr(*F, @ptrToInt(&buf));
            return await @asyncCall(frame, {}, amain, .{x - 1});
        }
    };
    _ = async S.amain(@as(u32, 1));
    resume S.global_frame;
    try expect(S.global_ok);
}

test "recursive call of await @asyncCall with struct return type" {
    const S = struct {
        var global_frame: anyframe = undefined;
        var global_ok = false;

        var buf: [100]u8 align(16) = undefined;

        fn amain(x: anytype) Foo {
            if (x == 0) {
                global_ok = true;
                return Foo{ .x = 1, .y = 2, .z = 3 };
            }
            suspend {
                global_frame = @frame();
            }
            const F = @TypeOf(async amain(x - 1));
            const frame = @intToPtr(*F, @ptrToInt(&buf));
            return await @asyncCall(frame, {}, amain, .{x - 1});
        }

        const Foo = struct {
            x: u64,
            y: u64,
            z: u64,
        };
    };
    var res: S.Foo = undefined;
    var frame: @TypeOf(async S.amain(@as(u32, 1))) = undefined;
    _ = @asyncCall(&frame, &res, S.amain, .{@as(u32, 1)});
    resume S.global_frame;
    try expect(S.global_ok);
    try expectEqual(res.x, 1);
    try expectEqual(res.y, 2);
    try expectEqual(res.z, 3);
}

test "nosuspend function call" {
    const S = struct {
        fn doTheTest() !void {
            const result = nosuspend add(50, 100);
            try expectEqual(result, 150);
        }
        fn add(a: i32, b: i32) i32 {
            if (a > 100) {
                suspend {}
            }
            return a + b;
        }
    };
    try S.doTheTest();
}

test "await used in expression and awaiting fn with no suspend but async calling convention" {
    const S = struct {
        fn atest() void {
            var f1 = async add(1, 2);
            var f2 = async add(3, 4);

            const sum = (await f1) + (await f2);
            expectEqual(sum, 10) catch @panic("test failure");
        }
        fn add(a: i32, b: i32) callconv(.Async) i32 {
            return a + b;
        }
    };
    _ = async S.atest();
}

test "await used in expression after a fn call" {
    const S = struct {
        fn atest() void {
            var f1 = async add(3, 4);
            var sum: i32 = 0;
            sum = foo() + await f1;
            expectEqual(sum, 8) catch @panic("test failure");
        }
        fn add(a: i32, b: i32) callconv(.Async) i32 {
            return a + b;
        }
        fn foo() i32 {
            return 1;
        }
    };
    _ = async S.atest();
}

test "async fn call used in expression after a fn call" {
    const S = struct {
        fn atest() void {
            var sum: i32 = 0;
            sum = foo() + add(3, 4);
            expectEqual(sum, 8) catch @panic("test failure");
        }
        fn add(a: i32, b: i32) callconv(.Async) i32 {
            return a + b;
        }
        fn foo() i32 {
            return 1;
        }
    };
    _ = async S.atest();
}

test "suspend in for loop" {
    const S = struct {
        var global_frame: ?anyframe = null;

        fn doTheTest() void {
            _ = async atest();
            while (global_frame) |f| resume f;
        }

        fn atest() void {
            expectEqual(func(&[_]u8{ 1, 2, 3 }), 6) catch @panic("test failure");
        }
        fn func(stuff: []const u8) u32 {
            global_frame = @frame();
            var sum: u32 = 0;
            for (stuff) |x| {
                suspend {}
                sum += x;
            }
            global_frame = null;
            return sum;
        }
    };
    S.doTheTest();
}

test "suspend in while loop" {
    const S = struct {
        var global_frame: ?anyframe = null;

        fn doTheTest() void {
            _ = async atest();
            while (global_frame) |f| resume f;
        }

        fn atest() void {
            expectEqual(optional(6), 6) catch @panic("test failure");
            expectEqual(errunion(6), 6) catch @panic("test failure");
        }
        fn optional(stuff: ?u32) u32 {
            global_frame = @frame();
            defer global_frame = null;
            while (stuff) |val| {
                suspend {}
                return val;
            }
            return 0;
        }
        fn errunion(stuff: anyerror!u32) u32 {
            global_frame = @frame();
            defer global_frame = null;
            while (stuff) |val| {
                suspend {}
                return val;
            } else |err| {
                err catch {};
                return 0;
            }
        }
    };
    S.doTheTest();
}

test "correctly spill when returning the error union result of another async fn" {
    const S = struct {
        var global_frame: anyframe = undefined;

        fn doTheTest() !void {
            expectEqual((atest() catch unreachable), 1234) catch @panic("test failure");
        }

        fn atest() !i32 {
            return fallible1();
        }

        fn fallible1() anyerror!i32 {
            suspend {
                global_frame = @frame();
            }
            return 1234;
        }
    };
    _ = async S.doTheTest();
    resume S.global_frame;
}

test "spill target expr in a for loop" {
    const S = struct {
        var global_frame: anyframe = undefined;

        fn doTheTest() !void {
            var foo = Foo{
                .slice = &[_]i32{ 1, 2 },
            };
            expectEqual(atest(&foo), 3) catch @panic("test failure");
        }

        const Foo = struct {
            slice: []const i32,
        };

        fn atest(foo: *Foo) i32 {
            var sum: i32 = 0;
            for (foo.slice) |x| {
                suspend {
                    global_frame = @frame();
                }
                sum += x;
            }
            return sum;
        }
    };
    _ = async S.doTheTest();
    resume S.global_frame;
    resume S.global_frame;
}

test "spill target expr in a for loop, with a var decl in the loop body" {
    const S = struct {
        var global_frame: anyframe = undefined;

        fn doTheTest() !void {
            var foo = Foo{
                .slice = &[_]i32{ 1, 2 },
            };
            expectEqual(atest(&foo), 3) catch @panic("test failure");
        }

        const Foo = struct {
            slice: []const i32,
        };

        fn atest(foo: *Foo) i32 {
            var sum: i32 = 0;
            for (foo.slice) |x| {
                // Previously this var decl would prevent spills. This test makes sure
                // the for loop spills still happen even though there is a VarDecl in scope
                // before the suspend.
                var anything = true;
                _ = anything;
                suspend {
                    global_frame = @frame();
                }
                sum += x;
            }
            return sum;
        }
    };
    _ = async S.doTheTest();
    resume S.global_frame;
    resume S.global_frame;
}

test "async call with @call" {
    const S = struct {
        var global_frame: anyframe = undefined;
        fn doTheTest() void {
            _ = @call(.{ .modifier = .async_kw }, atest, .{});
            resume global_frame;
        }
        fn atest() void {
            var frame = @call(.{ .modifier = .async_kw }, afoo, .{});
            const res = await frame;
            expectEqual(res, 42) catch @panic("test failure");
        }
        fn afoo() i32 {
            suspend {
                global_frame = @frame();
            }
            return 42;
        }
    };
    S.doTheTest();
}

test "async function passed 0-bit arg after non-0-bit arg" {
    const S = struct {
        var global_frame: anyframe = undefined;
        var global_int: i32 = 0;

        fn foo() void {
            bar(1, .{}) catch unreachable;
        }

        fn bar(x: i32, args: anytype) anyerror!void {
            _ = args;
            global_frame = @frame();
            suspend {}
            global_int = x;
        }
    };
    _ = async S.foo();
    resume S.global_frame;
    try expectEqual(S.global_int, 1);
}

test "async function passed align(16) arg after align(8) arg" {
    const S = struct {
        var global_frame: anyframe = undefined;
        var global_int: u128 = 0;

        fn foo() void {
            var a: u128 = 99;
            bar(10, .{a}) catch unreachable;
        }

        fn bar(x: u64, args: anytype) anyerror!void {
            try expectEqual(x, 10);
            global_frame = @frame();
            suspend {}
            global_int = args[0];
        }
    };
    _ = async S.foo();
    resume S.global_frame;
    try expectEqual(S.global_int, 99);
}

test "async function call resolves target fn frame, comptime func" {
    const S = struct {
        var global_frame: anyframe = undefined;
        var global_int: i32 = 9;

        fn foo() anyerror!void {
            const stack_size = 1000;
            var stack_frame: [stack_size]u8 align(std.Target.stack_align) = undefined;
            return await @asyncCall(&stack_frame, {}, bar, .{});
        }

        fn bar() anyerror!void {
            global_frame = @frame();
            suspend {}
            global_int += 1;
        }
    };
    _ = async S.foo();
    resume S.global_frame;
    try expectEqual(S.global_int, 10);
}

test "async function call resolves target fn frame, runtime func" {
    const S = struct {
        var global_frame: anyframe = undefined;
        var global_int: i32 = 9;

        fn foo() anyerror!void {
            const stack_size = 1000;
            var stack_frame: [stack_size]u8 align(std.Target.stack_align) = undefined;
            var func: fn () callconv(.Async) anyerror!void = bar;
            return await @asyncCall(&stack_frame, {}, func, .{});
        }

        fn bar() anyerror!void {
            global_frame = @frame();
            suspend {}
            global_int += 1;
        }
    };
    _ = async S.foo();
    resume S.global_frame;
    try expectEqual(S.global_int, 10);
}

test "properly spill optional payload capture value" {
    const S = struct {
        var global_frame: anyframe = undefined;
        var global_int: usize = 2;

        fn foo() void {
            var opt: ?usize = 1234;
            if (opt) |x| {
                bar();
                global_int += x;
            }
        }

        fn bar() void {
            global_frame = @frame();
            suspend {}
            global_int += 1;
        }
    };
    _ = async S.foo();
    resume S.global_frame;
    try expectEqual(S.global_int, 1237);
}

test "handle defer interfering with return value spill" {
    const S = struct {
        var global_frame1: anyframe = undefined;
        var global_frame2: anyframe = undefined;
        var finished = false;
        var baz_happened = false;

        fn doTheTest() !void {
            _ = async testFoo();
            resume global_frame1;
            resume global_frame2;
            try expect(baz_happened);
            try expect(finished);
        }

        fn testFoo() void {
            expectError(error.Bad, foo()) catch @panic("test failure");
            finished = true;
        }

        fn foo() anyerror!void {
            defer baz();
            return bar() catch |err| return err;
        }

        fn bar() anyerror!void {
            global_frame1 = @frame();
            suspend {}
            return error.Bad;
        }

        fn baz() void {
            global_frame2 = @frame();
            suspend {}
            baz_happened = true;
        }
    };
    try S.doTheTest();
}

test "take address of temporary async frame" {
    const S = struct {
        var global_frame: anyframe = undefined;
        var finished = false;

        fn doTheTest() !void {
            _ = async asyncDoTheTest();
            resume global_frame;
            try expect(finished);
        }

        fn asyncDoTheTest() void {
            expectEqual(finishIt(&async foo(10)), 1245) catch @panic("test failure");
            finished = true;
        }

        fn foo(arg: i32) i32 {
            global_frame = @frame();
            suspend {}
            return arg + 1234;
        }

        fn finishIt(frame: anyframe->i32) i32 {
            return (await frame) + 1;
        }
    };
    try S.doTheTest();
}

test "nosuspend await" {
    const S = struct {
        var finished = false;

        fn doTheTest() !void {
            var frame = async foo(false);
            try expectEqual(nosuspend await frame, 42);
            finished = true;
        }

        fn foo(want_suspend: bool) i32 {
            if (want_suspend) {
                suspend {}
            }
            return 42;
        }
    };
    try S.doTheTest();
    try expect(S.finished);
}

test "nosuspend on function calls" {
    const S0 = struct {
        b: i32 = 42,
    };
    const S1 = struct {
        fn c() S0 {
            return S0{};
        }
        fn d() !S0 {
            return S0{};
        }
    };
    try expectEqual(@as(i32, 42), nosuspend S1.c().b);
    try expectEqual(@as(i32, 42), (try nosuspend S1.d()).b);
}

test "nosuspend on async function calls" {
    const S0 = struct {
        b: i32 = 42,
    };
    const S1 = struct {
        fn c() S0 {
            return S0{};
        }
        fn d() !S0 {
            return S0{};
        }
    };
    var frame_c = nosuspend async S1.c();
    try expectEqual(@as(i32, 42), (await frame_c).b);
    var frame_d = nosuspend async S1.d();
    try expectEqual(@as(i32, 42), (try await frame_d).b);
}

// test "resume nosuspend async function calls" {
//     const S0 = struct {
//         b: i32 = 42,
//     };
//     const S1 = struct {
//         fn c() S0 {
//             suspend {}
//             return S0{};
//         }
//         fn d() !S0 {
//             suspend {}
//             return S0{};
//         }
//     };
//     var frame_c = nosuspend async S1.c();
//     resume frame_c;
// try expectEqual(@as(i32, 42), (await frame_c).b);
//     var frame_d = nosuspend async S1.d();
//     resume frame_d;
// try expectEqual(@as(i32, 42), (try await frame_d).b);
// }

test "nosuspend resume async function calls" {
    const S0 = struct {
        b: i32 = 42,
    };
    const S1 = struct {
        fn c() S0 {
            suspend {}
            return S0{};
        }
        fn d() !S0 {
            suspend {}
            return S0{};
        }
    };
    var frame_c = async S1.c();
    nosuspend resume frame_c;
    try expectEqual(@as(i32, 42), (await frame_c).b);
    var frame_d = async S1.d();
    nosuspend resume frame_d;
    try expectEqual(@as(i32, 42), (try await frame_d).b);
}

test "avoid forcing frame alignment resolution implicit cast to *c_void" {
    const S = struct {
        var x: ?*c_void = null;

        fn foo() bool {
            suspend {
                x = @frame();
            }
            return true;
        }
    };
    var frame = async S.foo();
    resume @ptrCast(anyframe->bool, @alignCast(@alignOf(@Frame(S.foo)), S.x));
    try expect(nosuspend await frame);
}

test "@asyncCall with pass-by-value arguments" {
    const F0: u64 = 0xbeefbeefbeefbeef;
    const F1: u64 = 0xf00df00df00df00d;
    const F2: u64 = 0xcafecafecafecafe;

    const S = struct {
        pub const ST = struct { f0: usize, f1: usize };
        pub const AT = [5]u8;

        pub fn f(_fill0: u64, s: ST, _fill1: u64, a: AT, _fill2: u64) callconv(.Async) void {
            _ = s;
            _ = a;
            // Check that the array and struct arguments passed by value don't
            // end up overflowing the adjacent fields in the frame structure.
            expectEqual(F0, _fill0) catch @panic("test failure");
            expectEqual(F1, _fill1) catch @panic("test failure");
            expectEqual(F2, _fill2) catch @panic("test failure");
        }
    };

    var buffer: [1024]u8 align(@alignOf(@Frame(S.f))) = undefined;
    // The function pointer must not be comptime-known.
    var t = S.f;
    var frame_ptr = @asyncCall(&buffer, {}, t, .{
        F0,
        .{ .f0 = 1, .f1 = 2 },
        F1,
        [_]u8{ 1, 2, 3, 4, 5 },
        F2,
    });
    _ = frame_ptr;
}

test "@asyncCall with arguments having non-standard alignment" {
    const F0: u64 = 0xbeefbeef;
    const F1: u64 = 0xf00df00df00df00d;

    const S = struct {
        pub fn f(_fill0: u32, s: struct { x: u64 align(16) }, _fill1: u64) callconv(.Async) void {
            _ = s;
            // The compiler inserts extra alignment for s, check that the
            // generated code picks the right slot for fill1.
            expectEqual(F0, _fill0) catch @panic("test failure");
            expectEqual(F1, _fill1) catch @panic("test failure");
        }
    };

    var buffer: [1024]u8 align(@alignOf(@Frame(S.f))) = undefined;
    // The function pointer must not be comptime-known.
    var t = S.f;
    var frame_ptr = @asyncCall(&buffer, {}, t, .{ F0, undefined, F1 });
    _ = frame_ptr;
}
