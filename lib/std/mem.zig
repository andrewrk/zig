// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.
const std = @import("std.zig");
const debug = std.debug;
const assert = debug.assert;
const math = std.math;
const mem = @This();
const meta = std.meta;
const trait = meta.trait;
const testing = std.testing;
const Endian = std.builtin.Endian;
const native_endian = std.Target.current.cpu.arch.endian();

/// Compile time known minimum page size.
/// https://github.com/ziglang/zig/issues/4082
pub const page_size = switch (std.Target.current.cpu.arch) {
    .wasm32, .wasm64 => 64 * 1024,
    .aarch64 => switch (std.Target.current.os.tag) {
        .macos, .ios, .watchos, .tvos => 16 * 1024,
        else => 4 * 1024,
    },
    .sparcv9 => 8 * 1024,
    else => 4 * 1024,
};

/// The standard library currently thoroughly depends on byte size
/// being 8 bits.  (see the use of u8 throughout allocation code as
/// the "byte" type.)  Code which depends on this can reference this
/// declaration.  If we ever try to port the standard library to a
/// non-8-bit-byte platform, this will allow us to search for things
/// which need to be updated.
pub const byte_size_in_bits = 8;

pub const Allocator = @import("mem/Allocator.zig");

/// Detects and asserts if the std.mem.Allocator interface is violated by the caller
/// or the allocator.
pub fn ValidationAllocator(comptime T: type) type {
    return struct {
        const Self = @This();
        allocator: Allocator,
        underlying_allocator: T,
        pub fn init(allocator: T) @This() {
            return .{
                .allocator = .{
                    .allocFn = alloc,
                    .resizeFn = resize,
                },
                .underlying_allocator = allocator,
            };
        }
        fn getUnderlyingAllocatorPtr(self: *@This()) *Allocator {
            if (T == *Allocator) return self.underlying_allocator;
            if (*T == *Allocator) return &self.underlying_allocator;
            return &self.underlying_allocator.allocator;
        }
        pub fn alloc(
            allocator: *Allocator,
            n: usize,
            ptr_align: u29,
            len_align: u29,
            ret_addr: usize,
        ) Allocator.Error![]u8 {
            assert(n > 0);
            assert(mem.isValidAlign(ptr_align));
            if (len_align != 0) {
                assert(mem.isAlignedAnyAlign(n, len_align));
                assert(n >= len_align);
            }

            const self = @fieldParentPtr(@This(), "allocator", allocator);
            const underlying = self.getUnderlyingAllocatorPtr();
            const result = try underlying.allocFn(underlying, n, ptr_align, len_align, ret_addr);
            assert(mem.isAligned(@ptrToInt(result.ptr), ptr_align));
            if (len_align == 0) {
                assert(result.len == n);
            } else {
                assert(result.len >= n);
                assert(mem.isAlignedAnyAlign(result.len, len_align));
            }
            return result;
        }
        pub fn resize(
            allocator: *Allocator,
            buf: []u8,
            buf_align: u29,
            new_len: usize,
            len_align: u29,
            ret_addr: usize,
        ) Allocator.Error!usize {
            assert(buf.len > 0);
            if (len_align != 0) {
                assert(mem.isAlignedAnyAlign(new_len, len_align));
                assert(new_len >= len_align);
            }
            const self = @fieldParentPtr(@This(), "allocator", allocator);
            const underlying = self.getUnderlyingAllocatorPtr();
            const result = try underlying.resizeFn(underlying, buf, buf_align, new_len, len_align, ret_addr);
            if (len_align == 0) {
                assert(result == new_len);
            } else {
                assert(result >= new_len);
                assert(mem.isAlignedAnyAlign(result, len_align));
            }
            return result;
        }
        pub usingnamespace if (T == *Allocator or !@hasDecl(T, "reset")) struct {} else struct {
            pub fn reset(self: *Self) void {
                self.underlying_allocator.reset();
            }
        };
    };
}

pub fn validationWrap(allocator: anytype) ValidationAllocator(@TypeOf(allocator)) {
    return ValidationAllocator(@TypeOf(allocator)).init(allocator);
}

/// An allocator helper function.  Adjusts an allocation length satisfy `len_align`.
/// `full_len` should be the full capacity of the allocation which may be greater
/// than the `len` that was requsted.  This function should only be used by allocators
/// that are unaffected by `len_align`.
pub fn alignAllocLen(full_len: usize, alloc_len: usize, len_align: u29) usize {
    assert(alloc_len > 0);
    assert(alloc_len >= len_align);
    assert(full_len >= alloc_len);
    if (len_align == 0)
        return alloc_len;
    const adjusted = alignBackwardAnyAlign(full_len, len_align);
    assert(adjusted >= alloc_len);
    return adjusted;
}

var failAllocator = Allocator{
    .allocFn = failAllocatorAlloc,
    .resizeFn = Allocator.noResize,
};
fn failAllocatorAlloc(self: *Allocator, n: usize, alignment: u29, len_align: u29, ra: usize) Allocator.Error![]u8 {
    _ = self;
    _ = n;
    _ = alignment;
    _ = len_align;
    _ = ra;
    return error.OutOfMemory;
}

test "mem.Allocator basics" {
    try testing.expectError(error.OutOfMemory, failAllocator.alloc(u8, 1));
    try testing.expectError(error.OutOfMemory, failAllocator.allocSentinel(u8, 1, 0));
}

/// Copy all of source into dest at position 0.
/// dest.len must be >= source.len.
/// If the slices overlap, dest.ptr must be <= src.ptr.
pub fn copy(comptime T: type, dest: []T, source: []const T) void {
    // TODO instead of manually doing this check for the whole array
    // and turning off runtime safety, the compiler should detect loops like
    // this and automatically omit safety checks for loops
    @setRuntimeSafety(false);
    assert(dest.len >= source.len);
    for (source) |s, i|
        dest[i] = s;
}

/// Copy all of source into dest at position 0.
/// dest.len must be >= source.len.
/// If the slices overlap, dest.ptr must be >= src.ptr.
pub fn copyBackwards(comptime T: type, dest: []T, source: []const T) void {
    // TODO instead of manually doing this check for the whole array
    // and turning off runtime safety, the compiler should detect loops like
    // this and automatically omit safety checks for loops
    @setRuntimeSafety(false);
    assert(dest.len >= source.len);
    var i = source.len;
    while (i > 0) {
        i -= 1;
        dest[i] = source[i];
    }
}

/// Sets all elements of `dest` to `value`.
pub fn set(comptime T: type, dest: []T, value: T) void {
    for (dest) |*d|
        d.* = value;
}

/// Generally, Zig users are encouraged to explicitly initialize all fields of a struct explicitly rather than using this function.
/// However, it is recognized that there are sometimes use cases for initializing all fields to a "zero" value. For example, when
/// interfacing with a C API where this practice is more common and relied upon. If you are performing code review and see this
/// function used, examine closely - it may be a code smell.
/// Zero initializes the type.
/// This can be used to zero initialize a any type for which it makes sense. Structs will be initialized recursively.
pub fn zeroes(comptime T: type) T {
    switch (@typeInfo(T)) {
        .ComptimeInt, .Int, .ComptimeFloat, .Float => {
            return @as(T, 0);
        },
        .Enum, .EnumLiteral => {
            return @intToEnum(T, 0);
        },
        .Void => {
            return {};
        },
        .Bool => {
            return false;
        },
        .Optional, .Null => {
            return null;
        },
        .Struct => |struct_info| {
            if (@sizeOf(T) == 0) return T{};
            if (comptime meta.containerLayout(T) == .Extern) {
                var item: T = undefined;
                set(u8, asBytes(&item), 0);
                return item;
            } else {
                var structure: T = undefined;
                inline for (struct_info.fields) |field| {
                    @field(structure, field.name) = zeroes(@TypeOf(@field(structure, field.name)));
                }
                return structure;
            }
        },
        .Pointer => |ptr_info| {
            switch (ptr_info.size) {
                .Slice => {
                    return &[_]ptr_info.child{};
                },
                .C => {
                    return null;
                },
                .One, .Many => {
                    @compileError("Can't set a non nullable pointer to zero.");
                },
            }
        },
        .Array => |info| {
            if (info.sentinel) |sentinel| {
                return [_:sentinel]info.child{zeroes(info.child)} ** info.len;
            }
            return [_]info.child{zeroes(info.child)} ** info.len;
        },
        .Vector => |info| {
            return @splat(info.len, zeroes(info.child));
        },
        .Union => |info| {
            if (comptime meta.containerLayout(T) == .Extern) {
                // The C language specification states that (global) unions
                // should be zero initialized to the first named member.
                var item: T = undefined;
                @field(item, info.fields[0].name) = zeroes(@TypeOf(@field(item, info.fields[0].name)));
                return item;
            }

            @compileError("Can't set a " ++ @typeName(T) ++ " to zero.");
        },
        .ErrorUnion,
        .ErrorSet,
        .Fn,
        .BoundFn,
        .Type,
        .NoReturn,
        .Undefined,
        .Opaque,
        .Frame,
        .AnyFrame,
        => {
            @compileError("Can't set a " ++ @typeName(T) ++ " to zero.");
        },
    }
}

test "mem.zeroes" {
    const C_struct = extern struct {
        x: u32,
        y: u32,
    };

    var a = zeroes(C_struct);
    a.y += 10;

    try testing.expect(a.x == 0);
    try testing.expect(a.y == 10);

    const ZigStruct = struct {
        integral_types: struct {
            integer_0: i0,
            integer_8: i8,
            integer_16: i16,
            integer_32: i32,
            integer_64: i64,
            integer_128: i128,
            unsigned_0: u0,
            unsigned_8: u8,
            unsigned_16: u16,
            unsigned_32: u32,
            unsigned_64: u64,
            unsigned_128: u128,

            float_32: f32,
            float_64: f64,
        },

        pointers: struct {
            optional: ?*u8,
            c_pointer: [*c]u8,
            slice: []u8,
        },

        array: [2]u32,
        vector_u32: meta.Vector(2, u32),
        vector_f32: meta.Vector(2, f32),
        vector_bool: meta.Vector(2, bool),
        optional_int: ?u8,
        empty: void,
        sentinel: [3:0]u8,
    };

    const b = zeroes(ZigStruct);
    try testing.expectEqual(@as(i8, 0), b.integral_types.integer_0);
    try testing.expectEqual(@as(i8, 0), b.integral_types.integer_8);
    try testing.expectEqual(@as(i16, 0), b.integral_types.integer_16);
    try testing.expectEqual(@as(i32, 0), b.integral_types.integer_32);
    try testing.expectEqual(@as(i64, 0), b.integral_types.integer_64);
    try testing.expectEqual(@as(i128, 0), b.integral_types.integer_128);
    try testing.expectEqual(@as(u8, 0), b.integral_types.unsigned_0);
    try testing.expectEqual(@as(u8, 0), b.integral_types.unsigned_8);
    try testing.expectEqual(@as(u16, 0), b.integral_types.unsigned_16);
    try testing.expectEqual(@as(u32, 0), b.integral_types.unsigned_32);
    try testing.expectEqual(@as(u64, 0), b.integral_types.unsigned_64);
    try testing.expectEqual(@as(u128, 0), b.integral_types.unsigned_128);
    try testing.expectEqual(@as(f32, 0), b.integral_types.float_32);
    try testing.expectEqual(@as(f64, 0), b.integral_types.float_64);
    try testing.expectEqual(@as(?*u8, null), b.pointers.optional);
    try testing.expectEqual(@as([*c]u8, null), b.pointers.c_pointer);
    try testing.expectEqual(@as([]u8, &[_]u8{}), b.pointers.slice);
    for (b.array) |e| {
        try testing.expectEqual(@as(u32, 0), e);
    }
    try testing.expectEqual(@splat(2, @as(u32, 0)), b.vector_u32);
    try testing.expectEqual(@splat(2, @as(f32, 0.0)), b.vector_f32);
    try testing.expectEqual(@splat(2, @as(bool, false)), b.vector_bool);
    try testing.expectEqual(@as(?u8, null), b.optional_int);
    for (b.sentinel) |e| {
        try testing.expectEqual(@as(u8, 0), e);
    }

    const C_union = extern union {
        a: u8,
        b: u32,
    };

    var c = zeroes(C_union);
    try testing.expectEqual(@as(u8, 0), c.a);
}

/// Initializes all fields of the struct with their default value, or zero values if no default value is present.
/// If the field is present in the provided initial values, it will have that value instead.
/// Structs are initialized recursively.
pub fn zeroInit(comptime T: type, init: anytype) T {
    const Init = @TypeOf(init);

    switch (@typeInfo(T)) {
        .Struct => |struct_info| {
            switch (@typeInfo(Init)) {
                .Struct => |init_info| {
                    var value = std.mem.zeroes(T);

                    if (init_info.is_tuple) {
                        inline for (init_info.fields) |field, i| {
                            @field(value, struct_info.fields[i].name) = @field(init, field.name);
                        }
                        return value;
                    }

                    inline for (init_info.fields) |field| {
                        if (!@hasField(T, field.name)) {
                            @compileError("Encountered an initializer for `" ++ field.name ++ "`, but it is not a field of " ++ @typeName(T));
                        }
                    }

                    inline for (struct_info.fields) |field| {
                        if (@hasField(Init, field.name)) {
                            switch (@typeInfo(field.field_type)) {
                                .Struct => {
                                    @field(value, field.name) = zeroInit(field.field_type, @field(init, field.name));
                                },
                                else => {
                                    @field(value, field.name) = @field(init, field.name);
                                },
                            }
                        } else if (field.default_value) |default_value| {
                            @field(value, field.name) = default_value;
                        }
                    }

                    return value;
                },
                else => {
                    @compileError("The initializer must be a struct");
                },
            }
        },
        else => {
            @compileError("Can't default init a " ++ @typeName(T));
        },
    }
}

