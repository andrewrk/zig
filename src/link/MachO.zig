const MachO = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const fmt = std.fmt;
const fs = std.fs;
const log = std.log.scoped(.link);
const macho = std.macho;
const codegen = @import("../codegen.zig");
const aarch64 = @import("../codegen/aarch64.zig");
const math = std.math;
const mem = std.mem;
const meta = std.meta;

const bind = @import("MachO/bind.zig");
const trace = @import("../tracy.zig").trace;
const build_options = @import("build_options");
const Module = @import("../Module.zig");
const Compilation = @import("../Compilation.zig");
const link = @import("../link.zig");
const File = link.File;
const Cache = @import("../Cache.zig");
const target_util = @import("../target.zig");
const Air = @import("../Air.zig");
const Liveness = @import("../Liveness.zig");

const DebugSymbols = @import("MachO/DebugSymbols.zig");
const Trie = @import("MachO/Trie.zig");
const CodeSignature = @import("MachO/CodeSignature.zig");
const Zld = @import("MachO/Zld.zig");

usingnamespace @import("MachO/commands.zig");

pub const base_tag: File.Tag = File.Tag.macho;

base: File,

/// Debug symbols bundle (or dSym).
d_sym: ?DebugSymbols = null,

/// Page size is dependent on the target cpu architecture.
/// For x86_64 that's 4KB, whereas for aarch64, that's 16KB.
page_size: u16,

/// Mach-O header
header: ?macho.mach_header_64 = null,
/// We commit 0x1000 = 4096 bytes of space to the header and
/// the table of load commands. This should be plenty for any
/// potential future extensions.
header_pad: u16 = 0x1000,

/// Table of all load commands
load_commands: std.ArrayListUnmanaged(LoadCommand) = .{},
/// __PAGEZERO segment
pagezero_segment_cmd_index: ?u16 = null,
/// __TEXT segment
text_segment_cmd_index: ?u16 = null,
/// __DATA_CONST segment
data_const_segment_cmd_index: ?u16 = null,
/// __DATA segment
data_segment_cmd_index: ?u16 = null,
/// __LINKEDIT segment
linkedit_segment_cmd_index: ?u16 = null,
/// Dyld info
dyld_info_cmd_index: ?u16 = null,
/// Symbol table
symtab_cmd_index: ?u16 = null,
/// Dynamic symbol table
dysymtab_cmd_index: ?u16 = null,
/// Path to dyld linker
dylinker_cmd_index: ?u16 = null,
/// Path to libSystem
libsystem_cmd_index: ?u16 = null,
/// Data-in-code section of __LINKEDIT segment
data_in_code_cmd_index: ?u16 = null,
/// Address to entry point function
function_starts_cmd_index: ?u16 = null,
/// Main/entry point
/// Specifies offset wrt __TEXT segment start address to the main entry point
/// of the binary.
main_cmd_index: ?u16 = null,
/// Minimum OS version
version_min_cmd_index: ?u16 = null,
/// Source version
source_version_cmd_index: ?u16 = null,
/// UUID load command
uuid_cmd_index: ?u16 = null,
/// Code signature
code_signature_cmd_index: ?u16 = null,

/// Index into __TEXT,__text section.
text_section_index: ?u16 = null,
/// Index into __TEXT,__stubs section.
stubs_section_index: ?u16 = null,
/// Index into __TEXT,__stub_helper section.
stub_helper_section_index: ?u16 = null,
/// Index into __DATA_CONST,__got section.
got_section_index: ?u16 = null,
/// Index into __DATA,__la_symbol_ptr section.
la_symbol_ptr_section_index: ?u16 = null,
/// Index into __DATA,__data section.
data_section_index: ?u16 = null,
/// The absolute address of the entry point.
entry_addr: ?u64 = null,

/// Table of all local symbols
/// Internally references string table for names (which are optional).
locals: std.ArrayListUnmanaged(macho.nlist_64) = .{},
/// Table of all global symbols
globals: std.ArrayListUnmanaged(macho.nlist_64) = .{},
/// Table of all extern nonlazy symbols, indexed by name.
nonlazy_imports: std.StringArrayHashMapUnmanaged(Import) = .{},
/// Table of all extern lazy symbols, indexed by name.
lazy_imports: std.StringArrayHashMapUnmanaged(Import) = .{},

locals_free_list: std.ArrayListUnmanaged(u32) = .{},
globals_free_list: std.ArrayListUnmanaged(u32) = .{},
offset_table_free_list: std.ArrayListUnmanaged(u32) = .{},

stub_helper_stubs_start_off: ?u64 = null,

/// Table of symbol names aka the string table.
string_table: std.ArrayListUnmanaged(u8) = .{},
string_table_directory: std.StringHashMapUnmanaged(u32) = .{},

/// Table of GOT entries.
offset_table: std.ArrayListUnmanaged(GOTEntry) = .{},

error_flags: File.ErrorFlags = File.ErrorFlags{},

offset_table_count_dirty: bool = false,
header_dirty: bool = false,
load_commands_dirty: bool = false,
rebase_info_dirty: bool = false,
binding_info_dirty: bool = false,
lazy_binding_info_dirty: bool = false,
export_info_dirty: bool = false,
string_table_dirty: bool = false,

string_table_needs_relocation: bool = false,

/// A list of text blocks that have surplus capacity. This list can have false
/// positives, as functions grow and shrink over time, only sometimes being added
/// or removed from the freelist.
///
/// A text block has surplus capacity when its overcapacity value is greater than
/// padToIdeal(minimum_text_block_size). That is, when it has so
/// much extra capacity, that we could fit a small new symbol in it, itself with
/// ideal_capacity or more.
///
/// Ideal capacity is defined by size + (size / ideal_factor).
///
/// Overcapacity is measured by actual_capacity - ideal_capacity. Note that
/// overcapacity can be negative. A simple way to have negative overcapacity is to
/// allocate a fresh text block, which will have ideal capacity, and then grow it
/// by 1 byte. It will then have -1 overcapacity.
text_block_free_list: std.ArrayListUnmanaged(*TextBlock) = .{},

/// Pointer to the last allocated text block
last_text_block: ?*TextBlock = null,

/// A list of all PIE fixups required for this run of the linker.
/// Warning, this is currently NOT thread-safe. See the TODO below.
/// TODO Move this list inside `updateDecl` where it should be allocated
/// prior to calling `generateSymbol`, and then immediately deallocated
/// rather than sitting in the global scope.
/// TODO We should also rewrite this using generic relocations common to all
/// backends.
pie_fixups: std.ArrayListUnmanaged(PIEFixup) = .{},

/// A list of all stub (extern decls) fixups required for this run of the linker.
/// Warning, this is currently NOT thread-safe. See the TODO below.
/// TODO Move this list inside `updateDecl` where it should be allocated
/// prior to calling `generateSymbol`, and then immediately deallocated
/// rather than sitting in the global scope.
stub_fixups: std.ArrayListUnmanaged(StubFixup) = .{},

pub const GOTEntry = struct {
    /// GOT entry can either be a local pointer or an extern (nonlazy) import.
    kind: enum {
        Local,
        Extern,
    },

    /// Id to the macho.nlist_64 from the respective table: either locals or nonlazy imports.
    /// TODO I'm more and more inclined to just manage a single, max two symbol tables
    ///  rather than 4 as we currently do, but I'll follow up in the future PR.
    symbol: u32,

    /// Index of this entry in the GOT.
    index: u32,
};

pub const Import = struct {
    /// MachO symbol table entry.
    symbol: macho.nlist_64,

    /// Id of the dynamic library where the specified entries can be found.
    dylib_ordinal: i64,

    /// Index of this import within the import list.
    index: u32,
};

pub const PIEFixup = struct {
    /// Target VM address of this relocation.
    target_addr: u64,

    /// Offset within the byte stream.
    offset: usize,

    /// Size of the relocation.
    size: usize,
};

pub const StubFixup = struct {
    /// Id of extern (lazy) symbol.
    symbol: u32,
    /// Signals whether the symbol has already been declared before. If so,
    /// then there is no need to rewrite the stub entry and related.
    already_defined: bool,
    /// Where in the byte stream we should perform the fixup.
    start: usize,
    /// The length of the byte stream. For x86_64, this will be
    /// variable. For aarch64, it will be fixed at 4 bytes.
    len: usize,
};

/// When allocating, the ideal_capacity is calculated by
/// actual_capacity + (actual_capacity / ideal_factor)
const ideal_factor = 2;

/// Default path to dyld
/// TODO instead of hardcoding it, we should probably look through some env vars and search paths
/// instead but this will do for now.
const DEFAULT_DYLD_PATH: [*:0]const u8 = "/usr/lib/dyld";

/// Default lib search path
/// TODO instead of hardcoding it, we should probably look through some env vars and search paths
/// instead but this will do for now.
const DEFAULT_LIB_SEARCH_PATH: []const u8 = "/usr/lib";

const LIB_SYSTEM_NAME: [*:0]const u8 = "System";
/// TODO we should search for libSystem and fail if it doesn't exist, instead of hardcoding it
const LIB_SYSTEM_PATH: [*:0]const u8 = DEFAULT_LIB_SEARCH_PATH ++ "/libSystem.B.dylib";

/// In order for a slice of bytes to be considered eligible to keep metadata pointing at
/// it as a possible place to put new symbols, it must have enough room for this many bytes
/// (plus extra for reserved capacity).
const minimum_text_block_size = 64;
const min_text_capacity = padToIdeal(minimum_text_block_size);

pub const TextBlock = struct {
    /// Each decl always gets a local symbol with the fully qualified name.
    /// The vaddr and size are found here directly.
    /// The file offset is found by computing the vaddr offset from the section vaddr
    /// the symbol references, and adding that to the file offset of the section.
    /// If this field is 0, it means the codegen size = 0 and there is no symbol or
    /// offset table entry.
    local_sym_index: u32,
    /// Index into offset table
    /// This field is undefined for symbols with size = 0.
    offset_table_index: u32,
    /// Size of this text block
    /// Unlike in Elf, we need to store the size of this symbol as part of
    /// the TextBlock since macho.nlist_64 lacks this information.
    size: u64,
    /// Points to the previous and next neighbours
    prev: ?*TextBlock,
    next: ?*TextBlock,

    /// Previous/next linked list pointers.
    /// This is the linked list node for this Decl's corresponding .debug_info tag.
    dbg_info_prev: ?*TextBlock,
    dbg_info_next: ?*TextBlock,
    /// Offset into .debug_info pointing to the tag for this Decl.
    dbg_info_off: u32,
    /// Size of the .debug_info tag for this Decl, not including padding.
    dbg_info_len: u32,

    pub const empty = TextBlock{
        .local_sym_index = 0,
        .offset_table_index = undefined,
        .size = 0,
        .prev = null,
        .next = null,
        .dbg_info_prev = null,
        .dbg_info_next = null,
        .dbg_info_off = undefined,
        .dbg_info_len = undefined,
    };

    /// Returns how much room there is to grow in virtual address space.
    /// File offset relocation happens transparently, so it is not included in
    /// this calculation.
    fn capacity(self: TextBlock, macho_file: MachO) u64 {
        const self_sym = macho_file.locals.items[self.local_sym_index];
        if (self.next) |next| {
            const next_sym = macho_file.locals.items[next.local_sym_index];
            return next_sym.n_value - self_sym.n_value;
        } else {
            // We are the last block.
            // The capacity is limited only by virtual address space.
            return std.math.maxInt(u64) - self_sym.n_value;
        }
    }

    fn freeListEligible(self: TextBlock, macho_file: MachO) bool {
        // No need to keep a free list node for the last block.
        const next = self.next orelse return false;
        const self_sym = macho_file.locals.items[self.local_sym_index];
        const next_sym = macho_file.locals.items[next.local_sym_index];
        const cap = next_sym.n_value - self_sym.n_value;
        const ideal_cap = padToIdeal(self.size);
        if (cap <= ideal_cap) return false;
        const surplus = cap - ideal_cap;
        return surplus >= min_text_capacity;
    }
};

pub const Export = struct {
    sym_index: ?u32 = null,
};

pub const SrcFn = struct {
    /// Offset from the beginning of the Debug Line Program header that contains this function.
    off: u32,
    /// Size of the line number program component belonging to this function, not
    /// including padding.
    len: u32,

    /// Points to the previous and next neighbors, based on the offset from .debug_line.
    /// This can be used to find, for example, the capacity of this `SrcFn`.
    prev: ?*SrcFn,
    next: ?*SrcFn,

    pub const empty: SrcFn = .{
        .off = 0,
        .len = 0,
        .prev = null,
        .next = null,
    };
};

pub fn openPath(allocator: *Allocator, sub_path: []const u8, options: link.Options) !*MachO {
    assert(options.object_format == .macho);

    if (options.use_llvm) return error.LLVM_BackendIsTODO_ForMachO; // TODO
    if (options.use_lld) return error.LLD_LinkingIsTODO_ForMachO; // TODO

    const file = try options.emit.?.directory.handle.createFile(sub_path, .{
        .truncate = false,
        .read = true,
        .mode = link.determineMode(options),
    });
    errdefer file.close();

    const self = try createEmpty(allocator, options);
    errdefer {
        self.base.file = null;
        self.base.destroy();
    }

    self.base.file = file;

    if (!options.strip and options.module != null) {
        // Create dSYM bundle.
        const dir = options.module.?.zig_cache_artifact_directory;
        log.debug("creating {s}.dSYM bundle in {s}", .{ sub_path, dir.path });

        const d_sym_path = try fmt.allocPrint(
            allocator,
            "{s}.dSYM" ++ fs.path.sep_str ++ "Contents" ++ fs.path.sep_str ++ "Resources" ++ fs.path.sep_str ++ "DWARF",
            .{sub_path},
        );
        defer allocator.free(d_sym_path);

        var d_sym_bundle = try dir.handle.makeOpenPath(d_sym_path, .{});
        defer d_sym_bundle.close();

        const d_sym_file = try d_sym_bundle.createFile(sub_path, .{
            .truncate = false,
            .read = true,
        });

        self.d_sym = .{
            .base = self,
            .file = d_sym_file,
        };
    }

    // Index 0 is always a null symbol.
    try self.locals.append(allocator, .{
        .n_strx = 0,
        .n_type = 0,
        .n_sect = 0,
        .n_desc = 0,
        .n_value = 0,
    });

    switch (options.output_mode) {
        .Exe => {},
        .Obj => {},
        .Lib => return error.TODOImplementWritingLibFiles,
    }

    try self.populateMissingMetadata();
    try self.writeLocalSymbol(0);

    if (self.d_sym) |*ds| {
        try ds.populateMissingMetadata(allocator);
        try ds.writeLocalSymbol(0);
    }

    return self;
}

pub fn createEmpty(gpa: *Allocator, options: link.Options) !*MachO {
    const self = try gpa.create(MachO);
    self.* = .{
        .base = .{
            .tag = .macho,
            .options = options,
            .allocator = gpa,
            .file = null,
        },
        .page_size = if (options.target.cpu.arch == .aarch64) 0x4000 else 0x1000,
    };
    return self;
}

pub fn flush(self: *MachO, comp: *Compilation) !void {
    if (build_options.have_llvm and self.base.options.use_lld) {
        return self.linkWithZld(comp);
    } else {
        switch (self.base.options.effectiveOutputMode()) {
            .Exe, .Obj => {},
            .Lib => return error.TODOImplementWritingLibFiles,
        }
        return self.flushModule(comp);
    }
}

pub fn flushModule(self: *MachO, comp: *Compilation) !void {
    _ = comp;
    const tracy = trace(@src());
    defer tracy.end();

    const output_mode = self.base.options.output_mode;
    const target = self.base.options.target;

    switch (output_mode) {
        .Exe => {
            if (self.entry_addr) |addr| {
                // Update LC_MAIN with entry offset.
                const text_segment = self.load_commands.items[self.text_segment_cmd_index.?].Segment;
                const main_cmd = &self.load_commands.items[self.main_cmd_index.?].Main;
                main_cmd.entryoff = addr - text_segment.inner.vmaddr;
                main_cmd.stacksize = self.base.options.stack_size_override orelse 0;
                self.load_commands_dirty = true;
            }
            try self.writeRebaseInfoTable();
            try self.writeBindingInfoTable();
            try self.writeLazyBindingInfoTable();
            try self.writeExportTrie();
            try self.writeAllGlobalAndUndefSymbols();
            try self.writeIndirectSymbolTable();
            try self.writeStringTable();
            try self.updateLinkeditSegmentSizes();

            if (self.d_sym) |*ds| {
                // Flush debug symbols bundle.
                try ds.flushModule(self.base.allocator, self.base.options);
            }

            if (target.cpu.arch == .aarch64) {
                // Preallocate space for the code signature.
                // We need to do this at this stage so that we have the load commands with proper values
                // written out to the file.
                // The most important here is to have the correct vm and filesize of the __LINKEDIT segment
                // where the code signature goes into.
                try self.writeCodeSignaturePadding();
            }
        },
        .Obj => {},
        .Lib => return error.TODOImplementWritingLibFiles,
    }

    try self.writeLoadCommands();
    try self.writeHeader();

    if (self.entry_addr == null and self.base.options.output_mode == .Exe) {
        log.debug("flushing. no_entry_point_found = true", .{});
        self.error_flags.no_entry_point_found = true;
    } else {
        log.debug("flushing. no_entry_point_found = false", .{});
        self.error_flags.no_entry_point_found = false;
    }

    assert(!self.offset_table_count_dirty);
    assert(!self.header_dirty);
    assert(!self.load_commands_dirty);
    assert(!self.rebase_info_dirty);
    assert(!self.binding_info_dirty);
    assert(!self.lazy_binding_info_dirty);
    assert(!self.export_info_dirty);
    assert(!self.string_table_dirty);
    assert(!self.string_table_needs_relocation);

    if (target.cpu.arch == .aarch64) {
        switch (output_mode) {
            .Exe, .Lib => try self.writeCodeSignature(), // code signing always comes last
            else => {},
        }
    }
}

