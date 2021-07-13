const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const math = std.math;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectApproxEqRel = std.testing.expectApproxEqRel;
const Vector = std.meta.Vector;

test "implicit cast vector to array - bool" {
    const S = struct {
        fn doTheTest() !void {
            const a: Vector(4, bool) = [_]bool{ true, false, true, false };
            const result_array: [4]bool = a;
            try expect(mem.eql(bool, &result_array, &[4]bool{ true, false, true, false }));
        }
    };
    try S.doTheTest();
    comptime try S.doTheTest();
}

test "vector wrap operators" {
    const S = struct {
        fn doTheTest() !void {
            var v: Vector(4, i32) = [4]i32{ 2147483647, -2, 30, 40 };
            var x: Vector(4, i32) = [4]i32{ 1, 2147483647, 3, 4 };
            try expect(mem.eql(i32, &@as([4]i32, v +% x), &[4]i32{ -2147483648, 2147483645, 33, 44 }));
            try expect(mem.eql(i32, &@as([4]i32, v -% x), &[4]i32{ 2147483646, 2147483647, 27, 36 }));
            try expect(mem.eql(i32, &@as([4]i32, v *% x), &[4]i32{ 2147483647, 2, 90, 160 }));
            var z: Vector(4, i32) = [4]i32{ 1, 2, 3, -2147483648 };
            try expect(mem.eql(i32, &@as([4]i32, -%z), &[4]i32{ -1, -2, -3, -2147483648 }));
        }
    };
    try S.doTheTest();
    comptime try S.doTheTest();
}

test "vector bin compares with mem.eql" {
    const S = struct {
        fn doTheTest() !void {
            var v: Vector(4, i32) = [4]i32{ 2147483647, -2, 30, 40 };
            var x: Vector(4, i32) = [4]i32{ 1, 2147483647, 30, 4 };
            try expect(mem.eql(bool, &@as([4]bool, v == x), &[4]bool{ false, false, true, false }));
            try expect(mem.eql(bool, &@as([4]bool, v != x), &[4]bool{ true, true, false, true }));
            try expect(mem.eql(bool, &@as([4]bool, v < x), &[4]bool{ false, true, false, false }));
            try expect(mem.eql(bool, &@as([4]bool, v > x), &[4]bool{ true, false, false, true }));
            try expect(mem.eql(bool, &@as([4]bool, v <= x), &[4]bool{ false, true, true, false }));
            try expect(mem.eql(bool, &@as([4]bool, v >= x), &[4]bool{ true, false, true, true }));
        }
    };
    try S.doTheTest();
    comptime try S.doTheTest();
}

test "vector int operators" {
    const S = struct {
        fn doTheTest() !void {
            var v: Vector(4, i32) = [4]i32{ 10, 20, 30, 40 };
            var x: Vector(4, i32) = [4]i32{ 1, 2, 3, 4 };
            try expect(mem.eql(i32, &@as([4]i32, v + x), &[4]i32{ 11, 22, 33, 44 }));
            try expect(mem.eql(i32, &@as([4]i32, v - x), &[4]i32{ 9, 18, 27, 36 }));
            try expect(mem.eql(i32, &@as([4]i32, v * x), &[4]i32{ 10, 40, 90, 160 }));
            try expect(mem.eql(i32, &@as([4]i32, -v), &[4]i32{ -10, -20, -30, -40 }));
        }
    };
    try S.doTheTest();
    comptime try S.doTheTest();
}

test "vector float operators" {
    const S = struct {
        fn doTheTest() !void {
            var v: Vector(4, f32) = [4]f32{ 10, 20, 30, 40 };
            var x: Vector(4, f32) = [4]f32{ 1, 2, 3, 4 };
            try expect(mem.eql(f32, &@as([4]f32, v + x), &[4]f32{ 11, 22, 33, 44 }));
            try expect(mem.eql(f32, &@as([4]f32, v - x), &[4]f32{ 9, 18, 27, 36 }));
            try expect(mem.eql(f32, &@as([4]f32, v * x), &[4]f32{ 10, 40, 90, 160 }));
            try expect(mem.eql(f32, &@as([4]f32, -x), &[4]f32{ -1, -2, -3, -4 }));
        }
    };
    try S.doTheTest();
    comptime try S.doTheTest();
}

