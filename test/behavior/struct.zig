const std = @import("std");
const builtin = @import("builtin");
const native_endian = builtin.target.cpu.arch.endian();
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const maxInt = std.math.maxInt;
const StructWithNoFields = struct {
    fn add(a: i32, b: i32) i32 {
        return a + b;
    }
};
const empty_global_instance = StructWithNoFields{};

top_level_field: i32,

test "top level fields" {
    var instance = @This(){
        .top_level_field = 1234,
    };
    instance.top_level_field += 1;
    try expectEqual(@as(i32, 1235), instance.top_level_field);
}

test "call struct static method" {
    const result = StructWithNoFields.add(3, 4);
    try expectEqual(result, 7);
}

test "return empty struct instance" {
    _ = returnEmptyStructInstance();
}
fn returnEmptyStructInstance() StructWithNoFields {
    return empty_global_instance;
}

const should_be_11 = StructWithNoFields.add(5, 6);

test "invoke static method in global scope" {
    try expectEqual(should_be_11, 11);
}

test "void struct fields" {
    const foo = VoidStructFieldsFoo{
        .a = void{},
        .b = 1,
        .c = void{},
    };
    try expectEqual(foo.b, 1);
    try expectEqual(@sizeOf(VoidStructFieldsFoo), 4);
}
const VoidStructFieldsFoo = struct {
    a: void,
    b: i32,
    c: void,
};

test "structs" {
    var foo: StructFoo = undefined;
    @memset(@ptrCast([*]u8, &foo), 0, @sizeOf(StructFoo));
    foo.a += 1;
    foo.b = foo.a == 1;
    try testFoo(foo);
    testMutation(&foo);
    try expectEqual(foo.c, 100);
}
const StructFoo = struct {
    a: i32,
    b: bool,
    c: f32,
};
fn testFoo(foo: StructFoo) !void {
    try expect(foo.b);
}
fn testMutation(foo: *StructFoo) void {
    foo.c = 100;
}

const Node = struct {
    val: Val,
    next: *Node,
};

const Val = struct {
    x: i32,
};

test "struct point to self" {
    var root: Node = undefined;
    root.val.x = 1;

    var node: Node = undefined;
    node.next = &root;
    node.val.x = 2;

    root.next = &node;

    try expectEqual(node.next.next.next.val.x, 1);
}

test "struct byval assign" {
    var foo1: StructFoo = undefined;
    var foo2: StructFoo = undefined;

    foo1.a = 1234;
    foo2.a = 0;
    try expectEqual(foo2.a, 0);
    foo2 = foo1;
    try expectEqual(foo2.a, 1234);
}

fn structInitializer() void {
    const val = Val{ .x = 42 };
    try expectEqual(val.x, 42);
}

test "fn call of struct field" {
    const Foo = struct {
        ptr: fn () i32,
    };
    const S = struct {
        fn aFunc() i32 {
            return 13;
        }

        fn callStructField(foo: Foo) i32 {
            return foo.ptr();
        }
    };

    try expectEqual(S.callStructField(Foo{ .ptr = S.aFunc }), 13);
}

test "store member function in variable" {
    const instance = MemberFnTestFoo{ .x = 1234 };
    const memberFn = MemberFnTestFoo.member;
    const result = memberFn(instance);
    try expectEqual(result, 1234);
}
const MemberFnTestFoo = struct {
    x: i32,
    fn member(foo: MemberFnTestFoo) i32 {
        return foo.x;
    }
};

test "call member function directly" {
    const instance = MemberFnTestFoo{ .x = 1234 };
    const result = MemberFnTestFoo.member(instance);
    try expectEqual(result, 1234);
}

test "member functions" {
    const r = MemberFnRand{ .seed = 1234 };
    try expectEqual(r.getSeed(), 1234);
}
const MemberFnRand = struct {
    seed: u32,
    pub fn getSeed(r: *const MemberFnRand) u32 {
        return r.seed;
    }
};

test "return struct byval from function" {
    const bar = makeBar(1234, 5678);
    try expectEqual(bar.y, 5678);
}
const Bar = struct {
    x: i32,
    y: i32,
};
fn makeBar(x: i32, y: i32) Bar {
    return Bar{
        .x = x,
        .y = y,
    };
}