test "zeroInit" {
    const I = struct {
        d: f64,
    };

    const S = struct {
        a: u32,
        b: ?bool,
        c: I,
        e: [3]u8,
        f: i64 = -1,
    };

    const s = zeroInit(S, .{
        .a = 42,
    });

    try testing.expectEqual(S{
        .a = 42,
        .b = null,
        .c = .{
            .d = 0,
        },
        .e = [3]u8{ 0, 0, 0 },
        .f = -1,
    }, s);

    const Color = struct {
        r: u8,
        g: u8,
        b: u8,
        a: u8,
    };

    const c = zeroInit(Color, .{ 255, 255 });
    try testing.expectEqual(Color{
        .r = 255,
        .g = 255,
        .b = 0,
        .a = 0,
    }, c);
}

/// Compares two slices of numbers lexicographically. O(n).
pub fn order(comptime T: type, lhs: []const T, rhs: []const T) math.Order {
    const n = math.min(lhs.len, rhs.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        switch (math.order(lhs[i], rhs[i])) {
            .eq => continue,
            .lt => return .lt,
            .gt => return .gt,
        }
    }
    return math.order(lhs.len, rhs.len);
}

test "order" {
    try testing.expect(order(u8, "abcd", "bee") == .lt);
    try testing.expect(order(u8, "abc", "abc") == .eq);
    try testing.expect(order(u8, "abc", "abc0") == .lt);
    try testing.expect(order(u8, "", "") == .eq);
    try testing.expect(order(u8, "", "a") == .lt);
}

/// Returns true if lhs < rhs, false otherwise
pub fn lessThan(comptime T: type, lhs: []const T, rhs: []const T) bool {
    return order(T, lhs, rhs) == .lt;
}

test "mem.lessThan" {
    try testing.expect(lessThan(u8, "abcd", "bee"));
    try testing.expect(!lessThan(u8, "abc", "abc"));
    try testing.expect(lessThan(u8, "abc", "abc0"));
    try testing.expect(!lessThan(u8, "", ""));
    try testing.expect(lessThan(u8, "", "a"));
}

/// Compares two slices and returns whether they are equal.
pub fn eql(comptime T: type, a: []const T, b: []const T) bool {
    if (a.len != b.len) return false;
    if (a.ptr == b.ptr) return true;
    for (a) |item, index| {
        if (b[index] != item) return false;
    }
    return true;
}

/// Compares two slices and returns the index of the first inequality.
/// Returns null if the slices are equal.
pub fn indexOfDiff(comptime T: type, a: []const T, b: []const T) ?usize {
    const shortest = math.min(a.len, b.len);
    if (a.ptr == b.ptr)
        return if (a.len == b.len) null else shortest;
    var index: usize = 0;
    while (index < shortest) : (index += 1) if (a[index] != b[index]) return index;
    return if (a.len == b.len) null else shortest;
}

test "indexOfDiff" {
    try testing.expectEqual(indexOfDiff(u8, "one", "one"), null);
    try testing.expectEqual(indexOfDiff(u8, "one two", "one"), 3);
    try testing.expectEqual(indexOfDiff(u8, "one", "one two"), 3);
    try testing.expectEqual(indexOfDiff(u8, "one twx", "one two"), 6);
    try testing.expectEqual(indexOfDiff(u8, "xne", "one"), 0);
}

pub const toSliceConst = @compileError("deprecated; use std.mem.spanZ");
pub const toSlice = @compileError("deprecated; use std.mem.spanZ");

/// Takes a pointer to an array, a sentinel-terminated pointer, or a slice, and
/// returns a slice. If there is a sentinel on the input type, there will be a
/// sentinel on the output type. The constness of the output type matches
/// the constness of the input type. `[*c]` pointers are assumed to be 0-terminated,
/// and assumed to not allow null.
pub fn Span(comptime T: type) type {
    switch (@typeInfo(T)) {
        .Optional => |optional_info| {
            return ?Span(optional_info.child);
        },
        .Pointer => |ptr_info| {
            var new_ptr_info = ptr_info;
            switch (ptr_info.size) {
                .One => switch (@typeInfo(ptr_info.child)) {
                    .Array => |info| {
                        new_ptr_info.child = info.child;
                        new_ptr_info.sentinel = info.sentinel;
                    },
                    else => @compileError("invalid type given to std.mem.Span"),
                },
                .C => {
                    new_ptr_info.sentinel = 0;
                    new_ptr_info.is_allowzero = false;
                },
                .Many, .Slice => {},
            }
            new_ptr_info.size = .Slice;
            return @Type(std.builtin.TypeInfo{ .Pointer = new_ptr_info });
        },
        else => @compileError("invalid type given to std.mem.Span"),
    }
}

test "Span" {
    try testing.expect(Span(*[5]u16) == []u16);
    try testing.expect(Span(?*[5]u16) == ?[]u16);
    try testing.expect(Span(*const [5]u16) == []const u16);
    try testing.expect(Span(?*const [5]u16) == ?[]const u16);
    try testing.expect(Span([]u16) == []u16);
    try testing.expect(Span(?[]u16) == ?[]u16);
    try testing.expect(Span([]const u8) == []const u8);
    try testing.expect(Span(?[]const u8) == ?[]const u8);
    try testing.expect(Span([:1]u16) == [:1]u16);
    try testing.expect(Span(?[:1]u16) == ?[:1]u16);
    try testing.expect(Span([:1]const u8) == [:1]const u8);
    try testing.expect(Span(?[:1]const u8) == ?[:1]const u8);
    try testing.expect(Span([*:1]u16) == [:1]u16);
    try testing.expect(Span(?[*:1]u16) == ?[:1]u16);
    try testing.expect(Span([*:1]const u8) == [:1]const u8);
    try testing.expect(Span(?[*:1]const u8) == ?[:1]const u8);
    try testing.expect(Span([*c]u16) == [:0]u16);
    try testing.expect(Span(?[*c]u16) == ?[:0]u16);
    try testing.expect(Span([*c]const u8) == [:0]const u8);
    try testing.expect(Span(?[*c]const u8) == ?[:0]const u8);
}

/// Takes a pointer to an array, a sentinel-terminated pointer, or a slice, and
/// returns a slice. If there is a sentinel on the input type, there will be a
/// sentinel on the output type. The constness of the output type matches
/// the constness of the input type.
///
/// When there is both a sentinel and an array length or slice length, the
/// length value is used instead of the sentinel.
pub fn span(ptr: anytype) Span(@TypeOf(ptr)) {
    if (@typeInfo(@TypeOf(ptr)) == .Optional) {
        if (ptr) |non_null| {
            return span(non_null);
        } else {
            return null;
        }
    }
    const Result = Span(@TypeOf(ptr));
    const l = len(ptr);
    if (@typeInfo(Result).Pointer.sentinel) |s| {
        return ptr[0..l :s];
    } else {
        return ptr[0..l];
    }
}

test "span" {
    var array: [5]u16 = [_]u16{ 1, 2, 3, 4, 5 };
    const ptr = @as([*:3]u16, array[0..2 :3]);
    try testing.expect(eql(u16, span(ptr), &[_]u16{ 1, 2 }));
    try testing.expect(eql(u16, span(&array), &[_]u16{ 1, 2, 3, 4, 5 }));
    try testing.expectEqual(@as(?[:0]u16, null), span(@as(?[*:0]u16, null)));
}

/// Deprecated: use std.mem.span() or std.mem.sliceTo()
/// Same as `span`, except when there is both a sentinel and an array
/// length or slice length, scans the memory for the sentinel value
/// rather than using the length.
pub fn spanZ(ptr: anytype) Span(@TypeOf(ptr)) {
    if (@typeInfo(@TypeOf(ptr)) == .Optional) {
        if (ptr) |non_null| {
            return spanZ(non_null);
        } else {
            return null;
        }
    }
    const Result = Span(@TypeOf(ptr));
    const l = lenZ(ptr);
    if (@typeInfo(Result).Pointer.sentinel) |s| {
        return ptr[0..l :s];
    } else {
        return ptr[0..l];
    }
}

test "spanZ" {
    var array: [5]u16 = [_]u16{ 1, 2, 3, 4, 5 };
    const ptr = @as([*:3]u16, array[0..2 :3]);
    try testing.expect(eql(u16, spanZ(ptr), &[_]u16{ 1, 2 }));
    try testing.expect(eql(u16, spanZ(&array), &[_]u16{ 1, 2, 3, 4, 5 }));
    try testing.expectEqual(@as(?[:0]u16, null), spanZ(@as(?[*:0]u16, null)));
}

/// Helper for the return type of sliceTo()
fn SliceTo(comptime T: type, comptime end: meta.Elem(T)) type {
    switch (@typeInfo(T)) {
        .Optional => |optional_info| {
            return ?SliceTo(optional_info.child, end);
        },
        .Pointer => |ptr_info| {
            var new_ptr_info = ptr_info;
            new_ptr_info.size = .Slice;
            switch (ptr_info.size) {
                .One => switch (@typeInfo(ptr_info.child)) {
                    .Array => |array_info| {
                        new_ptr_info.child = array_info.child;
                        // The return type must only be sentinel terminated if we are guaranteed
                        // to find the value searched for, which is only the case if it matches
                        // the sentinel of the type passed.
                        if (array_info.sentinel) |sentinel| {
                            if (end == sentinel) {
                                new_ptr_info.sentinel = end;
                            } else {
                                new_ptr_info.sentinel = null;
                            }
                        }
                    },
                    else => {},
                },
                .Many, .Slice => {
                    // The return type must only be sentinel terminated if we are guaranteed
                    // to find the value searched for, which is only the case if it matches
                    // the sentinel of the type passed.
                    if (ptr_info.sentinel) |sentinel| {
                        if (end == sentinel) {
                            new_ptr_info.sentinel = end;
                        } else {
                            new_ptr_info.sentinel = null;
                        }
                    }
                },
                .C => {
                    new_ptr_info.sentinel = end;
                    // C pointers are always allowzero, but we don't want the return type to be.
                    assert(new_ptr_info.is_allowzero);
                    new_ptr_info.is_allowzero = false;
                },
            }
            return @Type(std.builtin.TypeInfo{ .Pointer = new_ptr_info });
        },
        else => {},
    }
    @compileError("invalid type given to std.mem.sliceTo: " ++ @typeName(T));
}

/// Takes a pointer to an array, an array, a sentinel-terminated pointer, or a slice and
/// iterates searching for the first occurrence of `end`, returning the scanned slice.
/// If `end` is not found, the full length of the array/slice/sentinel terminated pointer is returned.
/// If the pointer type is sentinel terminated and `end` matches that terminator, the
/// resulting slice is also sentinel terminated.
/// Pointer properties such as mutability and alignment are preserved.
/// C pointers are assumed to be non-null.
pub fn sliceTo(ptr: anytype, comptime end: meta.Elem(@TypeOf(ptr))) SliceTo(@TypeOf(ptr), end) {
    if (@typeInfo(@TypeOf(ptr)) == .Optional) {
        const non_null = ptr orelse return null;
        return sliceTo(non_null, end);
    }
    const Result = SliceTo(@TypeOf(ptr), end);
    const length = lenSliceTo(ptr, end);
    if (@typeInfo(Result).Pointer.sentinel) |s| {
        return ptr[0..length :s];
    } else {
        return ptr[0..length];
    }
}

test "sliceTo" {
    try testing.expectEqualSlices(u8, "aoeu", sliceTo("aoeu", 0));

    {
        var array: [5]u16 = [_]u16{ 1, 2, 3, 4, 5 };
        try testing.expectEqualSlices(u16, &array, sliceTo(&array, 0));
        try testing.expectEqualSlices(u16, array[0..3], sliceTo(array[0..3], 0));
        try testing.expectEqualSlices(u16, array[0..2], sliceTo(&array, 3));
        try testing.expectEqualSlices(u16, array[0..2], sliceTo(array[0..3], 3));

        const sentinel_ptr = @ptrCast([*:5]u16, &array);
        try testing.expectEqualSlices(u16, array[0..2], sliceTo(sentinel_ptr, 3));
        try testing.expectEqualSlices(u16, array[0..4], sliceTo(sentinel_ptr, 99));

        const optional_sentinel_ptr = @ptrCast(?[*:5]u16, &array);
        try testing.expectEqualSlices(u16, array[0..2], sliceTo(optional_sentinel_ptr, 3).?);
        try testing.expectEqualSlices(u16, array[0..4], sliceTo(optional_sentinel_ptr, 99).?);

        const c_ptr = @as([*c]u16, &array);
        try testing.expectEqualSlices(u16, array[0..2], sliceTo(c_ptr, 3));

        const slice: []u16 = &array;
        try testing.expectEqualSlices(u16, array[0..2], sliceTo(slice, 3));
        try testing.expectEqualSlices(u16, &array, sliceTo(slice, 99));

        const sentinel_slice: [:5]u16 = array[0..4 :5];
        try testing.expectEqualSlices(u16, array[0..2], sliceTo(sentinel_slice, 3));
        try testing.expectEqualSlices(u16, array[0..4], sliceTo(sentinel_slice, 99));
    }
    {
        var sentinel_array: [5:0]u16 = [_:0]u16{ 1, 2, 3, 4, 5 };
        try testing.expectEqualSlices(u16, sentinel_array[0..2], sliceTo(&sentinel_array, 3));
        try testing.expectEqualSlices(u16, &sentinel_array, sliceTo(&sentinel_array, 0));
        try testing.expectEqualSlices(u16, &sentinel_array, sliceTo(&sentinel_array, 99));
    }

    try testing.expectEqual(@as(?[]u8, null), sliceTo(@as(?[]u8, null), 0));
}

