const std = @import("std");
const builtin = @import("builtin");
const TypeInfo = std.builtin.TypeInfo;
const testing = std.testing;

fn testTypes(comptime types: []const type) !void {
    inline for (types) |testType| {
        try testing.expectEqual(testType, @Type(@typeInfo(testType)));
    }
}

test "Type.MetaType" {
    try testing.expectEqual(type, @Type(TypeInfo{ .Type = undefined }));
    try testTypes(&[_]type{type});
}

test "Type.Void" {
    try testing.expectEqual(void, @Type(TypeInfo{ .Void = undefined }));
    try testTypes(&[_]type{void});
}

test "Type.Bool" {
    try testing.expectEqual(bool, @Type(TypeInfo{ .Bool = undefined }));
    try testTypes(&[_]type{bool});
}

test "Type.NoReturn" {
    try testing.expectEqual(noreturn, @Type(TypeInfo{ .NoReturn = undefined }));
    try testTypes(&[_]type{noreturn});
}

test "Type.Int" {
    try testing.expectEqual(u1, @Type(TypeInfo{ .Int = TypeInfo.Int{ .signedness = .unsigned, .bits = 1 } }));
    try testing.expectEqual(i1, @Type(TypeInfo{ .Int = TypeInfo.Int{ .signedness = .signed, .bits = 1 } }));
    try testing.expectEqual(u8, @Type(TypeInfo{ .Int = TypeInfo.Int{ .signedness = .unsigned, .bits = 8 } }));
    try testing.expectEqual(i8, @Type(TypeInfo{ .Int = TypeInfo.Int{ .signedness = .signed, .bits = 8 } }));
    try testing.expectEqual(u64, @Type(TypeInfo{ .Int = TypeInfo.Int{ .signedness = .unsigned, .bits = 64 } }));
    try testing.expectEqual(i64, @Type(TypeInfo{ .Int = TypeInfo.Int{ .signedness = .signed, .bits = 64 } }));
    try testTypes(&[_]type{ u8, u32, i64 });
}

test "Type.Float" {
    try testing.expectEqual(f16, @Type(TypeInfo{ .Float = TypeInfo.Float{ .bits = 16 } }));
    try testing.expectEqual(f32, @Type(TypeInfo{ .Float = TypeInfo.Float{ .bits = 32 } }));
    try testing.expectEqual(f64, @Type(TypeInfo{ .Float = TypeInfo.Float{ .bits = 64 } }));
    try testing.expectEqual(f128, @Type(TypeInfo{ .Float = TypeInfo.Float{ .bits = 128 } }));
    try testTypes(&[_]type{ f16, f32, f64, f128 });
}

test "Type.Pointer" {
    try testTypes(&[_]type{
        // One Value Pointer Types
        *u8,                               *const u8,
        *volatile u8,                      *const volatile u8,
        *align(4) u8,                      *align(4) const u8,
        *align(4) volatile u8,             *align(4) const volatile u8,
        *align(8) u8,                      *align(8) const u8,
        *align(8) volatile u8,             *align(8) const volatile u8,
        *allowzero u8,                     *allowzero const u8,
        *allowzero volatile u8,            *allowzero const volatile u8,
        *allowzero align(4) u8,            *allowzero align(4) const u8,
        *allowzero align(4) volatile u8,   *allowzero align(4) const volatile u8,
        // Many Values Pointer Types
        [*]u8,                             [*]const u8,
        [*]volatile u8,                    [*]const volatile u8,
        [*]align(4) u8,                    [*]align(4) const u8,
        [*]align(4) volatile u8,           [*]align(4) const volatile u8,
        [*]align(8) u8,                    [*]align(8) const u8,
        [*]align(8) volatile u8,           [*]align(8) const volatile u8,
        [*]allowzero u8,                   [*]allowzero const u8,
        [*]allowzero volatile u8,          [*]allowzero const volatile u8,
        [*]allowzero align(4) u8,          [*]allowzero align(4) const u8,
        [*]allowzero align(4) volatile u8, [*]allowzero align(4) const volatile u8,
        // Slice Types
        []u8,                              []const u8,
        []volatile u8,                     []const volatile u8,
        []align(4) u8,                     []align(4) const u8,
        []align(4) volatile u8,            []align(4) const volatile u8,
        []align(8) u8,                     []align(8) const u8,
        []align(8) volatile u8,            []align(8) const volatile u8,
        []allowzero u8,                    []allowzero const u8,
        []allowzero volatile u8,           []allowzero const volatile u8,
        []allowzero align(4) u8,           []allowzero align(4) const u8,
        []allowzero align(4) volatile u8,  []allowzero align(4) const volatile u8,
        // C Pointer Types
        [*c]u8,                            [*c]const u8,
        [*c]volatile u8,                   [*c]const volatile u8,
        [*c]align(4) u8,                   [*c]align(4) const u8,
        [*c]align(4) volatile u8,          [*c]align(4) const volatile u8,
        [*c]align(8) u8,                   [*c]align(8) const u8,
        [*c]align(8) volatile u8,          [*c]align(8) const volatile u8,
    });
}

