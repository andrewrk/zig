// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.

test "zig fmt: preserves clobbers in inline asm with stray comma" {
    try testTransform(
        \\fn foo() void {
        \\    asm volatile (""
        \\        : [_] "" (-> type),
        \\        :
        \\        : "clobber"
        \\    );
        \\    asm volatile (""
        \\        :
        \\        : [_] "" (type),
        \\        : "clobber"
        \\    );
        \\}
        \\
    ,
        \\fn foo() void {
        \\    asm volatile (""
        \\        : [_] "" (-> type)
        \\        :
        \\        : "clobber"
        \\    );
        \\    asm volatile (""
        \\        :
        \\        : [_] "" (type)
        \\        : "clobber"
        \\    );
        \\}
        \\
    );
}

test "zig fmt: respect line breaks in struct field value declaration" {
    try testCanonical(
        \\const Foo = struct {
        \\    bar: u32 =
        \\        42,
        \\    bar: u32 =
        \\        // a comment
        \\        42,
        \\    bar: u32 =
        \\        42,
        \\    // a comment
        \\    bar: []const u8 =
        \\        \\ foo
        \\        \\ bar
        \\        \\ baz
        \\    ,
        \\    bar: u32 =
        \\        blk: {
        \\            break :blk 42;
        \\        },
        \\};
        \\
    );
}

test "zig fmt: respect line breaks before functions" {
    try testCanonical(
        \\const std = @import("std");
        \\
        \\inline fn foo() void {}
        \\
        \\noinline fn foo() void {}
        \\
        \\export fn foo() void {}
        \\
        \\extern fn foo() void;
        \\
        \\extern "foo" fn foo() void;
        \\
    );
}

test "zig fmt: rewrite callconv(.Inline) to the inline keyword" {
    try testTransform(
        \\fn foo() callconv(.Inline) void {}
        \\const bar = .Inline;
        \\fn foo() callconv(bar) void {}
        \\
    ,
        \\inline fn foo() void {}
        \\const bar = .Inline;
        \\fn foo() callconv(bar) void {}
        \\
    );
}

// TODO Remove this after zig 0.9.0 is released.
test "zig fmt: rewrite @byteOffsetOf to @offsetOf" {
    try testTransform(
        \\fn foo() void {
        \\    @byteOffsetOf(Foo, "bar");
        \\}
        \\
    ,
        \\fn foo() void {
        \\    @offsetOf(Foo, "bar");
        \\}
        \\
    );
}

test "zig fmt: simple top level comptime block" {
    try testCanonical(
        \\// line comment
        \\comptime {}
        \\
    );
}

test "zig fmt: two spaced line comments before decl" {
    try testCanonical(
        \\// line comment
        \\
        \\// another
        \\comptime {}
        \\
    );
}

test "zig fmt: respect line breaks after var declarations" {
    try testCanonical(
        \\const crc =
        \\    lookup_tables[0][p[7]] ^
        \\    lookup_tables[1][p[6]] ^
        \\    lookup_tables[2][p[5]] ^
        \\    lookup_tables[3][p[4]] ^
        \\    lookup_tables[4][@truncate(u8, self.crc >> 24)] ^
        \\    lookup_tables[5][@truncate(u8, self.crc >> 16)] ^
        \\    lookup_tables[6][@truncate(u8, self.crc >> 8)] ^
        \\    lookup_tables[7][@truncate(u8, self.crc >> 0)];
        \\
    );
}

test "zig fmt: multiline string mixed with comments" {
    try testCanonical(
        \\const s1 =
        \\    //\\one
        \\    \\two)
        \\    \\three
        \\;
        \\const s2 =
        \\    \\one
        \\    \\two)
        \\    //\\three
        \\;
        \\const s3 =
        \\    \\one
        \\    //\\two)
        \\    \\three
        \\;
        \\const s4 =
        \\    \\one
        \\    //\\two
        \\    \\three
        \\    //\\four
        \\    \\five
        \\;
        \\const a =
        \\    1;
        \\
    );
}

test "zig fmt: empty file" {
    try testCanonical(
        \\
    );
}

test "zig fmt: file ends in comment" {
    try testTransform(
        \\     //foobar
    ,
        \\//foobar
        \\
    );
}

test "zig fmt: file ends in comment after var decl" {
    try testTransform(
        \\const x = 42;
        \\     //foobar
    ,
        \\const x = 42;
        \\//foobar
        \\
    );
}

test "zig fmt: doc comments on test" {
    try testCanonical(
        \\/// hello
        \\/// world
        \\test "" {}
        \\
    );
}

test "zig fmt: if statment" {
    try testCanonical(
        \\test "" {
        \\    if (optional()) |some|
        \\        bar = some.foo();
        \\}
        \\
    );
}

test "zig fmt: top-level fields" {
    try testCanonical(
        \\a: did_you_know,
        \\b: all_files_are,
        \\structs: ?x,
        \\
    );
}

test "zig fmt: decl between fields" {
    try testError(
        \\const S = struct {
        \\    const foo = 2;
        \\    const bar = 2;
        \\    const baz = 2;
        \\    a: usize,
        \\    const foo1 = 2;
        \\    const bar1 = 2;
        \\    const baz1 = 2;
        \\    b: usize,
        \\};
    , &[_]Error{
        .decl_between_fields,
    });
}

test "zig fmt: eof after missing comma" {
    try testError(
        \\foo()
    , &[_]Error{
        .expected_token,
    });
}

test "zig fmt: errdefer with payload" {
    try testCanonical(
        \\pub fn main() anyerror!void {
        \\    errdefer |a| x += 1;
        \\    errdefer |a| {}
        \\    errdefer |a| {
        \\        x += 1;
        \\    }
        \\}
        \\
    );
}

test "zig fmt: nosuspend block" {
    try testCanonical(
        \\pub fn main() anyerror!void {
        \\    nosuspend {
        \\        var foo: Foo = .{ .bar = 42 };
        \\    }
        \\}
        \\
    );
}

test "zig fmt: nosuspend await" {
    try testCanonical(
        \\fn foo() void {
        \\    x = nosuspend await y;
        \\}
        \\
    );
}

test "zig fmt: container declaration, single line" {
    try testCanonical(
        \\const X = struct { foo: i32 };
        \\const X = struct { foo: i32, bar: i32 };
        \\const X = struct { foo: i32 = 1, bar: i32 = 2 };
        \\const X = struct { foo: i32 align(4), bar: i32 align(4) };
        \\const X = struct { foo: i32 align(4) = 1, bar: i32 align(4) = 2 };
        \\
    );
}

test "zig fmt: container declaration, one item, multi line trailing comma" {
    try testCanonical(
        \\test "" {
        \\    comptime {
        \\        const X = struct {
        \\            x: i32,
        \\        };
        \\    }
        \\}
        \\
    );
}

test "zig fmt: container declaration, no trailing comma on separate line" {
    try testTransform(
        \\test "" {
        \\    comptime {
        \\        const X = struct {
        \\            x: i32
        \\        };
        \\    }
        \\}
        \\
    ,
        \\test "" {
        \\    comptime {
        \\        const X = struct { x: i32 };
        \\    }
        \\}
        \\
    );
}

test "zig fmt: container declaration, line break, no trailing comma" {
    try testTransform(
        \\const X = struct {
        \\    foo: i32, bar: i8 };
    ,
        \\const X = struct { foo: i32, bar: i8 };
        \\
    );
}

test "zig fmt: container declaration, transform trailing comma" {
    try testTransform(
        \\const X = struct {
        \\    foo: i32, bar: i8, };
    ,
        \\const X = struct {
        \\    foo: i32,
        \\    bar: i8,
        \\};
        \\
    );
}

test "zig fmt: remove empty lines at start/end of container decl" {
    try testTransform(
        \\const X = struct {
        \\
        \\    foo: i32,
        \\
        \\    bar: i8,
        \\
        \\};
        \\
    ,
        \\const X = struct {
        \\    foo: i32,
        \\
        \\    bar: i8,
        \\};
        \\
    );
}

test "zig fmt: remove empty lines at start/end of block" {
    try testTransform(
        \\test {
        \\
        \\    if (foo) {
        \\        foo();
        \\    }
        \\
        \\}
        \\
    ,
        \\test {
        \\    if (foo) {
        \\        foo();
        \\    }
        \\}
        \\
    );
}

test "zig fmt: allow empty line before commment at start of block" {
    try testCanonical(
        \\test {
        \\
        \\    // foo
        \\    const x = 42;
        \\}
        \\
    );
}

test "zig fmt: allow empty line before commment at start of block" {
    try testCanonical(
        \\test {
        \\
        \\    // foo
        \\    const x = 42;
        \\}
        \\
    );
}

test "zig fmt: trailing comma in fn parameter list" {
    try testCanonical(
        \\pub fn f(
        \\    a: i32,
        \\    b: i32,
        \\) i32 {}
        \\pub fn f(
        \\    a: i32,
        \\    b: i32,
        \\) align(8) i32 {}
        \\pub fn f(
        \\    a: i32,
        \\    b: i32,
        \\) linksection(".text") i32 {}
        \\pub fn f(
        \\    a: i32,
        \\    b: i32,
        \\) callconv(.C) i32 {}
        \\pub fn f(
        \\    a: i32,
        \\    b: i32,
        \\) align(8) linksection(".text") i32 {}
        \\pub fn f(
        \\    a: i32,
        \\    b: i32,
        \\) align(8) callconv(.C) i32 {}
        \\pub fn f(
        \\    a: i32,
        \\    b: i32,
        \\) align(8) linksection(".text") callconv(.C) i32 {}
        \\pub fn f(
        \\    a: i32,
        \\    b: i32,
        \\) linksection(".text") callconv(.C) i32 {}
        \\
    );
}

test "zig fmt: comptime struct field" {
    try testCanonical(
        \\const Foo = struct {
        \\    a: i32,
        \\    comptime b: i32 = 1234,
        \\};
        \\
    );
}

test "zig fmt: break from block" {
    try testCanonical(
        \\const a = blk: {
        \\    break :blk 42;
        \\};
        \\const b = blk: {
        \\    break :blk;
        \\};
        \\const c = {
        \\    break 42;
        \\};
        \\const d = {
        \\    break;
        \\};
        \\
    );
}

test "zig fmt: grouped expressions (parentheses)" {
    try testCanonical(
        \\const r = (x + y) * (a + b);
        \\
    );
}

test "zig fmt: c pointer type" {
    try testCanonical(
        \\pub extern fn repro() [*c]const u8;
        \\
    );
}

test "zig fmt: builtin call with trailing comma" {
    try testCanonical(
        \\pub fn main() void {
        \\    @breakpoint();
        \\    _ = @boolToInt(a);
        \\    _ = @call(
        \\        a,
        \\        b,
        \\        c,
        \\    );
        \\}
        \\
    );
}

test "zig fmt: asm expression with comptime content" {
    try testCanonical(
        \\comptime {
        \\    asm ("foo" ++ "bar");
        \\}
        \\pub fn main() void {
        \\    asm volatile ("foo" ++ "bar");
        \\    asm volatile ("foo" ++ "bar"
        \\        : [_] "" (x)
        \\    );
        \\    asm volatile ("foo" ++ "bar"
        \\        : [_] "" (x)
        \\        : [_] "" (y)
        \\    );
        \\    asm volatile ("foo" ++ "bar"
        \\        : [_] "" (x)
        \\        : [_] "" (y)
        \\        : "h", "e", "l", "l", "o"
        \\    );
        \\}
        \\
    );
}

test "zig fmt: anytype struct field" {
    try testCanonical(
        \\pub const Pointer = struct {
        \\    sentinel: anytype,
        \\};
        \\
    );
}

test "zig fmt: array types last token" {
    try testCanonical(
        \\test {
        \\    const x = [40]u32;
        \\}
        \\
        \\test {
        \\    const x = [40:0]u32;
        \\}
        \\
    );
}

test "zig fmt: sentinel-terminated array type" {
    try testCanonical(
        \\pub fn cStrToPrefixedFileW(s: [*:0]const u8) ![PATH_MAX_WIDE:0]u16 {
        \\    return sliceToPrefixedFileW(mem.toSliceConst(u8, s));
        \\}
        \\
    );
}

test "zig fmt: sentinel-terminated slice type" {
    try testCanonical(
        \\pub fn toSlice(self: Buffer) [:0]u8 {
        \\    return self.list.toSlice()[0..self.len()];
        \\}
        \\
    );
}

test "zig fmt: pointer-to-one with modifiers" {
    try testCanonical(
        \\const x: *u32 = undefined;
        \\const y: *allowzero align(8) const volatile u32 = undefined;
        \\const z: *allowzero align(8:4:2) const volatile u32 = undefined;
        \\
    );
}

test "zig fmt: pointer-to-many with modifiers" {
    try testCanonical(
        \\const x: [*]u32 = undefined;
        \\const y: [*]allowzero align(8) const volatile u32 = undefined;
        \\const z: [*]allowzero align(8:4:2) const volatile u32 = undefined;
        \\
    );
}

test "zig fmt: sentinel pointer with modifiers" {
    try testCanonical(
        \\const x: [*:42]u32 = undefined;
        \\const y: [*:42]allowzero align(8) const volatile u32 = undefined;
        \\const y: [*:42]allowzero align(8:4:2) const volatile u32 = undefined;
        \\
    );
}

test "zig fmt: c pointer with modifiers" {
    try testCanonical(
        \\const x: [*c]u32 = undefined;
        \\const y: [*c]allowzero align(8) const volatile u32 = undefined;
        \\const z: [*c]allowzero align(8:4:2) const volatile u32 = undefined;
        \\
    );
}

test "zig fmt: slice with modifiers" {
    try testCanonical(
        \\const x: []u32 = undefined;
        \\const y: []allowzero align(8) const volatile u32 = undefined;
        \\
    );
}

test "zig fmt: sentinel slice with modifiers" {
    try testCanonical(
        \\const x: [:42]u32 = undefined;
        \\const y: [:42]allowzero align(8) const volatile u32 = undefined;
        \\
    );
}

test "zig fmt: anon literal in array" {
    try testCanonical(
        \\var arr: [2]Foo = .{
        \\    .{ .a = 2 },
        \\    .{ .b = 3 },
        \\};
        \\
    );
}

test "zig fmt: alignment in anonymous literal" {
    try testTransform(
        \\const a = .{
        \\    "U",     "L",     "F",
        \\    "U'",
        \\    "L'",
        \\    "F'",
        \\};
        \\
    ,
        \\const a = .{
        \\    "U",  "L",  "F",
        \\    "U'", "L'", "F'",
        \\};
        \\
    );
}

test "zig fmt: anon struct literal 0 element" {
    try testCanonical(
        \\test {
        \\    const x = .{};
        \\}
        \\
    );
}

test "zig fmt: anon struct literal 1 element" {
    try testCanonical(
        \\test {
        \\    const x = .{ .a = b };
        \\}
        \\
    );
}

test "zig fmt: anon struct literal 1 element comma" {
    try testCanonical(
        \\test {
        \\    const x = .{
        \\        .a = b,
        \\    };
        \\}
        \\
    );
}

test "zig fmt: anon struct literal 2 element" {
    try testCanonical(
        \\test {
        \\    const x = .{ .a = b, .c = d };
        \\}
        \\
    );
}

test "zig fmt: anon struct literal 2 element comma" {
    try testCanonical(
        \\test {
        \\    const x = .{
        \\        .a = b,
        \\        .c = d,
        \\    };
        \\}
        \\
    );
}

