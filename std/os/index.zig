const builtin = @import("builtin");
const Os = builtin.Os;
pub const windows = @import("windows/index.zig");
pub const darwin = @import("darwin.zig");
pub const linux = @import("linux.zig");
pub const posix = switch(builtin.os) {
    Os.linux => linux,
    Os.darwin, Os.macosx, Os.ios => darwin,
    else => @compileError("Unsupported OS"),
};

pub const max_noalloc_path_len = 1024;
pub const ChildProcess = @import("child_process.zig").ChildProcess;
pub const path = @import("path.zig");

pub const line_sep = switch (builtin.os) {
    Os.windows => "\r\n",
    else => "\n",
};

pub const page_size = 4 * 1024;

const debug = @import("../debug.zig");
const assert = debug.assert;

const c = @import("../c/index.zig");

const mem = @import("../mem.zig");
const Allocator = mem.Allocator;

const BufMap = @import("../buf_map.zig").BufMap;
const cstr = @import("../cstr.zig");

const io = @import("../io.zig");
const base64 = @import("../base64.zig");
const ArrayList = @import("../array_list.zig").ArrayList;

error Unexpected;
error SystemResources;
error AccessDenied;
error InvalidExe;
error FileSystem;
error IsDir;
error FileNotFound;
error FileBusy;
error PathAlreadyExists;
error SymLinkLoop;
error ReadOnlyFileSystem;
error LinkQuotaExceeded;
error RenameAcrossMountPoints;
error DirNotEmpty;
error WouldBlock;

/// Fills `buf` with random bytes. If linking against libc, this calls the
/// appropriate OS-specific library call. Otherwise it uses the zig standard
/// library implementation.
pub fn getRandomBytes(buf: []u8) -> %void {
    switch (builtin.os) {
        Os.linux => while (true) {
            // TODO check libc version and potentially call c.getrandom.
            // See #397
            const err = posix.getErrno(posix.getrandom(buf.ptr, buf.len, 0));
            if (err > 0) {
                return switch (err) {
                    posix.EINVAL => unreachable,
                    posix.EFAULT => unreachable,
                    posix.EINTR  => continue,
                    else         => error.Unexpected,
                }
            }
            return;
        },
        Os.darwin, Os.macosx, Os.ios => {
            const fd = %return posixOpen("/dev/urandom", posix.O_RDONLY|posix.O_CLOEXEC,
                0, null);
            defer posixClose(fd);

            %return posixRead(fd, buf);
        },
        Os.windows => {
            var hCryptProv: windows.HCRYPTPROV = undefined;
            if (!windows.CryptAcquireContext(&hCryptProv, null, null, windows.PROV_RSA_FULL, 0)) {
                return error.Unexpected;
            }
            defer _ = windows.CryptReleaseContext(hCryptProv, 0);

            if (!windows.CryptGenRandom(hCryptProv, windows.DWORD(buf.len), buf.ptr)) {
                return error.Unexpected;
            }
        },
        else => @compileError("Unsupported OS"),
    }
}

/// Raises a signal in the current kernel thread, ending its execution.
/// If linking against libc, this calls the abort() libc function. Otherwise
/// it uses the zig standard library implementation.
pub coldcc fn abort() -> noreturn {
    if (builtin.link_libc) {
        c.abort();
    }
    switch (builtin.os) {
        Os.linux, Os.darwin, Os.macosx, Os.ios => {
            _ = posix.raise(posix.SIGABRT);
            _ = posix.raise(posix.SIGKILL);
            while (true) {}
        },
        Os.windows => {
            windows.ExitProcess(1);
        },
        else => @compileError("Unsupported OS"),
    }
}

/// Exits the program cleanly with the specified status code.
pub coldcc fn exit(status: i32) -> noreturn {
    if (builtin.link_libc) {
        c.exit(status);
    }
    switch (builtin.os) {
        Os.linux, Os.darwin, Os.macosx, Os.ios => {
            posix.exit(status)
        },
        Os.windows => {
            // Map a possibly negative status code to a non-negative status for the systems default
            // integer width.
            const p_status = if (@sizeOf(c_uint) < @sizeOf(u32)) {
                @truncate(c_uint, @bitCast(u32, status))
            } else {
                c_uint(@bitCast(u32, status))
            };

            windows.ExitProcess(p_status)
        },
        else => @compileError("Unsupported OS"),
    }
}

