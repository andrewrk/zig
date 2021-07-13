// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.
pub const ArrayHashMap = array_hash_map.ArrayHashMap;
pub const ArrayHashMapUnmanaged = array_hash_map.ArrayHashMapUnmanaged;
pub const ArrayList = @import("array_list.zig").ArrayList;
pub const ArrayListAligned = @import("array_list.zig").ArrayListAligned;
pub const ArrayListAlignedUnmanaged = @import("array_list.zig").ArrayListAlignedUnmanaged;
pub const ArrayListFixed = @import("array_list_fixed.zig").ArrayListFixed;
pub const ArrayListUnmanaged = @import("array_list.zig").ArrayListUnmanaged;
pub const AutoArrayHashMap = array_hash_map.AutoArrayHashMap;
pub const AutoArrayHashMapUnmanaged = array_hash_map.AutoArrayHashMapUnmanaged;
pub const AutoHashMap = hash_map.AutoHashMap;
pub const AutoHashMapUnmanaged = hash_map.AutoHashMapUnmanaged;
pub const BufMap = @import("buf_map.zig").BufMap;
pub const BufSet = @import("buf_set.zig").BufSet;
pub const ChildProcess = @import("child_process.zig").ChildProcess;
pub const ComptimeStringMap = @import("comptime_string_map.zig").ComptimeStringMap;
pub const DynLib = @import("dynamic_library.zig").DynLib;
pub const DynamicBitSet = bit_set.DynamicBitSet;
pub const DynamicBitSetUnmanaged = bit_set.DynamicBitSetUnmanaged;
pub const EnumArray = enums.EnumArray;
pub const EnumMap = enums.EnumMap;
pub const EnumSet = enums.EnumSet;
pub const HashMap = hash_map.HashMap;
pub const HashMapUnmanaged = hash_map.HashMapUnmanaged;
pub const MultiArrayList = @import("multi_array_list.zig").MultiArrayList;
pub const PackedIntArray = @import("packed_int_array.zig").PackedIntArray;
pub const PackedIntArrayEndian = @import("packed_int_array.zig").PackedIntArrayEndian;
pub const PackedIntSlice = @import("packed_int_array.zig").PackedIntSlice;
pub const PackedIntSliceEndian = @import("packed_int_array.zig").PackedIntSliceEndian;
pub const PriorityQueue = @import("priority_queue.zig").PriorityQueue;
pub const PriorityDequeue = @import("priority_dequeue.zig").PriorityDequeue;
pub const Progress = @import("Progress.zig");
pub const SemanticVersion = @import("SemanticVersion.zig");
pub const SinglyLinkedList = @import("linked_list.zig").SinglyLinkedList;
pub const StaticBitSet = bit_set.StaticBitSet;
pub const StringHashMap = hash_map.StringHashMap;
pub const StringHashMapUnmanaged = hash_map.StringHashMapUnmanaged;
pub const StringArrayHashMap = array_hash_map.StringArrayHashMap;
pub const StringArrayHashMapUnmanaged = array_hash_map.StringArrayHashMapUnmanaged;
pub const TailQueue = @import("linked_list.zig").TailQueue;
pub const Target = @import("target.zig").Target;
pub const Thread = @import("Thread.zig");

pub const array_hash_map = @import("array_hash_map.zig");
pub const atomic = @import("atomic.zig");
pub const base64 = @import("base64.zig");
pub const bit_set = @import("bit_set.zig");
pub const build = @import("build.zig");
pub const builtin = @import("builtin.zig");
pub const c = @import("c.zig");
pub const coff = @import("coff.zig");
pub const compress = @import("compress.zig");
pub const crypto = @import("crypto.zig");
pub const cstr = @import("cstr.zig");
pub const debug = @import("debug.zig");
pub const dwarf = @import("dwarf.zig");
pub const elf = @import("elf.zig");
pub const enums = @import("enums.zig");
pub const event = @import("event.zig");
pub const fifo = @import("fifo.zig");
pub const fmt = @import("fmt.zig");
pub const fs = @import("fs.zig");
pub const hash = @import("hash.zig");
pub const hash_map = @import("hash_map.zig");
pub const heap = @import("heap.zig");
pub const io = @import("io.zig");
pub const json = @import("json.zig");
pub const leb = @import("leb128.zig");
pub const log = @import("log.zig");
pub const macho = @import("macho.zig");
pub const math = @import("math.zig");
pub const mem = @import("mem.zig");
pub const meta = @import("meta.zig");
pub const net = @import("net.zig");
pub const os = @import("os.zig");
pub const once = @import("once.zig").once;
pub const packed_int_array = @import("packed_int_array.zig");
pub const pdb = @import("pdb.zig");
pub const process = @import("process.zig");
pub const rand = @import("rand.zig");
pub const sort = @import("sort.zig");
pub const ascii = @import("ascii.zig");
pub const testing = @import("testing.zig");
pub const time = @import("time.zig");
pub const unicode = @import("unicode.zig");
pub const valgrind = @import("valgrind.zig");
pub const wasm = @import("wasm.zig");
pub const x = @import("x.zig");
pub const zig = @import("zig.zig");
pub const start = @import("start.zig");

// This forces the start.zig file to be imported, and the comptime logic inside that
// file decides whether to export any appropriate start symbols, and call main.
comptime {
    _ = start;
}

test {
    if (builtin.os.tag == .windows) {
        // We only test the Windows-relevant stuff to save memory because the CI
        // server is hitting OOM. TODO revert this after stage2 arrives.
        _ = ChildProcess;
        _ = DynLib;
        _ = Progress;
        _ = Target;
        _ = Thread;

        _ = atomic;
        _ = build;
        _ = builtin;
        _ = debug;
        _ = event;
        _ = fs;
        _ = heap;
        _ = io;
        _ = log;
        _ = macho;
        _ = net;
        _ = os;
        _ = once;
        _ = pdb;
        _ = process;
        _ = testing;
        _ = time;
        _ = unicode;
        _ = zig;
        _ = start;
    } else {
        testing.refAllDecls(@This());
    }
}
