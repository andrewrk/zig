const expect = @import("std").testing.expect;
const expectEqual = @import("std").testing.expectEqual;

test "@ptrCast from const to nullable" {
    const c: u8 = 4;
    var x: ?*const u8 = @ptrCast(?*const u8, &c);
    try expectEqual(x.?.*, 4);
}

test "@ptrCast from var in empty struct to nullable" {
    const container = struct {
        var c: u8 = 4;
    };
    var x: ?*const u8 = @ptrCast(?*const u8, &container.c);
    try expectEqual(x.?.*, 4);
}
