const std = @import("std");
const fixuint = @import("fixuint.zig").fixuint;
const builtin = std.builtin;

pub fn __fixunsdfti(a: f64) callconv(.C) u128 {
    @setRuntimeSafety(builtin.is_test);
    return fixuint(f64, u128, a);
}

test "import fixunsdfti" {
    _ = @import("fixunsdfti_test.zig");
}
