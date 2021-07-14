const Wasm = @This();

const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const fs = std.fs;
const leb = std.leb;
const log = std.log.scoped(.link);
const wasm = std.wasm;

const Module = @import("../Module.zig");
const Compilation = @import("../Compilation.zig");
const codegen = @import("../codegen/wasm.zig");
const link = @import("../link.zig");
const trace = @import("../tracy.zig").trace;
const build_options = @import("build_options");
const wasi_libc = @import("../wasi_libc.zig");
const Cache = @import("../Cache.zig");
const TypedValue = @import("../TypedValue.zig");
const Air = @import("../Air.zig");
const Liveness = @import("../Liveness.zig");

pub const base_tag = link.File.Tag.wasm;

base: link.File,
/// List of all function Decls to be written to the output file. The index of
/// each Decl in this list at the time of writing the binary is used as the
/// function index. In the event where ext_funcs' size is not 0, the index of
/// each function is added on top of the ext_funcs' length.
/// TODO: can/should we access some data structure in Module directly?
funcs: std.ArrayListUnmanaged(*Module.Decl) = .{},
/// List of all extern function Decls to be written to the `import` section of the
/// wasm binary. The positin in the list defines the function index
ext_funcs: std.ArrayListUnmanaged(*Module.Decl) = .{},
/// When importing objects from the host environment, a name must be supplied.
/// LLVM uses "env" by default when none is given. This would be a good default for Zig
/// to support existing code.
/// TODO: Allow setting this through a flag?
host_name: []const u8 = "env",
/// The last `DeclBlock` that was initialized will be saved here.
last_block: ?*DeclBlock = null,
/// Table with offsets, each element represents an offset with the value being
/// the offset into the 'data' section where the data lives
offset_table: std.ArrayListUnmanaged(u32) = .{},
/// List of offset indexes which are free to be used for new decl's.
/// Each element's value points to an index into the offset_table.
offset_table_free_list: std.ArrayListUnmanaged(u32) = .{},
/// List of all `Decl` that are currently alive.
/// This is ment for bookkeeping so we can safely cleanup all codegen memory
/// when calling `deinit`
symbols: std.ArrayListUnmanaged(*Module.Decl) = .{},

pub const FnData = struct {
    /// Generated code for the type of the function
    functype: std.ArrayListUnmanaged(u8),
    /// Generated code for the body of the function
    code: std.ArrayListUnmanaged(u8),
    /// Locations in the generated code where function indexes must be filled in.
    /// This must be kept ordered by offset.
    idx_refs: std.ArrayListUnmanaged(struct { offset: u32, decl: *Module.Decl }),

    pub const empty: FnData = .{
        .functype = .{},
        .code = .{},
        .idx_refs = .{},
    };
};

pub const DeclBlock = struct {
    /// Determines whether the `DeclBlock` has been initialized for codegen.
    init: bool,
    /// Index into the `symbols` list.
    symbol_index: u32,
    /// Index into the offset table
    offset_index: u32,
    /// The size of the block and how large part of the data section it occupies.
    /// Will be 0 when the Decl will not live inside the data section and `data` will be undefined.
    size: u32,
    /// Points to the previous and next blocks.
    /// Can be used to find the total size, and used to calculate the `offset` based on the previous block.
    prev: ?*DeclBlock,
    next: ?*DeclBlock,
    /// Pointer to data that will be written to the 'data' section.
    /// This data either lives in `FnData.code` or is externally managed.
    /// For data that does not live inside the 'data' section, this field will be undefined. (size == 0).
    data: [*]const u8,

    pub const empty: DeclBlock = .{
        .init = false,
        .symbol_index = 0,
        .offset_index = 0,
        .size = 0,
        .prev = null,
        .next = null,
        .data = undefined,
    };

    /// Unplugs the `DeclBlock` from the chain
    fn unplug(self: *DeclBlock) void {
        if (self.prev) |prev| {
            prev.next = self.next;
        }

        if (self.next) |next| {
            next.prev = self.prev;
        }
        self.next = null;
        self.prev = null;
    }
};

