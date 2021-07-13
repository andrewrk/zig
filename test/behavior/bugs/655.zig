const std = @import("std");
const other_file = @import("655_other_file.zig");

test "function with *const parameter with type dereferenced by namespace" {
    const x: other_file.Integer = 1234;
    comptime try std.testing.expectEqual(@TypeOf(&x), *const other_file.Integer);
    try foo(&x);
}

fn foo(x: *const other_file.Integer) !void {
    try std.testing.expectEqual(x.*, 1234);
}
