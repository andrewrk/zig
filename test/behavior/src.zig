const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "@src" {
    try doTheTest();
}

fn doTheTest() !void {
    const src = @src();

    try expectEqual(src.line, 9);
    try expectEqual(src.column, 17);
    try expect(std.mem.endsWith(u8, src.fn_name, "doTheTest"));
    try expect(std.mem.endsWith(u8, src.file, "src.zig"));
    try expectEqual(src.fn_name[src.fn_name.len], 0);
    try expectEqual(src.file[src.file.len], 0);
}
