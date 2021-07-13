const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const builtin = @import("builtin");
const native_arch = builtin.target.cpu.arch;

var foo: u8 align(4) = 100;

test "global variable alignment" {
    comptime try expectEqual(@typeInfo(@TypeOf(&foo)).Pointer.alignment, 4);
    comptime try expectEqual(@TypeOf(&foo), *align(4) u8);
    {
        const slice = @as(*[1]u8, &foo)[0..];
        comptime try expectEqual(@TypeOf(slice), *align(4) [1]u8);
    }
    {
        var runtime_zero: usize = 0;
        const slice = @as(*[1]u8, &foo)[runtime_zero..];
        comptime try expectEqual(@TypeOf(slice), []align(4) u8);
    }
}

fn derp() align(@sizeOf(usize) * 2) i32 {
    return 1234;
}
fn noop1() align(1) void {}
fn noop4() align(4) void {}

test "function alignment" {
    // function alignment is a compile error on wasm32/wasm64
    if (native_arch == .wasm32 or native_arch == .wasm64) return error.SkipZigTest;

    try expectEqual(derp(), 1234);
    try expectEqual(@TypeOf(noop1), fn () align(1) void);
    try expectEqual(@TypeOf(noop4), fn () align(4) void);
    noop1();
    noop4();
}

var baz: packed struct {
    a: u32,
    b: u32,
} = undefined;

test "packed struct alignment" {
    try expectEqual(@TypeOf(&baz.b), *align(1) u32);
}

const blah: packed struct {
    a: u3,
    b: u3,
    c: u2,
} = undefined;

test "bit field alignment" {
    try expectEqual(@TypeOf(&blah.b), *align(1:3:1) const u3);
}

test "default alignment allows unspecified in type syntax" {
    try expectEqual(*u32, *align(@alignOf(u32)) u32);
}

test "implicitly decreasing pointer alignment" {
    const a: u32 align(4) = 3;
    const b: u32 align(8) = 4;
    try expectEqual(addUnaligned(&a, &b), 7);
}

fn addUnaligned(a: *align(1) const u32, b: *align(1) const u32) u32 {
    return a.* + b.*;
}

test "implicitly decreasing slice alignment" {
    const a: u32 align(4) = 3;
    const b: u32 align(8) = 4;
    try expectEqual(addUnalignedSlice(@as(*const [1]u32, &a)[0..], @as(*const [1]u32, &b)[0..]), 7);
}
fn addUnalignedSlice(a: []align(1) const u32, b: []align(1) const u32) u32 {
    return a[0] + b[0];
}

test "specifying alignment allows pointer cast" {
    try testBytesAlign(0x33);
}
fn testBytesAlign(b: u8) !void {
    var bytes align(4) = [_]u8{
        b,
        b,
        b,
        b,
    };
    const ptr = @ptrCast(*u32, &bytes[0]);
    try expectEqual(ptr.*, 0x33333333);
}

test "@alignCast pointers" {
    var x: u32 align(4) = 1;
    expectsOnly1(&x);
    try expectEqual(x, 2);
}
fn expectsOnly1(x: *align(1) u32) void {
    expects4(@alignCast(4, x));
}
fn expects4(x: *align(4) u32) void {
    x.* += 1;
}

test "@alignCast slices" {
    var array align(4) = [_]u32{
        1,
        1,
    };
    const slice = array[0..];
    sliceExpectsOnly1(slice);
    try expectEqual(slice[0], 2);
}
fn sliceExpectsOnly1(slice: []align(1) u32) void {
    sliceExpects4(@alignCast(4, slice));
}
fn sliceExpects4(slice: []align(4) u32) void {
    slice[0] += 1;
}

test "implicitly decreasing fn alignment" {
    // function alignment is a compile error on wasm32/wasm64
    if (native_arch == .wasm32 or native_arch == .wasm64) return error.SkipZigTest;

    try testImplicitlyDecreaseFnAlign(alignedSmall, 1234);
    try testImplicitlyDecreaseFnAlign(alignedBig, 5678);
}

