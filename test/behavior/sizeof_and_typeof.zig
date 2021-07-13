const std = @import("std");
const builtin = std.builtin;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "@sizeOf and @TypeOf" {
    const y: @TypeOf(x) = 120;
    try expectEqual(@sizeOf(@TypeOf(y)), 2);
}
const x: u16 = 13;
const z: @TypeOf(x) = 19;

const A = struct {
    a: u8,
    b: u32,
    c: u8,
    d: u3,
    e: u5,
    f: u16,
    g: u16,
    h: u9,
    i: u7,
};

const P = packed struct {
    a: u8,
    b: u32,
    c: u8,
    d: u3,
    e: u5,
    f: u16,
    g: u16,
    h: u9,
    i: u7,
};

test "@offsetOf" {
    // Packed structs have fixed memory layout
    try expectEqual(@offsetOf(P, "a"), 0);
    try expectEqual(@offsetOf(P, "b"), 1);
    try expectEqual(@offsetOf(P, "c"), 5);
    try expectEqual(@offsetOf(P, "d"), 6);
    try expectEqual(@offsetOf(P, "e"), 6);
    try expectEqual(@offsetOf(P, "f"), 7);
    try expectEqual(@offsetOf(P, "g"), 9);
    try expectEqual(@offsetOf(P, "h"), 11);
    try expectEqual(@offsetOf(P, "i"), 12);

    // Normal struct fields can be moved/padded
    var a: A = undefined;
    try expectEqual(@ptrToInt(&a.a) - @ptrToInt(&a), @offsetOf(A, "a"));
    try expectEqual(@ptrToInt(&a.b) - @ptrToInt(&a), @offsetOf(A, "b"));
    try expectEqual(@ptrToInt(&a.c) - @ptrToInt(&a), @offsetOf(A, "c"));
    try expectEqual(@ptrToInt(&a.d) - @ptrToInt(&a), @offsetOf(A, "d"));
    try expectEqual(@ptrToInt(&a.e) - @ptrToInt(&a), @offsetOf(A, "e"));
    try expectEqual(@ptrToInt(&a.f) - @ptrToInt(&a), @offsetOf(A, "f"));
    try expectEqual(@ptrToInt(&a.g) - @ptrToInt(&a), @offsetOf(A, "g"));
    try expectEqual(@ptrToInt(&a.h) - @ptrToInt(&a), @offsetOf(A, "h"));
    try expectEqual(@ptrToInt(&a.i) - @ptrToInt(&a), @offsetOf(A, "i"));
}

test "@offsetOf packed struct, array length not power of 2 or multiple of native pointer width in bytes" {
    const p3a_len = 3;
    const P3 = packed struct {
        a: [p3a_len]u8,
        b: usize,
    };
    try std.testing.expectEqual(0, @offsetOf(P3, "a"));
    try std.testing.expectEqual(p3a_len, @offsetOf(P3, "b"));

    const p5a_len = 5;
    const P5 = packed struct {
        a: [p5a_len]u8,
        b: usize,
    };
    try std.testing.expectEqual(0, @offsetOf(P5, "a"));
    try std.testing.expectEqual(p5a_len, @offsetOf(P5, "b"));

    const p6a_len = 6;
    const P6 = packed struct {
        a: [p6a_len]u8,
        b: usize,
    };
    try std.testing.expectEqual(0, @offsetOf(P6, "a"));
    try std.testing.expectEqual(p6a_len, @offsetOf(P6, "b"));

    const p7a_len = 7;
    const P7 = packed struct {
        a: [p7a_len]u8,
        b: usize,
    };
    try std.testing.expectEqual(0, @offsetOf(P7, "a"));
    try std.testing.expectEqual(p7a_len, @offsetOf(P7, "b"));

    const p9a_len = 9;
    const P9 = packed struct {
        a: [p9a_len]u8,
        b: usize,
    };
    try std.testing.expectEqual(0, @offsetOf(P9, "a"));
    try std.testing.expectEqual(p9a_len, @offsetOf(P9, "b"));

    // 10, 11, 12, 13, 14, 15, 17, 18, 19, 20, 21, 22, 23, 25 etc. are further cases
}

