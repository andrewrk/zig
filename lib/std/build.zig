// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.
const std = @import("std.zig");
const builtin = std.builtin;
const io = std.io;
const fs = std.fs;
const mem = std.mem;
const debug = std.debug;
const panic = std.debug.panic;
const assert = debug.assert;
const warn = std.debug.warn;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;
const Allocator = mem.Allocator;
const process = std.process;
const BufSet = std.BufSet;
const BufMap = std.BufMap;
const fmt_lib = std.fmt;
const File = std.fs.File;
const CrossTarget = std.zig.CrossTarget;

pub const FmtStep = @import("build/FmtStep.zig");
pub const TranslateCStep = @import("build/TranslateCStep.zig");
pub const WriteFileStep = @import("build/WriteFileStep.zig");
pub const RunStep = @import("build/RunStep.zig");
pub const CheckFileStep = @import("build/CheckFileStep.zig");
pub const InstallRawStep = @import("build/InstallRawStep.zig");

pub const Builder = struct {
    install_tls: TopLevelStep,
    uninstall_tls: TopLevelStep,
    allocator: *Allocator,
    user_input_options: UserInputOptionsMap,
    available_options_map: AvailableOptionsMap,
    available_options_list: ArrayList(AvailableOption),
    verbose: bool,
    verbose_tokenize: bool,
    verbose_ast: bool,
    verbose_link: bool,
    verbose_cc: bool,
    verbose_ir: bool,
    verbose_llvm_ir: bool,
    verbose_cimport: bool,
    verbose_llvm_cpu_features: bool,
    /// The purpose of executing the command is for a human to read compile errors from the terminal
    prominent_compile_errors: bool,
    color: enum { auto, on, off } = .auto,
    invalid_user_input: bool,
    zig_exe: []const u8,
    default_step: *Step,
    env_map: *BufMap,
    top_level_steps: ArrayList(*TopLevelStep),
    install_prefix: []const u8,
    dest_dir: ?[]const u8,
    lib_dir: []const u8,
    exe_dir: []const u8,
    h_dir: []const u8,
    install_path: []const u8,
    sysroot: ?[]const u8 = null,
    search_prefixes: ArrayList([]const u8),
    libc_file: ?[]const u8 = null,
    installed_files: ArrayList(InstalledFile),
    build_root: []const u8,
    cache_root: []const u8,
    global_cache_root: []const u8,
    release_mode: ?builtin.Mode,
    is_release: bool,
    override_lib_dir: ?[]const u8,
    vcpkg_root: VcpkgRoot,
    pkg_config_pkg_list: ?(PkgConfigError![]const PkgConfigPkg) = null,
    args: ?[][]const u8 = null,

    const PkgConfigError = error{
        PkgConfigCrashed,
        PkgConfigFailed,
        PkgConfigNotInstalled,
        PkgConfigInvalidOutput,
    };

    pub const PkgConfigPkg = struct {
        name: []const u8,
        desc: []const u8,
    };

    pub const CStd = enum {
        C89,
        C99,
        C11,
    };

    const UserInputOptionsMap = StringHashMap(UserInputOption);
    const AvailableOptionsMap = StringHashMap(AvailableOption);

    const AvailableOption = struct {
        name: []const u8,
        type_id: TypeId,
        description: []const u8,
    };

    const UserInputOption = struct {
        name: []const u8,
        value: UserValue,
        used: bool,
    };

    const UserValue = union(enum) {
        flag: void,
        scalar: []const u8,
        list: ArrayList([]const u8),
    };

    const TypeId = enum {
        bool,
        int,
        float,
        @"enum",
        string,
        list,
    };

    const TopLevelStep = struct {
        pub const base_id = .top_level;

        step: Step,
        description: []const u8,
    };

    pub const DirList = struct {
        lib_dir: ?[]const u8 = null,
        exe_dir: ?[]const u8 = null,
        include_dir: ?[]const u8 = null,
    };

    pub fn create(
        allocator: *Allocator,
        zig_exe: []const u8,
        build_root: []const u8,
        cache_root: []const u8,
        global_cache_root: []const u8,
    ) !*Builder {
        const env_map = try allocator.create(BufMap);
        env_map.* = try process.getEnvMap(allocator);

        const self = try allocator.create(Builder);
        self.* = Builder{
            .zig_exe = zig_exe,
            .build_root = build_root,
            .cache_root = try fs.path.relative(allocator, build_root, cache_root),
            .global_cache_root = global_cache_root,
            .verbose = false,
            .verbose_tokenize = false,
            .verbose_ast = false,
            .verbose_link = false,
            .verbose_cc = false,
            .verbose_ir = false,
            .verbose_llvm_ir = false,
            .verbose_cimport = false,
            .verbose_llvm_cpu_features = false,
            .prominent_compile_errors = false,
            .invalid_user_input = false,
            .allocator = allocator,
            .user_input_options = UserInputOptionsMap.init(allocator),
            .available_options_map = AvailableOptionsMap.init(allocator),
            .available_options_list = ArrayList(AvailableOption).init(allocator),
            .top_level_steps = ArrayList(*TopLevelStep).init(allocator),
            .default_step = undefined,
            .env_map = env_map,
            .search_prefixes = ArrayList([]const u8).init(allocator),
            .install_prefix = undefined,
            .lib_dir = undefined,
            .exe_dir = undefined,
            .h_dir = undefined,
            .dest_dir = env_map.get("DESTDIR"),
            .installed_files = ArrayList(InstalledFile).init(allocator),
            .install_tls = TopLevelStep{
                .step = Step.initNoOp(.top_level, "install", allocator),
                .description = "Copy build artifacts to prefix path",
            },
            .uninstall_tls = TopLevelStep{
                .step = Step.init(.top_level, "uninstall", allocator, makeUninstall),
                .description = "Remove build artifacts from prefix path",
            },
            .release_mode = null,
            .is_release = false,
            .override_lib_dir = null,
            .install_path = undefined,
            .vcpkg_root = VcpkgRoot{ .unattempted = {} },
            .args = null,
        };
        try self.top_level_steps.append(&self.install_tls);
        try self.top_level_steps.append(&self.uninstall_tls);
        self.default_step = &self.install_tls.step;
        return self;
    }

    pub fn destroy(self: *Builder) void {
        self.env_map.deinit();
        self.top_level_steps.deinit();
        self.allocator.destroy(self);
    }

    /// This function is intended to be called by std/special/build_runner.zig, not a build.zig file.
    pub fn resolveInstallPrefix(self: *Builder, install_prefix: ?[]const u8, dir_list: DirList) void {
        if (self.dest_dir) |dest_dir| {
            self.install_prefix = install_prefix orelse "/usr";
            self.install_path = fs.path.join(self.allocator, &[_][]const u8{ dest_dir, self.install_prefix }) catch unreachable;
        } else {
            self.install_prefix = install_prefix orelse
                (fs.path.join(self.allocator, &[_][]const u8{ self.build_root, "zig-out" }) catch unreachable);
            self.install_path = self.install_prefix;
        }

        var lib_list = [_][]const u8{ self.install_path, "lib" };
        var exe_list = [_][]const u8{ self.install_path, "bin" };
        var h_list = [_][]const u8{ self.install_path, "include" };

        if (dir_list.lib_dir) |dir| {
            if (std.fs.path.isAbsolute(dir)) lib_list[0] = self.dest_dir orelse "";
            lib_list[1] = dir;
        }

        if (dir_list.exe_dir) |dir| {
            if (std.fs.path.isAbsolute(dir)) exe_list[0] = self.dest_dir orelse "";
            exe_list[1] = dir;
        }

        if (dir_list.include_dir) |dir| {
            if (std.fs.path.isAbsolute(dir)) h_list[0] = self.dest_dir orelse "";
            h_list[1] = dir;
        }

        self.lib_dir = fs.path.join(self.allocator, &lib_list) catch unreachable;
        self.exe_dir = fs.path.join(self.allocator, &exe_list) catch unreachable;
        self.h_dir = fs.path.join(self.allocator, &h_list) catch unreachable;
    }

    fn convertOptionalPathToFileSource(path: ?[]const u8) ?FileSource {
        return if (path) |p|
            FileSource{ .path = p }
        else
            null;
    }

    pub fn addExecutable(self: *Builder, name: []const u8, root_src: ?[]const u8) *LibExeObjStep {
        return addExecutableSource(self, name, convertOptionalPathToFileSource(root_src));
    }

    pub fn addExecutableSource(builder: *Builder, name: []const u8, root_src: ?FileSource) *LibExeObjStep {
        return LibExeObjStep.createExecutable(builder, name, root_src);
    }

    pub fn addObject(self: *Builder, name: []const u8, root_src: ?[]const u8) *LibExeObjStep {
        return addObjectSource(self, name, convertOptionalPathToFileSource(root_src));
    }

    pub fn addObjectSource(builder: *Builder, name: []const u8, root_src: ?FileSource) *LibExeObjStep {
        return LibExeObjStep.createObject(builder, name, root_src);
    }

    pub fn addSharedLibrary(
        self: *Builder,
        name: []const u8,
        root_src: ?[]const u8,
        kind: LibExeObjStep.SharedLibKind,
    ) *LibExeObjStep {
        return addSharedLibrarySource(self, name, convertOptionalPathToFileSource(root_src), kind);
    }

    pub fn addSharedLibrarySource(
        self: *Builder,
        name: []const u8,
        root_src: ?FileSource,
        kind: LibExeObjStep.SharedLibKind,
    ) *LibExeObjStep {
        return LibExeObjStep.createSharedLibrary(self, name, root_src, kind);
    }

    pub fn addStaticLibrary(self: *Builder, name: []const u8, root_src: ?[]const u8) *LibExeObjStep {
        return addStaticLibrarySource(self, name, convertOptionalPathToFileSource(root_src));
    }

    pub fn addStaticLibrarySource(self: *Builder, name: []const u8, root_src: ?FileSource) *LibExeObjStep {
        return LibExeObjStep.createStaticLibrary(self, name, root_src);
    }

    pub fn addTest(self: *Builder, root_src: []const u8) *LibExeObjStep {
        return LibExeObjStep.createTest(self, "test", .{ .path = root_src });
    }

    pub fn addTestSource(self: *Builder, root_src: FileSource) *LibExeObjStep {
        return LibExeObjStep.createTest(self, "test", root_src.dupe(self));
    }

    pub fn addAssemble(self: *Builder, name: []const u8, src: []const u8) *LibExeObjStep {
        return addAssembleSource(self, name, .{ .path = src });
    }

    pub fn addAssembleSource(self: *Builder, name: []const u8, src: FileSource) *LibExeObjStep {
        const obj_step = LibExeObjStep.createObject(self, name, null);
        obj_step.addAssemblyFileSource(src.dupe(self));
        return obj_step;
    }

    /// Initializes a RunStep with argv, which must at least have the path to the
    /// executable. More command line arguments can be added with `addArg`,
    /// `addArgs`, and `addArtifactArg`.
    /// Be careful using this function, as it introduces a system dependency.
    /// To run an executable built with zig build, see `LibExeObjStep.run`.
    pub fn addSystemCommand(self: *Builder, argv: []const []const u8) *RunStep {
        assert(argv.len >= 1);
        const run_step = RunStep.create(self, self.fmt("run {s}", .{argv[0]}));
        run_step.addArgs(argv);
        return run_step;
    }

    /// Allocator.dupe without the need to handle out of memory.
    pub fn dupe(self: *Builder, bytes: []const u8) []u8 {
        return self.allocator.dupe(u8, bytes) catch unreachable;
    }

    /// Duplicates an array of strings without the need to handle out of memory.
    pub fn dupeStrings(self: *Builder, strings: []const []const u8) [][]u8 {
        const array = self.allocator.alloc([]u8, strings.len) catch unreachable;
        for (strings) |s, i| {
            array[i] = self.dupe(s);
        }
        return array;
    }

    /// Duplicates a path and converts all slashes to the OS's canonical path separator.
    pub fn dupePath(self: *Builder, bytes: []const u8) []u8 {
        const the_copy = self.dupe(bytes);
        for (the_copy) |*byte| {
            switch (byte.*) {
                '/', '\\' => byte.* = fs.path.sep,
                else => {},
            }
        }
        return the_copy;
    }

    /// Duplicates a package recursively.
    pub fn dupePkg(self: *Builder, package: Pkg) Pkg {
        var the_copy = Pkg{
            .name = self.dupe(package.name),
            .path = package.path.dupe(self),
        };

        if (package.dependencies) |dependencies| {
            const new_dependencies = self.allocator.alloc(Pkg, dependencies.len) catch unreachable;
            the_copy.dependencies = new_dependencies;

            for (dependencies) |dep_package, i| {
                new_dependencies[i] = self.dupePkg(dep_package);
            }
        }
        return the_copy;
    }

    pub fn addWriteFile(self: *Builder, file_path: []const u8, data: []const u8) *WriteFileStep {
        const write_file_step = self.addWriteFiles();
        write_file_step.add(file_path, data);
        return write_file_step;
    }

    pub fn addWriteFiles(self: *Builder) *WriteFileStep {
        const write_file_step = self.allocator.create(WriteFileStep) catch unreachable;
        write_file_step.* = WriteFileStep.init(self);
        return write_file_step;
    }

    pub fn addLog(self: *Builder, comptime format: []const u8, args: anytype) *LogStep {
        const data = self.fmt(format, args);
        const log_step = self.allocator.create(LogStep) catch unreachable;
        log_step.* = LogStep.init(self, data);
        return log_step;
    }

    pub fn addRemoveDirTree(self: *Builder, dir_path: []const u8) *RemoveDirStep {
        const remove_dir_step = self.allocator.create(RemoveDirStep) catch unreachable;
        remove_dir_step.* = RemoveDirStep.init(self, dir_path);
        return remove_dir_step;
    }

    pub fn addFmt(self: *Builder, paths: []const []const u8) *FmtStep {
        return FmtStep.create(self, paths);
    }

    pub fn addTranslateC(self: *Builder, source: FileSource) *TranslateCStep {
        return TranslateCStep.create(self, source.dupe(self));
    }

    pub fn version(self: *const Builder, major: u32, minor: u32, patch: u32) LibExeObjStep.SharedLibKind {
        _ = self;
        return .{
            .versioned = .{
                .major = major,
                .minor = minor,
                .patch = patch,
            },
        };
    }

    pub fn make(self: *Builder, step_names: []const []const u8) !void {
        try self.makePath(self.cache_root);

        var wanted_steps = ArrayList(*Step).init(self.allocator);
        defer wanted_steps.deinit();

        if (step_names.len == 0) {
            try wanted_steps.append(self.default_step);
        } else {
            for (step_names) |step_name| {
                const s = try self.getTopLevelStepByName(step_name);
                try wanted_steps.append(s);
            }
        }

        for (wanted_steps.items) |s| {
            try self.makeOneStep(s);
        }
    }

    pub fn getInstallStep(self: *Builder) *Step {
        return &self.install_tls.step;
    }

    pub fn getUninstallStep(self: *Builder) *Step {
        return &self.uninstall_tls.step;
    }

    fn makeUninstall(uninstall_step: *Step) anyerror!void {
        const uninstall_tls = @fieldParentPtr(TopLevelStep, "step", uninstall_step);
        const self = @fieldParentPtr(Builder, "uninstall_tls", uninstall_tls);

        for (self.installed_files.items) |installed_file| {
            const full_path = self.getInstallPath(installed_file.dir, installed_file.path);
            if (self.verbose) {
                warn("rm {s}\n", .{full_path});
            }
            fs.cwd().deleteTree(full_path) catch {};
        }

        // TODO remove empty directories
    }

    fn makeOneStep(self: *Builder, s: *Step) anyerror!void {
        if (s.loop_flag) {
            warn("Dependency loop detected:\n  {s}\n", .{s.name});
            return error.DependencyLoopDetected;
        }
        s.loop_flag = true;

        for (s.dependencies.items) |dep| {
            self.makeOneStep(dep) catch |err| {
                if (err == error.DependencyLoopDetected) {
                    warn("  {s}\n", .{s.name});
                }
                return err;
            };
        }

        s.loop_flag = false;

        try s.make();
    }

    fn getTopLevelStepByName(self: *Builder, name: []const u8) !*Step {
        for (self.top_level_steps.items) |top_level_step| {
            if (mem.eql(u8, top_level_step.step.name, name)) {
                return &top_level_step.step;
            }
        }
        warn("Cannot run step '{s}' because it does not exist\n", .{name});
        return error.InvalidStepName;
    }

    pub fn option(self: *Builder, comptime T: type, name_raw: []const u8, description_raw: []const u8) ?T {
        const name = self.dupe(name_raw);
        const description = self.dupe(description_raw);
        const type_id = comptime typeToEnum(T);
        const available_option = AvailableOption{
            .name = name,
            .type_id = type_id,
            .description = description,
        };
        if ((self.available_options_map.fetchPut(name, available_option) catch unreachable) != null) {
            panic("Option '{s}' declared twice", .{name});
        }
        self.available_options_list.append(available_option) catch unreachable;

        const option_ptr = self.user_input_options.getPtr(name) orelse return null;
        option_ptr.used = true;
        switch (type_id) {
            .bool => switch (option_ptr.value) {
                .flag => return true,
                .scalar => |s| {
                    if (mem.eql(u8, s, "true")) {
                        return true;
                    } else if (mem.eql(u8, s, "false")) {
                        return false;
                    } else {
                        warn("Expected -D{s} to be a boolean, but received '{s}'\n\n", .{ name, s });
                        self.markInvalidUserInput();
                        return null;
                    }
                },
                .list => {
                    warn("Expected -D{s} to be a boolean, but received a list.\n\n", .{name});
                    self.markInvalidUserInput();
                    return null;
                },
            },
            .int => switch (option_ptr.value) {
                .flag => {
                    warn("Expected -D{s} to be an integer, but received a boolean.\n\n", .{name});
                    self.markInvalidUserInput();
                    return null;
                },
                .scalar => |s| {
                    const n = std.fmt.parseInt(T, s, 10) catch |err| switch (err) {
                        error.Overflow => {
                            warn("-D{s} value {s} cannot fit into type {s}.\n\n", .{ name, s, @typeName(T) });
                            self.markInvalidUserInput();
                            return null;
                        },
                        else => {
                            warn("Expected -D{s} to be an integer of type {s}.\n\n", .{ name, @typeName(T) });
                            self.markInvalidUserInput();
                            return null;
                        },
                    };
                    return n;
                },
                .list => {
                    warn("Expected -D{s} to be an integer, but received a list.\n\n", .{name});
                    self.markInvalidUserInput();
                    return null;
                },
            },
            .float => switch (option_ptr.value) {
                .flag => {
                    warn("Expected -D{s} to be a float, but received a boolean.\n\n", .{name});
                    self.markInvalidUserInput();
                    return null;
                },
                .scalar => |s| {
                    const n = std.fmt.parseFloat(T, s) catch {
                        warn("Expected -D{s} to be a float of type {s}.\n\n", .{ name, @typeName(T) });
                        self.markInvalidUserInput();
                        return null;
                    };
                    return n;
                },
                .list => {
                    warn("Expected -D{s} to be a float, but received a list.\n\n", .{name});
                    self.markInvalidUserInput();
                    return null;
                },
            },
            .@"enum" => switch (option_ptr.value) {
                .flag => {
                    warn("Expected -D{s} to be a string, but received a boolean.\n\n", .{name});
                    self.markInvalidUserInput();
                    return null;
                },
                .scalar => |s| {
                    if (std.meta.stringToEnum(T, s)) |enum_lit| {
                        return enum_lit;
                    } else {
                        warn("Expected -D{s} to be of type {s}.\n\n", .{ name, @typeName(T) });
                        self.markInvalidUserInput();
                        return null;
                    }
                },
                .list => {
                    warn("Expected -D{s} to be a string, but received a list.\n\n", .{name});
                    self.markInvalidUserInput();
                    return null;
                },
            },
            .string => switch (option_ptr.value) {
                .flag => {
                    warn("Expected -D{s} to be a string, but received a boolean.\n\n", .{name});
                    self.markInvalidUserInput();
                    return null;
                },
                .list => {
                    warn("Expected -D{s} to be a string, but received a list.\n\n", .{name});
                    self.markInvalidUserInput();
                    return null;
                },
                .scalar => |s| return s,
            },
            .list => switch (option_ptr.value) {
                .flag => {
                    warn("Expected -D{s} to be a list, but received a boolean.\n\n", .{name});
                    self.markInvalidUserInput();
                    return null;
                },
                .scalar => |s| {
                    return self.allocator.dupe([]const u8, &[_][]const u8{s}) catch unreachable;
                },
                .list => |lst| return lst.items,
            },
        }
    }

    pub fn step(self: *Builder, name: []const u8, description: []const u8) *Step {
        const step_info = self.allocator.create(TopLevelStep) catch unreachable;
        step_info.* = TopLevelStep{
            .step = Step.initNoOp(.top_level, name, self.allocator),
            .description = self.dupe(description),
        };
        self.top_level_steps.append(step_info) catch unreachable;
        return &step_info.step;
    }

    /// This provides the -Drelease option to the build user and does not give them the choice.
    pub fn setPreferredReleaseMode(self: *Builder, mode: builtin.Mode) void {
        if (self.release_mode != null) {
            @panic("setPreferredReleaseMode must be called before standardReleaseOptions and may not be called twice");
        }
        const description = self.fmt("Create a release build ({s})", .{@tagName(mode)});
        self.is_release = self.option(bool, "release", description) orelse false;
        self.release_mode = if (self.is_release) mode else builtin.Mode.Debug;
    }

    /// If you call this without first calling `setPreferredReleaseMode` then it gives the build user
    /// the choice of what kind of release.
    pub fn standardReleaseOptions(self: *Builder) builtin.Mode {
        if (self.release_mode) |mode| return mode;

        const release_safe = self.option(bool, "release-safe", "Optimizations on and safety on") orelse false;
        const release_fast = self.option(bool, "release-fast", "Optimizations on and safety off") orelse false;
        const release_small = self.option(bool, "release-small", "Size optimizations on and safety off") orelse false;

        const mode = if (release_safe and !release_fast and !release_small)
            builtin.Mode.ReleaseSafe
        else if (release_fast and !release_safe and !release_small)
            builtin.Mode.ReleaseFast
        else if (release_small and !release_fast and !release_safe)
            builtin.Mode.ReleaseSmall
        else if (!release_fast and !release_safe and !release_small)
            builtin.Mode.Debug
        else x: {
            warn("Multiple release modes (of -Drelease-safe, -Drelease-fast and -Drelease-small)\n\n", .{});
            self.markInvalidUserInput();
            break :x builtin.Mode.Debug;
        };
        self.is_release = mode != .Debug;
        self.release_mode = mode;
        return mode;
    }

    pub const StandardTargetOptionsArgs = struct {
        whitelist: ?[]const CrossTarget = null,

        default_target: CrossTarget = CrossTarget{},
    };

    /// Exposes standard `zig build` options for choosing a target.
    pub fn standardTargetOptions(self: *Builder, args: StandardTargetOptionsArgs) CrossTarget {
        const maybe_triple = self.option(
            []const u8,
            "target",
            "The CPU architecture, OS, and ABI to build for",
        );
        const mcpu = self.option([]const u8, "cpu", "Target CPU features to add or subtract");

        const triple = maybe_triple orelse return args.default_target;

        var diags: CrossTarget.ParseOptions.Diagnostics = .{};
        const selected_target = CrossTarget.parse(.{
            .arch_os_abi = triple,
            .cpu_features = mcpu,
            .diagnostics = &diags,
        }) catch |err| switch (err) {
            error.UnknownCpuModel => {
                warn("Unknown CPU: '{s}'\nAvailable CPUs for architecture '{s}':\n", .{
                    diags.cpu_name.?,
                    @tagName(diags.arch.?),
                });
                for (diags.arch.?.allCpuModels()) |cpu| {
                    warn(" {s}\n", .{cpu.name});
                }
                warn("\n", .{});
                self.markInvalidUserInput();
                return args.default_target;
            },
            error.UnknownCpuFeature => {
                warn(
                    \\Unknown CPU feature: '{s}'
                    \\Available CPU features for architecture '{s}':
                    \\
                , .{
                    diags.unknown_feature_name,
                    @tagName(diags.arch.?),
                });
                for (diags.arch.?.allFeaturesList()) |feature| {
                    warn(" {s}: {s}\n", .{ feature.name, feature.description });
                }
                warn("\n", .{});
                self.markInvalidUserInput();
                return args.default_target;
            },
            error.UnknownOperatingSystem => {
                warn(
                    \\Unknown OS: '{s}'
                    \\Available operating systems:
                    \\
                , .{diags.os_name});
                inline for (std.meta.fields(std.Target.Os.Tag)) |field| {
                    warn(" {s}\n", .{field.name});
                }
                warn("\n", .{});
                self.markInvalidUserInput();
                return args.default_target;
            },
            else => |e| {
                warn("Unable to parse target '{s}': {s}\n\n", .{ triple, @errorName(e) });
                self.markInvalidUserInput();
                return args.default_target;
            },
        };

        const selected_canonicalized_triple = selected_target.zigTriple(self.allocator) catch unreachable;

        if (args.whitelist) |list| whitelist_check: {
            // Make sure it's a match of one of the list.
            var mismatch_triple = true;
            var mismatch_cpu_features = true;
            var whitelist_item = CrossTarget{};
            for (list) |t| {
                mismatch_cpu_features = true;
                mismatch_triple = true;

                const t_triple = t.zigTriple(self.allocator) catch unreachable;
                if (mem.eql(u8, t_triple, selected_canonicalized_triple)) {
                    mismatch_triple = false;
                    whitelist_item = t;
                    if (t.getCpuFeatures().isSuperSetOf(selected_target.getCpuFeatures())) {
                        mismatch_cpu_features = false;
                        break :whitelist_check;
                    } else {
                        break;
                    }
                }
            }
            if (mismatch_triple) {
                warn("Chosen target '{s}' does not match one of the supported targets:\n", .{
                    selected_canonicalized_triple,
                });
                for (list) |t| {
                    const t_triple = t.zigTriple(self.allocator) catch unreachable;
                    warn(" {s}\n", .{t_triple});
                }
                warn("\n", .{});
            } else {
                assert(mismatch_cpu_features);
                const whitelist_cpu = whitelist_item.getCpu();
                const selected_cpu = selected_target.getCpu();
                warn("Chosen CPU model '{s}' does not match one of the supported targets:\n", .{
                    selected_cpu.model.name,
                });
                warn("  Supported feature Set: ", .{});
                const all_features = whitelist_cpu.arch.allFeaturesList();
                var populated_cpu_features = whitelist_cpu.model.features;
                populated_cpu_features.populateDependencies(all_features);
                for (all_features) |feature, i_usize| {
                    const i = @intCast(std.Target.Cpu.Feature.Set.Index, i_usize);
                    const in_cpu_set = populated_cpu_features.isEnabled(i);
                    if (in_cpu_set) {
                        warn("{s} ", .{feature.name});
                    }
                }
                warn("\n", .{});
                warn("  Remove: ", .{});
                for (all_features) |feature, i_usize| {
                    const i = @intCast(std.Target.Cpu.Feature.Set.Index, i_usize);
                    const in_cpu_set = populated_cpu_features.isEnabled(i);
                    const in_actual_set = selected_cpu.features.isEnabled(i);
                    if (in_actual_set and !in_cpu_set) {
                        warn("{s} ", .{feature.name});
                    }
                }
                warn("\n", .{});
            }
            self.markInvalidUserInput();
            return args.default_target;
        }

        return selected_target;
    }

    pub fn addUserInputOption(self: *Builder, name_raw: []const u8, value_raw: []const u8) !bool {
        const name = self.dupe(name_raw);
        const value = self.dupe(value_raw);
        const gop = try self.user_input_options.getOrPut(name);
        if (!gop.found_existing) {
            gop.value_ptr.* = UserInputOption{
                .name = name,
                .value = .{ .scalar = value },
                .used = false,
            };
            return false;
        }

        // option already exists
        switch (gop.value_ptr.value) {
            .scalar => |s| {
                // turn it into a list
                var list = ArrayList([]const u8).init(self.allocator);
                list.append(s) catch unreachable;
                list.append(value) catch unreachable;
                self.user_input_options.put(name, .{
                    .name = name,
                    .value = .{ .list = list },
                    .used = false,
                }) catch unreachable;
            },
            .list => |*list| {
                // append to the list
                list.append(value) catch unreachable;
                self.user_input_options.put(name, .{
                    .name = name,
                    .value = .{ .list = list.* },
                    .used = false,
                }) catch unreachable;
            },
            .flag => {
                warn("Option '-D{s}={s}' conflicts with flag '-D{s}'.\n", .{ name, value, name });
                return true;
            },
        }
        return false;
    }

    pub fn addUserInputFlag(self: *Builder, name_raw: []const u8) !bool {
        const name = self.dupe(name_raw);
        const gop = try self.user_input_options.getOrPut(name);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .name = name,
                .value = .{ .flag = {} },
                .used = false,
            };
            return false;
        }

        // option already exists
        switch (gop.value_ptr.value) {
            .scalar => |s| {
                warn("Flag '-D{s}' conflicts with option '-D{s}={s}'.\n", .{ name, name, s });
                return true;
            },
            .list => {
                warn("Flag '-D{s}' conflicts with multiple options of the same name.\n", .{name});
                return true;
            },
            .flag => {},
        }
        return false;
    }

    fn typeToEnum(comptime T: type) TypeId {
        return switch (@typeInfo(T)) {
            .Int => .int,
            .Float => .float,
            .Bool => .bool,
            .Enum => .@"enum",
            else => switch (T) {
                []const u8 => .string,
                []const []const u8 => .list,
                else => @compileError("Unsupported type: " ++ @typeName(T)),
            },
        };
    }

    fn markInvalidUserInput(self: *Builder) void {
        self.invalid_user_input = true;
    }

    pub fn validateUserInputDidItFail(self: *Builder) bool {
        // make sure all args are used
        var it = self.user_input_options.iterator();
        while (it.next()) |entry| {
            if (!entry.value_ptr.used) {
                warn("Invalid option: -D{s}\n\n", .{entry.key_ptr.*});
                self.markInvalidUserInput();
            }
        }

        return self.invalid_user_input;
    }

    pub fn spawnChild(self: *Builder, argv: []const []const u8) !void {
        return self.spawnChildEnvMap(null, self.env_map, argv);
    }

    fn printCmd(cwd: ?[]const u8, argv: []const []const u8) void {
        if (cwd) |yes_cwd| warn("cd {s} && ", .{yes_cwd});
        for (argv) |arg| {
            warn("{s} ", .{arg});
        }
        warn("\n", .{});
    }

    fn spawnChildEnvMap(self: *Builder, cwd: ?[]const u8, env_map: *const BufMap, argv: []const []const u8) !void {
        if (self.verbose) {
            printCmd(cwd, argv);
        }

        const child = std.ChildProcess.init(argv, self.allocator) catch unreachable;
        defer child.deinit();

        child.cwd = cwd;
        child.env_map = env_map;

        const term = child.spawnAndWait() catch |err| {
            warn("Unable to spawn {s}: {s}\n", .{ argv[0], @errorName(err) });
            return err;
        };

        switch (term) {
            .Exited => |code| {
                if (code != 0) {
                    warn("The following command exited with error code {}:\n", .{code});
                    printCmd(cwd, argv);
                    return error.UncleanExit;
                }
            },
            else => {
                warn("The following command terminated unexpectedly:\n", .{});
                printCmd(cwd, argv);

                return error.UncleanExit;
            },
        }
    }

    pub fn makePath(self: *Builder, path: []const u8) !void {
        fs.cwd().makePath(self.pathFromRoot(path)) catch |err| {
            warn("Unable to create path {s}: {s}\n", .{ path, @errorName(err) });
            return err;
        };
    }

    pub fn installArtifact(self: *Builder, artifact: *LibExeObjStep) void {
        self.getInstallStep().dependOn(&self.addInstallArtifact(artifact).step);
    }

    pub fn addInstallArtifact(self: *Builder, artifact: *LibExeObjStep) *InstallArtifactStep {
        return InstallArtifactStep.create(self, artifact);
    }

    ///`dest_rel_path` is relative to prefix path
    pub fn installFile(self: *Builder, src_path: []const u8, dest_rel_path: []const u8) void {
        self.getInstallStep().dependOn(&self.addInstallFileWithDir(.{ .path = src_path }, .prefix, dest_rel_path).step);
    }

    pub fn installDirectory(self: *Builder, options: InstallDirectoryOptions) void {
        self.getInstallStep().dependOn(&self.addInstallDirectory(options).step);
    }

    ///`dest_rel_path` is relative to bin path
    pub fn installBinFile(self: *Builder, src_path: []const u8, dest_rel_path: []const u8) void {
        self.getInstallStep().dependOn(&self.addInstallFileWithDir(.{ .path = src_path }, .bin, dest_rel_path).step);
    }

    ///`dest_rel_path` is relative to lib path
    pub fn installLibFile(self: *Builder, src_path: []const u8, dest_rel_path: []const u8) void {
        self.getInstallStep().dependOn(&self.addInstallFileWithDir(.{ .path = src_path }, .lib, dest_rel_path).step);
    }

    pub fn installRaw(self: *Builder, artifact: *LibExeObjStep, dest_filename: []const u8) void {
        self.getInstallStep().dependOn(&self.addInstallRaw(artifact, dest_filename).step);
    }

    ///`dest_rel_path` is relative to install prefix path
    pub fn addInstallFile(self: *Builder, source: FileSource, dest_rel_path: []const u8) *InstallFileStep {
        return self.addInstallFileWithDir(source.dupe(self), .prefix, dest_rel_path);
    }

    ///`dest_rel_path` is relative to bin path
    pub fn addInstallBinFile(self: *Builder, source: FileSource, dest_rel_path: []const u8) *InstallFileStep {
        return self.addInstallFileWithDir(source.dupe(self), .bin, dest_rel_path);
    }

    ///`dest_rel_path` is relative to lib path
    pub fn addInstallLibFile(self: *Builder, source: FileSource, dest_rel_path: []const u8) *InstallFileStep {
        return self.addInstallFileWithDir(source.dupe(self), .lib, dest_rel_path);
    }

    pub fn addInstallRaw(self: *Builder, artifact: *LibExeObjStep, dest_filename: []const u8) *InstallRawStep {
        return InstallRawStep.create(self, artifact, dest_filename);
    }

    pub fn addInstallFileWithDir(
        self: *Builder,
        source: FileSource,
        install_dir: InstallDir,
        dest_rel_path: []const u8,
    ) *InstallFileStep {
        if (dest_rel_path.len == 0) {
            panic("dest_rel_path must be non-empty", .{});
        }
        const install_step = self.allocator.create(InstallFileStep) catch unreachable;
        install_step.* = InstallFileStep.init(self, source.dupe(self), install_dir, dest_rel_path);
        return install_step;
    }

    pub fn addInstallDirectory(self: *Builder, options: InstallDirectoryOptions) *InstallDirStep {
        const install_step = self.allocator.create(InstallDirStep) catch unreachable;
        install_step.* = InstallDirStep.init(self, options);
        return install_step;
    }

    pub fn pushInstalledFile(self: *Builder, dir: InstallDir, dest_rel_path: []const u8) void {
        const file = InstalledFile{
            .dir = dir,
            .path = dest_rel_path,
        };
        self.installed_files.append(file.dupe(self)) catch unreachable;
    }

    pub fn updateFile(self: *Builder, source_path: []const u8, dest_path: []const u8) !void {
        if (self.verbose) {
            warn("cp {s} {s} ", .{ source_path, dest_path });
        }
        const cwd = fs.cwd();
        const prev_status = try fs.Dir.updateFile(cwd, source_path, cwd, dest_path, .{});
        if (self.verbose) switch (prev_status) {
            .stale => warn("# installed\n", .{}),
            .fresh => warn("# up-to-date\n", .{}),
        };
    }

    pub fn truncateFile(self: *Builder, dest_path: []const u8) !void {
        if (self.verbose) {
            warn("truncate {s}\n", .{dest_path});
        }
        const cwd = fs.cwd();
        var src_file = cwd.createFile(dest_path, .{}) catch |err| switch (err) {
            error.FileNotFound => blk: {
                if (fs.path.dirname(dest_path)) |dirname| {
                    try cwd.makePath(dirname);
                }
                break :blk try cwd.createFile(dest_path, .{});
            },
            else => |e| return e,
        };
        src_file.close();
    }

    pub fn pathFromRoot(self: *Builder, rel_path: []const u8) []u8 {
        return fs.path.resolve(self.allocator, &[_][]const u8{ self.build_root, rel_path }) catch unreachable;
    }

    pub fn fmt(self: *Builder, comptime format: []const u8, args: anytype) []u8 {
        return fmt_lib.allocPrint(self.allocator, format, args) catch unreachable;
    }

    pub fn findProgram(self: *Builder, names: []const []const u8, paths: []const []const u8) ![]const u8 {
        // TODO report error for ambiguous situations
        const exe_extension = @as(CrossTarget, .{}).exeFileExt();
        for (self.search_prefixes.items) |search_prefix| {
            for (names) |name| {
                if (fs.path.isAbsolute(name)) {
                    return name;
                }
                const full_path = try fs.path.join(self.allocator, &[_][]const u8{
                    search_prefix,
                    "bin",
                    self.fmt("{s}{s}", .{ name, exe_extension }),
                });
                return fs.realpathAlloc(self.allocator, full_path) catch continue;
            }
        }
        if (self.env_map.get("PATH")) |PATH| {
            for (names) |name| {
                if (fs.path.isAbsolute(name)) {
                    return name;
                }
                var it = mem.tokenize(PATH, &[_]u8{fs.path.delimiter});
                while (it.next()) |path| {
                    const full_path = try fs.path.join(self.allocator, &[_][]const u8{
                        path,
                        self.fmt("{s}{s}", .{ name, exe_extension }),
                    });
                    return fs.realpathAlloc(self.allocator, full_path) catch continue;
                }
            }
        }
        for (names) |name| {
            if (fs.path.isAbsolute(name)) {
                return name;
            }
            for (paths) |path| {
                const full_path = try fs.path.join(self.allocator, &[_][]const u8{
                    path,
                    self.fmt("{s}{s}", .{ name, exe_extension }),
                });
                return fs.realpathAlloc(self.allocator, full_path) catch continue;
            }
        }
        return error.FileNotFound;
    }

    pub fn execAllowFail(
        self: *Builder,
        argv: []const []const u8,
        out_code: *u8,
        stderr_behavior: std.ChildProcess.StdIo,
    ) ![]u8 {
        assert(argv.len != 0);

        const max_output_size = 400 * 1024;
        const child = try std.ChildProcess.init(argv, self.allocator);
        defer child.deinit();

        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = stderr_behavior;
        child.env_map = self.env_map;

        try child.spawn();

        const stdout = try child.stdout.?.reader().readAllAlloc(self.allocator, max_output_size);
        errdefer self.allocator.free(stdout);

        const term = try child.wait();
        switch (term) {
            .Exited => |code| {
                if (code != 0) {
                    out_code.* = @truncate(u8, code);
                    return error.ExitCodeFailure;
                }
                return stdout;
            },
            .Signal, .Stopped, .Unknown => |code| {
                out_code.* = @truncate(u8, code);
                return error.ProcessTerminated;
            },
        }
    }

    pub fn execFromStep(self: *Builder, argv: []const []const u8, src_step: ?*Step) ![]u8 {
        assert(argv.len != 0);

        if (self.verbose) {
            printCmd(null, argv);
        }

        var code: u8 = undefined;
        return self.execAllowFail(argv, &code, .Inherit) catch |err| switch (err) {
            error.FileNotFound => {
                if (src_step) |s| warn("{s}...", .{s.name});
                warn("Unable to spawn the following command: file not found\n", .{});
                printCmd(null, argv);
                std.os.exit(@truncate(u8, code));
            },
            error.ExitCodeFailure => {
                if (src_step) |s| warn("{s}...", .{s.name});
                if (self.prominent_compile_errors) {
                    warn("The step exited with error code {d}\n", .{code});
                } else {
                    warn("The following command exited with error code {d}:\n", .{code});
                    printCmd(null, argv);
                }

                std.os.exit(@truncate(u8, code));
            },
            error.ProcessTerminated => {
                if (src_step) |s| warn("{s}...", .{s.name});
                warn("The following command terminated unexpectedly:\n", .{});
                printCmd(null, argv);
                std.os.exit(@truncate(u8, code));
            },
            else => |e| return e,
        };
    }

    pub fn exec(self: *Builder, argv: []const []const u8) ![]u8 {
        return self.execFromStep(argv, null);
    }

    pub fn addSearchPrefix(self: *Builder, search_prefix: []const u8) void {
        self.search_prefixes.append(self.dupePath(search_prefix)) catch unreachable;
    }

    pub fn getInstallPath(self: *Builder, dir: InstallDir, dest_rel_path: []const u8) []const u8 {
        assert(!fs.path.isAbsolute(dest_rel_path)); // Install paths must be relative to the prefix
        const base_dir = switch (dir) {
            .prefix => self.install_path,
            .bin => self.exe_dir,
            .lib => self.lib_dir,
            .header => self.h_dir,
            .custom => |path| fs.path.join(self.allocator, &[_][]const u8{ self.install_path, path }) catch unreachable,
        };
        return fs.path.resolve(
            self.allocator,
            &[_][]const u8{ base_dir, dest_rel_path },
        ) catch unreachable;
    }

    fn execPkgConfigList(self: *Builder, out_code: *u8) ![]const PkgConfigPkg {
        const stdout = try self.execAllowFail(&[_][]const u8{ "pkg-config", "--list-all" }, out_code, .Ignore);
        var list = ArrayList(PkgConfigPkg).init(self.allocator);
        errdefer list.deinit();
        var line_it = mem.tokenize(stdout, "\r\n");
        while (line_it.next()) |line| {
            if (mem.trim(u8, line, " \t").len == 0) continue;
            var tok_it = mem.tokenize(line, " \t");
            try list.append(PkgConfigPkg{
                .name = tok_it.next() orelse return error.PkgConfigInvalidOutput,
                .desc = tok_it.rest(),
            });
        }
        return list.toOwnedSlice();
    }

    fn getPkgConfigList(self: *Builder) ![]const PkgConfigPkg {
        if (self.pkg_config_pkg_list) |res| {
            return res;
        }
        var code: u8 = undefined;
        if (self.execPkgConfigList(&code)) |list| {
            self.pkg_config_pkg_list = list;
            return list;
        } else |err| {
            const result = switch (err) {
                error.ProcessTerminated => error.PkgConfigCrashed,
                error.ExitCodeFailure => error.PkgConfigFailed,
                error.FileNotFound => error.PkgConfigNotInstalled,
                error.InvalidName => error.PkgConfigNotInstalled,
                error.PkgConfigInvalidOutput => error.PkgConfigInvalidOutput,
                else => return err,
            };
            self.pkg_config_pkg_list = result;
            return result;
        }
    }
};