fn testImplicitlyDecreaseFnAlign(ptr: fn () align(1) i32, answer: i32) !void {
    try expectEqual(ptr(), answer);
}

fn alignedSmall() align(8) i32 {
    return 1234;
}
fn alignedBig() align(16) i32 {
    return 5678;
}

test "@alignCast functions" {
    // function alignment is a compile error on wasm32/wasm64
    if (native_arch == .wasm32 or native_arch == .wasm64) return error.SkipZigTest;
    if (native_arch == .thumb) return error.SkipZigTest;

    try expectEqual(fnExpectsOnly1(simple4), 0x19);
}
fn fnExpectsOnly1(ptr: fn () align(1) i32) i32 {
    return fnExpects4(@alignCast(4, ptr));
}
fn fnExpects4(ptr: fn () align(4) i32) i32 {
    return ptr();
}
fn simple4() align(4) i32 {
    return 0x19;
}

test "generic function with align param" {
    // function alignment is a compile error on wasm32/wasm64
    if (native_arch == .wasm32 or native_arch == .wasm64) return error.SkipZigTest;
    if (native_arch == .thumb) return error.SkipZigTest;

    try expectEqual(whyWouldYouEverDoThis(1), 0x1);
    try expectEqual(whyWouldYouEverDoThis(4), 0x1);
    try expectEqual(whyWouldYouEverDoThis(8), 0x1);
}

fn whyWouldYouEverDoThis(comptime align_bytes: u8) align(align_bytes) u8 {
    _ = align_bytes;
    return 0x1;
}

test "@ptrCast preserves alignment of bigger source" {
    var x: u32 align(16) = 1234;
    const ptr = @ptrCast(*u8, &x);
    try expectEqual(@TypeOf(ptr), *align(16) u8);
}

test "runtime known array index has best alignment possible" {
    // take full advantage of over-alignment
    var array align(4) = [_]u8{ 1, 2, 3, 4 };
    try expectEqual(@TypeOf(&array[0]), *align(4) u8);
    try expectEqual(@TypeOf(&array[1]), *u8);
    try expectEqual(@TypeOf(&array[2]), *align(2) u8);
    try expectEqual(@TypeOf(&array[3]), *u8);

    // because align is too small but we still figure out to use 2
    var bigger align(2) = [_]u64{ 1, 2, 3, 4 };
    try expectEqual(@TypeOf(&bigger[0]), *align(2) u64);
    try expectEqual(@TypeOf(&bigger[1]), *align(2) u64);
    try expectEqual(@TypeOf(&bigger[2]), *align(2) u64);
    try expectEqual(@TypeOf(&bigger[3]), *align(2) u64);

    // because pointer is align 2 and u32 align % 2 == 0 we can assume align 2
    var smaller align(2) = [_]u32{ 1, 2, 3, 4 };
    var runtime_zero: usize = 0;
    comptime try expectEqual(@TypeOf(smaller[runtime_zero..]), []align(2) u32);
    comptime try expectEqual(@TypeOf(smaller[runtime_zero..].ptr), [*]align(2) u32);
    try testIndex(smaller[runtime_zero..].ptr, 0, *align(2) u32);
    try testIndex(smaller[runtime_zero..].ptr, 1, *align(2) u32);
    try testIndex(smaller[runtime_zero..].ptr, 2, *align(2) u32);
    try testIndex(smaller[runtime_zero..].ptr, 3, *align(2) u32);

    // has to use ABI alignment because index known at runtime only
    try testIndex2(array[runtime_zero..].ptr, 0, *u8);
    try testIndex2(array[runtime_zero..].ptr, 1, *u8);
    try testIndex2(array[runtime_zero..].ptr, 2, *u8);
    try testIndex2(array[runtime_zero..].ptr, 3, *u8);
}
fn testIndex(smaller: [*]align(2) u32, index: usize, comptime T: type) !void {
    comptime try expectEqual(@TypeOf(&smaller[index]), T);
}
fn testIndex2(ptr: [*]align(4) u8, index: usize, comptime T: type) !void {
    comptime try expectEqual(@TypeOf(&ptr[index]), T);
}

