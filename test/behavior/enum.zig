const expect = @import("std").testing.expect;
const expectEqual = @import("std").testing.expectEqual;
const mem = @import("std").mem;
const Tag = @import("std").meta.Tag;

test "non-exhaustive enum" {
    const S = struct {
        const E = enum(u8) {
            a,
            b,
            _,
        };
        fn doTheTest(y: u8) !void {
            var e: E = .b;
            try expect(switch (e) {
                .a => false,
                .b => true,
                _ => false,
            });
            e = @intToEnum(E, 12);
            try expect(switch (e) {
                .a => false,
                .b => false,
                _ => true,
            });

            try expect(switch (e) {
                .a => false,
                .b => false,
                else => true,
            });
            e = .b;
            try expect(switch (e) {
                .a => false,
                else => true,
            });

            try expectEqual(@typeInfo(E).Enum.fields.len, 2);
            e = @intToEnum(E, 12);
            try expectEqual(@enumToInt(e), 12);
            e = @intToEnum(E, y);
            try expectEqual(@enumToInt(e), 52);
            try expectEqual(@typeInfo(E).Enum.is_exhaustive, false);
        }
    };
    try S.doTheTest(52);
    comptime try S.doTheTest(52);
}

test "empty non-exhaustive enum" {
    const S = struct {
        const E = enum(u8) {
            _,
        };
        fn doTheTest(y: u8) !void {
            var e = @intToEnum(E, y);
            try expect(switch (e) {
                _ => true,
            });
            try expectEqual(@enumToInt(e), y);

            try expectEqual(@typeInfo(E).Enum.fields.len, 0);
            try expectEqual(@typeInfo(E).Enum.is_exhaustive, false);
        }
    };
    try S.doTheTest(42);
    comptime try S.doTheTest(42);
}

test "single field non-exhaustive enum" {
    const S = struct {
        const E = enum(u8) {
            a,
            _,
        };
        fn doTheTest(y: u8) !void {
            var e: E = .a;
            try expect(switch (e) {
                .a => true,
                _ => false,
            });
            e = @intToEnum(E, 12);
            try expect(switch (e) {
                .a => false,
                _ => true,
            });

            try expect(switch (e) {
                .a => false,
                else => true,
            });
            e = .a;
            try expect(switch (e) {
                .a => true,
                else => false,
            });

            try expectEqual(@enumToInt(@intToEnum(E, y)), y);
            try expectEqual(@typeInfo(E).Enum.fields.len, 1);
            try expectEqual(@typeInfo(E).Enum.is_exhaustive, false);
        }
    };
    try S.doTheTest(23);
    comptime try S.doTheTest(23);
}

test "enum type" {
    const foo1 = Foo{ .One = 13 };
    const foo2 = Foo{
        .Two = Point{
            .x = 1234,
            .y = 5678,
        },
    };
    try expectEqual(foo1.One, 13);
    try expectEqual(foo2.Two.x == 1234 and foo2.Two.y, 5678);
    const bar = Bar.B;

    try expectEqual(bar, Bar.B);
    try expectEqual(@typeInfo(Foo).Union.fields.len, 3);
    try expectEqual(@typeInfo(Bar).Enum.fields.len, 4);
    try expectEqual(@sizeOf(Foo), @sizeOf(FooNoVoid));
    try expectEqual(@sizeOf(Bar), 1);
}

test "enum as return value" {
    switch (returnAnInt(13)) {
        Foo.One => |value| try expectEqual(value, 13),
        else => unreachable,
    }
}

const Point = struct {
    x: u64,
    y: u64,
};
const Foo = union(enum) {
    One: i32,
    Two: Point,
    Three: void,
};
const FooNoVoid = union(enum) {
    One: i32,
    Two: Point,
};
const Bar = enum {
    A,
    B,
    C,
    D,
};

fn returnAnInt(x: i32) Foo {
    return Foo{ .One = x };
}

test "constant enum with payload" {
    var empty = AnEnumWithPayload{ .Empty = {} };
    var full = AnEnumWithPayload{ .Full = 13 };
    shouldBeEmpty(empty);
    shouldBeNotEmpty(full);
}

fn shouldBeEmpty(x: AnEnumWithPayload) void {
    switch (x) {
        AnEnumWithPayload.Empty => {},
        else => unreachable,
    }
}

fn shouldBeNotEmpty(x: AnEnumWithPayload) void {
    switch (x) {
        AnEnumWithPayload.Empty => unreachable,
        else => {},
    }
}

