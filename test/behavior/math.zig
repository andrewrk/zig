const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const maxInt = std.math.maxInt;
const minInt = std.math.minInt;
const mem = std.mem;

test "division" {
    try testDivision();
    comptime try testDivision();
}
fn testDivision() !void {
    try expectEqual(div(u32, 13, 3), 4);
    try expectEqual(div(f16, 1.0, 2.0), 0.5);
    try expectEqual(div(f32, 1.0, 2.0), 0.5);

    try expectEqual(divExact(u32, 55, 11), 5);
    try expectEqual(divExact(i32, -55, 11), -5);
    try expectEqual(divExact(f16, 55.0, 11.0), 5.0);
    try expectEqual(divExact(f16, -55.0, 11.0), -5.0);
    try expectEqual(divExact(f32, 55.0, 11.0), 5.0);
    try expectEqual(divExact(f32, -55.0, 11.0), -5.0);

    try expectEqual(divFloor(i32, 5, 3), 1);
    try expectEqual(divFloor(i32, -5, 3), -2);
    try expectEqual(divFloor(f16, 5.0, 3.0), 1.0);
    try expectEqual(divFloor(f16, -5.0, 3.0), -2.0);
    try expectEqual(divFloor(f32, 5.0, 3.0), 1.0);
    try expectEqual(divFloor(f32, -5.0, 3.0), -2.0);
    try expectEqual(divFloor(i32, -0x80000000, -2), 0x40000000);
    try expectEqual(divFloor(i32, 0, -0x80000000), 0);
    try expectEqual(divFloor(i32, -0x40000001, 0x40000000), -2);
    try expectEqual(divFloor(i32, -0x80000000, 1), -0x80000000);
    try expectEqual(divFloor(i32, 10, 12), 0);
    try expectEqual(divFloor(i32, -14, 12), -2);
    try expectEqual(divFloor(i32, -2, 12), -1);

    try expectEqual(divTrunc(i32, 5, 3), 1);
    try expectEqual(divTrunc(i32, -5, 3), -1);
    try expectEqual(divTrunc(f16, 5.0, 3.0), 1.0);
    try expectEqual(divTrunc(f16, -5.0, 3.0), -1.0);
    try expectEqual(divTrunc(f32, 5.0, 3.0), 1.0);
    try expectEqual(divTrunc(f32, -5.0, 3.0), -1.0);
    try expectEqual(divTrunc(f64, 5.0, 3.0), 1.0);
    try expectEqual(divTrunc(f64, -5.0, 3.0), -1.0);
    try expectEqual(divTrunc(i32, 10, 12), 0);
    try expectEqual(divTrunc(i32, -14, 12), -1);
    try expectEqual(divTrunc(i32, -2, 12), 0);

    try expectEqual(mod(i32, 10, 12), 10);
    try expectEqual(mod(i32, -14, 12), 10);
    try expectEqual(mod(i32, -2, 12), 10);

    comptime {
        try expect(
            1194735857077236777412821811143690633098347576 % 508740759824825164163191790951174292733114988 == 177254337427586449086438229241342047632117600,
        );
        try expect(
            @rem(-1194735857077236777412821811143690633098347576, 508740759824825164163191790951174292733114988) == -177254337427586449086438229241342047632117600,
        );
        try expect(
            1194735857077236777412821811143690633098347576 / 508740759824825164163191790951174292733114988 == 2,
        );
        try expect(
            @divTrunc(-1194735857077236777412821811143690633098347576, 508740759824825164163191790951174292733114988) == -2,
        );
        try expect(
            @divTrunc(1194735857077236777412821811143690633098347576, -508740759824825164163191790951174292733114988) == -2,
        );
        try expect(
            @divTrunc(-1194735857077236777412821811143690633098347576, -508740759824825164163191790951174292733114988) == 2,
        );
        try expect(
            4126227191251978491697987544882340798050766755606969681711 % 10 == 1,
        );
    }
}
fn div(comptime T: type, a: T, b: T) T {
    return a / b;
}
fn divExact(comptime T: type, a: T, b: T) T {
    return @divExact(a, b);
}
fn divFloor(comptime T: type, a: T, b: T) T {
    return @divFloor(a, b);
}
fn divTrunc(comptime T: type, a: T, b: T) T {
    return @divTrunc(a, b);
}
fn mod(comptime T: type, a: T, b: T) T {
    return @mod(a, b);
}

