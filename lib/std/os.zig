// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.
// This file contains thin wrappers around OS-specific APIs, with these
// specific goals in mind:
// * Convert "errno"-style error codes into Zig errors.
// * When null-terminated byte buffers are required, provide APIs which accept
//   slices as well as APIs which accept null-terminated byte buffers. Same goes
//   for UTF-16LE encoding.
// * Where operating systems share APIs, e.g. POSIX, these thin wrappers provide
//   cross platform abstracting.
// * When there exists a corresponding libc function and linking libc, the libc
//   implementation is used. Exceptions are made for known buggy areas of libc.
//   On Linux libc can be side-stepped by using `std.os.linux` directly.
// * For Windows, this file represents the API that libc would provide for
//   Windows. For thin wrappers around Windows-specific APIs, see `std.os.windows`.
// Note: The Zig standard library does not support POSIX thread cancellation, and
// in general EINTR is handled by trying again.

const root = @import("root");
const std = @import("std.zig");
const builtin = std.builtin;
const assert = std.debug.assert;
const math = std.math;
const mem = std.mem;
const elf = std.elf;
const dl = @import("dynamic_library.zig");
const MAX_PATH_BYTES = std.fs.MAX_PATH_BYTES;

pub const darwin = @import("os/darwin.zig");
pub const dragonfly = @import("os/dragonfly.zig");
pub const freebsd = @import("os/freebsd.zig");
pub const haiku = @import("os/haiku.zig");
pub const netbsd = @import("os/netbsd.zig");
pub const openbsd = @import("os/openbsd.zig");
pub const linux = @import("os/linux.zig");
pub const uefi = @import("os/uefi.zig");
pub const wasi = @import("os/wasi.zig");
pub const windows = @import("os/windows.zig");

comptime {
    assert(@import("std") == std); // std lib tests require --zig-lib-dir
}

test {
    _ = darwin;
    _ = freebsd;
    _ = linux;
    _ = netbsd;
    _ = openbsd;
    _ = uefi;
    _ = wasi;
    _ = windows;
    _ = haiku;

    _ = @import("os/test.zig");
}

/// Applications can override the `system` API layer in their root source file.
/// Otherwise, when linking libc, this is the C API.
/// When not linking libc, it is the OS-specific system interface.
pub const system = if (@hasDecl(root, "os") and root.os != @This())
    root.os.system
else if (builtin.link_libc)
    std.c
else switch (builtin.os.tag) {
    .macos, .ios, .watchos, .tvos => darwin,
    .freebsd => freebsd,
    .haiku => haiku,
    .linux => linux,
    .netbsd => netbsd,
    .openbsd => openbsd,
    .dragonfly => dragonfly,
    .wasi => wasi,
    .windows => windows,
    else => struct {},
};

pub usingnamespace @import("os/bits.zig");

pub const socket_t = if (builtin.os.tag == .windows) windows.ws2_32.SOCKET else fd_t;

/// See also `getenv`. Populated by startup code before main().
/// TODO this is a footgun because the value will be undefined when using `zig build-lib`.
/// https://github.com/ziglang/zig/issues/4524
pub var environ: [][*:0]u8 = undefined;

/// Populated by startup code before main().
/// Not available on Windows. See `std.process.args`
/// for obtaining the process arguments.
pub var argv: [][*:0]u8 = undefined;

/// To obtain errno, call this function with the return value of the
/// system function call. For some systems this will obtain the value directly
/// from the return code; for others it will use a thread-local errno variable.
/// Therefore, this function only returns a well-defined value when it is called
/// directly after the system function call which one wants to learn the errno
/// value of.
pub const errno = system.getErrno;

/// Closes the file descriptor.
/// This function is not capable of returning any indication of failure. An
/// application which wants to ensure writes have succeeded before closing
/// must call `fsync` before `close`.
/// Note: The Zig standard library does not support POSIX thread cancellation.
pub fn close(fd: fd_t) void {
    if (builtin.os.tag == .windows) {
        return windows.CloseHandle(fd);
    }
    if (builtin.os.tag == .wasi) {
        _ = wasi.fd_close(fd);
        return;
    }
    if (comptime std.Target.current.isDarwin()) {
        // This avoids the EINTR problem.
        switch (darwin.getErrno(darwin.@"close$NOCANCEL"(fd))) {
            EBADF => unreachable, // Always a race condition.
            else => return,
        }
    }
    switch (errno(system.close(fd))) {
        EBADF => unreachable, // Always a race condition.
        EINTR => return, // This is still a success. See https://github.com/ziglang/zig/issues/2425
        else => return,
    }
}

pub const GetRandomError = OpenError;

/// Obtain a series of random bytes. These bytes can be used to seed user-space
/// random number generators or for cryptographic purposes.
/// When linking against libc, this calls the
/// appropriate OS-specific library call. Otherwise it uses the zig standard
/// library implementation.
pub fn getrandom(buffer: []u8) GetRandomError!void {
    if (builtin.os.tag == .windows) {
        return windows.RtlGenRandom(buffer);
    }
    if (builtin.os.tag == .linux or builtin.os.tag == .freebsd) {
        var buf = buffer;
        const use_c = builtin.os.tag != .linux or
            std.c.versionCheck(builtin.Version{ .major = 2, .minor = 25, .patch = 0 }).ok;

        while (buf.len != 0) {
            const res = if (use_c) blk: {
                const rc = std.c.getrandom(buf.ptr, buf.len, 0);
                break :blk .{
                    .num_read = @bitCast(usize, rc),
                    .err = std.c.getErrno(rc),
                };
            } else blk: {
                const rc = linux.getrandom(buf.ptr, buf.len, 0);
                break :blk .{
                    .num_read = rc,
                    .err = linux.getErrno(rc),
                };
            };

            switch (res.err) {
                0 => buf = buf[res.num_read..],
                EINVAL => unreachable,
                EFAULT => unreachable,
                EINTR => continue,
                ENOSYS => return getRandomBytesDevURandom(buf),
                else => return unexpectedErrno(res.err),
            }
        }
        return;
    }
    switch (builtin.os.tag) {
        .netbsd, .openbsd, .macos, .ios, .tvos, .watchos => {
            system.arc4random_buf(buffer.ptr, buffer.len);
            return;
        },
        .wasi => switch (wasi.random_get(buffer.ptr, buffer.len)) {
            0 => return,
            else => |err| return unexpectedErrno(err),
        },
        else => return getRandomBytesDevURandom(buffer),
    }
}

fn getRandomBytesDevURandom(buf: []u8) !void {
    const fd = try openZ("/dev/urandom", O_RDONLY | O_CLOEXEC, 0);
    defer close(fd);

    const st = try fstat(fd);
    if (!S_ISCHR(st.mode)) {
        return error.NoDevice;
    }

    const file = std.fs.File{
        .handle = fd,
        .capable_io_mode = .blocking,
        .intended_io_mode = .blocking,
    };
    const stream = file.reader();
    stream.readNoEof(buf) catch return error.Unexpected;
}

/// Causes abnormal process termination.
/// If linking against libc, this calls the abort() libc function. Otherwise
/// it raises SIGABRT followed by SIGKILL and finally lo
pub fn abort() noreturn {
    @setCold(true);
    // MSVCRT abort() sometimes opens a popup window which is undesirable, so
    // even when linking libc on Windows we use our own abort implementation.
    // See https://github.com/ziglang/zig/issues/2071 for more details.
    if (builtin.os.tag == .windows) {
        if (builtin.mode == .Debug) {
            @breakpoint();
        }
        windows.kernel32.ExitProcess(3);
    }
    if (!builtin.link_libc and builtin.os.tag == .linux) {
        raise(SIGABRT) catch {};

        // TODO the rest of the implementation of abort() from musl libc here

        raise(SIGKILL) catch {};
        exit(127);
    }
    if (builtin.os.tag == .uefi) {
        exit(0); // TODO choose appropriate exit code
    }
    if (builtin.os.tag == .wasi) {
        @breakpoint();
        exit(1);
    }

    system.abort();
}

pub const RaiseError = UnexpectedError;

pub fn raise(sig: u8) RaiseError!void {
    if (builtin.link_libc) {
        switch (errno(system.raise(sig))) {
            0 => return,
            else => |err| return unexpectedErrno(err),
        }
    }

    if (builtin.os.tag == .linux) {
        var set: linux.sigset_t = undefined;
        // block application signals
        _ = linux.sigprocmask(SIG_BLOCK, &linux.app_mask, &set);

        const tid = linux.gettid();
        const rc = linux.tkill(tid, sig);

        // restore signal mask
        _ = linux.sigprocmask(SIG_SETMASK, &set, null);

        switch (errno(rc)) {
            0 => return,
            else => |err| return unexpectedErrno(err),
        }
    }

    @compileError("std.os.raise unimplemented for this target");
}

pub const KillError = error{PermissionDenied} || UnexpectedError;

pub fn kill(pid: pid_t, sig: u8) KillError!void {
    switch (errno(system.kill(pid, sig))) {
        0 => return,
        EINVAL => unreachable, // invalid signal
        EPERM => return error.PermissionDenied,
        ESRCH => unreachable, // always a race condition
        else => |err| return unexpectedErrno(err),
    }
}

/// Exits the program cleanly with the specified status code.
pub fn exit(status: u8) noreturn {
    if (builtin.link_libc) {
        system.exit(status);
    }
    if (builtin.os.tag == .windows) {
        windows.kernel32.ExitProcess(status);
    }
    if (builtin.os.tag == .wasi) {
        wasi.proc_exit(status);
    }
    if (builtin.os.tag == .linux and !builtin.single_threaded) {
        linux.exit_group(status);
    }
    if (builtin.os.tag == .uefi) {
        // exit() is only avaliable if exitBootServices() has not been called yet.
        // This call to exit should not fail, so we don't care about its return value.
        if (uefi.system_table.boot_services) |bs| {
            _ = bs.exit(uefi.handle, @intToEnum(uefi.Status, status), 0, null);
        }
        // If we can't exit, reboot the system instead.
        uefi.system_table.runtime_services.resetSystem(uefi.tables.ResetType.ResetCold, @intToEnum(uefi.Status, status), 0, null);
    }
    system.exit(status);
}

pub const ReadError = error{
    InputOutput,
    SystemResources,
    IsDir,
    OperationAborted,
    BrokenPipe,
    ConnectionResetByPeer,
    ConnectionTimedOut,
    NotOpenForReading,

    /// This error occurs when no global event loop is configured,
    /// and reading from the file descriptor would block.
    WouldBlock,

    /// In WASI, this error occurs when the file descriptor does
    /// not hold the required rights to read from it.
    AccessDenied,
} || UnexpectedError;

/// Returns the number of bytes that were read, which can be less than
/// buf.len. If 0 bytes were read, that means EOF.
/// If `fd` is opened in non blocking mode, the function will return error.WouldBlock
/// when EAGAIN is received.
///
/// Linux has a limit on how many bytes may be transferred in one `read` call, which is `0x7ffff000`
/// on both 64-bit and 32-bit systems. This is due to using a signed C int as the return value, as
/// well as stuffing the errno codes into the last `4096` values. This is noted on the `read` man page.
/// The limit on Darwin is `0x7fffffff`, trying to read more than that returns EINVAL.
/// The corresponding POSIX limit is `math.maxInt(isize)`.
pub fn read(fd: fd_t, buf: []u8) ReadError!usize {
    if (builtin.os.tag == .windows) {
        return windows.ReadFile(fd, buf, null, std.io.default_mode);
    }
    if (builtin.os.tag == .wasi and !builtin.link_libc) {
        const iovs = [1]iovec{iovec{
            .iov_base = buf.ptr,
            .iov_len = buf.len,
        }};

        var nread: usize = undefined;
        switch (wasi.fd_read(fd, &iovs, iovs.len, &nread)) {
            wasi.ESUCCESS => return nread,
            wasi.EINTR => unreachable,
            wasi.EINVAL => unreachable,
            wasi.EFAULT => unreachable,
            wasi.EAGAIN => unreachable,
            wasi.EBADF => return error.NotOpenForReading, // Can be a race condition.
            wasi.EIO => return error.InputOutput,
            wasi.EISDIR => return error.IsDir,
            wasi.ENOBUFS => return error.SystemResources,
            wasi.ENOMEM => return error.SystemResources,
            wasi.ECONNRESET => return error.ConnectionResetByPeer,
            wasi.ETIMEDOUT => return error.ConnectionTimedOut,
            wasi.ENOTCAPABLE => return error.AccessDenied,
            else => |err| return unexpectedErrno(err),
        }
    }

    // Prevents EINVAL.
    const max_count = switch (std.Target.current.os.tag) {
        .linux => 0x7ffff000,
        .macos, .ios, .watchos, .tvos => math.maxInt(i32),
        else => math.maxInt(isize),
    };
    const adjusted_len = math.min(max_count, buf.len);

    while (true) {
        const rc = system.read(fd, buf.ptr, adjusted_len);
        switch (errno(rc)) {
            0 => return @intCast(usize, rc),
            EINTR => continue,
            EINVAL => unreachable,
            EFAULT => unreachable,
            EAGAIN => return error.WouldBlock,
            EBADF => return error.NotOpenForReading, // Can be a race condition.
            EIO => return error.InputOutput,
            EISDIR => return error.IsDir,
            ENOBUFS => return error.SystemResources,
            ENOMEM => return error.SystemResources,
            ECONNRESET => return error.ConnectionResetByPeer,
            ETIMEDOUT => return error.ConnectionTimedOut,
            else => |err| return unexpectedErrno(err),
        }
    }
    return index;
}

/// Number of bytes read is returned. Upon reading end-of-file, zero is returned.
///
/// For POSIX systems, if `fd` is opened in non blocking mode, the function will
/// return error.WouldBlock when EAGAIN is received.
/// On Windows, if the application has a global event loop enabled, I/O Completion Ports are
/// used to perform the I/O. `error.WouldBlock` is not possible on Windows.
///
/// This operation is non-atomic on the following systems:
/// * Windows
/// On these systems, the read races with concurrent writes to the same file descriptor.
pub fn readv(fd: fd_t, iov: []const iovec) ReadError!usize {
    if (std.Target.current.os.tag == .windows) {
        // TODO improve this to use ReadFileScatter
        if (iov.len == 0) return @as(usize, 0);
        const first = iov[0];
        return read(fd, first.iov_base[0..first.iov_len]);
    }
    if (builtin.os.tag == .wasi) {
        var nread: usize = undefined;
        switch (wasi.fd_read(fd, iov.ptr, iov.len, &nread)) {
            wasi.ESUCCESS => return nread,
            wasi.EINTR => unreachable,
            wasi.EINVAL => unreachable,
            wasi.EFAULT => unreachable,
            wasi.EAGAIN => unreachable, // currently not support in WASI
            wasi.EBADF => return error.NotOpenForReading, // can be a race condition
            wasi.EIO => return error.InputOutput,
            wasi.EISDIR => return error.IsDir,
            wasi.ENOBUFS => return error.SystemResources,
            wasi.ENOMEM => return error.SystemResources,
            wasi.ENOTCAPABLE => return error.AccessDenied,
            else => |err| return unexpectedErrno(err),
        }
    }
    const iov_count = math.cast(u31, iov.len) catch math.maxInt(u31);
    while (true) {
        // TODO handle the case when iov_len is too large and get rid of this @intCast
        const rc = system.readv(fd, iov.ptr, iov_count);
        switch (errno(rc)) {
            0 => return @intCast(usize, rc),
            EINTR => continue,
            EINVAL => unreachable,
            EFAULT => unreachable,
            EAGAIN => return error.WouldBlock,
            EBADF => return error.NotOpenForReading, // can be a race condition
            EIO => return error.InputOutput,
            EISDIR => return error.IsDir,
            ENOBUFS => return error.SystemResources,
            ENOMEM => return error.SystemResources,
            else => |err| return unexpectedErrno(err),
        }
    }
}

pub const PReadError = ReadError || error{Unseekable};

/// Number of bytes read is returned. Upon reading end-of-file, zero is returned.
///
/// Retries when interrupted by a signal.
///
/// For POSIX systems, if `fd` is opened in non blocking mode, the function will
/// return error.WouldBlock when EAGAIN is received.
/// On Windows, if the application has a global event loop enabled, I/O Completion Ports are
/// used to perform the I/O. `error.WouldBlock` is not possible on Windows.
///
/// Linux has a limit on how many bytes may be transferred in one `pread` call, which is `0x7ffff000`
/// on both 64-bit and 32-bit systems. This is due to using a signed C int as the return value, as
/// well as stuffing the errno codes into the last `4096` values. This is noted on the `read` man page.
/// The limit on Darwin is `0x7fffffff`, trying to read more than that returns EINVAL.
/// The corresponding POSIX limit is `math.maxInt(isize)`.
pub fn pread(fd: fd_t, buf: []u8, offset: u64) PReadError!usize {
    if (builtin.os.tag == .windows) {
        return windows.ReadFile(fd, buf, offset, std.io.default_mode);
    }
    if (builtin.os.tag == .wasi) {
        const iovs = [1]iovec{iovec{
            .iov_base = buf.ptr,
            .iov_len = buf.len,
        }};

        var nread: usize = undefined;
        switch (wasi.fd_pread(fd, &iovs, iovs.len, offset, &nread)) {
            wasi.ESUCCESS => return nread,
            wasi.EINTR => unreachable,
            wasi.EINVAL => unreachable,
            wasi.EFAULT => unreachable,
            wasi.EAGAIN => unreachable,
            wasi.EBADF => return error.NotOpenForReading, // Can be a race condition.
            wasi.EIO => return error.InputOutput,
            wasi.EISDIR => return error.IsDir,
            wasi.ENOBUFS => return error.SystemResources,
            wasi.ENOMEM => return error.SystemResources,
            wasi.ECONNRESET => return error.ConnectionResetByPeer,
            wasi.ENXIO => return error.Unseekable,
            wasi.ESPIPE => return error.Unseekable,
            wasi.EOVERFLOW => return error.Unseekable,
            wasi.ENOTCAPABLE => return error.AccessDenied,
            else => |err| return unexpectedErrno(err),
        }
    }

    // Prevent EINVAL.
    const max_count = switch (std.Target.current.os.tag) {
        .linux => 0x7ffff000,
        .macos, .ios, .watchos, .tvos => math.maxInt(i32),
        else => math.maxInt(isize),
    };
    const adjusted_len = math.min(max_count, buf.len);

    const pread_sym = if (builtin.os.tag == .linux and builtin.link_libc)
        system.pread64
    else
        system.pread;

    const ioffset = @bitCast(i64, offset); // the OS treats this as unsigned
    while (true) {
        const rc = pread_sym(fd, buf.ptr, adjusted_len, ioffset);
        switch (errno(rc)) {
            0 => return @intCast(usize, rc),
            EINTR => continue,
            EINVAL => unreachable,
            EFAULT => unreachable,
            EAGAIN => return error.WouldBlock,
            EBADF => return error.NotOpenForReading, // Can be a race condition.
            EIO => return error.InputOutput,
            EISDIR => return error.IsDir,
            ENOBUFS => return error.SystemResources,
            ENOMEM => return error.SystemResources,
            ECONNRESET => return error.ConnectionResetByPeer,
            ENXIO => return error.Unseekable,
            ESPIPE => return error.Unseekable,
            EOVERFLOW => return error.Unseekable,
            else => |err| return unexpectedErrno(err),
        }
    }
}

pub const TruncateError = error{
    FileTooBig,
    InputOutput,
    FileBusy,

    /// In WASI, this error occurs when the file descriptor does
    /// not hold the required rights to call `ftruncate` on it.
    AccessDenied,
} || UnexpectedError;

pub fn ftruncate(fd: fd_t, length: u64) TruncateError!void {
    if (std.Target.current.os.tag == .windows) {
        var io_status_block: windows.IO_STATUS_BLOCK = undefined;
        var eof_info = windows.FILE_END_OF_FILE_INFORMATION{
            .EndOfFile = @bitCast(windows.LARGE_INTEGER, length),
        };

        const rc = windows.ntdll.NtSetInformationFile(
            fd,
            &io_status_block,
            &eof_info,
            @sizeOf(windows.FILE_END_OF_FILE_INFORMATION),
            .FileEndOfFileInformation,
        );

        switch (rc) {
            .SUCCESS => return,
            .INVALID_HANDLE => unreachable, // Handle not open for writing
            .ACCESS_DENIED => return error.AccessDenied,
            else => return windows.unexpectedStatus(rc),
        }
    }
    if (std.Target.current.os.tag == .wasi) {
        switch (wasi.fd_filestat_set_size(fd, length)) {
            wasi.ESUCCESS => return,
            wasi.EINTR => unreachable,
            wasi.EFBIG => return error.FileTooBig,
            wasi.EIO => return error.InputOutput,
            wasi.EPERM => return error.AccessDenied,
            wasi.ETXTBSY => return error.FileBusy,
            wasi.EBADF => unreachable, // Handle not open for writing
            wasi.EINVAL => unreachable, // Handle not open for writing
            wasi.ENOTCAPABLE => return error.AccessDenied,
            else => |err| return unexpectedErrno(err),
        }
    }

    while (true) {
        const ftruncate_sym = if (builtin.os.tag == .linux and builtin.link_libc)
            system.ftruncate64
        else
            system.ftruncate;

        const ilen = @bitCast(i64, length); // the OS treats this as unsigned
        switch (errno(ftruncate_sym(fd, ilen))) {
            0 => return,
            EINTR => continue,
            EFBIG => return error.FileTooBig,
            EIO => return error.InputOutput,
            EPERM => return error.AccessDenied,
            ETXTBSY => return error.FileBusy,
            EBADF => unreachable, // Handle not open for writing
            EINVAL => unreachable, // Handle not open for writing
            else => |err| return unexpectedErrno(err),
        }
    }
}

/// Number of bytes read is returned. Upon reading end-of-file, zero is returned.
///
/// Retries when interrupted by a signal.
///
/// For POSIX systems, if `fd` is opened in non blocking mode, the function will
/// return error.WouldBlock when EAGAIN is received.
/// On Windows, if the application has a global event loop enabled, I/O Completion Ports are
/// used to perform the I/O. `error.WouldBlock` is not possible on Windows.
///
/// This operation is non-atomic on the following systems:
/// * Darwin
/// * Windows
/// On these systems, the read races with concurrent writes to the same file descriptor.
pub fn preadv(fd: fd_t, iov: []const iovec, offset: u64) PReadError!usize {
    const have_pread_but_not_preadv = switch (std.Target.current.os.tag) {
        .windows, .macos, .ios, .watchos, .tvos, .haiku => true,
        else => false,
    };
    if (have_pread_but_not_preadv) {
        // We could loop here; but proper usage of `preadv` must handle partial reads anyway.
        // So we simply read into the first vector only.
        if (iov.len == 0) return @as(usize, 0);
        const first = iov[0];
        return pread(fd, first.iov_base[0..first.iov_len], offset);
    }
    if (builtin.os.tag == .wasi) {
        var nread: usize = undefined;
        switch (wasi.fd_pread(fd, iov.ptr, iov.len, offset, &nread)) {
            wasi.ESUCCESS => return nread,
            wasi.EINTR => unreachable,
            wasi.EINVAL => unreachable,
            wasi.EFAULT => unreachable,
            wasi.EAGAIN => unreachable,
            wasi.EBADF => return error.NotOpenForReading, // can be a race condition
            wasi.EIO => return error.InputOutput,
            wasi.EISDIR => return error.IsDir,
            wasi.ENOBUFS => return error.SystemResources,
            wasi.ENOMEM => return error.SystemResources,
            wasi.ENXIO => return error.Unseekable,
            wasi.ESPIPE => return error.Unseekable,
            wasi.EOVERFLOW => return error.Unseekable,
            wasi.ENOTCAPABLE => return error.AccessDenied,
            else => |err| return unexpectedErrno(err),
        }
    }

    const iov_count = math.cast(u31, iov.len) catch math.maxInt(u31);

    const preadv_sym = if (builtin.os.tag == .linux and builtin.link_libc)
        system.preadv64
    else
        system.preadv;

    const ioffset = @bitCast(i64, offset); // the OS treats this as unsigned
    while (true) {
        const rc = preadv_sym(fd, iov.ptr, iov_count, ioffset);
        switch (errno(rc)) {
            0 => return @bitCast(usize, rc),
            EINTR => continue,
            EINVAL => unreachable,
            EFAULT => unreachable,
            EAGAIN => return error.WouldBlock,
            EBADF => return error.NotOpenForReading, // can be a race condition
            EIO => return error.InputOutput,
            EISDIR => return error.IsDir,
            ENOBUFS => return error.SystemResources,
            ENOMEM => return error.SystemResources,
            ENXIO => return error.Unseekable,
            ESPIPE => return error.Unseekable,
            EOVERFLOW => return error.Unseekable,
            else => |err| return unexpectedErrno(err),
        }
    }
}

pub const WriteError = error{
    DiskQuota,
    FileTooBig,
    InputOutput,
    NoSpaceLeft,

    /// In WASI, this error may occur when the file descriptor does
    /// not hold the required rights to write to it.
    AccessDenied,
    BrokenPipe,
    SystemResources,
    OperationAborted,
    NotOpenForWriting,

    /// This error occurs when no global event loop is configured,
    /// and reading from the file descriptor would block.
    WouldBlock,

    /// Connection reset by peer.
    ConnectionResetByPeer,
} || UnexpectedError;

/// Write to a file descriptor.
/// Retries when interrupted by a signal.
/// Returns the number of bytes written. If nonzero bytes were supplied, this will be nonzero.
///
/// Note that a successful write() may transfer fewer than count bytes.  Such partial  writes  can
/// occur  for  various reasons; for example, because there was insufficient space on the disk
/// device to write all of the requested bytes, or because a blocked write() to a socket,  pipe,  or
/// similar  was  interrupted by a signal handler after it had transferred some, but before it had
/// transferred all of the requested bytes.  In the event of a partial write, the caller can  make
/// another  write() call to transfer the remaining bytes.  The subsequent call will either
/// transfer further bytes or may result in an error (e.g., if the disk is now full).
///
/// For POSIX systems, if `fd` is opened in non blocking mode, the function will
/// return error.WouldBlock when EAGAIN is received.
/// On Windows, if the application has a global event loop enabled, I/O Completion Ports are
/// used to perform the I/O. `error.WouldBlock` is not possible on Windows.
///
/// Linux has a limit on how many bytes may be transferred in one `write` call, which is `0x7ffff000`
/// on both 64-bit and 32-bit systems. This is due to using a signed C int as the return value, as
/// well as stuffing the errno codes into the last `4096` values. This is noted on the `write` man page.
/// The limit on Darwin is `0x7fffffff`, trying to read more than that returns EINVAL.
/// The corresponding POSIX limit is `math.maxInt(isize)`.
pub fn write(fd: fd_t, bytes: []const u8) WriteError!usize {
    if (builtin.os.tag == .windows) {
        return windows.WriteFile(fd, bytes, null, std.io.default_mode);
    }

    if (builtin.os.tag == .wasi and !builtin.link_libc) {
        const ciovs = [_]iovec_const{iovec_const{
            .iov_base = bytes.ptr,
            .iov_len = bytes.len,
        }};
        var nwritten: usize = undefined;
        switch (wasi.fd_write(fd, &ciovs, ciovs.len, &nwritten)) {
            wasi.ESUCCESS => return nwritten,
            wasi.EINTR => unreachable,
            wasi.EINVAL => unreachable,
            wasi.EFAULT => unreachable,
            wasi.EAGAIN => unreachable,
            wasi.EBADF => return error.NotOpenForWriting, // can be a race condition.
            wasi.EDESTADDRREQ => unreachable, // `connect` was never called.
            wasi.EDQUOT => return error.DiskQuota,
            wasi.EFBIG => return error.FileTooBig,
            wasi.EIO => return error.InputOutput,
            wasi.ENOSPC => return error.NoSpaceLeft,
            wasi.EPERM => return error.AccessDenied,
            wasi.EPIPE => return error.BrokenPipe,
            wasi.ENOTCAPABLE => return error.AccessDenied,
            else => |err| return unexpectedErrno(err),
        }
    }

    const max_count = switch (std.Target.current.os.tag) {
        .linux => 0x7ffff000,
        .macos, .ios, .watchos, .tvos => math.maxInt(i32),
        else => math.maxInt(isize),
    };
    const adjusted_len = math.min(max_count, bytes.len);

    while (true) {
        const rc = system.write(fd, bytes.ptr, adjusted_len);
        switch (errno(rc)) {
            0 => return @intCast(usize, rc),
            EINTR => continue,
            EINVAL => unreachable,
            EFAULT => unreachable,
            EAGAIN => return error.WouldBlock,
            EBADF => return error.NotOpenForWriting, // can be a race condition.
            EDESTADDRREQ => unreachable, // `connect` was never called.
            EDQUOT => return error.DiskQuota,
            EFBIG => return error.FileTooBig,
            EIO => return error.InputOutput,
            ENOSPC => return error.NoSpaceLeft,
            EPERM => return error.AccessDenied,
            EPIPE => return error.BrokenPipe,
            ECONNRESET => return error.ConnectionResetByPeer,
            else => |err| return unexpectedErrno(err),
        }
    }
}