const AnEnumWithPayload = union(enum) {
    Empty: void,
    Full: i32,
};

const Number = enum {
    Zero,
    One,
    Two,
    Three,
    Four,
};

test "enum to int" {
    try shouldEqual(Number.Zero, 0);
    try shouldEqual(Number.One, 1);
    try shouldEqual(Number.Two, 2);
    try shouldEqual(Number.Three, 3);
    try shouldEqual(Number.Four, 4);
}

fn shouldEqual(n: Number, expected: u3) !void {
    try expectEqual(@enumToInt(n), expected);
}

test "int to enum" {
    try testIntToEnumEval(3);
}
fn testIntToEnumEval(x: i32) !void {
    try expectEqual(@intToEnum(IntToEnumNumber, @intCast(u3, x)), IntToEnumNumber.Three);
}
const IntToEnumNumber = enum {
    Zero,
    One,
    Two,
    Three,
    Four,
};

test "@tagName" {
    try expect(mem.eql(u8, testEnumTagNameBare(BareNumber.Three), "Three"));
    comptime try expect(mem.eql(u8, testEnumTagNameBare(BareNumber.Three), "Three"));
}

test "@tagName non-exhaustive enum" {
    try expect(mem.eql(u8, testEnumTagNameBare(NonExhaustive.B), "B"));
    comptime try expect(mem.eql(u8, testEnumTagNameBare(NonExhaustive.B), "B"));
}

fn testEnumTagNameBare(n: anytype) []const u8 {
    return @tagName(n);
}

const BareNumber = enum {
    One,
    Two,
    Three,
};

const NonExhaustive = enum(u8) {
    A,
    B,
    _,
};

test "enum alignment" {
    comptime {
        try expect(@alignOf(AlignTestEnum) >= @alignOf([9]u8));
        try expect(@alignOf(AlignTestEnum) >= @alignOf(u64));
    }
}

const AlignTestEnum = union(enum) {
    A: [9]u8,
    B: u64,
};