pub fn openPath(allocator: *Allocator, sub_path: []const u8, options: link.Options) !*Wasm {
    assert(options.object_format == .wasm);

    if (options.use_llvm) return error.LLVM_BackendIsTODO_ForWasm; // TODO
    if (options.use_lld) return error.LLD_LinkingIsTODO_ForWasm; // TODO

    // TODO: read the file and keep valid parts instead of truncating
    const file = try options.emit.?.directory.handle.createFile(sub_path, .{ .truncate = true, .read = true });
    errdefer file.close();

    const wasm_bin = try createEmpty(allocator, options);
    errdefer wasm_bin.base.destroy();

    wasm_bin.base.file = file;

    try file.writeAll(&(wasm.magic ++ wasm.version));

    return wasm_bin;
}

pub fn createEmpty(gpa: *Allocator, options: link.Options) !*Wasm {
    const wasm_bin = try gpa.create(Wasm);
    wasm_bin.* = .{
        .base = .{
            .tag = .wasm,
            .options = options,
            .file = null,
            .allocator = gpa,
        },
    };
    return wasm_bin;
}

pub fn deinit(self: *Wasm) void {
    for (self.symbols.items) |decl| {
        decl.fn_link.wasm.functype.deinit(self.base.allocator);
        decl.fn_link.wasm.code.deinit(self.base.allocator);
        decl.fn_link.wasm.idx_refs.deinit(self.base.allocator);
    }

    self.funcs.deinit(self.base.allocator);
    self.ext_funcs.deinit(self.base.allocator);
    self.offset_table.deinit(self.base.allocator);
    self.offset_table_free_list.deinit(self.base.allocator);
    self.symbols.deinit(self.base.allocator);
}

pub fn allocateDeclIndexes(self: *Wasm, decl: *Module.Decl) !void {
    if (decl.link.wasm.init) return;

    try self.offset_table.ensureCapacity(self.base.allocator, self.offset_table.items.len + 1);
    try self.symbols.ensureCapacity(self.base.allocator, self.symbols.items.len + 1);

    const block = &decl.link.wasm;
    block.init = true;

    block.symbol_index = @intCast(u32, self.symbols.items.len);
    self.symbols.appendAssumeCapacity(decl);

    if (self.offset_table_free_list.popOrNull()) |index| {
        block.offset_index = index;
    } else {
        block.offset_index = @intCast(u32, self.offset_table.items.len);
        _ = self.offset_table.addOneAssumeCapacity();
    }

    self.offset_table.items[block.offset_index] = 0;

    if (decl.ty.zigTypeTag() == .Fn) {
        switch (decl.val.tag()) {
            // dependent on function type, appends it to the correct list
            .function => try self.funcs.append(self.base.allocator, decl),
            .extern_fn => try self.ext_funcs.append(self.base.allocator, decl),
            else => unreachable,
        }
    }
}

pub fn updateFunc(self: *Wasm, module: *Module, func: *Module.Fn, air: Air, liveness: Liveness) !void {
    if (build_options.skip_non_native and builtin.object_format != .wasm) {
        @panic("Attempted to compile for object format that was disabled by build configuration");
    }
    if (build_options.have_llvm) {
        if (self.llvm_object) |llvm_object| return llvm_object.updateFunc(module, func, air, liveness);
    }
    const decl = func.owner_decl;
    assert(decl.link.wasm.init); // Must call allocateDeclIndexes()

    const fn_data = &decl.fn_link.wasm;
    fn_data.functype.items.len = 0;
    fn_data.code.items.len = 0;
    fn_data.idx_refs.items.len = 0;

    var context = codegen.Context{
        .gpa = self.base.allocator,
        .air = air,
        .liveness = liveness,
        .values = .{},
        .code = fn_data.code.toManaged(self.base.allocator),
        .func_type_data = fn_data.functype.toManaged(self.base.allocator),
        .decl = decl,
        .err_msg = undefined,
        .locals = .{},
        .target = self.base.options.target,
        .global_error_set = self.base.options.module.?.global_error_set,
    };
    defer context.deinit();

    // generate the 'code' section for the function declaration
    const result = context.genFunc(func) catch |err| switch (err) {
        error.CodegenFail => {
            decl.analysis = .codegen_failure;
            try module.failed_decls.put(module.gpa, decl, context.err_msg);
            return;
        },
        else => |e| return e,
    };
    return self.finishUpdateDecl(decl, result);
}

