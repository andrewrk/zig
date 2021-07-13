// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.
// This file provides the system interface functions for Linux matching those
// that are provided by libc, whether or not libc is linked. The following
// abstractions are made:
// * Work around kernel bugs and limitations. For example, see sendmmsg.
// * Implement all the syscalls in the same way that libc functions will
//   provide `rename` when only the `renameat` syscall exists.
// * Does not support POSIX thread cancellation.
const std = @import("../std.zig");
const assert = std.debug.assert;
const maxInt = std.math.maxInt;
const elf = std.elf;
const vdso = @import("linux/vdso.zig");
const dl = @import("../dynamic_library.zig");
const native_arch = std.Target.current.cpu.arch;
const native_endian = native_arch.endian();

pub usingnamespace switch (native_arch) {
    .i386 => @import("linux/i386.zig"),
    .x86_64 => @import("linux/x86_64.zig"),
    .aarch64 => @import("linux/arm64.zig"),
    .arm => @import("linux/arm-eabi.zig"),
    .thumb => @import("linux/thumb.zig"),
    .riscv64 => @import("linux/riscv64.zig"),
    .sparcv9 => @import("linux/sparc64.zig"),
    .mips, .mipsel => @import("linux/mips.zig"),
    .powerpc => @import("linux/powerpc.zig"),
    .powerpc64, .powerpc64le => @import("linux/powerpc64.zig"),
    else => struct {},
};
pub usingnamespace @import("bits.zig");
pub const tls = @import("linux/tls.zig");
pub const pie = @import("linux/start_pie.zig");
pub const BPF = @import("linux/bpf.zig");
pub usingnamespace @import("linux/io_uring.zig");

/// Set by startup code, used by `getauxval`.
pub var elf_aux_maybe: ?[*]std.elf.Auxv = null;

/// See `std.elf` for the constants.
pub fn getauxval(index: usize) usize {
    const auxv = elf_aux_maybe orelse return 0;
    var i: usize = 0;
    while (auxv[i].a_type != std.elf.AT_NULL) : (i += 1) {
        if (auxv[i].a_type == index)
            return auxv[i].a_un.a_val;
    }
    return 0;
}

// Some architectures (and some syscalls) require 64bit parameters to be passed
// in a even-aligned register pair.
const require_aligned_register_pair =
    std.Target.current.cpu.arch.isPPC() or
    std.Target.current.cpu.arch.isMIPS() or
    std.Target.current.cpu.arch.isARM() or
    std.Target.current.cpu.arch.isThumb();

// Split a 64bit value into a {LSB,MSB} pair.
// The LE/BE variants specify the endianness to assume.
fn splitValueLE64(val: i64) [2]u32 {
    const u = @bitCast(u64, val);
    return [2]u32{
        @truncate(u32, u),
        @truncate(u32, u >> 32),
    };
}
fn splitValueBE64(val: i64) [2]u32 {
    const u = @bitCast(u64, val);
    return [2]u32{
        @truncate(u32, u >> 32),
        @truncate(u32, u),
    };
}
fn splitValue64(val: i64) [2]u32 {
    const u = @bitCast(u64, val);
    switch (native_endian) {
        .Little => return [2]u32{
            @truncate(u32, u),
            @truncate(u32, u >> 32),
        },
        .Big => return [2]u32{
            @truncate(u32, u >> 32),
            @truncate(u32, u),
        },
    }
}

/// Get the errno from a syscall return value, or 0 for no error.
pub fn getErrno(r: usize) u12 {
    const signed_r = @bitCast(isize, r);
    return if (signed_r > -4096 and signed_r < 0) @intCast(u12, -signed_r) else 0;
}

pub fn dup(old: i32) usize {
    return syscall1(.dup, @bitCast(usize, @as(isize, old)));
}

pub fn dup2(old: i32, new: i32) usize {
    if (@hasField(SYS, "dup2")) {
        return syscall2(.dup2, @bitCast(usize, @as(isize, old)), @bitCast(usize, @as(isize, new)));
    } else {
        if (old == new) {
            if (std.debug.runtime_safety) {
                const rc = syscall2(.fcntl, @bitCast(usize, @as(isize, old)), F_GETFD);
                if (@bitCast(isize, rc) < 0) return rc;
            }
            return @intCast(usize, old);
        } else {
            return syscall3(.dup3, @bitCast(usize, @as(isize, old)), @bitCast(usize, @as(isize, new)), 0);
        }
    }
}

pub fn dup3(old: i32, new: i32, flags: u32) usize {
    return syscall3(.dup3, @bitCast(usize, @as(isize, old)), @bitCast(usize, @as(isize, new)), flags);
}

pub fn chdir(path: [*:0]const u8) usize {
    return syscall1(.chdir, @ptrToInt(path));
}

pub fn fchdir(fd: fd_t) usize {
    return syscall1(.fchdir, @bitCast(usize, @as(isize, fd)));
}

pub fn chroot(path: [*:0]const u8) usize {
    return syscall1(.chroot, @ptrToInt(path));
}

pub fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) usize {
    return syscall3(.execve, @ptrToInt(path), @ptrToInt(argv), @ptrToInt(envp));
}

pub fn fork() usize {
    if (comptime native_arch.isSPARC()) {
        return syscall_fork();
    } else if (@hasField(SYS, "fork")) {
        return syscall0(.fork);
    } else {
        return syscall2(.clone, SIGCHLD, 0);
    }
}

/// This must be inline, and inline call the syscall function, because if the
/// child does a return it will clobber the parent's stack.
/// It is advised to avoid this function and use clone instead, because
/// the compiler is not aware of how vfork affects control flow and you may
/// see different results in optimized builds.
pub inline fn vfork() usize {
    return @call(.{ .modifier = .always_inline }, syscall0, .{.vfork});
}

pub fn futimens(fd: i32, times: *const [2]timespec) usize {
    return utimensat(fd, null, times, 0);
}

pub fn utimensat(dirfd: i32, path: ?[*:0]const u8, times: *const [2]timespec, flags: u32) usize {
    return syscall4(.utimensat, @bitCast(usize, @as(isize, dirfd)), @ptrToInt(path), @ptrToInt(times), flags);
}

pub fn fallocate(fd: i32, mode: i32, offset: i64, length: i64) usize {
    if (usize_bits < 64) {
        const offset_halves = splitValue64(offset);
        const length_halves = splitValue64(length);
        return syscall6(
            .fallocate,
            @bitCast(usize, @as(isize, fd)),
            @bitCast(usize, @as(isize, mode)),
            offset_halves[0],
            offset_halves[1],
            length_halves[0],
            length_halves[1],
        );
    } else {
        return syscall4(
            .fallocate,
            @bitCast(usize, @as(isize, fd)),
            @bitCast(usize, @as(isize, mode)),
            @bitCast(u64, offset),
            @bitCast(u64, length),
        );
    }
}

pub fn futex_wait(uaddr: *const i32, futex_op: u32, val: i32, timeout: ?*const timespec) usize {
    return syscall4(.futex, @ptrToInt(uaddr), futex_op, @bitCast(u32, val), @ptrToInt(timeout));
}

pub fn futex_wake(uaddr: *const i32, futex_op: u32, val: i32) usize {
    return syscall3(.futex, @ptrToInt(uaddr), futex_op, @bitCast(u32, val));
}

pub fn getcwd(buf: [*]u8, size: usize) usize {
    return syscall2(.getcwd, @ptrToInt(buf), size);
}

pub fn getdents(fd: i32, dirp: [*]u8, len: usize) usize {
    return syscall3(
        .getdents,
        @bitCast(usize, @as(isize, fd)),
        @ptrToInt(dirp),
        std.math.min(len, maxInt(c_int)),
    );
}

pub fn getdents64(fd: i32, dirp: [*]u8, len: usize) usize {
    return syscall3(
        .getdents64,
        @bitCast(usize, @as(isize, fd)),
        @ptrToInt(dirp),
        std.math.min(len, maxInt(c_int)),
    );
}

