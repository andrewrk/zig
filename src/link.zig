const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const fs = std.fs;
const log = std.log.scoped(.link);
const assert = std.debug.assert;

const Compilation = @import("Compilation.zig");
const Module = @import("Module.zig");
const trace = @import("tracy.zig").trace;
const Package = @import("Package.zig");
const Type = @import("type.zig").Type;
const Cache = @import("Cache.zig");
const build_options = @import("build_options");
const LibCInstallation = @import("libc_installation.zig").LibCInstallation;
const wasi_libc = @import("wasi_libc.zig");
const Air = @import("Air.zig");
const Liveness = @import("Liveness.zig");

pub const producer_string = if (builtin.is_test) "zig test" else "zig " ++ build_options.version;

pub const Emit = struct {
    /// Where the output will go.
    directory: Compilation.Directory,
    /// Path to the output file, relative to `directory`.
    sub_path: []const u8,
};

pub const Options = struct {
    /// This is `null` when -fno-emit-bin is used. When `openPath` or `flush` is called,
    /// it will have already been null-checked.
    emit: ?Emit,
    target: std.Target,
    output_mode: std.builtin.OutputMode,
    link_mode: std.builtin.LinkMode,
    object_format: std.Target.ObjectFormat,
    optimize_mode: std.builtin.Mode,
    machine_code_model: std.builtin.CodeModel,
    root_name: []const u8,
    /// Not every Compilation compiles .zig code! For example you could do `zig build-exe foo.o`.
    module: ?*Module,
    dynamic_linker: ?[]const u8,
    /// The root path for the dynamic linker and system libraries (as well as frameworks on Darwin)
    sysroot: ?[]const u8,
    /// Used for calculating how much space to reserve for symbols in case the binary file
    /// does not already have a symbol table.
    symbol_count_hint: u64 = 32,
    /// Used for calculating how much space to reserve for executable program code in case
    /// the binary file does not already have such a section.
    program_code_size_hint: u64 = 256 * 1024,
    entry_addr: ?u64 = null,
    stack_size_override: ?u64,
    image_base_override: ?u64,
    include_compiler_rt: bool,
    /// Set to `true` to omit debug info.
    strip: bool,
    /// If this is true then this link code is responsible for outputting an object
    /// file and then using LLD to link it together with the link options and other objects.
    /// Otherwise (depending on `use_llvm`) this link code directly outputs and updates the final binary.
    use_lld: bool,
    /// If this is true then this link code is responsible for making an LLVM IR Module,
    /// outputting it to an object file, and then linking that together with link options and
    /// other objects.
    /// Otherwise (depending on `use_lld`) this link code directly outputs and updates the final binary.
    use_llvm: bool,
    link_libc: bool,
    link_libcpp: bool,
    link_libunwind: bool,
    function_sections: bool,
    eh_frame_hdr: bool,
    emit_relocs: bool,
    rdynamic: bool,
    z_nodelete: bool,
    z_defs: bool,
    tsaware: bool,
    nxcompat: bool,
    dynamicbase: bool,
    bind_global_refs_locally: bool,
    is_native_os: bool,
    is_native_abi: bool,
    pic: bool,
    pie: bool,
    lto: bool,
    valgrind: bool,
    tsan: bool,
    stack_check: bool,
    red_zone: bool,
    single_threaded: bool,
    verbose_link: bool,
    dll_export_fns: bool,
    error_return_tracing: bool,
    skip_linker_dependencies: bool,
    parent_compilation_link_libc: bool,
    each_lib_rpath: bool,
    disable_lld_caching: bool,
    is_test: bool,
    use_stage1: bool,
    major_subsystem_version: ?u32,
    minor_subsystem_version: ?u32,
    gc_sections: ?bool = null,
    allow_shlib_undefined: ?bool,
    subsystem: ?std.Target.SubSystem,
    linker_script: ?[]const u8,
    version_script: ?[]const u8,
    soname: ?[]const u8,
    llvm_cpu_features: ?[*:0]const u8,
    /// Extra args passed directly to LLD. Ignored when not linking with LLD.
    extra_lld_args: []const []const u8,

    objects: []const []const u8,
    framework_dirs: []const []const u8,
    frameworks: []const []const u8,
    system_libs: std.StringArrayHashMapUnmanaged(void),
    wasi_emulated_libs: []const wasi_libc.CRTFile,
    lib_dirs: []const []const u8,
    rpath_list: []const []const u8,

    version: ?std.builtin.Version,
    libc_installation: ?*const LibCInstallation,

    /// WASI-only. Type of WASI execution model ("command" or "reactor").
    wasi_exec_model: std.builtin.WasiExecModel = undefined,

    pub fn effectiveOutputMode(options: Options) std.builtin.OutputMode {
        return if (options.use_lld) .Obj else options.output_mode;
    }
};

