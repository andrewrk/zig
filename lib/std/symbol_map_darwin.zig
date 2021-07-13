const std = @import("std.zig");
const SymbolInfo = std.debug.SymbolMap.SymbolInfo;
const assert = std.debug.assert;
const debug_info_utils = @import("debug_info_utils.zig");
const chopSlice = debug_info_utils.chopSlice;
const mem = std.mem;
const macho = std.macho;
const fs = std.fs;
const File = std.fs.File;
const DW = std.dwarf;

const SymbolMapState = debug_info_utils.SymbolMapStateFromModuleInfo(Module);
pub const init = SymbolMapState.init;

const Module = struct {
    const Self = @This();

    base_address: usize,
    mapped_memory: []const u8,
    symbols: []const MachoSymbol,
    strings: [:0]const u8,
    ofiles: OFileTable,
    allocator: *mem.Allocator,

    const MachoSymbol = struct {
        nlist: *const macho.nlist_64,
        ofile: ?*const macho.nlist_64,
        reloc: u64,

        /// Returns the address from the macho file
        fn address(self: MachoSymbol) u64 {
            return self.nlist.n_value;
        }

        fn addressLessThan(context: void, lhs: MachoSymbol, rhs: MachoSymbol) bool {
            _ = context;
            return lhs.address() < rhs.address();
        }
    };

    const OFileTable = std.StringHashMap(DW.DwarfInfo);

    pub fn lookup(allocator: *mem.Allocator, address_map: *SymbolMapState.AddressMap, address: usize) !*Self {
        const image_count = std.c._dyld_image_count();

        var i: u32 = 0;
        while (i < image_count) : (i += 1) {
            const base_address = std.c._dyld_get_image_vmaddr_slide(i);

            if (address < base_address) continue;

            const header = std.c._dyld_get_image_header(i) orelse continue;
            // The array of load commands is right after the header
            var cmd_ptr = @intToPtr([*]u8, @ptrToInt(header) + @sizeOf(macho.mach_header_64));

            var cmds = header.ncmds;
            while (cmds != 0) : (cmds -= 1) {
                const lc = @ptrCast(
                    *macho.load_command,
                    @alignCast(@alignOf(macho.load_command), cmd_ptr),
                );
                cmd_ptr += lc.cmdsize;
                if (lc.cmd != macho.LC_SEGMENT_64) continue;

                const segment_cmd = @ptrCast(
                    *const std.macho.segment_command_64,
                    @alignCast(@alignOf(std.macho.segment_command_64), lc),
                );

                const rebased_address = address - base_address;
                const seg_start = segment_cmd.vmaddr;
                const seg_end = seg_start + segment_cmd.vmsize;

                if (rebased_address >= seg_start and rebased_address < seg_end) {
                    if (address_map.get(base_address)) |obj_di| {
                        return obj_di;
                    }

                    const obj_di = try allocator.create(Self);
                    errdefer allocator.destroy(obj_di);

                    const macho_path = mem.spanZ(std.c._dyld_get_image_name(i));
                    const macho_file = fs.cwd().openFile(macho_path, .{ .intended_io_mode = .blocking }) catch |err| switch (err) {
                        error.FileNotFound => return error.MissingDebugInfo,
                        else => return err,
                    };
                    obj_di.* = try readMachODebugInfo(allocator, macho_file);
                    obj_di.base_address = base_address;

                    try address_map.putNoClobber(base_address, obj_di);

                    return obj_di;
                }
            }
        }

        return error.MissingDebugInfo;
    }

    /// TODO resources https://github.com/ziglang/zig/issues/4353
    /// This takes ownership of macho_file: users of this function should not close
    /// it themselves, even on error.
    /// TODO it's weird to take ownership even on error, rework this code.
    fn readMachODebugInfo(allocator: *mem.Allocator, macho_file: File) !Self {
        const mapped_mem = try debug_info_utils.mapWholeFile(macho_file);

        const hdr = @ptrCast(
            *const macho.mach_header_64,
            @alignCast(@alignOf(macho.mach_header_64), mapped_mem.ptr),
        );
        if (hdr.magic != macho.MH_MAGIC_64)
            return error.InvalidDebugInfo;

        const hdr_base = @ptrCast([*]const u8, hdr);
        var ptr = hdr_base + @sizeOf(macho.mach_header_64);
        var ncmd: u32 = hdr.ncmds;
        const symtab = while (ncmd != 0) : (ncmd -= 1) {
            const lc = @ptrCast(*const std.macho.load_command, ptr);
            switch (lc.cmd) {
                std.macho.LC_SYMTAB => break @ptrCast(*const std.macho.symtab_command, ptr),
                else => {},
            }
            ptr = @alignCast(@alignOf(std.macho.load_command), ptr + lc.cmdsize);
        } else {
            return error.MissingDebugInfo;
        };
        const syms = @ptrCast([*]const macho.nlist_64, @alignCast(@alignOf(macho.nlist_64), hdr_base + symtab.symoff))[0..symtab.nsyms];
        const strings = @ptrCast([*]const u8, hdr_base + symtab.stroff)[0 .. symtab.strsize - 1 :0];

        const symbols_buf = try allocator.alloc(MachoSymbol, syms.len);

        var ofile: ?*const macho.nlist_64 = null;
        var reloc: u64 = 0;
        var symbol_index: usize = 0;
        var last_len: u64 = 0;
        for (syms) |*sym| {
            if (sym.n_type & std.macho.N_STAB != 0) {
                switch (sym.n_type) {
                    std.macho.N_OSO => {
                        ofile = sym;
                        reloc = 0;
                    },
                    std.macho.N_FUN => {
                        if (sym.n_sect == 0) {
                            last_len = sym.n_value;
                        } else {
                            symbols_buf[symbol_index] = MachoSymbol{
                                .nlist = sym,
                                .ofile = ofile,
                                .reloc = reloc,
                            };
                            symbol_index += 1;
                        }
                    },
                    std.macho.N_BNSYM => {
                        if (reloc == 0) {
                            reloc = sym.n_value;
                        }
                    },
                    else => continue,
                }
            }
        }
        const sentinel = try allocator.create(macho.nlist_64);
        sentinel.* = macho.nlist_64{
            .n_strx = 0,
            .n_type = 36,
            .n_sect = 0,
            .n_desc = 0,
            .n_value = symbols_buf[symbol_index - 1].nlist.n_value + last_len,
        };

        const symbols = allocator.shrink(symbols_buf, symbol_index);

        // Even though lld emits symbols in ascending order, this debug code
        // should work for programs linked in any valid way.
        // This sort is so that we can binary search later.
        std.sort.sort(MachoSymbol, symbols, {}, MachoSymbol.addressLessThan);

        return Self{
            .base_address = undefined,
            .mapped_memory = mapped_mem,
            .ofiles = Self.OFileTable.init(allocator),
            .symbols = symbols,
            .strings = strings,
            .allocator = allocator,
        };
    }

    pub fn addressToSymbol(self: *Self, address: usize) !SymbolInfo {
        nosuspend {
            // Translate the VA into an address into this object
            const relocated_address = address - self.base_address;
            assert(relocated_address >= 0x100000000);

            // Find the .o file where this symbol is defined
            const symbol = machoSearchSymbols(self.symbols, relocated_address) orelse
                return SymbolInfo{};

            // Take the symbol name from the N_FUN STAB entry, we're going to
            // use it if we fail to find the DWARF infos
            const stab_symbol = mem.spanZ(self.strings[symbol.nlist.n_strx..]);

            if (symbol.ofile == null)
                return SymbolInfo{ .symbol_name = stab_symbol };

            const o_file_path = mem.spanZ(self.strings[symbol.ofile.?.n_strx..]);

            // Check if its debug infos are already in the cache
            var o_file_di = self.ofiles.get(o_file_path) orelse
                (self.loadOFile(o_file_path) catch |err| switch (err) {
                error.FileNotFound,
                error.MissingDebugInfo,
                error.InvalidDebugInfo,
                => {
                    return SymbolInfo{ .symbol_name = stab_symbol };
                },
                else => return err,
            });

            // Translate again the address, this time into an address inside the
            // .o file
            const relocated_address_o = relocated_address - symbol.reloc;

            if (o_file_di.findCompileUnit(relocated_address_o)) |compile_unit| {
                return SymbolInfo{
                    .symbol_name = o_file_di.getSymbolName(relocated_address_o) orelse "???",
                    .compile_unit_name = compile_unit.die.getAttrString(&o_file_di, DW.AT_name) catch |err| switch (err) {
                        error.MissingDebugInfo, error.InvalidDebugInfo => "???",
                        else => return err,
                    },
                    .line_info = o_file_di.getLineNumberInfo(compile_unit.*, relocated_address_o) catch |err| switch (err) {
                        error.MissingDebugInfo, error.InvalidDebugInfo => null,
                        else => return err,
                    },
                };
            } else |err| switch (err) {
                error.MissingDebugInfo, error.InvalidDebugInfo => {
                    return SymbolInfo{ .symbol_name = stab_symbol };
                },
                else => return err,
            }

            unreachable;
        }
    }

    fn machoSearchSymbols(symbols: []const MachoSymbol, address: usize) ?*const MachoSymbol {
        var min: usize = 0;
        var max: usize = symbols.len - 1; // Exclude sentinel.
        while (min < max) {
            const mid = min + (max - min) / 2;
            const curr = &symbols[mid];
            const next = &symbols[mid + 1];
            if (address >= next.address()) {
                min = mid + 1;
            } else if (address < curr.address()) {
                max = mid;
            } else {
                return curr;
            }
        }
        return null;
    }

    fn loadOFile(self: *Self, o_file_path: []const u8) !DW.DwarfInfo {
        const o_file = try fs.cwd().openFile(o_file_path, .{ .intended_io_mode = .blocking });
        const mapped_mem = try debug_info_utils.mapWholeFile(o_file);

        const hdr = @ptrCast(
            *const macho.mach_header_64,
            @alignCast(@alignOf(macho.mach_header_64), mapped_mem.ptr),
        );
        if (hdr.magic != std.macho.MH_MAGIC_64)
            return error.InvalidDebugInfo;

        const hdr_base = @ptrCast([*]const u8, hdr);
        var ptr = hdr_base + @sizeOf(macho.mach_header_64);
        var ncmd: u32 = hdr.ncmds;
        const segcmd = while (ncmd != 0) : (ncmd -= 1) {
            const lc = @ptrCast(*const std.macho.load_command, ptr);
            switch (lc.cmd) {
                std.macho.LC_SEGMENT_64 => {
                    break @ptrCast(
                        *const std.macho.segment_command_64,
                        @alignCast(@alignOf(std.macho.segment_command_64), ptr),
                    );
                },
                else => {},
            }
            ptr = @alignCast(@alignOf(std.macho.load_command), ptr + lc.cmdsize);
        } else {
            return error.MissingDebugInfo;
        };

        var opt_debug_line: ?*const macho.section_64 = null;
        var opt_debug_info: ?*const macho.section_64 = null;
        var opt_debug_abbrev: ?*const macho.section_64 = null;
        var opt_debug_str: ?*const macho.section_64 = null;
        var opt_debug_ranges: ?*const macho.section_64 = null;

        const sections = @ptrCast(
            [*]const macho.section_64,
            @alignCast(@alignOf(macho.section_64), ptr + @sizeOf(std.macho.segment_command_64)),
        )[0..segcmd.nsects];
        for (sections) |*sect| {
            // The section name may not exceed 16 chars and a trailing null may
            // not be present
            const name = if (mem.indexOfScalar(u8, sect.sectname[0..], 0)) |last|
                sect.sectname[0..last]
            else
                sect.sectname[0..];

            if (mem.eql(u8, name, "__debug_line")) {
                opt_debug_line = sect;
            } else if (mem.eql(u8, name, "__debug_info")) {
                opt_debug_info = sect;
            } else if (mem.eql(u8, name, "__debug_abbrev")) {
                opt_debug_abbrev = sect;
            } else if (mem.eql(u8, name, "__debug_str")) {
                opt_debug_str = sect;
            } else if (mem.eql(u8, name, "__debug_ranges")) {
                opt_debug_ranges = sect;
            }
        }

        const debug_line = opt_debug_line orelse
            return error.MissingDebugInfo;
        const debug_info = opt_debug_info orelse
            return error.MissingDebugInfo;
        const debug_str = opt_debug_str orelse
            return error.MissingDebugInfo;
        const debug_abbrev = opt_debug_abbrev orelse
            return error.MissingDebugInfo;

        var di = DW.DwarfInfo{
            .endian = .Little,
            .debug_info = try chopSlice(mapped_mem, debug_info.offset, debug_info.size),
            .debug_abbrev = try chopSlice(mapped_mem, debug_abbrev.offset, debug_abbrev.size),
            .debug_str = try chopSlice(mapped_mem, debug_str.offset, debug_str.size),
            .debug_line = try chopSlice(mapped_mem, debug_line.offset, debug_line.size),
            .debug_ranges = if (opt_debug_ranges) |debug_ranges|
                try chopSlice(mapped_mem, debug_ranges.offset, debug_ranges.size)
            else
                null,
        };

        try DW.openDwarfDebugInfo(&di, self.allocator);

        // Add the debug info to the cache
        try self.ofiles.putNoClobber(o_file_path, di);

        return di;
    }
};
