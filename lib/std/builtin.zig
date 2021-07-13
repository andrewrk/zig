// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.
const builtin = @import("builtin");

// These are all deprecated.
pub const zig_version = builtin.zig_version;
pub const zig_is_stage2 = builtin.zig_is_stage2;
pub const output_mode = builtin.output_mode;
pub const link_mode = builtin.link_mode;
pub const is_test = builtin.is_test;
pub const single_threaded = builtin.single_threaded;
pub const abi = builtin.abi;
pub const cpu = builtin.cpu;
pub const os = builtin.os;
pub const target = builtin.target;
pub const object_format = builtin.object_format;
pub const mode = builtin.mode;
pub const link_libc = builtin.link_libc;
pub const link_libcpp = builtin.link_libcpp;
pub const have_error_return_tracing = builtin.have_error_return_tracing;
pub const valgrind_support = builtin.valgrind_support;
pub const position_independent_code = builtin.position_independent_code;
pub const position_independent_executable = builtin.position_independent_executable;
pub const strip_debug_info = builtin.strip_debug_info;
pub const code_model = builtin.code_model;

/// `explicit_subsystem` is missing when the subsystem is automatically detected,
/// so Zig standard library has the subsystem detection logic here. This should generally be
/// used rather than `explicit_subsystem`.
/// On non-Windows targets, this is `null`.
pub const subsystem: ?std.Target.SubSystem = blk: {
    if (@hasDecl(builtin, "explicit_subsystem")) break :blk explicit_subsystem;
    switch (os.tag) {
        .windows => {
            if (is_test) {
                break :blk std.Target.SubSystem.Console;
            }
            if (@hasDecl(root, "main") or
                @hasDecl(root, "WinMain") or
                @hasDecl(root, "wWinMain") or
                @hasDecl(root, "WinMainCRTStartup") or
                @hasDecl(root, "wWinMainCRTStartup"))
            {
                break :blk std.Target.SubSystem.Windows;
            } else {
                break :blk std.Target.SubSystem.Console;
            }
        },
        else => break :blk null,
    }
};

/// This data structure is used by the Zig language code generation and
/// therefore must be kept in sync with the compiler implementation.
pub const StackTrace = struct {
    index: usize,
    instruction_addresses: []usize,

    pub fn format(
        self: StackTrace,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const debug_info = std.debug.getSelfDebugInfo() catch |err| {
            return writer.print("\nUnable to print stack trace: Unable to open debug info: {s}\n", .{@errorName(err)});
        };
        const tty_config = std.debug.detectTTYConfig();
        try writer.writeAll("\n");
        std.debug.writeStackTrace(self, writer, &arena.allocator, debug_info, tty_config) catch |err| {
            try writer.print("Unable to print stack trace: {s}\n", .{@errorName(err)});
        };
        try writer.writeAll("\n");
    }
};

/// This data structure is used by the Zig language code generation and
/// therefore must be kept in sync with the compiler implementation.
pub const GlobalLinkage = enum {
    Internal,
    Strong,
    Weak,
    LinkOnce,
};

/// This data structure is used by the Zig language code generation and
/// therefore must be kept in sync with the compiler implementation.
pub const AtomicOrder = enum {
    Unordered,
    Monotonic,
    Acquire,
    Release,
    AcqRel,
    SeqCst,
};

/// This data structure is used by the Zig language code generation and
/// therefore must be kept in sync with the compiler implementation.
pub const ReduceOp = enum {
    And,
    Or,
    Xor,
    Min,
    Max,
    Add,
    Mul,
};

/// This data structure is used by the Zig language code generation and
/// therefore must be kept in sync with the compiler implementation.
pub const AtomicRmwOp = enum {
    Xchg,
    Add,
    Sub,
    And,
    Nand,
    Or,
    Xor,
    Max,
    Min,
};

/// The code model puts constraints on the location of symbols and the size of code and data.
/// The selection of a code model is a trade off on speed and restrictions that needs to be selected on a per application basis to meet its requirements.
/// A slightly more detailed explanation can be found in (for example) the [System V Application Binary Interface (x86_64)](https://github.com/hjl-tools/x86-psABI/wiki/x86-64-psABI-1.0.pdf) 3.5.1.
///
/// This data structure is used by the Zig language code generation and
/// therefore must be kept in sync with the compiler implementation.
pub const CodeModel = enum {
    default,
    tiny,
    small,
    kernel,
    medium,
    large,
};