test "zig fmt: anon struct literal 3 element" {
    try testCanonical(
        \\test {
        \\    const x = .{ .a = b, .c = d, .e = f };
        \\}
        \\
    );
}

test "zig fmt: anon struct literal 3 element comma" {
    try testCanonical(
        \\test {
        \\    const x = .{
        \\        .a = b,
        \\        .c = d,
        \\        .e = f,
        \\    };
        \\}
        \\
    );
}

test "zig fmt: struct literal 0 element" {
    try testCanonical(
        \\test {
        \\    const x = X{};
        \\}
        \\
    );
}

test "zig fmt: struct literal 1 element" {
    try testCanonical(
        \\test {
        \\    const x = X{ .a = b };
        \\}
        \\
    );
}

test "zig fmt: Unicode code point literal larger than u8" {
    try testCanonical(
        \\test {
        \\    const x = X{
        \\        .a = b,
        \\    };
        \\}
        \\
    );
}

test "zig fmt: struct literal 2 element" {
    try testCanonical(
        \\test {
        \\    const x = X{ .a = b, .c = d };
        \\}
        \\
    );
}

test "zig fmt: struct literal 2 element comma" {
    try testCanonical(
        \\test {
        \\    const x = X{
        \\        .a = b,
        \\        .c = d,
        \\    };
        \\}
        \\
    );
}

test "zig fmt: struct literal 3 element" {
    try testCanonical(
        \\test {
        \\    const x = X{ .a = b, .c = d, .e = f };
        \\}
        \\
    );
}

test "zig fmt: struct literal 3 element comma" {
    try testCanonical(
        \\test {
        \\    const x = X{
        \\        .a = b,
        \\        .c = d,
        \\        .e = f,
        \\    };
        \\}
        \\
    );
}

test "zig fmt: anon list literal 1 element" {
    try testCanonical(
        \\test {
        \\    const x = .{a};
        \\}
        \\
    );
}

test "zig fmt: anon list literal 1 element comma" {
    try testCanonical(
        \\test {
        \\    const x = .{
        \\        a,
        \\    };
        \\}
        \\
    );
}

test "zig fmt: anon list literal 2 element" {
    try testCanonical(
        \\test {
        \\    const x = .{ a, b };
        \\}
        \\
    );
}

test "zig fmt: anon list literal 2 element comma" {
    try testCanonical(
        \\test {
        \\    const x = .{
        \\        a,
        \\        b,
        \\    };
        \\}
        \\
    );
}

test "zig fmt: anon list literal 3 element" {
    try testCanonical(
        \\test {
        \\    const x = .{ a, b, c };
        \\}
        \\
    );
}

test "zig fmt: anon list literal 3 element comma" {
    try testCanonical(
        \\test {
        \\    const x = .{
        \\        a,
        \\        // foo
        \\        b,
        \\
        \\        c,
        \\    };
        \\}
        \\
    );
}

test "zig fmt: array literal 0 element" {
    try testCanonical(
        \\test {
        \\    const x = [_]u32{};
        \\}
        \\
    );
}

test "zig fmt: array literal 1 element" {
    try testCanonical(
        \\test {
        \\    const x = [_]u32{a};
        \\}
        \\
    );
}

test "zig fmt: array literal 1 element comma" {
    try testCanonical(
        \\test {
        \\    const x = [1]u32{
        \\        a,
        \\    };
        \\}
        \\
    );
}

test "zig fmt: array literal 2 element" {
    try testCanonical(
        \\test {
        \\    const x = [_]u32{ a, b };
        \\}
        \\
    );
}

test "zig fmt: array literal 2 element comma" {
    try testCanonical(
        \\test {
        \\    const x = [2]u32{
        \\        a,
        \\        b,
        \\    };
        \\}
        \\
    );
}

test "zig fmt: array literal 3 element" {
    try testCanonical(
        \\test {
        \\    const x = [_]u32{ a, b, c };
        \\}
        \\
    );
}

test "zig fmt: array literal 3 element comma" {
    try testCanonical(
        \\test {
        \\    const x = [3]u32{
        \\        a,
        \\        b,
        \\        c,
        \\    };
        \\}
        \\
    );
}

test "zig fmt: sentinel array literal 1 element" {
    try testCanonical(
        \\test {
        \\    const x = [_:9000]u32{a};
        \\}
        \\
    );
}

test "zig fmt: slices" {
    try testCanonical(
        \\const a = b[0..];
        \\const c = d[0..1];
        \\const d = f[0.. :0];
        \\const e = f[0..1 :0];
        \\
    );
}

test "zig fmt: slices with spaces in bounds" {
    try testCanonical(
        \\const a = b[0 + 0 ..];
        \\const c = d[0 + 0 .. 1];
        \\const c = d[0 + 0 .. :0];
        \\const e = f[0 .. 1 + 1 :0];
        \\
    );
}

test "zig fmt: block in slice expression" {
    try testCanonical(
        \\const a = b[{
        \\    _ = x;
        \\}..];
        \\const c = d[0..{
        \\    _ = x;
        \\    _ = y;
        \\}];
        \\const e = f[0..1 :{
        \\    _ = x;
        \\    _ = y;
        \\    _ = z;
        \\}];
        \\
    );
}

test "zig fmt: async function" {
    try testCanonical(
        \\pub const Server = struct {
        \\    handleRequestFn: fn (*Server, *const std.net.Address, File) callconv(.Async) void,
        \\};
        \\test "hi" {
        \\    var ptr = @ptrCast(fn (i32) callconv(.Async) void, other);
        \\}
        \\
    );
}

test "zig fmt: whitespace fixes" {
    try testTransform("test \"\" {\r\n\tconst hi = x;\r\n}\n// zig fmt: off\ntest \"\"{\r\n\tconst a  = b;}\r\n",
        \\test "" {
        \\    const hi = x;
        \\}
        \\// zig fmt: off
        \\test ""{
        \\    const a  = b;}
        \\
    );
}

test "zig fmt: while else err prong with no block" {
    try testCanonical(
        \\test "" {
        \\    const result = while (returnError()) |value| {
        \\        break value;
        \\    } else |err| @as(i32, 2);
        \\    try expect(result == 2);
        \\}
        \\
    );
}

test "zig fmt: tagged union with enum values" {
    try testCanonical(
        \\const MultipleChoice2 = union(enum(u32)) {
        \\    Unspecified1: i32,
        \\    A: f32 = 20,
        \\    Unspecified2: void,
        \\    B: bool = 40,
        \\    Unspecified3: i32,
        \\    C: i8 = 60,
        \\    Unspecified4: void,
        \\    D: void = 1000,
        \\    Unspecified5: i32,
        \\};
        \\
    );
}

test "zig fmt: tagged union enum tag last token" {
    try testCanonical(
        \\test {
        \\    const U = union(enum(u32)) {};
        \\}
        \\
        \\test {
        \\    const U = union(enum(u32)) { foo };
        \\}
        \\
        \\test {
        \\    const U = union(enum(u32)) {
        \\        foo,
        \\    };
        \\}
        \\
    );
}

test "zig fmt: allowzero pointer" {
    try testCanonical(
        \\const T = [*]allowzero const u8;
        \\
    );
}

test "zig fmt: empty enum decls" {
    try testCanonical(
        \\const A = enum {};
        \\const B = enum(u32) {};
        \\const C = extern enum(c_int) {};
        \\const D = packed enum(u8) {};
        \\
    );
}

test "zig fmt: empty union decls" {
    try testCanonical(
        \\const A = union {};
        \\const B = union(enum) {};
        \\const C = union(Foo) {};
        \\const D = extern union {};
        \\const E = packed union {};
        \\
    );
}

test "zig fmt: enum literal" {
    try testCanonical(
        \\const x = .hi;
        \\
    );
}

test "zig fmt: enum literal inside array literal" {
    try testCanonical(
        \\test "enums in arrays" {
        \\    var colors = []Color{.Green};
        \\    colors = []Colors{ .Green, .Cyan };
        \\    colors = []Colors{
        \\        .Grey,
        \\        .Green,
        \\        .Cyan,
        \\    };
        \\}
        \\
    );
}

test "zig fmt: character literal larger than u8" {
    try testCanonical(
        \\const x = '\u{01f4a9}';
        \\
    );
}

test "zig fmt: infix operator and then multiline string literal" {
    try testCanonical(
        \\const x = "" ++
        \\    \\ hi
        \\;
        \\
    );
}

test "zig fmt: infix operator and then multiline string literal" {
    try testCanonical(
        \\const x = "" ++
        \\    \\ hi0
        \\    \\ hi1
        \\    \\ hi2
        \\;
        \\
    );
}

test "zig fmt: C pointers" {
    try testCanonical(
        \\const Ptr = [*c]i32;
        \\
    );
}

test "zig fmt: threadlocal" {
    try testCanonical(
        \\threadlocal var x: i32 = 1234;
        \\
    );
}

test "zig fmt: linksection" {
    try testCanonical(
        \\export var aoeu: u64 linksection(".text.derp") = 1234;
        \\export fn _start() linksection(".text.boot") callconv(.Naked) noreturn {}
        \\
    );
}

test "zig fmt: correctly space struct fields with doc comments" {
    try testTransform(
        \\pub const S = struct {
        \\    /// A
        \\    a: u8,
        \\    /// B
        \\    /// B (cont)
        \\    b: u8,
        \\
        \\
        \\    /// C
        \\    c: u8,
        \\};
        \\
    ,
        \\pub const S = struct {
        \\    /// A
        \\    a: u8,
        \\    /// B
        \\    /// B (cont)
        \\    b: u8,
        \\
        \\    /// C
        \\    c: u8,
        \\};
        \\
    );
}

test "zig fmt: doc comments on param decl" {
    try testCanonical(
        \\pub const Allocator = struct {
        \\    shrinkFn: fn (
        \\        self: *Allocator,
        \\        /// Guaranteed to be the same as what was returned from most recent call to
        \\        /// `allocFn`, `reallocFn`, or `shrinkFn`.
        \\        old_mem: []u8,
        \\        /// Guaranteed to be the same as what was returned from most recent call to
        \\        /// `allocFn`, `reallocFn`, or `shrinkFn`.
        \\        old_alignment: u29,
        \\        /// Guaranteed to be less than or equal to `old_mem.len`.
        \\        new_byte_count: usize,
        \\        /// Guaranteed to be less than or equal to `old_alignment`.
        \\        new_alignment: u29,
        \\    ) []u8,
        \\};
        \\
    );
}

test "zig fmt: aligned struct field" {
    try testCanonical(
        \\pub const S = struct {
        \\    f: i32 align(32),
        \\};
        \\
    );
    try testCanonical(
        \\pub const S = struct {
        \\    f: i32 align(32) = 1,
        \\};
        \\
    );
}

test "zig fmt: comment to disable/enable zig fmt first" {
    try testCanonical(
        \\// Test trailing comma syntax
        \\// zig fmt: off
        \\
        \\const struct_trailing_comma = struct { x: i32, y: i32, };
    );
}

test "zig fmt: 'zig fmt: (off|on)' can be surrounded by arbitrary whitespace" {
    try testTransform(
        \\// Test trailing comma syntax
        \\//     zig fmt: off
        \\
        \\const struct_trailing_comma = struct { x: i32, y: i32, };
        \\
        \\//   zig fmt: on
    ,
        \\// Test trailing comma syntax
        \\// zig fmt: off
        \\
        \\const struct_trailing_comma = struct { x: i32, y: i32, };
        \\
        \\// zig fmt: on
        \\
    );
}

test "zig fmt: comment to disable/enable zig fmt" {
    try testTransform(
        \\const  a  =  b;
        \\// zig fmt: off
        \\const  c  =  d;
        \\// zig fmt: on
        \\const  e  =  f;
    ,
        \\const a = b;
        \\// zig fmt: off
        \\const  c  =  d;
        \\// zig fmt: on
        \\const e = f;
        \\
    );
}

test "zig fmt: line comment following 'zig fmt: off'" {
    try testCanonical(
        \\// zig fmt: off
        \\// Test
        \\const  e  =  f;
    );
}

test "zig fmt: doc comment following 'zig fmt: off'" {
    try testCanonical(
        \\// zig fmt: off
        \\/// test
        \\const  e  =  f;
    );
}

test "zig fmt: line and doc comment following 'zig fmt: off'" {
    try testCanonical(
        \\// zig fmt: off
        \\// test 1
        \\/// test 2
        \\const  e  =  f;
    );
}

test "zig fmt: doc and line comment following 'zig fmt: off'" {
    try testCanonical(
        \\// zig fmt: off
        \\/// test 1
        \\// test 2
        \\const  e  =  f;
    );
}

test "zig fmt: alternating 'zig fmt: off' and 'zig fmt: on'" {
    try testCanonical(
        \\// zig fmt: off
        \\// zig fmt: on
        \\// zig fmt: off
        \\const  e  =  f;
        \\// zig fmt: off
        \\// zig fmt: on
        \\// zig fmt: off
        \\const  a  =  b;
        \\// zig fmt: on
        \\const c = d;
        \\// zig fmt: on
        \\
    );
}

test "zig fmt: line comment following 'zig fmt: on'" {
    try testCanonical(
        \\// zig fmt: off
        \\const  e  =  f;
        \\// zig fmt: on
        \\// test
        \\const e = f;
        \\
    );
}

test "zig fmt: doc comment following 'zig fmt: on'" {
    try testCanonical(
        \\// zig fmt: off
        \\const  e  =  f;
        \\// zig fmt: on
        \\/// test
        \\const e = f;
        \\
    );
}

test "zig fmt: line and doc comment following 'zig fmt: on'" {
    try testCanonical(
        \\// zig fmt: off
        \\const  e  =  f;
        \\// zig fmt: on
        \\// test1
        \\/// test2
        \\const e = f;
        \\
    );
}

test "zig fmt: doc and line comment following 'zig fmt: on'" {
    try testCanonical(
        \\// zig fmt: off
        \\const  e  =  f;
        \\// zig fmt: on
        \\/// test1
        \\// test2
        \\const e = f;
        \\
    );
}

test "zig fmt: 'zig fmt: (off|on)' works in the middle of code" {
    try testTransform(
        \\test "" {
        \\    const x = 42;
        \\
        \\    if (foobar) |y| {
        \\    // zig fmt: off
        \\            }// zig fmt: on
        \\
        \\    const  z  = 420;
        \\}
        \\
    ,
        \\test "" {
        \\    const x = 42;
        \\
        \\    if (foobar) |y| {
        \\        // zig fmt: off
        \\            }// zig fmt: on
        \\
        \\    const z = 420;
        \\}
        \\
    );
}

test "zig fmt: 'zig fmt: on' indentation is unchanged" {
    try testCanonical(
        \\fn initOptionsAndLayouts(output: *Output, context: *Context) !void {
        \\    // zig fmt: off
        \\    try output.main_amount.init(output, "main_amount"); errdefer optput.main_amount.deinit();
        \\    try output.main_factor.init(output, "main_factor"); errdefer optput.main_factor.deinit();
        \\    try output.view_padding.init(output, "view_padding"); errdefer optput.view_padding.deinit();
        \\    try output.outer_padding.init(output, "outer_padding"); errdefer optput.outer_padding.deinit();
        \\    // zig fmt: on
        \\
        \\    // zig fmt: off
        \\    try output.top.init(output, .top); errdefer optput.top.deinit();
        \\    try output.right.init(output, .right); errdefer optput.right.deinit();
        \\    try output.bottom.init(output, .bottom); errdefer optput.bottom.deinit();
        \\    try output.left.init(output, .left); errdefer optput.left.deinit();
        \\        // zig fmt: on
        \\}
        \\
    );
}