/// Write multiple buffers to a file descriptor.
/// Retries when interrupted by a signal.
/// Returns the number of bytes written. If nonzero bytes were supplied, this will be nonzero.
///
/// Note that a successful write() may transfer fewer bytes than supplied.  Such partial  writes  can
/// occur  for  various reasons; for example, because there was insufficient space on the disk
/// device to write all of the requested bytes, or because a blocked write() to a socket,  pipe,  or
/// similar  was  interrupted by a signal handler after it had transferred some, but before it had
/// transferred all of the requested bytes.  In the event of a partial write, the caller can  make
/// another  write() call to transfer the remaining bytes.  The subsequent call will either
/// transfer further bytes or may result in an error (e.g., if the disk is now full).
///
/// For POSIX systems, if `fd` is opened in non blocking mode, the function will
/// return error.WouldBlock when EAGAIN is received.k`.
/// On Windows, if the application has a global event loop enabled, I/O Completion Ports are
/// used to perform the I/O. `error.WouldBlock` is not possible on Windows.
///
/// If `iov.len` is larger than `IOV_MAX`, a partial write will occur.
pub fn writev(fd: fd_t, iov: []const iovec_const) WriteError!usize {
    if (std.Target.current.os.tag == .windows) {
        // TODO improve this to use WriteFileScatter
        if (iov.len == 0) return @as(usize, 0);
        const first = iov[0];
        return write(fd, first.iov_base[0..first.iov_len]);
    }
    if (builtin.os.tag == .wasi) {
        var nwritten: usize = undefined;
        switch (wasi.fd_write(fd, iov.ptr, iov.len, &nwritten)) {
            wasi.ESUCCESS => return nwritten,
            wasi.EINTR => unreachable,
            wasi.EINVAL => unreachable,
            wasi.EFAULT => unreachable,
            wasi.EAGAIN => unreachable,
            wasi.EBADF => return error.NotOpenForWriting, // can be a race condition.
            wasi.EDESTADDRREQ => unreachable, // `connect` was never called.
            wasi.EDQUOT => return error.DiskQuota,
            wasi.EFBIG => return error.FileTooBig,
            wasi.EIO => return error.InputOutput,
            wasi.ENOSPC => return error.NoSpaceLeft,
            wasi.EPERM => return error.AccessDenied,
            wasi.EPIPE => return error.BrokenPipe,
            wasi.ENOTCAPABLE => return error.AccessDenied,
            else => |err| return unexpectedErrno(err),
        }
    }

    const iov_count = if (iov.len > IOV_MAX) IOV_MAX else @intCast(u31, iov.len);
    while (true) {
        const rc = system.writev(fd, iov.ptr, iov_count);
        switch (errno(rc)) {
            0 => return @intCast(usize, rc),
            EINTR => continue,
            EINVAL => unreachable,
            EFAULT => unreachable,
            EAGAIN => return error.WouldBlock,
            EBADF => return error.NotOpenForWriting, // Can be a race condition.
            EDESTADDRREQ => unreachable, // `connect` was never called.
            EDQUOT => return error.DiskQuota,
            EFBIG => return error.FileTooBig,
            EIO => return error.InputOutput,
            ENOSPC => return error.NoSpaceLeft,
            EPERM => return error.AccessDenied,
            EPIPE => return error.BrokenPipe,
            ECONNRESET => return error.ConnectionResetByPeer,
            else => |err| return unexpectedErrno(err),
        }
    }
}

pub const PWriteError = WriteError || error{Unseekable};

/// Write to a file descriptor, with a position offset.
/// Retries when interrupted by a signal.
/// Returns the number of bytes written. If nonzero bytes were supplied, this will be nonzero.
///
/// Note that a successful write() may transfer fewer bytes than supplied.  Such partial  writes  can
/// occur  for  various reasons; for example, because there was insufficient space on the disk
/// device to write all of the requested bytes, or because a blocked write() to a socket,  pipe,  or
/// similar  was  interrupted by a signal handler after it had transferred some, but before it had
/// transferred all of the requested bytes.  In the event of a partial write, the caller can  make
/// another  write() call to transfer the remaining bytes.  The subsequent call will either
/// transfer further bytes or may result in an error (e.g., if the disk is now full).
///
/// For POSIX systems, if `fd` is opened in non blocking mode, the function will
/// return error.WouldBlock when EAGAIN is received.
/// On Windows, if the application has a global event loop enabled, I/O Completion Ports are
/// used to perform the I/O. `error.WouldBlock` is not possible on Windows.
///
/// Linux has a limit on how many bytes may be transferred in one `pwrite` call, which is `0x7ffff000`
/// on both 64-bit and 32-bit systems. This is due to using a signed C int as the return value, as
/// well as stuffing the errno codes into the last `4096` values. This is noted on the `write` man page.
/// The limit on Darwin is `0x7fffffff`, trying to write more than that returns EINVAL.
/// The corresponding POSIX limit is `math.maxInt(isize)`.
pub fn pwrite(fd: fd_t, bytes: []const u8, offset: u64) PWriteError!usize {
    if (std.Target.current.os.tag == .windows) {
        return windows.WriteFile(fd, bytes, offset, std.io.default_mode);
    }
    if (builtin.os.tag == .wasi) {
        const ciovs = [1]iovec_const{iovec_const{
            .iov_base = bytes.ptr,
            .iov_len = bytes.len,
        }};

        var nwritten: usize = undefined;
        switch (wasi.fd_pwrite(fd, &ciovs, ciovs.len, offset, &nwritten)) {
            wasi.ESUCCESS => return nwritten,
            wasi.EINTR => unreachable,
            wasi.EINVAL => unreachable,
            wasi.EFAULT => unreachable,
            wasi.EAGAIN => unreachable,
            wasi.EBADF => return error.NotOpenForWriting, // can be a race condition.
            wasi.EDESTADDRREQ => unreachable, // `connect` was never called.
            wasi.EDQUOT => return error.DiskQuota,
            wasi.EFBIG => return error.FileTooBig,
            wasi.EIO => return error.InputOutput,
            wasi.ENOSPC => return error.NoSpaceLeft,
            wasi.EPERM => return error.AccessDenied,
            wasi.EPIPE => return error.BrokenPipe,
            wasi.ENXIO => return error.Unseekable,
            wasi.ESPIPE => return error.Unseekable,
            wasi.EOVERFLOW => return error.Unseekable,
            wasi.ENOTCAPABLE => return error.AccessDenied,
            else => |err| return unexpectedErrno(err),
        }
    }

    // Prevent EINVAL.
    const max_count = switch (std.Target.current.os.tag) {
        .linux => 0x7ffff000,
        .macos, .ios, .watchos, .tvos => math.maxInt(i32),
        else => math.maxInt(isize),
    };
    const adjusted_len = math.min(max_count, bytes.len);

    const pwrite_sym = if (builtin.os.tag == .linux and builtin.link_libc)
        system.pwrite64
    else
        system.pwrite;

    const ioffset = @bitCast(i64, offset); // the OS treats this as unsigned
    while (true) {
        const rc = pwrite_sym(fd, bytes.ptr, adjusted_len, ioffset);
        switch (errno(rc)) {
            0 => return @intCast(usize, rc),
            EINTR => continue,
            EINVAL => unreachable,
            EFAULT => unreachable,
            EAGAIN => return error.WouldBlock,
            EBADF => return error.NotOpenForWriting, // Can be a race condition.
            EDESTADDRREQ => unreachable, // `connect` was never called.
            EDQUOT => return error.DiskQuota,
            EFBIG => return error.FileTooBig,
            EIO => return error.InputOutput,
            ENOSPC => return error.NoSpaceLeft,
            EPERM => return error.AccessDenied,
            EPIPE => return error.BrokenPipe,
            ENXIO => return error.Unseekable,
            ESPIPE => return error.Unseekable,
            EOVERFLOW => return error.Unseekable,
            else => |err| return unexpectedErrno(err),
        }
    }
}

/// Write multiple buffers to a file descriptor, with a position offset.
/// Retries when interrupted by a signal.
/// Returns the number of bytes written. If nonzero bytes were supplied, this will be nonzero.
///
/// Note that a successful write() may transfer fewer than count bytes.  Such partial  writes  can
/// occur  for  various reasons; for example, because there was insufficient space on the disk
/// device to write all of the requested bytes, or because a blocked write() to a socket,  pipe,  or
/// similar  was  interrupted by a signal handler after it had transferred some, but before it had
/// transferred all of the requested bytes.  In the event of a partial write, the caller can  make
/// another  write() call to transfer the remaining bytes.  The subsequent call will either
/// transfer further bytes or may result in an error (e.g., if the disk is now full).
///
/// If `fd` is opened in non blocking mode, the function will
/// return error.WouldBlock when EAGAIN is received.
///
/// The following systems do not have this syscall, and will return partial writes if more than one
/// vector is provided:
/// * Darwin
/// * Windows
///
/// If `iov.len` is larger than `IOV_MAX`, a partial write will occur.
pub fn pwritev(fd: fd_t, iov: []const iovec_const, offset: u64) PWriteError!usize {
    const have_pwrite_but_not_pwritev = switch (std.Target.current.os.tag) {
        .windows, .macos, .ios, .watchos, .tvos, .haiku => true,
        else => false,
    };

    if (have_pwrite_but_not_pwritev) {
        // We could loop here; but proper usage of `pwritev` must handle partial writes anyway.
        // So we simply write the first vector only.
        if (iov.len == 0) return @as(usize, 0);
        const first = iov[0];
        return pwrite(fd, first.iov_base[0..first.iov_len], offset);
    }
    if (builtin.os.tag == .wasi) {
        var nwritten: usize = undefined;
        switch (wasi.fd_pwrite(fd, iov.ptr, iov.len, offset, &nwritten)) {
            wasi.ESUCCESS => return nwritten,
            wasi.EINTR => unreachable,
            wasi.EINVAL => unreachable,
            wasi.EFAULT => unreachable,
            wasi.EAGAIN => unreachable,
            wasi.EBADF => return error.NotOpenForWriting, // Can be a race condition.
            wasi.EDESTADDRREQ => unreachable, // `connect` was never called.
            wasi.EDQUOT => return error.DiskQuota,
            wasi.EFBIG => return error.FileTooBig,
            wasi.EIO => return error.InputOutput,
            wasi.ENOSPC => return error.NoSpaceLeft,
            wasi.EPERM => return error.AccessDenied,
            wasi.EPIPE => return error.BrokenPipe,
            wasi.ENXIO => return error.Unseekable,
            wasi.ESPIPE => return error.Unseekable,
            wasi.EOVERFLOW => return error.Unseekable,
            wasi.ENOTCAPABLE => return error.AccessDenied,
            else => |err| return unexpectedErrno(err),
        }
    }

    const pwritev_sym = if (builtin.os.tag == .linux and builtin.link_libc)
        system.pwritev64
    else
        system.pwritev;

    const iov_count = if (iov.len > IOV_MAX) IOV_MAX else @intCast(u31, iov.len);
    const ioffset = @bitCast(i64, offset); // the OS treats this as unsigned
    while (true) {
        const rc = pwritev_sym(fd, iov.ptr, iov_count, ioffset);
        switch (errno(rc)) {
            0 => return @intCast(usize, rc),
            EINTR => continue,
            EINVAL => unreachable,
            EFAULT => unreachable,
            EAGAIN => return error.WouldBlock,
            EBADF => return error.NotOpenForWriting, // Can be a race condition.
            EDESTADDRREQ => unreachable, // `connect` was never called.
            EDQUOT => return error.DiskQuota,
            EFBIG => return error.FileTooBig,
            EIO => return error.InputOutput,
            ENOSPC => return error.NoSpaceLeft,
            EPERM => return error.AccessDenied,
            EPIPE => return error.BrokenPipe,
            ENXIO => return error.Unseekable,
            ESPIPE => return error.Unseekable,
            EOVERFLOW => return error.Unseekable,
            else => |err| return unexpectedErrno(err),
        }
    }
}

pub const OpenError = error{
    /// In WASI, this error may occur when the file descriptor does
    /// not hold the required rights to open a new resource relative to it.
    AccessDenied,
    SymLinkLoop,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    NoDevice,
    FileNotFound,

    /// The path exceeded `MAX_PATH_BYTES` bytes.
    NameTooLong,

    /// Insufficient kernel memory was available, or
    /// the named file is a FIFO and per-user hard limit on
    /// memory allocation for pipes has been reached.
    SystemResources,

    /// The file is too large to be opened. This error is unreachable
    /// for 64-bit targets, as well as when opening directories.
    FileTooBig,

    /// The path refers to directory but the `O_DIRECTORY` flag was not provided.
    IsDir,

    /// A new path cannot be created because the device has no room for the new file.
    /// This error is only reachable when the `O_CREAT` flag is provided.
    NoSpaceLeft,

    /// A component used as a directory in the path was not, in fact, a directory, or
    /// `O_DIRECTORY` was specified and the path was not a directory.
    NotDir,

    /// The path already exists and the `O_CREAT` and `O_EXCL` flags were provided.
    PathAlreadyExists,
    DeviceBusy,

    /// The underlying filesystem does not support file locks
    FileLocksNotSupported,

    BadPathName,
    InvalidUtf8,

    WouldBlock,
} || UnexpectedError;

/// Open and possibly create a file. Keeps trying if it gets interrupted.
/// See also `openZ`.
pub fn open(file_path: []const u8, flags: u32, perm: mode_t) OpenError!fd_t {
    if (std.Target.current.os.tag == .windows) {
        const file_path_w = try windows.sliceToPrefixedFileW(file_path);
        return openW(file_path_w.span(), flags, perm);
    }
    const file_path_c = try toPosixPath(file_path);
    return openZ(&file_path_c, flags, perm);
}

pub const openC = @compileError("deprecated: renamed to openZ");

/// Open and possibly create a file. Keeps trying if it gets interrupted.
/// See also `open`.
pub fn openZ(file_path: [*:0]const u8, flags: u32, perm: mode_t) OpenError!fd_t {
    if (std.Target.current.os.tag == .windows) {
        const file_path_w = try windows.cStrToPrefixedFileW(file_path);
        return openW(file_path_w.span(), flags, perm);
    }

    const open_sym = if (builtin.os.tag == .linux and builtin.link_libc)
        system.open64
    else
        system.open;

    while (true) {
        const rc = open_sym(file_path, flags, perm);
        switch (errno(rc)) {
            0 => return @intCast(fd_t, rc),
            EINTR => continue,

            EFAULT => unreachable,
            EINVAL => unreachable,
            EACCES => return error.AccessDenied,
            EFBIG => return error.FileTooBig,
            EOVERFLOW => return error.FileTooBig,
            EISDIR => return error.IsDir,
            ELOOP => return error.SymLinkLoop,
            EMFILE => return error.ProcessFdQuotaExceeded,
            ENAMETOOLONG => return error.NameTooLong,
            ENFILE => return error.SystemFdQuotaExceeded,
            ENODEV => return error.NoDevice,
            ENOENT => return error.FileNotFound,
            ENOMEM => return error.SystemResources,
            ENOSPC => return error.NoSpaceLeft,
            ENOTDIR => return error.NotDir,
            EPERM => return error.AccessDenied,
            EEXIST => return error.PathAlreadyExists,
            EBUSY => return error.DeviceBusy,
            else => |err| return unexpectedErrno(err),
        }
    }
}

fn openOptionsFromFlags(flags: u32) windows.OpenFileOptions {
    const w = windows;

    var access_mask: w.ULONG = w.READ_CONTROL | w.FILE_WRITE_ATTRIBUTES | w.SYNCHRONIZE;
    if (flags & O_RDWR != 0) {
        access_mask |= w.GENERIC_READ | w.GENERIC_WRITE;
    } else if (flags & O_WRONLY != 0) {
        access_mask |= w.GENERIC_WRITE;
    } else {
        access_mask |= w.GENERIC_READ | w.GENERIC_WRITE;
    }

    const open_dir: bool = flags & O_DIRECTORY != 0;
    const follow_symlinks: bool = flags & O_NOFOLLOW == 0;

    const creation: w.ULONG = blk: {
        if (flags & O_CREAT != 0) {
            if (flags & O_EXCL != 0) {
                break :blk w.FILE_CREATE;
            }
        }
        break :blk w.FILE_OPEN;
    };

    return .{
        .access_mask = access_mask,
        .io_mode = .blocking,
        .creation = creation,
        .open_dir = open_dir,
        .follow_symlinks = follow_symlinks,
    };
}

/// Windows-only. The path parameter is
/// [WTF-16](https://simonsapin.github.io/wtf-8/#potentially-ill-formed-utf-16) encoded.
/// Translates the POSIX open API call to a Windows API call.
/// TODO currently, this function does not handle all flag combinations
/// or makes use of perm argument.
pub fn openW(file_path_w: []const u16, flags: u32, perm: mode_t) OpenError!fd_t {
    _ = perm;
    var options = openOptionsFromFlags(flags);
    options.dir = std.fs.cwd().fd;
    return windows.OpenFile(file_path_w, options) catch |err| switch (err) {
        error.WouldBlock => unreachable,
        error.PipeBusy => unreachable,
        else => |e| return e,
    };
}

/// Open and possibly create a file. Keeps trying if it gets interrupted.
/// `file_path` is relative to the open directory handle `dir_fd`.
/// See also `openatZ`.
pub fn openat(dir_fd: fd_t, file_path: []const u8, flags: u32, mode: mode_t) OpenError!fd_t {
    if (builtin.os.tag == .wasi) {
        @compileError("use openatWasi instead");
    }
    if (builtin.os.tag == .windows) {
        const file_path_w = try windows.sliceToPrefixedFileW(file_path);
        return openatW(dir_fd, file_path_w.span(), flags, mode);
    }
    const file_path_c = try toPosixPath(file_path);
    return openatZ(dir_fd, &file_path_c, flags, mode);
}

/// Open and possibly create a file in WASI.
pub fn openatWasi(dir_fd: fd_t, file_path: []const u8, lookup_flags: lookupflags_t, oflags: oflags_t, fdflags: fdflags_t, base: rights_t, inheriting: rights_t) OpenError!fd_t {
    while (true) {
        var fd: fd_t = undefined;
        switch (wasi.path_open(dir_fd, lookup_flags, file_path.ptr, file_path.len, oflags, base, inheriting, fdflags, &fd)) {
            wasi.ESUCCESS => return fd,
            wasi.EINTR => continue,

            wasi.EFAULT => unreachable,
            wasi.EINVAL => unreachable,
            wasi.EACCES => return error.AccessDenied,
            wasi.EFBIG => return error.FileTooBig,
            wasi.EOVERFLOW => return error.FileTooBig,
            wasi.EISDIR => return error.IsDir,
            wasi.ELOOP => return error.SymLinkLoop,
            wasi.EMFILE => return error.ProcessFdQuotaExceeded,
            wasi.ENAMETOOLONG => return error.NameTooLong,
            wasi.ENFILE => return error.SystemFdQuotaExceeded,
            wasi.ENODEV => return error.NoDevice,
            wasi.ENOENT => return error.FileNotFound,
            wasi.ENOMEM => return error.SystemResources,
            wasi.ENOSPC => return error.NoSpaceLeft,
            wasi.ENOTDIR => return error.NotDir,
            wasi.EPERM => return error.AccessDenied,
            wasi.EEXIST => return error.PathAlreadyExists,
            wasi.EBUSY => return error.DeviceBusy,
            wasi.ENOTCAPABLE => return error.AccessDenied,
            else => |err| return unexpectedErrno(err),
        }
    }
}

pub const openatC = @compileError("deprecated: renamed to openatZ");

/// Open and possibly create a file. Keeps trying if it gets interrupted.
/// `file_path` is relative to the open directory handle `dir_fd`.
/// See also `openat`.
pub fn openatZ(dir_fd: fd_t, file_path: [*:0]const u8, flags: u32, mode: mode_t) OpenError!fd_t {
    if (builtin.os.tag == .windows) {
        const file_path_w = try windows.cStrToPrefixedFileW(file_path);
        return openatW(dir_fd, file_path_w.span(), flags, mode);
    }

    const openat_sym = if (builtin.os.tag == .linux and builtin.link_libc)
        system.openat64
    else
        system.openat;

    while (true) {
        const rc = openat_sym(dir_fd, file_path, flags, mode);
        switch (errno(rc)) {
            0 => return @intCast(fd_t, rc),
            EINTR => continue,

            EFAULT => unreachable,
            EINVAL => unreachable,
            EBADF => unreachable,
            EACCES => return error.AccessDenied,
            EFBIG => return error.FileTooBig,
            EOVERFLOW => return error.FileTooBig,
            EISDIR => return error.IsDir,
            ELOOP => return error.SymLinkLoop,
            EMFILE => return error.ProcessFdQuotaExceeded,
            ENAMETOOLONG => return error.NameTooLong,
            ENFILE => return error.SystemFdQuotaExceeded,
            ENODEV => return error.NoDevice,
            ENOENT => return error.FileNotFound,
            ENOMEM => return error.SystemResources,
            ENOSPC => return error.NoSpaceLeft,
            ENOTDIR => return error.NotDir,
            EPERM => return error.AccessDenied,
            EEXIST => return error.PathAlreadyExists,
            EBUSY => return error.DeviceBusy,
            EOPNOTSUPP => return error.FileLocksNotSupported,
            EWOULDBLOCK => return error.WouldBlock,
            else => |err| return unexpectedErrno(err),
        }
    }
}

/// Windows-only. Similar to `openat` but with pathname argument null-terminated
/// WTF16 encoded.
/// TODO currently, this function does not handle all flag combinations
/// or makes use of perm argument.
pub fn openatW(dir_fd: fd_t, file_path_w: []const u16, flags: u32, mode: mode_t) OpenError!fd_t {
    _ = mode;
    var options = openOptionsFromFlags(flags);
    options.dir = dir_fd;
    return windows.OpenFile(file_path_w, options) catch |err| switch (err) {
        error.WouldBlock => unreachable,
        error.PipeBusy => unreachable,
        else => |e| return e,
    };
}

pub fn dup(old_fd: fd_t) !fd_t {
    const rc = system.dup(old_fd);
    return switch (errno(rc)) {
        0 => return @intCast(fd_t, rc),
        EMFILE => error.ProcessFdQuotaExceeded,
        EBADF => unreachable, // invalid file descriptor
        else => |err| return unexpectedErrno(err),
    };
}

pub fn dup2(old_fd: fd_t, new_fd: fd_t) !void {
    while (true) {
        switch (errno(system.dup2(old_fd, new_fd))) {
            0 => return,
            EBUSY, EINTR => continue,
            EMFILE => return error.ProcessFdQuotaExceeded,
            EINVAL => unreachable, // invalid parameters passed to dup2
            EBADF => unreachable, // invalid file descriptor
            else => |err| return unexpectedErrno(err),
        }
    }
}

pub const ExecveError = error{
    SystemResources,
    AccessDenied,
    InvalidExe,
    FileSystem,
    IsDir,
    FileNotFound,
    NotDir,
    FileBusy,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    NameTooLong,
} || UnexpectedError;

pub const execveC = @compileError("deprecated: use execveZ");

/// Like `execve` except the parameters are null-terminated,
/// matching the syscall API on all targets. This removes the need for an allocator.
/// This function ignores PATH environment variable. See `execvpeZ` for that.
pub fn execveZ(
    path: [*:0]const u8,
    child_argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) ExecveError {
    switch (errno(system.execve(path, child_argv, envp))) {
        0 => unreachable,
        EFAULT => unreachable,
        E2BIG => return error.SystemResources,
        EMFILE => return error.ProcessFdQuotaExceeded,
        ENAMETOOLONG => return error.NameTooLong,
        ENFILE => return error.SystemFdQuotaExceeded,
        ENOMEM => return error.SystemResources,
        EACCES => return error.AccessDenied,
        EPERM => return error.AccessDenied,
        EINVAL => return error.InvalidExe,
        ENOEXEC => return error.InvalidExe,
        EIO => return error.FileSystem,
        ELOOP => return error.FileSystem,
        EISDIR => return error.IsDir,
        ENOENT => return error.FileNotFound,
        ENOTDIR => return error.NotDir,
        ETXTBSY => return error.FileBusy,
        else => |err| return unexpectedErrno(err),
    }
}

pub const execvpeC = @compileError("deprecated in favor of execvpeZ");

pub const Arg0Expand = enum {
    expand,
    no_expand,
};

/// Like `execvpeZ` except if `arg0_expand` is `.expand`, then `argv` is mutable,
/// and `argv[0]` is expanded to be the same absolute path that is passed to the execve syscall.
/// If this function returns with an error, `argv[0]` will be restored to the value it was when it was passed in.
pub fn execvpeZ_expandArg0(
    comptime arg0_expand: Arg0Expand,
    file: [*:0]const u8,
    child_argv: switch (arg0_expand) {
        .expand => [*:null]?[*:0]const u8,
        .no_expand => [*:null]const ?[*:0]const u8,
    },
    envp: [*:null]const ?[*:0]const u8,
) ExecveError {
    const file_slice = mem.spanZ(file);
    if (mem.indexOfScalar(u8, file_slice, '/') != null) return execveZ(file, child_argv, envp);

    const PATH = getenvZ("PATH") orelse "/usr/local/bin:/bin/:/usr/bin";
    // Use of MAX_PATH_BYTES here is valid as the path_buf will be passed
    // directly to the operating system in execveZ.
    var path_buf: [MAX_PATH_BYTES]u8 = undefined;
    var it = mem.tokenize(PATH, ":");
    var seen_eacces = false;
    var err: ExecveError = undefined;

    // In case of expanding arg0 we must put it back if we return with an error.
    const prev_arg0 = child_argv[0];
    defer switch (arg0_expand) {
        .expand => child_argv[0] = prev_arg0,
        .no_expand => {},
    };

    while (it.next()) |search_path| {
        if (path_buf.len < search_path.len + file_slice.len + 1) return error.NameTooLong;
        mem.copy(u8, &path_buf, search_path);
        path_buf[search_path.len] = '/';
        mem.copy(u8, path_buf[search_path.len + 1 ..], file_slice);
        const path_len = search_path.len + file_slice.len + 1;
        path_buf[path_len] = 0;
        const full_path = path_buf[0..path_len :0].ptr;
        switch (arg0_expand) {
            .expand => child_argv[0] = full_path,
            .no_expand => {},
        }
        err = execveZ(full_path, child_argv, envp);
        switch (err) {
            error.AccessDenied => seen_eacces = true,
            error.FileNotFound, error.NotDir => {},
            else => |e| return e,
        }
    }
    if (seen_eacces) return error.AccessDenied;
    return err;
}

/// Like `execvpe` except the parameters are null-terminated,
/// matching the syscall API on all targets. This removes the need for an allocator.
/// This function also uses the PATH environment variable to get the full path to the executable.
/// If `file` is an absolute path, this is the same as `execveZ`.
pub fn execvpeZ(
    file: [*:0]const u8,
    argv_ptr: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) ExecveError {
    return execvpeZ_expandArg0(.no_expand, file, argv_ptr, envp);
}

/// Get an environment variable.
/// See also `getenvZ`.
pub fn getenv(key: []const u8) ?[]const u8 {
    if (builtin.link_libc) {
        var small_key_buf: [64]u8 = undefined;
        if (key.len < small_key_buf.len) {
            mem.copy(u8, &small_key_buf, key);
            small_key_buf[key.len] = 0;
            const key0 = small_key_buf[0..key.len :0];
            return getenvZ(key0);
        }
        // Search the entire `environ` because we don't have a null terminated pointer.
        var ptr = std.c.environ;
        while (ptr.*) |line| : (ptr += 1) {
            var line_i: usize = 0;
            while (line[line_i] != 0 and line[line_i] != '=') : (line_i += 1) {}
            const this_key = line[0..line_i];

            if (!mem.eql(u8, this_key, key)) continue;

            var end_i: usize = line_i;
            while (line[end_i] != 0) : (end_i += 1) {}
            const value = line[line_i + 1 .. end_i];

            return value;
        }
        return null;
    }
    if (builtin.os.tag == .windows) {
        @compileError("std.os.getenv is unavailable for Windows because environment string is in WTF-16 format. See std.process.getEnvVarOwned for cross-platform API or std.os.getenvW for Windows-specific API.");
    }
    // TODO see https://github.com/ziglang/zig/issues/4524
    for (environ) |ptr| {
        var line_i: usize = 0;
        while (ptr[line_i] != 0 and ptr[line_i] != '=') : (line_i += 1) {}
        const this_key = ptr[0..line_i];
        if (!mem.eql(u8, key, this_key)) continue;

        var end_i: usize = line_i;
        while (ptr[end_i] != 0) : (end_i += 1) {}
        const this_value = ptr[line_i + 1 .. end_i];

        return this_value;
    }
    return null;
}

pub const getenvC = @compileError("Deprecated in favor of `getenvZ`");

/// Get an environment variable with a null-terminated name.
/// See also `getenv`.
pub fn getenvZ(key: [*:0]const u8) ?[]const u8 {
    if (builtin.link_libc) {
        const value = system.getenv(key) orelse return null;
        return mem.spanZ(value);
    }
    if (builtin.os.tag == .windows) {
        @compileError("std.os.getenvZ is unavailable for Windows because environment string is in WTF-16 format. See std.process.getEnvVarOwned for cross-platform API or std.os.getenvW for Windows-specific API.");
    }
    return getenv(mem.spanZ(key));
}

/// Windows-only. Get an environment variable with a null-terminated, WTF-16 encoded name.
/// See also `getenv`.
/// This function first attempts a case-sensitive lookup. If no match is found, and `key`
/// is ASCII, then it attempts a second case-insensitive lookup.
pub fn getenvW(key: [*:0]const u16) ?[:0]const u16 {
    if (builtin.os.tag != .windows) {
        @compileError("std.os.getenvW is a Windows-only API");
    }
    const key_slice = mem.spanZ(key);
    const ptr = windows.peb().ProcessParameters.Environment;
    var ascii_match: ?[:0]const u16 = null;
    var i: usize = 0;
    while (ptr[i] != 0) {
        const key_start = i;

        while (ptr[i] != 0 and ptr[i] != '=') : (i += 1) {}
        const this_key = ptr[key_start..i];

        if (ptr[i] == '=') i += 1;

        const value_start = i;
        while (ptr[i] != 0) : (i += 1) {}
        const this_value = ptr[value_start..i :0];

        if (mem.eql(u16, key_slice, this_key)) return this_value;

        ascii_check: {
            if (ascii_match != null) break :ascii_check;
            if (key_slice.len != this_key.len) break :ascii_check;
            for (key_slice) |a_c, key_index| {
                const a = math.cast(u8, a_c) catch break :ascii_check;
                const b = math.cast(u8, this_key[key_index]) catch break :ascii_check;
                if (std.ascii.toLower(a) != std.ascii.toLower(b)) break :ascii_check;
            }
            ascii_match = this_value;
        }

        i += 1; // skip over null byte
    }
    return ascii_match;
}

pub const GetCwdError = error{
    NameTooLong,
    CurrentWorkingDirectoryUnlinked,
} || UnexpectedError;

/// The result is a slice of out_buffer, indexed from 0.
pub fn getcwd(out_buffer: []u8) GetCwdError![]u8 {
    if (builtin.os.tag == .windows) {
        return windows.GetCurrentDirectory(out_buffer);
    }
    if (builtin.os.tag == .wasi) {
        @compileError("WASI doesn't have a concept of cwd(); use std.fs.wasi.PreopenList to get available Dir handles instead");
    }

    const err = if (builtin.link_libc) blk: {
        break :blk if (std.c.getcwd(out_buffer.ptr, out_buffer.len)) |_| 0 else std.c._errno().*;
    } else blk: {
        break :blk errno(system.getcwd(out_buffer.ptr, out_buffer.len));
    };
    switch (err) {
        0 => return mem.spanZ(std.meta.assumeSentinel(out_buffer.ptr, 0)),
        EFAULT => unreachable,
        EINVAL => unreachable,
        ENOENT => return error.CurrentWorkingDirectoryUnlinked,
        ERANGE => return error.NameTooLong,
        else => return unexpectedErrno(err),
    }
}