/// This data structure is used by the Zig language code generation and
/// therefore must be kept in sync with the compiler implementation.
pub const Mode = enum {
    Debug,
    ReleaseSafe,
    ReleaseFast,
    ReleaseSmall,
};

/// This data structure is used by the Zig language code generation and
/// therefore must be kept in sync with the compiler implementation.
pub const CallingConvention = enum {
    Unspecified,
    C,
    Naked,
    Async,
    Inline,
    Interrupt,
    Signal,
    Stdcall,
    Fastcall,
    Vectorcall,
    Thiscall,
    APCS,
    AAPCS,
    AAPCSVFP,
    SysV,
};

/// This data structure is used by the Zig language code generation and
/// therefore must be kept in sync with the compiler implementation.
pub const SourceLocation = struct {
    file: [:0]const u8,
    fn_name: [:0]const u8,
    line: u32,
    column: u32,
};

pub const TypeId = std.meta.Tag(TypeInfo);

/// This data structure is used by the Zig language code generation and
/// therefore must be kept in sync with the compiler implementation.
pub const TypeInfo = union(enum) {
    Type: void,
    Void: void,
    Bool: void,
    NoReturn: void,
    Int: Int,
    Float: Float,
    Pointer: Pointer,
    Array: Array,
    Struct: Struct,
    ComptimeFloat: void,
    ComptimeInt: void,
    Undefined: void,
    Null: void,
    Optional: Optional,
    ErrorUnion: ErrorUnion,
    ErrorSet: ErrorSet,
    Enum: Enum,
    Union: Union,
    Fn: Fn,
    BoundFn: Fn,
    Opaque: Opaque,
    Frame: Frame,
    AnyFrame: AnyFrame,
    Vector: Vector,
    EnumLiteral: void,

    /// This data structure is used by the Zig language code generation and
    /// therefore must be kept in sync with the compiler implementation.
    pub const Int = struct {
        signedness: Signedness,
        bits: comptime_int,
    };

    /// This data structure is used by the Zig language code generation and
    /// therefore must be kept in sync with the compiler implementation.
    pub const Float = struct {
        bits: comptime_int,
    };

    /// This data structure is used by the Zig language code generation and
    /// therefore must be kept in sync with the compiler implementation.
    pub const Pointer = struct {
        size: Size,
        is_const: bool,
        is_volatile: bool,
        alignment: comptime_int,
        child: type,
        is_allowzero: bool,

        /// This field is an optional type.
        /// The type of the sentinel is the element type of the pointer, which is
        /// the value of the `child` field in this struct. However there is no way
        /// to refer to that type here, so we use `var`.
        sentinel: anytype,

        /// This data structure is used by the Zig language code generation and
        /// therefore must be kept in sync with the compiler implementation.
        pub const Size = enum {
            One,
            Many,
            Slice,
            C,
        };
    };

    /// This data structure is used by the Zig language code generation and
    /// therefore must be kept in sync with the compiler implementation.
    pub const Array = struct {
        len: comptime_int,
        child: type,

        /// This field is an optional type.
        /// The type of the sentinel is the element type of the array, which is
        /// the value of the `child` field in this struct. However there is no way
        /// to refer to that type here, so we use `var`.
        sentinel: anytype,
    };

    /// This data structure is used by the Zig language code generation and
    /// therefore must be kept in sync with the compiler implementation.
    pub const ContainerLayout = enum(u2) {
        Auto,
        Extern,
        Packed,
    };

    /// This data structure is used by the Zig language code generation and
    /// therefore must be kept in sync with the compiler implementation.
    pub const StructField = struct {
        name: []const u8,
        field_type: type,
        default_value: anytype,
        is_comptime: bool,
        alignment: comptime_int,
    };

    /// This data structure is used by the Zig language code generation and
    /// therefore must be kept in sync with the compiler implementation.
    pub const Struct = struct {
        layout: ContainerLayout,
        fields: []const StructField,
        decls: []const Declaration,
        is_tuple: bool,
    };

    /// This data structure is used by the Zig language code generation and
    /// therefore must be kept in sync with the compiler implementation.
    pub const Optional = struct {
        child: type,
    };

    /// This data structure is used by the Zig language code generation and
    /// therefore must be kept in sync with the compiler implementation.
    pub const ErrorUnion = struct {
        error_set: type,
        payload: type,
    };

    /// This data structure is used by the Zig language code generation and
    /// therefore must be kept in sync with the compiler implementation.
    pub const Error = struct {
        name: []const u8,
    };

    /// This data structure is used by the Zig language code generation and
    /// therefore must be kept in sync with the compiler implementation.
    pub const ErrorSet = ?[]const Error;

    /// This data structure is used by the Zig language code generation and
    /// therefore must be kept in sync with the compiler implementation.
    pub const EnumField = struct {
        name: []const u8,
        value: comptime_int,
    };

    /// This data structure is used by the Zig language code generation and
    /// therefore must be kept in sync with the compiler implementation.
    pub const Enum = struct {
        layout: ContainerLayout,
        tag_type: type,
        fields: []const EnumField,
        decls: []const Declaration,
        is_exhaustive: bool,
    };

    /// This data structure is used by the Zig language code generation and
    /// therefore must be kept in sync with the compiler implementation.
    pub const UnionField = struct {
        name: []const u8,
        field_type: type,
        alignment: comptime_int,
    };

    /// This data structure is used by the Zig language code generation and
    /// therefore must be kept in sync with the compiler implementation.
    pub const Union = struct {
        layout: ContainerLayout,
        tag_type: ?type,
        fields: []const UnionField,
        decls: []const Declaration,
    };

    /// This data structure is used by the Zig language code generation and
    /// therefore must be kept in sync with the compiler implementation.
    pub const FnArg = struct {
        is_generic: bool,
        is_noalias: bool,
        arg_type: ?type,
    };

    /// This data structure is used by the Zig language code generation and
    /// therefore must be kept in sync with the compiler implementation.
    pub const Fn = struct {
        calling_convention: CallingConvention,
        alignment: comptime_int,
        is_generic: bool,
        is_var_args: bool,
        return_type: ?type,
        args: []const FnArg,
    };

    /// This data structure is used by the Zig language code generation and
    /// therefore must be kept in sync with the compiler implementation.
    pub const Opaque = struct {
        decls: []const Declaration,
    };

    /// This data structure is used by the Zig language code generation and
    /// therefore must be kept in sync with the compiler implementation.
    pub const Frame = struct {
        function: anytype,
    };

    /// This data structure is used by the Zig language code generation and
    /// therefore must be kept in sync with the compiler implementation.
    pub const AnyFrame = struct {
        child: ?type,
    };

    /// This data structure is used by the Zig language code generation and
    /// therefore must be kept in sync with the compiler implementation.
    pub const Vector = struct {
        len: comptime_int,
        child: type,
    };

    /// This data structure is used by the Zig language code generation and
    /// therefore must be kept in sync with the compiler implementation.
    pub const Declaration = struct {
        name: []const u8,
        is_pub: bool,
        data: Data,

        /// This data structure is used by the Zig language code generation and
        /// therefore must be kept in sync with the compiler implementation.
        pub const Data = union(enum) {
            Type: type,
            Var: type,
            Fn: FnDecl,

            /// This data structure is used by the Zig language code generation and
            /// therefore must be kept in sync with the compiler implementation.
            pub const FnDecl = struct {
                fn_type: type,
                is_noinline: bool,
                is_var_args: bool,
                is_extern: bool,
                is_export: bool,
                lib_name: ?[]const u8,
                return_type: type,
                arg_names: []const []const u8,
            };
        };
    };
};

