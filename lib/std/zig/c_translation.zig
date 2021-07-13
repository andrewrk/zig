// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.

const std = @import("std");
const testing = std.testing;
const math = std.math;
const mem = std.mem;

/// Given a type and value, cast the value to the type as c would.
pub fn cast(comptime DestType: type, target: anytype) DestType {
    // this function should behave like transCCast in translate-c, except it's for macros
    const SourceType = @TypeOf(target);
    switch (@typeInfo(DestType)) {
        .Fn, .Pointer => return castToPtr(DestType, SourceType, target),
        .Optional => |dest_opt| {
            if (@typeInfo(dest_opt.child) == .Pointer or @typeInfo(dest_opt.child) == .Fn) {
                return castToPtr(DestType, SourceType, target);
            }
        },
        .Int => {
            switch (@typeInfo(SourceType)) {
                .Pointer => {
                    return castInt(DestType, @ptrToInt(target));
                },
                .Optional => |opt| {
                    if (@typeInfo(opt.child) == .Pointer) {
                        return castInt(DestType, @ptrToInt(target));
                    }
                },
                .Int => {
                    return castInt(DestType, target);
                },
                else => {},
            }
        },
        else => {},
    }
    return @as(DestType, target);
}

fn castInt(comptime DestType: type, target: anytype) DestType {
    const dest = @typeInfo(DestType).Int;
    const source = @typeInfo(@TypeOf(target)).Int;

    if (dest.bits < source.bits)
        return @bitCast(DestType, @truncate(std.meta.Int(source.signedness, dest.bits), target))
    else
        return @bitCast(DestType, @as(std.meta.Int(source.signedness, dest.bits), target));
}

fn castPtr(comptime DestType: type, target: anytype) DestType {
    const dest = ptrInfo(DestType);
    const source = ptrInfo(@TypeOf(target));

    if (source.is_const and !dest.is_const or source.is_volatile and !dest.is_volatile)
        return @intToPtr(DestType, @ptrToInt(target))
    else if (@typeInfo(dest.child) == .Opaque)
        // dest.alignment would error out
        return @ptrCast(DestType, target)
    else
        return @ptrCast(DestType, @alignCast(dest.alignment, target));
}

fn castToPtr(comptime DestType: type, comptime SourceType: type, target: anytype) DestType {
    switch (@typeInfo(SourceType)) {
        .Int => {
            return @intToPtr(DestType, castInt(usize, target));
        },
        .ComptimeInt => {
            if (target < 0)
                return @intToPtr(DestType, @bitCast(usize, @intCast(isize, target)))
            else
                return @intToPtr(DestType, @intCast(usize, target));
        },
        .Pointer => {
            return castPtr(DestType, target);
        },
        .Optional => |target_opt| {
            if (@typeInfo(target_opt.child) == .Pointer) {
                return castPtr(DestType, target);
            }
        },
        else => {},
    }
    return @as(DestType, target);
}

fn ptrInfo(comptime PtrType: type) std.builtin.TypeInfo.Pointer {
    return switch (@typeInfo(PtrType)) {
        .Optional => |opt_info| @typeInfo(opt_info.child).Pointer,
        .Pointer => |ptr_info| ptr_info,
        else => unreachable,
    };
}