// Generate code for the Decl, storing it in memory to be later written to
// the file on flush().
pub fn updateDecl(self: *Wasm, module: *Module, decl: *Module.Decl) !void {
    if (build_options.skip_non_native and builtin.object_format != .wasm) {
        @panic("Attempted to compile for object format that was disabled by build configuration");
    }
    if (build_options.have_llvm) {
        if (self.llvm_object) |llvm_object| return llvm_object.updateDecl(module, decl);
    }
    assert(decl.link.wasm.init); // Must call allocateDeclIndexes()

    // TODO don't use this for non-functions
    const fn_data = &decl.fn_link.wasm;
    fn_data.functype.items.len = 0;
    fn_data.code.items.len = 0;
    fn_data.idx_refs.items.len = 0;

    var context = codegen.Context{
        .gpa = self.base.allocator,
        .values = .{},
        .code = fn_data.code.toManaged(self.base.allocator),
        .func_type_data = fn_data.functype.toManaged(self.base.allocator),
        .decl = decl,
        .err_msg = undefined,
        .locals = .{},
        .target = self.base.options.target,
        .global_error_set = self.base.options.module.?.global_error_set,
    };
    defer context.deinit();

    // generate the 'code' section for the function declaration
    const result = context.gen(.{ .ty = decl.ty, .val = decl.val }) catch |err| switch (err) {
        error.CodegenFail => {
            decl.analysis = .codegen_failure;
            try module.failed_decls.put(module.gpa, decl, context.err_msg);
            return;
        },
        else => |e| return e,
    };
    return self.finishUpdateDecl(decl, result);
}

fn finishUpdateDecl(self: *Wasm, decl: *Module.Decl, result: codegen.Result) !void {
    const code: []const u8 = switch (result) {
        .appended => @as([]const u8, context.code.items),
        .externally_managed => |payload| payload,
    };

    fn_data.code = context.code.toUnmanaged();
    fn_data.functype = context.func_type_data.toUnmanaged();

    const block = &decl.link.wasm;
    if (decl.ty.zigTypeTag() == .Fn) {
        // as locals are patched afterwards, the offsets of funcidx's are off,
        // here we update them to correct them
        for (fn_data.idx_refs.items) |*func| {
            // For each local, add 6 bytes (count + type)
            func.offset += @intCast(u32, context.locals.items.len * 6);
        }
    } else {
        block.size = @intCast(u32, code.len);
        block.data = code.ptr;
    }

    // If we're updating an existing decl, unplug it first
    // to avoid infinite loops due to earlier links
    block.unplug();

    if (self.last_block) |last| {
        if (last != block) {
            last.next = block;
            block.prev = last;
        }
    }
    self.last_block = block;
}

pub fn updateDeclExports(
    self: *Wasm,
    module: *Module,
    decl: *const Module.Decl,
    exports: []const *Module.Export,
) !void {
    _ = self;
    _ = module;
    _ = decl;
    _ = exports;
}