/// This data structure is used by the Zig language code generation and
/// therefore must be kept in sync with the compiler implementation.
pub const FloatMode = enum {
    Strict,
    Optimized,
};

/// This data structure is used by the Zig language code generation and
/// therefore must be kept in sync with the compiler implementation.
pub const Endian = enum {
    Big,
    Little,
};

/// This data structure is used by the Zig language code generation and
/// therefore must be kept in sync with the compiler implementation.
pub const Signedness = enum {
    signed,
    unsigned,
};

/// This data structure is used by the Zig language code generation and
/// therefore must be kept in sync with the compiler implementation.
pub const OutputMode = enum {
    Exe,
    Lib,
    Obj,
};

/// This data structure is used by the Zig language code generation and
/// therefore must be kept in sync with the compiler implementation.
pub const LinkMode = enum {
    Static,
    Dynamic,
};

/// This data structure is used by the Zig language code generation and
/// therefore must be kept in sync with the compiler implementation.
pub const WasiExecModel = enum {
    command,
    reactor,
};

/// This data structure is used by the Zig language code generation and
/// therefore must be kept in sync with the compiler implementation.
pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32 = 0,

    pub const Range = struct {
        min: Version,
        max: Version,

        pub fn includesVersion(self: Range, ver: Version) bool {
            if (self.min.order(ver) == .gt) return false;
            if (self.max.order(ver) == .lt) return false;
            return true;
        }

        /// Checks if system is guaranteed to be at least `version` or older than `version`.
        /// Returns `null` if a runtime check is required.
        pub fn isAtLeast(self: Range, ver: Version) ?bool {
            if (self.min.order(ver) != .lt) return true;
            if (self.max.order(ver) == .lt) return false;
            return null;
        }
    };

    pub fn order(lhs: Version, rhs: Version) std.math.Order {
        if (lhs.major < rhs.major) return .lt;
        if (lhs.major > rhs.major) return .gt;
        if (lhs.minor < rhs.minor) return .lt;
        if (lhs.minor > rhs.minor) return .gt;
        if (lhs.patch < rhs.patch) return .lt;
        if (lhs.patch > rhs.patch) return .gt;
        return .eq;
    }

    pub fn parse(text: []const u8) !Version {
        var end: usize = 0;
        while (end < text.len) : (end += 1) {
            const c = text[end];
            if (!std.ascii.isDigit(c) and c != '.') break;
        }
        // found no digits or '.' before unexpected character
        if (end == 0) return error.InvalidVersion;

        var it = std.mem.split(text[0..end], ".");
        // substring is not empty, first call will succeed
        const major = it.next().?;
        if (major.len == 0) return error.InvalidVersion;
        const minor = it.next() orelse "0";
        // ignore 'patch' if 'minor' is invalid
        const patch = if (minor.len == 0) "0" else (it.next() orelse "0");

        return Version{
            .major = try std.fmt.parseUnsigned(u32, major, 10),
            .minor = try std.fmt.parseUnsigned(u32, if (minor.len == 0) "0" else minor, 10),
            .patch = try std.fmt.parseUnsigned(u32, if (patch.len == 0) "0" else patch, 10),
        };
    }

    pub fn format(
        self: Version,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        out_stream: anytype,
    ) !void {
        _ = options;
        if (fmt.len == 0) {
            if (self.patch == 0) {
                if (self.minor == 0) {
                    return std.fmt.format(out_stream, "{d}", .{self.major});
                } else {
                    return std.fmt.format(out_stream, "{d}.{d}", .{ self.major, self.minor });
                }
            } else {
                return std.fmt.format(out_stream, "{d}.{d}.{d}", .{ self.major, self.minor, self.patch });
            }
        } else {
            @compileError("Unknown format string: '" ++ fmt ++ "'");
        }
    }
};