test "Type.Array" {
    try testing.expect([123]u8 == @Type(TypeInfo{
        .Array = TypeInfo.Array{
            .len = 123,
            .child = u8,
            .sentinel = null,
        },
    }));
    try testing.expect([2]u32 == @Type(TypeInfo{
        .Array = TypeInfo.Array{
            .len = 2,
            .child = u32,
            .sentinel = null,
        },
    }));
    try testing.expect([2:0]u32 == @Type(TypeInfo{
        .Array = TypeInfo.Array{
            .len = 2,
            .child = u32,
            .sentinel = 0,
        },
    }));
    try testTypes(&[_]type{ [1]u8, [30]usize, [7]bool });
}

test "Type.ComptimeFloat" {
    try testTypes(&[_]type{comptime_float});
}
test "Type.ComptimeInt" {
    try testTypes(&[_]type{comptime_int});
}
test "Type.Undefined" {
    try testTypes(&[_]type{@TypeOf(undefined)});
}
test "Type.Null" {
    try testTypes(&[_]type{@TypeOf(null)});
}
test "@Type create slice with null sentinel" {
    const Slice = @Type(TypeInfo{
        .Pointer = .{
            .size = .Slice,
            .is_const = true,
            .is_volatile = false,
            .is_allowzero = false,
            .alignment = 8,
            .child = *i32,
            .sentinel = null,
        },
    });
    try testing.expectEqual(Slice, []align(8) const *i32);
}
test "@Type picks up the sentinel value from TypeInfo" {
    try testTypes(&[_]type{
        [11:0]u8,                            [4:10]u8,
        [*:0]u8,                             [*:0]const u8,
        [*:0]volatile u8,                    [*:0]const volatile u8,
        [*:0]align(4) u8,                    [*:0]align(4) const u8,
        [*:0]align(4) volatile u8,           [*:0]align(4) const volatile u8,
        [*:0]align(8) u8,                    [*:0]align(8) const u8,
        [*:0]align(8) volatile u8,           [*:0]align(8) const volatile u8,
        [*:0]allowzero u8,                   [*:0]allowzero const u8,
        [*:0]allowzero volatile u8,          [*:0]allowzero const volatile u8,
        [*:0]allowzero align(4) u8,          [*:0]allowzero align(4) const u8,
        [*:0]allowzero align(4) volatile u8, [*:0]allowzero align(4) const volatile u8,
        [*:5]allowzero align(4) volatile u8, [*:5]allowzero align(4) const volatile u8,
        [:0]u8,                              [:0]const u8,
        [:0]volatile u8,                     [:0]const volatile u8,
        [:0]align(4) u8,                     [:0]align(4) const u8,
        [:0]align(4) volatile u8,            [:0]align(4) const volatile u8,
        [:0]align(8) u8,                     [:0]align(8) const u8,
        [:0]align(8) volatile u8,            [:0]align(8) const volatile u8,
        [:0]allowzero u8,                    [:0]allowzero const u8,
        [:0]allowzero volatile u8,           [:0]allowzero const volatile u8,
        [:0]allowzero align(4) u8,           [:0]allowzero align(4) const u8,
        [:0]allowzero align(4) volatile u8,  [:0]allowzero align(4) const volatile u8,
        [:4]allowzero align(4) volatile u8,  [:4]allowzero align(4) const volatile u8,
    });
}

test "Type.Optional" {
    try testTypes(&[_]type{
        ?u8,
        ?*u8,
        ?[]u8,
        ?[*]u8,
        ?[*c]u8,
    });
}

test "Type.ErrorUnion" {
    try testTypes(&[_]type{
        error{}!void,
        error{Error}!void,
    });
}

test "Type.Opaque" {
    const Opaque = @Type(.{
        .Opaque = .{
            .decls = &[_]TypeInfo.Declaration{},
        },
    });
    try testing.expect(Opaque != opaque {});
    try testing.expectEqualSlices(
        TypeInfo.Declaration,
        &[_]TypeInfo.Declaration{},
        @typeInfo(Opaque).Opaque.decls,
    );
}

test "Type.Vector" {
    try testTypes(&[_]type{
        @Vector(0, u8),
        @Vector(4, u8),
        @Vector(8, *u8),
        std.meta.Vector(0, u8),
        std.meta.Vector(4, u8),
        std.meta.Vector(8, *u8),
    });
}

test "Type.AnyFrame" {
    try testTypes(&[_]type{
        anyframe,
        anyframe->u8,
        anyframe->anyframe->u8,
    });
}

