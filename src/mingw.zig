const std = @import("std");
const Allocator = std.mem.Allocator;
const mem = std.mem;
const path = std.fs.path;
const assert = std.debug.assert;
const log = std.log.scoped(.mingw);

const target_util = @import("target.zig");
const Compilation = @import("Compilation.zig");
const build_options = @import("build_options");
const Cache = @import("Cache.zig");

pub const CRTFile = enum {
    crt2_o,
    dllcrt2_o,
    mingw32_lib,
    msvcrt_os_lib,
    mingwex_lib,
    uuid_lib,
};

pub fn buildCRTFile(comp: *Compilation, crt_file: CRTFile) !void {
    if (!build_options.have_llvm) {
        return error.ZigCompilerNotBuiltWithLLVMExtensions;
    }
    var arena_allocator = std.heap.ArenaAllocator.init(comp.gpa);
    defer arena_allocator.deinit();
    const arena = &arena_allocator.allocator;

    switch (crt_file) {
        .crt2_o => {
            var args = std.ArrayList([]const u8).init(arena);
            try add_cc_args(comp, arena, &args);
            try args.appendSlice(&[_][]const u8{
                "-D_SYSCRT=1",
                "-DCRTDLL=1",
                "-U__CRTDLL__",
                "-D__MSVCRT__",
                // Uncomment these 3 things for crtu
                //"-DUNICODE",
                //"-D_UNICODE",
                //"-DWPRFLAG=1",
            });
            return comp.build_crt_file("crt2", .Obj, &[1]Compilation.CSourceFile{
                .{
                    .src_path = try comp.zig_lib_directory.join(arena, &[_][]const u8{
                        "libc", "mingw", "crt", "crtexe.c",
                    }),
                    .extra_flags = args.items,
                },
            });
        },

        .dllcrt2_o => {
            var args = std.ArrayList([]const u8).init(arena);
            try add_cc_args(comp, arena, &args);
            try args.appendSlice(&[_][]const u8{
                "-D_SYSCRT=1",
                "-DCRTDLL=1",
                "-U__CRTDLL__",
                "-D__MSVCRT__",
            });
            return comp.build_crt_file("dllcrt2", .Obj, &[1]Compilation.CSourceFile{
                .{
                    .src_path = try comp.zig_lib_directory.join(arena, &[_][]const u8{
                        "libc", "mingw", "crt", "crtdll.c",
                    }),
                    .extra_flags = args.items,
                },
            });
        },

        .mingw32_lib => {
            var c_source_files: [mingw32_lib_deps.len]Compilation.CSourceFile = undefined;
            for (mingw32_lib_deps) |dep, i| {
                var args = std.ArrayList([]const u8).init(arena);
                try args.appendSlice(&[_][]const u8{
                    "-DHAVE_CONFIG_H",
                    "-D_SYSCRT=1",
                    "-DCRTDLL=1",

                    "-isystem",
                    try comp.zig_lib_directory.join(arena, &[_][]const u8{
                        "libc", "include", "any-windows-any",
                    }),

                    "-isystem",
                    try comp.zig_lib_directory.join(arena, &[_][]const u8{ "libc", "mingw", "include" }),

                    "-std=gnu99",
                    "-D_CRTBLD",
                    "-D_WIN32_WINNT=0x0f00",
                    "-D__MSVCRT_VERSION__=0x700",
                });
                if (std.mem.eql(u8, dep, "tlssup.c")) {
                    // Can't let LTO drop symbols defined in this file (eg: _tls_index)
                    try args.append("-fno-lto");
                }
                c_source_files[i] = .{
                    .src_path = try comp.zig_lib_directory.join(arena, &[_][]const u8{
                        "libc", "mingw", "crt", dep,
                    }),
                    .extra_flags = args.items,
                };
            }
            return comp.build_crt_file("mingw32", .Lib, &c_source_files);
        },

        .msvcrt_os_lib => {
            const extra_flags = try arena.dupe([]const u8, &[_][]const u8{
                "-DHAVE_CONFIG_H",
                "-D__LIBMSVCRT__",

                "-I",
                try comp.zig_lib_directory.join(arena, &[_][]const u8{ "libc", "mingw", "include" }),

                "-std=gnu99",
                "-D_CRTBLD",
                "-D_WIN32_WINNT=0x0f00",
                "-D__MSVCRT_VERSION__=0x700",

                "-isystem",
                try comp.zig_lib_directory.join(arena, &[_][]const u8{ "libc", "include", "any-windows-any" }),
            });
            var c_source_files = std.ArrayList(Compilation.CSourceFile).init(arena);

            for (msvcrt_common_src) |dep| {
                (try c_source_files.addOne()).* = .{
                    .src_path = try comp.zig_lib_directory.join(arena, &[_][]const u8{ "libc", "mingw", dep }),
                    .extra_flags = extra_flags,
                };
            }
            if (comp.getTarget().cpu.arch == .i386) {
                for (msvcrt_i386_src) |dep| {
                    (try c_source_files.addOne()).* = .{
                        .src_path = try comp.zig_lib_directory.join(arena, &[_][]const u8{
                            "libc", "mingw", dep,
                        }),
                        .extra_flags = extra_flags,
                    };
                }
            } else {
                for (msvcrt_other_src) |dep| {
                    (try c_source_files.addOne()).* = .{
                        .src_path = try comp.zig_lib_directory.join(arena, &[_][]const u8{
                            "libc", "mingw", dep,
                        }),
                        .extra_flags = extra_flags,
                    };
                }
            }
            return comp.build_crt_file("msvcrt-os", .Lib, c_source_files.items);
        },

        .mingwex_lib => {
            const extra_flags = try arena.dupe([]const u8, &[_][]const u8{
                "-DHAVE_CONFIG_H",

                "-I",
                try comp.zig_lib_directory.join(arena, &[_][]const u8{ "libc", "mingw" }),

                "-I",
                try comp.zig_lib_directory.join(arena, &[_][]const u8{ "libc", "mingw", "include" }),

                "-std=gnu99",
                "-D_CRTBLD",
                "-D_WIN32_WINNT=0x0f00",
                "-D__MSVCRT_VERSION__=0x700",

                "-isystem",
                try comp.zig_lib_directory.join(arena, &[_][]const u8{ "libc", "include", "any-windows-any" }),
            });
            var c_source_files = std.ArrayList(Compilation.CSourceFile).init(arena);

            for (mingwex_generic_src) |dep| {
                (try c_source_files.addOne()).* = .{
                    .src_path = try comp.zig_lib_directory.join(arena, &[_][]const u8{
                        "libc", "mingw", dep,
                    }),
                    .extra_flags = extra_flags,
                };
            }
            const target = comp.getTarget();
            if (target.cpu.arch == .i386 or target.cpu.arch == .x86_64) {
                for (mingwex_x86_src) |dep| {
                    (try c_source_files.addOne()).* = .{
                        .src_path = try comp.zig_lib_directory.join(arena, &[_][]const u8{
                            "libc", "mingw", dep,
                        }),
                        .extra_flags = extra_flags,
                    };
                }
            } else if (target.cpu.arch.isARM()) {
                if (target.cpu.arch.ptrBitWidth() == 32) {
                    for (mingwex_arm32_src) |dep| {
                        (try c_source_files.addOne()).* = .{
                            .src_path = try comp.zig_lib_directory.join(arena, &[_][]const u8{
                                "libc", "mingw", dep,
                            }),
                            .extra_flags = extra_flags,
                        };
                    }
                } else {
                    for (mingwex_arm64_src) |dep| {
                        (try c_source_files.addOne()).* = .{
                            .src_path = try comp.zig_lib_directory.join(arena, &[_][]const u8{
                                "libc", "mingw", dep,
                            }),
                            .extra_flags = extra_flags,
                        };
                    }
                }
            } else {
                unreachable;
            }
            return comp.build_crt_file("mingwex", .Lib, c_source_files.items);
        },

        .uuid_lib => {
            const extra_flags = try arena.dupe([]const u8, &[_][]const u8{
                "-DHAVE_CONFIG_H",

                "-I",
                try comp.zig_lib_directory.join(arena, &[_][]const u8{ "libc", "mingw" }),

                "-I",
                try comp.zig_lib_directory.join(arena, &[_][]const u8{ "libc", "mingw", "include" }),

                "-std=gnu99",
                "-D_CRTBLD",
                "-D_WIN32_WINNT=0x0f00",
                "-D__MSVCRT_VERSION__=0x700",

                "-isystem",
                try comp.zig_lib_directory.join(arena, &[_][]const u8{
                    "libc", "include", "any-windows-any",
                }),
            });
            var c_source_files: [uuid_src.len]Compilation.CSourceFile = undefined;
            for (uuid_src) |dep, i| {
                c_source_files[i] = .{
                    .src_path = try comp.zig_lib_directory.join(arena, &[_][]const u8{
                        "libc", "mingw", "libsrc", dep,
                    }),
                    .extra_flags = extra_flags,
                };
            }
            return comp.build_crt_file("uuid", .Lib, &c_source_files);
        },
    }
}

