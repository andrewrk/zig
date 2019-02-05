const std = @import("std");
const mem = std.mem;
const assertOrPanic = std.debug.assertOrPanic;

test "vector wrap operators" {
    const S = struct {
        fn doTheTest() void {
            const v: @Vector(4, i32) = [4]i32{ 10, 20, 30, 40 };
            const x: @Vector(4, i32) = [4]i32{ 1, 2, 3, 4 };
            assertOrPanic(mem.eql(i32, ([4]i32)(v +% x), [4]i32{ 11, 22, 33, 44 }));
            assertOrPanic(mem.eql(i32, ([4]i32)(v -% x), [4]i32{ 9, 18, 27, 36 }));
            assertOrPanic(mem.eql(i32, ([4]i32)(v *% x), [4]i32{ 10, 40, 90, 160 }));
        }
    };
    S.doTheTest();
    comptime S.doTheTest();
}