pub const SymLinkError = error{
    /// In WASI, this error may occur when the file descriptor does
    /// not hold the required rights to create a new symbolic link relative to it.
    AccessDenied,
    DiskQuota,
    PathAlreadyExists,
    FileSystem,
    SymLinkLoop,
    FileNotFound,
    SystemResources,
    NoSpaceLeft,
    ReadOnlyFileSystem,
    NotDir,
    NameTooLong,
    InvalidUtf8,
    BadPathName,
} || UnexpectedError;

/// Creates a symbolic link named `sym_link_path` which contains the string `target_path`.
/// A symbolic link (also known as a soft link) may point to an existing file or to a nonexistent
/// one; the latter case is known as a dangling link.
/// If `sym_link_path` exists, it will not be overwritten.
/// See also `symlinkZ.
pub fn symlink(target_path: []const u8, sym_link_path: []const u8) SymLinkError!void {
    if (builtin.os.tag == .wasi) {
        @compileError("symlink is not supported in WASI; use symlinkat instead");
    }
    if (builtin.os.tag == .windows) {
        @compileError("symlink is not supported on Windows; use std.os.windows.CreateSymbolicLink instead");
    }
    const target_path_c = try toPosixPath(target_path);
    const sym_link_path_c = try toPosixPath(sym_link_path);
    return symlinkZ(&target_path_c, &sym_link_path_c);
}

pub const symlinkC = @compileError("deprecated: renamed to symlinkZ");

/// This is the same as `symlink` except the parameters are null-terminated pointers.
/// See also `symlink`.
pub fn symlinkZ(target_path: [*:0]const u8, sym_link_path: [*:0]const u8) SymLinkError!void {
    if (builtin.os.tag == .windows) {
        @compileError("symlink is not supported on Windows; use std.os.windows.CreateSymbolicLink instead");
    }
    switch (errno(system.symlink(target_path, sym_link_path))) {
        0 => return,
        EFAULT => unreachable,
        EINVAL => unreachable,
        EACCES => return error.AccessDenied,
        EPERM => return error.AccessDenied,
        EDQUOT => return error.DiskQuota,
        EEXIST => return error.PathAlreadyExists,
        EIO => return error.FileSystem,
        ELOOP => return error.SymLinkLoop,
        ENAMETOOLONG => return error.NameTooLong,
        ENOENT => return error.FileNotFound,
        ENOTDIR => return error.NotDir,
        ENOMEM => return error.SystemResources,
        ENOSPC => return error.NoSpaceLeft,
        EROFS => return error.ReadOnlyFileSystem,
        else => |err| return unexpectedErrno(err),
    }
}

/// Similar to `symlink`, however, creates a symbolic link named `sym_link_path` which contains the string
/// `target_path` **relative** to `newdirfd` directory handle.
/// A symbolic link (also known as a soft link) may point to an existing file or to a nonexistent
/// one; the latter case is known as a dangling link.
/// If `sym_link_path` exists, it will not be overwritten.
/// See also `symlinkatWasi`, `symlinkatZ` and `symlinkatW`.
pub fn symlinkat(target_path: []const u8, newdirfd: fd_t, sym_link_path: []const u8) SymLinkError!void {
    if (builtin.os.tag == .wasi) {
        return symlinkatWasi(target_path, newdirfd, sym_link_path);
    }
    if (builtin.os.tag == .windows) {
        @compileError("symlinkat is not supported on Windows; use std.os.windows.CreateSymbolicLink instead");
    }
    const target_path_c = try toPosixPath(target_path);
    const sym_link_path_c = try toPosixPath(sym_link_path);
    return symlinkatZ(&target_path_c, newdirfd, &sym_link_path_c);
}

pub const symlinkatC = @compileError("deprecated: renamed to symlinkatZ");

/// WASI-only. The same as `symlinkat` but targeting WASI.
/// See also `symlinkat`.
pub fn symlinkatWasi(target_path: []const u8, newdirfd: fd_t, sym_link_path: []const u8) SymLinkError!void {
    switch (wasi.path_symlink(target_path.ptr, target_path.len, newdirfd, sym_link_path.ptr, sym_link_path.len)) {
        wasi.ESUCCESS => {},
        wasi.EFAULT => unreachable,
        wasi.EINVAL => unreachable,
        wasi.EACCES => return error.AccessDenied,
        wasi.EPERM => return error.AccessDenied,
        wasi.EDQUOT => return error.DiskQuota,
        wasi.EEXIST => return error.PathAlreadyExists,
        wasi.EIO => return error.FileSystem,
        wasi.ELOOP => return error.SymLinkLoop,
        wasi.ENAMETOOLONG => return error.NameTooLong,
        wasi.ENOENT => return error.FileNotFound,
        wasi.ENOTDIR => return error.NotDir,
        wasi.ENOMEM => return error.SystemResources,
        wasi.ENOSPC => return error.NoSpaceLeft,
        wasi.EROFS => return error.ReadOnlyFileSystem,
        wasi.ENOTCAPABLE => return error.AccessDenied,
        else => |err| return unexpectedErrno(err),
    }
}

/// The same as `symlinkat` except the parameters are null-terminated pointers.
/// See also `symlinkat`.
pub fn symlinkatZ(target_path: [*:0]const u8, newdirfd: fd_t, sym_link_path: [*:0]const u8) SymLinkError!void {
    if (builtin.os.tag == .windows) {
        @compileError("symlinkat is not supported on Windows; use std.os.windows.CreateSymbolicLink instead");
    }
    switch (errno(system.symlinkat(target_path, newdirfd, sym_link_path))) {
        0 => return,
        EFAULT => unreachable,
        EINVAL => unreachable,
        EACCES => return error.AccessDenied,
        EPERM => return error.AccessDenied,
        EDQUOT => return error.DiskQuota,
        EEXIST => return error.PathAlreadyExists,
        EIO => return error.FileSystem,
        ELOOP => return error.SymLinkLoop,
        ENAMETOOLONG => return error.NameTooLong,
        ENOENT => return error.FileNotFound,
        ENOTDIR => return error.NotDir,
        ENOMEM => return error.SystemResources,
        ENOSPC => return error.NoSpaceLeft,
        EROFS => return error.ReadOnlyFileSystem,
        else => |err| return unexpectedErrno(err),
    }
}

pub const LinkError = UnexpectedError || error{
    AccessDenied,
    DiskQuota,
    PathAlreadyExists,
    FileSystem,
    SymLinkLoop,
    LinkQuotaExceeded,
    NameTooLong,
    FileNotFound,
    SystemResources,
    NoSpaceLeft,
    ReadOnlyFileSystem,
    NotSameFileSystem,
};

pub fn linkZ(oldpath: [*:0]const u8, newpath: [*:0]const u8, flags: i32) LinkError!void {
    switch (errno(system.link(oldpath, newpath, flags))) {
        0 => return,
        EACCES => return error.AccessDenied,
        EDQUOT => return error.DiskQuota,
        EEXIST => return error.PathAlreadyExists,
        EFAULT => unreachable,
        EIO => return error.FileSystem,
        ELOOP => return error.SymLinkLoop,
        EMLINK => return error.LinkQuotaExceeded,
        ENAMETOOLONG => return error.NameTooLong,
        ENOENT => return error.FileNotFound,
        ENOMEM => return error.SystemResources,
        ENOSPC => return error.NoSpaceLeft,
        EPERM => return error.AccessDenied,
        EROFS => return error.ReadOnlyFileSystem,
        EXDEV => return error.NotSameFileSystem,
        EINVAL => unreachable,
        else => |err| return unexpectedErrno(err),
    }
}

pub fn link(oldpath: []const u8, newpath: []const u8, flags: i32) LinkError!void {
    const old = try toPosixPath(oldpath);
    const new = try toPosixPath(newpath);
    return try linkZ(&old, &new, flags);
}

pub const LinkatError = LinkError || error{NotDir};

pub fn linkatZ(
    olddir: fd_t,
    oldpath: [*:0]const u8,
    newdir: fd_t,
    newpath: [*:0]const u8,
    flags: i32,
) LinkatError!void {
    switch (errno(system.linkat(olddir, oldpath, newdir, newpath, flags))) {
        0 => return,
        EACCES => return error.AccessDenied,
        EDQUOT => return error.DiskQuota,
        EEXIST => return error.PathAlreadyExists,
        EFAULT => unreachable,
        EIO => return error.FileSystem,
        ELOOP => return error.SymLinkLoop,
        EMLINK => return error.LinkQuotaExceeded,
        ENAMETOOLONG => return error.NameTooLong,
        ENOENT => return error.FileNotFound,
        ENOMEM => return error.SystemResources,
        ENOSPC => return error.NoSpaceLeft,
        ENOTDIR => return error.NotDir,
        EPERM => return error.AccessDenied,
        EROFS => return error.ReadOnlyFileSystem,
        EXDEV => return error.NotSameFileSystem,
        EINVAL => unreachable,
        else => |err| return unexpectedErrno(err),
    }
}

pub fn linkat(
    olddir: fd_t,
    oldpath: []const u8,
    newdir: fd_t,
    newpath: []const u8,
    flags: i32,
) LinkatError!void {
    const old = try toPosixPath(oldpath);
    const new = try toPosixPath(newpath);
    return try linkatZ(olddir, &old, newdir, &new, flags);
}

pub const UnlinkError = error{
    FileNotFound,

    /// In WASI, this error may occur when the file descriptor does
    /// not hold the required rights to unlink a resource by path relative to it.
    AccessDenied,
    FileBusy,
    FileSystem,
    IsDir,
    SymLinkLoop,
    NameTooLong,
    NotDir,
    SystemResources,
    ReadOnlyFileSystem,

    /// On Windows, file paths must be valid Unicode.
    InvalidUtf8,

    /// On Windows, file paths cannot contain these characters:
    /// '/', '*', '?', '"', '<', '>', '|'
    BadPathName,
} || UnexpectedError;

/// Delete a name and possibly the file it refers to.
/// See also `unlinkZ`.
pub fn unlink(file_path: []const u8) UnlinkError!void {
    if (builtin.os.tag == .wasi) {
        @compileError("unlink is not supported in WASI; use unlinkat instead");
    } else if (builtin.os.tag == .windows) {
        const file_path_w = try windows.sliceToPrefixedFileW(file_path);
        return unlinkW(file_path_w.span());
    } else {
        const file_path_c = try toPosixPath(file_path);
        return unlinkZ(&file_path_c);
    }
}

pub const unlinkC = @compileError("deprecated: renamed to unlinkZ");

/// Same as `unlink` except the parameter is a null terminated UTF8-encoded string.
pub fn unlinkZ(file_path: [*:0]const u8) UnlinkError!void {
    if (builtin.os.tag == .windows) {
        const file_path_w = try windows.cStrToPrefixedFileW(file_path);
        return unlinkW(file_path_w.span());
    }
    switch (errno(system.unlink(file_path))) {
        0 => return,
        EACCES => return error.AccessDenied,
        EPERM => return error.AccessDenied,
        EBUSY => return error.FileBusy,
        EFAULT => unreachable,
        EINVAL => unreachable,
        EIO => return error.FileSystem,
        EISDIR => return error.IsDir,
        ELOOP => return error.SymLinkLoop,
        ENAMETOOLONG => return error.NameTooLong,
        ENOENT => return error.FileNotFound,
        ENOTDIR => return error.NotDir,
        ENOMEM => return error.SystemResources,
        EROFS => return error.ReadOnlyFileSystem,
        else => |err| return unexpectedErrno(err),
    }
}

/// Windows-only. Same as `unlink` except the parameter is null-terminated, WTF16 encoded.
pub fn unlinkW(file_path_w: []const u16) UnlinkError!void {
    return windows.DeleteFile(file_path_w, .{ .dir = std.fs.cwd().fd });
}

pub const UnlinkatError = UnlinkError || error{
    /// When passing `AT_REMOVEDIR`, this error occurs when the named directory is not empty.
    DirNotEmpty,
};

/// Delete a file name and possibly the file it refers to, based on an open directory handle.
/// Asserts that the path parameter has no null bytes.
pub fn unlinkat(dirfd: fd_t, file_path: []const u8, flags: u32) UnlinkatError!void {
    if (builtin.os.tag == .windows) {
        const file_path_w = try windows.sliceToPrefixedFileW(file_path);
        return unlinkatW(dirfd, file_path_w.span(), flags);
    } else if (builtin.os.tag == .wasi) {
        return unlinkatWasi(dirfd, file_path, flags);
    } else {
        const file_path_c = try toPosixPath(file_path);
        return unlinkatZ(dirfd, &file_path_c, flags);
    }
}

pub const unlinkatC = @compileError("deprecated: renamed to unlinkatZ");

/// WASI-only. Same as `unlinkat` but targeting WASI.
/// See also `unlinkat`.
pub fn unlinkatWasi(dirfd: fd_t, file_path: []const u8, flags: u32) UnlinkatError!void {
    const remove_dir = (flags & AT_REMOVEDIR) != 0;
    const res = if (remove_dir)
        wasi.path_remove_directory(dirfd, file_path.ptr, file_path.len)
    else
        wasi.path_unlink_file(dirfd, file_path.ptr, file_path.len);
    switch (res) {
        wasi.ESUCCESS => return,
        wasi.EACCES => return error.AccessDenied,
        wasi.EPERM => return error.AccessDenied,
        wasi.EBUSY => return error.FileBusy,
        wasi.EFAULT => unreachable,
        wasi.EIO => return error.FileSystem,
        wasi.EISDIR => return error.IsDir,
        wasi.ELOOP => return error.SymLinkLoop,
        wasi.ENAMETOOLONG => return error.NameTooLong,
        wasi.ENOENT => return error.FileNotFound,
        wasi.ENOTDIR => return error.NotDir,
        wasi.ENOMEM => return error.SystemResources,
        wasi.EROFS => return error.ReadOnlyFileSystem,
        wasi.ENOTEMPTY => return error.DirNotEmpty,
        wasi.ENOTCAPABLE => return error.AccessDenied,

        wasi.EINVAL => unreachable, // invalid flags, or pathname has . as last component
        wasi.EBADF => unreachable, // always a race condition

        else => |err| return unexpectedErrno(err),
    }
}

/// Same as `unlinkat` but `file_path` is a null-terminated string.
pub fn unlinkatZ(dirfd: fd_t, file_path_c: [*:0]const u8, flags: u32) UnlinkatError!void {
    if (builtin.os.tag == .windows) {
        const file_path_w = try windows.cStrToPrefixedFileW(file_path_c);
        return unlinkatW(dirfd, file_path_w.span(), flags);
    }
    switch (errno(system.unlinkat(dirfd, file_path_c, flags))) {
        0 => return,
        EACCES => return error.AccessDenied,
        EPERM => return error.AccessDenied,
        EBUSY => return error.FileBusy,
        EFAULT => unreachable,
        EIO => return error.FileSystem,
        EISDIR => return error.IsDir,
        ELOOP => return error.SymLinkLoop,
        ENAMETOOLONG => return error.NameTooLong,
        ENOENT => return error.FileNotFound,
        ENOTDIR => return error.NotDir,
        ENOMEM => return error.SystemResources,
        EROFS => return error.ReadOnlyFileSystem,
        ENOTEMPTY => return error.DirNotEmpty,

        EINVAL => unreachable, // invalid flags, or pathname has . as last component
        EBADF => unreachable, // always a race condition

        else => |err| return unexpectedErrno(err),
    }
}

/// Same as `unlinkat` but `sub_path_w` is UTF16LE, NT prefixed. Windows only.
pub fn unlinkatW(dirfd: fd_t, sub_path_w: []const u16, flags: u32) UnlinkatError!void {
    const remove_dir = (flags & AT_REMOVEDIR) != 0;
    return windows.DeleteFile(sub_path_w, .{ .dir = dirfd, .remove_dir = remove_dir });
}

pub const RenameError = error{
    /// In WASI, this error may occur when the file descriptor does
    /// not hold the required rights to rename a resource by path relative to it.
    AccessDenied,
    FileBusy,
    DiskQuota,
    IsDir,
    SymLinkLoop,
    LinkQuotaExceeded,
    NameTooLong,
    FileNotFound,
    NotDir,
    SystemResources,
    NoSpaceLeft,
    PathAlreadyExists,
    ReadOnlyFileSystem,
    RenameAcrossMountPoints,
    InvalidUtf8,
    BadPathName,
    NoDevice,
    SharingViolation,
    PipeBusy,
} || UnexpectedError;

/// Change the name or location of a file.
pub fn rename(old_path: []const u8, new_path: []const u8) RenameError!void {
    if (builtin.os.tag == .wasi) {
        @compileError("rename is not supported in WASI; use renameat instead");
    } else if (builtin.os.tag == .windows) {
        const old_path_w = try windows.sliceToPrefixedFileW(old_path);
        const new_path_w = try windows.sliceToPrefixedFileW(new_path);
        return renameW(old_path_w.span().ptr, new_path_w.span().ptr);
    } else {
        const old_path_c = try toPosixPath(old_path);
        const new_path_c = try toPosixPath(new_path);
        return renameZ(&old_path_c, &new_path_c);
    }
}

pub const renameC = @compileError("deprecated: renamed to renameZ");

/// Same as `rename` except the parameters are null-terminated byte arrays.
pub fn renameZ(old_path: [*:0]const u8, new_path: [*:0]const u8) RenameError!void {
    if (builtin.os.tag == .windows) {
        const old_path_w = try windows.cStrToPrefixedFileW(old_path);
        const new_path_w = try windows.cStrToPrefixedFileW(new_path);
        return renameW(old_path_w.span().ptr, new_path_w.span().ptr);
    }
    switch (errno(system.rename(old_path, new_path))) {
        0 => return,
        EACCES => return error.AccessDenied,
        EPERM => return error.AccessDenied,
        EBUSY => return error.FileBusy,
        EDQUOT => return error.DiskQuota,
        EFAULT => unreachable,
        EINVAL => unreachable,
        EISDIR => return error.IsDir,
        ELOOP => return error.SymLinkLoop,
        EMLINK => return error.LinkQuotaExceeded,
        ENAMETOOLONG => return error.NameTooLong,
        ENOENT => return error.FileNotFound,
        ENOTDIR => return error.NotDir,
        ENOMEM => return error.SystemResources,
        ENOSPC => return error.NoSpaceLeft,
        EEXIST => return error.PathAlreadyExists,
        ENOTEMPTY => return error.PathAlreadyExists,
        EROFS => return error.ReadOnlyFileSystem,
        EXDEV => return error.RenameAcrossMountPoints,
        else => |err| return unexpectedErrno(err),
    }
}

/// Same as `rename` except the parameters are null-terminated UTF16LE encoded byte arrays.
/// Assumes target is Windows.
pub fn renameW(old_path: [*:0]const u16, new_path: [*:0]const u16) RenameError!void {
    const flags = windows.MOVEFILE_REPLACE_EXISTING | windows.MOVEFILE_WRITE_THROUGH;
    return windows.MoveFileExW(old_path, new_path, flags);
}

/// Change the name or location of a file based on an open directory handle.
pub fn renameat(
    old_dir_fd: fd_t,
    old_path: []const u8,
    new_dir_fd: fd_t,
    new_path: []const u8,
) RenameError!void {
    if (builtin.os.tag == .windows) {
        const old_path_w = try windows.sliceToPrefixedFileW(old_path);
        const new_path_w = try windows.sliceToPrefixedFileW(new_path);
        return renameatW(old_dir_fd, old_path_w.span(), new_dir_fd, new_path_w.span(), windows.TRUE);
    } else if (builtin.os.tag == .wasi) {
        return renameatWasi(old_dir_fd, old_path, new_dir_fd, new_path);
    } else {
        const old_path_c = try toPosixPath(old_path);
        const new_path_c = try toPosixPath(new_path);
        return renameatZ(old_dir_fd, &old_path_c, new_dir_fd, &new_path_c);
    }
}

/// WASI-only. Same as `renameat` expect targeting WASI.
/// See also `renameat`.
pub fn renameatWasi(old_dir_fd: fd_t, old_path: []const u8, new_dir_fd: fd_t, new_path: []const u8) RenameError!void {
    switch (wasi.path_rename(old_dir_fd, old_path.ptr, old_path.len, new_dir_fd, new_path.ptr, new_path.len)) {
        wasi.ESUCCESS => return,
        wasi.EACCES => return error.AccessDenied,
        wasi.EPERM => return error.AccessDenied,
        wasi.EBUSY => return error.FileBusy,
        wasi.EDQUOT => return error.DiskQuota,
        wasi.EFAULT => unreachable,
        wasi.EINVAL => unreachable,
        wasi.EISDIR => return error.IsDir,
        wasi.ELOOP => return error.SymLinkLoop,
        wasi.EMLINK => return error.LinkQuotaExceeded,
        wasi.ENAMETOOLONG => return error.NameTooLong,
        wasi.ENOENT => return error.FileNotFound,
        wasi.ENOTDIR => return error.NotDir,
        wasi.ENOMEM => return error.SystemResources,
        wasi.ENOSPC => return error.NoSpaceLeft,
        wasi.EEXIST => return error.PathAlreadyExists,
        wasi.ENOTEMPTY => return error.PathAlreadyExists,
        wasi.EROFS => return error.ReadOnlyFileSystem,
        wasi.EXDEV => return error.RenameAcrossMountPoints,
        wasi.ENOTCAPABLE => return error.AccessDenied,
        else => |err| return unexpectedErrno(err),
    }
}

/// Same as `renameat` except the parameters are null-terminated byte arrays.
pub fn renameatZ(
    old_dir_fd: fd_t,
    old_path: [*:0]const u8,
    new_dir_fd: fd_t,
    new_path: [*:0]const u8,
) RenameError!void {
    if (builtin.os.tag == .windows) {
        const old_path_w = try windows.cStrToPrefixedFileW(old_path);
        const new_path_w = try windows.cStrToPrefixedFileW(new_path);
        return renameatW(old_dir_fd, old_path_w.span(), new_dir_fd, new_path_w.span(), windows.TRUE);
    }

    switch (errno(system.renameat(old_dir_fd, old_path, new_dir_fd, new_path))) {
        0 => return,
        EACCES => return error.AccessDenied,
        EPERM => return error.AccessDenied,
        EBUSY => return error.FileBusy,
        EDQUOT => return error.DiskQuota,
        EFAULT => unreachable,
        EINVAL => unreachable,
        EISDIR => return error.IsDir,
        ELOOP => return error.SymLinkLoop,
        EMLINK => return error.LinkQuotaExceeded,
        ENAMETOOLONG => return error.NameTooLong,
        ENOENT => return error.FileNotFound,
        ENOTDIR => return error.NotDir,
        ENOMEM => return error.SystemResources,
        ENOSPC => return error.NoSpaceLeft,
        EEXIST => return error.PathAlreadyExists,
        ENOTEMPTY => return error.PathAlreadyExists,
        EROFS => return error.ReadOnlyFileSystem,
        EXDEV => return error.RenameAcrossMountPoints,
        else => |err| return unexpectedErrno(err),
    }
}

/// Same as `renameat` but Windows-only and the path parameters are
/// [WTF-16](https://simonsapin.github.io/wtf-8/#potentially-ill-formed-utf-16) encoded.
pub fn renameatW(
    old_dir_fd: fd_t,
    old_path_w: []const u16,
    new_dir_fd: fd_t,
    new_path_w: []const u16,
    ReplaceIfExists: windows.BOOLEAN,
) RenameError!void {
    const src_fd = windows.OpenFile(old_path_w, .{
        .dir = old_dir_fd,
        .access_mask = windows.SYNCHRONIZE | windows.GENERIC_WRITE | windows.DELETE,
        .creation = windows.FILE_OPEN,
        .io_mode = .blocking,
    }) catch |err| switch (err) {
        error.WouldBlock => unreachable, // Not possible without `.share_access_nonblocking = true`.
        else => |e| return e,
    };
    defer windows.CloseHandle(src_fd);

    const struct_buf_len = @sizeOf(windows.FILE_RENAME_INFORMATION) + (MAX_PATH_BYTES - 1);
    var rename_info_buf: [struct_buf_len]u8 align(@alignOf(windows.FILE_RENAME_INFORMATION)) = undefined;
    const struct_len = @sizeOf(windows.FILE_RENAME_INFORMATION) - 1 + new_path_w.len * 2;
    if (struct_len > struct_buf_len) return error.NameTooLong;

    const rename_info = @ptrCast(*windows.FILE_RENAME_INFORMATION, &rename_info_buf);

    rename_info.* = .{
        .ReplaceIfExists = ReplaceIfExists,
        .RootDirectory = if (std.fs.path.isAbsoluteWindowsWTF16(new_path_w)) null else new_dir_fd,
        .FileNameLength = @intCast(u32, new_path_w.len * 2), // already checked error.NameTooLong
        .FileName = undefined,
    };
    std.mem.copy(u16, @as([*]u16, &rename_info.FileName)[0..new_path_w.len], new_path_w);

    var io_status_block: windows.IO_STATUS_BLOCK = undefined;

    const rc = windows.ntdll.NtSetInformationFile(
        src_fd,
        &io_status_block,
        rename_info,
        @intCast(u32, struct_len), // already checked for error.NameTooLong
        .FileRenameInformation,
    );

    switch (rc) {
        .SUCCESS => return,
        .INVALID_HANDLE => unreachable,
        .INVALID_PARAMETER => unreachable,
        .OBJECT_PATH_SYNTAX_BAD => unreachable,
        .ACCESS_DENIED => return error.AccessDenied,
        .OBJECT_NAME_NOT_FOUND => return error.FileNotFound,
        .OBJECT_PATH_NOT_FOUND => return error.FileNotFound,
        .NOT_SAME_DEVICE => return error.RenameAcrossMountPoints,
        else => return windows.unexpectedStatus(rc),
    }
}

pub fn mkdirat(dir_fd: fd_t, sub_dir_path: []const u8, mode: u32) MakeDirError!void {
    if (builtin.os.tag == .windows) {
        const sub_dir_path_w = try windows.sliceToPrefixedFileW(sub_dir_path);
        return mkdiratW(dir_fd, sub_dir_path_w.span(), mode);
    } else if (builtin.os.tag == .wasi) {
        return mkdiratWasi(dir_fd, sub_dir_path, mode);
    } else {
        const sub_dir_path_c = try toPosixPath(sub_dir_path);
        return mkdiratZ(dir_fd, &sub_dir_path_c, mode);
    }
}

pub const mkdiratC = @compileError("deprecated: renamed to mkdiratZ");

pub fn mkdiratWasi(dir_fd: fd_t, sub_dir_path: []const u8, mode: u32) MakeDirError!void {
    _ = mode;
    switch (wasi.path_create_directory(dir_fd, sub_dir_path.ptr, sub_dir_path.len)) {
        wasi.ESUCCESS => return,
        wasi.EACCES => return error.AccessDenied,
        wasi.EBADF => unreachable,
        wasi.EPERM => return error.AccessDenied,
        wasi.EDQUOT => return error.DiskQuota,
        wasi.EEXIST => return error.PathAlreadyExists,
        wasi.EFAULT => unreachable,
        wasi.ELOOP => return error.SymLinkLoop,
        wasi.EMLINK => return error.LinkQuotaExceeded,
        wasi.ENAMETOOLONG => return error.NameTooLong,
        wasi.ENOENT => return error.FileNotFound,
        wasi.ENOMEM => return error.SystemResources,
        wasi.ENOSPC => return error.NoSpaceLeft,
        wasi.ENOTDIR => return error.NotDir,
        wasi.EROFS => return error.ReadOnlyFileSystem,
        wasi.ENOTCAPABLE => return error.AccessDenied,
        else => |err| return unexpectedErrno(err),
    }
}

pub fn mkdiratZ(dir_fd: fd_t, sub_dir_path: [*:0]const u8, mode: u32) MakeDirError!void {
    if (builtin.os.tag == .windows) {
        const sub_dir_path_w = try windows.cStrToPrefixedFileW(sub_dir_path);
        return mkdiratW(dir_fd, sub_dir_path_w.span().ptr, mode);
    }
    switch (errno(system.mkdirat(dir_fd, sub_dir_path, mode))) {
        0 => return,
        EACCES => return error.AccessDenied,
        EBADF => unreachable,
        EPERM => return error.AccessDenied,
        EDQUOT => return error.DiskQuota,
        EEXIST => return error.PathAlreadyExists,
        EFAULT => unreachable,
        ELOOP => return error.SymLinkLoop,
        EMLINK => return error.LinkQuotaExceeded,
        ENAMETOOLONG => return error.NameTooLong,
        ENOENT => return error.FileNotFound,
        ENOMEM => return error.SystemResources,
        ENOSPC => return error.NoSpaceLeft,
        ENOTDIR => return error.NotDir,
        EROFS => return error.ReadOnlyFileSystem,
        else => |err| return unexpectedErrno(err),
    }
}

pub fn mkdiratW(dir_fd: fd_t, sub_path_w: []const u16, mode: u32) MakeDirError!void {
    _ = mode;
    const sub_dir_handle = windows.OpenFile(sub_path_w, .{
        .dir = dir_fd,
        .access_mask = windows.GENERIC_READ | windows.SYNCHRONIZE,
        .creation = windows.FILE_CREATE,
        .io_mode = .blocking,
        .open_dir = true,
    }) catch |err| switch (err) {
        error.IsDir => unreachable,
        error.PipeBusy => unreachable,
        error.WouldBlock => unreachable,
        else => |e| return e,
    };
    windows.CloseHandle(sub_dir_handle);
}

pub const MakeDirError = error{
    /// In WASI, this error may occur when the file descriptor does
    /// not hold the required rights to create a new directory relative to it.
    AccessDenied,
    DiskQuota,
    PathAlreadyExists,
    SymLinkLoop,
    LinkQuotaExceeded,
    NameTooLong,
    FileNotFound,
    SystemResources,
    NoSpaceLeft,
    NotDir,
    ReadOnlyFileSystem,
    InvalidUtf8,
    BadPathName,
    NoDevice,
} || UnexpectedError;

/// Create a directory.
/// `mode` is ignored on Windows.
pub fn mkdir(dir_path: []const u8, mode: u32) MakeDirError!void {
    if (builtin.os.tag == .wasi) {
        @compileError("mkdir is not supported in WASI; use mkdirat instead");
    } else if (builtin.os.tag == .windows) {
        const dir_path_w = try windows.sliceToPrefixedFileW(dir_path);
        return mkdirW(dir_path_w.span(), mode);
    } else {
        const dir_path_c = try toPosixPath(dir_path);
        return mkdirZ(&dir_path_c, mode);
    }
}

