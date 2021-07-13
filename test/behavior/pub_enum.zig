const other = @import("pub_enum/other.zig");
const expect = @import("std").testing.expect;
const expectEqual = @import("std").testing.expectEqual;

test "pub enum" {
    try pubEnumTest(other.APubEnum.Two);
}
fn pubEnumTest(foo: other.APubEnum) !void {
    try expectEqual(foo, other.APubEnum.Two);
}

test "cast with imported symbol" {
    try expectEqual(@as(other.size_t, 42), 42);
}
