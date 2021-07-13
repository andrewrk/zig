const expect = @import("std").testing.expect;
const expectEqual = @import("std").testing.expectEqual;

const ptr = &global;
var global: u64 = 123;

test "constant pointer to global variable causes runtime load" {
    global = 1234;
    try expectEqual(&global, ptr);
    try expectEqual(ptr.*, 1234);
}