fn resolveSearchDir(
    arena: *Allocator,
    dir: []const u8,
    syslibroot: ?[]const u8,
) !?[]const u8 {
    var candidates = std.ArrayList([]const u8).init(arena);

    if (fs.path.isAbsolute(dir)) {
        if (syslibroot) |root| {
            const full_path = try fs.path.join(arena, &[_][]const u8{ root, dir });
            try candidates.append(full_path);
        }
    }

    try candidates.append(dir);

    for (candidates.items) |candidate| {
        // Verify that search path actually exists
        var tmp = fs.cwd().openDir(candidate, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |e| return e,
        };
        defer tmp.close();

        return candidate;
    }

    return null;
}

fn resolveLib(
    arena: *Allocator,
    search_dirs: []const []const u8,
    name: []const u8,
    ext: []const u8,
) !?[]const u8 {
    const search_name = try std.fmt.allocPrint(arena, "lib{s}{s}", .{ name, ext });

    for (search_dirs) |dir| {
        const full_path = try fs.path.join(arena, &[_][]const u8{ dir, search_name });

        // Check if the file exists.
        const tmp = fs.cwd().openFile(full_path, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |e| return e,
        };
        defer tmp.close();

        return full_path;
    }

    return null;
}

fn resolveFramework(
    arena: *Allocator,
    search_dirs: []const []const u8,
    name: []const u8,
    ext: []const u8,
) !?[]const u8 {
    const search_name = try std.fmt.allocPrint(arena, "{s}{s}", .{ name, ext });
    const prefix_path = try std.fmt.allocPrint(arena, "{s}.framework", .{name});

    for (search_dirs) |dir| {
        const full_path = try fs.path.join(arena, &[_][]const u8{ dir, prefix_path, search_name });

        // Check if the file exists.
        const tmp = fs.cwd().openFile(full_path, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |e| return e,
        };
        defer tmp.close();

        return full_path;
    }

    return null;
}

fn linkWithZld(self: *MachO, comp: *Compilation) !void {
    const tracy = trace(@src());
    defer tracy.end();

    var arena_allocator = std.heap.ArenaAllocator.init(self.base.allocator);
    defer arena_allocator.deinit();
    const arena = &arena_allocator.allocator;

    const directory = self.base.options.emit.?.directory; // Just an alias to make it shorter to type.

    // If there is no Zig code to compile, then we should skip flushing the output file because it
    // will not be part of the linker line anyway.
    const module_obj_path: ?[]const u8 = if (self.base.options.module) |module| blk: {
        const use_stage1 = build_options.is_stage1 and self.base.options.use_stage1;
        if (use_stage1) {
            const obj_basename = try std.zig.binNameAlloc(arena, .{
                .root_name = self.base.options.root_name,
                .target = self.base.options.target,
                .output_mode = .Obj,
            });
            const o_directory = module.zig_cache_artifact_directory;
            const full_obj_path = try o_directory.join(arena, &[_][]const u8{obj_basename});
            break :blk full_obj_path;
        }

        try self.flushModule(comp);
        const obj_basename = self.base.intermediary_basename.?;
        const full_obj_path = try directory.join(arena, &[_][]const u8{obj_basename});
        break :blk full_obj_path;
    } else null;

    const is_lib = self.base.options.output_mode == .Lib;
    const is_dyn_lib = self.base.options.link_mode == .Dynamic and is_lib;
    const is_exe_or_dyn_lib = is_dyn_lib or self.base.options.output_mode == .Exe;
    const target = self.base.options.target;
    const stack_size = self.base.options.stack_size_override orelse 0;
    const allow_shlib_undefined = self.base.options.allow_shlib_undefined orelse !self.base.options.is_native_os;

    const id_symlink_basename = "zld.id";

    var man: Cache.Manifest = undefined;
    defer if (!self.base.options.disable_lld_caching) man.deinit();

    var digest: [Cache.hex_digest_len]u8 = undefined;

    if (!self.base.options.disable_lld_caching) {
        man = comp.cache_parent.obtain();

        // We are about to obtain this lock, so here we give other processes a chance first.
        self.base.releaseLock();

        try man.addOptionalFile(self.base.options.linker_script);
        try man.addOptionalFile(self.base.options.version_script);
        try man.addListOfFiles(self.base.options.objects);
        for (comp.c_object_table.keys()) |key| {
            _ = try man.addFile(key.status.success.object_path, null);
        }
        try man.addOptionalFile(module_obj_path);
        // We can skip hashing libc and libc++ components that we are in charge of building from Zig
        // installation sources because they are always a product of the compiler version + target information.
        man.hash.add(stack_size);
        man.hash.add(self.base.options.rdynamic);
        man.hash.addListOfBytes(self.base.options.extra_lld_args);
        man.hash.addListOfBytes(self.base.options.lib_dirs);
        man.hash.addListOfBytes(self.base.options.framework_dirs);
        man.hash.addListOfBytes(self.base.options.frameworks);
        man.hash.addListOfBytes(self.base.options.rpath_list);
        man.hash.add(self.base.options.skip_linker_dependencies);
        man.hash.add(self.base.options.z_nodelete);
        man.hash.add(self.base.options.z_defs);
        if (is_dyn_lib) {
            man.hash.addOptional(self.base.options.version);
        }
        man.hash.addStringSet(self.base.options.system_libs);
        man.hash.add(allow_shlib_undefined);
        man.hash.add(self.base.options.bind_global_refs_locally);
        man.hash.addOptionalBytes(self.base.options.sysroot);

        // We don't actually care whether it's a cache hit or miss; we just need the digest and the lock.
        _ = try man.hit();
        digest = man.final();

        var prev_digest_buf: [digest.len]u8 = undefined;
        const prev_digest: []u8 = Cache.readSmallFile(
            directory.handle,
            id_symlink_basename,
            &prev_digest_buf,
        ) catch |err| blk: {
            log.debug("MachO Zld new_digest={s} error: {s}", .{ std.fmt.fmtSliceHexLower(&digest), @errorName(err) });
            // Handle this as a cache miss.
            break :blk prev_digest_buf[0..0];
        };
        if (mem.eql(u8, prev_digest, &digest)) {
            log.debug("MachO Zld digest={s} match - skipping invocation", .{std.fmt.fmtSliceHexLower(&digest)});
            // Hot diggity dog! The output binary is already there.
            self.base.lock = man.toOwnedLock();
            return;
        }
        log.debug("MachO Zld prev_digest={s} new_digest={s}", .{ std.fmt.fmtSliceHexLower(prev_digest), std.fmt.fmtSliceHexLower(&digest) });

        // We are about to change the output file to be different, so we invalidate the build hash now.
        directory.handle.deleteFile(id_symlink_basename) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        };
    }

    const full_out_path = try directory.join(arena, &[_][]const u8{self.base.options.emit.?.sub_path});

    if (self.base.options.output_mode == .Obj) {
        // LLD's MachO driver does not support the equvialent of `-r` so we do a simple file copy
        // here. TODO: think carefully about how we can avoid this redundant operation when doing
        // build-obj. See also the corresponding TODO in linkAsArchive.
        const the_object_path = blk: {
            if (self.base.options.objects.len != 0)
                break :blk self.base.options.objects[0];

            if (comp.c_object_table.count() != 0)
                break :blk comp.c_object_table.keys()[0].status.success.object_path;

            if (module_obj_path) |p|
                break :blk p;

            // TODO I think this is unreachable. Audit this situation when solving the above TODO
            // regarding eliding redundant object -> object transformations.
            return error.NoObjectsToLink;
        };
        // This can happen when using --enable-cache and using the stage1 backend. In this case
        // we can skip the file copy.
        if (!mem.eql(u8, the_object_path, full_out_path)) {
            try fs.cwd().copyFile(the_object_path, fs.cwd(), full_out_path, .{});
        }
    } else {
        var zld = Zld.init(self.base.allocator);
        defer {
            zld.closeFiles();
            zld.deinit();
        }
        zld.target = target;
        zld.stack_size = stack_size;

        // Positional arguments to the linker such as object files and static archives.
        var positionals = std.ArrayList([]const u8).init(arena);

        try positionals.appendSlice(self.base.options.objects);

        for (comp.c_object_table.keys()) |key| {
            try positionals.append(key.status.success.object_path);
        }

        if (module_obj_path) |p| {
            try positionals.append(p);
        }

        try positionals.append(comp.compiler_rt_static_lib.?.full_object_path);

        // libc++ dep
        if (self.base.options.link_libcpp) {
            try positionals.append(comp.libcxxabi_static_lib.?.full_object_path);
            try positionals.append(comp.libcxx_static_lib.?.full_object_path);
        }

        // Shared and static libraries passed via `-l` flag.
        var search_lib_names = std.ArrayList([]const u8).init(arena);

        const system_libs = self.base.options.system_libs.keys();
        for (system_libs) |link_lib| {
            // By this time, we depend on these libs being dynamically linked libraries and not static libraries
            // (the check for that needs to be earlier), but they could be full paths to .dylib files, in which
            // case we want to avoid prepending "-l".
            if (Compilation.classifyFileExt(link_lib) == .shared_library) {
                try positionals.append(link_lib);
                continue;
            }

            try search_lib_names.append(link_lib);
        }

        var lib_dirs = std.ArrayList([]const u8).init(arena);
        for (self.base.options.lib_dirs) |dir| {
            if (try resolveSearchDir(arena, dir, self.base.options.sysroot)) |search_dir| {
                try lib_dirs.append(search_dir);
            } else {
                log.warn("directory not found for '-L{s}'", .{dir});
            }
        }

        var libs = std.ArrayList([]const u8).init(arena);
        var lib_not_found = false;
        for (search_lib_names.items) |lib_name| {
            // Assume ld64 default: -search_paths_first
            // Look in each directory for a dylib (stub first), and then for archive
            // TODO implement alternative: -search_dylibs_first
            for (&[_][]const u8{ ".tbd", ".dylib", ".a" }) |ext| {
                if (try resolveLib(arena, lib_dirs.items, lib_name, ext)) |full_path| {
                    try libs.append(full_path);
                    break;
                }
            } else {
                log.warn("library not found for '-l{s}'", .{lib_name});
                lib_not_found = true;
            }
        }

        if (lib_not_found) {
            log.warn("Library search paths:", .{});
            for (lib_dirs.items) |dir| {
                log.warn("  {s}", .{dir});
            }
        }

        // If we're compiling native and we can find libSystem.B.{dylib, tbd},
        // we link against that instead of embedded libSystem.B.tbd file.
        var native_libsystem_available = false;
        if (self.base.options.is_native_os) blk: {
            // Try stub file first. If we hit it, then we're done as the stub file
            // re-exports every single symbol definition.
            if (try resolveLib(arena, lib_dirs.items, "System", ".tbd")) |full_path| {
                try libs.append(full_path);
                native_libsystem_available = true;
                break :blk;
            }
            // If we didn't hit the stub file, try .dylib next. However, libSystem.dylib
            // doesn't export libc.dylib which we'll need to resolve subsequently also.
            if (try resolveLib(arena, lib_dirs.items, "System", ".dylib")) |libsystem_path| {
                if (try resolveLib(arena, lib_dirs.items, "c", ".dylib")) |libc_path| {
                    try libs.append(libsystem_path);
                    try libs.append(libc_path);
                    native_libsystem_available = true;
                    break :blk;
                }
            }
        }
        if (!native_libsystem_available) {
            const full_path = try comp.zig_lib_directory.join(arena, &[_][]const u8{
                "libc", "darwin", "libSystem.B.tbd",
            });
            try libs.append(full_path);
        }

        // frameworks
        var framework_dirs = std.ArrayList([]const u8).init(arena);
        for (self.base.options.framework_dirs) |dir| {
            if (try resolveSearchDir(arena, dir, self.base.options.sysroot)) |search_dir| {
                try framework_dirs.append(search_dir);
            } else {
                log.warn("directory not found for '-F{s}'", .{dir});
            }
        }

        var framework_not_found = false;
        for (self.base.options.frameworks) |framework| {
            for (&[_][]const u8{ ".tbd", ".dylib", "" }) |ext| {
                if (try resolveFramework(arena, framework_dirs.items, framework, ext)) |full_path| {
                    try libs.append(full_path);
                    break;
                }
            } else {
                log.warn("framework not found for '-f{s}'", .{framework});
                framework_not_found = true;
            }
        }

        if (framework_not_found) {
            log.warn("Framework search paths:", .{});
            for (framework_dirs.items) |dir| {
                log.warn("  {s}", .{dir});
            }
        }

        // rpaths
        var rpath_table = std.StringArrayHashMap(void).init(arena);
        for (self.base.options.rpath_list) |rpath| {
            if (rpath_table.contains(rpath)) continue;
            try rpath_table.putNoClobber(rpath, {});
        }

        var rpaths = std.ArrayList([]const u8).init(arena);
        try rpaths.ensureCapacity(rpath_table.count());
        for (rpath_table.keys()) |*key| {
            rpaths.appendAssumeCapacity(key.*);
        }

        const output: Zld.Output = output: {
            if (is_dyn_lib) {
                const install_name = try std.fmt.allocPrint(arena, "@rpath/{s}", .{
                    self.base.options.emit.?.sub_path,
                });
                break :output .{
                    .tag = .dylib,
                    .path = full_out_path,
                    .install_name = install_name,
                };
            }
            break :output .{
                .tag = .exe,
                .path = full_out_path,
            };
        };

        if (self.base.options.verbose_link) {
            var argv = std.ArrayList([]const u8).init(arena);

            try argv.append("zig");
            try argv.append("ld");

            if (is_exe_or_dyn_lib) {
                try argv.append("-dynamic");
            }

            if (is_dyn_lib) {
                try argv.append("-dylib");

                try argv.append("-install_name");
                try argv.append(output.install_name.?);
            }

            if (self.base.options.sysroot) |syslibroot| {
                try argv.append("-syslibroot");
                try argv.append(syslibroot);
            }

            for (rpaths.items) |rpath| {
                try argv.append("-rpath");
                try argv.append(rpath);
            }

            try argv.appendSlice(positionals.items);

            try argv.append("-o");
            try argv.append(output.path);

            if (native_libsystem_available) {
                try argv.append("-lSystem");
                try argv.append("-lc");
            }

            for (search_lib_names.items) |l_name| {
                try argv.append(try std.fmt.allocPrint(arena, "-l{s}", .{l_name}));
            }

            for (self.base.options.lib_dirs) |lib_dir| {
                try argv.append(try std.fmt.allocPrint(arena, "-L{s}", .{lib_dir}));
            }

            Compilation.dump_argv(argv.items);
        }

        try zld.link(positionals.items, output, .{
            .syslibroot = self.base.options.sysroot,
            .libs = libs.items,
            .rpaths = rpaths.items,
        });
    }

    if (!self.base.options.disable_lld_caching) {
        // Update the file with the digest. If it fails we can continue; it only
        // means that the next invocation will have an unnecessary cache miss.
        Cache.writeSmallFile(directory.handle, id_symlink_basename, &digest) catch |err| {
            log.warn("failed to save linking hash digest file: {s}", .{@errorName(err)});
        };
        // Again failure here only means an unnecessary cache miss.
        man.writeManifest() catch |err| {
            log.warn("failed to write cache manifest when linking: {s}", .{@errorName(err)});
        };
        // We hang on to this lock so that the output file path can be used without
        // other processes clobbering it.
        self.base.lock = man.toOwnedLock();
    }
}

