const Coff = @This();

const std = @import("std");
const log = std.log.scoped(.link);
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const fs = std.fs;
const allocPrint = std.fmt.allocPrint;
const mem = std.mem;

const trace = @import("../tracy.zig").trace;
const Module = @import("../Module.zig");
const Compilation = @import("../Compilation.zig");
const codegen = @import("../codegen.zig");
const link = @import("../link.zig");
const build_options = @import("build_options");
const Cache = @import("../Cache.zig");
const mingw = @import("../mingw.zig");
const llvm_backend = @import("../codegen/llvm.zig");

const allocation_padding = 4 / 3;
const minimum_text_block_size = 64 * allocation_padding;

const section_alignment = 4096;
const file_alignment = 512;
const default_image_base = 0x400_000;
const section_table_size = 2 * 40;
comptime {
    assert(mem.isAligned(default_image_base, section_alignment));
}

pub const base_tag: link.File.Tag = .coff;

const msdos_stub = @embedFile("msdos-stub.bin");

/// If this is not null, an object file is created by LLVM and linked with LLD afterwards.
llvm_object: ?*llvm_backend.Object = null,

base: link.File,
ptr_width: PtrWidth,
error_flags: link.File.ErrorFlags = .{},

text_block_free_list: std.ArrayListUnmanaged(*TextBlock) = .{},
last_text_block: ?*TextBlock = null,

/// Section table file pointer.
section_table_offset: u32 = 0,
/// Section data file pointer.
section_data_offset: u32 = 0,
/// Optiona header file pointer.
optional_header_offset: u32 = 0,

/// Absolute virtual address of the offset table when the executable is loaded in memory.
offset_table_virtual_address: u32 = 0,
/// Current size of the offset table on disk, must be a multiple of `file_alignment`
offset_table_size: u32 = 0,
/// Contains absolute virtual addresses
offset_table: std.ArrayListUnmanaged(u64) = .{},
/// Free list of offset table indices
offset_table_free_list: std.ArrayListUnmanaged(u32) = .{},

/// Virtual address of the entry point procedure relative to image base.
entry_addr: ?u32 = null,

/// Absolute virtual address of the text section when the executable is loaded in memory.
text_section_virtual_address: u32 = 0,
/// Current size of the `.text` section on disk, must be a multiple of `file_alignment`
text_section_size: u32 = 0,

offset_table_size_dirty: bool = false,
text_section_size_dirty: bool = false,
/// This flag is set when the virtual size of the whole image file when loaded in memory has changed
/// and needs to be updated in the optional header.
size_of_image_dirty: bool = false,

pub const PtrWidth = enum { p32, p64 };

pub const TextBlock = struct {
    /// Offset of the code relative to the start of the text section
    text_offset: u32,
    /// Used size of the text block
    size: u32,
    /// This field is undefined for symbols with size = 0.
    offset_table_index: u32,
    /// Points to the previous and next neighbors, based on the `text_offset`.
    /// This can be used to find, for example, the capacity of this `TextBlock`.
    prev: ?*TextBlock,
    next: ?*TextBlock,

    pub const empty = TextBlock{
        .text_offset = 0,
        .size = 0,
        .offset_table_index = undefined,
        .prev = null,
        .next = null,
    };

    /// Returns how much room there is to grow in virtual address space.
    fn capacity(self: TextBlock) u64 {
        if (self.next) |next| {
            return next.text_offset - self.text_offset;
        }
        // This is the last block, the capacity is only limited by the address space.
        return std.math.maxInt(u32) - self.text_offset;
    }

    fn freeListEligible(self: TextBlock) bool {
        // No need to keep a free list node for the last block.
        const next = self.next orelse return false;
        const cap = next.text_offset - self.text_offset;
        const ideal_cap = self.size * allocation_padding;
        if (cap <= ideal_cap) return false;
        const surplus = cap - ideal_cap;
        return surplus >= minimum_text_block_size;
    }

    /// Absolute virtual address of the text block when the file is loaded in memory.
    fn getVAddr(self: TextBlock, coff: Coff) u32 {
        return coff.text_section_virtual_address + self.text_offset;
    }
};

pub const SrcFn = void;

