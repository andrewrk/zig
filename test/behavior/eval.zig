const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "compile time recursion" {
    try expectEqual(some_data.len, 21);
}
var some_data: [@intCast(usize, fibonacci(7))]u8 = undefined;
fn fibonacci(x: i32) i32 {
    if (x <= 1) return 1;
    return fibonacci(x - 1) + fibonacci(x - 2);
}

fn unwrapAndAddOne(blah: ?i32) i32 {
    return blah.? + 1;
}
const should_be_1235 = unwrapAndAddOne(1234);
test "static add one" {
    try expectEqual(should_be_1235, 1235);
}

test "inlined loop" {
    comptime var i = 0;
    comptime var sum = 0;
    inline while (i <= 5) : (i += 1)
        sum += i;
    try expectEqual(sum, 15);
}

fn gimme1or2(comptime a: bool) i32 {
    const x: i32 = 1;
    const y: i32 = 2;
    comptime var z: i32 = if (a) x else y;
    return z;
}
test "inline variable gets result of const if" {
    try expectEqual(gimme1or2(true), 1);
    try expectEqual(gimme1or2(false), 2);
}

test "static function evaluation" {
    try expectEqual(statically_added_number, 3);
}
const statically_added_number = staticAdd(1, 2);
fn staticAdd(a: i32, b: i32) i32 {
    return a + b;
}

test "const expr eval on single expr blocks" {
    try expectEqual(constExprEvalOnSingleExprBlocksFn(1, true), 3);
    comptime try expectEqual(constExprEvalOnSingleExprBlocksFn(1, true), 3);
}

fn constExprEvalOnSingleExprBlocksFn(x: i32, b: bool) i32 {
    const literal = 3;

    const result = if (b) b: {
        break :b literal;
    } else b: {
        break :b x;
    };

    return result;
}

test "statically initialized list" {
    try expectEqual(static_point_list[0].x, 1);
    try expectEqual(static_point_list[0].y, 2);
    try expectEqual(static_point_list[1].x, 3);
    try expectEqual(static_point_list[1].y, 4);
}
const Point = struct {
    x: i32,
    y: i32,
};
const static_point_list = [_]Point{
    makePoint(1, 2),
    makePoint(3, 4),
};
fn makePoint(x: i32, y: i32) Point {
    return Point{
        .x = x,
        .y = y,
    };
}

test "static eval list init" {
    try expectEqual(static_vec3.data[2], 1.0);
    try expectEqual(vec3(0.0, 0.0, 3.0).data[2], 3.0);
}
const static_vec3 = vec3(0.0, 0.0, 1.0);
pub const Vec3 = struct {
    data: [3]f32,
};
pub fn vec3(x: f32, y: f32, z: f32) Vec3 {
    return Vec3{
        .data = [_]f32{
            x,
            y,
            z,
        },
    };
}

test "constant expressions" {
    var array: [array_size]u8 = undefined;
    try expectEqual(@sizeOf(@TypeOf(array)), 20);
}
const array_size: u8 = 20;

test "constant struct with negation" {
    try expectEqual(vertices[0].x, -0.6);
}
const Vertex = struct {
    x: f32,
    y: f32,
    r: f32,
    g: f32,
    b: f32,
};
const vertices = [_]Vertex{
    Vertex{
        .x = -0.6,
        .y = -0.4,
        .r = 1.0,
        .g = 0.0,
        .b = 0.0,
    },
    Vertex{
        .x = 0.6,
        .y = -0.4,
        .r = 0.0,
        .g = 1.0,
        .b = 0.0,
    },
    Vertex{
        .x = 0.0,
        .y = 0.6,
        .r = 0.0,
        .g = 0.0,
        .b = 1.0,
    },
};

test "statically initialized struct" {
    st_init_str_foo.x += 1;
    try expectEqual(st_init_str_foo.x, 14);
}
const StInitStrFoo = struct {
    x: i32,
    y: bool,
};
var st_init_str_foo = StInitStrFoo{
    .x = 13,
    .y = true,
};

test "statically initalized array literal" {
    const y: [4]u8 = st_init_arr_lit_x;
    try expectEqual(y[3], 4);
}
const st_init_arr_lit_x = [_]u8{
    1,
    2,
    3,
    4,
};

test "const slice" {
    comptime {
        const a = "1234567890";
        try expectEqual(a.len, 10);
        const b = a[1..2];
        try expectEqual(b.len, 1);
        try expectEqual(b[0], '2');
    }
}

test "try to trick eval with runtime if" {
    try expectEqual(testTryToTrickEvalWithRuntimeIf(true), 10);
}