test "@bitOffsetOf" {
    // Packed structs have fixed memory layout
    try expectEqual(@bitOffsetOf(P, "a"), 0);
    try expectEqual(@bitOffsetOf(P, "b"), 8);
    try expectEqual(@bitOffsetOf(P, "c"), 40);
    try expectEqual(@bitOffsetOf(P, "d"), 48);
    try expectEqual(@bitOffsetOf(P, "e"), 51);
    try expectEqual(@bitOffsetOf(P, "f"), 56);
    try expectEqual(@bitOffsetOf(P, "g"), 72);

    try expectEqual(@offsetOf(A, "a") * 8, @bitOffsetOf(A, "a"));
    try expectEqual(@offsetOf(A, "b") * 8, @bitOffsetOf(A, "b"));
    try expectEqual(@offsetOf(A, "c") * 8, @bitOffsetOf(A, "c"));
    try expectEqual(@offsetOf(A, "d") * 8, @bitOffsetOf(A, "d"));
    try expectEqual(@offsetOf(A, "e") * 8, @bitOffsetOf(A, "e"));
    try expectEqual(@offsetOf(A, "f") * 8, @bitOffsetOf(A, "f"));
    try expectEqual(@offsetOf(A, "g") * 8, @bitOffsetOf(A, "g"));
}

test "@sizeOf on compile-time types" {
    try expectEqual(@sizeOf(comptime_int), 0);
    try expectEqual(@sizeOf(comptime_float), 0);
    try expectEqual(@sizeOf(@TypeOf(.hi)), 0);
    try expectEqual(@sizeOf(@TypeOf(type)), 0);
}

test "@sizeOf(T) == 0 doesn't force resolving struct size" {
    const S = struct {
        const Foo = struct {
            y: if (@sizeOf(Foo) == 0) u64 else u32,
        };
        const Bar = struct {
            x: i32,
            y: if (0 == @sizeOf(Bar)) u64 else u32,
        };
    };

    try expectEqual(@sizeOf(S.Foo), 4);
    try expectEqual(@sizeOf(S.Bar), 8);
}

test "@TypeOf() has no runtime side effects" {
    const S = struct {
        fn foo(comptime T: type, ptr: *T) T {
            ptr.* += 1;
            return ptr.*;
        }
    };
    var data: i32 = 0;
    const T = @TypeOf(S.foo(i32, &data));
    comptime try expectEqual(T, i32);
    try expectEqual(data, 0);
}

test "@TypeOf() with multiple arguments" {
    {
        var var_1: u32 = undefined;
        var var_2: u8 = undefined;
        var var_3: u64 = undefined;
        comptime try expectEqual(@TypeOf(var_1, var_2, var_3), u64);
    }
    {
        var var_1: f16 = undefined;
        var var_2: f32 = undefined;
        var var_3: f64 = undefined;
        comptime try expectEqual(@TypeOf(var_1, var_2, var_3), f64);
    }
    {
        var var_1: u16 = undefined;
        comptime try expectEqual(@TypeOf(var_1, 0xffff), u16);
    }
    {
        var var_1: f32 = undefined;
        comptime try expectEqual(@TypeOf(var_1, 3.1415), f32);
    }
}

test "branching logic inside @TypeOf" {
    const S = struct {
        var data: i32 = 0;
        fn foo() anyerror!i32 {
            data += 1;
            return undefined;
        }
    };
    const T = @TypeOf(S.foo() catch undefined);
    comptime try expectEqual(T, i32);
    try expectEqual(S.data, 0);
}

fn fn1(alpha: bool) void {
    const n: usize = 7;
    _ = if (alpha) n else @sizeOf(usize);
}

test "lazy @sizeOf result is checked for definedness" {
    _ = fn1;
}

test "@bitSizeOf" {
    try expectEqual(@bitSizeOf(u2), 2);
    try expectEqual(@bitSizeOf(u8), @sizeOf(u8) * 8);
    try expect(@bitSizeOf(struct {
        a: u2,
    }) == 8);
    try expect(@bitSizeOf(packed struct {
        a: u2,
    }) == 2);
}

test "@sizeOf comparison against zero" {
    const S0 = struct {
        f: *@This(),
    };
    const U0 = union {
        f: *@This(),
    };
    const S1 = struct {
        fn H(comptime T: type) type {
            return struct {
                x: T,
            };
        }
        f0: H(*@This()),
        f1: H(**@This()),
        f2: H(***@This()),
    };
    const U1 = union {
        fn H(comptime T: type) type {
            return struct {
                x: T,
            };
        }
        f0: H(*@This()),
        f1: H(**@This()),
        f2: H(***@This()),
    };
    const S = struct {
        fn doTheTest(comptime T: type, comptime result: bool) !void {
            try expectEqual(result, @sizeOf(T) > 0);
        }
    };
    // Zero-sized type
    try S.doTheTest(u0, false);
    try S.doTheTest(*u0, false);
    // Non byte-sized type
    try S.doTheTest(u1, true);
    try S.doTheTest(*u1, true);
    // Regular type
    try S.doTheTest(u8, true);
    try S.doTheTest(*u8, true);
    try S.doTheTest(f32, true);
    try S.doTheTest(*f32, true);
    // Container with ptr pointing to themselves
    try S.doTheTest(S0, true);
    try S.doTheTest(U0, true);
    try S.doTheTest(S1, true);
    try S.doTheTest(U1, true);
}