test "zig fmt: pointer of unknown length" {
    try testCanonical(
        \\fn foo(ptr: [*]u8) void {}
        \\
    );
}

test "zig fmt: spaces around slice operator" {
    try testCanonical(
        \\var a = b[c..d];
        \\var a = b[c..d :0];
        \\var a = b[c + 1 .. d];
        \\var a = b[c + 1 ..];
        \\var a = b[c .. d + 1];
        \\var a = b[c .. d + 1 :0];
        \\var a = b[c.a..d.e];
        \\var a = b[c.a..d.e :0];
        \\
    );
}

test "zig fmt: async call in if condition" {
    try testCanonical(
        \\comptime {
        \\    if (async b()) {
        \\        a();
        \\    }
        \\}
        \\
    );
}

test "zig fmt: 2nd arg multiline string" {
    try testCanonical(
        \\comptime {
        \\    cases.addAsm("hello world linux x86_64",
        \\        \\.text
        \\    , "Hello, world!\n");
        \\}
        \\
    );
    try testTransform(
        \\comptime {
        \\    cases.addAsm("hello world linux x86_64",
        \\        \\.text
        \\    , "Hello, world!\n",);
        \\}
    ,
        \\comptime {
        \\    cases.addAsm(
        \\        "hello world linux x86_64",
        \\        \\.text
        \\    ,
        \\        "Hello, world!\n",
        \\    );
        \\}
        \\
    );
}

test "zig fmt: 2nd arg multiline string many args" {
    try testCanonical(
        \\comptime {
        \\    cases.addAsm("hello world linux x86_64",
        \\        \\.text
        \\    , "Hello, world!\n", "Hello, world!\n");
        \\}
        \\
    );
}

test "zig fmt: final arg multiline string" {
    try testCanonical(
        \\comptime {
        \\    cases.addAsm("hello world linux x86_64", "Hello, world!\n",
        \\        \\.text
        \\    );
        \\}
        \\
    );
}

test "zig fmt: if condition wraps" {
    try testTransform(
        \\comptime {
        \\    if (cond and
        \\        cond) {
        \\        return x;
        \\    }
        \\    while (cond and
        \\        cond) {
        \\        return x;
        \\    }
        \\    if (a == b and
        \\        c) {
        \\        a = b;
        \\    }
        \\    while (a == b and
        \\        c) {
        \\        a = b;
        \\    }
        \\    if ((cond and
        \\        cond)) {
        \\        return x;
        \\    }
        \\    while ((cond and
        \\        cond)) {
        \\        return x;
        \\    }
        \\    var a = if (a) |*f| x: {
        \\        break :x &a.b;
        \\    } else |err| err;
        \\    var a = if (cond and
        \\                cond) |*f|
        \\    x: {
        \\        break :x &a.b;
        \\    } else |err| err;
        \\}
    ,
        \\comptime {
        \\    if (cond and
        \\        cond)
        \\    {
        \\        return x;
        \\    }
        \\    while (cond and
        \\        cond)
        \\    {
        \\        return x;
        \\    }
        \\    if (a == b and
        \\        c)
        \\    {
        \\        a = b;
        \\    }
        \\    while (a == b and
        \\        c)
        \\    {
        \\        a = b;
        \\    }
        \\    if ((cond and
        \\        cond))
        \\    {
        \\        return x;
        \\    }
        \\    while ((cond and
        \\        cond))
        \\    {
        \\        return x;
        \\    }
        \\    var a = if (a) |*f| x: {
        \\        break :x &a.b;
        \\    } else |err| err;
        \\    var a = if (cond and
        \\        cond) |*f|
        \\    x: {
        \\        break :x &a.b;
        \\    } else |err| err;
        \\}
        \\
    );
}

test "zig fmt: if condition has line break but must not wrap" {
    try testCanonical(
        \\comptime {
        \\    if (self.user_input_options.put(
        \\        name,
        \\        UserInputOption{
        \\            .name = name,
        \\            .used = false,
        \\        },
        \\    ) catch unreachable) |*prev_value| {
        \\        foo();
        \\        bar();
        \\    }
        \\    if (put(
        \\        a,
        \\        b,
        \\    )) {
        \\        foo();
        \\    }
        \\}
        \\
    );
}

test "zig fmt: if condition has line break but must not wrap (no fn call comma)" {
    try testCanonical(
        \\comptime {
        \\    if (self.user_input_options.put(name, UserInputOption{
        \\        .name = name,
        \\        .used = false,
        \\    }) catch unreachable) |*prev_value| {
        \\        foo();
        \\        bar();
        \\    }
        \\    if (put(
        \\        a,
        \\        b,
        \\    )) {
        \\        foo();
        \\    }
        \\}
        \\
    );
}

test "zig fmt: function call with multiline argument" {
    try testCanonical(
        \\comptime {
        \\    self.user_input_options.put(name, UserInputOption{
        \\        .name = name,
        \\        .used = false,
        \\    });
        \\}
        \\
    );
}

test "zig fmt: if-else with comment before else" {
    try testCanonical(
        \\comptime {
        \\    // cexp(finite|nan +- i inf|nan) = nan + i nan
        \\    if ((hx & 0x7fffffff) != 0x7f800000) {
        \\        return Complex(f32).init(y - y, y - y);
        \\    } // cexp(-inf +- i inf|nan) = 0 + i0
        \\    else if (hx & 0x80000000 != 0) {
        \\        return Complex(f32).init(0, 0);
        \\    } // cexp(+inf +- i inf|nan) = inf + i nan
        \\    else {
        \\        return Complex(f32).init(x, y - y);
        \\    }
        \\}
        \\
    );
}

test "zig fmt: if nested" {
    try testCanonical(
        \\pub fn foo() void {
        \\    return if ((aInt & bInt) >= 0)
        \\        if (aInt < bInt)
        \\            GE_LESS
        \\        else if (aInt == bInt)
        \\            GE_EQUAL
        \\        else
        \\            GE_GREATER
        \\        // comment
        \\    else if (aInt > bInt)
        \\        GE_LESS
        \\    else if (aInt == bInt)
        \\        GE_EQUAL
        \\    else
        \\        GE_GREATER;
        \\    // comment
        \\}
        \\
    );
}

test "zig fmt: respect line breaks in if-else" {
    try testCanonical(
        \\comptime {
        \\    return if (cond) a else b;
        \\    return if (cond)
        \\        a
        \\    else
        \\        b;
        \\    return if (cond)
        \\        a
        \\    else if (cond)
        \\        b
        \\    else
        \\        c;
        \\}
        \\
    );
}

test "zig fmt: respect line breaks after infix operators" {
    try testCanonical(
        \\comptime {
        \\    self.crc =
        \\        lookup_tables[0][p[7]] ^
        \\        lookup_tables[1][p[6]] ^
        \\        lookup_tables[2][p[5]] ^
        \\        lookup_tables[3][p[4]] ^
        \\        lookup_tables[4][@truncate(u8, self.crc >> 24)] ^
        \\        lookup_tables[5][@truncate(u8, self.crc >> 16)] ^
        \\        lookup_tables[6][@truncate(u8, self.crc >> 8)] ^
        \\        lookup_tables[7][@truncate(u8, self.crc >> 0)];
        \\}
        \\
    );
}

test "zig fmt: fn decl with trailing comma" {
    try testTransform(
        \\fn foo(a: i32, b: i32,) void {}
    ,
        \\fn foo(
        \\    a: i32,
        \\    b: i32,
        \\) void {}
        \\
    );
}

test "zig fmt: enum decl with no trailing comma" {
    try testTransform(
        \\const StrLitKind = enum {Normal, C};
    ,
        \\const StrLitKind = enum { Normal, C };
        \\
    );
}

test "zig fmt: switch comment before prong" {
    try testCanonical(
        \\comptime {
        \\    switch (a) {
        \\        // hi
        \\        0 => {},
        \\    }
        \\}
        \\
    );
}

test "zig fmt: struct literal no trailing comma" {
    try testTransform(
        \\const a = foo{ .x = 1, .y = 2 };
        \\const a = foo{ .x = 1,
        \\    .y = 2 };
        \\const a = foo{ .x = 1,
        \\    .y = 2, };
    ,
        \\const a = foo{ .x = 1, .y = 2 };
        \\const a = foo{ .x = 1, .y = 2 };
        \\const a = foo{
        \\    .x = 1,
        \\    .y = 2,
        \\};
        \\
    );
}

test "zig fmt: struct literal containing a multiline expression" {
    try testTransform(
        \\const a = A{ .x = if (f1()) 10 else 20 };
        \\const a = A{ .x = if (f1()) 10 else 20, };
        \\const a = A{ .x = if (f1())
        \\    10 else 20 };
        \\const a = A{ .x = if (f1())
        \\    10 else 20,};
        \\const a = A{ .x = if (f1()) 10 else 20, .y = f2() + 100 };
        \\const a = A{ .x = if (f1()) 10 else 20, .y = f2() + 100, };
        \\const a = A{ .x = if (f1())
        \\    10 else 20};
        \\const a = A{ .x = if (f1())
        \\    10 else 20,};
        \\const a = A{ .x = switch(g) {0 => "ok", else => "no"} };
        \\const a = A{ .x = switch(g) {0 => "ok", else => "no"}, };
        \\
    ,
        \\const a = A{ .x = if (f1()) 10 else 20 };
        \\const a = A{
        \\    .x = if (f1()) 10 else 20,
        \\};
        \\const a = A{ .x = if (f1())
        \\    10
        \\else
        \\    20 };
        \\const a = A{
        \\    .x = if (f1())
        \\        10
        \\    else
        \\        20,
        \\};
        \\const a = A{ .x = if (f1()) 10 else 20, .y = f2() + 100 };
        \\const a = A{
        \\    .x = if (f1()) 10 else 20,
        \\    .y = f2() + 100,
        \\};
        \\const a = A{ .x = if (f1())
        \\    10
        \\else
        \\    20 };
        \\const a = A{
        \\    .x = if (f1())
        \\        10
        \\    else
        \\        20,
        \\};
        \\const a = A{ .x = switch (g) {
        \\    0 => "ok",
        \\    else => "no",
        \\} };
        \\const a = A{
        \\    .x = switch (g) {
        \\        0 => "ok",
        \\        else => "no",
        \\    },
        \\};
        \\
    );
}

test "zig fmt: array literal with hint" {
    try testTransform(
        \\const a = []u8{
        \\    1, 2, //
        \\    3,
        \\    4,
        \\    5,
        \\    6,
        \\    7 };
        \\const a = []u8{
        \\    1, 2, //
        \\    3,
        \\    4,
        \\    5,
        \\    6,
        \\    7, 8 };
        \\const a = []u8{
        \\    1, 2, //
        \\    3,
        \\    4,
        \\    5,
        \\    6, // blah
        \\    7, 8 };
        \\const a = []u8{
        \\    1, 2, //
        \\    3, //
        \\    4,
        \\    5,
        \\    6,
        \\    7 };
        \\const a = []u8{
        \\    1,
        \\    2,
        \\    3, 4, //
        \\    5, 6, //
        \\    7, 8, //
        \\};
    ,
        \\const a = []u8{
        \\    1, 2, //
        \\    3, 4,
        \\    5, 6,
        \\    7,
        \\};
        \\const a = []u8{
        \\    1, 2, //
        \\    3, 4,
        \\    5, 6,
        \\    7, 8,
        \\};
        \\const a = []u8{
        \\    1, 2, //
        \\    3, 4,
        \\    5,
        \\    6, // blah
        \\    7,
        \\    8,
        \\};
        \\const a = []u8{
        \\    1, 2, //
        \\    3, //
        \\    4,
        \\    5,
        \\    6,
        \\    7,
        \\};
        \\const a = []u8{
        \\    1,
        \\    2,
        \\    3, 4, //
        \\    5, 6, //
        \\    7, 8, //
        \\};
        \\
    );
}

