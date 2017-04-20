const assert = @import("std").debug.assert;
const mem = @import("std").mem;

test "arrays" {
    var array : [5]u32 = undefined;

    var i : u32 = 0;
    while (i < 5) {
        array[i] = i + 1;
        i = array[i];
    }

    i = 0;
    var accumulator = u32(0);
    while (i < 5) {
        accumulator += array[i];

        i += 1;
    }

    assert(accumulator == 15);
    assert(getArrayLen(array) == 5);
}
fn getArrayLen(a: []const u32) -> usize {
    a.len
}

test "voidArrays" {
    var array: [4]void = undefined;
    array[0] = void{};
    array[1] = array[2];
    assert(@sizeOf(@typeOf(array)) == 0);
    assert(array.len == 4);
}

test "arrayLiteral" {
    const hex_mult = []u16{4096, 256, 16, 1};

    assert(hex_mult.len == 4);
    assert(hex_mult[1] == 256);
}

test "arrayDotLenConstExpr" {
    assert(comptime {some_array.len == 4});
}

const ArrayDotLenConstExpr = struct {
    y: [some_array.len]u8,
};
const some_array = []u8 {0, 1, 2, 3};


test "nestedArrays" {
    const array_of_strings = [][]const u8 {"hello", "this", "is", "my", "thing"};
    for (array_of_strings) |s, i| {
        if (i == 0) assert(mem.eql(u8, s, "hello"));
        if (i == 1) assert(mem.eql(u8, s, "this"));
        if (i == 2) assert(mem.eql(u8, s, "is"));
        if (i == 3) assert(mem.eql(u8, s, "my"));
        if (i == 4) assert(mem.eql(u8, s, "thing"));
    }
}


var s_array: [8]Sub = undefined;
const Sub = struct {
    b: u8,
};
const Str = struct {
    a: []Sub,
};
test "setGlobalVarArrayViaSliceEmbeddedInStruct" {
    var s = Str { .a = s_array[0...]};

    s.a[0].b = 1;
    s.a[1].b = 2;
    s.a[2].b = 3;

    assert(s_array[0].b == 1);
    assert(s_array[1].b == 2);
    assert(s_array[2].b == 3);
}
