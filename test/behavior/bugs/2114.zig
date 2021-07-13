const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const math = std.math;

fn ctz(x: anytype) usize {
    return @ctz(@TypeOf(x), x);
}

test "fixed" {
    try testClz();
    comptime try testClz();
}

fn testClz() !void {
    try expectEqual(ctz(@as(u128, 0x40000000000000000000000000000000)), 126);
    try expectEqual(math.rotl(u128, @as(u128, 0x40000000000000000000000000000000), @as(u8, 1)), @as(u128, 0x80000000000000000000000000000000));
    try expectEqual(ctz(@as(u128, 0x80000000000000000000000000000000)), 127);
    try expectEqual(ctz(math.rotl(u128, @as(u128, 0x40000000000000000000000000000000), @as(u8, 1))), 127);
}