test "cast" {
    var i = @as(i64, 10);

    try testing.expect(cast(*u8, 16) == @intToPtr(*u8, 16));
    try testing.expect(cast(*u64, &i).* == @as(u64, 10));
    try testing.expect(cast(*i64, @as(?*align(1) i64, &i)) == &i);

    try testing.expect(cast(?*u8, 2) == @intToPtr(*u8, 2));
    try testing.expect(cast(?*i64, @as(*align(1) i64, &i)) == &i);
    try testing.expect(cast(?*i64, @as(?*align(1) i64, &i)) == &i);

    try testing.expectEqual(@as(u32, 4), cast(u32, @intToPtr(*u32, 4)));
    try testing.expectEqual(@as(u32, 4), cast(u32, @intToPtr(?*u32, 4)));
    try testing.expectEqual(@as(u32, 10), cast(u32, @as(u64, 10)));

    try testing.expectEqual(@bitCast(i32, @as(u32, 0x8000_0000)), cast(i32, @as(u32, 0x8000_0000)));

    try testing.expectEqual(@intToPtr(*u8, 2), cast(*u8, @intToPtr(*const u8, 2)));
    try testing.expectEqual(@intToPtr(*u8, 2), cast(*u8, @intToPtr(*volatile u8, 2)));

    try testing.expectEqual(@intToPtr(?*c_void, 2), cast(?*c_void, @intToPtr(*u8, 2)));

    var foo: c_int = -1;
    try testing.expect(cast(*c_void, -1) == @intToPtr(*c_void, @bitCast(usize, @as(isize, -1))));
    try testing.expect(cast(*c_void, foo) == @intToPtr(*c_void, @bitCast(usize, @as(isize, -1))));
    try testing.expect(cast(?*c_void, -1) == @intToPtr(?*c_void, @bitCast(usize, @as(isize, -1))));
    try testing.expect(cast(?*c_void, foo) == @intToPtr(?*c_void, @bitCast(usize, @as(isize, -1))));

    const FnPtr = ?fn (*c_void) void;
    try testing.expect(cast(FnPtr, 0) == @intToPtr(FnPtr, @as(usize, 0)));
    try testing.expect(cast(FnPtr, foo) == @intToPtr(FnPtr, @bitCast(usize, @as(isize, -1))));
}

/// Given a value returns its size as C's sizeof operator would.
pub fn sizeof(target: anytype) usize {
    const T: type = if (@TypeOf(target) == type) target else @TypeOf(target);
    switch (@typeInfo(T)) {
        .Float, .Int, .Struct, .Union, .Array, .Bool, .Vector => return @sizeOf(T),
        .Fn => {
            // sizeof(main) returns 1, sizeof(&main) returns pointer size.
            // We cannot distinguish those types in Zig, so use pointer size.
            return @sizeOf(T);
        },
        .Null => return @sizeOf(*c_void),
        .Void => {
            // Note: sizeof(void) is 1 on clang/gcc and 0 on MSVC.
            return 1;
        },
        .Opaque => {
            if (T == c_void) {
                // Note: sizeof(void) is 1 on clang/gcc and 0 on MSVC.
                return 1;
            } else {
                @compileError("Cannot use C sizeof on opaque type " ++ @typeName(T));
            }
        },
        .Optional => |opt| {
            if (@typeInfo(opt.child) == .Pointer) {
                return sizeof(opt.child);
            } else {
                @compileError("Cannot use C sizeof on non-pointer optional " ++ @typeName(T));
            }
        },
        .Pointer => |ptr| {
            if (ptr.size == .Slice) {
                @compileError("Cannot use C sizeof on slice type " ++ @typeName(T));
            }
            // for strings, sizeof("a") returns 2.
            // normal pointer decay scenarios from C are handled
            // in the .Array case above, but strings remain literals
            // and are therefore always pointers, so they need to be
            // specially handled here.
            if (ptr.size == .One and ptr.is_const and @typeInfo(ptr.child) == .Array) {
                const array_info = @typeInfo(ptr.child).Array;
                if ((array_info.child == u8 or array_info.child == u16) and
                    array_info.sentinel != null and
                    array_info.sentinel.? == 0)
                {
                    // length of the string plus one for the null terminator.
                    return (array_info.len + 1) * @sizeOf(array_info.child);
                }
            }
            // When zero sized pointers are removed, this case will no
            // longer be reachable and can be deleted.
            if (@sizeOf(T) == 0) {
                return @sizeOf(*c_void);
            }
            return @sizeOf(T);
        },
        .ComptimeFloat => return @sizeOf(f64), // TODO c_double #3999
        .ComptimeInt => {
            // TODO to get the correct result we have to translate
            // `1073741824 * 4` as `int(1073741824) *% int(4)` since
            // sizeof(1073741824 * 4) != sizeof(4294967296).

            // TODO test if target fits in int, long or long long
            return @sizeOf(c_int);
        },
        else => @compileError("std.meta.sizeof does not support type " ++ @typeName(T)),
    }
}