/// Calls POSIX close, and keeps trying if it gets interrupted.
pub fn posixClose(fd: i32) {
    while (true) {
        const err = posix.getErrno(posix.close(fd));
        if (err == posix.EINTR) {
            continue;
        } else {
            return;
        }
    }
}

/// Calls POSIX read, and keeps trying if it gets interrupted.
pub fn posixRead(fd: i32, buf: []u8) -> %void {
    var index: usize = 0;
    while (index < buf.len) {
        const amt_written = posix.read(fd, &buf[index], buf.len - index);
        const err = posix.getErrno(amt_written);
        if (err > 0) {
            return switch (err) {
                posix.EINTR => continue,
                posix.EINVAL, posix.EFAULT => unreachable,
                posix.EAGAIN => error.WouldBlock,
                posix.EBADF => error.FileClosed,
                posix.EIO => error.InputOutput,
                posix.EISDIR => error.IsDir,
                posix.ENOBUFS, posix.ENOMEM => error.SystemResources,
                else => return error.Unexpected,
            }
        }
        index += amt_written;
    }
}

error WouldBlock;
error FileClosed;
error DestinationAddressRequired;
error DiskQuota;
error FileTooBig;
error InputOutput;
error NoSpaceLeft;
error BrokenPipe;
error Unexpected;

/// Calls POSIX write, and keeps trying if it gets interrupted.
pub fn posixWrite(fd: i32, bytes: []const u8) -> %void {
    while (true) {
        const write_ret = posix.write(fd, bytes.ptr, bytes.len);
        const write_err = posix.getErrno(write_ret);
        if (write_err > 0) {
            return switch (write_err) {
                posix.EINTR  => continue,
                posix.EINVAL, posix.EFAULT => unreachable,
                posix.EAGAIN => error.WouldBlock,
                posix.EBADF => error.FileClosed,
                posix.EDESTADDRREQ => error.DestinationAddressRequired,
                posix.EDQUOT => error.DiskQuota,
                posix.EFBIG  => error.FileTooBig,
                posix.EIO    => error.InputOutput,
                posix.ENOSPC => error.NoSpaceLeft,
                posix.EPERM  => error.AccessDenied,
                posix.EPIPE  => error.BrokenPipe,
                else         => error.Unexpected,
            }
        }
        return;
    }
}

error SystemResources;
error OperationAborted;
error IoPending;
error BrokenPipe;

pub fn windowsWrite(handle: windows.HANDLE, bytes: []const u8) -> %void {
    if (!windows.WriteFile(handle, @ptrCast(&const c_void, bytes.ptr), u32(bytes.len), null, null)) {
        return switch (windows.GetLastError()) {
            windows.ERROR.INVALID_USER_BUFFER => error.SystemResources,
            windows.ERROR.NOT_ENOUGH_MEMORY => error.SystemResources,
            windows.ERROR.OPERATION_ABORTED => error.OperationAborted,
            windows.ERROR.NOT_ENOUGH_QUOTA => error.SystemResources,
            windows.ERROR.IO_PENDING => error.IoPending,
            windows.ERROR.BROKEN_PIPE => error.BrokenPipe,
            else => error.Unexpected,
        };
    }
}

pub fn windowsIsTty(handle: windows.HANDLE) -> bool {
    if (windowsIsCygwinPty(handle))
        return true;

    var out: windows.DWORD = undefined;
    return windows.GetConsoleMode(handle, &out);
}

pub fn windowsIsCygwinPty(handle: windows.HANDLE) -> bool {
    const size = @sizeOf(windows.FILE_NAME_INFO);
    var name_info_bytes align(@alignOf(windows.FILE_NAME_INFO)) = []u8{0} ** (size + windows.MAX_PATH);

    if (!windows.GetFileInformationByHandleEx(handle, windows.FileNameInfo,
        @ptrCast(&c_void, &name_info_bytes[0]), u32(name_info_bytes.len)))
    {
        return true;
    }

    const name_info = @ptrCast(&const windows.FILE_NAME_INFO, &name_info_bytes[0]);
    const name_bytes = name_info_bytes[size..size + usize(name_info.FileNameLength)];
    const name_wide  = ([]u16)(name_bytes);
    return mem.indexOf(u16, name_wide, []u16{'m','s','y','s','-'}) != null or
           mem.indexOf(u16, name_wide, []u16{'-','p','t','y'}) != null;
}

