// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.

//! This struct represents a kernel thread, and acts as a namespace for concurrency
//! primitives that operate on kernel threads. For concurrency primitives that support
//! both evented I/O and async I/O, see the respective names in the top level std namespace.

const std = @import("std.zig");
const os = std.os;
const assert = std.debug.assert;
const target = std.Target.current;
const Atomic = std.atomic.Atomic;

pub const Futex = @import("Thread/Futex.zig");
pub const Mutex = @import("Thread/Mutex.zig");
pub const Condvar = @import("Thread/Condvar.zig");
pub const Semaphore = @import("Thread/Semaphore.zig");
pub const RwLock = @import("Thread/RwLock.zig");

pub const spinLoopHint = @compileError("deprecated: use std.atomic.spinLoopHint");

pub const use_pthreads = target.os.tag != .windows and std.builtin.link_libc;

const Thread = @This();
const Impl = if (target.os.tag == .windows)
    WindowsThreadImpl
else if (use_pthreads)
    PosixThreadImpl
else if (target.os.tag == .linux)
    LinuxThreadImpl
else
    UnsupportedImpl;

impl: Impl,

/// Represents a unique ID per thread.
pub const Id = u64;

/// Returns the platform ID of the callers thread.
/// Attempts to use thread locals and avoid syscalls when possible.
pub fn getCurrentId() Id {
    return Impl.getCurrentId();
}

pub const CpuCountError = error{
    PermissionDenied,
    SystemResources,
    Unexpected,
};

/// Returns the platforms view on the number of logical CPU cores available.
pub fn getCpuCount() CpuCountError!usize {
    return Impl.getCpuCount();
}

/// Configuration options for hints on how to spawn threads.
pub const SpawnConfig = struct {
    // TODO compile-time call graph analysis to determine stack upper bound
    // https://github.com/ziglang/zig/issues/157

    /// Size in bytes of the Thread's stack
    stack_size: usize = 16 * 1024 * 1024,
};

pub const SpawnError = error{
    /// A system-imposed limit on the number of threads was encountered.
    /// There are a number of limits that may trigger this error:
    /// *  the  RLIMIT_NPROC soft resource limit (set via setrlimit(2)),
    ///    which limits the number of processes and threads for  a  real
    ///    user ID, was reached;
    /// *  the kernel's system-wide limit on the number of processes and
    ///    threads,  /proc/sys/kernel/threads-max,  was   reached   (see
    ///    proc(5));
    /// *  the  maximum  number  of  PIDs, /proc/sys/kernel/pid_max, was
    ///    reached (see proc(5)); or
    /// *  the PID limit (pids.max) imposed by the cgroup "process  num‐
    ///    ber" (PIDs) controller was reached.
    ThreadQuotaExceeded,

    /// The kernel cannot allocate sufficient memory to allocate a task structure
    /// for the child, or to copy those parts of the caller's context that need to
    /// be copied.
    SystemResources,

    /// Not enough userland memory to spawn the thread.
    OutOfMemory,

    /// `mlockall` is enabled, and the memory needed to spawn the thread
    /// would exceed the limit.
    LockedMemoryLimitExceeded,

    Unexpected,
};

/// Spawns a new thread which executes `function` using `args` and returns a handle the spawned thread.
/// `config` can be used as hints to the platform for now to spawn and execute the `function`.
/// The caller must eventually either call `join()` to wait for the thread to finish and free its resources
/// or call `detach()` to excuse the caller from calling `join()` and have the thread clean up its resources on completion`.
pub fn spawn(config: SpawnConfig, comptime function: anytype, args: anytype) SpawnError!Thread {
    if (std.builtin.single_threaded) {
        @compileError("Cannot spawn thread when building in single-threaded mode");
    }

    const impl = try Impl.spawn(config, function, args);
    return Thread{ .impl = impl };
}

/// Represents a kernel thread handle.
/// May be an integer or a pointer depending on the platform.
pub const Handle = Impl.ThreadHandle;

/// Retrns the handle of this thread
pub fn getHandle(self: Thread) Handle {
    return self.impl.getHandle();
}

/// Release the obligation of the caller to call `join()` and have the thread clean up its own resources on completion.
/// Once called, this consumes the Thread object and invoking any other functions on it is considered undefined behavior.
pub fn detach(self: Thread) void {
    return self.impl.detach();
}