const ValueCount1 = enum {
    I0,
};
const ValueCount2 = enum {
    I0,
    I1,
};
const ValueCount256 = enum {
    I0,
    I1,
    I2,
    I3,
    I4,
    I5,
    I6,
    I7,
    I8,
    I9,
    I10,
    I11,
    I12,
    I13,
    I14,
    I15,
    I16,
    I17,
    I18,
    I19,
    I20,
    I21,
    I22,
    I23,
    I24,
    I25,
    I26,
    I27,
    I28,
    I29,
    I30,
    I31,
    I32,
    I33,
    I34,
    I35,
    I36,
    I37,
    I38,
    I39,
    I40,
    I41,
    I42,
    I43,
    I44,
    I45,
    I46,
    I47,
    I48,
    I49,
    I50,
    I51,
    I52,
    I53,
    I54,
    I55,
    I56,
    I57,
    I58,
    I59,
    I60,
    I61,
    I62,
    I63,
    I64,
    I65,
    I66,
    I67,
    I68,
    I69,
    I70,
    I71,
    I72,
    I73,
    I74,
    I75,
    I76,
    I77,
    I78,
    I79,
    I80,
    I81,
    I82,
    I83,
    I84,
    I85,
    I86,
    I87,
    I88,
    I89,
    I90,
    I91,
    I92,
    I93,
    I94,
    I95,
    I96,
    I97,
    I98,
    I99,
    I100,
    I101,
    I102,
    I103,
    I104,
    I105,
    I106,
    I107,
    I108,
    I109,
    I110,
    I111,
    I112,
    I113,
    I114,
    I115,
    I116,
    I117,
    I118,
    I119,
    I120,
    I121,
    I122,
    I123,
    I124,
    I125,
    I126,
    I127,
    I128,
    I129,
    I130,
    I131,
    I132,
    I133,
    I134,
    I135,
    I136,
    I137,
    I138,
    I139,
    I140,
    I141,
    I142,
    I143,
    I144,
    I145,
    I146,
    I147,
    I148,
    I149,
    I150,
    I151,
    I152,
    I153,
    I154,
    I155,
    I156,
    I157,
    I158,
    I159,
    I160,
    I161,
    I162,
    I163,
    I164,
    I165,
    I166,
    I167,
    I168,
    I169,
    I170,
    I171,
    I172,
    I173,
    I174,
    I175,
    I176,
    I177,
    I178,
    I179,
    I180,
    I181,
    I182,
    I183,
    I184,
    I185,
    I186,
    I187,
    I188,
    I189,
    I190,
    I191,
    I192,
    I193,
    I194,
    I195,
    I196,
    I197,
    I198,
    I199,
    I200,
    I201,
    I202,
    I203,
    I204,
    I205,
    I206,
    I207,
    I208,
    I209,
    I210,
    I211,
    I212,
    I213,
    I214,
    I215,
    I216,
    I217,
    I218,
    I219,
    I220,
    I221,
    I222,
    I223,
    I224,
    I225,
    I226,
    I227,
    I228,
    I229,
    I230,
    I231,
    I232,
    I233,
    I234,
    I235,
    I236,
    I237,
    I238,
    I239,
    I240,
    I241,
    I242,
    I243,
    I244,
    I245,
    I246,
    I247,
    I248,
    I249,
    I250,
    I251,
    I252,
    I253,
    I254,
    I255,
};
const ValueCount257 = enum {
    I0,
    I1,
    I2,
    I3,
    I4,
    I5,
    I6,
    I7,
    I8,
    I9,
    I10,
    I11,
    I12,
    I13,
    I14,
    I15,
    I16,
    I17,
    I18,
    I19,
    I20,
    I21,
    I22,
    I23,
    I24,
    I25,
    I26,
    I27,
    I28,
    I29,
    I30,
    I31,
    I32,
    I33,
    I34,
    I35,
    I36,
    I37,
    I38,
    I39,
    I40,
    I41,
    I42,
    I43,
    I44,
    I45,
    I46,
    I47,
    I48,
    I49,
    I50,
    I51,
    I52,
    I53,
    I54,
    I55,
    I56,
    I57,
    I58,
    I59,
    I60,
    I61,
    I62,
    I63,
    I64,
    I65,
    I66,
    I67,
    I68,
    I69,
    I70,
    I71,
    I72,
    I73,
    I74,
    I75,
    I76,
    I77,
    I78,
    I79,
    I80,
    I81,
    I82,
    I83,
    I84,
    I85,
    I86,
    I87,
    I88,
    I89,
    I90,
    I91,
    I92,
    I93,
    I94,
    I95,
    I96,
    I97,
    I98,
    I99,
    I100,
    I101,
    I102,
    I103,
    I104,
    I105,
    I106,
    I107,
    I108,
    I109,
    I110,
    I111,
    I112,
    I113,
    I114,
    I115,
    I116,
    I117,
    I118,
    I119,
    I120,
    I121,
    I122,
    I123,
    I124,
    I125,
    I126,
    I127,
    I128,
    I129,
    I130,
    I131,
    I132,
    I133,
    I134,
    I135,
    I136,
    I137,
    I138,
    I139,
    I140,
    I141,
    I142,
    I143,
    I144,
    I145,
    I146,
    I147,
    I148,
    I149,
    I150,
    I151,
    I152,
    I153,
    I154,
    I155,
    I156,
    I157,
    I158,
    I159,
    I160,
    I161,
    I162,
    I163,
    I164,
    I165,
    I166,
    I167,
    I168,
    I169,
    I170,
    I171,
    I172,
    I173,
    I174,
    I175,
    I176,
    I177,
    I178,
    I179,
    I180,
    I181,
    I182,
    I183,
    I184,
    I185,
    I186,
    I187,
    I188,
    I189,
    I190,
    I191,
    I192,
    I193,
    I194,
    I195,
    I196,
    I197,
    I198,
    I199,
    I200,
    I201,
    I202,
    I203,
    I204,
    I205,
    I206,
    I207,
    I208,
    I209,
    I210,
    I211,
    I212,
    I213,
    I214,
    I215,
    I216,
    I217,
    I218,
    I219,
    I220,
    I221,
    I222,
    I223,
    I224,
    I225,
    I226,
    I227,
    I228,
    I229,
    I230,
    I231,
    I232,
    I233,
    I234,
    I235,
    I236,
    I237,
    I238,
    I239,
    I240,
    I241,
    I242,
    I243,
    I244,
    I245,
    I246,
    I247,
    I248,
    I249,
    I250,
    I251,
    I252,
    I253,
    I254,
    I255,
    I256,
};

test "enum sizes" {
    comptime {
        try expectEqual(@sizeOf(ValueCount1), 0);
        try expectEqual(@sizeOf(ValueCount2), 1);
        try expectEqual(@sizeOf(ValueCount256), 1);
        try expectEqual(@sizeOf(ValueCount257), 2);
    }
}

const Small2 = enum(u2) {
    One,
    Two,
};
const Small = enum(u2) {
    One,
    Two,
    Three,
    Four,
};