fn add_cc_args(
    comp: *Compilation,
    arena: *Allocator,
    args: *std.ArrayList([]const u8),
) error{OutOfMemory}!void {
    try args.appendSlice(&[_][]const u8{
        "-DHAVE_CONFIG_H",

        "-I",
        try comp.zig_lib_directory.join(arena, &[_][]const u8{ "libc", "mingw", "include" }),

        "-isystem",
        try comp.zig_lib_directory.join(arena, &[_][]const u8{ "libc", "include", "any-windows-any" }),
    });

    const target = comp.getTarget();
    if (target.cpu.arch.isARM() and target.cpu.arch.ptrBitWidth() == 32) {
        try args.append("-mfpu=vfp");
    }

    try args.appendSlice(&[_][]const u8{
        "-std=gnu11",
        "-D_CRTBLD",
        "-D_WIN32_WINNT=0x0f00",
        "-D__MSVCRT_VERSION__=0x700",
    });
}

pub fn buildImportLib(comp: *Compilation, lib_name: []const u8) !void {
    var arena_allocator = std.heap.ArenaAllocator.init(comp.gpa);
    defer arena_allocator.deinit();
    const arena = &arena_allocator.allocator;

    const def_file_path = findDef(comp, arena, lib_name) catch |err| switch (err) {
        error.FileNotFound => {
            log.debug("no {s}.def file available to make a DLL import {s}.lib", .{ lib_name, lib_name });
            // In this case we will end up putting foo.lib onto the linker line and letting the linker
            // use its library paths to look for libraries and report any problems.
            return;
        },
        else => |e| return e,
    };

    // We need to invoke `zig clang` to use the preprocessor.
    if (!build_options.have_llvm) return error.ZigCompilerNotBuiltWithLLVMExtensions;
    const self_exe_path = comp.self_exe_path orelse return error.PreprocessorDisabled;

    const target = comp.getTarget();

    var cache: Cache = .{
        .gpa = comp.gpa,
        .manifest_dir = comp.cache_parent.manifest_dir,
    };
    cache.hash.addBytes(build_options.version);
    cache.hash.addOptionalBytes(comp.zig_lib_directory.path);
    cache.hash.add(target.cpu.arch);

    var man = cache.obtain();
    defer man.deinit();

    _ = try man.addFile(def_file_path, null);

    const final_lib_basename = try std.fmt.allocPrint(comp.gpa, "{s}.lib", .{lib_name});
    errdefer comp.gpa.free(final_lib_basename);

    if (try man.hit()) {
        const digest = man.final();

        try comp.crt_files.ensureCapacity(comp.gpa, comp.crt_files.count() + 1);
        comp.crt_files.putAssumeCapacityNoClobber(final_lib_basename, .{
            .full_object_path = try comp.global_cache_directory.join(comp.gpa, &[_][]const u8{
                "o", &digest, final_lib_basename,
            }),
            .lock = man.toOwnedLock(),
        });
        return;
    }

    const digest = man.final();
    const o_sub_path = try std.fs.path.join(arena, &[_][]const u8{ "o", &digest });
    var o_dir = try comp.global_cache_directory.handle.makeOpenPath(o_sub_path, .{});
    defer o_dir.close();

    const final_def_basename = try std.fmt.allocPrint(arena, "{s}.def", .{lib_name});
    const def_final_path = try comp.global_cache_directory.join(arena, &[_][]const u8{
        "o", &digest, final_def_basename,
    });

    const target_def_arg = switch (target.cpu.arch) {
        .i386 => "-DDEF_I386",
        .x86_64 => "-DDEF_X64",
        .arm, .armeb, .thumb, .thumbeb, .aarch64_32 => "-DDEF_ARM32",
        .aarch64, .aarch64_be => "-DDEF_ARM64",
        else => unreachable,
    };

    const args = [_][]const u8{
        self_exe_path,
        "clang",
        "-x",
        "c",
        def_file_path,
        "-Wp,-w",
        "-undef",
        "-P",
        "-I",
        try comp.zig_lib_directory.join(arena, &[_][]const u8{ "libc", "mingw", "def-include" }),
        target_def_arg,
        "-E",
        "-o",
        def_final_path,
    };

    if (comp.verbose_cc) {
        Compilation.dump_argv(&args);
    }

    const child = try std.ChildProcess.init(&args, arena);
    defer child.deinit();

    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    const stderr_reader = child.stderr.?.reader();

    // TODO https://github.com/ziglang/zig/issues/6343
    const stderr = try stderr_reader.readAllAlloc(arena, 10 * 1024 * 1024);

    const term = child.wait() catch |err| {
        // TODO surface a proper error here
        log.err("unable to spawn {s}: {s}", .{ args[0], @errorName(err) });
        return error.ClangPreprocessorFailed;
    };

    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                // TODO surface a proper error here
                log.err("clang exited with code {d} and stderr: {s}", .{ code, stderr });
                return error.ClangPreprocessorFailed;
            }
        },
        else => {
            // TODO surface a proper error here
            log.err("clang terminated unexpectedly with stderr: {s}", .{stderr});
            return error.ClangPreprocessorFailed;
        },
    }

    const lib_final_path = try comp.global_cache_directory.join(comp.gpa, &[_][]const u8{
        "o", &digest, final_lib_basename,
    });
    errdefer comp.gpa.free(lib_final_path);

    const llvm = @import("codegen/llvm/bindings.zig");
    const arch_type = @import("target.zig").archToLLVM(target.cpu.arch);
    const def_final_path_z = try arena.dupeZ(u8, def_final_path);
    const lib_final_path_z = try arena.dupeZ(u8, lib_final_path);
    if (llvm.WriteImportLibrary(def_final_path_z.ptr, arch_type, lib_final_path_z.ptr, true)) {
        // TODO surface a proper error here
        log.err("unable to turn {s}.def into {s}.lib", .{ lib_name, lib_name });
        return error.WritingImportLibFailed;
    }

    man.writeManifest() catch |err| {
        log.warn("failed to write cache manifest for DLL import {s}.lib: {s}", .{ lib_name, @errorName(err) });
    };

    try comp.crt_files.putNoClobber(comp.gpa, final_lib_basename, .{
        .full_object_path = lib_final_path,
        .lock = man.toOwnedLock(),
    });
}

