const std = @import("std");
const os = std.os;
const tests = @import("tests.zig");

pub fn addCases(cases: *tests.CompareOutputContext) void {
    cases.addC("hello world with libc",
        \\const c = @cImport({
        \\    // See https://github.com/ziglang/zig/issues/515
        \\    @cDefine("_NO_CRT_STDIO_INLINE", "1");
        \\    @cInclude("stdio.h");
        \\});
        \\pub export fn main(argc: c_int, argv: [*][*]u8) c_int {
        \\    _ = argc;
        \\    _ = argv;
        \\    _ = c.puts("Hello, world!");
        \\    return 0;
        \\}
    , "Hello, world!" ++ std.cstr.line_sep);

    cases.addCase(x: {
        var tc = cases.create("multiple files with private function",
            \\usingnamespace @import("std").io;
            \\usingnamespace @import("foo.zig");
            \\
            \\pub fn main() void {
            \\    privateFunction();
            \\    const stdout = getStdOut().writer();
            \\    stdout.print("OK 2\n", .{}) catch unreachable;
            \\}
            \\
            \\fn privateFunction() void {
            \\    printText();
            \\}
        , "OK 1\nOK 2\n");

        tc.addSourceFile("foo.zig",
            \\usingnamespace @import("std").io;
            \\
            \\// purposefully conflicting function with main.zig
            \\// but it's private so it should be OK
            \\fn privateFunction() void {
            \\    const stdout = getStdOut().writer();
            \\    stdout.print("OK 1\n", .{}) catch unreachable;
            \\}
            \\
            \\pub fn printText() void {
            \\    privateFunction();
            \\}
        );

        break :x tc;
    });

    cases.addCase(x: {
        var tc = cases.create("import segregation",
            \\usingnamespace @import("foo.zig");
            \\usingnamespace @import("bar.zig");
            \\
            \\pub fn main() void {
            \\    foo_function();
            \\    bar_function();
            \\}
        , "OK\nOK\n");

        tc.addSourceFile("foo.zig",
            \\usingnamespace @import("std").io;
            \\pub fn foo_function() void {
            \\    const stdout = getStdOut().writer();
            \\    stdout.print("OK\n", .{}) catch unreachable;
            \\}
        );

        tc.addSourceFile("bar.zig",
            \\usingnamespace @import("other.zig");
            \\usingnamespace @import("std").io;
            \\
            \\pub fn bar_function() void {
            \\    if (foo_function()) {
            \\        const stdout = getStdOut().writer();
            \\        stdout.print("OK\n", .{}) catch unreachable;
            \\    }
            \\}
        );

        tc.addSourceFile("other.zig",
            \\pub fn foo_function() bool {
            \\    // this one conflicts with the one from foo
            \\    return true;
            \\}
        );

        break :x tc;
    });

    cases.addCase(x: {
        var tc = cases.create("two files usingnamespace import each other",
            \\usingnamespace @import("a.zig");
            \\
            \\pub fn main() void {
            \\    ok();
            \\}
        , "OK\n");

        tc.addSourceFile("a.zig",
            \\usingnamespace @import("b.zig");
            \\const io = @import("std").io;
            \\
            \\pub const a_text = "OK\n";
            \\
            \\pub fn ok() void {
            \\    const stdout = io.getStdOut().writer();
            \\    stdout.print(b_text, .{}) catch unreachable;
            \\}
        );

        tc.addSourceFile("b.zig",
            \\usingnamespace @import("a.zig");
            \\
            \\pub const b_text = a_text;
        );

        break :x tc;
    });

    cases.add("hello world without libc",
        \\const io = @import("std").io;
        \\
        \\pub fn main() void {
        \\    const stdout = io.getStdOut().writer();
        \\    stdout.print("Hello, world!\n{d:4} {x:3} {c}\n", .{@as(u32, 12), @as(u16, 0x12), @as(u8, 'a')}) catch unreachable;
        \\}
    , "Hello, world!\n  12  12 a\n");

    cases.addC("number literals",
        \\const std = @import("std");
        \\const is_windows = std.Target.current.os.tag == .windows;
        \\const c = @cImport({
        \\    if (is_windows) {
        \\        // See https://github.com/ziglang/zig/issues/515
        \\        @cDefine("_NO_CRT_STDIO_INLINE", "1");
        \\        @cInclude("io.h");
        \\        @cInclude("fcntl.h");
        \\    }
        \\    @cInclude("stdio.h");
        \\});
        \\
        \\pub export fn main(argc: c_int, argv: [*][*]u8) c_int {
        \\    _ = argc;
        \\    _ = argv;
        \\    if (is_windows) {
        \\        // we want actual \n, not \r\n
        \\        _ = c._setmode(1, c._O_BINARY);
        \\    }
        \\    _ = c.printf("0: %llu\n",
        \\             @as(u64, 0));
        \\    _ = c.printf("320402575052271: %llu\n",
        \\         @as(u64, 320402575052271));
        \\    _ = c.printf("0x01236789abcdef: %llu\n",
        \\         @as(u64, 0x01236789abcdef));
        \\    _ = c.printf("0xffffffffffffffff: %llu\n",
        \\         @as(u64, 0xffffffffffffffff));
        \\    _ = c.printf("0x000000ffffffffffffffff: %llu\n",
        \\         @as(u64, 0x000000ffffffffffffffff));
        \\    _ = c.printf("0o1777777777777777777777: %llu\n",
        \\         @as(u64, 0o1777777777777777777777));
        \\    _ = c.printf("0o0000001777777777777777777777: %llu\n",
        \\         @as(u64, 0o0000001777777777777777777777));
        \\    _ = c.printf("0b1111111111111111111111111111111111111111111111111111111111111111: %llu\n",
        \\         @as(u64, 0b1111111111111111111111111111111111111111111111111111111111111111));
        \\    _ = c.printf("0b0000001111111111111111111111111111111111111111111111111111111111111111: %llu\n",
        \\         @as(u64, 0b0000001111111111111111111111111111111111111111111111111111111111111111));
        \\
        \\    _ = c.printf("\n");
        \\
        \\    _ = c.printf("0.0: %.013a\n",
        \\         @as(f64, 0.0));
        \\    _ = c.printf("0e0: %.013a\n",
        \\         @as(f64, 0e0));
        \\    _ = c.printf("0.0e0: %.013a\n",
        \\         @as(f64, 0.0e0));
        \\    _ = c.printf("000000000000000000000000000000000000000000000000000000000.0e0: %.013a\n",
        \\         @as(f64, 000000000000000000000000000000000000000000000000000000000.0e0));
        \\    _ = c.printf("0.000000000000000000000000000000000000000000000000000000000e0: %.013a\n",
        \\         @as(f64, 0.000000000000000000000000000000000000000000000000000000000e0));
        \\    _ = c.printf("0.0e000000000000000000000000000000000000000000000000000000000: %.013a\n",
        \\         @as(f64, 0.0e000000000000000000000000000000000000000000000000000000000));
        \\    _ = c.printf("1.0: %.013a\n",
        \\         @as(f64, 1.0));
        \\    _ = c.printf("10.0: %.013a\n",
        \\         @as(f64, 10.0));
        \\    _ = c.printf("10.5: %.013a\n",
        \\         @as(f64, 10.5));
        \\    _ = c.printf("10.5e5: %.013a\n",
        \\         @as(f64, 10.5e5));
        \\    _ = c.printf("10.5e+5: %.013a\n",
        \\         @as(f64, 10.5e+5));
        \\    _ = c.printf("50.0e-2: %.013a\n",
        \\         @as(f64, 50.0e-2));
        \\    _ = c.printf("50e-2: %.013a\n",
        \\         @as(f64, 50e-2));
        \\
        \\    _ = c.printf("\n");
        \\
        \\    _ = c.printf("0x1.0: %.013a\n",
        \\         @as(f64, 0x1.0));
        \\    _ = c.printf("0x10.0: %.013a\n",
        \\         @as(f64, 0x10.0));
        \\    _ = c.printf("0x100.0: %.013a\n",
        \\         @as(f64, 0x100.0));
        \\    _ = c.printf("0x103.0: %.013a\n",
        \\         @as(f64, 0x103.0));
        \\    _ = c.printf("0x103.7: %.013a\n",
        \\         @as(f64, 0x103.7));
        \\    _ = c.printf("0x103.70: %.013a\n",
        \\         @as(f64, 0x103.70));
        \\    _ = c.printf("0x103.70p4: %.013a\n",
        \\         @as(f64, 0x103.70p4));
        \\    _ = c.printf("0x103.70p5: %.013a\n",
        \\         @as(f64, 0x103.70p5));
        \\    _ = c.printf("0x103.70p+5: %.013a\n",
        \\         @as(f64, 0x103.70p+5));
        \\    _ = c.printf("0x103.70p-5: %.013a\n",
        \\         @as(f64, 0x103.70p-5));
        \\
        \\    return 0;
        \\}
    ,
        \\0: 0
        \\320402575052271: 320402575052271
        \\0x01236789abcdef: 320402575052271
        \\0xffffffffffffffff: 18446744073709551615
        \\0x000000ffffffffffffffff: 18446744073709551615
        \\0o1777777777777777777777: 18446744073709551615
        \\0o0000001777777777777777777777: 18446744073709551615
        \\0b1111111111111111111111111111111111111111111111111111111111111111: 18446744073709551615
        \\0b0000001111111111111111111111111111111111111111111111111111111111111111: 18446744073709551615
        \\
        \\0.0: 0x0.0000000000000p+0
        \\0e0: 0x0.0000000000000p+0
        \\0.0e0: 0x0.0000000000000p+0
        \\000000000000000000000000000000000000000000000000000000000.0e0: 0x0.0000000000000p+0
        \\0.000000000000000000000000000000000000000000000000000000000e0: 0x0.0000000000000p+0
        \\0.0e000000000000000000000000000000000000000000000000000000000: 0x0.0000000000000p+0
        \\1.0: 0x1.0000000000000p+0
        \\10.0: 0x1.4000000000000p+3
        \\10.5: 0x1.5000000000000p+3
        \\10.5e5: 0x1.0059000000000p+20
        \\10.5e+5: 0x1.0059000000000p+20
        \\50.0e-2: 0x1.0000000000000p-1
        \\50e-2: 0x1.0000000000000p-1
        \\
        \\0x1.0: 0x1.0000000000000p+0
        \\0x10.0: 0x1.0000000000000p+4
        \\0x100.0: 0x1.0000000000000p+8
        \\0x103.0: 0x1.0300000000000p+8
        \\0x103.7: 0x1.0370000000000p+8
        \\0x103.70: 0x1.0370000000000p+8
        \\0x103.70p4: 0x1.0370000000000p+12
        \\0x103.70p5: 0x1.0370000000000p+13
        \\0x103.70p+5: 0x1.0370000000000p+13
        \\0x103.70p-5: 0x1.0370000000000p+3
        \\
    );

    cases.add("order-independent declarations",
        \\const io = @import("std").io;
        \\const z = io.stdin_fileno;
        \\const x : @TypeOf(y) = 1234;
        \\const y : u16 = 5678;
        \\pub fn main() void {
        \\    var x_local : i32 = print_ok(x);
        \\    _ = x_local;
        \\}
        \\fn print_ok(val: @TypeOf(x)) @TypeOf(foo) {
        \\    _ = val;
        \\    const stdout = io.getStdOut().writer();
        \\    stdout.print("OK\n", .{}) catch unreachable;
        \\    return 0;
        \\}
        \\const foo : i32 = 0;
    , "OK\n");

    cases.addC("expose function pointer to C land",
        \\const c = @cImport(@cInclude("stdlib.h"));
        \\
        \\export fn compare_fn(a: ?*const c_void, b: ?*const c_void) c_int {
        \\    const a_int = @ptrCast(*const i32, @alignCast(@alignOf(i32), a));
        \\    const b_int = @ptrCast(*const i32, @alignCast(@alignOf(i32), b));
        \\    if (a_int.* < b_int.*) {
        \\        return -1;
        \\    } else if (a_int.* > b_int.*) {
        \\        return 1;
        \\    } else {
        \\        return 0;
        \\    }
        \\}
        \\
        \\pub export fn main() c_int {
        \\    var array = [_]u32{ 1, 7, 3, 2, 0, 9, 4, 8, 6, 5 };
        \\
        \\    c.qsort(@ptrCast(?*c_void, &array), @intCast(c_ulong, array.len), @sizeOf(i32), compare_fn);
        \\
        \\    for (array) |item, i| {
        \\        if (item != i) {
        \\            c.abort();
        \\        }
        \\    }
        \\
        \\    return 0;
        \\}
    , "");

    cases.addC("casting between float and integer types",
        \\const std = @import("std");
        \\const is_windows = std.Target.current.os.tag == .windows;
        \\const c = @cImport({
        \\    if (is_windows) {
        \\        // See https://github.com/ziglang/zig/issues/515
        \\        @cDefine("_NO_CRT_STDIO_INLINE", "1");
        \\        @cInclude("io.h");
        \\        @cInclude("fcntl.h");
        \\    }
        \\    @cInclude("stdio.h");
        \\});
        \\
        \\pub export fn main(argc: c_int, argv: [*][*]u8) c_int {
        \\    _ = argc;
        \\    _ = argv;
        \\    if (is_windows) {
        \\        // we want actual \n, not \r\n
        \\        _ = c._setmode(1, c._O_BINARY);
        \\    }
        \\    const small: f32 = 3.25;
        \\    const x: f64 = small;
        \\    const y = @floatToInt(i32, x);
        \\    const z = @intToFloat(f64, y);
        \\    _ = c.printf("%.2f\n%d\n%.2f\n%.2f\n", x, y, z, @as(f64, -0.4));
        \\    return 0;
        \\}
    , "3.25\n3\n3.00\n-0.40\n");

    cases.add("same named methods in incomplete struct",
        \\const io = @import("std").io;
        \\
        \\const Foo = struct {
        \\    field1: Bar,
        \\
        \\    fn method(a: *const Foo) bool {
        \\        _ = a;
        \\        return true;
        \\    }
        \\};
        \\
        \\const Bar = struct {
        \\    field2: i32,
        \\
        \\    fn method(b: *const Bar) bool {
        \\        _ = b;
        \\        return true;
        \\    }
        \\};
        \\
        \\pub fn main() void {
        \\    const bar = Bar {.field2 = 13,};
        \\    const foo = Foo {.field1 = bar,};
        \\    const stdout = io.getStdOut().writer();
        \\    if (!foo.method()) {
        \\        stdout.print("BAD\n", .{}) catch unreachable;
        \\    }
        \\    if (!bar.method()) {
        \\        stdout.print("BAD\n", .{}) catch unreachable;
        \\    }
        \\    stdout.print("OK\n", .{}) catch unreachable;
        \\}
    , "OK\n");

    cases.add("defer with only fallthrough",
        \\const io = @import("std").io;
        \\pub fn main() void {
        \\    const stdout = io.getStdOut().writer();
        \\    stdout.print("before\n", .{}) catch unreachable;
        \\    defer stdout.print("defer1\n", .{}) catch unreachable;
        \\    defer stdout.print("defer2\n", .{}) catch unreachable;
        \\    defer stdout.print("defer3\n", .{}) catch unreachable;
        \\    stdout.print("after\n", .{}) catch unreachable;
        \\}
    , "before\nafter\ndefer3\ndefer2\ndefer1\n");

    cases.add("defer with return",
        \\const io = @import("std").io;
        \\const os = @import("std").os;
        \\pub fn main() void {
        \\    const stdout = io.getStdOut().writer();
        \\    stdout.print("before\n", .{}) catch unreachable;
        \\    defer stdout.print("defer1\n", .{}) catch unreachable;
        \\    defer stdout.print("defer2\n", .{}) catch unreachable;
        \\    var args_it = @import("std").process.args();
        \\    if (args_it.skip() and !args_it.skip()) return;
        \\    defer stdout.print("defer3\n", .{}) catch unreachable;
        \\    stdout.print("after\n", .{}) catch unreachable;
        \\}
    , "before\ndefer2\ndefer1\n");

    cases.add("errdefer and it fails",
        \\const io = @import("std").io;
        \\pub fn main() void {
        \\    do_test() catch return;
        \\}
        \\fn do_test() !void {
        \\    const stdout = io.getStdOut().writer();
        \\    stdout.print("before\n", .{}) catch unreachable;
        \\    defer stdout.print("defer1\n", .{}) catch unreachable;
        \\    errdefer stdout.print("deferErr\n", .{}) catch unreachable;
        \\    try its_gonna_fail();
        \\    defer stdout.print("defer3\n", .{}) catch unreachable;
        \\    stdout.print("after\n", .{}) catch unreachable;
        \\}
        \\fn its_gonna_fail() !void {
        \\    return error.IToldYouItWouldFail;
        \\}
    , "before\ndeferErr\ndefer1\n");

    cases.add("errdefer and it passes",
        \\const io = @import("std").io;
        \\pub fn main() void {
        \\    do_test() catch return;
        \\}
        \\fn do_test() !void {
        \\    const stdout = io.getStdOut().writer();
        \\    stdout.print("before\n", .{}) catch unreachable;
        \\    defer stdout.print("defer1\n", .{}) catch unreachable;
        \\    errdefer stdout.print("deferErr\n", .{}) catch unreachable;
        \\    try its_gonna_pass();
        \\    defer stdout.print("defer3\n", .{}) catch unreachable;
        \\    stdout.print("after\n", .{}) catch unreachable;
        \\}
        \\fn its_gonna_pass() anyerror!void { }
    , "before\nafter\ndefer3\ndefer1\n");

    cases.addCase(x: {
        var tc = cases.create("@embedFile",
            \\const foo_txt = @embedFile("foo.txt");
            \\const io = @import("std").io;
            \\
            \\pub fn main() void {
            \\    const stdout = io.getStdOut().writer();
            \\    stdout.print(foo_txt, .{}) catch unreachable;
            \\}
        , "1234\nabcd\n");

        tc.addSourceFile("foo.txt", "1234\nabcd\n");

        break :x tc;
    });

    cases.addCase(x: {
        var tc = cases.create("parsing args",
            \\const std = @import("std");
            \\const io = std.io;
            \\const os = std.os;
            \\const allocator = std.testing.allocator;
            \\
            \\pub fn main() !void {
            \\    var args_it = std.process.args();
            \\    const stdout = io.getStdOut().writer();
            \\    var index: usize = 0;
            \\    _ = args_it.skip();
            \\    while (args_it.next(allocator)) |arg_or_err| : (index += 1) {
            \\        const arg = try arg_or_err;
            \\        try stdout.print("{}: {s}\n", .{index, arg});
            \\    }
            \\}
        ,
            \\0: first arg
            \\1: 'a' 'b' \
            \\2: bare
            \\3: ba""re
            \\4: "
            \\5: last arg
            \\
        );

        tc.setCommandLineArgs(&[_][]const u8{
            "first arg",
            "'a' 'b' \\",
            "bare",
            "ba\"\"re",
            "\"",
            "last arg",
        });

        break :x tc;
    });

    cases.addCase(x: {
        var tc = cases.create("parsing args new API",
            \\const std = @import("std");
            \\const io = std.io;
            \\const os = std.os;
            \\const allocator = std.testing.allocator;
            \\
            \\pub fn main() !void {
            \\    var args_it = std.process.args();
            \\    const stdout = io.getStdOut().writer();
            \\    var index: usize = 0;
            \\    _ = args_it.skip();
            \\    while (args_it.next(allocator)) |arg_or_err| : (index += 1) {
            \\        const arg = try arg_or_err;
            \\        try stdout.print("{}: {s}\n", .{index, arg});
            \\    }
            \\}
        ,
            \\0: first arg
            \\1: 'a' 'b' \
            \\2: bare
            \\3: ba""re
            \\4: "
            \\5: last arg
            \\
        );

        tc.setCommandLineArgs(&[_][]const u8{
            "first arg",
            "'a' 'b' \\",
            "bare",
            "ba\"\"re",
            "\"",
            "last arg",
        });

        break :x tc;
    });

    // It is required to override the log function in order to print to stdout instead of stderr
    cases.add("std.log per scope log level override",
        \\const std = @import("std");
        \\
        \\pub const log_level: std.log.Level = .debug;
        \\
        \\pub const scope_levels = [_]std.log.ScopeLevel{
        \\    .{ .scope = .a, .level = .alert },
        \\    .{ .scope = .c, .level = .emerg },
        \\};
        \\
        \\const loga = std.log.scoped(.a);
        \\const logb = std.log.scoped(.b);
        \\const logc = std.log.scoped(.c);
        \\
        \\pub fn main() !void {
        \\    loga.debug("", .{});
        \\    logb.debug("", .{});
        \\    logc.debug("", .{});
        \\
        \\    loga.info("", .{});
        \\    logb.info("", .{});
        \\    logc.info("", .{});
        \\
        \\    loga.notice("", .{});
        \\    logb.notice("", .{});
        \\    logc.notice("", .{});
        \\
        \\    loga.warn("", .{});
        \\    logb.warn("", .{});
        \\    logc.warn("", .{});
        \\
        \\    loga.err("", .{});
        \\    logb.err("", .{});
        \\    logc.err("", .{});
        \\
        \\    loga.crit("", .{});
        \\    logb.crit("", .{});
        \\    logc.crit("", .{});
        \\
        \\    loga.alert("", .{});
        \\    logb.alert("", .{});
        \\    logc.alert("", .{});
        \\
        \\    loga.emerg("", .{});
        \\    logb.emerg("", .{});
        \\    logc.emerg("", .{});
        \\}
        \\pub fn log(
        \\    comptime level: std.log.Level,
        \\    comptime scope: @TypeOf(.EnumLiteral),
        \\    comptime format: []const u8,
        \\    args: anytype,
        \\) void {
        \\    const level_txt = comptime level.asText();
        \\    const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
        \\    const stdout = std.io.getStdOut().writer();
        \\    nosuspend stdout.print(level_txt ++ prefix2 ++ format ++ "\n", args) catch return;
        \\}
    ,
        \\debug(b): 
        \\info(b): 
        \\notice(b): 
        \\warning(b): 
        \\error(b): 
        \\critical(b): 
        \\alert(a): 
        \\alert(b): 
        \\emergency(a): 
        \\emergency(b): 
        \\emergency(c): 
        \\
    );

    // It is required to override the log function in order to print to stdout instead of stderr
    cases.add("std.heap.LoggingAllocator logs to std.log",
        \\const std = @import("std");
        \\
        \\pub const log_level: std.log.Level = .debug;
        \\
        \\pub fn main() !void {
        \\    var allocator_buf: [10]u8 = undefined;
        \\    var fixedBufferAllocator = std.mem.validationWrap(std.heap.FixedBufferAllocator.init(&allocator_buf));
        \\    const allocator = &std.heap.loggingAllocator(&fixedBufferAllocator.allocator).allocator;
        \\
        \\    var a = try allocator.alloc(u8, 10);
        \\    a = allocator.shrink(a, 5);
        \\    try std.testing.expect(a.len == 5);
        \\    try std.testing.expectError(error.OutOfMemory, allocator.resize(a, 20));
        \\    allocator.free(a);
        \\}
        \\
        \\pub fn log(
        \\    comptime level: std.log.Level,
        \\    comptime scope: @TypeOf(.EnumLiteral),
        \\    comptime format: []const u8,
        \\    args: anytype,
        \\) void {
        \\    const level_txt = comptime level.asText();
        \\    const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
        \\    const stdout = std.io.getStdOut().writer();
        \\    nosuspend stdout.print(level_txt ++ prefix2 ++ format ++ "\n", args) catch return;
        \\}
    ,
        \\debug: alloc - success - len: 10, ptr_align: 1, len_align: 0
        \\debug: shrink - success - 10 to 5, len_align: 0, buf_align: 1
        \\critical: expand - failure: OutOfMemory - 5 to 20, len_align: 0, buf_align: 1
        \\debug: free - success - len: 5
        \\
    );
}
