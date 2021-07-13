// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.
const root = @import("@build");
const std = @import("std");
const builtin = @import("builtin");
const io = std.io;
const fmt = std.fmt;
const Builder = std.build.Builder;
const mem = std.mem;
const process = std.process;
const ArrayList = std.ArrayList;
const warn = std.debug.warn;
const File = std.fs.File;

pub fn main() !void {
    // Here we use an ArenaAllocator backed by a DirectAllocator because a build is a short-lived,
    // one shot program. We don't need to waste time freeing memory and finding places to squish
    // bytes into. So we free everything all at once at the very end.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = &arena.allocator;
    var args = try process.argsAlloc(allocator);
    defer process.argsFree(allocator, args);

    // skip my own exe name
    var arg_idx: usize = 1;

    const zig_exe = nextArg(args, &arg_idx) orelse {
        warn("Expected first argument to be path to zig compiler\n", .{});
        return error.InvalidArgs;
    };
    const build_root = nextArg(args, &arg_idx) orelse {
        warn("Expected second argument to be build root directory path\n", .{});
        return error.InvalidArgs;
    };
    const cache_root = nextArg(args, &arg_idx) orelse {
        warn("Expected third argument to be cache root directory path\n", .{});
        return error.InvalidArgs;
    };
    const global_cache_root = nextArg(args, &arg_idx) orelse {
        warn("Expected third argument to be global cache root directory path\n", .{});
        return error.InvalidArgs;
    };

    const builder = try Builder.create(
        allocator,
        zig_exe,
        build_root,
        cache_root,
        global_cache_root,
    );
    defer builder.destroy();

    var targets = ArrayList([]const u8).init(allocator);

    const stderr_stream = io.getStdErr().writer();
    const stdout_stream = io.getStdOut().writer();

    var install_prefix: ?[]const u8 = null;
    var dir_list = Builder.DirList{};

    // before arg parsing, check for the NO_COLOR environment variable
    // if it exists, default the color setting to .off
    // explicit --color arguments will still override this setting.
    builder.color = if (std.process.hasEnvVarConstant("NO_COLOR")) .off else .auto;

    while (nextArg(args, &arg_idx)) |arg| {
        if (mem.startsWith(u8, arg, "-D")) {
            const option_contents = arg[2..];
            if (option_contents.len == 0) {
                warn("Expected option name after '-D'\n\n", .{});
                return usageAndErr(builder, false, stderr_stream);
            }
            if (mem.indexOfScalar(u8, option_contents, '=')) |name_end| {
                const option_name = option_contents[0..name_end];
                const option_value = option_contents[name_end + 1 ..];
                if (try builder.addUserInputOption(option_name, option_value))
                    return usageAndErr(builder, false, stderr_stream);
            } else {
                if (try builder.addUserInputFlag(option_contents))
                    return usageAndErr(builder, false, stderr_stream);
            }
        } else if (mem.startsWith(u8, arg, "-")) {
            if (mem.eql(u8, arg, "--verbose")) {
                builder.verbose = true;
            } else if (mem.eql(u8, arg, "-h") or mem.eql(u8, arg, "--help")) {
                return usage(builder, false, stdout_stream);
            } else if (mem.eql(u8, arg, "-p") or mem.eql(u8, arg, "--prefix")) {
                install_prefix = nextArg(args, &arg_idx) orelse {
                    warn("Expected argument after {s}\n\n", .{arg});
                    return usageAndErr(builder, false, stderr_stream);
                };
            } else if (mem.eql(u8, arg, "--prefix-lib-dir")) {
                dir_list.lib_dir = nextArg(args, &arg_idx) orelse {
                    warn("Expected argument after {s}\n\n", .{arg});
                    return usageAndErr(builder, false, stderr_stream);
                };
            } else if (mem.eql(u8, arg, "--prefix-exe-dir")) {
                dir_list.exe_dir = nextArg(args, &arg_idx) orelse {
                    warn("Expected argument after {s}\n\n", .{arg});
                    return usageAndErr(builder, false, stderr_stream);
                };
            } else if (mem.eql(u8, arg, "--prefix-include-dir")) {
                dir_list.include_dir = nextArg(args, &arg_idx) orelse {
                    warn("Expected argument after {s}\n\n", .{arg});
                    return usageAndErr(builder, false, stderr_stream);
                };
            } else if (mem.eql(u8, arg, "--sysroot")) {
                const sysroot = nextArg(args, &arg_idx) orelse {
                    warn("Expected argument after --sysroot\n\n", .{});
                    return usageAndErr(builder, false, stderr_stream);
                };
                builder.sysroot = sysroot;
            } else if (mem.eql(u8, arg, "--search-prefix")) {
                const search_prefix = nextArg(args, &arg_idx) orelse {
                    warn("Expected argument after --search-prefix\n\n", .{});
                    return usageAndErr(builder, false, stderr_stream);
                };
                builder.addSearchPrefix(search_prefix);
            } else if (mem.eql(u8, arg, "--libc")) {
                const libc_file = nextArg(args, &arg_idx) orelse {
                    warn("Expected argument after --libc\n\n", .{});
                    return usageAndErr(builder, false, stderr_stream);
                };
                builder.libc_file = libc_file;
            } else if (mem.eql(u8, arg, "--color")) {
                const next_arg = nextArg(args, &arg_idx) orelse {
                    warn("expected [auto|on|off] after --color", .{});
                    return usageAndErr(builder, false, stderr_stream);
                };
                builder.color = std.meta.stringToEnum(@TypeOf(builder.color), next_arg) orelse {
                    warn("expected [auto|on|off] after --color, found '{s}'", .{next_arg});
                    return usageAndErr(builder, false, stderr_stream);
                };
            } else if (mem.eql(u8, arg, "--zig-lib-dir")) {
                builder.override_lib_dir = nextArg(args, &arg_idx) orelse {
                    warn("Expected argument after --zig-lib-dir\n\n", .{});
                    return usageAndErr(builder, false, stderr_stream);
                };
            } else if (mem.eql(u8, arg, "--verbose-tokenize")) {
                builder.verbose_tokenize = true;
            } else if (mem.eql(u8, arg, "--verbose-ast")) {
                builder.verbose_ast = true;
            } else if (mem.eql(u8, arg, "--verbose-link")) {
                builder.verbose_link = true;
            } else if (mem.eql(u8, arg, "--verbose-ir")) {
                builder.verbose_ir = true;
            } else if (mem.eql(u8, arg, "--verbose-llvm-ir")) {
                builder.verbose_llvm_ir = true;
            } else if (mem.eql(u8, arg, "--verbose-cimport")) {
                builder.verbose_cimport = true;
            } else if (mem.eql(u8, arg, "--verbose-cc")) {
                builder.verbose_cc = true;
            } else if (mem.eql(u8, arg, "--verbose-llvm-cpu-features")) {
                builder.verbose_llvm_cpu_features = true;
            } else if (mem.eql(u8, arg, "--prominent-compile-errors")) {
                builder.prominent_compile_errors = true;
            } else if (mem.eql(u8, arg, "--")) {
                builder.args = argsRest(args, arg_idx);
                break;
            } else {
                warn("Unrecognized argument: {s}\n\n", .{arg});
                return usageAndErr(builder, false, stderr_stream);
            }
        } else {
            try targets.append(arg);
        }
    }

    builder.resolveInstallPrefix(install_prefix, dir_list);
    try runBuild(builder);

    if (builder.validateUserInputDidItFail())
        return usageAndErr(builder, true, stderr_stream);

    builder.make(targets.items) catch |err| {
        switch (err) {
            error.InvalidStepName => {
                return usageAndErr(builder, true, stderr_stream);
            },
            error.UncleanExit => process.exit(1),
            else => return err,
        }
    };
}

