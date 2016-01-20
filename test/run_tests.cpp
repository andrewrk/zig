/*
 * Copyright (c) 2015 Andrew Kelley
 *
 * This file is part of zig, which is MIT licensed.
 * See http://opensource.org/licenses/MIT
 */

#include "list.hpp"
#include "buffer.hpp"
#include "os.hpp"

#include <stdio.h>
#include <stdarg.h>

struct TestSourceFile {
    const char *relative_path;
    const char *source_code;
};

struct TestCase {
    const char *case_name;
    const char *output;
    ZigList<TestSourceFile> source_files;
    ZigList<const char *> compile_errors;
    ZigList<const char *> compiler_args;
    ZigList<const char *> program_args;
};

static ZigList<TestCase*> test_cases = {0};
static const char *tmp_source_path = ".tmp_source.zig";
static const char *tmp_exe_path = "./.tmp_exe";
static const char *zig_exe = "./zig";

static void add_source_file(TestCase *test_case, const char *path, const char *source) {
    test_case->source_files.add_one();
    test_case->source_files.last().relative_path = path;
    test_case->source_files.last().source_code = source;
}

static TestCase *add_simple_case(const char *case_name, const char *source, const char *output) {
    TestCase *test_case = allocate<TestCase>(1);
    test_case->case_name = case_name;
    test_case->output = output;

    test_case->source_files.resize(1);
    test_case->source_files.at(0).relative_path = tmp_source_path;
    test_case->source_files.at(0).source_code = source;

    test_case->compiler_args.append("build");
    test_case->compiler_args.append(tmp_source_path);
    test_case->compiler_args.append("--export");
    test_case->compiler_args.append("exe");
    test_case->compiler_args.append("--name");
    test_case->compiler_args.append("test");
    test_case->compiler_args.append("--output");
    test_case->compiler_args.append(tmp_exe_path);
    test_case->compiler_args.append("--release");
    test_case->compiler_args.append("--strip");
    test_case->compiler_args.append("--color");
    test_case->compiler_args.append("on");

    test_cases.append(test_case);

    return test_case;
}

static TestCase *add_compile_fail_case(const char *case_name, const char *source, int count, ...) {
    va_list ap;
    va_start(ap, count);

    TestCase *test_case = allocate<TestCase>(1);
    test_case->case_name = case_name;
    test_case->source_files.resize(1);
    test_case->source_files.at(0).relative_path = tmp_source_path;
    test_case->source_files.at(0).source_code = source;

    for (int i = 0; i < count; i += 1) {
        const char *arg = va_arg(ap, const char *);
        test_case->compile_errors.append(arg);
    }

    test_case->compiler_args.append("build");
    test_case->compiler_args.append(tmp_source_path);
    test_case->compiler_args.append("--output");
    test_case->compiler_args.append(tmp_exe_path);
    test_case->compiler_args.append("--release");
    test_case->compiler_args.append("--strip");
    //test_case->compiler_args.append("--verbose");

    test_cases.append(test_case);

    va_end(ap);

    return test_case;
}