fn darwinArchString(arch: std.Target.Cpu.Arch) []const u8 {
    return switch (arch) {
        .aarch64, .aarch64_be, .aarch64_32 => "arm64",
        .thumb, .arm => "arm",
        .thumbeb, .armeb => "armeb",
        .powerpc => "ppc",
        .powerpc64 => "ppc64",
        .powerpc64le => "ppc64le",
        else => @tagName(arch),
    };
}

pub fn deinit(self: *MachO) void {
    if (self.d_sym) |*ds| {
        ds.deinit(self.base.allocator);
    }
    for (self.lazy_imports.keys()) |*key| {
        self.base.allocator.free(key.*);
    }
    self.lazy_imports.deinit(self.base.allocator);
    for (self.nonlazy_imports.keys()) |*key| {
        self.base.allocator.free(key.*);
    }
    self.nonlazy_imports.deinit(self.base.allocator);
    self.pie_fixups.deinit(self.base.allocator);
    self.stub_fixups.deinit(self.base.allocator);
    self.text_block_free_list.deinit(self.base.allocator);
    self.offset_table.deinit(self.base.allocator);
    self.offset_table_free_list.deinit(self.base.allocator);
    {
        var it = self.string_table_directory.keyIterator();
        while (it.next()) |key| {
            self.base.allocator.free(key.*);
        }
    }
    self.string_table_directory.deinit(self.base.allocator);
    self.string_table.deinit(self.base.allocator);
    self.globals.deinit(self.base.allocator);
    self.globals_free_list.deinit(self.base.allocator);
    self.locals.deinit(self.base.allocator);
    self.locals_free_list.deinit(self.base.allocator);
    for (self.load_commands.items) |*lc| {
        lc.deinit(self.base.allocator);
    }
    self.load_commands.deinit(self.base.allocator);
}

fn freeTextBlock(self: *MachO, text_block: *TextBlock) void {
    var already_have_free_list_node = false;
    {
        var i: usize = 0;
        // TODO turn text_block_free_list into a hash map
        while (i < self.text_block_free_list.items.len) {
            if (self.text_block_free_list.items[i] == text_block) {
                _ = self.text_block_free_list.swapRemove(i);
                continue;
            }
            if (self.text_block_free_list.items[i] == text_block.prev) {
                already_have_free_list_node = true;
            }
            i += 1;
        }
    }
    // TODO process free list for dbg info just like we do above for vaddrs

    if (self.last_text_block == text_block) {
        // TODO shrink the __text section size here
        self.last_text_block = text_block.prev;
    }
    if (self.d_sym) |*ds| {
        if (ds.dbg_info_decl_first == text_block) {
            ds.dbg_info_decl_first = text_block.dbg_info_next;
        }
        if (ds.dbg_info_decl_last == text_block) {
            // TODO shrink the .debug_info section size here
            ds.dbg_info_decl_last = text_block.dbg_info_prev;
        }
    }

    if (text_block.prev) |prev| {
        prev.next = text_block.next;

        if (!already_have_free_list_node and prev.freeListEligible(self.*)) {
            // The free list is heuristics, it doesn't have to be perfect, so we can ignore
            // the OOM here.
            self.text_block_free_list.append(self.base.allocator, prev) catch {};
        }
    } else {
        text_block.prev = null;
    }

    if (text_block.next) |next| {
        next.prev = text_block.prev;
    } else {
        text_block.next = null;
    }

    if (text_block.dbg_info_prev) |prev| {
        prev.dbg_info_next = text_block.dbg_info_next;

        // TODO the free list logic like we do for text blocks above
    } else {
        text_block.dbg_info_prev = null;
    }

    if (text_block.dbg_info_next) |next| {
        next.dbg_info_prev = text_block.dbg_info_prev;
    } else {
        text_block.dbg_info_next = null;
    }
}

fn shrinkTextBlock(self: *MachO, text_block: *TextBlock, new_block_size: u64) void {
    _ = self;
    _ = text_block;
    _ = new_block_size;
    // TODO check the new capacity, and if it crosses the size threshold into a big enough
    // capacity, insert a free list node for it.
}

fn growTextBlock(self: *MachO, text_block: *TextBlock, new_block_size: u64, alignment: u64) !u64 {
    const sym = self.locals.items[text_block.local_sym_index];
    const align_ok = mem.alignBackwardGeneric(u64, sym.n_value, alignment) == sym.n_value;
    const need_realloc = !align_ok or new_block_size > text_block.capacity(self.*);
    if (!need_realloc) return sym.n_value;
    return self.allocateTextBlock(text_block, new_block_size, alignment);
}

pub fn allocateDeclIndexes(self: *MachO, decl: *Module.Decl) !void {
    if (decl.link.macho.local_sym_index != 0) return;

    try self.locals.ensureCapacity(self.base.allocator, self.locals.items.len + 1);
    try self.offset_table.ensureCapacity(self.base.allocator, self.offset_table.items.len + 1);

    if (self.locals_free_list.popOrNull()) |i| {
        log.debug("reusing symbol index {d} for {s}", .{ i, decl.name });
        decl.link.macho.local_sym_index = i;
    } else {
        log.debug("allocating symbol index {d} for {s}", .{ self.locals.items.len, decl.name });
        decl.link.macho.local_sym_index = @intCast(u32, self.locals.items.len);
        _ = self.locals.addOneAssumeCapacity();
    }

    if (self.offset_table_free_list.popOrNull()) |i| {
        log.debug("reusing offset table entry index {d} for {s}", .{ i, decl.name });
        decl.link.macho.offset_table_index = i;
    } else {
        log.debug("allocating offset table entry index {d} for {s}", .{ self.offset_table.items.len, decl.name });
        decl.link.macho.offset_table_index = @intCast(u32, self.offset_table.items.len);
        _ = self.offset_table.addOneAssumeCapacity();
        self.offset_table_count_dirty = true;
        self.rebase_info_dirty = true;
    }

    self.locals.items[decl.link.macho.local_sym_index] = .{
        .n_strx = 0,
        .n_type = 0,
        .n_sect = 0,
        .n_desc = 0,
        .n_value = 0,
    };
    self.offset_table.items[decl.link.macho.offset_table_index] = .{
        .kind = .Local,
        .symbol = decl.link.macho.local_sym_index,
        .index = decl.link.macho.offset_table_index,
    };
}

pub fn updateFunc(self: *MachO, module: *Module, func: *Module.Fn, air: Air, liveness: Liveness) !void {
    if (build_options.skip_non_native and builtin.object_format != .macho) {
        @panic("Attempted to compile for object format that was disabled by build configuration");
    }
    if (build_options.have_llvm) {
        if (self.llvm_object) |llvm_object| return llvm_object.updateFunc(module, func, air, liveness);
    }
    const tracy = trace(@src());
    defer tracy.end();

    const decl = func.owner_decl;

    var code_buffer = std.ArrayList(u8).init(self.base.allocator);
    defer code_buffer.deinit();

    var debug_buffers = if (self.d_sym) |*ds| try ds.initDeclDebugBuffers(self.base.allocator, module, decl) else null;
    defer {
        if (debug_buffers) |*dbg| {
            dbg.dbg_line_buffer.deinit();
            dbg.dbg_info_buffer.deinit();
            var it = dbg.dbg_info_type_relocs.valueIterator();
            while (it.next()) |value| {
                value.relocs.deinit(self.base.allocator);
            }
            dbg.dbg_info_type_relocs.deinit(self.base.allocator);
        }
    }

    const res = if (debug_buffers) |*dbg|
        try codegen.generateFunction(&self.base, decl.srcLoc(), func, air, liveness, &code_buffer, .{
            .dwarf = .{
                .dbg_line = &dbg.dbg_line_buffer,
                .dbg_info = &dbg.dbg_info_buffer,
                .dbg_info_type_relocs = &dbg.dbg_info_type_relocs,
            },
        })
    else
        try codegen.generateSymbol(&self.base, decl.srcLoc(), func, air, liveness, &code_buffer, .none);

    return self.finishUpdateDecl(module, decl, res);
}

pub fn updateDecl(self: *MachO, module: *Module, decl: *Module.Decl) !void {
    if (build_options.skip_non_native and builtin.object_format != .macho) {
        @panic("Attempted to compile for object format that was disabled by build configuration");
    }
    if (build_options.have_llvm) {
        if (self.llvm_object) |llvm_object| return llvm_object.updateDecl(module, decl);
    }
    const tracy = trace(@src());
    defer tracy.end();

    if (decl.val.tag() == .extern_fn) {
        return; // TODO Should we do more when front-end analyzed extern decl?
    }

    var code_buffer = std.ArrayList(u8).init(self.base.allocator);
    defer code_buffer.deinit();

    var debug_buffers = if (self.d_sym) |*ds| try ds.initDeclDebugBuffers(self.base.allocator, module, decl) else null;
    defer {
        if (debug_buffers) |*dbg| {
            dbg.dbg_line_buffer.deinit();
            dbg.dbg_info_buffer.deinit();
            var it = dbg.dbg_info_type_relocs.valueIterator();
            while (it.next()) |value| {
                value.relocs.deinit(self.base.allocator);
            }
            dbg.dbg_info_type_relocs.deinit(self.base.allocator);
        }
    }

    const res = if (debug_buffers) |*dbg|
        try codegen.generateSymbol(&self.base, decl.srcLoc(), .{
            .ty = decl.ty,
            .val = decl.val,
        }, &code_buffer, .{
            .dwarf = .{
                .dbg_line = &dbg.dbg_line_buffer,
                .dbg_info = &dbg.dbg_info_buffer,
                .dbg_info_type_relocs = &dbg.dbg_info_type_relocs,
            },
        })
    else
        try codegen.generateSymbol(&self.base, decl.srcLoc(), .{
            .ty = decl.ty,
            .val = decl.val,
        }, &code_buffer, .none);

    return self.finishUpdateDecl(module, decl, res);
}

fn finishUpdateDecl(self: *MachO, module: *Module, decl: *Module.Decl, res: codegen.Result) !void {
    const code = switch (res) {
        .externally_managed => |x| x,
        .appended => code_buffer.items,
        .fail => |em| {
            // Clear any PIE fixups for this decl.
            self.pie_fixups.shrinkRetainingCapacity(0);
            // Clear any stub fixups for this decl.
            self.stub_fixups.shrinkRetainingCapacity(0);
            decl.analysis = .codegen_failure;
            try module.failed_decls.put(module.gpa, decl, em);
            return;
        },
    };

    const required_alignment = decl.ty.abiAlignment(self.base.options.target);
    assert(decl.link.macho.local_sym_index != 0); // Caller forgot to call allocateDeclIndexes()
    const symbol = &self.locals.items[decl.link.macho.local_sym_index];

    if (decl.link.macho.size != 0) {
        const capacity = decl.link.macho.capacity(self.*);
        const need_realloc = code.len > capacity or !mem.isAlignedGeneric(u64, symbol.n_value, required_alignment);
        if (need_realloc) {
            const vaddr = try self.growTextBlock(&decl.link.macho, code.len, required_alignment);

            log.debug("growing {s} and moving from 0x{x} to 0x{x}", .{ decl.name, symbol.n_value, vaddr });

            if (vaddr != symbol.n_value) {
                log.debug(" (writing new offset table entry)", .{});
                self.offset_table.items[decl.link.macho.offset_table_index] = .{
                    .kind = .Local,
                    .symbol = decl.link.macho.local_sym_index,
                    .index = decl.link.macho.offset_table_index,
                };
                try self.writeOffsetTableEntry(decl.link.macho.offset_table_index);
            }

            symbol.n_value = vaddr;
        } else if (code.len < decl.link.macho.size) {
            self.shrinkTextBlock(&decl.link.macho, code.len);
        }
        decl.link.macho.size = code.len;

        const new_name = try std.fmt.allocPrint(self.base.allocator, "_{s}", .{mem.spanZ(decl.name)});
        defer self.base.allocator.free(new_name);

        symbol.n_strx = try self.updateString(symbol.n_strx, new_name);
        symbol.n_type = macho.N_SECT;
        symbol.n_sect = @intCast(u8, self.text_section_index.?) + 1;
        symbol.n_desc = 0;

        try self.writeLocalSymbol(decl.link.macho.local_sym_index);
        if (self.d_sym) |*ds|
            try ds.writeLocalSymbol(decl.link.macho.local_sym_index);
    } else {
        const decl_name = try std.fmt.allocPrint(self.base.allocator, "_{s}", .{mem.spanZ(decl.name)});
        defer self.base.allocator.free(decl_name);

        const name_str_index = try self.makeString(decl_name);
        const addr = try self.allocateTextBlock(&decl.link.macho, code.len, required_alignment);

        log.debug("allocated text block for {s} at 0x{x}", .{ decl_name, addr });

        errdefer self.freeTextBlock(&decl.link.macho);

        symbol.* = .{
            .n_strx = name_str_index,
            .n_type = macho.N_SECT,
            .n_sect = @intCast(u8, self.text_section_index.?) + 1,
            .n_desc = 0,
            .n_value = addr,
        };
        self.offset_table.items[decl.link.macho.offset_table_index] = .{
            .kind = .Local,
            .symbol = decl.link.macho.local_sym_index,
            .index = decl.link.macho.offset_table_index,
        };

        try self.writeLocalSymbol(decl.link.macho.local_sym_index);
        if (self.d_sym) |*ds|
            try ds.writeLocalSymbol(decl.link.macho.local_sym_index);
        try self.writeOffsetTableEntry(decl.link.macho.offset_table_index);
    }

    // Calculate displacements to target addr (if any).
    while (self.pie_fixups.popOrNull()) |fixup| {
        assert(fixup.size == 4);
        const this_addr = symbol.n_value + fixup.offset;
        const target_addr = fixup.target_addr;

        switch (self.base.options.target.cpu.arch) {
            .x86_64 => {
                const displacement = try math.cast(u32, target_addr - this_addr - 4);
                mem.writeIntLittle(u32, code_buffer.items[fixup.offset..][0..4], displacement);
            },
            .aarch64 => {
                // TODO optimize instruction based on jump length (use ldr(literal) + nop if possible).
                {
                    const inst = code_buffer.items[fixup.offset..][0..4];
                    var parsed = mem.bytesAsValue(meta.TagPayload(
                        aarch64.Instruction,
                        aarch64.Instruction.pc_relative_address,
                    ), inst);
                    const this_page = @intCast(i32, this_addr >> 12);
                    const target_page = @intCast(i32, target_addr >> 12);
                    const pages = @bitCast(u21, @intCast(i21, target_page - this_page));
                    parsed.immhi = @truncate(u19, pages >> 2);
                    parsed.immlo = @truncate(u2, pages);
                }
                {
                    const inst = code_buffer.items[fixup.offset + 4 ..][0..4];
                    var parsed = mem.bytesAsValue(meta.TagPayload(
                        aarch64.Instruction,
                        aarch64.Instruction.load_store_register,
                    ), inst);
                    const narrowed = @truncate(u12, target_addr);
                    const offset = try math.divExact(u12, narrowed, 8);
                    parsed.offset = offset;
                }
            },
            else => unreachable, // unsupported target architecture
        }
    }

    // Resolve stubs (if any)
    const text_segment = self.load_commands.items[self.text_segment_cmd_index.?].Segment;
    const stubs = text_segment.sections.items[self.stubs_section_index.?];
    for (self.stub_fixups.items) |fixup| {
        const stub_addr = stubs.addr + fixup.symbol * stubs.reserved2;
        const text_addr = symbol.n_value + fixup.start;
        switch (self.base.options.target.cpu.arch) {
            .x86_64 => {
                assert(stub_addr >= text_addr + fixup.len);
                const displacement = try math.cast(u32, stub_addr - text_addr - fixup.len);
                var placeholder = code_buffer.items[fixup.start + fixup.len - @sizeOf(u32) ..][0..@sizeOf(u32)];
                mem.writeIntSliceLittle(u32, placeholder, displacement);
            },
            .aarch64 => {
                assert(stub_addr >= text_addr);
                const displacement = try math.cast(i28, stub_addr - text_addr);
                var placeholder = code_buffer.items[fixup.start..][0..fixup.len];
                mem.writeIntSliceLittle(u32, placeholder, aarch64.Instruction.bl(displacement).toU32());
            },
            else => unreachable, // unsupported target architecture
        }
        if (!fixup.already_defined) {
            try self.writeStub(fixup.symbol);
            try self.writeStubInStubHelper(fixup.symbol);
            try self.writeLazySymbolPointer(fixup.symbol);

            self.rebase_info_dirty = true;
            self.lazy_binding_info_dirty = true;
        }
    }
    self.stub_fixups.shrinkRetainingCapacity(0);

    const text_section = text_segment.sections.items[self.text_section_index.?];
    const section_offset = symbol.n_value - text_section.addr;
    const file_offset = text_section.offset + section_offset;
    try self.base.file.?.pwriteAll(code, file_offset);

    if (debug_buffers) |*db| {
        try self.d_sym.?.commitDeclDebugInfo(
            self.base.allocator,
            module,
            decl,
            db,
            self.base.options.target,
        );
    }

    // Since we updated the vaddr and the size, each corresponding export symbol also needs to be updated.
    const decl_exports = module.decl_exports.get(decl) orelse &[0]*Module.Export{};
    try self.updateDeclExports(module, decl, decl_exports);
}