test "Version.parse" {
    @setEvalBranchQuota(3000);
    try testVersionParse();
    comptime (try testVersionParse());
}

pub fn testVersionParse() !void {
    const f = struct {
        fn eql(text: []const u8, v1: u32, v2: u32, v3: u32) !void {
            const v = try Version.parse(text);
            try std.testing.expect(v.major == v1 and v.minor == v2 and v.patch == v3);
        }

        fn err(text: []const u8, expected_err: anyerror) !void {
            _ = Version.parse(text) catch |actual_err| {
                if (actual_err == expected_err) return;
                return actual_err;
            };
            return error.Unreachable;
        }
    };

    try f.eql("2.6.32.11-svn21605", 2, 6, 32); // Debian PPC
    try f.eql("2.11.2(0.329/5/3)", 2, 11, 2); // MinGW
    try f.eql("5.4.0-1018-raspi", 5, 4, 0); // Ubuntu
    try f.eql("5.7.12_3", 5, 7, 12); // Void
    try f.eql("2.13-DEVELOPMENT", 2, 13, 0); // DragonFly
    try f.eql("2.3-35", 2, 3, 0);
    try f.eql("1a.4", 1, 0, 0);
    try f.eql("3.b1.0", 3, 0, 0);
    try f.eql("1.4beta", 1, 4, 0);
    try f.eql("2.7.pre", 2, 7, 0);
    try f.eql("0..3", 0, 0, 0);
    try f.eql("8.008.", 8, 8, 0);
    try f.eql("01...", 1, 0, 0);
    try f.eql("55", 55, 0, 0);
    try f.eql("4294967295.0.1", 4294967295, 0, 1);
    try f.eql("429496729_6", 429496729, 0, 0);

    try f.err("foobar", error.InvalidVersion);
    try f.err("", error.InvalidVersion);
    try f.err("-1", error.InvalidVersion);
    try f.err("+4", error.InvalidVersion);
    try f.err(".", error.InvalidVersion);
    try f.err("....3", error.InvalidVersion);
    try f.err("4294967296", error.Overflow);
    try f.err("5000877755", error.Overflow);
    // error.InvalidCharacter is not possible anymore
}

