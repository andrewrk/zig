const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

fn ShardedTable(comptime Key: type, comptime mask_bit_count: comptime_int, comptime V: type) type {
    const key_bits = @typeInfo(Key).Int.bits;
    std.debug.assert(Key == std.meta.Int(.unsigned, key_bits));
    std.debug.assert(key_bits >= mask_bit_count);
    const shard_key_bits = mask_bit_count;
    const ShardKey = std.meta.Int(.unsigned, mask_bit_count);
    const shift_amount = key_bits - shard_key_bits;
    return struct {
        const Self = @This();
        shards: [1 << shard_key_bits]?*Node,

        pub fn create() Self {
            return Self{ .shards = [_]?*Node{null} ** (1 << shard_key_bits) };
        }

        fn getShardKey(key: Key) ShardKey {
            // https://github.com/ziglang/zig/issues/1544
            // this special case is needed because you can't u32 >> 32.
            if (ShardKey == u0) return 0;

            // this can be u1 >> u0
            const shard_key = key >> shift_amount;

            // TODO: https://github.com/ziglang/zig/issues/1544
            // This cast could be implicit if we teach the compiler that
            // u32 >> 30 -> u2
            return @intCast(ShardKey, shard_key);
        }

        pub fn put(self: *Self, node: *Node) void {
            const shard_key = Self.getShardKey(node.key);
            node.next = self.shards[shard_key];
            self.shards[shard_key] = node;
        }

        pub fn get(self: *Self, key: Key) ?*Node {
            const shard_key = Self.getShardKey(key);
            var maybe_node = self.shards[shard_key];
            while (maybe_node) |node| : (maybe_node = node.next) {
                if (node.key == key) return node;
            }
            return null;
        }

        pub const Node = struct {
            key: Key,
            value: V,
            next: ?*Node,

            pub fn init(self: *Node, key: Key, value: V) void {
                self.key = key;
                self.value = value;
                self.next = null;
            }
        };
    };
}

test "sharded table" {
    // realistic 16-way sharding
    try testShardedTable(u32, 4, 8);

    try testShardedTable(u5, 0, 32); // ShardKey == u0
    try testShardedTable(u5, 2, 32);
    try testShardedTable(u5, 5, 32);

    try testShardedTable(u1, 0, 2);
    try testShardedTable(u1, 1, 2); // this does u1 >> u0

    try testShardedTable(u0, 0, 1);
}
fn testShardedTable(comptime Key: type, comptime mask_bit_count: comptime_int, comptime node_count: comptime_int) !void {
    const Table = ShardedTable(Key, mask_bit_count, void);

    var table = Table.create();
    var node_buffer: [node_count]Table.Node = undefined;
    for (node_buffer) |*node, i| {
        const key = @intCast(Key, i);
        try expectEqual(table.get(key), null);
        node.init(key, {});
        table.put(node);
    }

    for (node_buffer) |*node, i| {
        try expectEqual(table.get(@intCast(Key, i)), node);
    }
}

// #2225
test "comptime shr of BigInt" {
    comptime {
        var n0 = 0xdeadbeef0000000000000000;
        try expectEqual(n0 >> 64, 0xdeadbeef);
        var n1 = 17908056155735594659;
        try expectEqual(n1 >> 64, 0);
    }
}

test "comptime shift safety check" {
    _ = @as(usize, 42) << @sizeOf(usize);
}
