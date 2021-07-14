//! This implementation does all the linking work in flush(). A future improvement
//! would be to add incremental linking in a similar way as ELF does.

const Plan9 = @This();
const link = @import("../link.zig");
const Module = @import("../Module.zig");
const Compilation = @import("../Compilation.zig");
const aout = @import("Plan9/aout.zig");
const codegen = @import("../codegen.zig");
const trace = @import("../tracy.zig").trace;
const File = link.File;
const build_options = @import("build_options");
const Air = @import("../Air.zig");
const Liveness = @import("../Liveness.zig");

const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.link);
const assert = std.debug.assert;

base: link.File,
sixtyfour_bit: bool,
error_flags: File.ErrorFlags = File.ErrorFlags{},
bases: Bases,

/// A symbol's value is just casted down when compiling
/// for a 32 bit target.
syms: std.ArrayListUnmanaged(aout.Sym) = .{},

fn_decl_table: std.AutoArrayHashMapUnmanaged(*Module.Decl, []const u8) = .{},
data_decl_table: std.AutoArrayHashMapUnmanaged(*Module.Decl, []const u8) = .{},

hdr: aout.ExecHdr = undefined,

entry_decl: ?*Module.Decl = null,

got_len: u64 = 0,

const Bases = struct {
    text: u64,
    /// the Global Offset Table starts at the beginning of the data section
    data: u64,
};

fn getAddr(self: Plan9, addr: u64, t: aout.Sym.Type) u64 {
    return addr + switch (t) {
        .T, .t, .l, .L => self.bases.text,
        .D, .d, .B, .b => self.bases.data,
        else => unreachable,
    };
}

fn getSymAddr(self: Plan9, s: aout.Sym) u64 {
    return self.getAddr(s.value, s.type);
}

pub const DeclBlock = struct {
    type: aout.Sym.Type,
    /// offset in the text or data sects
    offset: ?u64,
    /// offset into syms
    sym_index: ?usize,
    /// offset into got
    got_index: ?usize,
    pub const empty = DeclBlock{
        .type = .t,
        .offset = null,
        .sym_index = null,
        .got_index = null,
    };
};

pub fn defaultBaseAddrs(arch: std.Target.Cpu.Arch) Bases {
    return switch (arch) {
        .x86_64 => .{
            // header size => 40 => 0x28
            .text = 0x200028,
            .data = 0x400000,
        },
        .i386 => .{
            // header size => 32 => 0x20
            .text = 0x200020,
            .data = 0x400000,
        },
        .aarch64 => .{
            // header size => 40 => 0x28
            .text = 0x10028,
            .data = 0x20000,
        },
        else => std.debug.panic("find default base address for {}", .{arch}),
    };
}

pub const PtrWidth = enum { p32, p64 };

pub fn createEmpty(gpa: *Allocator, options: link.Options) !*Plan9 {
    if (options.use_llvm)
        return error.LLVMBackendDoesNotSupportPlan9;
    const sixtyfour_bit: bool = switch (options.target.cpu.arch.ptrBitWidth()) {
        0...32 => false,
        33...64 => true,
        else => return error.UnsupportedP9Architecture,
    };
    const self = try gpa.create(Plan9);
    self.* = .{
        .base = .{
            .tag = .plan9,
            .options = options,
            .allocator = gpa,
            .file = null,
        },
        .sixtyfour_bit = sixtyfour_bit,
        .bases = undefined,
    };
    return self;
}

pub fn updateFunc(self: *Plan9, module: *Module, func: *Module.Fn, air: Air, liveness: Liveness) !void {
    if (build_options.skip_non_native and builtin.object_format != .plan9) {
        @panic("Attempted to compile for object format that was disabled by build configuration");
    }

    const decl = func.owner_decl;
    log.debug("codegen decl {*} ({s})", .{ decl, decl.name });

    var code_buffer = std.ArrayList(u8).init(self.base.allocator);
    defer code_buffer.deinit();
    const res = try codegen.generateFunction(&self.base, decl.srcLoc(), func, air, liveness, &code_buffer, .{ .none = .{} });
    const code = switch (res) {
        .appended => code_buffer.toOwnedSlice(),
        .fail => |em| {
            decl.analysis = .codegen_failure;
            try module.failed_decls.put(module.gpa, decl, em);
            return;
        },
    };
    try self.fn_decl_table.put(self.base.allocator, decl, code);
    return self.updateFinish(decl);
}

