const std = @import("std");
const builtin = @import("builtin");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const maxInt = std.math.maxInt;
const native_endian = builtin.target.cpu.arch.endian();

test "@bitCast i32 -> u32" {
    try testBitCast_i32_u32();
    comptime try testBitCast_i32_u32();
}

fn testBitCast_i32_u32() !void {
    try expectEqual(conv(-1), maxInt(u32));
    try expectEqual(conv2(maxInt(u32)), -1);
}

fn conv(x: i32) u32 {
    return @bitCast(u32, x);
}
fn conv2(x: u32) i32 {
    return @bitCast(i32, x);
}

test "@bitCast enum to its integer type" {
    const SOCK = enum(c_int) {
        A,
        B,

        fn testBitCastExternEnum() !void {
            var SOCK_DGRAM = @This().B;
            var sock_dgram = @bitCast(c_int, SOCK_DGRAM);
            try expectEqual(sock_dgram, 1);
        }
    };

    try SOCK.testBitCastExternEnum();
    comptime try SOCK.testBitCastExternEnum();
}

test "@bitCast packed structs at runtime and comptime" {
    const Full = packed struct {
        number: u16,
    };
    const Divided = packed struct {
        half1: u8,
        quarter3: u4,
        quarter4: u4,
    };
    const S = struct {
        fn doTheTest() !void {
            var full = Full{ .number = 0x1234 };
            var two_halves = @bitCast(Divided, full);
            switch (native_endian) {
                .Big => {
                    try expectEqual(two_halves.half1, 0x12);
                    try expectEqual(two_halves.quarter3, 0x3);
                    try expectEqual(two_halves.quarter4, 0x4);
                },
                .Little => {
                    try expectEqual(two_halves.half1, 0x34);
                    try expectEqual(two_halves.quarter3, 0x2);
                    try expectEqual(two_halves.quarter4, 0x1);
                },
            }
        }
    };
    try S.doTheTest();
    comptime try S.doTheTest();
}

test "@bitCast extern structs at runtime and comptime" {
    const Full = extern struct {
        number: u16,
    };
    const TwoHalves = extern struct {
        half1: u8,
        half2: u8,
    };
    const S = struct {
        fn doTheTest() !void {
            var full = Full{ .number = 0x1234 };
            var two_halves = @bitCast(TwoHalves, full);
            switch (native_endian) {
                .Big => {
                    try expectEqual(two_halves.half1, 0x12);
                    try expectEqual(two_halves.half2, 0x34);
                },
                .Little => {
                    try expectEqual(two_halves.half1, 0x34);
                    try expectEqual(two_halves.half2, 0x12);
                },
            }
        }
    };
    try S.doTheTest();
    comptime try S.doTheTest();
}

test "bitcast packed struct to integer and back" {
    const LevelUpMove = packed struct {
        move_id: u9,
        level: u7,
    };
    const S = struct {
        fn doTheTest() !void {
            var move = LevelUpMove{ .move_id = 1, .level = 2 };
            var v = @bitCast(u16, move);
            var back_to_a_move = @bitCast(LevelUpMove, v);
            try expectEqual(back_to_a_move.move_id, 1);
            try expectEqual(back_to_a_move.level, 2);
        }
    };
    try S.doTheTest();
    comptime try S.doTheTest();
}

test "implicit cast to error union by returning" {
    const S = struct {
        fn entry() !void {
            try expectEqual((func(-1) catch unreachable), maxInt(u64));
        }
        pub fn func(sz: i64) anyerror!u64 {
            return @bitCast(u64, sz);
        }
    };
    try S.entry();
    comptime try S.entry();
}

// issue #3010: compiler segfault
test "bitcast literal [4]u8 param to u32" {
    const ip = @bitCast(u32, [_]u8{ 255, 255, 255, 255 });
    try expectEqual(ip, maxInt(u32));
}

test "bitcast packed struct literal to byte" {
    const Foo = packed struct {
        value: u8,
    };
    const casted = @bitCast(u8, Foo{ .value = 0xF });
    try expectEqual(casted, 0xf);
}

test "comptime bitcast used in expression has the correct type" {
    const Foo = packed struct {
        value: u8,
    };
    try expectEqual(@bitCast(u8, Foo{ .value = 0xF }), 0xf);
}

test "bitcast result to _" {
    _ = @bitCast(u8, @as(i8, 1));
}

test "nested bitcast" {
    const S = struct {
        fn moo(x: isize) !void {
            try @import("std").testing.expectEqual(@intCast(isize, 42), x);
        }

        fn foo(x: isize) !void {
            try @This().moo(
                @bitCast(isize, if (x != 0) @bitCast(usize, x) else @bitCast(usize, x)),
            );
        }
    };

    try S.foo(42);
    comptime try S.foo(42);
}

test "bitcast passed as tuple element" {
    const S = struct {
        fn foo(args: anytype) !void {
            comptime try expectEqual(@TypeOf(args[0]), f32);
            try expectEqual(args[0], 12.34);
        }
    };
    try S.foo(.{@bitCast(f32, @as(u32, 0x414570A4))});
}

test "triple level result location with bitcast sandwich passed as tuple element" {
    const S = struct {
        fn foo(args: anytype) !void {
            comptime try expectEqual(@TypeOf(args[0]), f64);
            try expect(args[0] > 12.33 and args[0] < 12.35);
        }
    };
    try S.foo(.{@as(f64, @bitCast(f32, @as(u32, 0x414570A4)))});
}

test "bitcast generates a temporary value" {
    var y = @as(u16, 0x55AA);
    const x = @bitCast(u16, @bitCast([2]u8, y));
    try expectEqual(y, x);
}