static void add_compiling_test_cases(void) {
    add_simple_case("hello world with libc", R"SOURCE(
#link("c")
extern {
    fn puts(s: &const u8) i32;
}

export fn main(argc: i32, argv: &&u8) i32 => {
    puts(c"Hello, world!");
    return 0;
}
    )SOURCE", "Hello, world!\n");

    add_simple_case("function call", R"SOURCE(
import "std.zig";
import "syscall.zig";

fn empty_function_1() => {}
fn empty_function_2() => { return; }

pub fn main(args: [][]u8) i32 => {
    empty_function_1();
    empty_function_2();
    this_is_a_function();
}

fn this_is_a_function() unreachable => {
    print_str("OK\n");
    exit(0);
}
    )SOURCE", "OK\n");

    add_simple_case("comments", R"SOURCE(
import "std.zig";

/**
    * multi line doc comment
    */
fn another_function() => {}

/// this is a documentation comment
/// doc comment line 2
pub fn main(args: [][]u8) i32 => {
    print_str(/* mid-line comment /* nested */ */ "OK\n");
    return 0;
}
    )SOURCE", "OK\n");

    {
        TestCase *tc = add_simple_case("multiple files with private function", R"SOURCE(
import "std.zig";
import "foo.zig";

pub fn main(args: [][]u8) i32 => {
    private_function();
    print_str("OK 2\n");
    return 0;
}

fn private_function() => {
    print_text();
}
        )SOURCE", "OK 1\nOK 2\n");

        add_source_file(tc, "foo.zig", R"SOURCE(
import "std.zig";

// purposefully conflicting function with main.zig
// but it's private so it should be OK
fn private_function() => {
    print_str("OK 1\n");
}

pub fn print_text() => {
    private_function();
}
        )SOURCE");
    }

    {
        TestCase *tc = add_simple_case("import segregation", R"SOURCE(
import "foo.zig";
import "bar.zig";

pub fn main(args: [][]u8) i32 => {
    foo_function();
    bar_function();
    return 0;
}
        )SOURCE", "OK\nOK\n");

        add_source_file(tc, "foo.zig", R"SOURCE(
import "std.zig";
pub fn foo_function() => {
    print_str("OK\n");
}
        )SOURCE");

        add_source_file(tc, "bar.zig", R"SOURCE(
import "other.zig";
import "std.zig";

pub fn bar_function() => {
    if (foo_function()) {
        print_str("OK\n");
    }
}
        )SOURCE");

        add_source_file(tc, "other.zig", R"SOURCE(
pub fn foo_function() bool => {
    // this one conflicts with the one from foo
    return true;
}
        )SOURCE");
    }

    add_simple_case("if statements", R"SOURCE(
import "std.zig";

pub fn main(args: [][]u8) i32 => {
    if (1 != 0) {
        print_str("1 is true\n");
    } else {
        print_str("1 is false\n");
    }
    if (0 != 0) {
        print_str("0 is true\n");
    } else if (1 - 1 != 0) {
        print_str("1 - 1 is true\n");
    }
    if (!(0 != 0)) {
        print_str("!0 is true\n");
    }
    return 0;
}
    )SOURCE", "1 is true\n!0 is true\n");

    add_simple_case("params", R"SOURCE(
import "std.zig";

fn add(a: i32, b: i32) i32 => {
    a + b
}

pub fn main(args: [][]u8) i32 => {
    if (add(22, 11) == 33) {
        print_str("pass\n");
    }
    return 0;
}
    )SOURCE", "pass\n");

    add_simple_case("goto", R"SOURCE(
import "std.zig";

fn loop(a : i32) => {
    if (a == 0) {
        goto done;
    }
    print_str("loop\n");
    loop(a - 1);

done:
    return;
}

pub fn main(args: [][]u8) i32 => {
    loop(3);
    return 0;
}
    )SOURCE", "loop\nloop\nloop\n");

    add_simple_case("local variables", R"SOURCE(
import "std.zig";

pub fn main(args: [][]u8) i32 => {
    const a : i32 = 1;
    const b = i32(2);
    if (a + b == 3) {
        print_str("OK\n");
    }
    return 0;
}
    )SOURCE", "OK\n");

    add_simple_case("bool literals", R"SOURCE(
import "std.zig";

pub fn main(args: [][]u8) i32 => {
    if (true)   { print_str("OK 1\n"); }
    if (false)  { print_str("BAD 1\n"); }
    if (!true)  { print_str("BAD 2\n"); }
    if (!false) { print_str("OK 2\n"); }
    return 0;
}
    )SOURCE", "OK 1\nOK 2\n");

    add_simple_case("separate block scopes", R"SOURCE(
import "std.zig";

pub fn main(args: [][]u8) i32 => {
    if (true) {
        const no_conflict : i32 = 5;
        if (no_conflict == 5) { print_str("OK 1\n"); }
    }

    const c = {
        const no_conflict = i32(10);
        no_conflict
    };
    if (c == 10) { print_str("OK 2\n"); }
    return 0;
}
    )SOURCE", "OK 1\nOK 2\n");

    add_simple_case("void parameters", R"SOURCE(
import "std.zig";

pub fn main(args: [][]u8) i32 => {
    void_fun(1, void{}, 2);
    return 0;
}

fn void_fun(a : i32, b : void, c : i32) => {
    const v = b;
    const vv : void = if (a == 1) {v} else {};
    if (a + c == 3) { print_str("OK\n"); }
    return vv;
}
    )SOURCE", "OK\n");

    add_simple_case("void struct fields", R"SOURCE(
import "std.zig";
struct Foo {
    a : void,
    b : i32,
    c : void,
}
pub fn main(args: [][]u8) i32 => {
    const foo = Foo {
        .a = void{},
        .b = 1,
        .c = void{},
    };
    if (foo.b != 1) {
        print_str("BAD\n");
    }
    if (@sizeof(Foo) != 4) {
        print_str("BAD\n");
    }
    print_str("OK\n");
    return 0;
}

    )SOURCE", "OK\n");

    add_simple_case("void arrays", R"SOURCE(
import "std.zig";

pub fn main(args: [][]u8) i32 => {
    var array: [4]void;
    array[0] = void{};
    array[1] = array[2];
    if (@sizeof(@typeof(array)) != 0) {
        print_str("BAD\n");
    }
    if (array.len != 4) {
        print_str("BAD\n");
    }
    print_str("OK\n");
    return 0;
}
    )SOURCE", "OK\n");


    add_simple_case("mutable local variables", R"SOURCE(
import "std.zig";

pub fn main(args: [][]u8) i32 => {
    var zero : i32 = 0;
    if (zero == 0) { print_str("zero\n"); }

    var i = i32(0);
loop_start:
    if (i == 3) {
        goto done;
    }
    print_str("loop\n");
    i = i + 1;
    goto loop_start;
done:
    return 0;
}
    )SOURCE", "zero\nloop\nloop\nloop\n");

    add_simple_case("arrays", R"SOURCE(
import "std.zig";

pub fn main(args: [][]u8) i32 => {
    var array : [5]i32;

    var i : i32 = 0;
    while (i < 5) {
        array[i] = i + 1;
        i = array[i];
    }

    i = 0;
    var accumulator = i32(0);
    while (i < 5) {
        accumulator += array[i];

        i += 1;
    }

    if (accumulator == 15) {
        print_str("OK\n");
    }

    if (get_array_len(array) != 5) {
        print_str("BAD\n");
    }

    return 0;
}
fn get_array_len(a: []i32) isize => {
    a.len
}
    )SOURCE", "OK\n");


    add_simple_case("hello world without libc", R"SOURCE(
import "std.zig";

pub fn main(args: [][]u8) i32 => {
    print_str("Hello, world!\n");
    return 0;
}
    )SOURCE", "Hello, world!\n");


    add_simple_case("a + b + c", R"SOURCE(
import "std.zig";

pub fn main(args: [][]u8) i32 => {
    if (false || false || false) { print_str("BAD 1\n"); }
    if (true && true && false)   { print_str("BAD 2\n"); }
    if (1 | 2 | 4 != 7)          { print_str("BAD 3\n"); }
    if (3 ^ 6 ^ 8 != 13)         { print_str("BAD 4\n"); }
    if (7 & 14 & 28 != 4)        { print_str("BAD 5\n"); }
    if (9  << 1 << 2 != 9  << 3) { print_str("BAD 6\n"); }
    if (90 >> 1 >> 2 != 90 >> 3) { print_str("BAD 7\n"); }
    if (100 - 1 + 1000 != 1099)  { print_str("BAD 8\n"); }
    if (5 * 4 / 2 % 3 != 1)      { print_str("BAD 9\n"); }
    if (i32(i32(5)) != 5)        { print_str("BAD 10\n"); }
    if (!!false)                 { print_str("BAD 11\n"); }
    if (i32(7) != --(i32(7)))    { print_str("BAD 12\n"); }

    print_str("OK\n");
    return 0;
}
    )SOURCE", "OK\n");

    add_simple_case("short circuit", R"SOURCE(
import "std.zig";

pub fn main(args: [][]u8) i32 => {
    if (true || { print_str("BAD 1\n"); false }) {
      print_str("OK 1\n");
    }
    if (false || { print_str("OK 2\n"); false }) {
      print_str("BAD 2\n");
    }

    if (true && { print_str("OK 3\n"); false }) {
      print_str("BAD 3\n");
    }
    if (false && { print_str("BAD 4\n"); false }) {
    } else {
      print_str("OK 4\n");
    }

    return 0;
}
    )SOURCE", "OK 1\nOK 2\nOK 3\nOK 4\n");

    add_simple_case("modify operators", R"SOURCE(
import "std.zig";

pub fn main(args: [][]u8) i32 => {
    var i : i32 = 0;
    i += 5;  if (i != 5)  { print_str("BAD +=\n"); }
    i -= 2;  if (i != 3)  { print_str("BAD -=\n"); }
    i *= 20; if (i != 60) { print_str("BAD *=\n"); }
    i /= 3;  if (i != 20) { print_str("BAD /=\n"); }
    i %= 11; if (i != 9)  { print_str("BAD %=\n"); }
    i <<= 1; if (i != 18) { print_str("BAD <<=\n"); }
    i >>= 2; if (i != 4)  { print_str("BAD >>=\n"); }
    i = 6;
    i &= 5;  if (i != 4)  { print_str("BAD &=\n"); }
    i ^= 6;  if (i != 2)  { print_str("BAD ^=\n"); }
    i = 6;
    i |= 3;  if (i != 7)  { print_str("BAD |=\n"); }

    print_str("OK\n");
    return 0;
}
    )SOURCE", "OK\n");

    add_simple_case("number literals", R"SOURCE(
#link("c")
extern {
    fn printf(__format: &const u8, ...) i32;
}

export fn main(argc: i32, argv: &&u8) i32 => {
    printf(c"\n");

    printf(c"0: %llu\n",
             u64(0));
    printf(c"320402575052271: %llu\n",
         u64(320402575052271));
    printf(c"0x01236789abcdef: %llu\n",
         u64(0x01236789abcdef));
    printf(c"0xffffffffffffffff: %llu\n",
         u64(0xffffffffffffffff));
    printf(c"0x000000ffffffffffffffff: %llu\n",
         u64(0x000000ffffffffffffffff));
    printf(c"0o1777777777777777777777: %llu\n",
         u64(0o1777777777777777777777));
    printf(c"0o0000001777777777777777777777: %llu\n",
         u64(0o0000001777777777777777777777));
    printf(c"0b1111111111111111111111111111111111111111111111111111111111111111: %llu\n",
         u64(0b1111111111111111111111111111111111111111111111111111111111111111));
    printf(c"0b0000001111111111111111111111111111111111111111111111111111111111111111: %llu\n",
         u64(0b0000001111111111111111111111111111111111111111111111111111111111111111));

    printf(c"\n");

    printf(c"0.0: %a\n",
         f64(0.0));
    printf(c"0e0: %a\n",
         f64(0e0));
    printf(c"0.0e0: %a\n",
         f64(0.0e0));
    printf(c"000000000000000000000000000000000000000000000000000000000.0e0: %a\n",
         f64(000000000000000000000000000000000000000000000000000000000.0e0));
    printf(c"0.000000000000000000000000000000000000000000000000000000000e0: %a\n",
         f64(0.000000000000000000000000000000000000000000000000000000000e0));
    printf(c"0.0e000000000000000000000000000000000000000000000000000000000: %a\n",
         f64(0.0e000000000000000000000000000000000000000000000000000000000));
    printf(c"1.0: %a\n",
         f64(1.0));
    printf(c"10.0: %a\n",
         f64(10.0));
    printf(c"10.5: %a\n",
         f64(10.5));
    printf(c"10.5e5: %a\n",
         f64(10.5e5));
    printf(c"10.5e+5: %a\n",
         f64(10.5e+5));
    printf(c"50.0e-2: %a\n",
         f64(50.0e-2));
    printf(c"50e-2: %a\n",
         f64(50e-2));

    printf(c"\n");

    printf(c"0x1.0: %a\n",
         f64(0x1.0));
    printf(c"0x10.0: %a\n",
         f64(0x10.0));
    printf(c"0x100.0: %a\n",
         f64(0x100.0));
    printf(c"0x103.0: %a\n",
         f64(0x103.0));
    printf(c"0x103.7: %a\n",
         f64(0x103.7));
    printf(c"0x103.70: %a\n",
         f64(0x103.70));
    printf(c"0x103.70p4: %a\n",
         f64(0x103.70p4));
    printf(c"0x103.70p5: %a\n",
         f64(0x103.70p5));
    printf(c"0x103.70p+5: %a\n",
         f64(0x103.70p+5));
    printf(c"0x103.70p-5: %a\n",
         f64(0x103.70p-5));

    printf(c"\n");

    printf(c"0b10100.00010e0: %a\n",
         f64(0b10100.00010e0));
    printf(c"0o10700.00010e0: %a\n",
         f64(0o10700.00010e0));

    return 0;
}
    )SOURCE", R"OUTPUT(
0: 0
320402575052271: 320402575052271
0x01236789abcdef: 320402575052271
0xffffffffffffffff: 18446744073709551615
0x000000ffffffffffffffff: 18446744073709551615
0o1777777777777777777777: 18446744073709551615
0o0000001777777777777777777777: 18446744073709551615
0b1111111111111111111111111111111111111111111111111111111111111111: 18446744073709551615
0b0000001111111111111111111111111111111111111111111111111111111111111111: 18446744073709551615

0.0: 0x0p+0
0e0: 0x0p+0
0.0e0: 0x0p+0
000000000000000000000000000000000000000000000000000000000.0e0: 0x0p+0
0.000000000000000000000000000000000000000000000000000000000e0: 0x0p+0
0.0e000000000000000000000000000000000000000000000000000000000: 0x0p+0
1.0: 0x1p+0
10.0: 0x1.4p+3
10.5: 0x1.5p+3
10.5e5: 0x1.0059p+20
10.5e+5: 0x1.0059p+20
50.0e-2: 0x1p-1
50e-2: 0x1p-1

0x1.0: 0x1p+0
0x10.0: 0x1p+4
0x100.0: 0x1p+8
0x103.0: 0x1.03p+8
0x103.7: 0x1.037p+8
0x103.70: 0x1.037p+8
0x103.70p4: 0x1.037p+12
0x103.70p5: 0x1.037p+13
0x103.70p+5: 0x1.037p+13
0x103.70p-5: 0x1.037p+3

0b10100.00010e0: 0x1.41p+4
0o10700.00010e0: 0x1.1c0001p+12
)OUTPUT");

    add_simple_case("structs", R"SOURCE(
import "std.zig";

pub fn main(args: [][]u8) i32 => {
    var foo : Foo;
    @memset(&foo, 0, @sizeof(Foo));
    foo.a += 1;
    foo.b = foo.a == 1;
    test_foo(foo);
    test_mutation(&foo);
    if (foo.c != 100) {
        print_str("BAD\n");
    }
    test_point_to_self();
    test_byval_assign();
    test_initializer();
    print_str("OK\n");
    return 0;
}
struct Foo {
    a : i32,
    b : bool,
    c : f32,
}
fn test_foo(foo : Foo) => {
    if (!foo.b) {
        print_str("BAD\n");
    }
}
fn test_mutation(foo : &Foo) => {
    foo.c = 100;
}
struct Node {
    val: Val,
    next: &Node,
}

struct Val {
    x: i32,
}
fn test_point_to_self() => {
    var root : Node;
    root.val.x = 1;

    var node : Node;
    node.next = &root;
    node.val.x = 2;

    root.next = &node;

    if (node.next.next.next.val.x != 1) {
        print_str("BAD\n");
    }
}
fn test_byval_assign() => {
    var foo1 : Foo;
    var foo2 : Foo;

    foo1.a = 1234;

    if (foo2.a != 0) { print_str("BAD\n"); }

    foo2 = foo1;

    if (foo2.a != 1234) { print_str("BAD - byval assignment failed\n"); }
}
fn test_initializer() => {
    const val = Val { .x = 42 };
    if (val.x != 42) { print_str("BAD\n"); }
}
    )SOURCE", "OK\n");

    add_simple_case("global variables", R"SOURCE(
import "std.zig";

const g1 : i32 = 1233 + 1;
var g2 : i32 = 0;

pub fn main(args: [][]u8) i32 => {
    if (g2 != 0) { print_str("BAD\n"); }
    g2 = g1;
    if (g2 != 1234) { print_str("BAD\n"); }
    print_str("OK\n");
    return 0;
}
    )SOURCE", "OK\n");

    add_simple_case("while loop", R"SOURCE(
import "std.zig";
pub fn main(args: [][]u8) i32 => {
    var i : i32 = 0;
    while (i < 4) {
        print_str("loop\n");
        i += 1;
    }
    return f();
}
fn f() i32 => {
    while (true) {
        return 0;
    }
}
    )SOURCE", "loop\nloop\nloop\nloop\n");

    add_simple_case("continue and break", R"SOURCE(
import "std.zig";
pub fn main(args: [][]u8) i32 => {
    var i : i32 = 0;
    while (true) {
        print_str("loop\n");
        i += 1;
        if (i < 4) {
            continue;
        }
        break;
    }
    return 0;
}
    )SOURCE", "loop\nloop\nloop\nloop\n");

    add_simple_case("maybe type", R"SOURCE(
import "std.zig";
pub fn main(args: [][]u8) i32 => {
    const x : ?bool = true;

    if (const y ?= x) {
        if (y) {
            print_str("x is true\n");
        } else {
            print_str("x is false\n");
        }
    } else {
        print_str("x is none\n");
    }

    const next_x : ?i32 = null;

    const z = next_x ?? 1234;

    if (z != 1234) {
        print_str("BAD\n");
    }

    const final_x : ?i32 = 13;

    const num = final_x ?? unreachable{};

    if (num != 13) {
        print_str("BAD\n");
    }

    return 0;
}
    )SOURCE", "x is true\n");

    add_simple_case("implicit cast after unreachable", R"SOURCE(
import "std.zig";
pub fn main(args: [][]u8) i32 => {
    const x = outer();
    if (x == 1234) {
        print_str("OK\n");
    }
    return 0;
}
fn inner() i32 => { 1234 }
fn outer() isize => {
    return inner();
}
    )SOURCE", "OK\n");

    add_simple_case("@sizeof() and @typeof()", R"SOURCE(
import "std.zig";
const x: u16 = 13;
const z: @typeof(x) = 19;
pub fn main(args: [][]u8) i32 => {
    const y: @typeof(x) = 120;
    print_u64(@sizeof(@typeof(y)));
    print_str("\n");
    return 0;
}
    )SOURCE", "2\n");

    add_simple_case("member functions", R"SOURCE(
import "std.zig";
struct Rand {
    seed: u32,
    pub fn get_seed(r: Rand) u32 => {
        r.seed
    }
}
pub fn main(args: [][]u8) i32 => {
    const r = Rand {.seed = 1234};
    if (r.get_seed() != 1234) {
        print_str("BAD seed\n");
    }
    print_str("OK\n");
    return 0;
}
    )SOURCE", "OK\n");

    add_simple_case("pointer dereferencing", R"SOURCE(
import "std.zig";

pub fn main(args: [][]u8) i32 => {
    var x = i32(3);
    const y = &x;

    *y += 1;

    if (x != 4) {
        print_str("BAD\n");
    }
    if (*y != 4) {
        print_str("BAD\n");
    }
    print_str("OK\n");
    return 0;
}
    )SOURCE", "OK\n");

    add_simple_case("constant expressions", R"SOURCE(
import "std.zig";

const ARRAY_SIZE : i8 = 20;

pub fn main(args: [][]u8) i32 => {
    var array : [ARRAY_SIZE]u8;
    print_u64(@sizeof(@typeof(array)));
    print_str("\n");
    return 0;
}
    )SOURCE", "20\n");

    add_simple_case("#min_value() and #max_value()", R"SOURCE(
import "std.zig";
pub fn main(args: [][]u8) i32 => {
    print_str("max u8: ");
    print_u64(@max_value(u8));
    print_str("\n");

    print_str("max u16: ");
    print_u64(@max_value(u16));
    print_str("\n");

    print_str("max u32: ");
    print_u64(@max_value(u32));
    print_str("\n");

    print_str("max u64: ");
    print_u64(@max_value(u64));
    print_str("\n");

    print_str("max i8: ");
    print_i64(@max_value(i8));
    print_str("\n");

    print_str("max i16: ");
    print_i64(@max_value(i16));
    print_str("\n");

    print_str("max i32: ");
    print_i64(@max_value(i32));
    print_str("\n");

    print_str("max i64: ");
    print_i64(@max_value(i64));
    print_str("\n");

    print_str("min u8: ");
    print_u64(@min_value(u8));
    print_str("\n");

    print_str("min u16: ");
    print_u64(@min_value(u16));
    print_str("\n");

    print_str("min u32: ");
    print_u64(@min_value(u32));
    print_str("\n");

    print_str("min u64: ");
    print_u64(@min_value(u64));
    print_str("\n");

    print_str("min i8: ");
    print_i64(@min_value(i8));
    print_str("\n");

    print_str("min i16: ");
    print_i64(@min_value(i16));
    print_str("\n");

    print_str("min i32: ");
    print_i64(@min_value(i32));
    print_str("\n");

    print_str("min i64: ");
    print_i64(@min_value(i64));
    print_str("\n");

    return 0;
}
    )SOURCE",
        "max u8: 255\n"
        "max u16: 65535\n"
        "max u32: 4294967295\n"
        "max u64: 18446744073709551615\n"
        "max i8: 127\n"
        "max i16: 32767\n"
        "max i32: 2147483647\n"
        "max i64: 9223372036854775807\n"
        "min u8: 0\n"
        "min u16: 0\n"
        "min u32: 0\n"
        "min u64: 0\n"
        "min i8: -128\n"
        "min i16: -32768\n"
        "min i32: -2147483648\n"
        "min i64: -9223372036854775808\n");


    add_simple_case("slicing", R"SOURCE(
import "std.zig";
pub fn main(args: [][]u8) i32 => {
    var array : [20]i32;

    array[5] = 1234;

    var slice = array[5...10];

    if (slice.len != 5) {
        print_str("BAD\n");
    }

    if (slice.ptr[0] != 1234) {
        print_str("BAD\n");
    }

    var slice_rest = array[10...];
    if (slice_rest.len != 10) {
        print_str("BAD\n");
    }

    print_str("OK\n");
    return 0;
}
    )SOURCE", "OK\n");


    add_simple_case("else if expression", R"SOURCE(
import "std.zig";
pub fn main(args: [][]u8) i32 => {
    if (f(1) == 1) {
        print_str("OK\n");
    }
    return 0;
}
fn f(c: u8) u8 => {
    if (c == 0) {
        0
    } else if (c == 1) {
        1
    } else {
        2
    }
}
    )SOURCE", "OK\n");

    add_simple_case("overflow intrinsics", R"SOURCE(
import "std.zig";
pub fn main(args: [][]u8) i32 => {
    var result: u8;
    if (!@add_with_overflow(u8, 250, 100, &result)) {
        print_str("BAD\n");
    }
    if (@add_with_overflow(u8, 100, 150, &result)) {
        print_str("BAD\n");
    }
    if (result != 250) {
        print_str("BAD\n");
    }
    print_str("OK\n");
    return 0;
}
    )SOURCE", "OK\n");

    add_simple_case("memcpy and memset intrinsics", R"SOURCE(
import "std.zig";
pub fn main(args: [][]u8) i32 => {
    var foo : [20]u8;
    var bar : [20]u8;

    @memset(foo.ptr, 'A', foo.len);
    @memcpy(bar.ptr, foo.ptr, bar.len);

    if (bar[11] != 'A') {
        print_str("BAD\n");
    }

    print_str("OK\n");
    return 0;
}
    )SOURCE", "OK\n");

    add_simple_case("order-independent declarations", R"SOURCE(
import "std.zig";
const z : @typeof(stdin_fileno) = 0;
const x : @typeof(y) = 1234;
const y : u16 = 5678;
pub fn main(args: [][]u8) i32 => {
    print_ok(x)
}
fn print_ok(val: @typeof(x)) @typeof(foo) => {
    print_str("OK\n");
    return 0;
}
const foo : i32 = 0;
    )SOURCE", "OK\n");

    add_simple_case("enum type", R"SOURCE(
import "std.zig";

struct Point {
    x: u64,
    y: u64,
}

enum Foo {
    One: i32,
    Two: Point,
    Three: void,
}

enum Bar {
    A,
    B,
    C,
    D,
}

pub fn main(args: [][]u8) i32 => {
    const foo1 = Foo.One(13);
    const foo2 = Foo.Two(Point { .x = 1234, .y = 5678, });
    const bar = Bar.B;

    if (bar != Bar.B) {
        print_str("BAD\n");
    }

    if (@member_count(Foo) != 3) {
        print_str("BAD\n");
    }

    if (@member_count(Bar) != 4) {
        print_str("BAD\n");
    }

    if (@sizeof(Foo) != 17) {
        print_str("BAD\n");
    }
    if (@sizeof(Bar) != 1) {
        print_str("BAD\n");
    }

    print_str("OK\n");

    return 0;
}
    )SOURCE", "OK\n");

    add_simple_case("array literal", R"SOURCE(
import "std.zig";

pub fn main(args: [][]u8) i32 => {
    const HEX_MULT = []u16{4096, 256, 16, 1};

    if (HEX_MULT.len != 4) {
        print_str("BAD\n");
    }

    if (HEX_MULT[1] != 256) {
        print_str("BAD\n");
    }

    print_str("OK\n");
    return 0;
}
    )SOURCE", "OK\n");

    add_simple_case("nested arrays", R"SOURCE(
import "std.zig";

pub fn main(args: [][]u8) i32 => {
    const array_of_strings = [][]u8 {"hello", "this", "is", "my", "thing"};
    var i: @typeof(array_of_strings.len) = 0;
    while (i < array_of_strings.len) {
        print_str(array_of_strings[i]);
        print_str("\n");
        i += 1;
    }
    return 0;
}
    )SOURCE", "hello\nthis\nis\nmy\nthing\n");

    add_simple_case("for loops", R"SOURCE(
import "std.zig";

pub fn main(args: [][]u8) i32 => {
    const array = []u8 {9, 8, 7, 6};
    for (item, array) {
        print_u64(item);
        print_str("\n");
    }
    for (item, array, index) {
        print_i64(index);
        print_str("\n");
    }
    const unknown_size: []u8 = array;
    for (item, unknown_size) {
        print_u64(item);
        print_str("\n");
    }
    for (item, unknown_size, index) {
        print_i64(index);
        print_str("\n");
    }
    return 0;
}
    )SOURCE", "9\n8\n7\n6\n0\n1\n2\n3\n9\n8\n7\n6\n0\n1\n2\n3\n");

    add_simple_case("function pointers", R"SOURCE(
import "std.zig";

pub fn main(args: [][]u8) i32 => {
    const fns = []@typeof(fn1) { fn1, fn2, fn3, fn4, };
    for (f, fns) {
        print_u64(f());
        print_str("\n");
    }
    return 0;
}

fn fn1() u32 => {5}
fn fn2() u32 => {6}
fn fn3() u32 => {7}
fn fn4() u32 => {8}
    )SOURCE", "5\n6\n7\n8\n");
}


