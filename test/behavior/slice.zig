const std = @import("std");
const expect = std.testing.expect;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectEqual = std.testing.expectEqual;
const mem = std.mem;

const x = @intToPtr([*]i32, 0x1000)[0..0x500];
const y = x[0x100..];
test "compile time slice of pointer to hard coded address" {
    try expectEqual(@ptrToInt(x), 0x1000);
    try expectEqual(x.len, 0x500);

    try expectEqual(@ptrToInt(y), 0x1100);
    try expectEqual(y.len, 0x400);
}

test "runtime safety lets us slice from len..len" {
    var an_array = [_]u8{
        1,
        2,
        3,
    };
    try expect(mem.eql(u8, sliceFromLenToLen(an_array[0..], 3, 3), ""));
}

fn sliceFromLenToLen(a_slice: []u8, start: usize, end: usize) []u8 {
    return a_slice[start..end];
}

test "implicitly cast array of size 0 to slice" {
    var msg = [_]u8{};
    try assertLenIsZero(&msg);
}

fn assertLenIsZero(msg: []const u8) !void {
    try expectEqual(msg.len, 0);
}

test "C pointer" {
    var buf: [*c]const u8 = "kjdhfkjdhfdkjhfkfjhdfkjdhfkdjhfdkjhf";
    var len: u32 = 10;
    var slice = buf[0..len];
    try expectEqualSlices(u8, "kjdhfkjdhf", slice);
}

test "C pointer slice access" {
    var buf: [10]u32 = [1]u32{42} ** 10;
    const c_ptr = @ptrCast([*c]const u32, &buf);

    var runtime_zero: usize = 0;
    comptime try expectEqual([]const u32, @TypeOf(c_ptr[runtime_zero..1]));
    comptime try expectEqual(*const [1]u32, @TypeOf(c_ptr[0..1]));

    for (c_ptr[0..5]) |*cl| {
        try expectEqual(@as(u32, 42), cl.*);
    }
}

fn sliceSum(comptime q: []const u8) i32 {
    comptime var result = 0;
    inline for (q) |item| {
        result += item;
    }
    return result;
}

test "comptime slices are disambiguated" {
    try expectEqual(sliceSum(&[_]u8{ 1, 2 }), 3);
    try expectEqual(sliceSum(&[_]u8{ 3, 4 }), 7);
}

test "slice type with custom alignment" {
    const LazilyResolvedType = struct {
        anything: i32,
    };
    var slice: []align(32) LazilyResolvedType = undefined;
    var array: [10]LazilyResolvedType align(32) = undefined;
    slice = &array;
    slice[1].anything = 42;
    try expectEqual(array[1].anything, 42);
}

test "access len index of sentinel-terminated slice" {
    const S = struct {
        fn doTheTest() !void {
            var slice: [:0]const u8 = "hello";

            try expectEqual(slice.len, 5);
            try expectEqual(slice[5], 0);
        }
    };
    try S.doTheTest();
    comptime try S.doTheTest();
}

test "obtaining a null terminated slice" {
    // here we have a normal array
    var buf: [50]u8 = undefined;

    buf[0] = 'a';
    buf[1] = 'b';
    buf[2] = 'c';
    buf[3] = 0;

    // now we obtain a null terminated slice:
    const ptr = buf[0..3 :0];
    _ = ptr;

    var runtime_len: usize = 3;
    const ptr2 = buf[0..runtime_len :0];
    // ptr2 is a null-terminated slice
    comptime try expectEqual(@TypeOf(ptr2), [:0]u8);
    comptime try expectEqual(@TypeOf(ptr2[0..2]), *[2]u8);
    var runtime_zero: usize = 0;
    comptime try expectEqual(@TypeOf(ptr2[runtime_zero..2]), []u8);
}