test "zig fmt: array literal vertical column alignment" {
    try testTransform(
        \\const a = []u8{
        \\    1000, 200,
        \\    30, 4,
        \\    50000, 60,
        \\};
        \\const a = []u8{0,   1, 2, 3, 40,
        \\    4,5,600,7,
        \\           80,
        \\    9, 10, 11, 0, 13, 14, 15,};
        \\const a = [12]u8{
        \\    31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
        \\const a = [12]u8{
        \\    31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31, };
        \\
    ,
        \\const a = []u8{
        \\    1000,  200,
        \\    30,    4,
        \\    50000, 60,
        \\};
        \\const a = []u8{
        \\    0,  1,  2,   3, 40,
        \\    4,  5,  600, 7, 80,
        \\    9,  10, 11,  0, 13,
        \\    14, 15,
        \\};
        \\const a = [12]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
        \\const a = [12]u8{
        \\    31,
        \\    28,
        \\    31,
        \\    30,
        \\    31,
        \\    30,
        \\    31,
        \\    31,
        \\    30,
        \\    31,
        \\    30,
        \\    31,
        \\};
        \\
    );
}

test "zig fmt: multiline string with backslash at end of line" {
    try testCanonical(
        \\comptime {
        \\    err(
        \\        \\\
        \\    );
        \\}
        \\
    );
}

test "zig fmt: multiline string parameter in fn call with trailing comma" {
    try testCanonical(
        \\fn foo() void {
        \\    try stdout.print(
        \\        \\ZIG_CMAKE_BINARY_DIR {}
        \\        \\ZIG_C_HEADER_FILES   {}
        \\        \\ZIG_DIA_GUIDS_LIB    {}
        \\        \\
        \\    ,
        \\        std.cstr.toSliceConst(c.ZIG_CMAKE_BINARY_DIR),
        \\        std.cstr.toSliceConst(c.ZIG_CXX_COMPILER),
        \\        std.cstr.toSliceConst(c.ZIG_DIA_GUIDS_LIB),
        \\    );
        \\}
        \\
    );
}

test "zig fmt: trailing comma on fn call" {
    try testCanonical(
        \\comptime {
        \\    var module = try Module.create(
        \\        allocator,
        \\        zig_lib_dir,
        \\        full_cache_dir,
        \\    );
        \\}
        \\
    );
}

test "zig fmt: multi line arguments without last comma" {
    try testTransform(
        \\pub fn foo(
        \\    a: usize,
        \\    b: usize,
        \\    c: usize,
        \\    d: usize
        \\) usize {
        \\    return a + b + c + d;
        \\}
        \\
    ,
        \\pub fn foo(a: usize, b: usize, c: usize, d: usize) usize {
        \\    return a + b + c + d;
        \\}
        \\
    );
}

test "zig fmt: empty block with only comment" {
    try testCanonical(
        \\comptime {
        \\    {
        \\        // comment
        \\    }
        \\}
        \\
    );
}

test "zig fmt: trailing commas on struct decl" {
    try testTransform(
        \\const RoundParam = struct {
        \\    k: usize, s: u32, t: u32
        \\};
        \\const RoundParam = struct {
        \\    k: usize, s: u32, t: u32,
        \\};
    ,
        \\const RoundParam = struct { k: usize, s: u32, t: u32 };
        \\const RoundParam = struct {
        \\    k: usize,
        \\    s: u32,
        \\    t: u32,
        \\};
        \\
    );
}

test "zig fmt: extra newlines at the end" {
    try testTransform(
        \\const a = b;
        \\
        \\
        \\
    ,
        \\const a = b;
        \\
    );
}

test "zig fmt: simple asm" {
    try testTransform(
        \\comptime {
        \\    asm volatile (
        \\        \\.globl aoeu;
        \\        \\.type aoeu, @function;
        \\        \\.set aoeu, derp;
        \\    );
        \\
        \\    asm ("not real assembly"
        \\        :[a] "x" (x),);
        \\    asm ("not real assembly"
        \\        :[a] "x" (->i32),:[a] "x" (1),);
        \\    asm ("still not real assembly"
        \\        :::"a","b",);
        \\}
    ,
        \\comptime {
        \\    asm volatile (
        \\        \\.globl aoeu;
        \\        \\.type aoeu, @function;
        \\        \\.set aoeu, derp;
        \\    );
        \\
        \\    asm ("not real assembly"
        \\        : [a] "x" (x)
        \\    );
        \\    asm ("not real assembly"
        \\        : [a] "x" (-> i32)
        \\        : [a] "x" (1)
        \\    );
        \\    asm ("still not real assembly" ::: "a", "b");
        \\}
        \\
    );
}

test "zig fmt: nested struct literal with one item" {
    try testCanonical(
        \\const a = foo{
        \\    .item = bar{ .a = b },
        \\};
        \\
    );
}

test "zig fmt: switch cases trailing comma" {
    try testTransform(
        \\test "switch cases trailing comma"{
        \\    switch (x) {
        \\        1,2,3 => {},
        \\        4,5, => {},
        \\        6... 8, => {},
        \\        else => {},
        \\    }
        \\}
    ,
        \\test "switch cases trailing comma" {
        \\    switch (x) {
        \\        1, 2, 3 => {},
        \\        4,
        \\        5,
        \\        => {},
        \\        6...8 => {},
        \\        else => {},
        \\    }
        \\}
        \\
    );
}

test "zig fmt: slice align" {
    try testCanonical(
        \\const A = struct {
        \\    items: []align(A) T,
        \\};
        \\
    );
}

test "zig fmt: add trailing comma to array literal" {
    try testTransform(
        \\comptime {
        \\    return []u16{'m', 's', 'y', 's', '-' // hi
        \\   };
        \\    return []u16{'m', 's', 'y', 's',
        \\      '-'};
        \\    return []u16{'m', 's', 'y', 's', '-'};
        \\}
    ,
        \\comptime {
        \\    return []u16{
        \\        'm', 's', 'y', 's', '-', // hi
        \\    };
        \\    return []u16{ 'm', 's', 'y', 's', '-' };
        \\    return []u16{ 'm', 's', 'y', 's', '-' };
        \\}
        \\
    );
}

test "zig fmt: first thing in file is line comment" {
    try testCanonical(
        \\// Introspection and determination of system libraries needed by zig.
        \\
        \\// Introspection and determination of system libraries needed by zig.
        \\
        \\const std = @import("std");
        \\
    );
}

test "zig fmt: line comment after doc comment" {
    try testCanonical(
        \\/// doc comment
        \\// line comment
        \\fn foo() void {}
        \\
    );
}

test "zig fmt: bit field alignment" {
    try testCanonical(
        \\test {
        \\    assert(@TypeOf(&blah.b) == *align(1:3:6) const u3);
        \\}
        \\
    );
}

test "zig fmt: nested switch" {
    try testCanonical(
        \\test {
        \\    switch (state) {
        \\        TermState.Start => switch (c) {
        \\            '\x1b' => state = TermState.Escape,
        \\            else => try out.writeByte(c),
        \\        },
        \\    }
        \\}
        \\
    );
}

test "zig fmt: float literal with exponent" {
    try testCanonical(
        \\pub const f64_true_min = 4.94065645841246544177e-324;
        \\const threshold = 0x1.a827999fcef32p+1022;
        \\
    );
}

test "zig fmt: if-else end of comptime" {
    try testCanonical(
        \\comptime {
        \\    if (a) {
        \\        b();
        \\    } else {
        \\        b();
        \\    }
        \\}
        \\
    );
}

test "zig fmt: nested blocks" {
    try testCanonical(
        \\comptime {
        \\    {
        \\        {
        \\            {
        \\                a();
        \\            }
        \\        }
        \\    }
        \\}
        \\
    );
}

test "zig fmt: block with same line comment after end brace" {
    try testCanonical(
        \\comptime {
        \\    {
        \\        b();
        \\    } // comment
        \\}
        \\
    );
}

test "zig fmt: statements with comment between" {
    try testCanonical(
        \\comptime {
        \\    a = b;
        \\    // comment
        \\    a = b;
        \\}
        \\
    );
}

test "zig fmt: statements with empty line between" {
    try testCanonical(
        \\comptime {
        \\    a = b;
        \\
        \\    a = b;
        \\}
        \\
    );
}

test "zig fmt: ptr deref operator and unwrap optional operator" {
    try testCanonical(
        \\const a = b.*;
        \\const a = b.?;
        \\
    );
}

test "zig fmt: comment after if before another if" {
    try testCanonical(
        \\test "aoeu" {
        \\    // comment
        \\    if (x) {
        \\        bar();
        \\    }
        \\}
        \\
        \\test "aoeu" {
        \\    if (x) {
        \\        foo();
        \\    }
        \\    // comment
        \\    if (x) {
        \\        bar();
        \\    }
        \\}
        \\
    );
}

test "zig fmt: line comment between if block and else keyword" {
    try testCanonical(
        \\test "aoeu" {
        \\    // cexp(finite|nan +- i inf|nan) = nan + i nan
        \\    if ((hx & 0x7fffffff) != 0x7f800000) {
        \\        return Complex(f32).init(y - y, y - y);
        \\    }
        \\    // cexp(-inf +- i inf|nan) = 0 + i0
        \\    else if (hx & 0x80000000 != 0) {
        \\        return Complex(f32).init(0, 0);
        \\    }
        \\    // cexp(+inf +- i inf|nan) = inf + i nan
        \\    // another comment
        \\    else {
        \\        return Complex(f32).init(x, y - y);
        \\    }
        \\}
        \\
    );
}

test "zig fmt: same line comments in expression" {
    try testCanonical(
        \\test "aoeu" {
        \\    const x = ( // a
        \\        0 // b
        \\    ); // c
        \\}
        \\
    );
}

test "zig fmt: add comma on last switch prong" {
    try testTransform(
        \\test "aoeu" {
        \\switch (self.init_arg_expr) {
        \\    InitArg.Type => |t| { },
        \\    InitArg.None,
        \\    InitArg.Enum => { }
        \\}
        \\ switch (self.init_arg_expr) {
        \\     InitArg.Type => |t| { },
        \\     InitArg.None,
        \\     InitArg.Enum => { }//line comment
        \\ }
        \\}
    ,
        \\test "aoeu" {
        \\    switch (self.init_arg_expr) {
        \\        InitArg.Type => |t| {},
        \\        InitArg.None, InitArg.Enum => {},
        \\    }
        \\    switch (self.init_arg_expr) {
        \\        InitArg.Type => |t| {},
        \\        InitArg.None, InitArg.Enum => {}, //line comment
        \\    }
        \\}
        \\
    );
}

test "zig fmt: same-line comment after a statement" {
    try testCanonical(
        \\test "" {
        \\    a = b;
        \\    debug.assert(H.digest_size <= H.block_size); // HMAC makes this assumption
        \\    a = b;
        \\}
        \\
    );
}

test "zig fmt: same-line comment after var decl in struct" {
    try testCanonical(
        \\pub const vfs_cap_data = extern struct {
        \\    const Data = struct {}; // when on disk.
        \\};
        \\
    );
}

test "zig fmt: same-line comment after field decl" {
    try testCanonical(
        \\pub const dirent = extern struct {
        \\    d_name: u8,
        \\    d_name: u8, // comment 1
        \\    d_name: u8,
        \\    d_name: u8, // comment 2
        \\    d_name: u8,
        \\};
        \\
    );
}

test "zig fmt: same-line comment after switch prong" {
    try testCanonical(
        \\test "" {
        \\    switch (err) {
        \\        error.PathAlreadyExists => {}, // comment 2
        \\        else => return err, // comment 1
        \\    }
        \\}
        \\
    );
}

test "zig fmt: same-line comment after non-block if expression" {
    try testCanonical(
        \\comptime {
        \\    if (sr > n_uword_bits - 1) // d > r
        \\        return 0;
        \\}
        \\
    );
}

test "zig fmt: same-line comment on comptime expression" {
    try testCanonical(
        \\test "" {
        \\    comptime assert(@typeInfo(T) == .Int); // must pass an integer to absInt
        \\}
        \\
    );
}

test "zig fmt: switch with empty body" {
    try testCanonical(
        \\test "" {
        \\    foo() catch |err| switch (err) {};
        \\}
        \\
    );
}

test "zig fmt: line comments in struct initializer" {
    try testCanonical(
        \\fn foo() void {
        \\    return Self{
        \\        .a = b,
        \\
        \\        // Initialize these two fields to buffer_size so that
        \\        // in `readFn` we treat the state as being able to read
        \\        .start_index = buffer_size,
        \\        .end_index = buffer_size,
        \\
        \\        // middle
        \\
        \\        .a = b,
        \\
        \\        // end
        \\    };
        \\}
        \\
    );
}

test "zig fmt: first line comment in struct initializer" {
    try testCanonical(
        \\pub fn acquire(self: *Self) HeldLock {
        \\    return HeldLock{
        \\        // guaranteed allocation elision
        \\        .held = self.lock.acquire(),
        \\        .value = &self.private_data,
        \\    };
        \\}
        \\
    );
}

test "zig fmt: doc comments before struct field" {
    try testCanonical(
        \\pub const Allocator = struct {
        \\    /// Allocate byte_count bytes and return them in a slice, with the
        \\    /// slice's pointer aligned at least to alignment bytes.
        \\    allocFn: fn () void,
        \\};
        \\
    );
}

test "zig fmt: error set declaration" {
    try testCanonical(
        \\const E = error{
        \\    A,
        \\    B,
        \\
        \\    C,
        \\};
        \\
        \\const Error = error{
        \\    /// no more memory
        \\    OutOfMemory,
        \\};
        \\
        \\const Error = error{
        \\    /// no more memory
        \\    OutOfMemory,
        \\
        \\    /// another
        \\    Another,
        \\
        \\    // end
        \\};
        \\
        \\const Error = error{OutOfMemory};
        \\const Error = error{};
        \\
        \\const Error = error{ OutOfMemory, OutOfTime };
        \\
    );
}

test "zig fmt: union(enum(u32)) with assigned enum values" {
    try testCanonical(
        \\const MultipleChoice = union(enum(u32)) {
        \\    A = 20,
        \\    B = 40,
        \\    C = 60,
        \\    D = 1000,
        \\};
        \\
    );
}

test "zig fmt: resume from suspend block" {
    try testCanonical(
        \\fn foo() void {
        \\    suspend {
        \\        resume @frame();
        \\    }
        \\}
        \\
    );
}

test "zig fmt: comments before error set decl" {
    try testCanonical(
        \\const UnexpectedError = error{
        \\    /// The Operating System returned an undocumented error code.
        \\    Unexpected,
        \\    // another
        \\    Another,
        \\
        \\    // in between
        \\
        \\    // at end
        \\};
        \\
    );
}

test "zig fmt: comments before switch prong" {
    try testCanonical(
        \\test "" {
        \\    switch (err) {
        \\        error.PathAlreadyExists => continue,
        \\
        \\        // comment 1
        \\
        \\        // comment 2
        \\        else => return err,
        \\        // at end
        \\    }
        \\}
        \\
    );
}

test "zig fmt: comments before var decl in struct" {
    try testCanonical(
        \\pub const vfs_cap_data = extern struct {
        \\    // All of these are mandated as little endian
        \\    // when on disk.
        \\    const Data = struct {
        \\        permitted: u32,
        \\        inheritable: u32,
        \\    };
        \\
        \\    // in between
        \\
        \\    /// All of these are mandated as little endian
        \\    /// when on disk.
        \\    const Data = struct {
        \\        permitted: u32,
        \\        inheritable: u32,
        \\    };
        \\
        \\    // at end
        \\};
        \\
    );
}

test "zig fmt: array literal with 1 item on 1 line" {
    try testCanonical(
        \\var s = []const u64{0} ** 25;
        \\
    );
}

test "zig fmt: comments before global variables" {
    try testCanonical(
        \\/// Foo copies keys and values before they go into the map, and
        \\/// frees them when they get removed.
        \\pub const Foo = struct {};
        \\
    );
}

test "zig fmt: comments in statements" {
    try testCanonical(
        \\test "std" {
        \\    // statement comment
        \\    _ = @import("foo/bar.zig");
        \\
        \\    // middle
        \\    // middle2
        \\
        \\    // end
        \\}
        \\
    );
}

test "zig fmt: comments before test decl" {
    try testCanonical(
        \\/// top level doc comment
        \\test "hi" {}
        \\
        \\// top level normal comment
        \\test "hi" {}
        \\
        \\// middle
        \\
        \\// end
        \\
    );
}

test "zig fmt: preserve spacing" {
    try testCanonical(
        \\const std = @import("std");
        \\
        \\pub fn main() !void {
        \\    var stdout_file = std.io.getStdOut;
        \\    var stdout_file = std.io.getStdOut;
        \\
        \\    var stdout_file = std.io.getStdOut;
        \\    var stdout_file = std.io.getStdOut;
        \\}
        \\
    );
}

test "zig fmt: return types" {
    try testCanonical(
        \\pub fn main() !void {}
        \\pub fn main() FooBar {}
        \\pub fn main() i32 {}
        \\
    );
}

test "zig fmt: imports" {
    try testCanonical(
        \\const std = @import("std");
        \\const std = @import();
        \\
    );
}

test "zig fmt: global declarations" {
    try testCanonical(
        \\const a = b;
        \\pub const a = b;
        \\var a = b;
        \\pub var a = b;
        \\const a: i32 = b;
        \\pub const a: i32 = b;
        \\var a: i32 = b;
        \\pub var a: i32 = b;
        \\extern const a: i32 = b;
        \\pub extern const a: i32 = b;
        \\extern var a: i32 = b;
        \\pub extern var a: i32 = b;
        \\extern "a" const a: i32 = b;
        \\pub extern "a" const a: i32 = b;
        \\extern "a" var a: i32 = b;
        \\pub extern "a" var a: i32 = b;
        \\
    );
}

test "zig fmt: extern declaration" {
    try testCanonical(
        \\extern var foo: c_int;
        \\
    );
}

test "zig fmt: alignment" {
    try testCanonical(
        \\var foo: c_int align(1);
        \\
    );
}

test "zig fmt: C main" {
    try testCanonical(
        \\fn main(argc: c_int, argv: **u8) c_int {
        \\    const a = b;
        \\}
        \\
    );
}

test "zig fmt: return" {
    try testCanonical(
        \\fn foo(argc: c_int, argv: **u8) c_int {
        \\    return 0;
        \\}
        \\
        \\fn bar() void {
        \\    return;
        \\}
        \\
    );
}

test "zig fmt: function attributes" {
    try testCanonical(
        \\export fn foo() void {}
        \\pub export fn foo() void {}
        \\extern fn foo() void;
        \\pub extern fn foo() void;
        \\extern "c" fn foo() void;
        \\pub extern "c" fn foo() void;
        \\noinline fn foo() void {}
        \\pub noinline fn foo() void {}
        \\
    );
}

test "zig fmt: nested pointers with ** tokens" {
    try testCanonical(
        \\const x: *u32 = undefined;
        \\const x: **u32 = undefined;
        \\const x: ***u32 = undefined;
        \\const x: ****u32 = undefined;
        \\const x: *****u32 = undefined;
        \\const x: ******u32 = undefined;
        \\const x: *******u32 = undefined;
        \\
    );
}

test "zig fmt: pointer attributes" {
    try testCanonical(
        \\extern fn f1(s: *align(*u8) u8) c_int;
        \\extern fn f2(s: **align(1) *const *volatile u8) c_int;
        \\extern fn f3(s: *align(1) const *align(1) volatile *const volatile u8) c_int;
        \\extern fn f4(s: *align(1) const volatile u8) c_int;
        \\extern fn f5(s: [*:0]align(1) const volatile u8) c_int;
        \\
    );
}

test "zig fmt: slice attributes" {
    try testCanonical(
        \\extern fn f1(s: []align(*u8) u8) c_int;
        \\extern fn f2(s: []align(1) []const []volatile u8) c_int;
        \\extern fn f3(s: []align(1) const [:0]align(1) volatile []const volatile u8) c_int;
        \\extern fn f4(s: []align(1) const volatile u8) c_int;
        \\extern fn f5(s: [:0]align(1) const volatile u8) c_int;
        \\
    );
}

test "zig fmt: test declaration" {
    try testCanonical(
        \\test "test name" {
        \\    const a = 1;
        \\    var b = 1;
        \\}
        \\
    );
}

test "zig fmt: infix operators" {
    try testCanonical(
        \\test {
        \\    var i = undefined;
        \\    i = 2;
        \\    i *= 2;
        \\    i |= 2;
        \\    i ^= 2;
        \\    i <<= 2;
        \\    i >>= 2;
        \\    i &= 2;
        \\    i *= 2;
        \\    i *%= 2;
        \\    i -= 2;
        \\    i -%= 2;
        \\    i += 2;
        \\    i +%= 2;
        \\    i /= 2;
        \\    i %= 2;
        \\    _ = i == i;
        \\    _ = i != i;
        \\    _ = i != i;
        \\    _ = i.i;
        \\    _ = i || i;
        \\    _ = i!i;
        \\    _ = i ** i;
        \\    _ = i ++ i;
        \\    _ = i orelse i;
        \\    _ = i % i;
        \\    _ = i / i;
        \\    _ = i *% i;
        \\    _ = i * i;
        \\    _ = i -% i;
        \\    _ = i - i;
        \\    _ = i +% i;
        \\    _ = i + i;
        \\    _ = i << i;
        \\    _ = i >> i;
        \\    _ = i & i;
        \\    _ = i ^ i;
        \\    _ = i | i;
        \\    _ = i >= i;
        \\    _ = i <= i;
        \\    _ = i > i;
        \\    _ = i < i;
        \\    _ = i and i;
        \\    _ = i or i;
        \\}
        \\
    );
}

test "zig fmt: precedence" {
    try testCanonical(
        \\test "precedence" {
        \\    a!b();
        \\    (a!b)();
        \\    !a!b;
        \\    !(a!b);
        \\    !a{};
        \\    !(a{});
        \\    a + b{};
        \\    (a + b){};
        \\    a << b + c;
        \\    (a << b) + c;
        \\    a & b << c;
        \\    (a & b) << c;
        \\    a ^ b & c;
        \\    (a ^ b) & c;
        \\    a | b ^ c;
        \\    (a | b) ^ c;
        \\    a == b | c;
        \\    (a == b) | c;
        \\    a and b == c;
        \\    (a and b) == c;
        \\    a or b and c;
        \\    (a or b) and c;
        \\    (a or b) and c;
        \\    a == b and c == d;
        \\}
        \\
    );
}

test "zig fmt: prefix operators" {
    try testCanonical(
        \\test "prefix operators" {
        \\    try return --%~!&0;
        \\}
        \\
    );
}

test "zig fmt: call expression" {
    try testCanonical(
        \\test "test calls" {
        \\    a();
        \\    a(1);
        \\    a(1, 2);
        \\    a(1, 2) + a(1, 2);
        \\}
        \\
    );
}

test "zig fmt: anytype type" {
    try testCanonical(
        \\fn print(args: anytype) @This() {}
        \\
    );
}

test "zig fmt: functions" {
    try testCanonical(
        \\extern fn puts(s: *const u8) c_int;
        \\extern "c" fn puts(s: *const u8) c_int;
        \\export fn puts(s: *const u8) c_int;
        \\inline fn puts(s: *const u8) c_int;
        \\noinline fn puts(s: *const u8) c_int;
        \\pub extern fn puts(s: *const u8) c_int;
        \\pub extern "c" fn puts(s: *const u8) c_int;
        \\pub export fn puts(s: *const u8) c_int;
        \\pub inline fn puts(s: *const u8) c_int;
        \\pub noinline fn puts(s: *const u8) c_int;
        \\pub extern fn puts(s: *const u8) align(2 + 2) c_int;
        \\pub extern "c" fn puts(s: *const u8) align(2 + 2) c_int;
        \\pub export fn puts(s: *const u8) align(2 + 2) c_int;
        \\pub inline fn puts(s: *const u8) align(2 + 2) c_int;
        \\pub noinline fn puts(s: *const u8) align(2 + 2) c_int;
        \\
    );
}

test "zig fmt: multiline string" {
    try testCanonical(
        \\test "" {
        \\    const s1 =
        \\        \\one
        \\        \\two)
        \\        \\three
        \\    ;
        \\    const s3 = // hi
        \\        \\one
        \\        \\two)
        \\        \\three
        \\    ;
        \\}
        \\
    );
}