test "@addWithOverflow" {
    var result: u8 = undefined;
    try expect(@addWithOverflow(u8, 250, 100, &result));
    try expect(!@addWithOverflow(u8, 100, 150, &result));
    try expectEqual(result, 250);
}

// TODO test mulWithOverflow
// TODO test subWithOverflow

test "@shlWithOverflow" {
    var result: u16 = undefined;
    try expect(@shlWithOverflow(u16, 0b0010111111111111, 3, &result));
    try expect(!@shlWithOverflow(u16, 0b0010111111111111, 2, &result));
    try expectEqual(result, 0b1011111111111100);
}

test "@*WithOverflow with u0 values" {
    var result: u0 = undefined;
    try expect(!@addWithOverflow(u0, 0, 0, &result));
    try expect(!@subWithOverflow(u0, 0, 0, &result));
    try expect(!@mulWithOverflow(u0, 0, 0, &result));
    try expect(!@shlWithOverflow(u0, 0, 0, &result));
}

test "@clz" {
    try testClz();
    comptime try testClz();
}

fn testClz() !void {
    try expectEqual(clz(u8, 0b10001010), 0);
    try expectEqual(clz(u8, 0b00001010), 4);
    try expectEqual(clz(u8, 0b00011010), 3);
    try expectEqual(clz(u8, 0b00000000), 8);
    try expectEqual(clz(u128, 0xffffffffffffffff), 64);
    try expectEqual(clz(u128, 0x10000000000000000), 63);
}

fn clz(comptime T: type, x: T) usize {
    return @clz(T, x);
}

test "@ctz" {
    try testCtz();
    comptime try testCtz();
}

fn testCtz() !void {
    try expectEqual(ctz(u8, 0b10100000), 5);
    try expectEqual(ctz(u8, 0b10001010), 1);
    try expectEqual(ctz(u8, 0b00000000), 8);
    try expectEqual(ctz(u16, 0b00000000), 16);
}

fn ctz(comptime T: type, x: T) usize {
    return @ctz(T, x);
}

test "assignment operators" {
    var i: u32 = 0;
    i += 5;
    try expectEqual(i, 5);
    i -= 2;
    try expectEqual(i, 3);
    i *= 20;
    try expectEqual(i, 60);
    i /= 3;
    try expectEqual(i, 20);
    i %= 11;
    try expectEqual(i, 9);
    i <<= 1;
    try expectEqual(i, 18);
    i >>= 2;
    try expectEqual(i, 4);
    i = 6;
    i &= 5;
    try expectEqual(i, 4);
    i ^= 6;
    try expectEqual(i, 2);
    i = 6;
    i |= 3;
    try expectEqual(i, 7);
}

test "three expr in a row" {
    try testThreeExprInARow(false, true);
    comptime try testThreeExprInARow(false, true);
}
fn testThreeExprInARow(f: bool, t: bool) !void {
    try assertFalse(f or f or f);
    try assertFalse(t and t and f);
    try assertFalse(1 | 2 | 4 != 7);
    try assertFalse(3 ^ 6 ^ 8 != 13);
    try assertFalse(7 & 14 & 28 != 4);
    try assertFalse(9 << 1 << 2 != 9 << 3);
    try assertFalse(90 >> 1 >> 2 != 90 >> 3);
    try assertFalse(100 - 1 + 1000 != 1099);
    try assertFalse(5 * 4 / 2 % 3 != 1);
    try assertFalse(@as(i32, @as(i32, 5)) != 5);
    try assertFalse(!!false);
    try assertFalse(@as(i32, 7) != --(@as(i32, 7)));
}
fn assertFalse(b: bool) !void {
    try expect(!b);
}

