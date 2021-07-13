// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.
const std = @import("std.zig");
const builtin = std.builtin;
const math = std.math;
const mem = std.mem;
const io = std.io;
const os = std.os;
const fs = std.fs;
const process = std.process;
const elf = std.elf;
const DW = std.dwarf;
const root = @import("root");
const windows = os.windows;
const native_arch = std.Target.current.cpu.arch;
const native_os = std.Target.current.os.tag;

pub const runtime_safety = switch (builtin.mode) {
    .Debug, .ReleaseSafe => true,
    .ReleaseFast, .ReleaseSmall => false,
};

// TODO: improve error approach somehow, anyerror shouldn't be used here.

/// Interface for mapping from addresses to symbols (`SymbolInfo`).
pub const SymbolMap = struct {
    pub const LineInfo = struct {
        line: u64,
        column: u64,
        file_name: []const u8,
        allocator: ?*mem.Allocator,

        fn deinit(self: @This()) void {
            const allocator = self.allocator orelse return;
            allocator.free(self.file_name);
        }
    };

    pub const SymbolInfo = struct {
        symbol_name: []const u8 = "???",
        compile_unit_name: []const u8 = "???",
        line_info: ?LineInfo = null,

        fn deinit(self: @This()) void {
            if (self.line_info) |li| {
                li.deinit();
            }
        }
    };

    const Self = @This();

    deinitFn: fn (self: *Self) void,
    addressToSymbolFn: fn (self: *Self, address: usize) anyerror!SymbolInfo,

    fn deinit(self: *Self) void {
        self.deinitFn(self);
    }

    fn addressToSymbol(self: *Self, address: usize) anyerror!SymbolInfo {
        return self.addressToSymbolFn(self, address);
    }

    pub const InitFn = fn (allocator: *mem.Allocator) anyerror!*Self;

    test {
        std.testing.refAllDecls(@This());
    }
};

pub const initSymbolMapDarwin = @import("symbol_map_darwin.zig").init;
pub const initSymbolMapUnix = @import("symbol_map_unix.zig").init;
pub const initSymbolMapWindows = @import("symbol_map_windows.zig").init;
pub const initSymbolMapUnsupported = @import("symbol_map_unsupported.zig").init;

pub const default_config = struct {
    /// A function to initialize a object of the interface type SymbolMap.
    pub const initSymbolMap: SymbolMap.InitFn = switch (builtin.os.tag) {
        .macos, .ios, .watchos, .tvos => initSymbolMapDarwin,
        .linux, .netbsd, .freebsd, .dragonfly, .openbsd => initSymbolMapUnix,
        .uefi, .windows => initSymbolMapWindows,
        else => initSymbolMapUnsupported,
    };

    test {
        std.testing.refAllDecls(@This());
    }
};

// Slightly different names than in config to avoid redefinition in default.

const initSymMap: SymbolMap.InitFn =
    if (@hasDecl(root, "debug_config") and @hasDecl(root.debug_config, "initSymbolMap"))
    root.debug_config.initSymbolMap
else if (@hasDecl(root, "os") and @hasDecl(root.os, "debug") and
    @hasDecl(root.os.debug, "initSymbolMap"))
    root.os.debug.initSymbolMap
else
    default_config.initSymbolMap;

var stderr_mutex = std.Thread.Mutex{};

/// Deprecated. Use `std.log` functions for logging or `std.debug.print` for
/// "printf debugging".
pub const warn = print;

/// Print to stderr, unbuffered, and silently returning on failure. Intended
/// for use in "printf debugging." Use `std.log` functions for proper logging.
pub fn print(comptime fmt: []const u8, args: anytype) void {
    const held = stderr_mutex.acquire();
    defer held.release();
    const stderr = io.getStdErr().writer();
    nosuspend stderr.print(fmt, args) catch return;
}

pub fn getStderrMutex() *std.Thread.Mutex {
    return &stderr_mutex;
}