test "builder.findProgram compiles" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const builder = try Builder.create(
        &arena.allocator,
        "zig",
        "zig-cache",
        "zig-cache",
        "zig-cache",
    );
    defer builder.destroy();
    _ = builder.findProgram(&[_][]const u8{}, &[_][]const u8{}) catch null;
}

/// Deprecated. Use `std.builtin.Version`.
pub const Version = builtin.Version;

/// Deprecated. Use `std.zig.CrossTarget`.
pub const Target = std.zig.CrossTarget;

pub const Pkg = struct {
    name: []const u8,
    path: FileSource,
    dependencies: ?[]const Pkg = null,
};

pub const CSourceFile = struct {
    source: FileSource,
    args: []const []const u8,

    fn dupe(self: CSourceFile, b: *Builder) CSourceFile {
        return .{
            .source = self.source.dupe(b),
            .args = b.dupeStrings(self.args),
        };
    }
};

const CSourceFiles = struct {
    files: []const []const u8,
    flags: []const []const u8,
};

fn isLibCLibrary(name: []const u8) bool {
    const libc_libraries = [_][]const u8{ "c", "m", "dl", "rt", "pthread" };
    for (libc_libraries) |libc_lib_name| {
        if (mem.eql(u8, name, libc_lib_name))
            return true;
    }
    return false;
}

