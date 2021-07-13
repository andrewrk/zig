const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "memory size and grow" {
    var prev = @wasmMemorySize(0);
    try expectEqual(prev, @wasmMemoryGrow(0, 1));
    try expectEqual(prev + 1, @wasmMemorySize(0));
}