/// TODO multithreaded awareness
var sym_map: ?*SymbolMap = null;

pub fn getSymbolMap() !*SymbolMap {
    if (sym_map) |info| {
        return info;
    } else {
        sym_map = try initSymMap(getDebugInfoAllocator());
        return sym_map.?;
    }
}

fn getSymbolMapForDump(writer: anytype) ?*SymbolMap {
    return getSymbolMap() catch |err| {
        writer.print(
            "Unable to dump stack trace: Unable to get symbol map (open debug info): {s}\n",
            .{@errorName(err)},
        ) catch {};
        return null;
    };
}

fn dumpHandleError(writer: anytype, err: anytype) void {
    writer.print("Unable to dump stack trace: {s}\n", .{@errorName(err)}) catch {};
}

pub fn detectTTYConfig() TTY.Config {
    if (process.hasEnvVarConstant("ZIG_DEBUG_COLOR")) {
        return .escape_codes;
    } else if (process.hasEnvVarConstant("NO_COLOR")) {
        return .no_color;
    } else {
        const stderr_file = io.getStdErr();
        if (stderr_file.supportsAnsiEscapeCodes()) {
            return .escape_codes;
        } else if (native_os == .windows and stderr_file.isTty()) {
            return .windows_api;
        } else {
            return .no_color;
        }
    }
}

/// Tries to print the current stack trace to stderr, unbuffered, and ignores any error returned.
/// TODO multithreaded awareness
pub fn dumpCurrentStackTrace(start_addr: ?usize) void {
    nosuspend {
        const stderr = io.getStdErr().writer();
        if (getSymbolMapForDump(stderr)) |symbol_map| {
            writeCurrentStackTrace(stderr, symbol_map, detectTTYConfig(), start_addr) catch |err| {
                dumpHandleError(stderr, err);
            };
        }
    }
}

/// Tries to print the stack trace starting from the supplied base pointer to stderr,
/// unbuffered, and ignores any error returned.
/// TODO multithreaded awareness
pub fn dumpStackTraceFromBase(bp: usize, ip: usize) void {
    nosuspend {
        const stderr = io.getStdErr().writer();
        if (getSymbolMapForDump(stderr)) |symbol_map| {
            const tty_config = detectTTYConfig();
            printSourceAtAddress(symbol_map, stderr, ip, tty_config) catch return;
            var it = StackIterator.init(null, bp);
            while (it.next()) |return_address| {
                printSourceAtAddress(symbol_map, stderr, return_address - 1, tty_config) catch return;
            }
        }
    }
}

/// Returns a slice with the same pointer as addresses, with a potentially smaller len.
/// On Windows, when first_address is not null, we ask for at least 32 stack frames,
/// and then try to find the first address. If addresses.len is more than 32, we
/// capture that many stack frames exactly, and then look for the first address,
/// chopping off the irrelevant frames and shifting so that the returned addresses pointer
/// equals the passed in addresses pointer.
pub fn captureStackTrace(first_address: ?usize, stack_trace: *builtin.StackTrace) void {
    if (native_os == .windows) {
        const addrs = stack_trace.instruction_addresses;
        const u32_addrs_len = @intCast(u32, addrs.len);
        const first_addr = first_address orelse {
            stack_trace.index = windows.ntdll.RtlCaptureStackBackTrace(
                0,
                u32_addrs_len,
                @ptrCast(**c_void, addrs.ptr),
                null,
            );
            return;
        };
        var addr_buf_stack: [32]usize = undefined;
        const addr_buf = if (addr_buf_stack.len > addrs.len) addr_buf_stack[0..] else addrs;
        const n = windows.ntdll.RtlCaptureStackBackTrace(0, u32_addrs_len, @ptrCast(**c_void, addr_buf.ptr), null);
        const first_index = for (addr_buf[0..n]) |addr, i| {
            if (addr == first_addr) {
                break i;
            }
        } else {
            stack_trace.index = 0;
            return;
        };
        const slice = addr_buf[first_index..n];
        // We use a for loop here because slice and addrs may alias.
        for (slice) |addr, i| {
            addrs[i] = addr;
        }
        stack_trace.index = slice.len;
    } else {
        var it = StackIterator.init(first_address, null);
        for (stack_trace.instruction_addresses) |*addr, i| {
            addr.* = it.next() orelse {
                stack_trace.index = i;
                return;
            };
        }
        stack_trace.index = stack_trace.instruction_addresses.len;
    }
}

