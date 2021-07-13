const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const State = struct {
    const Self = @This();
    enter: fn (previous: ?Self) void,
};

fn prev(p: ?State) void {
    expectEqual(p, null) catch @panic("test failure");
}

test "zig test crash" {
    var global: State = undefined;
    global.enter = prev;
    global.enter(null);
}