/// Waits for the thread to complete, then deallocates any resources created on `spawn()`.
/// Once called, this consumes the Thread object and invoking any other functions on it is considered undefined behavior.
pub fn join(self: Thread) void {
    return self.impl.join();
}

/// State to synchronize detachment of spawner thread to spawned thread
const Completion = Atomic(enum(u8) {
    running,
    detached,
    completed,
});

/// Used by the Thread implementations to call the spawned function with the arguments.
fn callFn(comptime f: anytype, args: anytype) switch (Impl) {
    WindowsThreadImpl => std.os.windows.DWORD,
    LinuxThreadImpl => u8,
    PosixThreadImpl => ?*c_void,
    else => unreachable,
} {
    const default_value = if (Impl == PosixThreadImpl) null else 0;
    const bad_fn_ret = "expected return type of startFn to be 'u8', 'noreturn', 'void', or '!void'";

    switch (@typeInfo(@typeInfo(@TypeOf(f)).Fn.return_type.?)) {
        .NoReturn => {
            @call(.{}, f, args);
        },
        .Void => {
            @call(.{}, f, args);
            return default_value;
        },
        .Int => |info| {
            if (info.bits != 8) {
                @compileError(bad_fn_ret);
            }

            const status = @call(.{}, f, args);
            if (Impl != PosixThreadImpl) {
                return status;
            }

            // pthreads don't support exit status, ignore value
            _ = status;
            return default_value;
        },
        .ErrorUnion => |info| {
            if (info.payload != void) {
                @compileError(bad_fn_ret);
            }

            @call(.{}, f, args) catch |err| {
                std.debug.warn("error: {s}\n", .{@errorName(err)});
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpStackTrace(trace.*);
                }
            };

            return default_value;
        },
        else => {
            @compileError(bad_fn_ret);
        },
    }
}

/// We can't compile error in the `Impl` switch statement as its eagerly evaluated.
/// So instead, we compile-error on the methods themselves for platforms which don't support threads.
const UnsupportedImpl = struct {
    pub const ThreadHandle = void;

    fn getCurrentId() u64 {
        return unsupported({});
    }

    fn getCpuCount() !usize {
        return unsupported({});
    }

    fn spawn(config: SpawnConfig, comptime f: anytype, args: anytype) !Impl {
        return unsupported(.{ config, f, args });
    }

    fn getHandle(self: Impl) ThreadHandle {
        return unsupported(self);
    }

    fn detach(self: Impl) void {
        return unsupported(self);
    }

    fn join(self: Impl) void {
        return unsupported(self);
    }

    fn unsupported(unusued: anytype) noreturn {
        @compileLog("Unsupported operating system", target.os.tag);
        _ = unusued;
        unreachable;
    }
};

