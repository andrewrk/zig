const std = @import("std");
const expect = std.testing.expect;
const expectError = std.testing.expectError;
const expectEqual = std.testing.expectEqual;
const mem = std.mem;

pub fn foo() anyerror!i32 {
    const x = try bar();
    return x + 1;
}

pub fn bar() anyerror!i32 {
    return 13;
}

pub fn baz() anyerror!i32 {
    const y = foo() catch 1234;
    return y + 1;
}

test "error wrapping" {
    try expectEqual((baz() catch unreachable), 15);
}

fn gimmeItBroke() []const u8 {
    return @errorName(error.ItBroke);
}

test "@errorName" {
    try expect(mem.eql(u8, @errorName(error.AnError), "AnError"));
    try expect(mem.eql(u8, @errorName(error.ALongerErrorName), "ALongerErrorName"));
}

test "error values" {
    const a = @errorToInt(error.err1);
    const b = @errorToInt(error.err2);
    try expect(a != b);
}

test "redefinition of error values allowed" {
    shouldBeNotEqual(error.AnError, error.SecondError);
}
fn shouldBeNotEqual(a: anyerror, b: anyerror) void {
    if (a == b) unreachable;
}

test "error binary operator" {
    const a = errBinaryOperatorG(true) catch 3;
    const b = errBinaryOperatorG(false) catch 3;
    try expectEqual(a, 3);
    try expectEqual(b, 10);
}
fn errBinaryOperatorG(x: bool) anyerror!isize {
    return if (x) error.ItBroke else @as(isize, 10);
}

test "unwrap simple value from error" {
    const i = unwrapSimpleValueFromErrorDo() catch unreachable;
    try expectEqual(i, 13);
}
fn unwrapSimpleValueFromErrorDo() anyerror!isize {
    return 13;
}

test "error return in assignment" {
    doErrReturnInAssignment() catch unreachable;
}

fn doErrReturnInAssignment() anyerror!void {
    var x: i32 = undefined;
    x = try makeANonErr();
}

fn makeANonErr() anyerror!i32 {
    return 1;
}

test "error union type " {
    try testErrorUnionType();
    comptime try testErrorUnionType();
}

fn testErrorUnionType() !void {
    const x: anyerror!i32 = 1234;
    if (x) |value| try expectEqual(value, 1234) else |_| unreachable;
    try expectEqual(@typeInfo(@TypeOf(x)), .ErrorUnion);
    try expectEqual(@typeInfo(@typeInfo(@TypeOf(x)).ErrorUnion.error_set), .ErrorSet);
    try expectEqual(@typeInfo(@TypeOf(x)).ErrorUnion.error_set, anyerror);
}

test "error set type" {
    try testErrorSetType();
    comptime try testErrorSetType();
}

const MyErrSet = error{
    OutOfMemory,
    FileNotFound,
};

fn testErrorSetType() !void {
    try expectEqual(@typeInfo(MyErrSet).ErrorSet.?.len, 2);

    const a: MyErrSet!i32 = 5678;
    const b: MyErrSet!i32 = MyErrSet.OutOfMemory;
    try expectEqual(b catch error.OutOfMemory, error.OutOfMemory);

    if (a) |value| try expectEqual(value, 5678) else |err| switch (err) {
        error.OutOfMemory => unreachable,
        error.FileNotFound => unreachable,
    }
}

test "explicit error set cast" {
    try testExplicitErrorSetCast(Set1.A);
    comptime try testExplicitErrorSetCast(Set1.A);
}

const Set1 = error{
    A,
    B,
};
const Set2 = error{
    A,
    C,
};

fn testExplicitErrorSetCast(set1: Set1) !void {
    var x = @errSetCast(Set2, set1);
    var y = @errSetCast(Set1, x);
    try expectEqual(y, error.A);
}

test "comptime test error for empty error set" {
    try testComptimeTestErrorEmptySet(1234);
    comptime try testComptimeTestErrorEmptySet(1234);
}