test "sizeof" {
    const S = extern struct { a: u32 };

    const ptr_size = @sizeOf(*c_void);

    try testing.expect(sizeof(u32) == 4);
    try testing.expect(sizeof(@as(u32, 2)) == 4);
    try testing.expect(sizeof(2) == @sizeOf(c_int));

    try testing.expect(sizeof(2.0) == @sizeOf(f64));

    try testing.expect(sizeof(S) == 4);

    try testing.expect(sizeof([_]u32{ 4, 5, 6 }) == 12);
    try testing.expect(sizeof([3]u32) == 12);
    try testing.expect(sizeof([3:0]u32) == 16);
    try testing.expect(sizeof(&[_]u32{ 4, 5, 6 }) == ptr_size);

    try testing.expect(sizeof(*u32) == ptr_size);
    try testing.expect(sizeof([*]u32) == ptr_size);
    try testing.expect(sizeof([*c]u32) == ptr_size);
    try testing.expect(sizeof(?*u32) == ptr_size);
    try testing.expect(sizeof(?[*]u32) == ptr_size);
    try testing.expect(sizeof(*c_void) == ptr_size);
    try testing.expect(sizeof(*void) == ptr_size);
    try testing.expect(sizeof(null) == ptr_size);

    try testing.expect(sizeof("foobar") == 7);
    try testing.expect(sizeof(&[_:0]u16{ 'f', 'o', 'o', 'b', 'a', 'r' }) == 14);
    try testing.expect(sizeof(*const [4:0]u8) == 5);
    try testing.expect(sizeof(*[4:0]u8) == ptr_size);
    try testing.expect(sizeof([*]const [4:0]u8) == ptr_size);
    try testing.expect(sizeof(*const *const [4:0]u8) == ptr_size);
    try testing.expect(sizeof(*const [4]u8) == ptr_size);

    try testing.expect(sizeof(sizeof) == @sizeOf(@TypeOf(sizeof)));

    try testing.expect(sizeof(void) == 1);
    try testing.expect(sizeof(c_void) == 1);
}

pub const CIntLiteralRadix = enum { decimal, octal, hexadecimal };

fn PromoteIntLiteralReturnType(comptime SuffixType: type, comptime number: comptime_int, comptime radix: CIntLiteralRadix) type {
    const signed_decimal = [_]type{ c_int, c_long, c_longlong };
    const signed_oct_hex = [_]type{ c_int, c_uint, c_long, c_ulong, c_longlong, c_ulonglong };
    const unsigned = [_]type{ c_uint, c_ulong, c_ulonglong };

    const list: []const type = if (@typeInfo(SuffixType).Int.signedness == .unsigned)
        &unsigned
    else if (radix == .decimal)
        &signed_decimal
    else
        &signed_oct_hex;

    var pos = mem.indexOfScalar(type, list, SuffixType).?;

    while (pos < list.len) : (pos += 1) {
        if (number >= math.minInt(list[pos]) and number <= math.maxInt(list[pos])) {
            return list[pos];
        }
    }
    @compileError("Integer literal is too large");
}

/// Promote the type of an integer literal until it fits as C would.
pub fn promoteIntLiteral(
    comptime SuffixType: type,
    comptime number: comptime_int,
    comptime radix: CIntLiteralRadix,
) PromoteIntLiteralReturnType(SuffixType, number, radix) {
    return number;
}

