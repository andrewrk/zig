// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.
const root = @import("root");
const builtin = std.builtin;
const std = @import("std.zig");
const os = std.os;
const mem = std.mem;
const base64 = std.base64;
const crypto = std.crypto;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const math = std.math;

const is_darwin = std.Target.current.os.tag.isDarwin();

pub const path = @import("fs/path.zig");
pub const File = @import("fs/file.zig").File;
pub const wasi = @import("fs/wasi.zig");

// TODO audit these APIs with respect to Dir and absolute paths

pub const realpath = os.realpath;
pub const realpathZ = os.realpathZ;
pub const realpathC = @compileError("deprecated: renamed to realpathZ");
pub const realpathW = os.realpathW;

pub const getAppDataDir = @import("fs/get_app_data_dir.zig").getAppDataDir;
pub const GetAppDataDirError = @import("fs/get_app_data_dir.zig").GetAppDataDirError;

pub const Watch = @import("fs/watch.zig").Watch;

/// This represents the maximum size of a UTF-8 encoded file path that the
/// operating system will accept. Paths, including those returned from file
/// system operations, may be longer than this length, but such paths cannot
/// be successfully passed back in other file system operations. However,
/// all path components returned by file system operations are assumed to
/// fit into a UTF-8 encoded array of this length.
/// The byte count includes room for a null sentinel byte.
pub const MAX_PATH_BYTES = switch (builtin.os.tag) {
    .linux, .macos, .ios, .freebsd, .netbsd, .dragonfly, .openbsd, .haiku => os.PATH_MAX,
    // Each UTF-16LE character may be expanded to 3 UTF-8 bytes.
    // If it would require 4 UTF-8 bytes, then there would be a surrogate
    // pair in the UTF-16LE, and we (over)account 3 bytes for it that way.
    // +1 for the null byte at the end, which can be encoded in 1 byte.
    .windows => os.windows.PATH_MAX_WIDE * 3 + 1,
    // TODO work out what a reasonable value we should use here
    .wasi => 4096,
    else => if (@hasDecl(root, "os") and @hasDecl(root.os, "PATH_MAX"))
        root.os.PATH_MAX
    else
        @compileError("PATH_MAX not implemented for " ++ @tagName(builtin.os.tag)),
};

pub const base64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".*;

/// Base64 encoder, replacing the standard `+/` with `-_` so that it can be used in a file name on any filesystem.
pub const base64_encoder = base64.Base64Encoder.init(base64_alphabet, null);

/// Base64 decoder, replacing the standard `+/` with `-_` so that it can be used in a file name on any filesystem.
pub const base64_decoder = base64.Base64Decoder.init(base64_alphabet, null);

/// Whether or not async file system syscalls need a dedicated thread because the operating
/// system does not support non-blocking I/O on the file system.
pub const need_async_thread = std.io.is_async and switch (builtin.os.tag) {
    .windows, .other => false,
    else => true,
};

/// TODO remove the allocator requirement from this API
pub fn atomicSymLink(allocator: *Allocator, existing_path: []const u8, new_path: []const u8) !void {
    if (cwd().symLink(existing_path, new_path, .{})) {
        return;
    } else |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err, // TODO zig should know this set does not include PathAlreadyExists
    }

    const dirname = path.dirname(new_path) orelse ".";

    var rand_buf: [AtomicFile.RANDOM_BYTES]u8 = undefined;
    const tmp_path = try allocator.alloc(u8, dirname.len + 1 + base64_encoder.calcSize(rand_buf.len));
    defer allocator.free(tmp_path);
    mem.copy(u8, tmp_path[0..], dirname);
    tmp_path[dirname.len] = path.sep;
    while (true) {
        crypto.random.bytes(rand_buf[0..]);
        _ = base64_encoder.encode(tmp_path[dirname.len + 1 ..], &rand_buf);

        if (cwd().symLink(existing_path, tmp_path, .{})) {
            return cwd().rename(tmp_path, new_path);
        } else |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err, // TODO zig should know this set does not include PathAlreadyExists
        }
    }
}

pub const PrevStatus = enum {
    stale,
    fresh,
};

pub const CopyFileOptions = struct {
    /// When this is `null` the mode is copied from the source file.
    override_mode: ?File.Mode = null,
};

/// Same as `Dir.updateFile`, except asserts that both `source_path` and `dest_path`
/// are absolute. See `Dir.updateFile` for a function that operates on both
/// absolute and relative paths.
pub fn updateFileAbsolute(
    source_path: []const u8,
    dest_path: []const u8,
    args: CopyFileOptions,
) !PrevStatus {
    assert(path.isAbsolute(source_path));
    assert(path.isAbsolute(dest_path));
    const my_cwd = cwd();
    return Dir.updateFile(my_cwd, source_path, my_cwd, dest_path, args);
}

/// Same as `Dir.copyFile`, except asserts that both `source_path` and `dest_path`
/// are absolute. See `Dir.copyFile` for a function that operates on both
/// absolute and relative paths.
pub fn copyFileAbsolute(source_path: []const u8, dest_path: []const u8, args: CopyFileOptions) !void {
    assert(path.isAbsolute(source_path));
    assert(path.isAbsolute(dest_path));
    const my_cwd = cwd();
    return Dir.copyFile(my_cwd, source_path, my_cwd, dest_path, args);
}

/// TODO update this API to avoid a getrandom syscall for every operation.
pub const AtomicFile = struct {
    file: File,
    // TODO either replace this with rand_buf or use []u16 on Windows
    tmp_path_buf: [TMP_PATH_LEN:0]u8,
    dest_basename: []const u8,
    file_open: bool,
    file_exists: bool,
    close_dir_on_deinit: bool,
    dir: Dir,

    const InitError = File.OpenError;

    const RANDOM_BYTES = 12;
    const TMP_PATH_LEN = base64_encoder.calcSize(RANDOM_BYTES);

    /// Note that the `Dir.atomicFile` API may be more handy than this lower-level function.
    pub fn init(
        dest_basename: []const u8,
        mode: File.Mode,
        dir: Dir,
        close_dir_on_deinit: bool,
    ) InitError!AtomicFile {
        var rand_buf: [RANDOM_BYTES]u8 = undefined;
        var tmp_path_buf: [TMP_PATH_LEN:0]u8 = undefined;

        while (true) {
            crypto.random.bytes(rand_buf[0..]);
            const tmp_path = base64_encoder.encode(&tmp_path_buf, &rand_buf);
            tmp_path_buf[tmp_path.len] = 0;

            const file = dir.createFile(
                tmp_path,
                .{ .mode = mode, .exclusive = true },
            ) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => |e| return e,
            };

            return AtomicFile{
                .file = file,
                .tmp_path_buf = tmp_path_buf,
                .dest_basename = dest_basename,
                .file_open = true,
                .file_exists = true,
                .close_dir_on_deinit = close_dir_on_deinit,
                .dir = dir,
            };
        }
    }

    /// always call deinit, even after successful finish()
    pub fn deinit(self: *AtomicFile) void {
        if (self.file_open) {
            self.file.close();
            self.file_open = false;
        }
        if (self.file_exists) {
            self.dir.deleteFile(&self.tmp_path_buf) catch {};
            self.file_exists = false;
        }
        if (self.close_dir_on_deinit) {
            self.dir.close();
        }
        self.* = undefined;
    }

    pub fn finish(self: *AtomicFile) !void {
        assert(self.file_exists);
        if (self.file_open) {
            self.file.close();
            self.file_open = false;
        }
        try os.renameat(self.dir.fd, self.tmp_path_buf[0..], self.dir.fd, self.dest_basename);
        self.file_exists = false;
    }
};

const default_new_dir_mode = 0o755;

/// Create a new directory, based on an absolute path.
/// Asserts that the path is absolute. See `Dir.makeDir` for a function that operates
/// on both absolute and relative paths.
pub fn makeDirAbsolute(absolute_path: []const u8) !void {
    assert(path.isAbsolute(absolute_path));
    return os.mkdir(absolute_path, default_new_dir_mode);
}

/// Same as `makeDirAbsolute` except the parameter is a null-terminated UTF8-encoded string.
pub fn makeDirAbsoluteZ(absolute_path_z: [*:0]const u8) !void {
    assert(path.isAbsoluteZ(absolute_path_z));
    return os.mkdirZ(absolute_path_z, default_new_dir_mode);
}

/// Same as `makeDirAbsolute` except the parameter is a null-terminated WTF-16 encoded string.
pub fn makeDirAbsoluteW(absolute_path_w: [*:0]const u16) !void {
    assert(path.isAbsoluteWindowsW(absolute_path_w));
    return os.mkdirW(absolute_path_w, default_new_dir_mode);
}

pub const deleteDir = @compileError("deprecated; use dir.deleteDir or deleteDirAbsolute");
pub const deleteDirC = @compileError("deprecated; use dir.deleteDirZ or deleteDirAbsoluteZ");
pub const deleteDirW = @compileError("deprecated; use dir.deleteDirW or deleteDirAbsoluteW");

/// Same as `Dir.deleteDir` except the path is absolute.
pub fn deleteDirAbsolute(dir_path: []const u8) !void {
    assert(path.isAbsolute(dir_path));
    return os.rmdir(dir_path);
}

/// Same as `deleteDirAbsolute` except the path parameter is null-terminated.
pub fn deleteDirAbsoluteZ(dir_path: [*:0]const u8) !void {
    assert(path.isAbsoluteZ(dir_path));
    return os.rmdirZ(dir_path);
}

/// Same as `deleteDirAbsolute` except the path parameter is WTF-16 and target OS is assumed Windows.
pub fn deleteDirAbsoluteW(dir_path: [*:0]const u16) !void {
    assert(path.isAbsoluteWindowsW(dir_path));
    return os.rmdirW(dir_path);
}

pub const renameC = @compileError("deprecated: use renameZ, dir.renameZ, or renameAbsoluteZ");

/// Same as `Dir.rename` except the paths are absolute.
pub fn renameAbsolute(old_path: []const u8, new_path: []const u8) !void {
    assert(path.isAbsolute(old_path));
    assert(path.isAbsolute(new_path));
    return os.rename(old_path, new_path);
}

/// Same as `renameAbsolute` except the path parameters are null-terminated.
pub fn renameAbsoluteZ(old_path: [*:0]const u8, new_path: [*:0]const u8) !void {
    assert(path.isAbsoluteZ(old_path));
    assert(path.isAbsoluteZ(new_path));
    return os.renameZ(old_path, new_path);
}

/// Same as `renameAbsolute` except the path parameters are WTF-16 and target OS is assumed Windows.
pub fn renameAbsoluteW(old_path: [*:0]const u16, new_path: [*:0]const u16) !void {
    assert(path.isAbsoluteWindowsW(old_path));
    assert(path.isAbsoluteWindowsW(new_path));
    return os.renameW(old_path, new_path);
}

/// Same as `Dir.rename`, except `new_sub_path` is relative to `new_dir`
pub fn rename(old_dir: Dir, old_sub_path: []const u8, new_dir: Dir, new_sub_path: []const u8) !void {
    return os.renameat(old_dir.fd, old_sub_path, new_dir.fd, new_sub_path);
}

/// Same as `rename` except the parameters are null-terminated.
pub fn renameZ(old_dir: Dir, old_sub_path_z: [*:0]const u8, new_dir: Dir, new_sub_path_z: [*:0]const u8) !void {
    return os.renameatZ(old_dir.fd, old_sub_path_z, new_dir.fd, new_sub_path_z);
}

/// Same as `rename` except the parameters are UTF16LE, NT prefixed.
/// This function is Windows-only.
pub fn renameW(old_dir: Dir, old_sub_path_w: []const u16, new_dir: Dir, new_sub_path_w: []const u16) !void {
    return os.renameatW(old_dir.fd, old_sub_path_w, new_dir.fd, new_sub_path_w);
}