/// ::file_path may need to be copied in memory to add a null terminating byte. In this case
/// a fixed size buffer of size ::max_noalloc_path_len is an attempted solution. If the fixed
/// size buffer is too small, and the provided allocator is null, ::error.NameTooLong is returned.
/// otherwise if the fixed size buffer is too small, allocator is used to obtain the needed memory.
/// Calls POSIX open, keeps trying if it gets interrupted, and translates
/// the return value into zig errors.
pub fn posixOpen(file_path: []const u8, flags: u32, perm: usize, allocator: ?&Allocator) -> %i32 {
    var stack_buf: [max_noalloc_path_len]u8 = undefined;
    var path0: []u8 = undefined;
    var need_free = false;

    if (file_path.len < stack_buf.len) {
        path0 = stack_buf[0..file_path.len + 1];
    } else if (allocator) |a| {
        path0 = %return a.alloc(u8, file_path.len + 1);
        need_free = true;
    } else {
        return error.NameTooLong;
    }
    defer if (need_free) {
        (??allocator).free(path0);
    };
    mem.copy(u8, path0, file_path);
    path0[file_path.len] = 0;

    while (true) {
        const result = posix.open(path0.ptr, flags, perm);
        const err = posix.getErrno(result);
        if (err > 0) {
            return switch (err) {
                posix.EINTR => continue,

                posix.EFAULT => unreachable,
                posix.EINVAL => unreachable,
                posix.EACCES => error.AccessDenied,
                posix.EFBIG, posix.EOVERFLOW => error.FileTooBig,
                posix.EISDIR => error.IsDir,
                posix.ELOOP => error.SymLinkLoop,
                posix.EMFILE => error.ProcessFdQuotaExceeded,
                posix.ENAMETOOLONG => error.NameTooLong,
                posix.ENFILE => error.SystemFdQuotaExceeded,
                posix.ENODEV => error.NoDevice,
                posix.ENOENT => error.PathNotFound,
                posix.ENOMEM => error.SystemResources,
                posix.ENOSPC => error.NoSpaceLeft,
                posix.ENOTDIR => error.NotDir,
                posix.EPERM => error.AccessDenied,
                else => error.Unexpected,
            }
        }
        return i32(result);
    }
}

pub fn posixDup2(old_fd: i32, new_fd: i32) -> %void {
    while (true) {
        const err = posix.getErrno(posix.dup2(old_fd, new_fd));
        if (err > 0) {
            return switch (err) {
                posix.EBUSY, posix.EINTR => continue,
                posix.EMFILE => error.ProcessFdQuotaExceeded,
                posix.EINVAL => unreachable,
                else => error.Unexpected,
            };
        }
        return;
    }
}

