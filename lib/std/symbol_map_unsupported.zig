//! This is so printing a stack trace on an unsupported platform just prints
//! with empty symbols instead of failing to build. This is important for
//! GeneralPurposeAllocator and similar.
//!
//! To implement actual debug symbols, use `root.debug_config.initSymbolMap`
//! or `root.os.debug.initSymbolMap`.

const std = @import("std.zig");
const SymbolMap = std.debug.SymbolMap;
const SymbolInfo = SymbolMap.SymbolInfo;
const mem = std.mem;

const Self = @This();

allocator: *mem.Allocator,
symbol_map: SymbolMap,

pub fn init(allocator: *mem.Allocator) !*SymbolMap {
    const value = try allocator.create(Self);
    value.* = Self{
        .allocator = allocator,
        .symbol_map = .{
            .deinitFn = deinit,
            .addressToSymbolFn = addressToSymbol,
        },
    };

    return &value.symbol_map;
}

fn deinit(_: *SymbolMap) void {}

fn addressToSymbol(_: *SymbolMap, _: usize) !SymbolInfo {
    return SymbolInfo{};
}

test {
    std.testing.refAllDecls(Self);
}
