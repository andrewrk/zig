const std = @import("std");
const fixint = @import("fixint.zig").fixint;
const builtin = std.builtin;

pub fn __fixdfti(a: f64) callconv(.C) i128 {
    @setRuntimeSafety(builtin.is_test);
    return fixint(f64, i128, a);
}

test "import fixdfti" {
    _ = @import("fixdfti_test.zig");
}