////////////////////////////////////////////////////////////////////////////////////

static void add_compile_failure_test_cases(void) {
    add_compile_fail_case("multiple function definitions", R"SOURCE(
fn a() => {}
fn a() => {}
    )SOURCE", 1, ".tmp_source.zig:3:1: error: redefinition of 'a'");

    add_compile_fail_case("bad directive", R"SOURCE(
#bogus1("")
extern {
    fn b();
}
#bogus2("")
fn a() => {}
    )SOURCE", 2, ".tmp_source.zig:2:1: error: invalid directive: 'bogus1'",
                 ".tmp_source.zig:6:1: error: invalid directive: 'bogus2'");

    add_compile_fail_case("unreachable with return", R"SOURCE(
fn a() unreachable => {return;}
    )SOURCE", 1, ".tmp_source.zig:2:24: error: expected type 'unreachable', got 'void'");

    add_compile_fail_case("control reaches end of non-void function", R"SOURCE(
fn a() i32 => {}
    )SOURCE", 1, ".tmp_source.zig:2:15: error: expected type 'i32', got 'void'");

    add_compile_fail_case("undefined function call", R"SOURCE(
fn a() => {
    b();
}
    )SOURCE", 1, ".tmp_source.zig:3:5: error: use of undeclared identifier 'b'");

    add_compile_fail_case("wrong number of arguments", R"SOURCE(
fn a() => {
    b(1);
}
fn b(a: i32, b: i32, c: i32) => { }
    )SOURCE", 1, ".tmp_source.zig:3:6: error: expected 3 arguments, got 1");

    add_compile_fail_case("invalid type", R"SOURCE(
fn a() bogus => {}
    )SOURCE", 1, ".tmp_source.zig:2:8: error: use of undeclared identifier 'bogus'");

    add_compile_fail_case("pointer to unreachable", R"SOURCE(
fn a() &unreachable => {}
    )SOURCE", 1, ".tmp_source.zig:2:8: error: pointer to unreachable not allowed");

    add_compile_fail_case("unreachable code", R"SOURCE(
fn a() => {
    return;
    b();
}

fn b() => {}
    )SOURCE", 1, ".tmp_source.zig:4:5: error: unreachable code");

    add_compile_fail_case("bad version string", R"SOURCE(
#version("aoeu")
export executable "test";
    )SOURCE", 1, ".tmp_source.zig:2:1: error: invalid version string");

    add_compile_fail_case("bad import", R"SOURCE(
import "bogus-does-not-exist.zig";
    )SOURCE", 1, ".tmp_source.zig:2:1: error: unable to find 'bogus-does-not-exist.zig'");

    add_compile_fail_case("undeclared identifier", R"SOURCE(
fn a() => {
    b +
    c
}
    )SOURCE", 2,
            ".tmp_source.zig:3:5: error: use of undeclared identifier 'b'",
            ".tmp_source.zig:4:5: error: use of undeclared identifier 'c'");

    add_compile_fail_case("goto cause unreachable code", R"SOURCE(
fn a() => {
    goto done;
    b();
done:
    return;
}
fn b() => {}
    )SOURCE", 1, ".tmp_source.zig:4:5: error: unreachable code");

    add_compile_fail_case("parameter redeclaration", R"SOURCE(
fn f(a : i32, a : i32) => {
}
    )SOURCE", 1, ".tmp_source.zig:2:15: error: redeclaration of variable 'a'");

    add_compile_fail_case("local variable redeclaration", R"SOURCE(
fn f() => {
    const a : i32 = 0;
    const a = 0;
}
    )SOURCE", 1, ".tmp_source.zig:4:5: error: redeclaration of variable 'a'");

    add_compile_fail_case("local variable redeclares parameter", R"SOURCE(
fn f(a : i32) => {
    const a = 0;
}
    )SOURCE", 1, ".tmp_source.zig:3:5: error: redeclaration of variable 'a'");

    add_compile_fail_case("variable has wrong type", R"SOURCE(
fn f() i32 => {
    const a = c"a";
    a
}
    )SOURCE", 1, ".tmp_source.zig:2:15: error: expected type 'i32', got '&const u8'");

    add_compile_fail_case("if condition is bool, not int", R"SOURCE(
fn f() => {
    if (0) {}
}
    )SOURCE", 1, ".tmp_source.zig:3:9: error: expected type 'bool', got '(u8 literal)'");

    add_compile_fail_case("assign unreachable", R"SOURCE(
fn f() => {
    const a = return;
}
    )SOURCE", 1, ".tmp_source.zig:3:5: error: variable initialization is unreachable");

    add_compile_fail_case("unreachable variable", R"SOURCE(
fn f() => {
    const a : unreachable = return;
}
    )SOURCE", 1, ".tmp_source.zig:3:15: error: variable of type 'unreachable' not allowed");

    add_compile_fail_case("unreachable parameter", R"SOURCE(
fn f(a : unreachable) => {}
    )SOURCE", 1, ".tmp_source.zig:2:10: error: parameter of type 'unreachable' not allowed");

    add_compile_fail_case("unused label", R"SOURCE(
fn f() => {
a_label:
}
    )SOURCE", 1, ".tmp_source.zig:3:1: error: label 'a_label' defined but not used");

    add_compile_fail_case("bad assignment target", R"SOURCE(
fn f() => {
    3 = 3;
}
    )SOURCE", 1, ".tmp_source.zig:3:5: error: invalid assignment target");

    add_compile_fail_case("assign to constant variable", R"SOURCE(
fn f() => {
    const a = 3;
    a = 4;
}
    )SOURCE", 1, ".tmp_source.zig:4:5: error: cannot assign to constant");

    add_compile_fail_case("use of undeclared identifier", R"SOURCE(
fn f() => {
    b = 3;
}
    )SOURCE", 1, ".tmp_source.zig:3:5: error: use of undeclared identifier 'b'");

    add_compile_fail_case("const is a statement, not an expression", R"SOURCE(
fn f() => {
    (const a = 0);
}
    )SOURCE", 1, ".tmp_source.zig:3:6: error: invalid token: 'const'");

    add_compile_fail_case("array access errors", R"SOURCE(
fn f() => {
    var bad : bool;
    i[i] = i[i];
    bad[bad] = bad[bad];
}
    )SOURCE", 8, ".tmp_source.zig:4:5: error: use of undeclared identifier 'i'",
                 ".tmp_source.zig:4:7: error: use of undeclared identifier 'i'",
                 ".tmp_source.zig:4:12: error: use of undeclared identifier 'i'",
                 ".tmp_source.zig:4:14: error: use of undeclared identifier 'i'",
                 ".tmp_source.zig:5:8: error: array access of non-array",
                 ".tmp_source.zig:5:9: error: expected type 'isize', got 'bool'",
                 ".tmp_source.zig:5:19: error: array access of non-array",
                 ".tmp_source.zig:5:20: error: expected type 'isize', got 'bool'");

    add_compile_fail_case("variadic functions only allowed in extern", R"SOURCE(
fn f(...) => {}
    )SOURCE", 1, ".tmp_source.zig:2:1: error: variadic arguments only allowed in extern functions");

    add_compile_fail_case("write to const global variable", R"SOURCE(
const x : i32 = 99;
fn f() => {
    x = 1;
}
    )SOURCE", 1, ".tmp_source.zig:4:5: error: cannot assign to constant");


    add_compile_fail_case("missing else clause", R"SOURCE(
fn f() => {
    const x : i32 = if (true) { 1 };
    const y = if (true) { i32(1) };
}
    )SOURCE", 2, ".tmp_source.zig:3:21: error: expected type 'i32', got 'void'",
                 ".tmp_source.zig:4:15: error: incompatible types: 'i32' and 'void'");

    add_compile_fail_case("direct struct loop", R"SOURCE(
struct A { a : A, }
    )SOURCE", 1, ".tmp_source.zig:2:1: error: struct has infinite size");

    add_compile_fail_case("indirect struct loop", R"SOURCE(
struct A { b : B, }
struct B { c : C, }
struct C { a : A, }
    )SOURCE", 1, ".tmp_source.zig:4:1: error: struct has infinite size");

    add_compile_fail_case("invalid struct field", R"SOURCE(
struct A { x : i32, }
fn f() => {
    var a : A;
    a.foo = 1;
    const y = a.bar;
}
    )SOURCE", 2,
            ".tmp_source.zig:5:6: error: no member named 'foo' in 'A'",
            ".tmp_source.zig:6:16: error: no member named 'bar' in 'A'");

    add_compile_fail_case("redefinition of struct", R"SOURCE(
struct A { x : i32, }
struct A { y : i32, }
    )SOURCE", 1, ".tmp_source.zig:3:1: error: redefinition of 'A'");

    add_compile_fail_case("byvalue struct on exported functions", R"SOURCE(
struct A { x : i32, }
export fn f(a : A) => {}
    )SOURCE", 1, ".tmp_source.zig:3:13: error: byvalue struct parameters not yet supported on exported functions");

    add_compile_fail_case("duplicate field in struct value expression", R"SOURCE(
struct A {
    x : i32,
    y : i32,
    z : i32,
}
fn f() => {
    const a = A {
        .z = 1,
        .y = 2,
        .x = 3,
        .z = 4,
    };
}
    )SOURCE", 1, ".tmp_source.zig:12:9: error: duplicate field");

    add_compile_fail_case("missing field in struct value expression", R"SOURCE(
struct A {
    x : i32,
    y : i32,
    z : i32,
}
fn f() => {
    const a = A {
        .z = 4,
        .y = 2,
    };
}
    )SOURCE", 1, ".tmp_source.zig:8:17: error: missing field: 'x'");

    add_compile_fail_case("invalid field in struct value expression", R"SOURCE(
struct A {
    x : i32,
    y : i32,
    z : i32,
}
fn f() => {
    const a = A {
        .z = 4,
        .y = 2,
        .foo = 42,
    };
}
    )SOURCE", 1, ".tmp_source.zig:11:9: error: no member named 'foo' in 'A'");

    add_compile_fail_case("invalid break expression", R"SOURCE(
fn f() => {
    break;
}
    )SOURCE", 1, ".tmp_source.zig:3:5: error: 'break' expression outside loop");

    add_compile_fail_case("invalid continue expression", R"SOURCE(
fn f() => {
    continue;
}
    )SOURCE", 1, ".tmp_source.zig:3:5: error: 'continue' expression outside loop");

    add_compile_fail_case("invalid maybe type", R"SOURCE(
fn f() => {
    if (const x ?= true) { }
}
    )SOURCE", 1, ".tmp_source.zig:3:20: error: expected maybe type");

    add_compile_fail_case("cast unreachable", R"SOURCE(
fn f() i32 => {
    i32(return 1)
}
    )SOURCE", 1, ".tmp_source.zig:3:8: error: invalid cast from type 'unreachable' to 'i32'");

    add_compile_fail_case("invalid builtin fn", R"SOURCE(
fn f() @bogus(foo) => {
}
    )SOURCE", 1, ".tmp_source.zig:2:8: error: invalid builtin function: 'bogus'");

    add_compile_fail_case("top level decl dependency loop", R"SOURCE(
const a : @typeof(b) = 0;
const b : @typeof(a) = 0;
    )SOURCE", 1, ".tmp_source.zig:3:19: error: use of undeclared identifier 'a'");

    add_compile_fail_case("noalias on non pointer param", R"SOURCE(
fn f(noalias x: i32) => {}
    )SOURCE", 1, ".tmp_source.zig:2:6: error: noalias on non-pointer parameter");

    add_compile_fail_case("struct init syntax for array", R"SOURCE(
const foo = []u16{.x = 1024,};
    )SOURCE", 1, ".tmp_source.zig:2:18: error: type '[]u16' does not support struct initialization syntax");

    add_compile_fail_case("type variables must be constant", R"SOURCE(
var foo = u8;
    )SOURCE", 1, ".tmp_source.zig:2:1: error: variable of type 'type' must be constant");

    add_compile_fail_case("variables shadowing types", R"SOURCE(
struct Foo {}
struct Bar {}

fn f(Foo: i32) => {
    var Bar : i32;
}
    )SOURCE", 2, ".tmp_source.zig:5:6: error: variable shadows type 'Foo'",
                 ".tmp_source.zig:6:5: error: variable shadows type 'Bar'");
}

