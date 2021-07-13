const std = @import("std");
const tests = @import("tests.zig");
const nl = std.cstr.line_sep;

pub fn addCases(cases: *tests.RunTranslatedCContext) void {
    cases.add("dereference address of",
        \\#include <stdlib.h>
        \\int main(void) {
        \\    int i = 0;
        \\    *&i = 42;
        \\    if (i != 42) abort();
        \\	  return 0;
        \\}
    , "");

    cases.add("division of floating literals",
        \\#define _NO_CRT_STDIO_INLINE 1
        \\#include <stdio.h>
        \\#define PI 3.14159265358979323846f
        \\#define DEG2RAD (PI/180.0f)
        \\int main(void) {
        \\    printf("DEG2RAD is: %f\n", DEG2RAD);
        \\    return 0;
        \\}
    , "DEG2RAD is: 0.017453" ++ nl);

    cases.add("use global scope for record/enum/typedef type transalation if needed",
        \\void bar(void);
        \\void baz(void);
        \\struct foo { int x; };
        \\void bar() {
        \\	struct foo tmp;
        \\}
        \\
        \\void baz() {
        \\	struct foo tmp;
        \\}
        \\
        \\int main(void) {
        \\	bar();
        \\	baz();
        \\	return 0;
        \\}
    , "");

    cases.add("failed macros are only declared once",
        \\#define FOO =
        \\#define FOO =
        \\#define PtrToPtr64(p) ((void *POINTER_64) p)
        \\#define STRUC_ALIGNED_STACK_COPY(t,s) ((CONST t *)(s))
        \\#define bar = 0x
        \\#define baz = 0b
        \\int main(void) {}
    , "");

    cases.add("parenthesized string literal",
        \\void foo(const char *s) {}
        \\int main(void) {
        \\	foo(("bar"));
        \\}
    , "");

    cases.add("variable shadowing type type",
        \\#include <stdlib.h>
        \\int main() {
        \\    int type = 1;
        \\    if (type != 1) abort();
        \\}
    , "");

    cases.add("assignment as expression",
        \\#include <stdlib.h>
        \\int main() {
        \\    int a, b, c, d = 5;
        \\    int e = a = b = c = d;
        \\    if (e != 5) abort();
        \\}
    , "");

    cases.add("static variable in block scope",
        \\#include <stdlib.h>
        \\int foo() {
        \\    static int bar;
        \\    bar += 1;
        \\    return bar;
        \\}
        \\int main() {
        \\    foo();
        \\    foo();
        \\    if (foo() != 3) abort();
        \\}
    , "");

    cases.add("array initializer",
        \\#include <stdlib.h>
        \\int main(int argc, char **argv) {
        \\    int a0[4] = {1};
        \\    int a1[4] = {1,2,3,4};
        \\    int s0 = 0, s1 = 0;
        \\    for (int i = 0; i < 4; i++) {
        \\        s0 += a0[i];
        \\        s1 += a1[i];
        \\    }
        \\    if (s0 != 1) abort();
        \\    if (s1 != 10) abort();
        \\}
    , "");

    cases.add("forward declarations",
        \\#include <stdlib.h>
        \\int foo(int);
        \\int foo(int x) { return x + 1; }
        \\int main(int argc, char **argv) {
        \\    if (foo(2) != 3) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("typedef and function pointer",
        \\#include <stdlib.h>
        \\typedef struct _Foo Foo;
        \\typedef int Ret;
        \\typedef int Param;
        \\struct _Foo { Ret (*func)(Param p); };
        \\static Ret add1(Param p) {
        \\    return p + 1;
        \\}
        \\int main(int argc, char **argv) {
        \\    Foo strct = { .func = add1 };
        \\    if (strct.func(16) != 17) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("ternary operator",
        \\#include <stdlib.h>
        \\static int cnt = 0;
        \\int foo() { cnt++; return 42; }
        \\int main(int argc, char **argv) {
        \\  short q = 3;
        \\  signed char z0 = q?:1;
        \\  if (z0 != 3) abort();
        \\  int z1 = 3?:1;
        \\  if (z1 != 3) abort();
        \\  int z2 = foo()?:-1;
        \\  if (z2 != 42) abort();
        \\  if (cnt != 1) abort();
        \\  return 0;
        \\}
    , "");

    cases.add("switch case",
        \\#include <stdlib.h>
        \\int lottery(unsigned int x) {
        \\    switch (x) {
        \\        case 3: return 0;
        \\        case -1: return 3;
        \\        case 8 ... 10: return x;
        \\        default: return -1;
        \\    }
        \\}
        \\int main(int argc, char **argv) {
        \\    if (lottery(2) != -1) abort();
        \\    if (lottery(3) != 0) abort();
        \\    if (lottery(-1) != 3) abort();
        \\    if (lottery(9) != 9) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("boolean values and expressions",
        \\#include <stdlib.h>
        \\static const _Bool false_val = 0;
        \\static const _Bool true_val = 1;
        \\void foo(int x, int y) {
        \\    _Bool r = x < y;
        \\    if (!r) abort();
        \\    _Bool self = foo;
        \\    if (self == false_val) abort();
        \\    if (((r) ? 'a' : 'b') != 'a') abort();
        \\}
        \\int main(int argc, char **argv) {
        \\    foo(2, 5);
        \\    if (false_val == true_val) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("hello world",
        \\#define _NO_CRT_STDIO_INLINE 1
        \\#include <stdio.h>
        \\int main(int argc, char **argv) {
        \\    printf("hello, world!\n");
        \\    return 0;
        \\}
    , "hello, world!" ++ nl);

    cases.add("anon struct init",
        \\#include <stdlib.h>
        \\struct {int a; int b;} x = {1, 2};
        \\int main(int argc, char **argv) {
        \\    x.a += 2;
        \\    x.b += 1;
        \\    if (x.a != 3) abort();
        \\    if (x.b != 3) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("casting away const and volatile",
        \\void foo(int *a) {}
        \\void bar(const int *a) {
        \\    foo((int *)a);
        \\}
        \\void baz(volatile int *a) {
        \\    foo((int *)a);
        \\}
        \\int main(int argc, char **argv) {
        \\    int a = 0;
        \\    bar((const int *)&a);
        \\    baz((volatile int *)&a);
        \\    return 0;
        \\}
    , "");

    cases.add("anonymous struct & unions",
        \\#include <stdlib.h>
        \\#include <stdint.h>
        \\static struct { struct { uint16_t x, y; }; } x = { 1 };
        \\static struct { union { uint32_t x; uint8_t y; }; } y = { 0x55AA55AA };
        \\int main(int argc, char **argv) {
        \\    if (x.x != 1) abort();
        \\    if (x.y != 0) abort();
        \\    if (y.x != 0x55AA55AA) abort();
        \\    if (y.y != 0xAA) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("array to pointer decay",
        \\#include <stdlib.h>
        \\int main(int argc, char **argv) {
        \\    char data[3] = {'a','b','c'};
        \\    if (2[data] != data[2]) abort();
        \\    if ("abc"[1] != data[1]) abort();
        \\    char *as_ptr = data;
        \\    if (2[as_ptr] != as_ptr[2]) abort();
        \\    if ("abc"[1] != as_ptr[1]) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("struct initializer - packed",
        \\#define _NO_CRT_STDIO_INLINE 1
        \\#include <stdint.h>
        \\#include <stdlib.h>
        \\struct s {uint8_t x,y;
        \\          uint32_t z;} __attribute__((packed)) s0 = {1, 2};
        \\int main() {
        \\  /* sizeof nor offsetof currently supported */
        \\  if (((intptr_t)&s0.z - (intptr_t)&s0.x) != 2) abort();
        \\  return 0;
        \\}
    , "");

    cases.add("cast signed array index to unsigned",
        \\#include <stdlib.h>
        \\int main(int argc, char **argv) {
        \\  int a[10], i = 0;
        \\  a[i] = 0;
        \\  if (a[i] != 0) abort();
        \\  return 0;
        \\}
    , "");

    cases.add("cast long long array index to unsigned",
        \\#include <stdlib.h>
        \\int main(int argc, char **argv) {
        \\  long long a[10], i = 0;
        \\  a[i] = 0;
        \\  if (a[i] != 0) abort();
        \\  return 0;
        \\}
    , "");

    cases.add("case boolean expression converted to int",
        \\#include <stdlib.h>
        \\int main(int argc, char **argv) {
        \\  int value = 1 + 2 * 3 + 4 * 5 + 6 << 7 | 8 == 9;
        \\  if (value != 4224) abort();
        \\  return 0;
        \\}
    , "");

    cases.add("case boolean expression on left converted to int",
        \\#include <stdlib.h>
        \\int main(int argc, char **argv) {
        \\  int value = 8 == 9 | 1 + 2 * 3 + 4 * 5 + 6 << 7;
        \\  if (value != 4224) abort();
        \\  return 0;
        \\}
    , "");

    cases.add("case boolean and operator+ converts bool to int",
        \\#include <stdlib.h>
        \\int main(int argc, char **argv) {
        \\  int value = (8 == 9) + 3;
        \\  int value2 = 3 + (8 == 9);
        \\  if (value != value2) abort();
        \\  return 0;
        \\}
    , "");

    cases.add("case boolean and operator<",
        \\#include <stdlib.h>
        \\int main(int argc, char **argv) {
        \\  int value = (8 == 9) < 3;
        \\  if (value == 0) abort();
        \\  return 0;
        \\}
    , "");

    cases.add("case boolean and operator*",
        \\#include <stdlib.h>
        \\int main(int argc, char **argv) {
        \\  int value = (8 == 9) * 3;
        \\  int value2 = 3 * (9 == 9);
        \\  if (value != 0) abort();
        \\  if (value2 == 0) abort();
        \\  return 0;
        \\}
    , "");

    cases.add("scoped typedef",
        \\int main(int argc, char **argv) {
        \\  typedef int Foo;
        \\  typedef Foo Bar;
        \\  typedef void (*func)(int);
        \\  typedef int uint32_t;
        \\  uint32_t a;
        \\  Foo i;
        \\  Bar j;
        \\  return 0;
        \\}
    , "");

    cases.add("scoped for loops with shadowing",
        \\#include <stdlib.h>
        \\int main() {
        \\    int count = 0;
        \\    for (int x = 0; x < 2; x++)
        \\        for (int x = 0; x < 2; x++)
        \\            count++;
        \\
        \\    if (count != 4) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("array value type casts properly",
        \\#include <stdlib.h>
        \\unsigned int choose[53][10];
        \\static int hash_binary(int k)
        \\{
        \\    choose[0][k] = 3;
        \\    int sum = 0;
        \\    sum += choose[0][k];
        \\    return sum;
        \\}
        \\
        \\int main() {
        \\    int s = hash_binary(4);
        \\    if (s != 3) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("array value type casts properly use +=",
        \\#include <stdlib.h>
        \\static int hash_binary(int k)
        \\{
        \\    unsigned int choose[1][1] = {{3}};
        \\    int sum = -1;
        \\    int prev = 0;
        \\    prev = sum += choose[0][0];
        \\    if (sum != 2) abort();
        \\    return sum + prev;
        \\}
        \\
        \\int main() {
        \\    int x = hash_binary(4);
        \\    if (x != 4) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("ensure array casts outisde +=",
        \\#include <stdlib.h>
        \\static int hash_binary(int k)
        \\{
        \\    unsigned int choose[3] = {1, 2, 3};
        \\    int sum = -2;
        \\    int prev = sum + choose[k];
        \\    if (prev != 0) abort();
        \\    return sum + prev;
        \\}
        \\
        \\int main() {
        \\    int x = hash_binary(1);
        \\    if (x != -2) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("array cast int to uint",
        \\#include <stdlib.h>
        \\static unsigned int hash_binary(int k)
        \\{
        \\    int choose[3] = {-1, -2, 3};
        \\    unsigned int sum = 2;
        \\    sum += choose[k];
        \\    return sum;
        \\}
        \\
        \\int main() {
        \\    unsigned int x = hash_binary(1);
        \\    if (x != 0) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("assign enum to uint, no explicit cast",
        \\#include <stdlib.h>
        \\typedef enum {
        \\    ENUM_0 = 0,
        \\    ENUM_1 = 1,
        \\} my_enum_t;
        \\
        \\int main() {
        \\    my_enum_t val = ENUM_1;
        \\    unsigned int x = val;
        \\    if (x != 1) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("assign enum to int",
        \\#include <stdlib.h>
        \\typedef enum {
        \\    ENUM_0 = 0,
        \\    ENUM_1 = 1,
        \\} my_enum_t;
        \\
        \\int main() {
        \\    my_enum_t val = ENUM_1;
        \\    int x = val;
        \\    if (x != 1) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("cast enum to smaller uint",
        \\#include <stdlib.h>
        \\#include <stdint.h>
        \\typedef enum {
        \\    ENUM_0 = 0,
        \\    ENUM_257 = 257,
        \\} my_enum_t;
        \\
        \\int main() {
        \\    my_enum_t val = ENUM_257;
        \\    uint8_t x = (uint8_t)val;
        \\    if (x != (uint8_t)257) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("cast enum to smaller signed int",
        \\#include <stdlib.h>
        \\#include <stdint.h>
        \\typedef enum {
        \\    ENUM_0 = 0,
        \\    ENUM_384 = 384,
        \\} my_enum_t;
        \\
        \\int main() {
        \\    my_enum_t val = ENUM_384;
        \\    int8_t x = (int8_t)val;
        \\    if (x != (int8_t)384) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("cast negative enum to smaller signed int",
        \\#include <stdlib.h>
        \\#include <stdint.h>
        \\typedef enum {
        \\    ENUM_MINUS_1 = -1,
        \\    ENUM_384 = 384,
        \\} my_enum_t;
        \\
        \\int main() {
        \\    my_enum_t val = ENUM_MINUS_1;
        \\    int8_t x = (int8_t)val;
        \\    if (x != -1) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("cast negative enum to smaller unsigned int",
        \\#include <stdlib.h>
        \\#include <stdint.h>
        \\typedef enum {
        \\    ENUM_MINUS_1 = -1,
        \\    ENUM_384 = 384,
        \\} my_enum_t;
        \\
        \\int main() {
        \\    my_enum_t val = ENUM_MINUS_1;
        \\    uint8_t x = (uint8_t)val;
        \\    if (x != (uint8_t)-1) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("implicit enum cast in boolean expression",
        \\#include <stdlib.h>
        \\enum Foo {
        \\    FooA,
        \\    FooB,
        \\    FooC,
        \\};
        \\int main() {
        \\    int a = 0;
        \\    float b = 0;
        \\    void *c = 0;
        \\    enum Foo d = FooA;
        \\    if (a || d) abort();
        \\    if (d && b) abort();
        \\    if (c || d) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("issue #6707 cast builtin call result to opaque struct pointer",
        \\#include <stdlib.h>
        \\struct foo* make_foo(void)
        \\{
        \\    return (struct foo*)__builtin_strlen("0123456789ABCDEF");
        \\}
        \\int main(void) {
        \\    struct foo *foo_pointer = make_foo();
        \\    if (foo_pointer != (struct foo*)16) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("C built-ins",
        \\#include <stdlib.h>
        \\#include <limits.h>
        \\#include <stdbool.h>
        \\#define M_E    2.71828182845904523536
        \\#define M_PI_2 1.57079632679489661923
        \\bool check_clz(unsigned int pos) {
        \\    return (__builtin_clz(1 << pos) == (8 * sizeof(unsigned int) - pos - 1));
        \\}
        \\int main(void) {
        \\    if (__builtin_bswap16(0x0102) != 0x0201) abort();
        \\    if (__builtin_bswap32(0x01020304) != 0x04030201) abort();
        \\    if (__builtin_bswap64(0x0102030405060708) != 0x0807060504030201) abort();
        \\
        \\    if (__builtin_signbit(0.0) != 0) abort();
        \\    if (__builtin_signbitf(0.0f) != 0) abort();
        \\    if (__builtin_signbit(1.0) != 0) abort();
        \\    if (__builtin_signbitf(1.0f) != 0) abort();
        \\    if (__builtin_signbit(-1.0) != 1) abort();
        \\    if (__builtin_signbitf(-1.0f) != 1) abort();
        \\
        \\    if (__builtin_popcount(0) != 0) abort();
        \\    if (__builtin_popcount(0b1) != 1) abort();
        \\    if (__builtin_popcount(0b11) != 2) abort();
        \\    if (__builtin_popcount(0b1111) != 4) abort();
        \\    if (__builtin_popcount(0b11111111) != 8) abort();
        \\
        \\    if (__builtin_ctz(0b1) != 0) abort();
        \\    if (__builtin_ctz(0b10) != 1) abort();
        \\    if (__builtin_ctz(0b100) != 2) abort();
        \\    if (__builtin_ctz(0b10000) != 4) abort();
        \\    if (__builtin_ctz(0b100000000) != 8) abort();
        \\
        \\    if (!check_clz(0)) abort();
        \\    if (!check_clz(1)) abort();
        \\    if (!check_clz(2)) abort();
        \\    if (!check_clz(4)) abort();
        \\    if (!check_clz(8)) abort();
        \\
        \\    if (__builtin_sqrt(__builtin_sqrt(__builtin_sqrt(256))) != 2.0) abort();
        \\    if (__builtin_sqrt(__builtin_sqrt(__builtin_sqrt(256.0))) != 2.0) abort();
        \\    if (__builtin_sqrt(__builtin_sqrt(__builtin_sqrt(256.0f))) != 2.0) abort();
        \\    if (__builtin_sqrtf(__builtin_sqrtf(__builtin_sqrtf(256.0f))) != 2.0f) abort();
        \\
        \\    if (__builtin_sin(1.0) != -__builtin_sin(-1.0)) abort();
        \\    if (__builtin_sinf(1.0f) != -__builtin_sinf(-1.0f)) abort();
        \\    if (__builtin_sin(M_PI_2) != 1.0) abort();
        \\    if (__builtin_sinf(M_PI_2) != 1.0f) abort();
        \\
        \\    if (__builtin_cos(1.0) != __builtin_cos(-1.0)) abort();
        \\    if (__builtin_cosf(1.0f) != __builtin_cosf(-1.0f)) abort();
        \\    if (__builtin_cos(0.0) != 1.0) abort();
        \\    if (__builtin_cosf(0.0f) != 1.0f) abort();
        \\
        \\    if (__builtin_exp(0) != 1.0) abort();
        \\    if (__builtin_fabs(__builtin_exp(1.0) - M_E) > 0.00000001) abort();
        \\    if (__builtin_exp(0.0f) != 1.0f) abort();
        \\
        \\    if (__builtin_exp2(0) != 1.0) abort();
        \\    if (__builtin_exp2(4.0) != 16.0) abort();
        \\    if (__builtin_exp2f(0.0f) != 1.0f) abort();
        \\    if (__builtin_exp2f(4.0f) != 16.0f) abort();
        \\
        \\    if (__builtin_log(M_E) != 1.0) abort();
        \\    if (__builtin_log(1.0) != 0.0) abort();
        \\    if (__builtin_logf(1.0f) != 0.0f) abort();
        \\
        \\    if (__builtin_log2(8.0) != 3.0) abort();
        \\    if (__builtin_log2(1.0) != 0.0) abort();
        \\    if (__builtin_log2f(8.0f) != 3.0f) abort();
        \\    if (__builtin_log2f(1.0f) != 0.0f) abort();
        \\
        \\    if (__builtin_log10(1000.0) != 3.0) abort();
        \\    if (__builtin_log10(1.0) != 0.0) abort();
        \\    if (__builtin_log10f(1000.0f) != 3.0f) abort();
        \\    if (__builtin_log10f(1.0f) != 0.0f) abort();
        \\
        \\    if (__builtin_fabs(-42.0f) != 42.0) abort();
        \\    if (__builtin_fabs(-42.0) != 42.0) abort();
        \\    if (__builtin_fabs(-42) != 42.0) abort();
        \\    if (__builtin_fabsf(-42.0f) != 42.0f) abort();
        \\
        \\    if (__builtin_fabs(-42.0f) != 42.0) abort();
        \\    if (__builtin_fabs(-42.0) != 42.0) abort();
        \\    if (__builtin_fabs(-42) != 42.0) abort();
        \\    if (__builtin_fabsf(-42.0f) != 42.0f) abort();
        \\
        \\    if (__builtin_abs(42) != 42) abort();
        \\    if (__builtin_abs(-42) != 42) abort();
        \\    if (__builtin_abs(INT_MIN) != INT_MIN) abort();
        \\
        \\    if (__builtin_floor(42.9) != 42.0) abort();
        \\    if (__builtin_floor(-42.9) != -43.0) abort();
        \\    if (__builtin_floorf(42.9f) != 42.0f) abort();
        \\    if (__builtin_floorf(-42.9f) != -43.0f) abort();
        \\
        \\    if (__builtin_ceil(42.9) != 43.0) abort();
        \\    if (__builtin_ceil(-42.9) != -42) abort();
        \\    if (__builtin_ceilf(42.9f) != 43.0f) abort();
        \\    if (__builtin_ceilf(-42.9f) != -42.0f) abort();
        \\
        \\    if (__builtin_trunc(42.9) != 42.0) abort();
        \\    if (__builtin_truncf(42.9f) != 42.0f) abort();
        \\    if (__builtin_trunc(-42.9) != -42.0) abort();
        \\    if (__builtin_truncf(-42.9f) != -42.0f) abort();
        \\
        \\    if (__builtin_round(0.5) != 1.0) abort();
        \\    if (__builtin_round(-0.5) != -1.0) abort();
        \\    if (__builtin_roundf(0.5f) != 1.0f) abort();
        \\    if (__builtin_roundf(-0.5f) != -1.0f) abort();
        \\
        \\    if (__builtin_strcmp("abc", "abc") != 0) abort();
        \\    if (__builtin_strcmp("abc", "def") >= 0 ) abort();
        \\    if (__builtin_strcmp("def", "abc") <= 0) abort();
        \\
        \\    if (__builtin_strlen("this is a string") != 16) abort();
        \\
        \\    char *s = malloc(6);
        \\    __builtin_memcpy(s, "hello", 5);
        \\    s[5] = '\0';
        \\    if (__builtin_strlen(s) != 5) abort();
        \\
        \\    __builtin_memset(s, 42, __builtin_strlen(s));
        \\    if (s[0] != 42 || s[1] != 42 || s[2] != 42 || s[3] != 42 || s[4] != 42) abort();
        \\
        \\    free(s);
        \\
        \\    return 0;
        \\}
    , "");

    cases.add("function macro that uses builtin",
        \\#include <stdlib.h>
        \\#define FOO(x, y) (__builtin_popcount((x)) + __builtin_strlen((y)))
        \\int main() {
        \\    if (FOO(7, "hello!") != 9) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("assign bool result to int or char",
        \\#include <stdlib.h>
        \\#include <stdbool.h>
        \\bool foo() { return true; }
        \\int main() {
        \\    int x = foo();
        \\    if (x != 1) abort();
        \\    signed char c = foo();
        \\    if (c != 1) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("static K&R-style no prototype function declaration (empty parameter list)",
        \\#include <stdlib.h>
        \\static int foo() {
        \\    return 42;
        \\}
        \\int main() {
        \\    if (foo() != 42) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("K&R-style static function prototype for unused function",
        \\static int foo();
        \\int main() {
        \\    return 0;
        \\}
    , "");

    cases.add("K&R-style static function prototype + separate definition",
        \\#include <stdlib.h>
        \\static int foo();
        \\static int foo(int a, int b) {
        \\    return a + b;
        \\}
        \\int main() {
        \\    if (foo(40, 2) != 42) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("dollar sign in identifiers",
        \\#include <stdlib.h>
        \\#define $FOO 2
        \\#define $foo bar$
        \\#define $baz($x) ($x + $FOO)
        \\int $$$(int $x$) { return $x$ + $FOO; }
        \\int main() {
        \\    int bar$ = 42;
        \\    if ($foo != 42) abort();
        \\    if (bar$ != 42) abort();
        \\    if ($baz(bar$) != 44) abort();
        \\    if ($$$(bar$) != 44) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("Cast boolean expression result to int",
        \\#include <stdlib.h>
        \\char foo(char c) { return c; }
        \\int  bar(int i)  { return i; }
        \\long baz(long l) { return l; }
        \\int main() {
        \\    if (foo(1 == 2)) abort();
        \\    if (!foo(1 == 1)) abort();
        \\    if (bar(1 == 2)) abort();
        \\    if (!bar(1 == 1)) abort();
        \\    if (baz(1 == 2)) abort();
        \\    if (!baz(1 == 1)) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("Wide, UTF-16, and UTF-32 character literals",
        \\#include <wchar.h>
        \\#include <stdlib.h>
        \\int main() {
        \\    wchar_t wc = L'™';
        \\    int utf16_char = u'™';
        \\    int utf32_char = U'💯';
        \\    if (wc != 8482) abort();
        \\    if (utf16_char != 8482) abort();
        \\    if (utf32_char != 128175) abort();
        \\    unsigned char c = wc;
        \\    if (c != 0x22) abort();
        \\    c = utf32_char;
        \\    if (c != 0xaf) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("Variadic function call",
        \\#define _NO_CRT_STDIO_INLINE 1
        \\#include <stdio.h>
        \\int main(void) {
        \\    printf("%d %d\n", 1, 2);
        \\    return 0;
        \\}
    , "1 2" ++ nl);

    cases.add("multi-character character constant",
        \\#include <stdlib.h>
        \\int main(void) {
        \\    int foo = 'abcd';
        \\    switch (foo) {
        \\        case 'abcd': break;
        \\        default: abort();
        \\    }
        \\    return 0;
        \\}
    , "");

    cases.add("Array initializers (string literals, incomplete arrays)",
        \\#include <stdlib.h>
        \\#include <string.h>
        \\extern int foo[];
        \\int global_arr[] = {1, 2, 3};
        \\char global_string[] = "hello";
        \\int main(int argc, char *argv[]) {
        \\    if (global_arr[2] != 3) abort();
        \\    if (strlen(global_string) != 5) abort();
        \\    const char *const_str = "hello";
        \\    if (strcmp(const_str, "hello") != 0) abort();
        \\    char empty_str[] = "";
        \\    if (strlen(empty_str) != 0) abort();
        \\    char hello[] = "hello";
        \\    if (strlen(hello) != 5 || sizeof(hello) != 6) abort();
        \\    int empty[] = {};
        \\    if (sizeof(empty) != 0) abort();
        \\    int bar[] = {42};
        \\    if (bar[0] != 42) abort();
        \\    bar[0] = 43;
        \\    if (bar[0] != 43) abort();
        \\    int baz[] = {1, [42] = 123, 456};
        \\    if (baz[42] != 123 || baz[43] != 456) abort();
        \\    if (sizeof(baz) != sizeof(int) * 44) abort();
        \\    const char *const names[] = {"first", "second", "third"};
        \\    if (strcmp(names[2], "third") != 0) abort();
        \\    char catted_str[] = "abc" "def";
        \\    if (strlen(catted_str) != 6 || sizeof(catted_str) != 7) abort();
        \\    char catted_trunc_str[2] = "abc" "def";
        \\    if (sizeof(catted_trunc_str) != 2 || catted_trunc_str[0] != 'a' || catted_trunc_str[1] != 'b') abort();
        \\    char big_array_utf8lit[10] = "💯";
        \\    if (strcmp(big_array_utf8lit, "💯") != 0 || big_array_utf8lit[9] != 0) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("Wide, UTF-16, and UTF-32 string literals",
        \\#include <stdlib.h>
        \\#include <stdint.h>
        \\#include <wchar.h>
        \\int main(void) {
        \\    const wchar_t *wide_str = L"wide";
        \\    const wchar_t wide_hello[] = L"hello";
        \\    if (wcslen(wide_str) != 4) abort();
        \\    if (wcslen(L"literal") != 7) abort();
        \\    if (wcscmp(wide_hello, L"hello") != 0) abort();
        \\
        \\    const uint16_t *u16_str = u"wide";
        \\    const uint16_t u16_hello[] = u"hello";
        \\    if (u16_str[3] != u'e' || u16_str[4] != 0) abort();
        \\    if (u16_hello[4] != u'o' || u16_hello[5] != 0) abort();
        \\
        \\    const uint32_t *u32_str = U"wide";
        \\    const uint32_t u32_hello[] = U"hello";
        \\    if (u32_str[3] != U'e' || u32_str[4] != 0) abort();
        \\    if (u32_hello[4] != U'o' || u32_hello[5] != 0) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("Address of function is no-op",
        \\#include <stdlib.h>
        \\#include <stdbool.h>
        \\typedef int (*myfunc)(int);
        \\int a(int arg) { return arg + 1;}
        \\int b(int arg) { return arg + 2;}
        \\int caller(myfunc fn, int arg) {
        \\    return fn(arg);
        \\}
        \\int main() {
        \\    myfunc arr[3] = {&a, &b, a};
        \\    myfunc foo = a;
        \\    myfunc bar = &(a);
        \\    if (foo != bar) abort();
        \\    if (arr[0] == arr[1]) abort();
        \\    if (arr[0] != arr[2]) abort();
        \\    if (caller(b, 40) != 42) abort();
        \\    if (caller(&b, 40) != 42) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("Obscure ways of calling functions; issue #4124",
        \\#include <stdlib.h>
        \\static int add(int a, int b) {
        \\    return a + b;
        \\}
        \\typedef int (*adder)(int, int);
        \\typedef void (*funcptr)(void);
        \\int main() {
        \\    if ((add)(1, 2) != 3) abort();
        \\    if ((&add)(1, 2) != 3) abort();
        \\    if (add(3, 1) != 4) abort();
        \\    if ((*add)(2, 3) != 5) abort();
        \\    if ((**add)(7, -1) != 6) abort();
        \\    if ((***add)(-2, 9) != 7) abort();
        \\
        \\    int (*ptr)(int a, int b);
        \\    ptr = add;
        \\
        \\    if (ptr(1, 2) != 3) abort();
        \\    if ((*ptr)(3, 1) != 4) abort();
        \\    if ((**ptr)(2, 3) != 5) abort();
        \\    if ((***ptr)(7, -1) != 6) abort();
        \\    if ((****ptr)(-2, 9) != 7) abort();
        \\
        \\    funcptr addr1 = (funcptr)(add);
        \\    funcptr addr2 = (funcptr)(&add);
        \\
        \\    if (addr1 != addr2) abort();
        \\    if (((int(*)(int, int))addr1)(1, 2) != 3) abort();
        \\    if (((adder)addr2)(1, 2) != 3) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("Return boolean expression as int; issue #6215",
        \\#include <stdlib.h>
        \\#include <stdbool.h>
        \\bool  actual_bool(void)    { return 4 - 1 < 4;}
        \\char  char_bool_ret(void)  { return 0 || 1; }
        \\short short_bool_ret(void) { return 0 < 1; }
        \\int   int_bool_ret(void)   { return 1 && 1; }
        \\long  long_bool_ret(void)  { return !(0 > 1); }
        \\static int GLOBAL = 1;
        \\int nested_scopes(int a, int b) {
        \\    if (a == 1) {
        \\        int target = 1;
        \\        return b == target;
        \\    } else {
        \\        int target = 2;
        \\        if (b == target) {
        \\            return GLOBAL == 1;
        \\        }
        \\        return target == 2;
        \\    }
        \\}
        \\int main(void) {
        \\    if (!actual_bool()) abort();
        \\    if (!char_bool_ret()) abort();
        \\    if (!short_bool_ret()) abort();
        \\    if (!int_bool_ret()) abort();
        \\    if (!long_bool_ret()) abort();
        \\    if (!nested_scopes(1, 1)) abort();
        \\    if (nested_scopes(1, 2)) abort();
        \\    if (!nested_scopes(0, 2)) abort();
        \\    if (!nested_scopes(0, 3)) abort();
        \\    return 1 != 1;
        \\}
    , "");

    cases.add("Comma operator should create new scope; issue #7989",
        \\#include <stdlib.h>
        \\#include <stdio.h>
        \\int main(void) {
        \\    if (1 || (abort(), 1)) {}
        \\    if (0 && (1, printf("do not print\n"))) {}
        \\    int x = 0;
        \\    x = (x = 3, 4, x + 1);
        \\    if (x != 4) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("Use correct break label for statement expression in nested scope",
        \\#include <stdlib.h>
        \\int main(void) {
        \\    int x = ({1, ({2; 3;});});
        \\    if (x != 3) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("pointer difference: scalar array w/ size truncation or negative result. Issue #7216",
        \\#include <stdlib.h>
        \\#include <stddef.h>
        \\#define SIZE 10
        \\int main() {
        \\    int foo[SIZE];
        \\    int *start = &foo[0];
        \\    int *one_past_end = start + SIZE;
        \\    ptrdiff_t diff = one_past_end - start;
        \\    char diff_char = one_past_end - start;
        \\    if (diff != SIZE || diff_char != SIZE) abort();
        \\    diff = start - one_past_end;
        \\    if (diff != -SIZE) abort();
        \\    if (one_past_end - foo != SIZE) abort();
        \\    if ((one_past_end - 1) - foo != SIZE - 1) abort();
        \\    if ((start + 1) - foo != 1) abort();
        \\    return 0;
        \\}
    , "");

    // C standard: if the expression P points either to an element of an array object or one
    // past the last element of an array object, and the expression Q points to the last
    // element of the same array object, the expression ((Q)+1)-(P) has the same value as
    // ((Q)-(P))+1 and as -((P)-((Q)+1)), and has the value zero if the expression P points
    // one past the last element of the array object, even though the expression (Q)+1
    // does not point to an element of the array object
    cases.add("pointer difference: C standard edge case",
        \\#include <stdlib.h>
        \\#include <stddef.h>
        \\#define SIZE 10
        \\int main() {
        \\    int foo[SIZE];
        \\    int *start = &foo[0];
        \\    int *P = start + SIZE;
        \\    int *Q = &foo[SIZE - 1];
        \\    if ((Q + 1) - P != 0) abort();
        \\    if ((Q + 1) - P != (Q - P) + 1) abort();
        \\    if ((Q + 1) - P != -(P - (Q + 1))) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("pointer difference: unary operators",
        \\#include <stdlib.h>
        \\int main() {
        \\    int foo[10];
        \\    int *x = &foo[1];
        \\    const int *y = &foo[5];
        \\    if (y - x++ != 4) abort();
        \\    if (y - x != 3) abort();
        \\    if (y - ++x != 2) abort();
        \\    if (y - x-- != 2) abort();
        \\    if (y - x != 3) abort();
        \\    if (y - --x != 4) abort();
        \\    if (y - &foo[0] != 5) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("pointer difference: struct array with padding",
        \\#include <stdlib.h>
        \\#include <stddef.h>
        \\#define SIZE 10
        \\typedef struct my_struct {
        \\    int x;
        \\    char c;
        \\    int y;
        \\} my_struct_t;
        \\int main() {
        \\    my_struct_t foo[SIZE];
        \\    my_struct_t *start = &foo[0];
        \\    my_struct_t *one_past_end = start + SIZE;
        \\    ptrdiff_t diff = one_past_end - start;
        \\    int diff_int = one_past_end - start;
        \\    if (diff != SIZE || diff_int != SIZE) abort();
        \\    diff = start - one_past_end;
        \\    if (diff != -SIZE) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("pointer difference: array of function pointers",
        \\#include <stdlib.h>
        \\int a(void) { return 1;}
        \\int b(void) { return 2;}
        \\int c(void) { return 3;}
        \\typedef int (*myfunc)(void);
        \\int main() {
        \\    myfunc arr[] = {a, b, c, a, b, c};
        \\    myfunc *f1 = &arr[1];
        \\    myfunc *f4 = &arr[4];
        \\    if (f4 - f1 != 3) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("typeof operator",
        \\#include <stdlib.h>
        \\static int FOO = 42;
        \\typedef typeof(FOO) foo_type;
        \\typeof(foo_type) myfunc(typeof(FOO) x) { return (typeof(FOO)) x; }
        \\int main(void) {
        \\    int x = FOO;
        \\    typeof(x) y = x;
        \\    foo_type z = y;
        \\    if (x != y) abort();
        \\    if (myfunc(z) != x) abort();
        \\
        \\    const char *my_string = "bar";
        \\    typeof (typeof (my_string)[4]) string_arr = {"a","b","c","d"};
        \\    if (string_arr[0][0] != 'a' || string_arr[3][0] != 'd') abort();
        \\    return 0;
        \\}
    , "");

    cases.add("offsetof",
        \\#include <stddef.h>
        \\#include <stdlib.h>
        \\#define container_of(ptr, type, member) ({                      \
        \\        const typeof( ((type *)0)->member ) *__mptr = (ptr);    \
        \\        (type *)( (char *)__mptr - offsetof(type,member) );})
        \\typedef struct {
        \\    int i;
        \\    struct { int x; char y; int z; } s;
        \\    float f;
        \\} container;
        \\int main(void) {
        \\    if (offsetof(container, i) != 0) abort();
        \\    if (offsetof(container, s) <= offsetof(container, i)) abort();
        \\    if (offsetof(container, f) <= offsetof(container, s)) abort();
        \\
        \\    container my_container;
        \\    typeof(my_container.s) *inner_member_pointer = &my_container.s;
        \\    float *float_member_pointer = &my_container.f;
        \\    int *anon_member_pointer = &my_container.s.z;
        \\    container *my_container_p;
        \\
        \\    my_container_p = container_of(inner_member_pointer, container, s);
        \\    if (my_container_p != &my_container) abort();
        \\
        \\    my_container_p = container_of(float_member_pointer, container, f);
        \\    if (my_container_p != &my_container) abort();
        \\
        \\    if (container_of(anon_member_pointer, typeof(my_container.s), z) != inner_member_pointer) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("handle assert.h",
        \\#include <assert.h>
        \\int main() {
        \\    int x = 1;
        \\    int *xp = &x;
        \\    assert(1);
        \\    assert(x != 0);
        \\    assert(xp);
        \\    assert(*xp);
        \\    return 0;
        \\}
    , "");

    cases.add("NDEBUG disables assert",
        \\#define NDEBUG
        \\#include <assert.h>
        \\int main() {
        \\    assert(0);
        \\    assert(NULL);
        \\    return 0;
        \\}
    , "");

    cases.add("pointer arithmetic with signed operand",
        \\#include <stdlib.h>
        \\int main() {
        \\    int array[10];
        \\    int *x = &array[5];
        \\    int *y;
        \\    int idx = 0;
        \\    y = x + ++idx;
        \\    if (y != x + 1 || y != &array[6]) abort();
        \\    y = idx + x;
        \\    if (y != x + 1 || y != &array[6]) abort();
        \\    y = x - idx;
        \\    if (y != x - 1 || y != &array[4]) abort();
        \\
        \\    idx = 0;
        \\    y = --idx + x;
        \\    if (y != x - 1 || y != &array[4]) abort();
        \\    y = idx + x;
        \\    if (y != x - 1 || y != &array[4]) abort();
        \\    y = x - idx;
        \\    if (y != x + 1 || y != &array[6]) abort();
        \\
        \\    idx = 1;
        \\    x += idx;
        \\    if (x != &array[6]) abort();
        \\    x -= idx;
        \\    if (x != &array[5]) abort();
        \\    y = (x += idx);
        \\    if (y != x || y != &array[6]) abort();
        \\    y = (x -= idx);
        \\    if (y != x || y != &array[5]) abort();
        \\
        \\    if (array + idx != &array[1] || array + 1 != &array[1]) abort();
        \\    idx = -1;
        \\    if (array - idx != &array[1]) abort();
        \\
        \\    return 0;
        \\}
    , "");

    cases.add("Compound literals",
        \\#include <stdlib.h>
        \\struct Foo {
        \\    int a;
        \\    char b[2];
        \\    float c;
        \\};
        \\int main() {
        \\    struct Foo foo;
        \\    int x = 1, y = 2;
        \\    foo = (struct Foo) {x + y, {'a', 'b'}, 42.0f};
        \\    if (foo.a != x + y || foo.b[0] != 'a' || foo.b[1] != 'b' || foo.c != 42.0f) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("Generic selections",
        \\#include <stdlib.h>
        \\#include <string.h>
        \\#include <stdint.h>
        \\#define my_generic_fn(X) _Generic((X),    \
        \\              int: abs,                   \
        \\              char *: strlen,             \
        \\              size_t: malloc,             \
        \\              default: free               \
        \\)(X)
        \\#define my_generic_val(X) _Generic((X),   \
        \\              int: 1,                     \
        \\              const char *: "bar"         \
        \\)
        \\int main(void) {
        \\    if (my_generic_val(100) != 1) abort();
        \\
        \\    const char *foo = "foo";
        \\    const char *bar = my_generic_val(foo);
        \\    if (strcmp(bar, "bar") != 0) abort();
        \\
        \\    if (my_generic_fn(-42) != 42) abort();
        \\    if (my_generic_fn("hello") != 5) abort();
        \\
        \\    size_t size = 8192;
        \\    uint8_t *mem = my_generic_fn(size);
        \\    memset(mem, 42, size);
        \\    if (mem[size - 1] != 42) abort();
        \\    my_generic_fn(mem);
        \\
        \\    return 0;
        \\}
    , "");

    // See __builtin_alloca_with_align comment in std.c.builtins
    cases.add("use of unimplemented builtin in unused function does not prevent compilation",
        \\#include <stdlib.h>
        \\void unused() {
        \\    __builtin_alloca_with_align(1, 8);
        \\}
        \\int main(void) {
        \\    if (__builtin_sqrt(1.0) != 1.0) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("convert single-statement bodies into blocks for if/else/for/while. issue #8159",
        \\#include <stdlib.h>
        \\int foo() { return 1; }
        \\int main(void) {
        \\    int i = 0;
        \\    if (i == 0) if (i == 0) if (i != 0) i = 1;
        \\    if (i != 0) i = 1; else if (i == 0) if (i == 0) i += 1;
        \\    for (; i < 10;) for (; i < 10;) i++;
        \\    while (i == 100) while (i == 100) foo();
        \\    if (0) do do "string"; while(1); while(1);
        \\    return 0;
        \\}
    , "");

    cases.add("cast RHS of compound assignment if necessary, unused result",
        \\#include <stdlib.h>
        \\int main(void) {
        \\   signed short val = -1;
        \\   val += 1; if (val != 0) abort();
        \\   val -= 1; if (val != -1) abort();
        \\   val *= 2; if (val != -2) abort();
        \\   val /= 2; if (val != -1) abort();
        \\   val %= 2; if (val != -1) abort();
        \\   val <<= 1; if (val != -2) abort();
        \\   val >>= 1; if (val != -1) abort();
        \\   val += 100000000;       // compile error if @truncate() not inserted
        \\   unsigned short uval = 1;
        \\   uval += 1; if (uval != 2) abort();
        \\   uval -= 1; if (uval != 1) abort();
        \\   uval *= 2; if (uval != 2) abort();
        \\   uval /= 2; if (uval != 1) abort();
        \\   uval %= 2; if (uval != 1) abort();
        \\   uval <<= 1; if (uval != 2) abort();
        \\   uval >>= 1; if (uval != 1) abort();
        \\   uval += 100000000;      // compile error if @truncate() not inserted
        \\}
    , "");

    cases.add("cast RHS of compound assignment if necessary, used result",
        \\#include <stdlib.h>
        \\int main(void) {
        \\   signed short foo;
        \\   signed short val = -1;
        \\   foo = (val += 1); if (foo != 0) abort();
        \\   foo = (val -= 1); if (foo != -1) abort();
        \\   foo = (val *= 2); if (foo != -2) abort();
        \\   foo = (val /= 2); if (foo != -1) abort();
        \\   foo = (val %= 2); if (foo != -1) abort();
        \\   foo = (val <<= 1); if (foo != -2) abort();
        \\   foo = (val >>= 1); if (foo != -1) abort();
        \\   foo = (val += 100000000);    // compile error if @truncate() not inserted
        \\   unsigned short ufoo;
        \\   unsigned short uval = 1;
        \\   ufoo = (uval += 1); if (ufoo != 2) abort();
        \\   ufoo = (uval -= 1); if (ufoo != 1) abort();
        \\   ufoo = (uval *= 2); if (ufoo != 2) abort();
        \\   ufoo = (uval /= 2); if (ufoo != 1) abort();
        \\   ufoo = (uval %= 2); if (ufoo != 1) abort();
        \\   ufoo = (uval <<= 1); if (ufoo != 2) abort();
        \\   ufoo = (uval >>= 1); if (ufoo != 1) abort();
        \\   ufoo = (uval += 100000000);  // compile error if @truncate() not inserted
        \\}
    , "");

    cases.add("basic vector expressions",
        \\#include <stdlib.h>
        \\#include <stdint.h>
        \\typedef int16_t  __v8hi __attribute__((__vector_size__(16)));
        \\int main(int argc, char**argv) {
        \\    __v8hi uninitialized;
        \\    __v8hi empty_init = {};
        \\    __v8hi partial_init = {0, 1, 2, 3};
        \\
        \\    __v8hi a = {0, 1, 2, 3, 4, 5, 6, 7};
        \\    __v8hi b = (__v8hi) {100, 200, 300, 400, 500, 600, 700, 800};
        \\
        \\    __v8hi sum = a + b;
        \\    for (int i = 0; i < 8; i++) {
        \\        if (sum[i] != a[i] + b[i]) abort();
        \\    }
        \\    return 0;
        \\}
    , "");

    cases.add("__builtin_shufflevector",
        \\#include <stdlib.h>
        \\#include <stdint.h>
        \\typedef int16_t  __v4hi __attribute__((__vector_size__(8)));
        \\typedef int16_t  __v8hi __attribute__((__vector_size__(16)));
        \\int main(int argc, char**argv) {
        \\    __v8hi v8_a = {0, 1, 2, 3, 4, 5, 6, 7};
        \\    __v8hi v8_b = {100, 200, 300, 400, 500, 600, 700, 800};
        \\    __v8hi shuffled = __builtin_shufflevector(v8_a, v8_b, 0, 1, 2, 3, 8, 9, 10, 11);
        \\    for (int i = 0; i < 8; i++) {
        \\        if (i < 4) {
        \\            if (shuffled[i] != v8_a[i]) abort();
        \\        } else {
        \\            if (shuffled[i] != v8_b[i - 4]) abort();
        \\        }
        \\    }
        \\    shuffled = __builtin_shufflevector(
        \\        (__v8hi) {-1, -1, -1, -1, -1, -1, -1, -1},
        \\        (__v8hi) {42, 42, 42, 42, 42, 42, 42, 42},
        \\        0, 1, 2, 3, 8, 9, 10, 11
        \\    );
        \\    for (int i = 0; i < 8; i++) {
        \\        if (i < 4) {
        \\            if (shuffled[i] != -1) abort();
        \\        } else {
        \\            if (shuffled[i] != 42) abort();
        \\        }
        \\    }
        \\    __v4hi shuffled_to_fewer_elements = __builtin_shufflevector(v8_a, v8_b, 0, 1, 8, 9);
        \\    for (int i = 0; i < 4; i++) {
        \\        if (i < 2) {
        \\            if (shuffled_to_fewer_elements[i] != v8_a[i]) abort();
        \\        } else {
        \\            if (shuffled_to_fewer_elements[i] != v8_b[i - 2]) abort();
        \\        }
        \\    }
        \\    __v4hi v4_a = {0, 1, 2, 3};
        \\    __v4hi v4_b = {100, 200, 300, 400};
        \\    __v8hi shuffled_to_more_elements = __builtin_shufflevector(v4_a, v4_b, 0, 1, 2, 3, 4, 5, 6, 7);
        \\    for (int i = 0; i < 4; i++) {
        \\        if (shuffled_to_more_elements[i] != v4_a[i]) abort();
        \\        if (shuffled_to_more_elements[i + 4] != v4_b[i]) abort();
        \\    }
        \\    return 0;
        \\}
    , "");

    cases.add("__builtin_convertvector",
        \\#include <stdlib.h>
        \\#include <stdint.h>
        \\typedef int16_t  __v8hi __attribute__((__vector_size__(16)));
        \\typedef uint16_t __v8hu __attribute__((__vector_size__(16)));
        \\int main(int argc, char**argv) {
        \\    __v8hi signed_vector = { 1, 2, 3, 4, -1, -2, -3,-4};
        \\    __v8hu unsigned_vector = __builtin_convertvector(signed_vector, __v8hu);
        \\
        \\    for (int i = 0; i < 8; i++) {
        \\        if (unsigned_vector[i] != (uint16_t)signed_vector[i]) abort();
        \\    }
        \\    return 0;
        \\}
    , "");

    cases.add("vector casting",
        \\#include <stdlib.h>
        \\#include <stdint.h>
        \\typedef int8_t __v8qi __attribute__((__vector_size__(8)));
        \\typedef uint8_t __v8qu __attribute__((__vector_size__(8)));
        \\int main(int argc, char**argv) {
        \\    __v8qi signed_vector = { 1, 2, 3, 4, -1, -2, -3,-4};
        \\
        \\    uint64_t big_int = (uint64_t) signed_vector;
        \\    if (big_int != 0x01020304FFFEFDFCULL && big_int != 0xFCFDFEFF04030201ULL) abort();
        \\    __v8qu unsigned_vector = (__v8qu) big_int;
        \\    for (int i = 0; i < 8; i++) {
        \\        if (unsigned_vector[i] != (uint8_t)signed_vector[i] && unsigned_vector[i] != (uint8_t)signed_vector[7 - i]) abort();
        \\    }
        \\    return 0;
        \\}
    , "");

    cases.add("break from switch statement. Issue #8387",
        \\#include <stdlib.h>
        \\int switcher(int x) {
        \\    switch (x) {
        \\        case 0:      // no braces
        \\            x += 1;
        \\            break;
        \\        case 1:      // conditional break
        \\            if (x == 1) {
        \\                x += 1;
        \\                break;
        \\            }
        \\            x += 100;
        \\        case 2: {    // braces with fallthrough
        \\            x += 1;
        \\        }
        \\        case 3:      // fallthrough to return statement
        \\            x += 1;
        \\        case 42: {   // random out of order case
        \\            x += 1;
        \\            return x;
        \\        }
        \\        case 4: {    // break within braces
        \\            x += 1;
        \\            break;
        \\        }
        \\        case 5:
        \\            x += 1;  // fallthrough to default
        \\        default:
        \\            x += 1;
        \\    }
        \\    return x;
        \\}
        \\int main(void) {
        \\    int expected[] = {1, 2, 5, 5, 5, 7, 7};
        \\    for (int i = 0; i < sizeof(expected) / sizeof(int); i++) {
        \\        int res = switcher(i);
        \\        if (res != expected[i]) abort();
        \\    }
        \\    if (switcher(42) != 43) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("Cast to enum from larger integral type. Issue #6011",
        \\#include <stdint.h>
        \\#include <stdlib.h>
        \\enum Foo { A, B, C };
        \\static inline enum Foo do_stuff(void) {
        \\    int64_t i = 1;
        \\    return (enum Foo)i;
        \\}
        \\int main(void) {
        \\    if (do_stuff() != B) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("Render array LHS as grouped node if necessary",
        \\#include <stdlib.h>
        \\int main(void) {
        \\    int arr[] = {40, 41, 42, 43};
        \\    if ((arr + 1)[1] != 42) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("typedef with multiple names",
        \\#include <stdlib.h>
        \\typedef struct {
        \\    char field;
        \\} a_t, b_t;
        \\
        \\int main(void) {
        \\    a_t a = { .field = 42 };
        \\    b_t b = a;
        \\    if (b.field != 42) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("__cleanup__ attribute",
        \\#include <stdlib.h>
        \\static int cleanup_count = 0;
        \\void clean_up(int *final_value) {
        \\    if (*final_value != cleanup_count++) abort();
        \\}
        \\void doit(void) {
        \\    int a __attribute__ ((__cleanup__(clean_up))) __attribute__ ((unused)) = 2;
        \\    int b __attribute__ ((__cleanup__(clean_up))) __attribute__ ((unused)) = 1;
        \\    int c __attribute__ ((__cleanup__(clean_up))) __attribute__ ((unused)) = 0;
        \\}
        \\int main(void) {
        \\    doit();
        \\    if (cleanup_count != 3) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("enum used as boolean expression",
        \\#include <stdlib.h>
        \\enum FOO {BAR, BAZ};
        \\int main(void) {
        \\    enum FOO x = BAR;
        \\    if (x) abort();
        \\    if (!BAZ) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("Flexible arrays",
        \\#include <stdlib.h>
        \\#include <stdint.h>
        \\typedef struct { char foo; int bar; } ITEM;
        \\typedef struct { size_t count; ITEM items[]; } ITEM_LIST;
        \\typedef struct { unsigned char count; int items[]; } INT_LIST;
        \\#define SIZE 10
        \\int main(void) {
        \\    ITEM_LIST *list = malloc(sizeof(ITEM_LIST) + SIZE * sizeof(ITEM));
        \\    for (int i = 0; i < SIZE; i++) list->items[i] = (ITEM) {.foo = i, .bar = i + 1};
        \\    const ITEM_LIST *const c_list = list;
        \\    for (int i = 0; i < SIZE; i++) if (c_list->items[i].foo != i || c_list->items[i].bar != i + 1) abort();
        \\    INT_LIST *int_list = malloc(sizeof(INT_LIST) + SIZE * sizeof(int));
        \\    for (int i = 0; i < SIZE; i++) int_list->items[i] = i;
        \\    const INT_LIST *const c_int_list = int_list;
        \\    const int *const ints = int_list->items;
        \\    for (int i = 0; i < SIZE; i++) if (ints[i] != i) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("enum with value that fits in c_uint but not c_int, issue #8003",
        \\#include <stdlib.h>
        \\enum my_enum {
        \\    FORCE_UINT = 0xffffffff
        \\};
        \\int main(void) {
        \\    if(FORCE_UINT != 0xffffffff) abort();
        \\}
    , "");

    cases.add("block-scope static variable shadows function parameter. Issue #8208",
        \\#include <stdlib.h>
        \\int func1(int foo) { return foo + 1; }
        \\int func2(void) {
        \\    static int foo = 5;
        \\    return foo++;
        \\}
        \\int main(void) {
        \\    if (func1(42) != 43) abort();
        \\    if (func2() != 5) abort();
        \\    if (func2() != 6) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("nested same-name static locals",
        \\#include <stdlib.h>
        \\int func(int val) {
        \\    static int foo;
        \\    if (foo != val) abort();
        \\    {
        \\        foo += 1;
        \\        static int foo = 2;
        \\        if (foo != val + 2) abort();
        \\        foo += 1;
        \\    }
        \\    return foo;
        \\}
        \\int main(void) {
        \\    int foo = 1;
        \\    if (func(0) != 1) abort();
        \\    if (func(1) != 2) abort();
        \\    if (func(2) != 3) abort();
        \\    if (foo != 1) abort();
        \\    return 0;
        \\}
    , "");

    cases.add("Enum constants are assigned correct type. Issue #9153",
        \\enum A { A0, A1=0xFFFFFFFF };
        \\enum B { B0=-1, B1=0xFFFFFFFF };
        \\enum C { C0=-1, C1=0 };
        \\enum D { D0, D1=0xFFFFFFFFFFL };
        \\enum E { E0=-1, E1=0xFFFFFFFFFFL };
        \\int main(void) {
        \\   signed char a0 = A0, a1 = A1;
        \\   signed char b0 = B0, b1 = B1;
        \\   signed char c0 = C0, c1 = C1;
        \\   signed char d0 = D0, d1 = D1;
        \\   signed char e0 = E0, e1 = E1;
        \\   return 0;
        \\}
    , "");

    cases.add("Enum constant matches enum name; multiple enumerations with same value",
        \\#include <stdlib.h>
        \\enum FOO {
        \\    FOO = 1,
        \\    BAR = 2,
        \\    BAZ = 1,
        \\};
        \\int main(void) {
        \\    enum FOO x = BAZ;
        \\    if (x != 1) abort();
        \\    if (x != BAZ) abort();
        \\    if (x != FOO) abort();
        \\}
    , "");

    cases.add("Scoped enums",
        \\#include <stdlib.h>
        \\int main(void) {
        \\   enum Foo { A, B, C };
        \\   enum Foo a = B;
        \\   if (a != B) abort();
        \\   if (a != 1) abort();
        \\   {
        \\      enum Foo { A = 5, B = 6, C = 7 };
        \\      enum Foo a = B;
        \\      if (a != B) abort();
        \\      if (a != 6) abort();
        \\   }
        \\   if (a != B) abort();
        \\   if (a != 1) abort();
        \\}
    , "");

    cases.add("Underscore identifiers",
        \\#include <stdlib.h>
        \\int _ = 10;
        \\typedef struct { int _; } S;
        \\int main(void) {
        \\    if (_ != 10) abort();
        \\    S foo = { ._ = _ };
        \\    if (foo._ != _) abort();
        \\    return 0;
        \\}
    , "");
}
