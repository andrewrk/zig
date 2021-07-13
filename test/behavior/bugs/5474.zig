const std = @import("std");

// baseline (control) struct with array of scalar
const Box0 = struct {
    items: [4]Item,

    const Item = struct {
        num: u32,
    };
};

// struct with array of empty struct
const Box1 = struct {
    items: [4]Item,

    const Item = struct {};
};

// struct with array of zero-size struct
const Box2 = struct {
    items: [4]Item,

    const Item = struct {
        nothing: void,
    };
};

fn doTest() !void {
    // var
    {
        var box0: Box0 = .{ .items = undefined };
        try std.testing.expectEqual(@typeInfo(@TypeOf(box0.items[0..])).Pointer.is_const, false);

        var box1: Box1 = .{ .items = undefined };
        try std.testing.expectEqual(@typeInfo(@TypeOf(box1.items[0..])).Pointer.is_const, false);

        var box2: Box2 = .{ .items = undefined };
        try std.testing.expectEqual(@typeInfo(@TypeOf(box2.items[0..])).Pointer.is_const, false);
    }

    // const
    {
        const box0: Box0 = .{ .items = undefined };
        try std.testing.expectEqual(@typeInfo(@TypeOf(box0.items[0..])).Pointer.is_const, true);

        const box1: Box1 = .{ .items = undefined };
        try std.testing.expectEqual(@typeInfo(@TypeOf(box1.items[0..])).Pointer.is_const, true);

        const box2: Box2 = .{ .items = undefined };
        try std.testing.expectEqual(@typeInfo(@TypeOf(box2.items[0..])).Pointer.is_const, true);
    }
}

test "pointer-to-array constness for zero-size elements" {
    try doTest();
    comptime try doTest();
}