/// This function must allocate memory to add a null terminating bytes on path and each arg.
/// It must also convert to KEY=VALUE\0 format for environment variables, and include null
/// pointers after the args and after the environment variables.
/// Also make the first arg equal to exe_path.
/// This function also uses the PATH environment variable to get the full path to the executable.
pub fn posixExecve(exe_path: []const u8, argv: []const []const u8, env_map: &const BufMap,
    allocator: &Allocator) -> %void
{
    const argv_buf = %return allocator.alloc(?&u8, argv.len + 2);
    mem.set(?&u8, argv_buf, null);
    defer {
        for (argv_buf) |arg| {
            const arg_buf = if (arg) |ptr| cstr.toSlice(ptr) else break;
            allocator.free(arg_buf);
        }
        allocator.free(argv_buf);
    }
    {
        // Add exe_path to the first argument.
        const arg_buf = %return allocator.alloc(u8, exe_path.len + 1);
        @memcpy(&arg_buf[0], exe_path.ptr, exe_path.len);
        arg_buf[exe_path.len] = 0;

        argv_buf[0] = arg_buf.ptr;
    }
    for (argv) |arg, i| {
        const arg_buf = %return allocator.alloc(u8, arg.len + 1);
        @memcpy(&arg_buf[0], arg.ptr, arg.len);
        arg_buf[arg.len] = 0;

        argv_buf[i + 1] = arg_buf.ptr;
    }
    argv_buf[argv.len + 1] = null;

    const envp_count = env_map.count();
    const envp_buf = %return allocator.alloc(?&u8, envp_count + 1);
    mem.set(?&u8, envp_buf, null);
    defer {
        for (envp_buf) |env| {
            const env_buf = if (env) |ptr| cstr.toSlice(ptr) else break;
            allocator.free(env_buf);
        }
        allocator.free(envp_buf);
    }
    {
        var it = env_map.iterator();
        var i: usize = 0;
        while (it.next()) |pair| : (i += 1) {
            const env_buf = %return allocator.alloc(u8, pair.key.len + pair.value.len + 2);
            @memcpy(&env_buf[0], pair.key.ptr, pair.key.len);
            env_buf[pair.key.len] = '=';
            @memcpy(&env_buf[pair.key.len + 1], pair.value.ptr, pair.value.len);
            env_buf[env_buf.len - 1] = 0;

            envp_buf[i] = env_buf.ptr;
        }
        assert(i == envp_count);
    }
    envp_buf[envp_count] = null;


    if (mem.indexOfScalar(u8, exe_path, '/') != null) {
        // +1 for the null terminating byte
        const path_buf = %return allocator.alloc(u8, exe_path.len + 1);
        defer allocator.free(path_buf);
        @memcpy(&path_buf[0], &exe_path[0], exe_path.len);
        path_buf[exe_path.len] = 0;
        return posixExecveErrnoToErr(posix.getErrno(posix.execve(path_buf.ptr, argv_buf.ptr, envp_buf.ptr)));
    }

    const PATH = getEnv("PATH") ?? "/usr/local/bin:/bin/:/usr/bin";
    // PATH.len because it is >= the largest search_path
    // +1 for the / to join the search path and exe_path
    // +1 for the null terminating byte
    const path_buf = %return allocator.alloc(u8, PATH.len + exe_path.len + 2);
    defer allocator.free(path_buf);
    var it = mem.split(PATH, ':');
    var seen_eacces = false;
    var err: usize = undefined;
    while (it.next()) |search_path| {
        mem.copy(u8, path_buf, search_path);
        path_buf[search_path.len] = '/';
        mem.copy(u8, path_buf[search_path.len + 1 ..], exe_path);
        path_buf[search_path.len + exe_path.len + 1] = 0;
        err = posix.getErrno(posix.execve(path_buf.ptr, argv_buf.ptr, envp_buf.ptr));
        assert(err > 0);
        if (err == posix.EACCES) {
            seen_eacces = true;
        } else if (err != posix.ENOENT) {
            return posixExecveErrnoToErr(err);
        }
    }
    if (seen_eacces) {
        err = posix.EACCES;
    }
    return posixExecveErrnoToErr(err);
}

fn posixExecveErrnoToErr(err: usize) -> error {
    assert(err > 0);
    return switch (err) {
        posix.EFAULT => unreachable,
        posix.E2BIG, posix.EMFILE, posix.ENAMETOOLONG, posix.ENFILE, posix.ENOMEM => error.SystemResources,
        posix.EACCES, posix.EPERM => error.AccessDenied,
        posix.EINVAL, posix.ENOEXEC => error.InvalidExe,
        posix.EIO, posix.ELOOP => error.FileSystem,
        posix.EISDIR => error.IsDir,
        posix.ENOENT => error.FileNotFound,
        posix.ENOTDIR => error.NotDir,
        posix.ETXTBSY => error.FileBusy,
        else => error.Unexpected,
    };
}

pub var environ_raw: []&u8 = undefined;

pub fn getEnvMap(allocator: &Allocator) -> %BufMap {
    var result = BufMap.init(allocator);
    %defer result.deinit();

    for (environ_raw) |ptr| {
        var line_i: usize = 0;
        while (ptr[line_i] != 0 and ptr[line_i] != '=') : (line_i += 1) {}
        const key = ptr[0..line_i];

        var end_i: usize = line_i;
        while (ptr[end_i] != 0) : (end_i += 1) {}
        const value = ptr[line_i + 1..end_i];

        %return result.set(key, value);
    }
    return result;
}

pub fn getEnv(key: []const u8) -> ?[]const u8 {
    for (environ_raw) |ptr| {
        var line_i: usize = 0;
        while (ptr[line_i] != 0 and ptr[line_i] != '=') : (line_i += 1) {}
        const this_key = ptr[0..line_i];
        if (!mem.eql(u8, key, this_key))
            continue;

        var end_i: usize = line_i;
        while (ptr[end_i] != 0) : (end_i += 1) {}
        const this_value = ptr[line_i + 1..end_i];

        return this_value;
    }
    return null;
}

pub const args = struct {
    pub var raw: []&u8 = undefined;

    pub fn count() -> usize {
        return raw.len;
    }
    pub fn at(i: usize) -> []const u8 {
        const s = raw[i];
        return cstr.toSlice(s);
    }
};

