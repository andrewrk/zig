const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "truncate u0 to larger integer allowed and has comptime known result" {
    var x: u0 = 0;
    const y = @truncate(u8, x);
    comptime try expectEqual(y, 0);
}

test "truncate.u0.literal" {
    var z = @truncate(u0, 0);
    try expectEqual(z, 0);
}

test "truncate.u0.const" {
    const c0: usize = 0;
    var z = @truncate(u0, c0);
    try expectEqual(z, 0);
}

test "truncate.u0.var" {
    var d: u8 = 2;
    var z = @truncate(u0, d);
    try expectEqual(z, 0);
}

test "truncate i0 to larger integer allowed and has comptime known result" {
    var x: i0 = 0;
    const y = @truncate(i8, x);
    comptime try expectEqual(y, 0);
}

test "truncate.i0.literal" {
    var z = @truncate(i0, 0);
    try expectEqual(z, 0);
}

test "truncate.i0.const" {
    const c0: isize = 0;
    var z = @truncate(i0, c0);
    try expectEqual(z, 0);
}

test "truncate.i0.var" {
    var d: i8 = 2;
    var z = @truncate(i0, d);
    try expectEqual(z, 0);
}

test "truncate on comptime integer" {
    var x = @truncate(u16, 9999);
    try expectEqual(x, 9999);
    var y = @truncate(u16, -21555);
    try expectEqual(y, 0xabcd);
    var z = @truncate(i16, -65537);
    try expectEqual(z, -1);
    var w = @truncate(u1, 1 << 100);
    try expectEqual(w, 0);
}