test "zig fmt: values" {
    try testCanonical(
        \\test "values" {
        \\    1;
        \\    1.0;
        \\    "string";
        \\    'c';
        \\    true;
        \\    false;
        \\    null;
        \\    undefined;
        \\    anyerror;
        \\    this;
        \\    unreachable;
        \\}
        \\
    );
}

test "zig fmt: indexing" {
    try testCanonical(
        \\test "test index" {
        \\    a[0];
        \\    a[0 + 5];
        \\    a[0..];
        \\    a[0..5];
        \\    a[a[0]];
        \\    a[a[0..]];
        \\    a[a[0..5]];
        \\    a[a[0]..];
        \\    a[a[0..5]..];
        \\    a[a[0]..a[0]];
        \\    a[a[0..5]..a[0]];
        \\    a[a[0..5]..a[0..5]];
        \\}
        \\
    );
}

test "zig fmt: struct declaration" {
    try testCanonical(
        \\const S = struct {
        \\    const Self = @This();
        \\    f1: u8,
        \\    f3: u8,
        \\
        \\    f2: u8,
        \\
        \\    fn method(self: *Self) Self {
        \\        return self.*;
        \\    }
        \\};
        \\
        \\const Ps = packed struct {
        \\    a: u8,
        \\    b: u8,
        \\
        \\    c: u8,
        \\};
        \\
        \\const Es = extern struct {
        \\    a: u8,
        \\    b: u8,
        \\
        \\    c: u8,
        \\};
        \\
    );
}

test "zig fmt: enum declaration" {
    try testCanonical(
        \\const E = enum {
        \\    Ok,
        \\    SomethingElse = 0,
        \\};
        \\
        \\const E2 = enum(u8) {
        \\    Ok,
        \\    SomethingElse = 255,
        \\    SomethingThird,
        \\};
        \\
        \\const Ee = extern enum {
        \\    Ok,
        \\    SomethingElse,
        \\    SomethingThird,
        \\};
        \\
        \\const Ep = packed enum {
        \\    Ok,
        \\    SomethingElse,
        \\    SomethingThird,
        \\};
        \\
    );
}

test "zig fmt: union declaration" {
    try testCanonical(
        \\const U = union {
        \\    Int: u8,
        \\    Float: f32,
        \\    None,
        \\    Bool: bool,
        \\};
        \\
        \\const Ue = union(enum) {
        \\    Int: u8,
        \\    Float: f32,
        \\    None,
        \\    Bool: bool,
        \\};
        \\
        \\const E = enum {
        \\    Int,
        \\    Float,
        \\    None,
        \\    Bool,
        \\};
        \\
        \\const Ue2 = union(E) {
        \\    Int: u8,
        \\    Float: f32,
        \\    None,
        \\    Bool: bool,
        \\};
        \\
        \\const Eu = extern union {
        \\    Int: u8,
        \\    Float: f32,
        \\    None,
        \\    Bool: bool,
        \\};
        \\
    );
}

test "zig fmt: arrays" {
    try testCanonical(
        \\test "test array" {
        \\    const a: [2]u8 = [2]u8{
        \\        1,
        \\        2,
        \\    };
        \\    const a: [2]u8 = []u8{
        \\        1,
        \\        2,
        \\    };
        \\    const a: [0]u8 = []u8{};
        \\    const x: [4:0]u8 = undefined;
        \\}
        \\
    );
}

test "zig fmt: container initializers" {
    try testCanonical(
        \\const a0 = []u8{};
        \\const a1 = []u8{1};
        \\const a2 = []u8{
        \\    1,
        \\    2,
        \\    3,
        \\    4,
        \\};
        \\const s0 = S{};
        \\const s1 = S{ .a = 1 };
        \\const s2 = S{
        \\    .a = 1,
        \\    .b = 2,
        \\};
        \\
    );
}

test "zig fmt: catch" {
    try testCanonical(
        \\test "catch" {
        \\    const a: anyerror!u8 = 0;
        \\    _ = a catch return;
        \\    _ = a catch
        \\        return;
        \\    _ = a catch |err| return;
        \\    _ = a catch |err|
        \\        return;
        \\}
        \\
    );
}

test "zig fmt: blocks" {
    try testCanonical(
        \\test "blocks" {
        \\    {
        \\        const a = 0;
        \\        const b = 0;
        \\    }
        \\
        \\    blk: {
        \\        const a = 0;
        \\        const b = 0;
        \\    }
        \\
        \\    const r = blk: {
        \\        const a = 0;
        \\        const b = 0;
        \\    };
        \\}
        \\
    );
}

test "zig fmt: switch" {
    try testCanonical(
        \\test "switch" {
        \\    switch (0) {
        \\        0 => {},
        \\        1 => unreachable,
        \\        2, 3 => {},
        \\        4...7 => {},
        \\        1 + 4 * 3 + 22 => {},
        \\        else => {
        \\            const a = 1;
        \\            const b = a;
        \\        },
        \\    }
        \\
        \\    const res = switch (0) {
        \\        0 => 0,
        \\        1 => 2,
        \\        1 => a = 4,
        \\        else => 4,
        \\    };
        \\
        \\    const Union = union(enum) {
        \\        Int: i64,
        \\        Float: f64,
        \\    };
        \\
        \\    switch (u) {
        \\        Union.Int => |int| {},
        \\        Union.Float => |*float| unreachable,
        \\    }
        \\}
        \\
    );

    try testTransform(
        \\test {
        \\    switch (x) {
        \\        foo =>
        \\            "bar",
        \\    }
        \\}
        \\
    ,
        \\test {
        \\    switch (x) {
        \\        foo => "bar",
        \\    }
        \\}
        \\
    );
}

test "zig fmt: switch multiline string" {
    try testCanonical(
        \\test "switch multiline string" {
        \\    const x: u32 = 0;
        \\    const str = switch (x) {
        \\        1 => "one",
        \\        2 =>
        \\        \\ Comma after the multiline string
        \\        \\ is needed
        \\        ,
        \\        3 => "three",
        \\        else => "else",
        \\    };
        \\
        \\    const Union = union(enum) {
        \\        Int: i64,
        \\        Float: f64,
        \\    };
        \\
        \\    const str = switch (u) {
        \\        Union.Int => |int|
        \\        \\ Comma after the multiline string
        \\        \\ is needed
        \\        ,
        \\        Union.Float => |*float| unreachable,
        \\    };
        \\}
        \\
    );
}

test "zig fmt: while" {
    try testCanonical(
        \\test "while" {
        \\    while (10 < 1) unreachable;
        \\
        \\    while (10 < 1) unreachable else unreachable;
        \\
        \\    while (10 < 1) {
        \\        unreachable;
        \\    }
        \\
        \\    while (10 < 1)
        \\        unreachable;
        \\
        \\    var i: usize = 0;
        \\    while (i < 10) : (i += 1) {
        \\        continue;
        \\    }
        \\
        \\    i = 0;
        \\    while (i < 10) : (i += 1)
        \\        continue;
        \\
        \\    i = 0;
        \\    var j: usize = 0;
        \\    while (i < 10) : ({
        \\        i += 1;
        \\        j += 1;
        \\    }) continue;
        \\
        \\    while (i < 10) : ({
        \\        i += 1;
        \\        j += 1;
        \\    }) {
        \\        continue;
        \\    }
        \\
        \\    var a: ?u8 = 2;
        \\    while (a) |v| : (a = null) {
        \\        continue;
        \\    }
        \\
        \\    while (a) |v| : (a = null)
        \\        unreachable;
        \\
        \\    label: while (10 < 0) {
        \\        unreachable;
        \\    }
        \\
        \\    const res = while (0 < 10) {
        \\        break 7;
        \\    } else {
        \\        unreachable;
        \\    };
        \\
        \\    const res = while (0 < 10)
        \\        break 7
        \\    else
        \\        unreachable;
        \\
        \\    var a: anyerror!u8 = 0;
        \\    while (a) |v| {
        \\        a = error.Err;
        \\    } else |err| {
        \\        i = 1;
        \\    }
        \\
        \\    comptime var k: usize = 0;
        \\    inline while (i < 10) : (i += 1)
        \\        j += 2;
        \\}
        \\
    );
}

test "zig fmt: for" {
    try testCanonical(
        \\test "for" {
        \\    for (a) |v| {
        \\        continue;
        \\    }
        \\
        \\    for (a) |v| continue;
        \\
        \\    for (a) |v| continue else return;
        \\
        \\    for (a) |v| {
        \\        continue;
        \\    } else return;
        \\
        \\    for (a) |v| continue else {
        \\        return;
        \\    }
        \\
        \\    for (a) |v|
        \\        continue
        \\    else
        \\        return;
        \\
        \\    for (a) |v|
        \\        continue;
        \\
        \\    for (a) |*v|
        \\        continue;
        \\
        \\    for (a) |v, i| {
        \\        continue;
        \\    }
        \\
        \\    for (a) |v, i|
        \\        continue;
        \\
        \\    for (a) |b| switch (b) {
        \\        c => {},
        \\        d => {},
        \\    };
        \\
        \\    const res = for (a) |v, i| {
        \\        break v;
        \\    } else {
        \\        unreachable;
        \\    };
        \\
        \\    var num: usize = 0;
        \\    inline for (a) |v, i| {
        \\        num += v;
        \\        num += i;
        \\    }
        \\}
        \\
    );

    try testTransform(
        \\test "fix for" {
        \\    for (a) |x|
        \\        f(x) else continue;
        \\}
        \\
    ,
        \\test "fix for" {
        \\    for (a) |x|
        \\        f(x)
        \\    else
        \\        continue;
        \\}
        \\
    );
}

test "zig fmt: for if" {
    try testCanonical(
        \\test {
        \\    for (a) |x| if (x) f(x);
        \\
        \\    for (a) |x| if (x)
        \\        f(x);
        \\
        \\    for (a) |x| if (x) {
        \\        f(x);
        \\    };
        \\
        \\    for (a) |x|
        \\        if (x)
        \\            f(x);
        \\
        \\    for (a) |x|
        \\        if (x) {
        \\            f(x);
        \\        };
        \\}
        \\
    );
}