test "empty array to slice" {
    const S = struct {
        fn doTheTest() !void {
            const empty: []align(16) u8 = &[_]u8{};
            const align_1: []align(1) u8 = empty;
            const align_4: []align(4) u8 = empty;
            const align_16: []align(16) u8 = empty;
            try expectEqual(1, @typeInfo(@TypeOf(align_1)).Pointer.alignment);
            try expectEqual(4, @typeInfo(@TypeOf(align_4)).Pointer.alignment);
            try expectEqual(16, @typeInfo(@TypeOf(align_16)).Pointer.alignment);
        }
    };

    try S.doTheTest();
    comptime try S.doTheTest();
}

test "@ptrCast slice to pointer" {
    const S = struct {
        fn doTheTest() !void {
            var array align(@alignOf(u16)) = [5]u8{ 0xff, 0xff, 0xff, 0xff, 0xff };
            var slice: []u8 = &array;
            var ptr = @ptrCast(*u16, slice);
            try expectEqual(ptr.*, 65535);
        }
    };

    try S.doTheTest();
    comptime try S.doTheTest();
}

test "slice syntax resulting in pointer-to-array" {
    const S = struct {
        fn doTheTest() !void {
            try testArray();
            try testArrayZ();
            try testArray0();
            try testArrayAlign();
            try testPointer();
            try testPointerZ();
            try testPointer0();
            try testPointerAlign();
            try testSlice();
            try testSliceZ();
            try testSlice0();
            try testSliceOpt();
            try testSliceAlign();
        }

        fn testArray() !void {
            var array = [5]u8{ 1, 2, 3, 4, 5 };
            var slice = array[1..3];
            comptime try expectEqual(@TypeOf(slice), *[2]u8);
            try expectEqual(slice[0], 2);
            try expectEqual(slice[1], 3);
        }

        fn testArrayZ() !void {
            var array = [5:0]u8{ 1, 2, 3, 4, 5 };
            comptime try expectEqual(@TypeOf(array[1..3]), *[2]u8);
            comptime try expectEqual(@TypeOf(array[1..5]), *[4:0]u8);
            comptime try expectEqual(@TypeOf(array[1..]), *[4:0]u8);
            comptime try expectEqual(@TypeOf(array[1..3 :4]), *[2:4]u8);
        }

        fn testArray0() !void {
            {
                var array = [0]u8{};
                var slice = array[0..0];
                comptime try expectEqual(@TypeOf(slice), *[0]u8);
            }
            {
                var array = [0:0]u8{};
                var slice = array[0..0];
                comptime try expectEqual(@TypeOf(slice), *[0:0]u8);
                try expectEqual(slice[0], 0);
            }
        }

        fn testArrayAlign() !void {
            var array align(4) = [5]u8{ 1, 2, 3, 4, 5 };
            var slice = array[4..5];
            comptime try expectEqual(@TypeOf(slice), *align(4) [1]u8);
            try expectEqual(slice[0], 5);
            comptime try expectEqual(@TypeOf(array[0..2]), *align(4) [2]u8);
        }

        fn testPointer() !void {
            var array = [5]u8{ 1, 2, 3, 4, 5 };
            var pointer: [*]u8 = &array;
            var slice = pointer[1..3];
            comptime try expectEqual(@TypeOf(slice), *[2]u8);
            try expectEqual(slice[0], 2);
            try expectEqual(slice[1], 3);
        }

        fn testPointerZ() !void {
            var array = [5:0]u8{ 1, 2, 3, 4, 5 };
            var pointer: [*:0]u8 = &array;
            comptime try expectEqual(@TypeOf(pointer[1..3]), *[2]u8);
            comptime try expectEqual(@TypeOf(pointer[1..3 :4]), *[2:4]u8);
        }

        fn testPointer0() !void {
            var pointer: [*]const u0 = &[1]u0{0};
            var slice = pointer[0..1];
            comptime try expectEqual(@TypeOf(slice), *const [1]u0);
            try expectEqual(slice[0], 0);
        }

        fn testPointerAlign() !void {
            var array align(4) = [5]u8{ 1, 2, 3, 4, 5 };
            var pointer: [*]align(4) u8 = &array;
            var slice = pointer[4..5];
            comptime try expectEqual(@TypeOf(slice), *align(4) [1]u8);
            try expectEqual(slice[0], 5);
            comptime try expectEqual(@TypeOf(pointer[0..2]), *align(4) [2]u8);
        }

        fn testSlice() !void {
            var array = [5]u8{ 1, 2, 3, 4, 5 };
            var src_slice: []u8 = &array;
            var slice = src_slice[1..3];
            comptime try expectEqual(@TypeOf(slice), *[2]u8);
            try expectEqual(slice[0], 2);
            try expectEqual(slice[1], 3);
        }

        fn testSliceZ() !void {
            var array = [5:0]u8{ 1, 2, 3, 4, 5 };
            var slice: [:0]u8 = &array;
            comptime try expectEqual(@TypeOf(slice[1..3]), *[2]u8);
            comptime try expectEqual(@TypeOf(slice[1..]), [:0]u8);
            comptime try expectEqual(@TypeOf(slice[1..3 :4]), *[2:4]u8);
        }

        fn testSliceOpt() !void {
            var array: [2]u8 = [2]u8{ 1, 2 };
            var slice: ?[]u8 = &array;
            comptime try expectEqual(@TypeOf(&array, slice), ?[]u8);
            comptime try expectEqual(@TypeOf(slice.?[0..2]), *[2]u8);
        }

        fn testSlice0() !void {
            {
                var array = [0]u8{};
                var src_slice: []u8 = &array;
                var slice = src_slice[0..0];
                comptime try expectEqual(@TypeOf(slice), *[0]u8);
            }
            {
                var array = [0:0]u8{};
                var src_slice: [:0]u8 = &array;
                var slice = src_slice[0..0];
                comptime try expectEqual(@TypeOf(slice), *[0]u8);
            }
        }

        fn testSliceAlign() !void {
            var array align(4) = [5]u8{ 1, 2, 3, 4, 5 };
            var src_slice: []align(4) u8 = &array;
            var slice = src_slice[4..5];
            comptime try expectEqual(@TypeOf(slice), *align(4) [1]u8);
            try expectEqual(slice[0], 5);
            comptime try expectEqual(@TypeOf(src_slice[0..2]), *align(4) [2]u8);
        }

        fn testConcatStrLiterals() !void {
            try expectEqualSlices("a"[0..] ++ "b"[0..], "ab");
            try expectEqualSlices("a"[0.. :0] ++ "b"[0.. :0], "ab");
        }
    };

    try S.doTheTest();
    comptime try S.doTheTest();
}

