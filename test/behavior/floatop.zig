const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const math = std.math;
const pi = std.math.pi;
const e = std.math.e;
const Vector = std.meta.Vector;

const epsilon = 0.000001;

test "@sqrt" {
    comptime try testSqrt();
    try testSqrt();
}

fn testSqrt() !void {
    {
        var a: f16 = 4;
        try expectEqual(@sqrt(a), 2);
    }
    {
        var a: f32 = 9;
        try expectEqual(@sqrt(a), 3);
        var b: f32 = 1.1;
        try expect(math.approxEqAbs(f32, @sqrt(b), 1.0488088481701516, epsilon));
    }
    {
        var a: f64 = 25;
        try expectEqual(@sqrt(a), 5);
    }
    {
        const a: comptime_float = 25.0;
        try expectEqual(@sqrt(a), 5.0);
    }
    // TODO https://github.com/ziglang/zig/issues/4026
    //{
    //    var a: f128 = 49;
    //try expectEqual(@sqrt(a) ,  7);
    //}
    {
        var v: Vector(4, f32) = [_]f32{ 1.1, 2.2, 3.3, 4.4 };
        var result = @sqrt(v);
        try expect(math.approxEqAbs(f32, @sqrt(@as(f32, 1.1)), result[0], epsilon));
        try expect(math.approxEqAbs(f32, @sqrt(@as(f32, 2.2)), result[1], epsilon));
        try expect(math.approxEqAbs(f32, @sqrt(@as(f32, 3.3)), result[2], epsilon));
        try expect(math.approxEqAbs(f32, @sqrt(@as(f32, 4.4)), result[3], epsilon));
    }
}

test "more @sqrt f16 tests" {
    // TODO these are not all passing at comptime
    try expectEqual(@sqrt(@as(f16, 0.0)), 0.0);
    try expect(math.approxEqAbs(f16, @sqrt(@as(f16, 2.0)), 1.414214, epsilon));
    try expect(math.approxEqAbs(f16, @sqrt(@as(f16, 3.6)), 1.897367, epsilon));
    try expectEqual(@sqrt(@as(f16, 4.0)), 2.0);
    try expect(math.approxEqAbs(f16, @sqrt(@as(f16, 7.539840)), 2.745877, epsilon));
    try expect(math.approxEqAbs(f16, @sqrt(@as(f16, 19.230934)), 4.385309, epsilon));
    try expectEqual(@sqrt(@as(f16, 64.0)), 8.0);
    try expect(math.approxEqAbs(f16, @sqrt(@as(f16, 64.1)), 8.006248, epsilon));
    try expect(math.approxEqAbs(f16, @sqrt(@as(f16, 8942.230469)), 94.563370, epsilon));

    // special cases
    try expect(math.isPositiveInf(@sqrt(@as(f16, math.inf(f16)))));
    try expectEqual(@sqrt(@as(f16, 0.0)), 0.0);
    try expectEqual(@sqrt(@as(f16, -0.0)), -0.0);
    try expect(math.isNan(@sqrt(@as(f16, -1.0))));
    try expect(math.isNan(@sqrt(@as(f16, math.nan(f16)))));
}

test "@sin" {
    comptime try testSin();
    try testSin();
}

fn testSin() !void {
    // TODO test f128, and c_longdouble
    // https://github.com/ziglang/zig/issues/4026
    {
        var a: f16 = 0;
        try expectEqual(@sin(a), 0);
    }
    {
        var a: f32 = 0;
        try expectEqual(@sin(a), 0);
    }
    {
        var a: f64 = 0;
        try expectEqual(@sin(a), 0);
    }
    {
        var v: Vector(4, f32) = [_]f32{ 1.1, 2.2, 3.3, 4.4 };
        var result = @sin(v);
        try expect(math.approxEqAbs(f32, @sin(@as(f32, 1.1)), result[0], epsilon));
        try expect(math.approxEqAbs(f32, @sin(@as(f32, 2.2)), result[1], epsilon));
        try expect(math.approxEqAbs(f32, @sin(@as(f32, 3.3)), result[2], epsilon));
        try expect(math.approxEqAbs(f32, @sin(@as(f32, 4.4)), result[3], epsilon));
    }
}

test "@cos" {
    comptime try testCos();
    try testCos();
}