/// This function body is verbose but all it does is test 3 different paths and see if a .def file exists.
fn findDef(comp: *Compilation, allocator: *Allocator, lib_name: []const u8) ![]u8 {
    const target = comp.getTarget();

    const lib_path = switch (target.cpu.arch) {
        .i386 => "lib32",
        .x86_64 => "lib64",
        .arm, .armeb, .thumb, .thumbeb, .aarch64_32 => "libarm32",
        .aarch64, .aarch64_be => "libarm64",
        else => unreachable,
    };

    var override_path = std.ArrayList(u8).init(allocator);
    defer override_path.deinit();

    const s = path.sep_str;

    {
        // Try the archtecture-specific path first.
        const fmt_path = "libc" ++ s ++ "mingw" ++ s ++ "{s}" ++ s ++ "{s}.def";
        if (comp.zig_lib_directory.path) |p| {
            try override_path.writer().print("{s}" ++ s ++ fmt_path, .{ p, lib_path, lib_name });
        } else {
            try override_path.writer().print(fmt_path, .{ lib_path, lib_name });
        }
        if (std.fs.cwd().access(override_path.items, .{})) |_| {
            return override_path.toOwnedSlice();
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        }
    }

    {
        // Try the generic version.
        override_path.shrinkRetainingCapacity(0);
        const fmt_path = "libc" ++ s ++ "mingw" ++ s ++ "lib-common" ++ s ++ "{s}.def";
        if (comp.zig_lib_directory.path) |p| {
            try override_path.writer().print("{s}" ++ s ++ fmt_path, .{ p, lib_name });
        } else {
            try override_path.writer().print(fmt_path, .{lib_name});
        }
        if (std.fs.cwd().access(override_path.items, .{})) |_| {
            return override_path.toOwnedSlice();
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        }
    }

    {
        // Try the generic version and preprocess it.
        override_path.shrinkRetainingCapacity(0);
        const fmt_path = "libc" ++ s ++ "mingw" ++ s ++ "lib-common" ++ s ++ "{s}.def.in";
        if (comp.zig_lib_directory.path) |p| {
            try override_path.writer().print("{s}" ++ s ++ fmt_path, .{ p, lib_name });
        } else {
            try override_path.writer().print(fmt_path, .{lib_name});
        }
        if (std.fs.cwd().access(override_path.items, .{})) |_| {
            return override_path.toOwnedSlice();
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        }
    }

    return error.FileNotFound;
}