const EmptyErrorSet = error{};

fn testComptimeTestErrorEmptySet(x: EmptyErrorSet!i32) !void {
    if (x) |v| try expectEqual(v, 1234) else |err| {
        _ = err;
        @compileError("bad");
    }
}

test "syntax: optional operator in front of error union operator" {
    comptime {
        try expectEqual(?(anyerror!i32), ?(anyerror!i32));
    }
}

test "comptime err to int of error set with only 1 possible value" {
    testErrToIntWithOnePossibleValue(error.A, @errorToInt(error.A));
    comptime testErrToIntWithOnePossibleValue(error.A, @errorToInt(error.A));
}
fn testErrToIntWithOnePossibleValue(
    x: error{A},
    comptime value: u32,
) void {
    if (@errorToInt(x) != value) {
        @compileError("bad");
    }
}

test "empty error union" {
    const x = error{} || error{};
    _ = x;
}

test "error union peer type resolution" {
    try testErrorUnionPeerTypeResolution(1);
}

fn testErrorUnionPeerTypeResolution(x: i32) !void {
    const y = switch (x) {
        1 => bar_1(),
        2 => baz_1(),
        else => quux_1(),
    };
    if (y) |_| {
        @panic("expected error");
    } else |e| {
        try expectEqual(e, error.A);
    }
}

fn bar_1() anyerror {
    return error.A;
}

fn baz_1() !i32 {
    return error.B;
}

fn quux_1() !i32 {
    return error.C;
}

test "error: fn returning empty error set can be passed as fn returning any error" {
    entry();
    comptime entry();
}

fn entry() void {
    foo2(bar2);
}

fn foo2(f: fn () anyerror!void) void {
    const x = f();
    x catch {};
}

fn bar2() (error{}!void) {}

test "error: Zero sized error set returned with value payload crash" {
    _ = foo3(0) catch {};
    _ = comptime foo3(0) catch {};
}

const Error = error{};
fn foo3(b: usize) Error!usize {
    return b;
}

test "error: Infer error set from literals" {
    _ = nullLiteral("n") catch |err| handleErrors(err);
    _ = floatLiteral("n") catch |err| handleErrors(err);
    _ = intLiteral("n") catch |err| handleErrors(err);
    _ = comptime nullLiteral("n") catch |err| handleErrors(err);
    _ = comptime floatLiteral("n") catch |err| handleErrors(err);
    _ = comptime intLiteral("n") catch |err| handleErrors(err);
}

fn handleErrors(err: anytype) noreturn {
    switch (err) {
        error.T => {},
    }

    unreachable;
}

fn nullLiteral(str: []const u8) !?i64 {
    if (str[0] == 'n') return null;

    return error.T;
}

fn floatLiteral(str: []const u8) !?f64 {
    if (str[0] == 'n') return 1.0;

    return error.T;
}

fn intLiteral(str: []const u8) !?i64 {
    if (str[0] == 'n') return 1;

    return error.T;
}

test "nested error union function call in optional unwrap" {
    const S = struct {
        const Foo = struct {
            a: i32,
        };

        fn errorable() !i32 {
            var x: Foo = (try getFoo()) orelse return error.Other;
            return x.a;
        }

        fn errorable2() !i32 {
            var x: Foo = (try getFoo2()) orelse return error.Other;
            return x.a;
        }

        fn errorable3() !i32 {
            var x: Foo = (try getFoo3()) orelse return error.Other;
            return x.a;
        }

        fn getFoo() anyerror!?Foo {
            return Foo{ .a = 1234 };
        }

        fn getFoo2() anyerror!?Foo {
            return error.Failure;
        }

        fn getFoo3() anyerror!?Foo {
            return null;
        }
    };
    try expectEqual((try S.errorable()), 1234);
    try expectError(error.Failure, S.errorable2());
    try expectError(error.Other, S.errorable3());
    comptime {
        try expectEqual((try S.errorable()), 1234);
        try expectError(error.Failure, S.errorable2());
        try expectError(error.Other, S.errorable3());
    }
}

