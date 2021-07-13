const expect = @import("std").testing.expect;
const expectEqual = @import("std").testing.expectEqual;

test "@popCount" {
    comptime try testPopCount();
    try testPopCount();
}

fn testPopCount() !void {
    {
        var x: u32 = 0xffffffff;
        try expectEqual(@popCount(u32, x), 32);
    }
    {
        var x: u5 = 0x1f;
        try expectEqual(@popCount(u5, x), 5);
    }
    {
        var x: u32 = 0xaa;
        try expectEqual(@popCount(u32, x), 4);
    }
    {
        var x: u32 = 0xaaaaaaaa;
        try expectEqual(@popCount(u32, x), 16);
    }
    {
        var x: u32 = 0xaaaaaaaa;
        try expectEqual(@popCount(u32, x), 16);
    }
    {
        var x: i16 = -1;
        try expectEqual(@popCount(i16, x), 16);
    }
    {
        var x: i8 = -120;
        try expectEqual(@popCount(i8, x), 2);
    }
    comptime {
        try expectEqual(@popCount(u8, @bitCast(u8, @as(i8, -120))), 2);
    }
    comptime {
        try expectEqual(@popCount(i128, 0b11111111000110001100010000100001000011000011100101010001), 24);
    }
}