/// Private helper for sliceTo(). If you want the length, use sliceTo(foo, x).len
fn lenSliceTo(ptr: anytype, comptime end: meta.Elem(@TypeOf(ptr))) usize {
    switch (@typeInfo(@TypeOf(ptr))) {
        .Pointer => |ptr_info| switch (ptr_info.size) {
            .One => switch (@typeInfo(ptr_info.child)) {
                .Array => |array_info| {
                    if (array_info.sentinel) |sentinel| {
                        if (sentinel == end) {
                            return indexOfSentinel(array_info.child, end, ptr);
                        }
                    }
                    return indexOfScalar(array_info.child, ptr, end) orelse array_info.len;
                },
                else => {},
            },
            .Many => if (ptr_info.sentinel) |sentinel| {
                // We may be looking for something other than the sentinel,
                // but iterating past the sentinel would be a bug so we need
                // to check for both.
                var i: usize = 0;
                while (ptr[i] != end and ptr[i] != sentinel) i += 1;
                return i;
            },
            .C => {
                assert(ptr != null);
                return indexOfSentinel(ptr_info.child, end, ptr);
            },
            .Slice => {
                if (ptr_info.sentinel) |sentinel| {
                    if (sentinel == end) {
                        return indexOfSentinel(ptr_info.child, sentinel, ptr);
                    }
                }
                return indexOfScalar(ptr_info.child, ptr, end) orelse ptr.len;
            },
        },
        else => {},
    }
    @compileError("invalid type given to std.mem.sliceTo: " ++ @typeName(@TypeOf(ptr)));
}

test "lenSliceTo" {
    try testing.expect(lenSliceTo("aoeu", 0) == 4);

    {
        var array: [5]u16 = [_]u16{ 1, 2, 3, 4, 5 };
        try testing.expectEqual(@as(usize, 5), lenSliceTo(&array, 0));
        try testing.expectEqual(@as(usize, 3), lenSliceTo(array[0..3], 0));
        try testing.expectEqual(@as(usize, 2), lenSliceTo(&array, 3));
        try testing.expectEqual(@as(usize, 2), lenSliceTo(array[0..3], 3));

        const sentinel_ptr = @ptrCast([*:5]u16, &array);
        try testing.expectEqual(@as(usize, 2), lenSliceTo(sentinel_ptr, 3));
        try testing.expectEqual(@as(usize, 4), lenSliceTo(sentinel_ptr, 99));

        const c_ptr = @as([*c]u16, &array);
        try testing.expectEqual(@as(usize, 2), lenSliceTo(c_ptr, 3));

        const slice: []u16 = &array;
        try testing.expectEqual(@as(usize, 2), lenSliceTo(slice, 3));
        try testing.expectEqual(@as(usize, 5), lenSliceTo(slice, 99));

        const sentinel_slice: [:5]u16 = array[0..4 :5];
        try testing.expectEqual(@as(usize, 2), lenSliceTo(sentinel_slice, 3));
        try testing.expectEqual(@as(usize, 4), lenSliceTo(sentinel_slice, 99));
    }
    {
        var sentinel_array: [5:0]u16 = [_:0]u16{ 1, 2, 3, 4, 5 };
        try testing.expectEqual(@as(usize, 2), lenSliceTo(&sentinel_array, 3));
        try testing.expectEqual(@as(usize, 5), lenSliceTo(&sentinel_array, 0));
        try testing.expectEqual(@as(usize, 5), lenSliceTo(&sentinel_array, 99));
    }
}

/// Takes a pointer to an array, an array, a vector, a sentinel-terminated pointer,
/// a slice or a tuple, and returns the length.
/// In the case of a sentinel-terminated array, it uses the array length.
/// For C pointers it assumes it is a pointer-to-many with a 0 sentinel.
pub fn len(value: anytype) usize {
    return switch (@typeInfo(@TypeOf(value))) {
        .Array => |info| info.len,
        .Vector => |info| info.len,
        .Pointer => |info| switch (info.size) {
            .One => switch (@typeInfo(info.child)) {
                .Array => value.len,
                else => @compileError("invalid type given to std.mem.len"),
            },
            .Many => if (info.sentinel) |sentinel|
                indexOfSentinel(info.child, sentinel, value)
            else
                @compileError("length of pointer with no sentinel"),
            .C => {
                assert(value != null);
                return indexOfSentinel(info.child, 0, value);
            },
            .Slice => value.len,
        },
        .Struct => |info| if (info.is_tuple) {
            return info.fields.len;
        } else @compileError("invalid type given to std.mem.len"),
        else => @compileError("invalid type given to std.mem.len"),
    };
}

test "len" {
    try testing.expect(len("aoeu") == 4);

    {
        var array: [5]u16 = [_]u16{ 1, 2, 3, 4, 5 };
        try testing.expect(len(&array) == 5);
        try testing.expect(len(array[0..3]) == 3);
        array[2] = 0;
        const ptr = @as([*:0]u16, array[0..2 :0]);
        try testing.expect(len(ptr) == 2);
    }
    {
        var array: [5:0]u16 = [_:0]u16{ 1, 2, 3, 4, 5 };
        try testing.expect(len(&array) == 5);
        array[2] = 0;
        try testing.expect(len(&array) == 5);
    }
    {
        const vector: meta.Vector(2, u32) = [2]u32{ 1, 2 };
        try testing.expect(len(vector) == 2);
    }
    {
        const tuple = .{ 1, 2 };
        try testing.expect(len(tuple) == 2);
        try testing.expect(tuple[0] == 1);
    }
}

/// Deprecated: use std.mem.len() or std.mem.sliceTo().len
/// Takes a pointer to an array, an array, a sentinel-terminated pointer,
/// or a slice, and returns the length.
/// In the case of a sentinel-terminated array, it scans the array
/// for a sentinel and uses that for the length, rather than using the array length.
/// For C pointers it assumes it is a pointer-to-many with a 0 sentinel.
pub fn lenZ(ptr: anytype) usize {
    return switch (@typeInfo(@TypeOf(ptr))) {
        .Array => |info| if (info.sentinel) |sentinel|
            indexOfSentinel(info.child, sentinel, &ptr)
        else
            info.len,
        .Pointer => |info| switch (info.size) {
            .One => switch (@typeInfo(info.child)) {
                .Array => |x| if (x.sentinel) |sentinel|
                    indexOfSentinel(x.child, sentinel, ptr)
                else
                    ptr.len,
                else => @compileError("invalid type given to std.mem.lenZ"),
            },
            .Many => if (info.sentinel) |sentinel|
                indexOfSentinel(info.child, sentinel, ptr)
            else
                @compileError("length of pointer with no sentinel"),
            .C => {
                assert(ptr != null);
                return indexOfSentinel(info.child, 0, ptr);
            },
            .Slice => if (info.sentinel) |sentinel|
                indexOfSentinel(info.child, sentinel, ptr.ptr)
            else
                ptr.len,
        },
        else => @compileError("invalid type given to std.mem.lenZ"),
    };
}

test "lenZ" {
    try testing.expect(lenZ("aoeu") == 4);

    {
        var array: [5]u16 = [_]u16{ 1, 2, 3, 4, 5 };
        try testing.expect(lenZ(&array) == 5);
        try testing.expect(lenZ(array[0..3]) == 3);
        array[2] = 0;
        const ptr = @as([*:0]u16, array[0..2 :0]);
        try testing.expect(lenZ(ptr) == 2);
    }
    {
        var array: [5:0]u16 = [_:0]u16{ 1, 2, 3, 4, 5 };
        try testing.expect(lenZ(&array) == 5);
        array[2] = 0;
        try testing.expect(lenZ(&array) == 2);
    }
}

pub fn indexOfSentinel(comptime Elem: type, comptime sentinel: Elem, ptr: [*:sentinel]const Elem) usize {
    var i: usize = 0;
    while (ptr[i] != sentinel) {
        i += 1;
    }
    return i;
}

/// Returns true if all elements in a slice are equal to the scalar value provided
pub fn allEqual(comptime T: type, slice: []const T, scalar: T) bool {
    for (slice) |item| {
        if (item != scalar) return false;
    }
    return true;
}

/// Deprecated, use `Allocator.dupe`.
pub fn dupe(allocator: *Allocator, comptime T: type, m: []const T) ![]T {
    return allocator.dupe(T, m);
}

/// Deprecated, use `Allocator.dupeZ`.
pub fn dupeZ(allocator: *Allocator, comptime T: type, m: []const T) ![:0]T {
    return allocator.dupeZ(T, m);
}

/// Remove values from the beginning of a slice.
pub fn trimLeft(comptime T: type, slice: []const T, values_to_strip: []const T) []const T {
    var begin: usize = 0;
    while (begin < slice.len and indexOfScalar(T, values_to_strip, slice[begin]) != null) : (begin += 1) {}
    return slice[begin..];
}

/// Remove values from the end of a slice.
pub fn trimRight(comptime T: type, slice: []const T, values_to_strip: []const T) []const T {
    var end: usize = slice.len;
    while (end > 0 and indexOfScalar(T, values_to_strip, slice[end - 1]) != null) : (end -= 1) {}
    return slice[0..end];
}

/// Remove values from the beginning and end of a slice.
pub fn trim(comptime T: type, slice: []const T, values_to_strip: []const T) []const T {
    var begin: usize = 0;
    var end: usize = slice.len;
    while (begin < end and indexOfScalar(T, values_to_strip, slice[begin]) != null) : (begin += 1) {}
    while (end > begin and indexOfScalar(T, values_to_strip, slice[end - 1]) != null) : (end -= 1) {}
    return slice[begin..end];
}

test "mem.trim" {
    try testing.expectEqualSlices(u8, "foo\n ", trimLeft(u8, " foo\n ", " \n"));
    try testing.expectEqualSlices(u8, " foo", trimRight(u8, " foo\n ", " \n"));
    try testing.expectEqualSlices(u8, "foo", trim(u8, " foo\n ", " \n"));
    try testing.expectEqualSlices(u8, "foo", trim(u8, "foo", " \n"));
}

/// Linear search for the index of a scalar value inside a slice.
pub fn indexOfScalar(comptime T: type, slice: []const T, value: T) ?usize {
    return indexOfScalarPos(T, slice, 0, value);
}

/// Linear search for the last index of a scalar value inside a slice.
pub fn lastIndexOfScalar(comptime T: type, slice: []const T, value: T) ?usize {
    var i: usize = slice.len;
    while (i != 0) {
        i -= 1;
        if (slice[i] == value) return i;
    }
    return null;
}

pub fn indexOfScalarPos(comptime T: type, slice: []const T, start_index: usize, value: T) ?usize {
    var i: usize = start_index;
    while (i < slice.len) : (i += 1) {
        if (slice[i] == value) return i;
    }
    return null;
}

pub fn indexOfAny(comptime T: type, slice: []const T, values: []const T) ?usize {
    return indexOfAnyPos(T, slice, 0, values);
}

pub fn lastIndexOfAny(comptime T: type, slice: []const T, values: []const T) ?usize {
    var i: usize = slice.len;
    while (i != 0) {
        i -= 1;
        for (values) |value| {
            if (slice[i] == value) return i;
        }
    }
    return null;
}

pub fn indexOfAnyPos(comptime T: type, slice: []const T, start_index: usize, values: []const T) ?usize {
    var i: usize = start_index;
    while (i < slice.len) : (i += 1) {
        for (values) |value| {
            if (slice[i] == value) return i;
        }
    }
    return null;
}

pub fn indexOf(comptime T: type, haystack: []const T, needle: []const T) ?usize {
    return indexOfPos(T, haystack, 0, needle);
}

/// Find the index in a slice of a sub-slice, searching from the end backwards.
/// To start looking at a different index, slice the haystack first.
/// Consider using `lastIndexOf` instead of this, which will automatically use a
/// more sophisticated algorithm on larger inputs.
pub fn lastIndexOfLinear(comptime T: type, haystack: []const T, needle: []const T) ?usize {
    var i: usize = haystack.len - needle.len;
    while (true) : (i -= 1) {
        if (mem.eql(T, haystack[i .. i + needle.len], needle)) return i;
        if (i == 0) return null;
    }
}