test "promoteIntLiteral" {
    const signed_hex = promoteIntLiteral(c_int, math.maxInt(c_int) + 1, .hexadecimal);
    try testing.expectEqual(c_uint, @TypeOf(signed_hex));

    if (math.maxInt(c_longlong) == math.maxInt(c_int)) return;

    const signed_decimal = promoteIntLiteral(c_int, math.maxInt(c_int) + 1, .decimal);
    const unsigned = promoteIntLiteral(c_uint, math.maxInt(c_uint) + 1, .hexadecimal);

    if (math.maxInt(c_long) > math.maxInt(c_int)) {
        try testing.expectEqual(c_long, @TypeOf(signed_decimal));
        try testing.expectEqual(c_ulong, @TypeOf(unsigned));
    } else {
        try testing.expectEqual(c_longlong, @TypeOf(signed_decimal));
        try testing.expectEqual(c_ulonglong, @TypeOf(unsigned));
    }
}

/// Convert from clang __builtin_shufflevector index to Zig @shuffle index
/// clang requires __builtin_shufflevector index arguments to be integer constants.
/// negative values for `this_index` indicate "don't care" so we arbitrarily choose 0
/// clang enforces that `this_index` is less than the total number of vector elements
/// See https://ziglang.org/documentation/master/#shuffle
/// See https://clang.llvm.org/docs/LanguageExtensions.html#langext-builtin-shufflevector
pub fn shuffleVectorIndex(comptime this_index: c_int, comptime source_vector_len: usize) i32 {
    if (this_index <= 0) return 0;

    const positive_index = @intCast(usize, this_index);
    if (positive_index < source_vector_len) return @intCast(i32, this_index);
    const b_index = positive_index - source_vector_len;
    return ~@intCast(i32, b_index);
}

test "shuffleVectorIndex" {
    const vector_len: usize = 4;

    try testing.expect(shuffleVectorIndex(-1, vector_len) == 0);

    try testing.expect(shuffleVectorIndex(0, vector_len) == 0);
    try testing.expect(shuffleVectorIndex(1, vector_len) == 1);
    try testing.expect(shuffleVectorIndex(2, vector_len) == 2);
    try testing.expect(shuffleVectorIndex(3, vector_len) == 3);

    try testing.expect(shuffleVectorIndex(4, vector_len) == -1);
    try testing.expect(shuffleVectorIndex(5, vector_len) == -2);
    try testing.expect(shuffleVectorIndex(6, vector_len) == -3);
    try testing.expect(shuffleVectorIndex(7, vector_len) == -4);
}

/// Constructs a [*c] pointer with the const and volatile annotations
/// from SelfType for pointing to a C flexible array of ElementType.
pub fn FlexibleArrayType(comptime SelfType: type, ElementType: type) type {
    switch (@typeInfo(SelfType)) {
        .Pointer => |ptr| {
            return @Type(.{ .Pointer = .{
                .size = .C,
                .is_const = ptr.is_const,
                .is_volatile = ptr.is_volatile,
                .alignment = @alignOf(ElementType),
                .child = ElementType,
                .is_allowzero = true,
                .sentinel = null,
            } });
        },
        else => |info| @compileError("Invalid self type \"" ++ @tagName(info) ++ "\" for flexible array getter: " ++ @typeName(SelfType)),
    }
}

test "Flexible Array Type" {
    const Container = extern struct {
        size: usize,
    };

    try testing.expectEqual(FlexibleArrayType(*Container, c_int), [*c]c_int);
    try testing.expectEqual(FlexibleArrayType(*const Container, c_int), [*c]const c_int);
    try testing.expectEqual(FlexibleArrayType(*volatile Container, c_int), [*c]volatile c_int);
    try testing.expectEqual(FlexibleArrayType(*const volatile Container, c_int), [*c]const volatile c_int);
}

