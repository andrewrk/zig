const tests = @import("tests.zig");
const std = @import("std");
const CrossTarget = std.zig.CrossTarget;

pub fn addCases(cases: *tests.TranslateCContext) void {
    const default_enum_type = if (std.Target.current.abi == .msvc) "c_int" else "c_uint";

    cases.add("field access is grouped if necessary",
        \\unsigned long foo(unsigned long x) {
        \\    return ((union{unsigned long _x}){x})._x;
        \\}
    , &[_][]const u8{
        \\pub export fn foo(arg_x: c_ulong) c_ulong {
        \\    var x = arg_x;
        \\    const union_unnamed_1 = extern union {
        \\        _x: c_ulong,
        \\    };
        \\    return (union_unnamed_1{
        \\        ._x = x,
        \\    })._x;
        \\}
    });

    cases.add("unnamed child types of typedef receive typedef's name",
        \\typedef enum {
        \\    FooA,
        \\    FooB,
        \\} Foo;
        \\typedef struct {
        \\    int a, b;
        \\} Bar;
    , &[_][]const u8{
        \\pub const FooA: c_int = 0;
        \\pub const FooB: c_int = 1;
        \\pub const Foo =
        ++ " " ++ default_enum_type ++
            \\;
            \\pub const Bar = extern struct {
            \\    a: c_int,
            \\    b: c_int,
            \\};
    });

    cases.add("if as while stmt has semicolon",
        \\void foo() {
        \\    while (1) if (1) {
        \\        int a = 1;
        \\    } else {
        \\        int b = 2;
        \\    }
        \\    if (1) if (1) {}
        \\}
    , &[_][]const u8{
        \\pub export fn foo() void {
        \\    while (true) if (true) {
        \\        var a: c_int = 1;
        \\        _ = a;
        \\    } else {
        \\        var b: c_int = 2;
        \\        _ = b;
        \\    };
        \\    if (true) if (true) {};
        \\}
    });

    cases.add("conditional operator cast to void",
        \\int bar();
        \\void foo() {
        \\    int a;
        \\    a ? a = 2 : bar();
        \\}
    , &[_][]const u8{
        \\pub extern fn bar(...) c_int;
        \\pub export fn foo() void {
        \\    var a: c_int = undefined;
        \\    if (a != 0) a = 2 else _ = bar();
        \\}
    });

    cases.add("struct in struct init to zero",
        \\struct Foo {
        \\    int a;
        \\    struct Bar {
        \\        int a;
        \\    } b;
        \\} a = {};
        \\#define PTR void *
    , &[_][]const u8{
        \\pub const struct_Bar = extern struct {
        \\    a: c_int,
        \\};
        \\pub const struct_Foo = extern struct {
        \\    a: c_int,
        \\    b: struct_Bar,
        \\};
        \\pub export var a: struct_Foo = struct_Foo{
        \\    .a = 0,
        \\    .b = @import("std").mem.zeroes(struct_Bar),
        \\};
        ,
        \\pub const PTR = ?*c_void;
    });

    cases.add("scoped record",
        \\void foo() {
        \\	struct Foo {
        \\		int A;
        \\		int B;
        \\		int C;
        \\	};
        \\	struct Foo a = {0};
        \\	{
        \\		struct Foo {
        \\			int A;
        \\			int B;
        \\			int C;
        \\		};
        \\		struct Foo a = {0};
        \\	}
        \\}
    , &[_][]const u8{
        \\pub export fn foo() void {
        \\    const struct_Foo = extern struct {
        \\        A: c_int,
        \\        B: c_int,
        \\        C: c_int,
        \\    };
        \\    var a: struct_Foo = struct_Foo{
        \\        .A = @as(c_int, 0),
        \\        .B = 0,
        \\        .C = 0,
        \\    };
        \\    _ = a;
        \\    {
        \\        const struct_Foo_1 = extern struct {
        \\            A: c_int,
        \\            B: c_int,
        \\            C: c_int,
        \\        };
        \\        var a_2: struct_Foo_1 = struct_Foo_1{
        \\            .A = @as(c_int, 0),
        \\            .B = 0,
        \\            .C = 0,
        \\        };
        \\        _ = a_2;
        \\    }
        \\}
    });

    cases.add("scoped typedef",
        \\void foo() {
        \\	typedef union {
        \\		int A;
        \\		int B;
        \\		int C;
        \\	} Foo;
        \\	Foo a = {0};
        \\	{
        \\		typedef union {
        \\			int A;
        \\			int B;
        \\			int C;
        \\		} Foo;
        \\		Foo a = {0};
        \\	}
        \\}
    , &[_][]const u8{
        \\pub export fn foo() void {
        \\    const union_unnamed_1 = extern union {
        \\        A: c_int,
        \\        B: c_int,
        \\        C: c_int,
        \\    };
        \\    _ = union_unnamed_1;
        \\    const Foo = union_unnamed_1;
        \\    var a: Foo = Foo{
        \\        .A = @as(c_int, 0),
        \\    };
        \\    _ = a;
        \\    {
        \\        const union_unnamed_2 = extern union {
        \\            A: c_int,
        \\            B: c_int,
        \\            C: c_int,
        \\        };
        \\        _ = union_unnamed_2;
        \\        const Foo_1 = union_unnamed_2;
        \\        var a_2: Foo_1 = Foo_1{
        \\            .A = @as(c_int, 0),
        \\        };
        \\        _ = a_2;
        \\    }
        \\}
    });

    cases.add("use cast param as macro fn return type",
        \\#include <stdint.h>
        \\#define MEM_PHYSICAL_TO_K0(x) (void*)((uint32_t)(x) + SYS_BASE_CACHED)
    , &[_][]const u8{
        \\pub inline fn MEM_PHYSICAL_TO_K0(x: anytype) ?*c_void {
        \\    return @import("std").zig.c_translation.cast(?*c_void, @import("std").zig.c_translation.cast(u32, x) + SYS_BASE_CACHED);
        \\}
    });

    cases.add("variadic function demoted to extern",
        \\int foo(int bar, ...) {
        \\    return 1;
        \\}
    , &[_][]const u8{
        \\warning: TODO unable to translate variadic function, demoted to extern
        \\pub extern fn foo(bar: c_int, ...) c_int;
    });

    cases.add("pointer to opaque demoted struct",
        \\typedef struct {
        \\    _Atomic int foo;
        \\} Foo;
        \\
        \\typedef struct {
        \\    Foo *bar;
        \\} Bar;
    , &[_][]const u8{
        \\source.h:1:9: warning: struct demoted to opaque type - unable to translate type of field foo
        \\pub const Foo = opaque {};
        \\pub const Bar = extern struct {
        \\    bar: ?*Foo,
        \\};
    });

    cases.add("macro expressions respect C operator precedence",
        \\#define FOO *((foo) + 2)
        \\#define VALUE  (1 + 2 * 3 + 4 * 5 + 6 << 7 | 8 == 9)
        \\#define _AL_READ3BYTES(p)   ((*(unsigned char *)(p))            \
        \\                             | (*((unsigned char *)(p) + 1) << 8)  \
        \\                             | (*((unsigned char *)(p) + 2) << 16))
    , &[_][]const u8{
        \\pub const FOO = (foo + @as(c_int, 2)).*;
        ,
        \\pub const VALUE = ((((@as(c_int, 1) + (@as(c_int, 2) * @as(c_int, 3))) + (@as(c_int, 4) * @as(c_int, 5))) + @as(c_int, 6)) << @as(c_int, 7)) | @boolToInt(@as(c_int, 8) == @as(c_int, 9));
        ,
        \\pub inline fn _AL_READ3BYTES(p: anytype) @TypeOf((@import("std").zig.c_translation.cast([*c]u8, p).* | ((@import("std").zig.c_translation.cast([*c]u8, p) + @as(c_int, 1)).* << @as(c_int, 8))) | ((@import("std").zig.c_translation.cast([*c]u8, p) + @as(c_int, 2)).* << @as(c_int, 16))) {
        \\    return (@import("std").zig.c_translation.cast([*c]u8, p).* | ((@import("std").zig.c_translation.cast([*c]u8, p) + @as(c_int, 1)).* << @as(c_int, 8))) | ((@import("std").zig.c_translation.cast([*c]u8, p) + @as(c_int, 2)).* << @as(c_int, 16));
        \\}
    });

    cases.add("static variable in block scope",
        \\float bar;
        \\int foo() {
        \\    _Thread_local static int bar = 2;
        \\}
    , &[_][]const u8{
        \\pub export var bar: f32 = @import("std").mem.zeroes(f32);
        \\pub export fn foo() c_int {
        \\    const bar_1 = struct {
        \\        threadlocal var static: c_int = 2;
        \\    };
        \\    _ = bar_1;
        \\    return 0;
        \\}
    });

    cases.add("missing return stmt",
        \\int foo() {}
        \\int bar() {
        \\    int a = 2;
        \\}
        \\int baz() {
        \\    return 0;
        \\}
    , &[_][]const u8{
        \\pub export fn foo() c_int {
        \\    return 0;
        \\}
        \\pub export fn bar() c_int {
        \\    var a: c_int = 2;
        \\    _ = a;
        \\    return 0;
        \\}
        \\pub export fn baz() c_int {
        \\    return 0;
        \\}
    });

    cases.add("alignof",
        \\void main() {
        \\    int a = _Alignof(int);
        \\}
    , &[_][]const u8{
        \\pub export fn main() void {
        \\    var a: c_int = @bitCast(c_int, @truncate(c_uint, @alignOf(c_int)));
        \\    _ = a;
        \\}
    });

    cases.add("initializer list macro",
        \\typedef struct Color {
        \\    unsigned char r;
        \\    unsigned char g;
        \\    unsigned char b;
        \\    unsigned char a;
        \\} Color;
        \\#define CLITERAL(type)      (type)
        \\#define LIGHTGRAY  CLITERAL(Color){ 200, 200, 200, 255 }   // Light Gray
        \\typedef struct boom_t
        \\{
        \\    int i1;
        \\} boom_t;
        \\#define FOO ((boom_t){1})
        \\typedef struct { float x; } MyCStruct;
        \\#define A(_x)   (MyCStruct) { .x = (_x) }
        \\#define B A(0.f)
    , &[_][]const u8{
        \\pub const struct_Color = extern struct {
        \\    r: u8,
        \\    g: u8,
        \\    b: u8,
        \\    a: u8,
        \\};
        \\pub const Color = struct_Color;
        ,
        \\pub inline fn CLITERAL(type_1: anytype) @TypeOf(type_1) {
        \\    return type_1;
        \\}
        ,
        \\pub const LIGHTGRAY = @import("std").mem.zeroInit(CLITERAL(Color), .{ @as(c_int, 200), @as(c_int, 200), @as(c_int, 200), @as(c_int, 255) });
        ,
        \\pub const struct_boom_t = extern struct {
        \\    i1: c_int,
        \\};
        \\pub const boom_t = struct_boom_t;
        ,
        \\pub const FOO = @import("std").mem.zeroInit(boom_t, .{@as(c_int, 1)});
        ,
        \\pub const MyCStruct = extern struct {
        \\    x: f32,
        \\};
        ,
        \\pub inline fn A(_x: anytype) MyCStruct {
        \\    return @import("std").mem.zeroInit(MyCStruct, .{
        \\        .x = _x,
        \\    });
        \\}
        ,
        \\pub const B = A(@as(f32, 0.0));
    });

    cases.add("complex switch",
        \\int main() {
        \\    int i = 2;
        \\    switch (i) {
        \\        case 0: {
        \\            case 2:{
        \\                i += 2;}
        \\            i += 1;
        \\        }
        \\    }
        \\}
    , &[_][]const u8{ // TODO properly translate this
        \\source.h:5:13: warning: TODO complex switch
        ,
        \\source.h:1:5: warning: unable to translate function, demoted to extern
        \\pub extern fn main() c_int;
    });

    cases.add("correct semicolon after infixop",
        \\#define __ferror_unlocked_body(_fp) (((_fp)->_flags & _IO_ERR_SEEN) != 0)
    , &[_][]const u8{
        \\pub inline fn __ferror_unlocked_body(_fp: anytype) @TypeOf((_fp.*._flags & _IO_ERR_SEEN) != @as(c_int, 0)) {
        \\    return (_fp.*._flags & _IO_ERR_SEEN) != @as(c_int, 0);
        \\}
    });

    cases.add("c booleans are just ints",
        \\#define FOO(x) ((x >= 0) + (x >= 0))
        \\#define BAR 1 && 2 > 4
    , &[_][]const u8{
        \\pub inline fn FOO(x: anytype) @TypeOf(@boolToInt(x >= @as(c_int, 0)) + @boolToInt(x >= @as(c_int, 0))) {
        \\    return @boolToInt(x >= @as(c_int, 0)) + @boolToInt(x >= @as(c_int, 0));
        \\}
        ,
        \\pub const BAR = (@as(c_int, 1) != 0) and (@as(c_int, 2) > @as(c_int, 4));
    });

    cases.add("struct with aligned fields",
        \\struct foo {
        \\    __attribute__((aligned(1))) short bar;
        \\};
    , &[_][]const u8{
        \\pub const struct_foo = extern struct {
        \\    bar: c_short align(1),
        \\};
    });

    cases.add("struct with flexible array",
        \\struct foo { int x; int y[]; };
        \\struct bar { int x; int y[0]; };
    , &[_][]const u8{
        \\pub const struct_foo = extern struct {
        \\    x: c_int align(4),
        \\    pub fn y(self: anytype) @import("std").zig.c_translation.FlexibleArrayType(@TypeOf(self), c_int) {
        \\        const Intermediate = @import("std").zig.c_translation.FlexibleArrayType(@TypeOf(self), u8);
        \\        const ReturnType = @import("std").zig.c_translation.FlexibleArrayType(@TypeOf(self), c_int);
        \\        return @ptrCast(ReturnType, @alignCast(@alignOf(c_int), @ptrCast(Intermediate, self) + 4));
        \\    }
        \\};
        \\pub const struct_bar = extern struct {
        \\    x: c_int align(4),
        \\    pub fn y(self: anytype) @import("std").zig.c_translation.FlexibleArrayType(@TypeOf(self), c_int) {
        \\        const Intermediate = @import("std").zig.c_translation.FlexibleArrayType(@TypeOf(self), u8);
        \\        const ReturnType = @import("std").zig.c_translation.FlexibleArrayType(@TypeOf(self), c_int);
        \\        return @ptrCast(ReturnType, @alignCast(@alignOf(c_int), @ptrCast(Intermediate, self) + 4));
        \\    }
        \\};
    });

    cases.add("nested loops without blocks",
        \\void foo() {
        \\    while (0) while (0) {}
        \\    for (;;) while (0);
        \\    for (;;) do {} while (0);
        \\}
    , &[_][]const u8{
        \\pub export fn foo() void {
        \\    while (false) while (false) {};
        \\    while (true) while (false) {};
        \\    while (true) {}
        \\}
    });

    cases.add("macro comma operator",
        \\#define foo (foo, bar)
        \\#define bar(x) (&x, +3, 4 == 4, 5 * 6, baz(1, 2), 2 % 2, baz(1,2))
    , &[_][]const u8{
        \\pub const foo = blk: {
        \\    _ = foo;
        \\    break :blk bar;
        \\};
        ,
        \\pub inline fn bar(x: anytype) @TypeOf(baz(@as(c_int, 1), @as(c_int, 2))) {
        \\    return blk: {
        \\        _ = &x;
        \\        _ = @as(c_int, 3);
        \\        _ = @as(c_int, 4) == @as(c_int, 4);
        \\        _ = @as(c_int, 5) * @as(c_int, 6);
        \\        _ = baz(@as(c_int, 1), @as(c_int, 2));
        \\        _ = @as(c_int, 2) % @as(c_int, 2);
        \\        break :blk baz(@as(c_int, 1), @as(c_int, 2));
        \\    };
        \\}
    });

    cases.add("macro keyword define",
        \\#define foo 1
        \\#define inline 2
    , &[_][]const u8{
        \\pub const foo = @as(c_int, 1);
        ,
        \\pub const @"inline" = @as(c_int, 2);
    });

    cases.add("macro line continuation",
        \\#define FOO -\
        \\BAR
    , &[_][]const u8{
        \\pub const FOO = -BAR;
    });

    cases.add("struct with atomic field",
        \\struct arcan_shmif_cont {
        \\        struct arcan_shmif_page* addr;
        \\};
        \\struct arcan_shmif_page {
        \\        volatile _Atomic int abufused[12];
        \\};
    , &[_][]const u8{
        \\source.h:4:8: warning: struct demoted to opaque type - unable to translate type of field abufused
        \\pub const struct_arcan_shmif_page = opaque {};
        \\pub const struct_arcan_shmif_cont = extern struct {
        \\    addr: ?*struct_arcan_shmif_page,
        \\};
    });

    cases.add("function prototype translated as optional",
        \\typedef void (*fnptr_ty)(void);
        \\typedef __attribute__((cdecl)) void (*fnptr_attr_ty)(void);
        \\struct foo {
        \\    __attribute__((cdecl)) void (*foo)(void);
        \\    void (*bar)(void);
        \\    fnptr_ty baz;
        \\    fnptr_attr_ty qux;
        \\};
    , &[_][]const u8{
        \\pub const fnptr_ty = ?fn () callconv(.C) void;
        \\pub const fnptr_attr_ty = ?fn () callconv(.C) void;
        \\pub const struct_foo = extern struct {
        \\    foo: ?fn () callconv(.C) void,
        \\    bar: ?fn () callconv(.C) void,
        \\    baz: fnptr_ty,
        \\    qux: fnptr_attr_ty,
        \\};
    });

    cases.add("function prototype with parenthesis",
        \\void (f0) (void *L);
        \\void ((f1)) (void *L);
        \\void (((f2))) (void *L);
    , &[_][]const u8{
        \\pub extern fn f0(L: ?*c_void) void;
        \\pub extern fn f1(L: ?*c_void) void;
        \\pub extern fn f2(L: ?*c_void) void;
    });

    cases.add("array initializer w/ typedef",
        \\typedef unsigned char uuid_t[16];
        \\static const uuid_t UUID_NULL __attribute__ ((unused)) = {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0};
    , &[_][]const u8{
        \\pub const uuid_t = [16]u8;
        \\pub const UUID_NULL: uuid_t = [16]u8{
        \\    0,
        \\    0,
        \\    0,
        \\    0,
        \\    0,
        \\    0,
        \\    0,
        \\    0,
        \\    0,
        \\    0,
        \\    0,
        \\    0,
        \\    0,
        \\    0,
        \\    0,
        \\    0,
        \\};
    });

    cases.add("empty declaration",
        \\;
    , &[_][]const u8{""});

    cases.add("#define hex literal with capital X",
        \\#define VAL 0XF00D
    , &[_][]const u8{
        \\pub const VAL = @import("std").zig.c_translation.promoteIntLiteral(c_int, 0xF00D, .hexadecimal);
    });

    cases.add("anonymous struct & unions",
        \\typedef struct {
        \\    union {
        \\        char x;
        \\        struct { int y; };
        \\    };
        \\} outer;
        \\void foo(outer *x) { x->y = x->x; }
    , &[_][]const u8{
        \\const struct_unnamed_2 = extern struct {
        \\    y: c_int,
        \\};
        \\const union_unnamed_1 = extern union {
        \\    x: u8,
        \\    unnamed_0: struct_unnamed_2,
        \\};
        \\pub const outer = extern struct {
        \\    unnamed_0: union_unnamed_1,
        \\};
        \\pub export fn foo(arg_x: [*c]outer) void {
        \\    var x = arg_x;
        \\    x.*.unnamed_0.unnamed_0.y = @bitCast(c_int, @as(c_uint, x.*.unnamed_0.x));
        \\}
    });

    cases.add("union initializer",
        \\union { int x; char c[4]; }
        \\  ua = {1},
        \\  ub = {.c={'a','b','b','a'}};
    , &[_][]const u8{
        \\const union_unnamed_1 = extern union {
        \\    x: c_int,
        \\    c: [4]u8,
        \\};
        \\pub export var ua: union_unnamed_1 = union_unnamed_1{
        \\    .x = @as(c_int, 1),
        \\};
        \\pub export var ub: union_unnamed_1 = union_unnamed_1{
        \\    .c = [4]u8{
        \\        'a',
        \\        'b',
        \\        'b',
        \\        'a',
        \\    },
        \\};
    });

    cases.add("struct initializer - simple",
        \\typedef struct { int x; } foo;
        \\struct {double x,y,z;} s0 = {1.2, 1.3};
        \\struct {int sec,min,hour,day,mon,year;} s1 = {.day=31,12,2014,.sec=30,15,17};
        \\struct {int x,y;} s2 = {.y = 2, .x=1};
        \\foo s3 = { 123 };
    , &[_][]const u8{
        \\pub const foo = extern struct {
        \\    x: c_int,
        \\};
        \\const struct_unnamed_1 = extern struct {
        \\    x: f64,
        \\    y: f64,
        \\    z: f64,
        \\};
        \\pub export var s0: struct_unnamed_1 = struct_unnamed_1{
        \\    .x = 1.2,
        \\    .y = 1.3,
        \\    .z = 0,
        \\};
        \\const struct_unnamed_2 = extern struct {
        \\    sec: c_int,
        \\    min: c_int,
        \\    hour: c_int,
        \\    day: c_int,
        \\    mon: c_int,
        \\    year: c_int,
        \\};
        \\pub export var s1: struct_unnamed_2 = struct_unnamed_2{
        \\    .sec = @as(c_int, 30),
        \\    .min = @as(c_int, 15),
        \\    .hour = @as(c_int, 17),
        \\    .day = @as(c_int, 31),
        \\    .mon = @as(c_int, 12),
        \\    .year = @as(c_int, 2014),
        \\};
        \\const struct_unnamed_3 = extern struct {
        \\    x: c_int,
        \\    y: c_int,
        \\};
        \\pub export var s2: struct_unnamed_3 = struct_unnamed_3{
        \\    .x = @as(c_int, 1),
        \\    .y = @as(c_int, 2),
        \\};
        \\pub export var s3: foo = foo{
        \\    .x = @as(c_int, 123),
        \\};
    });

    cases.add("simple ptrCast for casts between opaque types",
        \\struct opaque;
        \\struct opaque_2;
        \\void function(struct opaque *opaque) {
        \\    struct opaque_2 *cast = (struct opaque_2 *)opaque;
        \\}
    , &[_][]const u8{
        \\pub const struct_opaque = opaque {};
        \\pub const struct_opaque_2 = opaque {};
        \\pub export fn function(arg_opaque_1: ?*struct_opaque) void {
        \\    var opaque_1 = arg_opaque_1;
        \\    var cast: ?*struct_opaque_2 = @ptrCast(?*struct_opaque_2, opaque_1);
        \\    _ = cast;
        \\}
    });

    cases.add("struct initializer - packed",
        \\struct {int x,y,z;} __attribute__((packed)) s0 = {1, 2};
    , &[_][]const u8{
        \\const struct_unnamed_1 = packed struct {
        \\    x: c_int,
        \\    y: c_int,
        \\    z: c_int,
        \\};
        \\pub export var s0: struct_unnamed_1 = struct_unnamed_1{
        \\    .x = @as(c_int, 1),
        \\    .y = @as(c_int, 2),
        \\    .z = 0,
        \\};
    });

    cases.add("align() attribute",
        \\__attribute__ ((aligned(128)))
        \\extern char my_array[16];
        \\__attribute__ ((aligned(128)))
        \\void my_fn(void) { }
        \\void other_fn(void) {
        \\    char ARR[16] __attribute__ ((aligned (16)));
        \\}
    , &[_][]const u8{
        \\pub extern var my_array: [16]u8 align(128);
        \\pub export fn my_fn() align(128) void {}
        \\pub export fn other_fn() void {
        \\    var ARR: [16]u8 align(16) = undefined;
        \\    _ = ARR;
        \\}
    });

    cases.add("linksection() attribute",
        \\// Use the "segment,section" format to make this test pass when
        \\// targeting the mach-o binary format
        \\__attribute__ ((__section__("NEAR,.data")))
        \\extern char my_array[16];
        \\__attribute__ ((__section__("NEAR,.data")))
        \\void my_fn(void) { }
    , &[_][]const u8{
        \\pub extern var my_array: [16]u8 linksection("NEAR,.data");
        \\pub export fn my_fn() linksection("NEAR,.data") void {}
    });

    cases.add("simple function prototypes",
        \\void __attribute__((noreturn)) foo(void);
        \\int bar(void);
    , &[_][]const u8{
        \\pub extern fn foo() noreturn;
        \\pub extern fn bar() c_int;
    });

    cases.add("simple var decls",
        \\void foo(void) {
        \\    int a;
        \\    char b = 123;
        \\    const int c;
        \\    const unsigned d = 440;
        \\    int e = 10;
        \\    unsigned int f = 10u;
        \\}
    , &[_][]const u8{
        \\pub export fn foo() void {
        \\    var a: c_int = undefined;
        \\    _ = a;
        \\    var b: u8 = 123;
        \\    _ = b;
        \\    const c: c_int = undefined;
        \\    _ = c;
        \\    const d: c_uint = @bitCast(c_uint, @as(c_int, 440));
        \\    _ = d;
        \\    var e: c_int = 10;
        \\    _ = e;
        \\    var f: c_uint = 10;
        \\    _ = f;
        \\}
    });

    cases.add("ignore result, explicit function arguments",
        \\void foo(void) {
        \\    int a;
        \\    1;
        \\    "hey";
        \\    1 + 1;
        \\    1 - 1;
        \\    a = 1;
        \\}
    , &[_][]const u8{
        \\pub export fn foo() void {
        \\    var a: c_int = undefined;
        \\    _ = @as(c_int, 1);
        \\    _ = "hey";
        \\    _ = @as(c_int, 1) + @as(c_int, 1);
        \\    _ = @as(c_int, 1) - @as(c_int, 1);
        \\    a = 1;
        \\}
    });

    cases.add("function with no prototype",
        \\int foo() {
        \\    return 5;
        \\}
    , &[_][]const u8{
        \\pub export fn foo() c_int {
        \\    return 5;
        \\}
    });

    cases.add("variables",
        \\extern int extern_var;
        \\static const int int_var = 13;
        \\int foo;
    , &[_][]const u8{
        \\pub extern var extern_var: c_int;
        \\pub const int_var: c_int = 13;
        \\pub export var foo: c_int = @import("std").mem.zeroes(c_int);
    });

    cases.add("const ptr initializer",
        \\static const char *v0 = "0.0.0";
    , &[_][]const u8{
        \\pub var v0: [*c]const u8 = "0.0.0";
    });

    cases.add("static incomplete array inside function",
        \\void foo(void) {
        \\    static const char v2[] = "2.2.2";
        \\}
    , &[_][]const u8{
        \\pub export fn foo() void {
        \\    const v2 = struct {
        \\        const static: [5:0]u8 = "2.2.2".*;
        \\    };
        \\    _ = v2;
        \\}
    });

    cases.add("simple function definition",
        \\void foo(void) {}
        \\static void bar(void) {}
    , &[_][]const u8{
        \\pub export fn foo() void {}
        \\pub fn bar() callconv(.C) void {}
    });

    cases.add("typedef void",
        \\typedef void Foo;
        \\Foo fun(Foo *a);
    , &[_][]const u8{
        \\pub const Foo = c_void;
        ,
        \\pub extern fn fun(a: ?*Foo) Foo;
    });

    cases.add("duplicate typedef",
        \\typedef long foo;
        \\typedef int bar;
        \\typedef long foo;
        \\typedef int baz;
    , &[_][]const u8{
        \\pub const foo = c_long;
        \\pub const bar = c_int;
        \\pub const baz = c_int;
    });

    cases.add("casting pointers to ints and ints to pointers",
        \\void foo(void);
        \\void bar(void) {
        \\    void *func_ptr = foo;
        \\    void (*typed_func_ptr)(void) = (void (*)(void)) (unsigned long) func_ptr;
        \\}
    , &[_][]const u8{
        \\pub extern fn foo() void;
        \\pub export fn bar() void {
        \\    var func_ptr: ?*c_void = @ptrCast(?*c_void, foo);
        \\    var typed_func_ptr: ?fn () callconv(.C) void = @intToPtr(?fn () callconv(.C) void, @intCast(c_ulong, @ptrToInt(func_ptr)));
        \\    _ = typed_func_ptr;
        \\}
    });

    cases.add("noreturn attribute",
        \\void foo(void) __attribute__((noreturn));
    , &[_][]const u8{
        \\pub extern fn foo() noreturn;
    });

    cases.add("add, sub, mul, div, rem",
        \\int s() {
        \\    int a, b, c;
        \\    c = a + b;
        \\    c = a - b;
        \\    c = a * b;
        \\    c = a / b;
        \\    c = a % b;
        \\}
        \\unsigned u() {
        \\    unsigned a, b, c;
        \\    c = a + b;
        \\    c = a - b;
        \\    c = a * b;
        \\    c = a / b;
        \\    c = a % b;
        \\}
    , &[_][]const u8{
        \\pub export fn s() c_int {
        \\    var a: c_int = undefined;
        \\    var b: c_int = undefined;
        \\    var c: c_int = undefined;
        \\    c = a + b;
        \\    c = a - b;
        \\    c = a * b;
        \\    c = @divTrunc(a, b);
        \\    c = @rem(a, b);
        \\    return 0;
        \\}
        \\pub export fn u() c_uint {
        \\    var a: c_uint = undefined;
        \\    var b: c_uint = undefined;
        \\    var c: c_uint = undefined;
        \\    c = a +% b;
        \\    c = a -% b;
        \\    c = a *% b;
        \\    c = a / b;
        \\    c = a % b;
        \\    return 0;
        \\}
    });

    cases.add("typedef of function in struct field",
        \\typedef void lws_callback_function(void);
        \\struct Foo {
        \\    void (*func)(void);
        \\    lws_callback_function *callback_http;
        \\};
    , &[_][]const u8{
        \\pub const lws_callback_function = fn () callconv(.C) void;
        \\pub const struct_Foo = extern struct {
        \\    func: ?fn () callconv(.C) void,
        \\    callback_http: ?lws_callback_function,
        \\};
    });

    cases.add("pointer to struct demoted to opaque due to bit fields",
        \\struct Foo {
        \\    unsigned int: 1;
        \\};
        \\struct Bar {
        \\    struct Foo *foo;
        \\};
    , &[_][]const u8{
        \\pub const struct_Foo = opaque {};
        ,
        \\pub const struct_Bar = extern struct {
        \\    foo: ?*struct_Foo,
        \\};
    });

    cases.add("macro with left shift",
        \\#define REDISMODULE_READ (1<<0)
    , &[_][]const u8{
        \\pub const REDISMODULE_READ = @as(c_int, 1) << @as(c_int, 0);
    });

    cases.add("macro with right shift",
        \\#define FLASH_SIZE         0x200000UL          /* 2 MB   */
        \\#define FLASH_BANK_SIZE    (FLASH_SIZE >> 1)   /* 1 MB   */
    , &[_][]const u8{
        \\pub const FLASH_SIZE = @as(c_ulong, 0x200000);
        ,
        \\pub const FLASH_BANK_SIZE = FLASH_SIZE >> @as(c_int, 1);
    });

    cases.add("double define struct",
        \\typedef struct Bar Bar;
        \\typedef struct Foo Foo;
        \\
        \\struct Foo {
        \\    Foo *a;
        \\};
        \\
        \\struct Bar {
        \\    Foo *a;
        \\};
    , &[_][]const u8{
        \\pub const struct_Foo = extern struct {
        \\    a: [*c]Foo,
        \\};
        ,
        \\pub const Foo = struct_Foo;
        ,
        \\pub const struct_Bar = extern struct {
        \\    a: [*c]Foo,
        \\};
        ,
        \\pub const Bar = struct_Bar;
    });

    cases.add("simple struct",
        \\struct Foo {
        \\    int x;
        \\    char *y;
        \\};
    , &[_][]const u8{
        \\const struct_Foo = extern struct {
        \\    x: c_int,
        \\    y: [*c]u8,
        \\};
        ,
        \\pub const Foo = struct_Foo;
    });

    cases.add("self referential struct with function pointer",
        \\struct Foo {
        \\    void (*derp)(struct Foo *foo);
        \\};
    , &[_][]const u8{
        \\pub const struct_Foo = extern struct {
        \\    derp: ?fn ([*c]struct_Foo) callconv(.C) void,
        \\};
        ,
        \\pub const Foo = struct_Foo;
    });

    cases.add("struct prototype used in func",
        \\struct Foo;
        \\struct Foo *some_func(struct Foo *foo, int x);
    , &[_][]const u8{
        \\pub const struct_Foo = opaque {};
        ,
        \\pub extern fn some_func(foo: ?*struct_Foo, x: c_int) ?*struct_Foo;
        ,
        \\pub const Foo = struct_Foo;
    });

    cases.add("#define an unsigned integer literal",
        \\#define CHANNEL_COUNT 24
    , &[_][]const u8{
        \\pub const CHANNEL_COUNT = @as(c_int, 24);
    });

    cases.add("#define referencing another #define",
        \\#define THING2 THING1
        \\#define THING1 1234
    , &[_][]const u8{
        \\pub const THING1 = @as(c_int, 1234);
        ,
        \\pub const THING2 = THING1;
    });

    cases.add("circular struct definitions",
        \\struct Bar;
        \\
        \\struct Foo {
        \\    struct Bar *next;
        \\};
        \\
        \\struct Bar {
        \\    struct Foo *next;
        \\};
    , &[_][]const u8{
        \\pub const struct_Bar = extern struct {
        \\    next: [*c]struct_Foo,
        \\};
        ,
        \\pub const struct_Foo = extern struct {
        \\    next: [*c]struct_Bar,
        \\};
    });

    cases.add("#define string",
        \\#define  foo  "a string"
    , &[_][]const u8{
        \\pub const foo = "a string";
    });

    cases.add("zig keywords in C code",
        \\struct comptime {
        \\    int defer;
        \\};
    , &[_][]const u8{
        \\pub const struct_comptime = extern struct {
        \\    @"defer": c_int,
        \\};
        ,
        \\pub const @"comptime" = struct_comptime;
    });

    cases.add("macro with parens around negative number",
        \\#define LUA_GLOBALSINDEX        (-10002)
    , &[_][]const u8{
        \\pub const LUA_GLOBALSINDEX = -@as(c_int, 10002);
    });

    cases.add(
        "u integer suffix after 0 (zero) in macro definition",
        "#define ZERO 0U",
        &[_][]const u8{
            "pub const ZERO = @as(c_uint, 0);",
        },
    );

    cases.add(
        "l integer suffix after 0 (zero) in macro definition",
        "#define ZERO 0L",
        &[_][]const u8{
            "pub const ZERO = @as(c_long, 0);",
        },
    );

    cases.add(
        "ul integer suffix after 0 (zero) in macro definition",
        "#define ZERO 0UL",
        &[_][]const u8{
            "pub const ZERO = @as(c_ulong, 0);",
        },
    );

    cases.add(
        "lu integer suffix after 0 (zero) in macro definition",
        "#define ZERO 0LU",
        &[_][]const u8{
            "pub const ZERO = @as(c_ulong, 0);",
        },
    );

    cases.add(
        "ll integer suffix after 0 (zero) in macro definition",
        "#define ZERO 0LL",
        &[_][]const u8{
            "pub const ZERO = @as(c_longlong, 0);",
        },
    );

    cases.add(
        "ull integer suffix after 0 (zero) in macro definition",
        "#define ZERO 0ULL",
        &[_][]const u8{
            "pub const ZERO = @as(c_ulonglong, 0);",
        },
    );

    cases.add(
        "llu integer suffix after 0 (zero) in macro definition",
        "#define ZERO 0LLU",
        &[_][]const u8{
            "pub const ZERO = @as(c_ulonglong, 0);",
        },
    );

    cases.add(
        "bitwise not on u-suffixed 0 (zero) in macro definition",
        "#define NOT_ZERO (~0U)",
        &[_][]const u8{
            "pub const NOT_ZERO = ~@as(c_uint, 0);",
        },
    );

    cases.add("float suffixes",
        \\#define foo 3.14f
        \\#define bar 16.e-2l
        \\#define FOO 0.12345
        \\#define BAR .12345
    , &[_][]const u8{
        "pub const foo = @as(f32, 3.14);",
        "pub const bar = @as(c_longdouble, 16.0e-2);",
        "pub const FOO = 0.12345;",
        "pub const BAR = 0.12345;",
    });

    cases.add("comments",
        \\#define foo 1 //foo
        \\#define bar /* bar */ 2
    , &[_][]const u8{
        "pub const foo = @as(c_int, 1);",
        "pub const bar = @as(c_int, 2);",
    });

    cases.add("string prefix",
        \\#define foo L"hello"
    , &[_][]const u8{
        "pub const foo = \"hello\";",
    });

    cases.add("null statements",
        \\void foo(void) {
        \\    ;;;;;
        \\}
    , &[_][]const u8{
        \\pub export fn foo() void {}
    });

    if (std.Target.current.os.tag != .windows) {
        // Windows treats this as an enum with type c_int
        cases.add("big negative enum init values when C ABI supports long long enums",
            \\enum EnumWithInits {
            \\    VAL01 = 0,
            \\    VAL02 = 1,
            \\    VAL03 = 2,
            \\    VAL04 = 3,
            \\    VAL05 = -1,
            \\    VAL06 = -2,
            \\    VAL07 = -3,
            \\    VAL08 = -4,
            \\    VAL09 = VAL02 + VAL08,
            \\    VAL10 = -1000012000,
            \\    VAL11 = -1000161000,
            \\    VAL12 = -1000174001,
            \\    VAL13 = VAL09,
            \\    VAL14 = VAL10,
            \\    VAL15 = VAL11,
            \\    VAL16 = VAL13,
            \\    VAL17 = (VAL16 - VAL10 + 1),
            \\    VAL18 = 0x1000000000000000L,
            \\    VAL19 = VAL18 + VAL18 + VAL18 - 1,
            \\    VAL20 = VAL19 + VAL19,
            \\    VAL21 = VAL20 + 0xFFFFFFFFFFFFFFFF,
            \\    VAL22 = 0xFFFFFFFFFFFFFFFF + 1,
            \\    VAL23 = 0xFFFFFFFFFFFFFFFF,
            \\};
        , &[_][]const u8{
            \\pub const VAL01: c_int = 0;
            \\pub const VAL02: c_int = 1;
            \\pub const VAL03: c_int = 2;
            \\pub const VAL04: c_int = 3;
            \\pub const VAL05: c_int = -1;
            \\pub const VAL06: c_int = -2;
            \\pub const VAL07: c_int = -3;
            \\pub const VAL08: c_int = -4;
            \\pub const VAL09: c_int = -3;
            \\pub const VAL10: c_int = -1000012000;
            \\pub const VAL11: c_int = -1000161000;
            \\pub const VAL12: c_int = -1000174001;
            \\pub const VAL13: c_int = -3;
            \\pub const VAL14: c_int = -1000012000;
            \\pub const VAL15: c_int = -1000161000;
            \\pub const VAL16: c_int = -3;
            \\pub const VAL17: c_int = 1000011998;
            \\pub const VAL18: c_longlong = 1152921504606846976;
            \\pub const VAL19: c_longlong = 3458764513820540927;
            \\pub const VAL20: c_longlong = 6917529027641081854;
            \\pub const VAL21: c_longlong = 6917529027641081853;
            \\pub const VAL22: c_int = 0;
            \\pub const VAL23: c_longlong = -1;
            \\pub const enum_EnumWithInits = c_longlong;
        });
    }

    cases.add("predefined expressions",
        \\void foo(void) {
        \\    __func__;
        \\    __FUNCTION__;
        \\    __PRETTY_FUNCTION__;
        \\}
    , &[_][]const u8{
        \\pub export fn foo() void {
        \\    _ = "foo";
        \\    _ = "foo";
        \\    _ = "void foo(void)";
        \\}
    });

    cases.add("constant size array",
        \\void func(int array[20]);
    , &[_][]const u8{
        \\pub extern fn func(array: [*c]c_int) void;
    });

    cases.add("__cdecl doesn't mess up function pointers",
        \\void foo(void (__cdecl *fn_ptr)(void));
    , &[_][]const u8{
        \\pub extern fn foo(fn_ptr: ?fn () callconv(.C) void) void;
    });

    cases.add("void cast",
        \\void foo() {
        \\    int a;
        \\    (void) a;
        \\}
    , &[_][]const u8{
        \\pub export fn foo() void {
        \\    var a: c_int = undefined;
        \\    _ = a;
        \\}
    });

    cases.add("implicit cast to void *",
        \\void *foo() {
        \\    unsigned short *x;
        \\    return x;
        \\}
    , &[_][]const u8{
        \\pub export fn foo() ?*c_void {
        \\    var x: [*c]c_ushort = undefined;
        \\    return @ptrCast(?*c_void, x);
        \\}
    });

    cases.add("null pointer implicit cast",
        \\int* foo(void) {
        \\    return 0;
        \\}
    , &[_][]const u8{
        \\pub export fn foo() [*c]c_int {
        \\    return null;
        \\}
    });

    cases.add("simple union",
        \\union Foo {
        \\    int x;
        \\    double y;
        \\};
    , &[_][]const u8{
        \\pub const union_Foo = extern union {
        \\    x: c_int,
        \\    y: f64,
        \\};
        ,
        \\pub const Foo = union_Foo;
    });

    cases.add("string literal",
        \\const char *foo(void) {
        \\    return "bar";
        \\}
    , &[_][]const u8{
        \\pub export fn foo() [*c]const u8 {
        \\    return "bar";
        \\}
    });

    cases.add("return void",
        \\void foo(void) {
        \\    return;
        \\}
    , &[_][]const u8{
        \\pub export fn foo() void {
        \\    return;
        \\}
    });

    cases.add("for loop",
        \\void foo(void) {
        \\    for (int i = 0; i; i++) { }
        \\}
    , &[_][]const u8{
        \\pub export fn foo() void {
        \\    {
        \\        var i: c_int = 0;
        \\        while (i != 0) : (i += 1) {}
        \\    }
        \\}
    });

    cases.add("empty for loop",
        \\void foo(void) {
        \\    for (;;) { }
        \\}
    , &[_][]const u8{
        \\pub export fn foo() void {
        \\    while (true) {}
        \\}
    });

    cases.add("for loop with simple init expression",
        \\void foo(void) {
        \\    int i;
        \\    for (i = 3; i; i--) { }
        \\}
    , &[_][]const u8{
        \\pub export fn foo() void {
        \\    var i: c_int = undefined;
        \\    {
        \\        i = 3;
        \\        while (i != 0) : (i -= 1) {}
        \\    }
        \\}
    });

    cases.add("break statement",
        \\void foo(void) {
        \\    for (;;) {
        \\        break;
        \\    }
        \\}
    , &[_][]const u8{
        \\pub export fn foo() void {
        \\    while (true) {
        \\        break;
        \\    }
        \\}
    });

    cases.add("continue statement",
        \\void foo(void) {
        \\    for (;;) {
        \\        continue;
        \\    }
        \\}
    , &[_][]const u8{
        \\pub export fn foo() void {
        \\    while (true) {
        \\        continue;
        \\    }
        \\}
    });

    cases.add("pointer casting",
        \\float *ptrcast() {
        \\    int *a;
        \\    return (float *)a;
        \\}
    , &[_][]const u8{
        \\pub export fn ptrcast() [*c]f32 {
        \\    var a: [*c]c_int = undefined;
        \\    return @ptrCast([*c]f32, @alignCast(@import("std").meta.alignment(f32), a));
        \\}
    });

    cases.add("pointer conversion with different alignment",
        \\void test_ptr_cast() {
        \\    void *p;
        \\    {
        \\        char *to_char = (char *)p;
        \\        short *to_short = (short *)p;
        \\        int *to_int = (int *)p;
        \\        long long *to_longlong = (long long *)p;
        \\    }
        \\    {
        \\        char *to_char = p;
        \\        short *to_short = p;
        \\        int *to_int = p;
        \\        long long *to_longlong = p;
        \\    }
        \\}
    , &[_][]const u8{
        \\pub export fn test_ptr_cast() void {
        \\    var p: ?*c_void = undefined;
        \\    {
        \\        var to_char: [*c]u8 = @ptrCast([*c]u8, @alignCast(@import("std").meta.alignment(u8), p));
        \\        _ = to_char;
        \\        var to_short: [*c]c_short = @ptrCast([*c]c_short, @alignCast(@import("std").meta.alignment(c_short), p));
        \\        _ = to_short;
        \\        var to_int: [*c]c_int = @ptrCast([*c]c_int, @alignCast(@import("std").meta.alignment(c_int), p));
        \\        _ = to_int;
        \\        var to_longlong: [*c]c_longlong = @ptrCast([*c]c_longlong, @alignCast(@import("std").meta.alignment(c_longlong), p));
        \\        _ = to_longlong;
        \\    }
        \\    {
        \\        var to_char: [*c]u8 = @ptrCast([*c]u8, @alignCast(@import("std").meta.alignment(u8), p));
        \\        _ = to_char;
        \\        var to_short: [*c]c_short = @ptrCast([*c]c_short, @alignCast(@import("std").meta.alignment(c_short), p));
        \\        _ = to_short;
        \\        var to_int: [*c]c_int = @ptrCast([*c]c_int, @alignCast(@import("std").meta.alignment(c_int), p));
        \\        _ = to_int;
        \\        var to_longlong: [*c]c_longlong = @ptrCast([*c]c_longlong, @alignCast(@import("std").meta.alignment(c_longlong), p));
        \\        _ = to_longlong;
        \\    }
        \\}
    });

    cases.add("while on non-bool",
        \\int while_none_bool() {
        \\    int a;
        \\    float b;
        \\    void *c;
        \\    while (a) return 0;
        \\    while (b) return 1;
        \\    while (c) return 2;
        \\    return 3;
        \\}
    , &[_][]const u8{
        \\pub export fn while_none_bool() c_int {
        \\    var a: c_int = undefined;
        \\    var b: f32 = undefined;
        \\    var c: ?*c_void = undefined;
        \\    while (a != 0) return 0;
        \\    while (b != 0) return 1;
        \\    while (c != null) return 2;
        \\    return 3;
        \\}
    });

    cases.add("for on non-bool",
        \\int for_none_bool() {
        \\    int a;
        \\    float b;
        \\    void *c;
        \\    for (;a;) return 0;
        \\    for (;b;) return 1;
        \\    for (;c;) return 2;
        \\    return 3;
        \\}
    , &[_][]const u8{
        \\pub export fn for_none_bool() c_int {
        \\    var a: c_int = undefined;
        \\    var b: f32 = undefined;
        \\    var c: ?*c_void = undefined;
        \\    while (a != 0) return 0;
        \\    while (b != 0) return 1;
        \\    while (c != null) return 2;
        \\    return 3;
        \\}
    });

    cases.add("bitshift",
        \\int foo(void) {
        \\    return (1 << 2) >> 1;
        \\}
    , &[_][]const u8{
        \\pub export fn foo() c_int {
        \\    return (@as(c_int, 1) << @intCast(@import("std").math.Log2Int(c_int), 2)) >> @intCast(@import("std").math.Log2Int(c_int), 1);
        \\}
    });

    cases.add("sizeof",
        \\#include <stddef.h>
        \\size_t size_of(void) {
        \\        return sizeof(int);
        \\}
    , &[_][]const u8{
        \\pub export fn size_of() usize {
        \\    return @sizeOf(c_int);
        \\}
    });

    cases.add("normal deref",
        \\void foo() {
        \\    int *x;
        \\    *x = 1;
        \\}
    , &[_][]const u8{
        \\pub export fn foo() void {
        \\    var x: [*c]c_int = undefined;
        \\    x.* = 1;
        \\}
    });

    cases.add("address of operator",
        \\int foo(void) {
        \\    int x = 1234;
        \\    int *ptr = &x;
        \\    return *ptr;
        \\}
    , &[_][]const u8{
        \\pub export fn foo() c_int {
        \\    var x: c_int = 1234;
        \\    var ptr: [*c]c_int = &x;
        \\    return ptr.*;
        \\}
    });

    cases.add("bin not",
        \\int foo() {
        \\    int x;
        \\    return ~x;
        \\}
    , &[_][]const u8{
        \\pub export fn foo() c_int {
        \\    var x: c_int = undefined;
        \\    return ~x;
        \\}
    });

    cases.add("bool not",
        \\int foo() {
        \\    int a;
        \\    float b;
        \\    void *c;
        \\    return !(a == 0);
        \\    return !a;
        \\    return !b;
        \\    return !c;
        \\}
    , &[_][]const u8{
        \\pub export fn foo() c_int {
        \\    var a: c_int = undefined;
        \\    var b: f32 = undefined;
        \\    var c: ?*c_void = undefined;
        \\    return @boolToInt(!(a == @as(c_int, 0)));
        \\    return @boolToInt(!(a != 0));
        \\    return @boolToInt(!(b != 0));
        \\    return @boolToInt(!(c != null));
        \\}
    });

    cases.add("__extension__ cast",
        \\int foo(void) {
        \\    return __extension__ 1;
        \\}
    , &[_][]const u8{
        \\pub export fn foo() c_int {
        \\    return 1;
        \\}
    });

    if (std.Target.current.os.tag != .windows) {
        // sysv_abi not currently supported on windows
        cases.add("Macro qualified functions",
            \\void __attribute__((sysv_abi)) foo(void);
        , &[_][]const u8{
            \\pub extern fn foo() void;
        });
    }

    cases.add("Forward-declared enum",
        \\extern enum enum_ty my_enum;
        \\enum enum_ty { FOO };
    , &[_][]const u8{
        \\pub const FOO: c_int = 0;
        \\pub const enum_enum_ty = c_int;
        \\pub extern var my_enum: enum_enum_ty;
    });

    cases.add("Parameterless function pointers",
        \\typedef void (*fn0)();
        \\typedef void (*fn1)(char);
    , &[_][]const u8{
        \\pub const fn0 = ?fn (...) callconv(.C) void;
        \\pub const fn1 = ?fn (u8) callconv(.C) void;
    });

    cases.addWithTarget("Calling convention", .{
        .cpu_arch = .i386,
        .os_tag = .linux,
        .abi = .none,
    },
        \\void __attribute__((fastcall)) foo1(float *a);
        \\void __attribute__((stdcall)) foo2(float *a);
        \\void __attribute__((vectorcall)) foo3(float *a);
        \\void __attribute__((cdecl)) foo4(float *a);
        \\void __attribute__((thiscall)) foo5(float *a);
    , &[_][]const u8{
        \\pub extern fn foo1(a: [*c]f32) callconv(.Fastcall) void;
        \\pub extern fn foo2(a: [*c]f32) callconv(.Stdcall) void;
        \\pub extern fn foo3(a: [*c]f32) callconv(.Vectorcall) void;
        \\pub extern fn foo4(a: [*c]f32) void;
        \\pub extern fn foo5(a: [*c]f32) callconv(.Thiscall) void;
    });

    cases.addWithTarget("Calling convention", CrossTarget.parse(.{
        .arch_os_abi = "arm-linux-none",
        .cpu_features = "generic+v8_5a",
    }) catch unreachable,
        \\void __attribute__((pcs("aapcs"))) foo1(float *a);
        \\void __attribute__((pcs("aapcs-vfp"))) foo2(float *a);
    , &[_][]const u8{
        \\pub extern fn foo1(a: [*c]f32) callconv(.AAPCS) void;
        \\pub extern fn foo2(a: [*c]f32) callconv(.AAPCSVFP) void;
    });

    cases.addWithTarget("Calling convention", CrossTarget.parse(.{
        .arch_os_abi = "aarch64-linux-none",
        .cpu_features = "generic+v8_5a",
    }) catch unreachable,
        \\void __attribute__((aarch64_vector_pcs)) foo1(float *a);
    , &[_][]const u8{
        \\pub extern fn foo1(a: [*c]f32) callconv(.Vectorcall) void;
    });

    cases.add("Parameterless function prototypes",
        \\void a() {}
        \\void b(void) {}
        \\void c();
        \\void d(void);
        \\static void e() {}
        \\static void f(void) {}
        \\static void g();
        \\static void h(void);
    , &[_][]const u8{
        \\pub export fn a() void {}
        \\pub export fn b() void {}
        \\pub extern fn c(...) void;
        \\pub extern fn d() void;
        \\pub fn e() callconv(.C) void {}
        \\pub fn f() callconv(.C) void {}
        \\pub extern fn g() void;
        \\pub extern fn h() void;
    });

    cases.add("variable declarations",
        \\extern char arr0[] = "hello";
        \\static char arr1[] = "hello";
        \\char arr2[] = "hello";
    , &[_][]const u8{
        \\pub export var arr0: [5:0]u8 = "hello".*;
        \\pub var arr1: [5:0]u8 = "hello".*;
        \\pub export var arr2: [5:0]u8 = "hello".*;
    });

    cases.add("array initializer expr",
        \\static void foo(void){
        \\    char arr[10] ={1};
        \\    char *arr1[10] ={0};
        \\}
    , &[_][]const u8{
        \\pub fn foo() callconv(.C) void {
        \\    var arr: [10]u8 = [1]u8{
        \\        1,
        \\    } ++ [1]u8{0} ** 9;
        \\    _ = arr;
        \\    var arr1: [10][*c]u8 = [1][*c]u8{
        \\        null,
        \\    } ++ [1][*c]u8{null} ** 9;
        \\    _ = arr1;
        \\}
    });

    cases.add("enums",
        \\typedef enum {
        \\    a,
        \\    b,
        \\    c,
        \\} d;
        \\enum {
        \\    e,
        \\    f = 4,
        \\    g,
        \\} h = e;
        \\struct Baz {
        \\    enum {
        \\        i,
        \\        j,
        \\        k,
        \\    } l;
        \\    d m;
        \\};
        \\enum i {
        \\    n,
        \\    o,
        \\    p,
        \\};
    , &[_][]const u8{
        \\pub const a: c_int = 0;
        \\pub const b: c_int = 1;
        \\pub const c: c_int = 2;
        \\pub const d =
        ++ " " ++ default_enum_type ++
            \\;
            \\pub const e: c_int = 0;
            \\pub const f: c_int = 4;
            \\pub const g: c_int = 5;
            \\const enum_unnamed_1 =
        ++ " " ++ default_enum_type ++
            \\;
            \\pub export var h: enum_unnamed_1 = @bitCast(c_uint, e);
            \\pub const i: c_int = 0;
            \\pub const j: c_int = 1;
            \\pub const k: c_int = 2;
            \\const enum_unnamed_2 =
        ++ " " ++ default_enum_type ++
            \\;
            \\pub const struct_Baz = extern struct {
            \\    l: enum_unnamed_2,
            \\    m: d,
            \\};
            \\pub const n: c_int = 0;
            \\pub const o: c_int = 1;
            \\pub const p: c_int = 2;
            \\pub const enum_i =
        ++ " " ++ default_enum_type ++
            \\;
        ,
        "pub const Baz = struct_Baz;",
    });

    cases.add("#define a char literal",
        \\#define A_CHAR  'a'
    , &[_][]const u8{
        \\pub const A_CHAR = 'a';
    });

    cases.add("comment after integer literal",
        \\#define SDL_INIT_VIDEO 0x00000020  /**< SDL_INIT_VIDEO implies SDL_INIT_EVENTS */
    , &[_][]const u8{
        \\pub const SDL_INIT_VIDEO = @as(c_int, 0x00000020);
    });

    cases.add("u integer suffix after hex literal",
        \\#define SDL_INIT_VIDEO 0x00000020u  /**< SDL_INIT_VIDEO implies SDL_INIT_EVENTS */
    , &[_][]const u8{
        \\pub const SDL_INIT_VIDEO = @as(c_uint, 0x00000020);
    });

    cases.add("l integer suffix after hex literal",
        \\#define SDL_INIT_VIDEO 0x00000020l  /**< SDL_INIT_VIDEO implies SDL_INIT_EVENTS */
    , &[_][]const u8{
        \\pub const SDL_INIT_VIDEO = @as(c_long, 0x00000020);
    });

    cases.add("ul integer suffix after hex literal",
        \\#define SDL_INIT_VIDEO 0x00000020ul  /**< SDL_INIT_VIDEO implies SDL_INIT_EVENTS */
    , &[_][]const u8{
        \\pub const SDL_INIT_VIDEO = @as(c_ulong, 0x00000020);
    });

    cases.add("lu integer suffix after hex literal",
        \\#define SDL_INIT_VIDEO 0x00000020lu  /**< SDL_INIT_VIDEO implies SDL_INIT_EVENTS */
    , &[_][]const u8{
        \\pub const SDL_INIT_VIDEO = @as(c_ulong, 0x00000020);
    });

    cases.add("ll integer suffix after hex literal",
        \\#define SDL_INIT_VIDEO 0x00000020ll  /**< SDL_INIT_VIDEO implies SDL_INIT_EVENTS */
    , &[_][]const u8{
        \\pub const SDL_INIT_VIDEO = @as(c_longlong, 0x00000020);
    });

    cases.add("ull integer suffix after hex literal",
        \\#define SDL_INIT_VIDEO 0x00000020ull  /**< SDL_INIT_VIDEO implies SDL_INIT_EVENTS */
    , &[_][]const u8{
        \\pub const SDL_INIT_VIDEO = @as(c_ulonglong, 0x00000020);
    });

    cases.add("llu integer suffix after hex literal",
        \\#define SDL_INIT_VIDEO 0x00000020llu  /**< SDL_INIT_VIDEO implies SDL_INIT_EVENTS */
    , &[_][]const u8{
        \\pub const SDL_INIT_VIDEO = @as(c_ulonglong, 0x00000020);
    });

    cases.add("generate inline func for #define global extern fn",
        \\extern void (*fn_ptr)(void);
        \\#define foo fn_ptr
        \\
        \\extern char (*fn_ptr2)(int, float);
        \\#define bar fn_ptr2
    , &[_][]const u8{
        \\pub extern var fn_ptr: ?fn () callconv(.C) void;
        ,
        \\pub inline fn foo() void {
        \\    return fn_ptr.?();
        \\}
        ,
        \\pub extern var fn_ptr2: ?fn (c_int, f32) callconv(.C) u8;
        ,
        \\pub inline fn bar(arg_1: c_int, arg_2: f32) u8 {
        \\    return fn_ptr2.?(arg_1, arg_2);
        \\}
    });

    cases.add("macros with field targets",
        \\typedef unsigned int GLbitfield;
        \\typedef void (*PFNGLCLEARPROC) (GLbitfield mask);
        \\typedef void(*OpenGLProc)(void);
        \\union OpenGLProcs {
        \\    OpenGLProc ptr[1];
        \\    struct {
        \\        PFNGLCLEARPROC Clear;
        \\    } gl;
        \\};
        \\extern union OpenGLProcs glProcs;
        \\#define glClearUnion glProcs.gl.Clear
        \\#define glClearPFN PFNGLCLEARPROC
    , &[_][]const u8{
        \\pub const GLbitfield = c_uint;
        \\pub const PFNGLCLEARPROC = ?fn (GLbitfield) callconv(.C) void;
        \\pub const OpenGLProc = ?fn () callconv(.C) void;
        \\const struct_unnamed_1 = extern struct {
        \\    Clear: PFNGLCLEARPROC,
        \\};
        \\pub const union_OpenGLProcs = extern union {
        \\    ptr: [1]OpenGLProc,
        \\    gl: struct_unnamed_1,
        \\};
        \\pub extern var glProcs: union_OpenGLProcs;
        ,
        \\pub const glClearPFN = PFNGLCLEARPROC;
        ,
        \\pub inline fn glClearUnion(arg_2: GLbitfield) void {
        \\    return glProcs.gl.Clear.?(arg_2);
        \\}
        ,
        \\pub const OpenGLProcs = union_OpenGLProcs;
    });

    cases.add("macro pointer cast",
        \\typedef struct { int dummy; } NRF_GPIO_Type;
        \\#define NRF_GPIO ((NRF_GPIO_Type *) NRF_GPIO_BASE)
    , &[_][]const u8{
        \\pub const NRF_GPIO = @import("std").zig.c_translation.cast([*c]NRF_GPIO_Type, NRF_GPIO_BASE);
    });

    cases.add("basic macro function",
        \\extern int c;
        \\#define BASIC(c) (c*2)
        \\#define FOO(L,b) (L + b)
        \\#define BAR() (c*c)
    , &[_][]const u8{
        \\pub extern var c: c_int;
        ,
        \\pub inline fn BASIC(c_1: anytype) @TypeOf(c_1 * @as(c_int, 2)) {
        \\    return c_1 * @as(c_int, 2);
        \\}
        ,
        \\pub inline fn FOO(L: anytype, b: anytype) @TypeOf(L + b) {
        \\    return L + b;
        \\}
        ,
        \\pub inline fn BAR() @TypeOf(c * c) {
        \\    return c * c;
        \\}
    });

    cases.add("macro defines string literal with hex",
        \\#define FOO "aoeu\xab derp"
        \\#define FOO2 "aoeu\x0007a derp"
        \\#define FOO_CHAR '\xfF'
    , &[_][]const u8{
        \\pub const FOO = "aoeu\xab derp";
        ,
        \\pub const FOO2 = "aoeu\x7a derp";
        ,
        \\pub const FOO_CHAR = '\xff';
    });

    cases.add("macro add",
        \\#define PERIPH_BASE               (0x40000000UL) /*!< Base address of : AHB/APB Peripherals                                                   */
        \\#define D3_APB1PERIPH_BASE       (PERIPH_BASE + 0x18000000UL)
        \\#define RCC_BASE              (D3_AHB1PERIPH_BASE + 0x4400UL)
    , &[_][]const u8{
        \\pub const PERIPH_BASE = @as(c_ulong, 0x40000000);
        ,
        \\pub const D3_APB1PERIPH_BASE = PERIPH_BASE + @as(c_ulong, 0x18000000);
        ,
        \\pub const RCC_BASE = D3_AHB1PERIPH_BASE + @as(c_ulong, 0x4400);
    });

    cases.add("variable aliasing",
        \\static long a = 2;
        \\static long b = 2;
        \\static int c = 4;
        \\void foo(char c) {
        \\    int a;
        \\    char b = 123;
        \\    b = (char) a;
        \\    {
        \\        int d = 5;
        \\    }
        \\    unsigned d = 440;
        \\}
    , &[_][]const u8{
        \\pub var a: c_long = 2;
        \\pub var b: c_long = 2;
        \\pub var c: c_int = 4;
        \\pub export fn foo(arg_c_1: u8) void {
        \\    var c_1 = arg_c_1;
        \\    _ = c_1;
        \\    var a_2: c_int = undefined;
        \\    var b_3: u8 = 123;
        \\    b_3 = @bitCast(u8, @truncate(i8, a_2));
        \\    {
        \\        var d: c_int = 5;
        \\        _ = d;
        \\    }
        \\    var d: c_uint = @bitCast(c_uint, @as(c_int, 440));
        \\    _ = d;
        \\}
    });

    cases.add("comma operator",
        \\int foo() {
        \\    2, 4;
        \\    return 2, 4, 6;
        \\}
    , &[_][]const u8{
        \\pub export fn foo() c_int {
        \\    _ = blk: {
        \\        _ = @as(c_int, 2);
        \\        break :blk @as(c_int, 4);
        \\    };
        \\    return blk: {
        \\        _ = blk_1: {
        \\            _ = @as(c_int, 2);
        \\            break :blk_1 @as(c_int, 4);
        \\        };
        \\        break :blk @as(c_int, 6);
        \\    };
        \\}
    });

    cases.add("worst-case assign",
        \\void foo() {
        \\    int a;
        \\    int b;
        \\    a = b = 2;
        \\}
    , &[_][]const u8{
        \\pub export fn foo() void {
        \\    var a: c_int = undefined;
        \\    var b: c_int = undefined;
        \\    a = blk: {
        \\        const tmp = @as(c_int, 2);
        \\        b = tmp;
        \\        break :blk tmp;
        \\    };
        \\}
    });

    cases.add("while loops",
        \\int foo() {
        \\    int a = 5;
        \\    while (2)
        \\        a = 2;
        \\    while (4) {
        \\        int a = 4;
        \\        a = 9;
        \\        return 6, a;
        \\    }
        \\    do {
        \\        int a = 2;
        \\        a = 12;
        \\    } while (4);
        \\    do
        \\        a = 7;
        \\    while (4);
        \\}
    , &[_][]const u8{
        \\pub export fn foo() c_int {
        \\    var a: c_int = 5;
        \\    while (true) {
        \\        a = 2;
        \\    }
        \\    while (true) {
        \\        var a_1: c_int = 4;
        \\        a_1 = 9;
        \\        return blk: {
        \\            _ = @as(c_int, 6);
        \\            break :blk a_1;
        \\        };
        \\    }
        \\    while (true) {
        \\        var a_1: c_int = 2;
        \\        a_1 = 12;
        \\    }
        \\    while (true) {
        \\        a = 7;
        \\    }
        \\    return 0;
        \\}
    });

    cases.add("for loops",
        \\void foo() {
        \\    for (int i = 2, b = 4; i + 2; i = 2) {
        \\        int a = 2;
        \\        a = 6, 5, 7;
        \\    }
        \\    char i = 2;
        \\}
    , &[_][]const u8{
        \\pub export fn foo() void {
        \\    {
        \\        var i: c_int = 2;
        \\        var b: c_int = 4;
        \\        _ = b;
        \\        while ((i + @as(c_int, 2)) != 0) : (i = 2) {
        \\            var a: c_int = 2;
        \\            _ = blk: {
        \\                _ = blk_1: {
        \\                    a = 6;
        \\                    break :blk_1 @as(c_int, 5);
        \\                };
        \\                break :blk @as(c_int, 7);
        \\            };
        \\        }
        \\    }
        \\    var i: u8 = 2;
        \\    _ = i;
        \\}
    });

    cases.add("shadowing primitive types",
        \\unsigned anyerror = 2;
        \\#define noreturn _Noreturn
    , &[_][]const u8{
        \\pub export var anyerror_1: c_uint = 2;
        ,
        \\pub const noreturn_2 = @compileError("unable to translate C expr: unexpected token .Keyword_noreturn");
    });

    cases.add("floats",
        \\float a = 3.1415;
        \\double b = 3.1415;
        \\int c = 3.1415;
        \\double d = 3;
    , &[_][]const u8{
        \\pub export var a: f32 = @floatCast(f32, 3.1415);
        \\pub export var b: f64 = 3.1415;
        \\pub export var c: c_int = @floatToInt(c_int, 3.1415);
        \\pub export var d: f64 = 3;
    });

    cases.add("conditional operator",
        \\int bar(void) {
        \\    if (2 ? 5 : 5 ? 4 : 6) 2;
        \\    return  2 ? 5 : 5 ? 4 : 6;
        \\}
    , &[_][]const u8{
        \\pub export fn bar() c_int {
        \\    if ((if (true) @as(c_int, 5) else if (true) @as(c_int, 4) else @as(c_int, 6)) != 0) {
        \\        _ = @as(c_int, 2);
        \\    }
        \\    return if (true) @as(c_int, 5) else if (true) @as(c_int, 4) else @as(c_int, 6);
        \\}
    });

    cases.add("switch on int",
        \\void switch_fn(int i) {
        \\    int res = 0;
        \\    switch (i) {
        \\        case 0:
        \\            res = 1;
        \\        case 1 ... 3:
        \\            res = 2;
        \\        default:
        \\            res = 3 * i;
        \\            break;
        \\            break;
        \\        case 7: {
        \\           res = 7;
        \\           break;
        \\        }
        \\        case 4:
        \\		case 5:
        \\            res = 69;
        \\        {
        \\            res = 5;
        \\			  return;
        \\        }
        \\        case 6:
        \\            switch (res) {
        \\                case 9: break;
        \\            }
        \\            res = 1;
        \\			  return;
        \\    }
        \\}
    , &[_][]const u8{
        \\pub export fn switch_fn(arg_i: c_int) void {
        \\    var i = arg_i;
        \\    var res: c_int = 0;
        \\    while (true) {
        \\        switch (i) {
        \\            @as(c_int, 0) => {
        \\                res = 1;
        \\                res = 2;
        \\                res = @as(c_int, 3) * i;
        \\                break;
        \\            },
        \\            @as(c_int, 1)...@as(c_int, 3) => {
        \\                res = 2;
        \\                res = @as(c_int, 3) * i;
        \\                break;
        \\            },
        \\            else => {
        \\                res = @as(c_int, 3) * i;
        \\                break;
        \\            },
        \\            @as(c_int, 7) => {
        \\                {
        \\                    res = 7;
        \\                    break;
        \\                }
        \\            },
        \\            @as(c_int, 4), @as(c_int, 5) => {
        \\                res = 69;
        \\                {
        \\                    res = 5;
        \\                    return;
        \\                }
        \\            },
        \\            @as(c_int, 6) => {
        \\                while (true) {
        \\                    switch (res) {
        \\                        @as(c_int, 9) => break,
        \\                        else => {},
        \\                    }
        \\                    break;
        \\                }
        \\                res = 1;
        \\                return;
        \\            },
        \\        }
        \\        break;
        \\    }
        \\}
    });

    if (std.Target.current.os.tag != .windows) {
        // When clang uses the <arch>-windows-none triple it behaves as MSVC and
        // interprets the inner `struct Bar` as an anonymous structure
        cases.add("type referenced struct",
            \\struct Foo {
            \\    struct Bar{
            \\        int b;
            \\    };
            \\    struct Bar c;
            \\};
        , &[_][]const u8{
            \\pub const struct_Bar = extern struct {
            \\    b: c_int,
            \\};
            \\pub const struct_Foo = extern struct {
            \\    c: struct_Bar,
            \\};
        });
    }

    cases.add("undefined array global",
        \\int array[100] = {};
    , &[_][]const u8{
        \\pub export var array: [100]c_int = [1]c_int{0} ** 100;
    });

    cases.add("restrict -> noalias",
        \\void foo(void *restrict bar, void *restrict);
    , &[_][]const u8{
        \\pub extern fn foo(noalias bar: ?*c_void, noalias ?*c_void) void;
    });

    cases.add("assign",
        \\void max(int a) {
        \\    int tmp;
        \\    tmp = a;
        \\    a = tmp;
        \\}
    , &[_][]const u8{
        \\pub export fn max(arg_a: c_int) void {
        \\    var a = arg_a;
        \\    var tmp: c_int = undefined;
        \\    tmp = a;
        \\    a = tmp;
        \\}
    });

    cases.add("chaining assign",
        \\void max(int a) {
        \\    int b, c;
        \\    c = b = a;
        \\}
    , &[_][]const u8{
        \\pub export fn max(arg_a: c_int) void {
        \\    var a = arg_a;
        \\    var b: c_int = undefined;
        \\    var c: c_int = undefined;
        \\    c = blk: {
        \\        const tmp = a;
        \\        b = tmp;
        \\        break :blk tmp;
        \\    };
        \\}
    });

    cases.add("anonymous enum",
        \\enum {
        \\    One,
        \\    Two,
        \\};
    , &[_][]const u8{
        \\pub const One: c_int = 0;
        \\pub const Two: c_int = 1;
        \\const enum_unnamed_1 =
        ++ " " ++ default_enum_type ++
            \\;
    });

    cases.add("c style cast",
        \\int float_to_int(float a) {
        \\    return (int)a;
        \\}
    , &[_][]const u8{
        \\pub export fn float_to_int(arg_a: f32) c_int {
        \\    var a = arg_a;
        \\    return @floatToInt(c_int, a);
        \\}
    });

    cases.add("escape sequences",
        \\const char *escapes() {
        \\char a = '\'',
        \\    b = '\\',
        \\    c = '\a',
        \\    d = '\b',
        \\    e = '\f',
        \\    f = '\n',
        \\    g = '\r',
        \\    h = '\t',
        \\    i = '\v',
        \\    j = '\0',
        \\    k = '\"';
        \\    return "\'\\\a\b\f\n\r\t\v\0\"";
        \\}
        \\
    , &[_][]const u8{
        \\pub export fn escapes() [*c]const u8 {
        \\    var a: u8 = '\'';
        \\    _ = a;
        \\    var b: u8 = '\\';
        \\    _ = b;
        \\    var c: u8 = '\x07';
        \\    _ = c;
        \\    var d: u8 = '\x08';
        \\    _ = d;
        \\    var e: u8 = '\x0c';
        \\    _ = e;
        \\    var f: u8 = '\n';
        \\    _ = f;
        \\    var g: u8 = '\r';
        \\    _ = g;
        \\    var h: u8 = '\t';
        \\    _ = h;
        \\    var i: u8 = '\x0b';
        \\    _ = i;
        \\    var j: u8 = '\x00';
        \\    _ = j;
        \\    var k: u8 = '"';
        \\    _ = k;
        \\    return "'\\\x07\x08\x0c\n\r\t\x0b\x00\"";
        \\}
    });

    cases.add("do loop",
        \\void foo(void) {
        \\    int a = 2;
        \\    do {
        \\        a = a - 1;
        \\    } while (a);
        \\
        \\    int b = 2;
        \\    do
        \\        b = b -1;
        \\    while (b);
        \\}
    , &[_][]const u8{
        \\pub export fn foo() void {
        \\    var a: c_int = 2;
        \\    while (true) {
        \\        a = a - @as(c_int, 1);
        \\        if (!(a != 0)) break;
        \\    }
        \\    var b: c_int = 2;
        \\    while (true) {
        \\        b = b - @as(c_int, 1);
        \\        if (!(b != 0)) break;
        \\    }
        \\}
    });

    cases.add("logical and, logical or, on non-bool values, extra parens",
        \\enum Foo {
        \\    FooA,
        \\    FooB,
        \\    FooC,
        \\};
        \\typedef int SomeTypedef;
        \\int and_or_non_bool(int a, float b, void *c) {
        \\    enum Foo d = FooA;
        \\    int e = (a && b);
        \\    int f = (b && c);
        \\    int g = (a && c);
        \\    int h = (a || b);
        \\    int i = (b || c);
        \\    int j = (a || c);
        \\    int k = (a || (int)d);
        \\    int l = ((int)d && b);
        \\    int m = (c || (unsigned int)d);
        \\    SomeTypedef td = 44;
        \\    int o = (td || b);
        \\    int p = (c && td);
        \\    return ((((((((((e + f) + g) + h) + i) + j) + k) + l) + m) + o) + p);
        \\}
    , &[_][]const u8{
        \\pub const FooA: c_int = 0;
        \\pub const FooB: c_int = 1;
        \\pub const FooC: c_int = 2;
        \\pub const enum_Foo =
        ++ " " ++ default_enum_type ++
            \\;
            \\pub const SomeTypedef = c_int;
            \\pub export fn and_or_non_bool(arg_a: c_int, arg_b: f32, arg_c: ?*c_void) c_int {
            \\    var a = arg_a;
            \\    var b = arg_b;
            \\    var c = arg_c;
            \\    var d: enum_Foo = @bitCast(c_uint, FooA);
            \\    var e: c_int = @boolToInt((a != 0) and (b != 0));
            \\    var f: c_int = @boolToInt((b != 0) and (c != null));
            \\    var g: c_int = @boolToInt((a != 0) and (c != null));
            \\    var h: c_int = @boolToInt((a != 0) or (b != 0));
            \\    var i: c_int = @boolToInt((b != 0) or (c != null));
            \\    var j: c_int = @boolToInt((a != 0) or (c != null));
            \\    var k: c_int = @boolToInt((a != 0) or (@bitCast(c_int, d) != 0));
            \\    var l: c_int = @boolToInt((@bitCast(c_int, d) != 0) and (b != 0));
            \\    var m: c_int = @boolToInt((c != null) or (d != 0));
            \\    var td: SomeTypedef = 44;
            \\    var o: c_int = @boolToInt((td != 0) or (b != 0));
            \\    var p: c_int = @boolToInt((c != null) and (td != 0));
            \\    return (((((((((e + f) + g) + h) + i) + j) + k) + l) + m) + o) + p;
            \\}
        ,
        \\pub const Foo = enum_Foo;
    });

    cases.add("qualified struct and enum",
        \\struct Foo {
        \\    int x;
        \\    int y;
        \\};
        \\enum Bar {
        \\    BarA,
        \\    BarB,
        \\};
        \\void func(struct Foo *a, enum Bar **b);
    , &[_][]const u8{
        \\pub const struct_Foo = extern struct {
        \\    x: c_int,
        \\    y: c_int,
        \\};
        \\pub const BarA: c_int = 0;
        \\pub const BarB: c_int = 1;
        \\pub const enum_Bar =
        ++ " " ++ default_enum_type ++
            \\;
            \\pub extern fn func(a: [*c]struct_Foo, b: [*c][*c]enum_Bar) void;
        ,
        \\pub const Foo = struct_Foo;
        \\pub const Bar = enum_Bar;
    });

    cases.add("bitwise binary operators, simpler parens",
        \\int max(int a, int b) {
        \\    return (a & b) ^ (a | b);
        \\}
    , &[_][]const u8{
        \\pub export fn max(arg_a: c_int, arg_b: c_int) c_int {
        \\    var a = arg_a;
        \\    var b = arg_b;
        \\    return (a & b) ^ (a | b);
        \\}
    });

    cases.add("comparison operators (no if)", // TODO Come up with less contrived tests? Make sure to cover all these comparisons.
        \\int test_comparisons(int a, int b) {
        \\    int c = (a < b);
        \\    int d = (a > b);
        \\    int e = (a <= b);
        \\    int f = (a >= b);
        \\    int g = (c < d);
        \\    int h = (e < f);
        \\    int i = (g < h);
        \\    return i;
        \\}
    , &[_][]const u8{
        \\pub export fn test_comparisons(arg_a: c_int, arg_b: c_int) c_int {
        \\    var a = arg_a;
        \\    var b = arg_b;
        \\    var c: c_int = @boolToInt(a < b);
        \\    var d: c_int = @boolToInt(a > b);
        \\    var e: c_int = @boolToInt(a <= b);
        \\    var f: c_int = @boolToInt(a >= b);
        \\    var g: c_int = @boolToInt(c < d);
        \\    var h: c_int = @boolToInt(e < f);
        \\    var i: c_int = @boolToInt(g < h);
        \\    return i;
        \\}
    });

    cases.add("==, !=",
        \\int max(int a, int b) {
        \\    if (a == b)
        \\        return a;
        \\    if (a != b)
        \\        return b;
        \\    return a;
        \\}
    , &[_][]const u8{
        \\pub export fn max(arg_a: c_int, arg_b: c_int) c_int {
        \\    var a = arg_a;
        \\    var b = arg_b;
        \\    if (a == b) return a;
        \\    if (a != b) return b;
        \\    return a;
        \\}
    });

    cases.add("typedeffed bool expression",
        \\typedef char* yes;
        \\void foo(void) {
        \\    yes a;
        \\    if (a) 2;
        \\}
    , &[_][]const u8{
        \\pub const yes = [*c]u8;
        \\pub export fn foo() void {
        \\    var a: yes = undefined;
        \\    if (a != null) {
        \\        _ = @as(c_int, 2);
        \\    }
        \\}
    });

    cases.add("statement expression",
        \\int foo(void) {
        \\    return ({
        \\        int a = 1;
        \\        a;
        \\        a;
        \\    });
        \\}
    , &[_][]const u8{
        \\pub export fn foo() c_int {
        \\    return blk: {
        \\        var a: c_int = 1;
        \\        _ = a;
        \\        break :blk a;
        \\    };
        \\}
    });

    cases.add("field access expression",
        \\#define ARROW a->b
        \\#define DOT a.b
        \\extern struct Foo {
        \\    int b;
        \\}a;
        \\float b = 2.0f;
        \\void foo(void) {
        \\    struct Foo *c;
        \\    a.b;
        \\    c->b;
        \\}
    , &[_][]const u8{
        \\pub const struct_Foo = extern struct {
        \\    b: c_int,
        \\};
        \\pub extern var a: struct_Foo;
        \\pub export var b: f32 = 2.0;
        \\pub export fn foo() void {
        \\    var c: [*c]struct_Foo = undefined;
        \\    _ = a.b;
        \\    _ = c.*.b;
        \\}
        ,
        \\pub const DOT = a.b;
        ,
        \\pub const ARROW = a.*.b;
    });

    cases.add("array access",
        \\#define ACCESS array[2]
        \\int array[100] = {};
        \\int foo(int index) {
        \\    return array[index];
        \\}
    , &[_][]const u8{
        \\pub export var array: [100]c_int = [1]c_int{0} ** 100;
        \\pub export fn foo(arg_index: c_int) c_int {
        \\    var index = arg_index;
        \\    return array[@intCast(c_uint, index)];
        \\}
        ,
        \\pub const ACCESS = array[@as(c_int, 2)];
    });

    cases.add("cast signed array index to unsigned",
        \\void foo() {
        \\  int a[10], i = 0;
        \\  a[i] = 0;
        \\}
    , &[_][]const u8{
        \\pub export fn foo() void {
        \\    var a: [10]c_int = undefined;
        \\    var i: c_int = 0;
        \\    a[@intCast(c_uint, i)] = 0;
        \\}
    });

    cases.add("long long array index cast to usize",
        \\void foo() {
        \\  long long a[10], i = 0;
        \\  a[i] = 0;
        \\}
    , &[_][]const u8{
        \\pub export fn foo() void {
        \\    var a: [10]c_longlong = undefined;
        \\    var i: c_longlong = 0;
        \\    a[@intCast(usize, i)] = 0;
        \\}
    });

    cases.add("unsigned array index skips cast",
        \\void foo() {
        \\  unsigned int a[10], i = 0;
        \\  a[i] = 0;
        \\}
    , &[_][]const u8{
        \\pub export fn foo() void {
        \\    var a: [10]c_uint = undefined;
        \\    var i: c_uint = 0;
        \\    a[i] = 0;
        \\}
    });

    cases.add("macro call",
        \\#define CALL(arg) bar(arg)
    , &[_][]const u8{
        \\pub inline fn CALL(arg: anytype) @TypeOf(bar(arg)) {
        \\    return bar(arg);
        \\}
    });

    cases.add("macro call with no args",
        \\#define CALL(arg) bar()
    , &[_][]const u8{
        \\pub inline fn CALL(arg: anytype) @TypeOf(bar()) {
        \\    _ = arg;
        \\    return bar();
        \\}
    });

    cases.add("logical and, logical or",
        \\int max(int a, int b) {
        \\    if (a < b || a == b)
        \\        return b;
        \\    if (a >= b && a == b)
        \\        return a;
        \\    return a;
        \\}
    , &[_][]const u8{
        \\pub export fn max(arg_a: c_int, arg_b: c_int) c_int {
        \\    var a = arg_a;
        \\    var b = arg_b;
        \\    if ((a < b) or (a == b)) return b;
        \\    if ((a >= b) and (a == b)) return a;
        \\    return a;
        \\}
    });

    cases.add("simple if statement",
        \\int max(int a, int b) {
        \\    if (a < b)
        \\        return b;
        \\
        \\    if (a < b)
        \\        return b;
        \\    else
        \\        return a;
        \\
        \\    if (a < b) ; else ;
        \\}
    , &[_][]const u8{
        \\pub export fn max(arg_a: c_int, arg_b: c_int) c_int {
        \\    var a = arg_a;
        \\    var b = arg_b;
        \\    if (a < b) return b;
        \\    if (a < b) return b else return a;
        \\    if (a < b) {} else {}
        \\    return 0;
        \\}
    });

    cases.add("if statements",
        \\void foo() {
        \\    if (2) {
        \\        int a = 2;
        \\    }
        \\    if (2, 5) {
        \\        int a = 2;
        \\    }
        \\}
    , &[_][]const u8{
        \\pub export fn foo() void {
        \\    if (true) {
        \\        var a: c_int = 2;
        \\        _ = a;
        \\    }
        \\    if ((blk: {
        \\        _ = @as(c_int, 2);
        \\        break :blk @as(c_int, 5);
        \\    }) != 0) {
        \\        var a: c_int = 2;
        \\        _ = a;
        \\    }
        \\}
    });

    cases.add("if on non-bool",
        \\enum SomeEnum { A, B, C };
        \\int if_none_bool(int a, float b, void *c, enum SomeEnum d) {
        \\    if (a) return 0;
        \\    if (b) return 1;
        \\    if (c) return 2;
        \\    if (d) return 3;
        \\    return 4;
        \\}
    , &[_][]const u8{
        \\pub const A: c_int = 0;
        \\pub const B: c_int = 1;
        \\pub const C: c_int = 2;
        \\pub const enum_SomeEnum =
        ++ " " ++ default_enum_type ++
            \\;
            \\pub export fn if_none_bool(arg_a: c_int, arg_b: f32, arg_c: ?*c_void, arg_d: enum_SomeEnum) c_int {
            \\    var a = arg_a;
            \\    var b = arg_b;
            \\    var c = arg_c;
            \\    var d = arg_d;
            \\    if (a != 0) return 0;
            \\    if (b != 0) return 1;
            \\    if (c != null) return 2;
            \\    if (d != 0) return 3;
            \\    return 4;
            \\}
    });

    cases.add("simple data types",
        \\#include <stdint.h>
        \\int foo(char a, unsigned char b, signed char c);
        \\int foo(char a, unsigned char b, signed char c); // test a duplicate prototype
        \\void bar(uint8_t a, uint16_t b, uint32_t c, uint64_t d);
        \\void baz(int8_t a, int16_t b, int32_t c, int64_t d);
    , &[_][]const u8{
        \\pub extern fn foo(a: u8, b: u8, c: i8) c_int;
        \\pub extern fn bar(a: u8, b: u16, c: u32, d: u64) void;
        \\pub extern fn baz(a: i8, b: i16, c: i32, d: i64) void;
    });

    cases.add("simple function",
        \\int abs(int a) {
        \\    return a < 0 ? -a : a;
        \\}
    , &[_][]const u8{
        \\pub export fn abs(arg_a: c_int) c_int {
        \\    var a = arg_a;
        \\    return if (a < @as(c_int, 0)) -a else a;
        \\}
    });

    cases.add("post increment",
        \\unsigned foo1(unsigned a) {
        \\    a++;
        \\    return a;
        \\}
        \\int foo2(int a) {
        \\    a++;
        \\    return a;
        \\}
        \\int *foo3(int *a) {
        \\    a++;
        \\    return a;
        \\}
    , &[_][]const u8{
        \\pub export fn foo1(arg_a: c_uint) c_uint {
        \\    var a = arg_a;
        \\    a +%= 1;
        \\    return a;
        \\}
        \\pub export fn foo2(arg_a: c_int) c_int {
        \\    var a = arg_a;
        \\    a += 1;
        \\    return a;
        \\}
        \\pub export fn foo3(arg_a: [*c]c_int) [*c]c_int {
        \\    var a = arg_a;
        \\    a += 1;
        \\    return a;
        \\}
    });

    cases.add("deref function pointer",
        \\void foo(void) {}
        \\int baz(void) { return 0; }
        \\void bar(void) {
        \\    void(*f)(void) = foo;
        \\    int(*b)(void) = baz;
        \\    f();
        \\    (*(f))();
        \\    foo();
        \\    b();
        \\    (*(b))();
        \\    baz();
        \\}
    , &[_][]const u8{
        \\pub export fn foo() void {}
        \\pub export fn baz() c_int {
        \\    return 0;
        \\}
        \\pub export fn bar() void {
        \\    var f: ?fn () callconv(.C) void = foo;
        \\    var b: ?fn () callconv(.C) c_int = baz;
        \\    f.?();
        \\    f.?();
        \\    foo();
        \\    _ = b.?();
        \\    _ = b.?();
        \\    _ = baz();
        \\}
    });

    cases.add("pre increment/decrement",
        \\void foo(void) {
        \\    int i = 0;
        \\    unsigned u = 0;
        \\    ++i;
        \\    --i;
        \\    ++u;
        \\    --u;
        \\    i = ++i;
        \\    i = --i;
        \\    u = ++u;
        \\    u = --u;
        \\}
    , &[_][]const u8{
        \\pub export fn foo() void {
        \\    var i: c_int = 0;
        \\    var u: c_uint = 0;
        \\    i += 1;
        \\    i -= 1;
        \\    u +%= 1;
        \\    u -%= 1;
        \\    i = blk: {
        \\        const ref = &i;
        \\        ref.* += 1;
        \\        break :blk ref.*;
        \\    };
        \\    i = blk: {
        \\        const ref = &i;
        \\        ref.* -= 1;
        \\        break :blk ref.*;
        \\    };
        \\    u = blk: {
        \\        const ref = &u;
        \\        ref.* +%= 1;
        \\        break :blk ref.*;
        \\    };
        \\    u = blk: {
        \\        const ref = &u;
        \\        ref.* -%= 1;
        \\        break :blk ref.*;
        \\    };
        \\}
    });

    cases.add("shift right assign",
        \\int log2(unsigned a) {
        \\    int i = 0;
        \\    while (a > 0) {
        \\        a >>= 1;
        \\    }
        \\    return i;
        \\}
    , &[_][]const u8{
        \\pub export fn log2(arg_a: c_uint) c_int {
        \\    var a = arg_a;
        \\    var i: c_int = 0;
        \\    while (a > @bitCast(c_uint, @as(c_int, 0))) {
        \\        a >>= @intCast(@import("std").math.Log2Int(c_int), @as(c_int, 1));
        \\    }
        \\    return i;
        \\}
    });

    cases.add("shift right assign with a fixed size type",
        \\#include <stdint.h>
        \\int log2(uint32_t a) {
        \\    int i = 0;
        \\    while (a > 0) {
        \\        a >>= 1;
        \\    }
        \\    return i;
        \\}
    , &[_][]const u8{
        \\pub export fn log2(arg_a: u32) c_int {
        \\    var a = arg_a;
        \\    var i: c_int = 0;
        \\    while (a > @bitCast(c_uint, @as(c_int, 0))) {
        \\        a >>= @intCast(@import("std").math.Log2Int(c_int), @as(c_int, 1));
        \\    }
        \\    return i;
        \\}
    });

    cases.add("compound assignment operators",
        \\void foo(void) {
        \\    int a = 0;
        \\    unsigned b = 0;
        \\    a += (a += 1);
        \\    a -= (a -= 1);
        \\    a *= (a *= 1);
        \\    a &= (a &= 1);
        \\    a |= (a |= 1);
        \\    a ^= (a ^= 1);
        \\    a >>= (a >>= 1);
        \\    a <<= (a <<= 1);
        \\    a /= (a /= 1);
        \\    a %= (a %= 1);
        \\    b /= (b /= 1);
        \\    b %= (b %= 1);
        \\}
    , &[_][]const u8{
        \\pub export fn foo() void {
        \\    var a: c_int = 0;
        \\    var b: c_uint = 0;
        \\    a += blk: {
        \\        const ref = &a;
        \\        ref.* += @as(c_int, 1);
        \\        break :blk ref.*;
        \\    };
        \\    a -= blk: {
        \\        const ref = &a;
        \\        ref.* -= @as(c_int, 1);
        \\        break :blk ref.*;
        \\    };
        \\    a *= blk: {
        \\        const ref = &a;
        \\        ref.* *= @as(c_int, 1);
        \\        break :blk ref.*;
        \\    };
        \\    a &= blk: {
        \\        const ref = &a;
        \\        ref.* &= @as(c_int, 1);
        \\        break :blk ref.*;
        \\    };
        \\    a |= blk: {
        \\        const ref = &a;
        \\        ref.* |= @as(c_int, 1);
        \\        break :blk ref.*;
        \\    };
        \\    a ^= blk: {
        \\        const ref = &a;
        \\        ref.* ^= @as(c_int, 1);
        \\        break :blk ref.*;
        \\    };
        \\    a >>= @intCast(@import("std").math.Log2Int(c_int), blk: {
        \\        const ref = &a;
        \\        ref.* >>= @intCast(@import("std").math.Log2Int(c_int), @as(c_int, 1));
        \\        break :blk ref.*;
        \\    });
        \\    a <<= @intCast(@import("std").math.Log2Int(c_int), blk: {
        \\        const ref = &a;
        \\        ref.* <<= @intCast(@import("std").math.Log2Int(c_int), @as(c_int, 1));
        \\        break :blk ref.*;
        \\    });
        \\    a = @divTrunc(a, blk: {
        \\        const ref = &a;
        \\        ref.* = @divTrunc(ref.*, @as(c_int, 1));
        \\        break :blk ref.*;
        \\    });
        \\    a = @rem(a, blk: {
        \\        const ref = &a;
        \\        ref.* = @rem(ref.*, @as(c_int, 1));
        \\        break :blk ref.*;
        \\    });
        \\    b /= blk: {
        \\        const ref = &b;
        \\        ref.* /= @bitCast(c_uint, @as(c_int, 1));
        \\        break :blk ref.*;
        \\    };
        \\    b %= blk: {
        \\        const ref = &b;
        \\        ref.* %= @bitCast(c_uint, @as(c_int, 1));
        \\        break :blk ref.*;
        \\    };
        \\}
    });

    cases.add("compound assignment operators unsigned",
        \\void foo(void) {
        \\    unsigned a = 0;
        \\    a += (a += 1);
        \\    a -= (a -= 1);
        \\    a *= (a *= 1);
        \\    a &= (a &= 1);
        \\    a |= (a |= 1);
        \\    a ^= (a ^= 1);
        \\    a >>= (a >>= 1);
        \\    a <<= (a <<= 1);
        \\}
    , &[_][]const u8{
        \\pub export fn foo() void {
        \\    var a: c_uint = 0;
        \\    a +%= blk: {
        \\        const ref = &a;
        \\        ref.* +%= @bitCast(c_uint, @as(c_int, 1));
        \\        break :blk ref.*;
        \\    };
        \\    a -%= blk: {
        \\        const ref = &a;
        \\        ref.* -%= @bitCast(c_uint, @as(c_int, 1));
        \\        break :blk ref.*;
        \\    };
        \\    a *%= blk: {
        \\        const ref = &a;
        \\        ref.* *%= @bitCast(c_uint, @as(c_int, 1));
        \\        break :blk ref.*;
        \\    };
        \\    a &= blk: {
        \\        const ref = &a;
        \\        ref.* &= @bitCast(c_uint, @as(c_int, 1));
        \\        break :blk ref.*;
        \\    };
        \\    a |= blk: {
        \\        const ref = &a;
        \\        ref.* |= @bitCast(c_uint, @as(c_int, 1));
        \\        break :blk ref.*;
        \\    };
        \\    a ^= blk: {
        \\        const ref = &a;
        \\        ref.* ^= @bitCast(c_uint, @as(c_int, 1));
        \\        break :blk ref.*;
        \\    };
        \\    a >>= @intCast(@import("std").math.Log2Int(c_uint), blk: {
        \\        const ref = &a;
        \\        ref.* >>= @intCast(@import("std").math.Log2Int(c_int), @as(c_int, 1));
        \\        break :blk ref.*;
        \\    });
        \\    a <<= @intCast(@import("std").math.Log2Int(c_uint), blk: {
        \\        const ref = &a;
        \\        ref.* <<= @intCast(@import("std").math.Log2Int(c_int), @as(c_int, 1));
        \\        break :blk ref.*;
        \\    });
        \\}
    });

    cases.add("post increment/decrement",
        \\void foo(void) {
        \\    int i = 0;
        \\    unsigned u = 0;
        \\    i++;
        \\    i--;
        \\    u++;
        \\    u--;
        \\    i = i++;
        \\    i = i--;
        \\    u = u++;
        \\    u = u--;
        \\}
    , &[_][]const u8{
        \\pub export fn foo() void {
        \\    var i: c_int = 0;
        \\    var u: c_uint = 0;
        \\    i += 1;
        \\    i -= 1;
        \\    u +%= 1;
        \\    u -%= 1;
        \\    i = blk: {
        \\        const ref = &i;
        \\        const tmp = ref.*;
        \\        ref.* += 1;
        \\        break :blk tmp;
        \\    };
        \\    i = blk: {
        \\        const ref = &i;
        \\        const tmp = ref.*;
        \\        ref.* -= 1;
        \\        break :blk tmp;
        \\    };
        \\    u = blk: {
        \\        const ref = &u;
        \\        const tmp = ref.*;
        \\        ref.* +%= 1;
        \\        break :blk tmp;
        \\    };
        \\    u = blk: {
        \\        const ref = &u;
        \\        const tmp = ref.*;
        \\        ref.* -%= 1;
        \\        break :blk tmp;
        \\    };
        \\}
    });

    cases.add("implicit casts",
        \\#include <stdbool.h>
        \\
        \\void fn_int(int x);
        \\void fn_f32(float x);
        \\void fn_f64(double x);
        \\void fn_char(char x);
        \\void fn_bool(bool x);
        \\void fn_ptr(void *x);
        \\
        \\void call() {
        \\    fn_int(3.0f);
        \\    fn_int(3.0);
        \\    fn_int('ABCD');
        \\    fn_f32(3);
        \\    fn_f64(3);
        \\    fn_char('3');
        \\    fn_char('\x1');
        \\    fn_char(0);
        \\    fn_f32(3.0f);
        \\    fn_f64(3.0);
        \\    fn_bool(123);
        \\    fn_bool(0);
        \\    fn_bool(&fn_int);
        \\    fn_int(&fn_int);
        \\    fn_ptr(42);
        \\}
    , &[_][]const u8{
        \\pub extern fn fn_int(x: c_int) void;
        \\pub extern fn fn_f32(x: f32) void;
        \\pub extern fn fn_f64(x: f64) void;
        \\pub extern fn fn_char(x: u8) void;
        \\pub extern fn fn_bool(x: bool) void;
        \\pub extern fn fn_ptr(x: ?*c_void) void;
        \\pub export fn call() void {
        \\    fn_int(@floatToInt(c_int, 3.0));
        \\    fn_int(@floatToInt(c_int, 3.0));
        \\    fn_int(@as(c_int, 1094861636));
        \\    fn_f32(@intToFloat(f32, @as(c_int, 3)));
        \\    fn_f64(@intToFloat(f64, @as(c_int, 3)));
        \\    fn_char(@bitCast(u8, @truncate(i8, @as(c_int, '3'))));
        \\    fn_char(@bitCast(u8, @truncate(i8, @as(c_int, '\x01'))));
        \\    fn_char(@bitCast(u8, @truncate(i8, @as(c_int, 0))));
        \\    fn_f32(3.0);
        \\    fn_f64(3.0);
        \\    fn_bool(@as(c_int, 123) != 0);
        \\    fn_bool(@as(c_int, 0) != 0);
        \\    fn_bool(@ptrToInt(fn_int) != 0);
        \\    fn_int(@intCast(c_int, @ptrToInt(fn_int)));
        \\    fn_ptr(@intToPtr(?*c_void, @as(c_int, 42)));
        \\}
    });

    cases.add("function call",
        \\static void bar(void) { }
        \\void foo(int *(baz)(void)) {
        \\    bar();
        \\    baz();
        \\}
    , &[_][]const u8{
        \\pub fn bar() callconv(.C) void {}
        \\pub export fn foo(arg_baz: ?fn () callconv(.C) [*c]c_int) void {
        \\    var baz = arg_baz;
        \\    bar();
        \\    _ = baz.?();
        \\}
    });

    cases.add("macro defines string literal with octal",
        \\#define FOO "aoeu\023 derp"
        \\#define FOO2 "aoeu\0234 derp"
        \\#define FOO_CHAR '\077'
    , &[_][]const u8{
        \\pub const FOO = "aoeu\x13 derp";
        ,
        \\pub const FOO2 = "aoeu\x134 derp";
        ,
        \\pub const FOO_CHAR = '\x3f';
    });

    cases.add("enums",
        \\enum Foo {
        \\    FooA = 2,
        \\    FooB = 5,
        \\    Foo1,
        \\};
    , &[_][]const u8{
        \\pub const FooA: c_int = 2;
        \\pub const FooB: c_int = 5;
        \\pub const Foo1: c_int = 6;
        \\pub const enum_Foo =
        ++ " " ++ default_enum_type ++
            \\;
        ,
        \\pub const Foo = enum_Foo;
    });

    cases.add("macro cast",
        \\#include <stdint.h>
        \\#define FOO(bar) baz((void *)(baz))
        \\#define BAR (void*) a
        \\#define BAZ (uint32_t)(2)
    , &[_][]const u8{
        \\pub inline fn FOO(bar: anytype) @TypeOf(baz(@import("std").zig.c_translation.cast(?*c_void, baz))) {
        \\    _ = bar;
        \\    return baz(@import("std").zig.c_translation.cast(?*c_void, baz));
        \\}
        ,
        \\pub const BAR = @import("std").zig.c_translation.cast(?*c_void, a);
        ,
        \\pub const BAZ = @import("std").zig.c_translation.cast(u32, @as(c_int, 2));
    });

    cases.add("macro with cast to unsigned short, long, and long long",
        \\#define CURLAUTH_BASIC_BUT_USHORT ((unsigned short) 1)
        \\#define CURLAUTH_BASIC ((unsigned long) 1)
        \\#define CURLAUTH_BASIC_BUT_ULONGLONG ((unsigned long long) 1)
    , &[_][]const u8{
        \\pub const CURLAUTH_BASIC_BUT_USHORT = @import("std").zig.c_translation.cast(c_ushort, @as(c_int, 1));
        \\pub const CURLAUTH_BASIC = @import("std").zig.c_translation.cast(c_ulong, @as(c_int, 1));
        \\pub const CURLAUTH_BASIC_BUT_ULONGLONG = @import("std").zig.c_translation.cast(c_ulonglong, @as(c_int, 1));
    });

    cases.add("macro conditional operator",
        \\#define FOO a ? b : c
    , &[_][]const u8{
        \\pub const FOO = if (a) b else c;
    });

    cases.add("do while as expr",
        \\static void foo(void) {
        \\    if (1)
        \\        do {} while (0);
        \\}
    , &[_][]const u8{
        \\pub fn foo() callconv(.C) void {
        \\    if (true) {}
        \\}
    });

    cases.add("macro comparisions",
        \\#define MIN(a, b) ((b) < (a) ? (b) : (a))
        \\#define MAX(a, b) ((b) > (a) ? (b) : (a))
    , &[_][]const u8{
        \\pub inline fn MIN(a: anytype, b: anytype) @TypeOf(if (b < a) b else a) {
        \\    return if (b < a) b else a;
        \\}
        ,
        \\pub inline fn MAX(a: anytype, b: anytype) @TypeOf(if (b > a) b else a) {
        \\    return if (b > a) b else a;
        \\}
    });

    cases.add("nested assignment",
        \\int foo(int *p, int x) {
        \\    return *p++ = x;
        \\}
    , &[_][]const u8{
        \\pub export fn foo(arg_p: [*c]c_int, arg_x: c_int) c_int {
        \\    var p = arg_p;
        \\    var x = arg_x;
        \\    return blk: {
        \\        const tmp = x;
        \\        (blk_1: {
        \\            const ref = &p;
        \\            const tmp_2 = ref.*;
        \\            ref.* += 1;
        \\            break :blk_1 tmp_2;
        \\        }).* = tmp;
        \\        break :blk tmp;
        \\    };
        \\}
    });

    cases.add("widening and truncating integer casting to different signedness",
        \\unsigned long foo(void) {
        \\    return -1;
        \\}
        \\unsigned short bar(long x) {
        \\    return x;
        \\}
    , &[_][]const u8{
        \\pub export fn foo() c_ulong {
        \\    return @bitCast(c_ulong, @as(c_long, -@as(c_int, 1)));
        \\}
        \\pub export fn bar(arg_x: c_long) c_ushort {
        \\    var x = arg_x;
        \\    return @bitCast(c_ushort, @truncate(c_short, x));
        \\}
    });

    cases.add("arg name aliasing decl which comes after",
        \\void foo(int bar) {
        \\    bar = 2;
        \\}
        \\int bar = 4;
    , &[_][]const u8{
        \\pub export fn foo(arg_bar_1: c_int) void {
        \\    var bar_1 = arg_bar_1;
        \\    bar_1 = 2;
        \\}
        \\pub export var bar: c_int = 4;
    });

    cases.add("arg name aliasing macro which comes after",
        \\void foo(int bar) {
        \\    bar = 2;
        \\}
        \\#define bar 4
    , &[_][]const u8{
        \\pub export fn foo(arg_bar_1: c_int) void {
        \\    var bar_1 = arg_bar_1;
        \\    bar_1 = 2;
        \\}
        ,
        \\pub const bar = @as(c_int, 4);
    });

    cases.add("don't export inline functions",
        \\inline void a(void) {}
        \\static void b(void) {}
        \\void c(void) {}
        \\static void foo() {}
    , &[_][]const u8{
        \\pub fn a() callconv(.C) void {}
        \\pub fn b() callconv(.C) void {}
        \\pub export fn c() void {}
        \\pub fn foo() callconv(.C) void {}
    });

    cases.add("casting away const and volatile",
        \\void foo(int *a) {}
        \\void bar(const int *a) {
        \\    foo((int *)a);
        \\}
        \\void baz(volatile int *a) {
        \\    foo((int *)a);
        \\}
    , &[_][]const u8{
        \\pub export fn foo(arg_a: [*c]c_int) void {
        \\    var a = arg_a;
        \\    _ = a;
        \\}
        \\pub export fn bar(arg_a: [*c]const c_int) void {
        \\    var a = arg_a;
        \\    foo(@intToPtr([*c]c_int, @ptrToInt(a)));
        \\}
        \\pub export fn baz(arg_a: [*c]volatile c_int) void {
        \\    var a = arg_a;
        \\    foo(@intToPtr([*c]c_int, @ptrToInt(a)));
        \\}
    });

    cases.add("handling of _Bool type",
        \\_Bool foo(_Bool x) {
        \\    _Bool a = x != 1;
        \\    _Bool b = a != 0;
        \\    _Bool c = foo;
        \\    return foo(c != b);
        \\}
    , &[_][]const u8{
        \\pub export fn foo(arg_x: bool) bool {
        \\    var x = arg_x;
        \\    var a: bool = @as(c_int, @boolToInt(x)) != @as(c_int, 1);
        \\    var b: bool = @as(c_int, @boolToInt(a)) != @as(c_int, 0);
        \\    var c: bool = @ptrToInt(foo) != 0;
        \\    return foo(@as(c_int, @boolToInt(c)) != @as(c_int, @boolToInt(b)));
        \\}
    });

    cases.add("Don't make const parameters mutable",
        \\int max(const int x, int y) {
        \\    return (x > y) ? x : y;
        \\}
    , &[_][]const u8{
        \\pub export fn max(x: c_int, arg_y: c_int) c_int {
        \\    var y = arg_y;
        \\    return if (x > y) x else y;
        \\}
    });

    cases.add("string concatenation in macros",
        \\#define FOO "hello"
        \\#define BAR FOO " world"
        \\#define BAZ "oh, " FOO
    , &[_][]const u8{
        \\pub const FOO = "hello";
        ,
        \\pub const BAR = FOO ++ " world";
        ,
        \\pub const BAZ = "oh, " ++ FOO;
    });

    cases.add("string concatenation in macros: two defines",
        \\#define FOO "hello"
        \\#define BAZ " world"
        \\#define BAR FOO BAZ
    , &[_][]const u8{
        \\pub const FOO = "hello";
        ,
        \\pub const BAZ = " world";
        ,
        \\pub const BAR = FOO ++ BAZ;
    });

    cases.add("string concatenation in macros: two strings",
        \\#define FOO "a" "b"
        \\#define BAR FOO "c"
    , &[_][]const u8{
        \\pub const FOO = "a" ++ "b";
        ,
        \\pub const BAR = FOO ++ "c";
    });

    cases.add("string concatenation in macros: three strings",
        \\#define FOO "a" "b" "c"
    , &[_][]const u8{
        \\pub const FOO = "a" ++ "b" ++ "c";
    });

    cases.add("multibyte character literals",
        \\#define FOO 'abcd'
    , &[_][]const u8{
        \\pub const FOO = 0x61626364;
    });

    cases.add("Make sure casts are grouped",
        \\typedef struct
        \\{
        \\    int i;
        \\}
        \\*_XPrivDisplay;
        \\typedef struct _XDisplay Display;
        \\#define DefaultScreen(dpy) (((_XPrivDisplay)(dpy))->default_screen)
        \\
    , &[_][]const u8{
        \\pub inline fn DefaultScreen(dpy: anytype) @TypeOf(@import("std").zig.c_translation.cast(_XPrivDisplay, dpy).*.default_screen) {
        \\    return @import("std").zig.c_translation.cast(_XPrivDisplay, dpy).*.default_screen;
        \\}
    });

    cases.add("macro integer literal casts",
        \\#define NULL ((void*)0)
        \\#define FOO ((int)0x8000)
    , &[_][]const u8{
        \\pub const NULL = @import("std").zig.c_translation.cast(?*c_void, @as(c_int, 0));
        ,
        \\pub const FOO = @import("std").zig.c_translation.cast(c_int, @import("std").zig.c_translation.promoteIntLiteral(c_int, 0x8000, .hexadecimal));
    });

    if (std.Target.current.abi == .msvc) {
        cases.add("nameless struct fields",
            \\typedef struct NAMED
            \\{
            \\    long name;
            \\} NAMED;
            \\
            \\typedef struct ONENAMEWITHSTRUCT
            \\{
            \\    NAMED;
            \\    long b;
            \\} ONENAMEWITHSTRUCT;
        , &[_][]const u8{
            \\pub const struct_NAMED = extern struct {
            \\    name: c_long,
            \\};
            \\pub const NAMED = struct_NAMED;
            \\pub const struct_ONENAMEWITHSTRUCT = extern struct {
            \\    unnamed_0: struct_NAMED,
            \\    b: c_long,
            \\};
        });
    } else {
        cases.add("nameless struct fields",
            \\typedef struct NAMED
            \\{
            \\    long name;
            \\} NAMED;
            \\
            \\typedef struct ONENAMEWITHSTRUCT
            \\{
            \\    NAMED;
            \\    long b;
            \\} ONENAMEWITHSTRUCT;
        , &[_][]const u8{
            \\pub const struct_NAMED = extern struct {
            \\    name: c_long,
            \\};
            \\pub const NAMED = struct_NAMED;
            \\pub const struct_ONENAMEWITHSTRUCT = extern struct {
            \\    b: c_long,
            \\};
        });
    }

    cases.add("unnamed fields have predictabile names",
        \\struct a {
        \\    struct {};
        \\};
        \\struct b {
        \\    struct {};
        \\};
    , &[_][]const u8{
        \\const struct_unnamed_1 = extern struct {};
        \\pub const struct_a = extern struct {
        \\    unnamed_0: struct_unnamed_1,
        \\};
        \\const struct_unnamed_2 = extern struct {};
        \\pub const struct_b = extern struct {
        \\    unnamed_0: struct_unnamed_2,
        \\};
    });

    cases.add("integer literal promotion",
        \\#define GUARANTEED_TO_FIT_1 1024
        \\#define GUARANTEED_TO_FIT_2 10241024L
        \\#define GUARANTEED_TO_FIT_3 20482048LU
        \\#define MAY_NEED_PROMOTION_1 10241024
        \\#define MAY_NEED_PROMOTION_2 307230723072L
        \\#define MAY_NEED_PROMOTION_3 819281928192LU
        \\#define MAY_NEED_PROMOTION_HEX 0x80000000
        \\#define MAY_NEED_PROMOTION_OCT 020000000000
    , &[_][]const u8{
        \\pub const GUARANTEED_TO_FIT_1 = @as(c_int, 1024);
        \\pub const GUARANTEED_TO_FIT_2 = @as(c_long, 10241024);
        \\pub const GUARANTEED_TO_FIT_3 = @as(c_ulong, 20482048);
        \\pub const MAY_NEED_PROMOTION_1 = @import("std").zig.c_translation.promoteIntLiteral(c_int, 10241024, .decimal);
        \\pub const MAY_NEED_PROMOTION_2 = @import("std").zig.c_translation.promoteIntLiteral(c_long, 307230723072, .decimal);
        \\pub const MAY_NEED_PROMOTION_3 = @import("std").zig.c_translation.promoteIntLiteral(c_ulong, 819281928192, .decimal);
        \\pub const MAY_NEED_PROMOTION_HEX = @import("std").zig.c_translation.promoteIntLiteral(c_int, 0x80000000, .hexadecimal);
        \\pub const MAY_NEED_PROMOTION_OCT = @import("std").zig.c_translation.promoteIntLiteral(c_int, 0o20000000000, .octal);
    });

    // See __builtin_alloca_with_align comment in std.c.builtins
    cases.add("demote un-implemented builtins",
        \\#define FOO(X) __builtin_alloca_with_align((X), 8)
    , &[_][]const u8{
        \\pub const FOO = @compileError("TODO implement function '__builtin_alloca_with_align' in std.c.builtins");
    });

    cases.add("null sentinel arrays when initialized from string literal. Issue #8256",
        \\#include <stdint.h>
        \\char zero[0] = "abc";
        \\uint32_t zero_w[0] = U"💯💯💯";
        \\char empty_incomplete[] = "";
        \\uint32_t empty_incomplete_w[] = U"";
        \\char empty_constant[100] = "";
        \\uint32_t empty_constant_w[100] = U"";
        \\char incomplete[] = "abc";
        \\uint32_t incomplete_w[] = U"💯💯💯";
        \\char truncated[1] = "abc";
        \\uint32_t truncated_w[1] = U"💯💯💯";
        \\char extend[5] = "a";
        \\uint32_t extend_w[5] = U"💯";
        \\char no_null[3] = "abc";
        \\uint32_t no_null_w[3] = U"💯💯💯";
    , &[_][]const u8{
        \\pub export var zero: [0]u8 = [0]u8{};
        \\pub export var zero_w: [0]u32 = [0]u32{};
        \\pub export var empty_incomplete: [1]u8 = [1]u8{0} ** 1;
        \\pub export var empty_incomplete_w: [1]u32 = [1]u32{0} ** 1;
        \\pub export var empty_constant: [100]u8 = [1]u8{0} ** 100;
        \\pub export var empty_constant_w: [100]u32 = [1]u32{0} ** 100;
        \\pub export var incomplete: [3:0]u8 = "abc".*;
        \\pub export var incomplete_w: [3:0]u32 = [3:0]u32{
        \\    '\u{1f4af}',
        \\    '\u{1f4af}',
        \\    '\u{1f4af}',
        \\};
        \\pub export var truncated: [1]u8 = "abc"[0..1].*;
        \\pub export var truncated_w: [1]u32 = [1]u32{
        \\    '\u{1f4af}',
        \\};
        \\pub export var extend: [5]u8 = "a"[0..1].* ++ [1]u8{0} ** 4;
        \\pub export var extend_w: [5]u32 = [1]u32{
        \\    '\u{1f4af}',
        \\} ++ [1]u32{0} ** 4;
        \\pub export var no_null: [3]u8 = "abc".*;
        \\pub export var no_null_w: [3]u32 = [3]u32{
        \\    '\u{1f4af}',
        \\    '\u{1f4af}',
        \\    '\u{1f4af}',
        \\};
    });

    cases.add("global assembly",
        \\__asm__(".globl func\n\t"
        \\        ".type func, @function\n\t"
        \\        "func:\n\t"
        \\        ".cfi_startproc\n\t"
        \\        "movl $42, %eax\n\t"
        \\        "ret\n\t"
        \\        ".cfi_endproc");
    , &[_][]const u8{
        \\comptime {
        \\    asm (".globl func\n\t.type func, @function\n\tfunc:\n\t.cfi_startproc\n\tmovl $42, %eax\n\tret\n\t.cfi_endproc");
        \\}
    });

    cases.add("Demote function that initializes opaque struct",
        \\struct my_struct {
        \\    unsigned a: 15;
        \\    unsigned: 2;
        \\    unsigned b: 15;
        \\};
        \\void initialize(void) {
        \\    struct my_struct S = {.a = 1, .b = 2};
        \\}
    , &[_][]const u8{
        \\warning: cannot initialize opaque type
        ,
        \\warning: unable to translate function, demoted to extern
        \\pub extern fn initialize() void;
    });

    cases.add("Demote function that dereferences opaque type",
        \\struct my_struct {
        \\    unsigned a: 1;
        \\};
        \\void deref(struct my_struct *s) {
        \\    *s;
        \\}
    , &[_][]const u8{
        \\warning: cannot dereference opaque type
        ,
        \\warning: unable to translate function, demoted to extern
        \\pub extern fn deref(arg_s: ?*struct_my_struct) void;
    });

    cases.add("Function prototype declared within function",
        \\int foo(void) {
        \\    extern int bar(int, int);
        \\    return bar(1, 2);
        \\}
    , &[_][]const u8{
        \\pub extern fn bar(c_int, c_int) c_int;
        \\pub export fn foo() c_int {
        \\    return bar(@as(c_int, 1), @as(c_int, 2));
        \\}
    });

    cases.add("static local variable zero-initialized if no initializer",
        \\struct FOO {int x; int y;};
        \\int bar(void) {
        \\    static struct FOO foo;
        \\    return foo.x;
        \\}
    , &[_][]const u8{
        \\pub const struct_FOO = extern struct {
        \\    x: c_int,
        \\    y: c_int,
        \\};
        \\pub export fn bar() c_int {
        \\    const foo = struct {
        \\        var static: struct_FOO = @import("std").mem.zeroes(struct_FOO);
        \\    };
        \\    return foo.static.x;
        \\}
    });

    cases.add("macro with nontrivial cast",
        \\#define MAP_FAILED ((void *) -1)
        \\typedef long long LONG_PTR;
        \\#define INVALID_HANDLE_VALUE ((void *)(LONG_PTR)-1)
    , &[_][]const u8{
        \\pub const MAP_FAILED = @import("std").zig.c_translation.cast(?*c_void, -@as(c_int, 1));
        \\pub const INVALID_HANDLE_VALUE = @import("std").zig.c_translation.cast(?*c_void, @import("std").zig.c_translation.cast(LONG_PTR, -@as(c_int, 1)));
    });

    cases.add("discard unused local variables and function parameters",
        \\#define FOO(A, B) (A)
        \\int bar(int x, int y) {
        \\   return x;
        \\}
    , &[_][]const u8{
        \\pub export fn bar(arg_x: c_int, arg_y: c_int) c_int {
        \\    var x = arg_x;
        \\    var y = arg_y;
        \\    _ = y;
        \\    return x;
        \\}
        ,
        \\pub inline fn FOO(A: anytype, B: anytype) @TypeOf(A) {
        \\    _ = B;
        \\    return A;
        \\}
    });

    cases.add("Use @ syntax for bare underscore identifier in macro or public symbol",
        \\#define FOO _
        \\int _ = 42;
    , &[_][]const u8{
        \\pub const FOO = @"_";
        ,
        \\pub export var @"_": c_int = 42;
    });
}