const mingw32_lib_deps = [_][]const u8{
    "crt0_c.c",
    "dll_argv.c",
    "gccmain.c",
    "natstart.c",
    "pseudo-reloc-list.c",
    "wildcard.c",
    "charmax.c",
    "crt0_w.c",
    "dllargv.c",
    "_newmode.c",
    "tlssup.c",
    "xncommod.c",
    "cinitexe.c",
    "merr.c",
    "usermatherr.c",
    "pesect.c",
    "udllargc.c",
    "xthdloc.c",
    "CRT_fp10.c",
    "mingw_helpers.c",
    "pseudo-reloc.c",
    "udll_argv.c",
    "xtxtmode.c",
    "crt_handler.c",
    "tlsthrd.c",
    "tlsmthread.c",
    "tlsmcrt.c",
    "cxa_atexit.c",
    "cxa_thread_atexit.c",
    "tls_atexit.c",
};
const msvcrt_common_src = [_][]const u8{
    "misc" ++ path.sep_str ++ "_create_locale.c",
    "misc" ++ path.sep_str ++ "_free_locale.c",
    "misc" ++ path.sep_str ++ "onexit_table.c",
    "misc" ++ path.sep_str ++ "register_tls_atexit.c",
    "stdio" ++ path.sep_str ++ "acrt_iob_func.c",
    "stdio" ++ path.sep_str ++ "snprintf_alias.c",
    "stdio" ++ path.sep_str ++ "vsnprintf_alias.c",
    "misc" ++ path.sep_str ++ "_configthreadlocale.c",
    "misc" ++ path.sep_str ++ "_get_current_locale.c",
    "misc" ++ path.sep_str ++ "invalid_parameter_handler.c",
    "misc" ++ path.sep_str ++ "output_format.c",
    "misc" ++ path.sep_str ++ "purecall.c",
    "secapi" ++ path.sep_str ++ "_access_s.c",
    "secapi" ++ path.sep_str ++ "_cgets_s.c",
    "secapi" ++ path.sep_str ++ "_cgetws_s.c",
    "secapi" ++ path.sep_str ++ "_chsize_s.c",
    "secapi" ++ path.sep_str ++ "_controlfp_s.c",
    "secapi" ++ path.sep_str ++ "_cprintf_s.c",
    "secapi" ++ path.sep_str ++ "_cprintf_s_l.c",
    "secapi" ++ path.sep_str ++ "_ctime32_s.c",
    "secapi" ++ path.sep_str ++ "_ctime64_s.c",
    "secapi" ++ path.sep_str ++ "_cwprintf_s.c",
    "secapi" ++ path.sep_str ++ "_cwprintf_s_l.c",
    "secapi" ++ path.sep_str ++ "_gmtime32_s.c",
    "secapi" ++ path.sep_str ++ "_gmtime64_s.c",
    "secapi" ++ path.sep_str ++ "_localtime32_s.c",
    "secapi" ++ path.sep_str ++ "_localtime64_s.c",
    "secapi" ++ path.sep_str ++ "_mktemp_s.c",
    "secapi" ++ path.sep_str ++ "_sopen_s.c",
    "secapi" ++ path.sep_str ++ "_strdate_s.c",
    "secapi" ++ path.sep_str ++ "_strtime_s.c",
    "secapi" ++ path.sep_str ++ "_umask_s.c",
    "secapi" ++ path.sep_str ++ "_vcprintf_s.c",
    "secapi" ++ path.sep_str ++ "_vcprintf_s_l.c",
    "secapi" ++ path.sep_str ++ "_vcwprintf_s.c",
    "secapi" ++ path.sep_str ++ "_vcwprintf_s_l.c",
    "secapi" ++ path.sep_str ++ "_vscprintf_p.c",
    "secapi" ++ path.sep_str ++ "_vscwprintf_p.c",
    "secapi" ++ path.sep_str ++ "_vswprintf_p.c",
    "secapi" ++ path.sep_str ++ "_waccess_s.c",
    "secapi" ++ path.sep_str ++ "_wasctime_s.c",
    "secapi" ++ path.sep_str ++ "_wctime32_s.c",
    "secapi" ++ path.sep_str ++ "_wctime64_s.c",
    "secapi" ++ path.sep_str ++ "_wstrtime_s.c",
    "secapi" ++ path.sep_str ++ "_wmktemp_s.c",
    "secapi" ++ path.sep_str ++ "_wstrdate_s.c",
    "secapi" ++ path.sep_str ++ "asctime_s.c",
    "secapi" ++ path.sep_str ++ "memcpy_s.c",
    "secapi" ++ path.sep_str ++ "memmove_s.c",
    "secapi" ++ path.sep_str ++ "rand_s.c",
    "secapi" ++ path.sep_str ++ "sprintf_s.c",
    "secapi" ++ path.sep_str ++ "strerror_s.c",
    "secapi" ++ path.sep_str ++ "vsprintf_s.c",
    "secapi" ++ path.sep_str ++ "wmemcpy_s.c",
    "secapi" ++ path.sep_str ++ "wmemmove_s.c",
    "stdio" ++ path.sep_str ++ "mingw_lock.c",
};
const msvcrt_i386_src = [_][]const u8{
    "misc" ++ path.sep_str ++ "lc_locale_func.c",
    "misc" ++ path.sep_str ++ "___mb_cur_max_func.c",
    "misc" ++ path.sep_str ++ "wassert.c",
};

