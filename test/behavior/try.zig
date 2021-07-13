const expect = @import("std").testing.expect;
const expectEqual = @import("std").testing.expectEqual;

test "try on error union" {
    try tryOnErrorUnionImpl();
    comptime try tryOnErrorUnionImpl();
}

fn tryOnErrorUnionImpl() !void {
    const x = if (returnsTen()) |val| val + 1 else |err| switch (err) {
        error.ItBroke, error.NoMem => 1,
        error.CrappedOut => @as(i32, 2),
        else => unreachable,
    };
    try expectEqual(x, 11);
}

fn returnsTen() anyerror!i32 {
    return 10;
}

test "try without vars" {
    const result1 = if (failIfTrue(true)) 1 else |_| @as(i32, 2);
    try expectEqual(result1, 2);

    const result2 = if (failIfTrue(false)) 1 else |_| @as(i32, 2);
    try expectEqual(result2, 1);
}

fn failIfTrue(ok: bool) anyerror!void {
    if (ok) {
        return error.ItBroke;
    } else {
        return;
    }
}

test "try then not executed with assignment" {
    if (failIfTrue(true)) {
        unreachable;
    } else |err| {
        try expectEqual(err, error.ItBroke);
    }
}