pub fn inotify_init1(flags: u32) usize {
    return syscall1(.inotify_init1, flags);
}

pub fn inotify_add_watch(fd: i32, pathname: [*:0]const u8, mask: u32) usize {
    return syscall3(.inotify_add_watch, @bitCast(usize, @as(isize, fd)), @ptrToInt(pathname), mask);
}

pub fn inotify_rm_watch(fd: i32, wd: i32) usize {
    return syscall2(.inotify_rm_watch, @bitCast(usize, @as(isize, fd)), @bitCast(usize, @as(isize, wd)));
}

pub fn readlink(noalias path: [*:0]const u8, noalias buf_ptr: [*]u8, buf_len: usize) usize {
    if (@hasField(SYS, "readlink")) {
        return syscall3(.readlink, @ptrToInt(path), @ptrToInt(buf_ptr), buf_len);
    } else {
        return syscall4(.readlinkat, @bitCast(usize, @as(isize, AT_FDCWD)), @ptrToInt(path), @ptrToInt(buf_ptr), buf_len);
    }
}

pub fn readlinkat(dirfd: i32, noalias path: [*:0]const u8, noalias buf_ptr: [*]u8, buf_len: usize) usize {
    return syscall4(.readlinkat, @bitCast(usize, @as(isize, dirfd)), @ptrToInt(path), @ptrToInt(buf_ptr), buf_len);
}

pub fn mkdir(path: [*:0]const u8, mode: u32) usize {
    if (@hasField(SYS, "mkdir")) {
        return syscall2(.mkdir, @ptrToInt(path), mode);
    } else {
        return syscall3(.mkdirat, @bitCast(usize, @as(isize, AT_FDCWD)), @ptrToInt(path), mode);
    }
}

pub fn mkdirat(dirfd: i32, path: [*:0]const u8, mode: u32) usize {
    return syscall3(.mkdirat, @bitCast(usize, @as(isize, dirfd)), @ptrToInt(path), mode);
}

pub fn mknod(path: [*:0]const u8, mode: u32, dev: u32) usize {
    if (@hasField(SYS, "mknod")) {
        return syscall3(.mknod, @ptrToInt(path), mode, dev);
    } else {
        return mknodat(AT_FDCWD, path, mode, dev);
    }
}

pub fn mknodat(dirfd: i32, path: [*:0]const u8, mode: u32, dev: u32) usize {
    return syscall4(.mknodat, @bitCast(usize, @as(isize, dirfd)), @ptrToInt(path), mode, dev);
}

pub fn mount(special: [*:0]const u8, dir: [*:0]const u8, fstype: [*:0]const u8, flags: u32, data: usize) usize {
    return syscall5(.mount, @ptrToInt(special), @ptrToInt(dir), @ptrToInt(fstype), flags, data);
}

pub fn umount(special: [*:0]const u8) usize {
    return syscall2(.umount2, @ptrToInt(special), 0);
}

pub fn umount2(special: [*:0]const u8, flags: u32) usize {
    return syscall2(.umount2, @ptrToInt(special), flags);
}

pub fn mmap(address: ?[*]u8, length: usize, prot: usize, flags: u32, fd: i32, offset: i64) usize {
    if (@hasField(SYS, "mmap2")) {
        // Make sure the offset is also specified in multiples of page size
        if ((offset & (MMAP2_UNIT - 1)) != 0)
            return @bitCast(usize, @as(isize, -EINVAL));

        return syscall6(
            .mmap2,
            @ptrToInt(address),
            length,
            prot,
            flags,
            @bitCast(usize, @as(isize, fd)),
            @truncate(usize, @bitCast(u64, offset) / MMAP2_UNIT),
        );
    } else {
        return syscall6(
            .mmap,
            @ptrToInt(address),
            length,
            prot,
            flags,
            @bitCast(usize, @as(isize, fd)),
            @bitCast(u64, offset),
        );
    }
}

pub fn mprotect(address: [*]const u8, length: usize, protection: usize) usize {
    return syscall3(.mprotect, @ptrToInt(address), length, protection);
}

pub fn munmap(address: [*]const u8, length: usize) usize {
    return syscall2(.munmap, @ptrToInt(address), length);
}

pub fn poll(fds: [*]pollfd, n: nfds_t, timeout: i32) usize {
    if (@hasField(SYS, "poll")) {
        return syscall3(.poll, @ptrToInt(fds), n, @bitCast(u32, timeout));
    } else {
        return syscall5(
            .ppoll,
            @ptrToInt(fds),
            n,
            @ptrToInt(if (timeout >= 0)
                &timespec{
                    .tv_sec = @divTrunc(timeout, 1000),
                    .tv_nsec = @rem(timeout, 1000) * 1000000,
                }
            else
                null),
            0,
            NSIG / 8,
        );
    }
}

pub fn ppoll(fds: [*]pollfd, n: nfds_t, timeout: ?*timespec, sigmask: ?*const sigset_t) usize {
    return syscall5(.ppoll, @ptrToInt(fds), n, @ptrToInt(timeout), @ptrToInt(sigmask), NSIG / 8);
}

pub fn read(fd: i32, buf: [*]u8, count: usize) usize {
    return syscall3(.read, @bitCast(usize, @as(isize, fd)), @ptrToInt(buf), count);
}

pub fn preadv(fd: i32, iov: [*]const iovec, count: usize, offset: i64) usize {
    const offset_halves = splitValueLE64(offset);
    return syscall5(
        .preadv,
        @bitCast(usize, @as(isize, fd)),
        @ptrToInt(iov),
        count,
        offset_halves[0],
        offset_halves[1],
    );
}

pub fn preadv2(fd: i32, iov: [*]const iovec, count: usize, offset: i64, flags: kernel_rwf) usize {
    const offset_halves = splitValue64(offset);
    return syscall6(
        .preadv2,
        @bitCast(usize, @as(isize, fd)),
        @ptrToInt(iov),
        count,
        offset_halves[0],
        offset_halves[1],
        flags,
    );
}

pub fn readv(fd: i32, iov: [*]const iovec, count: usize) usize {
    return syscall3(.readv, @bitCast(usize, @as(isize, fd)), @ptrToInt(iov), count);
}

pub fn writev(fd: i32, iov: [*]const iovec_const, count: usize) usize {
    return syscall3(.writev, @bitCast(usize, @as(isize, fd)), @ptrToInt(iov), count);
}

pub fn pwritev(fd: i32, iov: [*]const iovec_const, count: usize, offset: i64) usize {
    const offset_halves = splitValueLE64(offset);
    return syscall5(
        .pwritev,
        @bitCast(usize, @as(isize, fd)),
        @ptrToInt(iov),
        count,
        offset_halves[0],
        offset_halves[1],
    );
}

pub fn pwritev2(fd: i32, iov: [*]const iovec_const, count: usize, offset: i64, flags: kernel_rwf) usize {
    const offset_halves = splitValue64(offset);
    return syscall6(
        .pwritev2,
        @bitCast(usize, @as(isize, fd)),
        @ptrToInt(iov),
        count,
        offset_halves[0],
        offset_halves[1],
        flags,
    );
}

pub fn rmdir(path: [*:0]const u8) usize {
    if (@hasField(SYS, "rmdir")) {
        return syscall1(.rmdir, @ptrToInt(path));
    } else {
        return syscall3(.unlinkat, @bitCast(usize, @as(isize, AT_FDCWD)), @ptrToInt(path), AT_REMOVEDIR);
    }
}

pub fn symlink(existing: [*:0]const u8, new: [*:0]const u8) usize {
    if (@hasField(SYS, "symlink")) {
        return syscall2(.symlink, @ptrToInt(existing), @ptrToInt(new));
    } else {
        return syscall3(.symlinkat, @ptrToInt(existing), @bitCast(usize, @as(isize, AT_FDCWD)), @ptrToInt(new));
    }
}

pub fn symlinkat(existing: [*:0]const u8, newfd: i32, newpath: [*:0]const u8) usize {
    return syscall3(.symlinkat, @ptrToInt(existing), @bitCast(usize, @as(isize, newfd)), @ptrToInt(newpath));
}