/// Tries to print a stack trace to stderr, unbuffered, and ignores any error returned.
/// TODO multithreaded awareness
pub fn dumpStackTrace(stack_trace: builtin.StackTrace) void {
    nosuspend {
        const stderr = io.getStdErr().writer();
        if (getSymbolMapForDump(stderr)) |symbol_map| {
            writeStackTrace(stack_trace, stderr, getDebugInfoAllocator(), symbol_map, detectTTYConfig()) catch |err| {
                dumpHandleError(stderr, err);
            };
        }
    }
}

/// This function invokes undefined behavior when `ok` is `false`.
/// In Debug and ReleaseSafe modes, calls to this function are always
/// generated, and the `unreachable` statement triggers a panic.
/// In ReleaseFast and ReleaseSmall modes, calls to this function are
/// optimized away, and in fact the optimizer is able to use the assertion
/// in its heuristics.
/// Inside a test block, it is best to use the `std.testing` module rather
/// than this function, because this function may not detect a test failure
/// in ReleaseFast and ReleaseSmall mode. Outside of a test block, this assert
/// function is the correct function to use.
pub fn assert(ok: bool) void {
    if (!ok) unreachable; // assertion failure
}

pub fn panic(comptime format: []const u8, args: anytype) noreturn {
    @setCold(true);
    // TODO: remove conditional once wasi / LLVM defines __builtin_return_address
    const first_trace_addr = if (native_os == .wasi) null else @returnAddress();
    panicExtra(null, first_trace_addr, format, args);
}

/// Non-zero whenever the program triggered a panic.
/// The counter is incremented/decremented atomically.
var panicking: u8 = 0;

// Locked to avoid interleaving panic messages from multiple threads.
var panic_mutex = std.Thread.Mutex{};

/// Counts how many times the panic handler is invoked by this thread.
/// This is used to catch and handle panics triggered by the panic handler.
threadlocal var panic_stage: usize = 0;

pub fn panicExtra(trace: ?*const builtin.StackTrace, first_trace_addr: ?usize, comptime format: []const u8, args: anytype) noreturn {
    @setCold(true);

    if (enable_segfault_handler) {
        // If a segfault happens while panicking, we want it to actually segfault, not trigger
        // the handler.
        resetSegfaultHandler();
    }

    nosuspend switch (panic_stage) {
        0 => {
            panic_stage = 1;

            _ = @atomicRmw(u8, &panicking, .Add, 1, .SeqCst);

            // Make sure to release the mutex when done
            {
                const held = panic_mutex.acquire();
                defer held.release();

                const stderr = io.getStdErr().writer();
                if (builtin.single_threaded) {
                    stderr.print("panic: ", .{}) catch os.abort();
                } else {
                    const current_thread_id = std.Thread.getCurrentId();
                    stderr.print("thread {} panic: ", .{current_thread_id}) catch os.abort();
                }
                stderr.print(format ++ "\n", args) catch os.abort();
                if (trace) |t| {
                    dumpStackTrace(t.*);
                }
                dumpCurrentStackTrace(first_trace_addr);
            }

            if (@atomicRmw(u8, &panicking, .Sub, 1, .SeqCst) != 1) {
                // Another thread is panicking, wait for the last one to finish
                // and call abort()

                // Sleep forever without hammering the CPU
                var event: std.Thread.StaticResetEvent = .{};
                event.wait();
                unreachable;
            }
        },
        1 => {
            panic_stage = 2;

            // A panic happened while trying to print a previous panic message,
            // we're still holding the mutex but that's fine as we're going to
            // call abort()
            const stderr = io.getStdErr().writer();
            stderr.print("Panicked during a panic. Aborting.\n", .{}) catch os.abort();
        },
        else => {
            // Panicked while printing "Panicked during a panic."
        },
    };

    os.abort();
}