const msvcrt_other_src = [_][]const u8{
    "misc" ++ path.sep_str ++ "__p___argv.c",
    "misc" ++ path.sep_str ++ "__p__acmdln.c",
    "misc" ++ path.sep_str ++ "__p__commode.c",
    "misc" ++ path.sep_str ++ "__p__fmode.c",
    "misc" ++ path.sep_str ++ "__p__wcmdln.c",
};
const mingwex_generic_src = [_][]const u8{
    "complex" ++ path.sep_str ++ "_cabs.c",
    "complex" ++ path.sep_str ++ "cabs.c",
    "complex" ++ path.sep_str ++ "cabsf.c",
    "complex" ++ path.sep_str ++ "cabsl.c",
    "complex" ++ path.sep_str ++ "cacos.c",
    "complex" ++ path.sep_str ++ "cacosf.c",
    "complex" ++ path.sep_str ++ "cacosl.c",
    "complex" ++ path.sep_str ++ "carg.c",
    "complex" ++ path.sep_str ++ "cargf.c",
    "complex" ++ path.sep_str ++ "cargl.c",
    "complex" ++ path.sep_str ++ "casin.c",
    "complex" ++ path.sep_str ++ "casinf.c",
    "complex" ++ path.sep_str ++ "casinl.c",
    "complex" ++ path.sep_str ++ "catan.c",
    "complex" ++ path.sep_str ++ "catanf.c",
    "complex" ++ path.sep_str ++ "catanl.c",
    "complex" ++ path.sep_str ++ "ccos.c",
    "complex" ++ path.sep_str ++ "ccosf.c",
    "complex" ++ path.sep_str ++ "ccosl.c",
    "complex" ++ path.sep_str ++ "cexp.c",
    "complex" ++ path.sep_str ++ "cexpf.c",
    "complex" ++ path.sep_str ++ "cexpl.c",
    "complex" ++ path.sep_str ++ "cimag.c",
    "complex" ++ path.sep_str ++ "cimagf.c",
    "complex" ++ path.sep_str ++ "cimagl.c",
    "complex" ++ path.sep_str ++ "clog.c",
    "complex" ++ path.sep_str ++ "clog10.c",
    "complex" ++ path.sep_str ++ "clog10f.c",
    "complex" ++ path.sep_str ++ "clog10l.c",
    "complex" ++ path.sep_str ++ "clogf.c",
    "complex" ++ path.sep_str ++ "clogl.c",
    "complex" ++ path.sep_str ++ "conj.c",
    "complex" ++ path.sep_str ++ "conjf.c",
    "complex" ++ path.sep_str ++ "conjl.c",
    "complex" ++ path.sep_str ++ "cpow.c",
    "complex" ++ path.sep_str ++ "cpowf.c",
    "complex" ++ path.sep_str ++ "cpowl.c",
    "complex" ++ path.sep_str ++ "cproj.c",
    "complex" ++ path.sep_str ++ "cprojf.c",
    "complex" ++ path.sep_str ++ "cprojl.c",
    "complex" ++ path.sep_str ++ "creal.c",
    "complex" ++ path.sep_str ++ "crealf.c",
    "complex" ++ path.sep_str ++ "creall.c",
    "complex" ++ path.sep_str ++ "csin.c",
    "complex" ++ path.sep_str ++ "csinf.c",
    "complex" ++ path.sep_str ++ "csinl.c",
    "complex" ++ path.sep_str ++ "csqrt.c",
    "complex" ++ path.sep_str ++ "csqrtf.c",
    "complex" ++ path.sep_str ++ "csqrtl.c",
    "complex" ++ path.sep_str ++ "ctan.c",
    "complex" ++ path.sep_str ++ "ctanf.c",
    "complex" ++ path.sep_str ++ "ctanl.c",
    "crt" ++ path.sep_str ++ "dllentry.c",
    "crt" ++ path.sep_str ++ "dllmain.c",
    "gdtoa" ++ path.sep_str ++ "arithchk.c",
    "gdtoa" ++ path.sep_str ++ "dmisc.c",
    "gdtoa" ++ path.sep_str ++ "dtoa.c",
    "gdtoa" ++ path.sep_str ++ "g__fmt.c",
    "gdtoa" ++ path.sep_str ++ "g_dfmt.c",
    "gdtoa" ++ path.sep_str ++ "g_ffmt.c",
    "gdtoa" ++ path.sep_str ++ "g_xfmt.c",
    "gdtoa" ++ path.sep_str ++ "gdtoa.c",
    "gdtoa" ++ path.sep_str ++ "gethex.c",
    "gdtoa" ++ path.sep_str ++ "gmisc.c",
    "gdtoa" ++ path.sep_str ++ "hd_init.c",
    "gdtoa" ++ path.sep_str ++ "hexnan.c",
    "gdtoa" ++ path.sep_str ++ "misc.c",
    "gdtoa" ++ path.sep_str ++ "qnan.c",
    "gdtoa" ++ path.sep_str ++ "smisc.c",
    "gdtoa" ++ path.sep_str ++ "strtodg.c",
    "gdtoa" ++ path.sep_str ++ "strtodnrp.c",
    "gdtoa" ++ path.sep_str ++ "strtof.c",
    "gdtoa" ++ path.sep_str ++ "strtopx.c",
    "gdtoa" ++ path.sep_str ++ "sum.c",
    "gdtoa" ++ path.sep_str ++ "ulp.c",
    "math" ++ path.sep_str ++ "abs64.c",
    "math" ++ path.sep_str ++ "cbrt.c",
    "math" ++ path.sep_str ++ "cbrtf.c",
    "math" ++ path.sep_str ++ "cbrtl.c",
    "math" ++ path.sep_str ++ "cephes_emath.c",
    "math" ++ path.sep_str ++ "copysign.c",
    "math" ++ path.sep_str ++ "copysignf.c",
    "math" ++ path.sep_str ++ "coshf.c",
    "math" ++ path.sep_str ++ "coshl.c",
    "math" ++ path.sep_str ++ "erfl.c",
    "math" ++ path.sep_str ++ "expf.c",
    "math" ++ path.sep_str ++ "fabs.c",
    "math" ++ path.sep_str ++ "fabsf.c",
    "math" ++ path.sep_str ++ "fabsl.c",
    "math" ++ path.sep_str ++ "fdim.c",
    "math" ++ path.sep_str ++ "fdimf.c",
    "math" ++ path.sep_str ++ "fdiml.c",
    "math" ++ path.sep_str ++ "fma.c",
    "math" ++ path.sep_str ++ "fmaf.c",
    "math" ++ path.sep_str ++ "fmal.c",
    "math" ++ path.sep_str ++ "fmax.c",
    "math" ++ path.sep_str ++ "fmaxf.c",
    "math" ++ path.sep_str ++ "fmaxl.c",
    "math" ++ path.sep_str ++ "fmin.c",
    "math" ++ path.sep_str ++ "fminf.c",
    "math" ++ path.sep_str ++ "fminl.c",
    "math" ++ path.sep_str ++ "fp_consts.c",
    "math" ++ path.sep_str ++ "fp_constsf.c",
    "math" ++ path.sep_str ++ "fp_constsl.c",
    "math" ++ path.sep_str ++ "fpclassify.c",
    "math" ++ path.sep_str ++ "fpclassifyf.c",
    "math" ++ path.sep_str ++ "fpclassifyl.c",
    "math" ++ path.sep_str ++ "frexpf.c",
    "math" ++ path.sep_str ++ "frexpl.c",
    "math" ++ path.sep_str ++ "hypot.c",
    "math" ++ path.sep_str ++ "hypotf.c",
    "math" ++ path.sep_str ++ "hypotl.c",
    "math" ++ path.sep_str ++ "isnan.c",
    "math" ++ path.sep_str ++ "isnanf.c",
    "math" ++ path.sep_str ++ "isnanl.c",
    "math" ++ path.sep_str ++ "ldexpf.c",
    "math" ++ path.sep_str ++ "lgamma.c",
    "math" ++ path.sep_str ++ "lgammaf.c",
    "math" ++ path.sep_str ++ "lgammal.c",
    "math" ++ path.sep_str ++ "llrint.c",
    "math" ++ path.sep_str ++ "llrintf.c",
    "math" ++ path.sep_str ++ "llrintl.c",
    "math" ++ path.sep_str ++ "llround.c",
    "math" ++ path.sep_str ++ "llroundf.c",
    "math" ++ path.sep_str ++ "llroundl.c",
    "math" ++ path.sep_str ++ "log10f.c",
    "math" ++ path.sep_str ++ "logf.c",
    "math" ++ path.sep_str ++ "lrint.c",
    "math" ++ path.sep_str ++ "lrintf.c",
    "math" ++ path.sep_str ++ "lrintl.c",
    "math" ++ path.sep_str ++ "lround.c",
    "math" ++ path.sep_str ++ "lroundf.c",
    "math" ++ path.sep_str ++ "lroundl.c",
    "math" ++ path.sep_str ++ "modf.c",
    "math" ++ path.sep_str ++ "modff.c",
    "math" ++ path.sep_str ++ "modfl.c",
    "math" ++ path.sep_str ++ "nextafterf.c",
    "math" ++ path.sep_str ++ "nextafterl.c",
    "math" ++ path.sep_str ++ "nexttoward.c",
    "math" ++ path.sep_str ++ "nexttowardf.c",
    "math" ++ path.sep_str ++ "powf.c",
    "math" ++ path.sep_str ++ "powi.c",
    "math" ++ path.sep_str ++ "powif.c",
    "math" ++ path.sep_str ++ "powil.c",
    "math" ++ path.sep_str ++ "round.c",
    "math" ++ path.sep_str ++ "roundf.c",
    "math" ++ path.sep_str ++ "roundl.c",
    "math" ++ path.sep_str ++ "s_erf.c",
    "math" ++ path.sep_str ++ "sf_erf.c",
    "math" ++ path.sep_str ++ "signbit.c",
    "math" ++ path.sep_str ++ "signbitf.c",
    "math" ++ path.sep_str ++ "signbitl.c",
    "math" ++ path.sep_str ++ "signgam.c",
    "math" ++ path.sep_str ++ "sinhf.c",
    "math" ++ path.sep_str ++ "sinhl.c",
    "math" ++ path.sep_str ++ "sqrt.c",
    "math" ++ path.sep_str ++ "sqrtf.c",
    "math" ++ path.sep_str ++ "sqrtl.c",
    "math" ++ path.sep_str ++ "tanhf.c",
    "math" ++ path.sep_str ++ "tanhl.c",
    "math" ++ path.sep_str ++ "tgamma.c",
    "math" ++ path.sep_str ++ "tgammaf.c",
    "math" ++ path.sep_str ++ "tgammal.c",
    "math" ++ path.sep_str ++ "truncl.c",
    "misc" ++ path.sep_str ++ "alarm.c",
    "misc" ++ path.sep_str ++ "basename.c",
    "misc" ++ path.sep_str ++ "btowc.c",
    "misc" ++ path.sep_str ++ "delay-f.c",
    "misc" ++ path.sep_str ++ "delay-n.c",
    "misc" ++ path.sep_str ++ "delayimp.c",
    "misc" ++ path.sep_str ++ "dirent.c",
    "misc" ++ path.sep_str ++ "dirname.c",
    "misc" ++ path.sep_str ++ "feclearexcept.c",
    "misc" ++ path.sep_str ++ "fegetenv.c",
    "misc" ++ path.sep_str ++ "fegetexceptflag.c",
    "misc" ++ path.sep_str ++ "fegetround.c",
    "misc" ++ path.sep_str ++ "feholdexcept.c",
    "misc" ++ path.sep_str ++ "feraiseexcept.c",
    "misc" ++ path.sep_str ++ "fesetenv.c",
    "misc" ++ path.sep_str ++ "fesetexceptflag.c",
    "misc" ++ path.sep_str ++ "fesetround.c",
    "misc" ++ path.sep_str ++ "fetestexcept.c",
    "misc" ++ path.sep_str ++ "feupdateenv.c",
    "misc" ++ path.sep_str ++ "ftruncate.c",
    "misc" ++ path.sep_str ++ "ftw.c",
    "misc" ++ path.sep_str ++ "ftw64.c",
    "misc" ++ path.sep_str ++ "fwide.c",
    "misc" ++ path.sep_str ++ "getlogin.c",
    "misc" ++ path.sep_str ++ "getopt.c",
    "misc" ++ path.sep_str ++ "gettimeofday.c",
    "misc" ++ path.sep_str ++ "imaxabs.c",
    "misc" ++ path.sep_str ++ "imaxdiv.c",
    "misc" ++ path.sep_str ++ "isblank.c",
    "misc" ++ path.sep_str ++ "iswblank.c",
    "misc" ++ path.sep_str ++ "mbrtowc.c",
    "misc" ++ path.sep_str ++ "mbsinit.c",
    "misc" ++ path.sep_str ++ "mempcpy.c",
    "misc" ++ path.sep_str ++ "mingw-aligned-malloc.c",
    "misc" ++ path.sep_str ++ "mingw_getsp.S",
    "misc" ++ path.sep_str ++ "mingw_matherr.c",
    "misc" ++ path.sep_str ++ "mingw_mbwc_convert.c",
    "misc" ++ path.sep_str ++ "mingw_usleep.c",
    "misc" ++ path.sep_str ++ "mingw_wcstod.c",
    "misc" ++ path.sep_str ++ "mingw_wcstof.c",
    "misc" ++ path.sep_str ++ "mingw_wcstold.c",
    "misc" ++ path.sep_str ++ "mkstemp.c",
    "misc" ++ path.sep_str ++ "seterrno.c",
    "misc" ++ path.sep_str ++ "sleep.c",
    "misc" ++ path.sep_str ++ "strnlen.c",
    "misc" ++ path.sep_str ++ "strsafe.c",
    "misc" ++ path.sep_str ++ "strtoimax.c",
    "misc" ++ path.sep_str ++ "strtold.c",
    "misc" ++ path.sep_str ++ "strtoumax.c",
    "misc" ++ path.sep_str ++ "tdelete.c",
    "misc" ++ path.sep_str ++ "tfind.c",
    "misc" ++ path.sep_str ++ "tsearch.c",
    "misc" ++ path.sep_str ++ "twalk.c",
    "misc" ++ path.sep_str ++ "uchar_c16rtomb.c",
    "misc" ++ path.sep_str ++ "uchar_c32rtomb.c",
    "misc" ++ path.sep_str ++ "uchar_mbrtoc16.c",
    "misc" ++ path.sep_str ++ "uchar_mbrtoc32.c",
    "misc" ++ path.sep_str ++ "wcrtomb.c",
    "misc" ++ path.sep_str ++ "wcsnlen.c",
    "misc" ++ path.sep_str ++ "wcstof.c",
    "misc" ++ path.sep_str ++ "wcstoimax.c",
    "misc" ++ path.sep_str ++ "wcstold.c",
    "misc" ++ path.sep_str ++ "wcstoumax.c",
    "misc" ++ path.sep_str ++ "wctob.c",
    "misc" ++ path.sep_str ++ "wctrans.c",
    "misc" ++ path.sep_str ++ "wctype.c",
    "misc" ++ path.sep_str ++ "wdirent.c",
    "misc" ++ path.sep_str ++ "winbs_uint64.c",
    "misc" ++ path.sep_str ++ "winbs_ulong.c",
    "misc" ++ path.sep_str ++ "winbs_ushort.c",
    "misc" ++ path.sep_str ++ "wmemchr.c",
    "misc" ++ path.sep_str ++ "wmemcmp.c",
    "misc" ++ path.sep_str ++ "wmemcpy.c",
    "misc" ++ path.sep_str ++ "wmemmove.c",
    "misc" ++ path.sep_str ++ "wmempcpy.c",
    "misc" ++ path.sep_str ++ "wmemset.c",
    "stdio" ++ path.sep_str ++ "_Exit.c",
    "stdio" ++ path.sep_str ++ "_findfirst64i32.c",
    "stdio" ++ path.sep_str ++ "_findnext64i32.c",
    "stdio" ++ path.sep_str ++ "_fstat.c",
    "stdio" ++ path.sep_str ++ "_fstat64i32.c",
    "stdio" ++ path.sep_str ++ "_ftime.c",
    "stdio" ++ path.sep_str ++ "_getc_nolock.c",
    "stdio" ++ path.sep_str ++ "_getwc_nolock.c",
    "stdio" ++ path.sep_str ++ "_putc_nolock.c",
    "stdio" ++ path.sep_str ++ "_putwc_nolock.c",
    "stdio" ++ path.sep_str ++ "_stat.c",
    "stdio" ++ path.sep_str ++ "_stat64i32.c",
    "stdio" ++ path.sep_str ++ "_wfindfirst64i32.c",
    "stdio" ++ path.sep_str ++ "_wfindnext64i32.c",
    "stdio" ++ path.sep_str ++ "_wstat.c",
    "stdio" ++ path.sep_str ++ "_wstat64i32.c",
    "stdio" ++ path.sep_str ++ "asprintf.c",
    "stdio" ++ path.sep_str ++ "atoll.c",
    "stdio" ++ path.sep_str ++ "fgetpos64.c",
    "stdio" ++ path.sep_str ++ "fopen64.c",
    "stdio" ++ path.sep_str ++ "fseeko32.c",
    "stdio" ++ path.sep_str ++ "fseeko64.c",
    "stdio" ++ path.sep_str ++ "fsetpos64.c",
    "stdio" ++ path.sep_str ++ "ftello.c",
    "stdio" ++ path.sep_str ++ "ftello64.c",
    "stdio" ++ path.sep_str ++ "ftruncate64.c",
    "stdio" ++ path.sep_str ++ "lltoa.c",
    "stdio" ++ path.sep_str ++ "lltow.c",
    "stdio" ++ path.sep_str ++ "lseek64.c",
    "stdio" ++ path.sep_str ++ "mingw_asprintf.c",
    "stdio" ++ path.sep_str ++ "mingw_fprintf.c",
    "stdio" ++ path.sep_str ++ "mingw_fprintfw.c",
    "stdio" ++ path.sep_str ++ "mingw_fscanf.c",
    "stdio" ++ path.sep_str ++ "mingw_fwscanf.c",
    "stdio" ++ path.sep_str ++ "mingw_pformat.c",
    "stdio" ++ path.sep_str ++ "mingw_pformatw.c",
    "stdio" ++ path.sep_str ++ "mingw_printf.c",
    "stdio" ++ path.sep_str ++ "mingw_printfw.c",
    "stdio" ++ path.sep_str ++ "mingw_scanf.c",
    "stdio" ++ path.sep_str ++ "mingw_snprintf.c",
    "stdio" ++ path.sep_str ++ "mingw_snprintfw.c",
    "stdio" ++ path.sep_str ++ "mingw_sprintf.c",
    "stdio" ++ path.sep_str ++ "mingw_sprintfw.c",
    "stdio" ++ path.sep_str ++ "mingw_sscanf.c",
    "stdio" ++ path.sep_str ++ "mingw_swscanf.c",
    "stdio" ++ path.sep_str ++ "mingw_vasprintf.c",
    "stdio" ++ path.sep_str ++ "mingw_vfprintf.c",
    "stdio" ++ path.sep_str ++ "mingw_vfprintfw.c",
    "stdio" ++ path.sep_str ++ "mingw_vfscanf.c",
    "stdio" ++ path.sep_str ++ "mingw_vprintf.c",
    "stdio" ++ path.sep_str ++ "mingw_vprintfw.c",
    "stdio" ++ path.sep_str ++ "mingw_vsnprintf.c",
    "stdio" ++ path.sep_str ++ "mingw_vsnprintfw.c",
    "stdio" ++ path.sep_str ++ "mingw_vsprintf.c",
    "stdio" ++ path.sep_str ++ "mingw_vsprintfw.c",
    "stdio" ++ path.sep_str ++ "mingw_wscanf.c",
    "stdio" ++ path.sep_str ++ "mingw_wvfscanf.c",
    "stdio" ++ path.sep_str ++ "scanf.S",
    "stdio" ++ path.sep_str ++ "snprintf.c",
    "stdio" ++ path.sep_str ++ "snwprintf.c",
    "stdio" ++ path.sep_str ++ "strtof.c",
    "stdio" ++ path.sep_str ++ "strtok_r.c",
    "stdio" ++ path.sep_str ++ "truncate.c",
    "stdio" ++ path.sep_str ++ "ulltoa.c",
    "stdio" ++ path.sep_str ++ "ulltow.c",
    "stdio" ++ path.sep_str ++ "vasprintf.c",
    "stdio" ++ path.sep_str ++ "vfscanf.c",
    "stdio" ++ path.sep_str ++ "vfscanf2.S",
    "stdio" ++ path.sep_str ++ "vfwscanf.c",
    "stdio" ++ path.sep_str ++ "vfwscanf2.S",
    "stdio" ++ path.sep_str ++ "vscanf.c",
    "stdio" ++ path.sep_str ++ "vscanf2.S",
    "stdio" ++ path.sep_str ++ "vsnprintf.c",
    "stdio" ++ path.sep_str ++ "vsnwprintf.c",
    "stdio" ++ path.sep_str ++ "vsscanf.c",
    "stdio" ++ path.sep_str ++ "vsscanf2.S",
    "stdio" ++ path.sep_str ++ "vswscanf.c",
    "stdio" ++ path.sep_str ++ "vswscanf2.S",
    "stdio" ++ path.sep_str ++ "vwscanf.c",
    "stdio" ++ path.sep_str ++ "vwscanf2.S",
    "stdio" ++ path.sep_str ++ "wtoll.c",
};