pub fn freeDecl(self: *Wasm, decl: *Module.Decl) void {
    if (self.getFuncidx(decl)) |func_idx| {
        switch (decl.val.tag()) {
            .function => _ = self.funcs.swapRemove(func_idx),
            .extern_fn => _ = self.ext_funcs.swapRemove(func_idx),
            else => unreachable,
        }
    }
    const block = &decl.link.wasm;

    if (self.last_block == block) {
        self.last_block = block.prev;
    }

    block.unplug();

    self.offset_table_free_list.append(self.base.allocator, decl.link.wasm.offset_index) catch {};
    _ = self.symbols.swapRemove(block.symbol_index);

    // update symbol_index as we swap removed the last symbol into the removed's position
    if (block.symbol_index < self.symbols.items.len)
        self.symbols.items[block.symbol_index].link.wasm.symbol_index = block.symbol_index;

    block.init = false;

    decl.fn_link.wasm.functype.deinit(self.base.allocator);
    decl.fn_link.wasm.code.deinit(self.base.allocator);
    decl.fn_link.wasm.idx_refs.deinit(self.base.allocator);
    decl.fn_link.wasm = undefined;
}

pub fn flush(self: *Wasm, comp: *Compilation) !void {
    if (build_options.have_llvm and self.base.options.use_lld) {
        return self.linkWithLLD(comp);
    } else {
        return self.flushModule(comp);
    }
}