pub fn updateDeclLineNumber(self: *MachO, module: *Module, decl: *const Module.Decl) !void {
    if (self.d_sym) |*ds| {
        try ds.updateDeclLineNumber(module, decl);
    }
}

pub fn updateDeclExports(
    self: *MachO,
    module: *Module,
    decl: *Module.Decl,
    exports: []const *Module.Export,
) !void {
    const tracy = trace(@src());
    defer tracy.end();

    try self.globals.ensureCapacity(self.base.allocator, self.globals.items.len + exports.len);
    if (decl.link.macho.local_sym_index == 0) return;
    const decl_sym = &self.locals.items[decl.link.macho.local_sym_index];

    for (exports) |exp| {
        const exp_name = try std.fmt.allocPrint(self.base.allocator, "_{s}", .{exp.options.name});
        defer self.base.allocator.free(exp_name);

        if (exp.options.section) |section_name| {
            if (!mem.eql(u8, section_name, "__text")) {
                try module.failed_exports.ensureCapacity(module.gpa, module.failed_exports.count() + 1);
                module.failed_exports.putAssumeCapacityNoClobber(
                    exp,
                    try Module.ErrorMsg.create(self.base.allocator, decl.srcLoc(), "Unimplemented: ExportOptions.section", .{}),
                );
                continue;
            }
        }

        var n_type: u8 = macho.N_SECT | macho.N_EXT;
        var n_desc: u16 = 0;

        switch (exp.options.linkage) {
            .Internal => {
                // Symbol should be hidden, or in MachO lingo, private extern.
                // We should also mark the symbol as Weak: n_desc == N_WEAK_DEF.
                // TODO work out when to add N_WEAK_REF.
                n_type |= macho.N_PEXT;
                n_desc |= macho.N_WEAK_DEF;
            },
            .Strong => {
                // Check if the export is _main, and note if os.
                // Otherwise, don't do anything since we already have all the flags
                // set that we need for global (strong) linkage.
                // n_type == N_SECT | N_EXT
                if (mem.eql(u8, exp_name, "_main")) {
                    self.entry_addr = decl_sym.n_value;
                }
            },
            .Weak => {
                // Weak linkage is specified as part of n_desc field.
                // Symbol's n_type is like for a symbol with strong linkage.
                n_desc |= macho.N_WEAK_DEF;
            },
            .LinkOnce => {
                try module.failed_exports.ensureCapacity(module.gpa, module.failed_exports.count() + 1);
                module.failed_exports.putAssumeCapacityNoClobber(
                    exp,
                    try Module.ErrorMsg.create(self.base.allocator, decl.srcLoc(), "Unimplemented: GlobalLinkage.LinkOnce", .{}),
                );
                continue;
            },
        }

        if (exp.link.macho.sym_index) |i| {
            const sym = &self.globals.items[i];
            sym.* = .{
                .n_strx = try self.updateString(sym.n_strx, exp_name),
                .n_type = n_type,
                .n_sect = @intCast(u8, self.text_section_index.?) + 1,
                .n_desc = n_desc,
                .n_value = decl_sym.n_value,
            };
        } else {
            const name_str_index = try self.makeString(exp_name);
            const i = if (self.globals_free_list.popOrNull()) |i| i else blk: {
                _ = self.globals.addOneAssumeCapacity();
                self.export_info_dirty = true;
                break :blk self.globals.items.len - 1;
            };
            self.globals.items[i] = .{
                .n_strx = name_str_index,
                .n_type = n_type,
                .n_sect = @intCast(u8, self.text_section_index.?) + 1,
                .n_desc = n_desc,
                .n_value = decl_sym.n_value,
            };

            exp.link.macho.sym_index = @intCast(u32, i);
        }
    }
}

pub fn deleteExport(self: *MachO, exp: Export) void {
    const sym_index = exp.sym_index orelse return;
    self.globals_free_list.append(self.base.allocator, sym_index) catch {};
    self.globals.items[sym_index].n_type = 0;
}

pub fn freeDecl(self: *MachO, decl: *Module.Decl) void {
    // Appending to free lists is allowed to fail because the free lists are heuristics based anyway.
    self.freeTextBlock(&decl.link.macho);
    if (decl.link.macho.local_sym_index != 0) {
        self.locals_free_list.append(self.base.allocator, decl.link.macho.local_sym_index) catch {};
        self.offset_table_free_list.append(self.base.allocator, decl.link.macho.offset_table_index) catch {};

        self.locals.items[decl.link.macho.local_sym_index].n_type = 0;

        decl.link.macho.local_sym_index = 0;
    }
    if (self.d_sym) |*ds| {
        // TODO make this logic match freeTextBlock. Maybe abstract the logic
        // out since the same thing is desired for both.
        _ = ds.dbg_line_fn_free_list.remove(&decl.fn_link.macho);
        if (decl.fn_link.macho.prev) |prev| {
            ds.dbg_line_fn_free_list.put(self.base.allocator, prev, {}) catch {};
            prev.next = decl.fn_link.macho.next;
            if (decl.fn_link.macho.next) |next| {
                next.prev = prev;
            } else {
                ds.dbg_line_fn_last = prev;
            }
        } else if (decl.fn_link.macho.next) |next| {
            ds.dbg_line_fn_first = next;
            next.prev = null;
        }
        if (ds.dbg_line_fn_first == &decl.fn_link.macho) {
            ds.dbg_line_fn_first = decl.fn_link.macho.next;
        }
        if (ds.dbg_line_fn_last == &decl.fn_link.macho) {
            ds.dbg_line_fn_last = decl.fn_link.macho.prev;
        }
    }
}

pub fn getDeclVAddr(self: *MachO, decl: *const Module.Decl) u64 {
    assert(decl.link.macho.local_sym_index != 0);
    return self.locals.items[decl.link.macho.local_sym_index].n_value;
}