/// Same as `mkdir` but the parameter is a null-terminated UTF8-encoded string.
pub fn mkdirZ(dir_path: [*:0]const u8, mode: u32) MakeDirError!void {
    if (builtin.os.tag == .windows) {
        const dir_path_w = try windows.cStrToPrefixedFileW(dir_path);
        return mkdirW(dir_path_w.span(), mode);
    }
    switch (errno(system.mkdir(dir_path, mode))) {
        0 => return,
        EACCES => return error.AccessDenied,
        EPERM => return error.AccessDenied,
        EDQUOT => return error.DiskQuota,
        EEXIST => return error.PathAlreadyExists,
        EFAULT => unreachable,
        ELOOP => return error.SymLinkLoop,
        EMLINK => return error.LinkQuotaExceeded,
        ENAMETOOLONG => return error.NameTooLong,
        ENOENT => return error.FileNotFound,
        ENOMEM => return error.SystemResources,
        ENOSPC => return error.NoSpaceLeft,
        ENOTDIR => return error.NotDir,
        EROFS => return error.ReadOnlyFileSystem,
        else => |err| return unexpectedErrno(err),
    }
}

/// Windows-only. Same as `mkdir` but the parameters is  WTF16 encoded.
pub fn mkdirW(dir_path_w: []const u16, mode: u32) MakeDirError!void {
    _ = mode;
    const sub_dir_handle = windows.OpenFile(dir_path_w, .{
        .dir = std.fs.cwd().fd,
        .access_mask = windows.GENERIC_READ | windows.SYNCHRONIZE,
        .creation = windows.FILE_CREATE,
        .io_mode = .blocking,
        .open_dir = true,
    }) catch |err| switch (err) {
        error.IsDir => unreachable,
        error.PipeBusy => unreachable,
        error.WouldBlock => unreachable,
        else => |e| return e,
    };
    windows.CloseHandle(sub_dir_handle);
}

pub const DeleteDirError = error{
    AccessDenied,
    FileBusy,
    SymLinkLoop,
    NameTooLong,
    FileNotFound,
    SystemResources,
    NotDir,
    DirNotEmpty,
    ReadOnlyFileSystem,
    InvalidUtf8,
    BadPathName,
} || UnexpectedError;

/// Deletes an empty directory.
pub fn rmdir(dir_path: []const u8) DeleteDirError!void {
    if (builtin.os.tag == .wasi) {
        @compileError("rmdir is not supported in WASI; use unlinkat instead");
    } else if (builtin.os.tag == .windows) {
        const dir_path_w = try windows.sliceToPrefixedFileW(dir_path);
        return rmdirW(dir_path_w.span());
    } else {
        const dir_path_c = try toPosixPath(dir_path);
        return rmdirZ(&dir_path_c);
    }
}

pub const rmdirC = @compileError("deprecated: renamed to rmdirZ");

/// Same as `rmdir` except the parameter is null-terminated.
pub fn rmdirZ(dir_path: [*:0]const u8) DeleteDirError!void {
    if (builtin.os.tag == .windows) {
        const dir_path_w = try windows.cStrToPrefixedFileW(dir_path);
        return rmdirW(dir_path_w.span());
    }
    switch (errno(system.rmdir(dir_path))) {
        0 => return,
        EACCES => return error.AccessDenied,
        EPERM => return error.AccessDenied,
        EBUSY => return error.FileBusy,
        EFAULT => unreachable,
        EINVAL => unreachable,
        ELOOP => return error.SymLinkLoop,
        ENAMETOOLONG => return error.NameTooLong,
        ENOENT => return error.FileNotFound,
        ENOMEM => return error.SystemResources,
        ENOTDIR => return error.NotDir,
        EEXIST => return error.DirNotEmpty,
        ENOTEMPTY => return error.DirNotEmpty,
        EROFS => return error.ReadOnlyFileSystem,
        else => |err| return unexpectedErrno(err),
    }
}

/// Windows-only. Same as `rmdir` except the parameter is WTF16 encoded.
pub fn rmdirW(dir_path_w: []const u16) DeleteDirError!void {
    return windows.DeleteFile(dir_path_w, .{ .dir = std.fs.cwd().fd, .remove_dir = true }) catch |err| switch (err) {
        error.IsDir => unreachable,
        else => |e| return e,
    };
}

pub const ChangeCurDirError = error{
    AccessDenied,
    FileSystem,
    SymLinkLoop,
    NameTooLong,
    FileNotFound,
    SystemResources,
    NotDir,
    BadPathName,

    /// On Windows, file paths must be valid Unicode.
    InvalidUtf8,
} || UnexpectedError;

/// Changes the current working directory of the calling process.
/// `dir_path` is recommended to be a UTF-8 encoded string.
pub fn chdir(dir_path: []const u8) ChangeCurDirError!void {
    if (builtin.os.tag == .wasi) {
        @compileError("chdir is not supported in WASI");
    } else if (builtin.os.tag == .windows) {
        var utf16_dir_path: [windows.PATH_MAX_WIDE]u16 = undefined;
        const len = try std.unicode.utf8ToUtf16Le(utf16_dir_path[0..], dir_path);
        if (len > utf16_dir_path.len) return error.NameTooLong;
        return chdirW(utf16_dir_path[0..len]);
    } else {
        const dir_path_c = try toPosixPath(dir_path);
        return chdirZ(&dir_path_c);
    }
}

pub const chdirC = @compileError("deprecated: renamed to chdirZ");

/// Same as `chdir` except the parameter is null-terminated.
pub fn chdirZ(dir_path: [*:0]const u8) ChangeCurDirError!void {
    if (builtin.os.tag == .windows) {
        var utf16_dir_path: [windows.PATH_MAX_WIDE]u16 = undefined;
        const len = try std.unicode.utf8ToUtf16Le(utf16_dir_path[0..], dir_path);
        if (len > utf16_dir_path.len) return error.NameTooLong;
        return chdirW(utf16_dir_path[0..len]);
    }
    switch (errno(system.chdir(dir_path))) {
        0 => return,
        EACCES => return error.AccessDenied,
        EFAULT => unreachable,
        EIO => return error.FileSystem,
        ELOOP => return error.SymLinkLoop,
        ENAMETOOLONG => return error.NameTooLong,
        ENOENT => return error.FileNotFound,
        ENOMEM => return error.SystemResources,
        ENOTDIR => return error.NotDir,
        else => |err| return unexpectedErrno(err),
    }
}

/// Windows-only. Same as `chdir` except the paramter is WTF16 encoded.
pub fn chdirW(dir_path: []const u16) ChangeCurDirError!void {
    windows.SetCurrentDirectory(dir_path) catch |err| switch (err) {
        error.NoDevice => return error.FileSystem,
        else => |e| return e,
    };
}

pub const FchdirError = error{
    AccessDenied,
    NotDir,
    FileSystem,
} || UnexpectedError;

pub fn fchdir(dirfd: fd_t) FchdirError!void {
    while (true) {
        switch (errno(system.fchdir(dirfd))) {
            0 => return,
            EACCES => return error.AccessDenied,
            EBADF => unreachable,
            ENOTDIR => return error.NotDir,
            EINTR => continue,
            EIO => return error.FileSystem,
            else => |err| return unexpectedErrno(err),
        }
    }
}

pub const ReadLinkError = error{
    /// In WASI, this error may occur when the file descriptor does
    /// not hold the required rights to read value of a symbolic link relative to it.
    AccessDenied,
    FileSystem,
    SymLinkLoop,
    NameTooLong,
    FileNotFound,
    SystemResources,
    NotDir,
    InvalidUtf8,
    BadPathName,
    /// Windows-only. This error may occur if the opened reparse point is
    /// of unsupported type.
    UnsupportedReparsePointType,
} || UnexpectedError;

/// Read value of a symbolic link.
/// The return value is a slice of `out_buffer` from index 0.
pub fn readlink(file_path: []const u8, out_buffer: []u8) ReadLinkError![]u8 {
    if (builtin.os.tag == .wasi) {
        @compileError("readlink is not supported in WASI; use readlinkat instead");
    } else if (builtin.os.tag == .windows) {
        const file_path_w = try windows.sliceToPrefixedFileW(file_path);
        return readlinkW(file_path_w.span(), out_buffer);
    } else {
        const file_path_c = try toPosixPath(file_path);
        return readlinkZ(&file_path_c, out_buffer);
    }
}

pub const readlinkC = @compileError("deprecated: renamed to readlinkZ");

/// Windows-only. Same as `readlink` except `file_path` is WTF16 encoded.
/// See also `readlinkZ`.
pub fn readlinkW(file_path: []const u16, out_buffer: []u8) ReadLinkError![]u8 {
    return windows.ReadLink(std.fs.cwd().fd, file_path, out_buffer);
}

/// Same as `readlink` except `file_path` is null-terminated.
pub fn readlinkZ(file_path: [*:0]const u8, out_buffer: []u8) ReadLinkError![]u8 {
    if (builtin.os.tag == .windows) {
        const file_path_w = try windows.cStrToWin32PrefixedFileW(file_path);
        return readlinkW(file_path_w.span(), out_buffer);
    }
    const rc = system.readlink(file_path, out_buffer.ptr, out_buffer.len);
    switch (errno(rc)) {
        0 => return out_buffer[0..@bitCast(usize, rc)],
        EACCES => return error.AccessDenied,
        EFAULT => unreachable,
        EINVAL => unreachable,
        EIO => return error.FileSystem,
        ELOOP => return error.SymLinkLoop,
        ENAMETOOLONG => return error.NameTooLong,
        ENOENT => return error.FileNotFound,
        ENOMEM => return error.SystemResources,
        ENOTDIR => return error.NotDir,
        else => |err| return unexpectedErrno(err),
    }
}

/// Similar to `readlink` except reads value of a symbolink link **relative** to `dirfd` directory handle.
/// The return value is a slice of `out_buffer` from index 0.
/// See also `readlinkatWasi`, `realinkatZ` and `realinkatW`.
pub fn readlinkat(dirfd: fd_t, file_path: []const u8, out_buffer: []u8) ReadLinkError![]u8 {
    if (builtin.os.tag == .wasi) {
        return readlinkatWasi(dirfd, file_path, out_buffer);
    }
    if (builtin.os.tag == .windows) {
        const file_path_w = try windows.sliceToPrefixedFileW(file_path);
        return readlinkatW(dirfd, file_path_w.span(), out_buffer);
    }
    const file_path_c = try toPosixPath(file_path);
    return readlinkatZ(dirfd, &file_path_c, out_buffer);
}

pub const readlinkatC = @compileError("deprecated: renamed to readlinkatZ");

/// WASI-only. Same as `readlinkat` but targets WASI.
/// See also `readlinkat`.
pub fn readlinkatWasi(dirfd: fd_t, file_path: []const u8, out_buffer: []u8) ReadLinkError![]u8 {
    var bufused: usize = undefined;
    switch (wasi.path_readlink(dirfd, file_path.ptr, file_path.len, out_buffer.ptr, out_buffer.len, &bufused)) {
        wasi.ESUCCESS => return out_buffer[0..bufused],
        wasi.EACCES => return error.AccessDenied,
        wasi.EFAULT => unreachable,
        wasi.EINVAL => unreachable,
        wasi.EIO => return error.FileSystem,
        wasi.ELOOP => return error.SymLinkLoop,
        wasi.ENAMETOOLONG => return error.NameTooLong,
        wasi.ENOENT => return error.FileNotFound,
        wasi.ENOMEM => return error.SystemResources,
        wasi.ENOTDIR => return error.NotDir,
        wasi.ENOTCAPABLE => return error.AccessDenied,
        else => |err| return unexpectedErrno(err),
    }
}

/// Windows-only. Same as `readlinkat` except `file_path` is null-terminated, WTF16 encoded.
/// See also `readlinkat`.
pub fn readlinkatW(dirfd: fd_t, file_path: []const u16, out_buffer: []u8) ReadLinkError![]u8 {
    return windows.ReadLink(dirfd, file_path, out_buffer);
}

/// Same as `readlinkat` except `file_path` is null-terminated.
/// See also `readlinkat`.
pub fn readlinkatZ(dirfd: fd_t, file_path: [*:0]const u8, out_buffer: []u8) ReadLinkError![]u8 {
    if (builtin.os.tag == .windows) {
        const file_path_w = try windows.cStrToPrefixedFileW(file_path);
        return readlinkatW(dirfd, file_path_w.span(), out_buffer);
    }
    const rc = system.readlinkat(dirfd, file_path, out_buffer.ptr, out_buffer.len);
    switch (errno(rc)) {
        0 => return out_buffer[0..@bitCast(usize, rc)],
        EACCES => return error.AccessDenied,
        EFAULT => unreachable,
        EINVAL => unreachable,
        EIO => return error.FileSystem,
        ELOOP => return error.SymLinkLoop,
        ENAMETOOLONG => return error.NameTooLong,
        ENOENT => return error.FileNotFound,
        ENOMEM => return error.SystemResources,
        ENOTDIR => return error.NotDir,
        else => |err| return unexpectedErrno(err),
    }
}

pub const SetEidError = error{
    InvalidUserId,
    PermissionDenied,
} || UnexpectedError;

pub const SetIdError = error{ResourceLimitReached} || SetEidError;

pub fn setuid(uid: uid_t) SetIdError!void {
    switch (errno(system.setuid(uid))) {
        0 => return,
        EAGAIN => return error.ResourceLimitReached,
        EINVAL => return error.InvalidUserId,
        EPERM => return error.PermissionDenied,
        else => |err| return unexpectedErrno(err),
    }
}

pub fn seteuid(uid: uid_t) SetEidError!void {
    switch (errno(system.seteuid(uid))) {
        0 => return,
        EINVAL => return error.InvalidUserId,
        EPERM => return error.PermissionDenied,
        else => |err| return unexpectedErrno(err),
    }
}

pub fn setreuid(ruid: uid_t, euid: uid_t) SetIdError!void {
    switch (errno(system.setreuid(ruid, euid))) {
        0 => return,
        EAGAIN => return error.ResourceLimitReached,
        EINVAL => return error.InvalidUserId,
        EPERM => return error.PermissionDenied,
        else => |err| return unexpectedErrno(err),
    }
}

pub fn setgid(gid: gid_t) SetIdError!void {
    switch (errno(system.setgid(gid))) {
        0 => return,
        EAGAIN => return error.ResourceLimitReached,
        EINVAL => return error.InvalidUserId,
        EPERM => return error.PermissionDenied,
        else => |err| return unexpectedErrno(err),
    }
}

pub fn setegid(uid: uid_t) SetEidError!void {
    switch (errno(system.setegid(uid))) {
        0 => return,
        EINVAL => return error.InvalidUserId,
        EPERM => return error.PermissionDenied,
        else => |err| return unexpectedErrno(err),
    }
}

pub fn setregid(rgid: gid_t, egid: gid_t) SetIdError!void {
    switch (errno(system.setregid(rgid, egid))) {
        0 => return,
        EAGAIN => return error.ResourceLimitReached,
        EINVAL => return error.InvalidUserId,
        EPERM => return error.PermissionDenied,
        else => |err| return unexpectedErrno(err),
    }
}

/// Test whether a file descriptor refers to a terminal.
pub fn isatty(handle: fd_t) bool {
    if (builtin.os.tag == .windows) {
        if (isCygwinPty(handle))
            return true;

        var out: windows.DWORD = undefined;
        return windows.kernel32.GetConsoleMode(handle, &out) != 0;
    }
    if (builtin.link_libc) {
        return system.isatty(handle) != 0;
    }
    if (builtin.os.tag == .wasi) {
        var statbuf: fdstat_t = undefined;
        const err = system.fd_fdstat_get(handle, &statbuf);
        if (err != 0) {
            // errno = err;
            return false;
        }

        // A tty is a character device that we can't seek or tell on.
        if (statbuf.fs_filetype != FILETYPE_CHARACTER_DEVICE or
            (statbuf.fs_rights_base & (RIGHT_FD_SEEK | RIGHT_FD_TELL)) != 0)
        {
            // errno = ENOTTY;
            return false;
        }

        return true;
    }
    if (builtin.os.tag == .linux) {
        while (true) {
            var wsz: linux.winsize = undefined;
            const fd = @bitCast(usize, @as(isize, handle));
            switch (linux.syscall3(.ioctl, fd, linux.TIOCGWINSZ, @ptrToInt(&wsz))) {
                0 => return true,
                EINTR => continue,
                else => return false,
            }
        }
    }
    return system.isatty(handle) != 0;
}

pub fn isCygwinPty(handle: fd_t) bool {
    if (builtin.os.tag != .windows) return false;

    const size = @sizeOf(windows.FILE_NAME_INFO);
    var name_info_bytes align(@alignOf(windows.FILE_NAME_INFO)) = [_]u8{0} ** (size + windows.MAX_PATH);

    if (windows.kernel32.GetFileInformationByHandleEx(
        handle,
        windows.FileNameInfo,
        @ptrCast(*c_void, &name_info_bytes),
        name_info_bytes.len,
    ) == 0) {
        return false;
    }

    const name_info = @ptrCast(*const windows.FILE_NAME_INFO, &name_info_bytes[0]);
    const name_bytes = name_info_bytes[size .. size + @as(usize, name_info.FileNameLength)];
    const name_wide = mem.bytesAsSlice(u16, name_bytes);
    return mem.indexOf(u16, name_wide, &[_]u16{ 'm', 's', 'y', 's', '-' }) != null or
        mem.indexOf(u16, name_wide, &[_]u16{ '-', 'p', 't', 'y' }) != null;
}

pub const SocketError = error{
    /// Permission to create a socket of the specified type and/or
    /// pro‐tocol is denied.
    PermissionDenied,

    /// The implementation does not support the specified address family.
    AddressFamilyNotSupported,

    /// Unknown protocol, or protocol family not available.
    ProtocolFamilyNotAvailable,

    /// The per-process limit on the number of open file descriptors has been reached.
    ProcessFdQuotaExceeded,

    /// The system-wide limit on the total number of open files has been reached.
    SystemFdQuotaExceeded,

    /// Insufficient memory is available. The socket cannot be created until sufficient
    /// resources are freed.
    SystemResources,

    /// The protocol type or the specified protocol is not supported within this domain.
    ProtocolNotSupported,

    /// The socket type is not supported by the protocol.
    SocketTypeNotSupported,
} || UnexpectedError;

pub fn socket(domain: u32, socket_type: u32, protocol: u32) SocketError!socket_t {
    if (builtin.os.tag == .windows) {
        // NOTE: windows translates the SOCK_NONBLOCK/SOCK_CLOEXEC flags into
        // windows-analagous operations
        const filtered_sock_type = socket_type & ~@as(u32, SOCK_NONBLOCK | SOCK_CLOEXEC);
        const flags: u32 = if ((socket_type & SOCK_CLOEXEC) != 0)
            windows.ws2_32.WSA_FLAG_NO_HANDLE_INHERIT
        else
            0;
        const rc = try windows.WSASocketW(
            @bitCast(i32, domain),
            @bitCast(i32, filtered_sock_type),
            @bitCast(i32, protocol),
            null,
            0,
            flags,
        );
        errdefer windows.closesocket(rc) catch unreachable;
        if ((socket_type & SOCK_NONBLOCK) != 0) {
            var mode: c_ulong = 1; // nonblocking
            if (windows.ws2_32.SOCKET_ERROR == windows.ws2_32.ioctlsocket(rc, windows.ws2_32.FIONBIO, &mode)) {
                switch (windows.ws2_32.WSAGetLastError()) {
                    // have not identified any error codes that should be handled yet
                    else => unreachable,
                }
            }
        }
        return rc;
    }

    const have_sock_flags = comptime !std.Target.current.isDarwin();
    const filtered_sock_type = if (!have_sock_flags)
        socket_type & ~@as(u32, SOCK_NONBLOCK | SOCK_CLOEXEC)
    else
        socket_type;
    const rc = system.socket(domain, filtered_sock_type, protocol);
    switch (errno(rc)) {
        0 => {
            const fd = @intCast(fd_t, rc);
            if (!have_sock_flags) {
                try setSockFlags(fd, socket_type);
            }
            return fd;
        },
        EACCES => return error.PermissionDenied,
        EAFNOSUPPORT => return error.AddressFamilyNotSupported,
        EINVAL => return error.ProtocolFamilyNotAvailable,
        EMFILE => return error.ProcessFdQuotaExceeded,
        ENFILE => return error.SystemFdQuotaExceeded,
        ENOBUFS => return error.SystemResources,
        ENOMEM => return error.SystemResources,
        EPROTONOSUPPORT => return error.ProtocolNotSupported,
        EPROTOTYPE => return error.SocketTypeNotSupported,
        else => |err| return unexpectedErrno(err),
    }
}

pub const ShutdownError = error{
    ConnectionAborted,

    /// Connection was reset by peer, application should close socket as it is no longer usable.
    ConnectionResetByPeer,
    BlockingOperationInProgress,

    /// The network subsystem has failed.
    NetworkSubsystemFailed,

    /// The socket is not connected (connection-oriented sockets only).
    SocketNotConnected,
    SystemResources,
} || UnexpectedError;

pub const ShutdownHow = enum { recv, send, both };

/// Shutdown socket send/receive operations
pub fn shutdown(sock: socket_t, how: ShutdownHow) ShutdownError!void {
    if (builtin.os.tag == .windows) {
        const result = windows.ws2_32.shutdown(sock, switch (how) {
            .recv => windows.ws2_32.SD_RECEIVE,
            .send => windows.ws2_32.SD_SEND,
            .both => windows.ws2_32.SD_BOTH,
        });
        if (0 != result) switch (windows.ws2_32.WSAGetLastError()) {
            .WSAECONNABORTED => return error.ConnectionAborted,
            .WSAECONNRESET => return error.ConnectionResetByPeer,
            .WSAEINPROGRESS => return error.BlockingOperationInProgress,
            .WSAEINVAL => unreachable,
            .WSAENETDOWN => return error.NetworkSubsystemFailed,
            .WSAENOTCONN => return error.SocketNotConnected,
            .WSAENOTSOCK => unreachable,
            .WSANOTINITIALISED => unreachable,
            else => |err| return windows.unexpectedWSAError(err),
        };
    } else {
        const rc = system.shutdown(sock, switch (how) {
            .recv => SHUT_RD,
            .send => SHUT_WR,
            .both => SHUT_RDWR,
        });
        switch (errno(rc)) {
            0 => return,
            EBADF => unreachable,
            EINVAL => unreachable,
            ENOTCONN => return error.SocketNotConnected,
            ENOTSOCK => unreachable,
            ENOBUFS => return error.SystemResources,
            else => |err| return unexpectedErrno(err),
        }
    }
}

pub fn closeSocket(sock: socket_t) void {
    if (builtin.os.tag == .windows) {
        windows.closesocket(sock) catch unreachable;
    } else {
        close(sock);
    }
}

pub const BindError = error{
    /// The address is protected, and the user is not the superuser.
    /// For UNIX domain sockets: Search permission is denied on  a  component
    /// of  the  path  prefix.
    AccessDenied,

    /// The given address is already in use, or in the case of Internet domain sockets,
    /// The  port number was specified as zero in the socket
    /// address structure, but, upon attempting to bind to  an  ephemeral  port,  it  was
    /// determined  that  all  port  numbers in the ephemeral port range are currently in
    /// use.  See the discussion of /proc/sys/net/ipv4/ip_local_port_range ip(7).
    AddressInUse,

    /// A nonexistent interface was requested or the requested address was not local.
    AddressNotAvailable,

    /// Too many symbolic links were encountered in resolving addr.
    SymLinkLoop,

    /// addr is too long.
    NameTooLong,

    /// A component in the directory prefix of the socket pathname does not exist.
    FileNotFound,

    /// Insufficient kernel memory was available.
    SystemResources,

    /// A component of the path prefix is not a directory.
    NotDir,

    /// The socket inode would reside on a read-only filesystem.
    ReadOnlyFileSystem,

    /// The network subsystem has failed.
    NetworkSubsystemFailed,

    FileDescriptorNotASocket,

    AlreadyBound,
} || UnexpectedError;

/// addr is `*const T` where T is one of the sockaddr
pub fn bind(sock: socket_t, addr: *const sockaddr, len: socklen_t) BindError!void {
    if (builtin.os.tag == .windows) {
        const rc = windows.bind(sock, addr, len);
        if (rc == windows.ws2_32.SOCKET_ERROR) {
            switch (windows.ws2_32.WSAGetLastError()) {
                .WSANOTINITIALISED => unreachable, // not initialized WSA
                .WSAEACCES => return error.AccessDenied,
                .WSAEADDRINUSE => return error.AddressInUse,
                .WSAEADDRNOTAVAIL => return error.AddressNotAvailable,
                .WSAENOTSOCK => return error.FileDescriptorNotASocket,
                .WSAEFAULT => unreachable, // invalid pointers
                .WSAEINVAL => return error.AlreadyBound,
                .WSAENOBUFS => return error.SystemResources,
                .WSAENETDOWN => return error.NetworkSubsystemFailed,
                else => |err| return windows.unexpectedWSAError(err),
            }
            unreachable;
        }
        return;
    } else {
        const rc = system.bind(sock, addr, len);
        switch (errno(rc)) {
            0 => return,
            EACCES => return error.AccessDenied,
            EADDRINUSE => return error.AddressInUse,
            EBADF => unreachable, // always a race condition if this error is returned
            EINVAL => unreachable, // invalid parameters
            ENOTSOCK => unreachable, // invalid `sockfd`
            EADDRNOTAVAIL => return error.AddressNotAvailable,
            EFAULT => unreachable, // invalid `addr` pointer
            ELOOP => return error.SymLinkLoop,
            ENAMETOOLONG => return error.NameTooLong,
            ENOENT => return error.FileNotFound,
            ENOMEM => return error.SystemResources,
            ENOTDIR => return error.NotDir,
            EROFS => return error.ReadOnlyFileSystem,
            else => |err| return unexpectedErrno(err),
        }
    }
    unreachable;
}

pub const ListenError = error{
    /// Another socket is already listening on the same port.
    /// For Internet domain sockets, the  socket referred to by sockfd had not previously
    /// been bound to an address and, upon attempting to bind it to an ephemeral port, it
    /// was determined that all port numbers in the ephemeral port range are currently in
    /// use.  See the discussion of /proc/sys/net/ipv4/ip_local_port_range in ip(7).
    AddressInUse,

    /// The file descriptor sockfd does not refer to a socket.
    FileDescriptorNotASocket,

    /// The socket is not of a type that supports the listen() operation.
    OperationNotSupported,

    /// The network subsystem has failed.
    NetworkSubsystemFailed,

    /// Ran out of system resources
    /// On Windows it can either run out of socket descriptors or buffer space
    SystemResources,

    /// Already connected
    AlreadyConnected,

    /// Socket has not been bound yet
    SocketNotBound,
} || UnexpectedError;

pub fn listen(sock: socket_t, backlog: u31) ListenError!void {
    if (builtin.os.tag == .windows) {
        const rc = windows.listen(sock, backlog);
        if (rc == windows.ws2_32.SOCKET_ERROR) {
            switch (windows.ws2_32.WSAGetLastError()) {
                .WSANOTINITIALISED => unreachable, // not initialized WSA
                .WSAENETDOWN => return error.NetworkSubsystemFailed,
                .WSAEADDRINUSE => return error.AddressInUse,
                .WSAEISCONN => return error.AlreadyConnected,
                .WSAEINVAL => return error.SocketNotBound,
                .WSAEMFILE, .WSAENOBUFS => return error.SystemResources,
                .WSAENOTSOCK => return error.FileDescriptorNotASocket,
                .WSAEOPNOTSUPP => return error.OperationNotSupported,
                .WSAEINPROGRESS => unreachable,
                else => |err| return windows.unexpectedWSAError(err),
            }
        }
        return;
    } else {
        const rc = system.listen(sock, backlog);
        switch (errno(rc)) {
            0 => return,
            EADDRINUSE => return error.AddressInUse,
            EBADF => unreachable,
            ENOTSOCK => return error.FileDescriptorNotASocket,
            EOPNOTSUPP => return error.OperationNotSupported,
            else => |err| return unexpectedErrno(err),
        }
    }
}

pub const AcceptError = error{
    ConnectionAborted,

    /// The file descriptor sockfd does not refer to a socket.
    FileDescriptorNotASocket,

    /// The per-process limit on the number of open file descriptors has been reached.
    ProcessFdQuotaExceeded,

    /// The system-wide limit on the total number of open files has been reached.
    SystemFdQuotaExceeded,

    /// Not enough free memory.  This often means that the memory allocation  is  limited
    /// by the socket buffer limits, not by the system memory.
    SystemResources,

    /// Socket is not listening for new connections.
    SocketNotListening,

    ProtocolFailure,

    /// Firewall rules forbid connection.
    BlockedByFirewall,

    /// This error occurs when no global event loop is configured,
    /// and accepting from the socket would block.
    WouldBlock,

    /// An incoming connection was indicated, but was subsequently terminated by the
    /// remote peer prior to accepting the call.
    ConnectionResetByPeer,

    /// The network subsystem has failed.
    NetworkSubsystemFailed,

    /// The referenced socket is not a type that supports connection-oriented service.
    OperationNotSupported,
} || UnexpectedError;