test "widen cast integer payload of error union function call" {
    const S = struct {
        fn errorable() !u64 {
            var x = @as(u64, try number());
            return x;
        }

        fn number() anyerror!u32 {
            return 1234;
        }
    };
    try expectEqual((try S.errorable()), 1234);
}

test "return function call to error set from error union function" {
    const S = struct {
        fn errorable() anyerror!i32 {
            return fail();
        }

        fn fail() anyerror {
            return error.Failure;
        }
    };
    try expectError(error.Failure, S.errorable());
    comptime try expectError(error.Failure, S.errorable());
}

test "optional error set is the same size as error set" {
    comptime try expectEqual(@sizeOf(?anyerror), @sizeOf(anyerror));
    const S = struct {
        fn returnsOptErrSet() ?anyerror {
            return null;
        }
    };
    try expectEqual(S.returnsOptErrSet(), null);
    comptime try expectEqual(S.returnsOptErrSet(), null);
}

test "debug info for optional error set" {
    const SomeError = error{Hello};
    var a_local_variable: ?SomeError = null;
    _ = a_local_variable;
}

test "nested catch" {
    const S = struct {
        fn entry() !void {
            try expectError(error.Bad, func());
        }
        fn fail() anyerror!Foo {
            return error.Wrong;
        }
        fn func() anyerror!Foo {
            _ = fail() catch
                fail() catch
                return error.Bad;
            unreachable;
        }
        const Foo = struct {
            field: i32,
        };
    };
    try S.entry();
    comptime try S.entry();
}

test "implicit cast to optional to error union to return result loc" {
    const S = struct {
        fn entry() !void {
            var x: Foo = undefined;
            if (func(&x)) |opt| {
                try expect(opt != null);
            } else |_| @panic("expected non error");
        }
        fn func(f: *Foo) anyerror!?*Foo {
            return f;
        }
        const Foo = struct {
            field: i32,
        };
    };
    try S.entry();
    //comptime S.entry(); TODO
}

test "function pointer with return type that is error union with payload which is pointer of parent struct" {
    const S = struct {
        const Foo = struct {
            fun: fn (a: i32) (anyerror!*Foo),
        };

        const Err = error{UnspecifiedErr};

        fn bar(a: i32) anyerror!*Foo {
            _ = a;
            return Err.UnspecifiedErr;
        }

        fn doTheTest() !void {
            var x = Foo{ .fun = @This().bar };
            try expectError(error.UnspecifiedErr, x.fun(1));
        }
    };
    try S.doTheTest();
}

test "return result loc as peer result loc in inferred error set function" {
    const S = struct {
        fn doTheTest() !void {
            if (foo(2)) |x| {
                try expect(x.Two);
            } else |e| switch (e) {
                error.Whatever => @panic("fail"),
            }
            try expectError(error.Whatever, foo(99));
        }
        const FormValue = union(enum) {
            One: void,
            Two: bool,
        };

        fn foo(id: u64) !FormValue {
            return switch (id) {
                2 => FormValue{ .Two = true },
                1 => FormValue{ .One = {} },
                else => return error.Whatever,
            };
        }
    };
    try S.doTheTest();
    comptime try S.doTheTest();
}

test "error payload type is correctly resolved" {
    const MyIntWrapper = struct {
        const Self = @This();

        x: i32,

        pub fn create() anyerror!Self {
            return Self{ .x = 42 };
        }
    };

    try expectEqual(MyIntWrapper{ .x = 42 }, try MyIntWrapper.create());
}

test "error union comptime caching" {
    const S = struct {
        fn foo(comptime arg: anytype) void {
            arg catch {};
        }
    };

    S.foo(@as(anyerror!void, {}));
    S.foo(@as(anyerror!void, {}));
}
