const std = @import("std");

const B = union(enum) {
    c: C,
    None,
};

const A = struct {
    b: B,
};

const C = struct {};

test "tagged union with all void fields but a meaningful tag" {
    var a: A = A{ .b = B{ .c = C{} } };
    try std.testing.expectEqual(@as(std.meta.Tag(B), a.b), std.meta.Tag(B).c);
    a = A{ .b = B.None };
    try std.testing.expectEqual(@as(std.meta.Tag(B), a.b), std.meta.Tag(B).None);
}
