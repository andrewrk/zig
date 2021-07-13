
extern int zig_k;
extern int add_may_panic(int);

_Thread_local int  C_k = 100;
int unused(int x) { return x*x; }
int add_C(int x) { return x+zig_k+C_k; }
int add_C_zig(int x) { return add_may_panic(x) + C_k; }