test "vector bit operators" {
    const S = struct {
        fn doTheTest() !void {
            var v: Vector(4, u8) = [4]u8{ 0b10101010, 0b10101010, 0b10101010, 0b10101010 };
            var x: Vector(4, u8) = [4]u8{ 0b11110000, 0b00001111, 0b10101010, 0b01010101 };
            try expect(mem.eql(u8, &@as([4]u8, v ^ x), &[4]u8{ 0b01011010, 0b10100101, 0b00000000, 0b11111111 }));
            try expect(mem.eql(u8, &@as([4]u8, v | x), &[4]u8{ 0b11111010, 0b10101111, 0b10101010, 0b11111111 }));
            try expect(mem.eql(u8, &@as([4]u8, v & x), &[4]u8{ 0b10100000, 0b00001010, 0b10101010, 0b00000000 }));
        }
    };
    try S.doTheTest();
    comptime try S.doTheTest();
}

test "implicit cast vector to array" {
    const S = struct {
        fn doTheTest() !void {
            var a: Vector(4, i32) = [_]i32{ 1, 2, 3, 4 };
            var result_array: [4]i32 = a;
            result_array = a;
            try expect(mem.eql(i32, &result_array, &[4]i32{ 1, 2, 3, 4 }));
        }
    };
    try S.doTheTest();
    comptime try S.doTheTest();
}

test "array to vector" {
    var foo: f32 = 3.14;
    var arr = [4]f32{ foo, 1.5, 0.0, 0.0 };
    var vec: Vector(4, f32) = arr;
    _ = vec;
}

test "vector casts of sizes not divisable by 8" {
    const S = struct {
        fn doTheTest() !void {
            {
                var v: Vector(4, u3) = [4]u3{ 5, 2, 3, 0 };
                var x: [4]u3 = v;
                try expect(mem.eql(u3, &x, &@as([4]u3, v)));
            }
            {
                var v: Vector(4, u2) = [4]u2{ 1, 2, 3, 0 };
                var x: [4]u2 = v;
                try expect(mem.eql(u2, &x, &@as([4]u2, v)));
            }
            {
                var v: Vector(4, u1) = [4]u1{ 1, 0, 1, 0 };
                var x: [4]u1 = v;
                try expect(mem.eql(u1, &x, &@as([4]u1, v)));
            }
            {
                var v: Vector(4, bool) = [4]bool{ false, false, true, false };
                var x: [4]bool = v;
                try expect(mem.eql(bool, &x, &@as([4]bool, v)));
            }
        }
    };
    try S.doTheTest();
    comptime try S.doTheTest();
}

test "vector @splat" {
    const S = struct {
        fn testForT(comptime N: comptime_int, v: anytype) !void {
            const T = @TypeOf(v);
            var vec = @splat(N, v);
            try expectEqual(Vector(N, T), @TypeOf(vec));
            var as_array = @as([N]T, vec);
            for (as_array) |elem| try expectEqual(v, elem);
        }
        fn doTheTest() !void {
            // Splats with multiple-of-8 bit types that fill a 128bit vector.
            try testForT(16, @as(u8, 0xEE));
            try testForT(8, @as(u16, 0xBEEF));
            try testForT(4, @as(u32, 0xDEADBEEF));
            try testForT(2, @as(u64, 0xCAFEF00DDEADBEEF));

            try testForT(8, @as(f16, 3.1415));
            try testForT(4, @as(f32, 3.1415));
            try testForT(2, @as(f64, 3.1415));

            // Same but fill more than 128 bits.
            try testForT(16 * 2, @as(u8, 0xEE));
            try testForT(8 * 2, @as(u16, 0xBEEF));
            try testForT(4 * 2, @as(u32, 0xDEADBEEF));
            try testForT(2 * 2, @as(u64, 0xCAFEF00DDEADBEEF));

            try testForT(8 * 2, @as(f16, 3.1415));
            try testForT(4 * 2, @as(f32, 3.1415));
            try testForT(2 * 2, @as(f64, 3.1415));
        }
    };
    try S.doTheTest();
    comptime try S.doTheTest();
}

test "load vector elements via comptime index" {
    const S = struct {
        fn doTheTest() !void {
            var v: Vector(4, i32) = [_]i32{ 1, 2, 3, undefined };
            try expectEqual(v[0], 1);
            try expectEqual(v[1], 2);
            try expectEqual(loadv(&v[2]), 3);
        }
        fn loadv(ptr: anytype) i32 {
            return ptr.*;
        }
    };

    try S.doTheTest();
    comptime try S.doTheTest();
}