pub fn flushModule(self: *Wasm, comp: *Compilation) !void {
    _ = comp;
    const tracy = trace(@src());
    defer tracy.end();

    const file = self.base.file.?;
    const header_size = 5 + 1;
    // ptr_width in bytes
    const ptr_width = self.base.options.target.cpu.arch.ptrBitWidth() / 8;
    // The size of the offset table in bytes
    // The table contains all decl's with its corresponding offset into
    // the 'data' section
    const offset_table_size = @intCast(u32, self.offset_table.items.len * ptr_width);

    // The size of the data, this together with `offset_table_size` amounts to the
    // total size of the 'data' section
    var first_decl: ?*DeclBlock = null;
    const data_size: u32 = if (self.last_block) |last| blk: {
        var size = last.size;
        var cur = last;
        while (cur.prev) |prev| : (cur = prev) {
            size += prev.size;
        }
        first_decl = cur;
        break :blk size;
    } else 0;

    // No need to rewrite the magic/version header
    try file.setEndPos(@sizeOf(@TypeOf(wasm.magic ++ wasm.version)));
    try file.seekTo(@sizeOf(@TypeOf(wasm.magic ++ wasm.version)));

    // Type section
    {
        const header_offset = try reserveVecSectionHeader(file);

        // extern functions are defined in the wasm binary first through the `import`
        // section, so define their func types first
        for (self.ext_funcs.items) |decl| try file.writeAll(decl.fn_link.wasm.functype.items);
        for (self.funcs.items) |decl| try file.writeAll(decl.fn_link.wasm.functype.items);

        try writeVecSectionHeader(
            file,
            header_offset,
            .type,
            @intCast(u32, (try file.getPos()) - header_offset - header_size),
            @intCast(u32, self.ext_funcs.items.len + self.funcs.items.len),
        );
    }

    // Import section
    {
        // TODO: implement non-functions imports
        const header_offset = try reserveVecSectionHeader(file);
        const writer = file.writer();
        for (self.ext_funcs.items) |decl, typeidx| {
            try leb.writeULEB128(writer, @intCast(u32, self.host_name.len));
            try writer.writeAll(self.host_name);

            // wasm requires the length of the import name with no null-termination
            const decl_len = mem.len(decl.name);
            try leb.writeULEB128(writer, @intCast(u32, decl_len));
            try writer.writeAll(decl.name[0..decl_len]);

            // emit kind and the function type
            try writer.writeByte(wasm.externalKind(.function));
            try leb.writeULEB128(writer, @intCast(u32, typeidx));
        }

        try writeVecSectionHeader(
            file,
            header_offset,
            .import,
            @intCast(u32, (try file.getPos()) - header_offset - header_size),
            @intCast(u32, self.ext_funcs.items.len),
        );
    }

    // Function section
    {
        const header_offset = try reserveVecSectionHeader(file);
        const writer = file.writer();
        for (self.funcs.items) |_, typeidx| {
            const func_idx = @intCast(u32, self.getFuncIdxOffset() + typeidx);
            try leb.writeULEB128(writer, func_idx);
        }

        try writeVecSectionHeader(
            file,
            header_offset,
            .function,
            @intCast(u32, (try file.getPos()) - header_offset - header_size),
            @intCast(u32, self.funcs.items.len),
        );
    }

    // Memory section
    if (data_size != 0) {
        const header_offset = try reserveVecSectionHeader(file);
        const writer = file.writer();

        try leb.writeULEB128(writer, @as(u32, 0));
        // Calculate the amount of memory pages are required and write them.
        // Wasm uses 64kB page sizes. Round up to ensure the data segments fit into the memory
        try leb.writeULEB128(
            writer,
            try std.math.divCeil(
                u32,
                offset_table_size + data_size,
                std.wasm.page_size,
            ),
        );
        try writeVecSectionHeader(
            file,
            header_offset,
            .memory,
            @intCast(u32, (try file.getPos()) - header_offset - header_size),
            @as(u32, 1), // wasm currently only supports 1 linear memory segment
        );
    }

    // Export section
    if (self.base.options.module) |module| {
        const header_offset = try reserveVecSectionHeader(file);
        const writer = file.writer();
        var count: u32 = 0;
        for (module.decl_exports.values()) |exports| {
            for (exports) |exprt| {
                // Export name length + name
                try leb.writeULEB128(writer, @intCast(u32, exprt.options.name.len));
                try writer.writeAll(exprt.options.name);

                switch (exprt.exported_decl.ty.zigTypeTag()) {
                    .Fn => {
                        // Type of the export
                        try writer.writeByte(wasm.externalKind(.function));
                        // Exported function index
                        try leb.writeULEB128(writer, self.getFuncidx(exprt.exported_decl).?);
                    },
                    else => return error.TODOImplementNonFnDeclsForWasm,
                }

                count += 1;
            }
        }

        // export memory if size is not 0
        if (data_size != 0) {
            try leb.writeULEB128(writer, @intCast(u32, "memory".len));
            try writer.writeAll("memory");
            try writer.writeByte(wasm.externalKind(.memory));
            try leb.writeULEB128(writer, @as(u32, 0)); // only 1 memory 'object' can exist
            count += 1;
        }

        try writeVecSectionHeader(
            file,
            header_offset,
            .@"export",
            @intCast(u32, (try file.getPos()) - header_offset - header_size),
            count,
        );
    }

    // Code section
    {
        const header_offset = try reserveVecSectionHeader(file);
        const writer = file.writer();
        for (self.funcs.items) |decl| {
            const fn_data = &decl.fn_link.wasm;

            // Write the already generated code to the file, inserting
            // function indexes where required.
            var current: u32 = 0;
            for (fn_data.idx_refs.items) |idx_ref| {
                try writer.writeAll(fn_data.code.items[current..idx_ref.offset]);
                current = idx_ref.offset;
                // Use a fixed width here to make calculating the code size
                // in codegen.wasm.gen() simpler.
                var buf: [5]u8 = undefined;
                leb.writeUnsignedFixed(5, &buf, self.getFuncidx(idx_ref.decl).?);
                try writer.writeAll(&buf);
            }

            try writer.writeAll(fn_data.code.items[current..]);
        }
        try writeVecSectionHeader(
            file,
            header_offset,
            .code,
            @intCast(u32, (try file.getPos()) - header_offset - header_size),
            @intCast(u32, self.funcs.items.len),
        );
    }

    // Data section
    if (data_size != 0) {
        const header_offset = try reserveVecSectionHeader(file);
        const writer = file.writer();
        // index to memory section (currently, there can only be 1 memory section in wasm)
        try leb.writeULEB128(writer, @as(u32, 0));

        // offset into data section
        try writer.writeByte(wasm.opcode(.i32_const));
        try leb.writeILEB128(writer, @as(i32, 0));
        try writer.writeByte(wasm.opcode(.end));

        const total_size = offset_table_size + data_size;

        // offset table + data size
        try leb.writeULEB128(writer, total_size);

        // fill in the offset table and the data segments
        const file_offset = try file.getPos();
        var cur = first_decl;
        var data_offset = offset_table_size;
        while (cur) |cur_block| : (cur = cur_block.next) {
            if (cur_block.size == 0) continue;
            assert(cur_block.init);

            const offset = (cur_block.offset_index) * ptr_width;
            var buf: [4]u8 = undefined;
            std.mem.writeIntLittle(u32, &buf, data_offset);

            try file.pwriteAll(&buf, file_offset + offset);
            try file.pwriteAll(cur_block.data[0..cur_block.size], file_offset + data_offset);
            data_offset += cur_block.size;
        }

        try file.seekTo(file_offset + data_offset);
        try writeVecSectionHeader(
            file,
            header_offset,
            .data,
            @intCast(u32, (file_offset + data_offset) - header_offset - header_size),
            @intCast(u32, 1), // only 1 data section
        );
    }
}

