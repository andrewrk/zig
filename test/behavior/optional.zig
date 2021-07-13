const std = @import("std");
const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;

pub const EmptyStruct = struct {};

test "optional pointer to size zero struct" {
    var e = EmptyStruct{};
    var o: ?*EmptyStruct = &e;
    try expect(o != null);
}

test "equality compare nullable pointers" {
    try testNullPtrsEql();
    comptime try testNullPtrsEql();
}

fn testNullPtrsEql() !void {
    var number: i32 = 1234;

    var x: ?*i32 = null;
    var y: ?*i32 = null;
    try expectEqual(x, y);
    y = &number;
    try expect(x != y);
    try expect(x != &number);
    try expect(&number != x);
    x = &number;
    try expectEqual(x, y);
    try expectEqual(x, &number);
    try expect(&number == x);
}

test "address of unwrap optional" {
    const S = struct {
        const Foo = struct {
            a: i32,
        };

        var global: ?Foo = null;

        pub fn getFoo() anyerror!*Foo {
            return &global.?;
        }
    };
    S.global = S.Foo{ .a = 1234 };
    const foo = S.getFoo() catch unreachable;
    try expectEqual(foo.a, 1234);
}

test "equality compare optional with non-optional" {
    try test_cmp_optional_non_optional();
    comptime try test_cmp_optional_non_optional();
}

fn test_cmp_optional_non_optional() !void {
    var ten: i32 = 10;
    var opt_ten: ?i32 = 10;
    var five: i32 = 5;
    var int_n: ?i32 = null;

    try expect(int_n != ten);
    try expectEqual(opt_ten, ten);
    try expect(opt_ten != five);

    // test evaluation is always lexical
    // ensure that the optional isn't always computed before the non-optional
    var mutable_state: i32 = 0;
    _ = blk1: {
        mutable_state += 1;
        break :blk1 @as(?f64, 10.0);
    } != blk2: {
        try expectEqual(mutable_state, 1);
        break :blk2 @as(f64, 5.0);
    };
    _ = blk1: {
        mutable_state += 1;
        break :blk1 @as(f64, 10.0);
    } != blk2: {
        try expectEqual(mutable_state, 2);
        break :blk2 @as(?f64, 5.0);
    };
}

test "passing an optional integer as a parameter" {
    const S = struct {
        fn entry() bool {
            var x: i32 = 1234;
            return foo(x);
        }

        fn foo(x: ?i32) bool {
            return x.? == 1234;
        }
    };
    try expect(S.entry());
    comptime try expect(S.entry());
}

test "unwrap function call with optional pointer return value" {
    const S = struct {
        fn entry() !void {
            try expectEqual(foo().?.*, 1234);
            try expectEqual(bar(), null);
        }
        const global: i32 = 1234;
        fn foo() ?*const i32 {
            return &global;
        }
        fn bar() ?*i32 {
            return null;
        }
    };
    try S.entry();
    comptime try S.entry();
}

test "nested orelse" {
    const S = struct {
        fn entry() !void {
            try expectEqual(func(), null);
        }
        fn maybe() ?Foo {
            return null;
        }
        fn func() ?Foo {
            const x = maybe() orelse
                maybe() orelse
                return null;
            _ = x;
            unreachable;
        }
        const Foo = struct {
            field: i32,
        };
    };
    try S.entry();
    comptime try S.entry();
}

test "self-referential struct through a slice of optional" {
    const S = struct {
        const Node = struct {
            children: []?Node,
            data: ?u8,

            fn new() Node {
                return Node{
                    .children = undefined,
                    .data = null,
                };
            }
        };
    };

    var n = S.Node.new();
    try expectEqual(n.data, null);
}

test "assigning to an unwrapped optional field in an inline loop" {
    comptime var maybe_pos_arg: ?comptime_int = null;
    inline for ("ab") |x| {
        _ = x;
        maybe_pos_arg = 0;
        if (maybe_pos_arg.? != 0) {
            @compileError("bad");
        }
        maybe_pos_arg.? = 10;
    }
}

test "coerce an anon struct literal to optional struct" {
    const S = struct {
        const Struct = struct {
            field: u32,
        };
        fn doTheTest() !void {
            var maybe_dims: ?Struct = null;
            maybe_dims = .{ .field = 1 };
            try expectEqual(maybe_dims.?.field, 1);
        }
    };
    try S.doTheTest();
    comptime try S.doTheTest();
}

test "optional with void type" {
    const Foo = struct {
        x: ?void,
    };
    var x = Foo{ .x = null };
    try expectEqual(x.x, null);
}

test "0-bit child type coerced to optional return ptr result location" {
    const S = struct {
        fn doTheTest() !void {
            var y = Foo{};
            var z = y.thing();
            try expect(z != null);
        }

        const Foo = struct {
            pub const Bar = struct {
                field: *Foo,
            };

            pub fn thing(self: *Foo) ?Bar {
                return Bar{ .field = self };
            }
        };
    };
    try S.doTheTest();
    comptime try S.doTheTest();
}

test "0-bit child type coerced to optional" {
    const S = struct {
        fn doTheTest() !void {
            var it: Foo = .{
                .list = undefined,
            };
            try expect(it.foo() != null);
        }

        const Empty = struct {};
        const Foo = struct {
            list: [10]Empty,

            fn foo(self: *Foo) ?*Empty {
                const data = &self.list[0];
                return data;
            }
        };
    };
    try S.doTheTest();
    comptime try S.doTheTest();
}

test "array of optional unaligned types" {
    const Enum = enum { one, two, three };

    const SomeUnion = union(enum) {
        Num: Enum,
        Other: u32,
    };

    const values = [_]?SomeUnion{
        SomeUnion{ .Num = .one },
        SomeUnion{ .Num = .two },
        SomeUnion{ .Num = .three },
        SomeUnion{ .Num = .one },
        SomeUnion{ .Num = .two },
        SomeUnion{ .Num = .three },
    };

    // The index must be a runtime value
    var i: usize = 0;
    try expectEqual(Enum.one, values[i].?.Num);
    i += 1;
    try expectEqual(Enum.two, values[i].?.Num);
    i += 1;
    try expectEqual(Enum.three, values[i].?.Num);
    i += 1;
    try expectEqual(Enum.one, values[i].?.Num);
    i += 1;
    try expectEqual(Enum.two, values[i].?.Num);
    i += 1;
    try expectEqual(Enum.three, values[i].?.Num);
}