test "set enum tag type" {
    {
        var x = Small.One;
        x = Small.Two;
        comptime try expectEqual(Tag(Small), u2);
    }
    {
        var x = Small2.One;
        x = Small2.Two;
        comptime try expectEqual(Tag(Small2), u2);
    }
}

const A = enum(u3) {
    One,
    Two,
    Three,
    Four,
    One2,
    Two2,
    Three2,
    Four2,
};

const B = enum(u3) {
    One3,
    Two3,
    Three3,
    Four3,
    One23,
    Two23,
    Three23,
    Four23,
};

const C = enum(u2) {
    One4,
    Two4,
    Three4,
    Four4,
};

const BitFieldOfEnums = packed struct {
    a: A,
    b: B,
    c: C,
};

const bit_field_1 = BitFieldOfEnums{
    .a = A.Two,
    .b = B.Three3,
    .c = C.Four4,
};

test "bit field access with enum fields" {
    var data = bit_field_1;
    try expectEqual(getA(&data), A.Two);
    try expectEqual(getB(&data), B.Three3);
    try expectEqual(getC(&data), C.Four4);
    comptime try expectEqual(@sizeOf(BitFieldOfEnums), 1);

    data.b = B.Four3;
    try expectEqual(data.b, B.Four3);

    data.a = A.Three;
    try expectEqual(data.a, A.Three);
    try expectEqual(data.b, B.Four3);
}

fn getA(data: *const BitFieldOfEnums) A {
    return data.a;
}

fn getB(data: *const BitFieldOfEnums) B {
    return data.b;
}

fn getC(data: *const BitFieldOfEnums) C {
    return data.c;
}

test "casting enum to its tag type" {
    try testCastEnumTag(Small2.Two);
    comptime try testCastEnumTag(Small2.Two);
}

fn testCastEnumTag(value: Small2) !void {
    try expectEqual(@enumToInt(value), 1);
}

const MultipleChoice = enum(u32) {
    A = 20,
    B = 40,
    C = 60,
    D = 1000,
};

test "enum with specified tag values" {
    try testEnumWithSpecifiedTagValues(MultipleChoice.C);
    comptime try testEnumWithSpecifiedTagValues(MultipleChoice.C);
}

fn testEnumWithSpecifiedTagValues(x: MultipleChoice) !void {
    try expectEqual(@enumToInt(x), 60);
    try expect(1234 == switch (x) {
        MultipleChoice.A => 1,
        MultipleChoice.B => 2,
        MultipleChoice.C => @as(u32, 1234),
        MultipleChoice.D => 4,
    });
}

const MultipleChoice2 = enum(u32) {
    Unspecified1,
    A = 20,
    Unspecified2,
    B = 40,
    Unspecified3,
    C = 60,
    Unspecified4,
    D = 1000,
    Unspecified5,
};

test "enum with specified and unspecified tag values" {
    try testEnumWithSpecifiedAndUnspecifiedTagValues(MultipleChoice2.D);
    comptime try testEnumWithSpecifiedAndUnspecifiedTagValues(MultipleChoice2.D);
}

fn testEnumWithSpecifiedAndUnspecifiedTagValues(x: MultipleChoice2) !void {
    try expectEqual(@enumToInt(x), 1000);
    try expect(1234 == switch (x) {
        MultipleChoice2.A => 1,
        MultipleChoice2.B => 2,
        MultipleChoice2.C => 3,
        MultipleChoice2.D => @as(u32, 1234),
        MultipleChoice2.Unspecified1 => 5,
        MultipleChoice2.Unspecified2 => 6,
        MultipleChoice2.Unspecified3 => 7,
        MultipleChoice2.Unspecified4 => 8,
        MultipleChoice2.Unspecified5 => 9,
    });
}

test "cast integer literal to enum" {
    try expectEqual(@intToEnum(MultipleChoice2, 0), MultipleChoice2.Unspecified1);
    try expectEqual(@intToEnum(MultipleChoice2, 40), MultipleChoice2.B);
}

const EnumWithOneMember = enum {
    Eof,
};

fn doALoopThing(id: EnumWithOneMember) void {
    while (true) {
        if (id == EnumWithOneMember.Eof) {
            break;
        }
        @compileError("above if condition should be comptime");
    }
}

test "comparison operator on enum with one member is comptime known" {
    doALoopThing(EnumWithOneMember.Eof);
}

const State = enum {
    Start,
};
test "switch on enum with one member is comptime known" {
    var state = State.Start;
    switch (state) {
        State.Start => return,
    }
    @compileError("analysis should not reach here");
}