/// Accept a connection on a socket.
/// If `sockfd` is opened in non blocking mode, the function will
/// return error.WouldBlock when EAGAIN is received.
pub fn accept(
    /// This argument is a socket that has been created with `socket`, bound to a local address
    /// with `bind`, and is listening for connections after a `listen`.
    sock: socket_t,
    /// This argument is a pointer to a sockaddr structure.  This structure is filled in with  the
    /// address  of  the  peer  socket, as known to the communications layer.  The exact format of the
    /// address returned addr is determined by the socket's address  family  (see  `socket`  and  the
    /// respective  protocol  man  pages).
    addr: ?*sockaddr,
    /// This argument is a value-result argument: the caller must initialize it to contain  the
    /// size (in bytes) of the structure pointed to by addr; on return it will contain the actual size
    /// of the peer address.
    ///
    /// The returned address is truncated if the buffer provided is too small; in this  case,  `addr_size`
    /// will return a value greater than was supplied to the call.
    addr_size: ?*socklen_t,
    /// The following values can be bitwise ORed in flags to obtain different behavior:
    /// * `SOCK_NONBLOCK` - Set the `O_NONBLOCK` file status flag on the open file description (see `open`)
    ///   referred  to by the new file descriptor.  Using this flag saves extra calls to `fcntl` to achieve
    ///   the same result.
    /// * `SOCK_CLOEXEC`  - Set the close-on-exec (`FD_CLOEXEC`) flag on the new file descriptor.   See  the
    ///   description  of the `O_CLOEXEC` flag in `open` for reasons why this may be useful.
    flags: u32,
) AcceptError!socket_t {
    const have_accept4 = comptime !(std.Target.current.isDarwin() or builtin.os.tag == .windows);
    assert(0 == (flags & ~@as(u32, SOCK_NONBLOCK | SOCK_CLOEXEC))); // Unsupported flag(s)

    const accepted_sock = while (true) {
        const rc = if (have_accept4)
            system.accept4(sock, addr, addr_size, flags)
        else if (builtin.os.tag == .windows)
            windows.accept(sock, addr, addr_size)
        else
            system.accept(sock, addr, addr_size);

        if (builtin.os.tag == .windows) {
            if (rc == windows.ws2_32.INVALID_SOCKET) {
                switch (windows.ws2_32.WSAGetLastError()) {
                    .WSANOTINITIALISED => unreachable, // not initialized WSA
                    .WSAECONNRESET => return error.ConnectionResetByPeer,
                    .WSAEFAULT => unreachable,
                    .WSAEINVAL => return error.SocketNotListening,
                    .WSAEMFILE => return error.ProcessFdQuotaExceeded,
                    .WSAENETDOWN => return error.NetworkSubsystemFailed,
                    .WSAENOBUFS => return error.FileDescriptorNotASocket,
                    .WSAEOPNOTSUPP => return error.OperationNotSupported,
                    .WSAEWOULDBLOCK => return error.WouldBlock,
                    else => |err| return windows.unexpectedWSAError(err),
                }
            } else {
                break rc;
            }
        } else {
            switch (errno(rc)) {
                0 => {
                    break @intCast(socket_t, rc);
                },
                EINTR => continue,
                EAGAIN => return error.WouldBlock,
                EBADF => unreachable, // always a race condition
                ECONNABORTED => return error.ConnectionAborted,
                EFAULT => unreachable,
                EINVAL => return error.SocketNotListening,
                ENOTSOCK => unreachable,
                EMFILE => return error.ProcessFdQuotaExceeded,
                ENFILE => return error.SystemFdQuotaExceeded,
                ENOBUFS => return error.SystemResources,
                ENOMEM => return error.SystemResources,
                EOPNOTSUPP => unreachable,
                EPROTO => return error.ProtocolFailure,
                EPERM => return error.BlockedByFirewall,
                else => |err| return unexpectedErrno(err),
            }
        }
    } else unreachable;

    if (!have_accept4) {
        try setSockFlags(accepted_sock, flags);
    }
    return accepted_sock;
}

pub const EpollCreateError = error{
    /// The  per-user   limit   on   the   number   of   epoll   instances   imposed   by
    /// /proc/sys/fs/epoll/max_user_instances  was encountered.  See epoll(7) for further
    /// details.
    /// Or, The per-process limit on the number of open file descriptors has been reached.
    ProcessFdQuotaExceeded,

    /// The system-wide limit on the total number of open files has been reached.
    SystemFdQuotaExceeded,

    /// There was insufficient memory to create the kernel object.
    SystemResources,
} || UnexpectedError;

pub fn epoll_create1(flags: u32) EpollCreateError!i32 {
    const rc = system.epoll_create1(flags);
    switch (errno(rc)) {
        0 => return @intCast(i32, rc),
        else => |err| return unexpectedErrno(err),

        EINVAL => unreachable,
        EMFILE => return error.ProcessFdQuotaExceeded,
        ENFILE => return error.SystemFdQuotaExceeded,
        ENOMEM => return error.SystemResources,
    }
}

pub const EpollCtlError = error{
    /// op was EPOLL_CTL_ADD, and the supplied file descriptor fd is  already  registered
    /// with this epoll instance.
    FileDescriptorAlreadyPresentInSet,

    /// fd refers to an epoll instance and this EPOLL_CTL_ADD operation would result in a
    /// circular loop of epoll instances monitoring one another.
    OperationCausesCircularLoop,

    /// op was EPOLL_CTL_MOD or EPOLL_CTL_DEL, and fd is not registered with  this  epoll
    /// instance.
    FileDescriptorNotRegistered,

    /// There was insufficient memory to handle the requested op control operation.
    SystemResources,

    /// The  limit  imposed  by /proc/sys/fs/epoll/max_user_watches was encountered while
    /// trying to register (EPOLL_CTL_ADD) a new file descriptor on  an  epoll  instance.
    /// See epoll(7) for further details.
    UserResourceLimitReached,

    /// The target file fd does not support epoll.  This error can occur if fd refers to,
    /// for example, a regular file or a directory.
    FileDescriptorIncompatibleWithEpoll,
} || UnexpectedError;

pub fn epoll_ctl(epfd: i32, op: u32, fd: i32, event: ?*epoll_event) EpollCtlError!void {
    const rc = system.epoll_ctl(epfd, op, fd, event);
    switch (errno(rc)) {
        0 => return,
        else => |err| return unexpectedErrno(err),

        EBADF => unreachable, // always a race condition if this happens
        EEXIST => return error.FileDescriptorAlreadyPresentInSet,
        EINVAL => unreachable,
        ELOOP => return error.OperationCausesCircularLoop,
        ENOENT => return error.FileDescriptorNotRegistered,
        ENOMEM => return error.SystemResources,
        ENOSPC => return error.UserResourceLimitReached,
        EPERM => return error.FileDescriptorIncompatibleWithEpoll,
    }
}

/// Waits for an I/O event on an epoll file descriptor.
/// Returns the number of file descriptors ready for the requested I/O,
/// or zero if no file descriptor became ready during the requested timeout milliseconds.
pub fn epoll_wait(epfd: i32, events: []epoll_event, timeout: i32) usize {
    while (true) {
        // TODO get rid of the @intCast
        const rc = system.epoll_wait(epfd, events.ptr, @intCast(u32, events.len), timeout);
        switch (errno(rc)) {
            0 => return @intCast(usize, rc),
            EINTR => continue,
            EBADF => unreachable,
            EFAULT => unreachable,
            EINVAL => unreachable,
            else => unreachable,
        }
    }
}

pub const EventFdError = error{
    SystemResources,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
} || UnexpectedError;

pub fn eventfd(initval: u32, flags: u32) EventFdError!i32 {
    const rc = system.eventfd(initval, flags);
    switch (errno(rc)) {
        0 => return @intCast(i32, rc),
        else => |err| return unexpectedErrno(err),

        EINVAL => unreachable, // invalid parameters
        EMFILE => return error.ProcessFdQuotaExceeded,
        ENFILE => return error.SystemFdQuotaExceeded,
        ENODEV => return error.SystemResources,
        ENOMEM => return error.SystemResources,
    }
}

pub const GetSockNameError = error{
    /// Insufficient resources were available in the system to perform the operation.
    SystemResources,

    /// The network subsystem has failed.
    NetworkSubsystemFailed,

    /// Socket hasn't been bound yet
    SocketNotBound,

    FileDescriptorNotASocket,
} || UnexpectedError;

pub fn getsockname(sock: socket_t, addr: *sockaddr, addrlen: *socklen_t) GetSockNameError!void {
    if (builtin.os.tag == .windows) {
        const rc = windows.getsockname(sock, addr, addrlen);
        if (rc == windows.ws2_32.SOCKET_ERROR) {
            switch (windows.ws2_32.WSAGetLastError()) {
                .WSANOTINITIALISED => unreachable,
                .WSAENETDOWN => return error.NetworkSubsystemFailed,
                .WSAEFAULT => unreachable, // addr or addrlen have invalid pointers or addrlen points to an incorrect value
                .WSAENOTSOCK => return error.FileDescriptorNotASocket,
                .WSAEINVAL => return error.SocketNotBound,
                else => |err| return windows.unexpectedWSAError(err),
            }
        }
        return;
    } else {
        const rc = system.getsockname(sock, addr, addrlen);
        switch (errno(rc)) {
            0 => return,
            else => |err| return unexpectedErrno(err),

            EBADF => unreachable, // always a race condition
            EFAULT => unreachable,
            EINVAL => unreachable, // invalid parameters
            ENOTSOCK => return error.FileDescriptorNotASocket,
            ENOBUFS => return error.SystemResources,
        }
    }
}

pub fn getpeername(sock: socket_t, addr: *sockaddr, addrlen: *socklen_t) GetSockNameError!void {
    if (builtin.os.tag == .windows) {
        const rc = windows.getpeername(sock, addr, addrlen);
        if (rc == windows.ws2_32.SOCKET_ERROR) {
            switch (windows.ws2_32.WSAGetLastError()) {
                .WSANOTINITIALISED => unreachable,
                .WSAENETDOWN => return error.NetworkSubsystemFailed,
                .WSAEFAULT => unreachable, // addr or addrlen have invalid pointers or addrlen points to an incorrect value
                .WSAENOTSOCK => return error.FileDescriptorNotASocket,
                .WSAEINVAL => return error.SocketNotBound,
                else => |err| return windows.unexpectedWSAError(err),
            }
        }
        return;
    } else {
        const rc = system.getpeername(sock, addr, addrlen);
        switch (errno(rc)) {
            0 => return,
            else => |err| return unexpectedErrno(err),

            EBADF => unreachable, // always a race condition
            EFAULT => unreachable,
            EINVAL => unreachable, // invalid parameters
            ENOTSOCK => return error.FileDescriptorNotASocket,
            ENOBUFS => return error.SystemResources,
        }
    }
}

pub const ConnectError = error{
    /// For UNIX domain sockets, which are identified by pathname: Write permission is denied on  the  socket
    /// file,  or  search  permission  is  denied  for  one of the directories in the path prefix.
    /// or
    /// The user tried to connect to a broadcast address without having the socket broadcast flag enabled  or
    /// the connection request failed because of a local firewall rule.
    PermissionDenied,

    /// Local address is already in use.
    AddressInUse,

    /// (Internet  domain  sockets)  The  socket  referred  to  by sockfd had not previously been bound to an
    /// address and, upon attempting to bind it to an ephemeral port, it was determined that all port numbers
    /// in    the    ephemeral    port    range    are   currently   in   use.    See   the   discussion   of
    /// /proc/sys/net/ipv4/ip_local_port_range in ip(7).
    AddressNotAvailable,

    /// The passed address didn't have the correct address family in its sa_family field.
    AddressFamilyNotSupported,

    /// Insufficient entries in the routing cache.
    SystemResources,

    /// A connect() on a stream socket found no one listening on the remote address.
    ConnectionRefused,

    /// Network is unreachable.
    NetworkUnreachable,

    /// Timeout  while  attempting  connection.   The server may be too busy to accept new connections.  Note
    /// that for IP sockets the timeout may be very long when syncookies are enabled on the server.
    ConnectionTimedOut,

    /// This error occurs when no global event loop is configured,
    /// and connecting to the socket would block.
    WouldBlock,

    /// The given path for the unix socket does not exist.
    FileNotFound,

    /// Connection was reset by peer before connect could complete.
    ConnectionResetByPeer,

    /// Socket is non-blocking and already has a pending connection in progress.
    ConnectionPending,
} || UnexpectedError;

/// Initiate a connection on a socket.
/// If `sockfd` is opened in non blocking mode, the function will
/// return error.WouldBlock when EAGAIN or EINPROGRESS is received.
pub fn connect(sock: socket_t, sock_addr: *const sockaddr, len: socklen_t) ConnectError!void {
    if (builtin.os.tag == .windows) {
        const rc = windows.ws2_32.connect(sock, sock_addr, @intCast(i32, len));
        if (rc == 0) return;
        switch (windows.ws2_32.WSAGetLastError()) {
            .WSAEADDRINUSE => return error.AddressInUse,
            .WSAEADDRNOTAVAIL => return error.AddressNotAvailable,
            .WSAECONNREFUSED => return error.ConnectionRefused,
            .WSAECONNRESET => return error.ConnectionResetByPeer,
            .WSAETIMEDOUT => return error.ConnectionTimedOut,
            .WSAEHOSTUNREACH, // TODO: should we return NetworkUnreachable in this case as well?
            .WSAENETUNREACH,
            => return error.NetworkUnreachable,
            .WSAEFAULT => unreachable,
            .WSAEINVAL => unreachable,
            .WSAEISCONN => unreachable,
            .WSAENOTSOCK => unreachable,
            .WSAEWOULDBLOCK => unreachable,
            .WSAEACCES => unreachable,
            .WSAENOBUFS => return error.SystemResources,
            .WSAEAFNOSUPPORT => return error.AddressFamilyNotSupported,
            else => |err| return windows.unexpectedWSAError(err),
        }
        return;
    }

    while (true) {
        switch (errno(system.connect(sock, sock_addr, len))) {
            0 => return,
            EACCES => return error.PermissionDenied,
            EPERM => return error.PermissionDenied,
            EADDRINUSE => return error.AddressInUse,
            EADDRNOTAVAIL => return error.AddressNotAvailable,
            EAFNOSUPPORT => return error.AddressFamilyNotSupported,
            EAGAIN, EINPROGRESS => return error.WouldBlock,
            EALREADY => return error.ConnectionPending,
            EBADF => unreachable, // sockfd is not a valid open file descriptor.
            ECONNREFUSED => return error.ConnectionRefused,
            ECONNRESET => return error.ConnectionResetByPeer,
            EFAULT => unreachable, // The socket structure address is outside the user's address space.
            EINTR => continue,
            EISCONN => unreachable, // The socket is already connected.
            ENETUNREACH => return error.NetworkUnreachable,
            ENOTSOCK => unreachable, // The file descriptor sockfd does not refer to a socket.
            EPROTOTYPE => unreachable, // The socket type does not support the requested communications protocol.
            ETIMEDOUT => return error.ConnectionTimedOut,
            ENOENT => return error.FileNotFound, // Returned when socket is AF_UNIX and the given path does not exist.
            else => |err| return unexpectedErrno(err),
        }
    }
}

pub fn getsockoptError(sockfd: fd_t) ConnectError!void {
    var err_code: u32 = undefined;
    var size: u32 = @sizeOf(u32);
    const rc = system.getsockopt(sockfd, SOL_SOCKET, SO_ERROR, @ptrCast([*]u8, &err_code), &size);
    assert(size == 4);
    switch (errno(rc)) {
        0 => switch (err_code) {
            0 => return,
            EACCES => return error.PermissionDenied,
            EPERM => return error.PermissionDenied,
            EADDRINUSE => return error.AddressInUse,
            EADDRNOTAVAIL => return error.AddressNotAvailable,
            EAFNOSUPPORT => return error.AddressFamilyNotSupported,
            EAGAIN => return error.SystemResources,
            EALREADY => return error.ConnectionPending,
            EBADF => unreachable, // sockfd is not a valid open file descriptor.
            ECONNREFUSED => return error.ConnectionRefused,
            EFAULT => unreachable, // The socket structure address is outside the user's address space.
            EISCONN => unreachable, // The socket is already connected.
            ENETUNREACH => return error.NetworkUnreachable,
            ENOTSOCK => unreachable, // The file descriptor sockfd does not refer to a socket.
            EPROTOTYPE => unreachable, // The socket type does not support the requested communications protocol.
            ETIMEDOUT => return error.ConnectionTimedOut,
            ECONNRESET => return error.ConnectionResetByPeer,
            else => |err| return unexpectedErrno(err),
        },
        EBADF => unreachable, // The argument sockfd is not a valid file descriptor.
        EFAULT => unreachable, // The address pointed to by optval or optlen is not in a valid part of the process address space.
        EINVAL => unreachable,
        ENOPROTOOPT => unreachable, // The option is unknown at the level indicated.
        ENOTSOCK => unreachable, // The file descriptor sockfd does not refer to a socket.
        else => |err| return unexpectedErrno(err),
    }
}

pub const WaitPidResult = struct {
    pid: pid_t,
    status: u32,
};

pub fn waitpid(pid: pid_t, flags: u32) WaitPidResult {
    const Status = if (builtin.link_libc) c_int else u32;
    var status: Status = undefined;
    while (true) {
        const rc = system.waitpid(pid, &status, if (builtin.link_libc) @intCast(c_int, flags) else flags);
        switch (errno(rc)) {
            0 => return .{
                .pid = @intCast(pid_t, rc),
                .status = @bitCast(u32, status),
            },
            EINTR => continue,
            ECHILD => unreachable, // The process specified does not exist. It would be a race condition to handle this error.
            EINVAL => unreachable, // Invalid flags.
            else => unreachable,
        }
    }
}

pub const Stat = if (builtin.link_libc)
    system.libc_stat
else
    system.kernel_stat;

pub const FStatError = error{
    SystemResources,

    /// In WASI, this error may occur when the file descriptor does
    /// not hold the required rights to get its filestat information.
    AccessDenied,
} || UnexpectedError;

/// Return information about a file descriptor.
pub fn fstat(fd: fd_t) FStatError!Stat {
    if (builtin.os.tag == .wasi) {
        var stat: wasi.filestat_t = undefined;
        switch (wasi.fd_filestat_get(fd, &stat)) {
            wasi.ESUCCESS => return Stat.fromFilestat(stat),
            wasi.EINVAL => unreachable,
            wasi.EBADF => unreachable, // Always a race condition.
            wasi.ENOMEM => return error.SystemResources,
            wasi.EACCES => return error.AccessDenied,
            wasi.ENOTCAPABLE => return error.AccessDenied,
            else => |err| return unexpectedErrno(err),
        }
    }
    if (builtin.os.tag == .windows) {
        @compileError("fstat is not yet implemented on Windows");
    }

    const fstat_sym = if (builtin.os.tag == .linux and builtin.link_libc)
        system.fstat64
    else
        system.fstat;

    var stat = mem.zeroes(Stat);
    switch (errno(fstat_sym(fd, &stat))) {
        0 => return stat,
        EINVAL => unreachable,
        EBADF => unreachable, // Always a race condition.
        ENOMEM => return error.SystemResources,
        EACCES => return error.AccessDenied,
        else => |err| return unexpectedErrno(err),
    }
}

pub const FStatAtError = FStatError || error{ NameTooLong, FileNotFound, SymLinkLoop };

/// Similar to `fstat`, but returns stat of a resource pointed to by `pathname`
/// which is relative to `dirfd` handle.
/// See also `fstatatZ` and `fstatatWasi`.
pub fn fstatat(dirfd: fd_t, pathname: []const u8, flags: u32) FStatAtError!Stat {
    if (builtin.os.tag == .wasi) {
        return fstatatWasi(dirfd, pathname, flags);
    } else if (builtin.os.tag == .windows) {
        @compileError("fstatat is not yet implemented on Windows");
    } else {
        const pathname_c = try toPosixPath(pathname);
        return fstatatZ(dirfd, &pathname_c, flags);
    }
}

pub const fstatatC = @compileError("deprecated: renamed to fstatatZ");

/// WASI-only. Same as `fstatat` but targeting WASI.
/// See also `fstatat`.
pub fn fstatatWasi(dirfd: fd_t, pathname: []const u8, flags: u32) FStatAtError!Stat {
    var stat: wasi.filestat_t = undefined;
    switch (wasi.path_filestat_get(dirfd, flags, pathname.ptr, pathname.len, &stat)) {
        wasi.ESUCCESS => return Stat.fromFilestat(stat),
        wasi.EINVAL => unreachable,
        wasi.EBADF => unreachable, // Always a race condition.
        wasi.ENOMEM => return error.SystemResources,
        wasi.EACCES => return error.AccessDenied,
        wasi.EFAULT => unreachable,
        wasi.ENAMETOOLONG => return error.NameTooLong,
        wasi.ENOENT => return error.FileNotFound,
        wasi.ENOTDIR => return error.FileNotFound,
        wasi.ENOTCAPABLE => return error.AccessDenied,
        else => |err| return unexpectedErrno(err),
    }
}

/// Same as `fstatat` but `pathname` is null-terminated.
/// See also `fstatat`.
pub fn fstatatZ(dirfd: fd_t, pathname: [*:0]const u8, flags: u32) FStatAtError!Stat {
    const fstatat_sym = if (builtin.os.tag == .linux and builtin.link_libc)
        system.fstatat64
    else
        system.fstatat;

    var stat = mem.zeroes(Stat);
    switch (errno(fstatat_sym(dirfd, pathname, &stat, flags))) {
        0 => return stat,
        EINVAL => unreachable,
        EBADF => unreachable, // Always a race condition.
        ENOMEM => return error.SystemResources,
        EACCES => return error.AccessDenied,
        EPERM => return error.AccessDenied,
        EFAULT => unreachable,
        ENAMETOOLONG => return error.NameTooLong,
        ELOOP => return error.SymLinkLoop,
        ENOENT => return error.FileNotFound,
        ENOTDIR => return error.FileNotFound,
        else => |err| return unexpectedErrno(err),
    }
}

pub const KQueueError = error{
    /// The per-process limit on the number of open file descriptors has been reached.
    ProcessFdQuotaExceeded,

    /// The system-wide limit on the total number of open files has been reached.
    SystemFdQuotaExceeded,
} || UnexpectedError;

pub fn kqueue() KQueueError!i32 {
    const rc = system.kqueue();
    switch (errno(rc)) {
        0 => return @intCast(i32, rc),
        EMFILE => return error.ProcessFdQuotaExceeded,
        ENFILE => return error.SystemFdQuotaExceeded,
        else => |err| return unexpectedErrno(err),
    }
}

pub const KEventError = error{
    /// The process does not have permission to register a filter.
    AccessDenied,

    /// The event could not be found to be modified or deleted.
    EventNotFound,

    /// No memory was available to register the event.
    SystemResources,

    /// The specified process to attach to does not exist.
    ProcessNotFound,

    /// changelist or eventlist had too many items on it.
    /// TODO remove this possibility
    Overflow,
};

pub fn kevent(
    kq: i32,
    changelist: []const Kevent,
    eventlist: []Kevent,
    timeout: ?*const timespec,
) KEventError!usize {
    while (true) {
        const rc = system.kevent(
            kq,
            changelist.ptr,
            try math.cast(c_int, changelist.len),
            eventlist.ptr,
            try math.cast(c_int, eventlist.len),
            timeout,
        );
        switch (errno(rc)) {
            0 => return @intCast(usize, rc),
            EACCES => return error.AccessDenied,
            EFAULT => unreachable,
            EBADF => unreachable, // Always a race condition.
            EINTR => continue,
            EINVAL => unreachable,
            ENOENT => return error.EventNotFound,
            ENOMEM => return error.SystemResources,
            ESRCH => return error.ProcessNotFound,
            else => unreachable,
        }
    }
}

pub const INotifyInitError = error{
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
} || UnexpectedError;

/// initialize an inotify instance
pub fn inotify_init1(flags: u32) INotifyInitError!i32 {
    const rc = system.inotify_init1(flags);
    switch (errno(rc)) {
        0 => return @intCast(i32, rc),
        EINVAL => unreachable,
        EMFILE => return error.ProcessFdQuotaExceeded,
        ENFILE => return error.SystemFdQuotaExceeded,
        ENOMEM => return error.SystemResources,
        else => |err| return unexpectedErrno(err),
    }
}

pub const INotifyAddWatchError = error{
    AccessDenied,
    NameTooLong,
    FileNotFound,
    SystemResources,
    UserResourceLimitReached,
} || UnexpectedError;

/// add a watch to an initialized inotify instance
pub fn inotify_add_watch(inotify_fd: i32, pathname: []const u8, mask: u32) INotifyAddWatchError!i32 {
    const pathname_c = try toPosixPath(pathname);
    return inotify_add_watchZ(inotify_fd, &pathname_c, mask);
}

pub const inotify_add_watchC = @compileError("deprecated: renamed to inotify_add_watchZ");

/// Same as `inotify_add_watch` except pathname is null-terminated.
pub fn inotify_add_watchZ(inotify_fd: i32, pathname: [*:0]const u8, mask: u32) INotifyAddWatchError!i32 {
    const rc = system.inotify_add_watch(inotify_fd, pathname, mask);
    switch (errno(rc)) {
        0 => return @intCast(i32, rc),
        EACCES => return error.AccessDenied,
        EBADF => unreachable,
        EFAULT => unreachable,
        EINVAL => unreachable,
        ENAMETOOLONG => return error.NameTooLong,
        ENOENT => return error.FileNotFound,
        ENOMEM => return error.SystemResources,
        ENOSPC => return error.UserResourceLimitReached,
        else => |err| return unexpectedErrno(err),
    }
}

/// remove an existing watch from an inotify instance
pub fn inotify_rm_watch(inotify_fd: i32, wd: i32) void {
    switch (errno(system.inotify_rm_watch(inotify_fd, wd))) {
        0 => return,
        EBADF => unreachable,
        EINVAL => unreachable,
        else => unreachable,
    }
}

pub const MProtectError = error{
    /// The memory cannot be given the specified access.  This can happen, for example, if you
    /// mmap(2)  a  file  to  which  you have read-only access, then ask mprotect() to mark it
    /// PROT_WRITE.
    AccessDenied,

    /// Changing  the  protection  of a memory region would result in the total number of map‐
    /// pings with distinct attributes (e.g., read versus read/write protection) exceeding the
    /// allowed maximum.  (For example, making the protection of a range PROT_READ in the mid‐
    /// dle of a region currently protected as PROT_READ|PROT_WRITE would result in three map‐
    /// pings: two read/write mappings at each end and a read-only mapping in the middle.)
    OutOfMemory,
} || UnexpectedError;

/// `memory.len` must be page-aligned.
pub fn mprotect(memory: []align(mem.page_size) u8, protection: u32) MProtectError!void {
    assert(mem.isAligned(memory.len, mem.page_size));
    switch (errno(system.mprotect(memory.ptr, memory.len, protection))) {
        0 => return,
        EINVAL => unreachable,
        EACCES => return error.AccessDenied,
        ENOMEM => return error.OutOfMemory,
        else => |err| return unexpectedErrno(err),
    }
}

pub const ForkError = error{SystemResources} || UnexpectedError;

pub fn fork() ForkError!pid_t {
    const rc = system.fork();
    switch (errno(rc)) {
        0 => return @intCast(pid_t, rc),
        EAGAIN => return error.SystemResources,
        ENOMEM => return error.SystemResources,
        else => |err| return unexpectedErrno(err),
    }
}

pub const MMapError = error{
    /// The underlying filesystem of the specified file does not support memory mapping.
    MemoryMappingNotSupported,

    /// A file descriptor refers to a non-regular file. Or a file mapping was requested,
    /// but the file descriptor is not open for reading. Or `MAP_SHARED` was requested
    /// and `PROT_WRITE` is set, but the file descriptor is not open in `O_RDWR` mode.
    /// Or `PROT_WRITE` is set, but the file is append-only.
    AccessDenied,

    /// The `prot` argument asks for `PROT_EXEC` but the mapped area belongs to a file on
    /// a filesystem that was mounted no-exec.
    PermissionDenied,
    LockedMemoryLimitExceeded,
    OutOfMemory,
} || UnexpectedError;

/// Map files or devices into memory.
/// `length` does not need to be aligned.
/// Use of a mapped region can result in these signals:
/// * SIGSEGV - Attempted write into a region mapped as read-only.
/// * SIGBUS - Attempted  access to a portion of the buffer that does not correspond to the file
pub fn mmap(
    ptr: ?[*]align(mem.page_size) u8,
    length: usize,
    prot: u32,
    flags: u32,
    fd: fd_t,
    offset: u64,
) MMapError![]align(mem.page_size) u8 {
    const mmap_sym = if (builtin.os.tag == .linux and builtin.link_libc)
        system.mmap64
    else
        system.mmap;

    const ioffset = @bitCast(i64, offset); // the OS treats this as unsigned
    const rc = mmap_sym(ptr, length, prot, flags, fd, ioffset);
    const err = if (builtin.link_libc) blk: {
        if (rc != std.c.MAP_FAILED) return @ptrCast([*]align(mem.page_size) u8, @alignCast(mem.page_size, rc))[0..length];
        break :blk system._errno().*;
    } else blk: {
        const err = errno(rc);
        if (err == 0) return @intToPtr([*]align(mem.page_size) u8, rc)[0..length];
        break :blk err;
    };
    switch (err) {
        ETXTBSY => return error.AccessDenied,
        EACCES => return error.AccessDenied,
        EPERM => return error.PermissionDenied,
        EAGAIN => return error.LockedMemoryLimitExceeded,
        EBADF => unreachable, // Always a race condition.
        EOVERFLOW => unreachable, // The number of pages used for length + offset would overflow.
        ENODEV => return error.MemoryMappingNotSupported,
        EINVAL => unreachable, // Invalid parameters to mmap()
        ENOMEM => return error.OutOfMemory,
        else => return unexpectedErrno(err),
    }
}

/// Deletes the mappings for the specified address range, causing
/// further references to addresses within the range to generate invalid memory references.
/// Note that while POSIX allows unmapping a region in the middle of an existing mapping,
/// Zig's munmap function does not, for two reasons:
/// * It violates the Zig principle that resource deallocation must succeed.
/// * The Windows function, VirtualFree, has this restriction.
pub fn munmap(memory: []align(mem.page_size) const u8) void {
    switch (errno(system.munmap(memory.ptr, memory.len))) {
        0 => return,
        EINVAL => unreachable, // Invalid parameters.
        ENOMEM => unreachable, // Attempted to unmap a region in the middle of an existing mapping.
        else => unreachable,
    }
}

pub const AccessError = error{
    PermissionDenied,
    FileNotFound,
    NameTooLong,
    InputOutput,
    SystemResources,
    BadPathName,
    FileBusy,
    SymLinkLoop,
    ReadOnlyFileSystem,

    /// On Windows, file paths must be valid Unicode.
    InvalidUtf8,
} || UnexpectedError;

/// check user's permissions for a file
/// TODO currently this assumes `mode` is `F_OK` on Windows.
pub fn access(path: []const u8, mode: u32) AccessError!void {
    if (builtin.os.tag == .windows) {
        const path_w = try windows.sliceToPrefixedFileW(path);
        _ = try windows.GetFileAttributesW(path_w.span().ptr);
        return;
    }
    const path_c = try toPosixPath(path);
    return accessZ(&path_c, mode);
}

pub const accessC = @compileError("Deprecated in favor of `accessZ`");

