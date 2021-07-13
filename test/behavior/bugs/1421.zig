const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const S = struct {
    fn method() std.builtin.TypeInfo {
        return @typeInfo(S);
    }
};

test "functions with return type required to be comptime are generic" {
    const ti = S.method();
    try expectEqual(@as(std.builtin.TypeId, ti), std.builtin.TypeId.Struct);
}
