const Object = @This();

const std = @import("std");
const assert = std.debug.assert;
const dwarf = std.dwarf;
const fs = std.fs;
const io = std.io;
const log = std.log.scoped(.object);
const macho = std.macho;
const mem = std.mem;
const reloc = @import("reloc.zig");
const sort = std.sort;

const Allocator = mem.Allocator;
const Arch = std.Target.Cpu.Arch;
const Relocation = reloc.Relocation;
const Symbol = @import("Symbol.zig");
const TextBlock = Zld.TextBlock;
const Zld = @import("Zld.zig");

usingnamespace @import("commands.zig");

allocator: *Allocator,
arch: ?Arch = null,
header: ?macho.mach_header_64 = null,
file: ?fs.File = null,
file_offset: ?u32 = null,
name: ?[]const u8 = null,
mtime: ?u64 = null,

load_commands: std.ArrayListUnmanaged(LoadCommand) = .{},

segment_cmd_index: ?u16 = null,
symtab_cmd_index: ?u16 = null,
dysymtab_cmd_index: ?u16 = null,
build_version_cmd_index: ?u16 = null,
data_in_code_cmd_index: ?u16 = null,

text_section_index: ?u16 = null,
mod_init_func_section_index: ?u16 = null,

// __DWARF segment sections
dwarf_debug_info_index: ?u16 = null,
dwarf_debug_abbrev_index: ?u16 = null,
dwarf_debug_str_index: ?u16 = null,
dwarf_debug_line_index: ?u16 = null,
dwarf_debug_ranges_index: ?u16 = null,

symtab: std.ArrayListUnmanaged(macho.nlist_64) = .{},
strtab: std.ArrayListUnmanaged(u8) = .{},

initializers: std.ArrayListUnmanaged(u32) = .{},
data_in_code_entries: std.ArrayListUnmanaged(macho.data_in_code_entry) = .{},

symbols: std.ArrayListUnmanaged(*Symbol) = .{},

const DebugInfo = struct {
    inner: dwarf.DwarfInfo,
    debug_info: []u8,
    debug_abbrev: []u8,
    debug_str: []u8,
    debug_line: []u8,
    debug_ranges: []u8,

    pub fn parseFromObject(allocator: *Allocator, object: *const Object) !?DebugInfo {
        var debug_info = blk: {
            const index = object.dwarf_debug_info_index orelse return null;
            break :blk try object.readSection(allocator, index);
        };
        var debug_abbrev = blk: {
            const index = object.dwarf_debug_abbrev_index orelse return null;
            break :blk try object.readSection(allocator, index);
        };
        var debug_str = blk: {
            const index = object.dwarf_debug_str_index orelse return null;
            break :blk try object.readSection(allocator, index);
        };
        var debug_line = blk: {
            const index = object.dwarf_debug_line_index orelse return null;
            break :blk try object.readSection(allocator, index);
        };
        var debug_ranges = blk: {
            if (object.dwarf_debug_ranges_index) |ind| {
                break :blk try object.readSection(allocator, ind);
            }
            break :blk try allocator.alloc(u8, 0);
        };

        var inner: dwarf.DwarfInfo = .{
            .endian = .Little,
            .debug_info = debug_info,
            .debug_abbrev = debug_abbrev,
            .debug_str = debug_str,
            .debug_line = debug_line,
            .debug_ranges = debug_ranges,
        };
        try dwarf.openDwarfDebugInfo(&inner, allocator);

        return DebugInfo{
            .inner = inner,
            .debug_info = debug_info,
            .debug_abbrev = debug_abbrev,
            .debug_str = debug_str,
            .debug_line = debug_line,
            .debug_ranges = debug_ranges,
        };
    }

    pub fn deinit(self: *DebugInfo, allocator: *Allocator) void {
        allocator.free(self.debug_info);
        allocator.free(self.debug_abbrev);
        allocator.free(self.debug_str);
        allocator.free(self.debug_line);
        allocator.free(self.debug_ranges);
        self.inner.abbrev_table_list.deinit();
        self.inner.compile_unit_list.deinit();
        self.inner.func_list.deinit();
    }
};