fn testCos() !void {
    // TODO test f128, and c_longdouble
    // https://github.com/ziglang/zig/issues/4026
    {
        var a: f16 = 0;
        try expectEqual(@cos(a), 1);
    }
    {
        var a: f32 = 0;
        try expectEqual(@cos(a), 1);
    }
    {
        var a: f64 = 0;
        try expectEqual(@cos(a), 1);
    }
    {
        var v: Vector(4, f32) = [_]f32{ 1.1, 2.2, 3.3, 4.4 };
        var result = @cos(v);
        try expect(math.approxEqAbs(f32, @cos(@as(f32, 1.1)), result[0], epsilon));
        try expect(math.approxEqAbs(f32, @cos(@as(f32, 2.2)), result[1], epsilon));
        try expect(math.approxEqAbs(f32, @cos(@as(f32, 3.3)), result[2], epsilon));
        try expect(math.approxEqAbs(f32, @cos(@as(f32, 4.4)), result[3], epsilon));
    }
}

test "@exp" {
    comptime try testExp();
    try testExp();
}

fn testExp() !void {
    // TODO test f128, and c_longdouble
    // https://github.com/ziglang/zig/issues/4026
    {
        var a: f16 = 0;
        try expectEqual(@exp(a), 1);
    }
    {
        var a: f32 = 0;
        try expectEqual(@exp(a), 1);
    }
    {
        var a: f64 = 0;
        try expectEqual(@exp(a), 1);
    }
    {
        var v: Vector(4, f32) = [_]f32{ 1.1, 2.2, 0.3, 0.4 };
        var result = @exp(v);
        try expect(math.approxEqAbs(f32, @exp(@as(f32, 1.1)), result[0], epsilon));
        try expect(math.approxEqAbs(f32, @exp(@as(f32, 2.2)), result[1], epsilon));
        try expect(math.approxEqAbs(f32, @exp(@as(f32, 0.3)), result[2], epsilon));
        try expect(math.approxEqAbs(f32, @exp(@as(f32, 0.4)), result[3], epsilon));
    }
}

test "@exp2" {
    comptime try testExp2();
    try testExp2();
}

fn testExp2() !void {
    // TODO test f128, and c_longdouble
    // https://github.com/ziglang/zig/issues/4026
    {
        var a: f16 = 2;
        try expectEqual(@exp2(a), 4);
    }
    {
        var a: f32 = 2;
        try expectEqual(@exp2(a), 4);
    }
    {
        var a: f64 = 2;
        try expectEqual(@exp2(a), 4);
    }
    {
        var v: Vector(4, f32) = [_]f32{ 1.1, 2.2, 0.3, 0.4 };
        var result = @exp2(v);
        try expect(math.approxEqAbs(f32, @exp2(@as(f32, 1.1)), result[0], epsilon));
        try expect(math.approxEqAbs(f32, @exp2(@as(f32, 2.2)), result[1], epsilon));
        try expect(math.approxEqAbs(f32, @exp2(@as(f32, 0.3)), result[2], epsilon));
        try expect(math.approxEqAbs(f32, @exp2(@as(f32, 0.4)), result[3], epsilon));
    }
}

test "@log" {
    // Old musl (and glibc?), and our current math.ln implementation do not return 1
    // so also accept those values.
    comptime try testLog();
    try testLog();
}

fn testLog() !void {
    // TODO test f128, and c_longdouble
    // https://github.com/ziglang/zig/issues/4026
    {
        var a: f16 = e;
        try expect(math.approxEqAbs(f16, @log(a), 1, epsilon));
    }
    {
        var a: f32 = e;
        try expect(@log(a) == 1 or @log(a) == @bitCast(f32, @as(u32, 0x3f7fffff)));
    }
    {
        var a: f64 = e;
        try expect(@log(a) == 1 or @log(a) == @bitCast(f64, @as(u64, 0x3ff0000000000000)));
    }
    {
        var v: Vector(4, f32) = [_]f32{ 1.1, 2.2, 0.3, 0.4 };
        var result = @log(v);
        try expect(math.approxEqAbs(f32, @log(@as(f32, 1.1)), result[0], epsilon));
        try expect(math.approxEqAbs(f32, @log(@as(f32, 2.2)), result[1], epsilon));
        try expect(math.approxEqAbs(f32, @log(@as(f32, 0.3)), result[2], epsilon));
        try expect(math.approxEqAbs(f32, @log(@as(f32, 0.4)), result[3], epsilon));
    }
}