pub fn updateDecl(self: *Plan9, module: *Module, decl: *Module.Decl) !void {
    if (decl.val.tag() == .extern_fn) {
        return; // TODO Should we do more when front-end analyzed extern decl?
    }
    if (decl.val.castTag(.variable)) |payload| {
        const variable = payload.data;
        if (variable.is_extern) {
            return; // TODO Should we do more when front-end analyzed extern decl?
        }
    }

    log.debug("codegen decl {*} ({s})", .{ decl, decl.name });

    var code_buffer = std.ArrayList(u8).init(self.base.allocator);
    defer code_buffer.deinit();
    const decl_val = if (decl.val.castTag(.variable)) |payload| payload.data.init else decl.val;
    const res = try codegen.generateSymbol(&self.base, decl.srcLoc(), .{
        .ty = decl.ty,
        .val = decl_val,
    }, &code_buffer, .{ .none = .{} });
    const code = switch (res) {
        .externally_managed => |x| x,
        .appended => code_buffer.items,
        .fail => |em| {
            decl.analysis = .codegen_failure;
            try module.failed_decls.put(module.gpa, decl, em);
            return;
        },
    };
    var duped_code = try std.mem.dupe(self.base.allocator, u8, code);
    errdefer self.base.allocator.free(duped_code);
    try self.data_decl_table.put(self.base.allocator, decl, duped_code);
    return self.updateFinish(decl);
}
/// called at the end of update{Decl,Func}
fn updateFinish(self: *Plan9, decl: *Module.Decl) !void {
    const is_fn = (decl.ty.zigTypeTag() == .Fn);
    log.debug("update the symbol table and got for decl {*} ({s})", .{ decl, decl.name });
    const sym_t: aout.Sym.Type = if (is_fn) .t else .d;
    // write the internal linker metadata
    decl.link.plan9.type = sym_t;
    // write the symbol
    // we already have the got index because that got allocated in allocateDeclIndexes
    const sym: aout.Sym = .{
        .value = undefined, // the value of stuff gets filled in in flushModule
        .type = decl.link.plan9.type,
        .name = mem.span(decl.name),
    };

    if (decl.link.plan9.sym_index) |s| {
        self.syms.items[s] = sym;
    } else {
        try self.syms.append(self.base.allocator, sym);
        decl.link.plan9.sym_index = self.syms.items.len - 1;
    }
}

pub fn flush(self: *Plan9, comp: *Compilation) !void {
    assert(!self.base.options.use_lld);

    switch (self.base.options.effectiveOutputMode()) {
        .Exe => {},
        // plan9 object files are totally different
        .Obj => return error.TODOImplementPlan9Objs,
        .Lib => return error.TODOImplementWritingLibFiles,
    }
    return self.flushModule(comp);
}

pub fn flushModule(self: *Plan9, comp: *Compilation) !void {
    if (build_options.skip_non_native and builtin.object_format != .plan9) {
        @panic("Attempted to compile for object format that was disabled by build configuration");
    }
    _ = comp;
    const tracy = trace(@src());
    defer tracy.end();

    log.debug("flushModule", .{});

    defer assert(self.hdr.entry != 0x0);

    _ = self.base.options.module orelse return error.LinkingWithoutZigSourceUnimplemented;

    assert(self.got_len == self.fn_decl_table.count() + self.data_decl_table.count());
    const got_size = self.got_len * if (!self.sixtyfour_bit) @as(u32, 4) else 8;
    var got_table = try self.base.allocator.alloc(u8, got_size);
    defer self.base.allocator.free(got_table);

    // + 2 for header, got, symbols
    var iovecs = try self.base.allocator.alloc(std.os.iovec_const, self.fn_decl_table.count() + self.data_decl_table.count() + 3);

    const file = self.base.file.?;

    var hdr_buf: [40]u8 = undefined;
    // account for the fat header
    const hdr_size = if (self.sixtyfour_bit) @as(usize, 40) else 32;
    const hdr_slice: []u8 = hdr_buf[0..hdr_size];
    var foff = hdr_size;
    iovecs[0] = .{ .iov_base = hdr_slice.ptr, .iov_len = hdr_slice.len };
    var iovecs_i: u64 = 1;
    var text_i: u64 = 0;
    // text
    {
        var it = self.fn_decl_table.iterator();
        while (it.next()) |entry| {
            const decl = entry.key_ptr.*;
            const code = entry.value_ptr.*;
            foff += code.len;
            text_i += code.len;
            iovecs[iovecs_i] = .{ .iov_base = code.ptr, .iov_len = code.len };
            iovecs_i += 1;
            const off = self.getAddr(text_i, .t);
            decl.link.plan9.offset = off;
            if (!self.sixtyfour_bit) {
                mem.writeIntNative(u32, got_table[decl.link.plan9.got_index.? * 4 ..][0..4], @intCast(u32, off));
                mem.writeInt(u32, got_table[decl.link.plan9.got_index.? * 4 ..][0..4], @intCast(u32, off), self.base.options.target.cpu.arch.endian());
            } else {
                mem.writeInt(u64, got_table[decl.link.plan9.got_index.? * 8 ..][0..8], off, self.base.options.target.cpu.arch.endian());
            }
            self.syms.items[decl.link.plan9.sym_index.?].value = off;
        }
        // etext symbol
        self.syms.items[2].value = self.getAddr(text_i, .t);
    }
    // data
    var data_i: u64 = got_size;
    {
        var it = self.data_decl_table.iterator();
        while (it.next()) |entry| {
            const decl = entry.key_ptr.*;
            const code = entry.value_ptr.*;
            foff += code.len;
            data_i += code.len;
            iovecs[iovecs_i] = .{ .iov_base = code.ptr, .iov_len = code.len };
            iovecs_i += 1;
            const off = self.getAddr(data_i, .d);
            decl.link.plan9.offset = off;
            if (!self.sixtyfour_bit) {
                mem.writeInt(u32, got_table[decl.link.plan9.got_index.? * 4 ..][0..4], @intCast(u32, off), self.base.options.target.cpu.arch.endian());
            } else {
                mem.writeInt(u64, got_table[decl.link.plan9.got_index.? * 8 ..][0..8], off, self.base.options.target.cpu.arch.endian());
            }
            self.syms.items[decl.link.plan9.sym_index.?].value = off;
        }
        // edata symbol
        self.syms.items[0].value = self.getAddr(data_i, .b);
    }
    // edata
    self.syms.items[1].value = self.getAddr(0x0, .b);
    var sym_buf = std.ArrayList(u8).init(self.base.allocator);
    defer sym_buf.deinit();
    try self.writeSyms(&sym_buf);
    iovecs[iovecs_i] = .{ .iov_base = got_table.ptr, .iov_len = got_table.len };
    iovecs_i += 1;
    assert(2 + self.fn_decl_table.count() + self.data_decl_table.count() == iovecs_i); // we didn't write all the decls
    iovecs[iovecs_i] = .{ .iov_base = sym_buf.items.ptr, .iov_len = sym_buf.items.len };
    iovecs_i += 1;
    // generate the header
    self.hdr = .{
        .magic = try aout.magicFromArch(self.base.options.target.cpu.arch),
        .text = @intCast(u32, text_i),
        .data = @intCast(u32, data_i),
        .syms = @intCast(u32, sym_buf.items.len),
        .bss = 0,
        .pcsz = 0,
        .spsz = 0,
        .entry = @intCast(u32, self.entry_decl.?.link.plan9.offset.?),
    };
    std.mem.copy(u8, hdr_slice, self.hdr.toU8s()[0..hdr_size]);
    // write the fat header for 64 bit entry points
    if (self.sixtyfour_bit) {
        mem.writeIntSliceBig(u64, hdr_buf[32..40], self.entry_decl.?.link.plan9.offset.?);
    }
    // write it all!
    try file.pwritevAll(iovecs, 0);
}
pub fn freeDecl(self: *Plan9, decl: *Module.Decl) void {
    const is_fn = (decl.ty.zigTypeTag() == .Fn);
    if (is_fn)
        assert(self.fn_decl_table.swapRemove(decl))
    else
        assert(self.data_decl_table.swapRemove(decl));
}