pub const File = struct {
    tag: Tag,
    options: Options,
    file: ?fs.File,
    allocator: *Allocator,
    /// When linking with LLD, this linker code will output an object file only at
    /// this location, and then this path can be placed on the LLD linker line.
    intermediary_basename: ?[]const u8 = null,

    /// Prevents other processes from clobbering files in the output directory
    /// of this linking operation.
    lock: ?Cache.Lock = null,

    pub const LinkBlock = union {
        elf: Elf.TextBlock,
        coff: Coff.TextBlock,
        macho: MachO.TextBlock,
        plan9: Plan9.DeclBlock,
        c: C.DeclBlock,
        wasm: Wasm.DeclBlock,
        spirv: void,
    };

    pub const LinkFn = union {
        elf: Elf.SrcFn,
        coff: Coff.SrcFn,
        macho: MachO.SrcFn,
        plan9: void,
        c: C.FnBlock,
        wasm: Wasm.FnData,
        spirv: SpirV.FnData,
    };

    pub const Export = union {
        elf: Elf.Export,
        coff: void,
        macho: MachO.Export,
        plan9: Plan9.Export,
        c: void,
        wasm: void,
        spirv: void,
    };

    /// For DWARF .debug_info.
    pub const DbgInfoTypeRelocsTable = std.HashMapUnmanaged(Type, DbgInfoTypeReloc, Type.HashContext64, std.hash_map.default_max_load_percentage);

    /// For DWARF .debug_info.
    pub const DbgInfoTypeReloc = struct {
        /// Offset from `TextBlock.dbg_info_off` (the buffer that is local to a Decl).
        /// This is where the .debug_info tag for the type is.
        off: u32,
        /// Offset from `TextBlock.dbg_info_off` (the buffer that is local to a Decl).
        /// List of DW.AT_type / DW.FORM_ref4 that points to the type.
        relocs: std.ArrayListUnmanaged(u32),
    };

    /// Attempts incremental linking, if the file already exists. If
    /// incremental linking fails, falls back to truncating the file and
    /// rewriting it. A malicious file is detected as incremental link failure
    /// and does not cause Illegal Behavior. This operation is not atomic.
    pub fn openPath(allocator: *Allocator, options: Options) !*File {
        const use_stage1 = build_options.is_stage1 and options.use_stage1;
        if (use_stage1 or options.emit == null) {
            return switch (options.object_format) {
                .coff, .pe => &(try Coff.createEmpty(allocator, options)).base,
                .elf => &(try Elf.createEmpty(allocator, options)).base,
                .macho => &(try MachO.createEmpty(allocator, options)).base,
                .wasm => &(try Wasm.createEmpty(allocator, options)).base,
                .plan9 => return &(try Plan9.createEmpty(allocator, options)).base,
                .c => unreachable, // Reported error earlier.
                .spirv => &(try SpirV.createEmpty(allocator, options)).base,
                .hex => return error.HexObjectFormatUnimplemented,
                .raw => return error.RawObjectFormatUnimplemented,
            };
        }
        const emit = options.emit.?;
        const use_lld = build_options.have_llvm and options.use_lld; // comptime known false when !have_llvm
        const sub_path = if (use_lld) blk: {
            if (options.module == null) {
                // No point in opening a file, we would not write anything to it. Initialize with empty.
                return switch (options.object_format) {
                    .coff, .pe => &(try Coff.createEmpty(allocator, options)).base,
                    .elf => &(try Elf.createEmpty(allocator, options)).base,
                    .macho => &(try MachO.createEmpty(allocator, options)).base,
                    .plan9 => &(try Plan9.createEmpty(allocator, options)).base,
                    .wasm => &(try Wasm.createEmpty(allocator, options)).base,
                    .c => unreachable, // Reported error earlier.
                    .spirv => &(try SpirV.createEmpty(allocator, options)).base,
                    .hex => return error.HexObjectFormatUnimplemented,
                    .raw => return error.RawObjectFormatUnimplemented,
                };
            }
            // Open a temporary object file, not the final output file because we want to link with LLD.
            break :blk try std.fmt.allocPrint(allocator, "{s}{s}", .{ emit.sub_path, options.target.oFileExt() });
        } else emit.sub_path;
        errdefer if (use_lld) allocator.free(sub_path);

        const file: *File = switch (options.object_format) {
            .coff, .pe => &(try Coff.openPath(allocator, sub_path, options)).base,
            .elf => &(try Elf.openPath(allocator, sub_path, options)).base,
            .macho => &(try MachO.openPath(allocator, sub_path, options)).base,
            .plan9 => &(try Plan9.openPath(allocator, sub_path, options)).base,
            .wasm => &(try Wasm.openPath(allocator, sub_path, options)).base,
            .c => &(try C.openPath(allocator, sub_path, options)).base,
            .spirv => &(try SpirV.openPath(allocator, sub_path, options)).base,
            .hex => return error.HexObjectFormatUnimplemented,
            .raw => return error.RawObjectFormatUnimplemented,
        };

        if (use_lld) {
            file.intermediary_basename = sub_path;
        }

        return file;
    }

    pub fn cast(base: *File, comptime T: type) ?*T {
        if (base.tag != T.base_tag)
            return null;

        return @fieldParentPtr(T, "base", base);
    }

    pub fn makeWritable(base: *File) !void {
        switch (base.tag) {
            .coff, .elf, .macho, .plan9 => {
                if (base.file != null) return;
                const emit = base.options.emit orelse return;
                base.file = try emit.directory.handle.createFile(emit.sub_path, .{
                    .truncate = false,
                    .read = true,
                    .mode = determineMode(base.options),
                });
            },
            .c, .wasm, .spirv => {},
        }
    }

    pub fn makeExecutable(base: *File) !void {
        switch (base.options.output_mode) {
            .Obj => return,
            .Lib => switch (base.options.link_mode) {
                .Static => return,
                .Dynamic => {},
            },
            .Exe => {},
        }
        switch (base.tag) {
            .macho => if (base.file) |f| {
                if (base.intermediary_basename != null) {
                    // The file we have open is not the final file that we want to
                    // make executable, so we don't have to close it.
                    return;
                }
                if (comptime std.Target.current.isDarwin() and std.Target.current.cpu.arch == .aarch64) {
                    if (base.options.target.cpu.arch != .aarch64) return; // If we're not targeting aarch64, nothing to do.
                    // XNU starting with Big Sur running on arm64 is caching inodes of running binaries.
                    // Any change to the binary will effectively invalidate the kernel's cache
                    // resulting in a SIGKILL on each subsequent run. Since when doing incremental
                    // linking we're modifying a binary in-place, this will end up with the kernel
                    // killing it on every subsequent run. To circumvent it, we will copy the file
                    // into a new inode, remove the original file, and rename the copy to match
                    // the original file. This is super messy, but there doesn't seem any other
                    // way to please the XNU.
                    const emit = base.options.emit orelse return;
                    try emit.directory.handle.copyFile(emit.sub_path, emit.directory.handle, emit.sub_path, .{});
                }
                f.close();
                base.file = null;
            },
            .coff, .elf, .plan9 => if (base.file) |f| {
                if (base.intermediary_basename != null) {
                    // The file we have open is not the final file that we want to
                    // make executable, so we don't have to close it.
                    return;
                }
                f.close();
                base.file = null;
            },
            .c, .wasm, .spirv => {},
        }
    }

    /// May be called before or after updateDeclExports but must be called
    /// after allocateDeclIndexes for any given Decl.
    pub fn updateDecl(base: *File, module: *Module, decl: *Module.Decl) !void {
        log.debug("updateDecl {*} ({s}), type={}", .{ decl, decl.name, decl.ty });
        assert(decl.has_tv);
        switch (base.tag) {
            // zig fmt: off
            .coff  => return @fieldParentPtr(Coff,  "base", base).updateDecl(module, decl),
            .elf   => return @fieldParentPtr(Elf,   "base", base).updateDecl(module, decl),
            .macho => return @fieldParentPtr(MachO, "base", base).updateDecl(module, decl),
            .c     => return @fieldParentPtr(C,     "base", base).updateDecl(module, decl),
            .wasm  => return @fieldParentPtr(Wasm,  "base", base).updateDecl(module, decl),
            .spirv => return @fieldParentPtr(SpirV, "base", base).updateDecl(module, decl),
            .plan9 => return @fieldParentPtr(Plan9, "base", base).updateDecl(module, decl),
            // zig fmt: on
        }
    }

    /// May be called before or after updateDeclExports but must be called
    /// after allocateDeclIndexes for any given Decl.
    pub fn updateFunc(base: *File, module: *Module, func: *Module.Fn, air: Air, liveness: Liveness) !void {
        log.debug("updateFunc {*} ({s}), type={}", .{
            func.owner_decl, func.owner_decl.name, func.owner_decl.ty,
        });
        switch (base.tag) {
            // zig fmt: off
            .coff  => return @fieldParentPtr(Coff,  "base", base).updateFunc(module, func, air, liveness),
            .elf   => return @fieldParentPtr(Elf,   "base", base).updateFunc(module, func, air, liveness),
            .macho => return @fieldParentPtr(MachO, "base", base).updateFunc(module, func, air, liveness),
            .c     => return @fieldParentPtr(C,     "base", base).updateFunc(module, func, air, liveness),
            .wasm  => return @fieldParentPtr(Wasm,  "base", base).updateFunc(module, func, air, liveness),
            .spirv => return @fieldParentPtr(SpirV, "base", base).updateFunc(module, func, air, liveness),
            .plan9 => return @fieldParentPtr(Plan9, "base", base).updateFunc(module, func, air, liveness),
            // zig fmt: on
        }
    }

    pub fn updateDeclLineNumber(base: *File, module: *Module, decl: *Module.Decl) !void {
        log.debug("updateDeclLineNumber {*} ({s}), line={}", .{
            decl, decl.name, decl.src_line + 1,
        });
        assert(decl.has_tv);
        switch (base.tag) {
            .coff => return @fieldParentPtr(Coff, "base", base).updateDeclLineNumber(module, decl),
            .elf => return @fieldParentPtr(Elf, "base", base).updateDeclLineNumber(module, decl),
            .macho => return @fieldParentPtr(MachO, "base", base).updateDeclLineNumber(module, decl),
            .c => return @fieldParentPtr(C, "base", base).updateDeclLineNumber(module, decl),
            .plan9 => @panic("TODO: implement updateDeclLineNumber for plan9"),
            .wasm, .spirv => {},
        }
    }

    /// Must be called before any call to updateDecl or updateDeclExports for
    /// any given Decl.
    pub fn allocateDeclIndexes(base: *File, decl: *Module.Decl) !void {
        log.debug("allocateDeclIndexes {*} ({s})", .{ decl, decl.name });
        switch (base.tag) {
            .coff => return @fieldParentPtr(Coff, "base", base).allocateDeclIndexes(decl),
            .elf => return @fieldParentPtr(Elf, "base", base).allocateDeclIndexes(decl),
            .macho => return @fieldParentPtr(MachO, "base", base).allocateDeclIndexes(decl),
            .c => return @fieldParentPtr(C, "base", base).allocateDeclIndexes(decl),
            .wasm => return @fieldParentPtr(Wasm, "base", base).allocateDeclIndexes(decl),
            .plan9 => return @fieldParentPtr(Plan9, "base", base).allocateDeclIndexes(decl),
            .spirv => {},
        }
    }

    pub fn releaseLock(self: *File) void {
        if (self.lock) |*lock| {
            lock.release();
            self.lock = null;
        }
    }

    pub fn toOwnedLock(self: *File) Cache.Lock {
        const lock = self.lock.?;
        self.lock = null;
        return lock;
    }

    pub fn destroy(base: *File) void {
        base.releaseLock();
        if (base.file) |f| f.close();
        if (base.intermediary_basename) |sub_path| base.allocator.free(sub_path);
        base.options.system_libs.deinit(base.allocator);
        switch (base.tag) {
            .coff => {
                const parent = @fieldParentPtr(Coff, "base", base);
                parent.deinit();
                base.allocator.destroy(parent);
            },
            .elf => {
                const parent = @fieldParentPtr(Elf, "base", base);
                parent.deinit();
                base.allocator.destroy(parent);
            },
            .macho => {
                const parent = @fieldParentPtr(MachO, "base", base);
                parent.deinit();
                base.allocator.destroy(parent);
            },
            .c => {
                const parent = @fieldParentPtr(C, "base", base);
                parent.deinit();
                base.allocator.destroy(parent);
            },
            .wasm => {
                const parent = @fieldParentPtr(Wasm, "base", base);
                parent.deinit();
                base.allocator.destroy(parent);
            },
            .spirv => {
                const parent = @fieldParentPtr(SpirV, "base", base);
                parent.deinit();
                base.allocator.destroy(parent);
            },
            .plan9 => {
                const parent = @fieldParentPtr(Plan9, "base", base);
                parent.deinit();
                base.allocator.destroy(parent);
            },
        }
    }

    /// Commit pending changes and write headers. Takes into account final output mode
    /// and `use_lld`, not only `effectiveOutputMode`.
    pub fn flush(base: *File, comp: *Compilation) !void {
        const emit = base.options.emit orelse return; // -fno-emit-bin

        if (comp.clang_preprocessor_mode == .yes) {
            // TODO: avoid extra link step when it's just 1 object file (the `zig cc -c` case)
            // Until then, we do `lld -r -o output.o input.o` even though the output is the same
            // as the input. For the preprocessing case (`zig cc -E -o foo`) we copy the file
            // to the final location. See also the corresponding TODO in Coff linking.
            const full_out_path = try emit.directory.join(comp.gpa, &[_][]const u8{emit.sub_path});
            defer comp.gpa.free(full_out_path);
            assert(comp.c_object_table.count() == 1);
            const the_key = comp.c_object_table.keys()[0];
            const cached_pp_file_path = the_key.status.success.object_path;
            try fs.cwd().copyFile(cached_pp_file_path, fs.cwd(), full_out_path, .{});
            return;
        }
        const use_lld = build_options.have_llvm and base.options.use_lld;
        if (use_lld and base.options.output_mode == .Lib and base.options.link_mode == .Static) {
            return base.linkAsArchive(comp);
        }
        switch (base.tag) {
            .coff => return @fieldParentPtr(Coff, "base", base).flush(comp),
            .elf => return @fieldParentPtr(Elf, "base", base).flush(comp),
            .macho => return @fieldParentPtr(MachO, "base", base).flush(comp),
            .c => return @fieldParentPtr(C, "base", base).flush(comp),
            .wasm => return @fieldParentPtr(Wasm, "base", base).flush(comp),
            .spirv => return @fieldParentPtr(SpirV, "base", base).flush(comp),
            .plan9 => return @fieldParentPtr(Plan9, "base", base).flush(comp),
        }
    }

    /// Commit pending changes and write headers. Works based on `effectiveOutputMode`
    /// rather than final output mode.
    pub fn flushModule(base: *File, comp: *Compilation) !void {
        switch (base.tag) {
            .coff => return @fieldParentPtr(Coff, "base", base).flushModule(comp),
            .elf => return @fieldParentPtr(Elf, "base", base).flushModule(comp),
            .macho => return @fieldParentPtr(MachO, "base", base).flushModule(comp),
            .c => return @fieldParentPtr(C, "base", base).flushModule(comp),
            .wasm => return @fieldParentPtr(Wasm, "base", base).flushModule(comp),
            .spirv => return @fieldParentPtr(SpirV, "base", base).flushModule(comp),
            .plan9 => return @fieldParentPtr(Plan9, "base", base).flushModule(comp),
        }
    }

    /// Called when a Decl is deleted from the Module.
    pub fn freeDecl(base: *File, decl: *Module.Decl) void {
        log.debug("freeDecl {*} ({s})", .{ decl, decl.name });
        switch (base.tag) {
            .coff => @fieldParentPtr(Coff, "base", base).freeDecl(decl),
            .elf => @fieldParentPtr(Elf, "base", base).freeDecl(decl),
            .macho => @fieldParentPtr(MachO, "base", base).freeDecl(decl),
            .c => @fieldParentPtr(C, "base", base).freeDecl(decl),
            .wasm => @fieldParentPtr(Wasm, "base", base).freeDecl(decl),
            .spirv => @fieldParentPtr(SpirV, "base", base).freeDecl(decl),
            .plan9 => @fieldParentPtr(Plan9, "base", base).freeDecl(decl),
        }
    }

    pub fn errorFlags(base: *File) ErrorFlags {
        switch (base.tag) {
            .coff => return @fieldParentPtr(Coff, "base", base).error_flags,
            .elf => return @fieldParentPtr(Elf, "base", base).error_flags,
            .macho => return @fieldParentPtr(MachO, "base", base).error_flags,
            .plan9 => return @fieldParentPtr(Plan9, "base", base).error_flags,
            .c => return .{ .no_entry_point_found = false },
            .wasm, .spirv => return ErrorFlags{},
        }
    }

    /// May be called before or after updateDecl, but must be called after
    /// allocateDeclIndexes for any given Decl.
    pub fn updateDeclExports(
        base: *File,
        module: *Module,
        decl: *Module.Decl,
        exports: []const *Module.Export,
    ) !void {
        log.debug("updateDeclExports {*} ({s})", .{ decl, decl.name });
        assert(decl.has_tv);
        switch (base.tag) {
            .coff => return @fieldParentPtr(Coff, "base", base).updateDeclExports(module, decl, exports),
            .elf => return @fieldParentPtr(Elf, "base", base).updateDeclExports(module, decl, exports),
            .macho => return @fieldParentPtr(MachO, "base", base).updateDeclExports(module, decl, exports),
            .c => return @fieldParentPtr(C, "base", base).updateDeclExports(module, decl, exports),
            .wasm => return @fieldParentPtr(Wasm, "base", base).updateDeclExports(module, decl, exports),
            .spirv => return @fieldParentPtr(SpirV, "base", base).updateDeclExports(module, decl, exports),
            .plan9 => return @fieldParentPtr(Plan9, "base", base).updateDeclExports(module, decl, exports),
        }
    }

    pub fn getDeclVAddr(base: *File, decl: *const Module.Decl) u64 {
        switch (base.tag) {
            .coff => return @fieldParentPtr(Coff, "base", base).getDeclVAddr(decl),
            .elf => return @fieldParentPtr(Elf, "base", base).getDeclVAddr(decl),
            .macho => return @fieldParentPtr(MachO, "base", base).getDeclVAddr(decl),
            .plan9 => @panic("GET VADDR"),
            .c => unreachable,
            .wasm => unreachable,
            .spirv => unreachable,
        }
    }

    fn linkAsArchive(base: *File, comp: *Compilation) !void {
        const tracy = trace(@src());
        defer tracy.end();

        var arena_allocator = std.heap.ArenaAllocator.init(base.allocator);
        defer arena_allocator.deinit();
        const arena = &arena_allocator.allocator;

        const directory = base.options.emit.?.directory; // Just an alias to make it shorter to type.

        // If there is no Zig code to compile, then we should skip flushing the output file because it
        // will not be part of the linker line anyway.
        const module_obj_path: ?[]const u8 = if (base.options.module) |module| blk: {
            const use_stage1 = build_options.is_stage1 and base.options.use_stage1;
            if (use_stage1) {
                const obj_basename = try std.zig.binNameAlloc(arena, .{
                    .root_name = base.options.root_name,
                    .target = base.options.target,
                    .output_mode = .Obj,
                });
                const o_directory = module.zig_cache_artifact_directory;
                const full_obj_path = try o_directory.join(arena, &[_][]const u8{obj_basename});
                break :blk full_obj_path;
            }
            try base.flushModule(comp);
            const obj_basename = base.intermediary_basename.?;
            const full_obj_path = try directory.join(arena, &[_][]const u8{obj_basename});
            break :blk full_obj_path;
        } else null;

        const compiler_rt_path: ?[]const u8 = if (base.options.include_compiler_rt)
            comp.compiler_rt_obj.?.full_object_path
        else
            null;

        // This function follows the same pattern as link.Elf.linkWithLLD so if you want some
        // insight as to what's going on here you can read that function body which is more
        // well-commented.

        const id_symlink_basename = "llvm-ar.id";

        var man: Cache.Manifest = undefined;
        defer if (!base.options.disable_lld_caching) man.deinit();

        var digest: [Cache.hex_digest_len]u8 = undefined;

        if (!base.options.disable_lld_caching) {
            man = comp.cache_parent.obtain();

            // We are about to obtain this lock, so here we give other processes a chance first.
            base.releaseLock();

            try man.addListOfFiles(base.options.objects);
            for (comp.c_object_table.keys()) |key| {
                _ = try man.addFile(key.status.success.object_path, null);
            }
            try man.addOptionalFile(module_obj_path);
            try man.addOptionalFile(compiler_rt_path);

            // We don't actually care whether it's a cache hit or miss; we just need the digest and the lock.
            _ = try man.hit();
            digest = man.final();

            var prev_digest_buf: [digest.len]u8 = undefined;
            const prev_digest: []u8 = Cache.readSmallFile(
                directory.handle,
                id_symlink_basename,
                &prev_digest_buf,
            ) catch |err| b: {
                log.debug("archive new_digest={s} readFile error: {s}", .{ std.fmt.fmtSliceHexLower(&digest), @errorName(err) });
                break :b prev_digest_buf[0..0];
            };
            if (mem.eql(u8, prev_digest, &digest)) {
                log.debug("archive digest={s} match - skipping invocation", .{std.fmt.fmtSliceHexLower(&digest)});
                base.lock = man.toOwnedLock();
                return;
            }

            // We are about to change the output file to be different, so we invalidate the build hash now.
            directory.handle.deleteFile(id_symlink_basename) catch |err| switch (err) {
                error.FileNotFound => {},
                else => |e| return e,
            };
        }

        var object_files = std.ArrayList([*:0]const u8).init(base.allocator);
        defer object_files.deinit();

        try object_files.ensureCapacity(base.options.objects.len + comp.c_object_table.count() + 2);
        for (base.options.objects) |obj_path| {
            object_files.appendAssumeCapacity(try arena.dupeZ(u8, obj_path));
        }
        for (comp.c_object_table.keys()) |key| {
            object_files.appendAssumeCapacity(try arena.dupeZ(u8, key.status.success.object_path));
        }
        if (module_obj_path) |p| {
            object_files.appendAssumeCapacity(try arena.dupeZ(u8, p));
        }
        if (compiler_rt_path) |p| {
            object_files.appendAssumeCapacity(try arena.dupeZ(u8, p));
        }

        const full_out_path = try directory.join(arena, &[_][]const u8{base.options.emit.?.sub_path});
        const full_out_path_z = try arena.dupeZ(u8, full_out_path);

        if (base.options.verbose_link) {
            std.debug.print("ar rcs {s}", .{full_out_path_z});
            for (object_files.items) |arg| {
                std.debug.print(" {s}", .{arg});
            }
            std.debug.print("\n", .{});
        }

        const llvm = @import("codegen/llvm/bindings.zig");
        const os_type = @import("target.zig").osToLLVM(base.options.target.os.tag);
        const bad = llvm.WriteArchive(full_out_path_z, object_files.items.ptr, object_files.items.len, os_type);
        if (bad) return error.UnableToWriteArchive;

        if (!base.options.disable_lld_caching) {
            Cache.writeSmallFile(directory.handle, id_symlink_basename, &digest) catch |err| {
                log.warn("failed to save archive hash digest file: {s}", .{@errorName(err)});
            };

            man.writeManifest() catch |err| {
                log.warn("failed to write cache manifest when archiving: {s}", .{@errorName(err)});
            };

            base.lock = man.toOwnedLock();
        }
    }

    pub const Tag = enum {
        coff,
        elf,
        macho,
        c,
        wasm,
        spirv,
        plan9,
    };

    pub const ErrorFlags = struct {
        no_entry_point_found: bool = false,
    };

    pub const C = @import("link/C.zig");
    pub const Coff = @import("link/Coff.zig");
    pub const Plan9 = @import("link/Plan9.zig");
    pub const Elf = @import("link/Elf.zig");
    pub const MachO = @import("link/MachO.zig");
    pub const SpirV = @import("link/SpirV.zig");
    pub const Wasm = @import("link/Wasm.zig");
};

pub fn determineMode(options: Options) fs.File.Mode {
    // On common systems with a 0o022 umask, 0o777 will still result in a file created
    // with 0o755 permissions, but it works appropriately if the system is configured
    // more leniently. As another data point, C's fopen seems to open files with the
    // 666 mode.
    const executable_mode = if (std.Target.current.os.tag == .windows) 0 else 0o777;
    switch (options.effectiveOutputMode()) {
        .Lib => return switch (options.link_mode) {
            .Dynamic => executable_mode,
            .Static => fs.File.default_mode,
        },
        .Exe => return executable_mode,
        .Obj => return fs.File.default_mode,
    }
}