fn runBuild(builder: *Builder) anyerror!void {
    switch (@typeInfo(@typeInfo(@TypeOf(root.build)).Fn.return_type.?)) {
        .Void => root.build(builder),
        .ErrorUnion => try root.build(builder),
        else => @compileError("expected return type of build to be 'void' or '!void'"),
    }
}

fn usage(builder: *Builder, already_ran_build: bool, out_stream: anytype) !void {
    // run the build script to collect the options
    if (!already_ran_build) {
        builder.resolveInstallPrefix(null, .{});
        try runBuild(builder);
    }

    try out_stream.print(
        \\Usage: {s} build [steps] [options]
        \\
        \\Steps:
        \\
    , .{builder.zig_exe});

    const allocator = builder.allocator;
    for (builder.top_level_steps.items) |top_level_step| {
        const name = if (&top_level_step.step == builder.default_step)
            try fmt.allocPrint(allocator, "{s} (default)", .{top_level_step.step.name})
        else
            top_level_step.step.name;
        try out_stream.print("  {s:<28} {s}\n", .{ name, top_level_step.description });
    }

    try out_stream.writeAll(
        \\
        \\General Options:
        \\  -p, --prefix [path]          Override default install prefix
        \\  --prefix-lib-dir [path]      Override default library directory path
        \\  --prefix-exe-dir [path]      Override default executable directory path
        \\  --prefix-include-dir [path]  Override default include directory path
        \\
        \\  --sysroot [path]             Set the system root directory (usually /)
        \\  --search-prefix [path]       Add a path to look for binaries, libraries, headers
        \\  --libc [file]                Provide a file which specifies libc paths
        \\
        \\  -h, --help                   Print this help and exit
        \\  --verbose                    Print commands before executing them
        \\  --color [auto|off|on]        Enable or disable colored error messages
        \\  --prominent-compile-errors   Output compile errors formatted for a human to read
        \\
        \\Project-Specific Options:
        \\
    );

    if (builder.available_options_list.items.len == 0) {
        try out_stream.print("  (none)\n", .{});
    } else {
        for (builder.available_options_list.items) |option| {
            const name = try fmt.allocPrint(allocator, "  -D{s}=[{s}]", .{
                option.name,
                @tagName(option.type_id),
            });
            defer allocator.free(name);
            try out_stream.print("{s:<30} {s}\n", .{ name, option.description });
        }
    }

    try out_stream.writeAll(
        \\
        \\Advanced Options:
        \\  --build-file [file]          Override path to build.zig
        \\  --cache-dir [path]           Override path to zig cache directory
        \\  --zig-lib-dir [arg]          Override path to Zig lib directory
        \\  --verbose-tokenize           Enable compiler debug output for tokenization
        \\  --verbose-ast                Enable compiler debug output for parsing into an AST
        \\  --verbose-link               Enable compiler debug output for linking
        \\  --verbose-ir                 Enable compiler debug output for Zig IR
        \\  --verbose-llvm-ir            Enable compiler debug output for LLVM IR
        \\  --verbose-cimport            Enable compiler debug output for C imports
        \\  --verbose-cc                 Enable compiler debug output for C compilation
        \\  --verbose-llvm-cpu-features  Enable compiler debug output for LLVM CPU features
        \\
    );
}

fn usageAndErr(builder: *Builder, already_ran_build: bool, out_stream: anytype) void {
    usage(builder, already_ran_build, out_stream) catch {};
    process.exit(1);
}

fn nextArg(args: [][]const u8, idx: *usize) ?[]const u8 {
    if (idx.* >= args.len) return null;
    defer idx.* += 1;
    return args[idx.*];
}

fn argsRest(args: [][]const u8, idx: usize) ?[][]const u8 {
    if (idx >= args.len) return null;
    return args[idx..];
}
