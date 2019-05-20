const std = @import("../std.zig");
const mem = std.mem;
const Allocator = mem.Allocator;
const AnyAllocator = mem.AnyAllocator;

/// Allocator that fails after N allocations, useful for making sure out of
/// memory conditions are handled correctly.
pub const FailingAllocator = struct {
    index: usize,
    fail_index: usize,
    internal_allocator: AnyAllocator,
    allocated_bytes: usize,
    freed_bytes: usize,
    allocations: usize,
    deallocations: usize,

    pub const ReallocError = error{OutOfMemory};

    pub fn init(internal_allocator: var, fail_index: usize) FailingAllocator {
        return FailingAllocator{
            .internal_allocator = internal_allocator.toAny(),
            .fail_index = fail_index,
            .index = 0,
            .allocated_bytes = 0,
            .freed_bytes = 0,
            .allocations = 0,
            .deallocations = 0,
        };
    }

    fn realloc(self: *FailingAllocator, old_mem: []u8, old_align: u29, new_size: usize, new_align: u29) ![]u8 {
        if (self.index == self.fail_index) {
            return error.OutOfMemory;
        }
        const result = try self.internal_allocator.reallocFn(
            self.internal_allocator.impl,
            old_mem,
            old_align,
            new_size,
            new_align,
        );
        if (new_size < old_mem.len) {
            self.freed_bytes += old_mem.len - new_size;
            if (new_size == 0)
                self.deallocations += 1;
        } else if (new_size > old_mem.len) {
            self.allocated_bytes += new_size - old_mem.len;
            if (old_mem.len == 0)
                self.allocations += 1;
        }
        self.index += 1;
        return result;
    }

    fn shrink(self: *FailingAllocator, old_mem: []u8, old_align: u29, new_size: usize, new_align: u29) []u8 {
        const r = self.internal_allocator.shrinkFn(self.internal_allocator.impl, old_mem, old_align, new_size, new_align);
        self.freed_bytes += old_mem.len - r.len;
        if (new_size == 0)
            self.deallocations += 1;
        return r;
    }
    
    pub const AllocatorImpl = Allocator(*FailingAllocator, @typeOf(realloc), @typeOf(shrink));
    pub fn allocator(self: *FailingAllocator) AllocatorImpl {
        return AllocatorImpl {
            .impl = self,
            .reallocFn = realloc,
            .shrinkFn = shrink,
            
            //These are only necessary until after the async rewrite #2377
            .asyncReallocFn = {},
            .asyncShrinkFn = {},
        };
    }
};