test "const number literal" {
    const one = 1;
    const eleven = ten + one;

    try expectEqual(eleven, 11);
}
const ten = 10;

test "unsigned wrapping" {
    try testUnsignedWrappingEval(maxInt(u32));
    comptime try testUnsignedWrappingEval(maxInt(u32));
}
fn testUnsignedWrappingEval(x: u32) !void {
    const zero = x +% 1;
    try expectEqual(zero, 0);
    const orig = zero -% 1;
    try expectEqual(orig, maxInt(u32));
}

test "signed wrapping" {
    try testSignedWrappingEval(maxInt(i32));
    comptime try testSignedWrappingEval(maxInt(i32));
}
fn testSignedWrappingEval(x: i32) !void {
    const min_val = x +% 1;
    try expectEqual(min_val, minInt(i32));
    const max_val = min_val -% 1;
    try expectEqual(max_val, maxInt(i32));
}

test "signed negation wrapping" {
    try testSignedNegationWrappingEval(minInt(i16));
    comptime try testSignedNegationWrappingEval(minInt(i16));
}
fn testSignedNegationWrappingEval(x: i16) !void {
    try expectEqual(x, -32768);
    const neg = -%x;
    try expectEqual(neg, -32768);
}

test "unsigned negation wrapping" {
    try testUnsignedNegationWrappingEval(1);
    comptime try testUnsignedNegationWrappingEval(1);
}
fn testUnsignedNegationWrappingEval(x: u16) !void {
    try expectEqual(x, 1);
    const neg = -%x;
    try expectEqual(neg, maxInt(u16));
}

test "unsigned 64-bit division" {
    try test_u64_div();
    comptime try test_u64_div();
}
fn test_u64_div() !void {
    const result = divWithResult(1152921504606846976, 34359738365);
    try expectEqual(result.quotient, 33554432);
    try expectEqual(result.remainder, 100663296);
}
fn divWithResult(a: u64, b: u64) DivResult {
    return DivResult{
        .quotient = a / b,
        .remainder = a % b,
    };
}
const DivResult = struct {
    quotient: u64,
    remainder: u64,
};

test "binary not" {
    try expect(comptime x: {
        break :x ~@as(u16, 0b1010101010101010) == 0b0101010101010101;
    });
    try expect(comptime x: {
        break :x ~@as(u64, 2147483647) == 18446744071562067968;
    });
    try testBinaryNot(0b1010101010101010);
}

fn testBinaryNot(x: u16) !void {
    try expectEqual(~x, 0b0101010101010101);
}

test "small int addition" {
    var x: u2 = 0;
    try expectEqual(x, 0);

    x += 1;
    try expectEqual(x, 1);

    x += 1;
    try expectEqual(x, 2);

    x += 1;
    try expectEqual(x, 3);

    var result: @TypeOf(x) = 3;
    try expect(@addWithOverflow(@TypeOf(x), x, 1, &result));

    try expectEqual(result, 0);
}

test "float equality" {
    const x: f64 = 0.012;
    const y: f64 = x + 1.0;

    try testFloatEqualityImpl(x, y);
    comptime try testFloatEqualityImpl(x, y);
}

fn testFloatEqualityImpl(x: f64, y: f64) !void {
    const y2 = x + 1.0;
    try expectEqual(y, y2);
}

test "allow signed integer division/remainder when values are comptime known and positive or exact" {
    try expectEqual(5 / 3, 1);
    try expectEqual(-5 / -3, 1);
    try expectEqual(-6 / 3, -2);

    try expectEqual(5 % 3, 2);
    try expectEqual(-6 % 3, 0);
}

test "hex float literal parsing" {
    comptime try expectEqual(0x1.0, 1.0);
}

test "quad hex float literal parsing in range" {
    const a = 0x1.af23456789bbaaab347645365cdep+5;
    const b = 0x1.dedafcff354b6ae9758763545432p-9;
    const c = 0x1.2f34dd5f437e849b4baab754cdefp+4534;
    const d = 0x1.edcbff8ad76ab5bf46463233214fp-435;
    if (false) {
        a;
        b;
        c;
        d;
    }
}