pub fn pread(fd: i32, buf: [*]u8, count: usize, offset: i64) usize {
    if (@hasField(SYS, "pread64") and usize_bits < 64) {
        const offset_halves = splitValue64(offset);
        if (require_aligned_register_pair) {
            return syscall6(
                .pread64,
                @bitCast(usize, @as(isize, fd)),
                @ptrToInt(buf),
                count,
                0,
                offset_halves[0],
                offset_halves[1],
            );
        } else {
            return syscall5(
                .pread64,
                @bitCast(usize, @as(isize, fd)),
                @ptrToInt(buf),
                count,
                offset_halves[0],
                offset_halves[1],
            );
        }
    } else {
        // Some architectures (eg. 64bit SPARC) pread is called pread64.
        const S = if (!@hasField(SYS, "pread") and @hasField(SYS, "pread64")) .pread64 else .pread;
        return syscall4(
            S,
            @bitCast(usize, @as(isize, fd)),
            @ptrToInt(buf),
            count,
            @bitCast(u64, offset),
        );
    }
}

pub fn access(path: [*:0]const u8, mode: u32) usize {
    if (@hasField(SYS, "access")) {
        return syscall2(.access, @ptrToInt(path), mode);
    } else {
        return syscall4(.faccessat, @bitCast(usize, @as(isize, AT_FDCWD)), @ptrToInt(path), mode, 0);
    }
}

pub fn faccessat(dirfd: i32, path: [*:0]const u8, mode: u32, flags: u32) usize {
    return syscall4(.faccessat, @bitCast(usize, @as(isize, dirfd)), @ptrToInt(path), mode, flags);
}

pub fn pipe(fd: *[2]i32) usize {
    if (comptime (native_arch.isMIPS() or native_arch.isSPARC())) {
        return syscall_pipe(fd);
    } else if (@hasField(SYS, "pipe")) {
        return syscall1(.pipe, @ptrToInt(fd));
    } else {
        return syscall2(.pipe2, @ptrToInt(fd), 0);
    }
}

pub fn pipe2(fd: *[2]i32, flags: u32) usize {
    return syscall2(.pipe2, @ptrToInt(fd), flags);
}

pub fn write(fd: i32, buf: [*]const u8, count: usize) usize {
    return syscall3(.write, @bitCast(usize, @as(isize, fd)), @ptrToInt(buf), count);
}

pub fn ftruncate(fd: i32, length: i64) usize {
    if (@hasField(SYS, "ftruncate64") and usize_bits < 64) {
        const length_halves = splitValue64(length);
        if (require_aligned_register_pair) {
            return syscall4(
                .ftruncate64,
                @bitCast(usize, @as(isize, fd)),
                0,
                length_halves[0],
                length_halves[1],
            );
        } else {
            return syscall3(
                .ftruncate64,
                @bitCast(usize, @as(isize, fd)),
                length_halves[0],
                length_halves[1],
            );
        }
    } else {
        return syscall2(
            .ftruncate,
            @bitCast(usize, @as(isize, fd)),
            @bitCast(usize, length),
        );
    }
}

pub fn pwrite(fd: i32, buf: [*]const u8, count: usize, offset: i64) usize {
    if (@hasField(SYS, "pwrite64") and usize_bits < 64) {
        const offset_halves = splitValue64(offset);

        if (require_aligned_register_pair) {
            return syscall6(
                .pwrite64,
                @bitCast(usize, @as(isize, fd)),
                @ptrToInt(buf),
                count,
                0,
                offset_halves[0],
                offset_halves[1],
            );
        } else {
            return syscall5(
                .pwrite64,
                @bitCast(usize, @as(isize, fd)),
                @ptrToInt(buf),
                count,
                offset_halves[0],
                offset_halves[1],
            );
        }
    } else {
        // Some architectures (eg. 64bit SPARC) pwrite is called pwrite64.
        const S = if (!@hasField(SYS, "pwrite") and @hasField(SYS, "pwrite64")) .pwrite64 else .pwrite;
        return syscall4(
            S,
            @bitCast(usize, @as(isize, fd)),
            @ptrToInt(buf),
            count,
            @bitCast(u64, offset),
        );
    }
}

pub fn rename(old: [*:0]const u8, new: [*:0]const u8) usize {
    if (@hasField(SYS, "rename")) {
        return syscall2(.rename, @ptrToInt(old), @ptrToInt(new));
    } else if (@hasField(SYS, "renameat")) {
        return syscall4(.renameat, @bitCast(usize, @as(isize, AT_FDCWD)), @ptrToInt(old), @bitCast(usize, @as(isize, AT_FDCWD)), @ptrToInt(new));
    } else {
        return syscall5(.renameat2, @bitCast(usize, @as(isize, AT_FDCWD)), @ptrToInt(old), @bitCast(usize, @as(isize, AT_FDCWD)), @ptrToInt(new), 0);
    }
}

pub fn renameat(oldfd: i32, oldpath: [*]const u8, newfd: i32, newpath: [*]const u8) usize {
    if (@hasField(SYS, "renameat")) {
        return syscall4(
            .renameat,
            @bitCast(usize, @as(isize, oldfd)),
            @ptrToInt(oldpath),
            @bitCast(usize, @as(isize, newfd)),
            @ptrToInt(newpath),
        );
    } else {
        return syscall5(
            .renameat2,
            @bitCast(usize, @as(isize, oldfd)),
            @ptrToInt(oldpath),
            @bitCast(usize, @as(isize, newfd)),
            @ptrToInt(newpath),
            0,
        );
    }
}

pub fn renameat2(oldfd: i32, oldpath: [*:0]const u8, newfd: i32, newpath: [*:0]const u8, flags: u32) usize {
    return syscall5(
        .renameat2,
        @bitCast(usize, @as(isize, oldfd)),
        @ptrToInt(oldpath),
        @bitCast(usize, @as(isize, newfd)),
        @ptrToInt(newpath),
        flags,
    );
}

pub fn open(path: [*:0]const u8, flags: u32, perm: mode_t) usize {
    if (@hasField(SYS, "open")) {
        return syscall3(.open, @ptrToInt(path), flags, perm);
    } else {
        return syscall4(
            .openat,
            @bitCast(usize, @as(isize, AT_FDCWD)),
            @ptrToInt(path),
            flags,
            perm,
        );
    }
}

pub fn create(path: [*:0]const u8, perm: mode_t) usize {
    return syscall2(.creat, @ptrToInt(path), perm);
}

pub fn openat(dirfd: i32, path: [*:0]const u8, flags: u32, mode: mode_t) usize {
    // dirfd could be negative, for example AT_FDCWD is -100
    return syscall4(.openat, @bitCast(usize, @as(isize, dirfd)), @ptrToInt(path), flags, mode);
}

/// See also `clone` (from the arch-specific include)
pub fn clone5(flags: usize, child_stack_ptr: usize, parent_tid: *i32, child_tid: *i32, newtls: usize) usize {
    return syscall5(.clone, flags, child_stack_ptr, @ptrToInt(parent_tid), @ptrToInt(child_tid), newtls);
}

/// See also `clone` (from the arch-specific include)
pub fn clone2(flags: u32, child_stack_ptr: usize) usize {
    return syscall2(.clone, flags, child_stack_ptr);
}

pub fn close(fd: i32) usize {
    return syscall1(.close, @bitCast(usize, @as(isize, fd)));
}

/// Can only be called on 32 bit systems. For 64 bit see `lseek`.
pub fn llseek(fd: i32, offset: u64, result: ?*u64, whence: usize) usize {
    // NOTE: The offset parameter splitting is independent from the target
    // endianness.
    return syscall5(
        ._llseek,
        @bitCast(usize, @as(isize, fd)),
        @truncate(usize, offset >> 32),
        @truncate(usize, offset),
        @ptrToInt(result),
        whence,
    );
}