test "zig fmt: if for" {
    try testCanonical(
        \\test {
        \\    if (a) for (x) |x| f(x);
        \\
        \\    if (a) for (x) |x|
        \\        f(x);
        \\
        \\    if (a) for (x) |x| {
        \\        f(x);
        \\    };
        \\
        \\    if (a)
        \\        for (x) |x|
        \\            f(x);
        \\
        \\    if (a)
        \\        for (x) |x| {
        \\            f(x);
        \\        };
        \\}
        \\
    );
}

test "zig fmt: while if" {
    try testCanonical(
        \\test {
        \\    while (a) if (x) f(x);
        \\
        \\    while (a) if (x)
        \\        f(x);
        \\
        \\    while (a) if (x) {
        \\        f(x);
        \\    };
        \\
        \\    while (a)
        \\        if (x)
        \\            f(x);
        \\
        \\    while (a)
        \\        if (x) {
        \\            f(x);
        \\        };
        \\}
        \\
    );
}

test "zig fmt: if while" {
    try testCanonical(
        \\test {
        \\    if (a) while (x) : (cont) f(x);
        \\
        \\    if (a) while (x) : (cont)
        \\        f(x);
        \\
        \\    if (a) while (x) : (cont) {
        \\        f(x);
        \\    };
        \\
        \\    if (a)
        \\        while (x) : (cont)
        \\            f(x);
        \\
        \\    if (a)
        \\        while (x) : (cont) {
        \\            f(x);
        \\        };
        \\}
        \\
    );
}

test "zig fmt: while for" {
    try testCanonical(
        \\test {
        \\    while (a) for (x) |x| f(x);
        \\
        \\    while (a) for (x) |x|
        \\        f(x);
        \\
        \\    while (a) for (x) |x| {
        \\        f(x);
        \\    };
        \\
        \\    while (a)
        \\        for (x) |x|
        \\            f(x);
        \\
        \\    while (a)
        \\        for (x) |x| {
        \\            f(x);
        \\        };
        \\}
        \\
    );
}

test "zig fmt: for while" {
    try testCanonical(
        \\test {
        \\    for (a) |a| while (x) |x| f(x);
        \\
        \\    for (a) |a| while (x) |x|
        \\        f(x);
        \\
        \\    for (a) |a| while (x) |x| {
        \\        f(x);
        \\    };
        \\
        \\    for (a) |a|
        \\        while (x) |x|
        \\            f(x);
        \\
        \\    for (a) |a|
        \\        while (x) |x| {
        \\            f(x);
        \\        };
        \\}
        \\
    );
}

test "zig fmt: if" {
    try testCanonical(
        \\test "if" {
        \\    if (10 < 0) {
        \\        unreachable;
        \\    }
        \\
        \\    if (10 < 0) unreachable;
        \\
        \\    if (10 < 0) {
        \\        unreachable;
        \\    } else {
        \\        const a = 20;
        \\    }
        \\
        \\    if (10 < 0) {
        \\        unreachable;
        \\    } else if (5 < 0) {
        \\        unreachable;
        \\    } else {
        \\        const a = 20;
        \\    }
        \\
        \\    const is_world_broken = if (10 < 0) true else false;
        \\    const some_number = 1 + if (10 < 0) 2 else 3;
        \\
        \\    const a: ?u8 = 10;
        \\    const b: ?u8 = null;
        \\    if (a) |v| {
        \\        const some = v;
        \\    } else if (b) |*v| {
        \\        unreachable;
        \\    } else {
        \\        const some = 10;
        \\    }
        \\
        \\    const non_null_a = if (a) |v| v else 0;
        \\
        \\    const a_err: anyerror!u8 = 0;
        \\    if (a_err) |v| {
        \\        const p = v;
        \\    } else |err| {
        \\        unreachable;
        \\    }
        \\}
        \\
    );
}

test "zig fmt: fix single statement if/for/while line breaks" {
    try testTransform(
        \\test {
        \\    if (cond) a
        \\    else b;
        \\
        \\    if (cond)
        \\        a
        \\    else b;
        \\
        \\    for (xs) |x| foo()
        \\    else bar();
        \\
        \\    for (xs) |x|
        \\        foo()
        \\    else bar();
        \\
        \\    while (a) : (b) foo()
        \\    else bar();
        \\
        \\    while (a) : (b)
        \\        foo()
        \\    else bar();
        \\}
        \\
    ,
        \\test {
        \\    if (cond) a else b;
        \\
        \\    if (cond)
        \\        a
        \\    else
        \\        b;
        \\
        \\    for (xs) |x| foo() else bar();
        \\
        \\    for (xs) |x|
        \\        foo()
        \\    else
        \\        bar();
        \\
        \\    while (a) : (b) foo() else bar();
        \\
        \\    while (a) : (b)
        \\        foo()
        \\    else
        \\        bar();
        \\}
        \\
    );
}

test "zig fmt: anon struct/array literal in if" {
    try testCanonical(
        \\test {
        \\    const a = if (cond) .{
        \\        1, 2,
        \\        3, 4,
        \\    } else .{
        \\        1,
        \\        2,
        \\        3,
        \\    };
        \\
        \\    const rl_and_tag: struct { rl: ResultLoc, tag: zir.Inst.Tag } = if (any_payload_is_ref) .{
        \\        .rl = .ref,
        \\        .tag = .switchbr_ref,
        \\    } else .{
        \\        .rl = .none,
        \\        .tag = .switchbr,
        \\    };
        \\}
        \\
    );
}

test "zig fmt: defer" {
    try testCanonical(
        \\test "defer" {
        \\    var i: usize = 0;
        \\    defer i = 1;
        \\    defer {
        \\        i += 2;
        \\        i *= i;
        \\    }
        \\
        \\    errdefer i += 3;
        \\    errdefer {
        \\        i += 2;
        \\        i /= i;
        \\    }
        \\}
        \\
    );
}

test "zig fmt: comptime" {
    try testCanonical(
        \\fn a() u8 {
        \\    return 5;
        \\}
        \\
        \\fn b(comptime i: u8) u8 {
        \\    return i;
        \\}
        \\
        \\const av = comptime a();
        \\const av2 = comptime blk: {
        \\    var res = a();
        \\    res *= b(2);
        \\    break :blk res;
        \\};
        \\
        \\comptime {
        \\    _ = a();
        \\}
        \\
        \\test "comptime" {
        \\    const av3 = comptime a();
        \\    const av4 = comptime blk: {
        \\        var res = a();
        \\        res *= a();
        \\        break :blk res;
        \\    };
        \\
        \\    comptime var i = 0;
        \\    comptime {
        \\        i = a();
        \\        i += b(i);
        \\    }
        \\}
        \\
    );
}

test "zig fmt: fn type" {
    try testCanonical(
        \\fn a(i: u8) u8 {
        \\    return i + 1;
        \\}
        \\
        \\const a: fn (u8) u8 = undefined;
        \\const b: fn (u8) callconv(.Naked) u8 = undefined;
        \\const ap: fn (u8) u8 = a;
        \\
    );
}

test "zig fmt: inline asm" {
    try testCanonical(
        \\pub fn syscall1(number: usize, arg1: usize) usize {
        \\    return asm volatile ("syscall"
        \\        : [ret] "={rax}" (-> usize)
        \\        : [number] "{rax}" (number),
        \\          [arg1] "{rdi}" (arg1)
        \\        : "rcx", "r11"
        \\    );
        \\}
        \\
    );
}

test "zig fmt: async functions" {
    try testCanonical(
        \\fn simpleAsyncFn() void {
        \\    const a = async a.b();
        \\    x += 1;
        \\    suspend {}
        \\    x += 1;
        \\    suspend {}
        \\    const p: anyframe->void = async simpleAsyncFn() catch unreachable;
        \\    await p;
        \\}
        \\
        \\test "suspend, resume, await" {
        \\    const p: anyframe = async testAsyncSeq();
        \\    resume p;
        \\    await p;
        \\}
        \\
    );
}

test "zig fmt: nosuspend" {
    try testCanonical(
        \\const a = nosuspend foo();
        \\
    );
}

test "zig fmt: Block after if" {
    try testCanonical(
        \\test {
        \\    if (true) {
        \\        const a = 0;
        \\    }
        \\
        \\    {
        \\        const a = 0;
        \\    }
        \\}
        \\
    );
}

test "zig fmt: usingnamespace" {
    try testCanonical(
        \\usingnamespace @import("std");
        \\pub usingnamespace @import("std");
        \\
    );
}

test "zig fmt: string identifier" {
    try testCanonical(
        \\const @"a b" = @"c d".@"e f";
        \\fn @"g h"() void {}
        \\
    );
}

test "zig fmt: error return" {
    try testCanonical(
        \\fn err() anyerror {
        \\    call();
        \\    return error.InvalidArgs;
        \\}
        \\
    );
}

test "zig fmt: comptime block in container" {
    try testCanonical(
        \\pub fn container() type {
        \\    return struct {
        \\        comptime {
        \\            if (false) {
        \\                unreachable;
        \\            }
        \\        }
        \\    };
        \\}
        \\
    );
}

test "zig fmt: inline asm parameter alignment" {
    try testCanonical(
        \\pub fn main() void {
        \\    asm volatile (
        \\        \\ foo
        \\        \\ bar
        \\    );
        \\    asm volatile (
        \\        \\ foo
        \\        \\ bar
        \\        : [_] "" (-> usize),
        \\          [_] "" (-> usize)
        \\    );
        \\    asm volatile (
        \\        \\ foo
        \\        \\ bar
        \\        :
        \\        : [_] "" (0),
        \\          [_] "" (0)
        \\    );
        \\    asm volatile (
        \\        \\ foo
        \\        \\ bar
        \\        ::: "", "");
        \\    asm volatile (
        \\        \\ foo
        \\        \\ bar
        \\        : [_] "" (-> usize),
        \\          [_] "" (-> usize)
        \\        : [_] "" (0),
        \\          [_] "" (0)
        \\        : "", ""
        \\    );
        \\}
        \\
    );
}

test "zig fmt: multiline string in array" {
    try testCanonical(
        \\const Foo = [][]const u8{
        \\    \\aaa
        \\    ,
        \\    \\bbb
        \\};
        \\
        \\fn bar() void {
        \\    const Foo = [][]const u8{
        \\        \\aaa
        \\        ,
        \\        \\bbb
        \\    };
        \\    const Bar = [][]const u8{ // comment here
        \\        \\aaa
        \\        \\
        \\        , // and another comment can go here
        \\        \\bbb
        \\    };
        \\}
        \\
    );
}

test "zig fmt: if type expr" {
    try testCanonical(
        \\const mycond = true;
        \\pub fn foo() if (mycond) i32 else void {
        \\    if (mycond) {
        \\        return 42;
        \\    }
        \\}
        \\
    );
}
test "zig fmt: file ends with struct field" {
    try testCanonical(
        \\a: bool
        \\
    );
}

test "zig fmt: comment after empty comment" {
    try testCanonical(
        \\const x = true; //
        \\//
        \\//
        \\//a
        \\
    );
}

test "zig fmt: line comment in array" {
    try testTransform(
        \\test "a" {
        \\    var arr = [_]u32{
        \\        0
        \\        // 1,
        \\        // 2,
        \\    };
        \\}
        \\
    ,
        \\test "a" {
        \\    var arr = [_]u32{
        \\        0,
        \\        // 1,
        \\        // 2,
        \\    };
        \\}
        \\
    );
    try testCanonical(
        \\test "a" {
        \\    var arr = [_]u32{
        \\        0,
        \\        // 1,
        \\        // 2,
        \\    };
        \\}
        \\
    );
}

test "zig fmt: comment after params" {
    try testTransform(
        \\fn a(
        \\    b: u32
        \\    // c: u32,
        \\    // d: u32,
        \\) void {}
        \\
    ,
        \\fn a(
        \\    b: u32,
        \\    // c: u32,
        \\    // d: u32,
        \\) void {}
        \\
    );
    try testCanonical(
        \\fn a(
        \\    b: u32,
        \\    // c: u32,
        \\    // d: u32,
        \\) void {}
        \\
    );
}

test "zig fmt: comment in array initializer/access" {
    try testCanonical(
        \\test "a" {
        \\    var a = x{ //aa
        \\        //bb
        \\    };
        \\    var a = []x{ //aa
        \\        //bb
        \\    };
        \\    var b = [ //aa
        \\        _
        \\    ]x{ //aa
        \\        //bb
        \\        9,
        \\    };
        \\    var c = b[ //aa
        \\        0
        \\    ];
        \\    var d = [
        \\        _
        \\        //aa
        \\        :
        \\        0
        \\    ]x{ //aa
        \\        //bb
        \\        9,
        \\    };
        \\    var e = d[
        \\        0
        \\        //aa
        \\    ];
        \\}
        \\
    );
}

test "zig fmt: comments at several places in struct init" {
    try testTransform(
        \\var bar = Bar{
        \\    .x = 10, // test
        \\    .y = "test"
        \\    // test
        \\};
        \\
    ,
        \\var bar = Bar{
        \\    .x = 10, // test
        \\    .y = "test",
        \\    // test
        \\};
        \\
    );

    try testCanonical(
        \\var bar = Bar{ // test
        \\    .x = 10, // test
        \\    .y = "test",
        \\    // test
        \\};
        \\
    );
}

test "zig fmt: container doc comments" {
    try testCanonical(
        \\//! tld 1
        \\//! tld 2
        \\//! tld 3
        \\
        \\// comment
        \\
        \\/// A doc
        \\const A = struct {
        \\    //! A tld 1
        \\    //! A tld 2
        \\    //! A tld 3
        \\};
        \\
        \\/// B doc
        \\const B = struct {
        \\    //! B tld 1
        \\    //! B tld 2
        \\    //! B tld 3
        \\
        \\    /// B doc
        \\    b: u32,
        \\};
        \\
        \\/// C doc
        \\const C = union(enum) { // comment
        \\    //! C tld 1
        \\    //! C tld 2
        \\    //! C tld 3
        \\};
        \\
        \\/// D doc
        \\const D = union(Foo) {
        \\    //! D tld 1
        \\    //! D tld 2
        \\    //! D tld 3
        \\
        \\    /// D doc
        \\    b: u32,
        \\};
        \\
    );
    try testCanonical(
        \\//! Top-level documentation.
        \\
        \\/// This is A
        \\pub const A = usize;
        \\
    );
    try testCanonical(
        \\//! Nothing here
        \\
    );
}

test "zig fmt: extern without container keyword returns error" {
    try testError(
        \\const container = extern {};
        \\
    , &[_]Error{
        .expected_container,
    });
}

test "zig fmt: same line doc comment returns error" {
    try testError(
        \\const Foo = struct{
        \\    bar: u32, /// comment
        \\    foo: u32, /// comment
        \\    /// commment
        \\};
        \\
        \\const a = 42; /// comment
        \\
        \\extern fn foo() void; /// comment
        \\
        \\/// comment
        \\
    , &[_]Error{
        .same_line_doc_comment,
        .same_line_doc_comment,
        .unattached_doc_comment,
        .same_line_doc_comment,
        .same_line_doc_comment,
        .unattached_doc_comment,
    });
}

test "zig fmt: integer literals with underscore separators" {
    try testTransform(
        \\const
        \\ x     =
        \\ 1_234_567
        \\ +(0b0_1-0o7_0+0xff_FF ) +  0_0;
    ,
        \\const x =
        \\    1_234_567 + (0b0_1 - 0o7_0 + 0xff_FF) + 0_0;
        \\
    );
}

