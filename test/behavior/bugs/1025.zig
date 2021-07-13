const A = struct {
    B: type,
};

fn getA() A {
    return A{ .B = u8 };
}

test "bug 1025" {
    const a = getA();
    try @import("std").testing.expectEqual(a.B, u8);
}