test "store vector elements via comptime index" {
    const S = struct {
        fn doTheTest() !void {
            var v: Vector(4, i32) = [_]i32{ 1, 5, 3, undefined };

            v[2] = 42;
            try expectEqual(v[1], 5);
            v[3] = -364;
            try expectEqual(v[2], 42);
            try expect(-364 == v[3]);

            storev(&v[0], 100);
            try expectEqual(v[0], 100);
        }
        fn storev(ptr: anytype, x: i32) void {
            ptr.* = x;
        }
    };

    try S.doTheTest();
    comptime try S.doTheTest();
}

test "load vector elements via runtime index" {
    const S = struct {
        fn doTheTest() !void {
            var v: Vector(4, i32) = [_]i32{ 1, 2, 3, undefined };
            var i: u32 = 0;
            try expectEqual(v[i], 1);
            i += 1;
            try expectEqual(v[i], 2);
            i += 1;
            try expectEqual(v[i], 3);
        }
    };

    try S.doTheTest();
    comptime try S.doTheTest();
}

test "store vector elements via runtime index" {
    const S = struct {
        fn doTheTest() !void {
            var v: Vector(4, i32) = [_]i32{ 1, 5, 3, undefined };
            var i: u32 = 2;
            v[i] = 1;
            try expectEqual(v[1], 5);
            try expectEqual(v[2], 1);
            i += 1;
            v[i] = -364;
            try expect(-364 == v[3]);
        }
    };

    try S.doTheTest();
    comptime try S.doTheTest();
}

test "initialize vector which is a struct field" {
    const Vec4Obj = struct {
        data: Vector(4, f32),
    };

    const S = struct {
        fn doTheTest() !void {
            var foo = Vec4Obj{
                .data = [_]f32{ 1, 2, 3, 4 },
            };
            _ = foo;
        }
    };
    try S.doTheTest();
    comptime try S.doTheTest();
}

test "vector comparison operators" {
    const S = struct {
        fn doTheTest() !void {
            {
                const v1: Vector(4, bool) = [_]bool{ true, false, true, false };
                const v2: Vector(4, bool) = [_]bool{ false, true, false, true };
                try expectEqual(@splat(4, true), v1 == v1);
                try expectEqual(@splat(4, false), v1 == v2);
                try expectEqual(@splat(4, true), v1 != v2);
                try expectEqual(@splat(4, false), v2 != v2);
            }
            {
                const v1 = @splat(4, @as(u32, 0xc0ffeeee));
                const v2: Vector(4, c_uint) = v1;
                const v3 = @splat(4, @as(u32, 0xdeadbeef));
                try expectEqual(@splat(4, true), v1 == v2);
                try expectEqual(@splat(4, false), v1 == v3);
                try expectEqual(@splat(4, true), v1 != v3);
                try expectEqual(@splat(4, false), v1 != v2);
            }
            {
                // Comptime-known LHS/RHS
                var v1: @Vector(4, u32) = [_]u32{ 2, 1, 2, 1 };
                const v2 = @splat(4, @as(u32, 2));
                const v3: @Vector(4, bool) = [_]bool{ true, false, true, false };
                try expectEqual(v3, v1 == v2);
                try expectEqual(v3, v2 == v1);
            }
        }
    };
    try S.doTheTest();
    comptime try S.doTheTest();
}