const WindowsThreadImpl = struct {
    const windows = os.windows;

    pub const ThreadHandle = windows.HANDLE;

    fn getCurrentId() u64 {
        return windows.kernel32.GetCurrentThreadId();
    }

    fn getCpuCount() !usize {
        // Faster than calling into GetSystemInfo(), even if amortized.
        return windows.peb().NumberOfProcessors;
    }

    thread: *ThreadCompletion,

    const ThreadCompletion = struct {
        completion: Completion,
        heap_ptr: windows.PVOID,
        heap_handle: windows.HANDLE,
        thread_handle: windows.HANDLE = undefined,

        fn free(self: ThreadCompletion) void {
            const status = windows.kernel32.HeapFree(self.heap_handle, 0, self.heap_ptr);
            assert(status != 0);
        }
    };

    fn spawn(config: SpawnConfig, comptime f: anytype, args: anytype) !Impl {
        const Args = @TypeOf(args);
        const Instance = struct {
            fn_args: Args,
            thread: ThreadCompletion,

            fn entryFn(raw_ptr: windows.PVOID) callconv(.C) windows.DWORD {
                const self = @ptrCast(*@This(), @alignCast(@alignOf(@This()), raw_ptr));
                defer switch (self.thread.completion.swap(.completed, .SeqCst)) {
                    .running => {},
                    .completed => unreachable,
                    .detached => self.thread.free(),
                };
                return callFn(f, self.fn_args);
            }
        };

        const heap_handle = windows.kernel32.GetProcessHeap() orelse return error.OutOfMemory;
        const alloc_bytes = @alignOf(Instance) + @sizeOf(Instance);
        const alloc_ptr = windows.kernel32.HeapAlloc(heap_handle, 0, alloc_bytes) orelse return error.OutOfMemory;
        errdefer assert(windows.kernel32.HeapFree(heap_handle, 0, alloc_ptr) != 0);

        const instance_bytes = @ptrCast([*]u8, alloc_ptr)[0..alloc_bytes];
        const instance = std.heap.FixedBufferAllocator.init(instance_bytes).allocator.create(Instance) catch unreachable;
        instance.* = .{
            .fn_args = args,
            .thread = .{
                .completion = Completion.init(.running),
                .heap_ptr = alloc_ptr,
                .heap_handle = heap_handle,
            },
        };

        // Windows appears to only support SYSTEM_INFO.dwAllocationGranularity minimum stack size.
        // Going lower makes it default to that specified in the executable (~1mb).
        // Its also fine if the limit here is incorrect as stack size is only a hint.
        var stack_size = std.math.cast(u32, config.stack_size) catch std.math.maxInt(u32);
        stack_size = std.math.max(64 * 1024, stack_size);

        instance.thread.thread_handle = windows.kernel32.CreateThread(
            null,
            stack_size,
            Instance.entryFn,
            @ptrCast(*c_void, instance),
            0,
            null,
        ) orelse {
            const errno = windows.kernel32.GetLastError();
            return windows.unexpectedError(errno);
        };

        return Impl{ .thread = &instance.thread };
    }

    fn getHandle(self: Impl) ThreadHandle {
        return self.thread.thread_handle;
    }

    fn detach(self: Impl) void {
        windows.CloseHandle(self.thread.thread_handle);
        switch (self.thread.completion.swap(.detached, .SeqCst)) {
            .running => {},
            .completed => self.thread.free(),
            .detached => unreachable,
        }
    }

    fn join(self: Impl) void {
        windows.WaitForSingleObjectEx(self.thread.thread_handle, windows.INFINITE, false) catch unreachable;
        windows.CloseHandle(self.thread.thread_handle);
        assert(self.thread.completion.load(.SeqCst) == .completed);
        self.thread.free();
    }
};