test "quad hex float literal parsing accurate" {
    const a: f128 = 0x1.1111222233334444555566667777p+0;

    // implied 1 is dropped, with an exponent of 0 (0x3fff) after biasing.
    const expected: u128 = 0x3fff1111222233334444555566667777;
    try expectEqual(@bitCast(u128, a), expected);

    // non-normalized
    const b: f128 = 0x11.111222233334444555566667777p-4;
    try expectEqual(@bitCast(u128, b), expected);

    const S = struct {
        fn doTheTest() !void {
            {
                var f: f128 = 0x1.2eab345678439abcdefea56782346p+5;
                try expectEqual(@bitCast(u128, f), 0x40042eab345678439abcdefea5678234);
            }
            {
                var f: f128 = 0x1.edcb34a235253948765432134674fp-1;
                try expectEqual(@bitCast(u128, f), 0x3ffeedcb34a235253948765432134674);
            }
            {
                var f: f128 = 0x1.353e45674d89abacc3a2ebf3ff4ffp-50;
                try expectEqual(@bitCast(u128, f), 0x3fcd353e45674d89abacc3a2ebf3ff50);
            }
            {
                var f: f128 = 0x1.ed8764648369535adf4be3214567fp-9;
                try expectEqual(@bitCast(u128, f), 0x3ff6ed8764648369535adf4be3214568);
            }
            const exp2ft = [_]f64{
                0x1.6a09e667f3bcdp-1,
                0x1.7a11473eb0187p-1,
                0x1.8ace5422aa0dbp-1,
                0x1.9c49182a3f090p-1,
                0x1.ae89f995ad3adp-1,
                0x1.c199bdd85529cp-1,
                0x1.d5818dcfba487p-1,
                0x1.ea4afa2a490dap-1,
                0x1.0000000000000p+0,
                0x1.0b5586cf9890fp+0,
                0x1.172b83c7d517bp+0,
                0x1.2387a6e756238p+0,
                0x1.306fe0a31b715p+0,
                0x1.3dea64c123422p+0,
                0x1.4bfdad5362a27p+0,
                0x1.5ab07dd485429p+0,
                0x1.8p23,
                0x1.62e430p-1,
                0x1.ebfbe0p-3,
                0x1.c6b348p-5,
                0x1.3b2c9cp-7,
                0x1.0p127,
                -0x1.0p-149,
            };

            const answers = [_]u64{
                0x3fe6a09e667f3bcd,
                0x3fe7a11473eb0187,
                0x3fe8ace5422aa0db,
                0x3fe9c49182a3f090,
                0x3feae89f995ad3ad,
                0x3fec199bdd85529c,
                0x3fed5818dcfba487,
                0x3feea4afa2a490da,
                0x3ff0000000000000,
                0x3ff0b5586cf9890f,
                0x3ff172b83c7d517b,
                0x3ff2387a6e756238,
                0x3ff306fe0a31b715,
                0x3ff3dea64c123422,
                0x3ff4bfdad5362a27,
                0x3ff5ab07dd485429,
                0x4168000000000000,
                0x3fe62e4300000000,
                0x3fcebfbe00000000,
                0x3fac6b3480000000,
                0x3f83b2c9c0000000,
                0x47e0000000000000,
                0xb6a0000000000000,
            };

            for (exp2ft) |x, i| {
                try expectEqual(@bitCast(u64, x), answers[i]);
            }
        }
    };
    try S.doTheTest();
    comptime try S.doTheTest();
}