/// Can only be called on 64 bit systems. For 32 bit see `llseek`.
pub fn lseek(fd: i32, offset: i64, whence: usize) usize {
    return syscall3(.lseek, @bitCast(usize, @as(isize, fd)), @bitCast(usize, offset), whence);
}

pub fn exit(status: i32) noreturn {
    _ = syscall1(.exit, @bitCast(usize, @as(isize, status)));
    unreachable;
}

pub fn exit_group(status: i32) noreturn {
    _ = syscall1(.exit_group, @bitCast(usize, @as(isize, status)));
    unreachable;
}

pub fn getrandom(buf: [*]u8, count: usize, flags: u32) usize {
    return syscall3(.getrandom, @ptrToInt(buf), count, flags);
}

pub fn kill(pid: pid_t, sig: i32) usize {
    return syscall2(.kill, @bitCast(usize, @as(isize, pid)), @bitCast(usize, @as(isize, sig)));
}

pub fn tkill(tid: pid_t, sig: i32) usize {
    return syscall2(.tkill, @bitCast(usize, @as(isize, tid)), @bitCast(usize, @as(isize, sig)));
}

pub fn tgkill(tgid: pid_t, tid: pid_t, sig: i32) usize {
    return syscall3(.tgkill, @bitCast(usize, @as(isize, tgid)), @bitCast(usize, @as(isize, tid)), @bitCast(usize, @as(isize, sig)));
}

pub fn link(oldpath: [*:0]const u8, newpath: [*:0]const u8, flags: i32) usize {
    if (@hasField(SYS, "link")) {
        return syscall3(
            .link,
            @ptrToInt(oldpath),
            @ptrToInt(newpath),
            @bitCast(usize, @as(isize, flags)),
        );
    } else {
        return syscall5(
            .linkat,
            @bitCast(usize, @as(isize, AT_FDCWD)),
            @ptrToInt(oldpath),
            @bitCast(usize, @as(isize, AT_FDCWD)),
            @ptrToInt(newpath),
            @bitCast(usize, @as(isize, flags)),
        );
    }
}

pub fn linkat(oldfd: fd_t, oldpath: [*:0]const u8, newfd: fd_t, newpath: [*:0]const u8, flags: i32) usize {
    return syscall5(
        .linkat,
        @bitCast(usize, @as(isize, oldfd)),
        @ptrToInt(oldpath),
        @bitCast(usize, @as(isize, newfd)),
        @ptrToInt(newpath),
        @bitCast(usize, @as(isize, flags)),
    );
}

pub fn unlink(path: [*:0]const u8) usize {
    if (@hasField(SYS, "unlink")) {
        return syscall1(.unlink, @ptrToInt(path));
    } else {
        return syscall3(.unlinkat, @bitCast(usize, @as(isize, AT_FDCWD)), @ptrToInt(path), 0);
    }
}

pub fn unlinkat(dirfd: i32, path: [*:0]const u8, flags: u32) usize {
    return syscall3(.unlinkat, @bitCast(usize, @as(isize, dirfd)), @ptrToInt(path), flags);
}

pub fn waitpid(pid: pid_t, status: *u32, flags: u32) usize {
    return syscall4(.wait4, @bitCast(usize, @as(isize, pid)), @ptrToInt(status), flags, 0);
}

pub fn waitid(id_type: P, id: i32, infop: *siginfo_t, flags: u32) usize {
    return syscall5(.waitid, @enumToInt(id_type), @bitCast(usize, @as(isize, id)), @ptrToInt(infop), flags, 0);
}

pub fn fcntl(fd: fd_t, cmd: i32, arg: usize) usize {
    return syscall3(.fcntl, @bitCast(usize, @as(isize, fd)), @bitCast(usize, @as(isize, cmd)), arg);
}

pub fn flock(fd: fd_t, operation: i32) usize {
    return syscall2(.flock, @bitCast(usize, @as(isize, fd)), @bitCast(usize, @as(isize, operation)));
}

var vdso_clock_gettime = @ptrCast(?*const c_void, init_vdso_clock_gettime);

// We must follow the C calling convention when we call into the VDSO
const vdso_clock_gettime_ty = fn (i32, *timespec) callconv(.C) usize;

pub fn clock_gettime(clk_id: i32, tp: *timespec) usize {
    if (@hasDecl(@This(), "VDSO_CGT_SYM")) {
        const ptr = @atomicLoad(?*const c_void, &vdso_clock_gettime, .Unordered);
        if (ptr) |fn_ptr| {
            const f = @ptrCast(vdso_clock_gettime_ty, fn_ptr);
            const rc = f(clk_id, tp);
            switch (rc) {
                0, @bitCast(usize, @as(isize, -EINVAL)) => return rc,
                else => {},
            }
        }
    }
    return syscall2(.clock_gettime, @bitCast(usize, @as(isize, clk_id)), @ptrToInt(tp));
}

fn init_vdso_clock_gettime(clk: i32, ts: *timespec) callconv(.C) usize {
    const ptr = @intToPtr(?*const c_void, vdso.lookup(VDSO_CGT_VER, VDSO_CGT_SYM));
    // Note that we may not have a VDSO at all, update the stub address anyway
    // so that clock_gettime will fall back on the good old (and slow) syscall
    @atomicStore(?*const c_void, &vdso_clock_gettime, ptr, .Monotonic);
    // Call into the VDSO if available
    if (ptr) |fn_ptr| {
        const f = @ptrCast(vdso_clock_gettime_ty, fn_ptr);
        return f(clk, ts);
    }
    return @bitCast(usize, @as(isize, -ENOSYS));
}

pub fn clock_getres(clk_id: i32, tp: *timespec) usize {
    return syscall2(.clock_getres, @bitCast(usize, @as(isize, clk_id)), @ptrToInt(tp));
}

pub fn clock_settime(clk_id: i32, tp: *const timespec) usize {
    return syscall2(.clock_settime, @bitCast(usize, @as(isize, clk_id)), @ptrToInt(tp));
}

pub fn gettimeofday(tv: *timeval, tz: *timezone) usize {
    return syscall2(.gettimeofday, @ptrToInt(tv), @ptrToInt(tz));
}

pub fn settimeofday(tv: *const timeval, tz: *const timezone) usize {
    return syscall2(.settimeofday, @ptrToInt(tv), @ptrToInt(tz));
}

pub fn nanosleep(req: *const timespec, rem: ?*timespec) usize {
    return syscall2(.nanosleep, @ptrToInt(req), @ptrToInt(rem));
}

pub fn setuid(uid: uid_t) usize {
    if (@hasField(SYS, "setuid32")) {
        return syscall1(.setuid32, uid);
    } else {
        return syscall1(.setuid, uid);
    }
}

pub fn setgid(gid: gid_t) usize {
    if (@hasField(SYS, "setgid32")) {
        return syscall1(.setgid32, gid);
    } else {
        return syscall1(.setgid, gid);
    }
}

pub fn setreuid(ruid: uid_t, euid: uid_t) usize {
    if (@hasField(SYS, "setreuid32")) {
        return syscall2(.setreuid32, ruid, euid);
    } else {
        return syscall2(.setreuid, ruid, euid);
    }
}

pub fn setregid(rgid: gid_t, egid: gid_t) usize {
    if (@hasField(SYS, "setregid32")) {
        return syscall2(.setregid32, rgid, egid);
    } else {
        return syscall2(.setregid, rgid, egid);
    }
}

pub fn getuid() uid_t {
    if (@hasField(SYS, "getuid32")) {
        return @intCast(uid_t, syscall0(.getuid32));
    } else {
        return @intCast(uid_t, syscall0(.getuid));
    }
}

pub fn getgid() gid_t {
    if (@hasField(SYS, "getgid32")) {
        return @intCast(gid_t, syscall0(.getgid32));
    } else {
        return @intCast(gid_t, syscall0(.getgid));
    }
}

pub fn geteuid() uid_t {
    if (@hasField(SYS, "geteuid32")) {
        return @intCast(uid_t, syscall0(.geteuid32));
    } else {
        return @intCast(uid_t, syscall0(.geteuid));
    }
}