pub fn updateDeclExports(
    self: *Plan9,
    module: *Module,
    decl: *Module.Decl,
    exports: []const *Module.Export,
) !void {
    // we do all the things in flush
    _ = self;
    _ = module;
    _ = decl;
    _ = exports;
}
pub fn deinit(self: *Plan9) void {
    var itf = self.fn_decl_table.iterator();
    while (itf.next()) |entry| {
        self.base.allocator.free(entry.value_ptr.*);
    }
    self.fn_decl_table.deinit(self.base.allocator);
    var itd = self.data_decl_table.iterator();
    while (itd.next()) |entry| {
        self.base.allocator.free(entry.value_ptr.*);
    }
    self.data_decl_table.deinit(self.base.allocator);
    self.syms.deinit(self.base.allocator);
}

pub const Export = ?usize;
pub const base_tag = .plan9;
pub fn openPath(allocator: *Allocator, sub_path: []const u8, options: link.Options) !*Plan9 {
    if (options.use_llvm)
        return error.LLVMBackendDoesNotSupportPlan9;
    assert(options.object_format == .plan9);
    const file = try options.emit.?.directory.handle.createFile(sub_path, .{
        .truncate = false,
        .read = true,
        .mode = link.determineMode(options),
    });
    errdefer file.close();

    const self = try createEmpty(allocator, options);
    errdefer self.base.destroy();

    self.bases = defaultBaseAddrs(options.target.cpu.arch);

    // first 3 symbols in our table are edata, end, etext
    try self.syms.appendSlice(self.base.allocator, &.{
        .{
            .value = 0xcafebabe,
            .type = .B,
            .name = "edata",
        },
        .{
            .value = 0xcafebabe,
            .type = .B,
            .name = "end",
        },
        .{
            .value = 0xcafebabe,
            .type = .T,
            .name = "etext",
        },
    });

    self.base.file = file;
    return self;
}

pub fn writeSyms(self: *Plan9, buf: *std.ArrayList(u8)) !void {
    const writer = buf.writer();
    for (self.syms.items) |sym| {
        if (!self.sixtyfour_bit) {
            try writer.writeIntBig(u32, @intCast(u32, sym.value));
        } else {
            try writer.writeIntBig(u64, sym.value);
        }
        try writer.writeByte(@enumToInt(sym.type));
        try writer.writeAll(std.mem.span(sym.name));
        try writer.writeByte(0);
    }
}

pub fn allocateDeclIndexes(self: *Plan9, decl: *Module.Decl) !void {
    if (decl.link.plan9.got_index != null) {
        self.got_len += 1;
        decl.link.plan9.got_index = self.got_len - 1;
    }
}