test "@log2" {
    comptime try testLog2();
    try testLog2();
}

fn testLog2() !void {
    // TODO test f128, and c_longdouble
    // https://github.com/ziglang/zig/issues/4026
    {
        var a: f16 = 4;
        try expectEqual(@log2(a), 2);
    }
    {
        var a: f32 = 4;
        try expectEqual(@log2(a), 2);
    }
    {
        var a: f64 = 4;
        try expectEqual(@log2(a), 2);
    }
    {
        var v: Vector(4, f32) = [_]f32{ 1.1, 2.2, 0.3, 0.4 };
        var result = @log2(v);
        try expect(math.approxEqAbs(f32, @log2(@as(f32, 1.1)), result[0], epsilon));
        try expect(math.approxEqAbs(f32, @log2(@as(f32, 2.2)), result[1], epsilon));
        try expect(math.approxEqAbs(f32, @log2(@as(f32, 0.3)), result[2], epsilon));
        try expect(math.approxEqAbs(f32, @log2(@as(f32, 0.4)), result[3], epsilon));
    }
}

test "@log10" {
    comptime try testLog10();
    try testLog10();
}

fn testLog10() !void {
    // TODO test f128, and c_longdouble
    // https://github.com/ziglang/zig/issues/4026
    {
        var a: f16 = 100;
        try expectEqual(@log10(a), 2);
    }
    {
        var a: f32 = 100;
        try expectEqual(@log10(a), 2);
    }
    {
        var a: f64 = 1000;
        try expectEqual(@log10(a), 3);
    }
    {
        var v: Vector(4, f32) = [_]f32{ 1.1, 2.2, 0.3, 0.4 };
        var result = @log10(v);
        try expect(math.approxEqAbs(f32, @log10(@as(f32, 1.1)), result[0], epsilon));
        try expect(math.approxEqAbs(f32, @log10(@as(f32, 2.2)), result[1], epsilon));
        try expect(math.approxEqAbs(f32, @log10(@as(f32, 0.3)), result[2], epsilon));
        try expect(math.approxEqAbs(f32, @log10(@as(f32, 0.4)), result[3], epsilon));
    }
}

test "@fabs" {
    comptime try testFabs();
    try testFabs();
}

fn testFabs() !void {
    // TODO test f128, and c_longdouble
    // https://github.com/ziglang/zig/issues/4026
    {
        var a: f16 = -2.5;
        var b: f16 = 2.5;
        try expectEqual(@fabs(a), 2.5);
        try expectEqual(@fabs(b), 2.5);
    }
    {
        var a: f32 = -2.5;
        var b: f32 = 2.5;
        try expectEqual(@fabs(a), 2.5);
        try expectEqual(@fabs(b), 2.5);
    }
    {
        var a: f64 = -2.5;
        var b: f64 = 2.5;
        try expectEqual(@fabs(a), 2.5);
        try expectEqual(@fabs(b), 2.5);
    }
    {
        var v: Vector(4, f32) = [_]f32{ 1.1, -2.2, 0.3, -0.4 };
        var result = @fabs(v);
        try expect(math.approxEqAbs(f32, @fabs(@as(f32, 1.1)), result[0], epsilon));
        try expect(math.approxEqAbs(f32, @fabs(@as(f32, -2.2)), result[1], epsilon));
        try expect(math.approxEqAbs(f32, @fabs(@as(f32, 0.3)), result[2], epsilon));
        try expect(math.approxEqAbs(f32, @fabs(@as(f32, -0.4)), result[3], epsilon));
    }
}

test "@floor" {
    comptime try testFloor();
    try testFloor();
}

fn testFloor() !void {
    // TODO test f128, and c_longdouble
    // https://github.com/ziglang/zig/issues/4026
    {
        var a: f16 = 2.1;
        try expectEqual(@floor(a), 2);
    }
    {
        var a: f32 = 2.1;
        try expectEqual(@floor(a), 2);
    }
    {
        var a: f64 = 3.5;
        try expectEqual(@floor(a), 3);
    }
    {
        var v: Vector(4, f32) = [_]f32{ 1.1, -2.2, 0.3, -0.4 };
        var result = @floor(v);
        try expect(math.approxEqAbs(f32, @floor(@as(f32, 1.1)), result[0], epsilon));
        try expect(math.approxEqAbs(f32, @floor(@as(f32, -2.2)), result[1], epsilon));
        try expect(math.approxEqAbs(f32, @floor(@as(f32, 0.3)), result[2], epsilon));
        try expect(math.approxEqAbs(f32, @floor(@as(f32, -0.4)), result[3], epsilon));
    }
}

