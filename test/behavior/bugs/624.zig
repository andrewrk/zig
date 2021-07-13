const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const TestContext = struct {
    server_context: *ListenerContext,
};

const ListenerContext = struct {
    context_alloc: *ContextAllocator,
};

const ContextAllocator = MemoryPool(TestContext);

fn MemoryPool(comptime T: type) type {
    _ = T;
    return struct {
        n: usize,
    };
}

test "foo" {
    var allocator = ContextAllocator{ .n = 10 };
    try expectEqual(allocator.n, 10);
}