pub fn createAndParseFromPath(allocator: *Allocator, arch: Arch, path: []const u8) !?*Object {
    const file = fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    errdefer file.close();

    const object = try allocator.create(Object);
    errdefer allocator.destroy(object);

    const name = try allocator.dupe(u8, path);
    errdefer allocator.free(name);

    object.* = .{
        .allocator = allocator,
        .arch = arch,
        .name = name,
        .file = file,
    };

    object.parse() catch |err| switch (err) {
        error.EndOfStream, error.NotObject => {
            object.deinit();
            allocator.destroy(object);
            return null;
        },
        else => |e| return e,
    };

    return object;
}

pub fn deinit(self: *Object) void {
    for (self.load_commands.items) |*lc| {
        lc.deinit(self.allocator);
    }
    self.load_commands.deinit(self.allocator);
    self.data_in_code_entries.deinit(self.allocator);
    self.initializers.deinit(self.allocator);
    self.symtab.deinit(self.allocator);
    self.strtab.deinit(self.allocator);
    self.symbols.deinit(self.allocator);

    if (self.name) |n| {
        self.allocator.free(n);
    }
}

pub fn closeFile(self: Object) void {
    if (self.file) |f| {
        f.close();
    }
}

pub fn parse(self: *Object) !void {
    var reader = self.file.?.reader();
    if (self.file_offset) |offset| {
        try reader.context.seekTo(offset);
    }

    const header = try reader.readStruct(macho.mach_header_64);

    if (header.filetype != macho.MH_OBJECT) {
        log.debug("invalid filetype: expected 0x{x}, found 0x{x}", .{ macho.MH_OBJECT, header.filetype });
        return error.NotObject;
    }

    const this_arch: Arch = switch (header.cputype) {
        macho.CPU_TYPE_ARM64 => .aarch64,
        macho.CPU_TYPE_X86_64 => .x86_64,
        else => |value| {
            log.err("unsupported cpu architecture 0x{x}", .{value});
            return error.UnsupportedCpuArchitecture;
        },
    };
    if (this_arch != self.arch.?) {
        log.err("mismatched cpu architecture: expected {s}, found {s}", .{ self.arch.?, this_arch });
        return error.MismatchedCpuArchitecture;
    }

    self.header = header;

    try self.readLoadCommands(reader);
    try self.parseSymtab();
    try self.parseDataInCode();
}

pub fn readLoadCommands(self: *Object, reader: anytype) !void {
    const offset = self.file_offset orelse 0;
    try self.load_commands.ensureCapacity(self.allocator, self.header.?.ncmds);

    var i: u16 = 0;
    while (i < self.header.?.ncmds) : (i += 1) {
        var cmd = try LoadCommand.read(self.allocator, reader);
        switch (cmd.cmd()) {
            macho.LC_SEGMENT_64 => {
                self.segment_cmd_index = i;
                var seg = cmd.Segment;
                for (seg.sections.items) |*sect, j| {
                    const index = @intCast(u16, j);
                    const segname = segmentName(sect.*);
                    const sectname = sectionName(sect.*);
                    if (mem.eql(u8, segname, "__DWARF")) {
                        if (mem.eql(u8, sectname, "__debug_info")) {
                            self.dwarf_debug_info_index = index;
                        } else if (mem.eql(u8, sectname, "__debug_abbrev")) {
                            self.dwarf_debug_abbrev_index = index;
                        } else if (mem.eql(u8, sectname, "__debug_str")) {
                            self.dwarf_debug_str_index = index;
                        } else if (mem.eql(u8, sectname, "__debug_line")) {
                            self.dwarf_debug_line_index = index;
                        } else if (mem.eql(u8, sectname, "__debug_ranges")) {
                            self.dwarf_debug_ranges_index = index;
                        }
                    } else if (mem.eql(u8, segname, "__TEXT")) {
                        if (mem.eql(u8, sectname, "__text")) {
                            self.text_section_index = index;
                        }
                    } else if (mem.eql(u8, segname, "__DATA")) {
                        if (mem.eql(u8, sectname, "__mod_init_func")) {
                            self.mod_init_func_section_index = index;
                        }
                    }

                    sect.offset += offset;
                    if (sect.reloff > 0) {
                        sect.reloff += offset;
                    }
                }

                seg.inner.fileoff += offset;
            },
            macho.LC_SYMTAB => {
                self.symtab_cmd_index = i;
                cmd.Symtab.symoff += offset;
                cmd.Symtab.stroff += offset;
            },
            macho.LC_DYSYMTAB => {
                self.dysymtab_cmd_index = i;
            },
            macho.LC_BUILD_VERSION => {
                self.build_version_cmd_index = i;
            },
            macho.LC_DATA_IN_CODE => {
                self.data_in_code_cmd_index = i;
                cmd.LinkeditData.dataoff += offset;
            },
            else => {
                log.debug("Unknown load command detected: 0x{x}.", .{cmd.cmd()});
            },
        }
        self.load_commands.appendAssumeCapacity(cmd);
    }
}