fn testTryToTrickEvalWithRuntimeIf(b: bool) usize {
    comptime var i: usize = 0;
    inline while (i < 10) : (i += 1) {
        const result = if (b) false else true;
        _ = result;
    }
    comptime {
        return i;
    }
}

test "inlined loop has array literal with elided runtime scope on first iteration but not second iteration" {
    var runtime = [1]i32{3};
    comptime var i: usize = 0;
    inline while (i < 2) : (i += 1) {
        const result = if (i == 0) [1]i32{2} else runtime;
        _ = result;
    }
    comptime {
        try expectEqual(i, 2);
    }
}

fn max(comptime T: type, a: T, b: T) T {
    if (T == bool) {
        return a or b;
    } else if (a > b) {
        return a;
    } else {
        return b;
    }
}
fn letsTryToCompareBools(a: bool, b: bool) bool {
    return max(bool, a, b);
}
test "inlined block and runtime block phi" {
    try expect(letsTryToCompareBools(true, true));
    try expect(letsTryToCompareBools(true, false));
    try expect(letsTryToCompareBools(false, true));
    try expect(!letsTryToCompareBools(false, false));

    comptime {
        try expect(letsTryToCompareBools(true, true));
        try expect(letsTryToCompareBools(true, false));
        try expect(letsTryToCompareBools(false, true));
        try expect(!letsTryToCompareBools(false, false));
    }
}

const CmdFn = struct {
    name: []const u8,
    func: fn (i32) i32,
};

const cmd_fns = [_]CmdFn{
    CmdFn{
        .name = "one",
        .func = one,
    },
    CmdFn{
        .name = "two",
        .func = two,
    },
    CmdFn{
        .name = "three",
        .func = three,
    },
};
fn one(value: i32) i32 {
    return value + 1;
}
fn two(value: i32) i32 {
    return value + 2;
}
fn three(value: i32) i32 {
    return value + 3;
}

fn performFn(comptime prefix_char: u8, start_value: i32) i32 {
    var result: i32 = start_value;
    comptime var i = 0;
    inline while (i < cmd_fns.len) : (i += 1) {
        if (cmd_fns[i].name[0] == prefix_char) {
            result = cmd_fns[i].func(result);
        }
    }
    return result;
}

test "comptime iterate over fn ptr list" {
    try expectEqual(performFn('t', 1), 6);
    try expectEqual(performFn('o', 0), 1);
    try expectEqual(performFn('w', 99), 99);
}

test "eval @setRuntimeSafety at compile-time" {
    const result = comptime fnWithSetRuntimeSafety();
    try expectEqual(result, 1234);
}

fn fnWithSetRuntimeSafety() i32 {
    @setRuntimeSafety(true);
    return 1234;
}

test "eval @setFloatMode at compile-time" {
    const result = comptime fnWithFloatMode();
    try expectEqual(result, 1234.0);
}

fn fnWithFloatMode() f32 {
    @setFloatMode(std.builtin.FloatMode.Strict);
    return 1234.0;
}

const SimpleStruct = struct {
    field: i32,

    fn method(self: *const SimpleStruct) i32 {
        return self.field + 3;
    }
};

var simple_struct = SimpleStruct{ .field = 1234 };

const bound_fn = simple_struct.method;

test "call method on bound fn referring to var instance" {
    try expectEqual(bound_fn(), 1237);
}

test "ptr to local array argument at comptime" {
    comptime {
        var bytes: [10]u8 = undefined;
        modifySomeBytes(bytes[0..]);
        try expectEqual(bytes[0], 'a');
        try expectEqual(bytes[9], 'b');
    }
}

fn modifySomeBytes(bytes: []u8) void {
    bytes[0] = 'a';
    bytes[9] = 'b';
}

test "comparisons 0 <= uint and 0 > uint should be comptime" {
    testCompTimeUIntComparisons(1234);
}
fn testCompTimeUIntComparisons(x: u32) void {
    if (!(0 <= x)) {
        @compileError("this condition should be comptime known");
    }
    if (0 > x) {
        @compileError("this condition should be comptime known");
    }
    if (!(x >= 0)) {
        @compileError("this condition should be comptime known");
    }
    if (x < 0) {
        @compileError("this condition should be comptime known");
    }
}

test "const ptr to variable data changes at runtime" {
    try expectEqual(foo_ref.name[0], 'a');
    foo_ref.name = "b";
    try expectEqual(foo_ref.name[0], 'b');
}

const Foo = struct {
    name: []const u8,
};

