const std = @import("std");

extern fn add_C(x: i32) i32;
extern fn add_C_zig(x: i32) i32;
extern threadlocal var C_k: c_int;

export var zig_k: c_int = 1;
export fn add_zig(x: i32) i32 {
    return x + zig_k + C_k;
}
export fn add_may_panic(x: i32) i32 {
    if (x < 0) @panic("negative int");
    return x + zig_k;
}

pub fn main() anyerror!void {
    var x: i32 = 0;
    x = add_zig(x);
    x = add_C(x);
    x = add_C_zig(x);

    C_k = 200;
    zig_k = 2;
    x = add_zig(x);
    x = add_C(x);
    x = add_C_zig(x);

    const u = @intCast(u32, x);
    try std.testing.expect(u / 100 == u % 100);
}