pub fn populateMissingMetadata(self: *MachO) !void {
    switch (self.base.options.output_mode) {
        .Exe => {},
        .Obj => return error.TODOImplementWritingObjFiles,
        .Lib => return error.TODOImplementWritingLibFiles,
    }

    if (self.header == null) {
        var header: macho.mach_header_64 = undefined;
        header.magic = macho.MH_MAGIC_64;

        const CpuInfo = struct {
            cpu_type: macho.cpu_type_t,
            cpu_subtype: macho.cpu_subtype_t,
        };

        const cpu_info: CpuInfo = switch (self.base.options.target.cpu.arch) {
            .aarch64 => .{
                .cpu_type = macho.CPU_TYPE_ARM64,
                .cpu_subtype = macho.CPU_SUBTYPE_ARM_ALL,
            },
            .x86_64 => .{
                .cpu_type = macho.CPU_TYPE_X86_64,
                .cpu_subtype = macho.CPU_SUBTYPE_X86_64_ALL,
            },
            else => return error.UnsupportedMachOArchitecture,
        };
        header.cputype = cpu_info.cpu_type;
        header.cpusubtype = cpu_info.cpu_subtype;

        const filetype: u32 = switch (self.base.options.output_mode) {
            .Exe => macho.MH_EXECUTE,
            .Obj => macho.MH_OBJECT,
            .Lib => switch (self.base.options.link_mode) {
                .Static => return error.TODOStaticLibMachOType,
                .Dynamic => macho.MH_DYLIB,
            },
        };
        header.filetype = filetype;
        // These will get populated at the end of flushing the results to file.
        header.ncmds = 0;
        header.sizeofcmds = 0;

        switch (self.base.options.output_mode) {
            .Exe => {
                header.flags = macho.MH_NOUNDEFS | macho.MH_DYLDLINK | macho.MH_PIE;
            },
            else => {
                header.flags = 0;
            },
        }
        header.reserved = 0;
        self.header = header;
        self.header_dirty = true;
    }
    if (self.pagezero_segment_cmd_index == null) {
        self.pagezero_segment_cmd_index = @intCast(u16, self.load_commands.items.len);
        try self.load_commands.append(self.base.allocator, .{
            .Segment = SegmentCommand.empty("__PAGEZERO", .{
                .vmsize = 0x100000000, // size always set to 4GB
            }),
        });
        self.header_dirty = true;
        self.load_commands_dirty = true;
    }
    if (self.text_segment_cmd_index == null) {
        self.text_segment_cmd_index = @intCast(u16, self.load_commands.items.len);
        const maxprot = macho.VM_PROT_READ | macho.VM_PROT_WRITE | macho.VM_PROT_EXECUTE;
        const initprot = macho.VM_PROT_READ | macho.VM_PROT_EXECUTE;

        const program_code_size_hint = self.base.options.program_code_size_hint;
        const offset_table_size_hint = @sizeOf(u64) * self.base.options.symbol_count_hint;
        const ideal_size = self.header_pad + program_code_size_hint + 3 * offset_table_size_hint;
        const needed_size = mem.alignForwardGeneric(u64, padToIdeal(ideal_size), self.page_size);

        log.debug("found __TEXT segment free space 0x{x} to 0x{x}", .{ 0, needed_size });

        try self.load_commands.append(self.base.allocator, .{
            .Segment = SegmentCommand.empty("__TEXT", .{
                .vmaddr = 0x100000000, // always starts at 4GB
                .vmsize = needed_size,
                .filesize = needed_size,
                .maxprot = maxprot,
                .initprot = initprot,
            }),
        });
        self.header_dirty = true;
        self.load_commands_dirty = true;
    }
    if (self.text_section_index == null) {
        const text_segment = &self.load_commands.items[self.text_segment_cmd_index.?].Segment;
        self.text_section_index = @intCast(u16, text_segment.sections.items.len);

        const alignment: u2 = switch (self.base.options.target.cpu.arch) {
            .x86_64 => 0,
            .aarch64 => 2,
            else => unreachable, // unhandled architecture type
        };
        const flags = macho.S_REGULAR | macho.S_ATTR_PURE_INSTRUCTIONS | macho.S_ATTR_SOME_INSTRUCTIONS;
        const needed_size = self.base.options.program_code_size_hint;
        const off = text_segment.findFreeSpace(needed_size, @as(u16, 1) << alignment, self.header_pad);

        log.debug("found __text section free space 0x{x} to 0x{x}", .{ off, off + needed_size });

        try text_segment.addSection(self.base.allocator, "__text", .{
            .addr = text_segment.inner.vmaddr + off,
            .size = @intCast(u32, needed_size),
            .offset = @intCast(u32, off),
            .@"align" = alignment,
            .flags = flags,
        });
        self.header_dirty = true;
        self.load_commands_dirty = true;
    }
    if (self.stubs_section_index == null) {
        const text_segment = &self.load_commands.items[self.text_segment_cmd_index.?].Segment;
        self.stubs_section_index = @intCast(u16, text_segment.sections.items.len);

        const alignment: u2 = switch (self.base.options.target.cpu.arch) {
            .x86_64 => 0,
            .aarch64 => 2,
            else => unreachable, // unhandled architecture type
        };
        const stub_size: u4 = switch (self.base.options.target.cpu.arch) {
            .x86_64 => 6,
            .aarch64 => 3 * @sizeOf(u32),
            else => unreachable, // unhandled architecture type
        };
        const flags = macho.S_SYMBOL_STUBS | macho.S_ATTR_PURE_INSTRUCTIONS | macho.S_ATTR_SOME_INSTRUCTIONS;
        const needed_size = @sizeOf(u64) * self.base.options.symbol_count_hint;
        const off = text_segment.findFreeSpace(needed_size, @alignOf(u64), self.header_pad);
        assert(off + needed_size <= text_segment.inner.fileoff + text_segment.inner.filesize); // TODO Must expand __TEXT segment.

        log.debug("found __stubs section free space 0x{x} to 0x{x}", .{ off, off + needed_size });

        try text_segment.addSection(self.base.allocator, "__stubs", .{
            .addr = text_segment.inner.vmaddr + off,
            .size = needed_size,
            .offset = @intCast(u32, off),
            .@"align" = alignment,
            .flags = flags,
            .reserved2 = stub_size,
        });
        self.header_dirty = true;
        self.load_commands_dirty = true;
    }
    if (self.stub_helper_section_index == null) {
        const text_segment = &self.load_commands.items[self.text_segment_cmd_index.?].Segment;
        self.stub_helper_section_index = @intCast(u16, text_segment.sections.items.len);

        const alignment: u2 = switch (self.base.options.target.cpu.arch) {
            .x86_64 => 0,
            .aarch64 => 2,
            else => unreachable, // unhandled architecture type
        };
        const flags = macho.S_REGULAR | macho.S_ATTR_PURE_INSTRUCTIONS | macho.S_ATTR_SOME_INSTRUCTIONS;
        const needed_size = @sizeOf(u64) * self.base.options.symbol_count_hint;
        const off = text_segment.findFreeSpace(needed_size, @alignOf(u64), self.header_pad);
        assert(off + needed_size <= text_segment.inner.fileoff + text_segment.inner.filesize); // TODO Must expand __TEXT segment.

        log.debug("found __stub_helper section free space 0x{x} to 0x{x}", .{ off, off + needed_size });

        try text_segment.addSection(self.base.allocator, "__stub_helper", .{
            .addr = text_segment.inner.vmaddr + off,
            .size = needed_size,
            .offset = @intCast(u32, off),
            .@"align" = alignment,
            .flags = flags,
        });
        self.header_dirty = true;
        self.load_commands_dirty = true;
    }
    if (self.data_const_segment_cmd_index == null) {
        self.data_const_segment_cmd_index = @intCast(u16, self.load_commands.items.len);
        const maxprot = macho.VM_PROT_READ | macho.VM_PROT_WRITE | macho.VM_PROT_EXECUTE;
        const initprot = macho.VM_PROT_READ | macho.VM_PROT_WRITE;
        const address_and_offset = self.nextSegmentAddressAndOffset();

        const ideal_size = @sizeOf(u64) * self.base.options.symbol_count_hint;
        const needed_size = mem.alignForwardGeneric(u64, padToIdeal(ideal_size), self.page_size);

        log.debug("found __DATA_CONST segment free space 0x{x} to 0x{x}", .{ address_and_offset.offset, address_and_offset.offset + needed_size });

        try self.load_commands.append(self.base.allocator, .{
            .Segment = SegmentCommand.empty("__DATA_CONST", .{
                .vmaddr = address_and_offset.address,
                .vmsize = needed_size,
                .fileoff = address_and_offset.offset,
                .filesize = needed_size,
                .maxprot = maxprot,
                .initprot = initprot,
            }),
        });
        self.header_dirty = true;
        self.load_commands_dirty = true;
    }
    if (self.got_section_index == null) {
        const dc_segment = &self.load_commands.items[self.data_const_segment_cmd_index.?].Segment;
        self.got_section_index = @intCast(u16, dc_segment.sections.items.len);

        const flags = macho.S_NON_LAZY_SYMBOL_POINTERS;
        const needed_size = @sizeOf(u64) * self.base.options.symbol_count_hint;
        const off = dc_segment.findFreeSpace(needed_size, @alignOf(u64), null);
        assert(off + needed_size <= dc_segment.inner.fileoff + dc_segment.inner.filesize); // TODO Must expand __DATA_CONST segment.

        log.debug("found __got section free space 0x{x} to 0x{x}", .{ off, off + needed_size });

        try dc_segment.addSection(self.base.allocator, "__got", .{
            .addr = dc_segment.inner.vmaddr + off - dc_segment.inner.fileoff,
            .size = needed_size,
            .offset = @intCast(u32, off),
            .@"align" = 3, // 2^3 = @sizeOf(u64)
            .flags = flags,
        });
        self.header_dirty = true;
        self.load_commands_dirty = true;
    }
    if (self.data_segment_cmd_index == null) {
        self.data_segment_cmd_index = @intCast(u16, self.load_commands.items.len);
        const maxprot = macho.VM_PROT_READ | macho.VM_PROT_WRITE | macho.VM_PROT_EXECUTE;
        const initprot = macho.VM_PROT_READ | macho.VM_PROT_WRITE;
        const address_and_offset = self.nextSegmentAddressAndOffset();

        const ideal_size = 2 * @sizeOf(u64) * self.base.options.symbol_count_hint;
        const needed_size = mem.alignForwardGeneric(u64, padToIdeal(ideal_size), self.page_size);

        log.debug("found __DATA segment free space 0x{x} to 0x{x}", .{ address_and_offset.offset, address_and_offset.offset + needed_size });

        try self.load_commands.append(self.base.allocator, .{
            .Segment = SegmentCommand.empty("__DATA", .{
                .vmaddr = address_and_offset.address,
                .vmsize = needed_size,
                .fileoff = address_and_offset.offset,
                .filesize = needed_size,
                .maxprot = maxprot,
                .initprot = initprot,
            }),
        });
        self.header_dirty = true;
        self.load_commands_dirty = true;
    }
    if (self.la_symbol_ptr_section_index == null) {
        const data_segment = &self.load_commands.items[self.data_segment_cmd_index.?].Segment;
        self.la_symbol_ptr_section_index = @intCast(u16, data_segment.sections.items.len);

        const flags = macho.S_LAZY_SYMBOL_POINTERS;
        const needed_size = @sizeOf(u64) * self.base.options.symbol_count_hint;
        const off = data_segment.findFreeSpace(needed_size, @alignOf(u64), null);
        assert(off + needed_size <= data_segment.inner.fileoff + data_segment.inner.filesize); // TODO Must expand __DATA segment.

        log.debug("found __la_symbol_ptr section free space 0x{x} to 0x{x}", .{ off, off + needed_size });

        try data_segment.addSection(self.base.allocator, "__la_symbol_ptr", .{
            .addr = data_segment.inner.vmaddr + off - data_segment.inner.fileoff,
            .size = needed_size,
            .offset = @intCast(u32, off),
            .@"align" = 3, // 2^3 = @sizeOf(u64)
            .flags = flags,
        });
        self.header_dirty = true;
        self.load_commands_dirty = true;
    }
    if (self.data_section_index == null) {
        const data_segment = &self.load_commands.items[self.data_segment_cmd_index.?].Segment;
        self.data_section_index = @intCast(u16, data_segment.sections.items.len);

        const needed_size = @sizeOf(u64) * self.base.options.symbol_count_hint;
        const off = data_segment.findFreeSpace(needed_size, @alignOf(u64), null);
        assert(off + needed_size <= data_segment.inner.fileoff + data_segment.inner.filesize); // TODO Must expand __DATA segment.

        log.debug("found __data section free space 0x{x} to 0x{x}", .{ off, off + needed_size });

        try data_segment.addSection(self.base.allocator, "__data", .{
            .addr = data_segment.inner.vmaddr + off - data_segment.inner.fileoff,
            .size = needed_size,
            .offset = @intCast(u32, off),
            .@"align" = 3, // 2^3 = @sizeOf(u64)
        });
        self.header_dirty = true;
        self.load_commands_dirty = true;
    }
    if (self.linkedit_segment_cmd_index == null) {
        self.linkedit_segment_cmd_index = @intCast(u16, self.load_commands.items.len);

        const maxprot = macho.VM_PROT_READ | macho.VM_PROT_WRITE | macho.VM_PROT_EXECUTE;
        const initprot = macho.VM_PROT_READ;
        const address_and_offset = self.nextSegmentAddressAndOffset();

        log.debug("found __LINKEDIT segment free space at 0x{x}", .{address_and_offset.offset});

        try self.load_commands.append(self.base.allocator, .{
            .Segment = SegmentCommand.empty("__LINKEDIT", .{
                .vmaddr = address_and_offset.address,
                .fileoff = address_and_offset.offset,
                .maxprot = maxprot,
                .initprot = initprot,
            }),
        });
        self.header_dirty = true;
        self.load_commands_dirty = true;
    }
    if (self.dyld_info_cmd_index == null) {
        self.dyld_info_cmd_index = @intCast(u16, self.load_commands.items.len);

        try self.load_commands.append(self.base.allocator, .{
            .DyldInfoOnly = .{
                .cmd = macho.LC_DYLD_INFO_ONLY,
                .cmdsize = @sizeOf(macho.dyld_info_command),
                .rebase_off = 0,
                .rebase_size = 0,
                .bind_off = 0,
                .bind_size = 0,
                .weak_bind_off = 0,
                .weak_bind_size = 0,
                .lazy_bind_off = 0,
                .lazy_bind_size = 0,
                .export_off = 0,
                .export_size = 0,
            },
        });

        const dyld = &self.load_commands.items[self.dyld_info_cmd_index.?].DyldInfoOnly;

        // Preallocate rebase, binding, lazy binding info, and export info.
        const expected_size = 48; // TODO This is totally random.
        const rebase_off = self.findFreeSpaceLinkedit(expected_size, 1, null);
        log.debug("found rebase info free space 0x{x} to 0x{x}", .{ rebase_off, rebase_off + expected_size });
        dyld.rebase_off = @intCast(u32, rebase_off);
        dyld.rebase_size = expected_size;

        const bind_off = self.findFreeSpaceLinkedit(expected_size, 1, null);
        log.debug("found binding info free space 0x{x} to 0x{x}", .{ bind_off, bind_off + expected_size });
        dyld.bind_off = @intCast(u32, bind_off);
        dyld.bind_size = expected_size;

        const lazy_bind_off = self.findFreeSpaceLinkedit(expected_size, 1, null);
        log.debug("found lazy binding info free space 0x{x} to 0x{x}", .{ lazy_bind_off, lazy_bind_off + expected_size });
        dyld.lazy_bind_off = @intCast(u32, lazy_bind_off);
        dyld.lazy_bind_size = expected_size;

        const export_off = self.findFreeSpaceLinkedit(expected_size, 1, null);
        log.debug("found export info free space 0x{x} to 0x{x}", .{ export_off, export_off + expected_size });
        dyld.export_off = @intCast(u32, export_off);
        dyld.export_size = expected_size;

        self.header_dirty = true;
        self.load_commands_dirty = true;
    }
    if (self.symtab_cmd_index == null) {
        self.symtab_cmd_index = @intCast(u16, self.load_commands.items.len);

        try self.load_commands.append(self.base.allocator, .{
            .Symtab = .{
                .cmd = macho.LC_SYMTAB,
                .cmdsize = @sizeOf(macho.symtab_command),
                .symoff = 0,
                .nsyms = 0,
                .stroff = 0,
                .strsize = 0,
            },
        });

        const symtab = &self.load_commands.items[self.symtab_cmd_index.?].Symtab;

        const symtab_size = self.base.options.symbol_count_hint * @sizeOf(macho.nlist_64);
        const symtab_off = self.findFreeSpaceLinkedit(symtab_size, @sizeOf(macho.nlist_64), null);
        log.debug("found symbol table free space 0x{x} to 0x{x}", .{ symtab_off, symtab_off + symtab_size });
        symtab.symoff = @intCast(u32, symtab_off);
        symtab.nsyms = @intCast(u32, self.base.options.symbol_count_hint);

        try self.string_table.append(self.base.allocator, 0); // Need a null at position 0.
        const strtab_size = self.string_table.items.len;
        const strtab_off = self.findFreeSpaceLinkedit(strtab_size, 1, symtab_off);
        log.debug("found string table free space 0x{x} to 0x{x}", .{ strtab_off, strtab_off + strtab_size });
        symtab.stroff = @intCast(u32, strtab_off);
        symtab.strsize = @intCast(u32, strtab_size);

        self.header_dirty = true;
        self.load_commands_dirty = true;
        self.string_table_dirty = true;
    }
    if (self.dysymtab_cmd_index == null) {
        self.dysymtab_cmd_index = @intCast(u16, self.load_commands.items.len);

        // Preallocate space for indirect symbol table.
        const indsymtab_size = self.base.options.symbol_count_hint * @sizeOf(u64); // Each entry is just a u64.
        const indsymtab_off = self.findFreeSpaceLinkedit(indsymtab_size, @sizeOf(u64), null);

        log.debug("found indirect symbol table free space 0x{x} to 0x{x}", .{ indsymtab_off, indsymtab_off + indsymtab_size });

        try self.load_commands.append(self.base.allocator, .{
            .Dysymtab = .{
                .cmd = macho.LC_DYSYMTAB,
                .cmdsize = @sizeOf(macho.dysymtab_command),
                .ilocalsym = 0,
                .nlocalsym = 0,
                .iextdefsym = 0,
                .nextdefsym = 0,
                .iundefsym = 0,
                .nundefsym = 0,
                .tocoff = 0,
                .ntoc = 0,
                .modtaboff = 0,
                .nmodtab = 0,
                .extrefsymoff = 0,
                .nextrefsyms = 0,
                .indirectsymoff = @intCast(u32, indsymtab_off),
                .nindirectsyms = @intCast(u32, self.base.options.symbol_count_hint),
                .extreloff = 0,
                .nextrel = 0,
                .locreloff = 0,
                .nlocrel = 0,
            },
        });
        self.header_dirty = true;
        self.load_commands_dirty = true;
    }
    if (self.dylinker_cmd_index == null) {
        self.dylinker_cmd_index = @intCast(u16, self.load_commands.items.len);
        const cmdsize = @intCast(u32, mem.alignForwardGeneric(
            u64,
            @sizeOf(macho.dylinker_command) + mem.lenZ(DEFAULT_DYLD_PATH),
            @sizeOf(u64),
        ));
        var dylinker_cmd = emptyGenericCommandWithData(macho.dylinker_command{
            .cmd = macho.LC_LOAD_DYLINKER,
            .cmdsize = cmdsize,
            .name = @sizeOf(macho.dylinker_command),
        });
        dylinker_cmd.data = try self.base.allocator.alloc(u8, cmdsize - dylinker_cmd.inner.name);
        mem.set(u8, dylinker_cmd.data, 0);
        mem.copy(u8, dylinker_cmd.data, mem.spanZ(DEFAULT_DYLD_PATH));
        try self.load_commands.append(self.base.allocator, .{ .Dylinker = dylinker_cmd });
        self.header_dirty = true;
        self.load_commands_dirty = true;
    }
    if (self.libsystem_cmd_index == null) {
        self.libsystem_cmd_index = @intCast(u16, self.load_commands.items.len);

        var dylib_cmd = try createLoadDylibCommand(self.base.allocator, mem.spanZ(LIB_SYSTEM_PATH), 2, 0, 0);
        errdefer dylib_cmd.deinit(self.base.allocator);

        try self.load_commands.append(self.base.allocator, .{ .Dylib = dylib_cmd });

        self.header_dirty = true;
        self.load_commands_dirty = true;
    }
    if (self.main_cmd_index == null) {
        self.main_cmd_index = @intCast(u16, self.load_commands.items.len);
        try self.load_commands.append(self.base.allocator, .{
            .Main = .{
                .cmd = macho.LC_MAIN,
                .cmdsize = @sizeOf(macho.entry_point_command),
                .entryoff = 0x0,
                .stacksize = 0,
            },
        });
        self.header_dirty = true;
        self.load_commands_dirty = true;
    }
    if (self.version_min_cmd_index == null) {
        self.version_min_cmd_index = @intCast(u16, self.load_commands.items.len);
        const cmd: u32 = switch (self.base.options.target.os.tag) {
            .macos => macho.LC_VERSION_MIN_MACOSX,
            .ios => macho.LC_VERSION_MIN_IPHONEOS,
            .tvos => macho.LC_VERSION_MIN_TVOS,
            .watchos => macho.LC_VERSION_MIN_WATCHOS,
            else => unreachable, // wrong OS
        };
        const ver = self.base.options.target.os.version_range.semver.min;
        const version = ver.major << 16 | ver.minor << 8 | ver.patch;
        try self.load_commands.append(self.base.allocator, .{
            .VersionMin = .{
                .cmd = cmd,
                .cmdsize = @sizeOf(macho.version_min_command),
                .version = version,
                .sdk = version,
            },
        });
        self.header_dirty = true;
        self.load_commands_dirty = true;
    }
    if (self.source_version_cmd_index == null) {
        self.source_version_cmd_index = @intCast(u16, self.load_commands.items.len);
        try self.load_commands.append(self.base.allocator, .{
            .SourceVersion = .{
                .cmd = macho.LC_SOURCE_VERSION,
                .cmdsize = @sizeOf(macho.source_version_command),
                .version = 0x0,
            },
        });
        self.header_dirty = true;
        self.load_commands_dirty = true;
    }
    if (self.uuid_cmd_index == null) {
        self.uuid_cmd_index = @intCast(u16, self.load_commands.items.len);
        var uuid_cmd: macho.uuid_command = .{
            .cmd = macho.LC_UUID,
            .cmdsize = @sizeOf(macho.uuid_command),
            .uuid = undefined,
        };
        std.crypto.random.bytes(&uuid_cmd.uuid);
        try self.load_commands.append(self.base.allocator, .{ .Uuid = uuid_cmd });
        self.header_dirty = true;
        self.load_commands_dirty = true;
    }
    if (self.code_signature_cmd_index == null) {
        self.code_signature_cmd_index = @intCast(u16, self.load_commands.items.len);
        try self.load_commands.append(self.base.allocator, .{
            .LinkeditData = .{
                .cmd = macho.LC_CODE_SIGNATURE,
                .cmdsize = @sizeOf(macho.linkedit_data_command),
                .dataoff = 0,
                .datasize = 0,
            },
        });
        self.header_dirty = true;
        self.load_commands_dirty = true;
    }
    if (!self.nonlazy_imports.contains("dyld_stub_binder")) {
        const index = @intCast(u32, self.nonlazy_imports.count());
        const name = try self.base.allocator.dupe(u8, "dyld_stub_binder");
        const offset = try self.makeString("dyld_stub_binder");
        try self.nonlazy_imports.putNoClobber(self.base.allocator, name, .{
            .symbol = .{
                .n_strx = offset,
                .n_type = std.macho.N_UNDF | std.macho.N_EXT,
                .n_sect = 0,
                .n_desc = std.macho.REFERENCE_FLAG_UNDEFINED_NON_LAZY | std.macho.N_SYMBOL_RESOLVER,
                .n_value = 0,
            },
            .dylib_ordinal = 1, // TODO this is currently hardcoded.
            .index = index,
        });
        const off_index = @intCast(u32, self.offset_table.items.len);
        try self.offset_table.append(self.base.allocator, .{
            .kind = .Extern,
            .symbol = index,
            .index = off_index,
        });
        try self.writeOffsetTableEntry(off_index);
        self.binding_info_dirty = true;
    }
    if (self.stub_helper_stubs_start_off == null) {
        try self.writeStubHelperPreamble();
    }
}

fn allocateTextBlock(self: *MachO, text_block: *TextBlock, new_block_size: u64, alignment: u64) !u64 {
    const text_segment = &self.load_commands.items[self.text_segment_cmd_index.?].Segment;
    const text_section = &text_segment.sections.items[self.text_section_index.?];
    const new_block_ideal_capacity = padToIdeal(new_block_size);

    // We use these to indicate our intention to update metadata, placing the new block,
    // and possibly removing a free list node.
    // It would be simpler to do it inside the for loop below, but that would cause a
    // problem if an error was returned later in the function. So this action
    // is actually carried out at the end of the function, when errors are no longer possible.
    var block_placement: ?*TextBlock = null;
    var free_list_removal: ?usize = null;

    // First we look for an appropriately sized free list node.
    // The list is unordered. We'll just take the first thing that works.
    const vaddr = blk: {
        var i: usize = 0;
        while (i < self.text_block_free_list.items.len) {
            const big_block = self.text_block_free_list.items[i];
            // We now have a pointer to a live text block that has too much capacity.
            // Is it enough that we could fit this new text block?
            const sym = self.locals.items[big_block.local_sym_index];
            const capacity = big_block.capacity(self.*);
            const ideal_capacity = padToIdeal(capacity);
            const ideal_capacity_end_vaddr = sym.n_value + ideal_capacity;
            const capacity_end_vaddr = sym.n_value + capacity;
            const new_start_vaddr_unaligned = capacity_end_vaddr - new_block_ideal_capacity;
            const new_start_vaddr = mem.alignBackwardGeneric(u64, new_start_vaddr_unaligned, alignment);
            if (new_start_vaddr < ideal_capacity_end_vaddr) {
                // Additional bookkeeping here to notice if this free list node
                // should be deleted because the block that it points to has grown to take up
                // more of the extra capacity.
                if (!big_block.freeListEligible(self.*)) {
                    _ = self.text_block_free_list.swapRemove(i);
                } else {
                    i += 1;
                }
                continue;
            }
            // At this point we know that we will place the new block here. But the
            // remaining question is whether there is still yet enough capacity left
            // over for there to still be a free list node.
            const remaining_capacity = new_start_vaddr - ideal_capacity_end_vaddr;
            const keep_free_list_node = remaining_capacity >= min_text_capacity;

            // Set up the metadata to be updated, after errors are no longer possible.
            block_placement = big_block;
            if (!keep_free_list_node) {
                free_list_removal = i;
            }
            break :blk new_start_vaddr;
        } else if (self.last_text_block) |last| {
            const last_symbol = self.locals.items[last.local_sym_index];
            // TODO We should pad out the excess capacity with NOPs. For executables,
            // no padding seems to be OK, but it will probably not be for objects.
            const ideal_capacity = padToIdeal(last.size);
            const ideal_capacity_end_vaddr = last_symbol.n_value + ideal_capacity;
            const new_start_vaddr = mem.alignForwardGeneric(u64, ideal_capacity_end_vaddr, alignment);
            block_placement = last;
            break :blk new_start_vaddr;
        } else {
            break :blk text_section.addr;
        }
    };

    const expand_text_section = block_placement == null or block_placement.?.next == null;
    if (expand_text_section) {
        const needed_size = (vaddr + new_block_size) - text_section.addr;
        assert(needed_size <= text_segment.inner.filesize); // TODO must move the entire text section.

        self.last_text_block = text_block;
        text_section.size = needed_size;
        self.load_commands_dirty = true; // TODO Make more granular.

        if (self.d_sym) |*ds| {
            const debug_text_seg = &ds.load_commands.items[ds.text_segment_cmd_index.?].Segment;
            const debug_text_sect = &debug_text_seg.sections.items[ds.text_section_index.?];
            debug_text_sect.size = needed_size;
            ds.load_commands_dirty = true;
        }
    }
    text_block.size = new_block_size;

    if (text_block.prev) |prev| {
        prev.next = text_block.next;
    }
    if (text_block.next) |next| {
        next.prev = text_block.prev;
    }

    if (block_placement) |big_block| {
        text_block.prev = big_block;
        text_block.next = big_block.next;
        big_block.next = text_block;
    } else {
        text_block.prev = null;
        text_block.next = null;
    }
    if (free_list_removal) |i| {
        _ = self.text_block_free_list.swapRemove(i);
    }

    return vaddr;
}

