const std = @import("std");

const TestEnum = enum { TestEnumValue };
const tag_name = @tagName(TestEnum.TestEnumValue);
const ptr_tag_name: [*:0]const u8 = tag_name;

test "@tagName() returns a string literal" {
    try std.testing.expectEqual([:0]const u8, @TypeOf(tag_name));
    try std.testing.expectEqualStrings("TestEnumValue", tag_name);
    try std.testing.expectEqualStrings("TestEnumValue", ptr_tag_name[0..tag_name.len]);
}

const TestError = error{TestErrorCode};
const error_name = @errorName(TestError.TestErrorCode);
const ptr_error_name: [*:0]const u8 = error_name;

test "@errorName() returns a string literal" {
    try std.testing.expectEqual([:0]const u8, @TypeOf(error_name));
    try std.testing.expectEqualStrings("TestErrorCode", error_name);
    try std.testing.expectEqualStrings("TestErrorCode", ptr_error_name[0..error_name.len]);
}

const TestType = struct {};
const type_name = @typeName(TestType);
const ptr_type_name: [*:0]const u8 = type_name;

test "@typeName() returns a string literal" {
    try std.testing.expectEqual(*const [type_name.len:0]u8, @TypeOf(type_name));
    try std.testing.expectEqualStrings("TestType", type_name);
    try std.testing.expectEqualStrings("TestType", ptr_type_name[0..type_name.len]);
}

const actual_contents = @embedFile("3779_file_to_embed.txt");
const ptr_actual_contents: [*:0]const u8 = actual_contents;
const expected_contents = "hello zig\n";

test "@embedFile() returns a string literal" {
    try std.testing.expectEqual(*const [expected_contents.len:0]u8, @TypeOf(actual_contents));
    try std.testing.expect(std.mem.eql(u8, expected_contents, actual_contents));
    try std.testing.expectEqualStrings(expected_contents, actual_contents);
    try std.testing.expectEqualStrings(expected_contents, ptr_actual_contents[0..actual_contents.len]);
}

fn testFnForSrc() std.builtin.SourceLocation {
    return @src();
}

test "@src() returns a struct containing 0-terminated string slices" {
    const src = testFnForSrc();
    try std.testing.expectEqual([:0]const u8, @TypeOf(src.file));
    try std.testing.expect(std.mem.endsWith(u8, src.file, "3779.zig"));
    try std.testing.expectEqual([:0]const u8, @TypeOf(src.fn_name));
    try std.testing.expect(std.mem.endsWith(u8, src.fn_name, "testFnForSrc"));

    const ptr_src_file: [*:0]const u8 = src.file;
    const ptr_src_fn_name: [*:0]const u8 = src.fn_name;
}