test "vector division operators" {
    const S = struct {
        fn doTheTestDiv(comptime T: type, x: Vector(4, T), y: Vector(4, T)) !void {
            if (!comptime std.meta.trait.isSignedInt(T)) {
                const d0 = x / y;
                for (@as([4]T, d0)) |v, i| {
                    try expectEqual(x[i] / y[i], v);
                }
            }
            const d1 = @divExact(x, y);
            for (@as([4]T, d1)) |v, i| {
                try expectEqual(@divExact(x[i], y[i]), v);
            }
            const d2 = @divFloor(x, y);
            for (@as([4]T, d2)) |v, i| {
                try expectEqual(@divFloor(x[i], y[i]), v);
            }
            const d3 = @divTrunc(x, y);
            for (@as([4]T, d3)) |v, i| {
                try expectEqual(@divTrunc(x[i], y[i]), v);
            }
        }

        fn doTheTestMod(comptime T: type, x: Vector(4, T), y: Vector(4, T)) !void {
            if ((!comptime std.meta.trait.isSignedInt(T)) and @typeInfo(T) != .Float) {
                const r0 = x % y;
                for (@as([4]T, r0)) |v, i| {
                    try expectEqual(x[i] % y[i], v);
                }
            }
            const r1 = @mod(x, y);
            for (@as([4]T, r1)) |v, i| {
                try expectEqual(@mod(x[i], y[i]), v);
            }
            const r2 = @rem(x, y);
            for (@as([4]T, r2)) |v, i| {
                try expectEqual(@rem(x[i], y[i]), v);
            }
        }

        fn doTheTest() !void {
            // https://github.com/ziglang/zig/issues/4952
            if (builtin.target.os.tag != .windows) {
                try doTheTestDiv(f16, [4]f16{ 4.0, -4.0, 4.0, -4.0 }, [4]f16{ 1.0, 2.0, -1.0, -2.0 });
            }

            try doTheTestDiv(f32, [4]f32{ 4.0, -4.0, 4.0, -4.0 }, [4]f32{ 1.0, 2.0, -1.0, -2.0 });
            try doTheTestDiv(f64, [4]f64{ 4.0, -4.0, 4.0, -4.0 }, [4]f64{ 1.0, 2.0, -1.0, -2.0 });

            // https://github.com/ziglang/zig/issues/4952
            if (builtin.target.os.tag != .windows) {
                try doTheTestMod(f16, [4]f16{ 4.0, -4.0, 4.0, -4.0 }, [4]f16{ 1.0, 2.0, 0.5, 3.0 });
            }
            try doTheTestMod(f32, [4]f32{ 4.0, -4.0, 4.0, -4.0 }, [4]f32{ 1.0, 2.0, 0.5, 3.0 });
            try doTheTestMod(f64, [4]f64{ 4.0, -4.0, 4.0, -4.0 }, [4]f64{ 1.0, 2.0, 0.5, 3.0 });

            try doTheTestDiv(i8, [4]i8{ 4, -4, 4, -4 }, [4]i8{ 1, 2, -1, -2 });
            try doTheTestDiv(i16, [4]i16{ 4, -4, 4, -4 }, [4]i16{ 1, 2, -1, -2 });
            try doTheTestDiv(i32, [4]i32{ 4, -4, 4, -4 }, [4]i32{ 1, 2, -1, -2 });
            try doTheTestDiv(i64, [4]i64{ 4, -4, 4, -4 }, [4]i64{ 1, 2, -1, -2 });

            try doTheTestMod(i8, [4]i8{ 4, -4, 4, -4 }, [4]i8{ 1, 2, 4, 8 });
            try doTheTestMod(i16, [4]i16{ 4, -4, 4, -4 }, [4]i16{ 1, 2, 4, 8 });
            try doTheTestMod(i32, [4]i32{ 4, -4, 4, -4 }, [4]i32{ 1, 2, 4, 8 });
            try doTheTestMod(i64, [4]i64{ 4, -4, 4, -4 }, [4]i64{ 1, 2, 4, 8 });

            try doTheTestDiv(u8, [4]u8{ 1, 2, 4, 8 }, [4]u8{ 1, 1, 2, 4 });
            try doTheTestDiv(u16, [4]u16{ 1, 2, 4, 8 }, [4]u16{ 1, 1, 2, 4 });
            try doTheTestDiv(u32, [4]u32{ 1, 2, 4, 8 }, [4]u32{ 1, 1, 2, 4 });
            try doTheTestDiv(u64, [4]u64{ 1, 2, 4, 8 }, [4]u64{ 1, 1, 2, 4 });

            try doTheTestMod(u8, [4]u8{ 1, 2, 4, 8 }, [4]u8{ 1, 1, 2, 4 });
            try doTheTestMod(u16, [4]u16{ 1, 2, 4, 8 }, [4]u16{ 1, 1, 2, 4 });
            try doTheTestMod(u32, [4]u32{ 1, 2, 4, 8 }, [4]u32{ 1, 1, 2, 4 });
            try doTheTestMod(u64, [4]u64{ 1, 2, 4, 8 }, [4]u64{ 1, 1, 2, 4 });
        }
    };

    try S.doTheTest();
    comptime try S.doTheTest();
}

test "vector bitwise not operator" {
    const S = struct {
        fn doTheTestNot(comptime T: type, x: Vector(4, T)) !void {
            var y = ~x;
            for (@as([4]T, y)) |v, i| {
                try expectEqual(~x[i], v);
            }
        }
        fn doTheTest() !void {
            try doTheTestNot(u8, [_]u8{ 0, 2, 4, 255 });
            try doTheTestNot(u16, [_]u16{ 0, 2, 4, 255 });
            try doTheTestNot(u32, [_]u32{ 0, 2, 4, 255 });
            try doTheTestNot(u64, [_]u64{ 0, 2, 4, 255 });

            try doTheTestNot(u8, [_]u8{ 0, 2, 4, 255 });
            try doTheTestNot(u16, [_]u16{ 0, 2, 4, 255 });
            try doTheTestNot(u32, [_]u32{ 0, 2, 4, 255 });
            try doTheTestNot(u64, [_]u64{ 0, 2, 4, 255 });
        }
    };

    try S.doTheTest();
    comptime try S.doTheTest();
}