/// Caller must free the returned memory.
pub fn getCwd(allocator: &Allocator) -> %[]u8 {
    var buf = %return allocator.alloc(u8, 1024);
    %defer allocator.free(buf);
    while (true) {
        const err = posix.getErrno(posix.getcwd(buf.ptr, buf.len));
        if (err == posix.ERANGE) {
            buf = %return allocator.realloc(u8, buf, buf.len * 2);
            continue;
        } else if (err > 0) {
            return error.Unexpected;
        }

        return cstr.toSlice(buf.ptr);
    }
}

pub fn symLink(allocator: &Allocator, existing_path: []const u8, new_path: []const u8) -> %void {
    const full_buf = %return allocator.alloc(u8, existing_path.len + new_path.len + 2);
    defer allocator.free(full_buf);

    const existing_buf = full_buf;
    mem.copy(u8, existing_buf, existing_path);
    existing_buf[existing_path.len] = 0;

    const new_buf = full_buf[existing_path.len + 1..];
    mem.copy(u8, new_buf, new_path);
    new_buf[new_path.len] = 0;

    const err = posix.getErrno(posix.symlink(existing_buf.ptr, new_buf.ptr));
    if (err > 0) {
        return switch (err) {
            posix.EFAULT, posix.EINVAL => unreachable,
            posix.EACCES, posix.EPERM => error.AccessDenied,
            posix.EDQUOT => error.DiskQuota,
            posix.EEXIST => error.PathAlreadyExists,
            posix.EIO => error.FileSystem,
            posix.ELOOP => error.SymLinkLoop,
            posix.ENAMETOOLONG => error.NameTooLong,
            posix.ENOENT => error.FileNotFound,
            posix.ENOTDIR => error.NotDir,
            posix.ENOMEM => error.SystemResources,
            posix.ENOSPC => error.NoSpaceLeft,
            posix.EROFS => error.ReadOnlyFileSystem,
            else => error.Unexpected,
        };
    }
}

// here we replace the standard +/ with -_ so that it can be used in a file name
const b64_fs_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_=";

pub fn atomicSymLink(allocator: &Allocator, existing_path: []const u8, new_path: []const u8) -> %void {
    if (symLink(allocator, existing_path, new_path)) {
        return;
    } else |err| {
        if (err != error.PathAlreadyExists) {
            return err;
        }
    }

    var rand_buf: [12]u8 = undefined;
    const tmp_path = %return allocator.alloc(u8, new_path.len + base64.calcEncodedSize(rand_buf.len));
    defer allocator.free(tmp_path);
    mem.copy(u8, tmp_path[0..], new_path);
    while (true) {
        %return getRandomBytes(rand_buf[0..]);
        _ = base64.encodeWithAlphabet(tmp_path[new_path.len..], rand_buf, b64_fs_alphabet);
        if (symLink(allocator, existing_path, tmp_path)) {
            return rename(allocator, tmp_path, new_path);
        } else |err| {
            if (err == error.PathAlreadyExists) {
                continue;
            } else {
                return err;
            }
        }
    }

}

pub fn deleteFile(allocator: &Allocator, file_path: []const u8) -> %void {
    const buf = %return allocator.alloc(u8, file_path.len + 1);
    defer allocator.free(buf);

    mem.copy(u8, buf, file_path);
    buf[file_path.len] = 0;

    const err = posix.getErrno(posix.unlink(buf.ptr));
    if (err > 0) {
        return switch (err) {
            posix.EACCES, posix.EPERM => error.AccessDenied,
            posix.EBUSY => error.FileBusy,
            posix.EFAULT, posix.EINVAL => unreachable,
            posix.EIO => error.FileSystem,
            posix.EISDIR => error.IsDir,
            posix.ELOOP => error.SymLinkLoop,
            posix.ENAMETOOLONG => error.NameTooLong,
            posix.ENOENT => error.FileNotFound,
            posix.ENOTDIR => error.NotDir,
            posix.ENOMEM => error.SystemResources,
            posix.EROFS => error.ReadOnlyFileSystem,
            else => error.Unexpected,
        };
    }
}

/// Calls ::copyFileMode with 0o666 for the mode.
pub fn copyFile(allocator: &Allocator, source_path: []const u8, dest_path: []const u8) -> %void {
    return copyFileMode(allocator, source_path, dest_path, 0o666);
}