const RED = "\x1b[31;1m";
const GREEN = "\x1b[32;1m";
const CYAN = "\x1b[36;1m";
const WHITE = "\x1b[37;1m";
const BOLD = "\x1b[1m";
const DIM = "\x1b[2m";
const RESET = "\x1b[0m";

pub fn writeStackTrace(
    stack_trace: builtin.StackTrace,
    out_stream: anytype,
    allocator: *mem.Allocator,
    symbol_map: *SymbolMap,
    tty_config: TTY.Config,
) !void {
    _ = allocator;
    if (builtin.strip_debug_info) return error.MissingDebugInfo;
    var frame_index: usize = 0;
    var frames_left: usize = std.math.min(stack_trace.index, stack_trace.instruction_addresses.len);

    while (frames_left != 0) : ({
        frames_left -= 1;
        frame_index = (frame_index + 1) % stack_trace.instruction_addresses.len;
    }) {
        const return_address = stack_trace.instruction_addresses[frame_index];
        try printSourceAtAddress(symbol_map, out_stream, return_address - 1, tty_config);
    }
}

pub const StackIterator = struct {
    // Skip every frame before this address is found.
    first_address: ?usize,
    // Last known value of the frame pointer register.
    fp: usize,

    pub fn init(first_address: ?usize, fp: ?usize) StackIterator {
        if (native_arch == .sparcv9) {
            // Flush all the register windows on stack.
            asm volatile (
                \\ flushw
                ::: "memory");
        }

        return StackIterator{
            .first_address = first_address,
            .fp = fp orelse @frameAddress(),
        };
    }

    // Offset of the saved BP wrt the frame pointer.
    const fp_offset = if (native_arch.isRISCV())
        // On RISC-V the frame pointer points to the top of the saved register
        // area, on pretty much every other architecture it points to the stack
        // slot where the previous frame pointer is saved.
        2 * @sizeOf(usize)
    else if (native_arch.isSPARC())
        // On SPARC the previous frame pointer is stored at 14 slots past %fp+BIAS.
        14 * @sizeOf(usize)
    else
        0;

    const fp_bias = if (native_arch.isSPARC())
        // On SPARC frame pointers are biased by a constant.
        2047
    else
        0;

    // Positive offset of the saved PC wrt the frame pointer.
    const pc_offset = if (native_arch == .powerpc64le)
        2 * @sizeOf(usize)
    else
        @sizeOf(usize);

    pub fn next(self: *StackIterator) ?usize {
        var address = self.next_internal() orelse return null;

        if (self.first_address) |first_address| {
            while (address != first_address) {
                address = self.next_internal() orelse return null;
            }
            self.first_address = null;
        }

        return address;
    }

    fn next_internal(self: *StackIterator) ?usize {
        const fp = if (comptime native_arch.isSPARC())
            // On SPARC the offset is positive. (!)
            math.add(usize, self.fp, fp_offset) catch return null
        else
            math.sub(usize, self.fp, fp_offset) catch return null;

        // Sanity check.
        if (fp == 0 or !mem.isAligned(fp, @alignOf(usize)))
            return null;

        const new_fp = math.add(usize, @intToPtr(*const usize, fp).*, fp_bias) catch return null;

        // Sanity check: the stack grows down thus all the parent frames must be
        // be at addresses that are greater (or equal) than the previous one.
        // A zero frame pointer often signals this is the last frame, that case
        // is gracefully handled by the next call to next_internal.
        if (new_fp != 0 and new_fp < self.fp)
            return null;

        const new_pc = @intToPtr(
            *const usize,
            math.add(usize, fp, pc_offset) catch return null,
        ).*;

        self.fp = new_fp;

        return new_pc;
    }
};