/// This data structure is used by the Zig language code generation and
/// therefore must be kept in sync with the compiler implementation.
pub const CallOptions = struct {
    modifier: Modifier = .auto,

    /// Only valid when `Modifier` is `Modifier.async_kw`.
    stack: ?[]align(std.Target.stack_align) u8 = null,

    pub const Modifier = enum {
        /// Equivalent to function call syntax.
        auto,

        /// Equivalent to async keyword used with function call syntax.
        async_kw,

        /// Prevents tail call optimization. This guarantees that the return
        /// address will point to the callsite, as opposed to the callsite's
        /// callsite. If the call is otherwise required to be tail-called
        /// or inlined, a compile error is emitted instead.
        never_tail,

        /// Guarantees that the call will not be inlined. If the call is
        /// otherwise required to be inlined, a compile error is emitted instead.
        never_inline,

        /// Asserts that the function call will not suspend. This allows a
        /// non-async function to call an async function.
        no_async,

        /// Guarantees that the call will be generated with tail call optimization.
        /// If this is not possible, a compile error is emitted instead.
        always_tail,

        /// Guarantees that the call will inlined at the callsite.
        /// If this is not possible, a compile error is emitted instead.
        always_inline,

        /// Evaluates the call at compile-time. If the call cannot be completed at
        /// compile-time, a compile error is emitted instead.
        compile_time,
    };
};

/// This data structure is used by the Zig language code generation and
/// therefore must be kept in sync with the compiler implementation.
pub const ExportOptions = struct {
    name: []const u8,
    linkage: GlobalLinkage = .Strong,
    section: ?[]const u8 = null,
};

/// This data structure is used by the Zig language code generation and
/// therefore must be kept in sync with the compiler implementation.
pub const ExternOptions = struct {
    name: []const u8,
    library_name: ?[]const u8 = null,
    linkage: GlobalLinkage = .Strong,
    is_thread_local: bool = false,
};

/// This function type is used by the Zig language code generation and
/// therefore must be kept in sync with the compiler implementation.
pub const TestFn = struct {
    name: []const u8,
    func: fn () anyerror!void,
    async_frame_size: ?usize,
};

/// This function type is used by the Zig language code generation and
/// therefore must be kept in sync with the compiler implementation.
pub const PanicFn = fn ([]const u8, ?*StackTrace) noreturn;

/// This function is used by the Zig language code generation and
/// therefore must be kept in sync with the compiler implementation.
pub const panic: PanicFn = if (@hasDecl(root, "panic")) root.panic else default_panic;

/// This function is used by the Zig language code generation and
/// therefore must be kept in sync with the compiler implementation.
pub fn default_panic(msg: []const u8, error_return_trace: ?*StackTrace) noreturn {
    @setCold(true);
    // Until self-hosted catches up with stage1 language features, we have a simpler
    // default panic function:
    if (builtin.zig_is_stage2) {
        while (true) {
            @breakpoint();
        }
    }
    if (@hasDecl(root, "os") and @hasDecl(root.os, "panic")) {
        root.os.panic(msg, error_return_trace);
        unreachable;
    }
    switch (os.tag) {
        .freestanding => {
            while (true) {
                @breakpoint();
            }
        },
        .wasi => {
            std.debug.warn("{s}", .{msg});
            std.os.abort();
        },
        .uefi => {
            // TODO look into using the debug info and logging helpful messages
            std.os.abort();
        },
        else => {
            const first_trace_addr = @returnAddress();
            std.debug.panicImpl(error_return_trace, first_trace_addr, msg);
        },
    }
}

const std = @import("std.zig");
const root = @import("root");
