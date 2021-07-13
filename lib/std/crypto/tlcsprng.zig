// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.

//! Thread-local cryptographically secure pseudo-random number generator.
//! This file has public declarations that are intended to be used internally
//! by the standard library; this namespace is not intended to be exposed
//! directly to standard library users.

const std = @import("std");
const root = @import("root");
const mem = std.mem;
const os = std.os;

/// We use this as a layer of indirection because global const pointers cannot
/// point to thread-local variables.
pub var interface = std.rand.Random{ .fillFn = tlsCsprngFill };

const os_has_fork = switch (std.Target.current.os.tag) {
    .dragonfly,
    .freebsd,
    .ios,
    .kfreebsd,
    .linux,
    .macos,
    .netbsd,
    .openbsd,
    .solaris,
    .tvos,
    .watchos,
    .haiku,
    => true,

    else => false,
};
const os_has_arc4random = std.builtin.link_libc and @hasDecl(std.c, "arc4random_buf");
const want_fork_safety = os_has_fork and !os_has_arc4random and
    (std.meta.globalOption("crypto_fork_safety", bool) orelse true);
const maybe_have_wipe_on_fork = std.Target.current.os.isAtLeast(.linux, .{
    .major = 4,
    .minor = 14,
}) orelse true;

const Context = struct {
    init_state: enum(u8) { uninitialized = 0, initialized, failed },
    gimli: std.crypto.core.Gimli,
};

var install_atfork_handler = std.once(struct {
    // Install the global handler only once.
    // The same handler is shared among threads and is inherinted by fork()-ed
    // processes.
    fn do() void {
        const r = std.c.pthread_atfork(null, null, childAtForkHandler);
        std.debug.assert(r == 0);
    }
}.do);

threadlocal var wipe_mem: []align(mem.page_size) u8 = &[_]u8{};

fn tlsCsprngFill(_: *const std.rand.Random, buffer: []u8) void {
    if (std.builtin.link_libc and @hasDecl(std.c, "arc4random_buf")) {
        // arc4random is already a thread-local CSPRNG.
        return std.c.arc4random_buf(buffer.ptr, buffer.len);
    }
    // Allow applications to decide they would prefer to have every call to
    // std.crypto.random always make an OS syscall, rather than rely on an
    // application implementation of a CSPRNG.
    if (comptime std.meta.globalOption("crypto_always_getrandom", bool) orelse false) {
        return fillWithOsEntropy(buffer);
    }

    // Use OS syscall for haiku
    if (std.Target.current.os.tag == .haiku) {
        return fillWithOsEntropy(buffer);
    }

    if (wipe_mem.len == 0) {
        // Not initialized yet.
        if (want_fork_safety and maybe_have_wipe_on_fork) {
            // Allocate a per-process page, madvise operates with page
            // granularity.
            wipe_mem = os.mmap(
                null,
                @sizeOf(Context),
                os.PROT_READ | os.PROT_WRITE,
                os.MAP_PRIVATE | os.MAP_ANONYMOUS,
                -1,
                0,
            ) catch {
                // Could not allocate memory for the local state, fall back to
                // the OS syscall.
                return fillWithOsEntropy(buffer);
            };
            // The memory is already zero-initialized.
        } else {
            // Use a static thread-local buffer.
            const S = struct {
                threadlocal var buf: Context align(mem.page_size) = .{
                    .init_state = .uninitialized,
                    .gimli = undefined,
                };
            };
            wipe_mem = mem.asBytes(&S.buf);
        }
    }
    const ctx = @ptrCast(*Context, wipe_mem.ptr);

    switch (ctx.init_state) {
        .uninitialized => {
            if (!want_fork_safety) {
                return initAndFill(buffer);
            }

            if (maybe_have_wipe_on_fork) wof: {
                // Qemu user-mode emulation ignores any valid/invalid madvise
                // hint and returns success. Check if this is the case by
                // passing bogus parameters, we expect EINVAL as result.
                if (os.madvise(wipe_mem.ptr, 0, 0xffffffff)) |_| {
                    break :wof;
                } else |_| {}

                if (os.madvise(wipe_mem.ptr, wipe_mem.len, os.MADV_WIPEONFORK)) |_| {
                    return initAndFill(buffer);
                } else |_| {}
            }

            if (std.Thread.use_pthreads) {
                return setupPthreadAtforkAndFill(buffer);
            }

            // Since we failed to set up fork safety, we fall back to always
            // calling getrandom every time.
            ctx.init_state = .failed;
            return fillWithOsEntropy(buffer);
        },
        .initialized => {
            return fillWithCsprng(buffer);
        },
        .failed => {
            if (want_fork_safety) {
                return fillWithOsEntropy(buffer);
            } else {
                unreachable;
            }
        },
    }
}

fn setupPthreadAtforkAndFill(buffer: []u8) void {
    install_atfork_handler.call();
    return initAndFill(buffer);
}

fn childAtForkHandler() callconv(.C) void {
    // The atfork handler is global, this function may be called after
    // fork()-ing threads that never initialized the CSPRNG context.
    if (wipe_mem.len == 0) return;
    std.crypto.utils.secureZero(u8, wipe_mem);
}

fn fillWithCsprng(buffer: []u8) void {
    const ctx = @ptrCast(*Context, wipe_mem.ptr);
    if (buffer.len != 0) {
        ctx.gimli.squeeze(buffer);
    } else {
        ctx.gimli.permute();
    }
    mem.set(u8, ctx.gimli.toSlice()[0..std.crypto.core.Gimli.RATE], 0);
}

fn fillWithOsEntropy(buffer: []u8) void {
    os.getrandom(buffer) catch @panic("getrandom() failed to provide entropy");
}

fn initAndFill(buffer: []u8) void {
    var seed: [std.crypto.core.Gimli.BLOCKBYTES]u8 = undefined;
    // Because we panic on getrandom() failing, we provide the opportunity
    // to override the default seed function. This also makes
    // `std.crypto.random` available on freestanding targets, provided that
    // the `cryptoRandomSeed` function is provided.
    if (@hasDecl(root, "cryptoRandomSeed")) {
        root.cryptoRandomSeed(&seed);
    } else {
        fillWithOsEntropy(&seed);
    }

    const ctx = @ptrCast(*Context, wipe_mem.ptr);
    ctx.gimli = std.crypto.core.Gimli.init(seed);

    // This is at the end so that accidental recursive dependencies result
    // in stack overflows instead of invalid random data.
    ctx.init_state = .initialized;

    return fillWithCsprng(buffer);
}