const NlistWithIndex = struct {
    nlist: macho.nlist_64,
    index: u32,

    fn lessThan(_: void, lhs: @This(), rhs: @This()) bool {
        return lhs.nlist.n_value < rhs.nlist.n_value;
    }

    fn filterInSection(symbols: []@This(), sect_id: u8) []@This() {
        var start: usize = 0;
        var end: usize = symbols.len;

        while (true) {
            var change = false;
            if (symbols[start].nlist.n_sect != sect_id) {
                start += 1;
                change = true;
            }
            if (symbols[end - 1].nlist.n_sect != sect_id) {
                end -= 1;
                change = true;
            }

            if (start == end) break;
            if (!change) break;
        }

        return symbols[start..end];
    }
};

fn filterRelocs(relocs: []macho.relocation_info, start: u64, end: u64) []macho.relocation_info {
    if (relocs.len == 0) return relocs;

    var start_id: usize = 0;
    var end_id: usize = relocs.len;

    while (true) {
        var change = false;
        if (relocs[start_id].r_address > end) {
            start_id += 1;
            change = true;
        }
        if (relocs[end_id - 1].r_address < start) {
            end_id -= 1;
            change = true;
        }

        if (start_id == end_id) break;
        if (!change) break;
    }

    return relocs[start_id..end_id];
}