/// Consider using `indexOfPos` instead of this, which will automatically use a
/// more sophisticated algorithm on larger inputs.
pub fn indexOfPosLinear(comptime T: type, haystack: []const T, start_index: usize, needle: []const T) ?usize {
    var i: usize = start_index;
    const end = haystack.len - needle.len;
    while (i <= end) : (i += 1) {
        if (eql(T, haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn boyerMooreHorspoolPreprocessReverse(pattern: []const u8, table: *[256]usize) void {
    for (table) |*c| {
        c.* = pattern.len;
    }

    var i: usize = pattern.len - 1;
    // The first item is intentionally ignored and the skip size will be pattern.len.
    // This is the standard way boyer-moore-horspool is implemented.
    while (i > 0) : (i -= 1) {
        table[pattern[i]] = i;
    }
}

fn boyerMooreHorspoolPreprocess(pattern: []const u8, table: *[256]usize) void {
    for (table) |*c| {
        c.* = pattern.len;
    }

    var i: usize = 0;
    // The last item is intentionally ignored and the skip size will be pattern.len.
    // This is the standard way boyer-moore-horspool is implemented.
    while (i < pattern.len - 1) : (i += 1) {
        table[pattern[i]] = pattern.len - 1 - i;
    }
}
/// Find the index in a slice of a sub-slice, searching from the end backwards.
/// To start looking at a different index, slice the haystack first.
/// Uses the Reverse boyer-moore-horspool algorithm on large inputs;
/// `lastIndexOfLinear` on small inputs.
pub fn lastIndexOf(comptime T: type, haystack: []const T, needle: []const T) ?usize {
    if (needle.len > haystack.len) return null;
    if (needle.len == 0) return haystack.len;

    if (!meta.trait.hasUniqueRepresentation(T) or haystack.len < 52 or needle.len <= 4)
        return lastIndexOfLinear(T, haystack, needle);

    const haystack_bytes = sliceAsBytes(haystack);
    const needle_bytes = sliceAsBytes(needle);

    var skip_table: [256]usize = undefined;
    boyerMooreHorspoolPreprocessReverse(needle_bytes, skip_table[0..]);

    var i: usize = haystack_bytes.len - needle_bytes.len;
    while (true) {
        if (i % @sizeOf(T) == 0 and mem.eql(u8, haystack_bytes[i .. i + needle_bytes.len], needle_bytes)) {
            return @divExact(i, @sizeOf(T));
        }
        const skip = skip_table[haystack_bytes[i]];
        if (skip > i) break;
        i -= skip;
    }

    return null;
}

/// Uses Boyer-moore-horspool algorithm on large inputs; `indexOfPosLinear` on small inputs.
pub fn indexOfPos(comptime T: type, haystack: []const T, start_index: usize, needle: []const T) ?usize {
    if (needle.len > haystack.len) return null;
    if (needle.len == 0) return 0;

    if (!meta.trait.hasUniqueRepresentation(T) or haystack.len < 52 or needle.len <= 4)
        return indexOfPosLinear(T, haystack, start_index, needle);

    const haystack_bytes = sliceAsBytes(haystack);
    const needle_bytes = sliceAsBytes(needle);

    var skip_table: [256]usize = undefined;
    boyerMooreHorspoolPreprocess(needle_bytes, skip_table[0..]);

    var i: usize = start_index * @sizeOf(T);
    while (i <= haystack_bytes.len - needle_bytes.len) {
        if (i % @sizeOf(T) == 0 and mem.eql(u8, haystack_bytes[i .. i + needle_bytes.len], needle_bytes)) {
            return @divExact(i, @sizeOf(T));
        }
        i += skip_table[haystack_bytes[i + needle_bytes.len - 1]];
    }

    return null;
}

test "mem.indexOf" {
    try testing.expect(indexOf(u8, "one two three four five six seven eight nine ten eleven", "three four").? == 8);
    try testing.expect(lastIndexOf(u8, "one two three four five six seven eight nine ten eleven", "three four").? == 8);
    try testing.expect(indexOf(u8, "one two three four five six seven eight nine ten eleven", "two two") == null);
    try testing.expect(lastIndexOf(u8, "one two three four five six seven eight nine ten eleven", "two two") == null);

    try testing.expect(indexOf(u8, "one two three four five six seven eight nine ten", "").? == 0);
    try testing.expect(lastIndexOf(u8, "one two three four five six seven eight nine ten", "").? == 48);

    try testing.expect(indexOf(u8, "one two three four", "four").? == 14);
    try testing.expect(lastIndexOf(u8, "one two three two four", "two").? == 14);
    try testing.expect(indexOf(u8, "one two three four", "gour") == null);
    try testing.expect(lastIndexOf(u8, "one two three four", "gour") == null);
    try testing.expect(indexOf(u8, "foo", "foo").? == 0);
    try testing.expect(lastIndexOf(u8, "foo", "foo").? == 0);
    try testing.expect(indexOf(u8, "foo", "fool") == null);
    try testing.expect(lastIndexOf(u8, "foo", "lfoo") == null);
    try testing.expect(lastIndexOf(u8, "foo", "fool") == null);

    try testing.expect(indexOf(u8, "foo foo", "foo").? == 0);
    try testing.expect(lastIndexOf(u8, "foo foo", "foo").? == 4);
    try testing.expect(lastIndexOfAny(u8, "boo, cat", "abo").? == 6);
    try testing.expect(lastIndexOfScalar(u8, "boo", 'o').? == 2);
}

test "mem.indexOf multibyte" {
    {
        // make haystack and needle long enough to trigger boyer-moore-horspool algorithm
        const haystack = [1]u16{0} ** 100 ++ [_]u16{ 0xbbaa, 0xccbb, 0xddcc, 0xeedd, 0xffee, 0x00ff };
        const needle = [_]u16{ 0xbbaa, 0xccbb, 0xddcc, 0xeedd, 0xffee };
        try testing.expectEqual(indexOfPos(u16, &haystack, 0, &needle), 100);

        // check for misaligned false positives (little and big endian)
        const needleLE = [_]u16{ 0xbbbb, 0xcccc, 0xdddd, 0xeeee, 0xffff };
        try testing.expectEqual(indexOfPos(u16, &haystack, 0, &needleLE), null);
        const needleBE = [_]u16{ 0xaacc, 0xbbdd, 0xccee, 0xddff, 0xee00 };
        try testing.expectEqual(indexOfPos(u16, &haystack, 0, &needleBE), null);
    }

    {
        // make haystack and needle long enough to trigger boyer-moore-horspool algorithm
        const haystack = [_]u16{ 0xbbaa, 0xccbb, 0xddcc, 0xeedd, 0xffee, 0x00ff } ++ [1]u16{0} ** 100;
        const needle = [_]u16{ 0xbbaa, 0xccbb, 0xddcc, 0xeedd, 0xffee };
        try testing.expectEqual(lastIndexOf(u16, &haystack, &needle), 0);

        // check for misaligned false positives (little and big endian)
        const needleLE = [_]u16{ 0xbbbb, 0xcccc, 0xdddd, 0xeeee, 0xffff };
        try testing.expectEqual(lastIndexOf(u16, &haystack, &needleLE), null);
        const needleBE = [_]u16{ 0xaacc, 0xbbdd, 0xccee, 0xddff, 0xee00 };
        try testing.expectEqual(lastIndexOf(u16, &haystack, &needleBE), null);
    }
}

/// Returns the number of needles inside the haystack
/// needle.len must be > 0
/// does not count overlapping needles
pub fn count(comptime T: type, haystack: []const T, needle: []const T) usize {
    assert(needle.len > 0);
    var i: usize = 0;
    var found: usize = 0;

    while (indexOfPos(T, haystack, i, needle)) |idx| {
        i = idx + needle.len;
        found += 1;
    }

    return found;
}

test "mem.count" {
    try testing.expect(count(u8, "", "h") == 0);
    try testing.expect(count(u8, "h", "h") == 1);
    try testing.expect(count(u8, "hh", "h") == 2);
    try testing.expect(count(u8, "world!", "hello") == 0);
    try testing.expect(count(u8, "hello world!", "hello") == 1);
    try testing.expect(count(u8, "   abcabc   abc", "abc") == 3);
    try testing.expect(count(u8, "udexdcbvbruhasdrw", "bruh") == 1);
    try testing.expect(count(u8, "foo bar", "o bar") == 1);
    try testing.expect(count(u8, "foofoofoo", "foo") == 3);
    try testing.expect(count(u8, "fffffff", "ff") == 3);
    try testing.expect(count(u8, "owowowu", "owowu") == 1);
}

/// Returns true if the haystack contains expected_count or more needles
/// needle.len must be > 0
/// does not count overlapping needles
pub fn containsAtLeast(comptime T: type, haystack: []const T, expected_count: usize, needle: []const T) bool {
    assert(needle.len > 0);
    if (expected_count == 0) return true;

    var i: usize = 0;
    var found: usize = 0;

    while (indexOfPos(T, haystack, i, needle)) |idx| {
        i = idx + needle.len;
        found += 1;
        if (found == expected_count) return true;
    }
    return false;
}

test "mem.containsAtLeast" {
    try testing.expect(containsAtLeast(u8, "aa", 0, "a"));
    try testing.expect(containsAtLeast(u8, "aa", 1, "a"));
    try testing.expect(containsAtLeast(u8, "aa", 2, "a"));
    try testing.expect(!containsAtLeast(u8, "aa", 3, "a"));

    try testing.expect(containsAtLeast(u8, "radaradar", 1, "radar"));
    try testing.expect(!containsAtLeast(u8, "radaradar", 2, "radar"));

    try testing.expect(containsAtLeast(u8, "radarradaradarradar", 3, "radar"));
    try testing.expect(!containsAtLeast(u8, "radarradaradarradar", 4, "radar"));

    try testing.expect(containsAtLeast(u8, "   radar      radar   ", 2, "radar"));
    try testing.expect(!containsAtLeast(u8, "   radar      radar   ", 3, "radar"));
}

/// Reads an integer from memory with size equal to bytes.len.
/// T specifies the return type, which must be large enough to store
/// the result.
pub fn readVarInt(comptime ReturnType: type, bytes: []const u8, endian: Endian) ReturnType {
    var result: ReturnType = 0;
    switch (endian) {
        .Big => {
            for (bytes) |b| {
                result = (result << 8) | b;
            }
        },
        .Little => {
            const ShiftType = math.Log2Int(ReturnType);
            for (bytes) |b, index| {
                result = result | (@as(ReturnType, b) << @intCast(ShiftType, index * 8));
            }
        },
    }
    return result;
}

/// Reads an integer from memory with bit count specified by T.
/// The bit count of T must be evenly divisible by 8.
/// This function cannot fail and cannot cause undefined behavior.
/// Assumes the endianness of memory is native. This means the function can
/// simply pointer cast memory.
pub fn readIntNative(comptime T: type, bytes: *const [@divExact(@typeInfo(T).Int.bits, 8)]u8) T {
    return @ptrCast(*align(1) const T, bytes).*;
}

/// Reads an integer from memory with bit count specified by T.
/// The bit count of T must be evenly divisible by 8.
/// This function cannot fail and cannot cause undefined behavior.
/// Assumes the endianness of memory is foreign, so it must byte-swap.
pub fn readIntForeign(comptime T: type, bytes: *const [@divExact(@typeInfo(T).Int.bits, 8)]u8) T {
    return @byteSwap(T, readIntNative(T, bytes));
}

pub const readIntLittle = switch (native_endian) {
    .Little => readIntNative,
    .Big => readIntForeign,
};

pub const readIntBig = switch (native_endian) {
    .Little => readIntForeign,
    .Big => readIntNative,
};

/// Asserts that bytes.len >= @typeInfo(T).Int.bits / 8. Reads the integer starting from index 0
/// and ignores extra bytes.
/// The bit count of T must be evenly divisible by 8.
/// Assumes the endianness of memory is native. This means the function can
/// simply pointer cast memory.
pub fn readIntSliceNative(comptime T: type, bytes: []const u8) T {
    const n = @divExact(@typeInfo(T).Int.bits, 8);
    assert(bytes.len >= n);
    return readIntNative(T, bytes[0..n]);
}

/// Asserts that bytes.len >= @typeInfo(T).Int.bits / 8. Reads the integer starting from index 0
/// and ignores extra bytes.
/// The bit count of T must be evenly divisible by 8.
/// Assumes the endianness of memory is foreign, so it must byte-swap.
pub fn readIntSliceForeign(comptime T: type, bytes: []const u8) T {
    return @byteSwap(T, readIntSliceNative(T, bytes));
}

pub const readIntSliceLittle = switch (native_endian) {
    .Little => readIntSliceNative,
    .Big => readIntSliceForeign,
};

pub const readIntSliceBig = switch (native_endian) {
    .Little => readIntSliceForeign,
    .Big => readIntSliceNative,
};

/// Reads an integer from memory with bit count specified by T.
/// The bit count of T must be evenly divisible by 8.
/// This function cannot fail and cannot cause undefined behavior.
pub fn readInt(comptime T: type, bytes: *const [@divExact(@typeInfo(T).Int.bits, 8)]u8, endian: Endian) T {
    if (endian == native_endian) {
        return readIntNative(T, bytes);
    } else {
        return readIntForeign(T, bytes);
    }
}

/// Asserts that bytes.len >= @typeInfo(T).Int.bits / 8. Reads the integer starting from index 0
/// and ignores extra bytes.
/// The bit count of T must be evenly divisible by 8.
pub fn readIntSlice(comptime T: type, bytes: []const u8, endian: Endian) T {
    const n = @divExact(@typeInfo(T).Int.bits, 8);
    assert(bytes.len >= n);
    return readInt(T, bytes[0..n], endian);
}

test "comptime read/write int" {
    comptime {
        var bytes: [2]u8 = undefined;
        writeIntLittle(u16, &bytes, 0x1234);
        const result = readIntBig(u16, &bytes);
        try testing.expect(result == 0x3412);
    }
    comptime {
        var bytes: [2]u8 = undefined;
        writeIntBig(u16, &bytes, 0x1234);
        const result = readIntLittle(u16, &bytes);
        try testing.expect(result == 0x3412);
    }
}

test "readIntBig and readIntLittle" {
    try testing.expect(readIntSliceBig(u0, &[_]u8{}) == 0x0);
    try testing.expect(readIntSliceLittle(u0, &[_]u8{}) == 0x0);

    try testing.expect(readIntSliceBig(u8, &[_]u8{0x32}) == 0x32);
    try testing.expect(readIntSliceLittle(u8, &[_]u8{0x12}) == 0x12);

    try testing.expect(readIntSliceBig(u16, &[_]u8{ 0x12, 0x34 }) == 0x1234);
    try testing.expect(readIntSliceLittle(u16, &[_]u8{ 0x12, 0x34 }) == 0x3412);

    try testing.expect(readIntSliceBig(u72, &[_]u8{ 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x24 }) == 0x123456789abcdef024);
    try testing.expect(readIntSliceLittle(u72, &[_]u8{ 0xec, 0x10, 0x32, 0x54, 0x76, 0x98, 0xba, 0xdc, 0xfe }) == 0xfedcba9876543210ec);

    try testing.expect(readIntSliceBig(i8, &[_]u8{0xff}) == -1);
    try testing.expect(readIntSliceLittle(i8, &[_]u8{0xfe}) == -2);

    try testing.expect(readIntSliceBig(i16, &[_]u8{ 0xff, 0xfd }) == -3);
    try testing.expect(readIntSliceLittle(i16, &[_]u8{ 0xfc, 0xff }) == -4);
}

/// Writes an integer to memory, storing it in twos-complement.
/// This function always succeeds, has defined behavior for all inputs, and
/// accepts any integer bit width.
/// This function stores in native endian, which means it is implemented as a simple
/// memory store.
pub fn writeIntNative(comptime T: type, buf: *[(@typeInfo(T).Int.bits + 7) / 8]u8, value: T) void {
    @ptrCast(*align(1) T, buf).* = value;
}

/// Writes an integer to memory, storing it in twos-complement.
/// This function always succeeds, has defined behavior for all inputs, but
/// the integer bit width must be divisible by 8.
/// This function stores in foreign endian, which means it does a @byteSwap first.
pub fn writeIntForeign(comptime T: type, buf: *[@divExact(@typeInfo(T).Int.bits, 8)]u8, value: T) void {
    writeIntNative(T, buf, @byteSwap(T, value));
}

pub const writeIntLittle = switch (native_endian) {
    .Little => writeIntNative,
    .Big => writeIntForeign,
};

pub const writeIntBig = switch (native_endian) {
    .Little => writeIntForeign,
    .Big => writeIntNative,
};

/// Writes an integer to memory, storing it in twos-complement.
/// This function always succeeds, has defined behavior for all inputs, but
/// the integer bit width must be divisible by 8.
pub fn writeInt(comptime T: type, buffer: *[@divExact(@typeInfo(T).Int.bits, 8)]u8, value: T, endian: Endian) void {
    if (endian == native_endian) {
        return writeIntNative(T, buffer, value);
    } else {
        return writeIntForeign(T, buffer, value);
    }
}

/// Writes a twos-complement little-endian integer to memory.
/// Asserts that buf.len >= @typeInfo(T).Int.bits / 8.
/// The bit count of T must be divisible by 8.
/// Any extra bytes in buffer after writing the integer are set to zero. To
/// avoid the branch to check for extra buffer bytes, use writeIntLittle
/// instead.
pub fn writeIntSliceLittle(comptime T: type, buffer: []u8, value: T) void {
    assert(buffer.len >= @divExact(@typeInfo(T).Int.bits, 8));

    if (@typeInfo(T).Int.bits == 0)
        return set(u8, buffer, 0);

    // TODO I want to call writeIntLittle here but comptime eval facilities aren't good enough
    const uint = std.meta.Int(.unsigned, @typeInfo(T).Int.bits);
    var bits = @bitCast(uint, value);
    for (buffer) |*b| {
        b.* = @truncate(u8, bits);
        bits >>= 8;
    }
}

/// Writes a twos-complement big-endian integer to memory.
/// Asserts that buffer.len >= @typeInfo(T).Int.bits / 8.
/// The bit count of T must be divisible by 8.
/// Any extra bytes in buffer before writing the integer are set to zero. To
/// avoid the branch to check for extra buffer bytes, use writeIntBig instead.
pub fn writeIntSliceBig(comptime T: type, buffer: []u8, value: T) void {
    assert(buffer.len >= @divExact(@typeInfo(T).Int.bits, 8));

    if (@typeInfo(T).Int.bits == 0)
        return set(u8, buffer, 0);

    // TODO I want to call writeIntBig here but comptime eval facilities aren't good enough
    const uint = std.meta.Int(.unsigned, @typeInfo(T).Int.bits);
    var bits = @bitCast(uint, value);
    var index: usize = buffer.len;
    while (index != 0) {
        index -= 1;
        buffer[index] = @truncate(u8, bits);
        bits >>= 8;
    }
}

pub const writeIntSliceNative = switch (native_endian) {
    .Little => writeIntSliceLittle,
    .Big => writeIntSliceBig,
};

pub const writeIntSliceForeign = switch (native_endian) {
    .Little => writeIntSliceBig,
    .Big => writeIntSliceLittle,
};

/// Writes a twos-complement integer to memory, with the specified endianness.
/// Asserts that buf.len >= @typeInfo(T).Int.bits / 8.
/// The bit count of T must be evenly divisible by 8.
/// Any extra bytes in buffer not part of the integer are set to zero, with
/// respect to endianness. To avoid the branch to check for extra buffer bytes,
/// use writeInt instead.
pub fn writeIntSlice(comptime T: type, buffer: []u8, value: T, endian: Endian) void {
    comptime assert(@typeInfo(T).Int.bits % 8 == 0);
    return switch (endian) {
        .Little => writeIntSliceLittle(T, buffer, value),
        .Big => writeIntSliceBig(T, buffer, value),
    };
}

test "writeIntBig and writeIntLittle" {
    var buf0: [0]u8 = undefined;
    var buf1: [1]u8 = undefined;
    var buf2: [2]u8 = undefined;
    var buf9: [9]u8 = undefined;

    writeIntBig(u0, &buf0, 0x0);
    try testing.expect(eql(u8, buf0[0..], &[_]u8{}));
    writeIntLittle(u0, &buf0, 0x0);
    try testing.expect(eql(u8, buf0[0..], &[_]u8{}));

    writeIntBig(u8, &buf1, 0x12);
    try testing.expect(eql(u8, buf1[0..], &[_]u8{0x12}));
    writeIntLittle(u8, &buf1, 0x34);
    try testing.expect(eql(u8, buf1[0..], &[_]u8{0x34}));

    writeIntBig(u16, &buf2, 0x1234);
    try testing.expect(eql(u8, buf2[0..], &[_]u8{ 0x12, 0x34 }));
    writeIntLittle(u16, &buf2, 0x5678);
    try testing.expect(eql(u8, buf2[0..], &[_]u8{ 0x78, 0x56 }));

    writeIntBig(u72, &buf9, 0x123456789abcdef024);
    try testing.expect(eql(u8, buf9[0..], &[_]u8{ 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x24 }));
    writeIntLittle(u72, &buf9, 0xfedcba9876543210ec);
    try testing.expect(eql(u8, buf9[0..], &[_]u8{ 0xec, 0x10, 0x32, 0x54, 0x76, 0x98, 0xba, 0xdc, 0xfe }));

    writeIntBig(i8, &buf1, -1);
    try testing.expect(eql(u8, buf1[0..], &[_]u8{0xff}));
    writeIntLittle(i8, &buf1, -2);
    try testing.expect(eql(u8, buf1[0..], &[_]u8{0xfe}));

    writeIntBig(i16, &buf2, -3);
    try testing.expect(eql(u8, buf2[0..], &[_]u8{ 0xff, 0xfd }));
    writeIntLittle(i16, &buf2, -4);
    try testing.expect(eql(u8, buf2[0..], &[_]u8{ 0xfc, 0xff }));
}

/// Swap the byte order of all the members of the fields of a struct
/// (Changing their endianess)
pub fn bswapAllFields(comptime S: type, ptr: *S) void {
    if (@typeInfo(S) != .Struct) @compileError("bswapAllFields expects a struct as the first argument");
    inline for (std.meta.fields(S)) |f| {
        @field(ptr, f.name) = @byteSwap(f.field_type, @field(ptr, f.name));
    }
}

test "bswapAllFields" {
    const T = extern struct {
        f0: u8,
        f1: u16,
        f2: u32,
    };
    var s = T{
        .f0 = 0x12,
        .f1 = 0x1234,
        .f2 = 0x12345678,
    };
    bswapAllFields(T, &s);
    try std.testing.expectEqual(T{
        .f0 = 0x12,
        .f1 = 0x3412,
        .f2 = 0x78563412,
    }, s);
}

/// Returns an iterator that iterates over the slices of `buffer` that are not
/// any of the bytes in `delimiter_bytes`.
/// tokenize("   abc def    ghi  ", " ")
/// Will return slices for "abc", "def", "ghi", null, in that order.
/// If `buffer` is empty, the iterator will return null.
/// If `delimiter_bytes` does not exist in buffer,
/// the iterator will return `buffer`, null, in that order.
/// See also the related function `split`.
pub fn tokenize(buffer: []const u8, delimiter_bytes: []const u8) TokenIterator {
    return TokenIterator{
        .index = 0,
        .buffer = buffer,
        .delimiter_bytes = delimiter_bytes,
    };
}

test "mem.tokenize" {
    var it = tokenize("   abc def   ghi  ", " ");
    try testing.expect(eql(u8, it.next().?, "abc"));
    try testing.expect(eql(u8, it.next().?, "def"));
    try testing.expect(eql(u8, it.next().?, "ghi"));
    try testing.expect(it.next() == null);

    it = tokenize("..\\bob", "\\");
    try testing.expect(eql(u8, it.next().?, ".."));
    try testing.expect(eql(u8, "..", "..\\bob"[0..it.index]));
    try testing.expect(eql(u8, it.next().?, "bob"));
    try testing.expect(it.next() == null);

    it = tokenize("//a/b", "/");
    try testing.expect(eql(u8, it.next().?, "a"));
    try testing.expect(eql(u8, it.next().?, "b"));
    try testing.expect(eql(u8, "//a/b", "//a/b"[0..it.index]));
    try testing.expect(it.next() == null);

    it = tokenize("|", "|");
    try testing.expect(it.next() == null);

    it = tokenize("", "|");
    try testing.expect(it.next() == null);

    it = tokenize("hello", "");
    try testing.expect(eql(u8, it.next().?, "hello"));
    try testing.expect(it.next() == null);

    it = tokenize("hello", " ");
    try testing.expect(eql(u8, it.next().?, "hello"));
    try testing.expect(it.next() == null);
}

test "mem.tokenize (multibyte)" {
    var it = tokenize("a|b,c/d e", " /,|");
    try testing.expect(eql(u8, it.next().?, "a"));
    try testing.expect(eql(u8, it.next().?, "b"));
    try testing.expect(eql(u8, it.next().?, "c"));
    try testing.expect(eql(u8, it.next().?, "d"));
    try testing.expect(eql(u8, it.next().?, "e"));
    try testing.expect(it.next() == null);
}

test "mem.tokenize (reset)" {
    var it = tokenize("   abc def   ghi  ", " ");
    try testing.expect(eql(u8, it.next().?, "abc"));
    try testing.expect(eql(u8, it.next().?, "def"));
    try testing.expect(eql(u8, it.next().?, "ghi"));

    it.reset();

    try testing.expect(eql(u8, it.next().?, "abc"));
    try testing.expect(eql(u8, it.next().?, "def"));
    try testing.expect(eql(u8, it.next().?, "ghi"));
    try testing.expect(it.next() == null);
}

/// Returns an iterator that iterates over the slices of `buffer` that
/// are separated by bytes in `delimiter`.
/// split("abc|def||ghi", "|")
/// will return slices for "abc", "def", "", "ghi", null, in that order.
/// If `delimiter` does not exist in buffer,
/// the iterator will return `buffer`, null, in that order.
/// The delimiter length must not be zero.
/// See also the related function `tokenize`.
pub fn split(buffer: []const u8, delimiter: []const u8) SplitIterator {
    assert(delimiter.len != 0);
    return SplitIterator{
        .index = 0,
        .buffer = buffer,
        .delimiter = delimiter,
    };
}

pub const separate = @compileError("deprecated: renamed to split (behavior remains unchanged)");

test "mem.split" {
    var it = split("abc|def||ghi", "|");
    try testing.expect(eql(u8, it.next().?, "abc"));
    try testing.expect(eql(u8, it.next().?, "def"));
    try testing.expect(eql(u8, it.next().?, ""));
    try testing.expect(eql(u8, it.next().?, "ghi"));
    try testing.expect(it.next() == null);

    it = split("", "|");
    try testing.expect(eql(u8, it.next().?, ""));
    try testing.expect(it.next() == null);

    it = split("|", "|");
    try testing.expect(eql(u8, it.next().?, ""));
    try testing.expect(eql(u8, it.next().?, ""));
    try testing.expect(it.next() == null);

    it = split("hello", " ");
    try testing.expect(eql(u8, it.next().?, "hello"));
    try testing.expect(it.next() == null);
}

test "mem.split (multibyte)" {
    var it = split("a, b ,, c, d, e", ", ");
    try testing.expect(eql(u8, it.next().?, "a"));
    try testing.expect(eql(u8, it.next().?, "b ,"));
    try testing.expect(eql(u8, it.next().?, "c"));
    try testing.expect(eql(u8, it.next().?, "d"));
    try testing.expect(eql(u8, it.next().?, "e"));
    try testing.expect(it.next() == null);
}

pub fn startsWith(comptime T: type, haystack: []const T, needle: []const T) bool {
    return if (needle.len > haystack.len) false else eql(T, haystack[0..needle.len], needle);
}

test "mem.startsWith" {
    try testing.expect(startsWith(u8, "Bob", "Bo"));
    try testing.expect(!startsWith(u8, "Needle in haystack", "haystack"));
}

pub fn endsWith(comptime T: type, haystack: []const T, needle: []const T) bool {
    return if (needle.len > haystack.len) false else eql(T, haystack[haystack.len - needle.len ..], needle);
}

test "mem.endsWith" {
    try testing.expect(endsWith(u8, "Needle in haystack", "haystack"));
    try testing.expect(!endsWith(u8, "Bob", "Bo"));
}

pub const TokenIterator = struct {
    buffer: []const u8,
    delimiter_bytes: []const u8,
    index: usize,

    /// Returns a slice of the next token, or null if tokenization is complete.
    pub fn next(self: *TokenIterator) ?[]const u8 {
        // move to beginning of token
        while (self.index < self.buffer.len and self.isSplitByte(self.buffer[self.index])) : (self.index += 1) {}
        const start = self.index;
        if (start == self.buffer.len) {
            return null;
        }

        // move to end of token
        while (self.index < self.buffer.len and !self.isSplitByte(self.buffer[self.index])) : (self.index += 1) {}
        const end = self.index;

        return self.buffer[start..end];
    }

    /// Returns a slice of the remaining bytes. Does not affect iterator state.
    pub fn rest(self: TokenIterator) []const u8 {
        // move to beginning of token
        var index: usize = self.index;
        while (index < self.buffer.len and self.isSplitByte(self.buffer[index])) : (index += 1) {}
        return self.buffer[index..];
    }

    /// Resets the iterator to the initial token.
    pub fn reset(self: *TokenIterator) void {
        self.index = 0;
    }

    fn isSplitByte(self: TokenIterator, byte: u8) bool {
        for (self.delimiter_bytes) |delimiter_byte| {
            if (byte == delimiter_byte) {
                return true;
            }
        }
        return false;
    }
};

pub const SplitIterator = struct {
    buffer: []const u8,
    index: ?usize,
    delimiter: []const u8,

    /// Returns a slice of the next field, or null if splitting is complete.
    pub fn next(self: *SplitIterator) ?[]const u8 {
        const start = self.index orelse return null;
        const end = if (indexOfPos(u8, self.buffer, start, self.delimiter)) |delim_start| blk: {
            self.index = delim_start + self.delimiter.len;
            break :blk delim_start;
        } else blk: {
            self.index = null;
            break :blk self.buffer.len;
        };
        return self.buffer[start..end];
    }

    /// Returns a slice of the remaining bytes. Does not affect iterator state.
    pub fn rest(self: SplitIterator) []const u8 {
        const end = self.buffer.len;
        const start = self.index orelse end;
        return self.buffer[start..end];
    }
};

/// Naively combines a series of slices with a separator.
/// Allocates memory for the result, which must be freed by the caller.
pub fn join(allocator: *Allocator, separator: []const u8, slices: []const []const u8) ![]u8 {
    return joinMaybeZ(allocator, separator, slices, false);
}

/// Naively combines a series of slices with a separator and null terminator.
/// Allocates memory for the result, which must be freed by the caller.
pub fn joinZ(allocator: *Allocator, separator: []const u8, slices: []const []const u8) ![:0]u8 {
    const out = try joinMaybeZ(allocator, separator, slices, true);
    return out[0 .. out.len - 1 :0];
}

fn joinMaybeZ(allocator: *Allocator, separator: []const u8, slices: []const []const u8, zero: bool) ![]u8 {
    if (slices.len == 0) return if (zero) try allocator.dupe(u8, &[1]u8{0}) else &[0]u8{};

    const total_len = blk: {
        var sum: usize = separator.len * (slices.len - 1);
        for (slices) |slice| sum += slice.len;
        if (zero) sum += 1;
        break :blk sum;
    };

    const buf = try allocator.alloc(u8, total_len);
    errdefer allocator.free(buf);

    copy(u8, buf, slices[0]);
    var buf_index: usize = slices[0].len;
    for (slices[1..]) |slice| {
        copy(u8, buf[buf_index..], separator);
        buf_index += separator.len;
        copy(u8, buf[buf_index..], slice);
        buf_index += slice.len;
    }

    if (zero) buf[buf.len - 1] = 0;

    // No need for shrink since buf is exactly the correct size.
    return buf;
}

test "mem.join" {
    {
        const str = try join(testing.allocator, ",", &[_][]const u8{});
        defer testing.allocator.free(str);
        try testing.expect(eql(u8, str, ""));
    }
    {
        const str = try join(testing.allocator, ",", &[_][]const u8{ "a", "b", "c" });
        defer testing.allocator.free(str);
        try testing.expect(eql(u8, str, "a,b,c"));
    }
    {
        const str = try join(testing.allocator, ",", &[_][]const u8{"a"});
        defer testing.allocator.free(str);
        try testing.expect(eql(u8, str, "a"));
    }
    {
        const str = try join(testing.allocator, ",", &[_][]const u8{ "a", "", "b", "", "c" });
        defer testing.allocator.free(str);
        try testing.expect(eql(u8, str, "a,,b,,c"));
    }
}

test "mem.joinZ" {
    {
        const str = try joinZ(testing.allocator, ",", &[_][]const u8{});
        defer testing.allocator.free(str);
        try testing.expect(eql(u8, str, ""));
        try testing.expectEqual(str[str.len], 0);
    }
    {
        const str = try joinZ(testing.allocator, ",", &[_][]const u8{ "a", "b", "c" });
        defer testing.allocator.free(str);
        try testing.expect(eql(u8, str, "a,b,c"));
        try testing.expectEqual(str[str.len], 0);
    }
    {
        const str = try joinZ(testing.allocator, ",", &[_][]const u8{"a"});
        defer testing.allocator.free(str);
        try testing.expect(eql(u8, str, "a"));
        try testing.expectEqual(str[str.len], 0);
    }
    {
        const str = try joinZ(testing.allocator, ",", &[_][]const u8{ "a", "", "b", "", "c" });
        defer testing.allocator.free(str);
        try testing.expect(eql(u8, str, "a,,b,,c"));
        try testing.expectEqual(str[str.len], 0);
    }
}

/// Copies each T from slices into a new slice that exactly holds all the elements.
pub fn concat(allocator: *Allocator, comptime T: type, slices: []const []const T) ![]T {
    if (slices.len == 0) return &[0]T{};

    const total_len = blk: {
        var sum: usize = 0;
        for (slices) |slice| {
            sum += slice.len;
        }
        break :blk sum;
    };

    const buf = try allocator.alloc(T, total_len);
    errdefer allocator.free(buf);

    var buf_index: usize = 0;
    for (slices) |slice| {
        copy(T, buf[buf_index..], slice);
        buf_index += slice.len;
    }

    // No need for shrink since buf is exactly the correct size.
    return buf;
}

test "concat" {
    {
        const str = try concat(testing.allocator, u8, &[_][]const u8{ "abc", "def", "ghi" });
        defer testing.allocator.free(str);
        try testing.expect(eql(u8, str, "abcdefghi"));
    }
    {
        const str = try concat(testing.allocator, u32, &[_][]const u32{
            &[_]u32{ 0, 1 },
            &[_]u32{ 2, 3, 4 },
            &[_]u32{},
            &[_]u32{5},
        });
        defer testing.allocator.free(str);
        try testing.expect(eql(u32, str, &[_]u32{ 0, 1, 2, 3, 4, 5 }));
    }
}

test "testStringEquality" {
    try testing.expect(eql(u8, "abcd", "abcd"));
    try testing.expect(!eql(u8, "abcdef", "abZdef"));
    try testing.expect(!eql(u8, "abcdefg", "abcdef"));
}

test "testReadInt" {
    try testReadIntImpl();
    comptime try testReadIntImpl();
}
fn testReadIntImpl() !void {
    {
        const bytes = [_]u8{
            0x12,
            0x34,
            0x56,
            0x78,
        };
        try testing.expect(readInt(u32, &bytes, Endian.Big) == 0x12345678);
        try testing.expect(readIntBig(u32, &bytes) == 0x12345678);
        try testing.expect(readIntBig(i32, &bytes) == 0x12345678);
        try testing.expect(readInt(u32, &bytes, Endian.Little) == 0x78563412);
        try testing.expect(readIntLittle(u32, &bytes) == 0x78563412);
        try testing.expect(readIntLittle(i32, &bytes) == 0x78563412);
    }
    {
        const buf = [_]u8{
            0x00,
            0x00,
            0x12,
            0x34,
        };
        const answer = readInt(u32, &buf, Endian.Big);
        try testing.expect(answer == 0x00001234);
    }
    {
        const buf = [_]u8{
            0x12,
            0x34,
            0x00,
            0x00,
        };
        const answer = readInt(u32, &buf, Endian.Little);
        try testing.expect(answer == 0x00003412);
    }
    {
        const bytes = [_]u8{
            0xff,
            0xfe,
        };
        try testing.expect(readIntBig(u16, &bytes) == 0xfffe);
        try testing.expect(readIntBig(i16, &bytes) == -0x0002);
        try testing.expect(readIntLittle(u16, &bytes) == 0xfeff);
        try testing.expect(readIntLittle(i16, &bytes) == -0x0101);
    }
}

test "writeIntSlice" {
    try testWriteIntImpl();
    comptime try testWriteIntImpl();
}
fn testWriteIntImpl() !void {
    var bytes: [8]u8 = undefined;

    writeIntSlice(u0, bytes[0..], 0, Endian.Big);
    try testing.expect(eql(u8, &bytes, &[_]u8{
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    }));

    writeIntSlice(u0, bytes[0..], 0, Endian.Little);
    try testing.expect(eql(u8, &bytes, &[_]u8{
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    }));

    writeIntSlice(u64, bytes[0..], 0x12345678CAFEBABE, Endian.Big);
    try testing.expect(eql(u8, &bytes, &[_]u8{
        0x12,
        0x34,
        0x56,
        0x78,
        0xCA,
        0xFE,
        0xBA,
        0xBE,
    }));

    writeIntSlice(u64, bytes[0..], 0xBEBAFECA78563412, Endian.Little);
    try testing.expect(eql(u8, &bytes, &[_]u8{
        0x12,
        0x34,
        0x56,
        0x78,
        0xCA,
        0xFE,
        0xBA,
        0xBE,
    }));

    writeIntSlice(u32, bytes[0..], 0x12345678, Endian.Big);
    try testing.expect(eql(u8, &bytes, &[_]u8{
        0x00,
        0x00,
        0x00,
        0x00,
        0x12,
        0x34,
        0x56,
        0x78,
    }));

    writeIntSlice(u32, bytes[0..], 0x78563412, Endian.Little);
    try testing.expect(eql(u8, &bytes, &[_]u8{
        0x12,
        0x34,
        0x56,
        0x78,
        0x00,
        0x00,
        0x00,
        0x00,
    }));

    writeIntSlice(u16, bytes[0..], 0x1234, Endian.Big);
    try testing.expect(eql(u8, &bytes, &[_]u8{
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x12,
        0x34,
    }));

    writeIntSlice(u16, bytes[0..], 0x1234, Endian.Little);
    try testing.expect(eql(u8, &bytes, &[_]u8{
        0x34,
        0x12,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
    }));

    writeIntSlice(i16, bytes[0..], @as(i16, -21555), Endian.Little);
    try testing.expect(eql(u8, &bytes, &[_]u8{
        0xCD,
        0xAB,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
    }));

    writeIntSlice(i16, bytes[0..], @as(i16, -21555), Endian.Big);
    try testing.expect(eql(u8, &bytes, &[_]u8{
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0xAB,
        0xCD,
    }));
}

/// Returns the smallest number in a slice. O(n).
/// `slice` must not be empty.
pub fn min(comptime T: type, slice: []const T) T {
    var best = slice[0];
    for (slice[1..]) |item| {
        best = math.min(best, item);
    }
    return best;
}

test "mem.min" {
    try testing.expect(min(u8, "abcdefg") == 'a');
}

/// Returns the largest number in a slice. O(n).
/// `slice` must not be empty.
pub fn max(comptime T: type, slice: []const T) T {
    var best = slice[0];
    for (slice[1..]) |item| {
        best = math.max(best, item);
    }
    return best;
}

test "mem.max" {
    try testing.expect(max(u8, "abcdefg") == 'g');
}

pub fn swap(comptime T: type, a: *T, b: *T) void {
    const tmp = a.*;
    a.* = b.*;
    b.* = tmp;
}

/// In-place order reversal of a slice
pub fn reverse(comptime T: type, items: []T) void {
    var i: usize = 0;
    const end = items.len / 2;
    while (i < end) : (i += 1) {
        swap(T, &items[i], &items[items.len - i - 1]);
    }
}

test "reverse" {
    var arr = [_]i32{ 5, 3, 1, 2, 4 };
    reverse(i32, arr[0..]);

    try testing.expect(eql(i32, &arr, &[_]i32{ 4, 2, 1, 3, 5 }));
}

/// In-place rotation of the values in an array ([0 1 2 3] becomes [1 2 3 0] if we rotate by 1)
/// Assumes 0 <= amount <= items.len
pub fn rotate(comptime T: type, items: []T, amount: usize) void {
    reverse(T, items[0..amount]);
    reverse(T, items[amount..]);
    reverse(T, items);
}

test "rotate" {
    var arr = [_]i32{ 5, 3, 1, 2, 4 };
    rotate(i32, arr[0..], 2);

    try testing.expect(eql(i32, &arr, &[_]i32{ 1, 2, 4, 5, 3 }));
}

/// Replace needle with replacement as many times as possible, writing to an output buffer which is assumed to be of
/// appropriate size. Use replacementSize to calculate an appropriate buffer size.
/// The needle must not be empty.
pub fn replace(comptime T: type, input: []const T, needle: []const T, replacement: []const T, output: []T) usize {
    // Empty needle will loop until output buffer overflows.
    assert(needle.len > 0);

    var i: usize = 0;
    var slide: usize = 0;
    var replacements: usize = 0;
    while (slide < input.len) {
        if (mem.startsWith(T, input[slide..], needle)) {
            mem.copy(T, output[i .. i + replacement.len], replacement);
            i += replacement.len;
            slide += needle.len;
            replacements += 1;
        } else {
            output[i] = input[slide];
            i += 1;
            slide += 1;
        }
    }

    return replacements;
}

test "replace" {
    var output: [29]u8 = undefined;
    var replacements = replace(u8, "All your base are belong to us", "base", "Zig", output[0..]);
    var expected: []const u8 = "All your Zig are belong to us";
    try testing.expect(replacements == 1);
    try testing.expectEqualStrings(expected, output[0..expected.len]);

    replacements = replace(u8, "Favor reading code over writing code.", "code", "", output[0..]);
    expected = "Favor reading  over writing .";
    try testing.expect(replacements == 2);
    try testing.expectEqualStrings(expected, output[0..expected.len]);

    // Empty needle is not allowed but input may be empty.
    replacements = replace(u8, "", "x", "y", output[0..0]);
    expected = "";
    try testing.expect(replacements == 0);
    try testing.expectEqualStrings(expected, output[0..expected.len]);

    // Adjacent replacements.

    replacements = replace(u8, "\\n\\n", "\\n", "\n", output[0..]);
    expected = "\n\n";
    try testing.expect(replacements == 2);
    try testing.expectEqualStrings(expected, output[0..expected.len]);

    replacements = replace(u8, "abbba", "b", "cd", output[0..]);
    expected = "acdcdcda";
    try testing.expect(replacements == 3);
    try testing.expectEqualStrings(expected, output[0..expected.len]);
}

/// Replace all occurences of `needle` with `replacement`.
pub fn replaceScalar(comptime T: type, slice: []T, needle: T, replacement: T) void {
    for (slice) |e, i| {
        if (e == needle) {
            slice[i] = replacement;
        }
    }
}

/// Collapse consecutive duplicate elements into one entry.
pub fn collapseRepeatsLen(comptime T: type, slice: []T, elem: T) usize {
    if (slice.len == 0) return 0;
    var write_idx: usize = 1;
    var read_idx: usize = 1;
    while (read_idx < slice.len) : (read_idx += 1) {
        if (slice[read_idx - 1] != elem or slice[read_idx] != elem) {
            slice[write_idx] = slice[read_idx];
            write_idx += 1;
        }
    }
    return write_idx;
}

/// Collapse consecutive duplicate elements into one entry.
pub fn collapseRepeats(comptime T: type, slice: []T, elem: T) []T {
    return slice[0..collapseRepeatsLen(T, slice, elem)];
}

fn testCollapseRepeats(str: []const u8, elem: u8, expected: []const u8) !void {
    const mutable = try std.testing.allocator.dupe(u8, str);
    defer std.testing.allocator.free(mutable);
    try testing.expect(std.mem.eql(u8, collapseRepeats(u8, mutable, elem), expected));
}
test "collapseRepeats" {
    try testCollapseRepeats("", '/', "");
    try testCollapseRepeats("a", '/', "a");
    try testCollapseRepeats("/", '/', "/");
    try testCollapseRepeats("//", '/', "/");
    try testCollapseRepeats("/a", '/', "/a");
    try testCollapseRepeats("//a", '/', "/a");
    try testCollapseRepeats("a/", '/', "a/");
    try testCollapseRepeats("a//", '/', "a/");
    try testCollapseRepeats("a/a", '/', "a/a");
    try testCollapseRepeats("a//a", '/', "a/a");
    try testCollapseRepeats("//a///a////", '/', "/a/a/");
}

/// Calculate the size needed in an output buffer to perform a replacement.
/// The needle must not be empty.
pub fn replacementSize(comptime T: type, input: []const T, needle: []const T, replacement: []const T) usize {
    // Empty needle will loop forever.
    assert(needle.len > 0);

    var i: usize = 0;
    var size: usize = input.len;
    while (i < input.len) {
        if (mem.startsWith(T, input[i..], needle)) {
            size = size - needle.len + replacement.len;
            i += needle.len;
        } else {
            i += 1;
        }
    }

    return size;
}

test "replacementSize" {
    try testing.expect(replacementSize(u8, "All your base are belong to us", "base", "Zig") == 29);
    try testing.expect(replacementSize(u8, "Favor reading code over writing code.", "code", "") == 29);
    try testing.expect(replacementSize(u8, "Only one obvious way to do things.", "things.", "things in Zig.") == 41);

    // Empty needle is not allowed but input may be empty.
    try testing.expect(replacementSize(u8, "", "x", "y") == 0);

    // Adjacent replacements.
    try testing.expect(replacementSize(u8, "\\n\\n", "\\n", "\n") == 2);
    try testing.expect(replacementSize(u8, "abbba", "b", "cd") == 8);
}

/// Perform a replacement on an allocated buffer of pre-determined size. Caller must free returned memory.
pub fn replaceOwned(comptime T: type, allocator: *Allocator, input: []const T, needle: []const T, replacement: []const T) Allocator.Error![]T {
    var output = try allocator.alloc(T, replacementSize(T, input, needle, replacement));
    _ = replace(T, input, needle, replacement, output);
    return output;
}

test "replaceOwned" {
    const gpa = std.testing.allocator;

    const base_replace = replaceOwned(u8, gpa, "All your base are belong to us", "base", "Zig") catch @panic("out of memory");
    defer gpa.free(base_replace);
    try testing.expect(eql(u8, base_replace, "All your Zig are belong to us"));

    const zen_replace = replaceOwned(u8, gpa, "Favor reading code over writing code.", " code", "") catch @panic("out of memory");
    defer gpa.free(zen_replace);
    try testing.expect(eql(u8, zen_replace, "Favor reading over writing."));
}

/// Converts a little-endian integer to host endianness.
pub fn littleToNative(comptime T: type, x: T) T {
    return switch (native_endian) {
        .Little => x,
        .Big => @byteSwap(T, x),
    };
}

/// Converts a big-endian integer to host endianness.
pub fn bigToNative(comptime T: type, x: T) T {
    return switch (native_endian) {
        .Little => @byteSwap(T, x),
        .Big => x,
    };
}

/// Converts an integer from specified endianness to host endianness.
pub fn toNative(comptime T: type, x: T, endianness_of_x: Endian) T {
    return switch (endianness_of_x) {
        .Little => littleToNative(T, x),
        .Big => bigToNative(T, x),
    };
}

/// Converts an integer which has host endianness to the desired endianness.
pub fn nativeTo(comptime T: type, x: T, desired_endianness: Endian) T {
    return switch (desired_endianness) {
        .Little => nativeToLittle(T, x),
        .Big => nativeToBig(T, x),
    };
}

/// Converts an integer which has host endianness to little endian.
pub fn nativeToLittle(comptime T: type, x: T) T {
    return switch (native_endian) {
        .Little => x,
        .Big => @byteSwap(T, x),
    };
}

/// Converts an integer which has host endianness to big endian.
pub fn nativeToBig(comptime T: type, x: T) T {
    return switch (native_endian) {
        .Little => @byteSwap(T, x),
        .Big => x,
    };
}

/// Returns the number of elements that, if added to the given pointer, align it
/// to a multiple of the given quantity, or `null` if one of the following
/// conditions is met:
/// - The aligned pointer would not fit the address space,
/// - The delta required to align the pointer is not a multiple of the pointee's
///   type.
pub fn alignPointerOffset(ptr: anytype, align_to: u29) ?usize {
    assert(align_to != 0 and @popCount(u29, align_to) == 1);

    const T = @TypeOf(ptr);
    const info = @typeInfo(T);
    if (info != .Pointer or info.Pointer.size != .Many)
        @compileError("expected many item pointer, got " ++ @typeName(T));

    // Do nothing if the pointer is already well-aligned.
    if (align_to <= info.Pointer.alignment)
        return 0;

    // Calculate the aligned base address with an eye out for overflow.
    const addr = @ptrToInt(ptr);
    var new_addr: usize = undefined;
    if (@addWithOverflow(usize, addr, align_to - 1, &new_addr)) return null;
    new_addr &= ~@as(usize, align_to - 1);

    // The delta is expressed in terms of bytes, turn it into a number of child
    // type elements.
    const delta = new_addr - addr;
    const pointee_size = @sizeOf(info.Pointer.child);
    if (delta % pointee_size != 0) return null;
    return delta / pointee_size;
}

/// Aligns a given pointer value to a specified alignment factor.
/// Returns an aligned pointer or null if one of the following conditions is
/// met:
/// - The aligned pointer would not fit the address space,
/// - The delta required to align the pointer is not a multiple of the pointee's
///   type.
pub fn alignPointer(ptr: anytype, align_to: u29) ?@TypeOf(ptr) {
    const adjust_off = alignPointerOffset(ptr, align_to) orelse return null;
    const T = @TypeOf(ptr);
    // Avoid the use of intToPtr to avoid losing the pointer provenance info.
    return @alignCast(@typeInfo(T).Pointer.alignment, ptr + adjust_off);
}

test "alignPointer" {
    const S = struct {
        fn checkAlign(comptime T: type, base: usize, align_to: u29, expected: usize) !void {
            var ptr = @intToPtr(T, base);
            var aligned = alignPointer(ptr, align_to);
            try testing.expectEqual(expected, @ptrToInt(aligned));
        }
    };

    try S.checkAlign([*]u8, 0x123, 0x200, 0x200);
    try S.checkAlign([*]align(4) u8, 0x10, 2, 0x10);
    try S.checkAlign([*]u32, 0x10, 2, 0x10);
    try S.checkAlign([*]u32, 0x4, 16, 0x10);
    // Misaligned.
    try S.checkAlign([*]align(1) u32, 0x3, 2, 0);
    // Overflow.
    try S.checkAlign([*]u32, math.maxInt(usize) - 3, 8, 0);
}

fn CopyPtrAttrs(comptime source: type, comptime size: std.builtin.TypeInfo.Pointer.Size, comptime child: type) type {
    const info = @typeInfo(source).Pointer;
    return @Type(.{
        .Pointer = .{
            .size = size,
            .is_const = info.is_const,
            .is_volatile = info.is_volatile,
            .is_allowzero = info.is_allowzero,
            .alignment = info.alignment,
            .child = child,
            .sentinel = null,
        },
    });
}

fn AsBytesReturnType(comptime P: type) type {
    if (!trait.isSingleItemPtr(P))
        @compileError("expected single item pointer, passed " ++ @typeName(P));

    const size = @sizeOf(meta.Child(P));

    return CopyPtrAttrs(P, .One, [size]u8);
}

/// Given a pointer to a single item, returns a slice of the underlying bytes, preserving pointer attributes.
pub fn asBytes(ptr: anytype) AsBytesReturnType(@TypeOf(ptr)) {
    const P = @TypeOf(ptr);
    return @ptrCast(AsBytesReturnType(P), ptr);
}

test "asBytes" {
    const deadbeef = @as(u32, 0xDEADBEEF);
    const deadbeef_bytes = switch (native_endian) {
        .Big => "\xDE\xAD\xBE\xEF",
        .Little => "\xEF\xBE\xAD\xDE",
    };

    try testing.expect(eql(u8, asBytes(&deadbeef), deadbeef_bytes));

    var codeface = @as(u32, 0xC0DEFACE);
    for (asBytes(&codeface).*) |*b|
        b.* = 0;
    try testing.expect(codeface == 0);

    const S = packed struct {
        a: u8,
        b: u8,
        c: u8,
        d: u8,
    };

    const inst = S{
        .a = 0xBE,
        .b = 0xEF,
        .c = 0xDE,
        .d = 0xA1,
    };
    try testing.expect(eql(u8, asBytes(&inst), "\xBE\xEF\xDE\xA1"));

    const ZST = struct {};
    const zero = ZST{};
    try testing.expect(eql(u8, asBytes(&zero), ""));
}

test "asBytes preserves pointer attributes" {
    const inArr: u32 align(16) = 0xDEADBEEF;
    const inPtr = @ptrCast(*align(16) const volatile u32, &inArr);
    const outSlice = asBytes(inPtr);

    const in = @typeInfo(@TypeOf(inPtr)).Pointer;
    const out = @typeInfo(@TypeOf(outSlice)).Pointer;

    try testing.expectEqual(in.is_const, out.is_const);
    try testing.expectEqual(in.is_volatile, out.is_volatile);
    try testing.expectEqual(in.is_allowzero, out.is_allowzero);
    try testing.expectEqual(in.alignment, out.alignment);
}

/// Given any value, returns a copy of its bytes in an array.
pub fn toBytes(value: anytype) [@sizeOf(@TypeOf(value))]u8 {
    return asBytes(&value).*;
}

test "toBytes" {
    var my_bytes = toBytes(@as(u32, 0x12345678));
    switch (native_endian) {
        .Big => try testing.expect(eql(u8, &my_bytes, "\x12\x34\x56\x78")),
        .Little => try testing.expect(eql(u8, &my_bytes, "\x78\x56\x34\x12")),
    }

    my_bytes[0] = '\x99';
    switch (native_endian) {
        .Big => try testing.expect(eql(u8, &my_bytes, "\x99\x34\x56\x78")),
        .Little => try testing.expect(eql(u8, &my_bytes, "\x99\x56\x34\x12")),
    }
}

fn BytesAsValueReturnType(comptime T: type, comptime B: type) type {
    const size = @as(usize, @sizeOf(T));

    if (comptime !trait.is(.Pointer)(B) or
        (meta.Child(B) != [size]u8 and meta.Child(B) != [size:0]u8))
    {
        comptime var buf: [100]u8 = undefined;
        @compileError(std.fmt.bufPrint(&buf, "expected *[{}]u8, passed " ++ @typeName(B), .{size}) catch unreachable);
    }

    return CopyPtrAttrs(B, .One, T);
}

/// Given a pointer to an array of bytes, returns a pointer to a value of the specified type
/// backed by those bytes, preserving pointer attributes.
pub fn bytesAsValue(comptime T: type, bytes: anytype) BytesAsValueReturnType(T, @TypeOf(bytes)) {
    return @ptrCast(BytesAsValueReturnType(T, @TypeOf(bytes)), bytes);
}

test "bytesAsValue" {
    const deadbeef = @as(u32, 0xDEADBEEF);
    const deadbeef_bytes = switch (native_endian) {
        .Big => "\xDE\xAD\xBE\xEF",
        .Little => "\xEF\xBE\xAD\xDE",
    };

    try testing.expect(deadbeef == bytesAsValue(u32, deadbeef_bytes).*);

    var codeface_bytes: [4]u8 = switch (native_endian) {
        .Big => "\xC0\xDE\xFA\xCE",
        .Little => "\xCE\xFA\xDE\xC0",
    }.*;
    var codeface = bytesAsValue(u32, &codeface_bytes);
    try testing.expect(codeface.* == 0xC0DEFACE);
    codeface.* = 0;
    for (codeface_bytes) |b|
        try testing.expect(b == 0);

    const S = packed struct {
        a: u8,
        b: u8,
        c: u8,
        d: u8,
    };

    const inst = S{
        .a = 0xBE,
        .b = 0xEF,
        .c = 0xDE,
        .d = 0xA1,
    };
    const inst_bytes = "\xBE\xEF\xDE\xA1";
    const inst2 = bytesAsValue(S, inst_bytes);
    try testing.expect(meta.eql(inst, inst2.*));
}

test "bytesAsValue preserves pointer attributes" {
    const inArr align(16) = [4]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    const inSlice = @ptrCast(*align(16) const volatile [4]u8, &inArr)[0..];
    const outPtr = bytesAsValue(u32, inSlice);

    const in = @typeInfo(@TypeOf(inSlice)).Pointer;
    const out = @typeInfo(@TypeOf(outPtr)).Pointer;

    try testing.expectEqual(in.is_const, out.is_const);
    try testing.expectEqual(in.is_volatile, out.is_volatile);
    try testing.expectEqual(in.is_allowzero, out.is_allowzero);
    try testing.expectEqual(in.alignment, out.alignment);
}

/// Given a pointer to an array of bytes, returns a value of the specified type backed by a
/// copy of those bytes.
pub fn bytesToValue(comptime T: type, bytes: anytype) T {
    return bytesAsValue(T, bytes).*;
}
test "bytesToValue" {
    const deadbeef_bytes = switch (native_endian) {
        .Big => "\xDE\xAD\xBE\xEF",
        .Little => "\xEF\xBE\xAD\xDE",
    };

    const deadbeef = bytesToValue(u32, deadbeef_bytes);
    try testing.expect(deadbeef == @as(u32, 0xDEADBEEF));
}

fn BytesAsSliceReturnType(comptime T: type, comptime bytesType: type) type {
    if (!(trait.isSlice(bytesType) or trait.isPtrTo(.Array)(bytesType)) or meta.Elem(bytesType) != u8) {
        @compileError("expected []u8 or *[_]u8, passed " ++ @typeName(bytesType));
    }

    if (trait.isPtrTo(.Array)(bytesType) and @typeInfo(meta.Child(bytesType)).Array.len % @sizeOf(T) != 0) {
        @compileError("number of bytes in " ++ @typeName(bytesType) ++ " is not divisible by size of " ++ @typeName(T));
    }

    return CopyPtrAttrs(bytesType, .Slice, T);
}

/// Given a slice of bytes, returns a slice of the specified type
/// backed by those bytes, preserving pointer attributes.
pub fn bytesAsSlice(comptime T: type, bytes: anytype) BytesAsSliceReturnType(T, @TypeOf(bytes)) {
    // let's not give an undefined pointer to @ptrCast
    // it may be equal to zero and fail a null check
    if (bytes.len == 0) {
        return &[0]T{};
    }

    const cast_target = CopyPtrAttrs(@TypeOf(bytes), .Many, T);

    return @ptrCast(cast_target, bytes)[0..@divExact(bytes.len, @sizeOf(T))];
}

test "bytesAsSlice" {
    {
        const bytes = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
        const slice = bytesAsSlice(u16, bytes[0..]);
        try testing.expect(slice.len == 2);
        try testing.expect(bigToNative(u16, slice[0]) == 0xDEAD);
        try testing.expect(bigToNative(u16, slice[1]) == 0xBEEF);
    }
    {
        const bytes = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
        var runtime_zero: usize = 0;
        const slice = bytesAsSlice(u16, bytes[runtime_zero..]);
        try testing.expect(slice.len == 2);
        try testing.expect(bigToNative(u16, slice[0]) == 0xDEAD);
        try testing.expect(bigToNative(u16, slice[1]) == 0xBEEF);
    }
}

test "bytesAsSlice keeps pointer alignment" {
    {
        var bytes = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
        const numbers = bytesAsSlice(u32, bytes[0..]);
        comptime try testing.expect(@TypeOf(numbers) == []align(@alignOf(@TypeOf(bytes))) u32);
    }
    {
        var bytes = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
        var runtime_zero: usize = 0;
        const numbers = bytesAsSlice(u32, bytes[runtime_zero..]);
        comptime try testing.expect(@TypeOf(numbers) == []align(@alignOf(@TypeOf(bytes))) u32);
    }
}

test "bytesAsSlice on a packed struct" {
    const F = packed struct {
        a: u8,
    };

    var b = [1]u8{9};
    var f = bytesAsSlice(F, &b);
    try testing.expect(f[0].a == 9);
}

test "bytesAsSlice with specified alignment" {
    var bytes align(4) = [_]u8{
        0x33,
        0x33,
        0x33,
        0x33,
    };
    const slice: []u32 = std.mem.bytesAsSlice(u32, bytes[0..]);
    try testing.expect(slice[0] == 0x33333333);
}

test "bytesAsSlice preserves pointer attributes" {
    const inArr align(16) = [4]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    const inSlice = @ptrCast(*align(16) const volatile [4]u8, &inArr)[0..];
    const outSlice = bytesAsSlice(u16, inSlice);

    const in = @typeInfo(@TypeOf(inSlice)).Pointer;
    const out = @typeInfo(@TypeOf(outSlice)).Pointer;

    try testing.expectEqual(in.is_const, out.is_const);
    try testing.expectEqual(in.is_volatile, out.is_volatile);
    try testing.expectEqual(in.is_allowzero, out.is_allowzero);
    try testing.expectEqual(in.alignment, out.alignment);
}

fn SliceAsBytesReturnType(comptime sliceType: type) type {
    if (!trait.isSlice(sliceType) and !trait.isPtrTo(.Array)(sliceType)) {
        @compileError("expected []T or *[_]T, passed " ++ @typeName(sliceType));
    }

    return CopyPtrAttrs(sliceType, .Slice, u8);
}

/// Given a slice, returns a slice of the underlying bytes, preserving pointer attributes.
pub fn sliceAsBytes(slice: anytype) SliceAsBytesReturnType(@TypeOf(slice)) {
    const Slice = @TypeOf(slice);

    // let's not give an undefined pointer to @ptrCast
    // it may be equal to zero and fail a null check
    if (slice.len == 0 and comptime meta.sentinel(Slice) == null) {
        return &[0]u8{};
    }

    const cast_target = CopyPtrAttrs(Slice, .Many, u8);

    return @ptrCast(cast_target, slice)[0 .. slice.len * @sizeOf(meta.Elem(Slice))];
}

test "sliceAsBytes" {
    const bytes = [_]u16{ 0xDEAD, 0xBEEF };
    const slice = sliceAsBytes(bytes[0..]);
    try testing.expect(slice.len == 4);
    try testing.expect(eql(u8, slice, switch (native_endian) {
        .Big => "\xDE\xAD\xBE\xEF",
        .Little => "\xAD\xDE\xEF\xBE",
    }));
}

test "sliceAsBytes with sentinel slice" {
    const empty_string: [:0]const u8 = "";
    const bytes = sliceAsBytes(empty_string);
    try testing.expect(bytes.len == 0);
}

test "sliceAsBytes packed struct at runtime and comptime" {
    const Foo = packed struct {
        a: u4,
        b: u4,
    };
    const S = struct {
        fn doTheTest() !void {
            var foo: Foo = undefined;
            var slice = sliceAsBytes(@as(*[1]Foo, &foo)[0..1]);
            slice[0] = 0x13;
            switch (native_endian) {
                .Big => {
                    try testing.expect(foo.a == 0x1);
                    try testing.expect(foo.b == 0x3);
                },
                .Little => {
                    try testing.expect(foo.a == 0x3);
                    try testing.expect(foo.b == 0x1);
                },
            }
        }
    };
    try S.doTheTest();
    comptime try S.doTheTest();
}

test "sliceAsBytes and bytesAsSlice back" {
    try testing.expect(@sizeOf(i32) == 4);

    var big_thing_array = [_]i32{ 1, 2, 3, 4 };
    const big_thing_slice: []i32 = big_thing_array[0..];

    const bytes = sliceAsBytes(big_thing_slice);
    try testing.expect(bytes.len == 4 * 4);

    bytes[4] = 0;
    bytes[5] = 0;
    bytes[6] = 0;
    bytes[7] = 0;
    try testing.expect(big_thing_slice[1] == 0);

    const big_thing_again = bytesAsSlice(i32, bytes);
    try testing.expect(big_thing_again[2] == 3);

    big_thing_again[2] = -1;
    try testing.expect(bytes[8] == math.maxInt(u8));
    try testing.expect(bytes[9] == math.maxInt(u8));
    try testing.expect(bytes[10] == math.maxInt(u8));
    try testing.expect(bytes[11] == math.maxInt(u8));
}

test "sliceAsBytes preserves pointer attributes" {
    const inArr align(16) = [2]u16{ 0xDEAD, 0xBEEF };
    const inSlice = @ptrCast(*align(16) const volatile [2]u16, &inArr)[0..];
    const outSlice = sliceAsBytes(inSlice);

    const in = @typeInfo(@TypeOf(inSlice)).Pointer;
    const out = @typeInfo(@TypeOf(outSlice)).Pointer;

    try testing.expectEqual(in.is_const, out.is_const);
    try testing.expectEqual(in.is_volatile, out.is_volatile);
    try testing.expectEqual(in.is_allowzero, out.is_allowzero);
    try testing.expectEqual(in.alignment, out.alignment);
}

/// Round an address up to the nearest aligned address
/// The alignment must be a power of 2 and greater than 0.
pub fn alignForward(addr: usize, alignment: usize) usize {
    return alignForwardGeneric(usize, addr, alignment);
}

/// Round an address up to the nearest aligned address
/// The alignment must be a power of 2 and greater than 0.
pub fn alignForwardGeneric(comptime T: type, addr: T, alignment: T) T {
    return alignBackwardGeneric(T, addr + (alignment - 1), alignment);
}

/// Force an evaluation of the expression; this tries to prevent
/// the compiler from optimizing the computation away even if the
/// result eventually gets discarded.
pub fn doNotOptimizeAway(val: anytype) void {
    asm volatile (""
        :
        : [val] "rm" (val)
        : "memory"
    );
}

test "alignForward" {
    try testing.expect(alignForward(1, 1) == 1);
    try testing.expect(alignForward(2, 1) == 2);
    try testing.expect(alignForward(1, 2) == 2);
    try testing.expect(alignForward(2, 2) == 2);
    try testing.expect(alignForward(3, 2) == 4);
    try testing.expect(alignForward(4, 2) == 4);
    try testing.expect(alignForward(7, 8) == 8);
    try testing.expect(alignForward(8, 8) == 8);
    try testing.expect(alignForward(9, 8) == 16);
    try testing.expect(alignForward(15, 8) == 16);
    try testing.expect(alignForward(16, 8) == 16);
    try testing.expect(alignForward(17, 8) == 24);
}

/// Round an address up to the previous aligned address
/// Unlike `alignBackward`, `alignment` can be any positive number, not just a power of 2.
pub fn alignBackwardAnyAlign(i: usize, alignment: usize) usize {
    if (@popCount(usize, alignment) == 1)
        return alignBackward(i, alignment);
    assert(alignment != 0);
    return i - @mod(i, alignment);
}

/// Round an address up to the previous aligned address
/// The alignment must be a power of 2 and greater than 0.
pub fn alignBackward(addr: usize, alignment: usize) usize {
    return alignBackwardGeneric(usize, addr, alignment);
}

/// Round an address up to the previous aligned address
/// The alignment must be a power of 2 and greater than 0.
pub fn alignBackwardGeneric(comptime T: type, addr: T, alignment: T) T {
    assert(@popCount(T, alignment) == 1);
    // 000010000 // example alignment
    // 000001111 // subtract 1
    // 111110000 // binary not
    return addr & ~(alignment - 1);
}

/// Returns whether `alignment` is a valid alignment, meaning it is
/// a positive power of 2.
pub fn isValidAlign(alignment: u29) bool {
    return @popCount(u29, alignment) == 1;
}

pub fn isAlignedAnyAlign(i: usize, alignment: usize) bool {
    if (@popCount(usize, alignment) == 1)
        return isAligned(i, alignment);
    assert(alignment != 0);
    return 0 == @mod(i, alignment);
}

/// Given an address and an alignment, return true if the address is a multiple of the alignment
/// The alignment must be a power of 2 and greater than 0.
pub fn isAligned(addr: usize, alignment: usize) bool {
    return isAlignedGeneric(u64, addr, alignment);
}

pub fn isAlignedGeneric(comptime T: type, addr: T, alignment: T) bool {
    return alignBackwardGeneric(T, addr, alignment) == addr;
}

test "isAligned" {
    try testing.expect(isAligned(0, 4));
    try testing.expect(isAligned(1, 1));
    try testing.expect(isAligned(2, 1));
    try testing.expect(isAligned(2, 2));
    try testing.expect(!isAligned(2, 4));
    try testing.expect(isAligned(3, 1));
    try testing.expect(!isAligned(3, 2));
    try testing.expect(!isAligned(3, 4));
    try testing.expect(isAligned(4, 4));
    try testing.expect(isAligned(4, 2));
    try testing.expect(isAligned(4, 1));
    try testing.expect(!isAligned(4, 8));
    try testing.expect(!isAligned(4, 16));
}

test "freeing empty string with null-terminated sentinel" {
    const empty_string = try dupeZ(testing.allocator, u8, "");
    testing.allocator.free(empty_string);
}

/// Returns a slice with the given new alignment,
/// all other pointer attributes copied from `AttributeSource`.
fn AlignedSlice(comptime AttributeSource: type, comptime new_alignment: u29) type {
    const info = @typeInfo(AttributeSource).Pointer;
    return @Type(.{
        .Pointer = .{
            .size = .Slice,
            .is_const = info.is_const,
            .is_volatile = info.is_volatile,
            .is_allowzero = info.is_allowzero,
            .alignment = new_alignment,
            .child = info.child,
            .sentinel = null,
        },
    });
}

/// Returns the largest slice in the given bytes that conforms to the new alignment,
/// or `null` if the given bytes contain no conforming address.
pub fn alignInBytes(bytes: []u8, comptime new_alignment: usize) ?[]align(new_alignment) u8 {
    const begin_address = @ptrToInt(bytes.ptr);
    const end_address = begin_address + bytes.len;

    const begin_address_aligned = mem.alignForward(begin_address, new_alignment);
    const new_length = std.math.sub(usize, end_address, begin_address_aligned) catch |e| switch (e) {
        error.Overflow => return null,
    };
    const alignment_offset = begin_address_aligned - begin_address;
    return @alignCast(new_alignment, bytes[alignment_offset .. alignment_offset + new_length]);
}

/// Returns the largest sub-slice within the given slice that conforms to the new alignment,
/// or `null` if the given slice contains no conforming address.
pub fn alignInSlice(slice: anytype, comptime new_alignment: usize) ?AlignedSlice(@TypeOf(slice), new_alignment) {
    const bytes = sliceAsBytes(slice);
    const aligned_bytes = alignInBytes(bytes, new_alignment) orelse return null;

    const Element = @TypeOf(slice[0]);
    const slice_length_bytes = aligned_bytes.len - (aligned_bytes.len % @sizeOf(Element));
    const aligned_slice = bytesAsSlice(Element, aligned_bytes[0..slice_length_bytes]);
    return @alignCast(new_alignment, aligned_slice);
}

pub fn sliceToArray(comptime T: type, comptime s: []const T) [s.len]T {
    var result: [s.len]T = undefined;
    inline for (s) |e, i| {
        result[i] = e;
    }
    return result;
}