test "Type.EnumLiteral" {
    try testTypes(&[_]type{
        @TypeOf(.Dummy),
    });
}

fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "Type.Frame" {
    try testTypes(&[_]type{
        @Frame(add),
    });
}

test "Type.ErrorSet" {
    // error sets don't compare equal so just check if they compile
    _ = @Type(@typeInfo(error{}));
    _ = @Type(@typeInfo(error{A}));
    _ = @Type(@typeInfo(error{ A, B, C }));
}

test "Type.Struct" {
    const A = @Type(@typeInfo(struct { x: u8, y: u32 }));
    const infoA = @typeInfo(A).Struct;
    try testing.expectEqual(TypeInfo.ContainerLayout.Auto, infoA.layout);
    try testing.expectEqualSlices(u8, "x", infoA.fields[0].name);
    try testing.expectEqual(u8, infoA.fields[0].field_type);
    try testing.expectEqual(@as(?u8, null), infoA.fields[0].default_value);
    try testing.expectEqualSlices(u8, "y", infoA.fields[1].name);
    try testing.expectEqual(u32, infoA.fields[1].field_type);
    try testing.expectEqual(@as(?u32, null), infoA.fields[1].default_value);
    try testing.expectEqualSlices(TypeInfo.Declaration, &[_]TypeInfo.Declaration{}, infoA.decls);
    try testing.expectEqual(@as(bool, false), infoA.is_tuple);

    var a = A{ .x = 0, .y = 1 };
    try testing.expectEqual(@as(u8, 0), a.x);
    try testing.expectEqual(@as(u32, 1), a.y);
    a.y += 1;
    try testing.expectEqual(@as(u32, 2), a.y);

    const B = @Type(@typeInfo(extern struct { x: u8, y: u32 = 5 }));
    const infoB = @typeInfo(B).Struct;
    try testing.expectEqual(TypeInfo.ContainerLayout.Extern, infoB.layout);
    try testing.expectEqualSlices(u8, "x", infoB.fields[0].name);
    try testing.expectEqual(u8, infoB.fields[0].field_type);
    try testing.expectEqual(@as(?u8, null), infoB.fields[0].default_value);
    try testing.expectEqualSlices(u8, "y", infoB.fields[1].name);
    try testing.expectEqual(u32, infoB.fields[1].field_type);
    try testing.expectEqual(@as(?u32, 5), infoB.fields[1].default_value);
    try testing.expectEqual(@as(usize, 0), infoB.decls.len);
    try testing.expectEqual(@as(bool, false), infoB.is_tuple);

    const C = @Type(@typeInfo(packed struct { x: u8 = 3, y: u32 = 5 }));
    const infoC = @typeInfo(C).Struct;
    try testing.expectEqual(TypeInfo.ContainerLayout.Packed, infoC.layout);
    try testing.expectEqualSlices(u8, "x", infoC.fields[0].name);
    try testing.expectEqual(u8, infoC.fields[0].field_type);
    try testing.expectEqual(@as(?u8, 3), infoC.fields[0].default_value);
    try testing.expectEqualSlices(u8, "y", infoC.fields[1].name);
    try testing.expectEqual(u32, infoC.fields[1].field_type);
    try testing.expectEqual(@as(?u32, 5), infoC.fields[1].default_value);
    try testing.expectEqual(@as(usize, 0), infoC.decls.len);
    try testing.expectEqual(@as(bool, false), infoC.is_tuple);
}

test "Type.Enum" {
    const Foo = @Type(.{
        .Enum = .{
            .layout = .Auto,
            .tag_type = u8,
            .fields = &[_]TypeInfo.EnumField{
                .{ .name = "a", .value = 1 },
                .{ .name = "b", .value = 5 },
            },
            .decls = &[_]TypeInfo.Declaration{},
            .is_exhaustive = true,
        },
    });
    try testing.expectEqual(true, @typeInfo(Foo).Enum.is_exhaustive);
    try testing.expectEqual(@as(u8, 1), @enumToInt(Foo.a));
    try testing.expectEqual(@as(u8, 5), @enumToInt(Foo.b));
    const Bar = @Type(.{
        .Enum = .{
            .layout = .Extern,
            .tag_type = u32,
            .fields = &[_]TypeInfo.EnumField{
                .{ .name = "a", .value = 1 },
                .{ .name = "b", .value = 5 },
            },
            .decls = &[_]TypeInfo.Declaration{},
            .is_exhaustive = false,
        },
    });
    try testing.expectEqual(false, @typeInfo(Bar).Enum.is_exhaustive);
    try testing.expectEqual(@as(u32, 1), @enumToInt(Bar.a));
    try testing.expectEqual(@as(u32, 5), @enumToInt(Bar.b));
    try testing.expectEqual(@as(u32, 6), @enumToInt(@intToEnum(Bar, 6)));
}