test "@ceil" {
    comptime try testCeil();
    try testCeil();
}

fn testCeil() !void {
    // TODO test f128, and c_longdouble
    // https://github.com/ziglang/zig/issues/4026
    {
        var a: f16 = 2.1;
        try expectEqual(@ceil(a), 3);
    }
    {
        var a: f32 = 2.1;
        try expectEqual(@ceil(a), 3);
    }
    {
        var a: f64 = 3.5;
        try expectEqual(@ceil(a), 4);
    }
    {
        var v: Vector(4, f32) = [_]f32{ 1.1, -2.2, 0.3, -0.4 };
        var result = @ceil(v);
        try expect(math.approxEqAbs(f32, @ceil(@as(f32, 1.1)), result[0], epsilon));
        try expect(math.approxEqAbs(f32, @ceil(@as(f32, -2.2)), result[1], epsilon));
        try expect(math.approxEqAbs(f32, @ceil(@as(f32, 0.3)), result[2], epsilon));
        try expect(math.approxEqAbs(f32, @ceil(@as(f32, -0.4)), result[3], epsilon));
    }
}

test "@trunc" {
    comptime try testTrunc();
    try testTrunc();
}

fn testTrunc() !void {
    // TODO test f128, and c_longdouble
    // https://github.com/ziglang/zig/issues/4026
    {
        var a: f16 = 2.1;
        try expectEqual(@trunc(a), 2);
    }
    {
        var a: f32 = 2.1;
        try expectEqual(@trunc(a), 2);
    }
    {
        var a: f64 = -3.5;
        try expectEqual(@trunc(a), -3);
    }
    {
        var v: Vector(4, f32) = [_]f32{ 1.1, -2.2, 0.3, -0.4 };
        var result = @trunc(v);
        try expect(math.approxEqAbs(f32, @trunc(@as(f32, 1.1)), result[0], epsilon));
        try expect(math.approxEqAbs(f32, @trunc(@as(f32, -2.2)), result[1], epsilon));
        try expect(math.approxEqAbs(f32, @trunc(@as(f32, 0.3)), result[2], epsilon));
        try expect(math.approxEqAbs(f32, @trunc(@as(f32, -0.4)), result[3], epsilon));
    }
}

test "floating point comparisons" {
    try testFloatComparisons();
    comptime try testFloatComparisons();
}

fn testFloatComparisons() !void {
    inline for ([_]type{ f16, f32, f64, f128 }) |ty| {
        // No decimal part
        {
            const x: ty = 1.0;
            try expectEqual(x, 1);
            try expect(x != 0);
            try expect(x > 0);
            try expect(x < 2);
            try expect(x >= 1);
            try expect(x <= 1);
        }
        // Non-zero decimal part
        {
            const x: ty = 1.5;
            try expect(x != 1);
            try expect(x != 2);
            try expect(x > 1);
            try expect(x < 2);
            try expect(x >= 1);
            try expect(x <= 2);
        }
    }
}

test "different sized float comparisons" {
    try testDifferentSizedFloatComparisons();
    comptime try testDifferentSizedFloatComparisons();
}

fn testDifferentSizedFloatComparisons() !void {
    var a: f16 = 1;
    var b: f64 = 2;
    try expect(a < b);
}

// TODO This is waiting on library support for the Windows build (not sure why the other's don't need it)
//test "@nearbyint" {
//    comptime testNearbyInt();
//    testNearbyInt();
//}

//fn testNearbyInt() void {
//    // TODO test f16, f128, and c_longdouble
//    // https://github.com/ziglang/zig/issues/4026
//    {
//        var a: f32 = 2.1;
//    try expectEqual(@nearbyint(a) ,  2);
//    }
//    {
//        var a: f64 = -3.75;
//    try expectEqual(@nearbyint(a) ,  -4);
//    }
//}