fn makeString(self: *MachO, bytes: []const u8) !u32 {
    if (self.string_table_directory.get(bytes)) |offset| {
        log.debug("reusing '{s}' from string table at offset 0x{x}", .{ bytes, offset });
        return offset;
    }

    try self.string_table.ensureCapacity(self.base.allocator, self.string_table.items.len + bytes.len + 1);
    const offset = @intCast(u32, self.string_table.items.len);

    log.debug("writing new string '{s}' into string table at offset 0x{x}", .{ bytes, offset });

    self.string_table.appendSliceAssumeCapacity(bytes);
    self.string_table.appendAssumeCapacity(0);

    try self.string_table_directory.putNoClobber(
        self.base.allocator,
        try self.base.allocator.dupe(u8, bytes),
        offset,
    );

    self.string_table_dirty = true;
    if (self.d_sym) |*ds|
        ds.string_table_dirty = true;

    return offset;
}

fn getString(self: *MachO, str_off: u32) []const u8 {
    assert(str_off < self.string_table.items.len);
    return mem.spanZ(@ptrCast([*:0]const u8, self.string_table.items.ptr + str_off));
}

fn updateString(self: *MachO, old_str_off: u32, new_name: []const u8) !u32 {
    const existing_name = self.getString(old_str_off);
    if (mem.eql(u8, existing_name, new_name)) {
        return old_str_off;
    }
    return self.makeString(new_name);
}

pub fn addExternSymbol(self: *MachO, name: []const u8) !u32 {
    const index = @intCast(u32, self.lazy_imports.count());
    const offset = try self.makeString(name);
    const sym_name = try self.base.allocator.dupe(u8, name);
    const dylib_ordinal = 1; // TODO this is now hardcoded, since we only support libSystem.
    try self.lazy_imports.putNoClobber(self.base.allocator, sym_name, .{
        .symbol = .{
            .n_strx = offset,
            .n_type = macho.N_UNDF | macho.N_EXT,
            .n_sect = 0,
            .n_desc = macho.REFERENCE_FLAG_UNDEFINED_NON_LAZY | macho.N_SYMBOL_RESOLVER,
            .n_value = 0,
        },
        .dylib_ordinal = dylib_ordinal,
        .index = index,
    });
    log.debug("adding new extern symbol '{s}' with dylib ordinal '{}'", .{ name, dylib_ordinal });
    return index;
}

const NextSegmentAddressAndOffset = struct {
    address: u64,
    offset: u64,
};

fn nextSegmentAddressAndOffset(self: *MachO) NextSegmentAddressAndOffset {
    var prev_segment_idx: ?usize = null; // We use optional here for safety.
    for (self.load_commands.items) |cmd, i| {
        if (cmd == .Segment) {
            prev_segment_idx = i;
        }
    }
    const prev_segment = self.load_commands.items[prev_segment_idx.?].Segment;
    const address = prev_segment.inner.vmaddr + prev_segment.inner.vmsize;
    const offset = prev_segment.inner.fileoff + prev_segment.inner.filesize;
    return .{
        .address = address,
        .offset = offset,
    };
}

fn allocatedSizeLinkedit(self: *MachO, start: u64) u64 {
    assert(start > 0);
    var min_pos: u64 = std.math.maxInt(u64);

    // __LINKEDIT is a weird segment where sections get their own load commands so we
    // special-case it.
    if (self.dyld_info_cmd_index) |idx| {
        const dyld_info = self.load_commands.items[idx].DyldInfoOnly;
        if (dyld_info.rebase_off > start and dyld_info.rebase_off < min_pos) min_pos = dyld_info.rebase_off;
        if (dyld_info.bind_off > start and dyld_info.bind_off < min_pos) min_pos = dyld_info.bind_off;
        if (dyld_info.weak_bind_off > start and dyld_info.weak_bind_off < min_pos) min_pos = dyld_info.weak_bind_off;
        if (dyld_info.lazy_bind_off > start and dyld_info.lazy_bind_off < min_pos) min_pos = dyld_info.lazy_bind_off;
        if (dyld_info.export_off > start and dyld_info.export_off < min_pos) min_pos = dyld_info.export_off;
    }

    if (self.function_starts_cmd_index) |idx| {
        const fstart = self.load_commands.items[idx].LinkeditData;
        if (fstart.dataoff > start and fstart.dataoff < min_pos) min_pos = fstart.dataoff;
    }

    if (self.data_in_code_cmd_index) |idx| {
        const dic = self.load_commands.items[idx].LinkeditData;
        if (dic.dataoff > start and dic.dataoff < min_pos) min_pos = dic.dataoff;
    }

    if (self.dysymtab_cmd_index) |idx| {
        const dysymtab = self.load_commands.items[idx].Dysymtab;
        if (dysymtab.indirectsymoff > start and dysymtab.indirectsymoff < min_pos) min_pos = dysymtab.indirectsymoff;
        // TODO Handle more dynamic symbol table sections.
    }

    if (self.symtab_cmd_index) |idx| {
        const symtab = self.load_commands.items[idx].Symtab;
        if (symtab.symoff > start and symtab.symoff < min_pos) min_pos = symtab.symoff;
        if (symtab.stroff > start and symtab.stroff < min_pos) min_pos = symtab.stroff;
    }

    return min_pos - start;
}
inline fn checkForCollision(start: u64, end: u64, off: u64, size: u64) ?u64 {
    const increased_size = padToIdeal(size);
    const test_end = off + increased_size;
    if (end > off and start < test_end) {
        return test_end;
    }
    return null;
}

fn detectAllocCollisionLinkedit(self: *MachO, start: u64, size: u64) ?u64 {
    const end = start + padToIdeal(size);

    // __LINKEDIT is a weird segment where sections get their own load commands so we
    // special-case it.
    if (self.dyld_info_cmd_index) |idx| outer: {
        if (self.load_commands.items.len == idx) break :outer;
        const dyld_info = self.load_commands.items[idx].DyldInfoOnly;
        if (checkForCollision(start, end, dyld_info.rebase_off, dyld_info.rebase_size)) |pos| {
            return pos;
        }
        // Binding info
        if (checkForCollision(start, end, dyld_info.bind_off, dyld_info.bind_size)) |pos| {
            return pos;
        }
        // Weak binding info
        if (checkForCollision(start, end, dyld_info.weak_bind_off, dyld_info.weak_bind_size)) |pos| {
            return pos;
        }
        // Lazy binding info
        if (checkForCollision(start, end, dyld_info.lazy_bind_off, dyld_info.lazy_bind_size)) |pos| {
            return pos;
        }
        // Export info
        if (checkForCollision(start, end, dyld_info.export_off, dyld_info.export_size)) |pos| {
            return pos;
        }
    }

    if (self.function_starts_cmd_index) |idx| outer: {
        if (self.load_commands.items.len == idx) break :outer;
        const fstart = self.load_commands.items[idx].LinkeditData;
        if (checkForCollision(start, end, fstart.dataoff, fstart.datasize)) |pos| {
            return pos;
        }
    }

    if (self.data_in_code_cmd_index) |idx| outer: {
        if (self.load_commands.items.len == idx) break :outer;
        const dic = self.load_commands.items[idx].LinkeditData;
        if (checkForCollision(start, end, dic.dataoff, dic.datasize)) |pos| {
            return pos;
        }
    }

    if (self.dysymtab_cmd_index) |idx| outer: {
        if (self.load_commands.items.len == idx) break :outer;
        const dysymtab = self.load_commands.items[idx].Dysymtab;
        // Indirect symbol table
        const nindirectsize = dysymtab.nindirectsyms * @sizeOf(u32);
        if (checkForCollision(start, end, dysymtab.indirectsymoff, nindirectsize)) |pos| {
            return pos;
        }
        // TODO Handle more dynamic symbol table sections.
    }

    if (self.symtab_cmd_index) |idx| outer: {
        if (self.load_commands.items.len == idx) break :outer;
        const symtab = self.load_commands.items[idx].Symtab;
        // Symbol table
        const symsize = symtab.nsyms * @sizeOf(macho.nlist_64);
        if (checkForCollision(start, end, symtab.symoff, symsize)) |pos| {
            return pos;
        }
        // String table
        if (checkForCollision(start, end, symtab.stroff, symtab.strsize)) |pos| {
            return pos;
        }
    }

    return null;
}

fn findFreeSpaceLinkedit(self: *MachO, object_size: u64, min_alignment: u16, start: ?u64) u64 {
    const linkedit = self.load_commands.items[self.linkedit_segment_cmd_index.?].Segment;
    var st: u64 = start orelse linkedit.inner.fileoff;
    while (self.detectAllocCollisionLinkedit(st, object_size)) |item_end| {
        st = mem.alignForwardGeneric(u64, item_end, min_alignment);
    }
    return st;
}

fn writeOffsetTableEntry(self: *MachO, index: usize) !void {
    const seg = &self.load_commands.items[self.data_const_segment_cmd_index.?].Segment;
    const sect = &seg.sections.items[self.got_section_index.?];
    const off = sect.offset + @sizeOf(u64) * index;

    if (self.offset_table_count_dirty) {
        // TODO relocate.
        self.offset_table_count_dirty = false;
    }

    const got_entry = self.offset_table.items[index];
    const sym = blk: {
        switch (got_entry.kind) {
            .Local => {
                break :blk self.locals.items[got_entry.symbol];
            },
            .Extern => {
                break :blk self.nonlazy_imports.values()[got_entry.symbol].symbol;
            },
        }
    };
    const sym_name = self.getString(sym.n_strx);
    log.debug("writing offset table entry [ 0x{x} => 0x{x} ({s}) ]", .{ off, sym.n_value, sym_name });
    try self.base.file.?.pwriteAll(mem.asBytes(&sym.n_value), off);
}

fn writeLazySymbolPointer(self: *MachO, index: u32) !void {
    const text_segment = self.load_commands.items[self.text_segment_cmd_index.?].Segment;
    const stub_helper = text_segment.sections.items[self.stub_helper_section_index.?];
    const data_segment = self.load_commands.items[self.data_segment_cmd_index.?].Segment;
    const la_symbol_ptr = data_segment.sections.items[self.la_symbol_ptr_section_index.?];

    const stub_size: u4 = switch (self.base.options.target.cpu.arch) {
        .x86_64 => 10,
        .aarch64 => 3 * @sizeOf(u32),
        else => unreachable,
    };
    const stub_off = self.stub_helper_stubs_start_off.? + index * stub_size;
    const end = stub_helper.addr + stub_off - stub_helper.offset;
    var buf: [@sizeOf(u64)]u8 = undefined;
    mem.writeIntLittle(u64, &buf, end);
    const off = la_symbol_ptr.offset + index * @sizeOf(u64);
    log.debug("writing lazy symbol pointer entry 0x{x} at 0x{x}", .{ end, off });
    try self.base.file.?.pwriteAll(&buf, off);
}

fn writeStubHelperPreamble(self: *MachO) !void {
    const text_segment = &self.load_commands.items[self.text_segment_cmd_index.?].Segment;
    const stub_helper = &text_segment.sections.items[self.stub_helper_section_index.?];
    const data_const_segment = &self.load_commands.items[self.data_const_segment_cmd_index.?].Segment;
    const got = &data_const_segment.sections.items[self.got_section_index.?];
    const data_segment = &self.load_commands.items[self.data_segment_cmd_index.?].Segment;
    const data = &data_segment.sections.items[self.data_section_index.?];

    switch (self.base.options.target.cpu.arch) {
        .x86_64 => {
            const code_size = 15;
            var code: [code_size]u8 = undefined;
            // lea %r11, [rip + disp]
            code[0] = 0x4c;
            code[1] = 0x8d;
            code[2] = 0x1d;
            {
                const target_addr = data.addr;
                const displacement = try math.cast(u32, target_addr - stub_helper.addr - 7);
                mem.writeIntLittle(u32, code[3..7], displacement);
            }
            // push %r11
            code[7] = 0x41;
            code[8] = 0x53;
            // jmp [rip + disp]
            code[9] = 0xff;
            code[10] = 0x25;
            {
                const displacement = try math.cast(u32, got.addr - stub_helper.addr - code_size);
                mem.writeIntLittle(u32, code[11..], displacement);
            }
            try self.base.file.?.pwriteAll(&code, stub_helper.offset);
            self.stub_helper_stubs_start_off = stub_helper.offset + code_size;
        },
        .aarch64 => {
            var code: [6 * @sizeOf(u32)]u8 = undefined;

            data_blk_outer: {
                const this_addr = stub_helper.addr;
                const target_addr = data.addr;
                data_blk: {
                    const displacement = math.cast(i21, target_addr - this_addr) catch break :data_blk;
                    // adr x17, disp
                    mem.writeIntLittle(u32, code[0..4], aarch64.Instruction.adr(.x17, displacement).toU32());
                    // nop
                    mem.writeIntLittle(u32, code[4..8], aarch64.Instruction.nop().toU32());
                    break :data_blk_outer;
                }
                data_blk: {
                    const new_this_addr = this_addr + @sizeOf(u32);
                    const displacement = math.cast(i21, target_addr - new_this_addr) catch break :data_blk;
                    // nop
                    mem.writeIntLittle(u32, code[0..4], aarch64.Instruction.nop().toU32());
                    // adr x17, disp
                    mem.writeIntLittle(u32, code[4..8], aarch64.Instruction.adr(.x17, displacement).toU32());
                    break :data_blk_outer;
                }
                // Jump is too big, replace adr with adrp and add.
                const this_page = @intCast(i32, this_addr >> 12);
                const target_page = @intCast(i32, target_addr >> 12);
                const pages = @intCast(i21, target_page - this_page);
                // adrp x17, pages
                mem.writeIntLittle(u32, code[0..4], aarch64.Instruction.adrp(.x17, pages).toU32());
                const narrowed = @truncate(u12, target_addr);
                mem.writeIntLittle(u32, code[4..8], aarch64.Instruction.add(.x17, .x17, narrowed, false).toU32());
            }

            // stp x16, x17, [sp, #-16]!
            mem.writeIntLittle(u32, code[8..12], aarch64.Instruction.stp(
                .x16,
                .x17,
                aarch64.Register.sp,
                aarch64.Instruction.LoadStorePairOffset.pre_index(-16),
            ).toU32());

            binder_blk_outer: {
                const this_addr = stub_helper.addr + 3 * @sizeOf(u32);
                const target_addr = got.addr;
                binder_blk: {
                    const displacement = math.divExact(u64, target_addr - this_addr, 4) catch break :binder_blk;
                    const literal = math.cast(u18, displacement) catch break :binder_blk;
                    // ldr x16, label
                    mem.writeIntLittle(u32, code[12..16], aarch64.Instruction.ldr(.x16, .{
                        .literal = literal,
                    }).toU32());
                    // nop
                    mem.writeIntLittle(u32, code[16..20], aarch64.Instruction.nop().toU32());
                    break :binder_blk_outer;
                }
                binder_blk: {
                    const new_this_addr = this_addr + @sizeOf(u32);
                    const displacement = math.divExact(u64, target_addr - new_this_addr, 4) catch break :binder_blk;
                    const literal = math.cast(u18, displacement) catch break :binder_blk;
                    // nop
                    mem.writeIntLittle(u32, code[12..16], aarch64.Instruction.nop().toU32());
                    // ldr x16, label
                    mem.writeIntLittle(u32, code[16..20], aarch64.Instruction.ldr(.x16, .{
                        .literal = literal,
                    }).toU32());
                    break :binder_blk_outer;
                }
                // Jump is too big, replace ldr with adrp and ldr(register).
                const this_page = @intCast(i32, this_addr >> 12);
                const target_page = @intCast(i32, target_addr >> 12);
                const pages = @intCast(i21, target_page - this_page);
                // adrp x16, pages
                mem.writeIntLittle(u32, code[12..16], aarch64.Instruction.adrp(.x16, pages).toU32());
                const narrowed = @truncate(u12, target_addr);
                const offset = try math.divExact(u12, narrowed, 8);
                // ldr x16, x16, offset
                mem.writeIntLittle(u32, code[16..20], aarch64.Instruction.ldr(.x16, .{
                    .register = .{
                        .rn = .x16,
                        .offset = aarch64.Instruction.LoadStoreOffset.imm(offset),
                    },
                }).toU32());
            }

            // br x16
            mem.writeIntLittle(u32, code[20..24], aarch64.Instruction.br(.x16).toU32());
            try self.base.file.?.pwriteAll(&code, stub_helper.offset);
            self.stub_helper_stubs_start_off = stub_helper.offset + code.len;
        },
        else => unreachable,
    }
}