test "underscore separator parsing" {
    try expectEqual(0_0_0_0, 0);
    try expectEqual(1_234_567, 1234567);
    try expectEqual(001_234_567, 1234567);
    try expectEqual(0_0_1_2_3_4_5_6_7, 1234567);

    try expectEqual(0b0_0_0_0, 0);
    try expectEqual(0b1010_1010, 0b10101010);
    try expectEqual(0b0000_1010_1010, 0b10101010);
    try expectEqual(0b1_0_1_0_1_0_1_0, 0b10101010);

    try expectEqual(0o0_0_0_0, 0);
    try expectEqual(0o1010_1010, 0o10101010);
    try expectEqual(0o0000_1010_1010, 0o10101010);
    try expectEqual(0o1_0_1_0_1_0_1_0, 0o10101010);

    try expectEqual(0x0_0_0_0, 0);
    try expectEqual(0x1010_1010, 0x10101010);
    try expectEqual(0x0000_1010_1010, 0x10101010);
    try expectEqual(0x1_0_1_0_1_0_1_0, 0x10101010);

    try expectEqual(123_456.789_000e1_0, 123456.789000e10);
    try expectEqual(0_1_2_3_4_5_6.7_8_9_0_0_0e0_0_1_0, 123456.789000e10);

    try expectEqual(0x1234_5678.9ABC_DEF0p-1_0, 0x12345678.9ABCDEF0p-10);
    try expectEqual(0x1_2_3_4_5_6_7_8.9_A_B_C_D_E_F_0p-0_0_0_1_0, 0x12345678.9ABCDEF0p-10);
}

test "hex float literal within range" {
    const a = 0x1.0p16383;
    const b = 0x0.1p16387;
    const c = 0x1.0p-16382;
    if (false) {
        a;
        b;
        c;
    }
}

test "truncating shift left" {
    try testShlTrunc(maxInt(u16));
    comptime try testShlTrunc(maxInt(u16));
}
fn testShlTrunc(x: u16) !void {
    const shifted = x << 1;
    try expectEqual(shifted, 65534);
}

test "truncating shift right" {
    try testShrTrunc(maxInt(u16));
    comptime try testShrTrunc(maxInt(u16));
}
fn testShrTrunc(x: u16) !void {
    const shifted = x >> 1;
    try expectEqual(shifted, 32767);
}

test "exact shift left" {
    try testShlExact(0b00110101);
    comptime try testShlExact(0b00110101);
}
fn testShlExact(x: u8) !void {
    const shifted = @shlExact(x, 2);
    try expectEqual(shifted, 0b11010100);
}

test "exact shift right" {
    try testShrExact(0b10110100);
    comptime try testShrExact(0b10110100);
}
fn testShrExact(x: u8) !void {
    const shifted = @shrExact(x, 2);
    try expectEqual(shifted, 0b00101101);
}

test "shift left/right on u0 operand" {
    const S = struct {
        fn doTheTest() !void {
            var x: u0 = 0;
            var y: u0 = 0;
            try expectEqual(@as(u0, 0), x << 0);
            try expectEqual(@as(u0, 0), x >> 0);
            try expectEqual(@as(u0, 0), x << y);
            try expectEqual(@as(u0, 0), x >> y);
            try expectEqual(@as(u0, 0), @shlExact(x, 0));
            try expectEqual(@as(u0, 0), @shrExact(x, 0));
            try expectEqual(@as(u0, 0), @shlExact(x, y));
            try expectEqual(@as(u0, 0), @shrExact(x, y));
        }
    };
    try S.doTheTest();
    comptime try S.doTheTest();
}

test "comptime_int addition" {
    comptime {
        try expectEqual(35361831660712422535336160538497375248 + 101752735581729509668353361206450473702, 137114567242441932203689521744947848950);
        try expectEqual(594491908217841670578297176641415611445982232488944558774612 + 390603545391089362063884922208143568023166603618446395589768, 985095453608931032642182098849559179469148836107390954364380);
    }
}

test "comptime_int multiplication" {
    comptime {
        try expect(
            45960427431263824329884196484953148229 * 128339149605334697009938835852565949723 == 5898522172026096622534201617172456926982464453350084962781392314016180490567,
        );
        try expect(
            594491908217841670578297176641415611445982232488944558774612 * 390603545391089362063884922208143568023166603618446395589768 == 232210647056203049913662402532976186578842425262306016094292237500303028346593132411865381225871291702600263463125370016,
        );
    }
}