/// Same as `access` except `path` is null-terminated.
pub fn accessZ(path: [*:0]const u8, mode: u32) AccessError!void {
    if (builtin.os.tag == .windows) {
        const path_w = try windows.cStrToPrefixedFileW(path);
        _ = try windows.GetFileAttributesW(path_w.span().ptr);
        return;
    }
    switch (errno(system.access(path, mode))) {
        0 => return,
        EACCES => return error.PermissionDenied,
        EROFS => return error.ReadOnlyFileSystem,
        ELOOP => return error.SymLinkLoop,
        ETXTBSY => return error.FileBusy,
        ENOTDIR => return error.FileNotFound,
        ENOENT => return error.FileNotFound,
        ENAMETOOLONG => return error.NameTooLong,
        EINVAL => unreachable,
        EFAULT => unreachable,
        EIO => return error.InputOutput,
        ENOMEM => return error.SystemResources,
        else => |err| return unexpectedErrno(err),
    }
}

/// Call from Windows-specific code if you already have a UTF-16LE encoded, null terminated string.
/// Otherwise use `access` or `accessC`.
/// TODO currently this ignores `mode`.
pub fn accessW(path: [*:0]const u16, mode: u32) windows.GetFileAttributesError!void {
    _ = mode;
    const ret = try windows.GetFileAttributesW(path);
    if (ret != windows.INVALID_FILE_ATTRIBUTES) {
        return;
    }
    switch (windows.kernel32.GetLastError()) {
        .FILE_NOT_FOUND => return error.FileNotFound,
        .PATH_NOT_FOUND => return error.FileNotFound,
        .ACCESS_DENIED => return error.PermissionDenied,
        else => |err| return windows.unexpectedError(err),
    }
}

/// Check user's permissions for a file, based on an open directory handle.
/// TODO currently this ignores `mode` and `flags` on Windows.
pub fn faccessat(dirfd: fd_t, path: []const u8, mode: u32, flags: u32) AccessError!void {
    if (builtin.os.tag == .windows) {
        const path_w = try windows.sliceToPrefixedFileW(path);
        return faccessatW(dirfd, path_w.span().ptr, mode, flags);
    }
    const path_c = try toPosixPath(path);
    return faccessatZ(dirfd, &path_c, mode, flags);
}

/// Same as `faccessat` except the path parameter is null-terminated.
pub fn faccessatZ(dirfd: fd_t, path: [*:0]const u8, mode: u32, flags: u32) AccessError!void {
    if (builtin.os.tag == .windows) {
        const path_w = try windows.cStrToPrefixedFileW(path);
        return faccessatW(dirfd, path_w.span().ptr, mode, flags);
    }
    switch (errno(system.faccessat(dirfd, path, mode, flags))) {
        0 => return,
        EACCES => return error.PermissionDenied,
        EROFS => return error.ReadOnlyFileSystem,
        ELOOP => return error.SymLinkLoop,
        ETXTBSY => return error.FileBusy,
        ENOTDIR => return error.FileNotFound,
        ENOENT => return error.FileNotFound,
        ENAMETOOLONG => return error.NameTooLong,
        EINVAL => unreachable,
        EFAULT => unreachable,
        EIO => return error.InputOutput,
        ENOMEM => return error.SystemResources,
        else => |err| return unexpectedErrno(err),
    }
}

/// Same as `faccessat` except asserts the target is Windows and the path parameter
/// is NtDll-prefixed, null-terminated, WTF-16 encoded.
/// TODO currently this ignores `mode` and `flags`
pub fn faccessatW(dirfd: fd_t, sub_path_w: [*:0]const u16, mode: u32, flags: u32) AccessError!void {
    _ = mode;
    _ = flags;
    if (sub_path_w[0] == '.' and sub_path_w[1] == 0) {
        return;
    }
    if (sub_path_w[0] == '.' and sub_path_w[1] == '.' and sub_path_w[2] == 0) {
        return;
    }

    const path_len_bytes = math.cast(u16, mem.lenZ(sub_path_w) * 2) catch |err| switch (err) {
        error.Overflow => return error.NameTooLong,
    };
    var nt_name = windows.UNICODE_STRING{
        .Length = path_len_bytes,
        .MaximumLength = path_len_bytes,
        .Buffer = @intToPtr([*]u16, @ptrToInt(sub_path_w)),
    };
    var attr = windows.OBJECT_ATTRIBUTES{
        .Length = @sizeOf(windows.OBJECT_ATTRIBUTES),
        .RootDirectory = if (std.fs.path.isAbsoluteWindowsW(sub_path_w)) null else dirfd,
        .Attributes = 0, // Note we do not use OBJ_CASE_INSENSITIVE here.
        .ObjectName = &nt_name,
        .SecurityDescriptor = null,
        .SecurityQualityOfService = null,
    };
    var basic_info: windows.FILE_BASIC_INFORMATION = undefined;
    switch (windows.ntdll.NtQueryAttributesFile(&attr, &basic_info)) {
        .SUCCESS => return,
        .OBJECT_NAME_NOT_FOUND => return error.FileNotFound,
        .OBJECT_PATH_NOT_FOUND => return error.FileNotFound,
        .OBJECT_NAME_INVALID => unreachable,
        .INVALID_PARAMETER => unreachable,
        .ACCESS_DENIED => return error.PermissionDenied,
        .OBJECT_PATH_SYNTAX_BAD => unreachable,
        else => |rc| return windows.unexpectedStatus(rc),
    }
}

pub const PipeError = error{
    SystemFdQuotaExceeded,
    ProcessFdQuotaExceeded,
} || UnexpectedError;

/// Creates a unidirectional data channel that can be used for interprocess communication.
pub fn pipe() PipeError![2]fd_t {
    var fds: [2]fd_t = undefined;
    switch (errno(system.pipe(&fds))) {
        0 => return fds,
        EINVAL => unreachable, // Invalid parameters to pipe()
        EFAULT => unreachable, // Invalid fds pointer
        ENFILE => return error.SystemFdQuotaExceeded,
        EMFILE => return error.ProcessFdQuotaExceeded,
        else => |err| return unexpectedErrno(err),
    }
}

pub fn pipe2(flags: u32) PipeError![2]fd_t {
    if (@hasDecl(system, "pipe2")) {
        var fds: [2]fd_t = undefined;
        switch (errno(system.pipe2(&fds, flags))) {
            0 => return fds,
            EINVAL => unreachable, // Invalid flags
            EFAULT => unreachable, // Invalid fds pointer
            ENFILE => return error.SystemFdQuotaExceeded,
            EMFILE => return error.ProcessFdQuotaExceeded,
            else => |err| return unexpectedErrno(err),
        }
    }

    var fds: [2]fd_t = try pipe();
    errdefer {
        close(fds[0]);
        close(fds[1]);
    }

    if (flags == 0)
        return fds;

    // O_CLOEXEC is special, it's a file descriptor flag and must be set using
    // F_SETFD.
    if (flags & O_CLOEXEC != 0) {
        for (fds) |fd| {
            switch (errno(system.fcntl(fd, F_SETFD, @as(u32, FD_CLOEXEC)))) {
                0 => {},
                EINVAL => unreachable, // Invalid flags
                EBADF => unreachable, // Always a race condition
                else => |err| return unexpectedErrno(err),
            }
        }
    }

    const new_flags = flags & ~@as(u32, O_CLOEXEC);
    // Set every other flag affecting the file status using F_SETFL.
    if (new_flags != 0) {
        for (fds) |fd| {
            switch (errno(system.fcntl(fd, F_SETFL, new_flags))) {
                0 => {},
                EINVAL => unreachable, // Invalid flags
                EBADF => unreachable, // Always a race condition
                else => |err| return unexpectedErrno(err),
            }
        }
    }

    return fds;
}

pub const SysCtlError = error{
    PermissionDenied,
    SystemResources,
    NameTooLong,
    UnknownName,
} || UnexpectedError;

pub fn sysctl(
    name: []const c_int,
    oldp: ?*c_void,
    oldlenp: ?*usize,
    newp: ?*c_void,
    newlen: usize,
) SysCtlError!void {
    if (builtin.os.tag == .wasi) {
        @panic("unsupported"); // TODO should be compile error, not panic
    }
    if (builtin.os.tag == .haiku) {
        @panic("unsupported"); // TODO should be compile error, not panic
    }

    const name_len = math.cast(c_uint, name.len) catch return error.NameTooLong;
    switch (errno(system.sysctl(name.ptr, name_len, oldp, oldlenp, newp, newlen))) {
        0 => return,
        EFAULT => unreachable,
        EPERM => return error.PermissionDenied,
        ENOMEM => return error.SystemResources,
        ENOENT => return error.UnknownName,
        else => |err| return unexpectedErrno(err),
    }
}

pub const sysctlbynameC = @compileError("deprecated: renamed to sysctlbynameZ");

pub fn sysctlbynameZ(
    name: [*:0]const u8,
    oldp: ?*c_void,
    oldlenp: ?*usize,
    newp: ?*c_void,
    newlen: usize,
) SysCtlError!void {
    if (builtin.os.tag == .wasi) {
        @panic("unsupported"); // TODO should be compile error, not panic
    }
    if (builtin.os.tag == .haiku) {
        @panic("unsupported"); // TODO should be compile error, not panic
    }

    switch (errno(system.sysctlbyname(name, oldp, oldlenp, newp, newlen))) {
        0 => return,
        EFAULT => unreachable,
        EPERM => return error.PermissionDenied,
        ENOMEM => return error.SystemResources,
        ENOENT => return error.UnknownName,
        else => |err| return unexpectedErrno(err),
    }
}

pub fn gettimeofday(tv: ?*timeval, tz: ?*timezone) void {
    switch (errno(system.gettimeofday(tv, tz))) {
        0 => return,
        EINVAL => unreachable,
        else => unreachable,
    }
}

pub const SeekError = error{
    Unseekable,

    /// In WASI, this error may occur when the file descriptor does
    /// not hold the required rights to seek on it.
    AccessDenied,
} || UnexpectedError;

/// Repositions read/write file offset relative to the beginning.
pub fn lseek_SET(fd: fd_t, offset: u64) SeekError!void {
    if (builtin.os.tag == .linux and !builtin.link_libc and @sizeOf(usize) == 4) {
        var result: u64 = undefined;
        switch (errno(system.llseek(fd, offset, &result, SEEK_SET))) {
            0 => return,
            EBADF => unreachable, // always a race condition
            EINVAL => return error.Unseekable,
            EOVERFLOW => return error.Unseekable,
            ESPIPE => return error.Unseekable,
            ENXIO => return error.Unseekable,
            else => |err| return unexpectedErrno(err),
        }
    }
    if (builtin.os.tag == .windows) {
        return windows.SetFilePointerEx_BEGIN(fd, offset);
    }
    if (builtin.os.tag == .wasi) {
        var new_offset: wasi.filesize_t = undefined;
        switch (wasi.fd_seek(fd, @bitCast(wasi.filedelta_t, offset), wasi.WHENCE_SET, &new_offset)) {
            wasi.ESUCCESS => return,
            wasi.EBADF => unreachable, // always a race condition
            wasi.EINVAL => return error.Unseekable,
            wasi.EOVERFLOW => return error.Unseekable,
            wasi.ESPIPE => return error.Unseekable,
            wasi.ENXIO => return error.Unseekable,
            wasi.ENOTCAPABLE => return error.AccessDenied,
            else => |err| return unexpectedErrno(err),
        }
    }

    const lseek_sym = if (builtin.os.tag == .linux and builtin.link_libc)
        system.lseek64
    else
        system.lseek;

    const ioffset = @bitCast(i64, offset); // the OS treats this as unsigned
    switch (errno(lseek_sym(fd, ioffset, SEEK_SET))) {
        0 => return,
        EBADF => unreachable, // always a race condition
        EINVAL => return error.Unseekable,
        EOVERFLOW => return error.Unseekable,
        ESPIPE => return error.Unseekable,
        ENXIO => return error.Unseekable,
        else => |err| return unexpectedErrno(err),
    }
}

/// Repositions read/write file offset relative to the current offset.
pub fn lseek_CUR(fd: fd_t, offset: i64) SeekError!void {
    if (builtin.os.tag == .linux and !builtin.link_libc and @sizeOf(usize) == 4) {
        var result: u64 = undefined;
        switch (errno(system.llseek(fd, @bitCast(u64, offset), &result, SEEK_CUR))) {
            0 => return,
            EBADF => unreachable, // always a race condition
            EINVAL => return error.Unseekable,
            EOVERFLOW => return error.Unseekable,
            ESPIPE => return error.Unseekable,
            ENXIO => return error.Unseekable,
            else => |err| return unexpectedErrno(err),
        }
    }
    if (builtin.os.tag == .windows) {
        return windows.SetFilePointerEx_CURRENT(fd, offset);
    }
    if (builtin.os.tag == .wasi) {
        var new_offset: wasi.filesize_t = undefined;
        switch (wasi.fd_seek(fd, offset, wasi.WHENCE_CUR, &new_offset)) {
            wasi.ESUCCESS => return,
            wasi.EBADF => unreachable, // always a race condition
            wasi.EINVAL => return error.Unseekable,
            wasi.EOVERFLOW => return error.Unseekable,
            wasi.ESPIPE => return error.Unseekable,
            wasi.ENXIO => return error.Unseekable,
            wasi.ENOTCAPABLE => return error.AccessDenied,
            else => |err| return unexpectedErrno(err),
        }
    }
    const lseek_sym = if (builtin.os.tag == .linux and builtin.link_libc)
        system.lseek64
    else
        system.lseek;

    const ioffset = @bitCast(i64, offset); // the OS treats this as unsigned
    switch (errno(lseek_sym(fd, ioffset, SEEK_CUR))) {
        0 => return,
        EBADF => unreachable, // always a race condition
        EINVAL => return error.Unseekable,
        EOVERFLOW => return error.Unseekable,
        ESPIPE => return error.Unseekable,
        ENXIO => return error.Unseekable,
        else => |err| return unexpectedErrno(err),
    }
}

/// Repositions read/write file offset relative to the end.
pub fn lseek_END(fd: fd_t, offset: i64) SeekError!void {
    if (builtin.os.tag == .linux and !builtin.link_libc and @sizeOf(usize) == 4) {
        var result: u64 = undefined;
        switch (errno(system.llseek(fd, @bitCast(u64, offset), &result, SEEK_END))) {
            0 => return,
            EBADF => unreachable, // always a race condition
            EINVAL => return error.Unseekable,
            EOVERFLOW => return error.Unseekable,
            ESPIPE => return error.Unseekable,
            ENXIO => return error.Unseekable,
            else => |err| return unexpectedErrno(err),
        }
    }
    if (builtin.os.tag == .windows) {
        return windows.SetFilePointerEx_END(fd, offset);
    }
    if (builtin.os.tag == .wasi) {
        var new_offset: wasi.filesize_t = undefined;
        switch (wasi.fd_seek(fd, offset, wasi.WHENCE_END, &new_offset)) {
            wasi.ESUCCESS => return,
            wasi.EBADF => unreachable, // always a race condition
            wasi.EINVAL => return error.Unseekable,
            wasi.EOVERFLOW => return error.Unseekable,
            wasi.ESPIPE => return error.Unseekable,
            wasi.ENXIO => return error.Unseekable,
            wasi.ENOTCAPABLE => return error.AccessDenied,
            else => |err| return unexpectedErrno(err),
        }
    }
    const lseek_sym = if (builtin.os.tag == .linux and builtin.link_libc)
        system.lseek64
    else
        system.lseek;

    const ioffset = @bitCast(i64, offset); // the OS treats this as unsigned
    switch (errno(lseek_sym(fd, ioffset, SEEK_END))) {
        0 => return,
        EBADF => unreachable, // always a race condition
        EINVAL => return error.Unseekable,
        EOVERFLOW => return error.Unseekable,
        ESPIPE => return error.Unseekable,
        ENXIO => return error.Unseekable,
        else => |err| return unexpectedErrno(err),
    }
}

/// Returns the read/write file offset relative to the beginning.
pub fn lseek_CUR_get(fd: fd_t) SeekError!u64 {
    if (builtin.os.tag == .linux and !builtin.link_libc and @sizeOf(usize) == 4) {
        var result: u64 = undefined;
        switch (errno(system.llseek(fd, 0, &result, SEEK_CUR))) {
            0 => return result,
            EBADF => unreachable, // always a race condition
            EINVAL => return error.Unseekable,
            EOVERFLOW => return error.Unseekable,
            ESPIPE => return error.Unseekable,
            ENXIO => return error.Unseekable,
            else => |err| return unexpectedErrno(err),
        }
    }
    if (builtin.os.tag == .windows) {
        return windows.SetFilePointerEx_CURRENT_get(fd);
    }
    if (builtin.os.tag == .wasi) {
        var new_offset: wasi.filesize_t = undefined;
        switch (wasi.fd_seek(fd, 0, wasi.WHENCE_CUR, &new_offset)) {
            wasi.ESUCCESS => return new_offset,
            wasi.EBADF => unreachable, // always a race condition
            wasi.EINVAL => return error.Unseekable,
            wasi.EOVERFLOW => return error.Unseekable,
            wasi.ESPIPE => return error.Unseekable,
            wasi.ENXIO => return error.Unseekable,
            wasi.ENOTCAPABLE => return error.AccessDenied,
            else => |err| return unexpectedErrno(err),
        }
    }
    const lseek_sym = if (builtin.os.tag == .linux and builtin.link_libc)
        system.lseek64
    else
        system.lseek;

    const rc = lseek_sym(fd, 0, SEEK_CUR);
    switch (errno(rc)) {
        0 => return @bitCast(u64, rc),
        EBADF => unreachable, // always a race condition
        EINVAL => return error.Unseekable,
        EOVERFLOW => return error.Unseekable,
        ESPIPE => return error.Unseekable,
        ENXIO => return error.Unseekable,
        else => |err| return unexpectedErrno(err),
    }
}

pub const FcntlError = error{
    PermissionDenied,
    FileBusy,
    ProcessFdQuotaExceeded,
    Locked,
} || UnexpectedError;

pub fn fcntl(fd: fd_t, cmd: i32, arg: usize) FcntlError!usize {
    while (true) {
        const rc = system.fcntl(fd, cmd, arg);
        switch (errno(rc)) {
            0 => return @intCast(usize, rc),
            EINTR => continue,
            EACCES => return error.Locked,
            EBADF => unreachable,
            EBUSY => return error.FileBusy,
            EINVAL => unreachable, // invalid parameters
            EPERM => return error.PermissionDenied,
            EMFILE => return error.ProcessFdQuotaExceeded,
            ENOTDIR => unreachable, // invalid parameter
            else => |err| return unexpectedErrno(err),
        }
    }
}

fn setSockFlags(sock: socket_t, flags: u32) !void {
    if ((flags & SOCK_CLOEXEC) != 0) {
        if (builtin.os.tag == .windows) {
            // TODO: Find out if this is supported for sockets
        } else {
            var fd_flags = fcntl(sock, F_GETFD, 0) catch |err| switch (err) {
                error.FileBusy => unreachable,
                error.Locked => unreachable,
                error.PermissionDenied => unreachable,
                else => |e| return e,
            };
            fd_flags |= FD_CLOEXEC;
            _ = fcntl(sock, F_SETFD, fd_flags) catch |err| switch (err) {
                error.FileBusy => unreachable,
                error.Locked => unreachable,
                error.PermissionDenied => unreachable,
                else => |e| return e,
            };
        }
    }
    if ((flags & SOCK_NONBLOCK) != 0) {
        if (builtin.os.tag == .windows) {
            var mode: c_ulong = 1;
            if (windows.ws2_32.ioctlsocket(sock, windows.ws2_32.FIONBIO, &mode) == windows.ws2_32.SOCKET_ERROR) {
                switch (windows.ws2_32.WSAGetLastError()) {
                    .WSANOTINITIALISED => unreachable,
                    .WSAENETDOWN => return error.NetworkSubsystemFailed,
                    .WSAENOTSOCK => return error.FileDescriptorNotASocket,
                    // TODO: handle more errors
                    else => |err| return windows.unexpectedWSAError(err),
                }
            }
        } else {
            var fl_flags = fcntl(sock, F_GETFL, 0) catch |err| switch (err) {
                error.FileBusy => unreachable,
                error.Locked => unreachable,
                error.PermissionDenied => unreachable,
                else => |e| return e,
            };
            fl_flags |= O_NONBLOCK;
            _ = fcntl(sock, F_SETFL, fl_flags) catch |err| switch (err) {
                error.FileBusy => unreachable,
                error.Locked => unreachable,
                error.PermissionDenied => unreachable,
                else => |e| return e,
            };
        }
    }
}

pub const FlockError = error{
    WouldBlock,

    /// The kernel ran out of memory for allocating file locks
    SystemResources,
} || UnexpectedError;

pub fn flock(fd: fd_t, operation: i32) FlockError!void {
    while (true) {
        const rc = system.flock(fd, operation);
        switch (errno(rc)) {
            0 => return,
            EBADF => unreachable,
            EINTR => continue,
            EINVAL => unreachable, // invalid parameters
            ENOLCK => return error.SystemResources,
            EWOULDBLOCK => return error.WouldBlock, // TODO: integrate with async instead of just returning an error
            else => |err| return unexpectedErrno(err),
        }
    }
}

pub const RealPathError = error{
    FileNotFound,
    AccessDenied,
    NameTooLong,
    NotSupported,
    NotDir,
    SymLinkLoop,
    InputOutput,
    FileTooBig,
    IsDir,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    NoDevice,
    SystemResources,
    NoSpaceLeft,
    FileSystem,
    BadPathName,
    DeviceBusy,

    SharingViolation,
    PipeBusy,

    /// On Windows, file paths must be valid Unicode.
    InvalidUtf8,

    PathAlreadyExists,
} || UnexpectedError;

/// Return the canonicalized absolute pathname.
/// Expands all symbolic links and resolves references to `.`, `..`, and
/// extra `/` characters in `pathname`.
/// The return value is a slice of `out_buffer`, but not necessarily from the beginning.
/// See also `realpathZ` and `realpathW`.
pub fn realpath(pathname: []const u8, out_buffer: *[MAX_PATH_BYTES]u8) RealPathError![]u8 {
    if (builtin.os.tag == .windows) {
        const pathname_w = try windows.sliceToPrefixedFileW(pathname);
        return realpathW(pathname_w.span(), out_buffer);
    }
    if (builtin.os.tag == .wasi) {
        @compileError("Use std.fs.wasi.PreopenList to obtain valid Dir handles instead of using absolute paths");
    }
    const pathname_c = try toPosixPath(pathname);
    return realpathZ(&pathname_c, out_buffer);
}

pub const realpathC = @compileError("deprecated: renamed realpathZ");

/// Same as `realpath` except `pathname` is null-terminated.
pub fn realpathZ(pathname: [*:0]const u8, out_buffer: *[MAX_PATH_BYTES]u8) RealPathError![]u8 {
    if (builtin.os.tag == .windows) {
        const pathname_w = try windows.cStrToPrefixedFileW(pathname);
        return realpathW(pathname_w.span(), out_buffer);
    }
    if (!builtin.link_libc) {
        const flags = if (builtin.os.tag == .linux) O_PATH | O_NONBLOCK | O_CLOEXEC else O_NONBLOCK | O_CLOEXEC;
        const fd = openZ(pathname, flags, 0) catch |err| switch (err) {
            error.FileLocksNotSupported => unreachable,
            error.WouldBlock => unreachable,
            else => |e| return e,
        };
        defer close(fd);

        return getFdPath(fd, out_buffer);
    }
    const result_path = std.c.realpath(pathname, out_buffer) orelse switch (std.c._errno().*) {
        EINVAL => unreachable,
        EBADF => unreachable,
        EFAULT => unreachable,
        EACCES => return error.AccessDenied,
        ENOENT => return error.FileNotFound,
        ENOTSUP => return error.NotSupported,
        ENOTDIR => return error.NotDir,
        ENAMETOOLONG => return error.NameTooLong,
        ELOOP => return error.SymLinkLoop,
        EIO => return error.InputOutput,
        else => |err| return unexpectedErrno(err),
    };
    return mem.spanZ(result_path);
}

/// Same as `realpath` except `pathname` is UTF16LE-encoded.
pub fn realpathW(pathname: []const u16, out_buffer: *[MAX_PATH_BYTES]u8) RealPathError![]u8 {
    const w = windows;

    const dir = std.fs.cwd().fd;
    const access_mask = w.GENERIC_READ | w.SYNCHRONIZE;
    const share_access = w.FILE_SHARE_READ;
    const creation = w.FILE_OPEN;
    const h_file = blk: {
        const res = w.OpenFile(pathname, .{
            .dir = dir,
            .access_mask = access_mask,
            .share_access = share_access,
            .creation = creation,
            .io_mode = .blocking,
        }) catch |err| switch (err) {
            error.IsDir => break :blk w.OpenFile(pathname, .{
                .dir = dir,
                .access_mask = access_mask,
                .share_access = share_access,
                .creation = creation,
                .io_mode = .blocking,
                .open_dir = true,
            }) catch |er| switch (er) {
                error.WouldBlock => unreachable,
                else => |e2| return e2,
            },
            error.WouldBlock => unreachable,
            else => |e| return e,
        };
        break :blk res;
    };
    defer w.CloseHandle(h_file);

    return getFdPath(h_file, out_buffer);
}

/// Return canonical path of handle `fd`.
/// This function is very host-specific and is not universally supported by all hosts.
/// For example, while it generally works on Linux, macOS or Windows, it is unsupported
/// on FreeBSD, or WASI.
pub fn getFdPath(fd: fd_t, out_buffer: *[MAX_PATH_BYTES]u8) RealPathError![]u8 {
    switch (builtin.os.tag) {
        .windows => {
            var wide_buf: [windows.PATH_MAX_WIDE]u16 = undefined;
            const wide_slice = try windows.GetFinalPathNameByHandle(fd, .{}, wide_buf[0..]);

            // Trust that Windows gives us valid UTF-16LE.
            const end_index = std.unicode.utf16leToUtf8(out_buffer, wide_slice) catch unreachable;
            return out_buffer[0..end_index];
        },
        .macos, .ios, .watchos, .tvos => {
            // On macOS, we can use F_GETPATH fcntl command to query the OS for
            // the path to the file descriptor.
            @memset(out_buffer, 0, MAX_PATH_BYTES);
            switch (errno(system.fcntl(fd, F_GETPATH, out_buffer))) {
                0 => {},
                EBADF => return error.FileNotFound,
                // TODO man pages for fcntl on macOS don't really tell you what
                // errno values to expect when command is F_GETPATH...
                else => |err| return unexpectedErrno(err),
            }
            const len = mem.indexOfScalar(u8, out_buffer[0..], @as(u8, 0)) orelse MAX_PATH_BYTES;
            return out_buffer[0..len];
        },
        .linux => {
            var procfs_buf: ["/proc/self/fd/-2147483648".len:0]u8 = undefined;
            const proc_path = std.fmt.bufPrint(procfs_buf[0..], "/proc/self/fd/{d}\x00", .{fd}) catch unreachable;

            const target = readlinkZ(std.meta.assumeSentinel(proc_path.ptr, 0), out_buffer) catch |err| {
                switch (err) {
                    error.UnsupportedReparsePointType => unreachable, // Windows only,
                    else => |e| return e,
                }
            };
            return target;
        },
        else => @compileError("querying for canonical path of a handle is unsupported on this host"),
    }
}

/// Spurious wakeups are possible and no precision of timing is guaranteed.
pub fn nanosleep(seconds: u64, nanoseconds: u64) void {
    var req = timespec{
        .tv_sec = math.cast(isize, seconds) catch math.maxInt(isize),
        .tv_nsec = math.cast(isize, nanoseconds) catch math.maxInt(isize),
    };
    var rem: timespec = undefined;
    while (true) {
        switch (errno(system.nanosleep(&req, &rem))) {
            EFAULT => unreachable,
            EINVAL => {
                // Sometimes Darwin returns EINVAL for no reason.
                // We treat it as a spurious wakeup.
                return;
            },
            EINTR => {
                req = rem;
                continue;
            },
            // This prong handles success as well as unexpected errors.
            else => return,
        }
    }
}

pub fn dl_iterate_phdr(
    context: anytype,
    comptime Error: type,
    comptime callback: fn (info: *dl_phdr_info, size: usize, context: @TypeOf(context)) Error!void,
) Error!void {
    const Context = @TypeOf(context);

    if (builtin.object_format != .elf)
        @compileError("dl_iterate_phdr is not available for this target");

    if (builtin.link_libc) {
        switch (system.dl_iterate_phdr(struct {
            fn callbackC(info: *dl_phdr_info, size: usize, data: ?*c_void) callconv(.C) c_int {
                const context_ptr = @ptrCast(*const Context, @alignCast(@alignOf(*const Context), data));
                callback(info, size, context_ptr.*) catch |err| return @errorToInt(err);
                return 0;
            }
        }.callbackC, @intToPtr(?*c_void, @ptrToInt(&context)))) {
            0 => return,
            else => |err| return @errSetCast(Error, @intToError(@intCast(u16, err))), // TODO don't hardcode u16
        }
    }

    const elf_base = std.process.getBaseAddress();
    const ehdr = @intToPtr(*elf.Ehdr, elf_base);
    // Make sure the base address points to an ELF image.
    assert(mem.eql(u8, ehdr.e_ident[0..4], "\x7fELF"));
    const n_phdr = ehdr.e_phnum;
    const phdrs = (@intToPtr([*]elf.Phdr, elf_base + ehdr.e_phoff))[0..n_phdr];

    var it = dl.linkmap_iterator(phdrs) catch unreachable;

    // The executable has no dynamic link segment, create a single entry for
    // the whole ELF image.
    if (it.end()) {
        // Find the base address for the ELF image, if this is a PIE the value
        // is non-zero.
        const base_address = for (phdrs) |*phdr| {
            if (phdr.p_type == elf.PT_PHDR) {
                break @ptrToInt(phdrs.ptr) - phdr.p_vaddr;
                // We could try computing the difference between _DYNAMIC and
                // the p_vaddr of the PT_DYNAMIC section, but using the phdr is
                // good enough (Is it?).
            }
        } else unreachable;

        var info = dl_phdr_info{
            .dlpi_addr = base_address,
            .dlpi_name = "/proc/self/exe",
            .dlpi_phdr = phdrs.ptr,
            .dlpi_phnum = ehdr.e_phnum,
        };

        return callback(&info, @sizeOf(dl_phdr_info), context);
    }

    // Last return value from the callback function.
    while (it.next()) |entry| {
        var dlpi_phdr: [*]elf.Phdr = undefined;
        var dlpi_phnum: u16 = undefined;

        if (entry.l_addr != 0) {
            const elf_header = @intToPtr(*elf.Ehdr, entry.l_addr);
            dlpi_phdr = @intToPtr([*]elf.Phdr, entry.l_addr + elf_header.e_phoff);
            dlpi_phnum = elf_header.e_phnum;
        } else {
            // This is the running ELF image
            dlpi_phdr = @intToPtr([*]elf.Phdr, elf_base + ehdr.e_phoff);
            dlpi_phnum = ehdr.e_phnum;
        }

        var info = dl_phdr_info{
            .dlpi_addr = entry.l_addr,
            .dlpi_name = entry.l_name,
            .dlpi_phdr = dlpi_phdr,
            .dlpi_phnum = dlpi_phnum,
        };

        try callback(&info, @sizeOf(dl_phdr_info), context);
    }
}