const EnumWithTagValues = enum(u4) {
    A = 1 << 0,
    B = 1 << 1,
    C = 1 << 2,
    D = 1 << 3,
};
test "enum with tag values don't require parens" {
    try expectEqual(@enumToInt(EnumWithTagValues.C), 0b0100);
}

test "enum with 1 field but explicit tag type should still have the tag type" {
    const Enum = enum(u8) {
        B = 2,
    };
    comptime try expectEqual(@sizeOf(Enum), @sizeOf(u8));
}

test "tag name with assigned enum values" {
    const LocalFoo = enum(u8) {
        A = 1,
        B = 0,
    };
    var b = LocalFoo.B;
    try expect(mem.eql(u8, @tagName(b), "B"));
}

test "enum literal equality" {
    const x = .hi;
    const y = .ok;
    const z = .hi;

    try expect(x != y);
    try expectEqual(x, z);
}

test "enum literal cast to enum" {
    const Color = enum {
        Auto,
        Off,
        On,
    };

    var color1: Color = .Auto;
    var color2 = Color.Auto;
    try expectEqual(color1, color2);
}

test "peer type resolution with enum literal" {
    const Items = enum {
        one,
        two,
    };

    try expectEqual(Items.two, .two);
    try expect(.two == Items.two);
}

test "enum literal in array literal" {
    const Items = enum {
        one,
        two,
    };

    const array = [_]Items{
        .one,
        .two,
    };

    try expectEqual(array[0], .one);
    try expectEqual(array[1], .two);
}

test "signed integer as enum tag" {
    const SignedEnum = enum(i2) {
        A0 = -1,
        A1 = 0,
        A2 = 1,
    };

    try expectEqual(@enumToInt(SignedEnum.A0), -1);
    try expectEqual(@enumToInt(SignedEnum.A1), 0);
    try expectEqual(@enumToInt(SignedEnum.A2), 1);
}

test "enum value allocation" {
    const LargeEnum = enum(u32) {
        A0 = 0x80000000,
        A1,
        A2,
    };

    try expectEqual(@enumToInt(LargeEnum.A0), 0x80000000);
    try expectEqual(@enumToInt(LargeEnum.A1), 0x80000001);
    try expectEqual(@enumToInt(LargeEnum.A2), 0x80000002);
}

test "enum literal casting to tagged union" {
    const Arch = union(enum) {
        x86_64,
        arm: Arm32,

        const Arm32 = enum {
            v8_5a,
            v8_4a,
        };
    };

    var t = true;
    var x: Arch = .x86_64;
    var y = if (t) x else .x86_64;
    switch (y) {
        .x86_64 => {},
        else => @panic("fail"),
    }
}

test "enum with one member and custom tag type" {
    const E = enum(u2) {
        One,
    };
    try expectEqual(@enumToInt(E.One), 0);
    const E2 = enum(u2) {
        One = 2,
    };
    try expectEqual(@enumToInt(E2.One), 2);
}

test "enum literal casting to optional" {
    var bar: ?Bar = undefined;
    bar = .B;

    try expectEqual(bar.?, Bar.B);
}

test "enum literal casting to error union with payload enum" {
    var bar: error{B}!Bar = undefined;
    bar = .B; // should never cast to the error set

    try expectEqual((try bar), Bar.B);
}

test "enum with one member and u1 tag type @enumToInt" {
    const Enum = enum(u1) {
        Test,
    };
    try expectEqual(@enumToInt(Enum.Test), 0);
}

test "enum with comptime_int tag type" {
    const Enum = enum(comptime_int) {
        One = 3,
        Two = 2,
        Three = 1,
    };
    comptime try expectEqual(Tag(Enum), comptime_int);
}

test "enum with one member default to u0 tag type" {
    const E0 = enum {
        X,
    };
    comptime try expectEqual(Tag(E0), u0);
}

test "tagName on enum literals" {
    try expect(mem.eql(u8, @tagName(.FooBar), "FooBar"));
    comptime try expect(mem.eql(u8, @tagName(.FooBar), "FooBar"));
}

test "method call on an enum" {
    const S = struct {
        const E = enum {
            one,
            two,

            fn method(self: *E) bool {
                return self.* == .two;
            }

            fn generic_method(self: *E, foo: anytype) bool {
                return self.* == .two and foo == bool;
            }
        };
        fn doTheTest() !void {
            var e = E.two;
            try expect(e.method());
            try expect(e.generic_method(bool));
        }
    };
    try S.doTheTest();
    comptime try S.doTheTest();
}