fn writeStub(self: *MachO, index: u32) !void {
    const text_segment = self.load_commands.items[self.text_segment_cmd_index.?].Segment;
    const stubs = text_segment.sections.items[self.stubs_section_index.?];
    const data_segment = self.load_commands.items[self.data_segment_cmd_index.?].Segment;
    const la_symbol_ptr = data_segment.sections.items[self.la_symbol_ptr_section_index.?];

    const stub_off = stubs.offset + index * stubs.reserved2;
    const stub_addr = stubs.addr + index * stubs.reserved2;
    const la_ptr_addr = la_symbol_ptr.addr + index * @sizeOf(u64);

    log.debug("writing stub at 0x{x}", .{stub_off});

    var code = try self.base.allocator.alloc(u8, stubs.reserved2);
    defer self.base.allocator.free(code);

    switch (self.base.options.target.cpu.arch) {
        .x86_64 => {
            assert(la_ptr_addr >= stub_addr + stubs.reserved2);
            const displacement = try math.cast(u32, la_ptr_addr - stub_addr - stubs.reserved2);
            // jmp
            code[0] = 0xff;
            code[1] = 0x25;
            mem.writeIntLittle(u32, code[2..][0..4], displacement);
        },
        .aarch64 => {
            assert(la_ptr_addr >= stub_addr);
            outer: {
                const this_addr = stub_addr;
                const target_addr = la_ptr_addr;
                inner: {
                    const displacement = math.divExact(u64, target_addr - this_addr, 4) catch break :inner;
                    const literal = math.cast(u18, displacement) catch break :inner;
                    // ldr x16, literal
                    mem.writeIntLittle(u32, code[0..4], aarch64.Instruction.ldr(.x16, .{
                        .literal = literal,
                    }).toU32());
                    // nop
                    mem.writeIntLittle(u32, code[4..8], aarch64.Instruction.nop().toU32());
                    break :outer;
                }
                inner: {
                    const new_this_addr = this_addr + @sizeOf(u32);
                    const displacement = math.divExact(u64, target_addr - new_this_addr, 4) catch break :inner;
                    const literal = math.cast(u18, displacement) catch break :inner;
                    // nop
                    mem.writeIntLittle(u32, code[0..4], aarch64.Instruction.nop().toU32());
                    // ldr x16, literal
                    mem.writeIntLittle(u32, code[4..8], aarch64.Instruction.ldr(.x16, .{
                        .literal = literal,
                    }).toU32());
                    break :outer;
                }
                // Use adrp followed by ldr(register).
                const this_page = @intCast(i32, this_addr >> 12);
                const target_page = @intCast(i32, target_addr >> 12);
                const pages = @intCast(i21, target_page - this_page);
                // adrp x16, pages
                mem.writeIntLittle(u32, code[0..4], aarch64.Instruction.adrp(.x16, pages).toU32());
                const narrowed = @truncate(u12, target_addr);
                const offset = try math.divExact(u12, narrowed, 8);
                // ldr x16, x16, offset
                mem.writeIntLittle(u32, code[4..8], aarch64.Instruction.ldr(.x16, .{
                    .register = .{
                        .rn = .x16,
                        .offset = aarch64.Instruction.LoadStoreOffset.imm(offset),
                    },
                }).toU32());
            }
            // br x16
            mem.writeIntLittle(u32, code[8..12], aarch64.Instruction.br(.x16).toU32());
        },
        else => unreachable,
    }
    try self.base.file.?.pwriteAll(code, stub_off);
}

fn writeStubInStubHelper(self: *MachO, index: u32) !void {
    const text_segment = self.load_commands.items[self.text_segment_cmd_index.?].Segment;
    const stub_helper = text_segment.sections.items[self.stub_helper_section_index.?];

    const stub_size: u4 = switch (self.base.options.target.cpu.arch) {
        .x86_64 => 10,
        .aarch64 => 3 * @sizeOf(u32),
        else => unreachable,
    };
    const stub_off = self.stub_helper_stubs_start_off.? + index * stub_size;

    var code = try self.base.allocator.alloc(u8, stub_size);
    defer self.base.allocator.free(code);

    switch (self.base.options.target.cpu.arch) {
        .x86_64 => {
            const displacement = try math.cast(
                i32,
                @intCast(i64, stub_helper.offset) - @intCast(i64, stub_off) - stub_size,
            );
            // pushq
            code[0] = 0x68;
            mem.writeIntLittle(u32, code[1..][0..4], 0x0); // Just a placeholder populated in `populateLazyBindOffsetsInStubHelper`.
            // jmpq
            code[5] = 0xe9;
            mem.writeIntLittle(u32, code[6..][0..4], @bitCast(u32, displacement));
        },
        .aarch64 => {
            const literal = blk: {
                const div_res = try math.divExact(u64, stub_size - @sizeOf(u32), 4);
                break :blk try math.cast(u18, div_res);
            };
            // ldr w16, literal
            mem.writeIntLittle(u32, code[0..4], aarch64.Instruction.ldr(.w16, .{
                .literal = literal,
            }).toU32());
            const displacement = try math.cast(i28, @intCast(i64, stub_helper.offset) - @intCast(i64, stub_off) - 4);
            // b disp
            mem.writeIntLittle(u32, code[4..8], aarch64.Instruction.b(displacement).toU32());
            // Just a placeholder populated in `populateLazyBindOffsetsInStubHelper`.
            mem.writeIntLittle(u32, code[8..12], 0x0);
        },
        else => unreachable,
    }
    try self.base.file.?.pwriteAll(code, stub_off);
}

fn relocateSymbolTable(self: *MachO) !void {
    const symtab = &self.load_commands.items[self.symtab_cmd_index.?].Symtab;
    const nlocals = self.locals.items.len;
    const nglobals = self.globals.items.len;
    const nundefs = self.lazy_imports.count() + self.nonlazy_imports.count();
    const nsyms = nlocals + nglobals + nundefs;

    if (symtab.nsyms < nsyms) {
        const needed_size = nsyms * @sizeOf(macho.nlist_64);
        if (needed_size > self.allocatedSizeLinkedit(symtab.symoff)) {
            // Move the entire symbol table to a new location
            const new_symoff = self.findFreeSpaceLinkedit(needed_size, @alignOf(macho.nlist_64), null);
            const existing_size = symtab.nsyms * @sizeOf(macho.nlist_64);

            log.debug("relocating symbol table from 0x{x}-0x{x} to 0x{x}-0x{x}", .{
                symtab.symoff,
                symtab.symoff + existing_size,
                new_symoff,
                new_symoff + existing_size,
            });

            const amt = try self.base.file.?.copyRangeAll(symtab.symoff, self.base.file.?, new_symoff, existing_size);
            if (amt != existing_size) return error.InputOutput;
            symtab.symoff = @intCast(u32, new_symoff);
            self.string_table_needs_relocation = true;
        }
        symtab.nsyms = @intCast(u32, nsyms);
        self.load_commands_dirty = true;
    }
}

fn writeLocalSymbol(self: *MachO, index: usize) !void {
    const tracy = trace(@src());
    defer tracy.end();
    try self.relocateSymbolTable();
    const symtab = &self.load_commands.items[self.symtab_cmd_index.?].Symtab;
    const off = symtab.symoff + @sizeOf(macho.nlist_64) * index;
    log.debug("writing local symbol {} at 0x{x}", .{ index, off });
    try self.base.file.?.pwriteAll(mem.asBytes(&self.locals.items[index]), off);
}

fn writeAllGlobalAndUndefSymbols(self: *MachO) !void {
    const tracy = trace(@src());
    defer tracy.end();

    try self.relocateSymbolTable();
    const symtab = &self.load_commands.items[self.symtab_cmd_index.?].Symtab;
    const nlocals = self.locals.items.len;
    const nglobals = self.globals.items.len;

    const nundefs = self.lazy_imports.count() + self.nonlazy_imports.count();
    var undefs = std.ArrayList(macho.nlist_64).init(self.base.allocator);
    defer undefs.deinit();
    try undefs.ensureCapacity(nundefs);
    for (self.lazy_imports.values()) |*value| {
        undefs.appendAssumeCapacity(value.symbol);
    }
    for (self.nonlazy_imports.values()) |*value| {
        undefs.appendAssumeCapacity(value.symbol);
    }

    const locals_off = symtab.symoff;
    const locals_size = nlocals * @sizeOf(macho.nlist_64);

    const globals_off = locals_off + locals_size;
    const globals_size = nglobals * @sizeOf(macho.nlist_64);
    log.debug("writing global symbols from 0x{x} to 0x{x}", .{ globals_off, globals_size + globals_off });
    try self.base.file.?.pwriteAll(mem.sliceAsBytes(self.globals.items), globals_off);

    const undefs_off = globals_off + globals_size;
    const undefs_size = nundefs * @sizeOf(macho.nlist_64);
    log.debug("writing extern symbols from 0x{x} to 0x{x}", .{ undefs_off, undefs_size + undefs_off });
    try self.base.file.?.pwriteAll(mem.sliceAsBytes(undefs.items), undefs_off);

    // Update dynamic symbol table.
    const dysymtab = &self.load_commands.items[self.dysymtab_cmd_index.?].Dysymtab;
    dysymtab.nlocalsym = @intCast(u32, nlocals);
    dysymtab.iextdefsym = @intCast(u32, nlocals);
    dysymtab.nextdefsym = @intCast(u32, nglobals);
    dysymtab.iundefsym = @intCast(u32, nlocals + nglobals);
    dysymtab.nundefsym = @intCast(u32, nundefs);
    self.load_commands_dirty = true;
}

fn writeIndirectSymbolTable(self: *MachO) !void {
    // TODO figure out a way not to rewrite the table every time if
    // no new undefs are not added.
    const tracy = trace(@src());
    defer tracy.end();

    const text_segment = &self.load_commands.items[self.text_segment_cmd_index.?].Segment;
    const stubs = &text_segment.sections.items[self.stubs_section_index.?];
    const data_const_seg = &self.load_commands.items[self.data_const_segment_cmd_index.?].Segment;
    const got = &data_const_seg.sections.items[self.got_section_index.?];
    const data_segment = &self.load_commands.items[self.data_segment_cmd_index.?].Segment;
    const la_symbol_ptr = &data_segment.sections.items[self.la_symbol_ptr_section_index.?];
    const dysymtab = &self.load_commands.items[self.dysymtab_cmd_index.?].Dysymtab;

    const lazy_count = self.lazy_imports.count();
    const got_entries = self.offset_table.items;
    const allocated_size = self.allocatedSizeLinkedit(dysymtab.indirectsymoff);
    const nindirectsyms = @intCast(u32, lazy_count * 2 + got_entries.len);
    const needed_size = @intCast(u32, nindirectsyms * @sizeOf(u32));

    if (needed_size > allocated_size) {
        dysymtab.nindirectsyms = 0;
        dysymtab.indirectsymoff = @intCast(u32, self.findFreeSpaceLinkedit(needed_size, @sizeOf(u32), null));
    }
    dysymtab.nindirectsyms = nindirectsyms;
    log.debug("writing indirect symbol table from 0x{x} to 0x{x}", .{
        dysymtab.indirectsymoff,
        dysymtab.indirectsymoff + needed_size,
    });

    var buf = try self.base.allocator.alloc(u8, needed_size);
    defer self.base.allocator.free(buf);
    var stream = std.io.fixedBufferStream(buf);
    var writer = stream.writer();

    stubs.reserved1 = 0;
    {
        var i: usize = 0;
        while (i < lazy_count) : (i += 1) {
            const symtab_idx = @intCast(u32, dysymtab.iundefsym + i);
            try writer.writeIntLittle(u32, symtab_idx);
        }
    }

    const base_id = @intCast(u32, lazy_count);
    got.reserved1 = base_id;
    for (got_entries) |entry| {
        switch (entry.kind) {
            .Local => {
                try writer.writeIntLittle(u32, macho.INDIRECT_SYMBOL_LOCAL);
            },
            .Extern => {
                const symtab_idx = @intCast(u32, dysymtab.iundefsym + entry.index + base_id);
                try writer.writeIntLittle(u32, symtab_idx);
            },
        }
    }

    la_symbol_ptr.reserved1 = got.reserved1 + @intCast(u32, got_entries.len);
    {
        var i: usize = 0;
        while (i < lazy_count) : (i += 1) {
            const symtab_idx = @intCast(u32, dysymtab.iundefsym + i);
            try writer.writeIntLittle(u32, symtab_idx);
        }
    }

    try self.base.file.?.pwriteAll(buf, dysymtab.indirectsymoff);
    self.load_commands_dirty = true;
}

fn writeCodeSignaturePadding(self: *MachO) !void {
    // TODO figure out how not to rewrite padding every single time.
    const tracy = trace(@src());
    defer tracy.end();

    const linkedit_segment = &self.load_commands.items[self.linkedit_segment_cmd_index.?].Segment;
    const code_sig_cmd = &self.load_commands.items[self.code_signature_cmd_index.?].LinkeditData;
    const fileoff = linkedit_segment.inner.fileoff + linkedit_segment.inner.filesize;
    const needed_size = CodeSignature.calcCodeSignaturePaddingSize(
        self.base.options.emit.?.sub_path,
        fileoff,
        self.page_size,
    );
    code_sig_cmd.dataoff = @intCast(u32, fileoff);
    code_sig_cmd.datasize = needed_size;

    // Advance size of __LINKEDIT segment
    linkedit_segment.inner.filesize += needed_size;
    if (linkedit_segment.inner.vmsize < linkedit_segment.inner.filesize) {
        linkedit_segment.inner.vmsize = mem.alignForwardGeneric(u64, linkedit_segment.inner.filesize, self.page_size);
    }
    log.debug("writing code signature padding from 0x{x} to 0x{x}", .{ fileoff, fileoff + needed_size });
    // Pad out the space. We need to do this to calculate valid hashes for everything in the file
    // except for code signature data.
    try self.base.file.?.pwriteAll(&[_]u8{0}, fileoff + needed_size - 1);
    self.load_commands_dirty = true;
}

fn writeCodeSignature(self: *MachO) !void {
    const tracy = trace(@src());
    defer tracy.end();

    const text_segment = self.load_commands.items[self.text_segment_cmd_index.?].Segment;
    const code_sig_cmd = self.load_commands.items[self.code_signature_cmd_index.?].LinkeditData;

    var code_sig = CodeSignature.init(self.base.allocator, self.page_size);
    defer code_sig.deinit();
    try code_sig.calcAdhocSignature(
        self.base.file.?,
        self.base.options.emit.?.sub_path,
        text_segment.inner,
        code_sig_cmd,
        self.base.options.output_mode,
    );

    var buffer = try self.base.allocator.alloc(u8, code_sig.size());
    defer self.base.allocator.free(buffer);
    var stream = std.io.fixedBufferStream(buffer);
    try code_sig.write(stream.writer());

    log.debug("writing code signature from 0x{x} to 0x{x}", .{ code_sig_cmd.dataoff, code_sig_cmd.dataoff + buffer.len });

    try self.base.file.?.pwriteAll(buffer, code_sig_cmd.dataoff);
}

