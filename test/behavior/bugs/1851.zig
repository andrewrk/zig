const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "allocation and looping over 3-byte integer" {
    try expectEqual(@sizeOf(u24), 4);
    try expectEqual(@sizeOf([1]u24), 4);
    try expectEqual(@alignOf(u24), 4);
    try expectEqual(@alignOf([1]u24), 4);

    var x = try std.testing.allocator.alloc(u24, 2);
    defer std.testing.allocator.free(x);
    try expectEqual(x.len, 2);
    x[0] = 0xFFFFFF;
    x[1] = 0xFFFFFF;

    const bytes = std.mem.sliceAsBytes(x);
    try expectEqual(@TypeOf(bytes), []align(4) u8);
    try expectEqual(bytes.len, 8);

    for (bytes) |*b| {
        b.* = 0x00;
    }

    try expectEqual(x[0], 0x00);
    try expectEqual(x[1], 0x00);
}
