const assert = @import("std").debug.assert;

const Value = enum {
    Int: u64,
    Array: [9]u8,
};

const Agg = struct {
    val1: Value,
    val2: Value,
};

const v1 = Value.Int { 1234 };
const v2 = Value.Array { []u8{3} ** 9 };

const err = (%Agg)(Agg {
    .val1 = v1,
    .val2 = v2,
});

const array = []Value { v1, v2, v1, v2};


test "unions embedded in aggregate types" {
    switch (array[1]) {
        Value.Array => |arr| assert(arr[4] == 3),
        else => unreachable,
    }
    switch((%%err).val1) {
        Value.Int => |x| assert(x == 1234),
        else => unreachable,
    }
}