pub const Macros = struct {
    pub fn U_SUFFIX(comptime n: comptime_int) @TypeOf(promoteIntLiteral(c_uint, n, .decimal)) {
        return promoteIntLiteral(c_uint, n, .decimal);
    }

    fn L_SUFFIX_ReturnType(comptime number: anytype) type {
        switch (@TypeOf(number)) {
            comptime_int => return @TypeOf(promoteIntLiteral(c_long, number, .decimal)),
            comptime_float => return c_longdouble,
            else => @compileError("Invalid value for L suffix"),
        }
    }
    pub fn L_SUFFIX(comptime number: anytype) L_SUFFIX_ReturnType(number) {
        switch (@TypeOf(number)) {
            comptime_int => return promoteIntLiteral(c_long, number, .decimal),
            comptime_float => @compileError("TODO: c_longdouble initialization from comptime_float not supported"),
            else => @compileError("Invalid value for L suffix"),
        }
    }

    pub fn UL_SUFFIX(comptime n: comptime_int) @TypeOf(promoteIntLiteral(c_ulong, n, .decimal)) {
        return promoteIntLiteral(c_ulong, n, .decimal);
    }

    pub fn LL_SUFFIX(comptime n: comptime_int) @TypeOf(promoteIntLiteral(c_longlong, n, .decimal)) {
        return promoteIntLiteral(c_longlong, n, .decimal);
    }

    pub fn ULL_SUFFIX(comptime n: comptime_int) @TypeOf(promoteIntLiteral(c_ulonglong, n, .decimal)) {
        return promoteIntLiteral(c_ulonglong, n, .decimal);
    }

    pub fn F_SUFFIX(comptime f: comptime_float) f32 {
        return @as(f32, f);
    }

    pub fn WL_CONTAINER_OF(ptr: anytype, sample: anytype, comptime member: []const u8) @TypeOf(sample) {
        return @fieldParentPtr(@TypeOf(sample.*), member, ptr);
    }
};

test "Macro suffix functions" {
    try testing.expect(@TypeOf(Macros.F_SUFFIX(1)) == f32);

    try testing.expect(@TypeOf(Macros.U_SUFFIX(1)) == c_uint);
    if (math.maxInt(c_ulong) > math.maxInt(c_uint)) {
        try testing.expect(@TypeOf(Macros.U_SUFFIX(math.maxInt(c_uint) + 1)) == c_ulong);
    }
    if (math.maxInt(c_ulonglong) > math.maxInt(c_ulong)) {
        try testing.expect(@TypeOf(Macros.U_SUFFIX(math.maxInt(c_ulong) + 1)) == c_ulonglong);
    }

    try testing.expect(@TypeOf(Macros.L_SUFFIX(1)) == c_long);
    if (math.maxInt(c_long) > math.maxInt(c_int)) {
        try testing.expect(@TypeOf(Macros.L_SUFFIX(math.maxInt(c_int) + 1)) == c_long);
    }
    if (math.maxInt(c_longlong) > math.maxInt(c_long)) {
        try testing.expect(@TypeOf(Macros.L_SUFFIX(math.maxInt(c_long) + 1)) == c_longlong);
    }

    try testing.expect(@TypeOf(Macros.UL_SUFFIX(1)) == c_ulong);
    if (math.maxInt(c_ulonglong) > math.maxInt(c_ulong)) {
        try testing.expect(@TypeOf(Macros.UL_SUFFIX(math.maxInt(c_ulong) + 1)) == c_ulonglong);
    }

    try testing.expect(@TypeOf(Macros.LL_SUFFIX(1)) == c_longlong);
    try testing.expect(@TypeOf(Macros.ULL_SUFFIX(1)) == c_ulonglong);
}

test "WL_CONTAINER_OF" {
    const S = struct {
        a: u32 = 0,
        b: u32 = 0,
    };
    var x = S{};
    var y = S{};
    var ptr = Macros.WL_CONTAINER_OF(&x.b, &y, "b");
    try testing.expectEqual(&x, ptr);
}