test "empty struct method call" {
    const es = EmptyStruct{};
    try expectEqual(es.method(), 1234);
}
const EmptyStruct = struct {
    fn method(es: *const EmptyStruct) i32 {
        _ = es;
        return 1234;
    }
};

test "return empty struct from fn" {
    _ = testReturnEmptyStructFromFn();
}
const EmptyStruct2 = struct {};
fn testReturnEmptyStructFromFn() EmptyStruct2 {
    return EmptyStruct2{};
}

test "pass slice of empty struct to fn" {
    try expectEqual(testPassSliceOfEmptyStructToFn(&[_]EmptyStruct2{EmptyStruct2{}}), 1);
}
fn testPassSliceOfEmptyStructToFn(slice: []const EmptyStruct2) usize {
    return slice.len;
}

const APackedStruct = packed struct {
    x: u8,
    y: u8,
};

test "packed struct" {
    var foo = APackedStruct{
        .x = 1,
        .y = 2,
    };
    foo.y += 1;
    const four = foo.x + foo.y;
    try expectEqual(four, 4);
}

const BitField1 = packed struct {
    a: u3,
    b: u3,
    c: u2,
};

const bit_field_1 = BitField1{
    .a = 1,
    .b = 2,
    .c = 3,
};

test "bit field access" {
    var data = bit_field_1;
    try expectEqual(getA(&data), 1);
    try expectEqual(getB(&data), 2);
    try expectEqual(getC(&data), 3);
    comptime try expectEqual(@sizeOf(BitField1), 1);

    data.b += 1;
    try expectEqual(data.b, 3);

    data.a += 1;
    try expectEqual(data.a, 2);
    try expectEqual(data.b, 3);
}

fn getA(data: *const BitField1) u3 {
    return data.a;
}

fn getB(data: *const BitField1) u3 {
    return data.b;
}

fn getC(data: *const BitField1) u2 {
    return data.c;
}

const Foo24Bits = packed struct {
    field: u24,
};
const Foo96Bits = packed struct {
    a: u24,
    b: u24,
    c: u24,
    d: u24,
};

test "packed struct 24bits" {
    comptime {
        try expectEqual(@sizeOf(Foo24Bits), 4);
        if (@sizeOf(usize) == 4) {
            try expectEqual(@sizeOf(Foo96Bits), 12);
        } else {
            try expectEqual(@sizeOf(Foo96Bits), 16);
        }
    }

    var value = Foo96Bits{
        .a = 0,
        .b = 0,
        .c = 0,
        .d = 0,
    };
    value.a += 1;
    try expectEqual(value.a, 1);
    try expectEqual(value.b, 0);
    try expectEqual(value.c, 0);
    try expectEqual(value.d, 0);

    value.b += 1;
    try expectEqual(value.a, 1);
    try expectEqual(value.b, 1);
    try expectEqual(value.c, 0);
    try expectEqual(value.d, 0);

    value.c += 1;
    try expectEqual(value.a, 1);
    try expectEqual(value.b, 1);
    try expectEqual(value.c, 1);
    try expectEqual(value.d, 0);

    value.d += 1;
    try expectEqual(value.a, 1);
    try expectEqual(value.b, 1);
    try expectEqual(value.c, 1);
    try expectEqual(value.d, 1);
}

const Foo32Bits = packed struct {
    field: u24,
    pad: u8,
};

const FooArray24Bits = packed struct {
    a: u16,
    b: [2]Foo32Bits,
    c: u16,
};

