const expect = @import("std").testing.expect;
const expectEqual = @import("std").testing.expectEqual;

const module = @This();

fn Point(comptime T: type) type {
    return struct {
        const Self = @This();
        x: T,
        y: T,

        fn addOne(self: *Self) void {
            self.x += 1;
            self.y += 1;
        }
    };
}

fn add(x: i32, y: i32) i32 {
    return x + y;
}

test "this refer to module call private fn" {
    try expectEqual(module.add(1, 2), 3);
}

test "this refer to container" {
    var pt = Point(i32){
        .x = 12,
        .y = 34,
    };
    pt.addOne();
    try expectEqual(pt.x, 13);
    try expectEqual(pt.y, 35);
}
