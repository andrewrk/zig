const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;

test "params" {
    try expectEqual(testParamsAdd(22, 11), 33);
}
fn testParamsAdd(a: i32, b: i32) i32 {
    return a + b;
}

test "local variables" {
    testLocVars(2);
}
fn testLocVars(b: i32) void {
    const a: i32 = 1;
    if (a + b != 3) unreachable;
}

test "void parameters" {
    try voidFun(1, void{}, 2, {});
}
fn voidFun(a: i32, b: void, c: i32, d: void) !void {
    _ = d;
    const v = b;
    const vv: void = if (a == 1) v else {};
    try expectEqual(a + c, 3);
    return vv;
}

test "mutable local variables" {
    var zero: i32 = 0;
    try expectEqual(zero, 0);

    var i = @as(i32, 0);
    while (i != 3) {
        i += 1;
    }
    try expectEqual(i, 3);
}

test "separate block scopes" {
    {
        const no_conflict: i32 = 5;
        try expectEqual(no_conflict, 5);
    }

    const c = x: {
        const no_conflict = @as(i32, 10);
        break :x no_conflict;
    };
    try expectEqual(c, 10);
}

test "call function with empty string" {
    acceptsString("");
}

fn acceptsString(foo: []u8) void {
    _ = foo;
}

fn @"weird function name"() i32 {
    return 1234;
}
test "weird function name" {
    try expectEqual(@"weird function name"(), 1234);
}

test "implicit cast function unreachable return" {
    wantsFnWithVoid(fnWithUnreachable);
}

fn wantsFnWithVoid(f: fn () void) void {
    _ = f;
}

fn fnWithUnreachable() noreturn {
    unreachable;
}

test "function pointers" {
    const fns = [_]@TypeOf(fn1){
        fn1,
        fn2,
        fn3,
        fn4,
    };
    for (fns) |f, i| {
        try expectEqual(f(), @intCast(u32, i) + 5);
    }
}
fn fn1() u32 {
    return 5;
}
fn fn2() u32 {
    return 6;
}
fn fn3() u32 {
    return 7;
}
fn fn4() u32 {
    return 8;
}

test "number literal as an argument" {
    try numberLiteralArg(3);
    comptime try numberLiteralArg(3);
}

fn numberLiteralArg(a: anytype) !void {
    try expectEqual(a, 3);
}

test "assign inline fn to const variable" {
    const a = inlineFn;
    a();
}

inline fn inlineFn() void {}

test "pass by non-copying value" {
    try expectEqual(addPointCoords(Point{ .x = 1, .y = 2 }), 3);
}

const Point = struct {
    x: i32,
    y: i32,
};

fn addPointCoords(pt: Point) i32 {
    return pt.x + pt.y;
}

test "pass by non-copying value through var arg" {
    try expectEqual((try addPointCoordsVar(Point{ .x = 1, .y = 2 })), 3);
}

fn addPointCoordsVar(pt: anytype) !i32 {
    comptime try expectEqual(@TypeOf(pt), Point);
    return pt.x + pt.y;
}

test "pass by non-copying value as method" {
    var pt = Point2{ .x = 1, .y = 2 };
    try expectEqual(pt.addPointCoords(), 3);
}

const Point2 = struct {
    x: i32,
    y: i32,

    fn addPointCoords(self: Point2) i32 {
        return self.x + self.y;
    }
};

test "pass by non-copying value as method, which is generic" {
    var pt = Point3{ .x = 1, .y = 2 };
    try expectEqual(pt.addPointCoords(i32), 3);
}

const Point3 = struct {
    x: i32,
    y: i32,

    fn addPointCoords(self: Point3, comptime T: type) i32 {
        _ = T;
        return self.x + self.y;
    }
};

test "pass by non-copying value as method, at comptime" {
    comptime {
        var pt = Point2{ .x = 1, .y = 2 };
        try expectEqual(pt.addPointCoords(), 3);
    }
}

fn outer(y: u32) fn (u32) u32 {
    const Y = @TypeOf(y);
    const st = struct {
        fn get(z: u32) u32 {
            return z + @sizeOf(Y);
        }
    };
    return st.get;
}

test "return inner function which references comptime variable of outer function" {
    var func = outer(10);
    try expectEqual(func(3), 7);
}

test "extern struct with stdcallcc fn pointer" {
    const S = extern struct {
        ptr: fn () callconv(if (builtin.target.cpu.arch == .i386) .Stdcall else .C) i32,

        fn foo() callconv(if (builtin.target.cpu.arch == .i386) .Stdcall else .C) i32 {
            return 1234;
        }
    };

    var s: S = undefined;
    s.ptr = S.foo;
    try expectEqual(s.ptr(), 1234);
}

test "implicit cast fn call result to optional in field result" {
    const S = struct {
        fn entry() !void {
            var x = Foo{
                .field = optionalPtr(),
            };
            try expectEqual(x.field.?.*, 999);
        }

        const glob: i32 = 999;

        fn optionalPtr() *const i32 {
            return &glob;
        }

        const Foo = struct {
            field: ?*const i32,
        };
    };
    try S.entry();
    comptime try S.entry();
}

test "discard the result of a function that returns a struct" {
    const S = struct {
        fn entry() void {
            _ = func();
        }

        fn func() Foo {
            return undefined;
        }

        const Foo = struct {
            a: u64,
            b: u64,
        };
    };
    S.entry();
    comptime S.entry();
}

test "function call with anon list literal" {
    const S = struct {
        fn doTheTest() !void {
            try consumeVec(.{ 9, 8, 7 });
        }

        fn consumeVec(vec: [3]f32) !void {
            try expectEqual(vec[0], 9);
            try expectEqual(vec[1], 8);
            try expectEqual(vec[2], 7);
        }
    };
    try S.doTheTest();
    comptime try S.doTheTest();
}

test "ability to give comptime types and non comptime types to same parameter" {
    const S = struct {
        fn doTheTest() !void {
            var x: i32 = 1;
            try expectEqual(foo(x), 10);
            try expectEqual(foo(i32), 20);
        }

        fn foo(arg: anytype) i32 {
            if (@typeInfo(@TypeOf(arg)) == .Type and arg == i32) return 20;
            return 9 + arg;
        }
    };
    try S.doTheTest();
    comptime try S.doTheTest();
}

test "function with inferred error set but returning no error" {
    const S = struct {
        fn foo() !void {}
    };

    const return_ty = @typeInfo(@TypeOf(S.foo)).Fn.return_type.?;
    try expectEqual(0, @typeInfo(@typeInfo(return_ty).ErrorUnion.error_set).ErrorSet.?.len);
}