pub fn getegid() gid_t {
    if (@hasField(SYS, "getegid32")) {
        return @intCast(gid_t, syscall0(.getegid32));
    } else {
        return @intCast(gid_t, syscall0(.getegid));
    }
}

pub fn seteuid(euid: uid_t) usize {
    // We use setresuid here instead of setreuid to ensure that the saved uid
    // is not changed. This is what musl and recent glibc versions do as well.
    //
    // The setresuid(2) man page says that if -1 is passed the corresponding
    // id will not be changed. Since uid_t is unsigned, this wraps around to the
    // max value in C.
    comptime assert(@typeInfo(uid_t) == .Int and @typeInfo(uid_t).Int.signedness == .unsigned);
    return setresuid(std.math.maxInt(uid_t), euid, std.math.maxInt(uid_t));
}

pub fn setegid(egid: gid_t) usize {
    // We use setresgid here instead of setregid to ensure that the saved uid
    // is not changed. This is what musl and recent glibc versions do as well.
    //
    // The setresgid(2) man page says that if -1 is passed the corresponding
    // id will not be changed. Since gid_t is unsigned, this wraps around to the
    // max value in C.
    comptime assert(@typeInfo(uid_t) == .Int and @typeInfo(uid_t).Int.signedness == .unsigned);
    return setresgid(std.math.maxInt(gid_t), egid, std.math.maxInt(gid_t));
}

pub fn getresuid(ruid: *uid_t, euid: *uid_t, suid: *uid_t) usize {
    if (@hasField(SYS, "getresuid32")) {
        return syscall3(.getresuid32, @ptrToInt(ruid), @ptrToInt(euid), @ptrToInt(suid));
    } else {
        return syscall3(.getresuid, @ptrToInt(ruid), @ptrToInt(euid), @ptrToInt(suid));
    }
}

pub fn getresgid(rgid: *gid_t, egid: *gid_t, sgid: *gid_t) usize {
    if (@hasField(SYS, "getresgid32")) {
        return syscall3(.getresgid32, @ptrToInt(rgid), @ptrToInt(egid), @ptrToInt(sgid));
    } else {
        return syscall3(.getresgid, @ptrToInt(rgid), @ptrToInt(egid), @ptrToInt(sgid));
    }
}

pub fn setresuid(ruid: uid_t, euid: uid_t, suid: uid_t) usize {
    if (@hasField(SYS, "setresuid32")) {
        return syscall3(.setresuid32, ruid, euid, suid);
    } else {
        return syscall3(.setresuid, ruid, euid, suid);
    }
}

pub fn setresgid(rgid: gid_t, egid: gid_t, sgid: gid_t) usize {
    if (@hasField(SYS, "setresgid32")) {
        return syscall3(.setresgid32, rgid, egid, sgid);
    } else {
        return syscall3(.setresgid, rgid, egid, sgid);
    }
}

pub fn getgroups(size: usize, list: *gid_t) usize {
    if (@hasField(SYS, "getgroups32")) {
        return syscall2(.getgroups32, size, @ptrToInt(list));
    } else {
        return syscall2(.getgroups, size, @ptrToInt(list));
    }
}

pub fn setgroups(size: usize, list: *const gid_t) usize {
    if (@hasField(SYS, "setgroups32")) {
        return syscall2(.setgroups32, size, @ptrToInt(list));
    } else {
        return syscall2(.setgroups, size, @ptrToInt(list));
    }
}

pub fn getpid() pid_t {
    return @bitCast(pid_t, @truncate(u32, syscall0(.getpid)));
}

pub fn gettid() pid_t {
    return @bitCast(pid_t, @truncate(u32, syscall0(.gettid)));
}

pub fn sigprocmask(flags: u32, noalias set: ?*const sigset_t, noalias oldset: ?*sigset_t) usize {
    return syscall4(.rt_sigprocmask, flags, @ptrToInt(set), @ptrToInt(oldset), NSIG / 8);
}

pub fn sigaction(sig: u6, noalias act: ?*const Sigaction, noalias oact: ?*Sigaction) usize {
    assert(sig >= 1);
    assert(sig != SIGKILL);
    assert(sig != SIGSTOP);

    var ksa: k_sigaction = undefined;
    var oldksa: k_sigaction = undefined;
    const mask_size = @sizeOf(@TypeOf(ksa.mask));

    if (act) |new| {
        const restorer_fn = if ((new.flags & SA_SIGINFO) != 0) restore_rt else restore;
        ksa = k_sigaction{
            .handler = new.handler.handler,
            .flags = new.flags | SA_RESTORER,
            .mask = undefined,
            .restorer = @ptrCast(fn () callconv(.C) void, restorer_fn),
        };
        @memcpy(@ptrCast([*]u8, &ksa.mask), @ptrCast([*]const u8, &new.mask), mask_size);
    }

    const ksa_arg = if (act != null) @ptrToInt(&ksa) else 0;
    const oldksa_arg = if (oact != null) @ptrToInt(&oldksa) else 0;

    const result = switch (native_arch) {
        // The sparc version of rt_sigaction needs the restorer function to be passed as an argument too.
        .sparc, .sparcv9 => syscall5(.rt_sigaction, sig, ksa_arg, oldksa_arg, @ptrToInt(ksa.restorer), mask_size),
        else => syscall4(.rt_sigaction, sig, ksa_arg, oldksa_arg, mask_size),
    };
    if (getErrno(result) != 0) return result;

    if (oact) |old| {
        old.handler.handler = oldksa.handler;
        old.flags = @truncate(c_uint, oldksa.flags);
        @memcpy(@ptrCast([*]u8, &old.mask), @ptrCast([*]const u8, &oldksa.mask), mask_size);
    }

    return 0;
}

const usize_bits = @typeInfo(usize).Int.bits;

pub fn sigaddset(set: *sigset_t, sig: u6) void {
    const s = sig - 1;
    // shift in musl: s&8*sizeof *set->__bits-1
    const shift = @intCast(u5, s & (usize_bits - 1));
    const val = @intCast(u32, 1) << shift;
    (set.*)[@intCast(usize, s) / usize_bits] |= val;
}

pub fn sigismember(set: *const sigset_t, sig: u6) bool {
    const s = sig - 1;
    return ((set.*)[@intCast(usize, s) / usize_bits] & (@intCast(usize, 1) << (s & (usize_bits - 1)))) != 0;
}

pub fn getsockname(fd: i32, noalias addr: *sockaddr, noalias len: *socklen_t) usize {
    if (native_arch == .i386) {
        return socketcall(SC_getsockname, &[3]usize{ @bitCast(usize, @as(isize, fd)), @ptrToInt(addr), @ptrToInt(len) });
    }
    return syscall3(.getsockname, @bitCast(usize, @as(isize, fd)), @ptrToInt(addr), @ptrToInt(len));
}

pub fn getpeername(fd: i32, noalias addr: *sockaddr, noalias len: *socklen_t) usize {
    if (native_arch == .i386) {
        return socketcall(SC_getpeername, &[3]usize{ @bitCast(usize, @as(isize, fd)), @ptrToInt(addr), @ptrToInt(len) });
    }
    return syscall3(.getpeername, @bitCast(usize, @as(isize, fd)), @ptrToInt(addr), @ptrToInt(len));
}

pub fn socket(domain: u32, socket_type: u32, protocol: u32) usize {
    if (native_arch == .i386) {
        return socketcall(SC_socket, &[3]usize{ domain, socket_type, protocol });
    }
    return syscall3(.socket, domain, socket_type, protocol);
}

pub fn setsockopt(fd: i32, level: u32, optname: u32, optval: [*]const u8, optlen: socklen_t) usize {
    if (native_arch == .i386) {
        return socketcall(SC_setsockopt, &[5]usize{ @bitCast(usize, @as(isize, fd)), level, optname, @ptrToInt(optval), @intCast(usize, optlen) });
    }
    return syscall5(.setsockopt, @bitCast(usize, @as(isize, fd)), level, optname, @ptrToInt(optval), @intCast(usize, optlen));
}