test "zig fmt: hex literals with underscore separators" {
    try testTransform(
        \\pub fn orMask(a: [ 1_000 ]u64, b: [  1_000]  u64) [1_000]u64 {
        \\    var c: [1_000]u64 =  [1]u64{ 0xFFFF_FFFF_FFFF_FFFF}**1_000;
        \\    for (c [ 0_0 .. ]) |_, i| {
        \\        c[i] = (a[i] | b[i]) & 0xCCAA_CCAA_CCAA_CCAA;
        \\    }
        \\    return c;
        \\}
        \\
        \\
    ,
        \\pub fn orMask(a: [1_000]u64, b: [1_000]u64) [1_000]u64 {
        \\    var c: [1_000]u64 = [1]u64{0xFFFF_FFFF_FFFF_FFFF} ** 1_000;
        \\    for (c[0_0..]) |_, i| {
        \\        c[i] = (a[i] | b[i]) & 0xCCAA_CCAA_CCAA_CCAA;
        \\    }
        \\    return c;
        \\}
        \\
    );
}

test "zig fmt: decimal float literals with underscore separators" {
    try testTransform(
        \\pub fn main() void {
        \\    const a:f64=(10.0e-0+(10.0e+0))+10_00.00_00e-2+00_00.00_10e+4;
        \\    const b:f64=010.0--0_10.0+0_1_0.0_0+1e2;
        \\    std.debug.warn("a: {}, b: {} -> a+b: {}\n", .{ a, b, a + b });
        \\}
    ,
        \\pub fn main() void {
        \\    const a: f64 = (10.0e-0 + (10.0e+0)) + 10_00.00_00e-2 + 00_00.00_10e+4;
        \\    const b: f64 = 010.0 - -0_10.0 + 0_1_0.0_0 + 1e2;
        \\    std.debug.warn("a: {}, b: {} -> a+b: {}\n", .{ a, b, a + b });
        \\}
        \\
    );
}

test "zig fmt: hexadeciaml float literals with underscore separators" {
    try testTransform(
        \\pub fn main() void {
        \\    const a: f64 = (0x10.0p-0+(0x10.0p+0))+0x10_00.00_00p-8+0x00_00.00_10p+16;
        \\    const b: f64 = 0x0010.0--0x00_10.0+0x10.00+0x1p4;
        \\    std.debug.warn("a: {}, b: {} -> a+b: {}\n", .{ a, b, a + b });
        \\}
    ,
        \\pub fn main() void {
        \\    const a: f64 = (0x10.0p-0 + (0x10.0p+0)) + 0x10_00.00_00p-8 + 0x00_00.00_10p+16;
        \\    const b: f64 = 0x0010.0 - -0x00_10.0 + 0x10.00 + 0x1p4;
        \\    std.debug.warn("a: {}, b: {} -> a+b: {}\n", .{ a, b, a + b });
        \\}
        \\
    );
}

test "zig fmt: C var args" {
    try testCanonical(
        \\pub extern "c" fn printf(format: [*:0]const u8, ...) c_int;
        \\
    );
}

test "zig fmt: Only indent multiline string literals in function calls" {
    try testCanonical(
        \\test "zig fmt:" {
        \\    try testTransform(
        \\        \\const X = struct {
        \\        \\    foo: i32, bar: i8 };
        \\    ,
        \\        \\const X = struct {
        \\        \\    foo: i32, bar: i8
        \\        \\};
        \\        \\
        \\    );
        \\}
        \\
    );
}

test "zig fmt: Don't add extra newline after if" {
    try testCanonical(
        \\pub fn atomicSymLink(allocator: *Allocator, existing_path: []const u8, new_path: []const u8) !void {
        \\    if (cwd().symLink(existing_path, new_path, .{})) {
        \\        return;
        \\    }
        \\}
        \\
    );
}

test "zig fmt: comments in ternary ifs" {
    try testCanonical(
        \\const x = if (true) {
        \\    1;
        \\} else if (false)
        \\    // Comment
        \\    0;
        \\const y = if (true)
        \\    // Comment
        \\    1
        \\else
        \\    // Comment
        \\    0;
        \\
        \\pub extern "c" fn printf(format: [*:0]const u8, ...) c_int;
        \\
    );
}

test "zig fmt: while statement in blockless if" {
    try testCanonical(
        \\pub fn main() void {
        \\    const zoom_node = if (focused_node == layout_first)
        \\        while (it.next()) |node| {
        \\            if (!node.view.pending.float and !node.view.pending.fullscreen) break node;
        \\        } else null
        \\    else
        \\        focused_node;
        \\}
        \\
    );
}

test "zig fmt: test comments in field access chain" {
    try testCanonical(
        \\pub const str = struct {
        \\    pub const Thing = more.more //
        \\        .more() //
        \\        .more().more() //
        \\        .more() //
        \\    // .more() //
        \\        .more() //
        \\        .more();
        \\    data: Data,
        \\};
        \\
        \\pub const str = struct {
        \\    pub const Thing = more.more //
        \\        .more() //
        \\    // .more() //
        \\    // .more() //
        \\    // .more() //
        \\        .more() //
        \\        .more();
        \\    data: Data,
        \\};
        \\
        \\pub const str = struct {
        \\    pub const Thing = more //
        \\        .more //
        \\        .more() //
        \\        .more();
        \\    data: Data,
        \\};
        \\
    );
}

test "zig fmt: allow line break before field access" {
    try testCanonical(
        \\test {
        \\    const w = foo.bar().zippy(zag).iguessthisisok();
        \\
        \\    const x = foo
        \\        .bar()
        \\        . // comment
        \\    // comment
        \\        swooop().zippy(zag)
        \\        .iguessthisisok();
        \\
        \\    const y = view.output.root.server.input_manager.default_seat.wlr_seat.name;
        \\
        \\    const z = view.output.root.server
        \\        .input_manager //
        \\        .default_seat
        \\        . // comment
        \\    // another comment
        \\        wlr_seat.name;
        \\}
        \\
    );
    try testTransform(
        \\test {
        \\    const x = foo.
        \\        bar()
        \\        .zippy(zag).iguessthisisok();
        \\
        \\    const z = view.output.root.server.
        \\        input_manager.
        \\        default_seat.wlr_seat.name;
        \\}
        \\
    ,
        \\test {
        \\    const x = foo
        \\        .bar()
        \\        .zippy(zag).iguessthisisok();
        \\
        \\    const z = view.output.root.server
        \\        .input_manager
        \\        .default_seat.wlr_seat.name;
        \\}
        \\
    );
}

test "zig fmt: Indent comma correctly after multiline string literals in arg list (trailing comma)" {
    try testCanonical(
        \\fn foo() void {
        \\    z.display_message_dialog(
        \\        *const [323:0]u8,
        \\        \\Message Text
        \\        \\------------
        \\        \\xxxxxxxxxxxx
        \\        \\xxxxxxxxxxxx
        \\    ,
        \\        g.GtkMessageType.GTK_MESSAGE_WARNING,
        \\        null,
        \\    );
        \\
        \\    z.display_message_dialog(*const [323:0]u8,
        \\        \\Message Text
        \\        \\------------
        \\        \\xxxxxxxxxxxx
        \\        \\xxxxxxxxxxxx
        \\    , g.GtkMessageType.GTK_MESSAGE_WARNING, null);
        \\}
        \\
    );
}

test "zig fmt: Control flow statement as body of blockless if" {
    try testCanonical(
        \\pub fn main() void {
        \\    const zoom_node = if (focused_node == layout_first)
        \\        if (it.next()) {
        \\            if (!node.view.pending.float and !node.view.pending.fullscreen) break node;
        \\        } else null
        \\    else
        \\        focused_node;
        \\
        \\    const zoom_node = if (focused_node == layout_first) while (it.next()) |node| {
        \\        if (!node.view.pending.float and !node.view.pending.fullscreen) break node;
        \\    } else null else focused_node;
        \\
        \\    const zoom_node = if (focused_node == layout_first)
        \\        if (it.next()) {
        \\            if (!node.view.pending.float and !node.view.pending.fullscreen) break node;
        \\        } else null;
        \\
        \\    const zoom_node = if (focused_node == layout_first) while (it.next()) |node| {
        \\        if (!node.view.pending.float and !node.view.pending.fullscreen) break node;
        \\    };
        \\
        \\    const zoom_node = if (focused_node == layout_first) for (nodes) |node| {
        \\        break node;
        \\    };
        \\
        \\    const zoom_node = if (focused_node == layout_first) switch (nodes) {
        \\        0 => 0,
        \\    } else focused_node;
        \\}
        \\
    );
}

test "zig fmt: regression test for #5722" {
    try testCanonical(
        \\pub fn sendViewTags(self: Self) void {
        \\    var it = ViewStack(View).iterator(self.output.views.first, std.math.maxInt(u32));
        \\    while (it.next()) |node|
        \\        view_tags.append(node.view.current_tags) catch {
        \\            c.wl_resource_post_no_memory(self.wl_resource);
        \\            log.crit(.river_status, "out of memory", .{});
        \\            return;
        \\        };
        \\}
        \\
    );
}

test "zig fmt: regression test for #8974" {
    try testCanonical(
        \\pub const VARIABLE;
        \\
    );
}

test "zig fmt: allow trailing line comments to do manual array formatting" {
    try testCanonical(
        \\fn foo() void {
        \\    self.code.appendSliceAssumeCapacity(&[_]u8{
        \\        0x55, // push rbp
        \\        0x48, 0x89, 0xe5, // mov rbp, rsp
        \\        0x48, 0x81, 0xec, // sub rsp, imm32 (with reloc)
        \\    });
        \\
        \\    di_buf.appendAssumeCapacity(&[_]u8{
        \\        1, DW.TAG_compile_unit, DW.CHILDREN_no, // header
        \\        DW.AT_stmt_list, DW_FORM_data4, // form value pairs
        \\        DW.AT_low_pc,    DW_FORM_addr,
        \\        DW.AT_high_pc,   DW_FORM_addr,
        \\        DW.AT_name,      DW_FORM_strp,
        \\        DW.AT_comp_dir,  DW_FORM_strp,
        \\        DW.AT_producer,  DW_FORM_strp,
        \\        DW.AT_language,  DW_FORM_data2,
        \\        0, 0, // sentinel
        \\    });
        \\
        \\    self.code.appendSliceAssumeCapacity(&[_]u8{
        \\        0x55, // push rbp
        \\        0x48, 0x89, 0xe5, // mov rbp, rsp
        \\        // How do we handle this?
        \\        //0x48, 0x81, 0xec, // sub rsp, imm32 (with reloc)
        \\        // Here's a blank line, should that be allowed?
        \\
        \\        0x48, 0x89, 0xe5,
        \\        0x33, 0x45,
        \\        // Now the comment breaks a single line -- how do we handle this?
        \\        0x88,
        \\    });
        \\}
        \\
    );
}

test "zig fmt: multiline string literals should play nice with array initializers" {
    try testCanonical(
        \\fn main() void {
        \\    var a = .{.{.{.{.{.{.{.{
        \\        0,
        \\    }}}}}}}};
        \\    myFunc(.{
        \\        "aaaaaaa",                           "bbbbbb", "ccccc",
        \\        "dddd",                              ("eee"),  ("fff"),
        \\        ("gggg"),
        \\        // Line comment
        \\        \\Multiline String Literals can be quite long
        \\        ,
        \\        \\Multiline String Literals can be quite long
        \\        \\Multiline String Literals can be quite long
        \\        ,
        \\        \\Multiline String Literals can be quite long
        \\        \\Multiline String Literals can be quite long
        \\        \\Multiline String Literals can be quite long
        \\        \\Multiline String Literals can be quite long
        \\        ,
        \\        (
        \\            \\Multiline String Literals can be quite long
        \\        ),
        \\        .{
        \\            \\xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
        \\            \\xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
        \\            \\xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
        \\        },
        \\        .{(
        \\            \\xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
        \\        )},
        \\        .{
        \\            "xxxxxxx", "xxx",
        \\            (
        \\                \\ xxx
        \\            ),
        \\            "xxx",
        \\            "xxx",
        \\        },
        \\        .{ "xxxxxxx", "xxx", "xxx", "xxx" },
        \\        .{ "xxxxxxx", "xxx", "xxx", "xxx" },
        \\        "aaaaaaa", "bbbbbb", "ccccc", // -
        \\        "dddd",    ("eee"),  ("fff"),
        \\        .{
        \\            "xxx",            "xxx",
        \\            (
        \\                \\ xxx
        \\            ),
        \\            "xxxxxxxxxxxxxx",
        \\            "xxx",
        \\        },
        \\        .{
        \\            (
        \\                \\xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
        \\            ),
        \\            \\xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
        \\        },
        \\        \\xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
        \\        \\xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
        \\    });
        \\}
        \\
    );
}

test "zig fmt: use of comments and multiline string literals may force the parameters over multiple lines" {
    try testCanonical(
        \\pub fn makeMemUndefined(qzz: []u8) i1 {
        \\    cases.add( // fixed bug foo
        \\        "compile diagnostic string for top level decl type",
        \\        \\export fn entry() void {
        \\        \\    var foo: u32 = @This(){};
        \\        \\}
        \\    , &[_][]const u8{
        \\        "tmp.zig:2:27: error: type 'u32' does not support array initialization",
        \\    });
        \\    @compileError(
        \\        \\ unknown-length pointers and C pointers cannot be hashed deeply.
        \\        \\ Consider providing your own hash function.
        \\        \\ unknown-length pointers and C pointers cannot be hashed deeply.
        \\        \\ Consider providing your own hash function.
        \\    );
        \\    return @intCast(i1, doMemCheckClientRequestExpr(0, // default return
        \\        .MakeMemUndefined, @ptrToInt(qzz.ptr), qzz.len, 0, 0, 0));
        \\}
        \\
        \\// This looks like garbage don't do this
        \\const rparen = tree.prevToken(
        \\// the first token for the annotation expressions is the left
        \\// parenthesis, hence the need for two prevToken
        \\if (fn_proto.getAlignExpr()) |align_expr|
        \\    tree.prevToken(tree.prevToken(align_expr.firstToken()))
        \\else if (fn_proto.getSectionExpr()) |section_expr|
        \\    tree.prevToken(tree.prevToken(section_expr.firstToken()))
        \\else if (fn_proto.getCallconvExpr()) |callconv_expr|
        \\    tree.prevToken(tree.prevToken(callconv_expr.firstToken()))
        \\else switch (fn_proto.return_type) {
        \\    .Explicit => |node| node.firstToken(),
        \\    .InferErrorSet => |node| tree.prevToken(node.firstToken()),
        \\    .Invalid => unreachable,
        \\});
        \\
    );
}

test "zig fmt: single argument trailing commas in @builtins()" {
    try testCanonical(
        \\pub fn foo(qzz: []u8) i1 {
        \\    @panic(
        \\        foo,
        \\    );
        \\    panic(
        \\        foo,
        \\    );
        \\    @panic(
        \\        foo,
        \\        bar,
        \\    );
        \\}
        \\
    );
}

test "zig fmt: trailing comma should force multiline 1 column" {
    try testTransform(
        \\pub const UUID_NULL: uuid_t = [16]u8{0,0,0,0,};
        \\
    ,
        \\pub const UUID_NULL: uuid_t = [16]u8{
        \\    0,
        \\    0,
        \\    0,
        \\    0,
        \\};
        \\
    );
}

test "zig fmt: function params should align nicely" {
    try testCanonical(
        \\pub fn foo() void {
        \\    cases.addRuntimeSafety("slicing operator with sentinel",
        \\        \\const std = @import("std");
        \\    ++ check_panic_msg ++
        \\        \\pub fn main() void {
        \\        \\    var buf = [4]u8{'a','b','c',0};
        \\        \\    const slice = buf[0..:0];
        \\        \\}
        \\    );
        \\}
        \\
    );
}

