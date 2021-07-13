const expect = @import("std").testing.expect;
const expectEqual = @import("std").testing.expectEqual;
const a_namespace = @import("import/a_namespace.zig");

test "call fn via namespace lookup" {
    try expectEqual(@as(i32, 1234), a_namespace.foo());
}

test "importing the same thing gives the same import" {
    try expectEqual(@import("std"), @import("std"));
}

test "import in non-toplevel scope" {
    const S = struct {
        usingnamespace @import("import/a_namespace.zig");
    };
    try expectEqual(@as(i32, 1234), S.foo());
}

test "import empty file" {
    _ = @import("import/empty.zig");
}
