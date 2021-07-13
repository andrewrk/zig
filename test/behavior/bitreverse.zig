const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const minInt = std.math.minInt;

test "@bitReverse" {
    comptime try testBitReverse();
    try testBitReverse();
}

fn testBitReverse() !void {
    // using comptime_ints, unsigned
    try expectEqual(@bitReverse(u0, 0), 0);
    try expectEqual(@bitReverse(u5, 0x12), 0x9);
    try expectEqual(@bitReverse(u8, 0x12), 0x48);
    try expectEqual(@bitReverse(u16, 0x1234), 0x2c48);
    try expectEqual(@bitReverse(u24, 0x123456), 0x6a2c48);
    try expectEqual(@bitReverse(u32, 0x12345678), 0x1e6a2c48);
    try expectEqual(@bitReverse(u40, 0x123456789a), 0x591e6a2c48);
    try expectEqual(@bitReverse(u48, 0x123456789abc), 0x3d591e6a2c48);
    try expectEqual(@bitReverse(u56, 0x123456789abcde), 0x7b3d591e6a2c48);
    try expectEqual(@bitReverse(u64, 0x123456789abcdef1), 0x8f7b3d591e6a2c48);
    try expectEqual(@bitReverse(u128, 0x123456789abcdef11121314151617181), 0x818e868a828c84888f7b3d591e6a2c48);

    // using runtime uints, unsigned
    var num0: u0 = 0;
    try expectEqual(@bitReverse(u0, num0), 0);
    var num5: u5 = 0x12;
    try expectEqual(@bitReverse(u5, num5), 0x9);
    var num8: u8 = 0x12;
    try expectEqual(@bitReverse(u8, num8), 0x48);
    var num16: u16 = 0x1234;
    try expectEqual(@bitReverse(u16, num16), 0x2c48);
    var num24: u24 = 0x123456;
    try expectEqual(@bitReverse(u24, num24), 0x6a2c48);
    var num32: u32 = 0x12345678;
    try expectEqual(@bitReverse(u32, num32), 0x1e6a2c48);
    var num40: u40 = 0x123456789a;
    try expectEqual(@bitReverse(u40, num40), 0x591e6a2c48);
    var num48: u48 = 0x123456789abc;
    try expectEqual(@bitReverse(u48, num48), 0x3d591e6a2c48);
    var num56: u56 = 0x123456789abcde;
    try expectEqual(@bitReverse(u56, num56), 0x7b3d591e6a2c48);
    var num64: u64 = 0x123456789abcdef1;
    try expectEqual(@bitReverse(u64, num64), 0x8f7b3d591e6a2c48);
    var num128: u128 = 0x123456789abcdef11121314151617181;
    try expectEqual(@bitReverse(u128, num128), 0x818e868a828c84888f7b3d591e6a2c48);

    // using comptime_ints, signed, positive
    try expectEqual(@bitReverse(u8, @as(u8, 0)), 0);
    try expectEqual(@bitReverse(i8, @bitCast(i8, @as(u8, 0x92))), @bitCast(i8, @as(u8, 0x49)));
    try expectEqual(@bitReverse(i16, @bitCast(i16, @as(u16, 0x1234))), @bitCast(i16, @as(u16, 0x2c48)));
    try expectEqual(@bitReverse(i24, @bitCast(i24, @as(u24, 0x123456))), @bitCast(i24, @as(u24, 0x6a2c48)));
    try expectEqual(@bitReverse(i32, @bitCast(i32, @as(u32, 0x12345678))), @bitCast(i32, @as(u32, 0x1e6a2c48)));
    try expectEqual(@bitReverse(i40, @bitCast(i40, @as(u40, 0x123456789a))), @bitCast(i40, @as(u40, 0x591e6a2c48)));
    try expectEqual(@bitReverse(i48, @bitCast(i48, @as(u48, 0x123456789abc))), @bitCast(i48, @as(u48, 0x3d591e6a2c48)));
    try expectEqual(@bitReverse(i56, @bitCast(i56, @as(u56, 0x123456789abcde))), @bitCast(i56, @as(u56, 0x7b3d591e6a2c48)));
    try expectEqual(@bitReverse(i64, @bitCast(i64, @as(u64, 0x123456789abcdef1))), @bitCast(i64, @as(u64, 0x8f7b3d591e6a2c48)));
    try expectEqual(@bitReverse(i128, @bitCast(i128, @as(u128, 0x123456789abcdef11121314151617181))), @bitCast(i128, @as(u128, 0x818e868a828c84888f7b3d591e6a2c48)));

    // using signed, negative. Compare to runtime ints returned from llvm.
    var neg8: i8 = -18;
    try expectEqual(@bitReverse(i8, @as(i8, -18)), @bitReverse(i8, neg8));
    var neg16: i16 = -32694;
    try expectEqual(@bitReverse(i16, @as(i16, -32694)), @bitReverse(i16, neg16));
    var neg24: i24 = -6773785;
    try expectEqual(@bitReverse(i24, @as(i24, -6773785)), @bitReverse(i24, neg24));
    var neg32: i32 = -16773785;
    try expectEqual(@bitReverse(i32, @as(i32, -16773785)), @bitReverse(i32, neg32));
}
