// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.
const std = @import("../std.zig");
const builtin = std.builtin;
const math = std.math;
const assert = std.debug.assert;
const mem = std.mem;
const testing = std.testing;

pub fn Reader(
    comptime Context: type,
    comptime ReadError: type,
    /// Returns the number of bytes read. It may be less than buffer.len.
    /// If the number of bytes read is 0, it means end of stream.
    /// End of stream is not an error condition.
    comptime readFn: fn (context: Context, buffer: []u8) ReadError!usize,
) type {
    return struct {
        pub const Error = ReadError;

        context: Context,

        const Self = @This();

        /// Returns the number of bytes read. It may be less than buffer.len.
        /// If the number of bytes read is 0, it means end of stream.
        /// End of stream is not an error condition.
        pub fn read(self: Self, buffer: []u8) Error!usize {
            return readFn(self.context, buffer);
        }

        /// Returns the number of bytes read. If the number read is smaller than `buffer.len`, it
        /// means the stream reached the end. Reaching the end of a stream is not an error
        /// condition.
        pub fn readAll(self: Self, buffer: []u8) Error!usize {
            var index: usize = 0;
            while (index != buffer.len) {
                const amt = try self.read(buffer[index..]);
                if (amt == 0) return index;
                index += amt;
            }
            return index;
        }

        /// If the number read would be smaller than `buf.len`, `error.EndOfStream` is returned instead.
        pub fn readNoEof(self: Self, buf: []u8) !void {
            const amt_read = try self.readAll(buf);
            if (amt_read < buf.len) return error.EndOfStream;
        }

        pub const readAllBuffer = @compileError("deprecated; use readAllArrayList()");

        /// Appends to the `std.ArrayList` contents by reading from the stream until end of stream is found.
        /// If the number of bytes appended would exceed `max_append_size`, `error.StreamTooLong` is returned
        /// and the `std.ArrayList` has exactly `max_append_size` bytes appended.
        pub fn readAllArrayList(self: Self, array_list: *std.ArrayList(u8), max_append_size: usize) !void {
            return self.readAllArrayListAligned(null, array_list, max_append_size);
        }

        pub fn readAllArrayListAligned(
            self: Self,
            comptime alignment: ?u29,
            array_list: *std.ArrayListAligned(u8, alignment),
            max_append_size: usize,
        ) !void {
            try array_list.ensureCapacity(math.min(max_append_size, 4096));
            const original_len = array_list.items.len;
            var start_index: usize = original_len;
            while (true) {
                array_list.expandToCapacity();
                const dest_slice = array_list.items[start_index..];
                const bytes_read = try self.readAll(dest_slice);
                start_index += bytes_read;

                if (start_index - original_len > max_append_size) {
                    array_list.shrinkAndFree(original_len + max_append_size);
                    return error.StreamTooLong;
                }

                if (bytes_read != dest_slice.len) {
                    array_list.shrinkAndFree(start_index);
                    return;
                }

                // This will trigger ArrayList to expand superlinearly at whatever its growth rate is.
                try array_list.ensureCapacity(start_index + 1);
            }
        }

        /// Allocates enough memory to hold all the contents of the stream. If the allocated
        /// memory would be greater than `max_size`, returns `error.StreamTooLong`.
        /// Caller owns returned memory.
        /// If this function returns an error, the contents from the stream read so far are lost.
        pub fn readAllAlloc(self: Self, allocator: *mem.Allocator, max_size: usize) ![]u8 {
            var array_list = std.ArrayList(u8).init(allocator);
            defer array_list.deinit();
            try self.readAllArrayList(&array_list, max_size);
            return array_list.toOwnedSlice();
        }

        /// Replaces the `std.ArrayList` contents by reading from the stream until `delimiter` is found.
        /// Does not include the delimiter in the result.
        /// If the `std.ArrayList` length would exceed `max_size`, `error.StreamTooLong` is returned and the
        /// `std.ArrayList` is populated with `max_size` bytes from the stream.
        pub fn readUntilDelimiterArrayList(
            self: Self,
            array_list: *std.ArrayList(u8),
            delimiter: u8,
            max_size: usize,
        ) !void {
            array_list.shrinkRetainingCapacity(0);
            while (true) {
                var byte: u8 = try self.readByte();

                if (byte == delimiter) {
                    return;
                }

                if (array_list.items.len == max_size) {
                    return error.StreamTooLong;
                }

                try array_list.append(byte);
            }
        }

        /// Allocates enough memory to read until `delimiter`. If the allocated
        /// memory would be greater than `max_size`, returns `error.StreamTooLong`.
        /// Caller owns returned memory.
        /// If this function returns an error, the contents from the stream read so far are lost.
        pub fn readUntilDelimiterAlloc(
            self: Self,
            allocator: *mem.Allocator,
            delimiter: u8,
            max_size: usize,
        ) ![]u8 {
            var array_list = std.ArrayList(u8).init(allocator);
            defer array_list.deinit();
            try self.readUntilDelimiterArrayList(&array_list, delimiter, max_size);
            return array_list.toOwnedSlice();
        }

        /// Reads from the stream until specified byte is found. If the buffer is not
        /// large enough to hold the entire contents, `error.StreamTooLong` is returned.
        /// Returns a slice of the stream data, with ptr equal to `buf.ptr`. The
        /// delimiter byte is not included in the returned slice.
        pub fn readUntilDelimiter(self: Self, buf: []u8, delimiter: u8) ![]u8 {
            var index: usize = 0;
            while (true) {
                const byte = try self.readByte();

                if (byte == delimiter) return buf[0..index];
                if (index >= buf.len) return error.StreamTooLong;

                buf[index] = byte;
                index += 1;
            }
        }

        /// Allocates enough memory to read until `delimiter` or end-of-stream.
        /// If the allocated memory would be greater than `max_size`, returns
        /// `error.StreamTooLong`. If end-of-stream is found, returns the rest
        /// of the stream. If this function is called again after that, returns
        /// null.
        /// Caller owns returned memory.
        /// If this function returns an error, the contents from the stream read so far are lost.
        pub fn readUntilDelimiterOrEofAlloc(
            self: Self,
            allocator: *mem.Allocator,
            delimiter: u8,
            max_size: usize,
        ) !?[]u8 {
            var array_list = std.ArrayList(u8).init(allocator);
            defer array_list.deinit();
            self.readUntilDelimiterArrayList(&array_list, delimiter, max_size) catch |err| switch (err) {
                error.EndOfStream => if (array_list.items.len == 0) {
                    return null;
                } else {
                    return array_list.toOwnedSlice();
                },
                else => |e| return e,
            };
            return array_list.toOwnedSlice();
        }

        /// Reads from the stream until specified byte is found. If the buffer is not
        /// large enough to hold the entire contents, `error.StreamTooLong` is returned.
        /// If end-of-stream is found, returns the rest of the stream. If this
        /// function is called again after that, returns null.
        /// Returns a slice of the stream data, with ptr equal to `buf.ptr`. The
        /// delimiter byte is not included in the returned slice.
        pub fn readUntilDelimiterOrEof(self: Self, buf: []u8, delimiter: u8) !?[]u8 {
            var index: usize = 0;
            while (true) {
                const byte = self.readByte() catch |err| switch (err) {
                    error.EndOfStream => {
                        if (index == 0) {
                            return null;
                        } else {
                            return buf[0..index];
                        }
                    },
                    else => |e| return e,
                };

                if (byte == delimiter) return buf[0..index];
                if (index >= buf.len) return error.StreamTooLong;

                buf[index] = byte;
                index += 1;
            }
        }

        /// Reads from the stream until specified byte is found, discarding all data,
        /// including the delimiter.
        /// If end-of-stream is found, this function succeeds.
        pub fn skipUntilDelimiterOrEof(self: Self, delimiter: u8) !void {
            while (true) {
                const byte = self.readByte() catch |err| switch (err) {
                    error.EndOfStream => return,
                    else => |e| return e,
                };
                if (byte == delimiter) return;
            }
        }

        /// Reads 1 byte from the stream or returns `error.EndOfStream`.
        pub fn readByte(self: Self) !u8 {
            var result: [1]u8 = undefined;
            const amt_read = try self.read(result[0..]);
            if (amt_read < 1) return error.EndOfStream;
            return result[0];
        }

        /// Same as `readByte` except the returned byte is signed.
        pub fn readByteSigned(self: Self) !i8 {
            return @bitCast(i8, try self.readByte());
        }

        /// Reads exactly `num_bytes` bytes and returns as an array.
        /// `num_bytes` must be comptime-known
        pub fn readBytesNoEof(self: Self, comptime num_bytes: usize) ![num_bytes]u8 {
            var bytes: [num_bytes]u8 = undefined;
            try self.readNoEof(&bytes);
            return bytes;
        }

        /// Reads a native-endian integer
        pub fn readIntNative(self: Self, comptime T: type) !T {
            const bytes = try self.readBytesNoEof((@typeInfo(T).Int.bits + 7) / 8);
            return mem.readIntNative(T, &bytes);
        }

        /// Reads a foreign-endian integer
        pub fn readIntForeign(self: Self, comptime T: type) !T {
            const bytes = try self.readBytesNoEof((@typeInfo(T).Int.bits + 7) / 8);
            return mem.readIntForeign(T, &bytes);
        }

        pub fn readIntLittle(self: Self, comptime T: type) !T {
            const bytes = try self.readBytesNoEof((@typeInfo(T).Int.bits + 7) / 8);
            return mem.readIntLittle(T, &bytes);
        }

        pub fn readIntBig(self: Self, comptime T: type) !T {
            const bytes = try self.readBytesNoEof((@typeInfo(T).Int.bits + 7) / 8);
            return mem.readIntBig(T, &bytes);
        }

        pub fn readInt(self: Self, comptime T: type, endian: builtin.Endian) !T {
            const bytes = try self.readBytesNoEof((@typeInfo(T).Int.bits + 7) / 8);
            return mem.readInt(T, &bytes, endian);
        }

        pub fn readVarInt(self: Self, comptime ReturnType: type, endian: builtin.Endian, size: usize) !ReturnType {
            assert(size <= @sizeOf(ReturnType));
            var bytes_buf: [@sizeOf(ReturnType)]u8 = undefined;
            const bytes = bytes_buf[0..size];
            try self.readNoEof(bytes);
            return mem.readVarInt(ReturnType, bytes, endian);
        }

        /// Optional parameters for `skipBytes`
        pub const SkipBytesOptions = struct {
            buf_size: usize = 512,
        };

        // `num_bytes` is a `u64` to match `off_t`
        /// Reads `num_bytes` bytes from the stream and discards them
        pub fn skipBytes(self: Self, num_bytes: u64, comptime options: SkipBytesOptions) !void {
            var buf: [options.buf_size]u8 = undefined;
            var remaining = num_bytes;

            while (remaining > 0) {
                const amt = std.math.min(remaining, options.buf_size);
                try self.readNoEof(buf[0..amt]);
                remaining -= amt;
            }
        }

        /// Reads `slice.len` bytes from the stream and returns if they are the same as the passed slice
        pub fn isBytes(self: Self, slice: []const u8) !bool {
            var i: usize = 0;
            var matches = true;
            while (i < slice.len) : (i += 1) {
                if (slice[i] != try self.readByte()) {
                    matches = false;
                }
            }
            return matches;
        }

        pub fn readStruct(self: Self, comptime T: type) !T {
            // Only extern and packed structs have defined in-memory layout.
            comptime assert(@typeInfo(T).Struct.layout != builtin.TypeInfo.ContainerLayout.Auto);
            var res: [1]T = undefined;
            try self.readNoEof(mem.sliceAsBytes(res[0..]));
            return res[0];
        }

        /// Reads an integer with the same size as the given enum's tag type. If the integer matches
        /// an enum tag, casts the integer to the enum tag and returns it. Otherwise, returns an error.
        /// TODO optimization taking advantage of most fields being in order
        pub fn readEnum(self: Self, comptime Enum: type, endian: builtin.Endian) !Enum {
            const E = error{
                /// An integer was read, but it did not match any of the tags in the supplied enum.
                InvalidValue,
            };
            const type_info = @typeInfo(Enum).Enum;
            const tag = try self.readInt(type_info.tag_type, endian);

            inline for (std.meta.fields(Enum)) |field| {
                if (tag == field.value) {
                    return @field(Enum, field.name);
                }
            }

            return E.InvalidValue;
        }
    };
}

test "Reader" {
    var buf = "a\x02".*;
    const reader = std.io.fixedBufferStream(&buf).reader();
    try testing.expect((try reader.readByte()) == 'a');
    try testing.expect((try reader.readEnum(enum(u8) {
        a = 0,
        b = 99,
        c = 2,
        d = 3,
    }, undefined)) == .c);
    try testing.expectError(error.EndOfStream, reader.readByte());
}

test "Reader.isBytes" {
    const reader = std.io.fixedBufferStream("foobar").reader();
    try testing.expectEqual(true, try reader.isBytes("foo"));
    try testing.expectEqual(false, try reader.isBytes("qux"));
}

test "Reader.skipBytes" {
    const reader = std.io.fixedBufferStream("foobar").reader();
    try reader.skipBytes(3, .{});
    try testing.expect(try reader.isBytes("bar"));
    try reader.skipBytes(0, .{});
    try testing.expectError(error.EndOfStream, reader.skipBytes(1, .{}));
}
