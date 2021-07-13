const std = @import("std");

const mystruct = struct {
    pending: ?listofstructs,
};
pub fn TailQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Node = struct {
            prev: ?*Node,
            next: ?*Node,
            data: T,
        };

        first: ?*Node,
        last: ?*Node,
        len: usize,

        pub fn init() Self {
            return Self{
                .first = null,
                .last = null,
                .len = 0,
            };
        }
    };
}
const listofstructs = TailQueue(mystruct);

const a = struct {
    const Self = @This();

    foo: listofstructs,

    pub fn init() Self {
        return Self{
            .foo = listofstructs.init(),
        };
    }
};

test "intialization" {
    var t = a.init();
    try std.testing.expectEqual(t.foo.len, 0);
}