fn isLibCppLibrary(name: []const u8) bool {
    const libcpp_libraries = [_][]const u8{ "c++", "stdc++" };
    for (libcpp_libraries) |libcpp_lib_name| {
        if (mem.eql(u8, name, libcpp_lib_name))
            return true;
    }
    return false;
}

/// A file that is generated by a build step.
/// This struct is an interface that is meant to be used with `@fieldParentPtr` to implement the actual path logic.
pub const GeneratedFile = struct {
    /// The step that generates the file
    step: *Step,

    /// The path to the generated file. Must be either absolute or relative to the build root.
    /// This value must be set in the `fn make()` of the `step` and must not be `null` afterwards.
    path: ?[]const u8 = null,

    pub fn getPath(self: GeneratedFile) []const u8 {
        return self.path orelse std.debug.panic(
            "getPath() was called on a GeneratedFile that wasn't build yet. Is there a missing Step dependency on step '{s}'?",
            .{self.step.name},
        );
    }
};

/// A file source is a reference to an existing or future file.
///
pub const FileSource = union(enum) {
    /// A plain file path, relative to build root or absolute.
    path: []const u8,

    /// A file that is generated by an interface. Those files usually are
    /// not available until built by a build step.
    generated: *const GeneratedFile,

    /// Returns a new file source that will have a relative path to the build root guaranteed.
    /// This should be preferred over setting `.path` directly as it documents that the files are in the project directory.
    pub fn relative(path: []const u8) FileSource {
        std.debug.assert(!std.fs.path.isAbsolute(path));
        return FileSource{ .path = path };
    }

    /// Returns a string that can be shown to represent the file source.
    /// Either returns the path or `"generated"`.
    pub fn getDisplayName(self: FileSource) []const u8 {
        return switch (self) {
            .path => self.path,
            .generated => "generated",
        };
    }

    /// Adds dependencies this file source implies to the given step.
    pub fn addStepDependencies(self: FileSource, step: *Step) void {
        switch (self) {
            .path => {},
            .generated => |gen| step.dependOn(gen.step),
        }
    }

    /// Should only be called during make(), returns a path relative to the build root or absolute.
    pub fn getPath(self: FileSource, builder: *Builder) []const u8 {
        const path = switch (self) {
            .path => |p| builder.pathFromRoot(p),
            .generated => |gen| gen.getPath(),
        };
        return path;
    }

    /// Duplicates the file source for a given builder.
    pub fn dupe(self: FileSource, b: *Builder) FileSource {
        return switch (self) {
            .path => |p| .{ .path = b.dupePath(p) },
            .generated => |gen| .{ .generated = gen },
        };
    }
};

