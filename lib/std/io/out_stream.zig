const std = @import("../std.zig");
const builtin = @import("builtin");
const root = @import("root");
const mem = std.mem;

pub const default_stack_size = 1 * 1024 * 1024;
pub const stack_size: usize = if (@hasDecl(root, "stack_size_std_io_OutStream"))
    root.stack_size_std_io_OutStream
else
    default_stack_size;

/// TODO this is not integrated with evented I/O yet.
/// https://github.com/ziglang/zig/issues/3557
pub fn OutStream(comptime WriteError: type) type {
    return struct {
        const Self = @This();
        pub const Error = WriteError;
        // TODO https://github.com/ziglang/zig/issues/3557
        pub const WriteFn = if (std.io.is_async and false)
            async fn (self: *Self, bytes: []const u8) Error!void
        else
            fn (self: *Self, bytes: []const u8) Error!void;

        writeFn: WriteFn,

        pub fn write(self: *Self, bytes: []const u8) Error!void {
            // TODO https://github.com/ziglang/zig/issues/3557
            if (std.io.is_async and false) {
                // Let's not be writing 0xaa in safe modes for upwards of 4 MiB for every stream write.
                @setRuntimeSafety(false);
                var stack_frame: [stack_size]u8 align(std.Target.stack_align) = undefined;
                return await @asyncCall(&stack_frame, {}, self.writeFn, self, bytes);
            } else {
                return self.writeFn(self, bytes);
            }
        }

        pub fn print(self: *Self, comptime format: []const u8, args: var) Error!void {
            var generator = std.fmtgen.Generator([]const u8).init();
            _ = async std.fmtgen.format(&generator, format, args);
            while (generator.next()) |bytes| {
                try self.writeFn(self, bytes);
            }
        }

        pub fn writeByte(self: *Self, byte: u8) Error!void {
            const slice = @as(*const [1]u8, &byte)[0..];
            return self.writeFn(self, slice);
        }

        pub fn writeByteNTimes(self: *Self, byte: u8, n: usize) Error!void {
            var bytes: [256]u8 = undefined;
            mem.set(u8, bytes[0..], byte);

            var remaining: usize = n;
            while (remaining > 0) {
                const to_write = std.math.min(remaining, bytes.len);
                try self.writeFn(self, bytes[0..to_write]);
                remaining -= to_write;
            }
        }

        /// Write a native-endian integer.
        pub fn writeIntNative(self: *Self, comptime T: type, value: T) Error!void {
            var bytes: [(T.bit_count + 7) / 8]u8 = undefined;
            mem.writeIntNative(T, &bytes, value);
            return self.writeFn(self, &bytes);
        }

        /// Write a foreign-endian integer.
        pub fn writeIntForeign(self: *Self, comptime T: type, value: T) Error!void {
            var bytes: [(T.bit_count + 7) / 8]u8 = undefined;
            mem.writeIntForeign(T, &bytes, value);
            return self.writeFn(self, &bytes);
        }

        pub fn writeIntLittle(self: *Self, comptime T: type, value: T) Error!void {
            var bytes: [(T.bit_count + 7) / 8]u8 = undefined;
            mem.writeIntLittle(T, &bytes, value);
            return self.writeFn(self, &bytes);
        }

        pub fn writeIntBig(self: *Self, comptime T: type, value: T) Error!void {
            var bytes: [(T.bit_count + 7) / 8]u8 = undefined;
            mem.writeIntBig(T, &bytes, value);
            return self.writeFn(self, &bytes);
        }

        pub fn writeInt(self: *Self, comptime T: type, value: T, endian: builtin.Endian) Error!void {
            var bytes: [(T.bit_count + 7) / 8]u8 = undefined;
            mem.writeInt(T, &bytes, value, endian);
            return self.writeFn(self, &bytes);
        }
    };
}