const PosixThreadImpl = struct {
    const c = std.c;

    pub const ThreadHandle = c.pthread_t;

    fn getCurrentId() Id {
        switch (target.os.tag) {
            .linux => {
                return LinuxThreadImpl.getCurrentId();
            },
            .macos, .ios, .watchos, .tvos => {
                var thread_id: u64 = undefined;
                // Pass thread=null to get the current thread ID.
                assert(c.pthread_threadid_np(null, &thread_id) == 0);
                return thread_id;
            },
            .dragonfly => {
                return @bitCast(u32, c.lwp_gettid());
            },
            .netbsd => {
                return @bitCast(u32, c._lwp_self());
            },
            .freebsd => {
                return @bitCast(u32, c.pthread_getthreadid_np());
            },
            .openbsd => {
                return @bitCast(u32, c.getthrid());
            },
            .haiku => {
                return @bitCast(u32, c.find_thread(null));
            },
            else => {
                return @ptrToInt(c.pthread_self());
            },
        }
    }

    fn getCpuCount() !usize {
        switch (target.os.tag) {
            .linux => {
                return LinuxThreadImpl.getCpuCount();
            },
            .openbsd => {
                var count: c_int = undefined;
                var count_size: usize = @sizeOf(c_int);
                const mib = [_]c_int{ os.CTL_HW, os.HW_NCPUONLINE };
                os.sysctl(&mib, &count, &count_size, null, 0) catch |err| switch (err) {
                    error.NameTooLong, error.UnknownName => unreachable,
                    else => |e| return e,
                };
                return @intCast(usize, count);
            },
            .haiku => {
                var count: u32 = undefined;
                var system_info: os.system_info = undefined;
                _ = os.system.get_system_info(&system_info); // always returns B_OK
                count = system_info.cpu_count;
                return @intCast(usize, count);
            },
            else => {
                var count: c_int = undefined;
                var count_len: usize = @sizeOf(c_int);
                const name = if (comptime target.isDarwin()) "hw.logicalcpu" else "hw.ncpu";
                os.sysctlbynameZ(name, &count, &count_len, null, 0) catch |err| switch (err) {
                    error.NameTooLong, error.UnknownName => unreachable,
                    else => |e| return e,
                };
                return @intCast(usize, count);
            },
        }
    }

    handle: ThreadHandle,

    fn spawn(config: SpawnConfig, comptime f: anytype, args: anytype) !Impl {
        const Args = @TypeOf(args);
        const allocator = std.heap.c_allocator;

        const Instance = struct {
            fn entryFn(raw_arg: ?*c_void) callconv(.C) ?*c_void {
                // @alignCast() below doesn't support zero-sized-types (ZST)
                if (@sizeOf(Args) < 1) {
                    return callFn(f, @as(Args, undefined));
                }

                const args_ptr = @ptrCast(*Args, @alignCast(@alignOf(Args), raw_arg));
                defer allocator.destroy(args_ptr);
                return callFn(f, args_ptr.*);
            }
        };

        const args_ptr = try allocator.create(Args);
        args_ptr.* = args;
        errdefer allocator.destroy(args_ptr);

        var attr: c.pthread_attr_t = undefined;
        if (c.pthread_attr_init(&attr) != 0) return error.SystemResources;
        defer assert(c.pthread_attr_destroy(&attr) == 0);

        // Use the same set of parameters used by the libc-less impl.
        const stack_size = std.math.max(config.stack_size, 16 * 1024);
        assert(c.pthread_attr_setstacksize(&attr, stack_size) == 0);
        assert(c.pthread_attr_setguardsize(&attr, std.mem.page_size) == 0);

        var handle: c.pthread_t = undefined;
        switch (c.pthread_create(
            &handle,
            &attr,
            Instance.entryFn,
            if (@sizeOf(Args) > 1) @ptrCast(*c_void, args_ptr) else undefined,
        )) {
            0 => return Impl{ .handle = handle },
            os.EAGAIN => return error.SystemResources,
            os.EPERM => unreachable,
            os.EINVAL => unreachable,
            else => |err| return os.unexpectedErrno(err),
        }
    }

    fn getHandle(self: Impl) ThreadHandle {
        return self.handle;
    }

    fn detach(self: Impl) void {
        switch (c.pthread_detach(self.handle)) {
            0 => {},
            os.EINVAL => unreachable, // thread handle is not joinable
            os.ESRCH => unreachable, // thread handle is invalid
            else => unreachable,
        }
    }

    fn join(self: Impl) void {
        switch (c.pthread_join(self.handle, null)) {
            0 => {},
            os.EINVAL => unreachable, // thread handle is not joinable (or another thread is already joining in)
            os.ESRCH => unreachable, // thread handle is invalid
            os.EDEADLK => unreachable, // two threads tried to join each other
            else => unreachable,
        }
    }
};