pub fn writeCurrentStackTrace(
    out_stream: anytype,
    symbol_map: *SymbolMap,
    tty_config: TTY.Config,
    start_addr: ?usize,
) !void {
    if (native_os == .windows) {
        return writeCurrentStackTraceWindows(out_stream, symbol_map, tty_config, start_addr);
    }
    var it = StackIterator.init(start_addr, null);
    while (it.next()) |return_address| {
        try printSourceAtAddress(symbol_map, out_stream, return_address - 1, tty_config);
    }
}

pub fn writeCurrentStackTraceWindows(
    out_stream: anytype,
    symbol_map: *SymbolMap,
    tty_config: TTY.Config,
    start_addr: ?usize,
) !void {
    var addr_buf: [1024]usize = undefined;
    const n = windows.ntdll.RtlCaptureStackBackTrace(0, addr_buf.len, @ptrCast(**c_void, &addr_buf), null);
    const addrs = addr_buf[0..n];
    var start_i: usize = if (start_addr) |saddr| blk: {
        for (addrs) |addr, i| {
            if (addr == saddr) break :blk i;
        }
        return;
    } else 0;
    for (addrs[start_i..]) |addr| {
        try printSourceAtAddress(symbol_map, out_stream, addr - 1, tty_config);
    }
}

pub const TTY = struct {
    pub const Color = enum {
        Red,
        Green,
        Cyan,
        White,
        Dim,
        Bold,
        Reset,
    };

    pub const Config = enum {
        no_color,
        escape_codes,
        // TODO give this a payload of file handle
        windows_api,

        pub fn setColor(conf: Config, out_stream: anytype, color: Color) void {
            nosuspend switch (conf) {
                .no_color => return,
                .escape_codes => switch (color) {
                    .Red => out_stream.writeAll(RED) catch return,
                    .Green => out_stream.writeAll(GREEN) catch return,
                    .Cyan => out_stream.writeAll(CYAN) catch return,
                    .White => out_stream.writeAll(WHITE) catch return,
                    .Dim => out_stream.writeAll(DIM) catch return,
                    .Bold => out_stream.writeAll(BOLD) catch return,
                    .Reset => out_stream.writeAll(RESET) catch return,
                },
                .windows_api => if (native_os == .windows) {
                    const stderr_file = io.getStdErr();
                    const S = struct {
                        var attrs: windows.WORD = undefined;
                        var init_attrs = false;
                    };
                    if (!S.init_attrs) {
                        S.init_attrs = true;
                        var info: windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;
                        // TODO handle error
                        _ = windows.kernel32.GetConsoleScreenBufferInfo(stderr_file.handle, &info);
                        S.attrs = info.wAttributes;
                    }

                    // TODO handle errors
                    switch (color) {
                        .Red => {
                            _ = windows.SetConsoleTextAttribute(stderr_file.handle, windows.FOREGROUND_RED | windows.FOREGROUND_INTENSITY) catch {};
                        },
                        .Green => {
                            _ = windows.SetConsoleTextAttribute(stderr_file.handle, windows.FOREGROUND_GREEN | windows.FOREGROUND_INTENSITY) catch {};
                        },
                        .Cyan => {
                            _ = windows.SetConsoleTextAttribute(stderr_file.handle, windows.FOREGROUND_GREEN | windows.FOREGROUND_BLUE | windows.FOREGROUND_INTENSITY) catch {};
                        },
                        .White, .Bold => {
                            _ = windows.SetConsoleTextAttribute(stderr_file.handle, windows.FOREGROUND_RED | windows.FOREGROUND_GREEN | windows.FOREGROUND_BLUE | windows.FOREGROUND_INTENSITY) catch {};
                        },
                        .Dim => {
                            _ = windows.SetConsoleTextAttribute(stderr_file.handle, windows.FOREGROUND_INTENSITY) catch {};
                        },
                        .Reset => {
                            _ = windows.SetConsoleTextAttribute(stderr_file.handle, S.attrs) catch {};
                        },
                    }
                } else {
                    unreachable;
                },
            };
        }
    };
};