pub fn getsockopt(fd: i32, level: u32, optname: u32, noalias optval: [*]u8, noalias optlen: *socklen_t) usize {
    if (native_arch == .i386) {
        return socketcall(SC_getsockopt, &[5]usize{ @bitCast(usize, @as(isize, fd)), level, optname, @ptrToInt(optval), @ptrToInt(optlen) });
    }
    return syscall5(.getsockopt, @bitCast(usize, @as(isize, fd)), level, optname, @ptrToInt(optval), @ptrToInt(optlen));
}

pub fn sendmsg(fd: i32, msg: *const std.x.os.Socket.Message, flags: c_int) usize {
    if (native_arch == .i386) {
        return socketcall(SC_sendmsg, &[3]usize{ @bitCast(usize, @as(isize, fd)), @ptrToInt(msg), @bitCast(usize, @as(isize, flags)) });
    }
    return syscall3(.sendmsg, @bitCast(usize, @as(isize, fd)), @ptrToInt(msg), @bitCast(usize, @as(isize, flags)));
}

pub fn sendmmsg(fd: i32, msgvec: [*]mmsghdr_const, vlen: u32, flags: u32) usize {
    if (@typeInfo(usize).Int.bits > @typeInfo(@TypeOf(mmsghdr(undefined).msg_len)).Int.bits) {
        // workaround kernel brokenness:
        // if adding up all iov_len overflows a i32 then split into multiple calls
        // see https://www.openwall.com/lists/musl/2014/06/07/5
        const kvlen = if (vlen > IOV_MAX) IOV_MAX else vlen; // matches kernel
        var next_unsent: usize = 0;
        for (msgvec[0..kvlen]) |*msg, i| {
            var size: i32 = 0;
            const msg_iovlen = @intCast(usize, msg.msg_hdr.msg_iovlen); // kernel side this is treated as unsigned
            for (msg.msg_hdr.msg_iov[0..msg_iovlen]) |iov| {
                if (iov.iov_len > std.math.maxInt(i32) or @addWithOverflow(i32, size, @intCast(i32, iov.iov_len), &size)) {
                    // batch-send all messages up to the current message
                    if (next_unsent < i) {
                        const batch_size = i - next_unsent;
                        const r = syscall4(.sendmmsg, @bitCast(usize, @as(isize, fd)), @ptrToInt(&msgvec[next_unsent]), batch_size, flags);
                        if (getErrno(r) != 0) return next_unsent;
                        if (r < batch_size) return next_unsent + r;
                    }
                    // send current message as own packet
                    const r = sendmsg(fd, &msg.msg_hdr, flags);
                    if (getErrno(r) != 0) return r;
                    // Linux limits the total bytes sent by sendmsg to INT_MAX, so this cast is safe.
                    msg.msg_len = @intCast(u32, r);
                    next_unsent = i + 1;
                    break;
                }
            }
        }
        if (next_unsent < kvlen or next_unsent == 0) { // want to make sure at least one syscall occurs (e.g. to trigger MSG_EOR)
            const batch_size = kvlen - next_unsent;
            const r = syscall4(.sendmmsg, @bitCast(usize, @as(isize, fd)), @ptrToInt(&msgvec[next_unsent]), batch_size, flags);
            if (getErrno(r) != 0) return r;
            return next_unsent + r;
        }
        return kvlen;
    }
    return syscall4(.sendmmsg, @bitCast(usize, @as(isize, fd)), @ptrToInt(msgvec), vlen, flags);
}

pub fn connect(fd: i32, addr: *const c_void, len: socklen_t) usize {
    if (native_arch == .i386) {
        return socketcall(SC_connect, &[3]usize{ @bitCast(usize, @as(isize, fd)), @ptrToInt(addr), len });
    }
    return syscall3(.connect, @bitCast(usize, @as(isize, fd)), @ptrToInt(addr), len);
}

pub fn recvmsg(fd: i32, msg: *std.x.os.Socket.Message, flags: c_int) usize {
    if (native_arch == .i386) {
        return socketcall(SC_recvmsg, &[3]usize{ @bitCast(usize, @as(isize, fd)), @ptrToInt(msg), @bitCast(usize, @as(isize, flags)) });
    }
    return syscall3(.recvmsg, @bitCast(usize, @as(isize, fd)), @ptrToInt(msg), @bitCast(usize, @as(isize, flags)));
}

pub fn recvfrom(fd: i32, noalias buf: [*]u8, len: usize, flags: u32, noalias addr: ?*sockaddr, noalias alen: ?*socklen_t) usize {
    if (native_arch == .i386) {
        return socketcall(SC_recvfrom, &[6]usize{ @bitCast(usize, @as(isize, fd)), @ptrToInt(buf), len, flags, @ptrToInt(addr), @ptrToInt(alen) });
    }
    return syscall6(.recvfrom, @bitCast(usize, @as(isize, fd)), @ptrToInt(buf), len, flags, @ptrToInt(addr), @ptrToInt(alen));
}

pub fn shutdown(fd: i32, how: i32) usize {
    if (native_arch == .i386) {
        return socketcall(SC_shutdown, &[2]usize{ @bitCast(usize, @as(isize, fd)), @bitCast(usize, @as(isize, how)) });
    }
    return syscall2(.shutdown, @bitCast(usize, @as(isize, fd)), @bitCast(usize, @as(isize, how)));
}

pub fn bind(fd: i32, addr: *const sockaddr, len: socklen_t) usize {
    if (native_arch == .i386) {
        return socketcall(SC_bind, &[3]usize{ @bitCast(usize, @as(isize, fd)), @ptrToInt(addr), @intCast(usize, len) });
    }
    return syscall3(.bind, @bitCast(usize, @as(isize, fd)), @ptrToInt(addr), @intCast(usize, len));
}

pub fn listen(fd: i32, backlog: u32) usize {
    if (native_arch == .i386) {
        return socketcall(SC_listen, &[2]usize{ @bitCast(usize, @as(isize, fd)), backlog });
    }
    return syscall2(.listen, @bitCast(usize, @as(isize, fd)), backlog);
}

pub fn sendto(fd: i32, buf: [*]const u8, len: usize, flags: u32, addr: ?*const sockaddr, alen: socklen_t) usize {
    if (native_arch == .i386) {
        return socketcall(SC_sendto, &[6]usize{ @bitCast(usize, @as(isize, fd)), @ptrToInt(buf), len, flags, @ptrToInt(addr), @intCast(usize, alen) });
    }
    return syscall6(.sendto, @bitCast(usize, @as(isize, fd)), @ptrToInt(buf), len, flags, @ptrToInt(addr), @intCast(usize, alen));
}

pub fn sendfile(outfd: i32, infd: i32, offset: ?*i64, count: usize) usize {
    if (@hasField(SYS, "sendfile64")) {
        return syscall4(
            .sendfile64,
            @bitCast(usize, @as(isize, outfd)),
            @bitCast(usize, @as(isize, infd)),
            @ptrToInt(offset),
            count,
        );
    } else {
        return syscall4(
            .sendfile,
            @bitCast(usize, @as(isize, outfd)),
            @bitCast(usize, @as(isize, infd)),
            @ptrToInt(offset),
            count,
        );
    }
}

pub fn socketpair(domain: i32, socket_type: i32, protocol: i32, fd: [2]i32) usize {
    if (native_arch == .i386) {
        return socketcall(SC_socketpair, &[4]usize{ @intCast(usize, domain), @intCast(usize, socket_type), @intCast(usize, protocol), @ptrToInt(&fd[0]) });
    }
    return syscall4(.socketpair, @intCast(usize, domain), @intCast(usize, socket_type), @intCast(usize, protocol), @ptrToInt(&fd[0]));
}

pub fn accept(fd: i32, noalias addr: ?*sockaddr, noalias len: ?*socklen_t) usize {
    if (native_arch == .i386) {
        return socketcall(SC_accept, &[4]usize{ fd, addr, len, 0 });
    }
    return accept4(fd, addr, len, 0);
}