// TODO revisit this test when doing https://github.com/ziglang/zig/issues/1512
test "packed array 24bits" {
    comptime {
        try expectEqual(@sizeOf([9]Foo32Bits), 9 * 4);
        try expectEqual(@sizeOf(FooArray24Bits), 2 + 2 * 4 + 2);
    }

    var bytes = [_]u8{0} ** (@sizeOf(FooArray24Bits) + 1);
    bytes[bytes.len - 1] = 0xaa;
    const ptr = &std.mem.bytesAsSlice(FooArray24Bits, bytes[0 .. bytes.len - 1])[0];
    try expectEqual(ptr.a, 0);
    try expectEqual(ptr.b[0].field, 0);
    try expectEqual(ptr.b[1].field, 0);
    try expectEqual(ptr.c, 0);

    ptr.a = maxInt(u16);
    try expectEqual(ptr.a, maxInt(u16));
    try expectEqual(ptr.b[0].field, 0);
    try expectEqual(ptr.b[1].field, 0);
    try expectEqual(ptr.c, 0);

    ptr.b[0].field = maxInt(u24);
    try expectEqual(ptr.a, maxInt(u16));
    try expectEqual(ptr.b[0].field, maxInt(u24));
    try expectEqual(ptr.b[1].field, 0);
    try expectEqual(ptr.c, 0);

    ptr.b[1].field = maxInt(u24);
    try expectEqual(ptr.a, maxInt(u16));
    try expectEqual(ptr.b[0].field, maxInt(u24));
    try expectEqual(ptr.b[1].field, maxInt(u24));
    try expectEqual(ptr.c, 0);

    ptr.c = maxInt(u16);
    try expectEqual(ptr.a, maxInt(u16));
    try expectEqual(ptr.b[0].field, maxInt(u24));
    try expectEqual(ptr.b[1].field, maxInt(u24));
    try expectEqual(ptr.c, maxInt(u16));

    try expectEqual(bytes[bytes.len - 1], 0xaa);
}

const FooStructAligned = packed struct {
    a: u8,
    b: u8,
};

const FooArrayOfAligned = packed struct {
    a: [2]FooStructAligned,
};

test "aligned array of packed struct" {
    comptime {
        try expectEqual(@sizeOf(FooStructAligned), 2);
        try expectEqual(@sizeOf(FooArrayOfAligned), 2 * 2);
    }

    var bytes = [_]u8{0xbb} ** @sizeOf(FooArrayOfAligned);
    const ptr = &std.mem.bytesAsSlice(FooArrayOfAligned, bytes[0..])[0];

    try expectEqual(ptr.a[0].a, 0xbb);
    try expectEqual(ptr.a[0].b, 0xbb);
    try expectEqual(ptr.a[1].a, 0xbb);
    try expectEqual(ptr.a[1].b, 0xbb);
}

test "runtime struct initialization of bitfield" {
    const s1 = Nibbles{
        .x = x1,
        .y = x1,
    };
    const s2 = Nibbles{
        .x = @intCast(u4, x2),
        .y = @intCast(u4, x2),
    };

    try expectEqual(s1.x, x1);
    try expectEqual(s1.y, x1);
    try expectEqual(s2.x, @intCast(u4, x2));
    try expectEqual(s2.y, @intCast(u4, x2));
}

var x1 = @as(u4, 1);
var x2 = @as(u8, 2);

const Nibbles = packed struct {
    x: u4,
    y: u4,
};

const Bitfields = packed struct {
    f1: u16,
    f2: u16,
    f3: u8,
    f4: u8,
    f5: u4,
    f6: u4,
    f7: u8,
};

test "native bit field understands endianness" {
    var all: u64 = if (native_endian != .Little)
        0x1111222233445677
    else
        0x7765443322221111;
    var bytes: [8]u8 = undefined;
    @memcpy(&bytes, @ptrCast([*]u8, &all), 8);
    var bitfields = @ptrCast(*Bitfields, &bytes).*;

    try expectEqual(bitfields.f1, 0x1111);
    try expectEqual(bitfields.f2, 0x2222);
    try expectEqual(bitfields.f3, 0x33);
    try expectEqual(bitfields.f4, 0x44);
    try expectEqual(bitfields.f5, 0x5);
    try expectEqual(bitfields.f6, 0x6);
    try expectEqual(bitfields.f7, 0x77);
}

test "align 1 field before self referential align 8 field as slice return type" {
    const result = alloc(Expr);
    try expectEqual(result.len, 0);
}

const Expr = union(enum) {
    Literal: u8,
    Question: *Expr,
};