test "comptime_int shifting" {
    comptime {
        try expectEqual((@as(u128, 1) << 127), 0x80000000000000000000000000000000);
    }
}

test "comptime_int multi-limb shift and mask" {
    comptime {
        var a = 0xefffffffa0000001eeeeeeefaaaaaaab;

        try expectEqual(@as(u32, a & 0xffffffff), 0xaaaaaaab);
        a >>= 32;
        try expectEqual(@as(u32, a & 0xffffffff), 0xeeeeeeef);
        a >>= 32;
        try expectEqual(@as(u32, a & 0xffffffff), 0xa0000001);
        a >>= 32;
        try expectEqual(@as(u32, a & 0xffffffff), 0xefffffff);
        a >>= 32;

        try expectEqual(a, 0);
    }
}

test "comptime_int multi-limb partial shift right" {
    comptime {
        var a = 0x1ffffffffeeeeeeee;
        a >>= 16;
        try expectEqual(a, 0x1ffffffffeeee);
    }
}

test "xor" {
    try test_xor();
    comptime try test_xor();
}

fn test_xor() !void {
    try expectEqual(0xFF ^ 0x00, 0xFF);
    try expectEqual(0xF0 ^ 0x0F, 0xFF);
    try expectEqual(0xFF ^ 0xF0, 0x0F);
    try expectEqual(0xFF ^ 0x0F, 0xF0);
    try expectEqual(0xFF ^ 0xFF, 0x00);
}

test "comptime_int xor" {
    comptime {
        try expectEqual(0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF ^ 0x00000000000000000000000000000000, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF);
        try expectEqual(0xFFFFFFFFFFFFFFFF0000000000000000 ^ 0x0000000000000000FFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF);
        try expectEqual(0xFFFFFFFFFFFFFFFF0000000000000000 ^ 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF, 0x0000000000000000FFFFFFFFFFFFFFFF);
        try expectEqual(0x0000000000000000FFFFFFFFFFFFFFFF ^ 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF0000000000000000);
        try expectEqual(0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF ^ 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF, 0x00000000000000000000000000000000);
        try expectEqual(0xFFFFFFFF00000000FFFFFFFF00000000 ^ 0x00000000FFFFFFFF00000000FFFFFFFF, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF);
        try expectEqual(0xFFFFFFFF00000000FFFFFFFF00000000 ^ 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF, 0x00000000FFFFFFFF00000000FFFFFFFF);
        try expectEqual(0x00000000FFFFFFFF00000000FFFFFFFF ^ 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF, 0xFFFFFFFF00000000FFFFFFFF00000000);
    }
}

test "f128" {
    try test_f128();
    comptime try test_f128();
}

fn make_f128(x: f128) f128 {
    return x;
}

fn test_f128() !void {
    try expectEqual(@sizeOf(f128), 16);
    try expectEqual(make_f128(1.0), 1.0);
    try expect(make_f128(1.0) != 1.1);
    try expect(make_f128(1.0) > 0.9);
    try expect(make_f128(1.0) >= 0.9);
    try expect(make_f128(1.0) >= 1.0);
    try should_not_be_zero(1.0);
}

fn should_not_be_zero(x: f128) !void {
    try expect(x != 0.0);
}

test "comptime float rem int" {
    comptime {
        var x = @as(f32, 1) % 2;
        try expectEqual(x, 1.0);
    }
}

test "remainder division" {
    comptime try remdiv(f16);
    comptime try remdiv(f32);
    comptime try remdiv(f64);
    comptime try remdiv(f128);
    try remdiv(f16);
    try remdiv(f64);
    try remdiv(f128);
}

fn remdiv(comptime T: type) !void {
    try expectEqual(@as(T, 1), @as(T, 1) % @as(T, 2));
    try expectEqual(@as(T, 1), @as(T, 7) % @as(T, 3));
}

