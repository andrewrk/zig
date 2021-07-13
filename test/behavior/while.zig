const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "while loop" {
    var i: i32 = 0;
    while (i < 4) {
        i += 1;
    }
    try expectEqual(i, 4);
    try expectEqual(whileLoop1(), 1);
}
fn whileLoop1() i32 {
    return whileLoop2();
}
fn whileLoop2() i32 {
    while (true) {
        return 1;
    }
}

test "static eval while" {
    try expectEqual(static_eval_while_number, 1);
}
const static_eval_while_number = staticWhileLoop1();
fn staticWhileLoop1() i32 {
    return whileLoop2();
}
fn staticWhileLoop2() i32 {
    while (true) {
        return 1;
    }
}

test "continue and break" {
    try runContinueAndBreakTest();
    try expectEqual(continue_and_break_counter, 8);
}
var continue_and_break_counter: i32 = 0;
fn runContinueAndBreakTest() !void {
    var i: i32 = 0;
    while (true) {
        continue_and_break_counter += 2;
        i += 1;
        if (i < 4) {
            continue;
        }
        break;
    }
    try expectEqual(i, 4);
}

test "return with implicit cast from while loop" {
    returnWithImplicitCastFromWhileLoopTest() catch unreachable;
}
fn returnWithImplicitCastFromWhileLoopTest() anyerror!void {
    while (true) {
        return;
    }
}

test "while with continue expression" {
    var sum: i32 = 0;
    {
        var i: i32 = 0;
        while (i < 10) : (i += 1) {
            if (i == 5) continue;
            sum += i;
        }
    }
    try expectEqual(sum, 40);
}

test "while with else" {
    var sum: i32 = 0;
    var i: i32 = 0;
    var got_else: i32 = 0;
    while (i < 10) : (i += 1) {
        sum += 1;
    } else {
        got_else += 1;
    }
    try expectEqual(sum, 10);
    try expectEqual(got_else, 1);
}

test "while with optional as condition" {
    numbers_left = 10;
    var sum: i32 = 0;
    while (getNumberOrNull()) |value| {
        sum += value;
    }
    try expectEqual(sum, 45);
}

test "while with optional as condition with else" {
    numbers_left = 10;
    var sum: i32 = 0;
    var got_else: i32 = 0;
    while (getNumberOrNull()) |value| {
        sum += value;
        try expectEqual(got_else, 0);
    } else {
        got_else += 1;
    }
    try expectEqual(sum, 45);
    try expectEqual(got_else, 1);
}

test "while with error union condition" {
    numbers_left = 10;
    var sum: i32 = 0;
    var got_else: i32 = 0;
    while (getNumberOrErr()) |value| {
        sum += value;
    } else |err| {
        try expectEqual(err, error.OutOfNumbers);
        got_else += 1;
    }
    try expectEqual(sum, 45);
    try expectEqual(got_else, 1);
}

var numbers_left: i32 = undefined;
fn getNumberOrErr() anyerror!i32 {
    return if (numbers_left == 0) error.OutOfNumbers else x: {
        numbers_left -= 1;
        break :x numbers_left;
    };
}
fn getNumberOrNull() ?i32 {
    return if (numbers_left == 0) null else x: {
        numbers_left -= 1;
        break :x numbers_left;
    };
}

test "while on optional with else result follow else prong" {
    const result = while (returnNull()) |value| {
        break value;
    } else @as(i32, 2);
    try expectEqual(result, 2);
}

test "while on optional with else result follow break prong" {
    const result = while (returnOptional(10)) |value| {
        break value;
    } else @as(i32, 2);
    try expectEqual(result, 10);
}

test "while on error union with else result follow else prong" {
    const result = while (returnError()) |value| {
        break value;
    } else |_| @as(i32, 2);
    try expectEqual(result, 2);
}

test "while on error union with else result follow break prong" {
    const result = while (returnSuccess(10)) |value| {
        break value;
    } else |_| @as(i32, 2);
    try expectEqual(result, 10);
}

test "while on bool with else result follow else prong" {
    const result = while (returnFalse()) {
        break @as(i32, 10);
    } else @as(i32, 2);
    try expectEqual(result, 2);
}

test "while on bool with else result follow break prong" {
    const result = while (returnTrue()) {
        break @as(i32, 10);
    } else @as(i32, 2);
    try expectEqual(result, 10);
}

test "break from outer while loop" {
    testBreakOuter();
    comptime testBreakOuter();
}

fn testBreakOuter() void {
    outer: while (true) {
        while (true) {
            break :outer;
        }
    }
}

test "continue outer while loop" {
    testContinueOuter();
    comptime testContinueOuter();
}

fn testContinueOuter() void {
    var i: usize = 0;
    outer: while (i < 10) : (i += 1) {
        while (true) {
            continue :outer;
        }
    }
}

fn returnNull() ?i32 {
    return null;
}
fn returnOptional(x: i32) ?i32 {
    return x;
}
fn returnError() anyerror!i32 {
    return error.YouWantedAnError;
}
fn returnSuccess(x: i32) anyerror!i32 {
    return x;
}
fn returnFalse() bool {
    return false;
}
fn returnTrue() bool {
    return true;
}

test "while bool 2 break statements and an else" {
    const S = struct {
        fn entry(t: bool, f: bool) !void {
            var ok = false;
            ok = while (t) {
                if (f) break false;
                if (t) break true;
            } else false;
            try expect(ok);
        }
    };
    try S.entry(true, false);
    comptime try S.entry(true, false);
}

test "while optional 2 break statements and an else" {
    const S = struct {
        fn entry(opt_t: ?bool, f: bool) !void {
            var ok = false;
            ok = while (opt_t) |t| {
                if (f) break false;
                if (t) break true;
            } else false;
            try expect(ok);
        }
    };
    try S.entry(true, false);
    comptime try S.entry(true, false);
}

test "while error 2 break statements and an else" {
    const S = struct {
        fn entry(opt_t: anyerror!bool, f: bool) !void {
            var ok = false;
            ok = while (opt_t) |t| {
                if (f) break false;
                if (t) break true;
            } else |_| false;
            try expect(ok);
        }
    };
    try S.entry(true, false);
    comptime try S.entry(true, false);
}

test "while copies its payload" {
    const S = struct {
        fn doTheTest() !void {
            var tmp: ?i32 = 10;
            while (tmp) |value| {
                // Modify the original variable
                tmp = null;
                try expectEqual(value, 10);
            }
        }
    };
    try S.doTheTest();
    comptime try S.doTheTest();
}