pub fn openPath(allocator: *Allocator, sub_path: []const u8, options: link.Options) !*Coff {
    assert(options.object_format == .coff);

    if (build_options.have_llvm and options.use_llvm) {
        const self = try createEmpty(allocator, options);
        errdefer self.base.destroy();

        self.llvm_object = try llvm_backend.Object.create(allocator, sub_path, options);
        return self;
    }

    const file = try options.emit.?.directory.handle.createFile(sub_path, .{
        .truncate = false,
        .read = true,
        .mode = link.determineMode(options),
    });
    errdefer file.close();

    const self = try createEmpty(allocator, options);
    errdefer self.base.destroy();

    self.base.file = file;

    // TODO Write object specific relocations, COFF symbol table, then enable object file output.
    switch (options.output_mode) {
        .Exe => {},
        .Obj => return error.TODOImplementWritingObjFiles,
        .Lib => return error.TODOImplementWritingLibFiles,
    }

    var coff_file_header_offset: u32 = 0;
    if (options.output_mode == .Exe) {
        // Write the MS-DOS stub and the PE signature
        try self.base.file.?.pwriteAll(msdos_stub ++ "PE\x00\x00", 0);
        coff_file_header_offset = msdos_stub.len + 4;
    }

    // COFF file header
    const data_directory_count = 0;
    var hdr_data: [112 + data_directory_count * 8 + section_table_size]u8 = undefined;
    var index: usize = 0;

    const machine = self.base.options.target.cpu.arch.toCoffMachine();
    if (machine == .Unknown) {
        return error.UnsupportedCOFFArchitecture;
    }
    mem.writeIntLittle(u16, hdr_data[0..2], @enumToInt(machine));
    index += 2;

    // Number of sections (we only use .got, .text)
    mem.writeIntLittle(u16, hdr_data[index..][0..2], 2);
    index += 2;
    // TimeDateStamp (u32), PointerToSymbolTable (u32), NumberOfSymbols (u32)
    mem.set(u8, hdr_data[index..][0..12], 0);
    index += 12;

    const optional_header_size = switch (options.output_mode) {
        .Exe => data_directory_count * 8 + switch (self.ptr_width) {
            .p32 => @as(u16, 96),
            .p64 => 112,
        },
        else => 0,
    };

    const section_table_offset = coff_file_header_offset + 20 + optional_header_size;
    const default_offset_table_size = file_alignment;
    const default_size_of_code = 0;

    self.section_data_offset = mem.alignForwardGeneric(u32, self.section_table_offset + section_table_size, file_alignment);
    const section_data_relative_virtual_address = mem.alignForwardGeneric(u32, self.section_table_offset + section_table_size, section_alignment);
    self.offset_table_virtual_address = default_image_base + section_data_relative_virtual_address;
    self.offset_table_size = default_offset_table_size;
    self.section_table_offset = section_table_offset;
    self.text_section_virtual_address = default_image_base + section_data_relative_virtual_address + section_alignment;
    self.text_section_size = default_size_of_code;

    // Size of file when loaded in memory
    const size_of_image = mem.alignForwardGeneric(u32, self.text_section_virtual_address - default_image_base + default_size_of_code, section_alignment);

    mem.writeIntLittle(u16, hdr_data[index..][0..2], optional_header_size);
    index += 2;

    // Characteristics
    var characteristics: u16 = std.coff.IMAGE_FILE_DEBUG_STRIPPED | std.coff.IMAGE_FILE_RELOCS_STRIPPED; // TODO Remove debug info stripped flag when necessary
    if (options.output_mode == .Exe) {
        characteristics |= std.coff.IMAGE_FILE_EXECUTABLE_IMAGE;
    }
    switch (self.ptr_width) {
        .p32 => characteristics |= std.coff.IMAGE_FILE_32BIT_MACHINE,
        .p64 => characteristics |= std.coff.IMAGE_FILE_LARGE_ADDRESS_AWARE,
    }
    mem.writeIntLittle(u16, hdr_data[index..][0..2], characteristics);
    index += 2;

    assert(index == 20);
    try self.base.file.?.pwriteAll(hdr_data[0..index], coff_file_header_offset);

    if (options.output_mode == .Exe) {
        self.optional_header_offset = coff_file_header_offset + 20;
        // Optional header
        index = 0;
        mem.writeIntLittle(u16, hdr_data[0..2], switch (self.ptr_width) {
            .p32 => @as(u16, 0x10b),
            .p64 => 0x20b,
        });
        index += 2;

        // Linker version (u8 + u8)
        mem.set(u8, hdr_data[index..][0..2], 0);
        index += 2;

        // SizeOfCode (UNUSED, u32), SizeOfInitializedData (u32), SizeOfUninitializedData (u32), AddressOfEntryPoint (u32), BaseOfCode (UNUSED, u32)
        mem.set(u8, hdr_data[index..][0..20], 0);
        index += 20;

        if (self.ptr_width == .p32) {
            // Base of data relative to the image base (UNUSED)
            mem.set(u8, hdr_data[index..][0..4], 0);
            index += 4;

            // Image base address
            mem.writeIntLittle(u32, hdr_data[index..][0..4], default_image_base);
            index += 4;
        } else {
            // Image base address
            mem.writeIntLittle(u64, hdr_data[index..][0..8], default_image_base);
            index += 8;
        }

        // Section alignment
        mem.writeIntLittle(u32, hdr_data[index..][0..4], section_alignment);
        index += 4;
        // File alignment
        mem.writeIntLittle(u32, hdr_data[index..][0..4], file_alignment);
        index += 4;
        // Required OS version, 6.0 is vista
        mem.writeIntLittle(u16, hdr_data[index..][0..2], 6);
        index += 2;
        mem.writeIntLittle(u16, hdr_data[index..][0..2], 0);
        index += 2;
        // Image version
        mem.set(u8, hdr_data[index..][0..4], 0);
        index += 4;
        // Required subsystem version, same as OS version
        mem.writeIntLittle(u16, hdr_data[index..][0..2], 6);
        index += 2;
        mem.writeIntLittle(u16, hdr_data[index..][0..2], 0);
        index += 2;
        // Reserved zeroes (u32)
        mem.set(u8, hdr_data[index..][0..4], 0);
        index += 4;
        mem.writeIntLittle(u32, hdr_data[index..][0..4], size_of_image);
        index += 4;
        mem.writeIntLittle(u32, hdr_data[index..][0..4], self.section_data_offset);
        index += 4;
        // CheckSum (u32)
        mem.set(u8, hdr_data[index..][0..4], 0);
        index += 4;
        // Subsystem, TODO: Let users specify the subsystem, always CUI for now
        mem.writeIntLittle(u16, hdr_data[index..][0..2], 3);
        index += 2;
        // DLL characteristics
        mem.writeIntLittle(u16, hdr_data[index..][0..2], 0x0);
        index += 2;

        switch (self.ptr_width) {
            .p32 => {
                // Size of stack reserve + commit
                mem.writeIntLittle(u32, hdr_data[index..][0..4], 0x1_000_000);
                index += 4;
                mem.writeIntLittle(u32, hdr_data[index..][0..4], 0x1_000);
                index += 4;
                // Size of heap reserve + commit
                mem.writeIntLittle(u32, hdr_data[index..][0..4], 0x100_000);
                index += 4;
                mem.writeIntLittle(u32, hdr_data[index..][0..4], 0x1_000);
                index += 4;
            },
            .p64 => {
                // Size of stack reserve + commit
                mem.writeIntLittle(u64, hdr_data[index..][0..8], 0x1_000_000);
                index += 8;
                mem.writeIntLittle(u64, hdr_data[index..][0..8], 0x1_000);
                index += 8;
                // Size of heap reserve + commit
                mem.writeIntLittle(u64, hdr_data[index..][0..8], 0x100_000);
                index += 8;
                mem.writeIntLittle(u64, hdr_data[index..][0..8], 0x1_000);
                index += 8;
            },
        }

        // Reserved zeroes
        mem.set(u8, hdr_data[index..][0..4], 0);
        index += 4;

        // Number of data directories
        mem.writeIntLittle(u32, hdr_data[index..][0..4], data_directory_count);
        index += 4;
        // Initialize data directories to zero
        mem.set(u8, hdr_data[index..][0 .. data_directory_count * 8], 0);
        index += data_directory_count * 8;

        assert(index == optional_header_size);
    }

    // Write section table.
    // First, the .got section
    hdr_data[index..][0..8].* = ".got\x00\x00\x00\x00".*;
    index += 8;
    if (options.output_mode == .Exe) {
        // Virtual size (u32)
        mem.writeIntLittle(u32, hdr_data[index..][0..4], default_offset_table_size);
        index += 4;
        // Virtual address (u32)
        mem.writeIntLittle(u32, hdr_data[index..][0..4], self.offset_table_virtual_address - default_image_base);
        index += 4;
    } else {
        mem.set(u8, hdr_data[index..][0..8], 0);
        index += 8;
    }
    // Size of raw data (u32)
    mem.writeIntLittle(u32, hdr_data[index..][0..4], default_offset_table_size);
    index += 4;
    // File pointer to the start of the section
    mem.writeIntLittle(u32, hdr_data[index..][0..4], self.section_data_offset);
    index += 4;
    // Pointer to relocations (u32), PointerToLinenumbers (u32), NumberOfRelocations (u16), NumberOfLinenumbers (u16)
    mem.set(u8, hdr_data[index..][0..12], 0);
    index += 12;
    // Section flags
    mem.writeIntLittle(u32, hdr_data[index..][0..4], std.coff.IMAGE_SCN_CNT_INITIALIZED_DATA | std.coff.IMAGE_SCN_MEM_READ);
    index += 4;
    // Then, the .text section
    hdr_data[index..][0..8].* = ".text\x00\x00\x00".*;
    index += 8;
    if (options.output_mode == .Exe) {
        // Virtual size (u32)
        mem.writeIntLittle(u32, hdr_data[index..][0..4], default_size_of_code);
        index += 4;
        // Virtual address (u32)
        mem.writeIntLittle(u32, hdr_data[index..][0..4], self.text_section_virtual_address - default_image_base);
        index += 4;
    } else {
        mem.set(u8, hdr_data[index..][0..8], 0);
        index += 8;
    }
    // Size of raw data (u32)
    mem.writeIntLittle(u32, hdr_data[index..][0..4], default_size_of_code);
    index += 4;
    // File pointer to the start of the section
    mem.writeIntLittle(u32, hdr_data[index..][0..4], self.section_data_offset + default_offset_table_size);
    index += 4;
    // Pointer to relocations (u32), PointerToLinenumbers (u32), NumberOfRelocations (u16), NumberOfLinenumbers (u16)
    mem.set(u8, hdr_data[index..][0..12], 0);
    index += 12;
    // Section flags
    mem.writeIntLittle(
        u32,
        hdr_data[index..][0..4],
        std.coff.IMAGE_SCN_CNT_CODE | std.coff.IMAGE_SCN_MEM_EXECUTE | std.coff.IMAGE_SCN_MEM_READ | std.coff.IMAGE_SCN_MEM_WRITE,
    );
    index += 4;

    assert(index == optional_header_size + section_table_size);
    try self.base.file.?.pwriteAll(hdr_data[0..index], self.optional_header_offset);
    try self.base.file.?.setEndPos(self.section_data_offset + default_offset_table_size + default_size_of_code);

    return self;
}