const LinuxThreadImpl = struct {
    const linux = os.linux;

    pub const ThreadHandle = i32;

    threadlocal var tls_thread_id: ?Id = null;

    fn getCurrentId() Id {
        return tls_thread_id orelse {
            const tid = @bitCast(u32, linux.gettid());
            tls_thread_id = tid;
            return tid;
        };
    }

    fn getCpuCount() !usize {
        const cpu_set = try os.sched_getaffinity(0);
        // TODO: should not need this usize cast
        return @as(usize, os.CPU_COUNT(cpu_set));
    }

    thread: *ThreadCompletion,

    const ThreadCompletion = struct {
        completion: Completion = Completion.init(.running),
        child_tid: Atomic(i32) = Atomic(i32).init(1),
        parent_tid: i32 = undefined,
        mapped: []align(std.mem.page_size) u8,

        /// Calls `munmap(mapped.ptr, mapped.len)` then `exit(1)` without touching the stack (which lives in `mapped.ptr`).
        /// Ported over from musl libc's pthread detached implementation:
        /// https://github.com/ifduyue/musl/search?q=__unmapself
        fn freeAndExit(self: *ThreadCompletion) noreturn {
            const unmap_and_exit: []const u8 = switch (target.cpu.arch) {
                .i386 => (
                    \\  movl $91, %%eax
                    \\  movl %[ptr], %%ebx
                    \\  movl %[len], %%ecx
                    \\  int $128
                    \\  movl $1, %%eax
                    \\  movl $0, %%ebx
                    \\  int $128
                ),
                .x86_64 => (
                    \\  movq $11, %%rax
                    \\  movq %[ptr], %%rbx
                    \\  movq %[len], %%rcx
                    \\  syscall
                    \\  movq $60, %%rax
                    \\  movq $1, %%rdi
                    \\  syscall
                ),
                .arm, .armeb, .thumb, .thumbeb => (
                    \\  mov r7, #91
                    \\  mov r0, %[ptr]
                    \\  mov r1, %[len]
                    \\  svc 0
                    \\  mov r7, #1
                    \\  mov r0, #0
                    \\  svc 0
                ),
                .aarch64, .aarch64_be, .aarch64_32 => (
                    \\  mov x8, #215
                    \\  mov x0, %[ptr]
                    \\  mov x1, %[len]
                    \\  svc 0
                    \\  mov x8, #93
                    \\  mov x0, #0
                    \\  svc 0
                ),
                .mips, .mipsel => (
                    \\  move $sp, $25
                    \\  li $2, 4091
                    \\  move $4, %[ptr]
                    \\  move $5, %[len]
                    \\  syscall
                    \\  li $2, 4001
                    \\  li $4, 0
                    \\  syscall
                ),
                .mips64, .mips64el => (
                    \\  li $2, 4091
                    \\  move $4, %[ptr]
                    \\  move $5, %[len]
                    \\  syscall
                    \\  li $2, 4001
                    \\  li $4, 0
                    \\  syscall
                ),
                .powerpc, .powerpcle, .powerpc64, .powerpc64le => (
                    \\  li 0, 91
                    \\  mr %[ptr], 3
                    \\  mr %[len], 4
                    \\  sc
                    \\  li 0, 1
                    \\  li 3, 0
                    \\  sc
                    \\  blr
                ),
                .riscv64 => (
                    \\  li a7, 215
                    \\  mv a0, %[ptr]
                    \\  mv a1, %[len]
                    \\  ecall
                    \\  li a7, 93
                    \\  mv a0, zero
                    \\  ecall
                ),
                else => |cpu_arch| {
                    @compileLog("Unsupported linux arch ", cpu_arch);
                },
            };

            asm volatile (unmap_and_exit
                :
                : [ptr] "r" (@ptrToInt(self.mapped.ptr)),
                  [len] "r" (self.mapped.len)
                : "memory"
            );

            unreachable;
        }
    };

    fn spawn(config: SpawnConfig, comptime f: anytype, args: anytype) !Impl {
        const Args = @TypeOf(args);
        const Instance = struct {
            fn_args: Args,
            thread: ThreadCompletion,

            fn entryFn(raw_arg: usize) callconv(.C) u8 {
                const self = @intToPtr(*@This(), raw_arg);
                defer switch (self.thread.completion.swap(.completed, .SeqCst)) {
                    .running => {},
                    .completed => unreachable,
                    .detached => self.thread.freeAndExit(),
                };
                return callFn(f, self.fn_args);
            }
        };

        var guard_offset: usize = undefined;
        var stack_offset: usize = undefined;
        var tls_offset: usize = undefined;
        var instance_offset: usize = undefined;

        const map_bytes = blk: {
            var bytes: usize = std.mem.page_size;
            guard_offset = bytes;

            bytes += std.math.max(std.mem.page_size, config.stack_size);
            bytes = std.mem.alignForward(bytes, std.mem.page_size);
            stack_offset = bytes;

            bytes = std.mem.alignForward(bytes, linux.tls.tls_image.alloc_align);
            tls_offset = bytes;
            bytes += linux.tls.tls_image.alloc_size;

            bytes = std.mem.alignForward(bytes, @alignOf(Instance));
            instance_offset = bytes;
            bytes += @sizeOf(Instance);

            bytes = std.mem.alignForward(bytes, std.mem.page_size);
            break :blk bytes;
        };

        // map all memory needed without read/write permissions
        // to avoid committing the whole region right away
        const mapped = os.mmap(
            null,
            map_bytes,
            os.PROT_NONE,
            os.MAP_PRIVATE | os.MAP_ANONYMOUS,
            -1,
            0,
        ) catch |err| switch (err) {
            error.MemoryMappingNotSupported => unreachable,
            error.AccessDenied => unreachable,
            error.PermissionDenied => unreachable,
            else => |e| return e,
        };
        assert(mapped.len >= map_bytes);
        errdefer os.munmap(mapped);

        // map everything but the guard page as read/write
        os.mprotect(
            mapped[guard_offset..],
            os.PROT_READ | os.PROT_WRITE,
        ) catch |err| switch (err) {
            error.AccessDenied => unreachable,
            else => |e| return e,
        };

        // Prepare the TLS segment and prepare a user_desc struct when needed on i386
        var tls_ptr = os.linux.tls.prepareTLS(mapped[tls_offset..]);
        var user_desc: if (target.cpu.arch == .i386) os.linux.user_desc else void = undefined;
        if (target.cpu.arch == .i386) {
            defer tls_ptr = @ptrToInt(&user_desc);
            user_desc = .{
                .entry_number = os.linux.tls.tls_image.gdt_entry_number,
                .base_addr = tls_ptr,
                .limit = 0xfffff,
                .seg_32bit = 1,
                .contents = 0, // Data
                .read_exec_only = 0,
                .limit_in_pages = 1,
                .seg_not_present = 0,
                .useable = 1,
            };
        }

        const instance = @ptrCast(*Instance, @alignCast(@alignOf(Instance), &mapped[instance_offset]));
        instance.* = .{
            .fn_args = args,
            .thread = .{ .mapped = mapped },
        };

        const flags: u32 = os.CLONE_THREAD | os.CLONE_DETACHED |
            os.CLONE_VM | os.CLONE_FS | os.CLONE_FILES |
            os.CLONE_PARENT_SETTID | os.CLONE_CHILD_CLEARTID |
            os.CLONE_SIGHAND | os.CLONE_SYSVSEM | os.CLONE_SETTLS;

        switch (linux.getErrno(linux.clone(
            Instance.entryFn,
            @ptrToInt(&mapped[stack_offset]),
            flags,
            @ptrToInt(instance),
            &instance.thread.parent_tid,
            tls_ptr,
            &instance.thread.child_tid.value,
        ))) {
            0 => return Impl{ .thread = &instance.thread },
            os.EAGAIN => return error.ThreadQuotaExceeded,
            os.EINVAL => unreachable,
            os.ENOMEM => return error.SystemResources,
            os.ENOSPC => unreachable,
            os.EPERM => unreachable,
            os.EUSERS => unreachable,
            else => |err| return os.unexpectedErrno(err),
        }
    }

    fn getHandle(self: Impl) ThreadHandle {
        return self.thread.parent_tid;
    }

    fn detach(self: Impl) void {
        switch (self.thread.completion.swap(.detached, .SeqCst)) {
            .running => {},
            .completed => self.join(),
            .detached => unreachable,
        }
    }

    fn join(self: Impl) void {
        defer os.munmap(self.thread.mapped);

        var spin: u8 = 10;
        while (true) {
            const tid = self.thread.child_tid.load(.SeqCst);
            if (tid == 0) {
                break;
            }

            if (spin > 0) {
                spin -= 1;
                std.atomic.spinLoopHint();
                continue;
            }

            switch (linux.getErrno(linux.futex_wait(
                &self.thread.child_tid.value,
                linux.FUTEX_WAIT,
                tid,
                null,
            ))) {
                0 => continue,
                os.EINTR => continue,
                os.EAGAIN => continue,
                else => unreachable,
            }
        }
    }
};

test "std.Thread" {
    // Doesn't use testing.refAllDecls() since that would pull in the compileError spinLoopHint.
    _ = AutoResetEvent;
    _ = Futex;
    _ = ResetEvent;
    _ = StaticResetEvent;
    _ = Mutex;
    _ = Semaphore;
    _ = Condition;
}

fn testIncrementNotify(value: *usize, event: *ResetEvent) void {
    value.* += 1;
    event.set();
}

test "Thread.join" {
    if (std.builtin.single_threaded) return error.SkipZigTest;

    var value: usize = 0;
    var event: ResetEvent = undefined;
    try event.init();
    defer event.deinit();

    const thread = try Thread.spawn(.{}, testIncrementNotify, .{ &value, &event });
    thread.join();

    try std.testing.expectEqual(value, 1);
}

test "Thread.detach" {
    if (std.builtin.single_threaded) return error.SkipZigTest;

    var value: usize = 0;
    var event: ResetEvent = undefined;
    try event.init();
    defer event.deinit();

    const thread = try Thread.spawn(.{}, testIncrementNotify, .{ &value, &event });
    thread.detach();

    event.wait();
    try std.testing.expectEqual(value, 1);
}