const mingwex_x86_src = [_][]const u8{
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "acosf.c",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "acosh.c",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "acoshf.c",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "acoshl.c",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "acosl.c",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "asinf.c",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "asinh.c",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "asinhf.c",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "asinhl.c",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "asinl.c",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "atan2.c",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "atan2f.c",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "atan2l.c",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "atanf.c",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "atanh.c",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "atanhf.c",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "atanhl.c",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "atanl.c",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "ceilf.S",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "ceill.S",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "ceil.S",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "_chgsignl.S",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "copysignl.S",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "cos.c",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "cosf.c",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "cosl.c",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "cosl_internal.S",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "cossin.c",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "exp2f.S",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "exp2l.S",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "exp2.S",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "exp.c",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "expl.c",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "expm1.c",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "expm1f.c",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "expm1l.c",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "floorf.S",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "floorl.S",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "floor.S",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "fmod.c",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "fmodf.c",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "fmodl.c",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "fucom.c",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "ilogbf.S",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "ilogbl.S",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "ilogb.S",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "internal_logl.S",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "ldexp.c",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "ldexpl.c",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "log10l.S",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "log1pf.S",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "log1pl.S",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "log1p.S",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "log2f.S",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "log2l.S",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "log2.S",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "logb.c",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "logbf.c",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "logbl.c",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "log.c",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "logl.c",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "nearbyintf.S",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "nearbyintl.S",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "nearbyint.S",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "pow.c",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "powl.c",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "remainderf.S",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "remainderl.S",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "remainder.S",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "remquof.S",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "remquol.S",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "remquo.S",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "rint.c",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "rintf.c",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "scalbnf.S",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "scalbnl.S",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "scalbn.S",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "sin.c",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "sinf.c",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "sinl.c",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "sinl_internal.S",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "tanf.c",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "tanl.S",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "truncf.S",
    "math" ++ path.sep_str ++ "x86" ++ path.sep_str ++ "trunc.S",
};

