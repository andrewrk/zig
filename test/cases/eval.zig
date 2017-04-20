const assert = @import("std").debug.assert;

test "compileTimeRecursion" {
    assert(some_data.len == 21);
}
var some_data: [usize(fibonacci(7))]u8 = undefined;
fn fibonacci(x: i32) -> i32 {
    if (x <= 1) return 1;
    return fibonacci(x - 1) + fibonacci(x - 2);
}



fn unwrapAndAddOne(blah: ?i32) -> i32 {
    return ??blah + 1;
}
const should_be_1235 = unwrapAndAddOne(1234);
test "testStaticAddOne" {
    assert(should_be_1235 == 1235);
}

test "inlinedLoop" {
    comptime var i = 0;
    comptime var sum = 0;
    inline while (i <= 5; i += 1)
        sum += i;
    assert(sum == 15);
}

fn gimme1or2(comptime a: bool) -> i32 {
    const x: i32 = 1;
    const y: i32 = 2;
    comptime var z: i32 = if (a) x else y;
    return z;
}
test "inlineVariableGetsResultOfConstIf" {
    assert(gimme1or2(true) == 1);
    assert(gimme1or2(false) == 2);
}


test "staticFunctionEvaluation" {
    assert(statically_added_number == 3);
}
const statically_added_number = staticAdd(1, 2);
fn staticAdd(a: i32, b: i32) -> i32 { a + b }


test "constExprEvalOnSingleExprBlocks" {
    assert(constExprEvalOnSingleExprBlocksFn(1, true) == 3);
}

fn constExprEvalOnSingleExprBlocksFn(x: i32, b: bool) -> i32 {
    const literal = 3;

    const result = if (b) {
        literal
    } else {
        x
    };

    return result;
}




test "staticallyInitalizedList" {
    assert(static_point_list[0].x == 1);
    assert(static_point_list[0].y == 2);
    assert(static_point_list[1].x == 3);
    assert(static_point_list[1].y == 4);
}
const Point = struct {
    x: i32,
    y: i32,
};
const static_point_list = []Point { makePoint(1, 2), makePoint(3, 4) };
fn makePoint(x: i32, y: i32) -> Point {
    return Point {
        .x = x,
        .y = y,
    };
}


test "staticEvalListInit" {
    assert(static_vec3.data[2] == 1.0);
    assert(vec3(0.0, 0.0, 3.0).data[2] == 3.0);
}
const static_vec3 = vec3(0.0, 0.0, 1.0);
pub const Vec3 = struct {
    data: [3]f32,
};
pub fn vec3(x: f32, y: f32, z: f32) -> Vec3 {
    Vec3 {
        .data = []f32 { x, y, z, },
    }
}


test "constantExpressions" {
    var array : [array_size]u8 = undefined;
    assert(@sizeOf(@typeOf(array)) == 20);
}
const array_size : u8 = 20;


test "constantStructWithNegation" {
    assert(vertices[0].x == -0.6);
}
const Vertex = struct {
    x: f32,
    y: f32,
    r: f32,
    g: f32,
    b: f32,
};
const vertices = []Vertex {
    Vertex { .x = -0.6, .y = -0.4, .r = 1.0, .g = 0.0, .b = 0.0 },
    Vertex { .x =  0.6, .y = -0.4, .r = 0.0, .g = 1.0, .b = 0.0 },
    Vertex { .x =  0.0, .y =  0.6, .r = 0.0, .g = 0.0, .b = 1.0 },
};


test "staticallyInitalizedStruct" {
    st_init_str_foo.x += 1;
    assert(st_init_str_foo.x == 14);
}
const StInitStrFoo = struct {
    x: i32,
    y: bool,
};
var st_init_str_foo = StInitStrFoo { .x = 13, .y = true, };


test "staticallyInitializedArrayLiteral" {
    const y : [4]u8 = st_init_arr_lit_x;
    assert(y[3] == 4);
}
const st_init_arr_lit_x = []u8{1,2,3,4};


