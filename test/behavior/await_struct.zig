const std = @import("std");
const builtin = @import("builtin");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const Foo = struct {
    x: i32,
};

var await_a_promise: anyframe = undefined;
var await_final_result = Foo{ .x = 0 };

test "coroutine await struct" {
    await_seq('a');
    var p = async await_amain();
    _ = p;
    await_seq('f');
    resume await_a_promise;
    await_seq('i');
    try expectEqual(await_final_result.x, 1234);
    try expect(std.mem.eql(u8, &await_points, "abcdefghi"));
}
fn await_amain() callconv(.Async) void {
    await_seq('b');
    var p = async await_another();
    await_seq('e');
    await_final_result = await p;
    await_seq('h');
}
fn await_another() callconv(.Async) Foo {
    await_seq('c');
    suspend {
        await_seq('d');
        await_a_promise = @frame();
    }
    await_seq('g');
    return Foo{ .x = 1234 };
}

var await_points = [_]u8{0} ** "abcdefghi".len;
var await_seq_index: usize = 0;

fn await_seq(c: u8) void {
    await_points[await_seq_index] = c;
    await_seq_index += 1;
}