const mingwex_arm32_src = [_][]const u8{
    "math" ++ path.sep_str ++ "arm" ++ path.sep_str ++ "_chgsignl.S",
    "math" ++ path.sep_str ++ "arm" ++ path.sep_str ++ "s_rint.c",
    "math" ++ path.sep_str ++ "arm" ++ path.sep_str ++ "s_rintf.c",
    "math" ++ path.sep_str ++ "arm" ++ path.sep_str ++ "exp2.S",
    "math" ++ path.sep_str ++ "arm" ++ path.sep_str ++ "exp2f.S",
    "math" ++ path.sep_str ++ "arm" ++ path.sep_str ++ "nearbyint.S",
    "math" ++ path.sep_str ++ "arm" ++ path.sep_str ++ "nearbyintf.S",
    "math" ++ path.sep_str ++ "arm" ++ path.sep_str ++ "nearbyintl.S",
    "math" ++ path.sep_str ++ "arm" ++ path.sep_str ++ "sincos.S",
    "math" ++ path.sep_str ++ "arm" ++ path.sep_str ++ "sincosf.S",
    "math" ++ path.sep_str ++ "arm" ++ path.sep_str ++ "s_trunc.c",
    "math" ++ path.sep_str ++ "arm" ++ path.sep_str ++ "s_truncf.c",
};