pub fn createEmpty(gpa: *Allocator, options: link.Options) !*Coff {
    const ptr_width: PtrWidth = switch (options.target.cpu.arch.ptrBitWidth()) {
        0...32 => .p32,
        33...64 => .p64,
        else => return error.UnsupportedCOFFArchitecture,
    };
    const self = try gpa.create(Coff);
    self.* = .{
        .base = .{
            .tag = .coff,
            .options = options,
            .allocator = gpa,
            .file = null,
        },
        .ptr_width = ptr_width,
    };
    return self;
}

pub fn allocateDeclIndexes(self: *Coff, decl: *Module.Decl) !void {
    if (self.llvm_object) |_| return;

    try self.offset_table.ensureCapacity(self.base.allocator, self.offset_table.items.len + 1);

    if (self.offset_table_free_list.popOrNull()) |i| {
        decl.link.coff.offset_table_index = i;
    } else {
        decl.link.coff.offset_table_index = @intCast(u32, self.offset_table.items.len);
        _ = self.offset_table.addOneAssumeCapacity();

        const entry_size = self.base.options.target.cpu.arch.ptrBitWidth() / 8;
        if (self.offset_table.items.len > self.offset_table_size / entry_size) {
            self.offset_table_size_dirty = true;
        }
    }

    self.offset_table.items[decl.link.coff.offset_table_index] = 0;
}