/// TODO resources https://github.com/ziglang/zig/issues/4353
pub fn printSourceAtAddress(symbol_map: *SymbolMap, out_stream: anytype, address: usize, tty_config: TTY.Config) !void {
    const symbol_info = try symbol_map.addressToSymbol(address);
    defer symbol_info.deinit();

    return printLineInfo(
        out_stream,
        symbol_info.line_info,
        address,
        symbol_info.symbol_name,
        symbol_info.compile_unit_name,
        tty_config,
        printLineFromFileAnyOs,
    );
}

fn printLineInfo(
    out_stream: anytype,
    line_info: ?SymbolMap.LineInfo,
    address: usize,
    symbol_name: []const u8,
    compile_unit_name: []const u8,
    tty_config: TTY.Config,
    comptime printLineFromFile: anytype,
) !void {
    nosuspend {
        tty_config.setColor(out_stream, .Bold);

        if (line_info) |*li| {
            try out_stream.print("{s}:{d}:{d}", .{ li.file_name, li.line, li.column });
        } else {
            try out_stream.writeAll("???:?:?");
        }

        tty_config.setColor(out_stream, .Reset);
        try out_stream.writeAll(": ");
        tty_config.setColor(out_stream, .Dim);
        try out_stream.print("0x{x} in {s} ({s})", .{ address, symbol_name, compile_unit_name });
        tty_config.setColor(out_stream, .Reset);
        try out_stream.writeAll("\n");

        // Show the matching source code line if possible
        if (line_info) |li| {
            if (printLineFromFile(out_stream, li)) {
                if (li.column > 0) {
                    // The caret already takes one char
                    const space_needed = @intCast(usize, li.column - 1);

                    try out_stream.writeByteNTimes(' ', space_needed);
                    tty_config.setColor(out_stream, .Green);
                    try out_stream.writeAll("^");
                    tty_config.setColor(out_stream, .Reset);
                }
                try out_stream.writeAll("\n");
            } else |err| switch (err) {
                error.EndOfFile, error.FileNotFound => {},
                error.BadPathName => {},
                error.AccessDenied => {},
                else => return err,
            }
        }
    }
}

fn printLineFromFileAnyOs(out_stream: anytype, line_info: SymbolMap.LineInfo) !void {
    // Need this to always block even in async I/O mode, because this could potentially
    // be called from e.g. the event loop code crashing.
    var f = try fs.cwd().openFile(line_info.file_name, .{ .intended_io_mode = .blocking });
    defer f.close();
    // TODO fstat and make sure that the file has the correct size

    var buf: [mem.page_size]u8 = undefined;
    var line: usize = 1;
    var column: usize = 1;
    while (true) {
        const amt_read = try f.read(buf[0..]);
        const slice = buf[0..amt_read];

        for (slice) |byte| {
            if (line == line_info.line) {
                try out_stream.writeByte(byte);
                if (byte == '\n') {
                    return;
                }
            }
            if (byte == '\n') {
                line += 1;
                column = 1;
            } else {
                column += 1;
            }
        }

        if (amt_read < buf.len) return error.EndOfFile;
    }
}

/// TODO multithreaded awareness
var debug_info_allocator: ?*mem.Allocator = null;
var debug_info_arena_allocator: std.heap.ArenaAllocator = undefined;
fn getDebugInfoAllocator() *mem.Allocator {
    if (debug_info_allocator) |a| return a;

    debug_info_arena_allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    debug_info_allocator = &debug_info_arena_allocator.allocator;
    return &debug_info_arena_allocator.allocator;
}

/// Whether or not the current target can print useful debug information when a segfault occurs.
pub const have_segfault_handling_support = switch (native_os) {
    .linux, .netbsd => true,
    .windows => true,
    .freebsd, .openbsd => @hasDecl(os, "ucontext_t"),
    else => false,
};
pub const enable_segfault_handler: bool = if (@hasDecl(root, "enable_segfault_handler"))
    root.enable_segfault_handler