const BuildOptionArtifactArg = struct {
    name: []const u8,
    artifact: *LibExeObjStep,
};

const BuildOptionFileSourceArg = struct {
    name: []const u8,
    source: FileSource,
};

pub const LibExeObjStep = struct {
    pub const base_id = .lib_exe_obj;

    step: Step,
    builder: *Builder,
    name: []const u8,
    target: CrossTarget = CrossTarget{},
    linker_script: ?FileSource = null,
    version_script: ?[]const u8 = null,
    out_filename: []const u8,
    linkage: ?Linkage = null,
    version: ?Version,
    build_mode: builtin.Mode,
    kind: Kind,
    major_only_filename: ?[]const u8,
    name_only_filename: ?[]const u8,
    strip: bool,
    lib_paths: ArrayList([]const u8),
    rpaths: ArrayList([]const u8),
    framework_dirs: ArrayList([]const u8),
    frameworks: BufSet,
    verbose_link: bool,
    verbose_cc: bool,
    emit_llvm_ir: bool = false,
    emit_asm: bool = false,
    emit_bin: bool = true,
    emit_docs: bool = false,
    emit_h: bool = false,
    bundle_compiler_rt: ?bool = null,
    disable_stack_probing: bool,
    disable_sanitize_c: bool,
    sanitize_thread: bool,
    rdynamic: bool,
    c_std: Builder.CStd,
    override_lib_dir: ?[]const u8,
    main_pkg_path: ?[]const u8,
    exec_cmd_args: ?[]const ?[]const u8,
    name_prefix: []const u8,
    filter: ?[]const u8,
    single_threaded: bool,
    test_evented_io: bool = false,
    code_model: builtin.CodeModel = .default,

    root_src: ?FileSource,
    out_h_filename: []const u8,
    out_lib_filename: []const u8,
    out_pdb_filename: []const u8,
    packages: ArrayList(Pkg),
    build_options_contents: std.ArrayList(u8),
    build_options_artifact_args: std.ArrayList(BuildOptionArtifactArg),
    build_options_file_source_args: std.ArrayList(BuildOptionFileSourceArg),

    object_src: []const u8,

    link_objects: ArrayList(LinkObject),
    include_dirs: ArrayList(IncludeDir),
    c_macros: ArrayList([]const u8),
    output_dir: ?[]const u8,
    is_linking_libc: bool = false,
    is_linking_libcpp: bool = false,
    vcpkg_bin_path: ?[]const u8 = null,

    /// This may be set in order to override the default install directory
    override_dest_dir: ?InstallDir,
    installed_path: ?[]const u8,
    install_step: ?*InstallArtifactStep,

    /// Base address for an executable image.
    image_base: ?u64 = null,

    libc_file: ?FileSource = null,

    valgrind_support: ?bool = null,

    /// Create a .eh_frame_hdr section and a PT_GNU_EH_FRAME segment in the ELF
    /// file.
    link_eh_frame_hdr: bool = false,
    link_emit_relocs: bool = false,

    /// Place every function in its own section so that unused ones may be
    /// safely garbage-collected during the linking phase.
    link_function_sections: bool = false,

    linker_allow_shlib_undefined: ?bool = null,

    /// Uses system Wine installation to run cross compiled Windows build artifacts.
    enable_wine: bool = false,

    /// Uses system QEMU installation to run cross compiled foreign architecture build artifacts.
    enable_qemu: bool = false,

    /// Uses system Wasmtime installation to run cross compiled wasm/wasi build artifacts.
    enable_wasmtime: bool = false,

    /// Experimental. Uses system Darling installation to run cross compiled macOS build artifacts.
    enable_darling: bool = false,

    /// After following the steps in https://github.com/ziglang/zig/wiki/Updating-libc#glibc,
    /// this will be the directory $glibc-build-dir/install/glibcs
    /// Given the example of the aarch64 target, this is the directory
    /// that contains the path `aarch64-linux-gnu/lib/ld-linux-aarch64.so.1`.
    glibc_multi_install_dir: ?[]const u8 = null,

    /// Position Independent Code
    force_pic: ?bool = null,

    /// Position Independent Executable
    pie: ?bool = null,

    red_zone: ?bool = null,

    subsystem: ?std.Target.SubSystem = null,

    /// Overrides the default stack size
    stack_size: ?u64 = null,

    want_lto: ?bool = null,

    output_path_source: GeneratedFile,
    output_lib_path_source: GeneratedFile,
    output_h_path_source: GeneratedFile,
    output_pdb_path_source: GeneratedFile,

    const LinkObject = union(enum) {
        static_path: FileSource,
        other_step: *LibExeObjStep,
        system_lib: []const u8,
        assembly_file: FileSource,
        c_source_file: *CSourceFile,
        c_source_files: *CSourceFiles,
    };

    const IncludeDir = union(enum) {
        raw_path: []const u8,
        raw_path_system: []const u8,
        other_step: *LibExeObjStep,
    };

    const Kind = enum {
        exe,
        lib,
        obj,
        @"test",
    };

    const SharedLibKind = union(enum) {
        versioned: Version,
        unversioned: void,
    };

    pub const Linkage = enum { dynamic, static };

    pub fn createSharedLibrary(builder: *Builder, name: []const u8, root_src: ?FileSource, kind: SharedLibKind) *LibExeObjStep {
        return initExtraArgs(builder, name, root_src, .lib, .dynamic, switch (kind) {
            .versioned => |ver| ver,
            .unversioned => null,
        });
    }

    pub fn createStaticLibrary(builder: *Builder, name: []const u8, root_src: ?FileSource) *LibExeObjStep {
        return initExtraArgs(builder, name, root_src, .lib, .static, null);
    }

    pub fn createObject(builder: *Builder, name: []const u8, root_src: ?FileSource) *LibExeObjStep {
        return initExtraArgs(builder, name, root_src, .obj, null, null);
    }

    pub fn createExecutable(builder: *Builder, name: []const u8, root_src: ?FileSource) *LibExeObjStep {
        return initExtraArgs(builder, name, root_src, .exe, null, null);
    }

    pub fn createTest(builder: *Builder, name: []const u8, root_src: FileSource) *LibExeObjStep {
        return initExtraArgs(builder, name, root_src, .@"test", null, null);
    }

    fn initExtraArgs(
        builder: *Builder,
        name_raw: []const u8,
        root_src_raw: ?FileSource,
        kind: Kind,
        linkage: ?Linkage,
        ver: ?Version,
    ) *LibExeObjStep {
        const name = builder.dupe(name_raw);
        const root_src: ?FileSource = if (root_src_raw) |rsrc| rsrc.dupe(builder) else null;
        if (mem.indexOf(u8, name, "/") != null or mem.indexOf(u8, name, "\\") != null) {
            panic("invalid name: '{s}'. It looks like a file path, but it is supposed to be the library or application name.", .{name});
        }

        const self = builder.allocator.create(LibExeObjStep) catch unreachable;
        self.* = LibExeObjStep{
            .strip = false,
            .builder = builder,
            .verbose_link = false,
            .verbose_cc = false,
            .build_mode = builtin.Mode.Debug,
            .linkage = linkage,
            .kind = kind,
            .root_src = root_src,
            .name = name,
            .frameworks = BufSet.init(builder.allocator),
            .step = Step.init(base_id, name, builder.allocator, make),
            .version = ver,
            .out_filename = undefined,
            .out_h_filename = builder.fmt("{s}.h", .{name}),
            .out_lib_filename = undefined,
            .out_pdb_filename = builder.fmt("{s}.pdb", .{name}),
            .major_only_filename = null,
            .name_only_filename = null,
            .packages = ArrayList(Pkg).init(builder.allocator),
            .include_dirs = ArrayList(IncludeDir).init(builder.allocator),
            .link_objects = ArrayList(LinkObject).init(builder.allocator),
            .c_macros = ArrayList([]const u8).init(builder.allocator),
            .lib_paths = ArrayList([]const u8).init(builder.allocator),
            .rpaths = ArrayList([]const u8).init(builder.allocator),
            .framework_dirs = ArrayList([]const u8).init(builder.allocator),
            .object_src = undefined,
            .build_options_contents = std.ArrayList(u8).init(builder.allocator),
            .build_options_artifact_args = std.ArrayList(BuildOptionArtifactArg).init(builder.allocator),
            .build_options_file_source_args = std.ArrayList(BuildOptionFileSourceArg).init(builder.allocator),
            .c_std = Builder.CStd.C99,
            .override_lib_dir = null,
            .main_pkg_path = null,
            .exec_cmd_args = null,
            .name_prefix = "",
            .filter = null,
            .disable_stack_probing = false,
            .disable_sanitize_c = false,
            .sanitize_thread = false,
            .rdynamic = false,
            .output_dir = null,
            .single_threaded = false,
            .override_dest_dir = null,
            .installed_path = null,
            .install_step = null,

            .output_path_source = GeneratedFile{ .step = &self.step },
            .output_lib_path_source = GeneratedFile{ .step = &self.step },
            .output_h_path_source = GeneratedFile{ .step = &self.step },
            .output_pdb_path_source = GeneratedFile{ .step = &self.step },
        };
        self.computeOutFileNames();
        if (root_src) |rs| rs.addStepDependencies(&self.step);
        return self;
    }

    fn computeOutFileNames(self: *LibExeObjStep) void {
        const target_info = std.zig.system.NativeTargetInfo.detect(
            self.builder.allocator,
            self.target,
        ) catch unreachable;
        const target = target_info.target;
        self.out_filename = std.zig.binNameAlloc(self.builder.allocator, .{
            .root_name = self.name,
            .target = target,
            .output_mode = switch (self.kind) {
                .lib => .Lib,
                .obj => .Obj,
                .exe, .@"test" => .Exe,
            },
            .link_mode = if (self.linkage) |some| @as(std.builtin.LinkMode, switch (some) {
                .dynamic => .Dynamic,
                .static => .Static,
            }) else null,
            .version = self.version,
        }) catch unreachable;

        if (self.kind == .lib) {
            if (self.linkage != null and self.linkage.? == .static) {
                self.out_lib_filename = self.out_filename;
            } else if (self.version) |version| {
                if (target.isDarwin()) {
                    self.major_only_filename = self.builder.fmt("lib{s}.{d}.dylib", .{
                        self.name,
                        version.major,
                    });
                    self.name_only_filename = self.builder.fmt("lib{s}.dylib", .{self.name});
                    self.out_lib_filename = self.out_filename;
                } else if (target.os.tag == .windows) {
                    self.out_lib_filename = self.builder.fmt("{s}.lib", .{self.name});
                } else {
                    self.major_only_filename = self.builder.fmt("lib{s}.so.{d}", .{ self.name, version.major });
                    self.name_only_filename = self.builder.fmt("lib{s}.so", .{self.name});
                    self.out_lib_filename = self.out_filename;
                }
            } else {
                if (target.isDarwin()) {
                    self.out_lib_filename = self.out_filename;
                } else if (target.os.tag == .windows) {
                    self.out_lib_filename = self.builder.fmt("{s}.lib", .{self.name});
                } else {
                    self.out_lib_filename = self.out_filename;
                }
            }
            if (self.output_dir != null) {
                self.output_lib_path_source.path =
                    fs.path.join(
                    self.builder.allocator,
                    &[_][]const u8{ self.output_dir.?, self.out_lib_filename },
                ) catch unreachable;
            }
        }
    }

    pub fn setTarget(self: *LibExeObjStep, target: CrossTarget) void {
        self.target = target;
        self.computeOutFileNames();
    }

    pub fn setOutputDir(self: *LibExeObjStep, dir: []const u8) void {
        self.output_dir = self.builder.dupePath(dir);
    }

    pub fn install(self: *LibExeObjStep) void {
        self.builder.installArtifact(self);
    }

    pub fn installRaw(self: *LibExeObjStep, dest_filename: []const u8) void {
        self.builder.installRaw(self, dest_filename);
    }

    /// Creates a `RunStep` with an executable built with `addExecutable`.
    /// Add command line arguments with `addArg`.
    pub fn run(exe: *LibExeObjStep) *RunStep {
        assert(exe.kind == .exe);

        // It doesn't have to be native. We catch that if you actually try to run it.
        // Consider that this is declarative; the run step may not be run unless a user
        // option is supplied.
        const run_step = RunStep.create(exe.builder, exe.builder.fmt("run {s}", .{exe.step.name}));
        run_step.addArtifactArg(exe);

        if (exe.vcpkg_bin_path) |path| {
            run_step.addPathDir(path);
        }

        return run_step;
    }

    pub fn setLinkerScriptPath(self: *LibExeObjStep, source: FileSource) void {
        self.linker_script = source.dupe(self.builder);
    }

    pub fn linkFramework(self: *LibExeObjStep, framework_name: []const u8) void {
        assert(self.target.isDarwin());
        // Note: No need to dupe because frameworks dupes internally.
        self.frameworks.insert(framework_name) catch unreachable;
    }

    /// Returns whether the library, executable, or object depends on a particular system library.
    pub fn dependsOnSystemLibrary(self: LibExeObjStep, name: []const u8) bool {
        if (isLibCLibrary(name)) {
            return self.is_linking_libc;
        }
        if (isLibCppLibrary(name)) {
            return self.is_linking_libcpp;
        }
        for (self.link_objects.items) |link_object| {
            switch (link_object) {
                .system_lib => |n| if (mem.eql(u8, n, name)) return true,
                else => continue,
            }
        }
        return false;
    }

    pub fn linkLibrary(self: *LibExeObjStep, lib: *LibExeObjStep) void {
        assert(lib.kind == .lib);
        self.linkLibraryOrObject(lib);
    }

    pub fn isDynamicLibrary(self: *LibExeObjStep) bool {
        return self.kind == .lib and self.linkage != null and self.linkage.? == .dynamic;
    }

    pub fn producesPdbFile(self: *LibExeObjStep) bool {
        if (!self.target.isWindows() and !self.target.isUefi()) return false;
        if (self.strip) return false;
        return self.isDynamicLibrary() or self.kind == .exe;
    }

    pub fn linkLibC(self: *LibExeObjStep) void {
        if (!self.is_linking_libc) {
            self.is_linking_libc = true;
            self.link_objects.append(.{ .system_lib = "c" }) catch unreachable;
        }
    }

    pub fn linkLibCpp(self: *LibExeObjStep) void {
        if (!self.is_linking_libcpp) {
            self.is_linking_libcpp = true;
            self.link_objects.append(.{ .system_lib = "c++" }) catch unreachable;
        }
    }

    /// If the value is omitted, it is set to 1.
    /// `name` and `value` need not live longer than the function call.
    pub fn defineCMacro(self: *LibExeObjStep, name: []const u8, value: ?[]const u8) void {
        var macro = self.builder.allocator.alloc(
            u8,
            name.len + if (value) |value_slice| value_slice.len + 1 else 0,
        ) catch |err| if (err == error.OutOfMemory) @panic("Out of memory") else unreachable;
        mem.copy(u8, macro, name);
        if (value) |value_slice| {
            macro[name.len] = '=';
            mem.copy(u8, macro[name.len + 1 ..], value_slice);
        }
        self.c_macros.append(macro) catch unreachable;
    }

    /// name_and_value looks like [name]=[value]. If the value is omitted, it is set to 1.
    pub fn defineCMacroRaw(self: *LibExeObjStep, name_and_value: []const u8) void {
        self.c_macros.append(self.builder.dupe(name_and_value)) catch unreachable;
    }

    /// This one has no integration with anything, it just puts -lname on the command line.
    /// Prefer to use `linkSystemLibrary` instead.
    pub fn linkSystemLibraryName(self: *LibExeObjStep, name: []const u8) void {
        self.link_objects.append(.{ .system_lib = self.builder.dupe(name) }) catch unreachable;
    }

    /// This links against a system library, exclusively using pkg-config to find the library.
    /// Prefer to use `linkSystemLibrary` instead.
    pub fn linkSystemLibraryPkgConfigOnly(self: *LibExeObjStep, lib_name: []const u8) !void {
        const pkg_name = match: {
            // First we have to map the library name to pkg config name. Unfortunately,
            // there are several examples where this is not straightforward:
            // -lSDL2 -> pkg-config sdl2
            // -lgdk-3 -> pkg-config gdk-3.0
            // -latk-1.0 -> pkg-config atk
            const pkgs = try self.builder.getPkgConfigList();

            // Exact match means instant winner.
            for (pkgs) |pkg| {
                if (mem.eql(u8, pkg.name, lib_name)) {
                    break :match pkg.name;
                }
            }

            // Next we'll try ignoring case.
            for (pkgs) |pkg| {
                if (std.ascii.eqlIgnoreCase(pkg.name, lib_name)) {
                    break :match pkg.name;
                }
            }

            // Now try appending ".0".
            for (pkgs) |pkg| {
                if (std.ascii.indexOfIgnoreCase(pkg.name, lib_name)) |pos| {
                    if (pos != 0) continue;
                    if (mem.eql(u8, pkg.name[lib_name.len..], ".0")) {
                        break :match pkg.name;
                    }
                }
            }

            // Trimming "-1.0".
            if (mem.endsWith(u8, lib_name, "-1.0")) {
                const trimmed_lib_name = lib_name[0 .. lib_name.len - "-1.0".len];
                for (pkgs) |pkg| {
                    if (std.ascii.eqlIgnoreCase(pkg.name, trimmed_lib_name)) {
                        break :match pkg.name;
                    }
                }
            }

            return error.PackageNotFound;
        };

        var code: u8 = undefined;
        const stdout = if (self.builder.execAllowFail(&[_][]const u8{
            "pkg-config",
            pkg_name,
            "--cflags",
            "--libs",
        }, &code, .Ignore)) |stdout| stdout else |err| switch (err) {
            error.ProcessTerminated => return error.PkgConfigCrashed,
            error.ExitCodeFailure => return error.PkgConfigFailed,
            error.FileNotFound => return error.PkgConfigNotInstalled,
            else => return err,
        };
        var it = mem.tokenize(stdout, " \r\n\t");
        while (it.next()) |tok| {
            if (mem.eql(u8, tok, "-I")) {
                const dir = it.next() orelse return error.PkgConfigInvalidOutput;
                self.addIncludeDir(dir);
            } else if (mem.startsWith(u8, tok, "-I")) {
                self.addIncludeDir(tok["-I".len..]);
            } else if (mem.eql(u8, tok, "-L")) {
                const dir = it.next() orelse return error.PkgConfigInvalidOutput;
                self.addLibPath(dir);
            } else if (mem.startsWith(u8, tok, "-L")) {
                self.addLibPath(tok["-L".len..]);
            } else if (mem.eql(u8, tok, "-l")) {
                const lib = it.next() orelse return error.PkgConfigInvalidOutput;
                self.linkSystemLibraryName(lib);
            } else if (mem.startsWith(u8, tok, "-l")) {
                self.linkSystemLibraryName(tok["-l".len..]);
            } else if (mem.eql(u8, tok, "-D")) {
                const macro = it.next() orelse return error.PkgConfigInvalidOutput;
                self.defineCMacroRaw(macro);
            } else if (mem.startsWith(u8, tok, "-D")) {
                self.defineCMacroRaw(tok["-D".len..]);
            } else if (mem.eql(u8, tok, "-pthread")) {
                self.linkLibC();
            } else if (self.builder.verbose) {
                warn("Ignoring pkg-config flag '{s}'\n", .{tok});
            }
        }
    }

    pub fn linkSystemLibrary(self: *LibExeObjStep, name: []const u8) void {
        if (isLibCLibrary(name)) {
            self.linkLibC();
            return;
        }
        if (isLibCppLibrary(name)) {
            self.linkLibCpp();
            return;
        }
        if (self.linkSystemLibraryPkgConfigOnly(name)) |_| {
            // pkg-config worked, so nothing further needed to do.
            return;
        } else |err| switch (err) {
            error.PkgConfigInvalidOutput,
            error.PkgConfigCrashed,
            error.PkgConfigFailed,
            error.PkgConfigNotInstalled,
            error.PackageNotFound,
            => {},

            else => unreachable,
        }

        self.linkSystemLibraryName(name);
    }

    pub fn setNamePrefix(self: *LibExeObjStep, text: []const u8) void {
        assert(self.kind == .@"test");
        self.name_prefix = self.builder.dupe(text);
    }

    pub fn setFilter(self: *LibExeObjStep, text: ?[]const u8) void {
        assert(self.kind == .@"test");
        self.filter = if (text) |t| self.builder.dupe(t) else null;
    }

    /// Handy when you have many C/C++ source files and want them all to have the same flags.
    pub fn addCSourceFiles(self: *LibExeObjStep, files: []const []const u8, flags: []const []const u8) void {
        const c_source_files = self.builder.allocator.create(CSourceFiles) catch unreachable;

        const files_copy = self.builder.dupeStrings(files);
        const flags_copy = self.builder.dupeStrings(flags);

        c_source_files.* = .{
            .files = files_copy,
            .flags = flags_copy,
        };
        self.link_objects.append(.{ .c_source_files = c_source_files }) catch unreachable;
    }

    pub fn addCSourceFile(self: *LibExeObjStep, file: []const u8, flags: []const []const u8) void {
        self.addCSourceFileSource(.{
            .args = flags,
            .source = .{ .path = file },
        });
    }

    pub fn addCSourceFileSource(self: *LibExeObjStep, source: CSourceFile) void {
        const c_source_file = self.builder.allocator.create(CSourceFile) catch unreachable;
        c_source_file.* = source.dupe(self.builder);
        self.link_objects.append(.{ .c_source_file = c_source_file }) catch unreachable;
        source.source.addStepDependencies(&self.step);
    }

    pub fn setVerboseLink(self: *LibExeObjStep, value: bool) void {
        self.verbose_link = value;
    }

    pub fn setVerboseCC(self: *LibExeObjStep, value: bool) void {
        self.verbose_cc = value;
    }

    pub fn setBuildMode(self: *LibExeObjStep, mode: builtin.Mode) void {
        self.build_mode = mode;
    }

    pub fn overrideZigLibDir(self: *LibExeObjStep, dir_path: []const u8) void {
        self.override_lib_dir = self.builder.dupePath(dir_path);
    }

    pub fn setMainPkgPath(self: *LibExeObjStep, dir_path: []const u8) void {
        self.main_pkg_path = self.builder.dupePath(dir_path);
    }

    pub fn setLibCFile(self: *LibExeObjStep, libc_file: ?FileSource) void {
        self.libc_file = if (libc_file) |f| f.dupe(self.builder) else null;
    }

    /// Returns the generated executable, library or object file.
    /// To run an executable built with zig build, use `run`, or create an install step and invoke it.
    pub fn getOutputSource(self: *LibExeObjStep) FileSource {
        return FileSource{ .generated = &self.output_path_source };
    }

    /// Returns the generated import library. This function can only be called for libraries.
    pub fn getOutputLibSource(self: *LibExeObjStep) FileSource {
        assert(self.kind == .lib);
        return FileSource{ .generated = &self.output_lib_path_source };
    }

    /// Returns the generated header file.
    /// This function can only be called for libraries or object files which have `emit_h` set.
    pub fn getOutputHSource(self: *LibExeObjStep) FileSource {
        assert(self.kind != .exe);
        assert(self.emit_h);
        return FileSource{ .generated = &self.output_h_path_source };
    }

    /// Returns the generated PDB file. This function can only be called for Windows and UEFI.
    pub fn getOutputPdbSource(self: *LibExeObjStep) FileSource {
        // TODO: Is this right? Isn't PDB for *any* PE/COFF file?
        assert(self.target.isWindows() or self.target.isUefi());
        return FileSource{ .generated = &self.output_pdb_path_source };
    }

    pub fn addAssemblyFile(self: *LibExeObjStep, path: []const u8) void {
        self.link_objects.append(.{
            .assembly_file = .{ .path = self.builder.dupe(path) },
        }) catch unreachable;
    }

    pub fn addAssemblyFileSource(self: *LibExeObjStep, source: FileSource) void {
        const source_duped = source.dupe(self.builder);
        self.link_objects.append(.{ .assembly_file = source_duped }) catch unreachable;
        source_duped.addStepDependencies(&self.step);
    }

    pub fn addObjectFile(self: *LibExeObjStep, source_file: []const u8) void {
        self.addObjectFileSource(.{ .path = source_file });
    }

    pub fn addObjectFileSource(self: *LibExeObjStep, source: FileSource) void {
        self.link_objects.append(.{ .static_path = source.dupe(self.builder) }) catch unreachable;
        source.addStepDependencies(&self.step);
    }

    pub fn addObject(self: *LibExeObjStep, obj: *LibExeObjStep) void {
        assert(obj.kind == .obj);
        self.linkLibraryOrObject(obj);
    }

    pub fn addBuildOption(self: *LibExeObjStep, comptime T: type, name: []const u8, value: T) void {
        const out = self.build_options_contents.writer();
        switch (T) {
            []const []const u8 => {
                out.print("pub const {}: []const []const u8 = &[_][]const u8{{\n", .{std.zig.fmtId(name)}) catch unreachable;
                for (value) |slice| {
                    out.print("    \"{}\",\n", .{std.zig.fmtEscapes(slice)}) catch unreachable;
                }
                out.writeAll("};\n") catch unreachable;
                return;
            },
            [:0]const u8 => {
                out.print("pub const {}: [:0]const u8 = \"{}\";\n", .{ std.zig.fmtId(name), std.zig.fmtEscapes(value) }) catch unreachable;
                return;
            },
            []const u8 => {
                out.print("pub const {}: []const u8 = \"{}\";\n", .{ std.zig.fmtId(name), std.zig.fmtEscapes(value) }) catch unreachable;
                return;
            },
            ?[:0]const u8 => {
                out.print("pub const {}: ?[:0]const u8 = ", .{std.zig.fmtId(name)}) catch unreachable;
                if (value) |payload| {
                    out.print("\"{}\";\n", .{std.zig.fmtEscapes(payload)}) catch unreachable;
                } else {
                    out.writeAll("null;\n") catch unreachable;
                }
                return;
            },
            ?[]const u8 => {
                out.print("pub const {}: ?[]const u8 = ", .{std.zig.fmtId(name)}) catch unreachable;
                if (value) |payload| {
                    out.print("\"{}\";\n", .{std.zig.fmtEscapes(payload)}) catch unreachable;
                } else {
                    out.writeAll("null;\n") catch unreachable;
                }
                return;
            },
            std.builtin.Version => {
                out.print(
                    \\pub const {}: @import("std").builtin.Version = .{{
                    \\    .major = {d},
                    \\    .minor = {d},
                    \\    .patch = {d},
                    \\}};
                    \\
                , .{
                    std.zig.fmtId(name),

                    value.major,
                    value.minor,
                    value.patch,
                }) catch unreachable;
            },
            std.SemanticVersion => {
                out.print(
                    \\pub const {}: @import("std").SemanticVersion = .{{
                    \\    .major = {d},
                    \\    .minor = {d},
                    \\    .patch = {d},
                    \\
                , .{
                    std.zig.fmtId(name),

                    value.major,
                    value.minor,
                    value.patch,
                }) catch unreachable;
                if (value.pre) |some| {
                    out.print("    .pre = \"{}\",\n", .{std.zig.fmtEscapes(some)}) catch unreachable;
                }
                if (value.build) |some| {
                    out.print("    .build = \"{}\",\n", .{std.zig.fmtEscapes(some)}) catch unreachable;
                }
                out.writeAll("};\n") catch unreachable;
                return;
            },
            else => {},
        }
        switch (@typeInfo(T)) {
            .Enum => |enum_info| {
                out.print("pub const {} = enum {{\n", .{std.zig.fmtId(@typeName(T))}) catch unreachable;
                inline for (enum_info.fields) |field| {
                    out.print("    {},\n", .{std.zig.fmtId(field.name)}) catch unreachable;
                }
                out.writeAll("};\n") catch unreachable;
            },
            else => {},
        }
        out.print("pub const {}: {s} = {};\n", .{ std.zig.fmtId(name), @typeName(T), value }) catch unreachable;
    }

    /// The value is the path in the cache dir.
    /// Adds a dependency automatically.
    pub fn addBuildOptionArtifact(self: *LibExeObjStep, name: []const u8, artifact: *LibExeObjStep) void {
        self.build_options_artifact_args.append(.{ .name = self.builder.dupe(name), .artifact = artifact }) catch unreachable;
        self.step.dependOn(&artifact.step);
    }

    /// The value is the path in the cache dir.
    /// Adds a dependency automatically.
    /// basename refers to the basename of the WriteFileStep
    pub fn addBuildOptionFileSource(
        self: *LibExeObjStep,
        name: []const u8,
        source: FileSource,
    ) void {
        self.build_options_file_source_args.append(.{
            .name = name,
            .source = source.dupe(self.builder),
        }) catch unreachable;
        source.addStepDependencies(&self.step);
    }

    pub fn addSystemIncludeDir(self: *LibExeObjStep, path: []const u8) void {
        self.include_dirs.append(IncludeDir{ .raw_path_system = self.builder.dupe(path) }) catch unreachable;
    }

    pub fn addIncludeDir(self: *LibExeObjStep, path: []const u8) void {
        self.include_dirs.append(IncludeDir{ .raw_path = self.builder.dupe(path) }) catch unreachable;
    }

    pub fn addLibPath(self: *LibExeObjStep, path: []const u8) void {
        self.lib_paths.append(self.builder.dupe(path)) catch unreachable;
    }

    pub fn addRPath(self: *LibExeObjStep, path: []const u8) void {
        self.rpaths.append(self.builder.dupe(path)) catch unreachable;
    }

    pub fn addFrameworkDir(self: *LibExeObjStep, dir_path: []const u8) void {
        self.framework_dirs.append(self.builder.dupe(dir_path)) catch unreachable;
    }

    pub fn addPackage(self: *LibExeObjStep, package: Pkg) void {
        self.packages.append(self.builder.dupePkg(package)) catch unreachable;
        self.addRecursiveBuildDeps(package);
    }

    fn addRecursiveBuildDeps(self: *LibExeObjStep, package: Pkg) void {
        package.path.addStepDependencies(&self.step);
        if (package.dependencies) |deps| {
            for (deps) |dep| {
                self.addRecursiveBuildDeps(dep);
            }
        }
    }

    pub fn addPackagePath(self: *LibExeObjStep, name: []const u8, pkg_index_path: []const u8) void {
        self.addPackage(Pkg{
            .name = self.builder.dupe(name),
            .path = .{ .path = self.builder.dupe(pkg_index_path) },
        });
    }

    /// If Vcpkg was found on the system, it will be added to include and lib
    /// paths for the specified target.
    pub fn addVcpkgPaths(self: *LibExeObjStep, linkage: LibExeObjStep.Linkage) !void {
        // Ideally in the Unattempted case we would call the function recursively
        // after findVcpkgRoot and have only one switch statement, but the compiler
        // cannot resolve the error set.
        switch (self.builder.vcpkg_root) {
            .unattempted => {
                self.builder.vcpkg_root = if (try findVcpkgRoot(self.builder.allocator)) |root|
                    VcpkgRoot{ .found = root }
                else
                    .not_found;
            },
            .not_found => return error.VcpkgNotFound,
            .found => {},
        }

        switch (self.builder.vcpkg_root) {
            .unattempted => unreachable,
            .not_found => return error.VcpkgNotFound,
            .found => |root| {
                const allocator = self.builder.allocator;
                const triplet = try self.target.vcpkgTriplet(allocator, if (linkage == .static) .Static else .Dynamic);
                defer self.builder.allocator.free(triplet);

                const include_path = try fs.path.join(allocator, &[_][]const u8{ root, "installed", triplet, "include" });
                errdefer allocator.free(include_path);
                try self.include_dirs.append(IncludeDir{ .raw_path = include_path });

                const lib_path = try fs.path.join(allocator, &[_][]const u8{ root, "installed", triplet, "lib" });
                try self.lib_paths.append(lib_path);

                self.vcpkg_bin_path = try fs.path.join(allocator, &[_][]const u8{ root, "installed", triplet, "bin" });
            },
        }
    }

    pub fn setExecCmd(self: *LibExeObjStep, args: []const ?[]const u8) void {
        assert(self.kind == .@"test");
        const duped_args = self.builder.allocator.alloc(?[]u8, args.len) catch unreachable;
        for (args) |arg, i| {
            duped_args[i] = if (arg) |a| self.builder.dupe(a) else null;
        }
        self.exec_cmd_args = duped_args;
    }

    fn linkLibraryOrObject(self: *LibExeObjStep, other: *LibExeObjStep) void {
        self.step.dependOn(&other.step);
        self.link_objects.append(.{ .other_step = other }) catch unreachable;
        self.include_dirs.append(.{ .other_step = other }) catch unreachable;

        // BUG: The following code introduces a order-of-call dependency:
        // var lib = addSharedLibrary(...);
        // var exe = addExecutable(...);
        // exe.linkLibrary(lib);
        // lib.linkSystemLibrary("foobar"); //  this will be ignored for exe!

        // Inherit dependency on system libraries
        for (other.link_objects.items) |link_object| {
            switch (link_object) {
                .system_lib => |name| self.linkSystemLibrary(name),
                else => continue,
            }
        }

        // Inherit dependencies on darwin frameworks
        if (self.target.isDarwin() and !other.isDynamicLibrary()) {
            var it = other.frameworks.iterator();
            while (it.next()) |framework| {
                self.frameworks.insert(framework.*) catch unreachable;
            }
        }
    }

    fn makePackageCmd(self: *LibExeObjStep, pkg: Pkg, zig_args: *ArrayList([]const u8)) error{OutOfMemory}!void {
        const builder = self.builder;

        try zig_args.append("--pkg-begin");
        try zig_args.append(pkg.name);
        try zig_args.append(builder.pathFromRoot(pkg.path.getPath(self.builder)));

        if (pkg.dependencies) |dependencies| {
            for (dependencies) |sub_pkg| {
                try self.makePackageCmd(sub_pkg, zig_args);
            }
        }

        try zig_args.append("--pkg-end");
    }

    fn make(step: *Step) !void {
        const self = @fieldParentPtr(LibExeObjStep, "step", step);
        const builder = self.builder;

        if (self.root_src == null and self.link_objects.items.len == 0) {
            warn("{s}: linker needs 1 or more objects to link\n", .{self.step.name});
            return error.NeedAnObject;
        }

        var zig_args = ArrayList([]const u8).init(builder.allocator);
        defer zig_args.deinit();

        zig_args.append(builder.zig_exe) catch unreachable;

        const cmd = switch (self.kind) {
            .lib => "build-lib",
            .exe => "build-exe",
            .obj => "build-obj",
            .@"test" => "test",
        };
        zig_args.append(cmd) catch unreachable;

        if (builder.color != .auto) {
            try zig_args.append("--color");
            try zig_args.append(@tagName(builder.color));
        }

        if (self.stack_size) |stack_size| {
            try zig_args.append("--stack");
            try zig_args.append(try std.fmt.allocPrint(builder.allocator, "{}", .{stack_size}));
        }

        if (self.root_src) |root_src| try zig_args.append(root_src.getPath(builder));

        var prev_has_extra_flags = false;
        for (self.link_objects.items) |link_object| {
            switch (link_object) {
                .static_path => |static_path| try zig_args.append(static_path.getPath(builder)),

                .other_step => |other| switch (other.kind) {
                    .exe => unreachable,
                    .@"test" => unreachable,
                    .obj => {
                        try zig_args.append(other.getOutputSource().getPath(builder));
                    },
                    .lib => {
                        const full_path_lib = other.getOutputLibSource().getPath(builder);
                        try zig_args.append(full_path_lib);

                        if (other.linkage != null and other.linkage.? == .dynamic and !self.target.isWindows()) {
                            if (fs.path.dirname(full_path_lib)) |dirname| {
                                try zig_args.append("-rpath");
                                try zig_args.append(dirname);
                            }
                        }
                    },
                },
                .system_lib => |name| {
                    try zig_args.append(builder.fmt("-l{s}", .{name}));
                },

                .assembly_file => |asm_file| {
                    if (prev_has_extra_flags) {
                        try zig_args.append("-extra-cflags");
                        try zig_args.append("--");
                        prev_has_extra_flags = false;
                    }
                    try zig_args.append(asm_file.getPath(builder));
                },

                .c_source_file => |c_source_file| {
                    if (c_source_file.args.len == 0) {
                        if (prev_has_extra_flags) {
                            try zig_args.append("-cflags");
                            try zig_args.append("--");
                            prev_has_extra_flags = false;
                        }
                    } else {
                        try zig_args.append("-cflags");
                        for (c_source_file.args) |arg| {
                            try zig_args.append(arg);
                        }
                        try zig_args.append("--");
                    }
                    try zig_args.append(c_source_file.source.getPath(builder));
                },

                .c_source_files => |c_source_files| {
                    if (c_source_files.flags.len == 0) {
                        if (prev_has_extra_flags) {
                            try zig_args.append("-cflags");
                            try zig_args.append("--");
                            prev_has_extra_flags = false;
                        }
                    } else {
                        try zig_args.append("-cflags");
                        for (c_source_files.flags) |flag| {
                            try zig_args.append(flag);
                        }
                        try zig_args.append("--");
                    }
                    for (c_source_files.files) |file| {
                        try zig_args.append(builder.pathFromRoot(file));
                    }
                },
            }
        }

        if (self.build_options_contents.items.len > 0 or
            self.build_options_artifact_args.items.len > 0 or
            self.build_options_file_source_args.items.len > 0)
        {
            // Render build artifact and write file options at the last minute, now that the path is known.
            //
            // Note that pathFromRoot uses resolve path, so this will have
            // correct behavior even if getOutputPath is already absolute.
            for (self.build_options_artifact_args.items) |item| {
                self.addBuildOption(
                    []const u8,
                    item.name,
                    self.builder.pathFromRoot(item.artifact.getOutputSource().getPath(self.builder)),
                );
            }
            for (self.build_options_file_source_args.items) |item| {
                self.addBuildOption(
                    []const u8,
                    item.name,
                    item.source.getPath(self.builder),
                );
            }

            const build_options_file = try fs.path.join(
                builder.allocator,
                &[_][]const u8{ builder.cache_root, builder.fmt("{s}_build_options.zig", .{self.name}) },
            );
            const path_from_root = builder.pathFromRoot(build_options_file);
            try fs.cwd().writeFile(path_from_root, self.build_options_contents.items);
            try zig_args.append("--pkg-begin");
            try zig_args.append("build_options");
            try zig_args.append(path_from_root);
            try zig_args.append("--pkg-end");
        }

        if (self.image_base) |image_base| {
            try zig_args.append("--image-base");
            try zig_args.append(builder.fmt("0x{x}", .{image_base}));
        }

        if (self.filter) |filter| {
            try zig_args.append("--test-filter");
            try zig_args.append(filter);
        }

        if (self.test_evented_io) {
            try zig_args.append("--test-evented-io");
        }

        if (self.name_prefix.len != 0) {
            try zig_args.append("--test-name-prefix");
            try zig_args.append(self.name_prefix);
        }

        if (builder.verbose_tokenize) zig_args.append("--verbose-tokenize") catch unreachable;
        if (builder.verbose_ast) zig_args.append("--verbose-ast") catch unreachable;
        if (builder.verbose_cimport) zig_args.append("--verbose-cimport") catch unreachable;
        if (builder.verbose_ir) zig_args.append("--verbose-ir") catch unreachable;
        if (builder.verbose_llvm_ir) zig_args.append("--verbose-llvm-ir") catch unreachable;
        if (builder.verbose_link or self.verbose_link) zig_args.append("--verbose-link") catch unreachable;
        if (builder.verbose_cc or self.verbose_cc) zig_args.append("--verbose-cc") catch unreachable;
        if (builder.verbose_llvm_cpu_features) zig_args.append("--verbose-llvm-cpu-features") catch unreachable;

        if (self.emit_llvm_ir) try zig_args.append("-femit-llvm-ir");
        if (self.emit_asm) try zig_args.append("-femit-asm");
        if (!self.emit_bin) try zig_args.append("-fno-emit-bin");
        if (self.emit_docs) try zig_args.append("-femit-docs");
        if (self.emit_h) try zig_args.append("-femit-h");

        if (self.strip) {
            try zig_args.append("--strip");
        }
        if (self.link_eh_frame_hdr) {
            try zig_args.append("--eh-frame-hdr");
        }
        if (self.link_emit_relocs) {
            try zig_args.append("--emit-relocs");
        }
        if (self.link_function_sections) {
            try zig_args.append("-ffunction-sections");
        }
        if (self.linker_allow_shlib_undefined) |x| {
            try zig_args.append(if (x) "-fallow-shlib-undefined" else "-fno-allow-shlib-undefined");
        }
        if (self.single_threaded) {
            try zig_args.append("--single-threaded");
        }

        if (self.libc_file) |libc_file| {
            try zig_args.append("--libc");
            try zig_args.append(libc_file.getPath(self.builder));
        } else if (builder.libc_file) |libc_file| {
            try zig_args.append("--libc");
            try zig_args.append(libc_file);
        }

        switch (self.build_mode) {
            .Debug => {}, // Skip since it's the default.
            else => zig_args.append(builder.fmt("-O{s}", .{@tagName(self.build_mode)})) catch unreachable,
        }

        try zig_args.append("--cache-dir");
        try zig_args.append(builder.pathFromRoot(builder.cache_root));

        try zig_args.append("--global-cache-dir");
        try zig_args.append(builder.pathFromRoot(builder.global_cache_root));

        zig_args.append("--name") catch unreachable;
        zig_args.append(self.name) catch unreachable;

        if (self.linkage) |some| switch (some) {
            .dynamic => try zig_args.append("-dynamic"),
            .static => try zig_args.append("-static"),
        };
        if (self.kind == .lib and self.linkage != null and self.linkage.? == .dynamic) {
            if (self.version) |version| {
                zig_args.append("--version") catch unreachable;
                zig_args.append(builder.fmt("{}", .{version})) catch unreachable;
            }
        }

        if (self.bundle_compiler_rt) |x| {
            if (x) {
                try zig_args.append("-fcompiler-rt");
            } else {
                try zig_args.append("-fno-compiler-rt");
            }
        }
        if (self.disable_stack_probing) {
            try zig_args.append("-fno-stack-check");
        }
        if (self.red_zone) |red_zone| {
            if (red_zone) {
                try zig_args.append("-mred-zone");
            } else {
                try zig_args.append("-mno-red-zone");
            }
        }
        if (self.disable_sanitize_c) {
            try zig_args.append("-fno-sanitize-c");
        }
        if (self.sanitize_thread) {
            try zig_args.append("-fsanitize-thread");
        }
        if (self.rdynamic) {
            try zig_args.append("-rdynamic");
        }

        if (self.code_model != .default) {
            try zig_args.append("-mcmodel");
            try zig_args.append(@tagName(self.code_model));
        }

        if (!self.target.isNative()) {
            try zig_args.append("-target");
            try zig_args.append(try self.target.zigTriple(builder.allocator));

            // TODO this logic can disappear if cpu model + features becomes part of the target triple
            const cross = self.target.toTarget();
            const all_features = cross.cpu.arch.allFeaturesList();
            var populated_cpu_features = cross.cpu.model.features;
            populated_cpu_features.populateDependencies(all_features);

            if (populated_cpu_features.eql(cross.cpu.features)) {
                // The CPU name alone is sufficient.
                // If it is the baseline CPU, no command line args are required.
                if (cross.cpu.model != std.Target.Cpu.baseline(cross.cpu.arch).model) {
                    try zig_args.append("-mcpu");
                    try zig_args.append(cross.cpu.model.name);
                }
            } else {
                var mcpu_buffer = std.ArrayList(u8).init(builder.allocator);

                try mcpu_buffer.writer().print("-mcpu={s}", .{cross.cpu.model.name});

                for (all_features) |feature, i_usize| {
                    const i = @intCast(std.Target.Cpu.Feature.Set.Index, i_usize);
                    const in_cpu_set = populated_cpu_features.isEnabled(i);
                    const in_actual_set = cross.cpu.features.isEnabled(i);
                    if (in_cpu_set and !in_actual_set) {
                        try mcpu_buffer.writer().print("-{s}", .{feature.name});
                    } else if (!in_cpu_set and in_actual_set) {
                        try mcpu_buffer.writer().print("+{s}", .{feature.name});
                    }
                }

                try zig_args.append(mcpu_buffer.toOwnedSlice());
            }

            if (self.target.dynamic_linker.get()) |dynamic_linker| {
                try zig_args.append("--dynamic-linker");
                try zig_args.append(dynamic_linker);
            }
        }

        if (self.linker_script) |linker_script| {
            try zig_args.append("--script");
            try zig_args.append(linker_script.getPath(builder));
        }

        if (self.version_script) |version_script| {
            try zig_args.append("--version-script");
            try zig_args.append(builder.pathFromRoot(version_script));
        }

        if (self.exec_cmd_args) |exec_cmd_args| {
            for (exec_cmd_args) |cmd_arg| {
                if (cmd_arg) |arg| {
                    try zig_args.append("--test-cmd");
                    try zig_args.append(arg);
                } else {
                    try zig_args.append("--test-cmd-bin");
                }
            }
        } else switch (self.target.getExternalExecutor()) {
            .native, .unavailable => {},
            .qemu => |bin_name| if (self.enable_qemu) qemu: {
                const need_cross_glibc = self.target.isGnuLibC() and self.is_linking_libc;
                const glibc_dir_arg = if (need_cross_glibc)
                    self.glibc_multi_install_dir orelse break :qemu
                else
                    null;
                try zig_args.append("--test-cmd");
                try zig_args.append(bin_name);
                if (glibc_dir_arg) |dir| {
                    // TODO look into making this a call to `linuxTriple`. This
                    // needs the directory to be called "i686" rather than
                    // "i386" which is why we do it manually here.
                    const fmt_str = "{s}" ++ fs.path.sep_str ++ "{s}-{s}-{s}";
                    const cpu_arch = self.target.getCpuArch();
                    const os_tag = self.target.getOsTag();
                    const abi = self.target.getAbi();
                    const cpu_arch_name: []const u8 = if (cpu_arch == .i386)
                        "i686"
                    else
                        @tagName(cpu_arch);
                    const full_dir = try std.fmt.allocPrint(builder.allocator, fmt_str, .{
                        dir, cpu_arch_name, @tagName(os_tag), @tagName(abi),
                    });

                    try zig_args.append("--test-cmd");
                    try zig_args.append("-L");
                    try zig_args.append("--test-cmd");
                    try zig_args.append(full_dir);
                }
                try zig_args.append("--test-cmd-bin");
            },
            .wine => |bin_name| if (self.enable_wine) {
                try zig_args.append("--test-cmd");
                try zig_args.append(bin_name);
                try zig_args.append("--test-cmd-bin");
            },
            .wasmtime => |bin_name| if (self.enable_wasmtime) {
                try zig_args.append("--test-cmd");
                try zig_args.append(bin_name);
                try zig_args.append("--test-cmd");
                try zig_args.append("--dir=.");
                try zig_args.append("--test-cmd-bin");
            },
            .darling => |bin_name| if (self.enable_darling) {
                try zig_args.append("--test-cmd");
                try zig_args.append(bin_name);
                try zig_args.append("--test-cmd-bin");
            },
        }

        for (self.packages.items) |pkg| {
            try self.makePackageCmd(pkg, &zig_args);
        }

        for (self.include_dirs.items) |include_dir| {
            switch (include_dir) {
                .raw_path => |include_path| {
                    try zig_args.append("-I");
                    try zig_args.append(self.builder.pathFromRoot(include_path));
                },
                .raw_path_system => |include_path| {
                    try zig_args.append("-isystem");
                    try zig_args.append(self.builder.pathFromRoot(include_path));
                },
                .other_step => |other| if (other.emit_h) {
                    const h_path = other.getOutputHSource().getPath(self.builder);
                    try zig_args.append("-isystem");
                    try zig_args.append(fs.path.dirname(h_path).?);
                },
            }
        }

        for (self.lib_paths.items) |lib_path| {
            try zig_args.append("-L");
            try zig_args.append(lib_path);
        }

        for (self.rpaths.items) |rpath| {
            try zig_args.append("-rpath");
            try zig_args.append(rpath);
        }

        for (self.c_macros.items) |c_macro| {
            try zig_args.append("-D");
            try zig_args.append(c_macro);
        }

        if (self.target.isDarwin()) {
            for (self.framework_dirs.items) |dir| {
                try zig_args.append("-F");
                try zig_args.append(dir);
            }

            var it = self.frameworks.iterator();
            while (it.next()) |framework| {
                zig_args.append("-framework") catch unreachable;
                zig_args.append(framework.*) catch unreachable;
            }
        }

        if (builder.sysroot) |sysroot| {
            try zig_args.appendSlice(&[_][]const u8{ "--sysroot", sysroot });
        }

        for (builder.search_prefixes.items) |search_prefix| {
            try zig_args.append("-L");
            try zig_args.append(try fs.path.join(builder.allocator, &[_][]const u8{
                search_prefix, "lib",
            }));
            try zig_args.append("-isystem");
            try zig_args.append(try fs.path.join(builder.allocator, &[_][]const u8{
                search_prefix, "include",
            }));
        }

        if (self.valgrind_support) |valgrind_support| {
            if (valgrind_support) {
                try zig_args.append("-fvalgrind");
            } else {
                try zig_args.append("-fno-valgrind");
            }
        }

        if (self.override_lib_dir) |dir| {
            try zig_args.append("--zig-lib-dir");
            try zig_args.append(builder.pathFromRoot(dir));
        } else if (self.builder.override_lib_dir) |dir| {
            try zig_args.append("--zig-lib-dir");
            try zig_args.append(builder.pathFromRoot(dir));
        }

        if (self.main_pkg_path) |dir| {
            try zig_args.append("--main-pkg-path");
            try zig_args.append(builder.pathFromRoot(dir));
        }

        if (self.force_pic) |pic| {
            if (pic) {
                try zig_args.append("-fPIC");
            } else {
                try zig_args.append("-fno-PIC");
            }
        }

        if (self.pie) |pie| {
            if (pie) {
                try zig_args.append("-fPIE");
            } else {
                try zig_args.append("-fno-PIE");
            }
        }

        if (self.want_lto) |lto| {
            if (lto) {
                try zig_args.append("-flto");
            } else {
                try zig_args.append("-fno-lto");
            }
        }

        if (self.subsystem) |subsystem| {
            try zig_args.append("--subsystem");
            try zig_args.append(switch (subsystem) {
                .Console => "console",
                .Windows => "windows",
                .Posix => "posix",
                .Native => "native",
                .EfiApplication => "efi_application",
                .EfiBootServiceDriver => "efi_boot_service_driver",
                .EfiRom => "efi_rom",
                .EfiRuntimeDriver => "efi_runtime_driver",
            });
        }

        if (self.kind == .@"test") {
            try builder.spawnChild(zig_args.items);
        } else {
            try zig_args.append("--enable-cache");

            const output_dir_nl = try builder.execFromStep(zig_args.items, &self.step);
            const build_output_dir = mem.trimRight(u8, output_dir_nl, "\r\n");

            if (self.output_dir) |output_dir| {
                var src_dir = try std.fs.cwd().openDir(build_output_dir, .{ .iterate = true });
                defer src_dir.close();

                // Create the output directory if it doesn't exist.
                try std.fs.cwd().makePath(output_dir);

                var dest_dir = try std.fs.cwd().openDir(output_dir, .{});
                defer dest_dir.close();

                var it = src_dir.iterate();
                while (try it.next()) |entry| {
                    // The compiler can put these files into the same directory, but we don't
                    // want to copy them over.
                    if (mem.eql(u8, entry.name, "stage1.id") or
                        mem.eql(u8, entry.name, "llvm-ar.id") or
                        mem.eql(u8, entry.name, "libs.txt") or
                        mem.eql(u8, entry.name, "builtin.zig") or
                        mem.eql(u8, entry.name, "lld.id")) continue;

                    _ = try src_dir.updateFile(entry.name, dest_dir, entry.name, .{});
                }
            } else {
                self.output_dir = build_output_dir;
            }
        }

        // This will ensure all output filenames will now have the output_dir available!
        self.computeOutFileNames();

        // Update generated files
        if (self.output_dir != null) {
            self.output_path_source.path =
                fs.path.join(
                self.builder.allocator,
                &[_][]const u8{ self.output_dir.?, self.out_filename },
            ) catch unreachable;

            if (self.emit_h) {
                self.output_h_path_source.path =
                    fs.path.join(
                    self.builder.allocator,
                    &[_][]const u8{ self.output_dir.?, self.out_h_filename },
                ) catch unreachable;
            }

            if (self.target.isWindows() or self.target.isUefi()) {
                self.output_pdb_path_source.path =
                    fs.path.join(
                    self.builder.allocator,
                    &[_][]const u8{ self.output_dir.?, self.out_pdb_filename },
                ) catch unreachable;
            }
        }

        if (self.kind == .lib and self.linkage != null and self.linkage.? == .dynamic and self.version != null and self.target.wantSharedLibSymLinks()) {
            try doAtomicSymLinks(builder.allocator, self.getOutputSource().getPath(builder), self.major_only_filename.?, self.name_only_filename.?);
        }
    }
};

pub const InstallArtifactStep = struct {
    pub const base_id = .install_artifact;

    step: Step,
    builder: *Builder,
    artifact: *LibExeObjStep,
    dest_dir: InstallDir,
    pdb_dir: ?InstallDir,
    h_dir: ?InstallDir,

    const Self = @This();

    pub fn create(builder: *Builder, artifact: *LibExeObjStep) *Self {
        if (artifact.install_step) |s| return s;

        const self = builder.allocator.create(Self) catch unreachable;
        self.* = Self{
            .builder = builder,
            .step = Step.init(.install_artifact, builder.fmt("install {s}", .{artifact.step.name}), builder.allocator, make),
            .artifact = artifact,
            .dest_dir = artifact.override_dest_dir orelse switch (artifact.kind) {
                .obj => unreachable,
                .@"test" => unreachable,
                .exe => InstallDir{ .bin = {} },
                .lib => InstallDir{ .lib = {} },
            },
            .pdb_dir = if (artifact.producesPdbFile()) blk: {
                if (artifact.kind == .exe) {
                    break :blk InstallDir{ .bin = {} };
                } else {
                    break :blk InstallDir{ .lib = {} };
                }
            } else null,
            .h_dir = if (artifact.kind == .lib and artifact.emit_h) .header else null,
        };
        self.step.dependOn(&artifact.step);
        artifact.install_step = self;

        builder.pushInstalledFile(self.dest_dir, artifact.out_filename);
        if (self.artifact.isDynamicLibrary()) {
            if (artifact.major_only_filename) |name| {
                builder.pushInstalledFile(.lib, name);
            }
            if (artifact.name_only_filename) |name| {
                builder.pushInstalledFile(.lib, name);
            }
            if (self.artifact.target.isWindows()) {
                builder.pushInstalledFile(.lib, artifact.out_lib_filename);
            }
        }
        if (self.pdb_dir) |pdb_dir| {
            builder.pushInstalledFile(pdb_dir, artifact.out_pdb_filename);
        }
        if (self.h_dir) |h_dir| {
            builder.pushInstalledFile(h_dir, artifact.out_h_filename);
        }
        return self;
    }

    fn make(step: *Step) !void {
        const self = @fieldParentPtr(Self, "step", step);
        const builder = self.builder;

        const full_dest_path = builder.getInstallPath(self.dest_dir, self.artifact.out_filename);
        try builder.updateFile(self.artifact.getOutputSource().getPath(builder), full_dest_path);
        if (self.artifact.isDynamicLibrary() and self.artifact.version != null and self.artifact.target.wantSharedLibSymLinks()) {
            try doAtomicSymLinks(builder.allocator, full_dest_path, self.artifact.major_only_filename.?, self.artifact.name_only_filename.?);
        }
        if (self.pdb_dir) |pdb_dir| {
            const full_pdb_path = builder.getInstallPath(pdb_dir, self.artifact.out_pdb_filename);
            try builder.updateFile(self.artifact.getOutputPdbSource().getPath(builder), full_pdb_path);
        }
        if (self.h_dir) |h_dir| {
            const full_pdb_path = builder.getInstallPath(h_dir, self.artifact.out_h_filename);
            try builder.updateFile(self.artifact.getOutputHSource().getPath(builder), full_pdb_path);
        }
        self.artifact.installed_path = full_dest_path;
    }
};

pub const InstallFileStep = struct {
    pub const base_id = .install_file;

    step: Step,
    builder: *Builder,
    source: FileSource,
    dir: InstallDir,
    dest_rel_path: []const u8,

    pub fn init(
        builder: *Builder,
        source: FileSource,
        dir: InstallDir,
        dest_rel_path: []const u8,
    ) InstallFileStep {
        builder.pushInstalledFile(dir, dest_rel_path);
        return InstallFileStep{
            .builder = builder,
            .step = Step.init(.install_file, builder.fmt("install {s} to {s}", .{ source.getDisplayName(), dest_rel_path }), builder.allocator, make),
            .source = source.dupe(builder),
            .dir = dir.dupe(builder),
            .dest_rel_path = builder.dupePath(dest_rel_path),
        };
    }

    fn make(step: *Step) !void {
        const self = @fieldParentPtr(InstallFileStep, "step", step);
        const full_dest_path = self.builder.getInstallPath(self.dir, self.dest_rel_path);
        const full_src_path = self.source.getPath(self.builder);
        try self.builder.updateFile(full_src_path, full_dest_path);
    }
};

pub const InstallDirectoryOptions = struct {
    source_dir: []const u8,
    install_dir: InstallDir,
    install_subdir: []const u8,
    /// File paths which end in any of these suffixes will be excluded
    /// from being installed.
    exclude_extensions: []const []const u8 = &.{},
    /// File paths which end in any of these suffixes will result in
    /// empty files being installed. This is mainly intended for large
    /// test.zig files in order to prevent needless installation bloat.
    /// However if the files were not present at all, then
    /// `@import("test.zig")` would be a compile error.
    blank_extensions: []const []const u8 = &.{},

    fn dupe(self: InstallDirectoryOptions, b: *Builder) InstallDirectoryOptions {
        return .{
            .source_dir = b.dupe(self.source_dir),
            .install_dir = self.install_dir.dupe(b),
            .install_subdir = b.dupe(self.install_subdir),
            .exclude_extensions = b.dupeStrings(self.exclude_extensions),
            .blank_extensions = b.dupeStrings(self.blank_extensions),
        };
    }
};

pub const InstallDirStep = struct {
    pub const base_id = .install_dir;

    step: Step,
    builder: *Builder,
    options: InstallDirectoryOptions,

    pub fn init(
        builder: *Builder,
        options: InstallDirectoryOptions,
    ) InstallDirStep {
        builder.pushInstalledFile(options.install_dir, options.install_subdir);
        return InstallDirStep{
            .builder = builder,
            .step = Step.init(.install_dir, builder.fmt("install {s}/", .{options.source_dir}), builder.allocator, make),
            .options = options.dupe(builder),
        };
    }

    fn make(step: *Step) !void {
        const self = @fieldParentPtr(InstallDirStep, "step", step);
        const dest_prefix = self.builder.getInstallPath(self.options.install_dir, self.options.install_subdir);
        const full_src_dir = self.builder.pathFromRoot(self.options.source_dir);
        var it = try fs.walkPath(self.builder.allocator, full_src_dir);
        next_entry: while (try it.next()) |entry| {
            for (self.options.exclude_extensions) |ext| {
                if (mem.endsWith(u8, entry.path, ext)) {
                    continue :next_entry;
                }
            }

            const rel_path = entry.path[full_src_dir.len + 1 ..];
            const dest_path = try fs.path.join(self.builder.allocator, &[_][]const u8{
                dest_prefix, rel_path,
            });

            switch (entry.kind) {
                .Directory => try fs.cwd().makePath(dest_path),
                .File => {
                    for (self.options.blank_extensions) |ext| {
                        if (mem.endsWith(u8, entry.path, ext)) {
                            try self.builder.truncateFile(dest_path);
                            continue :next_entry;
                        }
                    }

                    try self.builder.updateFile(entry.path, dest_path);
                },
                else => continue,
            }
        }
    }
};

pub const LogStep = struct {
    pub const base_id = .log;

    step: Step,
    builder: *Builder,
    data: []const u8,

    pub fn init(builder: *Builder, data: []const u8) LogStep {
        return LogStep{
            .builder = builder,
            .step = Step.init(.log, builder.fmt("log {s}", .{data}), builder.allocator, make),
            .data = builder.dupe(data),
        };
    }

    fn make(step: *Step) anyerror!void {
        const self = @fieldParentPtr(LogStep, "step", step);
        warn("{s}", .{self.data});
    }
};

pub const RemoveDirStep = struct {
    pub const base_id = .remove_dir;

    step: Step,
    builder: *Builder,
    dir_path: []const u8,

    pub fn init(builder: *Builder, dir_path: []const u8) RemoveDirStep {
        return RemoveDirStep{
            .builder = builder,
            .step = Step.init(.remove_dir, builder.fmt("RemoveDir {s}", .{dir_path}), builder.allocator, make),
            .dir_path = builder.dupePath(dir_path),
        };
    }

    fn make(step: *Step) !void {
        const self = @fieldParentPtr(RemoveDirStep, "step", step);

        const full_path = self.builder.pathFromRoot(self.dir_path);
        fs.cwd().deleteTree(full_path) catch |err| {
            warn("Unable to remove {s}: {s}\n", .{ full_path, @errorName(err) });
            return err;
        };
    }
};

const ThisModule = @This();
pub const Step = struct {
    id: Id,
    name: []const u8,
    makeFn: fn (self: *Step) anyerror!void,
    dependencies: ArrayList(*Step),
    loop_flag: bool,
    done_flag: bool,

    pub const Id = enum {
        top_level,
        lib_exe_obj,
        install_artifact,
        install_file,
        install_dir,
        log,
        remove_dir,
        fmt,
        translate_c,
        write_file,
        run,
        check_file,
        install_raw,
        custom,
    };

    pub fn init(id: Id, name: []const u8, allocator: *Allocator, makeFn: fn (*Step) anyerror!void) Step {
        return Step{
            .id = id,
            .name = allocator.dupe(u8, name) catch unreachable,
            .makeFn = makeFn,
            .dependencies = ArrayList(*Step).init(allocator),
            .loop_flag = false,
            .done_flag = false,
        };
    }
    pub fn initNoOp(id: Id, name: []const u8, allocator: *Allocator) Step {
        return init(id, name, allocator, makeNoOp);
    }

    pub fn make(self: *Step) !void {
        if (self.done_flag) return;

        try self.makeFn(self);
        self.done_flag = true;
    }

    pub fn dependOn(self: *Step, other: *Step) void {
        self.dependencies.append(other) catch unreachable;
    }

    fn makeNoOp(self: *Step) anyerror!void {
        _ = self;
    }

    pub fn cast(step: *Step, comptime T: type) ?*T {
        if (step.id == T.base_id) {
            return @fieldParentPtr(T, "step", step);
        }
        return null;
    }
};

fn doAtomicSymLinks(allocator: *Allocator, output_path: []const u8, filename_major_only: []const u8, filename_name_only: []const u8) !void {
    const out_dir = fs.path.dirname(output_path) orelse ".";
    const out_basename = fs.path.basename(output_path);
    // sym link for libfoo.so.1 to libfoo.so.1.2.3
    const major_only_path = fs.path.join(
        allocator,
        &[_][]const u8{ out_dir, filename_major_only },
    ) catch unreachable;
    fs.atomicSymLink(allocator, out_basename, major_only_path) catch |err| {
        warn("Unable to symlink {s} -> {s}\n", .{ major_only_path, out_basename });
        return err;
    };
    // sym link for libfoo.so to libfoo.so.1
    const name_only_path = fs.path.join(
        allocator,
        &[_][]const u8{ out_dir, filename_name_only },
    ) catch unreachable;
    fs.atomicSymLink(allocator, filename_major_only, name_only_path) catch |err| {
        warn("Unable to symlink {s} -> {s}\n", .{ name_only_path, filename_major_only });
        return err;
    };
}

/// Returned slice must be freed by the caller.
fn findVcpkgRoot(allocator: *Allocator) !?[]const u8 {
    const appdata_path = try fs.getAppDataDir(allocator, "vcpkg");
    defer allocator.free(appdata_path);

    const path_file = try fs.path.join(allocator, &[_][]const u8{ appdata_path, "vcpkg.path.txt" });
    defer allocator.free(path_file);

    const file = fs.cwd().openFile(path_file, .{}) catch return null;
    defer file.close();

    const size = @intCast(usize, try file.getEndPos());
    const vcpkg_path = try allocator.alloc(u8, size);
    const size_read = try file.read(vcpkg_path);
    std.debug.assert(size == size_read);

    return vcpkg_path;
}

const VcpkgRoot = union(VcpkgRootStatus) {
    unattempted: void,
    not_found: void,
    found: []const u8,
};

const VcpkgRootStatus = enum {
    unattempted,
    not_found,
    found,
};

pub const InstallDir = union(enum) {
    prefix: void,
    lib: void,
    bin: void,
    header: void,
    /// A path relative to the prefix
    custom: []const u8,

    /// Duplicates the install directory including the path if set to custom.
    pub fn dupe(self: InstallDir, builder: *Builder) InstallDir {
        if (self == .custom) {
            // Written with this temporary to avoid RLS problems
            const duped_path = builder.dupe(self.custom);
            return .{ .custom = duped_path };
        } else {
            return self;
        }
    }
};

pub const InstalledFile = struct {
    dir: InstallDir,
    path: []const u8,

    /// Duplicates the installed file path and directory.
    pub fn dupe(self: InstalledFile, builder: *Builder) InstalledFile {
        return .{
            .dir = self.dir.dupe(builder),
            .path = builder.dupe(self.path),
        };
    }
};

test "Builder.dupePkg()" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var builder = try Builder.create(
        &arena.allocator,
        "test",
        "test",
        "test",
        "test",
    );
    defer builder.destroy();

    var pkg_dep = Pkg{
        .name = "pkg_dep",
        .path = .{ .path = "/not/a/pkg_dep.zig" },
    };
    var pkg_top = Pkg{
        .name = "pkg_top",
        .path = .{ .path = "/not/a/pkg_top.zig" },
        .dependencies = &[_]Pkg{pkg_dep},
    };
    const dupe = builder.dupePkg(pkg_top);

    const original_deps = pkg_top.dependencies.?;
    const dupe_deps = dupe.dependencies.?;

    // probably the same top level package details
    try std.testing.expectEqualStrings(pkg_top.name, dupe.name);

    // probably the same dependencies
    try std.testing.expectEqual(original_deps.len, dupe_deps.len);
    try std.testing.expectEqual(original_deps[0].name, pkg_dep.name);

    // could segfault otherwise if pointers in duplicated package's fields are
    // the same as those in stack allocated package's fields
    try std.testing.expect(dupe_deps.ptr != original_deps.ptr);
    try std.testing.expect(dupe.name.ptr != pkg_top.name.ptr);
    try std.testing.expect(dupe.path.path.ptr != pkg_top.path.path.ptr);
    try std.testing.expect(dupe_deps[0].name.ptr != pkg_dep.name.ptr);
    try std.testing.expect(dupe_deps[0].path.path.ptr != pkg_dep.path.path.ptr);
}

test "LibExeObjStep.addBuildOption" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var builder = try Builder.create(
        &arena.allocator,
        "test",
        "test",
        "test",
        "test",
    );
    defer builder.destroy();

    var exe = builder.addExecutable("not_an_executable", "/not/an/executable.zig");
    exe.addBuildOption(usize, "option1", 1);
    exe.addBuildOption(?usize, "option2", null);
    exe.addBuildOption([]const u8, "string", "zigisthebest");
    exe.addBuildOption(?[]const u8, "optional_string", null);
    exe.addBuildOption(std.SemanticVersion, "semantic_version", try std.SemanticVersion.parse("0.1.2-foo+bar"));

    try std.testing.expectEqualStrings(
        \\pub const option1: usize = 1;
        \\pub const option2: ?usize = null;
        \\pub const string: []const u8 = "zigisthebest";
        \\pub const optional_string: ?[]const u8 = null;
        \\pub const semantic_version: @import("std").SemanticVersion = .{
        \\    .major = 0,
        \\    .minor = 1,
        \\    .patch = 2,
        \\    .pre = "foo",
        \\    .build = "bar",
        \\};
        \\
    , exe.build_options_contents.items);
}