test "vector shift operators" {
    const S = struct {
        fn doTheTestShift(x: anytype, y: anytype) !void {
            const N = @typeInfo(@TypeOf(x)).Array.len;
            const TX = @typeInfo(@TypeOf(x)).Array.child;
            const TY = @typeInfo(@TypeOf(y)).Array.child;

            var xv = @as(Vector(N, TX), x);
            var yv = @as(Vector(N, TY), y);

            var z0 = xv >> yv;
            for (@as([N]TX, z0)) |v, i| {
                try expectEqual(x[i] >> y[i], v);
            }
            var z1 = xv << yv;
            for (@as([N]TX, z1)) |v, i| {
                try expectEqual(x[i] << y[i], v);
            }
        }
        fn doTheTestShiftExact(x: anytype, y: anytype, dir: enum { Left, Right }) !void {
            const N = @typeInfo(@TypeOf(x)).Array.len;
            const TX = @typeInfo(@TypeOf(x)).Array.child;
            const TY = @typeInfo(@TypeOf(y)).Array.child;

            var xv = @as(Vector(N, TX), x);
            var yv = @as(Vector(N, TY), y);

            var z = if (dir == .Left) @shlExact(xv, yv) else @shrExact(xv, yv);
            for (@as([N]TX, z)) |v, i| {
                const check = if (dir == .Left) x[i] << y[i] else x[i] >> y[i];
                try expectEqual(check, v);
            }
        }
        fn doTheTest() !void {
            try doTheTestShift([_]u8{ 0, 2, 4, math.maxInt(u8) }, [_]u3{ 2, 0, 2, 7 });
            try doTheTestShift([_]u16{ 0, 2, 4, math.maxInt(u16) }, [_]u4{ 2, 0, 2, 15 });
            try doTheTestShift([_]u24{ 0, 2, 4, math.maxInt(u24) }, [_]u5{ 2, 0, 2, 23 });
            try doTheTestShift([_]u32{ 0, 2, 4, math.maxInt(u32) }, [_]u5{ 2, 0, 2, 31 });
            try doTheTestShift([_]u64{ 0xfe, math.maxInt(u64) }, [_]u6{ 0, 63 });

            try doTheTestShift([_]i8{ 0, 2, 4, math.maxInt(i8) }, [_]u3{ 2, 0, 2, 7 });
            try doTheTestShift([_]i16{ 0, 2, 4, math.maxInt(i16) }, [_]u4{ 2, 0, 2, 7 });
            try doTheTestShift([_]i24{ 0, 2, 4, math.maxInt(i24) }, [_]u5{ 2, 0, 2, 7 });
            try doTheTestShift([_]i32{ 0, 2, 4, math.maxInt(i32) }, [_]u5{ 2, 0, 2, 7 });
            try doTheTestShift([_]i64{ 0xfe, math.maxInt(i64) }, [_]u6{ 0, 63 });

            try doTheTestShiftExact([_]u8{ 0, 1, 1 << 7, math.maxInt(u8) ^ 1 }, [_]u3{ 4, 0, 7, 1 }, .Right);
            try doTheTestShiftExact([_]u16{ 0, 1, 1 << 15, math.maxInt(u16) ^ 1 }, [_]u4{ 4, 0, 15, 1 }, .Right);
            try doTheTestShiftExact([_]u24{ 0, 1, 1 << 23, math.maxInt(u24) ^ 1 }, [_]u5{ 4, 0, 23, 1 }, .Right);
            try doTheTestShiftExact([_]u32{ 0, 1, 1 << 31, math.maxInt(u32) ^ 1 }, [_]u5{ 4, 0, 31, 1 }, .Right);
            try doTheTestShiftExact([_]u64{ 1 << 63, 1 }, [_]u6{ 63, 0 }, .Right);

            try doTheTestShiftExact([_]u8{ 0, 1, 1, math.maxInt(u8) ^ (1 << 7) }, [_]u3{ 4, 0, 7, 1 }, .Left);
            try doTheTestShiftExact([_]u16{ 0, 1, 1, math.maxInt(u16) ^ (1 << 15) }, [_]u4{ 4, 0, 15, 1 }, .Left);
            try doTheTestShiftExact([_]u24{ 0, 1, 1, math.maxInt(u24) ^ (1 << 23) }, [_]u5{ 4, 0, 23, 1 }, .Left);
            try doTheTestShiftExact([_]u32{ 0, 1, 1, math.maxInt(u32) ^ (1 << 31) }, [_]u5{ 4, 0, 31, 1 }, .Left);
            try doTheTestShiftExact([_]u64{ 1 << 63, 1 }, [_]u6{ 0, 63 }, .Left);
        }
    };

    switch (builtin.target.cpu.arch) {
        .i386,
        .aarch64,
        .aarch64_be,
        .aarch64_32,
        .arm,
        .armeb,
        .thumb,
        .thumbeb,
        .mips,
        .mipsel,
        .mips64,
        .mips64el,
        .riscv64,
        .sparcv9,
        => {
            // LLVM miscompiles on this architecture
            // https://github.com/ziglang/zig/issues/4951
            return error.SkipZigTest;
        },
        else => {},
    }

    try S.doTheTest();
    comptime try S.doTheTest();
}