const TextBlockParser = struct {
    allocator: *Allocator,
    section: macho.section_64,
    code: []u8,
    object: *Object,
    zld: *Zld,
    nlists: []NlistWithIndex,
    index: u32 = 0,

    fn peek(self: *TextBlockParser) ?NlistWithIndex {
        return if (self.index + 1 < self.nlists.len) self.nlists[self.index + 1] else null;
    }

    const SeniorityContext = struct {
        zld: *Zld,
    };

    fn lessThanBySeniority(context: SeniorityContext, lhs: NlistWithIndex, rhs: NlistWithIndex) bool {
        const lsym = context.zld.locals.items[lhs.index];
        const rsym = context.zld.locals.items[rhs.index];
        const lreg = lsym.payload.regular;
        const rreg = rsym.payload.regular;

        return switch (rreg.linkage) {
            .global => true,
            .linkage_unit => lreg.linkage == .translation_unit,
            else => lsym.isTemp(),
        };
    }

    pub fn next(self: *TextBlockParser) !?*TextBlock {
        if (self.index == self.nlists.len) return null;

        var aliases = std.ArrayList(NlistWithIndex).init(self.allocator);
        defer aliases.deinit();

        const next_nlist: ?NlistWithIndex = blk: while (true) {
            const curr_nlist = self.nlists[self.index];
            try aliases.append(curr_nlist);

            if (self.peek()) |next_nlist| {
                if (curr_nlist.nlist.n_value == next_nlist.nlist.n_value) {
                    self.index += 1;
                    continue;
                }
                break :blk next_nlist;
            }
            break :blk null;
        } else null;

        for (aliases.items) |*nlist_with_index| {
            const sym = self.object.symbols.items[nlist_with_index.index];
            if (sym.payload != .regular) {
                log.err("expected a regular symbol, found {s}", .{sym.payload});
                log.err("  when remapping {s}", .{sym.name});
                return error.SymbolIsNotRegular;
            }
            assert(sym.payload.regular.local_sym_index != 0); // This means the symbol has not been properly resolved.
            nlist_with_index.index = sym.payload.regular.local_sym_index;
        }

        if (aliases.items.len > 1) {
            // Bubble-up senior symbol as the main link to the text block.
            sort.sort(
                NlistWithIndex,
                aliases.items,
                SeniorityContext{ .zld = self.zld },
                @This().lessThanBySeniority,
            );
        }

        const senior_nlist = aliases.pop();
        const senior_sym = self.zld.locals.items[senior_nlist.index];
        assert(senior_sym.payload == .regular);

        const start_addr = senior_nlist.nlist.n_value - self.section.addr;
        const end_addr = if (next_nlist) |n| n.nlist.n_value - self.section.addr else self.section.size;

        const code = self.code[start_addr..end_addr];
        const size = code.len;

        const alias_only_indices = if (aliases.items.len > 0) blk: {
            var out = std.ArrayList(u32).init(self.allocator);
            try out.ensureTotalCapacity(aliases.items.len);
            for (aliases.items) |alias| {
                out.appendAssumeCapacity(alias.index);
            }
            break :blk out.toOwnedSlice();
        } else null;

        const block = try self.allocator.create(TextBlock);
        errdefer self.allocator.destroy(block);

        block.* = .{
            .local_sym_index = senior_nlist.index,
            .aliases = alias_only_indices,
            .code = code,
            .size = size,
            .alignment = self.section.@"align",
        };

        self.index += 1;

        return block;
    }
};

