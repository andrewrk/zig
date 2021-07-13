const std = @import("std");

const source = "A-";

fn parseNote() ?i32 {
    const letter = source[0];
    const modifier = source[1];

    const semitone = blk: {
        if (letter == 'C' and modifier == '-') break :blk @as(i32, 0);
        if (letter == 'C' and modifier == '#') break :blk @as(i32, 1);
        if (letter == 'D' and modifier == '-') break :blk @as(i32, 2);
        if (letter == 'D' and modifier == '#') break :blk @as(i32, 3);
        if (letter == 'E' and modifier == '-') break :blk @as(i32, 4);
        if (letter == 'F' and modifier == '-') break :blk @as(i32, 5);
        if (letter == 'F' and modifier == '#') break :blk @as(i32, 6);
        if (letter == 'G' and modifier == '-') break :blk @as(i32, 7);
        if (letter == 'G' and modifier == '#') break :blk @as(i32, 8);
        if (letter == 'A' and modifier == '-') break :blk @as(i32, 9);
        if (letter == 'A' and modifier == '#') break :blk @as(i32, 10);
        if (letter == 'B' and modifier == '-') break :blk @as(i32, 11);
        return null;
    };

    return semitone;
}

test "fixed" {
    const result = parseNote();
    try std.testing.expectEqual(result.?, 9);
}