else
    runtime_safety and have_segfault_handling_support;

pub fn maybeEnableSegfaultHandler() void {
    if (enable_segfault_handler) {
        std.debug.attachSegfaultHandler();
    }
}

var windows_segfault_handle: ?windows.HANDLE = null;

/// Attaches a global SIGSEGV handler which calls @panic("segmentation fault");
pub fn attachSegfaultHandler() void {
    if (!have_segfault_handling_support) {
        @compileError("segfault handler not supported for this target");
    }
    if (native_os == .windows) {
        windows_segfault_handle = windows.kernel32.AddVectoredExceptionHandler(0, handleSegfaultWindows);
        return;
    }
    var act = os.Sigaction{
        .handler = .{ .sigaction = handleSegfaultLinux },
        .mask = os.empty_sigset,
        .flags = (os.SA_SIGINFO | os.SA_RESTART | os.SA_RESETHAND),
    };

    os.sigaction(os.SIGSEGV, &act, null);
    os.sigaction(os.SIGILL, &act, null);
    os.sigaction(os.SIGBUS, &act, null);
}

fn resetSegfaultHandler() void {
    if (native_os == .windows) {
        if (windows_segfault_handle) |handle| {
            assert(windows.kernel32.RemoveVectoredExceptionHandler(handle) != 0);
            windows_segfault_handle = null;
        }
        return;
    }
    var act = os.Sigaction{
        .handler = .{ .sigaction = os.SIG_DFL },
        .mask = os.empty_sigset,
        .flags = 0,
    };
    os.sigaction(os.SIGSEGV, &act, null);
    os.sigaction(os.SIGILL, &act, null);
    os.sigaction(os.SIGBUS, &act, null);
}

fn handleSegfaultLinux(sig: i32, info: *const os.siginfo_t, ctx_ptr: ?*const c_void) callconv(.C) noreturn {
    // Reset to the default handler so that if a segfault happens in this handler it will crash
    // the process. Also when this handler returns, the original instruction will be repeated
    // and the resulting segfault will crash the process rather than continually dump stack traces.
    resetSegfaultHandler();

    const addr = switch (native_os) {
        .linux => @ptrToInt(info.fields.sigfault.addr),
        .freebsd => @ptrToInt(info.addr),
        .netbsd => @ptrToInt(info.info.reason.fault.addr),
        .openbsd => @ptrToInt(info.data.fault.addr),
        else => unreachable,
    };

    // Don't use std.debug.print() as stderr_mutex may still be locked.
    nosuspend {
        const stderr = io.getStdErr().writer();
        _ = switch (sig) {
            os.SIGSEGV => stderr.print("Segmentation fault at address 0x{x}\n", .{addr}),
            os.SIGILL => stderr.print("Illegal instruction at address 0x{x}\n", .{addr}),
            os.SIGBUS => stderr.print("Bus error at address 0x{x}\n", .{addr}),
            else => unreachable,
        } catch os.abort();
    }

    switch (native_arch) {
        .i386 => {
            const ctx = @ptrCast(*const os.ucontext_t, @alignCast(@alignOf(os.ucontext_t), ctx_ptr));
            const ip = @intCast(usize, ctx.mcontext.gregs[os.REG_EIP]);
            const bp = @intCast(usize, ctx.mcontext.gregs[os.REG_EBP]);
            dumpStackTraceFromBase(bp, ip);
        },
        .x86_64 => {
            const ctx = @ptrCast(*const os.ucontext_t, @alignCast(@alignOf(os.ucontext_t), ctx_ptr));
            const ip = switch (native_os) {
                .linux, .netbsd => @intCast(usize, ctx.mcontext.gregs[os.REG_RIP]),
                .freebsd => @intCast(usize, ctx.mcontext.rip),
                .openbsd => @intCast(usize, ctx.sc_rip),
                else => unreachable,
            };
            const bp = switch (native_os) {
                .linux, .netbsd => @intCast(usize, ctx.mcontext.gregs[os.REG_RBP]),
                .openbsd => @intCast(usize, ctx.sc_rbp),
                .freebsd => @intCast(usize, ctx.mcontext.rbp),
                else => unreachable,
            };
            dumpStackTraceFromBase(bp, ip);
        },
        .arm => {
            const ctx = @ptrCast(*const os.ucontext_t, @alignCast(@alignOf(os.ucontext_t), ctx_ptr));
            const ip = @intCast(usize, ctx.mcontext.arm_pc);
            const bp = @intCast(usize, ctx.mcontext.arm_fp);
            dumpStackTraceFromBase(bp, ip);
        },
        .aarch64 => {
            const ctx = @ptrCast(*const os.ucontext_t, @alignCast(@alignOf(os.ucontext_t), ctx_ptr));
            const ip = @intCast(usize, ctx.mcontext.pc);
            // x29 is the ABI-designated frame pointer
            const bp = @intCast(usize, ctx.mcontext.regs[29]);
            dumpStackTraceFromBase(bp, ip);
        },
        else => {},
    }

    // We cannot allow the signal handler to return because when it runs the original instruction
    // again, the memory may be mapped and undefined behavior would occur rather than repeating
    // the segfault. So we simply abort here.
    os.abort();
}

