const std = @import("std");
const TestContext = @import("../../src/test.zig").TestContext;

// These tests should work with all platforms, but we're using linux_x64 for
// now for consistency. Will be expanded eventually.
const linux_x64 = std.zig.CrossTarget{
    .cpu_arch = .x86_64,
    .os_tag = .linux,
};

pub fn addCases(ctx: *TestContext) !void {
    {
        var case = ctx.exeFromCompiledC("hello world with updates", .{});

        // Regular old hello world
        case.addCompareOutput(
            \\extern fn puts(s: [*:0]const u8) c_int;
            \\pub export fn main() c_int {
            \\    _ = puts("hello world!");
            \\    return 0;
            \\}
        , "hello world!" ++ std.cstr.line_sep);

        // Now change the message only
        case.addCompareOutput(
            \\extern fn puts(s: [*:0]const u8) c_int;
            \\pub export fn main() c_int {
            \\    _ = puts("yo");
            \\    return 0;
            \\}
        , "yo" ++ std.cstr.line_sep);

        // Add an unused Decl
        case.addCompareOutput(
            \\extern fn puts(s: [*:0]const u8) c_int;
            \\pub export fn main() c_int {
            \\    _ = puts("yo!");
            \\    return 0;
            \\}
            \\fn unused() void {}
        , "yo!" ++ std.cstr.line_sep);

        // Comptime return type and calling convention expected.
        case.addError(
            \\var x: i32 = 1234;
            \\pub export fn main() x {
            \\    return 0;
            \\}
            \\export fn foo() callconv(y) c_int {
            \\    return 0;
            \\}
            \\var y: i32 = 1234;
        , &.{
            ":2:22: error: unable to resolve comptime value",
            ":5:26: error: unable to resolve comptime value",
        });
    }

    {
        var case = ctx.exeFromCompiledC("var args", .{});

        case.addCompareOutput(
            \\extern fn printf(format: [*:0]const u8, ...) c_int;
            \\
            \\pub export fn main() c_int {
            \\    _ = printf("Hello, %s!\n", "world");
            \\    return 0;
            \\}
        , "Hello, world!" ++ std.cstr.line_sep);
    }

    {
        var case = ctx.exeFromCompiledC("@intToError", .{});

        case.addCompareOutput(
            \\pub export fn main() c_int {
            \\    // comptime checks
            \\    const a = error.A;
            \\    const b = error.B;
            \\    const c = @intToError(2);
            \\    const d = @intToError(1);
            \\    if (!(c == b)) unreachable;
            \\    if (!(a == d)) unreachable;
            \\    // runtime checks
            \\    var x = error.A;
            \\    var y = error.B;
            \\    var z = @intToError(2);
            \\    var f = @intToError(1);
            \\    if (!(y == z)) unreachable;
            \\    if (!(x == f)) unreachable;
            \\    return 0;
            \\}
        , "");
        case.addError(
            \\pub export fn main() c_int {
            \\    _ = @intToError(0);
            \\    return 0;
            \\}
        , &.{":2:21: error: integer value 0 represents no error"});
        case.addError(
            \\pub export fn main() c_int {
            \\    _ = @intToError(3);
            \\    return 0;
            \\}
        , &.{":2:21: error: integer value 3 represents no error"});
    }

    {
        var case = ctx.exeFromCompiledC("x86_64-linux inline assembly", linux_x64);

        // Exit with 0
        case.addCompareOutput(
            \\fn exitGood() noreturn {
            \\    asm volatile ("syscall"
            \\        :
            \\        : [number] "{rax}" (231),
            \\          [arg1] "{rdi}" (0)
            \\    );
            \\    unreachable;
            \\}
            \\
            \\pub export fn main() c_int {
            \\    exitGood();
            \\}
        , "");

        // Pass a usize parameter to exit
        case.addCompareOutput(
            \\pub export fn main() c_int {
            \\    exit(0);
            \\}
            \\
            \\fn exit(code: usize) noreturn {
            \\    asm volatile ("syscall"
            \\        :
            \\        : [number] "{rax}" (231),
            \\          [arg1] "{rdi}" (code)
            \\    );
            \\    unreachable;
            \\}
        , "");

        // Change the parameter to u8
        case.addCompareOutput(
            \\pub export fn main() c_int {
            \\    exit(0);
            \\}
            \\
            \\fn exit(code: u8) noreturn {
            \\    asm volatile ("syscall"
            \\        :
            \\        : [number] "{rax}" (231),
            \\          [arg1] "{rdi}" (code)
            \\    );
            \\    unreachable;
            \\}
        , "");

        // Do some arithmetic at the exit callsite
        case.addCompareOutput(
            \\pub export fn main() c_int {
            \\    exitMath(1);
            \\}
            \\
            \\fn exitMath(a: u8) noreturn {
            \\    exit(0 + a - a);
            \\}
            \\
            \\fn exit(code: u8) noreturn {
            \\    asm volatile ("syscall"
            \\        :
            \\        : [number] "{rax}" (231),
            \\          [arg1] "{rdi}" (code)
            \\    );
            \\    unreachable;
            \\}
            \\
        , "");

        // Invert the arithmetic
        case.addCompareOutput(
            \\pub export fn main() c_int {
            \\    exitMath(1);
            \\}
            \\
            \\fn exitMath(a: u8) noreturn {
            \\    exit(a + 0 - a);
            \\}
            \\
            \\fn exit(code: u8) noreturn {
            \\    asm volatile ("syscall"
            \\        :
            \\        : [number] "{rax}" (231),
            \\          [arg1] "{rdi}" (code)
            \\    );
            \\    unreachable;
            \\}
            \\
        , "");
    }

    {
        var case = ctx.exeFromCompiledC("alloc and retptr", .{});

        case.addCompareOutput(
            \\fn add(a: i32, b: i32) i32 {
            \\    return a + b;
            \\}
            \\
            \\fn addIndirect(a: i32, b: i32) i32 {
            \\    return add(a, b);
            \\}
            \\
            \\pub export fn main() c_int {
            \\    return addIndirect(1, 2) - 3;
            \\}
        , "");
    }

    {
        var case = ctx.exeFromCompiledC("inferred local const and var", .{});

        case.addCompareOutput(
            \\fn add(a: i32, b: i32) i32 {
            \\    return a + b;
            \\}
            \\
            \\pub export fn main() c_int {
            \\    const x = add(1, 2);
            \\    var y = add(3, 0);
            \\    y -= x;
            \\    return y;
            \\}
        , "");
    }
    // This will make a pretty deep call stack, so this test can only be enabled
    // on hosts where Zig's linking strategy can honor the 16 MiB (default) we
    // link the self-hosted compiler with.
    const host_supports_custom_stack_size = @import("builtin").target.os.tag == .linux;
    if (host_supports_custom_stack_size) {
        var case = ctx.exeFromCompiledC("@setEvalBranchQuota", .{});

        case.addCompareOutput(
            \\pub export fn main() i32 {
            \\    @setEvalBranchQuota(1001);
            \\    const y = rec(1001);
            \\    return y - 1;
            \\}
            \\
            \\fn rec(n: usize) callconv(.Inline) usize {
            \\    if (n <= 1) return n;
            \\    return rec(n - 1);
            \\}
        , "");
    }
    {
        var case = ctx.exeFromCompiledC("control flow", .{});

        // Simple while loop
        case.addCompareOutput(
            \\pub export fn main() c_int {
            \\    var a: c_int = 0;
            \\    while (a < 5) : (a+=1) {}
            \\    return a - 5;
            \\}
        , "");
        case.addCompareOutput(
            \\pub export fn main() c_int {
            \\    var a = true;
            \\    while (!a) {}
            \\    return 0;
            \\}
        , "");

        // If expression
        case.addCompareOutput(
            \\pub export fn main() c_int {
            \\    var cond: c_int = 0;
            \\    var a: c_int = @as(c_int, if (cond == 0)
            \\        2
            \\    else
            \\        3) + 9;
            \\    return a - 11;
            \\}
        , "");

        // If expression with breakpoint that does not get hit
        case.addCompareOutput(
            \\pub export fn main() c_int {
            \\    var x: i32 = 1;
            \\    if (x != 1) @breakpoint();
            \\    return 0;
            \\}
        , "");

        // Switch expression
        case.addCompareOutput(
            \\pub export fn main() c_int {
            \\    var cond: c_int = 0;
            \\    var a: c_int = switch (cond) {
            \\        1 => 1,
            \\        2 => 2,
            \\        99...300, 12 => 3,
            \\        0 => 4,
            \\        else => 5,
            \\    };
            \\    return a - 4;
            \\}
        , "");

        // Switch expression missing else case.
        case.addError(
            \\pub export fn main() c_int {
            \\    var cond: c_int = 0;
            \\    const a: c_int = switch (cond) {
            \\        1 => 1,
            \\        2 => 2,
            \\        3 => 3,
            \\        4 => 4,
            \\    };
            \\    return a - 4;
            \\}
        , &.{":3:22: error: switch must handle all possibilities"});

        // Switch expression, has an unreachable prong.
        case.addCompareOutput(
            \\pub export fn main() c_int {
            \\    var cond: c_int = 0;
            \\    const a: c_int = switch (cond) {
            \\        1 => 1,
            \\        2 => 2,
            \\        99...300, 12 => 3,
            \\        0 => 4,
            \\        13 => unreachable,
            \\        else => 5,
            \\    };
            \\    return a - 4;
            \\}
        , "");

        // Switch expression, has an unreachable prong and prongs write
        // to result locations.
        case.addCompareOutput(
            \\pub export fn main() c_int {
            \\    var cond: c_int = 0;
            \\    var a: c_int = switch (cond) {
            \\        1 => 1,
            \\        2 => 2,
            \\        99...300, 12 => 3,
            \\        0 => 4,
            \\        13 => unreachable,
            \\        else => 5,
            \\    };
            \\    return a - 4;
            \\}
        , "");

        // Integer switch expression has duplicate case value.
        case.addError(
            \\pub export fn main() c_int {
            \\    var cond: c_int = 0;
            \\    const a: c_int = switch (cond) {
            \\        1 => 1,
            \\        2 => 2,
            \\        96, 11...13, 97 => 3,
            \\        0 => 4,
            \\        90, 12 => 100,
            \\        else => 5,
            \\    };
            \\    return a - 4;
            \\}
        , &.{
            ":8:13: error: duplicate switch value",
            ":6:15: note: previous value here",
        });

        // Boolean switch expression has duplicate case value.
        case.addError(
            \\pub export fn main() c_int {
            \\    var a: bool = false;
            \\    const b: c_int = switch (a) {
            \\        false => 1,
            \\        true => 2,
            \\        false => 3,
            \\    };
            \\    _  = b;
            \\}
        , &.{
            ":6:9: error: duplicate switch value",
        });

        // Sparse (no range capable) switch expression has duplicate case value.
        case.addError(
            \\pub export fn main() c_int {
            \\    const A: type = i32;
            \\    const b: c_int = switch (A) {
            \\        i32 => 1,
            \\        bool => 2,
            \\        f64, i32 => 3,
            \\        else => 4,
            \\    };
            \\    _ = b;
            \\}
        , &.{
            ":6:14: error: duplicate switch value",
            ":4:9: note: previous value here",
        });

        // Ranges not allowed for some kinds of switches.
        case.addError(
            \\pub export fn main() c_int {
            \\    const A: type = i32;
            \\    const b: c_int = switch (A) {
            \\        i32 => 1,
            \\        bool => 2,
            \\        f16...f64 => 3,
            \\        else => 4,
            \\    };
            \\    _ = b;
            \\}
        , &.{
            ":3:30: error: ranges not allowed when switching on type 'type'",
            ":6:12: note: range here",
        });

        // Switch expression has unreachable else prong.
        case.addError(
            \\pub export fn main() c_int {
            \\    var a: u2 = 0;
            \\    const b: i32 = switch (a) {
            \\        0 => 10,
            \\        1 => 20,
            \\        2 => 30,
            \\        3 => 40,
            \\        else => 50,
            \\    };
            \\    _ = b;
            \\}
        , &.{
            ":8:14: error: unreachable else prong; all cases already handled",
        });
    }
    //{
    //    var case = ctx.exeFromCompiledC("optionals", .{});

    //    // Simple while loop
    //    case.addCompareOutput(
    //        \\pub export fn main() c_int {
    //        \\    var count: c_int = 0;
    //        \\    var opt_ptr: ?*c_int = &count;
    //        \\    while (opt_ptr) |_| : (count += 1) {
    //        \\        if (count == 4) opt_ptr = null;
    //        \\    }
    //        \\    return count - 5;
    //        \\}
    //    , "");

    //    // Same with non pointer optionals
    //    case.addCompareOutput(
    //        \\pub export fn main() c_int {
    //        \\    var count: c_int = 0;
    //        \\    var opt_ptr: ?c_int = count;
    //        \\    while (opt_ptr) |_| : (count += 1) {
    //        \\        if (count == 4) opt_ptr = null;
    //        \\    }
    //        \\    return count - 5;
    //        \\}
    //    , "");
    //}

    {
        var case = ctx.exeFromCompiledC("errors", .{});
        case.addCompareOutput(
            \\pub export fn main() c_int {
            \\    var e1 = error.Foo;
            \\    var e2 = error.Bar;
            \\    assert(e1 != e2);
            \\    assert(e1 == error.Foo);
            \\    assert(e2 == error.Bar);
            \\    return 0;
            \\}
            \\fn assert(b: bool) void {
            \\    if (!b) unreachable;
            \\}
        , "");
        case.addCompareOutput(
            \\pub export fn main() c_int {
            \\    var e: anyerror!c_int = 0;
            \\    const i = e catch 69;
            \\    return i;
            \\}
        , "");
        case.addCompareOutput(
            \\pub export fn main() c_int {
            \\    var e: anyerror!c_int = error.Foo;
            \\    const i = e catch 69;
            \\    return 69 - i;
            \\}
        , "");
    }

    {
        var case = ctx.exeFromCompiledC("structs", .{});
        case.addError(
            \\const Point = struct { x: i32, y: i32 };
            \\pub export fn main() c_int {
            \\    var p: Point = .{
            \\        .y = 24,
            \\        .x = 12,
            \\        .y = 24,
            \\    };
            \\    return p.y - p.x - p.x;
            \\}
        , &.{
            ":6:10: error: duplicate field",
            ":4:10: note: other field here",
        });
        case.addError(
            \\const Point = struct { x: i32, y: i32 };
            \\pub export fn main() c_int {
            \\    var p: Point = .{
            \\        .y = 24,
            \\    };
            \\    return p.y - p.x - p.x;
            \\}
        , &.{
            ":3:21: error: missing struct field: x",
            ":1:15: note: struct 'tmp.Point' declared here",
        });
        case.addError(
            \\const Point = struct { x: i32, y: i32 };
            \\pub export fn main() c_int {
            \\    var p: Point = .{
            \\        .x = 12,
            \\        .y = 24,
            \\        .z = 48,
            \\    };
            \\    return p.y - p.x - p.x;
            \\}
        , &.{
            ":6:10: error: no field named 'z' in struct 'tmp.Point'",
            ":1:15: note: struct declared here",
        });
        case.addCompareOutput(
            \\const Point = struct { x: i32, y: i32 };
            \\pub export fn main() c_int {
            \\    var p: Point = .{
            \\        .x = 12,
            \\        .y = 24,
            \\    };
            \\    return p.y - p.x - p.x;
            \\}
        , "");
    }

    {
        var case = ctx.exeFromCompiledC("enums", .{});

        case.addError(
            \\const E1 = packed enum { a, b, c };
            \\const E2 = extern enum { a, b, c };
            \\export fn foo() void {
            \\    _ = E1.a;
            \\}
            \\export fn bar() void {
            \\    _ = E2.a;
            \\}
        , &.{
            ":1:12: error: enums do not support 'packed' or 'extern'; instead provide an explicit integer tag type",
            ":2:12: error: enums do not support 'packed' or 'extern'; instead provide an explicit integer tag type",
        });

        // comptime and types are caught in AstGen.
        case.addError(
            \\const E1 = enum {
            \\    a,
            \\    comptime b,
            \\    c,
            \\};
            \\const E2 = enum {
            \\    a,
            \\    b: i32,
            \\    c,
            \\};
            \\export fn foo() void {
            \\    _ = E1.a;
            \\}
            \\export fn bar() void {
            \\    _ = E2.a;
            \\}
        , &.{
            ":3:5: error: enum fields cannot be marked comptime",
            ":8:8: error: enum fields do not have types",
            ":6:12: note: consider 'union(enum)' here to make it a tagged union",
        });

        // @enumToInt, @intToEnum, enum literal coercion, field access syntax, comparison, switch
        case.addCompareOutput(
            \\const Number = enum { One, Two, Three };
            \\
            \\pub export fn main() c_int {
            \\    var number1 = Number.One;
            \\    var number2: Number = .Two;
            \\    const number3 = @intToEnum(Number, 2);
            \\    if (number1 == number2) return 1;
            \\    if (number2 == number3) return 1;
            \\    if (@enumToInt(number1) != 0) return 1;
            \\    if (@enumToInt(number2) != 1) return 1;
            \\    if (@enumToInt(number3) != 2) return 1;
            \\    var x: Number = .Two;
            \\    if (number2 != x) return 1;
            \\    switch (x) {
            \\        .One => return 1,
            \\        .Two => return 0,
            \\        number3 => return 2,
            \\    }
            \\}
        , "");

        // Specifying alignment is a parse error.
        // This also tests going from a successful build to a parse error.
        case.addError(
            \\const E1 = enum {
            \\    a,
            \\    b align(4),
            \\    c,
            \\};
            \\export fn foo() void {
            \\    _ = E1.a;
            \\}
        , &.{
            ":3:7: error: expected ',', found 'align'",
        });

        // Redundant non-exhaustive enum mark.
        // This also tests going from a parse error to an AstGen error.
        case.addError(
            \\const E1 = enum {
            \\    a,
            \\    _,
            \\    b,
            \\    c,
            \\    _,
            \\};
            \\export fn foo() void {
            \\    _ = E1.a;
            \\}
        , &.{
            ":6:5: error: redundant non-exhaustive enum mark",
            ":3:5: note: other mark here",
        });

        case.addError(
            \\const E1 = enum {
            \\    a,
            \\    b,
            \\    c,
            \\    _ = 10,
            \\};
            \\export fn foo() void {
            \\    _ = E1.a;
            \\}
        , &.{
            ":5:9: error: '_' is used to mark an enum as non-exhaustive and cannot be assigned a value",
        });

        case.addError(
            \\const E1 = enum {};
            \\export fn foo() void {
            \\    _ = E1.a;
            \\}
        , &.{
            ":1:12: error: enum declarations must have at least one tag",
        });

        case.addError(
            \\const E1 = enum { a, b, _ };
            \\export fn foo() void {
            \\    _ = E1.a;
            \\}
        , &.{
            ":1:12: error: non-exhaustive enum missing integer tag type",
            ":1:25: note: marked non-exhaustive here",
        });

        case.addError(
            \\const E1 = enum { a, b, c, b, d };
            \\pub export fn main() c_int {
            \\    _ = E1.a;
            \\}
        , &.{
            ":1:28: error: duplicate enum tag",
            ":1:22: note: other tag here",
        });

        case.addError(
            \\pub export fn main() c_int {
            \\    const a = true;
            \\    _ = @enumToInt(a);
            \\}
        , &.{
            ":3:20: error: expected enum or tagged union, found bool",
        });

        case.addError(
            \\pub export fn main() c_int {
            \\    const a = 1;
            \\    _ = @intToEnum(bool, a);
            \\}
        , &.{
            ":3:20: error: expected enum, found bool",
        });

        case.addError(
            \\const E = enum { a, b, c };
            \\pub export fn main() c_int {
            \\    _ = @intToEnum(E, 3);
            \\}
        , &.{
            ":3:9: error: enum 'tmp.E' has no tag with value 3",
            ":1:11: note: enum declared here",
        });

        case.addError(
            \\const E = enum { a, b, c };
            \\pub export fn main() c_int {
            \\    var x: E = .a;
            \\    switch (x) {
            \\        .a => {},
            \\        .c => {},
            \\    }
            \\}
        , &.{
            ":4:5: error: switch must handle all possibilities",
            ":4:5: note: unhandled enumeration value: 'b'",
            ":1:11: note: enum 'tmp.E' declared here",
        });

        case.addError(
            \\const E = enum { a, b, c };
            \\pub export fn main() c_int {
            \\    var x: E = .a;
            \\    switch (x) {
            \\        .a => {},
            \\        .b => {},
            \\        .b => {},
            \\        .c => {},
            \\    }
            \\}
        , &.{
            ":7:10: error: duplicate switch value",
            ":6:10: note: previous value here",
        });

        case.addError(
            \\const E = enum { a, b, c };
            \\pub export fn main() c_int {
            \\    var x: E = .a;
            \\    switch (x) {
            \\        .a => {},
            \\        .b => {},
            \\        .c => {},
            \\        else => {},
            \\    }
            \\}
        , &.{
            ":8:14: error: unreachable else prong; all cases already handled",
        });

        case.addError(
            \\const E = enum { a, b, c };
            \\pub export fn main() c_int {
            \\    var x: E = .a;
            \\    switch (x) {
            \\        .a => {},
            \\        .b => {},
            \\        _ => {},
            \\    }
            \\}
        , &.{
            ":4:5: error: '_' prong only allowed when switching on non-exhaustive enums",
            ":7:11: note: '_' prong here",
        });

        case.addError(
            \\const E = enum { a, b, c };
            \\pub export fn main() c_int {
            \\    _ = E.d;
            \\}
        , &.{
            ":3:10: error: enum 'tmp.E' has no member named 'd'",
            ":1:11: note: enum declared here",
        });

        case.addError(
            \\const E = enum { a, b, c };
            \\pub export fn main() c_int {
            \\    var x: E = .d;
            \\    _ = x;
            \\}
        , &.{
            ":3:17: error: enum 'tmp.E' has no field named 'd'",
            ":1:11: note: enum declared here",
        });
    }

    {
        var case = ctx.exeFromCompiledC("inferred error sets", .{});

        case.addCompareOutput(
            \\pub export fn main() c_int {
            \\    if (foo()) |_| {
            \\        @panic("test fail");
            \\    } else |err| {
            \\        if (err != error.ItBroke) {
            \\            @panic("test fail");
            \\        }
            \\    }
            \\    return 0;
            \\}
            \\fn foo() !void {
            \\    return error.ItBroke;
            \\}
        , "");
    }

    {
        var case = ctx.exeFromCompiledC("@ptrToInt/@intToPtr", .{});

        case.addCompareOutput(
            \\pub export fn main() i32 {
            \\    var y = 0x41;
            \\    _ = @ptrToInt(&y);
            \\    return 0;
            \\}
        , "");

        case.addCompareOutput(
            \\pub export fn main() i32 {
            \\    var y: u8 = 0x41;
            \\    const y_ptr = @ptrToInt(&y);
            \\    const z = @intToPtr(*u8, y_ptr).*;
            \\
            \\    if (y != z)
            \\        @panic("test fail");
            \\
            \\    return 0;
            \\}
        , "");
    }

    {
        // TODO: add u64 tests, ran into issues with the literal generated for std.math.maxInt(u64)
        var case = ctx.exeFromCompiledC("add/sub wrapping operations", .{});
        case.addCompareOutput(
            \\pub export fn main() c_int {
            \\    // Addition
            \\    if (!add_u3(1, 1, 2)) return 1;
            \\    if (!add_u3(7, 1, 0)) return 1;
            \\    if (!add_i3(1, 1, 2)) return 1;
            \\    if (!add_i3(3, 2, -3)) return 1;
            \\    if (!add_i3(-3, -2, 3)) return 1;
            \\    if (!add_c_int(1, 1, 2)) return 1;
            \\    // TODO enable these when stage2 supports std.math.maxInt
            \\    //if (!add_c_int(maxInt(c_int), 2, minInt(c_int) + 1)) return 1;
            \\    //if (!add_c_int(maxInt(c_int) + 1, -2, maxInt(c_int))) return 1;
            \\
            \\    // Subtraction
            \\    if (!sub_u3(2, 1, 1)) return 1;
            \\    if (!sub_u3(0, 1, 7)) return 1;
            \\    if (!sub_i3(2, 1, 1)) return 1;
            \\    if (!sub_i3(3, -2, -3)) return 1;
            \\    if (!sub_i3(-3, 2, 3)) return 1;
            \\    if (!sub_c_int(2, 1, 1)) return 1;
            \\    // TODO enable these when stage2 supports std.math.maxInt
            \\    //if (!sub_c_int(maxInt(c_int), -2, minInt(c_int) + 1)) return 1;
            \\    //if (!sub_c_int(minInt(c_int) + 1, 2, maxInt(c_int))) return 1;
            \\
            \\    return 0;
            \\}
            \\fn add_u3(lhs: u3, rhs: u3, expected: u3) bool {
            \\    return expected == lhs +% rhs;
            \\}
            \\fn add_i3(lhs: i3, rhs: i3, expected: i3) bool {
            \\    return expected == lhs +% rhs;
            \\}
            \\fn add_c_int(lhs: c_int, rhs: c_int, expected: c_int) bool {
            \\    return expected == lhs +% rhs;
            \\}
            \\fn sub_u3(lhs: u3, rhs: u3, expected: u3) bool {
            \\    return expected == lhs -% rhs;
            \\}
            \\fn sub_i3(lhs: i3, rhs: i3, expected: i3) bool {
            \\    return expected == lhs -% rhs;
            \\}
            \\fn sub_c_int(lhs: c_int, rhs: c_int, expected: c_int) bool {
            \\    return expected == lhs -% rhs;
            \\}
        , "");
    }

    ctx.h("simple header", linux_x64,
        \\export fn start() void{}
    ,
        \\ZIG_EXTERN_C void start(void);
        \\
    );
    ctx.h("header with single param function", linux_x64,
        \\export fn start(a: u8) void{
        \\    _ = a;
        \\}
    ,
        \\ZIG_EXTERN_C void start(uint8_t a0);
        \\
    );
    ctx.h("header with multiple param function", linux_x64,
        \\export fn start(a: u8, b: u8, c: u8) void{
        \\  _ = a; _ = b; _ = c;
        \\}
    ,
        \\ZIG_EXTERN_C void start(uint8_t a0, uint8_t a1, uint8_t a2);
        \\
    );
    ctx.h("header with u32 param function", linux_x64,
        \\export fn start(a: u32) void{ _ = a; }
    ,
        \\ZIG_EXTERN_C void start(uint32_t a0);
        \\
    );
    ctx.h("header with usize param function", linux_x64,
        \\export fn start(a: usize) void{ _ = a; }
    ,
        \\ZIG_EXTERN_C void start(uintptr_t a0);
        \\
    );
    ctx.h("header with bool param function", linux_x64,
        \\export fn start(a: bool) void{_ = a;}
    ,
        \\ZIG_EXTERN_C void start(bool a0);
        \\
    );
    ctx.h("header with noreturn function", linux_x64,
        \\export fn start() noreturn {
        \\    unreachable;
        \\}
    ,
        \\ZIG_EXTERN_C zig_noreturn void start(void);
        \\
    );
    ctx.h("header with multiple functions", linux_x64,
        \\export fn a() void{}
        \\export fn b() void{}
        \\export fn c() void{}
    ,
        \\ZIG_EXTERN_C void a(void);
        \\ZIG_EXTERN_C void b(void);
        \\ZIG_EXTERN_C void c(void);
        \\
    );
    ctx.h("header with multiple includes", linux_x64,
        \\export fn start(a: u32, b: usize) void{ _ = a; _ = b; }
    ,
        \\ZIG_EXTERN_C void start(uint32_t a0, uintptr_t a1);
        \\
    );
}