// TODO instead of accepting a mode argument, use the mode from fstat'ing the source path once open
/// Guaranteed to be atomic.
pub fn copyFileMode(allocator: &Allocator, source_path: []const u8, dest_path: []const u8, mode: usize) -> %void {
    var rand_buf: [12]u8 = undefined;
    const tmp_path = %return allocator.alloc(u8, dest_path.len + base64.calcEncodedSize(rand_buf.len));
    defer allocator.free(tmp_path);
    mem.copy(u8, tmp_path[0..], dest_path);
    %return getRandomBytes(rand_buf[0..]);
    _ = base64.encodeWithAlphabet(tmp_path[dest_path.len..], rand_buf, b64_fs_alphabet);

    var out_stream = %return io.OutStream.openMode(tmp_path, mode, allocator);
    defer out_stream.close();
    %defer _ = deleteFile(allocator, tmp_path);

    var in_stream = %return io.InStream.open(source_path, allocator);
    defer in_stream.close();

    const buf = out_stream.buffer[0..];
    while (true) {
        const amt = %return in_stream.read(buf);
        out_stream.index = amt;
        %return out_stream.flush();
        if (amt != out_stream.buffer.len)
            return rename(allocator, tmp_path, dest_path);
    }
}

pub fn rename(allocator: &Allocator, old_path: []const u8, new_path: []const u8) -> %void {
    const full_buf = %return allocator.alloc(u8, old_path.len + new_path.len + 2);
    defer allocator.free(full_buf);

    const old_buf = full_buf;
    mem.copy(u8, old_buf, old_path);
    old_buf[old_path.len] = 0;

    const new_buf = full_buf[old_path.len + 1..];
    mem.copy(u8, new_buf, new_path);
    new_buf[new_path.len] = 0;

    const err = posix.getErrno(posix.rename(old_buf.ptr, new_buf.ptr));
    if (err > 0) {
        return switch (err) {
            posix.EACCES, posix.EPERM => error.AccessDenied,
            posix.EBUSY => error.FileBusy,
            posix.EDQUOT => error.DiskQuota,
            posix.EFAULT, posix.EINVAL => unreachable,
            posix.EISDIR => error.IsDir,
            posix.ELOOP => error.SymLinkLoop,
            posix.EMLINK => error.LinkQuotaExceeded,
            posix.ENAMETOOLONG => error.NameTooLong,
            posix.ENOENT => error.FileNotFound,
            posix.ENOTDIR => error.NotDir,
            posix.ENOMEM => error.SystemResources,
            posix.ENOSPC => error.NoSpaceLeft,
            posix.EEXIST, posix.ENOTEMPTY => error.PathAlreadyExists,
            posix.EROFS => error.ReadOnlyFileSystem,
            posix.EXDEV => error.RenameAcrossMountPoints,
            else => error.Unexpected,
        };
    }
}

pub fn makeDir(allocator: &Allocator, dir_path: []const u8) -> %void {
    const path_buf = %return allocator.alloc(u8, dir_path.len + 1);
    defer allocator.free(path_buf);

    mem.copy(u8, path_buf, dir_path);
    path_buf[dir_path.len] = 0;

    const err = posix.getErrno(posix.mkdir(path_buf.ptr, 0o755));
    if (err > 0) {
        return switch (err) {
            posix.EACCES, posix.EPERM => error.AccessDenied,
            posix.EDQUOT => error.DiskQuota,
            posix.EEXIST => error.PathAlreadyExists,
            posix.EFAULT => unreachable,
            posix.ELOOP => error.SymLinkLoop,
            posix.EMLINK => error.LinkQuotaExceeded,
            posix.ENAMETOOLONG => error.NameTooLong,
            posix.ENOENT => error.FileNotFound,
            posix.ENOMEM => error.SystemResources,
            posix.ENOSPC => error.NoSpaceLeft,
            posix.ENOTDIR => error.NotDir,
            posix.EROFS => error.ReadOnlyFileSystem,
            else => error.Unexpected,
        };
    }
}

/// Calls makeDir recursively to make an entire path. Returns success if the path
/// already exists and is a directory.
pub fn makePath(allocator: &Allocator, full_path: []const u8) -> %void {
    const resolved_path = %return path.resolve(allocator, full_path);
    defer allocator.free(resolved_path);

    var end_index: usize = resolved_path.len;
    while (true) {
        makeDir(allocator, resolved_path[0..end_index]) %% |err| {
            if (err == error.PathAlreadyExists) {
                // TODO stat the file and return an error if it's not a directory
                // this is important because otherwise a dangling symlink
                // could cause an infinite loop
                if (end_index == resolved_path.len)
                    return;
            } else if (err == error.FileNotFound) {
                // march end_index backward until next path component
                while (true) {
                    end_index -= 1;
                    if (resolved_path[end_index] == '/')
                        break;
                }
                continue;
            } else {
                return err;
            }
        };
        if (end_index == resolved_path.len)
            return;
        // march end_index forward until next path component
        while (true) {
            end_index += 1;
            if (end_index == resolved_path.len or resolved_path[end_index] == '/')
                break;
        }
    }
}