test "Type.Union" {
    const Untagged = @Type(.{
        .Union = .{
            .layout = .Auto,
            .tag_type = null,
            .fields = &[_]TypeInfo.UnionField{
                .{ .name = "int", .field_type = i32, .alignment = @alignOf(f32) },
                .{ .name = "float", .field_type = f32, .alignment = @alignOf(f32) },
            },
            .decls = &[_]TypeInfo.Declaration{},
        },
    });
    var untagged = Untagged{ .int = 1 };
    untagged.float = 2.0;
    untagged.int = 3;
    try testing.expectEqual(@as(i32, 3), untagged.int);

    const PackedUntagged = @Type(.{
        .Union = .{
            .layout = .Packed,
            .tag_type = null,
            .fields = &[_]TypeInfo.UnionField{
                .{ .name = "signed", .field_type = i32, .alignment = @alignOf(i32) },
                .{ .name = "unsigned", .field_type = u32, .alignment = @alignOf(u32) },
            },
            .decls = &[_]TypeInfo.Declaration{},
        },
    });
    var packed_untagged = PackedUntagged{ .signed = -1 };
    try testing.expectEqual(@as(i32, -1), packed_untagged.signed);
    try testing.expectEqual(~@as(u32, 0), packed_untagged.unsigned);

    const Tag = @Type(.{
        .Enum = .{
            .layout = .Auto,
            .tag_type = u1,
            .fields = &[_]TypeInfo.EnumField{
                .{ .name = "signed", .value = 0 },
                .{ .name = "unsigned", .value = 1 },
            },
            .decls = &[_]TypeInfo.Declaration{},
            .is_exhaustive = true,
        },
    });
    const Tagged = @Type(.{
        .Union = .{
            .layout = .Auto,
            .tag_type = Tag,
            .fields = &[_]TypeInfo.UnionField{
                .{ .name = "signed", .field_type = i32, .alignment = @alignOf(i32) },
                .{ .name = "unsigned", .field_type = u32, .alignment = @alignOf(u32) },
            },
            .decls = &[_]TypeInfo.Declaration{},
        },
    });
    var tagged = Tagged{ .signed = -1 };
    try testing.expectEqual(Tag.signed, tagged);
    tagged = .{ .unsigned = 1 };
    try testing.expectEqual(Tag.unsigned, tagged);
}

test "Type.Union from Type.Enum" {
    const Tag = @Type(.{
        .Enum = .{
            .layout = .Auto,
            .tag_type = u0,
            .fields = &[_]TypeInfo.EnumField{
                .{ .name = "working_as_expected", .value = 0 },
            },
            .decls = &[_]TypeInfo.Declaration{},
            .is_exhaustive = true,
        },
    });
    const T = @Type(.{
        .Union = .{
            .layout = .Auto,
            .tag_type = Tag,
            .fields = &[_]TypeInfo.UnionField{
                .{ .name = "working_as_expected", .field_type = u32, .alignment = @alignOf(u32) },
            },
            .decls = &[_]TypeInfo.Declaration{},
        },
    });
    _ = T;
    _ = @typeInfo(T).Union;
}

test "Type.Union from regular enum" {
    const E = enum { working_as_expected };
    const T = @Type(.{
        .Union = .{
            .layout = .Auto,
            .tag_type = E,
            .fields = &[_]TypeInfo.UnionField{
                .{ .name = "working_as_expected", .field_type = u32, .alignment = @alignOf(u32) },
            },
            .decls = &[_]TypeInfo.Declaration{},
        },
    });
    _ = T;
    _ = @typeInfo(T).Union;
}

test "Type.Fn" {
    // wasm doesn't support align attributes on functions
    if (builtin.target.cpu.arch == .wasm32 or builtin.target.cpu.arch == .wasm64) return error.SkipZigTest;

    const foo = struct {
        fn func(a: usize, b: bool) align(4) callconv(.C) usize {
            _ = a;
            _ = b;
            return 0;
        }
    }.func;
    const Foo = @Type(@typeInfo(@TypeOf(foo)));
    const foo_2: Foo = foo;
    _ = foo_2;
}

test "Type.BoundFn" {
    // wasm doesn't support align attributes on functions
    if (builtin.target.cpu.arch == .wasm32 or builtin.target.cpu.arch == .wasm64) return error.SkipZigTest;

    const TestStruct = packed struct {
        pub fn foo(self: *const @This()) align(4) callconv(.Unspecified) void {
            _ = self;
        }
    };
    const test_instance: TestStruct = undefined;
    try testing.expect(std.meta.eql(
        @typeName(@TypeOf(test_instance.foo)),
        @typeName(@Type(@typeInfo(@TypeOf(test_instance.foo)))),
    ));
}