var foo_contents = Foo{ .name = "a" };
const foo_ref = &foo_contents;

test "create global array with for loop" {
    try expectEqual(global_array[5], 5 * 5);
    try expectEqual(global_array[9], 9 * 9);
}

const global_array = x: {
    var result: [10]usize = undefined;
    for (result) |*item, index| {
        item.* = index * index;
    }
    break :x result;
};

test "compile-time downcast when the bits fit" {
    comptime {
        const spartan_count: u16 = 255;
        const byte = @intCast(u8, spartan_count);
        try expectEqual(byte, 255);
    }
}

const hi1 = "hi";
const hi2 = hi1;
test "const global shares pointer with other same one" {
    try assertEqualPtrs(&hi1[0], &hi2[0]);
    comptime try expectEqual(&hi1[0], &hi2[0]);
}
fn assertEqualPtrs(ptr1: *const u8, ptr2: *const u8) !void {
    try expectEqual(ptr1, ptr2);
}

test "@setEvalBranchQuota" {
    comptime {
        // 1001 for the loop and then 1 more for the expect fn call
        @setEvalBranchQuota(1002);
        var i = 0;
        var sum = 0;
        while (i < 1001) : (i += 1) {
            sum += i;
        }
        try expectEqual(sum, 500500);
    }
}

test "float literal at compile time not lossy" {
    try expectEqual(16777216.0 + 1.0, 16777217.0);
    try expectEqual(9007199254740992.0 + 1.0, 9007199254740993.0);
}

test "f32 at compile time is lossy" {
    try expectEqual(@as(f32, 1 << 24) + 1, 1 << 24);
}

test "f64 at compile time is lossy" {
    try expectEqual(@as(f64, 1 << 53) + 1, 1 << 53);
}

test "f128 at compile time is lossy" {
    try expectEqual(@as(f128, 10384593717069655257060992658440192.0) + 1, 10384593717069655257060992658440192.0);
}

test {
    comptime try expectEqual(@as(f128, 1 << 113), 10384593717069655257060992658440192);
}

pub fn TypeWithCompTimeSlice(comptime field_name: []const u8) type {
    _ = field_name;
    return struct {
        pub const Node = struct {};
    };
}

test "string literal used as comptime slice is memoized" {
    const a = "link";
    const b = "link";
    comptime try expectEqual(TypeWithCompTimeSlice(a).Node, TypeWithCompTimeSlice(b).Node);
    comptime try expectEqual(TypeWithCompTimeSlice("link").Node, TypeWithCompTimeSlice("link").Node);
}

test "comptime slice of undefined pointer of length 0" {
    const slice1 = @as([*]i32, undefined)[0..0];
    try expectEqual(slice1.len, 0);
    const slice2 = @as([*]i32, undefined)[100..100];
    try expectEqual(slice2.len, 0);
}

fn copyWithPartialInline(s: []u32, b: []u8) void {
    comptime var i: usize = 0;
    inline while (i < 4) : (i += 1) {
        s[i] = 0;
        s[i] |= @as(u32, b[i * 4 + 0]) << 24;
        s[i] |= @as(u32, b[i * 4 + 1]) << 16;
        s[i] |= @as(u32, b[i * 4 + 2]) << 8;
        s[i] |= @as(u32, b[i * 4 + 3]) << 0;
    }
}

test "binary math operator in partially inlined function" {
    var s: [4]u32 = undefined;
    var b: [16]u8 = undefined;

    for (b) |*r, i|
        r.* = @intCast(u8, i + 1);

    copyWithPartialInline(s[0..], b[0..]);
    try expectEqual(s[0], 0x1020304);
    try expectEqual(s[1], 0x5060708);
    try expectEqual(s[2], 0x90a0b0c);
    try expectEqual(s[3], 0xd0e0f10);
}

test "comptime function with the same args is memoized" {
    comptime {
        try expectEqual(MakeType(i32), MakeType(i32));
        try expect(MakeType(i32) != MakeType(f64));
    }
}

fn MakeType(comptime T: type) type {
    return struct {
        field: T,
    };
}

test "comptime function with mutable pointer is not memoized" {
    comptime {
        var x: i32 = 1;
        const ptr = &x;
        increment(ptr);
        increment(ptr);
        try expectEqual(x, 3);
    }
}

fn increment(value: *i32) void {
    value.* += 1;
}

fn generateTable(comptime T: type) [1010]T {
    var res: [1010]T = undefined;
    var i: usize = 0;
    while (i < 1010) : (i += 1) {
        res[i] = @intCast(T, i);
    }
    return res;
}