static void print_compiler_invocation(TestCase *test_case) {
    printf("%s", zig_exe);
    for (int i = 0; i < test_case->compiler_args.length; i += 1) {
        printf(" %s", test_case->compiler_args.at(i));
    }
    printf("\n");
}

static void run_test(TestCase *test_case) {
    for (int i = 0; i < test_case->source_files.length; i += 1) {
        TestSourceFile *test_source = &test_case->source_files.at(i);
        os_write_file(
                buf_create_from_str(test_source->relative_path),
                buf_create_from_str(test_source->source_code));
    }

    Buf zig_stderr = BUF_INIT;
    Buf zig_stdout = BUF_INIT;
    int return_code;
    os_exec_process(zig_exe, test_case->compiler_args, &return_code, &zig_stderr, &zig_stdout);

    if (test_case->compile_errors.length) {
        if (return_code) {
            for (int i = 0; i < test_case->compile_errors.length; i += 1) {
                const char *err_text = test_case->compile_errors.at(i);
                if (!strstr(buf_ptr(&zig_stderr), err_text)) {
                    printf("\n");
                    printf("========= Expected this compile error: =========\n");
                    printf("%s\n", err_text);
                    printf("================================================\n");
                    print_compiler_invocation(test_case);
                    printf("%s\n", buf_ptr(&zig_stderr));
                    exit(1);
                }
            }
            return; // success
        } else {
            printf("\nCompile failed with return code 0 (Expected failure):\n");
            print_compiler_invocation(test_case);
            printf("%s\n", buf_ptr(&zig_stderr));
            exit(1);
        }
    }

    if (return_code != 0) {
        printf("\nCompile failed with return code %d:\n", return_code);
        print_compiler_invocation(test_case);
        printf("%s\n", buf_ptr(&zig_stderr));
        exit(1);
    }

    Buf program_stderr = BUF_INIT;
    Buf program_stdout = BUF_INIT;
    os_exec_process(tmp_exe_path, test_case->program_args, &return_code, &program_stderr, &program_stdout);

    if (return_code != 0) {
        printf("\nProgram exited with return code %d:\n", return_code);
        print_compiler_invocation(test_case);
        printf("%s", tmp_exe_path);
        for (int i = 0; i < test_case->program_args.length; i += 1) {
            printf(" %s", test_case->program_args.at(i));
        }
        printf("\n");
        printf("%s\n", buf_ptr(&program_stderr));
        exit(1);
    }

    if (!buf_eql_str(&program_stdout, test_case->output)) {
        printf("\n");
        print_compiler_invocation(test_case);
        printf("%s", tmp_exe_path);
        for (int i = 0; i < test_case->program_args.length; i += 1) {
            printf(" %s", test_case->program_args.at(i));
        }
        printf("\n");
        printf("==== Test failed. Expected output: ====\n");
        printf("%s\n", test_case->output);
        printf("========= Actual output: ==============\n");
        printf("%s\n", buf_ptr(&program_stdout));
        printf("=======================================\n");
        exit(1);
    }

    for (int i = 0; i < test_case->source_files.length; i += 1) {
        TestSourceFile *test_source = &test_case->source_files.at(i);
        remove(test_source->relative_path);
    }
}