test "@sqrt" {
    try testSqrt(f64, 12.0);
    comptime try testSqrt(f64, 12.0);
    try testSqrt(f32, 13.0);
    comptime try testSqrt(f32, 13.0);
    try testSqrt(f16, 13.0);
    comptime try testSqrt(f16, 13.0);

    const x = 14.0;
    const y = x * x;
    const z = @sqrt(y);
    comptime try expectEqual(z, x);
}

fn testSqrt(comptime T: type, x: T) !void {
    try expectEqual(@sqrt(x * x), x);
}

test "@fabs" {
    try testFabs(f128, 12.0);
    comptime try testFabs(f128, 12.0);
    try testFabs(f64, 12.0);
    comptime try testFabs(f64, 12.0);
    try testFabs(f32, 12.0);
    comptime try testFabs(f32, 12.0);
    try testFabs(f16, 12.0);
    comptime try testFabs(f16, 12.0);

    const x = 14.0;
    const y = -x;
    const z = @fabs(y);
    comptime try expectEqual(x, z);
}

fn testFabs(comptime T: type, x: T) !void {
    const y = -x;
    const z = @fabs(y);
    try expectEqual(x, z);
}

test "@floor" {
    // FIXME: Generates a floorl function call
    // testFloor(f128, 12.0);
    comptime try testFloor(f128, 12.0);
    try testFloor(f64, 12.0);
    comptime try testFloor(f64, 12.0);
    try testFloor(f32, 12.0);
    comptime try testFloor(f32, 12.0);
    try testFloor(f16, 12.0);
    comptime try testFloor(f16, 12.0);

    const x = 14.0;
    const y = x + 0.7;
    const z = @floor(y);
    comptime try expectEqual(x, z);
}

fn testFloor(comptime T: type, x: T) !void {
    const y = x + 0.6;
    const z = @floor(y);
    try expectEqual(x, z);
}

test "@ceil" {
    // FIXME: Generates a ceill function call
    //testCeil(f128, 12.0);
    comptime try testCeil(f128, 12.0);
    try testCeil(f64, 12.0);
    comptime try testCeil(f64, 12.0);
    try testCeil(f32, 12.0);
    comptime try testCeil(f32, 12.0);
    try testCeil(f16, 12.0);
    comptime try testCeil(f16, 12.0);

    const x = 14.0;
    const y = x - 0.7;
    const z = @ceil(y);
    comptime try expectEqual(x, z);
}

fn testCeil(comptime T: type, x: T) !void {
    const y = x - 0.8;
    const z = @ceil(y);
    try expectEqual(x, z);
}

test "@trunc" {
    // FIXME: Generates a truncl function call
    //testTrunc(f128, 12.0);
    comptime try testTrunc(f128, 12.0);
    try testTrunc(f64, 12.0);
    comptime try testTrunc(f64, 12.0);
    try testTrunc(f32, 12.0);
    comptime try testTrunc(f32, 12.0);
    try testTrunc(f16, 12.0);
    comptime try testTrunc(f16, 12.0);

    const x = 14.0;
    const y = x + 0.7;
    const z = @trunc(y);
    comptime try expectEqual(x, z);
}

fn testTrunc(comptime T: type, x: T) !void {
    {
        const y = x + 0.8;
        const z = @trunc(y);
        try expectEqual(x, z);
    }

    {
        const y = -x - 0.8;
        const z = @trunc(y);
        try expectEqual(-x, z);
    }
}

test "@round" {
    // FIXME: Generates a roundl function call
    //testRound(f128, 12.0);
    comptime try testRound(f128, 12.0);
    try testRound(f64, 12.0);
    comptime try testRound(f64, 12.0);
    try testRound(f32, 12.0);
    comptime try testRound(f32, 12.0);
    try testRound(f16, 12.0);
    comptime try testRound(f16, 12.0);

    const x = 14.0;
    const y = x + 0.4;
    const z = @round(y);
    comptime try expectEqual(x, z);
}

