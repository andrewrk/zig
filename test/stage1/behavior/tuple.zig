const std = @import("std");
const expect = std.testing.expect;

test "tuple concatenation" {
    const S = struct {
        fn doTheTest() void {
            var a: i32 = 1;
            var b: i32 = 2;
            var x = .{a};
            var y = .{b};
            var c = x ++ y;
            expect(c[0] == 1);
            expect(c[1] == 2);
        }
    };
    S.doTheTest();
    comptime S.doTheTest();
}

test "tuple initialization with structure initializer and constant expression" {
    const TestStruct = struct {
        state: u8,
    };

    const tuple_with_struct = .{ TestStruct{ .state = 42 }, 0 };
    expect(tuple_with_struct.len == 2);
    expect(tuple_with_struct[0].state == 42);
    expect(tuple_with_struct[1] == 0);
}
