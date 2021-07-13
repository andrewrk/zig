const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

pub fn List(comptime T: type) type {
    _ = T;
    return u32;
}

const ElementList = List(Element);
const Element = struct {
    link: ElementList,
};

test "false dependency loop in struct definition" {
    const listType = ElementList;
    var x: listType = 42;
    try expectEqual(x, 42);
}
