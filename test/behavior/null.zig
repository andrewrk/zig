const expect = @import("std").testing.expect;
const expectEqual = @import("std").testing.expectEqual;

test "optional type" {
    const x: ?bool = true;

    if (x) |y| {
        if (y) {
            // OK
        } else {
            unreachable;
        }
    } else {
        unreachable;
    }

    const next_x: ?i32 = null;

    const z = next_x orelse 1234;

    try expectEqual(z, 1234);

    const final_x: ?i32 = 13;

    const num = final_x orelse unreachable;

    try expectEqual(num, 13);
}

test "test maybe object and get a pointer to the inner value" {
    var maybe_bool: ?bool = true;

    if (maybe_bool) |*b| {
        b.* = false;
    }

    try expectEqual(maybe_bool.?, false);
}

test "rhs maybe unwrap return" {
    const x: ?bool = true;
    const y = x orelse return;
    _ = y;
}

test "maybe return" {
    try maybeReturnImpl();
    comptime try maybeReturnImpl();
}

fn maybeReturnImpl() !void {
    try expect(foo(1235).?);
    if (foo(null) != null) unreachable;
    try expect(!foo(1234).?);
}

fn foo(x: ?i32) ?bool {
    const value = x orelse return null;
    return value > 1234;
}

test "if var maybe pointer" {
    try expect(shouldBeAPlus1(Particle{
        .a = 14,
        .b = 1,
        .c = 1,
        .d = 1,
    }) == 15);
}
fn shouldBeAPlus1(p: Particle) u64 {
    var maybe_particle: ?Particle = p;
    if (maybe_particle) |*particle| {
        particle.a += 1;
    }
    if (maybe_particle) |particle| {
        return particle.a;
    }
    return 0;
}
const Particle = struct {
    a: u64,
    b: u64,
    c: u64,
    d: u64,
};

test "null literal outside function" {
    const is_null = here_is_a_null_literal.context == null;
    try expect(is_null);

    const is_non_null = here_is_a_null_literal.context != null;
    try expect(!is_non_null);
}
const SillyStruct = struct {
    context: ?i32,
};
const here_is_a_null_literal = SillyStruct{ .context = null };

test "test null runtime" {
    try testTestNullRuntime(null);
}
fn testTestNullRuntime(x: ?i32) !void {
    try expectEqual(x, null);
    try expect(!(x != null));
}

test "optional void" {
    try optionalVoidImpl();
    comptime try optionalVoidImpl();
}

fn optionalVoidImpl() !void {
    try expectEqual(bar(null), null);
    try expect(bar({}) != null);
}

fn bar(x: ?void) ?void {
    if (x) |_| {
        return {};
    } else {
        return null;
    }
}

const StructWithOptional = struct {
    field: ?i32,
};

var struct_with_optional: StructWithOptional = undefined;

test "unwrap optional which is field of global var" {
    struct_with_optional.field = null;
    if (struct_with_optional.field) |payload| {
        _ = payload;
        unreachable;
    }
    struct_with_optional.field = 1234;
    if (struct_with_optional.field) |payload| {
        try expectEqual(payload, 1234);
    } else {
        unreachable;
    }
}

test "null with default unwrap" {
    const x: i32 = null orelse 1;
    try expectEqual(x, 1);
}

test "optional types" {
    comptime {
        const opt_type_struct = StructWithOptionalType{ .t = u8 };
        try expectEqual(opt_type_struct.t != null and opt_type_struct.t.?, u8);
    }
}

const StructWithOptionalType = struct {
    t: ?type,
};

test "optional pointer to 0 bit type null value at runtime" {
    const EmptyStruct = struct {};
    var x: ?*EmptyStruct = null;
    try expectEqual(x, null);
}