pub fn accept4(fd: i32, noalias addr: ?*sockaddr, noalias len: ?*socklen_t, flags: u32) usize {
    if (native_arch == .i386) {
        return socketcall(SC_accept4, &[4]usize{ @bitCast(usize, @as(isize, fd)), @ptrToInt(addr), @ptrToInt(len), flags });
    }
    return syscall4(.accept4, @bitCast(usize, @as(isize, fd)), @ptrToInt(addr), @ptrToInt(len), flags);
}

pub fn fstat(fd: i32, stat_buf: *kernel_stat) usize {
    if (@hasField(SYS, "fstat64")) {
        return syscall2(.fstat64, @bitCast(usize, @as(isize, fd)), @ptrToInt(stat_buf));
    } else {
        return syscall2(.fstat, @bitCast(usize, @as(isize, fd)), @ptrToInt(stat_buf));
    }
}

pub fn stat(pathname: [*:0]const u8, statbuf: *kernel_stat) usize {
    if (@hasField(SYS, "stat64")) {
        return syscall2(.stat64, @ptrToInt(pathname), @ptrToInt(statbuf));
    } else {
        return syscall2(.stat, @ptrToInt(pathname), @ptrToInt(statbuf));
    }
}

pub fn lstat(pathname: [*:0]const u8, statbuf: *kernel_stat) usize {
    if (@hasField(SYS, "lstat64")) {
        return syscall2(.lstat64, @ptrToInt(pathname), @ptrToInt(statbuf));
    } else {
        return syscall2(.lstat, @ptrToInt(pathname), @ptrToInt(statbuf));
    }
}

pub fn fstatat(dirfd: i32, path: [*:0]const u8, stat_buf: *kernel_stat, flags: u32) usize {
    if (@hasField(SYS, "fstatat64")) {
        return syscall4(.fstatat64, @bitCast(usize, @as(isize, dirfd)), @ptrToInt(path), @ptrToInt(stat_buf), flags);
    } else {
        return syscall4(.fstatat, @bitCast(usize, @as(isize, dirfd)), @ptrToInt(path), @ptrToInt(stat_buf), flags);
    }
}

pub fn statx(dirfd: i32, path: [*]const u8, flags: u32, mask: u32, statx_buf: *Statx) usize {
    if (@hasField(SYS, "statx")) {
        return syscall5(
            .statx,
            @bitCast(usize, @as(isize, dirfd)),
            @ptrToInt(path),
            flags,
            mask,
            @ptrToInt(statx_buf),
        );
    }
    return @bitCast(usize, @as(isize, -ENOSYS));
}

pub fn listxattr(path: [*:0]const u8, list: [*]u8, size: usize) usize {
    return syscall3(.listxattr, @ptrToInt(path), @ptrToInt(list), size);
}

pub fn llistxattr(path: [*:0]const u8, list: [*]u8, size: usize) usize {
    return syscall3(.llistxattr, @ptrToInt(path), @ptrToInt(list), size);
}

pub fn flistxattr(fd: usize, list: [*]u8, size: usize) usize {
    return syscall3(.flistxattr, fd, @ptrToInt(list), size);
}

pub fn getxattr(path: [*:0]const u8, name: [*:0]const u8, value: [*]u8, size: usize) usize {
    return syscall4(.getxattr, @ptrToInt(path), @ptrToInt(name), @ptrToInt(value), size);
}

pub fn lgetxattr(path: [*:0]const u8, name: [*:0]const u8, value: [*]u8, size: usize) usize {
    return syscall4(.lgetxattr, @ptrToInt(path), @ptrToInt(name), @ptrToInt(value), size);
}

pub fn fgetxattr(fd: usize, name: [*:0]const u8, value: [*]u8, size: usize) usize {
    return syscall4(.lgetxattr, fd, @ptrToInt(name), @ptrToInt(value), size);
}

pub fn setxattr(path: [*:0]const u8, name: [*:0]const u8, value: *const void, size: usize, flags: usize) usize {
    return syscall5(.setxattr, @ptrToInt(path), @ptrToInt(name), @ptrToInt(value), size, flags);
}

pub fn lsetxattr(path: [*:0]const u8, name: [*:0]const u8, value: *const void, size: usize, flags: usize) usize {
    return syscall5(.lsetxattr, @ptrToInt(path), @ptrToInt(name), @ptrToInt(value), size, flags);
}

pub fn fsetxattr(fd: usize, name: [*:0]const u8, value: *const void, size: usize, flags: usize) usize {
    return syscall5(.fsetxattr, fd, @ptrToInt(name), @ptrToInt(value), size, flags);
}

pub fn removexattr(path: [*:0]const u8, name: [*:0]const u8) usize {
    return syscall2(.removexattr, @ptrToInt(path), @ptrToInt(name));
}

pub fn lremovexattr(path: [*:0]const u8, name: [*:0]const u8) usize {
    return syscall2(.lremovexattr, @ptrToInt(path), @ptrToInt(name));
}

pub fn fremovexattr(fd: usize, name: [*:0]const u8) usize {
    return syscall2(.fremovexattr, fd, @ptrToInt(name));
}

pub fn sched_yield() usize {
    return syscall0(.sched_yield);
}

pub fn sched_getaffinity(pid: pid_t, size: usize, set: *cpu_set_t) usize {
    const rc = syscall3(.sched_getaffinity, @bitCast(usize, @as(isize, pid)), size, @ptrToInt(set));
    if (@bitCast(isize, rc) < 0) return rc;
    if (rc < size) @memset(@ptrCast([*]u8, set) + rc, 0, size - rc);
    return 0;
}

pub fn epoll_create() usize {
    return epoll_create1(0);
}

pub fn epoll_create1(flags: usize) usize {
    return syscall1(.epoll_create1, flags);
}

pub fn epoll_ctl(epoll_fd: i32, op: u32, fd: i32, ev: ?*epoll_event) usize {
    return syscall4(.epoll_ctl, @bitCast(usize, @as(isize, epoll_fd)), @intCast(usize, op), @bitCast(usize, @as(isize, fd)), @ptrToInt(ev));
}

pub fn epoll_wait(epoll_fd: i32, events: [*]epoll_event, maxevents: u32, timeout: i32) usize {
    return epoll_pwait(epoll_fd, events, maxevents, timeout, null);
}

pub fn epoll_pwait(epoll_fd: i32, events: [*]epoll_event, maxevents: u32, timeout: i32, sigmask: ?*const sigset_t) usize {
    return syscall6(
        .epoll_pwait,
        @bitCast(usize, @as(isize, epoll_fd)),
        @ptrToInt(events),
        @intCast(usize, maxevents),
        @bitCast(usize, @as(isize, timeout)),
        @ptrToInt(sigmask),
        @sizeOf(sigset_t),
    );
}

pub fn eventfd(count: u32, flags: u32) usize {
    return syscall2(.eventfd2, count, flags);
}

pub fn timerfd_create(clockid: i32, flags: u32) usize {
    return syscall2(.timerfd_create, @bitCast(usize, @as(isize, clockid)), flags);
}

pub const itimerspec = extern struct {
    it_interval: timespec,
    it_value: timespec,
};

pub fn timerfd_gettime(fd: i32, curr_value: *itimerspec) usize {
    return syscall2(.timerfd_gettime, @bitCast(usize, @as(isize, fd)), @ptrToInt(curr_value));
}

pub fn timerfd_settime(fd: i32, flags: u32, new_value: *const itimerspec, old_value: ?*itimerspec) usize {
    return syscall4(.timerfd_settime, @bitCast(usize, @as(isize, fd)), flags, @ptrToInt(new_value), @ptrToInt(old_value));
}

pub fn unshare(flags: usize) usize {
    return syscall1(.unshare, flags);
}

pub fn capget(hdrp: *cap_user_header_t, datap: *cap_user_data_t) usize {
    return syscall2(.capget, @ptrToInt(hdrp), @ptrToInt(datap));
}

pub fn capset(hdrp: *cap_user_header_t, datap: *const cap_user_data_t) usize {
    return syscall2(.capset, @ptrToInt(hdrp), @ptrToInt(datap));
}