fn allocateTextBlock(self: *Coff, text_block: *TextBlock, new_block_size: u64, alignment: u64) !u64 {
    const new_block_min_capacity = new_block_size * allocation_padding;

    // We use these to indicate our intention to update metadata, placing the new block,
    // and possibly removing a free list node.
    // It would be simpler to do it inside the for loop below, but that would cause a
    // problem if an error was returned later in the function. So this action
    // is actually carried out at the end of the function, when errors are no longer possible.
    var block_placement: ?*TextBlock = null;
    var free_list_removal: ?usize = null;

    const vaddr = blk: {
        var i: usize = 0;
        while (i < self.text_block_free_list.items.len) {
            const free_block = self.text_block_free_list.items[i];

            const next_block_text_offset = free_block.text_offset + free_block.capacity();
            const new_block_text_offset = mem.alignForwardGeneric(u64, free_block.getVAddr(self.*) + free_block.size, alignment) - self.text_section_virtual_address;
            if (new_block_text_offset < next_block_text_offset and next_block_text_offset - new_block_text_offset >= new_block_min_capacity) {
                block_placement = free_block;

                const remaining_capacity = next_block_text_offset - new_block_text_offset - new_block_min_capacity;
                if (remaining_capacity < minimum_text_block_size) {
                    free_list_removal = i;
                }

                break :blk new_block_text_offset + self.text_section_virtual_address;
            } else {
                if (!free_block.freeListEligible()) {
                    _ = self.text_block_free_list.swapRemove(i);
                } else {
                    i += 1;
                }
                continue;
            }
        } else if (self.last_text_block) |last| {
            const new_block_vaddr = mem.alignForwardGeneric(u64, last.getVAddr(self.*) + last.size, alignment);
            block_placement = last;
            break :blk new_block_vaddr;
        } else {
            break :blk self.text_section_virtual_address;
        }
    };

    const expand_text_section = block_placement == null or block_placement.?.next == null;
    if (expand_text_section) {
        const needed_size = @intCast(u32, mem.alignForwardGeneric(u64, vaddr + new_block_size - self.text_section_virtual_address, file_alignment));
        if (needed_size > self.text_section_size) {
            const current_text_section_virtual_size = mem.alignForwardGeneric(u32, self.text_section_size, section_alignment);
            const new_text_section_virtual_size = mem.alignForwardGeneric(u32, needed_size, section_alignment);
            if (current_text_section_virtual_size != new_text_section_virtual_size) {
                self.size_of_image_dirty = true;
                // Write new virtual size
                var buf: [4]u8 = undefined;
                mem.writeIntLittle(u32, &buf, new_text_section_virtual_size);
                try self.base.file.?.pwriteAll(&buf, self.section_table_offset + 40 + 8);
            }

            self.text_section_size = needed_size;
            self.text_section_size_dirty = true;
        }
        self.last_text_block = text_block;
    }
    text_block.text_offset = @intCast(u32, vaddr - self.text_section_virtual_address);
    text_block.size = @intCast(u32, new_block_size);

    // This function can also reallocate a text block.
    // In this case we need to "unplug" it from its previous location before
    // plugging it in to its new location.
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

fn growTextBlock(self: *Coff, text_block: *TextBlock, new_block_size: u64, alignment: u64) !u64 {
    const block_vaddr = text_block.getVAddr(self.*);
    const align_ok = mem.alignBackwardGeneric(u64, block_vaddr, alignment) == block_vaddr;
    const need_realloc = !align_ok or new_block_size > text_block.capacity();
    if (!need_realloc) return @as(u64, block_vaddr);
    return self.allocateTextBlock(text_block, new_block_size, alignment);
}

fn shrinkTextBlock(self: *Coff, text_block: *TextBlock, new_block_size: u64) void {
    text_block.size = @intCast(u32, new_block_size);
    if (text_block.capacity() - text_block.size >= minimum_text_block_size) {
        self.text_block_free_list.append(self.base.allocator, text_block) catch {};
    }
}

fn freeTextBlock(self: *Coff, text_block: *TextBlock) void {
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
    if (self.last_text_block == text_block) {
        self.last_text_block = text_block.prev;
    }
    if (text_block.prev) |prev| {
        prev.next = text_block.next;

        if (!already_have_free_list_node and prev.freeListEligible()) {
            // The free list is heuristics, it doesn't have to be perfect, so we can
            // ignore the OOM here.
            self.text_block_free_list.append(self.base.allocator, prev) catch {};
        }
    }

    if (text_block.next) |next| {
        next.prev = text_block.prev;
    }
}

fn writeOffsetTableEntry(self: *Coff, index: usize) !void {
    const entry_size = self.base.options.target.cpu.arch.ptrBitWidth() / 8;
    const endian = self.base.options.target.cpu.arch.endian();

    const offset_table_start = self.section_data_offset;
    if (self.offset_table_size_dirty) {
        const current_raw_size = self.offset_table_size;
        const new_raw_size = self.offset_table_size * 2;
        log.debug("growing offset table from raw size {} to {}\n", .{ current_raw_size, new_raw_size });

        // Move the text section to a new place in the executable
        const current_text_section_start = self.section_data_offset + current_raw_size;
        const new_text_section_start = self.section_data_offset + new_raw_size;

        const amt = try self.base.file.?.copyRangeAll(current_text_section_start, self.base.file.?, new_text_section_start, self.text_section_size);
        if (amt != self.text_section_size) return error.InputOutput;

        // Write the new raw size in the .got header
        var buf: [8]u8 = undefined;
        mem.writeIntLittle(u32, buf[0..4], new_raw_size);
        try self.base.file.?.pwriteAll(buf[0..4], self.section_table_offset + 16);
        // Write the new .text section file offset in the .text section header
        mem.writeIntLittle(u32, buf[0..4], new_text_section_start);
        try self.base.file.?.pwriteAll(buf[0..4], self.section_table_offset + 40 + 20);

        const current_virtual_size = mem.alignForwardGeneric(u32, self.offset_table_size, section_alignment);
        const new_virtual_size = mem.alignForwardGeneric(u32, new_raw_size, section_alignment);
        // If we had to move in the virtual address space, we need to fix the VAs in the offset table, as well as the virtual address of the `.text` section
        // and the virutal size of the `.got` section

        if (new_virtual_size != current_virtual_size) {
            log.debug("growing offset table from virtual size {} to {}\n", .{ current_virtual_size, new_virtual_size });
            self.size_of_image_dirty = true;
            const va_offset = new_virtual_size - current_virtual_size;

            // Write .got virtual size
            mem.writeIntLittle(u32, buf[0..4], new_virtual_size);
            try self.base.file.?.pwriteAll(buf[0..4], self.section_table_offset + 8);

            // Write .text new virtual address
            self.text_section_virtual_address = self.text_section_virtual_address + va_offset;
            mem.writeIntLittle(u32, buf[0..4], self.text_section_virtual_address - default_image_base);
            try self.base.file.?.pwriteAll(buf[0..4], self.section_table_offset + 40 + 12);

            // Fix the VAs in the offset table
            for (self.offset_table.items) |*va, idx| {
                if (va.* != 0) {
                    va.* += va_offset;

                    switch (entry_size) {
                        4 => {
                            mem.writeInt(u32, buf[0..4], @intCast(u32, va.*), endian);
                            try self.base.file.?.pwriteAll(buf[0..4], offset_table_start + idx * entry_size);
                        },
                        8 => {
                            mem.writeInt(u64, &buf, va.*, endian);
                            try self.base.file.?.pwriteAll(&buf, offset_table_start + idx * entry_size);
                        },
                        else => unreachable,
                    }
                }
            }
        }
        self.offset_table_size = new_raw_size;
        self.offset_table_size_dirty = false;
    }
    // Write the new entry
    switch (entry_size) {
        4 => {
            var buf: [4]u8 = undefined;
            mem.writeInt(u32, &buf, @intCast(u32, self.offset_table.items[index]), endian);
            try self.base.file.?.pwriteAll(&buf, offset_table_start + index * entry_size);
        },
        8 => {
            var buf: [8]u8 = undefined;
            mem.writeInt(u64, &buf, self.offset_table.items[index], endian);
            try self.base.file.?.pwriteAll(&buf, offset_table_start + index * entry_size);
        },
        else => unreachable,
    }
}

pub fn updateDecl(self: *Coff, module: *Module, decl: *Module.Decl) !void {
    // TODO COFF/PE debug information
    // TODO Implement exports
    const tracy = trace(@src());
    defer tracy.end();

    if (build_options.have_llvm)
        if (self.llvm_object) |llvm_object| return try llvm_object.updateDecl(module, decl);

    if (decl.val.tag() == .extern_fn) {
        return; // TODO Should we do more when front-end analyzed extern decl?
    }

    var code_buffer = std.ArrayList(u8).init(self.base.allocator);
    defer code_buffer.deinit();

    const res = try codegen.generateSymbol(&self.base, decl.srcLoc(), .{
        .ty = decl.ty,
        .val = decl.val,
    }, &code_buffer, .none);
    const code = switch (res) {
        .externally_managed => |x| x,
        .appended => code_buffer.items,
        .fail => |em| {
            decl.analysis = .codegen_failure;
            try module.failed_decls.put(module.gpa, decl, em);
            return;
        },
    };

    const required_alignment = decl.ty.abiAlignment(self.base.options.target);
    const curr_size = decl.link.coff.size;
    if (curr_size != 0) {
        const capacity = decl.link.coff.capacity();
        const need_realloc = code.len > capacity or
            !mem.isAlignedGeneric(u32, decl.link.coff.text_offset, required_alignment);
        if (need_realloc) {
            const curr_vaddr = self.getDeclVAddr(decl);
            const vaddr = try self.growTextBlock(&decl.link.coff, code.len, required_alignment);
            log.debug("growing {s} from 0x{x} to 0x{x}\n", .{ decl.name, curr_vaddr, vaddr });
            if (vaddr != curr_vaddr) {
                log.debug("  (writing new offset table entry)\n", .{});
                self.offset_table.items[decl.link.coff.offset_table_index] = vaddr;
                try self.writeOffsetTableEntry(decl.link.coff.offset_table_index);
            }
        } else if (code.len < curr_size) {
            self.shrinkTextBlock(&decl.link.coff, code.len);
        }
    } else {
        const vaddr = try self.allocateTextBlock(&decl.link.coff, code.len, required_alignment);
        log.debug("allocated text block for {s} at 0x{x} (size: {Bi})\n", .{
            mem.spanZ(decl.name),
            vaddr,
            std.fmt.fmtIntSizeDec(code.len),
        });
        errdefer self.freeTextBlock(&decl.link.coff);
        self.offset_table.items[decl.link.coff.offset_table_index] = vaddr;
        try self.writeOffsetTableEntry(decl.link.coff.offset_table_index);
    }

    // Write the code into the file
    try self.base.file.?.pwriteAll(code, self.section_data_offset + self.offset_table_size + decl.link.coff.text_offset);

    // Since we updated the vaddr and the size, each corresponding export symbol also needs to be updated.
    const decl_exports = module.decl_exports.get(decl) orelse &[0]*Module.Export{};
    return self.updateDeclExports(module, decl, decl_exports);
}

pub fn freeDecl(self: *Coff, decl: *Module.Decl) void {
    if (self.llvm_object) |_| return;

    // Appending to free lists is allowed to fail because the free lists are heuristics based anyway.
    self.freeTextBlock(&decl.link.coff);
    self.offset_table_free_list.append(self.base.allocator, decl.link.coff.offset_table_index) catch {};
}

pub fn updateDeclExports(self: *Coff, module: *Module, decl: *Module.Decl, exports: []const *Module.Export) !void {
    if (self.llvm_object) |_| return;

    for (exports) |exp| {
        if (exp.options.section) |section_name| {
            if (!mem.eql(u8, section_name, ".text")) {
                try module.failed_exports.ensureCapacity(module.gpa, module.failed_exports.count() + 1);
                module.failed_exports.putAssumeCapacityNoClobber(
                    exp,
                    try Module.ErrorMsg.create(self.base.allocator, decl.srcLoc(), "Unimplemented: ExportOptions.section", .{}),
                );
                continue;
            }
        }
        if (mem.eql(u8, exp.options.name, "_start")) {
            self.entry_addr = decl.link.coff.getVAddr(self.*) - default_image_base;
        } else {
            try module.failed_exports.ensureCapacity(module.gpa, module.failed_exports.count() + 1);
            module.failed_exports.putAssumeCapacityNoClobber(
                exp,
                try Module.ErrorMsg.create(self.base.allocator, decl.srcLoc(), "Unimplemented: Exports other than '_start'", .{}),
            );
            continue;
        }
    }
}

pub fn flush(self: *Coff, comp: *Compilation) !void {
    if (build_options.have_llvm and self.base.options.use_lld) {
        return self.linkWithLLD(comp);
    } else {
        switch (self.base.options.effectiveOutputMode()) {
            .Exe, .Obj => {},
            .Lib => return error.TODOImplementWritingLibFiles,
        }
        return self.flushModule(comp);
    }
}

pub fn flushModule(self: *Coff, comp: *Compilation) !void {
    const tracy = trace(@src());
    defer tracy.end();

    if (build_options.have_llvm)
        if (self.llvm_object) |llvm_object| return try llvm_object.flushModule(comp);

    if (self.text_section_size_dirty) {
        // Write the new raw size in the .text header
        var buf: [4]u8 = undefined;
        mem.writeIntLittle(u32, &buf, self.text_section_size);
        try self.base.file.?.pwriteAll(&buf, self.section_table_offset + 40 + 16);
        try self.base.file.?.setEndPos(self.section_data_offset + self.offset_table_size + self.text_section_size);
        self.text_section_size_dirty = false;
    }

    if (self.base.options.output_mode == .Exe and self.size_of_image_dirty) {
        const new_size_of_image = mem.alignForwardGeneric(u32, self.text_section_virtual_address - default_image_base + self.text_section_size, section_alignment);
        var buf: [4]u8 = undefined;
        mem.writeIntLittle(u32, &buf, new_size_of_image);
        try self.base.file.?.pwriteAll(&buf, self.optional_header_offset + 56);
        self.size_of_image_dirty = false;
    }

    if (self.entry_addr == null and self.base.options.output_mode == .Exe) {
        log.debug("flushing. no_entry_point_found = true\n", .{});
        self.error_flags.no_entry_point_found = true;
    } else {
        log.debug("flushing. no_entry_point_found = false\n", .{});
        self.error_flags.no_entry_point_found = false;

        if (self.base.options.output_mode == .Exe) {
            // Write AddressOfEntryPoint
            var buf: [4]u8 = undefined;
            mem.writeIntLittle(u32, &buf, self.entry_addr.?);
            try self.base.file.?.pwriteAll(&buf, self.optional_header_offset + 16);
        }
    }
}

fn linkWithLLD(self: *Coff, comp: *Compilation) !void {
    const tracy = trace(@src());
    defer tracy.end();

    var arena_allocator = std.heap.ArenaAllocator.init(self.base.allocator);
    defer arena_allocator.deinit();
    const arena = &arena_allocator.allocator;

    const directory = self.base.options.emit.?.directory; // Just an alias to make it shorter to type.

    // If there is no Zig code to compile, then we should skip flushing the output file because it
    // will not be part of the linker line anyway.
    const module_obj_path: ?[]const u8 = if (self.base.options.module) |module| blk: {
        // Both stage1 and stage2 LLVM backend put the object file in the cache directory.
        if (self.base.options.use_llvm) {
            // Stage2 has to call flushModule since that outputs the LLVM object file.
            if (!build_options.is_stage1) try self.flushModule(comp);

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
    const link_in_crt = self.base.options.link_libc and is_exe_or_dyn_lib;
    const target = self.base.options.target;

    // See link/Elf.zig for comments on how this mechanism works.
    const id_symlink_basename = "lld.id";

    var man: Cache.Manifest = undefined;
    defer if (!self.base.options.disable_lld_caching) man.deinit();

    var digest: [Cache.hex_digest_len]u8 = undefined;

    if (!self.base.options.disable_lld_caching) {
        man = comp.cache_parent.obtain();
        self.base.releaseLock();

        try man.addListOfFiles(self.base.options.objects);
        for (comp.c_object_table.keys()) |key| {
            _ = try man.addFile(key.status.success.object_path, null);
        }
        try man.addOptionalFile(module_obj_path);
        man.hash.addOptional(self.base.options.stack_size_override);
        man.hash.addOptional(self.base.options.image_base_override);
        man.hash.addListOfBytes(self.base.options.extra_lld_args);
        man.hash.addListOfBytes(self.base.options.lib_dirs);
        man.hash.add(self.base.options.skip_linker_dependencies);
        if (self.base.options.link_libc) {
            man.hash.add(self.base.options.libc_installation != null);
            if (self.base.options.libc_installation) |libc_installation| {
                man.hash.addBytes(libc_installation.crt_dir.?);
                if (target.abi == .msvc) {
                    man.hash.addBytes(libc_installation.msvc_lib_dir.?);
                    man.hash.addBytes(libc_installation.kernel32_lib_dir.?);
                }
            }
        }
        man.hash.addStringSet(self.base.options.system_libs);
        man.hash.addOptional(self.base.options.subsystem);
        man.hash.add(self.base.options.is_test);
        man.hash.add(self.base.options.tsaware);
        man.hash.add(self.base.options.nxcompat);
        man.hash.add(self.base.options.dynamicbase);
        man.hash.addOptional(self.base.options.major_subsystem_version);
        man.hash.addOptional(self.base.options.minor_subsystem_version);
        man.hash.addOptionalBytes(self.base.options.out_implib);

        // We don't actually care whether it's a cache hit or miss; we just need the digest and the lock.
        _ = try man.hit();
        digest = man.final();
        var prev_digest_buf: [digest.len]u8 = undefined;
        const prev_digest: []u8 = Cache.readSmallFile(
            directory.handle,
            id_symlink_basename,
            &prev_digest_buf,
        ) catch |err| blk: {
            log.debug("COFF LLD new_digest={s} error: {s}", .{ std.fmt.fmtSliceHexLower(&digest), @errorName(err) });
            // Handle this as a cache miss.
            break :blk prev_digest_buf[0..0];
        };
        if (mem.eql(u8, prev_digest, &digest)) {
            log.debug("COFF LLD digest={s} match - skipping invocation", .{std.fmt.fmtSliceHexLower(&digest)});
            // Hot diggity dog! The output binary is already there.
            self.base.lock = man.toOwnedLock();
            return;
        }
        log.debug("COFF LLD prev_digest={s} new_digest={s}", .{ std.fmt.fmtSliceHexLower(prev_digest), std.fmt.fmtSliceHexLower(&digest) });

        // We are about to change the output file to be different, so we invalidate the build hash now.
        directory.handle.deleteFile(id_symlink_basename) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        };
    }

    const full_out_path = try directory.join(arena, &[_][]const u8{self.base.options.emit.?.sub_path});

    if (self.base.options.output_mode == .Obj) {
        // LLD's COFF driver does not support the equvialent of `-r` so we do a simple file copy
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
        try argv.appendSlice(&[_][]const u8{ comp.self_exe_path.?, "lld-link" });

        try argv.append("-ERRORLIMIT:0");
        try argv.append("-NOLOGO");
        if (!self.base.options.strip) {
            try argv.append("-DEBUG");
        }
        if (self.base.options.lto) {
            switch (self.base.options.optimize_mode) {
                .Debug => {},
                .ReleaseSmall => try argv.append("-OPT:lldlto=2"),
                .ReleaseFast, .ReleaseSafe => try argv.append("-OPT:lldlto=3"),
            }
        }
        if (self.base.options.output_mode == .Exe) {
            const stack_size = self.base.options.stack_size_override orelse 16777216;
            try argv.append(try allocPrint(arena, "-STACK:{d}", .{stack_size}));
        }
        if (self.base.options.image_base_override) |image_base| {
            try argv.append(try std.fmt.allocPrint(arena, "-BASE:{d}", .{image_base}));
        }

        if (target.cpu.arch == .i386) {
            try argv.append("-MACHINE:X86");
        } else if (target.cpu.arch == .x86_64) {
            try argv.append("-MACHINE:X64");
        } else if (target.cpu.arch.isARM()) {
            if (target.cpu.arch.ptrBitWidth() == 32) {
                try argv.append("-MACHINE:ARM");
            } else {
                try argv.append("-MACHINE:ARM64");
            }
        }

        if (is_dyn_lib) {
            try argv.append("-DLL");
        }

        if (self.base.options.tsaware) {
            try argv.append("-tsaware");
        }
        if (self.base.options.nxcompat) {
            try argv.append("-nxcompat");
        }
        if (self.base.options.dynamicbase) {
            try argv.append("-dynamicbase");
        }

        try argv.appendSlice(self.base.options.extra_lld_args);

        const subsystem_suffix = ss: {
            if (self.base.options.major_subsystem_version) |major| {
                if (self.base.options.minor_subsystem_version) |minor| {
                    break :ss try allocPrint(arena, ",{d}.{d}", .{ major, minor });
                } else {
                    break :ss try allocPrint(arena, ",{d}", .{major});
                }
            }
            break :ss "";
        };

        try argv.append(try allocPrint(arena, "-OUT:{s}", .{full_out_path}));

        if (self.base.options.link_libc) {
            if (self.base.options.libc_installation) |libc_installation| {
                try argv.append(try allocPrint(arena, "-LIBPATH:{s}", .{libc_installation.crt_dir.?}));

                if (target.abi == .msvc) {
                    try argv.append(try allocPrint(arena, "-LIBPATH:{s}", .{libc_installation.msvc_lib_dir.?}));
                    try argv.append(try allocPrint(arena, "-LIBPATH:{s}", .{libc_installation.kernel32_lib_dir.?}));
                }
            }
        }

        for (self.base.options.lib_dirs) |lib_dir| {
            try argv.append(try allocPrint(arena, "-LIBPATH:{s}", .{lib_dir}));
        }

        try argv.appendSlice(self.base.options.objects);

        for (comp.c_object_table.keys()) |key| {
            try argv.append(key.status.success.object_path);
        }

        if (module_obj_path) |p| {
            try argv.append(p);
        }

        if (self.base.options.out_implib) |out_implib| {
            try argv.append(try allocPrint(arena, "-IMPLIB:{s}.lib", .{full_out_path}));
        }

        const resolved_subsystem: ?std.Target.SubSystem = blk: {
            if (self.base.options.subsystem) |explicit| break :blk explicit;
            switch (target.os.tag) {
                .windows => {
                    if (self.base.options.module) |module| {
                        if (module.stage1_flags.have_dllmain_crt_startup or is_dyn_lib)
                            break :blk null;
                        if (module.stage1_flags.have_c_main or self.base.options.is_test or
                            module.stage1_flags.have_winmain_crt_startup or
                            module.stage1_flags.have_wwinmain_crt_startup)
                        {
                            break :blk .Console;
                        }
                        if (module.stage1_flags.have_winmain or module.stage1_flags.have_wwinmain)
                            break :blk .Windows;
                    }
                },
                .uefi => break :blk .EfiApplication,
                else => {},
            }
            break :blk null;
        };
        const Mode = enum { uefi, win32 };
        const mode: Mode = mode: {
            if (resolved_subsystem) |subsystem| switch (subsystem) {
                .Console => {
                    try argv.append(try allocPrint(arena, "-SUBSYSTEM:console{s}", .{
                        subsystem_suffix,
                    }));
                    break :mode .win32;
                },
                .EfiApplication => {
                    try argv.append(try allocPrint(arena, "-SUBSYSTEM:efi_application{s}", .{
                        subsystem_suffix,
                    }));
                    break :mode .uefi;
                },
                .EfiBootServiceDriver => {
                    try argv.append(try allocPrint(arena, "-SUBSYSTEM:efi_boot_service_driver{s}", .{
                        subsystem_suffix,
                    }));
                    break :mode .uefi;
                },
                .EfiRom => {
                    try argv.append(try allocPrint(arena, "-SUBSYSTEM:efi_rom{s}", .{
                        subsystem_suffix,
                    }));
                    break :mode .uefi;
                },
                .EfiRuntimeDriver => {
                    try argv.append(try allocPrint(arena, "-SUBSYSTEM:efi_runtime_driver{s}", .{
                        subsystem_suffix,
                    }));
                    break :mode .uefi;
                },
                .Native => {
                    try argv.append(try allocPrint(arena, "-SUBSYSTEM:native{s}", .{
                        subsystem_suffix,
                    }));
                    break :mode .win32;
                },
                .Posix => {
                    try argv.append(try allocPrint(arena, "-SUBSYSTEM:posix{s}", .{
                        subsystem_suffix,
                    }));
                    break :mode .win32;
                },
                .Windows => {
                    try argv.append(try allocPrint(arena, "-SUBSYSTEM:windows{s}", .{
                        subsystem_suffix,
                    }));
                    break :mode .win32;
                },
            } else if (target.os.tag == .uefi) {
                break :mode .uefi;
            } else {
                break :mode .win32;
            }
        };

        switch (mode) {
            .uefi => try argv.appendSlice(&[_][]const u8{
                "-BASE:0",
                "-ENTRY:EfiMain",
                "-OPT:REF",
                "-SAFESEH:NO",
                "-MERGE:.rdata=.data",
                "-ALIGN:32",
                "-NODEFAULTLIB",
                "-SECTION:.xdata,D",
            }),
            .win32 => {
                if (link_in_crt) {
                    if (target.abi.isGnu()) {
                        try argv.append("-lldmingw");

                        if (target.cpu.arch == .i386) {
                            try argv.append("-ALTERNATENAME:__image_base__=___ImageBase");
                        } else {
                            try argv.append("-ALTERNATENAME:__image_base__=__ImageBase");
                        }

                        if (is_dyn_lib) {
                            try argv.append(try comp.get_libc_crt_file(arena, "dllcrt2.obj"));
                            if (target.cpu.arch == .i386) {
                                try argv.append("-ALTERNATENAME:__DllMainCRTStartup@12=_DllMainCRTStartup@12");
                            } else {
                                try argv.append("-ALTERNATENAME:_DllMainCRTStartup=DllMainCRTStartup");
                            }
                        } else {
                            try argv.append(try comp.get_libc_crt_file(arena, "crt2.obj"));
                        }

                        try argv.append(try comp.get_libc_crt_file(arena, "mingw32.lib"));
                        try argv.append(try comp.get_libc_crt_file(arena, "mingwex.lib"));
                        try argv.append(try comp.get_libc_crt_file(arena, "msvcrt-os.lib"));

                        for (mingw.always_link_libs) |name| {
                            if (!self.base.options.system_libs.contains(name)) {
                                const lib_basename = try allocPrint(arena, "{s}.lib", .{name});
                                try argv.append(try comp.get_libc_crt_file(arena, lib_basename));
                            }
                        }
                    } else {
                        const lib_str = switch (self.base.options.link_mode) {
                            .Dynamic => "",
                            .Static => "lib",
                        };
                        const d_str = switch (self.base.options.optimize_mode) {
                            .Debug => "d",
                            else => "",
                        };
                        switch (self.base.options.link_mode) {
                            .Static => try argv.append(try allocPrint(arena, "libcmt{s}.lib", .{d_str})),
                            .Dynamic => try argv.append(try allocPrint(arena, "msvcrt{s}.lib", .{d_str})),
                        }

                        try argv.append(try allocPrint(arena, "{s}vcruntime{s}.lib", .{ lib_str, d_str }));
                        try argv.append(try allocPrint(arena, "{s}ucrt{s}.lib", .{ lib_str, d_str }));

                        //Visual C++ 2015 Conformance Changes
                        //https://msdn.microsoft.com/en-us/library/bb531344.aspx
                        try argv.append("legacy_stdio_definitions.lib");

                        // msvcrt depends on kernel32 and ntdll
                        try argv.append("kernel32.lib");
                        try argv.append("ntdll.lib");
                    }
                } else {
                    try argv.append("-NODEFAULTLIB");
                    if (!is_lib) {
                        if (self.base.options.module) |module| {
                            if (module.stage1_flags.have_winmain_crt_startup) {
                                try argv.append("-ENTRY:WinMainCRTStartup");
                            } else {
                                try argv.append("-ENTRY:wWinMainCRTStartup");
                            }
                        } else {
                            try argv.append("-ENTRY:wWinMainCRTStartup");
                        }
                    }
                }
            },
        }

        // libc++ dep
        if (self.base.options.link_libcpp) {
            try argv.append(comp.libcxxabi_static_lib.?.full_object_path);
            try argv.append(comp.libcxx_static_lib.?.full_object_path);
            try argv.append(comp.libunwind_static_lib.?.full_object_path);
        }

        // TODO: remove when stage2 can build compiler_rt.zig, c.zig and ssp.zig
        // compiler-rt, libc and libssp
        if (is_exe_or_dyn_lib and !self.base.options.skip_linker_dependencies and build_options.is_stage1) {
            if (!self.base.options.link_libc) {
                try argv.append(comp.libc_static_lib.?.full_object_path);
            }
            // MinGW doesn't provide libssp symbols
            if (target.abi.isGnu()) {
                try argv.append(comp.libssp_static_lib.?.full_object_path);
            }
            // MSVC compiler_rt is missing some stuff, so we build it unconditionally but
            // and rely on weak linkage to allow MSVC compiler_rt functions to override ours.
            try argv.append(comp.compiler_rt_static_lib.?.full_object_path);
        }

        try argv.ensureUnusedCapacity(self.base.options.system_libs.count());
        for (self.base.options.system_libs.keys()) |key| {
            const lib_basename = try allocPrint(arena, "{s}.lib", .{key});
            if (comp.crt_files.get(lib_basename)) |crt_file| {
                argv.appendAssumeCapacity(crt_file.full_object_path);
                continue;
            }
            if (try self.findLib(arena, lib_basename)) |full_path| {
                argv.appendAssumeCapacity(full_path);
                continue;
            }
            if (target.abi.isGnu()) {
                const fallback_name = try allocPrint(arena, "lib{s}.dll.a", .{key});
                if (try self.findLib(arena, fallback_name)) |full_path| {
                    argv.appendAssumeCapacity(full_path);
                    continue;
                }
            }
            log.err("DLL import library for -l{s} not found", .{key});
            return error.DllImportLibraryNotFound;
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

fn findLib(self: *Coff, arena: *Allocator, name: []const u8) !?[]const u8 {
    for (self.base.options.lib_dirs) |lib_dir| {
        const full_path = try fs.path.join(arena, &.{ lib_dir, name });
        fs.cwd().access(full_path, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |e| return e,
        };
        return full_path;
    }
    return null;
}

pub fn getDeclVAddr(self: *Coff, decl: *const Module.Decl) u64 {
    assert(self.llvm_object == null);
    return self.text_section_virtual_address + decl.link.coff.text_offset;
}

pub fn updateDeclLineNumber(self: *Coff, module: *Module, decl: *Module.Decl) !void {
    _ = self;
    _ = module;
    _ = decl;
    // TODO Implement this
}

pub fn deinit(self: *Coff) void {
    if (build_options.have_llvm)
        if (self.llvm_object) |ir_module| ir_module.deinit(self.base.allocator);

    self.text_block_free_list.deinit(self.base.allocator);
    self.offset_table.deinit(self.base.allocator);
    self.offset_table_free_list.deinit(self.base.allocator);
}