pub fn parseTextBlocks(self: *Object, zld: *Zld) !void {
    const seg = self.load_commands.items[self.segment_cmd_index.?].Segment;

    log.warn("analysing {s}", .{self.name.?});

    const dysymtab = self.load_commands.items[self.dysymtab_cmd_index.?].Dysymtab;
    // We only care about defined symbols, so filter every other out.
    const nlists = self.symtab.items[dysymtab.ilocalsym..dysymtab.iundefsym];

    var sorted_nlists = std.ArrayList(NlistWithIndex).init(self.allocator);
    defer sorted_nlists.deinit();
    try sorted_nlists.ensureTotalCapacity(nlists.len);

    for (nlists) |nlist, index| {
        sorted_nlists.appendAssumeCapacity(.{
            .nlist = nlist,
            .index = @intCast(u32, index + dysymtab.ilocalsym),
        });
    }

    sort.sort(NlistWithIndex, sorted_nlists.items, {}, NlistWithIndex.lessThan);

    for (seg.sections.items) |sect, sect_id| {
        log.warn("putting section '{s},{s}' as a TextBlock", .{
            segmentName(sect),
            sectionName(sect),
        });

        // Get matching segment/section in the final artifact.
        const match = (try zld.getMatchingSection(sect)) orelse {
            log.warn("unhandled section", .{});
            continue;
        };

        // Read section's code
        var code = try self.allocator.alloc(u8, @intCast(usize, sect.size));
        defer self.allocator.free(code);
        _ = try self.file.?.preadAll(code, sect.offset);

        // Is there any padding between symbols within the section?
        const is_padded = self.header.?.flags & macho.MH_SUBSECTIONS_VIA_SYMBOLS != 0;

        next: {
            if (is_padded) blocks: {
                const filtered_nlists = NlistWithIndex.filterInSection(
                    sorted_nlists.items,
                    @intCast(u8, sect_id + 1),
                );

                if (filtered_nlists.len == 0) break :blocks;

                var parser = TextBlockParser{
                    .allocator = self.allocator,
                    .section = sect,
                    .code = code,
                    .object = self,
                    .zld = zld,
                    .nlists = filtered_nlists,
                };

                while (try parser.next()) |block| {
                    {
                        const sym = zld.locals.items[block.local_sym_index];
                        const reg = &sym.payload.regular;
                        if (reg.file) |file| {
                            if (file != self) {
                                log.warn("deduping definition of {s} in {s}", .{ sym.name, self.name.? });
                                continue;
                            }
                        }
                        reg.segment_id = match.seg;
                        reg.section_id = match.sect;
                    }

                    if (block.aliases) |aliases| {
                        for (aliases) |alias| {
                            const sym = zld.locals.items[alias];
                            const reg = &sym.payload.regular;
                            reg.segment_id = match.seg;
                            reg.section_id = match.sect;
                        }
                    }

                    // TODO parse relocs

                    if (zld.last_text_block) |last| {
                        last.next = block;
                        block.prev = last;
                    }
                    zld.last_text_block = block;
                }

                break :next;
            }

            // Since there is no symbol to refer to this block, we create
            // a temp one.
            const name = try std.fmt.allocPrint(self.allocator, "l_{s}_{s}_{s}", .{
                self.name.?,
                segmentName(sect),
                sectionName(sect),
            });
            defer self.allocator.free(name);
            const symbol = try Symbol.new(self.allocator, name);
            symbol.payload = .{
                .regular = .{
                    .linkage = .translation_unit,
                    .segment_id = match.seg,
                    .section_id = match.sect,
                    .file = self,
                },
            };
            const local_sym_index = @intCast(u32, zld.locals.items.len);
            try zld.locals.append(zld.allocator, symbol);

            const block = try self.allocator.create(TextBlock);
            errdefer self.allocator.destroy(block);

            block.* = .{
                .local_sym_index = local_sym_index,
                .code = code,
                .size = sect.size,
                .alignment = sect.@"align",
            };

            // TODO parse relocs

            if (zld.last_text_block) |last| {
                last.next = block;
                block.prev = last;
            }
            zld.last_text_block = block;
        }
    }
}

pub fn parseInitializers(self: *Object) !void {
    const index = self.mod_init_func_section_index orelse return;
    const section = self.sections.items[index];

    log.debug("parsing initializers in {s}", .{self.name.?});

    // Parse C++ initializers
    const relocs = section.relocs orelse unreachable;
    try self.initializers.ensureCapacity(self.allocator, relocs.len);
    for (relocs) |rel| {
        self.initializers.appendAssumeCapacity(rel.target.symbol);
    }

    mem.reverse(u32, self.initializers.items);
}

fn parseSymtab(self: *Object) !void {
    const index = self.symtab_cmd_index orelse return;
    const symtab_cmd = self.load_commands.items[index].Symtab;

    var symtab = try self.allocator.alloc(u8, @sizeOf(macho.nlist_64) * symtab_cmd.nsyms);
    defer self.allocator.free(symtab);
    _ = try self.file.?.preadAll(symtab, symtab_cmd.symoff);
    const slice = @alignCast(@alignOf(macho.nlist_64), mem.bytesAsSlice(macho.nlist_64, symtab));
    try self.symtab.appendSlice(self.allocator, slice);

    var strtab = try self.allocator.alloc(u8, symtab_cmd.strsize);
    defer self.allocator.free(strtab);
    _ = try self.file.?.preadAll(strtab, symtab_cmd.stroff);
    try self.strtab.appendSlice(self.allocator, strtab);
}