fn handleSegfaultWindows(info: *windows.EXCEPTION_POINTERS) callconv(windows.WINAPI) c_long {
    switch (info.ExceptionRecord.ExceptionCode) {
        windows.EXCEPTION_DATATYPE_MISALIGNMENT => handleSegfaultWindowsExtra(info, 0, "Unaligned Memory Access"),
        windows.EXCEPTION_ACCESS_VIOLATION => handleSegfaultWindowsExtra(info, 1, null),
        windows.EXCEPTION_ILLEGAL_INSTRUCTION => handleSegfaultWindowsExtra(info, 2, null),
        windows.EXCEPTION_STACK_OVERFLOW => handleSegfaultWindowsExtra(info, 0, "Stack Overflow"),
        else => return windows.EXCEPTION_CONTINUE_SEARCH,
    }
}

// zig won't let me use an anon enum here https://github.com/ziglang/zig/issues/3707
fn handleSegfaultWindowsExtra(info: *windows.EXCEPTION_POINTERS, comptime msg: u8, comptime format: ?[]const u8) noreturn {
    const exception_address = @ptrToInt(info.ExceptionRecord.ExceptionAddress);
    if (@hasDecl(windows, "CONTEXT")) {
        const regs = info.ContextRecord.getRegs();
        // Don't use std.debug.print() as stderr_mutex may still be locked.
        nosuspend {
            const stderr = io.getStdErr().writer();
            _ = switch (msg) {
                0 => stderr.print("{s}\n", .{format.?}),
                1 => stderr.print("Segmentation fault at address 0x{x}\n", .{info.ExceptionRecord.ExceptionInformation[1]}),
                2 => stderr.print("Illegal instruction at address 0x{x}\n", .{regs.ip}),
                else => unreachable,
            } catch os.abort();
        }

        dumpStackTraceFromBase(regs.bp, regs.ip);
        os.abort();
    } else {
        switch (msg) {
            0 => panicExtra(null, exception_address, format.?, .{}),
            1 => panicExtra(null, exception_address, "Segmentation fault at address 0x{x}", .{info.ExceptionRecord.ExceptionInformation[1]}),
            2 => panicExtra(null, exception_address, "Illegal Instruction", .{}),
            else => unreachable,
        }
    }
}

pub fn dumpStackPointerAddr(prefix: []const u8) void {
    const sp = asm (""
        : [argc] "={rsp}" (-> usize)
    );
    std.debug.warn("{} sp = 0x{x}\n", .{ prefix, sp });
}
