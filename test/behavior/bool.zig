const expect = @import("std").testing.expect;
const expectEqual = @import("std").testing.expectEqual;

test "bool literals" {
    try expect(true);
    try expect(!false);
}

test "cast bool to int" {
    const t = true;
    const f = false;
    try expectEqual(@boolToInt(t), @as(u32, 1));
    try expectEqual(@boolToInt(f), @as(u32, 0));
    try nonConstCastBoolToInt(t, f);
}

fn nonConstCastBoolToInt(t: bool, f: bool) !void {
    try expectEqual(@boolToInt(t), @as(u32, 1));
    try expectEqual(@boolToInt(f), @as(u32, 0));
}

test "bool cmp" {
    try expectEqual(testBoolCmp(true, false), false);
}
fn testBoolCmp(a: bool, b: bool) bool {
    return a == b;
}

const global_f = false;
const global_t = true;
const not_global_f = !global_f;
const not_global_t = !global_t;
test "compile time bool not" {
    try expect(not_global_f);
    try expect(!not_global_t);
}