fn alloc(comptime T: type) []T {
    return &[_]T{};
}

test "call method with mutable reference to struct with no fields" {
    const S = struct {
        fn doC(s: *const @This()) bool {
            _ = s;
            return true;
        }
        fn do(s: *@This()) bool {
            _ = s;
            return true;
        }
    };

    var s = S{};
    try expect(S.doC(&s));
    try expect(s.doC());
    try expect(S.do(&s));
    try expect(s.do());
}

test "implicit cast packed struct field to const ptr" {
    const LevelUpMove = packed struct {
        move_id: u9,
        level: u7,

        fn toInt(value: u7) u7 {
            return value;
        }
    };

    var lup: LevelUpMove = undefined;
    lup.level = 12;
    const res = LevelUpMove.toInt(lup.level);
    try expectEqual(res, 12);
}

test "pointer to packed struct member in a stack variable" {
    const S = packed struct {
        a: u2,
        b: u2,
    };

    var s = S{ .a = 2, .b = 0 };
    var b_ptr = &s.b;
    try expectEqual(s.b, 0);
    b_ptr.* = 2;
    try expectEqual(s.b, 2);
}

test "non-byte-aligned array inside packed struct" {
    const Foo = packed struct {
        a: bool,
        b: [0x16]u8,
    };
    const S = struct {
        fn bar(slice: []const u8) !void {
            try expectEqualSlices(u8, slice, "abcdefghijklmnopqurstu");
        }
        fn doTheTest() !void {
            var foo = Foo{
                .a = true,
                .b = "abcdefghijklmnopqurstu".*,
            };
            const value = foo.b;
            try bar(&value);
        }
    };
    try S.doTheTest();
    comptime try S.doTheTest();
}

test "packed struct with u0 field access" {
    const S = packed struct {
        f0: u0,
    };
    var s = S{ .f0 = 0 };
    comptime try expectEqual(s.f0, 0);
}

const S0 = struct {
    bar: S1,

    pub const S1 = struct {
        value: u8,
    };

    fn init() @This() {
        return S0{ .bar = S1{ .value = 123 } };
    }
};

var g_foo: S0 = S0.init();

test "access to global struct fields" {
    g_foo.bar.value = 42;
    try expectEqual(g_foo.bar.value, 42);
}

test "packed struct with fp fields" {
    const S = packed struct {
        data: [3]f32,

        pub fn frob(self: *@This()) void {
            self.data[0] += self.data[1] + self.data[2];
            self.data[1] += self.data[0] + self.data[2];
            self.data[2] += self.data[0] + self.data[1];
        }
    };

    var s: S = undefined;
    s.data[0] = 1.0;
    s.data[1] = 2.0;
    s.data[2] = 3.0;
    s.frob();
    try expectEqual(@as(f32, 6.0), s.data[0]);
    try expectEqual(@as(f32, 11.0), s.data[1]);
    try expectEqual(@as(f32, 20.0), s.data[2]);
}

test "use within struct scope" {
    const S = struct {
        usingnamespace struct {
            pub fn inner() i32 {
                return 42;
            }
        };
    };
    try expectEqual(@as(i32, 42), S.inner());
}

test "default struct initialization fields" {
    const S = struct {
        a: i32 = 1234,
        b: i32,
    };
    const x = S{
        .b = 5,
    };
    var five: i32 = 5;
    const y = S{
        .b = five,
    };
    if (x.a + x.b != 1239) {
        @compileError("it should be comptime known");
    }
    try expectEqual(y, x);
    try expectEqual(1239, x.a + x.b);
}

test "fn with C calling convention returns struct by value" {
    const S = struct {
        fn entry() !void {
            var x = makeBar(10);
            try expectEqual(@as(i32, 10), x.handle);
        }

        const ExternBar = extern struct {
            handle: i32,
        };

        fn makeBar(t: i32) callconv(.C) ExternBar {
            return ExternBar{
                .handle = t,
            };
        }
    };
    try S.entry();
    comptime try S.entry();
}