fn testRound(comptime T: type, x: T) !void {
    const y = x - 0.5;
    const z = @round(y);
    try expectEqual(x, z);
}

test "comptime_int param and return" {
    const a = comptimeAdd(35361831660712422535336160538497375248, 101752735581729509668353361206450473702);
    try expectEqual(a, 137114567242441932203689521744947848950);

    const b = comptimeAdd(594491908217841670578297176641415611445982232488944558774612, 390603545391089362063884922208143568023166603618446395589768);
    try expectEqual(b, 985095453608931032642182098849559179469148836107390954364380);
}

fn comptimeAdd(comptime a: comptime_int, comptime b: comptime_int) comptime_int {
    return a + b;
}

test "vector integer addition" {
    const S = struct {
        fn doTheTest() !void {
            var a: std.meta.Vector(4, i32) = [_]i32{ 1, 2, 3, 4 };
            var b: std.meta.Vector(4, i32) = [_]i32{ 5, 6, 7, 8 };
            var result = a + b;
            var result_array: [4]i32 = result;
            const expected = [_]i32{ 6, 8, 10, 12 };
            try expectEqualSlices(i32, &expected, &result_array);
        }
    };
    try S.doTheTest();
    comptime try S.doTheTest();
}

test "NaN comparison" {
    try testNanEqNan(f16);
    try testNanEqNan(f32);
    try testNanEqNan(f64);
    try testNanEqNan(f128);
    comptime try testNanEqNan(f16);
    comptime try testNanEqNan(f32);
    comptime try testNanEqNan(f64);
    comptime try testNanEqNan(f128);
}

fn testNanEqNan(comptime F: type) !void {
    var nan1 = std.math.nan(F);
    var nan2 = std.math.nan(F);
    try expect(nan1 != nan2);
    try expect(!(nan1 == nan2));
    try expect(!(nan1 > nan2));
    try expect(!(nan1 >= nan2));
    try expect(!(nan1 < nan2));
    try expect(!(nan1 <= nan2));
}

test "128-bit multiplication" {
    var a: i128 = 3;
    var b: i128 = 2;
    var c = a * b;
    try expectEqual(c, 6);
}

test "vector comparison" {
    const S = struct {
        fn doTheTest() !void {
            var a: std.meta.Vector(6, i32) = [_]i32{ 1, 3, -1, 5, 7, 9 };
            var b: std.meta.Vector(6, i32) = [_]i32{ -1, 3, 0, 6, 10, -10 };
            try expect(mem.eql(bool, &@as([6]bool, a < b), &[_]bool{ false, false, true, true, true, false }));
            try expect(mem.eql(bool, &@as([6]bool, a <= b), &[_]bool{ false, true, true, true, true, false }));
            try expect(mem.eql(bool, &@as([6]bool, a == b), &[_]bool{ false, true, false, false, false, false }));
            try expect(mem.eql(bool, &@as([6]bool, a != b), &[_]bool{ true, false, true, true, true, true }));
            try expect(mem.eql(bool, &@as([6]bool, a > b), &[_]bool{ true, false, false, false, false, true }));
            try expect(mem.eql(bool, &@as([6]bool, a >= b), &[_]bool{ true, true, false, false, false, true }));
        }
    };
    try S.doTheTest();
    comptime try S.doTheTest();
}

test "compare undefined literal with comptime_int" {
    var x = undefined == 1;
    // x is now undefined with type bool
    x = true;
    try expect(x);
}

test "signed zeros are represented properly" {
    const S = struct {
        fn doTheTest() !void {
            inline for ([_]type{ f16, f32, f64, f128 }) |T| {
                const ST = std.meta.Int(.unsigned, @typeInfo(T).Float.bits);
                var as_fp_val = -@as(T, 0.0);
                var as_uint_val = @bitCast(ST, as_fp_val);
                // Ensure the sign bit is set.
                try expectEqual(as_uint_val >> (@typeInfo(T).Float.bits - 1), 1);
            }
        }
    };

    try S.doTheTest();
    comptime try S.doTheTest();
}