test "constSlice" {
    comptime {
        const a = "1234567890";
        assert(a.len == 10);
        const b = a[1...2];
        assert(b.len == 1);
        assert(b[0] == '2');
    }
}

test "tryToTrickEvalWithRuntimeIf" {
    assert(testTryToTrickEvalWithRuntimeIf(true) == 10);
}

fn testTryToTrickEvalWithRuntimeIf(b: bool) -> usize {
    comptime var i: usize = 0;
    inline while (i < 10; i += 1) {
        const result = if (b) false else true;
    }
    comptime {
        return i;
    }
}

fn max(comptime T: type, a: T, b: T) -> T {
    if (T == bool) {
        return a or b;
    } else if (a > b) {
        return a;
    } else {
        return b;
    }
}
fn letsTryToCompareBools(a: bool, b: bool) -> bool {
    max(bool, a, b)
}
test "inlinedBlockAndRuntimeBlockPhi" {
    assert(letsTryToCompareBools(true, true));
    assert(letsTryToCompareBools(true, false));
    assert(letsTryToCompareBools(false, true));
    assert(!letsTryToCompareBools(false, false));

    comptime {
        assert(letsTryToCompareBools(true, true));
        assert(letsTryToCompareBools(true, false));
        assert(letsTryToCompareBools(false, true));
        assert(!letsTryToCompareBools(false, false));
    }
}

const CmdFn = struct {
    name: []const u8,
    func: fn(i32) -> i32,
};

const cmd_fns = []CmdFn{
    CmdFn {.name = "one", .func = one},
    CmdFn {.name = "two", .func = two},
    CmdFn {.name = "three", .func = three},
};
fn one(value: i32) -> i32 { value + 1 }
fn two(value: i32) -> i32 { value + 2 }
fn three(value: i32) -> i32 { value + 3 }

fn performFn(comptime prefix_char: u8, start_value: i32) -> i32 {
    var result: i32 = start_value;
    comptime var i = 0;
    inline while (i < cmd_fns.len; i += 1) {
        if (cmd_fns[i].name[0] == prefix_char) {
            result = cmd_fns[i].func(result);
        }
    }
    return result;
}

test "comptimeIterateOverFnPtrList" {
    assert(performFn('t', 1) == 6);
    assert(performFn('o', 0) == 1);
    assert(performFn('w', 99) == 99);
}

test "evalSetDebugSafetyAtCompileTime" {
    const result = comptime fnWithSetDebugSafety();
    assert(result == 1234);
}

fn fnWithSetDebugSafety() -> i32{
    @setDebugSafety(this, true);
    return 1234;
}



const SimpleStruct = struct {
    field: i32,

    fn method(self: &const SimpleStruct) -> i32 {
        return self.field + 3;
    }
};

var simple_struct = SimpleStruct{ .field = 1234, };

const bound_fn = simple_struct.method;

test "callMethodOnBoundFnReferringToVarInstance" {
    assert(bound_fn() == 1237);
}



test "ptrToLocalArrayArgumentAtComptime" {
    comptime {
        var bytes: [10]u8 = undefined;
        modifySomeBytes(bytes[0...]);
        assert(bytes[0] == 'a');
        assert(bytes[9] == 'b');
    }
}

fn modifySomeBytes(bytes: []u8) {
    bytes[0] = 'a';
    bytes[9] = 'b';
}


test "comparisons 0 <= uint and 0 > uint should be comptime" {
    testCompTimeUIntComparisons(1234);
}
fn testCompTimeUIntComparisons(x: u32) {
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
    assert(foo_ref.name[0] == 'a');
    foo_ref.name = "b";
    assert(foo_ref.name[0] == 'b');
}

const Foo = struct {
    name: []const u8,
};

var foo_contents = Foo { .name = "a", };
const foo_ref = &foo_contents;



test "create global array with for loop" {
    assert(global_array[5] == 5 * 5);
    assert(global_array[9] == 9 * 9);
}

const global_array = {
    var result: [10]usize = undefined;
    for (result) |*item, index| {
        *item = index * index;
    }
    result
};