pub fn sigaltstack(ss: ?*stack_t, old_ss: ?*stack_t) usize {
    return syscall2(.sigaltstack, @ptrToInt(ss), @ptrToInt(old_ss));
}

pub fn uname(uts: *utsname) usize {
    return syscall1(.uname, @ptrToInt(uts));
}

pub fn io_uring_setup(entries: u32, p: *io_uring_params) usize {
    return syscall2(.io_uring_setup, entries, @ptrToInt(p));
}

pub fn io_uring_enter(fd: i32, to_submit: u32, min_complete: u32, flags: u32, sig: ?*sigset_t) usize {
    return syscall6(.io_uring_enter, @bitCast(usize, @as(isize, fd)), to_submit, min_complete, flags, @ptrToInt(sig), NSIG / 8);
}

pub fn io_uring_register(fd: i32, opcode: IORING_REGISTER, arg: ?*const c_void, nr_args: u32) usize {
    return syscall4(.io_uring_register, @bitCast(usize, @as(isize, fd)), @enumToInt(opcode), @ptrToInt(arg), nr_args);
}

pub fn memfd_create(name: [*:0]const u8, flags: u32) usize {
    return syscall2(.memfd_create, @ptrToInt(name), flags);
}

pub fn getrusage(who: i32, usage: *rusage) usize {
    return syscall2(.getrusage, @bitCast(usize, @as(isize, who)), @ptrToInt(usage));
}

pub fn tcgetattr(fd: fd_t, termios_p: *termios) usize {
    return syscall3(.ioctl, @bitCast(usize, @as(isize, fd)), TCGETS, @ptrToInt(termios_p));
}

pub fn tcsetattr(fd: fd_t, optional_action: TCSA, termios_p: *const termios) usize {
    return syscall3(.ioctl, @bitCast(usize, @as(isize, fd)), TCSETS + @enumToInt(optional_action), @ptrToInt(termios_p));
}

pub fn ioctl(fd: fd_t, request: u32, arg: usize) usize {
    return syscall3(.ioctl, @bitCast(usize, @as(isize, fd)), request, arg);
}

pub fn signalfd(fd: fd_t, mask: *const sigset_t, flags: u32) usize {
    return syscall4(.signalfd4, @bitCast(usize, @as(isize, fd)), @ptrToInt(mask), NSIG / 8, flags);
}

pub fn copy_file_range(fd_in: fd_t, off_in: ?*i64, fd_out: fd_t, off_out: ?*i64, len: usize, flags: u32) usize {
    return syscall6(
        .copy_file_range,
        @bitCast(usize, @as(isize, fd_in)),
        @ptrToInt(off_in),
        @bitCast(usize, @as(isize, fd_out)),
        @ptrToInt(off_out),
        len,
        flags,
    );
}

pub fn bpf(cmd: BPF.Cmd, attr: *BPF.Attr, size: u32) usize {
    return syscall3(.bpf, @enumToInt(cmd), @ptrToInt(attr), size);
}

pub fn sync() void {
    _ = syscall0(.sync);
}

pub fn syncfs(fd: fd_t) usize {
    return syscall1(.syncfs, @bitCast(usize, @as(isize, fd)));
}

pub fn fsync(fd: fd_t) usize {
    return syscall1(.fsync, @bitCast(usize, @as(isize, fd)));
}

pub fn fdatasync(fd: fd_t) usize {
    return syscall1(.fdatasync, @bitCast(usize, @as(isize, fd)));
}

pub fn prctl(option: i32, arg2: usize, arg3: usize, arg4: usize, arg5: usize) usize {
    return syscall5(.prctl, @bitCast(usize, @as(isize, option)), arg2, arg3, arg4, arg5);
}

pub fn getrlimit(resource: rlimit_resource, rlim: *rlimit) usize {
    // use prlimit64 to have 64 bit limits on 32 bit platforms
    return prlimit(0, resource, null, rlim);
}

pub fn setrlimit(resource: rlimit_resource, rlim: *const rlimit) usize {
    // use prlimit64 to have 64 bit limits on 32 bit platforms
    return prlimit(0, resource, rlim, null);
}

pub fn prlimit(pid: pid_t, resource: rlimit_resource, new_limit: ?*const rlimit, old_limit: ?*rlimit) usize {
    return syscall4(
        .prlimit64,
        @bitCast(usize, @as(isize, pid)),
        @bitCast(usize, @as(isize, @enumToInt(resource))),
        @ptrToInt(new_limit),
        @ptrToInt(old_limit),
    );
}

pub fn madvise(address: [*]u8, len: usize, advice: u32) usize {
    return syscall3(.madvise, @ptrToInt(address), len, advice);
}

pub fn pidfd_open(pid: pid_t, flags: u32) usize {
    return syscall2(.pidfd_open, @bitCast(usize, @as(isize, pid)), flags);
}

pub fn pidfd_getfd(pidfd: fd_t, targetfd: fd_t, flags: u32) usize {
    return syscall3(
        .pidfd_getfd,
        @bitCast(usize, @as(isize, pidfd)),
        @bitCast(usize, @as(isize, targetfd)),
        flags,
    );
}

pub fn pidfd_send_signal(pidfd: fd_t, sig: i32, info: ?*siginfo_t, flags: u32) usize {
    return syscall4(
        .pidfd_send_signal,
        @bitCast(usize, @as(isize, pidfd)),
        @bitCast(usize, @as(isize, sig)),
        @ptrToInt(info),
        flags,
    );
}

pub fn process_vm_readv(pid: pid_t, local: [*]const iovec, local_count: usize, remote: [*]const iovec, remote_count: usize, flags: usize) usize {
    return syscall6(
        .process_vm_readv,
        @bitCast(usize, @as(isize, pid)),
        @ptrToInt(local),
        local_count,
        @ptrToInt(remote),
        remote_count,
        flags,
    );
}

pub fn process_vm_writev(pid: pid_t, local: [*]const iovec, local_count: usize, remote: [*]const iovec, remote_count: usize, flags: usize) usize {
    return syscall6(
        .process_vm_writev,
        @bitCast(usize, @as(isize, pid)),
        @ptrToInt(local),
        local_count,
        @ptrToInt(remote),
        remote_count,
        flags,
    );
}

pub fn fadvise(fd: fd_t, offset: i64, len: i64, advice: usize) usize {
    if (comptime std.Target.current.cpu.arch.isMIPS()) {
        // MIPS requires a 7 argument syscall

        const offset_halves = splitValue64(offset);
        const length_halves = splitValue64(len);

        return syscall7(
            .fadvise64,
            @bitCast(usize, @as(isize, fd)),
            0,
            offset_halves[0],
            offset_halves[1],
            length_halves[0],
            length_halves[1],
            advice,
        );
    } else if (comptime std.Target.current.cpu.arch.isARM()) {
        // ARM reorders the arguments

        const offset_halves = splitValue64(offset);
        const length_halves = splitValue64(len);

        return syscall6(
            .fadvise64_64,
            @bitCast(usize, @as(isize, fd)),
            advice,
            offset_halves[0],
            offset_halves[1],
            length_halves[0],
            length_halves[1],
        );
    } else if (@hasField(SYS, "fadvise64_64") and usize_bits != 64) {
        // The extra usize check is needed to avoid SPARC64 because it provides both
        // fadvise64 and fadvise64_64 but the latter behaves differently than other platforms.

        const offset_halves = splitValue64(offset);
        const length_halves = splitValue64(len);

        return syscall6(
            .fadvise64_64,
            @bitCast(usize, @as(isize, fd)),
            offset_halves[0],
            offset_halves[1],
            length_halves[0],
            length_halves[1],
            advice,
        );
    } else {
        return syscall4(
            .fadvise64,
            @bitCast(usize, @as(isize, fd)),
            @bitCast(usize, offset),
            @bitCast(usize, len),
            advice,
        );
    }
}

test {
    if (std.Target.current.os.tag == .linux) {
        _ = @import("linux/test.zig");
    }
}