test "zig fmt: fn proto end with anytype and comma" {
    try testCanonical(
        \\pub fn format(
        \\    out_stream: anytype,
        \\) !void {}
        \\
    );
}

test "zig fmt: space after top level doc comment" {
    try testCanonical(
        \\//! top level doc comment
        \\
        \\field: i32,
        \\
    );
}

test "zig fmt: for loop with ptr payload and index" {
    try testCanonical(
        \\test {
        \\    for (self.entries.items) |*item, i| {}
        \\    for (self.entries.items) |*item, i|
        \\        a = b;
        \\    for (self.entries.items) |*item, i| a = b;
        \\}
        \\
    );
}

test "zig fmt: proper indent line comment after multi-line single expr while loop" {
    try testCanonical(
        \\test {
        \\    while (a) : (b)
        \\        foo();
        \\
        \\    // bar
        \\    baz();
        \\}
        \\
    );
}

test "zig fmt: function with labeled block as return type" {
    try testCanonical(
        \\fn foo() t: {
        \\    break :t bar;
        \\} {
        \\    baz();
        \\}
        \\
    );
}

test "zig fmt: extern function with missing param name" {
    try testCanonical(
        \\extern fn a(
        \\    *b,
        \\    c: *d,
        \\) e;
        \\extern fn f(*g, h: *i) j;
        \\
    );
}

test "zig fmt: line comment after multiline single expr if statement with multiline string" {
    try testCanonical(
        \\test {
        \\    if (foo)
        \\        x =
        \\            \\hello
        \\            \\hello
        \\            \\
        \\        ;
        \\
        \\    // bar
        \\    baz();
        \\
        \\    if (foo)
        \\        x =
        \\            \\hello
        \\            \\hello
        \\            \\
        \\    else
        \\        y =
        \\            \\hello
        \\            \\hello
        \\            \\
        \\        ;
        \\
        \\    // bar
        \\    baz();
        \\}
        \\
    );
}

test "zig fmt: respect extra newline between fn and pub usingnamespace" {
    try testCanonical(
        \\fn foo() void {
        \\    bar();
        \\}
        \\
        \\pub usingnamespace baz;
        \\
    );
}

test "zig fmt: respect extra newline between switch items" {
    try testCanonical(
        \\const a = switch (b) {
        \\    .c => {},
        \\
        \\    .d,
        \\    .e,
        \\    => f,
        \\};
        \\
    );
}

test "zig fmt: assignment with inline for and inline while" {
    try testCanonical(
        \\const tmp = inline for (items) |item| {};
        \\
    );

    try testCanonical(
        \\const tmp2 = inline while (true) {};
        \\
    );
}

test "zig fmt: insert trailing comma if there are comments between switch values" {
    try testTransform(
        \\const a = switch (b) {
        \\    .c => {},
        \\
        \\    .d, // foobar
        \\    .e
        \\    => f,
        \\
        \\    .g, .h
        \\    // comment
        \\    => i,
        \\};
        \\
    ,
        \\const a = switch (b) {
        \\    .c => {},
        \\
        \\    .d, // foobar
        \\    .e,
        \\    => f,
        \\
        \\    .g,
        \\    .h,
        \\    // comment
        \\    => i,
        \\};
        \\
    );
}

test "zig fmt: insert trailing comma if comments in array init" {
    try testTransform(
        \\var a = .{
        \\    "foo", //
        \\    "bar"
        \\};
        \\var a = .{
        \\    "foo",
        \\    "bar" //
        \\};
        \\var a = .{
        \\    "foo",
        \\    "//"
        \\};
        \\var a = .{
        \\    "foo",
        \\    "//" //
        \\};
        \\
    ,
        \\var a = .{
        \\    "foo", //
        \\    "bar",
        \\};
        \\var a = .{
        \\    "foo",
        \\    "bar", //
        \\};
        \\var a = .{ "foo", "//" };
        \\var a = .{
        \\    "foo",
        \\    "//", //
        \\};
        \\
    );
}

test "zig fmt: make single-line if no trailing comma" {
    try testTransform(
        \\test "function call no trailing comma" {
        \\    foo(
        \\        1,
        \\        2
        \\    );
        \\}
        \\
    ,
        \\test "function call no trailing comma" {
        \\    foo(1, 2);
        \\}
        \\
    );

    try testTransform(
        \\test "struct no trailing comma" {
        \\    const a = .{
        \\        .foo = 1,
        \\        .bar = 2
        \\    };
        \\}
        \\
    ,
        \\test "struct no trailing comma" {
        \\    const a = .{ .foo = 1, .bar = 2 };
        \\}
        \\
    );

    try testTransform(
        \\test "array no trailing comma" {
        \\    var stream = multiOutStream(.{
        \\        fbs1.outStream(),
        \\        fbs2.outStream()
        \\    });
        \\}
        \\
    ,
        \\test "array no trailing comma" {
        \\    var stream = multiOutStream(.{ fbs1.outStream(), fbs2.outStream() });
        \\}
        \\
    );
}

test "zig fmt: error for invalid bit range" {
    try testError(
        \\var x: []align(0:0:0)u8 = bar;
    , &[_]Error{
        .invalid_bit_range,
    });
}

test "zig fmt: error for ptr mod on array child type" {
    try testError(
        \\var a: [10]align(10) u8 = e;
        \\var b: [10]const u8 = f;
        \\var c: [10]volatile u8 = g;
        \\var d: [10]allowzero u8 = h;
    , &[_]Error{
        .ptr_mod_on_array_child_type,
        .ptr_mod_on_array_child_type,
        .ptr_mod_on_array_child_type,
        .ptr_mod_on_array_child_type,
    });
}

test "recovery: top level" {
    try testError(
        \\test "" {inline}
        \\test "" {inline}
    , &[_]Error{
        .expected_inlinable,
        .expected_inlinable,
    });
}

test "recovery: block statements" {
    try testError(
        \\test "" {
        \\    foo + +;
        \\    inline;
        \\}
    , &[_]Error{
        .invalid_token,
        .expected_inlinable,
    });
}

test "recovery: missing comma" {
    try testError(
        \\test "" {
        \\    switch (foo) {
        \\        2 => {}
        \\        3 => {}
        \\        else => {
        \\            foo && bar +;
        \\        }
        \\    }
        \\}
    , &[_]Error{
        .expected_token,
        .expected_token,
        .invalid_token,
    });
}

test "recovery: non-associative operators" {
    try testError(
        \\const x = a == b == c;
        \\const x = a == b != c;
    , &[_]Error{
        .expected_token,
        .expected_token,
    });
}

test "recovery: extra qualifier" {
    try testError(
        \\const a: *const const u8;
        \\test ""
    , &[_]Error{
        .extra_const_qualifier,
        .expected_block,
    });
}

test "recovery: missing return type" {
    try testError(
        \\fn foo() {
        \\    a && b;
        \\}
        \\test ""
    , &[_]Error{
        .expected_return_type,
        .expected_block,
    });
}

test "recovery: continue after invalid decl" {
    try testError(
        \\fn foo {
        \\    inline;
        \\}
        \\pub test "" {
        \\    async a && b;
        \\}
    , &[_]Error{
        .expected_token,
        .expected_pub_item,
        .expected_param_list,
    });
    try testError(
        \\threadlocal test "" {
        \\    @a && b;
        \\}
    , &[_]Error{
        .expected_var_decl,
        .expected_param_list,
    });
}

test "recovery: invalid extern/inline" {
    try testError(
        \\inline test "" { a && b; }
    , &[_]Error{
        .expected_fn,
    });
    try testError(
        \\extern "" test "" { a && b; }
    , &[_]Error{
        .expected_var_decl_or_fn,
    });
}

test "recovery: missing semicolon" {
    try testError(
        \\test "" {
        \\    comptime a && b
        \\    c && d
        \\    @foo
        \\}
    , &[_]Error{
        .expected_token,
        .expected_token,
        .expected_param_list,
        .expected_token,
    });
}

test "recovery: invalid container members" {
    try testError(
        \\usingnamespace;
        \\foo+
        \\bar@,
        \\while (a == 2) { test "" {}}
        \\test "" {
        \\    a && b
        \\}
    , &[_]Error{
        .expected_expr,
        .expected_token,
        .expected_container_members,
        .expected_token,
    });
}

// TODO after https://github.com/ziglang/zig/issues/35 is implemented,
// we should be able to recover from this *at any indentation level*,
// reporting a parse error and yet also parsing all the decls even
// inside structs.
test "recovery: extra '}' at top level" {
    try testError(
        \\}}}
        \\test "" {
        \\    a && b;
        \\}
    , &[_]Error{
        .expected_token,
    });
}

test "recovery: mismatched bracket at top level" {
    try testError(
        \\const S = struct {
        \\    arr: 128]?G
        \\};
    , &[_]Error{
        .expected_token,
    });
}

test "recovery: invalid global error set access" {
    try testError(
        \\test "" {
        \\    error && foo;
        \\}
    , &[_]Error{
        .expected_token,
        .expected_token,
    });
}

test "recovery: invalid asterisk after pointer dereference" {
    try testError(
        \\test "" {
        \\    var sequence = "repeat".*** 10;
        \\}
    , &[_]Error{
        .asterisk_after_ptr_deref,
    });
    try testError(
        \\test "" {
        \\    var sequence = "repeat".** 10&&a;
        \\}
    , &[_]Error{
        .asterisk_after_ptr_deref,
    });
}

test "recovery: missing semicolon after if, for, while stmt" {
    try testError(
        \\test "" {
        \\    if (foo) bar
        \\    for (foo) |a| bar
        \\    while (foo) bar
        \\    a && b;
        \\}
    , &[_]Error{
        .expected_semi_or_else,
        .expected_semi_or_else,
        .expected_semi_or_else,
    });
}

test "recovery: invalid comptime" {
    try testError(
        \\comptime
    , &[_]Error{
        .expected_block_or_field,
    });
}

test "recovery: missing block after suspend" {
    // TODO Enable this after zig 0.9.0 is released.
    if (true) return error.SkipZigTest;

    try testError(
        \\fn foo() void {
        \\    suspend;
        \\    nosuspend;
        \\}
    , &[_]Error{
        .expected_block_or_expr,
        .expected_block_or_expr,
    });
}

test "recovery: missing block after for/while loops" {
    try testError(
        \\test "" { while (foo) }
    , &[_]Error{
        .expected_block_or_assignment,
    });
    try testError(
        \\test "" { for (foo) |bar| }
    , &[_]Error{
        .expected_block_or_assignment,
    });
}

test "recovery: missing for payload" {
    try testError(
        \\comptime {
        \\    const a = for(a) {};
        \\    const a: for(a) blk: {};
        \\    for(a) {}
        \\}
    , &[_]Error{
        .expected_loop_payload,
        .expected_loop_payload,
        .expected_loop_payload,
    });
}

test "recovery: missing comma in params" {
    try testError(
        \\fn foo(comptime bool what what) void { }
        \\fn bar(a: i32, b: i32 c) void { }
        \\
    , &[_]Error{
        .expected_token,
        .expected_token,
        .expected_token,
    });
}

test "recovery: missing while rbrace" {
    try testError(
        \\fn a() b {
        \\    while (d) {
        \\}
    , &[_]Error{
        .expected_statement,
    });
}

test "recovery: nonfinal varargs" {
    try testError(
        \\extern fn f(a: u32, ..., b: u32) void;
        \\extern fn g(a: u32, ..., b: anytype) void;
        \\extern fn h(a: u32, ..., ...) void;
    , &[_]Error{
        .varargs_nonfinal,
        .varargs_nonfinal,
        .varargs_nonfinal,
    });
}

const std = @import("std");
const mem = std.mem;
const print = std.debug.print;
const io = std.io;
const maxInt = std.math.maxInt;

var fixed_buffer_mem: [100 * 1024]u8 = undefined;

fn testParse(source: [:0]const u8, allocator: *mem.Allocator, anything_changed: *bool) ![]u8 {
    const stderr = io.getStdErr().writer();

    var tree = try std.zig.parse(allocator, source);
    defer tree.deinit(allocator);

    for (tree.errors) |parse_error| {
        const loc = tree.tokenLocation(0, parse_error.token);
        try stderr.print("(memory buffer):{d}:{d}: error: ", .{ loc.line + 1, loc.column + 1 });
        try tree.renderError(parse_error, stderr);
        try stderr.print("\n{s}\n", .{source[loc.line_start..loc.line_end]});
        {
            var i: usize = 0;
            while (i < loc.column) : (i += 1) {
                try stderr.writeAll(" ");
            }
            try stderr.writeAll("^");
        }
        try stderr.writeAll("\n");
    }
    if (tree.errors.len != 0) {
        return error.ParseError;
    }

    const formatted = try tree.render(allocator);
    anything_changed.* = !mem.eql(u8, formatted, source);
    return formatted;
}
fn testTransform(source: [:0]const u8, expected_source: []const u8) !void {
    const needed_alloc_count = x: {
        // Try it once with unlimited memory, make sure it works
        var fixed_allocator = std.heap.FixedBufferAllocator.init(fixed_buffer_mem[0..]);
        var failing_allocator = std.testing.FailingAllocator.init(&fixed_allocator.allocator, maxInt(usize));
        var anything_changed: bool = undefined;
        const result_source = try testParse(source, &failing_allocator.allocator, &anything_changed);
        try std.testing.expectEqualStrings(expected_source, result_source);
        const changes_expected = source.ptr != expected_source.ptr;
        if (anything_changed != changes_expected) {
            print("std.zig.render returned {} instead of {}\n", .{ anything_changed, changes_expected });
            return error.TestFailed;
        }
        try std.testing.expect(anything_changed == changes_expected);
        failing_allocator.allocator.free(result_source);
        break :x failing_allocator.index;
    };

    var fail_index: usize = 0;
    while (fail_index < needed_alloc_count) : (fail_index += 1) {
        var fixed_allocator = std.heap.FixedBufferAllocator.init(fixed_buffer_mem[0..]);
        var failing_allocator = std.testing.FailingAllocator.init(&fixed_allocator.allocator, fail_index);
        var anything_changed: bool = undefined;
        if (testParse(source, &failing_allocator.allocator, &anything_changed)) |_| {
            return error.NondeterministicMemoryUsage;
        } else |err| switch (err) {
            error.OutOfMemory => {
                if (failing_allocator.allocated_bytes != failing_allocator.freed_bytes) {
                    print(
                        "\nfail_index: {d}/{d}\nallocated bytes: {d}\nfreed bytes: {d}\nallocations: {d}\ndeallocations: {d}\n",
                        .{
                            fail_index,
                            needed_alloc_count,
                            failing_allocator.allocated_bytes,
                            failing_allocator.freed_bytes,
                            failing_allocator.allocations,
                            failing_allocator.deallocations,
                        },
                    );
                    return error.MemoryLeakDetected;
                }
            },
            else => return err,
        }
    }
}
fn testCanonical(source: [:0]const u8) !void {
    return testTransform(source, source);
}

const Error = std.zig.ast.Error.Tag;

fn testError(source: [:0]const u8, expected_errors: []const Error) !void {
    var tree = try std.zig.parse(std.testing.allocator, source);
    defer tree.deinit(std.testing.allocator);

    try std.testing.expectEqual(expected_errors.len, tree.errors.len);
    for (expected_errors) |expected, i| {
        try std.testing.expectEqual(expected, tree.errors[i].tag);
    }
}