test "vector reduce operation" {
    const S = struct {
        fn doTheTestReduce(comptime op: std.builtin.ReduceOp, x: anytype, expected: anytype) !void {
            const N = @typeInfo(@TypeOf(x)).Array.len;
            const TX = @typeInfo(@TypeOf(x)).Array.child;

            var r = @reduce(op, @as(Vector(N, TX), x));
            switch (@typeInfo(TX)) {
                .Int, .Bool => try expectEqual(expected, r),
                .Float => {
                    const expected_nan = math.isNan(expected);
                    const got_nan = math.isNan(r);

                    if (expected_nan and got_nan) {
                        // Do this check explicitly as two NaN values are never
                        // equal.
                    } else {
                        try expectApproxEqRel(expected, r, math.sqrt(math.epsilon(TX)));
                    }
                },
                else => unreachable,
            }
        }
        fn doTheTest() !void {
            try doTheTestReduce(.Add, [4]i16{ -9, -99, -999, -9999 }, @as(i32, -11106));
            try doTheTestReduce(.Add, [4]u16{ 9, 99, 999, 9999 }, @as(u32, 11106));
            try doTheTestReduce(.Add, [4]i32{ -9, -99, -999, -9999 }, @as(i32, -11106));
            try doTheTestReduce(.Add, [4]u32{ 9, 99, 999, 9999 }, @as(u32, 11106));
            try doTheTestReduce(.Add, [4]i64{ -9, -99, -999, -9999 }, @as(i64, -11106));
            try doTheTestReduce(.Add, [4]u64{ 9, 99, 999, 9999 }, @as(u64, 11106));
            try doTheTestReduce(.Add, [4]i128{ -9, -99, -999, -9999 }, @as(i128, -11106));
            try doTheTestReduce(.Add, [4]u128{ 9, 99, 999, 9999 }, @as(u128, 11106));
            try doTheTestReduce(.Add, [4]f16{ -1.9, 5.1, -60.3, 100.0 }, @as(f16, 42.9));
            try doTheTestReduce(.Add, [4]f32{ -1.9, 5.1, -60.3, 100.0 }, @as(f32, 42.9));
            try doTheTestReduce(.Add, [4]f64{ -1.9, 5.1, -60.3, 100.0 }, @as(f64, 42.9));

            try doTheTestReduce(.And, [4]bool{ true, false, true, true }, @as(bool, false));
            try doTheTestReduce(.And, [4]u1{ 1, 0, 1, 1 }, @as(u1, 0));
            try doTheTestReduce(.And, [4]u16{ 0xffff, 0xff55, 0xaaff, 0x1010 }, @as(u16, 0x10));
            try doTheTestReduce(.And, [4]u32{ 0xffffffff, 0xffff5555, 0xaaaaffff, 0x10101010 }, @as(u32, 0x1010));
            try doTheTestReduce(.And, [4]u64{ 0xffffffff, 0xffff5555, 0xaaaaffff, 0x10101010 }, @as(u64, 0x1010));

            try doTheTestReduce(.Min, [4]i16{ -1, 2, 3, 4 }, @as(i16, -1));
            try doTheTestReduce(.Min, [4]u16{ 1, 2, 3, 4 }, @as(u16, 1));
            try doTheTestReduce(.Min, [4]i32{ 1234567, -386, 0, 3 }, @as(i32, -386));
            try doTheTestReduce(.Min, [4]u32{ 99, 9999, 9, 99999 }, @as(u32, 9));

            // LLVM 11 ERROR: Cannot select type
            // https://github.com/ziglang/zig/issues/7138
            if (builtin.target.cpu.arch != .aarch64) {
                try doTheTestReduce(.Min, [4]i64{ 1234567, -386, 0, 3 }, @as(i64, -386));
                try doTheTestReduce(.Min, [4]u64{ 99, 9999, 9, 99999 }, @as(u64, 9));
            }

            try doTheTestReduce(.Min, [4]i128{ 1234567, -386, 0, 3 }, @as(i128, -386));
            try doTheTestReduce(.Min, [4]u128{ 99, 9999, 9, 99999 }, @as(u128, 9));
            try doTheTestReduce(.Min, [4]f16{ -10.3, 10.0e9, 13.0, -100.0 }, @as(f16, -100.0));
            try doTheTestReduce(.Min, [4]f32{ -10.3, 10.0e9, 13.0, -100.0 }, @as(f32, -100.0));
            try doTheTestReduce(.Min, [4]f64{ -10.3, 10.0e9, 13.0, -100.0 }, @as(f64, -100.0));

            try doTheTestReduce(.Max, [4]i16{ -1, 2, 3, 4 }, @as(i16, 4));
            try doTheTestReduce(.Max, [4]u16{ 1, 2, 3, 4 }, @as(u16, 4));
            try doTheTestReduce(.Max, [4]i32{ 1234567, -386, 0, 3 }, @as(i32, 1234567));
            try doTheTestReduce(.Max, [4]u32{ 99, 9999, 9, 99999 }, @as(u32, 99999));

            // LLVM 11 ERROR: Cannot select type
            // https://github.com/ziglang/zig/issues/7138
            if (builtin.target.cpu.arch != .aarch64) {
                try doTheTestReduce(.Max, [4]i64{ 1234567, -386, 0, 3 }, @as(i64, 1234567));
                try doTheTestReduce(.Max, [4]u64{ 99, 9999, 9, 99999 }, @as(u64, 99999));
            }

            try doTheTestReduce(.Max, [4]i128{ 1234567, -386, 0, 3 }, @as(i128, 1234567));
            try doTheTestReduce(.Max, [4]u128{ 99, 9999, 9, 99999 }, @as(u128, 99999));
            try doTheTestReduce(.Max, [4]f16{ -10.3, 10.0e9, 13.0, -100.0 }, @as(f16, 10.0e9));
            try doTheTestReduce(.Max, [4]f32{ -10.3, 10.0e9, 13.0, -100.0 }, @as(f32, 10.0e9));
            try doTheTestReduce(.Max, [4]f64{ -10.3, 10.0e9, 13.0, -100.0 }, @as(f64, 10.0e9));

            try doTheTestReduce(.Mul, [4]i16{ -1, 2, 3, 4 }, @as(i16, -24));
            try doTheTestReduce(.Mul, [4]u16{ 1, 2, 3, 4 }, @as(u16, 24));
            try doTheTestReduce(.Mul, [4]i32{ -9, -99, -999, 999 }, @as(i32, -889218891));
            try doTheTestReduce(.Mul, [4]u32{ 1, 2, 3, 4 }, @as(u32, 24));
            try doTheTestReduce(.Mul, [4]i64{ 9, 99, 999, 9999 }, @as(i64, 8900199891));
            try doTheTestReduce(.Mul, [4]u64{ 9, 99, 999, 9999 }, @as(u64, 8900199891));
            try doTheTestReduce(.Mul, [4]i128{ -9, -99, -999, 9999 }, @as(i128, -8900199891));
            try doTheTestReduce(.Mul, [4]u128{ 9, 99, 999, 9999 }, @as(u128, 8900199891));
            try doTheTestReduce(.Mul, [4]f16{ -1.9, 5.1, -60.3, 100.0 }, @as(f16, 58430.7));
            try doTheTestReduce(.Mul, [4]f32{ -1.9, 5.1, -60.3, 100.0 }, @as(f32, 58430.7));
            try doTheTestReduce(.Mul, [4]f64{ -1.9, 5.1, -60.3, 100.0 }, @as(f64, 58430.7));

            try doTheTestReduce(.Or, [4]bool{ false, true, false, false }, @as(bool, true));
            try doTheTestReduce(.Or, [4]u1{ 0, 1, 0, 0 }, @as(u1, 1));
            try doTheTestReduce(.Or, [4]u16{ 0xff00, 0xff00, 0xf0, 0xf }, ~@as(u16, 0));
            try doTheTestReduce(.Or, [4]u32{ 0xffff0000, 0xff00, 0xf0, 0xf }, ~@as(u32, 0));
            try doTheTestReduce(.Or, [4]u64{ 0xffff0000, 0xff00, 0xf0, 0xf }, @as(u64, 0xffffffff));
            try doTheTestReduce(.Or, [4]u128{ 0xffff0000, 0xff00, 0xf0, 0xf }, @as(u128, 0xffffffff));

            try doTheTestReduce(.Xor, [4]bool{ true, true, true, false }, @as(bool, true));
            try doTheTestReduce(.Xor, [4]u1{ 1, 1, 1, 0 }, @as(u1, 1));
            try doTheTestReduce(.Xor, [4]u16{ 0x0000, 0x3333, 0x8888, 0x4444 }, ~@as(u16, 0));
            try doTheTestReduce(.Xor, [4]u32{ 0x00000000, 0x33333333, 0x88888888, 0x44444444 }, ~@as(u32, 0));
            try doTheTestReduce(.Xor, [4]u64{ 0x00000000, 0x33333333, 0x88888888, 0x44444444 }, @as(u64, 0xffffffff));
            try doTheTestReduce(.Xor, [4]u128{ 0x00000000, 0x33333333, 0x88888888, 0x44444444 }, @as(u128, 0xffffffff));

            // Test the reduction on vectors containing NaNs.
            const f16_nan = math.nan(f16);
            const f32_nan = math.nan(f32);
            const f64_nan = math.nan(f64);

            try doTheTestReduce(.Add, [4]f16{ -1.9, 5.1, f16_nan, 100.0 }, f16_nan);
            try doTheTestReduce(.Add, [4]f32{ -1.9, 5.1, f32_nan, 100.0 }, f32_nan);
            try doTheTestReduce(.Add, [4]f64{ -1.9, 5.1, f64_nan, 100.0 }, f64_nan);

            // LLVM 11 ERROR: Cannot select type
            // https://github.com/ziglang/zig/issues/7138
            if (false) {
                try doTheTestReduce(.Min, [4]f16{ -1.9, 5.1, f16_nan, 100.0 }, f16_nan);
                try doTheTestReduce(.Min, [4]f32{ -1.9, 5.1, f32_nan, 100.0 }, f32_nan);
                try doTheTestReduce(.Min, [4]f64{ -1.9, 5.1, f64_nan, 100.0 }, f64_nan);

                try doTheTestReduce(.Max, [4]f16{ -1.9, 5.1, f16_nan, 100.0 }, f16_nan);
                try doTheTestReduce(.Max, [4]f32{ -1.9, 5.1, f32_nan, 100.0 }, f32_nan);
                try doTheTestReduce(.Max, [4]f64{ -1.9, 5.1, f64_nan, 100.0 }, f64_nan);
            }

            try doTheTestReduce(.Mul, [4]f16{ -1.9, 5.1, f16_nan, 100.0 }, f16_nan);
            try doTheTestReduce(.Mul, [4]f32{ -1.9, 5.1, f32_nan, 100.0 }, f32_nan);
            try doTheTestReduce(.Mul, [4]f64{ -1.9, 5.1, f64_nan, 100.0 }, f64_nan);
        }
    };

    try S.doTheTest();
    comptime try S.doTheTest();
}

test "mask parameter of @shuffle is comptime scope" {
    const __v4hi = std.meta.Vector(4, i16);
    var v4_a = __v4hi{ 0, 0, 0, 0 };
    var v4_b = __v4hi{ 0, 0, 0, 0 };
    var shuffled: __v4hi = @shuffle(i16, v4_a, v4_b, std.meta.Vector(4, i32){
        std.zig.c_translation.shuffleVectorIndex(0, @typeInfo(@TypeOf(v4_a)).Vector.len),
        std.zig.c_translation.shuffleVectorIndex(0, @typeInfo(@TypeOf(v4_a)).Vector.len),
        std.zig.c_translation.shuffleVectorIndex(0, @typeInfo(@TypeOf(v4_a)).Vector.len),
        std.zig.c_translation.shuffleVectorIndex(0, @typeInfo(@TypeOf(v4_a)).Vector.len),
    });
    _ = shuffled;
}