static void run_all_tests(bool reverse) {
    if (reverse) {
        for (int i = test_cases.length - 1; i >= 0; i -= 1) {
            TestCase *test_case = test_cases.at(i);
            printf("Test %d/%d %s...", i + 1, test_cases.length, test_case->case_name);
            run_test(test_case);
            printf("OK\n");
        }
    } else {
        for (int i = 0; i < test_cases.length; i += 1) {
            TestCase *test_case = test_cases.at(i);
            printf("Test %d/%d %s...", i + 1, test_cases.length, test_case->case_name);
            run_test(test_case);
            printf("OK\n");
        }
    }
    printf("%d tests passed.\n", test_cases.length);
}

static void cleanup(void) {
    remove(tmp_source_path);
    remove(tmp_exe_path);
}

static int usage(const char *arg0) {
    fprintf(stderr, "Usage: %s [--reverse]\n", arg0);
    return 1;
}

int main(int argc, char **argv) {
    bool reverse = false;
    for (int i = 1; i < argc; i += 1) {
        if (strcmp(argv[i], "--reverse") == 0) {
            reverse = true;
        } else {
            return usage(argv[0]);
        }
    }
    add_compiling_test_cases();
    add_compile_failure_test_cases();
    run_all_tests(reverse);
    cleanup();
}