pub const ClockGetTimeError = error{UnsupportedClock} || UnexpectedError;

/// TODO: change this to return the timespec as a return value
/// TODO: look into making clk_id an enum
pub fn clock_gettime(clk_id: i32, tp: *timespec) ClockGetTimeError!void {
    if (std.Target.current.os.tag == .wasi) {
        var ts: timestamp_t = undefined;
        switch (system.clock_time_get(@bitCast(u32, clk_id), 1, &ts)) {
            0 => {
                tp.* = .{
                    .tv_sec = @intCast(i64, ts / std.time.ns_per_s),
                    .tv_nsec = @intCast(isize, ts % std.time.ns_per_s),
                };
            },
            EINVAL => return error.UnsupportedClock,
            else => |err| return unexpectedErrno(err),
        }
        return;
    }
    if (std.Target.current.os.tag == .windows) {
        if (clk_id == CLOCK_REALTIME) {
            var ft: windows.FILETIME = undefined;
            windows.kernel32.GetSystemTimeAsFileTime(&ft);
            // FileTime has a granularity of 100 nanoseconds and uses the NTFS/Windows epoch.
            const ft64 = (@as(u64, ft.dwHighDateTime) << 32) | ft.dwLowDateTime;
            const ft_per_s = std.time.ns_per_s / 100;
            tp.* = .{
                .tv_sec = @intCast(i64, ft64 / ft_per_s) + std.time.epoch.windows,
                .tv_nsec = @intCast(c_long, ft64 % ft_per_s) * 100,
            };
            return;
        } else {
            // TODO POSIX implementation of CLOCK_MONOTONIC on Windows.
            return error.UnsupportedClock;
        }
    }

    switch (errno(system.clock_gettime(clk_id, tp))) {
        0 => return,
        EFAULT => unreachable,
        EINVAL => return error.UnsupportedClock,
        else => |err| return unexpectedErrno(err),
    }
}

pub fn clock_getres(clk_id: i32, res: *timespec) ClockGetTimeError!void {
    if (std.Target.current.os.tag == .wasi) {
        var ts: timestamp_t = undefined;
        switch (system.clock_res_get(@bitCast(u32, clk_id), &ts)) {
            0 => res.* = .{
                .tv_sec = @intCast(i64, ts / std.time.ns_per_s),
                .tv_nsec = @intCast(isize, ts % std.time.ns_per_s),
            },
            EINVAL => return error.UnsupportedClock,
            else => |err| return unexpectedErrno(err),
        }
        return;
    }

    switch (errno(system.clock_getres(clk_id, res))) {
        0 => return,
        EFAULT => unreachable,
        EINVAL => return error.UnsupportedClock,
        else => |err| return unexpectedErrno(err),
    }
}

pub const SchedGetAffinityError = error{PermissionDenied} || UnexpectedError;

pub fn sched_getaffinity(pid: pid_t) SchedGetAffinityError!cpu_set_t {
    var set: cpu_set_t = undefined;
    switch (errno(system.sched_getaffinity(pid, @sizeOf(cpu_set_t), &set))) {
        0 => return set,
        EFAULT => unreachable,
        EINVAL => unreachable,
        ESRCH => unreachable,
        EPERM => return error.PermissionDenied,
        else => |err| return unexpectedErrno(err),
    }
}

/// Used to convert a slice to a null terminated slice on the stack.
/// TODO https://github.com/ziglang/zig/issues/287
pub fn toPosixPath(file_path: []const u8) ![MAX_PATH_BYTES - 1:0]u8 {
    if (std.debug.runtime_safety) assert(std.mem.indexOfScalar(u8, file_path, 0) == null);
    var path_with_null: [MAX_PATH_BYTES - 1:0]u8 = undefined;
    // >= rather than > to make room for the null byte
    if (file_path.len >= MAX_PATH_BYTES) return error.NameTooLong;
    mem.copy(u8, &path_with_null, file_path);
    path_with_null[file_path.len] = 0;
    return path_with_null;
}

/// Whether or not error.Unexpected will print its value and a stack trace.
/// if this happens the fix is to add the error code to the corresponding
/// switch expression, possibly introduce a new error in the error set, and
/// send a patch to Zig.
pub const unexpected_error_tracing = builtin.mode == .Debug;

pub const UnexpectedError = error{
    /// The Operating System returned an undocumented error code.
    /// This error is in theory not possible, but it would be better
    /// to handle this error than to invoke undefined behavior.
    Unexpected,
};

/// Call this when you made a syscall or something that sets errno
/// and you get an unexpected error.
pub fn unexpectedErrno(err: anytype) UnexpectedError {
    if (@typeInfo(@TypeOf(err)) != .Int) {
        @compileError("err is expected to be an integer");
    }

    if (unexpected_error_tracing) {
        std.debug.warn("unexpected errno: {d}\n", .{err});
        std.debug.dumpCurrentStackTrace(null);
    }
    return error.Unexpected;
}

pub const SigaltstackError = error{
    /// The supplied stack size was less than MINSIGSTKSZ.
    SizeTooSmall,

    /// Attempted to change the signal stack while it was active.
    PermissionDenied,
} || UnexpectedError;

pub fn sigaltstack(ss: ?*stack_t, old_ss: ?*stack_t) SigaltstackError!void {
    switch (errno(system.sigaltstack(ss, old_ss))) {
        0 => return,
        EFAULT => unreachable,
        EINVAL => unreachable,
        ENOMEM => return error.SizeTooSmall,
        EPERM => return error.PermissionDenied,
        else => |err| return unexpectedErrno(err),
    }
}

/// Examine and change a signal action.
pub fn sigaction(sig: u6, act: ?*const Sigaction, oact: ?*Sigaction) void {
    switch (errno(system.sigaction(sig, act, oact))) {
        0 => return,
        EFAULT => unreachable,
        EINVAL => unreachable,
        else => unreachable,
    }
}

pub const FutimensError = error{
    /// times is NULL, or both tv_nsec values are UTIME_NOW, and either:
    /// *  the effective user ID of the caller does not match the  owner
    ///    of  the  file,  the  caller does not have write access to the
    ///    file, and the caller is not privileged (Linux: does not  have
    ///    either  the  CAP_FOWNER  or the CAP_DAC_OVERRIDE capability);
    ///    or,
    /// *  the file is marked immutable (see chattr(1)).
    AccessDenied,

    /// The caller attempted to change one or both timestamps to a value
    /// other than the current time, or to change one of the  timestamps
    /// to the current time while leaving the other timestamp unchanged,
    /// (i.e., times is not NULL, neither tv_nsec  field  is  UTIME_NOW,
    /// and neither tv_nsec field is UTIME_OMIT) and either:
    /// *  the  caller's  effective  user ID does not match the owner of
    ///    file, and the caller is not privileged (Linux: does not  have
    ///    the CAP_FOWNER capability); or,
    /// *  the file is marked append-only or immutable (see chattr(1)).
    PermissionDenied,

    ReadOnlyFileSystem,
} || UnexpectedError;

pub fn futimens(fd: fd_t, times: *const [2]timespec) FutimensError!void {
    if (builtin.os.tag == .wasi) {
        // TODO WASI encodes `wasi.fstflags` to signify magic values
        // similar to UTIME_NOW and UTIME_OMIT. Currently, we ignore
        // this here, but we should really handle it somehow.
        const atim = times[0].toTimestamp();
        const mtim = times[1].toTimestamp();
        switch (wasi.fd_filestat_set_times(fd, atim, mtim, wasi.FILESTAT_SET_ATIM | wasi.FILESTAT_SET_MTIM)) {
            wasi.ESUCCESS => return,
            wasi.EACCES => return error.AccessDenied,
            wasi.EPERM => return error.PermissionDenied,
            wasi.EBADF => unreachable, // always a race condition
            wasi.EFAULT => unreachable,
            wasi.EINVAL => unreachable,
            wasi.EROFS => return error.ReadOnlyFileSystem,
            else => |err| return unexpectedErrno(err),
        }
    }

    switch (errno(system.futimens(fd, times))) {
        0 => return,
        EACCES => return error.AccessDenied,
        EPERM => return error.PermissionDenied,
        EBADF => unreachable, // always a race condition
        EFAULT => unreachable,
        EINVAL => unreachable,
        EROFS => return error.ReadOnlyFileSystem,
        else => |err| return unexpectedErrno(err),
    }
}

pub const GetHostNameError = error{PermissionDenied} || UnexpectedError;

pub fn gethostname(name_buffer: *[HOST_NAME_MAX]u8) GetHostNameError![]u8 {
    if (builtin.link_libc) {
        switch (errno(system.gethostname(name_buffer, name_buffer.len))) {
            0 => return mem.spanZ(std.meta.assumeSentinel(name_buffer, 0)),
            EFAULT => unreachable,
            ENAMETOOLONG => unreachable, // HOST_NAME_MAX prevents this
            EPERM => return error.PermissionDenied,
            else => |err| return unexpectedErrno(err),
        }
    }
    if (builtin.os.tag == .linux) {
        const uts = uname();
        const hostname = mem.spanZ(std.meta.assumeSentinel(&uts.nodename, 0));
        mem.copy(u8, name_buffer, hostname);
        return name_buffer[0..hostname.len];
    }

    @compileError("TODO implement gethostname for this OS");
}

pub fn uname() utsname {
    var uts: utsname = undefined;
    switch (errno(system.uname(&uts))) {
        0 => return uts,
        EFAULT => unreachable,
        else => unreachable,
    }
}

pub fn res_mkquery(
    op: u4,
    dname: []const u8,
    class: u8,
    ty: u8,
    data: []const u8,
    newrr: ?[*]const u8,
    buf: []u8,
) usize {
    _ = data;
    _ = newrr;
    // This implementation is ported from musl libc.
    // A more idiomatic "ziggy" implementation would be welcome.
    var name = dname;
    if (mem.endsWith(u8, name, ".")) name.len -= 1;
    assert(name.len <= 253);
    const n = 17 + name.len + @boolToInt(name.len != 0);

    // Construct query template - ID will be filled later
    var q: [280]u8 = undefined;
    @memset(&q, 0, n);
    q[2] = @as(u8, op) * 8 + 1;
    q[5] = 1;
    mem.copy(u8, q[13..], name);
    var i: usize = 13;
    var j: usize = undefined;
    while (q[i] != 0) : (i = j + 1) {
        j = i;
        while (q[j] != 0 and q[j] != '.') : (j += 1) {}
        // TODO determine the circumstances for this and whether or
        // not this should be an error.
        if (j - i - 1 > 62) unreachable;
        q[i - 1] = @intCast(u8, j - i);
    }
    q[i + 1] = ty;
    q[i + 3] = class;

    // Make a reasonably unpredictable id
    var ts: timespec = undefined;
    clock_gettime(CLOCK_REALTIME, &ts) catch {};
    const UInt = std.meta.Int(.unsigned, std.meta.bitCount(@TypeOf(ts.tv_nsec)));
    const unsec = @bitCast(UInt, ts.tv_nsec);
    const id = @truncate(u32, unsec + unsec / 65536);
    q[0] = @truncate(u8, id / 256);
    q[1] = @truncate(u8, id);

    mem.copy(u8, buf, q[0..n]);
    return n;
}

pub const SendError = error{
    /// (For UNIX domain sockets, which are identified by pathname) Write permission is  denied
    /// on  the destination socket file, or search permission is denied for one of the
    /// directories the path prefix.  (See path_resolution(7).)
    /// (For UDP sockets) An attempt was made to send to a network/broadcast address as  though
    /// it was a unicast address.
    AccessDenied,

    /// The socket is marked nonblocking and the requested operation would block, and
    /// there is no global event loop configured.
    /// It's also possible to get this error under the following condition:
    /// (Internet  domain datagram sockets) The socket referred to by sockfd had not previously
    /// been bound to an address and, upon attempting to bind it to an ephemeral port,  it  was
    /// determined that all port numbers in the ephemeral port range are currently in use.  See
    /// the discussion of /proc/sys/net/ipv4/ip_local_port_range in ip(7).
    WouldBlock,

    /// Another Fast Open is already in progress.
    FastOpenAlreadyInProgress,

    /// Connection reset by peer.
    ConnectionResetByPeer,

    /// The  socket  type requires that message be sent atomically, and the size of the message
    /// to be sent made this impossible. The message is not transmitted.
    MessageTooBig,

    /// The output queue for a network interface was full.  This generally indicates  that  the
    /// interface  has  stopped sending, but may be caused by transient congestion.  (Normally,
    /// this does not occur in Linux.  Packets are just silently dropped when  a  device  queue
    /// overflows.)
    /// This is also caused when there is not enough kernel memory available.
    SystemResources,

    /// The  local  end  has been shut down on a connection oriented socket.  In this case, the
    /// process will also receive a SIGPIPE unless MSG_NOSIGNAL is set.
    BrokenPipe,

    FileDescriptorNotASocket,

    /// Network is unreachable.
    NetworkUnreachable,

    /// The local network interface used to reach the destination is down.
    NetworkSubsystemFailed,
} || UnexpectedError;

pub const SendMsgError = SendError || error{
    /// The passed address didn't have the correct address family in its sa_family field.
    AddressFamilyNotSupported,

    /// Returned when socket is AF_UNIX and the given path has a symlink loop.
    SymLinkLoop,

    /// Returned when socket is AF_UNIX and the given path length exceeds `MAX_PATH_BYTES` bytes.
    NameTooLong,

    /// Returned when socket is AF_UNIX and the given path does not point to an existing file.
    FileNotFound,
    NotDir,

    /// The socket is not connected (connection-oriented sockets only).
    SocketNotConnected,
    AddressNotAvailable,
};

pub fn sendmsg(
    /// The file descriptor of the sending socket.
    sockfd: socket_t,
    /// Message header and iovecs
    msg: msghdr_const,
    flags: u32,
) SendMsgError!usize {
    while (true) {
        const rc = system.sendmsg(sockfd, @ptrCast(*const std.x.os.Socket.Message, &msg), @intCast(c_int, flags));
        if (builtin.os.tag == .windows) {
            if (rc == windows.ws2_32.SOCKET_ERROR) {
                switch (windows.ws2_32.WSAGetLastError()) {
                    .WSAEACCES => return error.AccessDenied,
                    .WSAEADDRNOTAVAIL => return error.AddressNotAvailable,
                    .WSAECONNRESET => return error.ConnectionResetByPeer,
                    .WSAEMSGSIZE => return error.MessageTooBig,
                    .WSAENOBUFS => return error.SystemResources,
                    .WSAENOTSOCK => return error.FileDescriptorNotASocket,
                    .WSAEAFNOSUPPORT => return error.AddressFamilyNotSupported,
                    .WSAEDESTADDRREQ => unreachable, // A destination address is required.
                    .WSAEFAULT => unreachable, // The lpBuffers, lpTo, lpOverlapped, lpNumberOfBytesSent, or lpCompletionRoutine parameters are not part of the user address space, or the lpTo parameter is too small.
                    .WSAEHOSTUNREACH => return error.NetworkUnreachable,
                    // TODO: WSAEINPROGRESS, WSAEINTR
                    .WSAEINVAL => unreachable,
                    .WSAENETDOWN => return error.NetworkSubsystemFailed,
                    .WSAENETRESET => return error.ConnectionResetByPeer,
                    .WSAENETUNREACH => return error.NetworkUnreachable,
                    .WSAENOTCONN => return error.SocketNotConnected,
                    .WSAESHUTDOWN => unreachable, // The socket has been shut down; it is not possible to WSASendTo on a socket after shutdown has been invoked with how set to SD_SEND or SD_BOTH.
                    .WSAEWOULDBLOCK => return error.WouldBlock,
                    .WSANOTINITIALISED => unreachable, // A successful WSAStartup call must occur before using this function.
                    else => |err| return windows.unexpectedWSAError(err),
                }
            } else {
                return @intCast(usize, rc);
            }
        } else {
            switch (errno(rc)) {
                0 => return @intCast(usize, rc),

                EACCES => return error.AccessDenied,
                EAGAIN => return error.WouldBlock,
                EALREADY => return error.FastOpenAlreadyInProgress,
                EBADF => unreachable, // always a race condition
                ECONNRESET => return error.ConnectionResetByPeer,
                EDESTADDRREQ => unreachable, // The socket is not connection-mode, and no peer address is set.
                EFAULT => unreachable, // An invalid user space address was specified for an argument.
                EINTR => continue,
                EINVAL => unreachable, // Invalid argument passed.
                EISCONN => unreachable, // connection-mode socket was connected already but a recipient was specified
                EMSGSIZE => return error.MessageTooBig,
                ENOBUFS => return error.SystemResources,
                ENOMEM => return error.SystemResources,
                ENOTSOCK => unreachable, // The file descriptor sockfd does not refer to a socket.
                EOPNOTSUPP => unreachable, // Some bit in the flags argument is inappropriate for the socket type.
                EPIPE => return error.BrokenPipe,
                EAFNOSUPPORT => return error.AddressFamilyNotSupported,
                ELOOP => return error.SymLinkLoop,
                ENAMETOOLONG => return error.NameTooLong,
                ENOENT => return error.FileNotFound,
                ENOTDIR => return error.NotDir,
                EHOSTUNREACH => return error.NetworkUnreachable,
                ENETUNREACH => return error.NetworkUnreachable,
                ENOTCONN => return error.SocketNotConnected,
                ENETDOWN => return error.NetworkSubsystemFailed,
                else => |err| return unexpectedErrno(err),
            }
        }
    }
}

pub const SendToError = SendMsgError;

/// Transmit a message to another socket.
///
/// The `sendto` call may be used only when the socket is in a connected state (so that the intended
/// recipient  is  known). The  following call
///
///     send(sockfd, buf, len, flags);
///
/// is equivalent to
///
///     sendto(sockfd, buf, len, flags, NULL, 0);
///
/// If  sendto()  is used on a connection-mode (`SOCK_STREAM`, `SOCK_SEQPACKET`) socket, the arguments
/// `dest_addr` and `addrlen` are asserted to be `null` and `0` respectively, and asserted
/// that the socket was actually connected.
/// Otherwise, the address of the target is given by `dest_addr` with `addrlen` specifying  its  size.
///
/// If the message is too long to pass atomically through the underlying protocol,
/// `SendError.MessageTooBig` is returned, and the message is not transmitted.
///
/// There is no  indication  of  failure  to  deliver.
///
/// When the message does not fit into the send buffer of  the  socket,  `sendto`  normally  blocks,
/// unless  the socket has been placed in nonblocking I/O mode.  In nonblocking mode it would fail
/// with `SendError.WouldBlock`.  The `select` call may be used  to  determine when it is
/// possible to send more data.
pub fn sendto(
    /// The file descriptor of the sending socket.
    sockfd: socket_t,
    /// Message to send.
    buf: []const u8,
    flags: u32,
    dest_addr: ?*const sockaddr,
    addrlen: socklen_t,
) SendToError!usize {
    while (true) {
        const rc = system.sendto(sockfd, buf.ptr, buf.len, flags, dest_addr, addrlen);
        if (builtin.os.tag == .windows) {
            if (rc == windows.ws2_32.SOCKET_ERROR) {
                switch (windows.ws2_32.WSAGetLastError()) {
                    .WSAEACCES => return error.AccessDenied,
                    .WSAEADDRNOTAVAIL => return error.AddressNotAvailable,
                    .WSAECONNRESET => return error.ConnectionResetByPeer,
                    .WSAEMSGSIZE => return error.MessageTooBig,
                    .WSAENOBUFS => return error.SystemResources,
                    .WSAENOTSOCK => return error.FileDescriptorNotASocket,
                    .WSAEAFNOSUPPORT => return error.AddressFamilyNotSupported,
                    .WSAEDESTADDRREQ => unreachable, // A destination address is required.
                    .WSAEFAULT => unreachable, // The lpBuffers, lpTo, lpOverlapped, lpNumberOfBytesSent, or lpCompletionRoutine parameters are not part of the user address space, or the lpTo parameter is too small.
                    .WSAEHOSTUNREACH => return error.NetworkUnreachable,
                    // TODO: WSAEINPROGRESS, WSAEINTR
                    .WSAEINVAL => unreachable,
                    .WSAENETDOWN => return error.NetworkSubsystemFailed,
                    .WSAENETRESET => return error.ConnectionResetByPeer,
                    .WSAENETUNREACH => return error.NetworkUnreachable,
                    .WSAENOTCONN => return error.SocketNotConnected,
                    .WSAESHUTDOWN => unreachable, // The socket has been shut down; it is not possible to WSASendTo on a socket after shutdown has been invoked with how set to SD_SEND or SD_BOTH.
                    .WSAEWOULDBLOCK => return error.WouldBlock,
                    .WSANOTINITIALISED => unreachable, // A successful WSAStartup call must occur before using this function.
                    else => |err| return windows.unexpectedWSAError(err),
                }
            } else {
                return @intCast(usize, rc);
            }
        } else {
            switch (errno(rc)) {
                0 => return @intCast(usize, rc),

                EACCES => return error.AccessDenied,
                EAGAIN => return error.WouldBlock,
                EALREADY => return error.FastOpenAlreadyInProgress,
                EBADF => unreachable, // always a race condition
                ECONNRESET => return error.ConnectionResetByPeer,
                EDESTADDRREQ => unreachable, // The socket is not connection-mode, and no peer address is set.
                EFAULT => unreachable, // An invalid user space address was specified for an argument.
                EINTR => continue,
                EINVAL => unreachable, // Invalid argument passed.
                EISCONN => unreachable, // connection-mode socket was connected already but a recipient was specified
                EMSGSIZE => return error.MessageTooBig,
                ENOBUFS => return error.SystemResources,
                ENOMEM => return error.SystemResources,
                ENOTSOCK => unreachable, // The file descriptor sockfd does not refer to a socket.
                EOPNOTSUPP => unreachable, // Some bit in the flags argument is inappropriate for the socket type.
                EPIPE => return error.BrokenPipe,
                EAFNOSUPPORT => return error.AddressFamilyNotSupported,
                ELOOP => return error.SymLinkLoop,
                ENAMETOOLONG => return error.NameTooLong,
                ENOENT => return error.FileNotFound,
                ENOTDIR => return error.NotDir,
                EHOSTUNREACH => return error.NetworkUnreachable,
                ENETUNREACH => return error.NetworkUnreachable,
                ENOTCONN => return error.SocketNotConnected,
                ENETDOWN => return error.NetworkSubsystemFailed,
                else => |err| return unexpectedErrno(err),
            }
        }
    }
}

/// Transmit a message to another socket.
///
/// The `send` call may be used only when the socket is in a connected state (so that the intended
/// recipient  is  known).   The  only  difference  between `send` and `write` is the presence of
/// flags.  With a zero flags argument, `send` is equivalent to  `write`.   Also,  the  following
/// call
///
///     send(sockfd, buf, len, flags);
///
/// is equivalent to
///
///     sendto(sockfd, buf, len, flags, NULL, 0);
///
/// There is no  indication  of  failure  to  deliver.
///
/// When the message does not fit into the send buffer of  the  socket,  `send`  normally  blocks,
/// unless  the socket has been placed in nonblocking I/O mode.  In nonblocking mode it would fail
/// with `SendError.WouldBlock`.  The `select` call may be used  to  determine when it is
/// possible to send more data.
pub fn send(
    /// The file descriptor of the sending socket.
    sockfd: socket_t,
    buf: []const u8,
    flags: u32,
) SendError!usize {
    return sendto(sockfd, buf, flags, null, 0) catch |err| switch (err) {
        error.AddressFamilyNotSupported => unreachable,
        error.SymLinkLoop => unreachable,
        error.NameTooLong => unreachable,
        error.FileNotFound => unreachable,
        error.NotDir => unreachable,
        error.NetworkUnreachable => unreachable,
        error.AddressNotAvailable => unreachable,
        error.SocketNotConnected => unreachable,
        else => |e| return e,
    };
}

pub const SendFileError = PReadError || WriteError || SendError;

fn count_iovec_bytes(iovs: []const iovec_const) usize {
    var count: usize = 0;
    for (iovs) |iov| {
        count += iov.iov_len;
    }
    return count;
}

/// Transfer data between file descriptors, with optional headers and trailers.
/// Returns the number of bytes written, which can be zero.
///
/// The `sendfile` call copies `in_len` bytes from one file descriptor to another. When possible,
/// this is done within the operating system kernel, which can provide better performance
/// characteristics than transferring data from kernel to user space and back, such as with
/// `read` and `write` calls. When `in_len` is `0`, it means to copy until the end of the input file has been
/// reached. Note, however, that partial writes are still possible in this case.
///
/// `in_fd` must be a file descriptor opened for reading, and `out_fd` must be a file descriptor
/// opened for writing. They may be any kind of file descriptor; however, if `in_fd` is not a regular
/// file system file, it may cause this function to fall back to calling `read` and `write`, in which case
/// atomicity guarantees no longer apply.
///
/// Copying begins reading at `in_offset`. The input file descriptor seek position is ignored and not updated.
/// If the output file descriptor has a seek position, it is updated as bytes are written. When
/// `in_offset` is past the end of the input file, it successfully reads 0 bytes.
///
/// `flags` has different meanings per operating system; refer to the respective man pages.
///
/// These systems support atomically sending everything, including headers and trailers:
/// * macOS
/// * FreeBSD
///
/// These systems support in-kernel data copying, but headers and trailers are not sent atomically:
/// * Linux
///
/// Other systems fall back to calling `read` / `write`.
///
/// Linux has a limit on how many bytes may be transferred in one `sendfile` call, which is `0x7ffff000`
/// on both 64-bit and 32-bit systems. This is due to using a signed C int as the return value, as
/// well as stuffing the errno codes into the last `4096` values. This is noted on the `sendfile` man page.
/// The limit on Darwin is `0x7fffffff`, trying to write more than that returns EINVAL.
/// The corresponding POSIX limit on this is `math.maxInt(isize)`.
pub fn sendfile(
    out_fd: fd_t,
    in_fd: fd_t,
    in_offset: u64,
    in_len: u64,
    headers: []const iovec_const,
    trailers: []const iovec_const,
    flags: u32,
) SendFileError!usize {
    var header_done = false;
    var total_written: usize = 0;

    // Prevents EOVERFLOW.
    const size_t = std.meta.Int(.unsigned, @typeInfo(usize).Int.bits - 1);
    const max_count = switch (std.Target.current.os.tag) {
        .linux => 0x7ffff000,
        .macos, .ios, .watchos, .tvos => math.maxInt(i32),
        else => math.maxInt(size_t),
    };

    switch (std.Target.current.os.tag) {
        .linux => sf: {
            // sendfile() first appeared in Linux 2.2, glibc 2.1.
            const call_sf = comptime if (builtin.link_libc)
                std.c.versionCheck(.{ .major = 2, .minor = 1 }).ok
            else
                std.Target.current.os.version_range.linux.range.max.order(.{ .major = 2, .minor = 2 }) != .lt;
            if (!call_sf) break :sf;

            if (headers.len != 0) {
                const amt = try writev(out_fd, headers);
                total_written += amt;
                if (amt < count_iovec_bytes(headers)) return total_written;
                header_done = true;
            }

            // Here we match BSD behavior, making a zero count value send as many bytes as possible.
            const adjusted_count = if (in_len == 0) max_count else math.min(in_len, @as(size_t, max_count));

            const sendfile_sym = if (builtin.link_libc)
                system.sendfile64
            else
                system.sendfile;

            while (true) {
                var offset: off_t = @bitCast(off_t, in_offset);
                const rc = sendfile_sym(out_fd, in_fd, &offset, adjusted_count);
                switch (errno(rc)) {
                    0 => {
                        const amt = @bitCast(usize, rc);
                        total_written += amt;
                        if (in_len == 0 and amt == 0) {
                            // We have detected EOF from `in_fd`.
                            break;
                        } else if (amt < in_len) {
                            return total_written;
                        } else {
                            break;
                        }
                    },

                    EBADF => unreachable, // Always a race condition.
                    EFAULT => unreachable, // Segmentation fault.
                    EOVERFLOW => unreachable, // We avoid passing too large of a `count`.
                    ENOTCONN => unreachable, // `out_fd` is an unconnected socket.

                    EINVAL, ENOSYS => {
                        // EINVAL could be any of the following situations:
                        // * Descriptor is not valid or locked
                        // * an mmap(2)-like operation is  not  available  for in_fd
                        // * count is negative
                        // * out_fd has the O_APPEND flag set
                        // Because of the "mmap(2)-like operation" possibility, we fall back to doing read/write
                        // manually, the same as ENOSYS.
                        break :sf;
                    },
                    EAGAIN => if (std.event.Loop.instance) |loop| {
                        loop.waitUntilFdWritable(out_fd);
                        continue;
                    } else {
                        return error.WouldBlock;
                    },
                    EIO => return error.InputOutput,
                    EPIPE => return error.BrokenPipe,
                    ENOMEM => return error.SystemResources,
                    ENXIO => return error.Unseekable,
                    ESPIPE => return error.Unseekable,
                    else => |err| {
                        unexpectedErrno(err) catch {};
                        break :sf;
                    },
                }
            }

            if (trailers.len != 0) {
                total_written += try writev(out_fd, trailers);
            }

            return total_written;
        },
        .freebsd => sf: {
            var hdtr_data: std.c.sf_hdtr = undefined;
            var hdtr: ?*std.c.sf_hdtr = null;
            if (headers.len != 0 or trailers.len != 0) {
                // Here we carefully avoid `@intCast` by returning partial writes when
                // too many io vectors are provided.
                const hdr_cnt = math.cast(u31, headers.len) catch math.maxInt(u31);
                if (headers.len > hdr_cnt) return writev(out_fd, headers);

                const trl_cnt = math.cast(u31, trailers.len) catch math.maxInt(u31);

                hdtr_data = std.c.sf_hdtr{
                    .headers = headers.ptr,
                    .hdr_cnt = hdr_cnt,
                    .trailers = trailers.ptr,
                    .trl_cnt = trl_cnt,
                };
                hdtr = &hdtr_data;
            }

            const adjusted_count = math.min(in_len, max_count);

            while (true) {
                var sbytes: off_t = undefined;
                const offset = @bitCast(off_t, in_offset);
                const err = errno(system.sendfile(in_fd, out_fd, offset, adjusted_count, hdtr, &sbytes, flags));
                const amt = @bitCast(usize, sbytes);
                switch (err) {
                    0 => return amt,

                    EBADF => unreachable, // Always a race condition.
                    EFAULT => unreachable, // Segmentation fault.
                    ENOTCONN => unreachable, // `out_fd` is an unconnected socket.

                    EINVAL, EOPNOTSUPP, ENOTSOCK, ENOSYS => {
                        // EINVAL could be any of the following situations:
                        // * The fd argument is not a regular file.
                        // * The s argument is not a SOCK_STREAM type socket.
                        // * The offset argument is negative.
                        // Because of some of these possibilities, we fall back to doing read/write
                        // manually, the same as ENOSYS.
                        break :sf;
                    },

                    EINTR => if (amt != 0) return amt else continue,

                    EAGAIN => if (amt != 0) {
                        return amt;
                    } else if (std.event.Loop.instance) |loop| {
                        loop.waitUntilFdWritable(out_fd);
                        continue;
                    } else {
                        return error.WouldBlock;
                    },

                    EBUSY => if (amt != 0) {
                        return amt;
                    } else if (std.event.Loop.instance) |loop| {
                        loop.waitUntilFdReadable(in_fd);
                        continue;
                    } else {
                        return error.WouldBlock;
                    },

                    EIO => return error.InputOutput,
                    ENOBUFS => return error.SystemResources,
                    EPIPE => return error.BrokenPipe,

                    else => {
                        unexpectedErrno(err) catch {};
                        if (amt != 0) {
                            return amt;
                        } else {
                            break :sf;
                        }
                    },
                }
            }
        },
        .macos, .ios, .tvos, .watchos => sf: {
            var hdtr_data: std.c.sf_hdtr = undefined;
            var hdtr: ?*std.c.sf_hdtr = null;
            if (headers.len != 0 or trailers.len != 0) {
                // Here we carefully avoid `@intCast` by returning partial writes when
                // too many io vectors are provided.
                const hdr_cnt = math.cast(u31, headers.len) catch math.maxInt(u31);
                if (headers.len > hdr_cnt) return writev(out_fd, headers);

                const trl_cnt = math.cast(u31, trailers.len) catch math.maxInt(u31);

                hdtr_data = std.c.sf_hdtr{
                    .headers = headers.ptr,
                    .hdr_cnt = hdr_cnt,
                    .trailers = trailers.ptr,
                    .trl_cnt = trl_cnt,
                };
                hdtr = &hdtr_data;
            }

            const adjusted_count = math.min(in_len, @as(u63, max_count));

            while (true) {
                var sbytes: off_t = adjusted_count;
                const signed_offset = @bitCast(i64, in_offset);
                const err = errno(system.sendfile(in_fd, out_fd, signed_offset, &sbytes, hdtr, flags));
                const amt = @bitCast(usize, sbytes);
                switch (err) {
                    0 => return amt,

                    EBADF => unreachable, // Always a race condition.
                    EFAULT => unreachable, // Segmentation fault.
                    EINVAL => unreachable,
                    ENOTCONN => unreachable, // `out_fd` is an unconnected socket.

                    ENOTSUP, ENOTSOCK, ENOSYS => break :sf,

                    EINTR => if (amt != 0) return amt else continue,

                    EAGAIN => if (amt != 0) {
                        return amt;
                    } else if (std.event.Loop.instance) |loop| {
                        loop.waitUntilFdWritable(out_fd);
                        continue;
                    } else {
                        return error.WouldBlock;
                    },

                    EIO => return error.InputOutput,
                    EPIPE => return error.BrokenPipe,

                    else => {
                        unexpectedErrno(err) catch {};
                        if (amt != 0) {
                            return amt;
                        } else {
                            break :sf;
                        }
                    },
                }
            }
        },
        else => {}, // fall back to read/write
    }

    if (headers.len != 0 and !header_done) {
        const amt = try writev(out_fd, headers);
        total_written += amt;
        if (amt < count_iovec_bytes(headers)) return total_written;
    }

    rw: {
        var buf: [8 * 4096]u8 = undefined;
        // Here we match BSD behavior, making a zero count value send as many bytes as possible.
        const adjusted_count = if (in_len == 0) buf.len else math.min(buf.len, in_len);
        const amt_read = try pread(in_fd, buf[0..adjusted_count], in_offset);
        if (amt_read == 0) {
            if (in_len == 0) {
                // We have detected EOF from `in_fd`.
                break :rw;
            } else {
                return total_written;
            }
        }
        const amt_written = try write(out_fd, buf[0..amt_read]);
        total_written += amt_written;
        if (amt_written < in_len or in_len == 0) return total_written;
    }

    if (trailers.len != 0) {
        total_written += try writev(out_fd, trailers);
    }

    return total_written;
}

