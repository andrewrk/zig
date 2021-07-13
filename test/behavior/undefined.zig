const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const mem = std.mem;

fn initStaticArray() [10]i32 {
    var array: [10]i32 = undefined;
    array[0] = 1;
    array[4] = 2;
    array[7] = 3;
    array[9] = 4;
    return array;
}
const static_array = initStaticArray();
test "init static array to undefined" {
    try expectEqual(static_array[0], 1);
    try expectEqual(static_array[4], 2);
    try expectEqual(static_array[7], 3);
    try expectEqual(static_array[9], 4);

    comptime {
        try expectEqual(static_array[0], 1);
        try expectEqual(static_array[4], 2);
        try expectEqual(static_array[7], 3);
        try expectEqual(static_array[9], 4);
    }
}

const Foo = struct {
    x: i32,

    fn setFooXMethod(foo: *Foo) void {
        foo.x = 3;
    }
};

fn setFooX(foo: *Foo) void {
    foo.x = 2;
}

test "assign undefined to struct" {
    comptime {
        var foo: Foo = undefined;
        setFooX(&foo);
        try expectEqual(foo.x, 2);
    }
    {
        var foo: Foo = undefined;
        setFooX(&foo);
        try expectEqual(foo.x, 2);
    }
}

test "assign undefined to struct with method" {
    comptime {
        var foo: Foo = undefined;
        foo.setFooXMethod();
        try expectEqual(foo.x, 3);
    }
    {
        var foo: Foo = undefined;
        foo.setFooXMethod();
        try expectEqual(foo.x, 3);
    }
}

test "type name of undefined" {
    const x = undefined;
    try expect(mem.eql(u8, @typeName(@TypeOf(x)), "(undefined)"));
}
