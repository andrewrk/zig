const std = @import("std");
const TestContext = @import("../src/test.zig").TestContext;

// Self-hosted has differing levels of support for various architectures. For now we pass explicit
// target parameters to each test case. At some point we will take this to the next level and have
// a set of targets that all test cases run on unless specifically overridden. For now, each test
// case applies to only the specified target.

const linux_x64 = std.zig.CrossTarget{
    .cpu_arch = .x86_64,
    .os_tag = .linux,
};

pub fn addCases(ctx: *TestContext) !void {
    try @import("compile_errors.zig").addCases(ctx);
    try @import("stage2/cbe.zig").addCases(ctx);
    try @import("stage2/arm.zig").addCases(ctx);
    try @import("stage2/aarch64.zig").addCases(ctx);
    try @import("stage2/llvm.zig").addCases(ctx);
    try @import("stage2/wasm.zig").addCases(ctx);
    try @import("stage2/darwin.zig").addCases(ctx);
    try @import("stage2/riscv64.zig").addCases(ctx);
    try @import("stage2/plan9.zig").addCases(ctx);

    {
        var case = ctx.exe("hello world with updates", linux_x64);

        case.addError("", &[_][]const u8{
            ":93:9: error: struct 'tmp.tmp' has no member named 'main'",
        });

        // Incorrect return type
        case.addError(
            \\pub export fn _start() noreturn {
            \\}
        , &[_][]const u8{":2:1: error: expected noreturn, found void"});

        // Regular old hello world
        case.addCompareOutput(
            \\pub export fn _start() noreturn {
            \\    print();
            \\
            \\    exit();
            \\}
            \\
            \\fn print() void {
            \\    asm volatile ("syscall"
            \\        :
            \\        : [number] "{rax}" (1),
            \\          [arg1] "{rdi}" (1),
            \\          [arg2] "{rsi}" (@ptrToInt("Hello, World!\n")),
            \\          [arg3] "{rdx}" (14)
            \\        : "rcx", "r11", "memory"
            \\    );
            \\    return;
            \\}
            \\
            \\fn exit() noreturn {
            \\    asm volatile ("syscall"
            \\        :
            \\        : [number] "{rax}" (231),
            \\          [arg1] "{rdi}" (0)
            \\        : "rcx", "r11", "memory"
            \\    );
            \\    unreachable;
            \\}
        ,
            "Hello, World!\n",
        );

        // Convert to pub fn main
        case.addCompareOutput(
            \\pub fn main() void {
            \\    print();
            \\}
            \\
            \\fn print() void {
            \\    asm volatile ("syscall"
            \\        :
            \\        : [number] "{rax}" (1),
            \\          [arg1] "{rdi}" (1),
            \\          [arg2] "{rsi}" (@ptrToInt("Hello, World!\n")),
            \\          [arg3] "{rdx}" (14)
            \\        : "rcx", "r11", "memory"
            \\    );
            \\    return;
            \\}
        ,
            "Hello, World!\n",
        );

        // Now change the message only
        case.addCompareOutput(
            \\pub fn main() void {
            \\    print();
            \\}
            \\
            \\fn print() void {
            \\    asm volatile ("syscall"
            \\        :
            \\        : [number] "{rax}" (1),
            \\          [arg1] "{rdi}" (1),
            \\          [arg2] "{rsi}" (@ptrToInt("What is up? This is a longer message that will force the data to be relocated in virtual address space.\n")),
            \\          [arg3] "{rdx}" (104)
            \\        : "rcx", "r11", "memory"
            \\    );
            \\    return;
            \\}
        ,
            "What is up? This is a longer message that will force the data to be relocated in virtual address space.\n",
        );
        // Now we print it twice.
        case.addCompareOutput(
            \\pub fn main() void {
            \\    print();
            \\    print();
            \\}
            \\
            \\fn print() void {
            \\    asm volatile ("syscall"
            \\        :
            \\        : [number] "{rax}" (1),
            \\          [arg1] "{rdi}" (1),
            \\          [arg2] "{rsi}" (@ptrToInt("What is up? This is a longer message that will force the data to be relocated in virtual address space.\n")),
            \\          [arg3] "{rdx}" (104)
            \\        : "rcx", "r11", "memory"
            \\    );
            \\    return;
            \\}
        ,
            \\What is up? This is a longer message that will force the data to be relocated in virtual address space.
            \\What is up? This is a longer message that will force the data to be relocated in virtual address space.
            \\
        );
    }

    {
        var case = ctx.exe("adding numbers at comptime", linux_x64);
        case.addCompareOutput(
            \\pub export fn _start() noreturn {
            \\    asm volatile ("syscall"
            \\        :
            \\        : [number] "{rax}" (1),
            \\          [arg1] "{rdi}" (1),
            \\          [arg2] "{rsi}" (@ptrToInt("Hello, World!\n")),
            \\          [arg3] "{rdx}" (10 + 4)
            \\        : "rcx", "r11", "memory"
            \\    );
            \\    asm volatile ("syscall"
            \\        :
            \\        : [number] "{rax}" (@as(usize, 230) + @as(usize, 1)),
            \\          [arg1] "{rdi}" (0)
            \\        : "rcx", "r11", "memory"
            \\    );
            \\    unreachable;
            \\}
        ,
            "Hello, World!\n",
        );
    }

    {
        var case = ctx.exe("adding numbers at runtime and comptime", linux_x64);
        case.addCompareOutput(
            \\pub export fn _start() noreturn {
            \\    add(3, 4);
            \\
            \\    exit();
            \\}
            \\
            \\fn add(a: u32, b: u32) void {
            \\    if (a + b != 7) unreachable;
            \\}
            \\
            \\fn exit() noreturn {
            \\    asm volatile ("syscall"
            \\        :
            \\        : [number] "{rax}" (231),
            \\          [arg1] "{rdi}" (0)
            \\        : "rcx", "r11", "memory"
            \\    );
            \\    unreachable;
            \\}
        ,
            "",
        );
        // comptime function call
        case.addCompareOutput(
            \\pub export fn _start() noreturn {
            \\    exit();
            \\}
            \\
            \\fn add(a: u32, b: u32) u32 {
            \\    return a + b;
            \\}
            \\
            \\const x = add(3, 4);
            \\
            \\fn exit() noreturn {
            \\    asm volatile ("syscall"
            \\        :
            \\        : [number] "{rax}" (231),
            \\          [arg1] "{rdi}" (x - 7)
            \\        : "rcx", "r11", "memory"
            \\    );
            \\    unreachable;
            \\}
        ,
            "",
        );
        // Inline function call
        case.addCompareOutput(
            \\pub export fn _start() noreturn {
            \\    var x: usize = 3;
            \\    const y = add(1, 2, x);
            \\    exit(y - 6);
            \\}
            \\
            \\fn add(a: usize, b: usize, c: usize) callconv(.Inline) usize {
            \\    return a + b + c;
            \\}
            \\
            \\fn exit(code: usize) noreturn {
            \\    asm volatile ("syscall"
            \\        :
            \\        : [number] "{rax}" (231),
            \\          [arg1] "{rdi}" (code)
            \\        : "rcx", "r11", "memory"
            \\    );
            \\    unreachable;
            \\}
        ,
            "",
        );
    }

    {
        var case = ctx.exe("subtracting numbers at runtime", linux_x64);
        case.addCompareOutput(
            \\pub fn main() void {
            \\    sub(7, 4);
            \\}
            \\
            \\fn sub(a: u32, b: u32) void {
            \\    if (a - b != 3) unreachable;
            \\}
        ,
            "",
        );
    }
    {
        var case = ctx.exe("unused vars", linux_x64);
        case.addError(
            \\pub fn main() void {
            \\    const x = 1;
            \\}
        , &.{":2:11: error: unused local constant"});
    }
    {
        var case = ctx.exe("@TypeOf", linux_x64);
        case.addCompareOutput(
            \\pub fn main() void {
            \\    var x: usize = 0;
            \\    _ = x;
            \\    const z = @TypeOf(x, @as(u128, 5));
            \\    assert(z == u128);
            \\}
            \\
            \\pub fn assert(ok: bool) void {
            \\    if (!ok) unreachable; // assertion failure
            \\}
        ,
            "",
        );
        case.addCompareOutput(
            \\pub fn main() void {
            \\    const z = @TypeOf(true);
            \\    assert(z == bool);
            \\}
            \\
            \\pub fn assert(ok: bool) void {
            \\    if (!ok) unreachable; // assertion failure
            \\}
        ,
            "",
        );
        case.addError(
            \\pub fn main() void {
            \\    _ = @TypeOf(true, 1);
            \\}
        , &[_][]const u8{
            ":2:9: error: incompatible types: 'bool' and 'comptime_int'",
            ":2:17: note: type 'bool' here",
            ":2:23: note: type 'comptime_int' here",
        });
    }

    {
        var case = ctx.exe("multiplying numbers at runtime and comptime", linux_x64);
        case.addCompareOutput(
            \\pub export fn _start() noreturn {
            \\    mul(3, 4);
            \\
            \\    exit();
            \\}
            \\
            \\fn mul(a: u32, b: u32) void {
            \\    if (a * b != 12) unreachable;
            \\}
            \\
            \\fn exit() noreturn {
            \\    asm volatile ("syscall"
            \\        :
            \\        : [number] "{rax}" (231),
            \\          [arg1] "{rdi}" (0)
            \\        : "rcx", "r11", "memory"
            \\    );
            \\    unreachable;
            \\}
        ,
            "",
        );
        // comptime function call
        case.addCompareOutput(
            \\pub fn _start() noreturn {
            \\    exit();
            \\}
            \\
            \\fn mul(a: u32, b: u32) u32 {
            \\    return a * b;
            \\}
            \\
            \\const x = mul(3, 4);
            \\
            \\fn exit() noreturn {
            \\    asm volatile ("syscall"
            \\        :
            \\        : [number] "{rax}" (231),
            \\          [arg1] "{rdi}" (x - 12)
            \\        : "rcx", "r11", "memory"
            \\    );
            \\    unreachable;
            \\}
        ,
            "",
        );
        // Inline function call
        case.addCompareOutput(
            \\pub export fn _start() noreturn {
            \\    var x: usize = 5;
            \\    const y = mul(2, 3, x);
            \\    exit(y - 30);
            \\}
            \\
            \\fn mul(a: usize, b: usize, c: usize) callconv(.Inline) usize {
            \\    return a * b * c;
            \\}
            \\
            \\fn exit(code: usize) noreturn {
            \\    asm volatile ("syscall"
            \\        :
            \\        : [number] "{rax}" (231),
            \\          [arg1] "{rdi}" (code)
            \\        : "rcx", "r11", "memory"
            \\    );
            \\    unreachable;
            \\}
        ,
            "",
        );
    }

    {
        var case = ctx.exe("assert function", linux_x64);
        case.addCompareOutput(
            \\pub fn main() void {
            \\    add(3, 4);
            \\}
            \\
            \\fn add(a: u32, b: u32) void {
            \\    assert(a + b == 7);
            \\}
            \\
            \\pub fn assert(ok: bool) void {
            \\    if (!ok) unreachable; // assertion failure
            \\}
            \\
            \\fn exit() noreturn {
            \\    asm volatile ("syscall"
            \\        :
            \\        : [number] "{rax}" (231),
            \\          [arg1] "{rdi}" (0)
            \\        : "rcx", "r11", "memory"
            \\    );
            \\    unreachable;
            \\}
        ,
            "",
        );

        // Tests copying a register. For the `c = a + b`, it has to
        // preserve both a and b, because they are both used later.
        case.addCompareOutput(
            \\pub fn main() void {
            \\    add(3, 4);
            \\}
            \\
            \\fn add(a: u32, b: u32) void {
            \\    const c = a + b; // 7
            \\    const d = a + c; // 10
            \\    const e = d + b; // 14
            \\    assert(e == 14);
            \\}
            \\
            \\pub fn assert(ok: bool) void {
            \\    if (!ok) unreachable; // assertion failure
            \\}
        ,
            "",
        );

        // More stress on the liveness detection.
        case.addCompareOutput(
            \\pub fn main() void {
            \\    add(3, 4);
            \\}
            \\
            \\fn add(a: u32, b: u32) void {
            \\    const c = a + b; // 7
            \\    const d = a + c; // 10
            \\    const e = d + b; // 14
            \\    const f = d + e; // 24
            \\    const g = e + f; // 38
            \\    const h = f + g; // 62
            \\    const i = g + h; // 100
            \\    assert(i == 100);
            \\}
            \\
            \\pub fn assert(ok: bool) void {
            \\    if (!ok) unreachable; // assertion failure
            \\}
        ,
            "",
        );

        // Requires a second move. The register allocator should figure out to re-use rax.
        case.addCompareOutput(
            \\pub fn main() void {
            \\    add(3, 4);
            \\}
            \\
            \\fn add(a: u32, b: u32) void {
            \\    const c = a + b; // 7
            \\    const d = a + c; // 10
            \\    const e = d + b; // 14
            \\    const f = d + e; // 24
            \\    const g = e + f; // 38
            \\    const h = f + g; // 62
            \\    const i = g + h; // 100
            \\    const j = i + d; // 110
            \\    assert(j == 110);
            \\}
            \\
            \\pub fn assert(ok: bool) void {
            \\    if (!ok) unreachable; // assertion failure
            \\}
        ,
            "",
        );

        // Now we test integer return values.
        case.addCompareOutput(
            \\pub fn main() void {
            \\    assert(add(3, 4) == 7);
            \\    assert(add(20, 10) == 30);
            \\}
            \\
            \\fn add(a: u32, b: u32) u32 {
            \\    return a + b;
            \\}
            \\
            \\pub fn assert(ok: bool) void {
            \\    if (!ok) unreachable; // assertion failure
            \\}
        ,
            "",
        );

        // Local mutable variables.
        case.addCompareOutput(
            \\pub fn main() void {
            \\    assert(add(3, 4) == 7);
            \\    assert(add(20, 10) == 30);
            \\}
            \\
            \\fn add(a: u32, b: u32) u32 {
            \\    var x: u32 = undefined;
            \\    x = 0;
            \\    x += a;
            \\    x += b;
            \\    return x;
            \\}
            \\
            \\pub fn assert(ok: bool) void {
            \\    if (!ok) unreachable; // assertion failure
            \\}
        ,
            "",
        );

        // Optionals
        case.addCompareOutput(
            \\pub fn main() void {
            \\    const a: u32 = 2;
            \\    const b: ?u32 = a;
            \\    const c = b.?;
            \\    if (c != 2) unreachable;
            \\}
        ,
            "",
        );

        // While loops
        case.addCompareOutput(
            \\pub fn main() void {
            \\    var i: u32 = 0;
            \\    while (i < 4) : (i += 1) print();
            \\    assert(i == 4);
            \\}
            \\
            \\fn print() void {
            \\    asm volatile ("syscall"
            \\        :
            \\        : [number] "{rax}" (1),
            \\          [arg1] "{rdi}" (1),
            \\          [arg2] "{rsi}" (@ptrToInt("hello\n")),
            \\          [arg3] "{rdx}" (6)
            \\        : "rcx", "r11", "memory"
            \\    );
            \\    return;
            \\}
            \\
            \\pub fn assert(ok: bool) void {
            \\    if (!ok) unreachable; // assertion failure
            \\}
        ,
            "hello\nhello\nhello\nhello\n",
        );

        // inline while requires the condition to be comptime known.
        case.addError(
            \\pub fn main() void {
            \\    var i: u32 = 0;
            \\    inline while (i < 4) : (i += 1) print();
            \\    assert(i == 4);
            \\}
            \\
            \\fn print() void {
            \\    asm volatile ("syscall"
            \\        :
            \\        : [number] "{rax}" (1),
            \\          [arg1] "{rdi}" (1),
            \\          [arg2] "{rsi}" (@ptrToInt("hello\n")),
            \\          [arg3] "{rdx}" (6)
            \\        : "rcx", "r11", "memory"
            \\    );
            \\    return;
            \\}
            \\
            \\pub fn assert(ok: bool) void {
            \\    if (!ok) unreachable; // assertion failure
            \\}
        , &[_][]const u8{":3:21: error: unable to resolve comptime value"});

        // Labeled blocks (no conditional branch)
        case.addCompareOutput(
            \\pub fn main() void {
            \\    assert(add(3, 4) == 20);
            \\}
            \\
            \\fn add(a: u32, b: u32) u32 {
            \\    const x: u32 = blk: {
            \\        const c = a + b; // 7
            \\        const d = a + c; // 10
            \\        const e = d + b; // 14
            \\        break :blk e;
            \\    };
            \\    const y = x + a; // 17
            \\    const z = y + a; // 20
            \\    return z;
            \\}
            \\
            \\pub fn assert(ok: bool) void {
            \\    if (!ok) unreachable; // assertion failure
            \\}
        ,
            "",
        );

        // This catches a possible bug in the logic for re-using dying operands.
        case.addCompareOutput(
            \\pub fn main() void {
            \\    assert(add(3, 4) == 116);
            \\}
            \\
            \\fn add(a: u32, b: u32) u32 {
            \\    const x: u32 = blk: {
            \\        const c = a + b; // 7
            \\        const d = a + c; // 10
            \\        const e = d + b; // 14
            \\        const f = d + e; // 24
            \\        const g = e + f; // 38
            \\        const h = f + g; // 62
            \\        const i = g + h; // 100
            \\        const j = i + d; // 110
            \\        break :blk j;
            \\    };
            \\    const y = x + a; // 113
            \\    const z = y + a; // 116
            \\    return z;
            \\}
            \\
            \\pub fn assert(ok: bool) void {
            \\    if (!ok) unreachable; // assertion failure
            \\}
        ,
            "",
        );

        // Spilling registers to the stack.
        case.addCompareOutput(
            \\pub fn main() void {
            \\    assert(add(3, 4) == 1221);
            \\    assert(mul(3, 4) == 21609);
            \\}
            \\
            \\fn add(a: u32, b: u32) u32 {
            \\    const x: u32 = blk: {
            \\        const c = a + b; // 7
            \\        const d = a + c; // 10
            \\        const e = d + b; // 14
            \\        const f = d + e; // 24
            \\        const g = e + f; // 38
            \\        const h = f + g; // 62
            \\        const i = g + h; // 100
            \\        const j = i + d; // 110
            \\        const k = i + j; // 210
            \\        const l = j + k; // 320
            \\        const m = l + c; // 327
            \\        const n = m + d; // 337
            \\        const o = n + e; // 351
            \\        const p = o + f; // 375
            \\        const q = p + g; // 413
            \\        const r = q + h; // 475
            \\        const s = r + i; // 575
            \\        const t = s + j; // 685
            \\        const u = t + k; // 895
            \\        const v = u + l; // 1215
            \\        break :blk v;
            \\    };
            \\    const y = x + a; // 1218
            \\    const z = y + a; // 1221
            \\    return z;
            \\}
            \\
            \\fn mul(a: u32, b: u32) u32 {
            \\    const x: u32 = blk: {
            \\        const c = a * a * a * a; // 81
            \\        const d = a * a * a * b; // 108
            \\        const e = a * a * b * a; // 108
            \\        const f = a * a * b * b; // 144
            \\        const g = a * b * a * a; // 108
            \\        const h = a * b * a * b; // 144
            \\        const i = a * b * b * a; // 144
            \\        const j = a * b * b * b; // 192
            \\        const k = b * a * a * a; // 108
            \\        const l = b * a * a * b; // 144
            \\        const m = b * a * b * a; // 144
            \\        const n = b * a * b * b; // 192
            \\        const o = b * b * a * a; // 144
            \\        const p = b * b * a * b; // 192
            \\        const q = b * b * b * a; // 192
            \\        const r = b * b * b * b; // 256
            \\        const s = c + d + e + f + g + h + i + j + k + l + m + n + o + p + q + r; // 2401
            \\        break :blk s;
            \\    };
            \\    const y = x * a; // 7203
            \\    const z = y * a; // 21609
            \\    return z;
            \\}
            \\
            \\pub fn assert(ok: bool) void {
            \\    if (!ok) unreachable; // assertion failure
            \\}
        ,
            "",
        );

        // Reusing the registers of dead operands playing nicely with conditional branching.
        case.addCompareOutput(
            \\pub fn main() void {
            \\    assert(add(3, 4) == 791);
            \\    assert(add(4, 3) == 79);
            \\}
            \\
            \\fn add(a: u32, b: u32) u32 {
            \\    const x: u32 = if (a < b) blk: {
            \\        const c = a + b; // 7
            \\        const d = a + c; // 10
            \\        const e = d + b; // 14
            \\        const f = d + e; // 24
            \\        const g = e + f; // 38
            \\        const h = f + g; // 62
            \\        const i = g + h; // 100
            \\        const j = i + d; // 110
            \\        const k = i + j; // 210
            \\        const l = k + c; // 217
            \\        const m = l + d; // 227
            \\        const n = m + e; // 241
            \\        const o = n + f; // 265
            \\        const p = o + g; // 303
            \\        const q = p + h; // 365
            \\        const r = q + i; // 465
            \\        const s = r + j; // 575
            \\        const t = s + k; // 785
            \\        break :blk t;
            \\    } else blk: {
            \\        const t = b + b + a; // 10
            \\        const c = a + t; // 14
            \\        const d = c + t; // 24
            \\        const e = d + t; // 34
            \\        const f = e + t; // 44
            \\        const g = f + t; // 54
            \\        const h = c + g; // 68
            \\        break :blk h + b; // 71
            \\    };
            \\    const y = x + a; // 788, 75
            \\    const z = y + a; // 791, 79
            \\    return z;
            \\}
            \\
            \\pub fn assert(ok: bool) void {
            \\    if (!ok) unreachable; // assertion failure
            \\}
        ,
            "",
        );

        // Character literals and multiline strings.
        case.addCompareOutput(
            \\pub fn main() void {
            \\    const ignore =
            \\        \\ cool thx
            \\        \\
            \\    ;
            \\    _ = ignore;
            \\    add('ぁ', '\x03');
            \\}
            \\
            \\fn add(a: u32, b: u32) void {
            \\    assert(a + b == 12356);
            \\}
            \\
            \\pub fn assert(ok: bool) void {
            \\    if (!ok) unreachable; // assertion failure
            \\}
        ,
            "",
        );

        // Global const.
        case.addCompareOutput(
            \\pub fn main() void {
            \\    add(aa, bb);
            \\}
            \\
            \\const aa = 'ぁ';
            \\const bb = '\x03';
            \\
            \\fn add(a: u32, b: u32) void {
            \\    assert(a + b == 12356);
            \\}
            \\
            \\pub fn assert(ok: bool) void {
            \\    if (!ok) unreachable; // assertion failure
            \\}
        ,
            "",
        );

        // Array access.
        case.addCompareOutput(
            \\pub fn main() void {
            \\    assert("hello"[0] == 'h');
            \\}
            \\
            \\pub fn assert(ok: bool) void {
            \\    if (!ok) unreachable; // assertion failure
            \\}
        ,
            "",
        );

        // Array access to a global array.
        case.addCompareOutput(
            \\const hello = "hello".*;
            \\pub fn main() void {
            \\    assert(hello[1] == 'e');
            \\}
            \\
            \\pub fn assert(ok: bool) void {
            \\    if (!ok) unreachable; // assertion failure
            \\}
        ,
            "",
        );

        // 64bit set stack
        case.addCompareOutput(
            \\pub fn main() void {
            \\    var i: u64 = 0xFFEEDDCCBBAA9988;
            \\    assert(i == 0xFFEEDDCCBBAA9988);
            \\}
            \\
            \\pub fn assert(ok: bool) void {
            \\    if (!ok) unreachable; // assertion failure
            \\}
        ,
            "",
        );

        // Basic for loop
        case.addCompareOutput(
            \\pub fn main() void {
            \\    for ("hello") |_| print();
            \\}
            \\
            \\fn print() void {
            \\    asm volatile ("syscall"
            \\        :
            \\        : [number] "{rax}" (1),
            \\          [arg1] "{rdi}" (1),
            \\          [arg2] "{rsi}" (@ptrToInt("hello\n")),
            \\          [arg3] "{rdx}" (6)
            \\        : "rcx", "r11", "memory"
            \\    );
            \\    return;
            \\}
        ,
            "hello\nhello\nhello\nhello\nhello\n",
        );
    }

    {
        var case = ctx.exe("basic import", linux_x64);
        case.addCompareOutput(
            \\pub fn main() void {
            \\    @import("print.zig").print();
            \\}
        ,
            "Hello, World!\n",
        );
        try case.files.append(.{
            .src = 
            \\pub fn print() void {
            \\    asm volatile ("syscall"
            \\        :
            \\        : [number] "{rax}" (@as(usize, 1)),
            \\          [arg1] "{rdi}" (@as(usize, 1)),
            \\          [arg2] "{rsi}" (@ptrToInt("Hello, World!\n")),
            \\          [arg3] "{rdx}" (@as(usize, 14))
            \\        : "rcx", "r11", "memory"
            \\    );
            \\    return;
            \\}
            ,
            .path = "print.zig",
        });
    }
    {
        var case = ctx.exe("redundant comptime", linux_x64);
        case.addError(
            \\pub fn main() void {
            \\    var a: comptime u32 = 0;
            \\}
        ,
            &.{":2:12: error: redundant comptime keyword in already comptime scope"},
        );
        case.addError(
            \\pub fn main() void {
            \\    comptime {
            \\        var a: u32 = comptime 0;
            \\    }
            \\}
        ,
            &.{":3:22: error: redundant comptime keyword in already comptime scope"},
        );
    }
    {
        var case = ctx.exe("try in comptime in struct in test", linux_x64);
        case.addError(
            \\test "@unionInit on union w/ tag but no fields" {
            \\    const S = struct {
            \\        comptime {
            \\            try expect(false);
            \\        }
            \\    };
            \\    _ = S;
            \\}
        ,
            &.{":4:13: error: 'try' outside function scope"},
        );
    }
    {
        var case = ctx.exe("import private", linux_x64);
        case.addError(
            \\pub fn main() void {
            \\    @import("print.zig").print();
            \\}
        ,
            &.{
                ":2:25: error: 'print' is not marked 'pub'",
                "print.zig:2:1: note: declared here",
            },
        );
        try case.files.append(.{
            .src = 
            \\// dummy comment to make print be on line 2
            \\fn print() void {
            \\    asm volatile ("syscall"
            \\        :
            \\        : [number] "{rax}" (@as(usize, 1)),
            \\          [arg1] "{rdi}" (@as(usize, 1)),
            \\          [arg2] "{rsi}" (@ptrToInt("Hello, World!\n")),
            \\          [arg3] "{rdx}" (@as(usize, 14))
            \\        : "rcx", "r11", "memory"
            \\    );
            \\    return;
            \\}
            ,
            .path = "print.zig",
        });
    }

    ctx.compileError("function redeclaration", linux_x64,
        \\// dummy comment
        \\fn entry() void {}
        \\fn entry() void {}
        \\
        \\fn foo() void {
        \\    var foo = 1234;
        \\}
    , &[_][]const u8{
        ":3:1: error: redeclaration of 'entry'",
        ":2:1: note: other declaration here",
        ":6:9: error: local shadows declaration of 'foo'",
        ":5:1: note: declared here",
    });

    ctx.compileError("returns in try", linux_x64,
        \\pub fn main() !void {
        \\	try a();
        \\	try b();
        \\}
        \\
        \\pub fn a() !void {
        \\	defer try b();
        \\}
        \\pub fn b() !void {
        \\	defer return a();
        \\}
    , &[_][]const u8{
        ":7:8: error: 'try' not allowed inside defer expression",
        ":10:8: error: cannot return from defer expression",
    });

    ctx.compileError("ambiguous references", linux_x64,
        \\const T = struct {
        \\    const T = struct {
        \\        fn f() void {
        \\            _ = T;
        \\        }
        \\    };
        \\};
    , &.{
        ":4:17: error: ambiguous reference",
        ":1:1: note: declared here",
        ":2:5: note: also declared here",
    });

    ctx.compileError("inner func accessing outer var", linux_x64,
        \\pub fn f() void {
        \\    var bar: bool = true;
        \\    const S = struct {
        \\        fn baz() bool {
        \\            return bar;
        \\        }
        \\    };
        \\    _ = S;
        \\}
    , &.{
        ":5:20: error: 'bar' not accessible from inner function",
        ":2:9: note: declared here",
    });

    ctx.compileError("global variable redeclaration", linux_x64,
        \\// dummy comment
        \\var foo = false;
        \\var foo = true;
    , &[_][]const u8{
        ":3:1: error: redeclaration of 'foo'",
        ":2:1: note: other declaration here",
    });

    ctx.compileError("compileError", linux_x64,
        \\export fn foo() void {
        \\  @compileError("this is an error");
        \\}
    , &[_][]const u8{":2:3: error: this is an error"});

    {
        var case = ctx.exe("intToPtr", linux_x64);
        case.addError(
            \\pub fn main() void {
            \\    _ = @intToPtr(*u8, 0);
            \\}
        , &[_][]const u8{
            ":2:24: error: pointer type '*u8' does not allow address zero",
        });
        case.addError(
            \\pub fn main() void {
            \\    _ = @intToPtr(*u32, 2);
            \\}
        , &[_][]const u8{
            ":2:25: error: pointer type '*u32' requires aligned address",
        });
    }

    {
        var case = ctx.obj("variable shadowing", linux_x64);
        case.addError(
            \\pub fn main() void {
            \\    var i: u32 = 10;
            \\    var i: u32 = 10;
            \\}
        , &[_][]const u8{
            ":3:9: error: redeclaration of local variable 'i'",
            ":2:9: note: previous declaration here",
        });
        case.addError(
            \\var testing: i64 = 10;
            \\pub fn main() void {
            \\    var testing: i64 = 20;
            \\}
        , &[_][]const u8{
            ":3:9: error: local shadows declaration of 'testing'",
            ":1:1: note: declared here",
        });
        case.addError(
            \\fn a() type {
            \\    return struct {
            \\        pub fn b() void {
            \\            const c = 6;
            \\            const c = 69;
            \\        }
            \\    };
            \\}
        , &[_][]const u8{
            ":5:19: error: redeclaration of local constant 'c'",
            ":4:19: note: previous declaration here",
        });
    }

    {
        // TODO make the test harness support checking the compile log output too
        var case = ctx.obj("@compileLog", linux_x64);
        // The other compile error prevents emission of a "found compile log" statement.
        case.addError(
            \\export fn _start() noreturn {
            \\    const b = true;
            \\    var f: u32 = 1;
            \\    @compileLog(b, 20, f, x);
            \\    @compileLog(1000);
            \\    var bruh: usize = true;
            \\    _ = bruh;
            \\    unreachable;
            \\}
            \\export fn other() void {
            \\    @compileLog(1234);
            \\}
            \\fn x() void {}
        , &[_][]const u8{
            ":6:23: error: expected usize, found bool",
        });

        // Now only compile log statements remain. One per Decl.
        case.addError(
            \\export fn _start() noreturn {
            \\    const b = true;
            \\    var f: u32 = 1;
            \\    @compileLog(b, 20, f, x);
            \\    @compileLog(1000);
            \\    unreachable;
            \\}
            \\export fn other() void {
            \\    @compileLog(1234);
            \\}
            \\fn x() void {}
        , &[_][]const u8{
            ":9:5: error: found compile log statement",
            ":4:5: note: also here",
        });
    }

    {
        var case = ctx.obj("extern variable has no type", linux_x64);
        case.addError(
            \\comptime {
            \\    _ = foo;
            \\}
            \\extern var foo: i32;
        , &[_][]const u8{":2:9: error: unable to resolve comptime value"});
        case.addError(
            \\export fn entry() void {
            \\    _ = foo;
            \\}
            \\extern var foo;
        , &[_][]const u8{":4:8: error: unable to infer variable type"});
    }

    {
        var case = ctx.exe("break/continue", linux_x64);

        // Break out of loop
        case.addCompareOutput(
            \\pub fn main() void {
            \\    while (true) {
            \\        break;
            \\    }
            \\}
        ,
            "",
        );
        case.addCompareOutput(
            \\pub fn main() void {
            \\    foo: while (true) {
            \\        break :foo;
            \\    }
            \\}
        ,
            "",
        );

        // Continue in loop
        case.addCompareOutput(
            \\pub export fn _start() noreturn {
            \\    var i: u64 = 0;
            \\    while (true) : (i+=1) {
            \\        if (i == 4) exit();
            \\        continue;
            \\    }
            \\}
            \\
            \\fn exit() noreturn {
            \\    asm volatile ("syscall"
            \\        :
            \\        : [number] "{rax}" (231),
            \\          [arg1] "{rdi}" (0)
            \\        : "rcx", "r11", "memory"
            \\    );
            \\    unreachable;
            \\}
        ,
            "",
        );
        case.addCompareOutput(
            \\pub export fn _start() noreturn {
            \\    var i: u64 = 0;
            \\    foo: while (true) : (i+=1) {
            \\        if (i == 4) exit();
            \\        continue :foo;
            \\    }
            \\}
            \\
            \\fn exit() noreturn {
            \\    asm volatile ("syscall"
            \\        :
            \\        : [number] "{rax}" (231),
            \\          [arg1] "{rdi}" (0)
            \\        : "rcx", "r11", "memory"
            \\    );
            \\    unreachable;
            \\}
        ,
            "",
        );
    }

    {
        var case = ctx.exe("unused labels", linux_x64);
        case.addError(
            \\comptime {
            \\    foo: {}
            \\}
        , &[_][]const u8{":2:5: error: unused block label"});
        case.addError(
            \\comptime {
            \\    foo: while (true) {}
            \\}
        , &[_][]const u8{":2:5: error: unused while loop label"});
        case.addError(
            \\comptime {
            \\    foo: for ("foo") |_| {}
            \\}
        , &[_][]const u8{":2:5: error: unused for loop label"});
        case.addError(
            \\comptime {
            \\    blk: {blk: {}}
            \\}
        , &[_][]const u8{
            ":2:11: error: redefinition of label 'blk'",
            ":2:5: note: previous definition here",
        });
    }

    {
        var case = ctx.exe("bad inferred variable type", linux_x64);
        case.addError(
            \\pub fn main() void {
            \\    var x = null;
            \\    _ = x;
            \\}
        , &[_][]const u8{
            ":2:9: error: variable of type '@Type(.Null)' must be const or comptime",
        });
    }

    {
        var case = ctx.exe("compile error in inline fn call fixed", linux_x64);
        case.addError(
            \\pub export fn _start() noreturn {
            \\    var x: usize = 3;
            \\    const y = add(10, 2, x);
            \\    exit(y - 6);
            \\}
            \\
            \\fn add(a: usize, b: usize, c: usize) callconv(.Inline) usize {
            \\    if (a == 10) @compileError("bad");
            \\    return a + b + c;
            \\}
            \\
            \\fn exit(code: usize) noreturn {
            \\    asm volatile ("syscall"
            \\        :
            \\        : [number] "{rax}" (231),
            \\          [arg1] "{rdi}" (code)
            \\        : "rcx", "r11", "memory"
            \\    );
            \\    unreachable;
            \\}
        , &[_][]const u8{":8:18: error: bad"});

        case.addCompareOutput(
            \\pub export fn _start() noreturn {
            \\    var x: usize = 3;
            \\    const y = add(1, 2, x);
            \\    exit(y - 6);
            \\}
            \\
            \\fn add(a: usize, b: usize, c: usize) callconv(.Inline) usize {
            \\    if (a == 10) @compileError("bad");
            \\    return a + b + c;
            \\}
            \\
            \\fn exit(code: usize) noreturn {
            \\    asm volatile ("syscall"
            \\        :
            \\        : [number] "{rax}" (231),
            \\          [arg1] "{rdi}" (code)
            \\        : "rcx", "r11", "memory"
            \\    );
            \\    unreachable;
            \\}
        ,
            "",
        );
    }
    {
        var case = ctx.exe("recursive inline function", linux_x64);
        case.addCompareOutput(
            \\pub export fn _start() noreturn {
            \\    const y = fibonacci(7);
            \\    exit(y - 21);
            \\}
            \\
            \\fn fibonacci(n: usize) callconv(.Inline) usize {
            \\    if (n <= 2) return n;
            \\    return fibonacci(n - 2) + fibonacci(n - 1);
            \\}
            \\
            \\fn exit(code: usize) noreturn {
            \\    asm volatile ("syscall"
            \\        :
            \\        : [number] "{rax}" (231),
            \\          [arg1] "{rdi}" (code)
            \\        : "rcx", "r11", "memory"
            \\    );
            \\    unreachable;
            \\}
        ,
            "",
        );
        // This additionally tests that the compile error reports the correct source location.
        // Without storing source locations relative to the owner decl, the compile error
        // here would be off by 2 bytes (from the "7" -> "999").
        case.addError(
            \\pub export fn _start() noreturn {
            \\    const y = fibonacci(999);
            \\    exit(y - 21);
            \\}
            \\
            \\fn fibonacci(n: usize) callconv(.Inline) usize {
            \\    if (n <= 2) return n;
            \\    return fibonacci(n - 2) + fibonacci(n - 1);
            \\}
            \\
            \\fn exit(code: usize) noreturn {
            \\    asm volatile ("syscall"
            \\        :
            \\        : [number] "{rax}" (231),
            \\          [arg1] "{rdi}" (code)
            \\        : "rcx", "r11", "memory"
            \\    );
            \\    unreachable;
            \\}
        , &[_][]const u8{":8:21: error: evaluation exceeded 1000 backwards branches"});
    }
    {
        var case = ctx.exe("orelse at comptime", linux_x64);
        case.addCompareOutput(
            \\pub fn main() void {
            \\    const i: ?u64 = 0;
            \\    const result = i orelse 5;
            \\    assert(result == 0);
            \\}
            \\fn assert(b: bool) void {
            \\    if (!b) unreachable;
            \\}
        ,
            "",
        );
        case.addCompareOutput(
            \\pub fn main() void {
            \\    const i: ?u64 = null;
            \\    const result = i orelse 5;
            \\    assert(result == 5);
            \\}
            \\fn assert(b: bool) void {
            \\    if (!b) unreachable;
            \\}
        ,
            "",
        );
    }

    {
        var case = ctx.exe("only 1 function and it gets updated", linux_x64);
        case.addCompareOutput(
            \\pub export fn _start() noreturn {
            \\    asm volatile ("syscall"
            \\        :
            \\        : [number] "{rax}" (60), // exit
            \\          [arg1] "{rdi}" (0)
            \\        : "rcx", "r11", "memory"
            \\    );
            \\    unreachable;
            \\}
        ,
            "",
        );
        case.addCompareOutput(
            \\pub export fn _start() noreturn {
            \\    asm volatile ("syscall"
            \\        :
            \\        : [number] "{rax}" (231), // exit_group
            \\          [arg1] "{rdi}" (0)
            \\        : "rcx", "r11", "memory"
            \\    );
            \\    unreachable;
            \\}
        ,
            "",
        );
    }
    {
        var case = ctx.exe("passing u0 to function", linux_x64);
        case.addCompareOutput(
            \\pub fn main() void {
            \\    doNothing(0);
            \\}
            \\fn doNothing(arg: u0) void {
            \\    _ = arg;
            \\}
        ,
            "",
        );
    }
    {
        var case = ctx.exe("catch at comptime", linux_x64);
        case.addCompareOutput(
            \\pub fn main() void {
            \\    const i: anyerror!u64 = 0;
            \\    const caught = i catch 5;
            \\    assert(caught == 0);
            \\}
            \\fn assert(b: bool) void {
            \\    if (!b) unreachable;
            \\}
        ,
            "",
        );

        case.addCompareOutput(
            \\pub fn main() void {
            \\    const i: anyerror!u64 = error.B;
            \\    const caught = i catch 5;
            \\    assert(caught == 5);
            \\}
            \\fn assert(b: bool) void {
            \\    if (!b) unreachable;
            \\}
        ,
            "",
        );

        case.addCompareOutput(
            \\pub fn main() void {
            \\    const a: anyerror!comptime_int = 42;
            \\    const b: *const comptime_int = &(a catch unreachable);
            \\    assert(b.* == 42);
            \\}
            \\fn assert(b: bool) void {
            \\    if (!b) unreachable; // assertion failure
            \\}
        , "");

        case.addCompareOutput(
            \\pub fn main() void {
            \\    const a: anyerror!u32 = error.B;
            \\    _ = &(a catch |err| assert(err == error.B));
            \\}
            \\fn assert(b: bool) void {
            \\    if (!b) unreachable;
            \\}
        , "");

        case.addCompareOutput(
            \\pub fn main() void {
            \\    const a: anyerror!u32 = error.Bar;
            \\    a catch |err| assert(err == error.Bar);
            \\}
            \\fn assert(b: bool) void {
            \\    if (!b) unreachable;
            \\}
        , "");
    }
    {
        var case = ctx.exe("merge error sets", linux_x64);

        case.addCompareOutput(
            \\pub fn main() void {
            \\    const E = error{ A, B, D } || error { A, B, C };
            \\    E.A catch {};
            \\    E.B catch {};
            \\    E.C catch {};
            \\    E.D catch {};
            \\    const E2 = error { X, Y } || @TypeOf(error.Z);
            \\    E2.X catch {};
            \\    E2.Y catch {};
            \\    E2.Z catch {};
            \\    assert(anyerror || error { Z } == anyerror);
            \\}
            \\fn assert(b: bool) void {
            \\    if (!b) unreachable;
            \\}
        ,
            "",
        );
        case.addError(
            \\pub fn main() void {
            \\    const z = true || false;
            \\    _ = z;
            \\}
        , &.{
            ":2:15: error: expected error set type, found 'bool'",
            ":2:20: note: '||' merges error sets; 'or' performs boolean OR",
        });
    }
    {
        var case = ctx.exe("inline assembly", linux_x64);

        case.addError(
            \\pub fn main() void {
            \\    const number = 1234;
            \\    const x = asm volatile ("syscall"
            \\        : [o] "{rax}" (-> number)
            \\        : [number] "{rax}" (231),
            \\          [arg1] "{rdi}" (code)
            \\        : "rcx", "r11", "memory"
            \\    );
            \\    _ = x;
            \\}
        , &[_][]const u8{":4:27: error: expected type, found comptime_int"});
        case.addError(
            \\const S = struct {
            \\    comptime {
            \\        asm volatile (
            \\            \\zig_moment:
            \\            \\syscall
            \\        );
            \\    }
            \\};
            \\pub fn main() void {
            \\    _ = S;
            \\}
        , &.{":3:13: error: volatile is meaningless on global assembly"});
        case.addError(
            \\pub fn main() void {
            \\    var bruh: u32 = 1;
            \\    asm (""
            \\        :
            \\        : [bruh] "{rax}" (4)
            \\        : "memory"
            \\    );
            \\}
        , &.{":3:5: error: assembly expression with no output must be marked volatile"});
        case.addError(
            \\pub fn main() void {}
            \\comptime {
            \\    asm (""
            \\        :
            \\        : [bruh] "{rax}" (4)
            \\        : "memory"
            \\    );
            \\}
        , &.{":3:5: error: global assembly cannot have inputs, outputs, or clobbers"});
    }
    {
        var case = ctx.exe("comptime var", linux_x64);

        case.addError(
            \\pub fn main() void {
            \\    var a: u32 = 0;
            \\    comptime var b: u32 = 0;
            \\    if (a == 0) b = 3;
            \\}
        , &.{
            ":4:21: error: store to comptime variable depends on runtime condition",
            ":4:11: note: runtime condition here",
        });

        case.addError(
            \\pub fn main() void {
            \\    var a: u32 = 0;
            \\    comptime var b: u32 = 0;
            \\    switch (a) {
            \\        0 => {},
            \\        else => b = 3,
            \\    }
            \\}
        , &.{
            ":6:21: error: store to comptime variable depends on runtime condition",
            ":4:13: note: runtime condition here",
        });

        case.addCompareOutput(
            \\pub fn main() void {
            \\    comptime var len: u32 = 5;
            \\    print(len);
            \\    len += 9;
            \\    print(len);
            \\}
            \\
            \\fn print(len: usize) void {
            \\    asm volatile ("syscall"
            \\        :
            \\        : [number] "{rax}" (1),
            \\          [arg1] "{rdi}" (1),
            \\          [arg2] "{rsi}" (@ptrToInt("Hello, World!\n")),
            \\          [arg3] "{rdx}" (len)
            \\        : "rcx", "r11", "memory"
            \\    );
            \\    return;
            \\}
        , "HelloHello, World!\n");

        case.addError(
            \\comptime {
            \\    var x: i32 = 1;
            \\    x += 1;
            \\    if (x != 1) unreachable;
            \\}
            \\pub fn main() void {}
        , &.{":4:17: error: unable to resolve comptime value"});

        case.addError(
            \\pub fn main() void {
            \\    comptime var i: u64 = 0;
            \\    while (i < 5) : (i += 1) {}
            \\}
        , &.{
            ":3:24: error: cannot store to comptime variable in non-inline loop",
            ":3:5: note: non-inline loop here",
        });

        case.addCompareOutput(
            \\pub fn main() void {
            \\    var a: u32 = 0;
            \\    if (a == 0) {
            \\        comptime var b: u32 = 0;
            \\        b = 1;
            \\    }
            \\}
            \\comptime {
            \\    var x: i32 = 1;
            \\    x += 1;
            \\    if (x != 2) unreachable;
            \\}
        , "");

        case.addCompareOutput(
            \\pub fn main() void {
            \\    comptime var i: u64 = 2;
            \\    inline while (i < 6) : (i+=1) {
            \\        print(i);
            \\    }
            \\}
            \\fn print(len: usize) void {
            \\    asm volatile ("syscall"
            \\        :
            \\        : [number] "{rax}" (1),
            \\          [arg1] "{rdi}" (1),
            \\          [arg2] "{rsi}" (@ptrToInt("Hello")),
            \\          [arg3] "{rdx}" (len)
            \\        : "rcx", "r11", "memory"
            \\    );
            \\    return;
            \\}
        , "HeHelHellHello");
    }

    {
        var case = ctx.exe("double ampersand", linux_x64);

        case.addError(
            \\pub const a = if (true && false) 1 else 2;
        , &[_][]const u8{":1:24: error: `&&` is invalid; note that `and` is boolean AND"});

        case.addError(
            \\pub fn main() void {
            \\    const a = true;
            \\    const b = false;
            \\    _ = a & &b;
            \\}
        , &[_][]const u8{
            ":4:11: error: incompatible types: 'bool' and '*const bool'",
            ":4:9: note: type 'bool' here",
            ":4:13: note: type '*const bool' here",
        });

        case.addCompareOutput(
            \\pub fn main() void {
            \\    const b: u8 = 1;
            \\    _ = &&b;
            \\}
        , "");
    }
}
