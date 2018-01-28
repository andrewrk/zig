const root = @import("@build");
const std = @import("std");
const io = std.io;
const fmt = std.fmt;
const os = std.os;
const Builder = std.build.Builder;
const mem = std.mem;
const ArrayList = std.ArrayList;
const warn = std.debug.warn;

error InvalidArgs;

pub fn main() %void {
    var arg_it = os.args();

    // TODO use a more general purpose allocator here
    var inc_allocator = try std.heap.IncrementingAllocator.init(40 * 1024 * 1024);
    defer inc_allocator.deinit();

    const allocator = &inc_allocator.allocator;


    // skip my own exe name
    _ = arg_it.skip();

    const zig_exe = try unwrapArg(arg_it.next(allocator) ?? {
        warn("Expected first argument to be path to zig compiler\n");
        return error.InvalidArgs;
    });
    const build_root = try unwrapArg(arg_it.next(allocator) ?? {
        warn("Expected second argument to be build root directory path\n");
        return error.InvalidArgs;
    });
    const cache_root = try unwrapArg(arg_it.next(allocator) ?? {
        warn("Expected third argument to be cache root directory path\n");
        return error.InvalidArgs;
    });

    var builder = Builder.init(allocator, zig_exe, build_root, cache_root);
    defer builder.deinit();

    var targets = ArrayList([]const u8).init(allocator);

    var prefix: ?[]const u8 = null;

    var stderr_file = io.getStdErr();
    var stderr_file_stream: io.FileOutStream = undefined;
    var stderr_stream: %&io.OutStream = if (stderr_file) |*f| x: {
        stderr_file_stream = io.FileOutStream.init(f);
        break :x &stderr_file_stream.stream;
    } else |err| err;

    var stdout_file = io.getStdOut();
    var stdout_file_stream: io.FileOutStream = undefined;
    var stdout_stream: %&io.OutStream = if (stdout_file) |*f| x: {
        stdout_file_stream = io.FileOutStream.init(f);
        break :x &stdout_file_stream.stream;
    } else |err| err;

    while (arg_it.next(allocator)) |err_or_arg| {
        const arg = try unwrapArg(err_or_arg);
        if (mem.startsWith(u8, arg, "-D")) {
            const option_contents = arg[2..];
            if (option_contents.len == 0) {
                warn("Expected option name after '-D'\n\n");
                return usageAndErr(&builder, false, try stderr_stream);
            }
            if (mem.indexOfScalar(u8, option_contents, '=')) |name_end| {
                const option_name = option_contents[0..name_end];
                const option_value = option_contents[name_end + 1..];
                if (builder.addUserInputOption(option_name, option_value))
                    return usageAndErr(&builder, false, try stderr_stream);
            } else {
                if (builder.addUserInputFlag(option_contents))
                    return usageAndErr(&builder, false, try stderr_stream);
            }
        } else if (mem.startsWith(u8, arg, "-")) {
            if (mem.eql(u8, arg, "--verbose")) {
                builder.verbose = true;
            } else if (mem.eql(u8, arg, "--help")) {
                return usage(&builder, false, try stdout_stream);
            } else if (mem.eql(u8, arg, "--prefix")) {
                prefix = try unwrapArg(arg_it.next(allocator) ?? {
                    warn("Expected argument after --prefix\n\n");
                    return usageAndErr(&builder, false, try stderr_stream);
                });
            } else if (mem.eql(u8, arg, "--search-prefix")) {
                const search_prefix = try unwrapArg(arg_it.next(allocator) ?? {
                    warn("Expected argument after --search-prefix\n\n");
                    return usageAndErr(&builder, false, try stderr_stream);
                });
                builder.addSearchPrefix(search_prefix);
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
            } else {
                warn("Unrecognized argument: {}\n\n", arg);
                return usageAndErr(&builder, false, try stderr_stream);
            }
        } else {
            try targets.append(arg);
        }
    }

    builder.setInstallPrefix(prefix);
    try root.build(&builder);

    if (builder.validateUserInputDidItFail())
        return usageAndErr(&builder, true, try stderr_stream);

    builder.make(targets.toSliceConst()) catch |err| {
        if (err == error.InvalidStepName) {
            return usageAndErr(&builder, true, try stderr_stream);
        }
        return err;
    };
}

fn usage(builder: &Builder, already_ran_build: bool, out_stream: &io.OutStream) %void {
    // run the build script to collect the options
    if (!already_ran_build) {
        builder.setInstallPrefix(null);
        try root.build(builder);
    }

    // This usage text has to be synchronized with src/main.cpp
    try out_stream.print(
        \\Usage: {} build [steps] [options]
        \\
        \\Steps:
        \\
    , builder.zig_exe);

    const allocator = builder.allocator;
    for (builder.top_level_steps.toSliceConst()) |top_level_step| {
        try out_stream.print("  {s22} {}\n", top_level_step.step.name, top_level_step.description);
    }

    try out_stream.write(
        \\
        \\General Options:
        \\  --help                 Print this help and exit
        \\  --verbose              Print commands before executing them
        \\  --prefix [path]        Override default install prefix
        \\  --search-prefix [path] Add a path to look for binaries, libraries, headers
        \\
        \\Project-Specific Options:
        \\
    );

    if (builder.available_options_list.len == 0) {
        try out_stream.print("  (none)\n");
    } else {
        for (builder.available_options_list.toSliceConst()) |option| {
            const name = try fmt.allocPrint(allocator,
                "  -D{}=[{}]", option.name, Builder.typeIdName(option.type_id));
            defer allocator.free(name);
            try out_stream.print("{s24} {}\n", name, option.description);
        }
    }

    try out_stream.write(
        \\
        \\Advanced Options:
        \\  --build-file [file]    Override path to build.zig
        \\  --cache-dir [path]     Override path to zig cache directory
        \\  --verbose-tokenize     Enable compiler debug output for tokenization
        \\  --verbose-ast          Enable compiler debug output for parsing into an AST
        \\  --verbose-link         Enable compiler debug output for linking
        \\  --verbose-ir           Enable compiler debug output for Zig IR
        \\  --verbose-llvm-ir      Enable compiler debug output for LLVM IR
        \\  --verbose-cimport      Enable compiler debug output for C imports
        \\
    );
}

fn usageAndErr(builder: &Builder, already_ran_build: bool, out_stream: &io.OutStream) error {
    usage(builder, already_ran_build, out_stream) catch {};
    return error.InvalidArgs;
}

fn unwrapArg(arg: %[]u8) %[]u8 {
    return arg catch |err| {
        warn("Unable to parse command line: {}\n", err);
        return err;
    };
}
