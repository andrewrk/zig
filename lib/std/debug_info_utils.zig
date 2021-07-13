//! Misc utility functions for creating a `SymbolMap` for `std.debug`
//! TODO: better name for this file?

const std = @import("std.zig");
const SymbolMap = std.debug.SymbolMap;
const SymbolInfo = SymbolMap.SymbolInfo;
const mem = std.mem;
const DW = std.dwarf;
const os = std.os;
const math = std.math;
const File = std.fs.File;

pub fn SymbolMapStateFromModuleInfo(comptime Module: type) type {
    return struct {
        const Self = @This();

        pub const AddressMap = std.AutoHashMap(usize, *Module);

        allocator: *mem.Allocator,
        address_map: AddressMap,
        symbol_map: SymbolMap,

        pub fn init(allocator: *mem.Allocator) !*SymbolMap {
            const value = try allocator.create(Self);
            value.* = Self{
                .allocator = allocator,
                .address_map = std.AutoHashMap(usize, *Module).init(allocator),
                .symbol_map = .{
                    .deinitFn = deinit,
                    .addressToSymbolFn = addressToSymbol,
                },
            };

            return &value.symbol_map;
        }

        fn deinit(symbol_map: *SymbolMap) void {
            const self = @fieldParentPtr(Self, "symbol_map", symbol_map);
            self.address_map.deinit();
            self.allocator.destroy(self);
        }

        fn addressToSymbol(symbol_map: *SymbolMap, address: usize) !SymbolInfo {
            const self = @fieldParentPtr(Self, "symbol_map", symbol_map);
            const module = Module.lookup(self.allocator, &self.address_map, address) catch |err|
                return if (std.meta.errorInSet(err, BaseError)) SymbolInfo{} else return err;
            return module.addressToSymbol(address);
        }
    };
}

const BaseError = error{
    MissingDebugInfo,
    InvalidDebugInfo,
};

pub fn chopSlice(ptr: []const u8, offset: u64, size: u64) ![]const u8 {
    const start = try math.cast(usize, offset);
    const end = start + try math.cast(usize, size);
    return ptr[start..end];
}

/// `file` is expected to have been opened with .intended_io_mode == .blocking.
/// Takes ownership of file, even on error.
/// TODO it's weird to take ownership even on error, rework this code.
pub fn mapWholeFile(file: File) ![]align(mem.page_size) const u8 {
    nosuspend {
        defer file.close();

        const file_len = try math.cast(usize, try file.getEndPos());
        const mapped_mem = try os.mmap(
            null,
            file_len,
            os.PROT_READ,
            os.MAP_SHARED,
            file.handle,
            0,
        );
        errdefer os.munmap(mapped_mem);

        return mapped_mem;
    }
}
