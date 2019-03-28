const expect = @import("std").testing.expect;

test "@popCount" {
    comptime testPopCount();
    testPopCount();
}

fn testPopCount() void {
    {
        var x: u32 = 0xaa;
        expect(@popCount(u32, x) == 4);
    }
    {
        var x: u32 = 0xaaaaaaaa;
        expect(@popCount(u32, x) == 16);
    }
    {
        var x: u32 = 0xaaaaaaaa;
        expect(@popCount(u64, x) == 16);
    }
    {
        var x: i16 = -1;
        expect(@popCount(i16, x) == 16);
    }
    {
        var x: i8 = -120;
        expect(@popCount(i8, x) == 2);
    }
    comptime {
        expect(@popCount(i8, -120) == 2);
    }
    comptime {
        expect(@popCount(u128, 0b11111111000110001100010000100001000011000011100101010001) == 24);
    }
}