fn linkWithLLD(self: *Wasm, comp: *Compilation) !void {
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

    const compiler_rt_path: ?[]const u8 = if (self.base.options.include_compiler_rt)
        comp.compiler_rt_static_lib.?.full_object_path
    else
        null;

    const target = self.base.options.target;

    const id_symlink_basename = "lld.id";

    var man: Cache.Manifest = undefined;
    defer if (!self.base.options.disable_lld_caching) man.deinit();

    var digest: [Cache.hex_digest_len]u8 = undefined;

    if (!self.base.options.disable_lld_caching) {
        man = comp.cache_parent.obtain();

        // We are about to obtain this lock, so here we give other processes a chance first.
        self.base.releaseLock();

        try man.addListOfFiles(self.base.options.objects);
        for (comp.c_object_table.keys()) |key| {
            _ = try man.addFile(key.status.success.object_path, null);
        }
        try man.addOptionalFile(module_obj_path);
        try man.addOptionalFile(compiler_rt_path);
        man.hash.addOptional(self.base.options.stack_size_override);
        man.hash.addListOfBytes(self.base.options.extra_lld_args);

        // We don't actually care whether it's a cache hit or miss; we just need the digest and the lock.
        _ = try man.hit();
        digest = man.final();

        var prev_digest_buf: [digest.len]u8 = undefined;
        const prev_digest: []u8 = Cache.readSmallFile(
            directory.handle,
            id_symlink_basename,
            &prev_digest_buf,
        ) catch |err| blk: {
            log.debug("WASM LLD new_digest={s} error: {s}", .{ std.fmt.fmtSliceHexLower(&digest), @errorName(err) });
            // Handle this as a cache miss.
            break :blk prev_digest_buf[0..0];
        };
        if (mem.eql(u8, prev_digest, &digest)) {
            log.debug("WASM LLD digest={s} match - skipping invocation", .{std.fmt.fmtSliceHexLower(&digest)});
            // Hot diggity dog! The output binary is already there.
            self.base.lock = man.toOwnedLock();
            return;
        }
        log.debug("WASM LLD prev_digest={s} new_digest={s}", .{ std.fmt.fmtSliceHexLower(prev_digest), std.fmt.fmtSliceHexLower(&digest) });

        // We are about to change the output file to be different, so we invalidate the build hash now.
        directory.handle.deleteFile(id_symlink_basename) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        };
    }

    const full_out_path = try directory.join(arena, &[_][]const u8{self.base.options.emit.?.sub_path});

    if (self.base.options.output_mode == .Obj) {
        // LLD's WASM driver does not support the equvialent of `-r` so we do a simple file copy
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
        // Create an LLD command line and invoke it.
        var argv = std.ArrayList([]const u8).init(self.base.allocator);
        defer argv.deinit();
        // We will invoke ourselves as a child process to gain access to LLD.
        // This is necessary because LLD does not behave properly as a library -
        // it calls exit() and does not reset all global data between invocations.
        try argv.appendSlice(&[_][]const u8{ comp.self_exe_path.?, "wasm-ld" });
        try argv.append("-error-limit=0");

        if (self.base.options.lto) {
            switch (self.base.options.optimize_mode) {
                .Debug => {},
                .ReleaseSmall => try argv.append("-O2"),
                .ReleaseFast, .ReleaseSafe => try argv.append("-O3"),
            }
        }

        if (self.base.options.output_mode == .Exe) {
            // Increase the default stack size to a more reasonable value of 1MB instead of
            // the default of 1 Wasm page being 64KB, unless overriden by the user.
            try argv.append("-z");
            const stack_size = self.base.options.stack_size_override orelse 1048576;
            const arg = try std.fmt.allocPrint(arena, "stack-size={d}", .{stack_size});
            try argv.append(arg);

            // Put stack before globals so that stack overflow results in segfault immediately
            // before corrupting globals. See https://github.com/ziglang/zig/issues/4496
            try argv.append("--stack-first");

            if (self.base.options.wasi_exec_model == .reactor) {
                // Reactor execution model does not have _start so lld doesn't look for it.
                try argv.append("--no-entry");
                // Make sure "_initialize" is exported even if this is pure Zig WASI reactor
                // where WASM_SYMBOL_EXPORTED flag in LLVM is not set on _initialize.
                try argv.appendSlice(&[_][]const u8{
                    "--export",
                    "_initialize",
                });
            }
        } else {
            try argv.append("--no-entry"); // So lld doesn't look for _start.
            try argv.append("--export-all");
        }
        try argv.appendSlice(&[_][]const u8{
            "--allow-undefined",
            "-o",
            full_out_path,
        });

        if (target.os.tag == .wasi) {
            const is_exe_or_dyn_lib = self.base.options.output_mode == .Exe or
                (self.base.options.output_mode == .Lib and self.base.options.link_mode == .Dynamic);
            if (is_exe_or_dyn_lib) {
                const wasi_emulated_libs = self.base.options.wasi_emulated_libs;
                for (wasi_emulated_libs) |crt_file| {
                    try argv.append(try comp.get_libc_crt_file(
                        arena,
                        wasi_libc.emulatedLibCRFileLibName(crt_file),
                    ));
                }

                if (self.base.options.link_libc) {
                    try argv.append(try comp.get_libc_crt_file(
                        arena,
                        wasi_libc.execModelCrtFileFullName(self.base.options.wasi_exec_model),
                    ));
                    try argv.append(try comp.get_libc_crt_file(arena, "libc.a"));
                }

                if (self.base.options.link_libcpp) {
                    try argv.append(comp.libcxx_static_lib.?.full_object_path);
                    try argv.append(comp.libcxxabi_static_lib.?.full_object_path);
                }
            }
        }

        // Positional arguments to the linker such as object files.
        try argv.appendSlice(self.base.options.objects);

        for (comp.c_object_table.keys()) |key| {
            try argv.append(key.status.success.object_path);
        }
        if (module_obj_path) |p| {
            try argv.append(p);
        }

        if (self.base.options.output_mode != .Obj and
            !self.base.options.skip_linker_dependencies and
            !self.base.options.link_libc)
        {
            try argv.append(comp.libc_static_lib.?.full_object_path);
        }

        if (compiler_rt_path) |p| {
            try argv.append(p);
        }

        if (self.base.options.verbose_link) {
            // Skip over our own name so that the LLD linker name is the first argv item.
            Compilation.dump_argv(argv.items[1..]);
        }

        // Sadly, we must run LLD as a child process because it does not behave
        // properly as a library.
        const child = try std.ChildProcess.init(argv.items, arena);
        defer child.deinit();

        if (comp.clang_passthrough_mode) {
            child.stdin_behavior = .Inherit;
            child.stdout_behavior = .Inherit;
            child.stderr_behavior = .Inherit;

            const term = child.spawnAndWait() catch |err| {
                log.err("unable to spawn {s}: {s}", .{ argv.items[0], @errorName(err) });
                return error.UnableToSpawnSelf;
            };
            switch (term) {
                .Exited => |code| {
                    if (code != 0) {
                        // TODO https://github.com/ziglang/zig/issues/6342
                        std.process.exit(1);
                    }
                },
                else => std.process.abort(),
            }
        } else {
            child.stdin_behavior = .Ignore;
            child.stdout_behavior = .Ignore;
            child.stderr_behavior = .Pipe;

            try child.spawn();

            const stderr = try child.stderr.?.reader().readAllAlloc(arena, 10 * 1024 * 1024);

            const term = child.wait() catch |err| {
                log.err("unable to spawn {s}: {s}", .{ argv.items[0], @errorName(err) });
                return error.UnableToSpawnSelf;
            };

            switch (term) {
                .Exited => |code| {
                    if (code != 0) {
                        // TODO parse this output and surface with the Compilation API rather than
                        // directly outputting to stderr here.
                        std.debug.print("{s}", .{stderr});
                        return error.LLDReportedFailure;
                    }
                },
                else => {
                    log.err("{s} terminated with stderr:\n{s}", .{ argv.items[0], stderr });
                    return error.LLDCrashed;
                },
            }

            if (stderr.len != 0) {
                log.warn("unexpected LLD stderr:\n{s}", .{stderr});
            }
        }
    }

    if (!self.base.options.disable_lld_caching) {
        // Update the file with the digest. If it fails we can continue; it only
        // means that the next invocation will have an unnecessary cache miss.
        Cache.writeSmallFile(directory.handle, id_symlink_basename, &digest) catch |err| {
            log.warn("failed to save linking hash digest symlink: {s}", .{@errorName(err)});
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

/// Get the current index of a given Decl in the function list
/// This will correctly provide the index, regardless whether the function is extern or not
/// TODO: we could maintain a hash map to potentially make this simpler
fn getFuncidx(self: Wasm, decl: *Module.Decl) ?u32 {
    var offset: u32 = 0;
    const slice = switch (decl.val.tag()) {
        .function => blk: {
            // when the target is a regular function, we have to calculate
            // the offset of where the index starts
            offset += self.getFuncIdxOffset();
            break :blk self.funcs.items;
        },
        .extern_fn => self.ext_funcs.items,
        else => return null,
    };
    return for (slice) |func, idx| {
        if (func == decl) break @intCast(u32, offset + idx);
    } else null;
}

/// Based on the size of `ext_funcs` returns the
/// offset of the function indices
fn getFuncIdxOffset(self: Wasm) u32 {
    return @intCast(u32, self.ext_funcs.items.len);
}

fn reserveVecSectionHeader(file: fs.File) !u64 {
    // section id + fixed leb contents size + fixed leb vector length
    const header_size = 1 + 5 + 5;
    // TODO: this should be a single lseek(2) call, but fs.File does not
    // currently provide a way to do this.
    try file.seekBy(header_size);
    return (try file.getPos()) - header_size;
}

fn writeVecSectionHeader(file: fs.File, offset: u64, section: wasm.Section, size: u32, items: u32) !void {
    var buf: [1 + 5 + 5]u8 = undefined;
    buf[0] = @enumToInt(section);
    leb.writeUnsignedFixed(5, buf[1..6], size);
    leb.writeUnsignedFixed(5, buf[6..], items);
    try file.pwriteAll(&buf, offset);
}
