const expect = @import("std").testing.expect;
const expectEqual = @import("std").testing.expectEqual;
const builtin = @import("builtin");

test "@hasField" {
    const struc = struct {
        a: i32,
        b: []u8,

        pub const nope = 1;
    };
    try expectEqual(@hasField(struc, "a"), true);
    try expectEqual(@hasField(struc, "b"), true);
    try expectEqual(@hasField(struc, "non-existant"), false);
    try expectEqual(@hasField(struc, "nope"), false);

    const unin = union {
        a: u64,
        b: []u16,

        pub const nope = 1;
    };
    try expectEqual(@hasField(unin, "a"), true);
    try expectEqual(@hasField(unin, "b"), true);
    try expectEqual(@hasField(unin, "non-existant"), false);
    try expectEqual(@hasField(unin, "nope"), false);

    const enm = enum {
        a,
        b,

        pub const nope = 1;
    };
    try expectEqual(@hasField(enm, "a"), true);
    try expectEqual(@hasField(enm, "b"), true);
    try expectEqual(@hasField(enm, "non-existant"), false);
    try expectEqual(@hasField(enm, "nope"), false);
}