pub const Dir = struct {
    fd: os.fd_t,

    pub const Entry = struct {
        name: []const u8,
        kind: Kind,

        pub const Kind = File.Kind;
    };

    const IteratorError = error{AccessDenied} || os.UnexpectedError;

    pub const Iterator = switch (builtin.os.tag) {
        .macos, .ios, .freebsd, .netbsd, .dragonfly, .openbsd => struct {
            dir: Dir,
            seek: i64,
            buf: [8192]u8, // TODO align(@alignOf(os.dirent)),
            index: usize,
            end_index: usize,

            const Self = @This();

            pub const Error = IteratorError;

            /// Memory such as file names referenced in this returned entry becomes invalid
            /// with subsequent calls to `next`, as well as when this `Dir` is deinitialized.
            pub fn next(self: *Self) Error!?Entry {
                switch (builtin.os.tag) {
                    .macos, .ios => return self.nextDarwin(),
                    .freebsd, .netbsd, .dragonfly, .openbsd => return self.nextBsd(),
                    else => @compileError("unimplemented"),
                }
            }

            fn nextDarwin(self: *Self) !?Entry {
                start_over: while (true) {
                    if (self.index >= self.end_index) {
                        const rc = os.system.__getdirentries64(
                            self.dir.fd,
                            &self.buf,
                            self.buf.len,
                            &self.seek,
                        );
                        if (rc == 0) return null;
                        if (rc < 0) {
                            switch (os.errno(rc)) {
                                os.EBADF => unreachable, // Dir is invalid or was opened without iteration ability
                                os.EFAULT => unreachable,
                                os.ENOTDIR => unreachable,
                                os.EINVAL => unreachable,
                                else => |err| return os.unexpectedErrno(err),
                            }
                        }
                        self.index = 0;
                        self.end_index = @intCast(usize, rc);
                    }
                    const darwin_entry = @ptrCast(*align(1) os.dirent, &self.buf[self.index]);
                    const next_index = self.index + darwin_entry.reclen();
                    self.index = next_index;

                    const name = @ptrCast([*]u8, &darwin_entry.d_name)[0..darwin_entry.d_namlen];

                    if (mem.eql(u8, name, ".") or mem.eql(u8, name, "..") or (darwin_entry.d_ino == 0)) {
                        continue :start_over;
                    }

                    const entry_kind = switch (darwin_entry.d_type) {
                        os.DT_BLK => Entry.Kind.BlockDevice,
                        os.DT_CHR => Entry.Kind.CharacterDevice,
                        os.DT_DIR => Entry.Kind.Directory,
                        os.DT_FIFO => Entry.Kind.NamedPipe,
                        os.DT_LNK => Entry.Kind.SymLink,
                        os.DT_REG => Entry.Kind.File,
                        os.DT_SOCK => Entry.Kind.UnixDomainSocket,
                        os.DT_WHT => Entry.Kind.Whiteout,
                        else => Entry.Kind.Unknown,
                    };
                    return Entry{
                        .name = name,
                        .kind = entry_kind,
                    };
                }
            }

            fn nextBsd(self: *Self) !?Entry {
                start_over: while (true) {
                    if (self.index >= self.end_index) {
                        const rc = if (builtin.os.tag == .netbsd)
                            os.system.__getdents30(self.dir.fd, &self.buf, self.buf.len)
                        else
                            os.system.getdents(self.dir.fd, &self.buf, self.buf.len);
                        switch (os.errno(rc)) {
                            0 => {},
                            os.EBADF => unreachable, // Dir is invalid or was opened without iteration ability
                            os.EFAULT => unreachable,
                            os.ENOTDIR => unreachable,
                            os.EINVAL => unreachable,
                            else => |err| return os.unexpectedErrno(err),
                        }
                        if (rc == 0) return null;
                        self.index = 0;
                        self.end_index = @intCast(usize, rc);
                    }
                    const bsd_entry = @ptrCast(*align(1) os.dirent, &self.buf[self.index]);
                    const next_index = self.index + bsd_entry.reclen();
                    self.index = next_index;

                    const name = @ptrCast([*]u8, &bsd_entry.d_name)[0..bsd_entry.d_namlen];

                    const skip_zero_fileno = switch (builtin.os.tag) {
                        // d_fileno=0 is used to mark invalid entries or deleted files.
                        .openbsd, .netbsd => true,
                        else => false,
                    };
                    if (mem.eql(u8, name, ".") or mem.eql(u8, name, "..") or
                        (skip_zero_fileno and bsd_entry.d_fileno == 0))
                    {
                        continue :start_over;
                    }

                    const entry_kind = switch (bsd_entry.d_type) {
                        os.DT_BLK => Entry.Kind.BlockDevice,
                        os.DT_CHR => Entry.Kind.CharacterDevice,
                        os.DT_DIR => Entry.Kind.Directory,
                        os.DT_FIFO => Entry.Kind.NamedPipe,
                        os.DT_LNK => Entry.Kind.SymLink,
                        os.DT_REG => Entry.Kind.File,
                        os.DT_SOCK => Entry.Kind.UnixDomainSocket,
                        os.DT_WHT => Entry.Kind.Whiteout,
                        else => Entry.Kind.Unknown,
                    };
                    return Entry{
                        .name = name,
                        .kind = entry_kind,
                    };
                }
            }
        },
        .haiku => struct {
            dir: Dir,
            buf: [8192]u8, // TODO align(@alignOf(os.dirent64)),
            index: usize,
            end_index: usize,

            const Self = @This();

            pub const Error = IteratorError;

            /// Memory such as file names referenced in this returned entry becomes invalid
            /// with subsequent calls to `next`, as well as when this `Dir` is deinitialized.
            pub fn next(self: *Self) Error!?Entry {
                start_over: while (true) {
                    // TODO: find a better max
                    const HAIKU_MAX_COUNT = 10000;
                    if (self.index >= self.end_index) {
                        const rc = os.system._kern_read_dir(
                            self.dir.fd,
                            &self.buf,
                            self.buf.len,
                            HAIKU_MAX_COUNT,
                        );
                        if (rc == 0) return null;
                        if (rc < 0) {
                            switch (os.errno(rc)) {
                                os.EBADF => unreachable, // Dir is invalid or was opened without iteration ability
                                os.EFAULT => unreachable,
                                os.ENOTDIR => unreachable,
                                os.EINVAL => unreachable,
                                else => |err| return os.unexpectedErrno(err),
                            }
                        }
                        self.index = 0;
                        self.end_index = @intCast(usize, rc);
                    }
                    const haiku_entry = @ptrCast(*align(1) os.dirent, &self.buf[self.index]);
                    const next_index = self.index + haiku_entry.reclen();
                    self.index = next_index;
                    const name = mem.spanZ(@ptrCast([*:0]u8, &haiku_entry.d_name));

                    if (mem.eql(u8, name, ".") or mem.eql(u8, name, "..") or (haiku_entry.d_ino == 0)) {
                        continue :start_over;
                    }

                    var stat_info: os.libc_stat = undefined;
                    _ = os.system._kern_read_stat(
                        self.dir.fd,
                        &haiku_entry.d_name,
                        false,
                        &stat_info,
                        0,
                    );
                    const statmode = stat_info.mode & os.S_IFMT;

                    const entry_kind = switch (statmode) {
                        os.S_IFDIR => Entry.Kind.Directory,
                        os.S_IFBLK => Entry.Kind.BlockDevice,
                        os.S_IFCHR => Entry.Kind.CharacterDevice,
                        os.S_IFLNK => Entry.Kind.SymLink,
                        os.S_IFREG => Entry.Kind.File,
                        os.S_IFIFO => Entry.Kind.NamedPipe,
                        else => Entry.Kind.Unknown,
                    };

                    return Entry{
                        .name = name,
                        .kind = entry_kind,
                    };
                }
            }
        },
        .linux => struct {
            dir: Dir,
            // The if guard is solely there to prevent compile errors from missing `os.linux.dirent64`
            // definition when compiling for other OSes. It doesn't do anything when compiling for Linux.
            buf: [8192]u8 align(if (builtin.os.tag != .linux) 1 else @alignOf(os.linux.dirent64)),
            index: usize,
            end_index: usize,

            const Self = @This();

            pub const Error = IteratorError;

            /// Memory such as file names referenced in this returned entry becomes invalid
            /// with subsequent calls to `next`, as well as when this `Dir` is deinitialized.
            pub fn next(self: *Self) Error!?Entry {
                start_over: while (true) {
                    if (self.index >= self.end_index) {
                        const rc = os.linux.getdents64(self.dir.fd, &self.buf, self.buf.len);
                        switch (os.linux.getErrno(rc)) {
                            0 => {},
                            os.EBADF => unreachable, // Dir is invalid or was opened without iteration ability
                            os.EFAULT => unreachable,
                            os.ENOTDIR => unreachable,
                            os.EINVAL => unreachable,
                            else => |err| return os.unexpectedErrno(err),
                        }
                        if (rc == 0) return null;
                        self.index = 0;
                        self.end_index = rc;
                    }
                    const linux_entry = @ptrCast(*align(1) os.dirent64, &self.buf[self.index]);
                    const next_index = self.index + linux_entry.reclen();
                    self.index = next_index;

                    const name = mem.spanZ(@ptrCast([*:0]u8, &linux_entry.d_name));

                    // skip . and .. entries
                    if (mem.eql(u8, name, ".") or mem.eql(u8, name, "..")) {
                        continue :start_over;
                    }

                    const entry_kind = switch (linux_entry.d_type) {
                        os.DT_BLK => Entry.Kind.BlockDevice,
                        os.DT_CHR => Entry.Kind.CharacterDevice,
                        os.DT_DIR => Entry.Kind.Directory,
                        os.DT_FIFO => Entry.Kind.NamedPipe,
                        os.DT_LNK => Entry.Kind.SymLink,
                        os.DT_REG => Entry.Kind.File,
                        os.DT_SOCK => Entry.Kind.UnixDomainSocket,
                        else => Entry.Kind.Unknown,
                    };
                    return Entry{
                        .name = name,
                        .kind = entry_kind,
                    };
                }
            }
        },
        .windows => struct {
            dir: Dir,
            buf: [8192]u8 align(@alignOf(os.windows.FILE_BOTH_DIR_INFORMATION)),
            index: usize,
            end_index: usize,
            first: bool,
            name_data: [256]u8,

            const Self = @This();

            pub const Error = IteratorError;

            /// Memory such as file names referenced in this returned entry becomes invalid
            /// with subsequent calls to `next`, as well as when this `Dir` is deinitialized.
            pub fn next(self: *Self) Error!?Entry {
                while (true) {
                    const w = os.windows;
                    if (self.index >= self.end_index) {
                        var io: w.IO_STATUS_BLOCK = undefined;
                        const rc = w.ntdll.NtQueryDirectoryFile(
                            self.dir.fd,
                            null,
                            null,
                            null,
                            &io,
                            &self.buf,
                            self.buf.len,
                            .FileBothDirectoryInformation,
                            w.FALSE,
                            null,
                            if (self.first) @as(w.BOOLEAN, w.TRUE) else @as(w.BOOLEAN, w.FALSE),
                        );
                        self.first = false;
                        if (io.Information == 0) return null;
                        self.index = 0;
                        self.end_index = io.Information;
                        switch (rc) {
                            .SUCCESS => {},
                            .ACCESS_DENIED => return error.AccessDenied, // Double-check that the Dir was opened with iteration ability

                            else => return w.unexpectedStatus(rc),
                        }
                    }

                    const aligned_ptr = @alignCast(@alignOf(w.FILE_BOTH_DIR_INFORMATION), &self.buf[self.index]);
                    const dir_info = @ptrCast(*w.FILE_BOTH_DIR_INFORMATION, aligned_ptr);
                    if (dir_info.NextEntryOffset != 0) {
                        self.index += dir_info.NextEntryOffset;
                    } else {
                        self.index = self.buf.len;
                    }

                    const name_utf16le = @ptrCast([*]u16, &dir_info.FileName)[0 .. dir_info.FileNameLength / 2];

                    if (mem.eql(u16, name_utf16le, &[_]u16{'.'}) or mem.eql(u16, name_utf16le, &[_]u16{ '.', '.' }))
                        continue;
                    // Trust that Windows gives us valid UTF-16LE
                    const name_utf8_len = std.unicode.utf16leToUtf8(self.name_data[0..], name_utf16le) catch unreachable;
                    const name_utf8 = self.name_data[0..name_utf8_len];
                    const kind = blk: {
                        const attrs = dir_info.FileAttributes;
                        if (attrs & w.FILE_ATTRIBUTE_DIRECTORY != 0) break :blk Entry.Kind.Directory;
                        if (attrs & w.FILE_ATTRIBUTE_REPARSE_POINT != 0) break :blk Entry.Kind.SymLink;
                        break :blk Entry.Kind.File;
                    };
                    return Entry{
                        .name = name_utf8,
                        .kind = kind,
                    };
                }
            }
        },
        .wasi => struct {
            dir: Dir,
            buf: [8192]u8, // TODO align(@alignOf(os.wasi.dirent_t)),
            cookie: u64,
            index: usize,
            end_index: usize,

            const Self = @This();

            pub const Error = IteratorError;

            /// Memory such as file names referenced in this returned entry becomes invalid
            /// with subsequent calls to `next`, as well as when this `Dir` is deinitialized.
            pub fn next(self: *Self) Error!?Entry {
                const w = os.wasi;
                start_over: while (true) {
                    if (self.index >= self.end_index) {
                        var bufused: usize = undefined;
                        switch (w.fd_readdir(self.dir.fd, &self.buf, self.buf.len, self.cookie, &bufused)) {
                            w.ESUCCESS => {},
                            w.EBADF => unreachable, // Dir is invalid or was opened without iteration ability
                            w.EFAULT => unreachable,
                            w.ENOTDIR => unreachable,
                            w.EINVAL => unreachable,
                            w.ENOTCAPABLE => return error.AccessDenied,
                            else => |err| return os.unexpectedErrno(err),
                        }
                        if (bufused == 0) return null;
                        self.index = 0;
                        self.end_index = bufused;
                    }
                    const entry = @ptrCast(*align(1) w.dirent_t, &self.buf[self.index]);
                    const entry_size = @sizeOf(w.dirent_t);
                    const name_index = self.index + entry_size;
                    const name = mem.span(self.buf[name_index .. name_index + entry.d_namlen]);

                    const next_index = name_index + entry.d_namlen;
                    self.index = next_index;
                    self.cookie = entry.d_next;

                    // skip . and .. entries
                    if (mem.eql(u8, name, ".") or mem.eql(u8, name, "..")) {
                        continue :start_over;
                    }

                    const entry_kind = switch (entry.d_type) {
                        w.FILETYPE_BLOCK_DEVICE => Entry.Kind.BlockDevice,
                        w.FILETYPE_CHARACTER_DEVICE => Entry.Kind.CharacterDevice,
                        w.FILETYPE_DIRECTORY => Entry.Kind.Directory,
                        w.FILETYPE_SYMBOLIC_LINK => Entry.Kind.SymLink,
                        w.FILETYPE_REGULAR_FILE => Entry.Kind.File,
                        w.FILETYPE_SOCKET_STREAM, wasi.FILETYPE_SOCKET_DGRAM => Entry.Kind.UnixDomainSocket,
                        else => Entry.Kind.Unknown,
                    };
                    return Entry{
                        .name = name,
                        .kind = entry_kind,
                    };
                }
            }
        },
        else => @compileError("unimplemented"),
    };

    pub fn iterate(self: Dir) Iterator {
        switch (builtin.os.tag) {
            .macos,
            .ios,
            .freebsd,
            .netbsd,
            .dragonfly,
            .openbsd,
            => return Iterator{
                .dir = self,
                .seek = 0,
                .index = 0,
                .end_index = 0,
                .buf = undefined,
            },
            .linux, .haiku => return Iterator{
                .dir = self,
                .index = 0,
                .end_index = 0,
                .buf = undefined,
            },
            .windows => return Iterator{
                .dir = self,
                .index = 0,
                .end_index = 0,
                .first = true,
                .buf = undefined,
                .name_data = undefined,
            },
            .wasi => return Iterator{
                .dir = self,
                .cookie = os.wasi.DIRCOOKIE_START,
                .index = 0,
                .end_index = 0,
                .buf = undefined,
            },
            else => @compileError("unimplemented"),
        }
    }

    pub const Walker = struct {
        stack: std.ArrayList(StackItem),
        name_buffer: std.ArrayList(u8),

        pub const WalkerEntry = struct {
            /// The containing directory. This can be used to operate directly on `basename`
            /// rather than `path`, avoiding `error.NameTooLong` for deeply nested paths.
            /// The directory remains open until `next` or `deinit` is called.
            dir: Dir,
            basename: []const u8,
            path: []const u8,
            kind: Dir.Entry.Kind,
        };

        const StackItem = struct {
            iter: Dir.Iterator,
            dirname_len: usize,
        };

        /// After each call to this function, and on deinit(), the memory returned
        /// from this function becomes invalid. A copy must be made in order to keep
        /// a reference to the path.
        pub fn next(self: *Walker) !?WalkerEntry {
            while (self.stack.items.len != 0) {
                // `top` becomes invalid after appending to `self.stack`
                var top = &self.stack.items[self.stack.items.len - 1];
                const dirname_len = top.dirname_len;
                if (try top.iter.next()) |base| {
                    self.name_buffer.shrinkRetainingCapacity(dirname_len);
                    try self.name_buffer.append(path.sep);
                    try self.name_buffer.appendSlice(base.name);
                    if (base.kind == .Directory) {
                        var new_dir = top.iter.dir.openDir(base.name, .{ .iterate = true }) catch |err| switch (err) {
                            error.NameTooLong => unreachable, // no path sep in base.name
                            else => |e| return e,
                        };
                        {
                            errdefer new_dir.close();
                            try self.stack.append(StackItem{
                                .iter = new_dir.iterate(),
                                .dirname_len = self.name_buffer.items.len,
                            });
                            top = &self.stack.items[self.stack.items.len - 1];
                        }
                    }
                    return WalkerEntry{
                        .dir = top.iter.dir,
                        .basename = self.name_buffer.items[dirname_len + 1 ..],
                        .path = self.name_buffer.items,
                        .kind = base.kind,
                    };
                } else {
                    self.stack.pop().iter.dir.close();
                }
            }
            return null;
        }

        pub fn deinit(self: *Walker) void {
            while (self.stack.popOrNull()) |*item| item.iter.dir.close();
            self.stack.deinit();
            self.name_buffer.deinit();
        }
    };

    /// Recursively iterates over a directory.
    /// Must call `Walker.deinit` when done.
    /// The order of returned file system entries is undefined.
    pub fn walk(self: Dir, allocator: *Allocator) !Walker {
        var name_buffer = std.ArrayList(u8).init(allocator);
        errdefer name_buffer.deinit();

        var stack = std.ArrayList(Walker.StackItem).init(allocator);
        errdefer stack.deinit();

        try stack.append(Walker.StackItem{
            .iter = self.iterate(),
            .dirname_len = 0,
        });

        return Walker{
            .stack = stack,
            .name_buffer = name_buffer,
        };
    }

    pub const OpenError = error{
        FileNotFound,
        NotDir,
        AccessDenied,
        SymLinkLoop,
        ProcessFdQuotaExceeded,
        NameTooLong,
        SystemFdQuotaExceeded,
        NoDevice,
        SystemResources,
        InvalidUtf8,
        BadPathName,
        DeviceBusy,
    } || os.UnexpectedError;

    pub fn close(self: *Dir) void {
        if (need_async_thread) {
            std.event.Loop.instance.?.close(self.fd);
        } else {
            os.close(self.fd);
        }
        self.* = undefined;
    }

    /// Opens a file for reading or writing, without attempting to create a new file.
    /// To create a new file, see `createFile`.
    /// Call `File.close` to release the resource.
    /// Asserts that the path parameter has no null bytes.
    pub fn openFile(self: Dir, sub_path: []const u8, flags: File.OpenFlags) File.OpenError!File {
        if (builtin.os.tag == .windows) {
            const path_w = try os.windows.sliceToPrefixedFileW(sub_path);
            return self.openFileW(path_w.span(), flags);
        }
        if (builtin.os.tag == .wasi) {
            return self.openFileWasi(sub_path, flags);
        }
        const path_c = try os.toPosixPath(sub_path);
        return self.openFileZ(&path_c, flags);
    }

    /// Same as `openFile` but WASI only.
    pub fn openFileWasi(self: Dir, sub_path: []const u8, flags: File.OpenFlags) File.OpenError!File {
        const w = os.wasi;
        var fdflags: w.fdflags_t = 0x0;
        var base: w.rights_t = 0x0;
        if (flags.read) {
            base |= w.RIGHT_FD_READ | w.RIGHT_FD_TELL | w.RIGHT_FD_SEEK | w.RIGHT_FD_FILESTAT_GET;
        }
        if (flags.write) {
            fdflags |= w.FDFLAG_APPEND;
            base |= w.RIGHT_FD_WRITE |
                w.RIGHT_FD_TELL |
                w.RIGHT_FD_SEEK |
                w.RIGHT_FD_DATASYNC |
                w.RIGHT_FD_FDSTAT_SET_FLAGS |
                w.RIGHT_FD_SYNC |
                w.RIGHT_FD_ALLOCATE |
                w.RIGHT_FD_ADVISE |
                w.RIGHT_FD_FILESTAT_SET_TIMES |
                w.RIGHT_FD_FILESTAT_SET_SIZE;
        }
        const fd = try os.openatWasi(self.fd, sub_path, 0x0, 0x0, fdflags, base, 0x0);
        return File{ .handle = fd };
    }

    pub const openFileC = @compileError("deprecated: renamed to openFileZ");

    /// Same as `openFile` but the path parameter is null-terminated.
    pub fn openFileZ(self: Dir, sub_path: [*:0]const u8, flags: File.OpenFlags) File.OpenError!File {
        if (builtin.os.tag == .windows) {
            const path_w = try os.windows.cStrToPrefixedFileW(sub_path);
            return self.openFileW(path_w.span(), flags);
        }

        var os_flags: u32 = os.O_CLOEXEC;
        // Use the O_ locking flags if the os supports them to acquire the lock
        // atomically.
        const has_flock_open_flags = @hasDecl(os, "O_EXLOCK");
        if (has_flock_open_flags) {
            // Note that the O_NONBLOCK flag is removed after the openat() call
            // is successful.
            const nonblocking_lock_flag: u32 = if (flags.lock_nonblocking)
                os.O_NONBLOCK
            else
                0;
            os_flags |= switch (flags.lock) {
                .None => @as(u32, 0),
                .Shared => os.O_SHLOCK | nonblocking_lock_flag,
                .Exclusive => os.O_EXLOCK | nonblocking_lock_flag,
            };
        }
        if (@hasDecl(os, "O_LARGEFILE")) {
            os_flags |= os.O_LARGEFILE;
        }
        if (!flags.allow_ctty) {
            os_flags |= os.O_NOCTTY;
        }
        os_flags |= if (flags.write and flags.read)
            @as(u32, os.O_RDWR)
        else if (flags.write)
            @as(u32, os.O_WRONLY)
        else
            @as(u32, os.O_RDONLY);
        const fd = if (flags.intended_io_mode != .blocking)
            try std.event.Loop.instance.?.openatZ(self.fd, sub_path, os_flags, 0)
        else
            try os.openatZ(self.fd, sub_path, os_flags, 0);
        errdefer os.close(fd);

        if (!has_flock_open_flags and flags.lock != .None) {
            // TODO: integrate async I/O
            const lock_nonblocking = if (flags.lock_nonblocking) os.LOCK_NB else @as(i32, 0);
            try os.flock(fd, switch (flags.lock) {
                .None => unreachable,
                .Shared => os.LOCK_SH | lock_nonblocking,
                .Exclusive => os.LOCK_EX | lock_nonblocking,
            });
        }

        if (has_flock_open_flags and flags.lock_nonblocking) {
            var fl_flags = os.fcntl(fd, os.F_GETFL, 0) catch |err| switch (err) {
                error.FileBusy => unreachable,
                error.Locked => unreachable,
                error.PermissionDenied => unreachable,
                else => |e| return e,
            };
            fl_flags &= ~@as(usize, os.O_NONBLOCK);
            _ = os.fcntl(fd, os.F_SETFL, fl_flags) catch |err| switch (err) {
                error.FileBusy => unreachable,
                error.Locked => unreachable,
                error.PermissionDenied => unreachable,
                else => |e| return e,
            };
        }

        return File{
            .handle = fd,
            .capable_io_mode = .blocking,
            .intended_io_mode = flags.intended_io_mode,
        };
    }

    /// Same as `openFile` but Windows-only and the path parameter is
    /// [WTF-16](https://simonsapin.github.io/wtf-8/#potentially-ill-formed-utf-16) encoded.
    pub fn openFileW(self: Dir, sub_path_w: []const u16, flags: File.OpenFlags) File.OpenError!File {
        const w = os.windows;
        const file: File = .{
            .handle = try w.OpenFile(sub_path_w, .{
                .dir = self.fd,
                .access_mask = w.SYNCHRONIZE |
                    (if (flags.read) @as(u32, w.GENERIC_READ) else 0) |
                    (if (flags.write) @as(u32, w.GENERIC_WRITE) else 0),
                .creation = w.FILE_OPEN,
                .io_mode = flags.intended_io_mode,
            }),
            .capable_io_mode = std.io.default_mode,
            .intended_io_mode = flags.intended_io_mode,
        };
        var io: w.IO_STATUS_BLOCK = undefined;
        const range_off: w.LARGE_INTEGER = 0;
        const range_len: w.LARGE_INTEGER = 1;
        const exclusive = switch (flags.lock) {
            .None => return file,
            .Shared => false,
            .Exclusive => true,
        };
        try w.LockFile(
            file.handle,
            null,
            null,
            null,
            &io,
            &range_off,
            &range_len,
            null,
            @boolToInt(flags.lock_nonblocking),
            @boolToInt(exclusive),
        );
        return file;
    }

    /// Creates, opens, or overwrites a file with write access.
    /// Call `File.close` on the result when done.
    /// Asserts that the path parameter has no null bytes.
    pub fn createFile(self: Dir, sub_path: []const u8, flags: File.CreateFlags) File.OpenError!File {
        if (builtin.os.tag == .windows) {
            const path_w = try os.windows.sliceToPrefixedFileW(sub_path);
            return self.createFileW(path_w.span(), flags);
        }
        if (builtin.os.tag == .wasi) {
            return self.createFileWasi(sub_path, flags);
        }
        const path_c = try os.toPosixPath(sub_path);
        return self.createFileZ(&path_c, flags);
    }

    pub const createFileC = @compileError("deprecated: renamed to createFileZ");

    /// Same as `createFile` but WASI only.
    pub fn createFileWasi(self: Dir, sub_path: []const u8, flags: File.CreateFlags) File.OpenError!File {
        const w = os.wasi;
        var oflags = w.O_CREAT;
        var base: w.rights_t = w.RIGHT_FD_WRITE |
            w.RIGHT_FD_DATASYNC |
            w.RIGHT_FD_SEEK |
            w.RIGHT_FD_TELL |
            w.RIGHT_FD_FDSTAT_SET_FLAGS |
            w.RIGHT_FD_SYNC |
            w.RIGHT_FD_ALLOCATE |
            w.RIGHT_FD_ADVISE |
            w.RIGHT_FD_FILESTAT_SET_TIMES |
            w.RIGHT_FD_FILESTAT_SET_SIZE |
            w.RIGHT_FD_FILESTAT_GET;
        if (flags.read) {
            base |= w.RIGHT_FD_READ;
        }
        if (flags.truncate) {
            oflags |= w.O_TRUNC;
        }
        if (flags.exclusive) {
            oflags |= w.O_EXCL;
        }
        const fd = try os.openatWasi(self.fd, sub_path, 0x0, oflags, 0x0, base, 0x0);
        return File{ .handle = fd };
    }

    /// Same as `createFile` but the path parameter is null-terminated.
    pub fn createFileZ(self: Dir, sub_path_c: [*:0]const u8, flags: File.CreateFlags) File.OpenError!File {
        if (builtin.os.tag == .windows) {
            const path_w = try os.windows.cStrToPrefixedFileW(sub_path_c);
            return self.createFileW(path_w.span(), flags);
        }

        // Use the O_ locking flags if the os supports them to acquire the lock
        // atomically.
        const has_flock_open_flags = @hasDecl(os, "O_EXLOCK");
        // Note that the O_NONBLOCK flag is removed after the openat() call
        // is successful.
        const nonblocking_lock_flag: u32 = if (has_flock_open_flags and flags.lock_nonblocking)
            os.O_NONBLOCK
        else
            0;
        const lock_flag: u32 = if (has_flock_open_flags) switch (flags.lock) {
            .None => @as(u32, 0),
            .Shared => os.O_SHLOCK | nonblocking_lock_flag,
            .Exclusive => os.O_EXLOCK | nonblocking_lock_flag,
        } else 0;

        const O_LARGEFILE = if (@hasDecl(os, "O_LARGEFILE")) os.O_LARGEFILE else 0;
        const os_flags = lock_flag | O_LARGEFILE | os.O_CREAT | os.O_CLOEXEC |
            (if (flags.truncate) @as(u32, os.O_TRUNC) else 0) |
            (if (flags.read) @as(u32, os.O_RDWR) else os.O_WRONLY) |
            (if (flags.exclusive) @as(u32, os.O_EXCL) else 0);
        const fd = if (flags.intended_io_mode != .blocking)
            try std.event.Loop.instance.?.openatZ(self.fd, sub_path_c, os_flags, flags.mode)
        else
            try os.openatZ(self.fd, sub_path_c, os_flags, flags.mode);
        errdefer os.close(fd);

        if (!has_flock_open_flags and flags.lock != .None) {
            // TODO: integrate async I/O
            const lock_nonblocking = if (flags.lock_nonblocking) os.LOCK_NB else @as(i32, 0);
            try os.flock(fd, switch (flags.lock) {
                .None => unreachable,
                .Shared => os.LOCK_SH | lock_nonblocking,
                .Exclusive => os.LOCK_EX | lock_nonblocking,
            });
        }

        if (has_flock_open_flags and flags.lock_nonblocking) {
            var fl_flags = os.fcntl(fd, os.F_GETFL, 0) catch |err| switch (err) {
                error.FileBusy => unreachable,
                error.Locked => unreachable,
                error.PermissionDenied => unreachable,
                else => |e| return e,
            };
            fl_flags &= ~@as(usize, os.O_NONBLOCK);
            _ = os.fcntl(fd, os.F_SETFL, fl_flags) catch |err| switch (err) {
                error.FileBusy => unreachable,
                error.Locked => unreachable,
                error.PermissionDenied => unreachable,
                else => |e| return e,
            };
        }

        return File{
            .handle = fd,
            .capable_io_mode = .blocking,
            .intended_io_mode = flags.intended_io_mode,
        };
    }

    /// Same as `createFile` but Windows-only and the path parameter is
    /// [WTF-16](https://simonsapin.github.io/wtf-8/#potentially-ill-formed-utf-16) encoded.
    pub fn createFileW(self: Dir, sub_path_w: []const u16, flags: File.CreateFlags) File.OpenError!File {
        const w = os.windows;
        const read_flag = if (flags.read) @as(u32, w.GENERIC_READ) else 0;
        const file: File = .{
            .handle = try os.windows.OpenFile(sub_path_w, .{
                .dir = self.fd,
                .access_mask = w.SYNCHRONIZE | w.GENERIC_WRITE | read_flag,
                .creation = if (flags.exclusive)
                    @as(u32, w.FILE_CREATE)
                else if (flags.truncate)
                    @as(u32, w.FILE_OVERWRITE_IF)
                else
                    @as(u32, w.FILE_OPEN_IF),
                .io_mode = flags.intended_io_mode,
            }),
            .capable_io_mode = std.io.default_mode,
            .intended_io_mode = flags.intended_io_mode,
        };
        var io: w.IO_STATUS_BLOCK = undefined;
        const range_off: w.LARGE_INTEGER = 0;
        const range_len: w.LARGE_INTEGER = 1;
        const exclusive = switch (flags.lock) {
            .None => return file,
            .Shared => false,
            .Exclusive => true,
        };
        try w.LockFile(
            file.handle,
            null,
            null,
            null,
            &io,
            &range_off,
            &range_len,
            null,
            @boolToInt(flags.lock_nonblocking),
            @boolToInt(exclusive),
        );
        return file;
    }

    pub const openRead = @compileError("deprecated in favor of openFile");
    pub const openReadC = @compileError("deprecated in favor of openFileZ");
    pub const openReadW = @compileError("deprecated in favor of openFileW");

    pub fn makeDir(self: Dir, sub_path: []const u8) !void {
        try os.mkdirat(self.fd, sub_path, default_new_dir_mode);
    }

    pub fn makeDirZ(self: Dir, sub_path: [*:0]const u8) !void {
        try os.mkdiratZ(self.fd, sub_path, default_new_dir_mode);
    }

    pub fn makeDirW(self: Dir, sub_path: [*:0]const u16) !void {
        try os.mkdiratW(self.fd, sub_path, default_new_dir_mode);
    }

    /// Calls makeDir recursively to make an entire path. Returns success if the path
    /// already exists and is a directory.
    /// This function is not atomic, and if it returns an error, the file system may
    /// have been modified regardless.
    pub fn makePath(self: Dir, sub_path: []const u8) !void {
        var end_index: usize = sub_path.len;
        while (true) {
            self.makeDir(sub_path[0..end_index]) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    // TODO stat the file and return an error if it's not a directory
                    // this is important because otherwise a dangling symlink
                    // could cause an infinite loop
                    if (end_index == sub_path.len) return;
                },
                error.FileNotFound => {
                    if (end_index == 0) return err;
                    // march end_index backward until next path component
                    while (true) {
                        end_index -= 1;
                        if (path.isSep(sub_path[end_index])) break;
                    }
                    continue;
                },
                else => return err,
            };
            if (end_index == sub_path.len) return;
            // march end_index forward until next path component
            while (true) {
                end_index += 1;
                if (end_index == sub_path.len or path.isSep(sub_path[end_index])) break;
            }
        }
    }

    /// This function performs `makePath`, followed by `openDir`.
    /// If supported by the OS, this operation is atomic. It is not atomic on
    /// all operating systems.
    pub fn makeOpenPath(self: Dir, sub_path: []const u8, open_dir_options: OpenDirOptions) !Dir {
        // TODO improve this implementation on Windows; we can avoid 1 call to NtClose
        try self.makePath(sub_path);
        return self.openDir(sub_path, open_dir_options);
    }

    ///  This function returns the canonicalized absolute pathname of
    /// `pathname` relative to this `Dir`. If `pathname` is absolute, ignores this
    /// `Dir` handle and returns the canonicalized absolute pathname of `pathname`
    /// argument.
    /// This function is not universally supported by all platforms.
    /// Currently supported hosts are: Linux, macOS, and Windows.
    /// See also `Dir.realpathZ`, `Dir.realpathW`, and `Dir.realpathAlloc`.
    pub fn realpath(self: Dir, pathname: []const u8, out_buffer: []u8) ![]u8 {
        if (builtin.os.tag == .wasi) {
            @compileError("realpath is unsupported in WASI");
        }
        if (builtin.os.tag == .windows) {
            const pathname_w = try os.windows.sliceToPrefixedFileW(pathname);
            return self.realpathW(pathname_w.span(), out_buffer);
        }
        const pathname_c = try os.toPosixPath(pathname);
        return self.realpathZ(&pathname_c, out_buffer);
    }

    /// Same as `Dir.realpath` except `pathname` is null-terminated.
    /// See also `Dir.realpath`, `realpathZ`.
    pub fn realpathZ(self: Dir, pathname: [*:0]const u8, out_buffer: []u8) ![]u8 {
        if (builtin.os.tag == .windows) {
            const pathname_w = try os.windows.cStrToPrefixedFileW(pathname);
            return self.realpathW(pathname_w.span(), out_buffer);
        }

        const flags = if (builtin.os.tag == .linux) os.O_PATH | os.O_NONBLOCK | os.O_CLOEXEC else os.O_NONBLOCK | os.O_CLOEXEC;
        const fd = os.openatZ(self.fd, pathname, flags, 0) catch |err| switch (err) {
            error.FileLocksNotSupported => unreachable,
            else => |e| return e,
        };
        defer os.close(fd);

        // Use of MAX_PATH_BYTES here is valid as the realpath function does not
        // have a variant that takes an arbitrary-size buffer.
        // TODO(#4812): Consider reimplementing realpath or using the POSIX.1-2008
        // NULL out parameter (GNU's canonicalize_file_name) to handle overelong
        // paths. musl supports passing NULL but restricts the output to PATH_MAX
        // anyway.
        var buffer: [MAX_PATH_BYTES]u8 = undefined;
        const out_path = try os.getFdPath(fd, &buffer);

        if (out_path.len > out_buffer.len) {
            return error.NameTooLong;
        }

        mem.copy(u8, out_buffer, out_path);

        return out_buffer[0..out_path.len];
    }

    /// Windows-only. Same as `Dir.realpath` except `pathname` is WTF16 encoded.
    /// See also `Dir.realpath`, `realpathW`.
    pub fn realpathW(self: Dir, pathname: []const u16, out_buffer: []u8) ![]u8 {
        const w = os.windows;

        const access_mask = w.GENERIC_READ | w.SYNCHRONIZE;
        const share_access = w.FILE_SHARE_READ;
        const creation = w.FILE_OPEN;
        const h_file = blk: {
            const res = w.OpenFile(pathname, .{
                .dir = self.fd,
                .access_mask = access_mask,
                .share_access = share_access,
                .creation = creation,
                .io_mode = .blocking,
            }) catch |err| switch (err) {
                error.IsDir => break :blk w.OpenFile(pathname, .{
                    .dir = self.fd,
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

        // Use of MAX_PATH_BYTES here is valid as the realpath function does not
        // have a variant that takes an arbitrary-size buffer.
        // TODO(#4812): Consider reimplementing realpath or using the POSIX.1-2008
        // NULL out parameter (GNU's canonicalize_file_name) to handle overelong
        // paths. musl supports passing NULL but restricts the output to PATH_MAX
        // anyway.
        var buffer: [MAX_PATH_BYTES]u8 = undefined;
        const out_path = try os.getFdPath(h_file, &buffer);

        if (out_path.len > out_buffer.len) {
            return error.NameTooLong;
        }

        mem.copy(u8, out_buffer, out_path);

        return out_buffer[0..out_path.len];
    }

    /// Same as `Dir.realpath` except caller must free the returned memory.
    /// See also `Dir.realpath`.
    pub fn realpathAlloc(self: Dir, allocator: *Allocator, pathname: []const u8) ![]u8 {
        // Use of MAX_PATH_BYTES here is valid as the realpath function does not
        // have a variant that takes an arbitrary-size buffer.
        // TODO(#4812): Consider reimplementing realpath or using the POSIX.1-2008
        // NULL out parameter (GNU's canonicalize_file_name) to handle overelong
        // paths. musl supports passing NULL but restricts the output to PATH_MAX
        // anyway.
        var buf: [MAX_PATH_BYTES]u8 = undefined;
        return allocator.dupe(u8, try self.realpath(pathname, buf[0..]));
    }

    /// Changes the current working directory to the open directory handle.
    /// This modifies global state and can have surprising effects in multi-
    /// threaded applications. Most applications and especially libraries should
    /// not call this function as a general rule, however it can have use cases
    /// in, for example, implementing a shell, or child process execution.
    /// Not all targets support this. For example, WASI does not have the concept
    /// of a current working directory.
    pub fn setAsCwd(self: Dir) !void {
        if (builtin.os.tag == .wasi) {
            @compileError("changing cwd is not currently possible in WASI");
        }
        try os.fchdir(self.fd);
    }

    pub const OpenDirOptions = struct {
        /// `true` means the opened directory can be used as the `Dir` parameter
        /// for functions which operate based on an open directory handle. When `false`,
        /// such operations are Illegal Behavior.
        access_sub_paths: bool = true,

        /// `true` means the opened directory can be scanned for the files and sub-directories
        /// of the result. It means the `iterate` function can be called.
        iterate: bool = false,

        /// `true` means it won't dereference the symlinks.
        no_follow: bool = false,
    };

    /// Opens a directory at the given path. The directory is a system resource that remains
    /// open until `close` is called on the result.
    ///
    /// Asserts that the path parameter has no null bytes.
    pub fn openDir(self: Dir, sub_path: []const u8, args: OpenDirOptions) OpenError!Dir {
        if (builtin.os.tag == .windows) {
            const sub_path_w = try os.windows.sliceToPrefixedFileW(sub_path);
            return self.openDirW(sub_path_w.span().ptr, args);
        } else if (builtin.os.tag == .wasi) {
            return self.openDirWasi(sub_path, args);
        } else {
            const sub_path_c = try os.toPosixPath(sub_path);
            return self.openDirZ(&sub_path_c, args);
        }
    }

    pub const openDirC = @compileError("deprecated: renamed to openDirZ");

    /// Same as `openDir` except only WASI.
    pub fn openDirWasi(self: Dir, sub_path: []const u8, args: OpenDirOptions) OpenError!Dir {
        const w = os.wasi;
        var base: w.rights_t = w.RIGHT_FD_FILESTAT_GET | w.RIGHT_FD_FDSTAT_SET_FLAGS | w.RIGHT_FD_FILESTAT_SET_TIMES;
        if (args.access_sub_paths) {
            base |= w.RIGHT_FD_READDIR |
                w.RIGHT_PATH_CREATE_DIRECTORY |
                w.RIGHT_PATH_CREATE_FILE |
                w.RIGHT_PATH_LINK_SOURCE |
                w.RIGHT_PATH_LINK_TARGET |
                w.RIGHT_PATH_OPEN |
                w.RIGHT_PATH_READLINK |
                w.RIGHT_PATH_RENAME_SOURCE |
                w.RIGHT_PATH_RENAME_TARGET |
                w.RIGHT_PATH_FILESTAT_GET |
                w.RIGHT_PATH_FILESTAT_SET_SIZE |
                w.RIGHT_PATH_FILESTAT_SET_TIMES |
                w.RIGHT_PATH_SYMLINK |
                w.RIGHT_PATH_REMOVE_DIRECTORY |
                w.RIGHT_PATH_UNLINK_FILE;
        }
        const symlink_flags: w.lookupflags_t = if (args.no_follow) 0x0 else w.LOOKUP_SYMLINK_FOLLOW;
        // TODO do we really need all the rights here?
        const inheriting: w.rights_t = w.RIGHT_ALL ^ w.RIGHT_SOCK_SHUTDOWN;

        const result = os.openatWasi(self.fd, sub_path, symlink_flags, w.O_DIRECTORY, 0x0, base, inheriting);
        const fd = result catch |err| switch (err) {
            error.FileTooBig => unreachable, // can't happen for directories
            error.IsDir => unreachable, // we're providing O_DIRECTORY
            error.NoSpaceLeft => unreachable, // not providing O_CREAT
            error.PathAlreadyExists => unreachable, // not providing O_CREAT
            error.FileLocksNotSupported => unreachable, // locking folders is not supported
            error.WouldBlock => unreachable, // can't happen for directories
            else => |e| return e,
        };
        return Dir{ .fd = fd };
    }

    /// Same as `openDir` except the parameter is null-terminated.
    pub fn openDirZ(self: Dir, sub_path_c: [*:0]const u8, args: OpenDirOptions) OpenError!Dir {
        if (builtin.os.tag == .windows) {
            const sub_path_w = try os.windows.cStrToPrefixedFileW(sub_path_c);
            return self.openDirW(sub_path_w.span().ptr, args);
        }
        const symlink_flags: u32 = if (args.no_follow) os.O_NOFOLLOW else 0x0;
        if (!args.iterate) {
            const O_PATH = if (@hasDecl(os, "O_PATH")) os.O_PATH else 0;
            return self.openDirFlagsZ(sub_path_c, os.O_DIRECTORY | os.O_RDONLY | os.O_CLOEXEC | O_PATH | symlink_flags);
        } else {
            return self.openDirFlagsZ(sub_path_c, os.O_DIRECTORY | os.O_RDONLY | os.O_CLOEXEC | symlink_flags);
        }
    }

    /// Same as `openDir` except the path parameter is WTF-16 encoded, NT-prefixed.
    /// This function asserts the target OS is Windows.
    pub fn openDirW(self: Dir, sub_path_w: [*:0]const u16, args: OpenDirOptions) OpenError!Dir {
        const w = os.windows;
        // TODO remove some of these flags if args.access_sub_paths is false
        const base_flags = w.STANDARD_RIGHTS_READ | w.FILE_READ_ATTRIBUTES | w.FILE_READ_EA |
            w.SYNCHRONIZE | w.FILE_TRAVERSE;
        const flags: u32 = if (args.iterate) base_flags | w.FILE_LIST_DIRECTORY else base_flags;
        return self.openDirAccessMaskW(sub_path_w, flags, args.no_follow);
    }

    /// `flags` must contain `os.O_DIRECTORY`.
    fn openDirFlagsZ(self: Dir, sub_path_c: [*:0]const u8, flags: u32) OpenError!Dir {
        const result = if (need_async_thread)
            std.event.Loop.instance.?.openatZ(self.fd, sub_path_c, flags, 0)
        else
            os.openatZ(self.fd, sub_path_c, flags, 0);
        const fd = result catch |err| switch (err) {
            error.FileTooBig => unreachable, // can't happen for directories
            error.IsDir => unreachable, // we're providing O_DIRECTORY
            error.NoSpaceLeft => unreachable, // not providing O_CREAT
            error.PathAlreadyExists => unreachable, // not providing O_CREAT
            error.FileLocksNotSupported => unreachable, // locking folders is not supported
            error.WouldBlock => unreachable, // can't happen for directories
            else => |e| return e,
        };
        return Dir{ .fd = fd };
    }

    fn openDirAccessMaskW(self: Dir, sub_path_w: [*:0]const u16, access_mask: u32, no_follow: bool) OpenError!Dir {
        const w = os.windows;

        var result = Dir{
            .fd = undefined,
        };

        const path_len_bytes = @intCast(u16, mem.lenZ(sub_path_w) * 2);
        var nt_name = w.UNICODE_STRING{
            .Length = path_len_bytes,
            .MaximumLength = path_len_bytes,
            .Buffer = @intToPtr([*]u16, @ptrToInt(sub_path_w)),
        };
        var attr = w.OBJECT_ATTRIBUTES{
            .Length = @sizeOf(w.OBJECT_ATTRIBUTES),
            .RootDirectory = if (path.isAbsoluteWindowsW(sub_path_w)) null else self.fd,
            .Attributes = 0, // Note we do not use OBJ_CASE_INSENSITIVE here.
            .ObjectName = &nt_name,
            .SecurityDescriptor = null,
            .SecurityQualityOfService = null,
        };
        const open_reparse_point: w.DWORD = if (no_follow) w.FILE_OPEN_REPARSE_POINT else 0x0;
        var io: w.IO_STATUS_BLOCK = undefined;
        const rc = w.ntdll.NtCreateFile(
            &result.fd,
            access_mask,
            &attr,
            &io,
            null,
            0,
            w.FILE_SHARE_READ | w.FILE_SHARE_WRITE,
            w.FILE_OPEN,
            w.FILE_DIRECTORY_FILE | w.FILE_SYNCHRONOUS_IO_NONALERT | w.FILE_OPEN_FOR_BACKUP_INTENT | open_reparse_point,
            null,
            0,
        );
        switch (rc) {
            .SUCCESS => return result,
            .OBJECT_NAME_INVALID => unreachable,
            .OBJECT_NAME_NOT_FOUND => return error.FileNotFound,
            .OBJECT_PATH_NOT_FOUND => return error.FileNotFound,
            .NOT_A_DIRECTORY => return error.NotDir,
            .INVALID_PARAMETER => unreachable,
            else => return w.unexpectedStatus(rc),
        }
    }

    pub const DeleteFileError = os.UnlinkError;

    /// Delete a file name and possibly the file it refers to, based on an open directory handle.
    /// Asserts that the path parameter has no null bytes.
    pub fn deleteFile(self: Dir, sub_path: []const u8) DeleteFileError!void {
        if (builtin.os.tag == .windows) {
            const sub_path_w = try os.windows.sliceToPrefixedFileW(sub_path);
            return self.deleteFileW(sub_path_w.span());
        } else if (builtin.os.tag == .wasi) {
            os.unlinkatWasi(self.fd, sub_path, 0) catch |err| switch (err) {
                error.DirNotEmpty => unreachable, // not passing AT_REMOVEDIR
                else => |e| return e,
            };
        } else {
            const sub_path_c = try os.toPosixPath(sub_path);
            return self.deleteFileZ(&sub_path_c);
        }
    }

    pub const deleteFileC = @compileError("deprecated: renamed to deleteFileZ");

    /// Same as `deleteFile` except the parameter is null-terminated.
    pub fn deleteFileZ(self: Dir, sub_path_c: [*:0]const u8) DeleteFileError!void {
        os.unlinkatZ(self.fd, sub_path_c, 0) catch |err| switch (err) {
            error.DirNotEmpty => unreachable, // not passing AT_REMOVEDIR
            error.AccessDenied => |e| switch (builtin.os.tag) {
                // non-Linux POSIX systems return EPERM when trying to delete a directory, so
                // we need to handle that case specifically and translate the error
                .macos, .ios, .freebsd, .netbsd, .dragonfly, .openbsd => {
                    // Don't follow symlinks to match unlinkat (which acts on symlinks rather than follows them)
                    const fstat = os.fstatatZ(self.fd, sub_path_c, os.AT_SYMLINK_NOFOLLOW) catch return e;
                    const is_dir = fstat.mode & os.S_IFMT == os.S_IFDIR;
                    return if (is_dir) error.IsDir else e;
                },
                else => return e,
            },
            else => |e| return e,
        };
    }

    /// Same as `deleteFile` except the parameter is WTF-16 encoded.
    pub fn deleteFileW(self: Dir, sub_path_w: []const u16) DeleteFileError!void {
        os.unlinkatW(self.fd, sub_path_w, 0) catch |err| switch (err) {
            error.DirNotEmpty => unreachable, // not passing AT_REMOVEDIR
            else => |e| return e,
        };
    }

    pub const DeleteDirError = error{
        DirNotEmpty,
        FileNotFound,
        AccessDenied,
        FileBusy,
        FileSystem,
        SymLinkLoop,
        NameTooLong,
        NotDir,
        SystemResources,
        ReadOnlyFileSystem,
        InvalidUtf8,
        BadPathName,
        Unexpected,
    };

    /// Returns `error.DirNotEmpty` if the directory is not empty.
    /// To delete a directory recursively, see `deleteTree`.
    /// Asserts that the path parameter has no null bytes.
    pub fn deleteDir(self: Dir, sub_path: []const u8) DeleteDirError!void {
        if (builtin.os.tag == .windows) {
            const sub_path_w = try os.windows.sliceToPrefixedFileW(sub_path);
            return self.deleteDirW(sub_path_w.span());
        } else if (builtin.os.tag == .wasi) {
            os.unlinkat(self.fd, sub_path, os.AT_REMOVEDIR) catch |err| switch (err) {
                error.IsDir => unreachable, // not possible since we pass AT_REMOVEDIR
                else => |e| return e,
            };
        } else {
            const sub_path_c = try os.toPosixPath(sub_path);
            return self.deleteDirZ(&sub_path_c);
        }
    }

    /// Same as `deleteDir` except the parameter is null-terminated.
    pub fn deleteDirZ(self: Dir, sub_path_c: [*:0]const u8) DeleteDirError!void {
        os.unlinkatZ(self.fd, sub_path_c, os.AT_REMOVEDIR) catch |err| switch (err) {
            error.IsDir => unreachable, // not possible since we pass AT_REMOVEDIR
            else => |e| return e,
        };
    }

    /// Same as `deleteDir` except the parameter is UTF16LE, NT prefixed.
    /// This function is Windows-only.
    pub fn deleteDirW(self: Dir, sub_path_w: []const u16) DeleteDirError!void {
        os.unlinkatW(self.fd, sub_path_w, os.AT_REMOVEDIR) catch |err| switch (err) {
            error.IsDir => unreachable, // not possible since we pass AT_REMOVEDIR
            else => |e| return e,
        };
    }

    pub const RenameError = os.RenameError;

    /// Change the name or location of a file or directory.
    /// If new_sub_path already exists, it will be replaced.
    /// Renaming a file over an existing directory or a directory
    /// over an existing file will fail with `error.IsDir` or `error.NotDir`
    pub fn rename(self: Dir, old_sub_path: []const u8, new_sub_path: []const u8) RenameError!void {
        return os.renameat(self.fd, old_sub_path, self.fd, new_sub_path);
    }

    /// Same as `rename` except the parameters are null-terminated.
    pub fn renameZ(self: Dir, old_sub_path_z: [*:0]const u8, new_sub_path_z: [*:0]const u8) RenameError!void {
        return os.renameatZ(self.fd, old_sub_path_z, self.fd, new_sub_path_z);
    }

    /// Same as `rename` except the parameters are UTF16LE, NT prefixed.
    /// This function is Windows-only.
    pub fn renameW(self: Dir, old_sub_path_w: []const u16, new_sub_path_w: []const u16) RenameError!void {
        return os.renameatW(self.fd, old_sub_path_w, self.fd, new_sub_path_w);
    }

    /// Creates a symbolic link named `sym_link_path` which contains the string `target_path`.
    /// A symbolic link (also known as a soft link) may point to an existing file or to a nonexistent
    /// one; the latter case is known as a dangling link.
    /// If `sym_link_path` exists, it will not be overwritten.
    pub fn symLink(
        self: Dir,
        target_path: []const u8,
        sym_link_path: []const u8,
        flags: SymLinkFlags,
    ) !void {
        if (builtin.os.tag == .wasi) {
            return self.symLinkWasi(target_path, sym_link_path, flags);
        }
        if (builtin.os.tag == .windows) {
            const target_path_w = try os.windows.sliceToPrefixedFileW(target_path);
            const sym_link_path_w = try os.windows.sliceToPrefixedFileW(sym_link_path);
            return self.symLinkW(target_path_w.span(), sym_link_path_w.span(), flags);
        }
        const target_path_c = try os.toPosixPath(target_path);
        const sym_link_path_c = try os.toPosixPath(sym_link_path);
        return self.symLinkZ(&target_path_c, &sym_link_path_c, flags);
    }

    /// WASI-only. Same as `symLink` except targeting WASI.
    pub fn symLinkWasi(
        self: Dir,
        target_path: []const u8,
        sym_link_path: []const u8,
        _: SymLinkFlags,
    ) !void {
        return os.symlinkatWasi(target_path, self.fd, sym_link_path);
    }

    /// Same as `symLink`, except the pathname parameters are null-terminated.
    pub fn symLinkZ(
        self: Dir,
        target_path_c: [*:0]const u8,
        sym_link_path_c: [*:0]const u8,
        flags: SymLinkFlags,
    ) !void {
        if (builtin.os.tag == .windows) {
            const target_path_w = try os.windows.cStrToPrefixedFileW(target_path_c);
            const sym_link_path_w = try os.windows.cStrToPrefixedFileW(sym_link_path_c);
            return self.symLinkW(target_path_w.span(), sym_link_path_w.span(), flags);
        }
        return os.symlinkatZ(target_path_c, self.fd, sym_link_path_c);
    }

    /// Windows-only. Same as `symLink` except the pathname parameters
    /// are null-terminated, WTF16 encoded.
    pub fn symLinkW(
        self: Dir,
        target_path_w: []const u16,
        sym_link_path_w: []const u16,
        flags: SymLinkFlags,
    ) !void {
        return os.windows.CreateSymbolicLink(self.fd, sym_link_path_w, target_path_w, flags.is_directory);
    }

    /// Read value of a symbolic link.
    /// The return value is a slice of `buffer`, from index `0`.
    /// Asserts that the path parameter has no null bytes.
    pub fn readLink(self: Dir, sub_path: []const u8, buffer: []u8) ![]u8 {
        if (builtin.os.tag == .wasi) {
            return self.readLinkWasi(sub_path, buffer);
        }
        if (builtin.os.tag == .windows) {
            const sub_path_w = try os.windows.sliceToPrefixedFileW(sub_path);
            return self.readLinkW(sub_path_w.span(), buffer);
        }
        const sub_path_c = try os.toPosixPath(sub_path);
        return self.readLinkZ(&sub_path_c, buffer);
    }

    pub const readLinkC = @compileError("deprecated: renamed to readLinkZ");

    /// WASI-only. Same as `readLink` except targeting WASI.
    pub fn readLinkWasi(self: Dir, sub_path: []const u8, buffer: []u8) ![]u8 {
        return os.readlinkatWasi(self.fd, sub_path, buffer);
    }

    /// Same as `readLink`, except the `pathname` parameter is null-terminated.
    pub fn readLinkZ(self: Dir, sub_path_c: [*:0]const u8, buffer: []u8) ![]u8 {
        if (builtin.os.tag == .windows) {
            const sub_path_w = try os.windows.cStrToPrefixedFileW(sub_path_c);
            return self.readLinkW(sub_path_w.span(), buffer);
        }
        return os.readlinkatZ(self.fd, sub_path_c, buffer);
    }

    /// Windows-only. Same as `readLink` except the pathname parameter
    /// is null-terminated, WTF16 encoded.
    pub fn readLinkW(self: Dir, sub_path_w: []const u16, buffer: []u8) ![]u8 {
        return os.windows.ReadLink(self.fd, sub_path_w, buffer);
    }

    /// Read all of file contents using a preallocated buffer.
    /// The returned slice has the same pointer as `buffer`. If the length matches `buffer.len`
    /// the situation is ambiguous. It could either mean that the entire file was read, and
    /// it exactly fits the buffer, or it could mean the buffer was not big enough for the
    /// entire file.
    pub fn readFile(self: Dir, file_path: []const u8, buffer: []u8) ![]u8 {
        var file = try self.openFile(file_path, .{});
        defer file.close();

        const end_index = try file.readAll(buffer);
        return buffer[0..end_index];
    }

    /// On success, caller owns returned buffer.
    /// If the file is larger than `max_bytes`, returns `error.FileTooBig`.
    pub fn readFileAlloc(self: Dir, allocator: *mem.Allocator, file_path: []const u8, max_bytes: usize) ![]u8 {
        return self.readFileAllocOptions(allocator, file_path, max_bytes, null, @alignOf(u8), null);
    }

    /// On success, caller owns returned buffer.
    /// If the file is larger than `max_bytes`, returns `error.FileTooBig`.
    /// If `size_hint` is specified the initial buffer size is calculated using
    /// that value, otherwise the effective file size is used instead.
    /// Allows specifying alignment and a sentinel value.
    pub fn readFileAllocOptions(
        self: Dir,
        allocator: *mem.Allocator,
        file_path: []const u8,
        max_bytes: usize,
        size_hint: ?usize,
        comptime alignment: u29,
        comptime optional_sentinel: ?u8,
    ) !(if (optional_sentinel) |s| [:s]align(alignment) u8 else []align(alignment) u8) {
        var file = try self.openFile(file_path, .{});
        defer file.close();

        // If the file size doesn't fit a usize it'll be certainly greater than
        // `max_bytes`
        const stat_size = size_hint orelse math.cast(usize, try file.getEndPos()) catch
            return error.FileTooBig;

        return file.readToEndAllocOptions(allocator, max_bytes, stat_size, alignment, optional_sentinel);
    }

    pub const DeleteTreeError = error{
        AccessDenied,
        FileTooBig,
        SymLinkLoop,
        ProcessFdQuotaExceeded,
        NameTooLong,
        SystemFdQuotaExceeded,
        NoDevice,
        SystemResources,
        ReadOnlyFileSystem,
        FileSystem,
        FileBusy,
        DeviceBusy,

        /// One of the path components was not a directory.
        /// This error is unreachable if `sub_path` does not contain a path separator.
        NotDir,

        /// On Windows, file paths must be valid Unicode.
        InvalidUtf8,

        /// On Windows, file paths cannot contain these characters:
        /// '/', '*', '?', '"', '<', '>', '|'
        BadPathName,
    } || os.UnexpectedError;

    /// Whether `full_path` describes a symlink, file, or directory, this function
    /// removes it. If it cannot be removed because it is a non-empty directory,
    /// this function recursively removes its entries and then tries again.
    /// This operation is not atomic on most file systems.
    pub fn deleteTree(self: Dir, sub_path: []const u8) DeleteTreeError!void {
        start_over: while (true) {
            var got_access_denied = false;

            // First, try deleting the item as a file. This way we don't follow sym links.
            if (self.deleteFile(sub_path)) {
                return;
            } else |err| switch (err) {
                error.FileNotFound => return,
                error.IsDir => {},
                error.AccessDenied => got_access_denied = true,

                error.InvalidUtf8,
                error.SymLinkLoop,
                error.NameTooLong,
                error.SystemResources,
                error.ReadOnlyFileSystem,
                error.NotDir,
                error.FileSystem,
                error.FileBusy,
                error.BadPathName,
                error.Unexpected,
                => |e| return e,
            }
            var dir = self.openDir(sub_path, .{ .iterate = true, .no_follow = true }) catch |err| switch (err) {
                error.NotDir => {
                    if (got_access_denied) {
                        return error.AccessDenied;
                    }
                    continue :start_over;
                },
                error.FileNotFound => {
                    // That's fine, we were trying to remove this directory anyway.
                    continue :start_over;
                },

                error.AccessDenied,
                error.SymLinkLoop,
                error.ProcessFdQuotaExceeded,
                error.NameTooLong,
                error.SystemFdQuotaExceeded,
                error.NoDevice,
                error.SystemResources,
                error.Unexpected,
                error.InvalidUtf8,
                error.BadPathName,
                error.DeviceBusy,
                => |e| return e,
            };
            var cleanup_dir_parent: ?Dir = null;
            defer if (cleanup_dir_parent) |*d| d.close();

            var cleanup_dir = true;
            defer if (cleanup_dir) dir.close();

            // Valid use of MAX_PATH_BYTES because dir_name_buf will only
            // ever store a single path component that was returned from the
            // filesystem.
            var dir_name_buf: [MAX_PATH_BYTES]u8 = undefined;
            var dir_name: []const u8 = sub_path;

            // Here we must avoid recursion, in order to provide O(1) memory guarantee of this function.
            // Go through each entry and if it is not a directory, delete it. If it is a directory,
            // open it, and close the original directory. Repeat. Then start the entire operation over.

            scan_dir: while (true) {
                var dir_it = dir.iterate();
                while (try dir_it.next()) |entry| {
                    if (dir.deleteFile(entry.name)) {
                        continue;
                    } else |err| switch (err) {
                        error.FileNotFound => continue,

                        // Impossible because we do not pass any path separators.
                        error.NotDir => unreachable,

                        error.IsDir => {},
                        error.AccessDenied => got_access_denied = true,

                        error.InvalidUtf8,
                        error.SymLinkLoop,
                        error.NameTooLong,
                        error.SystemResources,
                        error.ReadOnlyFileSystem,
                        error.FileSystem,
                        error.FileBusy,
                        error.BadPathName,
                        error.Unexpected,
                        => |e| return e,
                    }

                    const new_dir = dir.openDir(entry.name, .{ .iterate = true, .no_follow = true }) catch |err| switch (err) {
                        error.NotDir => {
                            if (got_access_denied) {
                                return error.AccessDenied;
                            }
                            continue :scan_dir;
                        },
                        error.FileNotFound => {
                            // That's fine, we were trying to remove this directory anyway.
                            continue :scan_dir;
                        },

                        error.AccessDenied,
                        error.SymLinkLoop,
                        error.ProcessFdQuotaExceeded,
                        error.NameTooLong,
                        error.SystemFdQuotaExceeded,
                        error.NoDevice,
                        error.SystemResources,
                        error.Unexpected,
                        error.InvalidUtf8,
                        error.BadPathName,
                        error.DeviceBusy,
                        => |e| return e,
                    };
                    if (cleanup_dir_parent) |*d| d.close();
                    cleanup_dir_parent = dir;
                    dir = new_dir;
                    mem.copy(u8, &dir_name_buf, entry.name);
                    dir_name = dir_name_buf[0..entry.name.len];
                    continue :scan_dir;
                }
                // Reached the end of the directory entries, which means we successfully deleted all of them.
                // Now to remove the directory itself.
                dir.close();
                cleanup_dir = false;

                if (cleanup_dir_parent) |d| {
                    d.deleteDir(dir_name) catch |err| switch (err) {
                        // These two things can happen due to file system race conditions.
                        error.FileNotFound, error.DirNotEmpty => continue :start_over,
                        else => |e| return e,
                    };
                    continue :start_over;
                } else {
                    self.deleteDir(sub_path) catch |err| switch (err) {
                        error.FileNotFound => return,
                        error.DirNotEmpty => continue :start_over,
                        else => |e| return e,
                    };
                    return;
                }
            }
        }
    }

    /// Writes content to the file system, creating a new file if it does not exist, truncating
    /// if it already exists.
    pub fn writeFile(self: Dir, sub_path: []const u8, data: []const u8) !void {
        var file = try self.createFile(sub_path, .{});
        defer file.close();
        try file.writeAll(data);
    }

    pub const AccessError = os.AccessError;

    /// Test accessing `path`.
    /// `path` is UTF8-encoded.
    /// Be careful of Time-Of-Check-Time-Of-Use race conditions when using this function.
    /// For example, instead of testing if a file exists and then opening it, just
    /// open it and handle the error for file not found.
    pub fn access(self: Dir, sub_path: []const u8, flags: File.OpenFlags) AccessError!void {
        if (builtin.os.tag == .windows) {
            const sub_path_w = try os.windows.sliceToPrefixedFileW(sub_path);
            return self.accessW(sub_path_w.span().ptr, flags);
        }
        const path_c = try os.toPosixPath(sub_path);
        return self.accessZ(&path_c, flags);
    }

    /// Same as `access` except the path parameter is null-terminated.
    pub fn accessZ(self: Dir, sub_path: [*:0]const u8, flags: File.OpenFlags) AccessError!void {
        if (builtin.os.tag == .windows) {
            const sub_path_w = try os.windows.cStrToPrefixedFileW(sub_path);
            return self.accessW(sub_path_w.span().ptr, flags);
        }
        const os_mode = if (flags.write and flags.read)
            @as(u32, os.R_OK | os.W_OK)
        else if (flags.write)
            @as(u32, os.W_OK)
        else
            @as(u32, os.F_OK);
        const result = if (need_async_thread and flags.intended_io_mode != .blocking)
            std.event.Loop.instance.?.faccessatZ(self.fd, sub_path, os_mode, 0)
        else
            os.faccessatZ(self.fd, sub_path, os_mode, 0);
        return result;
    }

    /// Same as `access` except asserts the target OS is Windows and the path parameter is
    /// * WTF-16 encoded
    /// * null-terminated
    /// * NtDll prefixed
    /// TODO currently this ignores `flags`.
    pub fn accessW(self: Dir, sub_path_w: [*:0]const u16, flags: File.OpenFlags) AccessError!void {
        _ = flags;
        return os.faccessatW(self.fd, sub_path_w, 0, 0);
    }

    /// Check the file size, mtime, and mode of `source_path` and `dest_path`. If they are equal, does nothing.
    /// Otherwise, atomically copies `source_path` to `dest_path`. The destination file gains the mtime,
    /// atime, and mode of the source file so that the next call to `updateFile` will not need a copy.
    /// Returns the previous status of the file before updating.
    /// If any of the directories do not exist for dest_path, they are created.
    pub fn updateFile(
        source_dir: Dir,
        source_path: []const u8,
        dest_dir: Dir,
        dest_path: []const u8,
        options: CopyFileOptions,
    ) !PrevStatus {
        var src_file = try source_dir.openFile(source_path, .{});
        defer src_file.close();

        const src_stat = try src_file.stat();
        const actual_mode = options.override_mode orelse src_stat.mode;
        check_dest_stat: {
            const dest_stat = blk: {
                var dest_file = dest_dir.openFile(dest_path, .{}) catch |err| switch (err) {
                    error.FileNotFound => break :check_dest_stat,
                    else => |e| return e,
                };
                defer dest_file.close();

                break :blk try dest_file.stat();
            };

            if (src_stat.size == dest_stat.size and
                src_stat.mtime == dest_stat.mtime and
                actual_mode == dest_stat.mode)
            {
                return PrevStatus.fresh;
            }
        }

        if (path.dirname(dest_path)) |dirname| {
            try dest_dir.makePath(dirname);
        }

        var atomic_file = try dest_dir.atomicFile(dest_path, .{ .mode = actual_mode });
        defer atomic_file.deinit();

        try atomic_file.file.writeFileAll(src_file, .{ .in_len = src_stat.size });
        try atomic_file.file.updateTimes(src_stat.atime, src_stat.mtime);
        try atomic_file.finish();
        return PrevStatus.stale;
    }

    /// Guaranteed to be atomic.
    /// On Linux, until https://patchwork.kernel.org/patch/9636735/ is merged and readily available,
    /// there is a possibility of power loss or application termination leaving temporary files present
    /// in the same directory as dest_path.
    pub fn copyFile(
        source_dir: Dir,
        source_path: []const u8,
        dest_dir: Dir,
        dest_path: []const u8,
        options: CopyFileOptions,
    ) !void {
        var in_file = try source_dir.openFile(source_path, .{});
        defer in_file.close();

        var size: ?u64 = null;
        const mode = options.override_mode orelse blk: {
            const st = try in_file.stat();
            size = st.size;
            break :blk st.mode;
        };

        var atomic_file = try dest_dir.atomicFile(dest_path, .{ .mode = mode });
        defer atomic_file.deinit();

        try copy_file(in_file.handle, atomic_file.file.handle);
        return atomic_file.finish();
    }

    pub const AtomicFileOptions = struct {
        mode: File.Mode = File.default_mode,
    };

    /// Directly access the `.file` field, and then call `AtomicFile.finish`
    /// to atomically replace `dest_path` with contents.
    /// Always call `AtomicFile.deinit` to clean up, regardless of whether `AtomicFile.finish` succeeded.
    /// `dest_path` must remain valid until `AtomicFile.deinit` is called.
    pub fn atomicFile(self: Dir, dest_path: []const u8, options: AtomicFileOptions) !AtomicFile {
        if (path.dirname(dest_path)) |dirname| {
            const dir = try self.openDir(dirname, .{});
            return AtomicFile.init(path.basename(dest_path), options.mode, dir, true);
        } else {
            return AtomicFile.init(dest_path, options.mode, self, false);
        }
    }

    pub const Stat = File.Stat;
    pub const StatError = File.StatError;

    pub fn stat(self: Dir) StatError!Stat {
        const file: File = .{
            .handle = self.fd,
            .capable_io_mode = .blocking,
        };
        return file.stat();
    }
};

/// Returns a handle to the current working directory. It is not opened with iteration capability.
/// Closing the returned `Dir` is checked illegal behavior. Iterating over the result is illegal behavior.
/// On POSIX targets, this function is comptime-callable.
pub fn cwd() Dir {
    if (builtin.os.tag == .windows) {
        return Dir{ .fd = os.windows.peb().ProcessParameters.CurrentDirectory.Handle };
    } else if (builtin.os.tag == .wasi) {
        @compileError("WASI doesn't have a concept of cwd(); use std.fs.wasi.PreopenList to get available Dir handles instead");
    } else {
        return Dir{ .fd = os.AT_FDCWD };
    }
}

/// Opens a directory at the given path. The directory is a system resource that remains
/// open until `close` is called on the result.
/// See `openDirAbsoluteZ` for a function that accepts a null-terminated path.
///
/// Asserts that the path parameter has no null bytes.
pub fn openDirAbsolute(absolute_path: []const u8, flags: Dir.OpenDirOptions) File.OpenError!Dir {
    if (builtin.os.tag == .wasi) {
        @compileError("WASI doesn't have the concept of an absolute directory; use openDir instead for WASI.");
    }
    assert(path.isAbsolute(absolute_path));
    return cwd().openDir(absolute_path, flags);
}

/// Same as `openDirAbsolute` but the path parameter is null-terminated.
pub fn openDirAbsoluteZ(absolute_path_c: [*:0]const u8, flags: Dir.OpenDirOptions) File.OpenError!Dir {
    if (builtin.os.tag == .wasi) {
        @compileError("WASI doesn't have the concept of an absolute directory; use openDir instead for WASI.");
    }
    assert(path.isAbsoluteZ(absolute_path_c));
    return cwd().openDirZ(absolute_path_c, flags);
}
/// Same as `openDirAbsolute` but the path parameter is null-terminated.
pub fn openDirAbsoluteW(absolute_path_c: [*:0]const u16, flags: Dir.OpenDirOptions) File.OpenError!Dir {
    if (builtin.os.tag == .wasi) {
        @compileError("WASI doesn't have the concept of an absolute directory; use openDir instead for WASI.");
    }
    assert(path.isAbsoluteWindowsW(absolute_path_c));
    return cwd().openDirW(absolute_path_c, flags);
}

/// Opens a file for reading or writing, without attempting to create a new file, based on an absolute path.
/// Call `File.close` to release the resource.
/// Asserts that the path is absolute. See `Dir.openFile` for a function that
/// operates on both absolute and relative paths.
/// Asserts that the path parameter has no null bytes. See `openFileAbsoluteZ` for a function
/// that accepts a null-terminated path.
pub fn openFileAbsolute(absolute_path: []const u8, flags: File.OpenFlags) File.OpenError!File {
    assert(path.isAbsolute(absolute_path));
    return cwd().openFile(absolute_path, flags);
}

pub const openFileAbsoluteC = @compileError("deprecated: renamed to openFileAbsoluteZ");

/// Same as `openFileAbsolute` but the path parameter is null-terminated.
pub fn openFileAbsoluteZ(absolute_path_c: [*:0]const u8, flags: File.OpenFlags) File.OpenError!File {
    assert(path.isAbsoluteZ(absolute_path_c));
    return cwd().openFileZ(absolute_path_c, flags);
}

/// Same as `openFileAbsolute` but the path parameter is WTF-16 encoded.
pub fn openFileAbsoluteW(absolute_path_w: []const u16, flags: File.OpenFlags) File.OpenError!File {
    assert(path.isAbsoluteWindowsWTF16(absolute_path_w));
    return cwd().openFileW(absolute_path_w, flags);
}

/// Test accessing `path`.
/// `path` is UTF8-encoded.
/// Be careful of Time-Of-Check-Time-Of-Use race conditions when using this function.
/// For example, instead of testing if a file exists and then opening it, just
/// open it and handle the error for file not found.
/// See `accessAbsoluteZ` for a function that accepts a null-terminated path.
pub fn accessAbsolute(absolute_path: []const u8, flags: File.OpenFlags) Dir.AccessError!void {
    if (builtin.os.tag == .wasi) {
        @compileError("WASI doesn't have the concept of an absolute path; use access instead for WASI.");
    }
    assert(path.isAbsolute(absolute_path));
    try cwd().access(absolute_path, flags);
}
/// Same as `accessAbsolute` but the path parameter is null-terminated.
pub fn accessAbsoluteZ(absolute_path: [*:0]const u8, flags: File.OpenFlags) Dir.AccessError!void {
    if (builtin.os.tag == .wasi) {
        @compileError("WASI doesn't have the concept of an absolute path; use access instead for WASI.");
    }
    assert(path.isAbsoluteZ(absolute_path));
    try cwd().accessZ(absolute_path, flags);
}
/// Same as `accessAbsolute` but the path parameter is WTF-16 encoded.
pub fn accessAbsoluteW(absolute_path: [*:0]const 16, flags: File.OpenFlags) Dir.AccessError!void {
    if (builtin.os.tag == .wasi) {
        @compileError("WASI doesn't have the concept of an absolute path; use access instead for WASI.");
    }
    assert(path.isAbsoluteWindowsW(absolute_path));
    try cwd().accessW(absolute_path, flags);
}

/// Creates, opens, or overwrites a file with write access, based on an absolute path.
/// Call `File.close` to release the resource.
/// Asserts that the path is absolute. See `Dir.createFile` for a function that
/// operates on both absolute and relative paths.
/// Asserts that the path parameter has no null bytes. See `createFileAbsoluteC` for a function
/// that accepts a null-terminated path.
pub fn createFileAbsolute(absolute_path: []const u8, flags: File.CreateFlags) File.OpenError!File {
    assert(path.isAbsolute(absolute_path));
    return cwd().createFile(absolute_path, flags);
}

pub const createFileAbsoluteC = @compileError("deprecated: renamed to createFileAbsoluteZ");

/// Same as `createFileAbsolute` but the path parameter is null-terminated.
pub fn createFileAbsoluteZ(absolute_path_c: [*:0]const u8, flags: File.CreateFlags) File.OpenError!File {
    assert(path.isAbsoluteZ(absolute_path_c));
    return cwd().createFileZ(absolute_path_c, flags);
}

/// Same as `createFileAbsolute` but the path parameter is WTF-16 encoded.
pub fn createFileAbsoluteW(absolute_path_w: [*:0]const u16, flags: File.CreateFlags) File.OpenError!File {
    assert(path.isAbsoluteWindowsW(absolute_path_w));
    return cwd().createFileW(absolute_path_w, flags);
}

/// Delete a file name and possibly the file it refers to, based on an absolute path.
/// Asserts that the path is absolute. See `Dir.deleteFile` for a function that
/// operates on both absolute and relative paths.
/// Asserts that the path parameter has no null bytes.
pub fn deleteFileAbsolute(absolute_path: []const u8) Dir.DeleteFileError!void {
    assert(path.isAbsolute(absolute_path));
    return cwd().deleteFile(absolute_path);
}

pub const deleteFileAbsoluteC = @compileError("deprecated: renamed to deleteFileAbsoluteZ");

/// Same as `deleteFileAbsolute` except the parameter is null-terminated.
pub fn deleteFileAbsoluteZ(absolute_path_c: [*:0]const u8) Dir.DeleteFileError!void {
    assert(path.isAbsoluteZ(absolute_path_c));
    return cwd().deleteFileZ(absolute_path_c);
}

/// Same as `deleteFileAbsolute` except the parameter is WTF-16 encoded.
pub fn deleteFileAbsoluteW(absolute_path_w: [*:0]const u16) Dir.DeleteFileError!void {
    assert(path.isAbsoluteWindowsW(absolute_path_w));
    return cwd().deleteFileW(absolute_path_w);
}

/// Removes a symlink, file, or directory.
/// This is equivalent to `Dir.deleteTree` with the base directory.
/// Asserts that the path is absolute. See `Dir.deleteTree` for a function that
/// operates on both absolute and relative paths.
/// Asserts that the path parameter has no null bytes.
pub fn deleteTreeAbsolute(absolute_path: []const u8) !void {
    assert(path.isAbsolute(absolute_path));
    const dirname = path.dirname(absolute_path) orelse return error{
        /// Attempt to remove the root file system path.
        /// This error is unreachable if `absolute_path` is relative.
        CannotDeleteRootDirectory,
    }.CannotDeleteRootDirectory;

    var dir = try cwd().openDir(dirname, .{});
    defer dir.close();

    return dir.deleteTree(path.basename(absolute_path));
}

/// Same as `Dir.readLink`, except it asserts the path is absolute.
pub fn readLinkAbsolute(pathname: []const u8, buffer: *[MAX_PATH_BYTES]u8) ![]u8 {
    assert(path.isAbsolute(pathname));
    return os.readlink(pathname, buffer);
}

/// Windows-only. Same as `readlinkW`, except the path parameter is null-terminated, WTF16
/// encoded.
pub fn readlinkAbsoluteW(pathname_w: [*:0]const u16, buffer: *[MAX_PATH_BYTES]u8) ![]u8 {
    assert(path.isAbsoluteWindowsW(pathname_w));
    return os.readlinkW(pathname_w, buffer);
}

/// Same as `readLink`, except the path parameter is null-terminated.
pub fn readLinkAbsoluteZ(pathname_c: [*:0]const u8, buffer: *[MAX_PATH_BYTES]u8) ![]u8 {
    assert(path.isAbsoluteZ(pathname_c));
    return os.readlinkZ(pathname_c, buffer);
}

pub const readLink = @compileError("deprecated; use Dir.readLink or readLinkAbsolute");
pub const readLinkC = @compileError("deprecated; use Dir.readLinkZ or readLinkAbsoluteZ");

/// Use with `Dir.symLink` and `symLinkAbsolute` to specify whether the symlink
/// will point to a file or a directory. This value is ignored on all hosts
/// except Windows where creating symlinks to different resource types, requires
/// different flags. By default, `symLinkAbsolute` is assumed to point to a file.
pub const SymLinkFlags = struct {
    is_directory: bool = false,
};

/// Creates a symbolic link named `sym_link_path` which contains the string `target_path`.
/// A symbolic link (also known as a soft link) may point to an existing file or to a nonexistent
/// one; the latter case is known as a dangling link.
/// If `sym_link_path` exists, it will not be overwritten.
/// See also `symLinkAbsoluteZ` and `symLinkAbsoluteW`.
pub fn symLinkAbsolute(target_path: []const u8, sym_link_path: []const u8, flags: SymLinkFlags) !void {
    if (builtin.os.tag == .wasi) {
        @compileError("symLinkAbsolute is not supported in WASI; use Dir.symLinkWasi instead");
    }
    assert(path.isAbsolute(target_path));
    assert(path.isAbsolute(sym_link_path));
    if (builtin.os.tag == .windows) {
        const target_path_w = try os.windows.sliceToPrefixedFileW(target_path);
        const sym_link_path_w = try os.windows.sliceToPrefixedFileW(sym_link_path);
        return os.windows.CreateSymbolicLink(null, sym_link_path_w.span(), target_path_w.span(), flags.is_directory);
    }
    return os.symlink(target_path, sym_link_path);
}

/// Windows-only. Same as `symLinkAbsolute` except the parameters are null-terminated, WTF16 encoded.
/// Note that this function will by default try creating a symbolic link to a file. If you would
/// like to create a symbolic link to a directory, specify this with `SymLinkFlags{ .is_directory = true }`.
/// See also `symLinkAbsolute`, `symLinkAbsoluteZ`.
pub fn symLinkAbsoluteW(target_path_w: []const u16, sym_link_path_w: []const u16, flags: SymLinkFlags) !void {
    assert(path.isAbsoluteWindowsWTF16(target_path_w));
    assert(path.isAbsoluteWindowsWTF16(sym_link_path_w));
    return os.windows.CreateSymbolicLink(null, sym_link_path_w, target_path_w, flags.is_directory);
}

/// Same as `symLinkAbsolute` except the parameters are null-terminated pointers.
/// See also `symLinkAbsolute`.
pub fn symLinkAbsoluteZ(target_path_c: [*:0]const u8, sym_link_path_c: [*:0]const u8, flags: SymLinkFlags) !void {
    assert(path.isAbsoluteZ(target_path_c));
    assert(path.isAbsoluteZ(sym_link_path_c));
    if (builtin.os.tag == .windows) {
        const target_path_w = try os.windows.cStrToWin32PrefixedFileW(target_path_c);
        const sym_link_path_w = try os.windows.cStrToWin32PrefixedFileW(sym_link_path_c);
        return os.windows.CreateSymbolicLink(sym_link_path_w.span(), target_path_w.span(), flags.is_directory);
    }
    return os.symlinkZ(target_path_c, sym_link_path_c);
}

pub const symLink = @compileError("deprecated: use Dir.symLink or symLinkAbsolute");
pub const symLinkC = @compileError("deprecated: use Dir.symLinkZ or symLinkAbsoluteZ");

pub const walkPath = @compileError("deprecated: use Dir.walk");

pub const OpenSelfExeError = error{
    SharingViolation,
    PathAlreadyExists,
    FileNotFound,
    AccessDenied,
    PipeBusy,
    NameTooLong,
    /// On Windows, file paths must be valid Unicode.
    InvalidUtf8,
    /// On Windows, file paths cannot contain these characters:
    /// '/', '*', '?', '"', '<', '>', '|'
    BadPathName,
    Unexpected,
} || os.OpenError || SelfExePathError || os.FlockError;

pub fn openSelfExe(flags: File.OpenFlags) OpenSelfExeError!File {
    if (builtin.os.tag == .linux) {
        return openFileAbsoluteZ("/proc/self/exe", flags);
    }
    if (builtin.os.tag == .windows) {
        const wide_slice = selfExePathW();
        const prefixed_path_w = try os.windows.wToPrefixedFileW(wide_slice);
        return cwd().openFileW(prefixed_path_w.span(), flags);
    }
    // Use of MAX_PATH_BYTES here is valid as the resulting path is immediately
    // opened with no modification.
    var buf: [MAX_PATH_BYTES]u8 = undefined;
    const self_exe_path = try selfExePath(&buf);
    buf[self_exe_path.len] = 0;
    return openFileAbsoluteZ(buf[0..self_exe_path.len :0].ptr, flags);
}

pub const SelfExePathError = os.ReadLinkError || os.SysCtlError || os.RealPathError;

/// `selfExePath` except allocates the result on the heap.
/// Caller owns returned memory.
pub fn selfExePathAlloc(allocator: *Allocator) ![]u8 {
    // Use of MAX_PATH_BYTES here is justified as, at least on one tested Linux
    // system, readlink will completely fail to return a result larger than
    // PATH_MAX even if given a sufficiently large buffer. This makes it
    // fundamentally impossible to get the selfExePath of a program running in
    // a very deeply nested directory chain in this way.
    // TODO(#4812): Investigate other systems and whether it is possible to get
    // this path by trying larger and larger buffers until one succeeds.
    var buf: [MAX_PATH_BYTES]u8 = undefined;
    return allocator.dupe(u8, try selfExePath(&buf));
}

/// Get the path to the current executable.
/// If you only need the directory, use selfExeDirPath.
/// If you only want an open file handle, use openSelfExe.
/// This function may return an error if the current executable
/// was deleted after spawning.
/// Returned value is a slice of out_buffer.
///
/// On Linux, depends on procfs being mounted. If the currently executing binary has
/// been deleted, the file path looks something like `/a/b/c/exe (deleted)`.
/// TODO make the return type of this a null terminated pointer
pub fn selfExePath(out_buffer: []u8) SelfExePathError![]u8 {
    if (is_darwin) {
        // Note that _NSGetExecutablePath() will return "a path" to
        // the executable not a "real path" to the executable.
        var symlink_path_buf: [MAX_PATH_BYTES:0]u8 = undefined;
        var u32_len: u32 = MAX_PATH_BYTES + 1; // include the sentinel
        const rc = std.c._NSGetExecutablePath(&symlink_path_buf, &u32_len);
        if (rc != 0) return error.NameTooLong;

        var real_path_buf: [MAX_PATH_BYTES]u8 = undefined;
        const real_path = try std.os.realpathZ(&symlink_path_buf, &real_path_buf);
        if (real_path.len > out_buffer.len) return error.NameTooLong;
        std.mem.copy(u8, out_buffer, real_path);
        return out_buffer[0..real_path.len];
    }
    switch (builtin.os.tag) {
        .linux => return os.readlinkZ("/proc/self/exe", out_buffer),
        .freebsd, .dragonfly => {
            var mib = [4]c_int{ os.CTL_KERN, os.KERN_PROC, os.KERN_PROC_PATHNAME, -1 };
            var out_len: usize = out_buffer.len;
            try os.sysctl(&mib, out_buffer.ptr, &out_len, null, 0);
            // TODO could this slice from 0 to out_len instead?
            return mem.spanZ(std.meta.assumeSentinel(out_buffer.ptr, 0));
        },
        .netbsd => {
            var mib = [4]c_int{ os.CTL_KERN, os.KERN_PROC_ARGS, -1, os.KERN_PROC_PATHNAME };
            var out_len: usize = out_buffer.len;
            try os.sysctl(&mib, out_buffer.ptr, &out_len, null, 0);
            // TODO could this slice from 0 to out_len instead?
            return mem.spanZ(std.meta.assumeSentinel(out_buffer.ptr, 0));
        },
        .openbsd, .haiku => {
            // OpenBSD doesn't support getting the path of a running process, so try to guess it
            if (os.argv.len == 0)
                return error.FileNotFound;

            const argv0 = mem.span(os.argv[0]);
            if (mem.indexOf(u8, argv0, "/") != null) {
                // argv[0] is a path (relative or absolute): use realpath(3) directly
                var real_path_buf: [MAX_PATH_BYTES]u8 = undefined;
                const real_path = try os.realpathZ(os.argv[0], &real_path_buf);
                if (real_path.len > out_buffer.len)
                    return error.NameTooLong;
                mem.copy(u8, out_buffer, real_path);
                return out_buffer[0..real_path.len];
            } else if (argv0.len != 0) {
                // argv[0] is not empty (and not a path): search it inside PATH
                const PATH = std.os.getenvZ("PATH") orelse return error.FileNotFound;
                var path_it = mem.tokenize(PATH, &[_]u8{path.delimiter});
                while (path_it.next()) |a_path| {
                    var resolved_path_buf: [MAX_PATH_BYTES - 1:0]u8 = undefined;
                    const resolved_path = std.fmt.bufPrintZ(&resolved_path_buf, "{s}/{s}", .{
                        a_path,
                        os.argv[0],
                    }) catch continue;

                    var real_path_buf: [MAX_PATH_BYTES]u8 = undefined;
                    if (os.realpathZ(resolved_path, &real_path_buf)) |real_path| {
                        // found a file, and hope it is the right file
                        if (real_path.len > out_buffer.len)
                            return error.NameTooLong;
                        mem.copy(u8, out_buffer, real_path);
                        return out_buffer[0..real_path.len];
                    } else |_| continue;
                }
            }
            return error.FileNotFound;
        },
        .windows => {
            const utf16le_slice = selfExePathW();
            // Trust that Windows gives us valid UTF-16LE.
            const end_index = std.unicode.utf16leToUtf8(out_buffer, utf16le_slice) catch unreachable;
            return out_buffer[0..end_index];
        },
        else => @compileError("std.fs.selfExePath not supported for this target"),
    }
}

/// The result is UTF16LE-encoded.
pub fn selfExePathW() [:0]const u16 {
    const image_path_name = &os.windows.peb().ProcessParameters.ImagePathName;
    return mem.spanZ(std.meta.assumeSentinel(image_path_name.Buffer, 0));
}

/// `selfExeDirPath` except allocates the result on the heap.
/// Caller owns returned memory.
pub fn selfExeDirPathAlloc(allocator: *Allocator) ![]u8 {
    // Use of MAX_PATH_BYTES here is justified as, at least on one tested Linux
    // system, readlink will completely fail to return a result larger than
    // PATH_MAX even if given a sufficiently large buffer. This makes it
    // fundamentally impossible to get the selfExeDirPath of a program running
    // in a very deeply nested directory chain in this way.
    // TODO(#4812): Investigate other systems and whether it is possible to get
    // this path by trying larger and larger buffers until one succeeds.
    var buf: [MAX_PATH_BYTES]u8 = undefined;
    return allocator.dupe(u8, try selfExeDirPath(&buf));
}

/// Get the directory path that contains the current executable.
/// Returned value is a slice of out_buffer.
pub fn selfExeDirPath(out_buffer: []u8) SelfExePathError![]const u8 {
    const self_exe_path = try selfExePath(out_buffer);
    // Assume that the OS APIs return absolute paths, and therefore dirname
    // will not return null.
    return path.dirname(self_exe_path).?;
}

/// `realpath`, except caller must free the returned memory.
/// See also `Dir.realpath`.
pub fn realpathAlloc(allocator: *Allocator, pathname: []const u8) ![]u8 {
    // Use of MAX_PATH_BYTES here is valid as the realpath function does not
    // have a variant that takes an arbitrary-size buffer.
    // TODO(#4812): Consider reimplementing realpath or using the POSIX.1-2008
    // NULL out parameter (GNU's canonicalize_file_name) to handle overelong
    // paths. musl supports passing NULL but restricts the output to PATH_MAX
    // anyway.
    var buf: [MAX_PATH_BYTES]u8 = undefined;
    return allocator.dupe(u8, try os.realpath(pathname, &buf));
}

const CopyFileError = error{SystemResources} || os.CopyFileRangeError || os.SendFileError;

// Transfer all the data between two file descriptors in the most efficient way.
// The copy starts at offset 0, the initial offsets are preserved.
// No metadata is transferred over.
fn copy_file(fd_in: os.fd_t, fd_out: os.fd_t) CopyFileError!void {
    if (comptime std.Target.current.isDarwin()) {
        const rc = os.system.fcopyfile(fd_in, fd_out, null, os.system.COPYFILE_DATA);
        switch (os.errno(rc)) {
            0 => return,
            os.EINVAL => unreachable,
            os.ENOMEM => return error.SystemResources,
            // The source file is not a directory, symbolic link, or regular file.
            // Try with the fallback path before giving up.
            os.ENOTSUP => {},
            else => |err| return os.unexpectedErrno(err),
        }
    }

    if (std.Target.current.os.tag == .linux) {
        // Try copy_file_range first as that works at the FS level and is the
        // most efficient method (if available).
        var offset: u64 = 0;
        cfr_loop: while (true) {
            // The kernel checks the u64 value `offset+count` for overflow, use
            // a 32 bit value so that the syscall won't return EINVAL except for
            // impossibly large files (> 2^64-1 - 2^32-1).
            const amt = try os.copy_file_range(fd_in, offset, fd_out, offset, math.maxInt(u32), 0);
            // Terminate when no data was copied
            if (amt == 0) break :cfr_loop;
            offset += amt;
        }
        return;
    }

    // Sendfile is a zero-copy mechanism iff the OS supports it, otherwise the
    // fallback code will copy the contents chunk by chunk.
    const empty_iovec = [0]os.iovec_const{};
    var offset: u64 = 0;
    sendfile_loop: while (true) {
        const amt = try os.sendfile(fd_out, fd_in, offset, 0, &empty_iovec, &empty_iovec, 0);
        // Terminate when no data was copied
        if (amt == 0) break :sendfile_loop;
        offset += amt;
    }
}

test {
    if (builtin.os.tag != .wasi) {
        _ = makeDirAbsolute;
        _ = makeDirAbsoluteZ;
        _ = copyFileAbsolute;
        _ = updateFileAbsolute;
    }
    _ = Dir.copyFile;
    _ = @import("fs/test.zig");
    _ = @import("fs/path.zig");
    _ = @import("fs/file.zig");
    _ = @import("fs/get_app_data_dir.zig");
    _ = @import("fs/watch.zig");
}