/// Returns ::error.DirNotEmpty if the directory is not empty.
/// To delete a directory recursively, see ::deleteTree
pub fn deleteDir(allocator: &Allocator, dir_path: []const u8) -> %void {
    const path_buf = %return allocator.alloc(u8, dir_path.len + 1);
    defer allocator.free(path_buf);

    mem.copy(u8, path_buf, dir_path);
    path_buf[dir_path.len] = 0;

    const err = posix.getErrno(posix.rmdir(path_buf.ptr));
    if (err > 0) {
        return switch (err) {
            posix.EACCES, posix.EPERM => error.AccessDenied,
            posix.EBUSY => error.FileBusy,
            posix.EFAULT, posix.EINVAL => unreachable,
            posix.ELOOP => error.SymLinkLoop,
            posix.ENAMETOOLONG => error.NameTooLong,
            posix.ENOENT => error.FileNotFound,
            posix.ENOMEM => error.SystemResources,
            posix.ENOTDIR => error.NotDir,
            posix.EEXIST, posix.ENOTEMPTY => error.DirNotEmpty,
            posix.EROFS => error.ReadOnlyFileSystem,
            else => error.Unexpected,
        };
    }
}

/// Whether ::full_path describes a symlink, file, or directory, this function
/// removes it. If it cannot be removed because it is a non-empty directory,
/// this function recursively removes its entries and then tries again.
// TODO non-recursive implementation
pub fn deleteTree(allocator: &Allocator, full_path: []const u8) -> %void {
start_over:
    // First, try deleting the item as a file. This way we don't follow sym links.
    if (deleteFile(allocator, full_path)) {
        return;
    } else |err| {
        if (err == error.FileNotFound)
            return;
        if (err != error.IsDir)
            return err;
    }
    {
        var dir = Dir.open(allocator, full_path) %% |err| {
            if (err == error.FileNotFound)
                return;
            if (err == error.NotDir)
                goto start_over;
            return err;
        };
        defer dir.close();

        var full_entry_buf = ArrayList(u8).init(allocator);
        defer full_entry_buf.deinit();

        while (%return dir.next()) |entry| {
            %return full_entry_buf.resize(full_path.len + entry.name.len + 1);
            const full_entry_path = full_entry_buf.toSlice();
            mem.copy(u8, full_entry_path, full_path);
            full_entry_path[full_path.len] = '/';
            mem.copy(u8, full_entry_path[full_path.len + 1..], entry.name);

            %return deleteTree(allocator, full_entry_path);
        }
    }
    return deleteDir(allocator, full_path);
}

