const expect = @import("std").testing.expect;
const expectEqual = @import("std").testing.expectEqual;

fn add(args: anytype) i32 {
    var sum = @as(i32, 0);
    {
        comptime var i: usize = 0;
        inline while (i < args.len) : (i += 1) {
            sum += args[i];
        }
    }
    return sum;
}

test "add arbitrary args" {
    try expectEqual(add(.{ @as(i32, 1), @as(i32, 2), @as(i32, 3), @as(i32, 4) }), 10);
    try expectEqual(add(.{@as(i32, 1234)}), 1234);
    try expectEqual(add(.{}), 0);
}

fn readFirstVarArg(args: anytype) void {
    _ = args[0];
}

test "send void arg to var args" {
    readFirstVarArg(.{{}});
}

test "pass args directly" {
    try expectEqual(addSomeStuff(.{ @as(i32, 1), @as(i32, 2), @as(i32, 3), @as(i32, 4) }), 10);
    try expectEqual(addSomeStuff(.{@as(i32, 1234)}), 1234);
    try expectEqual(addSomeStuff(.{}), 0);
}

fn addSomeStuff(args: anytype) i32 {
    return add(args);
}

test "runtime parameter before var args" {
    try expectEqual((try extraFn(10, .{})), 0);
    try expectEqual((try extraFn(10, .{false})), 1);
    try expectEqual((try extraFn(10, .{ false, true })), 2);

    comptime {
        try expectEqual((try extraFn(10, .{})), 0);
        try expectEqual((try extraFn(10, .{false})), 1);
        try expectEqual((try extraFn(10, .{ false, true })), 2);
    }
}

fn extraFn(extra: u32, args: anytype) !usize {
    _ = extra;
    if (args.len >= 1) {
        try expectEqual(args[0], false);
    }
    if (args.len >= 2) {
        try expectEqual(args[1], true);
    }
    return args.len;
}

const foos = [_]fn (anytype) bool{
    foo1,
    foo2,
};

fn foo1(args: anytype) bool {
    _ = args;
    return true;
}
fn foo2(args: anytype) bool {
    _ = args;
    return false;
}

test "array of var args functions" {
    try expect(foos[0](.{}));
    try expect(!foos[1](.{}));
}

test "pass zero length array to var args param" {
    doNothingWithFirstArg(.{""});
}

fn doNothingWithFirstArg(args: anytype) void {
    _ = args[0];
}