test "slice of hardcoded address to pointer" {
    const S = struct {
        fn doTheTest() !void {
            const pointer = @intToPtr([*]u8, 0x04)[0..2];
            comptime try expectEqual(@TypeOf(pointer), *[2]u8);
            const slice: []const u8 = pointer;
            try expectEqual(@ptrToInt(slice.ptr), 4);
            try expectEqual(slice.len, 2);
        }
    };

    try S.doTheTest();
}

test "type coercion of pointer to anon struct literal to pointer to slice" {
    const S = struct {
        const U = union {
            a: u32,
            b: bool,
            c: []const u8,
        };

        fn doTheTest() !void {
            var x1: u8 = 42;
            const t1 = &.{ x1, 56, 54 };
            var slice1: []const u8 = t1;
            try expectEqual(slice1.len, 3);
            try expectEqual(slice1[0], 42);
            try expectEqual(slice1[1], 56);
            try expectEqual(slice1[2], 54);

            var x2: []const u8 = "hello";
            const t2 = &.{ x2, ", ", "world!" };
            // @compileLog(@TypeOf(t2));
            var slice2: []const []const u8 = t2;
            try expectEqual(slice2.len, 3);
            try expect(mem.eql(u8, slice2[0], "hello"));
            try expect(mem.eql(u8, slice2[1], ", "));
            try expect(mem.eql(u8, slice2[2], "world!"));
        }
    };
    // try S.doTheTest();
    comptime try S.doTheTest();
}