pub const Dir = struct {
    fd: i32,
    allocator: &Allocator,
    buf: []u8,
    index: usize,
    end_index: usize,

    const LinuxEntry = extern struct {
        d_ino: usize,
        d_off: usize,
        d_reclen: u16,
        d_name: u8, // field address is the address of first byte of name
    };

    pub const Entry = struct {
        name: []const u8,
        kind: Kind,

        pub const Kind = enum {
            BlockDevice,
            CharacterDevice,
            Directory,
            NamedPipe,
            SymLink,
            File,
            UnixDomainSocket,
            Unknown,
        };
    };

    pub fn open(allocator: &Allocator, dir_path: []const u8) -> %Dir {
        const fd = %return posixOpen(dir_path, posix.O_RDONLY|posix.O_DIRECTORY|posix.O_CLOEXEC, 0, allocator);
        return Dir {
            .allocator = allocator,
            .fd = fd,
            .index = 0,
            .end_index = 0,
            .buf = []u8{},
        };
    }

    pub fn close(self: &Dir) {
        self.allocator.free(self.buf);
        posixClose(self.fd);
    }

    /// Memory such as file names referenced in this returned entry becomes invalid
    /// with subsequent calls to next, as well as when this ::Dir is deinitialized.
    pub fn next(self: &Dir) -> %?Entry {
    start_over:
        if (self.index >= self.end_index) {
            if (self.buf.len == 0) {
                self.buf = %return self.allocator.alloc(u8, 2); //page_size);
            }

            while (true) {
                const result = posix.getdents(self.fd, self.buf.ptr, self.buf.len);
                const err = linux.getErrno(result);
                if (err > 0) {
                    switch (err) {
                        posix.EBADF, posix.EFAULT, posix.ENOTDIR => unreachable,
                        posix.EINVAL => {
                            self.buf = %return self.allocator.realloc(u8, self.buf, self.buf.len * 2);
                            continue;
                        },
                        else => return error.Unexpected,
                    };
                }
                if (result == 0)
                    return null;
                self.index = 0;
                self.end_index = result;
                break;
            }
        }
        const linux_entry = @ptrCast(&LinuxEntry, &self.buf[self.index]);
        const next_index = self.index + linux_entry.d_reclen;
        self.index = next_index;

        const name = cstr.toSlice(&linux_entry.d_name);

        // skip . and .. entries
        if (mem.eql(u8, name, ".") or mem.eql(u8, name, "..")) {
            goto start_over;
        }

        const type_char = self.buf[next_index - 1];
        const entry_kind = switch (type_char) {
            posix.DT_BLK => Entry.Kind.BlockDevice,
            posix.DT_CHR => Entry.Kind.CharacterDevice,
            posix.DT_DIR => Entry.Kind.Directory,
            posix.DT_FIFO => Entry.Kind.NamedPipe,
            posix.DT_LNK => Entry.Kind.SymLink,
            posix.DT_REG => Entry.Kind.File,
            posix.DT_SOCK => Entry.Kind.UnixDomainSocket,
            else => Entry.Kind.Unknown,
        };
        return Entry {
            .name = name,
            .kind = entry_kind,
        };
    }
};

pub fn changeCurDir(allocator: &Allocator, dir_path: []const u8) -> %void {
    const path_buf = %return allocator.alloc(u8, dir_path.len + 1);
    defer allocator.free(path_buf);

    mem.copy(u8, path_buf, dir_path);
    path_buf[dir_path.len] = 0;

    const err = posix.getErrno(posix.chdir(path_buf.ptr));
    if (err > 0) {
        return switch (err) {
            posix.EACCES => error.AccessDenied,
            posix.EFAULT => unreachable,
            posix.EIO => error.FileSystem,
            posix.ELOOP => error.SymLinkLoop,
            posix.ENAMETOOLONG => error.NameTooLong,
            posix.ENOENT => error.FileNotFound,
            posix.ENOMEM => error.SystemResources,
            posix.ENOTDIR => error.NotDir,
            else => error.Unexpected,
        };
    }
}

/// Read value of a symbolic link.
pub fn readLink(allocator: &Allocator, pathname: []const u8) -> %[]u8 {
    const path_buf = %return allocator.alloc(u8, pathname.len + 1);
    defer allocator.free(path_buf);

    mem.copy(u8, path_buf, pathname);
    path_buf[pathname.len] = 0;

    var result_buf = %return allocator.alloc(u8, 1024);
    %defer allocator.free(result_buf);
    while (true) {
        const ret_val = posix.readlink(path_buf.ptr, result_buf.ptr, result_buf.len);
        const err = posix.getErrno(ret_val);
        if (err > 0) {
            return switch (err) {
                posix.EACCES => error.AccessDenied,
                posix.EFAULT, posix.EINVAL => unreachable,
                posix.EIO => error.FileSystem,
                posix.ELOOP => error.SymLinkLoop,
                posix.ENAMETOOLONG => error.NameTooLong,
                posix.ENOENT => error.FileNotFound,
                posix.ENOMEM => error.SystemResources,
                posix.ENOTDIR => error.NotDir,
                else => error.Unexpected,
            };
        }
        if (ret_val == result_buf.len) {
            result_buf = %return allocator.realloc(u8, result_buf, result_buf.len * 2);
            continue;
        }
        return result_buf[0..ret_val];
    }
}

pub fn sleep(seconds: u64, nanoseconds: u64) {
    var req = posix.timespec {
        .tv_sec = seconds,
        .tv_nsec = nanoseconds,
    };
    var rem: posix.timespec = undefined;
    while (true) {
        const ret_val = posix.nanosleep(&req, &rem);
        const err = posix.getErrno(ret_val);
        if (err == 0) return;
        switch (err) {
            posix.EFAULT => unreachable,
            posix.EINVAL => unreachable,
            posix.EINTR => {
                req = rem;
                continue;
            },
            else => return,
        }
    }
}