test "LibExeObjStep.addPackage" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var builder = try Builder.create(
        &arena.allocator,
        "test",
        "test",
        "test",
        "test",
    );
    defer builder.destroy();

    const pkg_dep = Pkg{
        .name = "pkg_dep",
        .path = .{ .path = "/not/a/pkg_dep.zig" },
    };
    const pkg_top = Pkg{
        .name = "pkg_dep",
        .path = .{ .path = "/not/a/pkg_top.zig" },
        .dependencies = &[_]Pkg{pkg_dep},
    };

    var exe = builder.addExecutable("not_an_executable", "/not/an/executable.zig");
    exe.addPackage(pkg_top);

    try std.testing.expectEqual(@as(usize, 1), exe.packages.items.len);

    const dupe = exe.packages.items[0];
    try std.testing.expectEqualStrings(pkg_top.name, dupe.name);
}

test {
    // The only purpose of this test is to get all these untested functions
    // to be referenced to avoid regression so it is okay to skip some targets.
    if (comptime std.Target.current.cpu.arch.ptrBitWidth() == 64) {
        std.testing.refAllDecls(@This());
        std.testing.refAllDecls(Builder);

        inline for (std.meta.declarations(@This())) |decl|
            if (comptime mem.endsWith(u8, decl.name, "Step"))
                std.testing.refAllDecls(decl.data.Type);
    }
}