pub const CopyFileRangeError = error{
    FileTooBig,
    InputOutput,
    /// `fd_in` is not open for reading; or `fd_out` is not open  for  writing;
    /// or the  `O_APPEND`  flag  is  set  for `fd_out`.
    FilesOpenedWithWrongFlags,
    IsDir,
    OutOfMemory,
    NoSpaceLeft,
    Unseekable,
    PermissionDenied,
    FileBusy,
} || PReadError || PWriteError || UnexpectedError;

var has_copy_file_range_syscall = std.atomic.Atomic(bool).init(true);

/// Transfer data between file descriptors at specified offsets.
/// Returns the number of bytes written, which can less than requested.
///
/// The `copy_file_range` call copies `len` bytes from one file descriptor to another. When possible,
/// this is done within the operating system kernel, which can provide better performance
/// characteristics than transferring data from kernel to user space and back, such as with
/// `pread` and `pwrite` calls.
///
/// `fd_in` must be a file descriptor opened for reading, and `fd_out` must be a file descriptor
/// opened for writing. They may be any kind of file descriptor; however, if `fd_in` is not a regular
/// file system file, it may cause this function to fall back to calling `pread` and `pwrite`, in which case
/// atomicity guarantees no longer apply.
///
/// If `fd_in` and `fd_out` are the same, source and target ranges must not overlap.
/// The file descriptor seek positions are ignored and not updated.
/// When `off_in` is past the end of the input file, it successfully reads 0 bytes.
///
/// `flags` has different meanings per operating system; refer to the respective man pages.
///
/// These systems support in-kernel data copying:
/// * Linux 4.5 (cross-filesystem 5.3)
///
/// Other systems fall back to calling `pread` / `pwrite`.
///
/// Maximum offsets on Linux are `math.maxInt(i64)`.
pub fn copy_file_range(fd_in: fd_t, off_in: u64, fd_out: fd_t, off_out: u64, len: usize, flags: u32) CopyFileRangeError!usize {
    const call_cfr = comptime if (builtin.link_libc)
        std.c.versionCheck(.{ .major = 2, .minor = 27, .patch = 0 }).ok
    else
        std.Target.current.os.isAtLeast(.linux, .{ .major = 4, .minor = 5 }) orelse true;

    if (call_cfr and has_copy_file_range_syscall.load(.Monotonic)) {
        var off_in_copy = @bitCast(i64, off_in);
        var off_out_copy = @bitCast(i64, off_out);

        const rc = system.copy_file_range(fd_in, &off_in_copy, fd_out, &off_out_copy, len, flags);
        switch (system.getErrno(rc)) {
            0 => return @intCast(usize, rc),
            EBADF => return error.FilesOpenedWithWrongFlags,
            EFBIG => return error.FileTooBig,
            EIO => return error.InputOutput,
            EISDIR => return error.IsDir,
            ENOMEM => return error.OutOfMemory,
            ENOSPC => return error.NoSpaceLeft,
            EOVERFLOW => return error.Unseekable,
            EPERM => return error.PermissionDenied,
            ETXTBSY => return error.FileBusy,
            // these may not be regular files, try fallback
            EINVAL => {},
            // support for cross-filesystem copy added in Linux 5.3, use fallback
            EXDEV => {},
            // syscall added in Linux 4.5, use fallback
            ENOSYS => {
                has_copy_file_range_syscall.store(false, .Monotonic);
            },
            else => |err| return unexpectedErrno(err),
        }
    }

    var buf: [8 * 4096]u8 = undefined;
    const adjusted_count = math.min(buf.len, len);
    const amt_read = try pread(fd_in, buf[0..adjusted_count], off_in);
    // TODO without @as the line below fails to compile for wasm32-wasi:
    // error: integer value 0 cannot be coerced to type 'os.PWriteError!usize'
    if (amt_read == 0) return @as(usize, 0);
    return pwrite(fd_out, buf[0..amt_read], off_out);
}

pub const PollError = error{
    /// The network subsystem has failed.
    NetworkSubsystemFailed,

    /// The kernel had no space to allocate file descriptor tables.
    SystemResources,
} || UnexpectedError;

pub fn poll(fds: []pollfd, timeout: i32) PollError!usize {
    while (true) {
        const fds_count = math.cast(nfds_t, fds.len) catch return error.SystemResources;
        const rc = system.poll(fds.ptr, fds_count, timeout);
        if (builtin.os.tag == .windows) {
            if (rc == windows.ws2_32.SOCKET_ERROR) {
                switch (windows.ws2_32.WSAGetLastError()) {
                    .WSANOTINITIALISED => unreachable,
                    .WSAENETDOWN => return error.NetworkSubsystemFailed,
                    .WSAENOBUFS => return error.SystemResources,
                    // TODO: handle more errors
                    else => |err| return windows.unexpectedWSAError(err),
                }
            } else {
                return @intCast(usize, rc);
            }
        } else {
            switch (errno(rc)) {
                0 => return @intCast(usize, rc),
                EFAULT => unreachable,
                EINTR => continue,
                EINVAL => unreachable,
                ENOMEM => return error.SystemResources,
                else => |err| return unexpectedErrno(err),
            }
        }
        unreachable;
    }
}

pub const PPollError = error{
    /// The operation was interrupted by a delivery of a signal before it could complete.
    SignalInterrupt,

    /// The kernel had no space to allocate file descriptor tables.
    SystemResources,
} || UnexpectedError;

pub fn ppoll(fds: []pollfd, timeout: ?*const timespec, mask: ?*const sigset_t) PPollError!usize {
    var ts: timespec = undefined;
    var ts_ptr: ?*timespec = null;
    if (timeout) |timeout_ns| {
        ts_ptr = &ts;
        ts = timeout_ns.*;
    }
    const rc = system.ppoll(fds.ptr, fds.len, ts_ptr, mask);
    switch (errno(rc)) {
        0 => return @intCast(usize, rc),
        EFAULT => unreachable,
        EINTR => return error.SignalInterrupt,
        EINVAL => unreachable,
        ENOMEM => return error.SystemResources,
        else => |err| return unexpectedErrno(err),
    }
}

pub const RecvFromError = error{
    /// The socket is marked nonblocking and the requested operation would block, and
    /// there is no global event loop configured.
    WouldBlock,

    /// A remote host refused to allow the network connection, typically because it is not
    /// running the requested service.
    ConnectionRefused,

    /// Could not allocate kernel memory.
    SystemResources,

    ConnectionResetByPeer,

    /// The socket has not been bound.
    SocketNotBound,

    /// The UDP message was too big for the buffer and part of it has been discarded
    MessageTooBig,

    /// The network subsystem has failed.
    NetworkSubsystemFailed,

    /// The socket is not connected (connection-oriented sockets only).
    SocketNotConnected,
} || UnexpectedError;

pub fn recv(sock: socket_t, buf: []u8, flags: u32) RecvFromError!usize {
    return recvfrom(sock, buf, flags, null, null);
}

/// If `sockfd` is opened in non blocking mode, the function will
/// return error.WouldBlock when EAGAIN is received.
pub fn recvfrom(
    sockfd: socket_t,
    buf: []u8,
    flags: u32,
    src_addr: ?*sockaddr,
    addrlen: ?*socklen_t,
) RecvFromError!usize {
    while (true) {
        const rc = system.recvfrom(sockfd, buf.ptr, buf.len, flags, src_addr, addrlen);
        if (builtin.os.tag == .windows) {
            if (rc == windows.ws2_32.SOCKET_ERROR) {
                switch (windows.ws2_32.WSAGetLastError()) {
                    .WSANOTINITIALISED => unreachable,
                    .WSAECONNRESET => return error.ConnectionResetByPeer,
                    .WSAEINVAL => return error.SocketNotBound,
                    .WSAEMSGSIZE => return error.MessageTooBig,
                    .WSAENETDOWN => return error.NetworkSubsystemFailed,
                    .WSAENOTCONN => return error.SocketNotConnected,
                    .WSAEWOULDBLOCK => return error.WouldBlock,
                    // TODO: handle more errors
                    else => |err| return windows.unexpectedWSAError(err),
                }
            } else {
                return @intCast(usize, rc);
            }
        } else {
            switch (errno(rc)) {
                0 => return @intCast(usize, rc),
                EBADF => unreachable, // always a race condition
                EFAULT => unreachable,
                EINVAL => unreachable,
                ENOTCONN => unreachable,
                ENOTSOCK => unreachable,
                EINTR => continue,
                EAGAIN => return error.WouldBlock,
                ENOMEM => return error.SystemResources,
                ECONNREFUSED => return error.ConnectionRefused,
                ECONNRESET => return error.ConnectionResetByPeer,
                else => |err| return unexpectedErrno(err),
            }
        }
    }
}

pub const DnExpandError = error{InvalidDnsPacket};

pub fn dn_expand(
    msg: []const u8,
    comp_dn: []const u8,
    exp_dn: []u8,
) DnExpandError!usize {
    // This implementation is ported from musl libc.
    // A more idiomatic "ziggy" implementation would be welcome.
    var p = comp_dn.ptr;
    var len: usize = std.math.maxInt(usize);
    const end = msg.ptr + msg.len;
    if (p == end or exp_dn.len == 0) return error.InvalidDnsPacket;
    var dest = exp_dn.ptr;
    const dend = dest + std.math.min(exp_dn.len, 254);
    // detect reference loop using an iteration counter
    var i: usize = 0;
    while (i < msg.len) : (i += 2) {
        // loop invariants: p<end, dest<dend
        if ((p[0] & 0xc0) != 0) {
            if (p + 1 == end) return error.InvalidDnsPacket;
            var j = ((p[0] & @as(usize, 0x3f)) << 8) | p[1];
            if (len == std.math.maxInt(usize)) len = @ptrToInt(p) + 2 - @ptrToInt(comp_dn.ptr);
            if (j >= msg.len) return error.InvalidDnsPacket;
            p = msg.ptr + j;
        } else if (p[0] != 0) {
            if (dest != exp_dn.ptr) {
                dest.* = '.';
                dest += 1;
            }
            var j = p[0];
            p += 1;
            if (j >= @ptrToInt(end) - @ptrToInt(p) or j >= @ptrToInt(dend) - @ptrToInt(dest)) {
                return error.InvalidDnsPacket;
            }
            while (j != 0) {
                j -= 1;
                dest.* = p[0];
                dest += 1;
                p += 1;
            }
        } else {
            dest.* = 0;
            if (len == std.math.maxInt(usize)) len = @ptrToInt(p) + 1 - @ptrToInt(comp_dn.ptr);
            return len;
        }
    }
    return error.InvalidDnsPacket;
}

pub const SchedYieldError = error{
    /// The system is not configured to allow yielding
    SystemCannotYield,
};

pub fn sched_yield() SchedYieldError!void {
    if (builtin.os.tag == .windows) {
        // The return value has to do with how many other threads there are; it is not
        // an error condition on Windows.
        _ = windows.kernel32.SwitchToThread();
        return;
    }
    switch (errno(system.sched_yield())) {
        0 => return,
        ENOSYS => return error.SystemCannotYield,
        else => return error.SystemCannotYield,
    }
}

pub const SetSockOptError = error{
    /// The socket is already connected, and a specified option cannot be set while the socket is connected.
    AlreadyConnected,

    /// The option is not supported by the protocol.
    InvalidProtocolOption,

    /// The send and receive timeout values are too big to fit into the timeout fields in the socket structure.
    TimeoutTooBig,

    /// Insufficient resources are available in the system to complete the call.
    SystemResources,

    // Setting the socket option requires more elevated permissions.
    PermissionDenied,

    NetworkSubsystemFailed,
    FileDescriptorNotASocket,
    SocketNotBound,
} || UnexpectedError;

/// Set a socket's options.
pub fn setsockopt(fd: socket_t, level: u32, optname: u32, opt: []const u8) SetSockOptError!void {
    if (builtin.os.tag == .windows) {
        const rc = windows.ws2_32.setsockopt(fd, @intCast(i32, level), @intCast(i32, optname), opt.ptr, @intCast(i32, opt.len));
        if (rc == windows.ws2_32.SOCKET_ERROR) {
            switch (windows.ws2_32.WSAGetLastError()) {
                .WSANOTINITIALISED => unreachable,
                .WSAENETDOWN => return error.NetworkSubsystemFailed,
                .WSAEFAULT => unreachable,
                .WSAENOTSOCK => return error.FileDescriptorNotASocket,
                .WSAEINVAL => return error.SocketNotBound,
                else => |err| return windows.unexpectedWSAError(err),
            }
        }
        return;
    } else {
        switch (errno(system.setsockopt(fd, level, optname, opt.ptr, @intCast(socklen_t, opt.len)))) {
            0 => {},
            EBADF => unreachable, // always a race condition
            ENOTSOCK => unreachable, // always a race condition
            EINVAL => unreachable,
            EFAULT => unreachable,
            EDOM => return error.TimeoutTooBig,
            EISCONN => return error.AlreadyConnected,
            ENOPROTOOPT => return error.InvalidProtocolOption,
            ENOMEM => return error.SystemResources,
            ENOBUFS => return error.SystemResources,
            EPERM => return error.PermissionDenied,
            else => |err| return unexpectedErrno(err),
        }
    }
}

pub const MemFdCreateError = error{
    SystemFdQuotaExceeded,
    ProcessFdQuotaExceeded,
    OutOfMemory,

    /// memfd_create is available in Linux 3.17 and later. This error is returned
    /// for older kernel versions.
    SystemOutdated,
} || UnexpectedError;

pub const memfd_createC = @compileError("deprecated: renamed to memfd_createZ");

pub fn memfd_createZ(name: [*:0]const u8, flags: u32) MemFdCreateError!fd_t {
    // memfd_create is available only in glibc versions starting with 2.27.
    const use_c = std.c.versionCheck(.{ .major = 2, .minor = 27, .patch = 0 }).ok;
    const sys = if (use_c) std.c else linux;
    const getErrno = if (use_c) std.c.getErrno else linux.getErrno;
    const rc = sys.memfd_create(name, flags);
    switch (getErrno(rc)) {
        0 => return @intCast(fd_t, rc),
        EFAULT => unreachable, // name has invalid memory
        EINVAL => unreachable, // name/flags are faulty
        ENFILE => return error.SystemFdQuotaExceeded,
        EMFILE => return error.ProcessFdQuotaExceeded,
        ENOMEM => return error.OutOfMemory,
        ENOSYS => return error.SystemOutdated,
        else => |err| return unexpectedErrno(err),
    }
}

pub const MFD_NAME_PREFIX = "memfd:";
pub const MFD_MAX_NAME_LEN = NAME_MAX - MFD_NAME_PREFIX.len;
fn toMemFdPath(name: []const u8) ![MFD_MAX_NAME_LEN:0]u8 {
    var path_with_null: [MFD_MAX_NAME_LEN:0]u8 = undefined;
    // >= rather than > to make room for the null byte
    if (name.len >= MFD_MAX_NAME_LEN) return error.NameTooLong;
    mem.copy(u8, &path_with_null, name);
    path_with_null[name.len] = 0;
    return path_with_null;
}

pub fn memfd_create(name: []const u8, flags: u32) !fd_t {
    const name_t = try toMemFdPath(name);
    return memfd_createZ(&name_t, flags);
}

pub fn getrusage(who: i32) rusage {
    var result: rusage = undefined;
    const rc = system.getrusage(who, &result);
    switch (errno(rc)) {
        0 => return result,
        EINVAL => unreachable,
        EFAULT => unreachable,
        else => unreachable,
    }
}

pub const TermiosGetError = error{NotATerminal} || UnexpectedError;

pub fn tcgetattr(handle: fd_t) TermiosGetError!termios {
    while (true) {
        var term: termios = undefined;
        switch (errno(system.tcgetattr(handle, &term))) {
            0 => return term,
            EINTR => continue,
            EBADF => unreachable,
            ENOTTY => return error.NotATerminal,
            else => |err| return unexpectedErrno(err),
        }
    }
}

pub const TermiosSetError = TermiosGetError || error{ProcessOrphaned};

pub fn tcsetattr(handle: fd_t, optional_action: TCSA, termios_p: termios) TermiosSetError!void {
    while (true) {
        switch (errno(system.tcsetattr(handle, optional_action, &termios_p))) {
            0 => return,
            EBADF => unreachable,
            EINTR => continue,
            EINVAL => unreachable,
            ENOTTY => return error.NotATerminal,
            EIO => return error.ProcessOrphaned,
            else => |err| return unexpectedErrno(err),
        }
    }
}

pub const IoCtl_SIOCGIFINDEX_Error = error{
    FileSystem,
    InterfaceNotFound,
} || UnexpectedError;

pub fn ioctl_SIOCGIFINDEX(fd: fd_t, ifr: *ifreq) IoCtl_SIOCGIFINDEX_Error!void {
    while (true) {
        switch (errno(system.ioctl(fd, SIOCGIFINDEX, @ptrToInt(ifr)))) {
            0 => return,
            EINVAL => unreachable, // Bad parameters.
            ENOTTY => unreachable,
            ENXIO => unreachable,
            EBADF => unreachable, // Always a race condition.
            EFAULT => unreachable, // Bad pointer parameter.
            EINTR => continue,
            EIO => return error.FileSystem,
            ENODEV => return error.InterfaceNotFound,
            else => |err| return unexpectedErrno(err),
        }
    }
}

pub fn signalfd(fd: fd_t, mask: *const sigset_t, flags: u32) !fd_t {
    const rc = system.signalfd(fd, mask, flags);
    switch (errno(rc)) {
        0 => return @intCast(fd_t, rc),
        EBADF, EINVAL => unreachable,
        ENFILE => return error.SystemFdQuotaExceeded,
        ENOMEM => return error.SystemResources,
        EMFILE => return error.ProcessResources,
        ENODEV => return error.InodeMountFail,
        ENOSYS => return error.SystemOutdated,
        else => |err| return unexpectedErrno(err),
    }
}

pub const SyncError = error{
    InputOutput,
    NoSpaceLeft,
    DiskQuota,
    AccessDenied,
} || UnexpectedError;

/// Write all pending file contents and metadata modifications to all filesystems.
pub fn sync() void {
    system.sync();
}

/// Write all pending file contents and metadata modifications to the filesystem which contains the specified file.
pub fn syncfs(fd: fd_t) SyncError!void {
    const rc = system.syncfs(fd);
    switch (errno(rc)) {
        0 => return,
        EBADF, EINVAL, EROFS => unreachable,
        EIO => return error.InputOutput,
        ENOSPC => return error.NoSpaceLeft,
        EDQUOT => return error.DiskQuota,
        else => |err| return unexpectedErrno(err),
    }
}

/// Write all pending file contents and metadata modifications for the specified file descriptor to the underlying filesystem.
pub fn fsync(fd: fd_t) SyncError!void {
    if (std.Target.current.os.tag == .windows) {
        if (windows.kernel32.FlushFileBuffers(fd) != 0)
            return;
        switch (windows.kernel32.GetLastError()) {
            .SUCCESS => return,
            .INVALID_HANDLE => unreachable,
            .ACCESS_DENIED => return error.AccessDenied, // a sync was performed but the system couldn't update the access time
            .UNEXP_NET_ERR => return error.InputOutput,
            else => return error.InputOutput,
        }
    }
    const rc = system.fsync(fd);
    switch (errno(rc)) {
        0 => return,
        EBADF, EINVAL, EROFS => unreachable,
        EIO => return error.InputOutput,
        ENOSPC => return error.NoSpaceLeft,
        EDQUOT => return error.DiskQuota,
        else => |err| return unexpectedErrno(err),
    }
}

/// Write all pending file contents for the specified file descriptor to the underlying filesystem, but not necessarily the metadata.
pub fn fdatasync(fd: fd_t) SyncError!void {
    if (std.Target.current.os.tag == .windows) {
        return fsync(fd) catch |err| switch (err) {
            SyncError.AccessDenied => return, // fdatasync doesn't promise that the access time was synced
            else => return err,
        };
    }
    const rc = system.fdatasync(fd);
    switch (errno(rc)) {
        0 => return,
        EBADF, EINVAL, EROFS => unreachable,
        EIO => return error.InputOutput,
        ENOSPC => return error.NoSpaceLeft,
        EDQUOT => return error.DiskQuota,
        else => |err| return unexpectedErrno(err),
    }
}

pub const PrctlError = error{
    /// Can only occur with PR_SET_SECCOMP/SECCOMP_MODE_FILTER or
    /// PR_SET_MM/PR_SET_MM_EXE_FILE
    AccessDenied,
    /// Can only occur with PR_SET_MM/PR_SET_MM_EXE_FILE
    InvalidFileDescriptor,
    InvalidAddress,
    /// Can only occur with PR_SET_SPECULATION_CTRL, PR_MPX_ENABLE_MANAGEMENT,
    /// or PR_MPX_DISABLE_MANAGEMENT
    UnsupportedFeature,
    /// Can only occur wih PR_SET_FP_MODE
    OperationNotSupported,
    PermissionDenied,
} || UnexpectedError;

pub fn prctl(option: PR, args: anytype) PrctlError!u31 {
    if (@typeInfo(@TypeOf(args)) != .Struct)
        @compileError("Expected tuple or struct argument, found " ++ @typeName(@TypeOf(args)));
    if (args.len > 4)
        @compileError("prctl takes a maximum of 4 optional arguments");

    var buf: [4]usize = undefined;
    {
        comptime var i = 0;
        inline while (i < args.len) : (i += 1) buf[i] = args[i];
    }

    const rc = system.prctl(@enumToInt(option), buf[0], buf[1], buf[2], buf[3]);
    switch (errno(rc)) {
        0 => return @intCast(u31, rc),
        EACCES => return error.AccessDenied,
        EBADF => return error.InvalidFileDescriptor,
        EFAULT => return error.InvalidAddress,
        EINVAL => unreachable,
        ENODEV, ENXIO => return error.UnsupportedFeature,
        EOPNOTSUPP => return error.OperationNotSupported,
        EPERM, EBUSY => return error.PermissionDenied,
        ERANGE => unreachable,
        else => |err| return unexpectedErrno(err),
    }
}

pub const GetrlimitError = UnexpectedError;

pub fn getrlimit(resource: rlimit_resource) GetrlimitError!rlimit {
    const getrlimit_sym = if (builtin.os.tag == .linux and builtin.link_libc)
        system.getrlimit64
    else
        system.getrlimit;

    var limits: rlimit = undefined;
    switch (errno(getrlimit_sym(resource, &limits))) {
        0 => return limits,
        EFAULT => unreachable, // bogus pointer
        EINVAL => unreachable,
        else => |err| return unexpectedErrno(err),
    }
}

pub const SetrlimitError = error{ PermissionDenied, LimitTooBig } || UnexpectedError;

pub fn setrlimit(resource: rlimit_resource, limits: rlimit) SetrlimitError!void {
    const setrlimit_sym = if (builtin.os.tag == .linux and builtin.link_libc)
        system.setrlimit64
    else
        system.setrlimit;

    switch (errno(setrlimit_sym(resource, &limits))) {
        0 => return,
        EFAULT => unreachable, // bogus pointer
        EINVAL => return error.LimitTooBig, // this could also mean "invalid resource", but that would be unreachable
        EPERM => return error.PermissionDenied,
        else => |err| return unexpectedErrno(err),
    }
}

pub const MadviseError = error{
    /// advice is MADV_REMOVE, but the specified address range is not a shared writable mapping.
    AccessDenied,
    /// advice is MADV_HWPOISON, but the caller does not have the CAP_SYS_ADMIN capability.
    PermissionDenied,
    /// A kernel resource was temporarily unavailable.
    SystemResources,
    /// One of the following:
    /// * addr is not page-aligned or length is negative
    /// * advice is not valid
    /// * advice is MADV_DONTNEED or MADV_REMOVE and the specified address range
    ///   includes locked, Huge TLB pages, or VM_PFNMAP pages.
    /// * advice is MADV_MERGEABLE or MADV_UNMERGEABLE, but the kernel was not
    ///   configured with CONFIG_KSM.
    /// * advice is MADV_FREE or MADV_WIPEONFORK but the specified address range
    ///   includes file, Huge TLB, MAP_SHARED, or VM_PFNMAP ranges.
    InvalidSyscall,
    /// (for MADV_WILLNEED) Paging in this area would exceed the process's
    /// maximum resident set size.
    WouldExceedMaximumResidentSetSize,
    /// One of the following:
    /// * (for MADV_WILLNEED) Not enough memory: paging in failed.
    /// * Addresses in the specified range are not currently mapped, or
    ///   are outside the address space of the process.
    OutOfMemory,
    /// The madvise syscall is not available on this version and configuration
    /// of the Linux kernel.
    MadviseUnavailable,
    /// The operating system returned an undocumented error code.
    Unexpected,
};

/// Give advice about use of memory.
/// This syscall is optional and is sometimes configured to be disabled.
pub fn madvise(ptr: [*]align(mem.page_size) u8, length: usize, advice: u32) MadviseError!void {
    switch (errno(system.madvise(ptr, length, advice))) {
        0 => return,
        EACCES => return error.AccessDenied,
        EAGAIN => return error.SystemResources,
        EBADF => unreachable, // The map exists, but the area maps something that isn't a file.
        EINVAL => return error.InvalidSyscall,
        EIO => return error.WouldExceedMaximumResidentSetSize,
        ENOMEM => return error.OutOfMemory,
        ENOSYS => return error.MadviseUnavailable,
        else => |err| return unexpectedErrno(err),
    }
}