pub fn parseDebugInfo(self: *Object) !void {
    var debug_info = blk: {
        var di = try DebugInfo.parseFromObject(self.allocator, self);
        break :blk di orelse return;
    };
    defer debug_info.deinit(self.allocator);

    log.debug("parsing debug info in '{s}'", .{self.name.?});

    // We assume there is only one CU.
    const compile_unit = debug_info.inner.findCompileUnit(0x0) catch |err| switch (err) {
        error.MissingDebugInfo => {
            // TODO audit cases with missing debug info and audit our dwarf.zig module.
            log.debug("invalid or missing debug info in {s}; skipping", .{self.name.?});
            return;
        },
        else => |e| return e,
    };
    const name = try compile_unit.die.getAttrString(&debug_info.inner, dwarf.AT_name);
    const comp_dir = try compile_unit.die.getAttrString(&debug_info.inner, dwarf.AT_comp_dir);

    if (self.mtime == null) {
        self.mtime = mtime: {
            const file = self.file orelse break :mtime 0;
            const stat = file.stat() catch break :mtime 0;
            break :mtime @intCast(u64, @divFloor(stat.mtime, 1_000_000_000));
        };
    }

    try self.stabs.ensureUnusedCapacity(self.allocator, self.symbols.items.len + 4);

    // Current dir
    self.stabs.appendAssumeCapacity(try Symbol.Stab.new(self.allocator, comp_dir, .{
        .kind = .so,
        .file = self,
    }));

    // Artifact name
    self.stabs.appendAssumeCapacity(try Symbol.Stab.new(self.allocator, name, .{
        .kind = .so,
        .file = self,
    }));

    // Path to object file with debug info
    self.stabs.appendAssumeCapacity(try Symbol.Stab.new(self.allocator, self.name.?, .{
        .kind = .oso,
        .file = self,
    }));

    for (self.symbols.items) |sym| {
        if (sym.cast(Symbol.Regular)) |reg| {
            const size: u64 = blk: for (debug_info.inner.func_list.items) |func| {
                if (func.pc_range) |range| {
                    if (reg.address >= range.start and reg.address < range.end) {
                        break :blk range.end - range.start;
                    }
                }
            } else 0;

            const stab = try Symbol.Stab.new(self.allocator, sym.name, .{
                .kind = kind: {
                    if (size > 0) break :kind .function;
                    switch (reg.linkage) {
                        .translation_unit => break :kind .static,
                        else => break :kind .global,
                    }
                },
                .size = size,
                .symbol = sym,
                .file = self,
            });
            self.stabs.appendAssumeCapacity(stab);
        } else if (sym.cast(Symbol.Tentative)) |_| {
            const stab = try Symbol.Stab.new(self.allocator, sym.name, .{
                .kind = .global,
                .size = 0,
                .symbol = sym,
                .file = self,
            });
            self.stabs.appendAssumeCapacity(stab);
        }
    }

    // Closing delimiter.
    const delim_stab = try Symbol.Stab.new(self.allocator, "", .{
        .kind = .so,
        .file = self,
    });
    self.stabs.appendAssumeCapacity(delim_stab);
}

pub fn parseDataInCode(self: *Object) !void {
    const index = self.data_in_code_cmd_index orelse return;
    const data_in_code = self.load_commands.items[index].LinkeditData;

    var buffer = try self.allocator.alloc(u8, data_in_code.datasize);
    defer self.allocator.free(buffer);

    _ = try self.file.?.preadAll(buffer, data_in_code.dataoff);

    var stream = io.fixedBufferStream(buffer);
    var reader = stream.reader();
    while (true) {
        const dice = reader.readStruct(macho.data_in_code_entry) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        try self.data_in_code_entries.append(self.allocator, dice);
    }
}

fn readSection(self: Object, allocator: *Allocator, index: u16) ![]u8 {
    const seg = self.load_commands.items[self.segment_cmd_index.?].Segment;
    const sect = seg.sections.items[index];
    var buffer = try allocator.alloc(u8, @intCast(usize, sect.size));
    _ = try self.file.?.preadAll(buffer, sect.offset);
    return buffer;
}

pub fn getString(self: Object, off: u32) []const u8 {
    assert(off < self.strtab.items.len);
    return mem.spanZ(@ptrCast([*:0]const u8, self.strtab.items.ptr + off));
}