test "for loop over pointers to struct, getting field from struct pointer" {
    const S = struct {
        const Foo = struct {
            name: []const u8,
        };

        var ok = true;

        fn eql(a: []const u8) bool {
            _ = a;
            return true;
        }

        const ArrayList = struct {
            fn toSlice(self: *ArrayList) []*Foo {
                _ = self;
                return @as([*]*Foo, undefined)[0..0];
            }
        };

        fn doTheTest() !void {
            var objects: ArrayList = undefined;

            for (objects.toSlice()) |obj| {
                if (eql(obj.name)) {
                    ok = false;
                }
            }

            try expect(ok);
        }
    };
    try S.doTheTest();
}

test "zero-bit field in packed struct" {
    const S = packed struct {
        x: u10,
        y: void,
    };
    var x: S = undefined;
    _ = x;
}

test "struct field init with catch" {
    const S = struct {
        fn doTheTest() !void {
            var x: anyerror!isize = 1;
            var req = Foo{
                .field = x catch undefined,
            };
            try expectEqual(req.field, 1);
        }

        pub const Foo = extern struct {
            field: isize,
        };
    };
    try S.doTheTest();
    comptime try S.doTheTest();
}

test "packed struct with non-ABI-aligned field" {
    const S = packed struct {
        x: u9,
        y: u183,
    };
    var s: S = undefined;
    s.x = 1;
    s.y = 42;
    try expectEqual(s.x, 1);
    try expectEqual(s.y, 42);
}

test "non-packed struct with u128 entry in union" {
    const U = union(enum) {
        Num: u128,
        Void,
    };

    const S = struct {
        f1: U,
        f2: U,
    };

    var sx: S = undefined;
    var s = &sx;
    try std.testing.expectEqual(@ptrToInt(&s.f2) - @ptrToInt(&s.f1), @offsetOf(S, "f2"));
    var v2 = U{ .Num = 123 };
    s.f2 = v2;
    try std.testing.expectEqual(s.f2.Num, 123);
}

test "packed struct field passed to generic function" {
    const S = struct {
        const P = packed struct {
            b: u5,
            g: u5,
            r: u5,
            a: u1,
        };

        fn genericReadPackedField(ptr: anytype) u5 {
            return ptr.*;
        }
    };

    var p: S.P = undefined;
    p.b = 29;
    var loaded = S.genericReadPackedField(&p.b);
    try expectEqual(loaded, 29);
}

test "anonymous struct literal syntax" {
    const S = struct {
        const Point = struct {
            x: i32,
            y: i32,
        };

        fn doTheTest() !void {
            var p: Point = .{
                .x = 1,
                .y = 2,
            };
            try expectEqual(p.x, 1);
            try expectEqual(p.y, 2);
        }
    };
    try S.doTheTest();
    comptime try S.doTheTest();
}

test "fully anonymous struct" {
    const S = struct {
        fn doTheTest() !void {
            try dump(.{
                .int = @as(u32, 1234),
                .float = @as(f64, 12.34),
                .b = true,
                .s = "hi",
            });
        }
        fn dump(args: anytype) !void {
            try expectEqual(args.int, 1234);
            try expectEqual(args.float, 12.34);
            try expect(args.b);
            try expectEqual(args.s[0], 'h');
            try expectEqual(args.s[1], 'i');
        }
    };
    try S.doTheTest();
    comptime try S.doTheTest();
}

test "fully anonymous list literal" {
    const S = struct {
        fn doTheTest() !void {
            try dump(.{ @as(u32, 1234), @as(f64, 12.34), true, "hi" });
        }
        fn dump(args: anytype) !void {
            try expectEqual(args.@"0", 1234);
            try expectEqual(args.@"1", 12.34);
            try expect(args.@"2");
            try expectEqual(args.@"3"[0], 'h');
            try expectEqual(args.@"3"[1], 'i');
        }
    };
    try S.doTheTest();
    comptime try S.doTheTest();
}

test "anonymous struct literal assigned to variable" {
    var vec = .{ @as(i32, 22), @as(i32, 55), @as(i32, 99) };
    try expectEqual(vec.@"0", 22);
    try expectEqual(vec.@"1", 55);
    try expectEqual(vec.@"2", 99);
}