test "alignstack" {
    try expectEqual(fnWithAlignedStack(), 1234);
}

fn fnWithAlignedStack() i32 {
    @setAlignStack(256);
    return 1234;
}

test "alignment of structs" {
    try expect(@alignOf(struct {
        a: i32,
        b: *i32,
    }) == @alignOf(usize));
}

test "alignment of function with c calling convention" {
    var runtime_nothing = nothing;
    const casted1 = @ptrCast(*const u8, runtime_nothing);
    const casted2 = @ptrCast(fn () callconv(.C) void, casted1);
    casted2();
}

fn nothing() callconv(.C) void {}

test "return error union with 128-bit integer" {
    try expectEqual(try give(), 3);
}
fn give() anyerror!u128 {
    return 3;
}

test "alignment of >= 128-bit integer type" {
    try expectEqual(@alignOf(u128), 16);
    try expectEqual(@alignOf(u129), 16);
}

test "alignment of struct with 128-bit field" {
    try expect(@alignOf(struct {
        x: u128,
    }) == 16);

    comptime {
        try expect(@alignOf(struct {
            x: u128,
        }) == 16);
    }
}

test "size of extern struct with 128-bit field" {
    try expect(@sizeOf(extern struct {
        x: u128,
        y: u8,
    }) == 32);

    comptime {
        try expect(@sizeOf(extern struct {
            x: u128,
            y: u8,
        }) == 32);
    }
}

const DefaultAligned = struct {
    nevermind: u32,
    badguy: i128,
};

test "read 128-bit field from default aligned struct in stack memory" {
    var default_aligned = DefaultAligned{
        .nevermind = 1,
        .badguy = 12,
    };
    try expectEqual((@ptrToInt(&default_aligned.badguy) % 16), 0);
    try expectEqual(default_aligned.badguy, 12);
}

var default_aligned_global = DefaultAligned{
    .nevermind = 1,
    .badguy = 12,
};

test "read 128-bit field from default aligned struct in global memory" {
    try expectEqual((@ptrToInt(&default_aligned_global.badguy) % 16), 0);
    try expectEqual(default_aligned_global.badguy, 12);
}

test "struct field explicit alignment" {
    const S = struct {
        const Node = struct {
            next: *Node,
            massive_byte: u8 align(64),
        };
    };

    var node: S.Node = undefined;
    node.massive_byte = 100;
    try expectEqual(node.massive_byte, 100);
    comptime try expectEqual(@TypeOf(&node.massive_byte), *align(64) u8);
    try expectEqual(@ptrToInt(&node.massive_byte) % 64, 0);
}

test "align(@alignOf(T)) T does not force resolution of T" {
    const S = struct {
        const A = struct {
            a: *align(@alignOf(A)) A,
        };
        fn doTheTest() void {
            suspend {
                resume @frame();
            }
            _ = bar(@Frame(doTheTest));
        }
        fn bar(comptime T: type) *align(@alignOf(T)) T {
            ok = true;
            return undefined;
        }

        var ok = false;
    };
    _ = async S.doTheTest();
    try expect(S.ok);
}

test "align(N) on functions" {
    // function alignment is a compile error on wasm32/wasm64
    if (native_arch == .wasm32 or native_arch == .wasm64) return error.SkipZigTest;
    if (native_arch == .thumb) return error.SkipZigTest;

    try expectEqual((@ptrToInt(overaligned_fn) & (0x1000 - 1)), 0);
}
fn overaligned_fn() align(0x1000) i32 {
    return 42;
}
