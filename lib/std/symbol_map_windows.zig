const std = @import("std.zig");
const assert = std.debug.assert;
const SymbolInfo = std.debug.SymbolMap.SymbolInfo;
const debug_info_utils = @import("debug_info_utils.zig");
const mem = std.mem;
const math = std.math;
const fs = std.fs;
const File = fs.File;
const coff = std.coff;
const pdb = std.pdb;
const windows = std.os.windows;

const SymbolMapState = debug_info_utils.SymbolMapStateFromModuleInfo(Module);
pub const init = SymbolMapState.init;

const Module = struct {
    const Self = @This();

    base_address: usize,
    debug_data: PdbOrDwarf,
    coff: *coff.Coff,

    const PdbOrDwarf = union(enum) {
        pdb: pdb.Pdb,
        dwarf: DW.DwarfInfo,
    };

    pub fn lookup(allocator: *mem.Allocator, address_map: *SymbolMapState.AddressMap, address: usize) !*Self {
        const process_handle = windows.kernel32.GetCurrentProcess();

        // Find how many modules are actually loaded
        var dummy: windows.HMODULE = undefined;
        var bytes_needed: windows.DWORD = undefined;
        if (windows.kernel32.K32EnumProcessModules(
            process_handle,
            @ptrCast([*]windows.HMODULE, &dummy),
            0,
            &bytes_needed,
        ) == 0)
            return error.MissingDebugInfo;

        const needed_modules = bytes_needed / @sizeOf(windows.HMODULE);

        // Fetch the complete module list
        var modules = try allocator.alloc(windows.HMODULE, needed_modules);
        defer allocator.free(modules);
        if (windows.kernel32.K32EnumProcessModules(
            process_handle,
            modules.ptr,
            try math.cast(windows.DWORD, modules.len * @sizeOf(windows.HMODULE)),
            &bytes_needed,
        ) == 0)
            return error.MissingDebugInfo;

        // There's an unavoidable TOCTOU problem here, the module list may have
        // changed between the two EnumProcessModules call.
        // Pick the smallest amount of elements to avoid processing garbage.
        const needed_modules_after = bytes_needed / @sizeOf(windows.HMODULE);
        const loaded_modules = math.min(needed_modules, needed_modules_after);

        for (modules[0..loaded_modules]) |module| {
            var info: windows.MODULEINFO = undefined;
            if (windows.kernel32.K32GetModuleInformation(
                process_handle,
                module,
                &info,
                @sizeOf(@TypeOf(info)),
            ) == 0)
                return error.MissingDebugInfo;

            const seg_start = @ptrToInt(info.lpBaseOfDll);
            const seg_end = seg_start + info.SizeOfImage;

            if (address >= seg_start and address < seg_end) {
                if (address_map.get(seg_start)) |obj_di| {
                    return obj_di;
                }

                var name_buffer: [windows.PATH_MAX_WIDE + 4:0]u16 = undefined;
                // openFileAbsoluteW requires the prefix to be present
                mem.copy(u16, name_buffer[0..4], &[_]u16{ '\\', '?', '?', '\\' });
                const len = windows.kernel32.K32GetModuleFileNameExW(
                    process_handle,
                    module,
                    @ptrCast(windows.LPWSTR, &name_buffer[4]),
                    windows.PATH_MAX_WIDE,
                );
                assert(len > 0);

                const obj_di = try allocator.create(Self);
                errdefer allocator.destroy(obj_di);

                const coff_file = fs.openFileAbsoluteW(name_buffer[0 .. len + 4 :0], .{}) catch |err| switch (err) {
                    error.FileNotFound => return error.MissingDebugInfo,
                    else => return err,
                };
                obj_di.* = try readCoffDebugInfo(allocator, coff_file);
                obj_di.base_address = seg_start;

                try address_map.putNoClobber(seg_start, obj_di);

                return obj_di;
            }
        }

        return error.MissingDebugInfo;
    }

    /// This takes ownership of coff_file: users of this function should not close
    /// it themselves, even on error.
    /// TODO resources https://github.com/ziglang/zig/issues/4353
    /// TODO it's weird to take ownership even on error, rework this code.
    fn readCoffDebugInfo(allocator: *mem.Allocator, coff_file: File) !Self {
        nosuspend {
            errdefer coff_file.close();

            const coff_obj = try allocator.create(coff.Coff);
            coff_obj.* = coff.Coff.init(allocator, coff_file);

            var di = Self{
                .base_address = undefined,
                .coff = coff_obj,
                .debug_data = undefined,
            };

            try di.coff.loadHeader();
            try di.coff.loadSections();
            if (di.coff.getSection(".debug_info")) |sec| {
                // This coff file has embedded DWARF debug info
                _ = sec;
                // TODO: free the section data slices
                const debug_info_data = di.coff.getSectionData(".debug_info", allocator) catch null;
                const debug_abbrev_data = di.coff.getSectionData(".debug_abbrev", allocator) catch null;
                const debug_str_data = di.coff.getSectionData(".debug_str", allocator) catch null;
                const debug_line_data = di.coff.getSectionData(".debug_line", allocator) catch null;
                const debug_ranges_data = di.coff.getSectionData(".debug_ranges", allocator) catch null;

                var dwarf = DW.DwarfInfo{
                    .endian = native_endian,
                    .debug_info = debug_info_data orelse return error.MissingDebugInfo,
                    .debug_abbrev = debug_abbrev_data orelse return error.MissingDebugInfo,
                    .debug_str = debug_str_data orelse return error.MissingDebugInfo,
                    .debug_line = debug_line_data orelse return error.MissingDebugInfo,
                    .debug_ranges = debug_ranges_data,
                };
                try DW.openDwarfDebugInfo(&dwarf, allocator);
                di.debug_data = PdbOrDwarf{ .dwarf = dwarf };
                return di;
            }

            var path_buf: [windows.MAX_PATH]u8 = undefined;
            const len = try di.coff.getPdbPath(path_buf[0..]);
            const raw_path = path_buf[0..len];

            const path = try fs.path.resolve(allocator, &[_][]const u8{raw_path});
            defer allocator.free(path);

            di.debug_data = PdbOrDwarf{ .pdb = undefined };
            di.debug_data.pdb = try pdb.Pdb.init(allocator, path);
            try di.debug_data.pdb.parseInfoStream();
            try di.debug_data.pdb.parseDbiStream();

            if (!mem.eql(u8, &di.coff.guid, &di.debug_data.pdb.guid) or di.coff.age != di.debug_data.pdb.age)
                return error.InvalidDebugInfo;

            return di;
        }
    }

    pub fn addressToSymbol(self: *Self, address: usize) !SymbolInfo {
        // Translate the VA into an address into this object
        const relocated_address = address - self.base_address;

        switch (self.debug_data) {
            .dwarf => |*dwarf| {
                const dwarf_address = relocated_address + self.coff.pe_header.image_base;
                return getSymbolFromDwarf(dwarf_address, dwarf);
            },
            .pdb => {
                // fallthrough to pdb handling
            },
        }

        var coff_section: *coff.Section = undefined;
        const mod_index = for (self.debug_data.pdb.sect_contribs) |sect_contrib| {
            if (sect_contrib.Section > self.coff.sections.items.len) continue;
            // Remember that SectionContribEntry.Section is 1-based.
            coff_section = &self.coff.sections.items[sect_contrib.Section - 1];

            const vaddr_start = coff_section.header.virtual_address + sect_contrib.Offset;
            const vaddr_end = vaddr_start + sect_contrib.Size;
            if (relocated_address >= vaddr_start and relocated_address < vaddr_end) {
                break sect_contrib.ModuleIndex;
            }
        } else {
            // we have no information to add to the address
            return SymbolInfo{};
        };

        const module = (try self.debug_data.pdb.getModule(mod_index)) orelse
            return error.InvalidDebugInfo;
        const obj_basename = fs.path.basename(module.obj_file_name);

        const symbol_name = self.debug_data.pdb.getSymbolName(
            module,
            relocated_address - coff_section.header.virtual_address,
        ) orelse "???";
        const opt_line_info = try self.debug_data.pdb.getLineNumberInfo(
            module,
            relocated_address - coff_section.header.virtual_address,
        );

        return SymbolInfo{
            .symbol_name = symbol_name,
            .compile_unit_name = obj_basename,
            .line_info = opt_line_info,
        };
    }
};