fn doesAlotT(comptime T: type, value: usize) T {
    @setEvalBranchQuota(5000);
    const table = comptime blk: {
        break :blk generateTable(T);
    };
    return table[value];
}

test "@setEvalBranchQuota at same scope as generic function call" {
    try expectEqual(doesAlotT(u32, 2), 2);
}

test "comptime slice of slice preserves comptime var" {
    comptime {
        var buff: [10]u8 = undefined;
        buff[0..][0..][0] = 1;
        try expectEqual(buff[0..][0..][0], 1);
    }
}

test "comptime slice of pointer preserves comptime var" {
    comptime {
        var buff: [10]u8 = undefined;
        var a = @ptrCast([*]u8, &buff);
        a[0..1][0] = 1;
        try expectEqual(buff[0..][0..][0], 1);
    }
}

const SingleFieldStruct = struct {
    x: i32,

    fn read_x(self: *const SingleFieldStruct) i32 {
        return self.x;
    }
};
test "const ptr to comptime mutable data is not memoized" {
    comptime {
        var foo = SingleFieldStruct{ .x = 1 };
        try expectEqual(foo.read_x(), 1);
        foo.x = 2;
        try expectEqual(foo.read_x(), 2);
    }
}

test "array concat of slices gives slice" {
    comptime {
        var a: []const u8 = "aoeu";
        var b: []const u8 = "asdf";
        const c = a ++ b;
        try expect(std.mem.eql(u8, c, "aoeuasdf"));
    }
}

test "comptime shlWithOverflow" {
    const ct_shifted: u64 = comptime amt: {
        var amt = @as(u64, 0);
        _ = @shlWithOverflow(u64, ~@as(u64, 0), 16, &amt);
        break :amt amt;
    };

    const rt_shifted: u64 = amt: {
        var amt = @as(u64, 0);
        _ = @shlWithOverflow(u64, ~@as(u64, 0), 16, &amt);
        break :amt amt;
    };

    try expectEqual(ct_shifted, rt_shifted);
}

test "comptime shl" {
    var a: u128 = 3;
    var b: u7 = 63;
    var c: u128 = 3 << 63;
    try expectEqual(a << b, c);
}

test "runtime 128 bit integer division" {
    var a: u128 = 152313999999999991610955792383;
    var b: u128 = 10000000000000000000;
    var c = a / b;
    try expectEqual(c, 15231399999);
}

pub const Info = struct {
    version: u8,
};

pub const diamond_info = Info{ .version = 0 };

test "comptime modification of const struct field" {
    comptime {
        var res = diamond_info;
        res.version = 1;
        try expectEqual(diamond_info.version, 0);
        try expectEqual(res.version, 1);
    }
}

test "pointer to type" {
    comptime {
        var T: type = i32;
        try expectEqual(T, i32);
        var ptr = &T;
        try expectEqual(@TypeOf(ptr), *type);
        ptr.* = f32;
        try expectEqual(T, f32);
        try expectEqual(*T, *f32);
    }
}

test "slice of type" {
    comptime {
        var types_array = [_]type{ i32, f64, type };
        for (types_array) |T, i| {
            switch (i) {
                0 => try expectEqual(T, i32),
                1 => try expectEqual(T, f64),
                2 => try expectEqual(T, type),
                else => unreachable,
            }
        }
        for (types_array[0..]) |T, i| {
            switch (i) {
                0 => try expectEqual(T, i32),
                1 => try expectEqual(T, f64),
                2 => try expectEqual(T, type),
                else => unreachable,
            }
        }
    }
}

const Wrapper = struct {
    T: type,
};

fn wrap(comptime T: type) Wrapper {
    return Wrapper{ .T = T };
}

test "function which returns struct with type field causes implicit comptime" {
    const ty = wrap(i32).T;
    try expectEqual(ty, i32);
}

test "call method with comptime pass-by-non-copying-value self parameter" {
    const S = struct {
        a: u8,

        fn b(comptime s: @This()) u8 {
            return s.a;
        }
    };

    const s = S{ .a = 2 };
    var b = s.b();
    try expectEqual(b, 2);
}

test "@tagName of @typeInfo" {
    const str = @tagName(@typeInfo(u8));
    try expect(std.mem.eql(u8, str, "Int"));
}

test "setting backward branch quota just before a generic fn call" {
    @setEvalBranchQuota(1001);
    loopNTimes(1001);
}

fn loopNTimes(comptime n: usize) void {
    comptime var i = 0;
    inline while (i < n) : (i += 1) {}
}

test "variable inside inline loop that has different types on different iterations" {
    try testVarInsideInlineLoop(.{ true, @as(u32, 42) });
}