fn writeExportTrie(self: *MachO) !void {
    if (!self.export_info_dirty) return;
    if (self.globals.items.len == 0) return;

    const tracy = trace(@src());
    defer tracy.end();

    var trie = Trie.init(self.base.allocator);
    defer trie.deinit();

    const text_segment = self.load_commands.items[self.text_segment_cmd_index.?].Segment;
    for (self.globals.items) |symbol| {
        // TODO figure out if we should put all global symbols into the export trie
        const name = self.getString(symbol.n_strx);
        assert(symbol.n_value >= text_segment.inner.vmaddr);
        try trie.put(.{
            .name = name,
            .vmaddr_offset = symbol.n_value - text_segment.inner.vmaddr,
            .export_flags = macho.EXPORT_SYMBOL_FLAGS_KIND_REGULAR,
        });
    }

    try trie.finalize();
    var buffer = try self.base.allocator.alloc(u8, @intCast(usize, trie.size));
    defer self.base.allocator.free(buffer);
    var stream = std.io.fixedBufferStream(buffer);
    const nwritten = try trie.write(stream.writer());
    assert(nwritten == trie.size);

    const dyld_info = &self.load_commands.items[self.dyld_info_cmd_index.?].DyldInfoOnly;
    const allocated_size = self.allocatedSizeLinkedit(dyld_info.export_off);
    const needed_size = mem.alignForwardGeneric(u64, buffer.len, @alignOf(u64));

    if (needed_size > allocated_size) {
        dyld_info.export_off = 0;
        dyld_info.export_off = @intCast(u32, self.findFreeSpaceLinkedit(needed_size, 1, null));
        // TODO this might require relocating all following LC_DYLD_INFO_ONLY sections too.
    }
    dyld_info.export_size = @intCast(u32, needed_size);
    log.debug("writing export info from 0x{x} to 0x{x}", .{ dyld_info.export_off, dyld_info.export_off + dyld_info.export_size });

    try self.base.file.?.pwriteAll(buffer, dyld_info.export_off);
    self.load_commands_dirty = true;
    self.export_info_dirty = false;
}

fn writeRebaseInfoTable(self: *MachO) !void {
    if (!self.rebase_info_dirty) return;

    const tracy = trace(@src());
    defer tracy.end();

    var pointers = std.ArrayList(bind.Pointer).init(self.base.allocator);
    defer pointers.deinit();

    if (self.got_section_index) |idx| {
        const seg = self.load_commands.items[self.data_const_segment_cmd_index.?].Segment;
        const sect = seg.sections.items[idx];
        const base_offset = sect.addr - seg.inner.vmaddr;
        const segment_id = self.data_const_segment_cmd_index.?;

        for (self.offset_table.items) |entry| {
            if (entry.kind == .Extern) continue;
            try pointers.append(.{
                .offset = base_offset + entry.index * @sizeOf(u64),
                .segment_id = segment_id,
            });
        }
    }

    if (self.la_symbol_ptr_section_index) |idx| {
        try pointers.ensureCapacity(pointers.items.len + self.lazy_imports.count());
        const seg = self.load_commands.items[self.data_segment_cmd_index.?].Segment;
        const sect = seg.sections.items[idx];
        const base_offset = sect.addr - seg.inner.vmaddr;
        const segment_id = self.data_segment_cmd_index.?;

        for (self.lazy_imports.values()) |*value| {
            pointers.appendAssumeCapacity(.{
                .offset = base_offset + value.index * @sizeOf(u64),
                .segment_id = segment_id,
            });
        }
    }

    std.sort.sort(bind.Pointer, pointers.items, {}, bind.pointerCmp);

    const size = try bind.rebaseInfoSize(pointers.items);
    var buffer = try self.base.allocator.alloc(u8, @intCast(usize, size));
    defer self.base.allocator.free(buffer);

    var stream = std.io.fixedBufferStream(buffer);
    try bind.writeRebaseInfo(pointers.items, stream.writer());

    const dyld_info = &self.load_commands.items[self.dyld_info_cmd_index.?].DyldInfoOnly;
    const allocated_size = self.allocatedSizeLinkedit(dyld_info.rebase_off);
    const needed_size = mem.alignForwardGeneric(u64, buffer.len, @alignOf(u64));

    if (needed_size > allocated_size) {
        dyld_info.rebase_off = 0;
        dyld_info.rebase_off = @intCast(u32, self.findFreeSpaceLinkedit(needed_size, 1, null));
        // TODO this might require relocating all following LC_DYLD_INFO_ONLY sections too.
    }

    dyld_info.rebase_size = @intCast(u32, needed_size);
    log.debug("writing rebase info from 0x{x} to 0x{x}", .{ dyld_info.rebase_off, dyld_info.rebase_off + dyld_info.rebase_size });

    try self.base.file.?.pwriteAll(buffer, dyld_info.rebase_off);
    self.load_commands_dirty = true;
    self.rebase_info_dirty = false;
}

fn writeBindingInfoTable(self: *MachO) !void {
    if (!self.binding_info_dirty) return;

    const tracy = trace(@src());
    defer tracy.end();

    var pointers = std.ArrayList(bind.Pointer).init(self.base.allocator);
    defer pointers.deinit();

    if (self.got_section_index) |idx| {
        const seg = self.load_commands.items[self.data_const_segment_cmd_index.?].Segment;
        const sect = seg.sections.items[idx];
        const base_offset = sect.addr - seg.inner.vmaddr;
        const segment_id = @intCast(u16, self.data_const_segment_cmd_index.?);

        for (self.offset_table.items) |entry| {
            if (entry.kind == .Local) continue;
            const import_key = self.nonlazy_imports.keys()[entry.symbol];
            const import_ordinal = self.nonlazy_imports.values()[entry.symbol].dylib_ordinal;
            try pointers.append(.{
                .offset = base_offset + entry.index * @sizeOf(u64),
                .segment_id = segment_id,
                .dylib_ordinal = import_ordinal,
                .name = import_key,
            });
        }
    }

    const size = try bind.bindInfoSize(pointers.items);
    var buffer = try self.base.allocator.alloc(u8, @intCast(usize, size));
    defer self.base.allocator.free(buffer);

    var stream = std.io.fixedBufferStream(buffer);
    try bind.writeBindInfo(pointers.items, stream.writer());

    const dyld_info = &self.load_commands.items[self.dyld_info_cmd_index.?].DyldInfoOnly;
    const allocated_size = self.allocatedSizeLinkedit(dyld_info.bind_off);
    const needed_size = mem.alignForwardGeneric(u64, buffer.len, @alignOf(u64));

    if (needed_size > allocated_size) {
        dyld_info.bind_off = 0;
        dyld_info.bind_off = @intCast(u32, self.findFreeSpaceLinkedit(needed_size, 1, null));
        // TODO this might require relocating all following LC_DYLD_INFO_ONLY sections too.
    }

    dyld_info.bind_size = @intCast(u32, needed_size);
    log.debug("writing binding info from 0x{x} to 0x{x}", .{ dyld_info.bind_off, dyld_info.bind_off + dyld_info.bind_size });

    try self.base.file.?.pwriteAll(buffer, dyld_info.bind_off);
    self.load_commands_dirty = true;
    self.binding_info_dirty = false;
}

fn writeLazyBindingInfoTable(self: *MachO) !void {
    if (!self.lazy_binding_info_dirty) return;

    const tracy = trace(@src());
    defer tracy.end();

    var pointers = std.ArrayList(bind.Pointer).init(self.base.allocator);
    defer pointers.deinit();

    if (self.la_symbol_ptr_section_index) |idx| {
        try pointers.ensureCapacity(self.lazy_imports.count());
        const seg = self.load_commands.items[self.data_segment_cmd_index.?].Segment;
        const sect = seg.sections.items[idx];
        const base_offset = sect.addr - seg.inner.vmaddr;
        const segment_id = @intCast(u16, self.data_segment_cmd_index.?);

        const slice = self.lazy_imports.entries.slice();
        const keys = slice.items(.key);
        const values = slice.items(.value);
        for (keys) |*key, i| {
            pointers.appendAssumeCapacity(.{
                .offset = base_offset + values[i].index * @sizeOf(u64),
                .segment_id = segment_id,
                .dylib_ordinal = values[i].dylib_ordinal,
                .name = key.*,
            });
        }
    }

    const size = try bind.lazyBindInfoSize(pointers.items);
    var buffer = try self.base.allocator.alloc(u8, @intCast(usize, size));
    defer self.base.allocator.free(buffer);

    var stream = std.io.fixedBufferStream(buffer);
    try bind.writeLazyBindInfo(pointers.items, stream.writer());

    const dyld_info = &self.load_commands.items[self.dyld_info_cmd_index.?].DyldInfoOnly;
    const allocated_size = self.allocatedSizeLinkedit(dyld_info.lazy_bind_off);
    const needed_size = mem.alignForwardGeneric(u64, buffer.len, @alignOf(u64));

    if (needed_size > allocated_size) {
        dyld_info.lazy_bind_off = 0;
        dyld_info.lazy_bind_off = @intCast(u32, self.findFreeSpaceLinkedit(needed_size, 1, null));
        // TODO this might require relocating all following LC_DYLD_INFO_ONLY sections too.
    }

    dyld_info.lazy_bind_size = @intCast(u32, needed_size);
    log.debug("writing lazy binding info from 0x{x} to 0x{x}", .{ dyld_info.lazy_bind_off, dyld_info.lazy_bind_off + dyld_info.lazy_bind_size });

    try self.base.file.?.pwriteAll(buffer, dyld_info.lazy_bind_off);
    try self.populateLazyBindOffsetsInStubHelper(buffer);
    self.load_commands_dirty = true;
    self.lazy_binding_info_dirty = false;
}

fn populateLazyBindOffsetsInStubHelper(self: *MachO, buffer: []const u8) !void {
    if (self.lazy_imports.count() == 0) return;

    var stream = std.io.fixedBufferStream(buffer);
    var reader = stream.reader();
    var offsets = std.ArrayList(u32).init(self.base.allocator);
    try offsets.append(0);
    defer offsets.deinit();
    var valid_block = false;

    while (true) {
        const inst = reader.readByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        const opcode: u8 = inst & macho.BIND_OPCODE_MASK;

        switch (opcode) {
            macho.BIND_OPCODE_DO_BIND => {
                valid_block = true;
            },
            macho.BIND_OPCODE_DONE => {
                if (valid_block) {
                    const offset = try stream.getPos();
                    try offsets.append(@intCast(u32, offset));
                }
                valid_block = false;
            },
            macho.BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM => {
                var next = try reader.readByte();
                while (next != @as(u8, 0)) {
                    next = try reader.readByte();
                }
            },
            macho.BIND_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB => {
                _ = try std.leb.readULEB128(u64, reader);
            },
            macho.BIND_OPCODE_SET_DYLIB_ORDINAL_ULEB => {
                _ = try std.leb.readULEB128(u64, reader);
            },
            macho.BIND_OPCODE_SET_ADDEND_SLEB => {
                _ = try std.leb.readILEB128(i64, reader);
            },
            else => {},
        }
    }
    assert(self.lazy_imports.count() <= offsets.items.len);

    const stub_size: u4 = switch (self.base.options.target.cpu.arch) {
        .x86_64 => 10,
        .aarch64 => 3 * @sizeOf(u32),
        else => unreachable,
    };
    const off: u4 = switch (self.base.options.target.cpu.arch) {
        .x86_64 => 1,
        .aarch64 => 2 * @sizeOf(u32),
        else => unreachable,
    };
    var buf: [@sizeOf(u32)]u8 = undefined;
    for (offsets.items[0..self.lazy_imports.count()]) |offset, i| {
        const placeholder_off = self.stub_helper_stubs_start_off.? + i * stub_size + off;
        mem.writeIntLittle(u32, &buf, offset);
        try self.base.file.?.pwriteAll(&buf, placeholder_off);
    }
}

fn writeStringTable(self: *MachO) !void {
    if (!self.string_table_dirty) return;

    const tracy = trace(@src());
    defer tracy.end();

    const symtab = &self.load_commands.items[self.symtab_cmd_index.?].Symtab;
    const allocated_size = self.allocatedSizeLinkedit(symtab.stroff);
    const needed_size = mem.alignForwardGeneric(u64, self.string_table.items.len, @alignOf(u64));

    if (needed_size > allocated_size or self.string_table_needs_relocation) {
        symtab.strsize = 0;
        symtab.stroff = @intCast(u32, self.findFreeSpaceLinkedit(needed_size, 1, symtab.symoff));
        self.string_table_needs_relocation = false;
    }
    symtab.strsize = @intCast(u32, needed_size);
    log.debug("writing string table from 0x{x} to 0x{x}", .{ symtab.stroff, symtab.stroff + symtab.strsize });

    try self.base.file.?.pwriteAll(self.string_table.items, symtab.stroff);
    self.load_commands_dirty = true;
    self.string_table_dirty = false;
}

fn updateLinkeditSegmentSizes(self: *MachO) !void {
    if (!self.load_commands_dirty) return;

    const tracy = trace(@src());
    defer tracy.end();

    // Now, we are in position to update __LINKEDIT segment sizes.
    // TODO Add checkpointing so that we don't have to do this every single time.
    const linkedit_segment = &self.load_commands.items[self.linkedit_segment_cmd_index.?].Segment;
    var final_offset = linkedit_segment.inner.fileoff;

    if (self.dyld_info_cmd_index) |idx| {
        const dyld_info = self.load_commands.items[idx].DyldInfoOnly;
        final_offset = std.math.max(final_offset, dyld_info.rebase_off + dyld_info.rebase_size);
        final_offset = std.math.max(final_offset, dyld_info.bind_off + dyld_info.bind_size);
        final_offset = std.math.max(final_offset, dyld_info.weak_bind_off + dyld_info.weak_bind_size);
        final_offset = std.math.max(final_offset, dyld_info.lazy_bind_off + dyld_info.lazy_bind_size);
        final_offset = std.math.max(final_offset, dyld_info.export_off + dyld_info.export_size);
    }
    if (self.function_starts_cmd_index) |idx| {
        const fstart = self.load_commands.items[idx].LinkeditData;
        final_offset = std.math.max(final_offset, fstart.dataoff + fstart.datasize);
    }
    if (self.data_in_code_cmd_index) |idx| {
        const dic = self.load_commands.items[idx].LinkeditData;
        final_offset = std.math.max(final_offset, dic.dataoff + dic.datasize);
    }
    if (self.dysymtab_cmd_index) |idx| {
        const dysymtab = self.load_commands.items[idx].Dysymtab;
        const nindirectsize = dysymtab.nindirectsyms * @sizeOf(u32);
        final_offset = std.math.max(final_offset, dysymtab.indirectsymoff + nindirectsize);
        // TODO Handle more dynamic symbol table sections.
    }
    if (self.symtab_cmd_index) |idx| {
        const symtab = self.load_commands.items[idx].Symtab;
        const symsize = symtab.nsyms * @sizeOf(macho.nlist_64);
        final_offset = std.math.max(final_offset, symtab.symoff + symsize);
        final_offset = std.math.max(final_offset, symtab.stroff + symtab.strsize);
    }

    const filesize = final_offset - linkedit_segment.inner.fileoff;
    linkedit_segment.inner.filesize = filesize;
    linkedit_segment.inner.vmsize = mem.alignForwardGeneric(u64, filesize, self.page_size);
    try self.base.file.?.pwriteAll(&[_]u8{0}, final_offset);
    self.load_commands_dirty = true;
}

/// Writes all load commands and section headers.
fn writeLoadCommands(self: *MachO) !void {
    if (!self.load_commands_dirty) return;

    var sizeofcmds: u32 = 0;
    for (self.load_commands.items) |lc| {
        sizeofcmds += lc.cmdsize();
    }

    var buffer = try self.base.allocator.alloc(u8, sizeofcmds);
    defer self.base.allocator.free(buffer);
    var writer = std.io.fixedBufferStream(buffer).writer();
    for (self.load_commands.items) |lc| {
        try lc.write(writer);
    }

    const off = @sizeOf(macho.mach_header_64);
    log.debug("writing {} load commands from 0x{x} to 0x{x}", .{ self.load_commands.items.len, off, off + sizeofcmds });
    try self.base.file.?.pwriteAll(buffer, off);
    self.load_commands_dirty = false;
}

/// Writes Mach-O file header.
fn writeHeader(self: *MachO) !void {
    if (!self.header_dirty) return;

    self.header.?.ncmds = @intCast(u32, self.load_commands.items.len);
    var sizeofcmds: u32 = 0;
    for (self.load_commands.items) |cmd| {
        sizeofcmds += cmd.cmdsize();
    }
    self.header.?.sizeofcmds = sizeofcmds;
    log.debug("writing Mach-O header {}", .{self.header.?});
    try self.base.file.?.pwriteAll(mem.asBytes(&self.header.?), 0);
    self.header_dirty = false;
}

pub fn padToIdeal(actual_size: anytype) @TypeOf(actual_size) {
    // TODO https://github.com/ziglang/zig/issues/1284
    return std.math.add(@TypeOf(actual_size), actual_size, actual_size / ideal_factor) catch
        std.math.maxInt(@TypeOf(actual_size));
}