const mingwex_arm64_src = [_][]const u8{
    "math" ++ path.sep_str ++ "arm64" ++ path.sep_str ++ "_chgsignl.S",
    "math" ++ path.sep_str ++ "arm64" ++ path.sep_str ++ "rint.c",
    "math" ++ path.sep_str ++ "arm64" ++ path.sep_str ++ "rintf.c",
    "math" ++ path.sep_str ++ "arm64" ++ path.sep_str ++ "sincos.S",
    "math" ++ path.sep_str ++ "arm64" ++ path.sep_str ++ "sincosf.S",
    "math" ++ path.sep_str ++ "arm64" ++ path.sep_str ++ "exp2f.S",
    "math" ++ path.sep_str ++ "arm64" ++ path.sep_str ++ "exp2.S",
    "math" ++ path.sep_str ++ "arm64" ++ path.sep_str ++ "nearbyintf.S",
    "math" ++ path.sep_str ++ "arm64" ++ path.sep_str ++ "nearbyintl.S",
    "math" ++ path.sep_str ++ "arm64" ++ path.sep_str ++ "nearbyint.S",
    "math" ++ path.sep_str ++ "arm64" ++ path.sep_str ++ "truncf.S",
    "math" ++ path.sep_str ++ "arm64" ++ path.sep_str ++ "trunc.S",
};

const uuid_src = [_][]const u8{
    "ativscp-uuid.c",
    "atsmedia-uuid.c",
    "bth-uuid.c",
    "cguid-uuid.c",
    "comcat-uuid.c",
    "devguid.c",
    "docobj-uuid.c",
    "dxva-uuid.c",
    "exdisp-uuid.c",
    "extras-uuid.c",
    "fwp-uuid.c",
    "guid_nul.c",
    "hlguids-uuid.c",
    "hlink-uuid.c",
    "mlang-uuid.c",
    "msctf-uuid.c",
    "mshtmhst-uuid.c",
    "mshtml-uuid.c",
    "msxml-uuid.c",
    "netcfg-uuid.c",
    "netcon-uuid.c",
    "ntddkbd-uuid.c",
    "ntddmou-uuid.c",
    "ntddpar-uuid.c",
    "ntddscsi-uuid.c",
    "ntddser-uuid.c",
    "ntddstor-uuid.c",
    "ntddvdeo-uuid.c",
    "oaidl-uuid.c",
    "objidl-uuid.c",
    "objsafe-uuid.c",
    "ocidl-uuid.c",
    "oleacc-uuid.c",
    "olectlid-uuid.c",
    "oleidl-uuid.c",
    "power-uuid.c",
    "powrprof-uuid.c",
    "uianimation-uuid.c",
    "usbcamdi-uuid.c",
    "usbiodef-uuid.c",
    "uuid.c",
    "vds-uuid.c",
    "virtdisk-uuid.c",
    "wia-uuid.c",
};

pub const always_link_libs = [_][]const u8{
    "advapi32",
    "kernel32",
    "msvcrt",
    "ntdll",
    "shell32",
    "user32",
};