test "struct with var field" {
    const Point = struct {
        x: anytype,
        y: anytype,
    };
    const pt = Point{
        .x = 1,
        .y = 2,
    };
    try expectEqual(pt.x, 1);
    try expectEqual(pt.y, 2);
}

test "comptime struct field" {
    const T = struct {
        a: i32,
        comptime b: i32 = 1234,
    };

    var foo: T = undefined;
    comptime try expectEqual(foo.b, 1234);
}

test "anon struct literal field value initialized with fn call" {
    const S = struct {
        fn doTheTest() !void {
            var x = .{foo()};
            try expectEqualSlices(u8, x[0], "hi");
        }
        fn foo() []const u8 {
            return "hi";
        }
    };
    try S.doTheTest();
    comptime try S.doTheTest();
}

test "self-referencing struct via array member" {
    const T = struct {
        children: [1]*@This(),
    };
    var x: T = undefined;
    x = T{ .children = .{&x} };
    try expectEqual(x.children[0], &x);
}

test "struct with union field" {
    const Value = struct {
        ref: u32 = 2,
        kind: union(enum) {
            None: usize,
            Bool: bool,
        },
    };

    var True = Value{
        .kind = .{ .Bool = true },
    };
    try expectEqual(@as(u32, 2), True.ref);
    try expectEqual(true, True.kind.Bool);
}

test "type coercion of anon struct literal to struct" {
    const S = struct {
        const S2 = struct {
            A: u32,
            B: []const u8,
            C: void,
            D: Foo = .{},
        };

        const Foo = struct {
            field: i32 = 1234,
        };

        fn doTheTest() !void {
            var y: u32 = 42;
            const t0 = .{ .A = 123, .B = "foo", .C = {} };
            const t1 = .{ .A = y, .B = "foo", .C = {} };
            const y0: S2 = t0;
            var y1: S2 = t1;
            try expectEqual(y0.A, 123);
            try expect(std.mem.eql(u8, y0.B, "foo"));
            try expectEqual(y0.C, {});
            try expectEqual(y0.D.field, 1234);
            try expectEqual(y1.A, y);
            try expect(std.mem.eql(u8, y1.B, "foo"));
            try expectEqual(y1.C, {});
            try expectEqual(y1.D.field, 1234);
        }
    };
    try S.doTheTest();
    comptime try S.doTheTest();
}

test "type coercion of pointer to anon struct literal to pointer to struct" {
    const S = struct {
        const S2 = struct {
            A: u32,
            B: []const u8,
            C: void,
            D: Foo = .{},
        };

        const Foo = struct {
            field: i32 = 1234,
        };

        fn doTheTest() !void {
            var y: u32 = 42;
            const t0 = &.{ .A = 123, .B = "foo", .C = {} };
            const t1 = &.{ .A = y, .B = "foo", .C = {} };
            const y0: *const S2 = t0;
            var y1: *const S2 = t1;
            try expectEqual(y0.A, 123);
            try expect(std.mem.eql(u8, y0.B, "foo"));
            try expectEqual(y0.C, {});
            try expectEqual(y0.D.field, 1234);
            try expectEqual(y1.A, y);
            try expect(std.mem.eql(u8, y1.B, "foo"));
            try expectEqual(y1.C, {});
            try expectEqual(y1.D.field, 1234);
        }
    };
    try S.doTheTest();
    comptime try S.doTheTest();
}

test "packed struct with undefined initializers" {
    const S = struct {
        const P = packed struct {
            a: u3,
            _a: u3 = undefined,
            b: u3,
            _b: u3 = undefined,
            c: u3,
            _c: u3 = undefined,
        };

        fn doTheTest() !void {
            var p: P = undefined;
            p = P{ .a = 2, .b = 4, .c = 6 };
            // Make sure the compiler doesn't touch the unprefixed fields.
            // Use expect since i386-linux doesn't like expectEqual
            try expectEqual(p.a, 2);
            try expectEqual(p.b, 4);
            try expectEqual(p.c, 6);
        }
    };

    try S.doTheTest();
    comptime try S.doTheTest();
}
