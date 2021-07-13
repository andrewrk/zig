const std = @import("std");

test "fixed" {
    const x: f32 align(128) = 12.34;
    try std.testing.expectEqual(@ptrToInt(&x) % 128, 0);
}