fn testVarInsideInlineLoop(args: anytype) !void {
    comptime var i = 0;
    inline while (i < args.len) : (i += 1) {
        const x = args[i];
        if (i == 0) try expect(x);
        if (i == 1) try expectEqual(x, 42);
    }
}

test "inline for with same type but different values" {
    var res: usize = 0;
    inline for ([_]type{ [2]u8, [1]u8, [2]u8 }) |T| {
        var a: T = undefined;
        res += a.len;
    }
    try expectEqual(res, 5);
}

test "refer to the type of a generic function" {
    const Func = fn (type) void;
    const f: Func = doNothingWithType;
    f(i32);
}

fn doNothingWithType(comptime T: type) void {
    _ = T;
}

test "zero extend from u0 to u1" {
    var zero_u0: u0 = 0;
    var zero_u1: u1 = zero_u0;
    try expectEqual(zero_u1, 0);
}

test "bit shift a u1" {
    var x: u1 = 1;
    var y = x << 0;
    try expectEqual(y, 1);
}

test "comptime pointer cast array and then slice" {
    const array = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };

    const ptrA: [*]const u8 = @ptrCast([*]const u8, &array);
    const sliceA: []const u8 = ptrA[0..2];

    const ptrB: [*]const u8 = &array;
    const sliceB: []const u8 = ptrB[0..2];

    try expectEqual(sliceA[1], 2);
    try expectEqual(sliceB[1], 2);
}

test "slice bounds in comptime concatenation" {
    const bs = comptime blk: {
        const b = "........1........";
        break :blk b[8..9];
    };
    const str = "" ++ bs;
    try expectEqual(str.len, 1);
    try expect(std.mem.eql(u8, str, "1"));

    const str2 = bs ++ "";
    try expectEqual(str2.len, 1);
    try expect(std.mem.eql(u8, str2, "1"));
}

test "comptime bitwise operators" {
    comptime {
        try expectEqual(3 & 1, 1);
        try expectEqual(3 & -1, 3);
        try expectEqual(-3 & -1, -3);
        try expectEqual(3 | -1, -1);
        try expectEqual(-3 | -1, -1);
        try expectEqual(3 ^ -1, -4);
        try expectEqual(-3 ^ -1, 2);
        try expectEqual(~@as(i8, -1), 0);
        try expectEqual(~@as(i128, -1), 0);
        try expectEqual(18446744073709551615 & 18446744073709551611, 18446744073709551611);
        try expectEqual(-18446744073709551615 & -18446744073709551611, -18446744073709551615);
        try expectEqual(~@as(u128, 0), 0xffffffffffffffffffffffffffffffff);
    }
}

test "*align(1) u16 is the same as *align(1:0:2) u16" {
    comptime {
        try expectEqual(*align(1:0:2) u16, *align(1) u16);
        try expectEqual(*align(2:0:2) u16, *u16);
    }
}

test "array concatenation forces comptime" {
    var a = oneItem(3) ++ oneItem(4);
    try expect(std.mem.eql(i32, &a, &[_]i32{ 3, 4 }));
}

test "array multiplication forces comptime" {
    var a = oneItem(3) ** scalar(2);
    try expect(std.mem.eql(i32, &a, &[_]i32{ 3, 3 }));
}

fn oneItem(x: i32) [1]i32 {
    return [_]i32{x};
}

fn scalar(x: u32) u32 {
    return x;
}

test "no undeclared identifier error in unanalyzed branches" {
    if (false) {
        lol_this_doesnt_exist = nonsense;
    }
}

test "comptime assign int to optional int" {
    comptime {
        var x: ?i32 = null;
        x = 2;
        x.? *= 10;
        try expectEqual(20, x.?);
    }
}

test "return 0 from function that has u0 return type" {
    const S = struct {
        fn foo_zero() u0 {
            return 0;
        }
    };
    comptime {
        if (S.foo_zero() != 0) {
            @compileError("test failed");
        }
    }
}

test "two comptime calls with array default initialized to undefined" {
    const S = struct {
        const CrossTarget = struct {
            dynamic_linker: DynamicLinker = DynamicLinker{},

            pub fn parse() void {
                var result: CrossTarget = .{};
                result.getCpuArch();
            }

            pub fn getCpuArch(self: CrossTarget) void {
                _ = self;
            }
        };

        const DynamicLinker = struct {
            buffer: [255]u8 = undefined,
        };
    };

    comptime {
        S.CrossTarget.parse();
        S.CrossTarget.parse();
    }
}
