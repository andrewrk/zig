// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.
const std = @import("std.zig");
const math = std.math;
const print = std.debug.print;

pub const FailingAllocator = @import("testing/failing_allocator.zig").FailingAllocator;

/// This should only be used in temporary test programs.
pub const allocator = &allocator_instance.allocator;
pub var allocator_instance = std.heap.GeneralPurposeAllocator(.{}){};

pub const failing_allocator = &failing_allocator_instance.allocator;
pub var failing_allocator_instance = FailingAllocator.init(&base_allocator_instance.allocator, 0);

pub var base_allocator_instance = std.heap.FixedBufferAllocator.init("");

pub var log_level = std.log.Level.warn;

/// This can be set by a user inside a test by calling `std.testing.setupLogTests()`.
/// This will be used in `test_runner.zig` to test logs & track how many matching logs have been seen
/// during a test.
pub var log_test_settings = LogTestSettings{};

/// This is available to any test that wants to execute Zig in a child process.
/// It will be the same executable that is running `zig test`.
pub var zig_exe_path: []const u8 = undefined;

/// This function is intended to be used only in tests. It prints diagnostics to stderr
/// and then aborts when actual_error_union is not expected_error.
pub fn expectError(expected_error: anyerror, actual_error_union: anytype) !void {
    if (actual_error_union) |actual_payload| {
        std.debug.print("expected error.{s}, found {any}\n", .{ @errorName(expected_error), actual_payload });
        return error.TestUnexpectedError;
    } else |actual_error| {
        if (expected_error != actual_error) {
            std.debug.print("expected error.{s}, found error.{s}\n", .{
                @errorName(expected_error),
                @errorName(actual_error),
            });
            return error.TestExpectedError;
        }
    }
}

/// This function is intended to be used only in tests. When the two values are not
/// equal, prints diagnostics to stderr to show exactly how they are not equal,
/// then aborts.
/// `actual` is casted to the type of `expected`.
pub fn expectEqual(expected: anytype, actual: @TypeOf(expected)) !void {
    switch (@typeInfo(@TypeOf(actual))) {
        .NoReturn,
        .BoundFn,
        .Opaque,
        .Frame,
        .AnyFrame,
        => @compileError("value of type " ++ @typeName(@TypeOf(actual)) ++ " encountered"),

        .Undefined,
        .Null,
        .Void,
        => return,

        .Type => {
            if (actual != expected) {
                std.debug.print("expected type {s}, found type {s}\n", .{ @typeName(expected), @typeName(actual) });
                return error.TestExpectedEqual;
            }
        },

        .Bool,
        .Int,
        .Float,
        .ComptimeFloat,
        .ComptimeInt,
        .EnumLiteral,
        .Enum,
        .Fn,
        .ErrorSet,
        => {
            if (actual != expected) {
                std.debug.print("expected {}, found {}\n", .{ expected, actual });
                return error.TestExpectedEqual;
            }
        },

        .Pointer => |pointer| {
            switch (pointer.size) {
                .One, .Many, .C => {
                    if (actual != expected) {
                        std.debug.print("expected {*}, found {*}\n", .{ expected, actual });
                        return error.TestExpectedEqual;
                    }
                },
                .Slice => {
                    if (actual.ptr != expected.ptr) {
                        std.debug.print("expected slice ptr {*}, found {*}\n", .{ expected.ptr, actual.ptr });
                        return error.TestExpectedEqual;
                    }
                    if (actual.len != expected.len) {
                        std.debug.print("expected slice len {}, found {}\n", .{ expected.len, actual.len });
                        return error.TestExpectedEqual;
                    }
                },
            }
        },

        .Array => |array| try expectEqualSlices(array.child, &expected, &actual),

        .Vector => |vectorType| {
            var i: usize = 0;
            while (i < vectorType.len) : (i += 1) {
                if (!std.meta.eql(expected[i], actual[i])) {
                    std.debug.print("index {} incorrect. expected {}, found {}\n", .{ i, expected[i], actual[i] });
                    return error.TestExpectedEqual;
                }
            }
        },

        .Struct => |structType| {
            inline for (structType.fields) |field| {
                try expectEqual(@field(expected, field.name), @field(actual, field.name));
            }
        },

        .Union => |union_info| {
            if (union_info.tag_type == null) {
                @compileError("Unable to compare untagged union values");
            }

            const Tag = std.meta.Tag(@TypeOf(expected));

            const expectedTag = @as(Tag, expected);
            const actualTag = @as(Tag, actual);

            try expectEqual(expectedTag, actualTag);

            // we only reach this loop if the tags are equal
            inline for (std.meta.fields(@TypeOf(actual))) |fld| {
                if (std.mem.eql(u8, fld.name, @tagName(actualTag))) {
                    try expectEqual(@field(expected, fld.name), @field(actual, fld.name));
                    return;
                }
            }

            // we iterate over *all* union fields
            // => we should never get here as the loop above is
            //    including all possible values.
            unreachable;
        },

        .Optional => {
            if (expected) |expected_payload| {
                if (actual) |actual_payload| {
                    try expectEqual(expected_payload, actual_payload);
                } else {
                    std.debug.print("expected {any}, found null\n", .{expected_payload});
                    return error.TestExpectedEqual;
                }
            } else {
                if (actual) |actual_payload| {
                    std.debug.print("expected null, found {any}\n", .{actual_payload});
                    return error.TestExpectedEqual;
                }
            }
        },

        .ErrorUnion => {
            if (expected) |expected_payload| {
                if (actual) |actual_payload| {
                    try expectEqual(expected_payload, actual_payload);
                } else |actual_err| {
                    std.debug.print("expected {any}, found {}\n", .{ expected_payload, actual_err });
                    return error.TestExpectedEqual;
                }
            } else |expected_err| {
                if (actual) |actual_payload| {
                    std.debug.print("expected {}, found {any}\n", .{ expected_err, actual_payload });
                    return error.TestExpectedEqual;
                } else |actual_err| {
                    try expectEqual(expected_err, actual_err);
                }
            }
        },
    }
}

test "expectEqual.union(enum)" {
    const T = union(enum) {
        a: i32,
        b: f32,
    };

    const a10 = T{ .a = 10 };

    try expectEqual(a10, a10);
}

/// This function is intended to be used only in tests. When the formatted result of the template
/// and its arguments does not equal the expected text, it prints diagnostics to stderr to show how
/// they are not equal, then returns an error.
pub fn expectFmt(expected: []const u8, comptime template: []const u8, args: anytype) !void {
    const result = try std.fmt.allocPrint(allocator, template, args);
    defer allocator.free(result);
    if (std.mem.eql(u8, result, expected)) return;

    print("\n====== expected this output: =========\n", .{});
    print("{s}", .{expected});
    print("\n======== instead found this: =========\n", .{});
    print("{s}", .{result});
    print("\n======================================\n", .{});
    return error.TestExpectedFmt;
}

pub const expectWithinMargin = @compileError("expectWithinMargin is deprecated, use expectApproxEqAbs or expectApproxEqRel");
pub const expectWithinEpsilon = @compileError("expectWithinEpsilon is deprecated, use expectApproxEqAbs or expectApproxEqRel");

/// This function is intended to be used only in tests. When the actual value is
/// not approximately equal to the expected value, prints diagnostics to stderr
/// to show exactly how they are not equal, then aborts.
/// See `math.approxEqAbs` for more informations on the tolerance parameter.
/// The types must be floating point
pub fn expectApproxEqAbs(expected: anytype, actual: @TypeOf(expected), tolerance: @TypeOf(expected)) !void {
    const T = @TypeOf(expected);

    switch (@typeInfo(T)) {
        .Float => if (!math.approxEqAbs(T, expected, actual, tolerance)) {
            std.debug.print("actual {}, not within absolute tolerance {} of expected {}\n", .{ actual, tolerance, expected });
            return error.TestExpectedApproxEqAbs;
        },

        .ComptimeFloat => @compileError("Cannot approximately compare two comptime_float values"),

        else => @compileError("Unable to compare non floating point values"),
    }
}

test "expectApproxEqAbs" {
    inline for ([_]type{ f16, f32, f64, f128 }) |T| {
        const pos_x: T = 12.0;
        const pos_y: T = 12.06;
        const neg_x: T = -12.0;
        const neg_y: T = -12.06;

        try expectApproxEqAbs(pos_x, pos_y, 0.1);
        try expectApproxEqAbs(neg_x, neg_y, 0.1);
    }
}

/// This function is intended to be used only in tests. When the actual value is
/// not approximately equal to the expected value, prints diagnostics to stderr
/// to show exactly how they are not equal, then aborts.
/// See `math.approxEqRel` for more informations on the tolerance parameter.
/// The types must be floating point
pub fn expectApproxEqRel(expected: anytype, actual: @TypeOf(expected), tolerance: @TypeOf(expected)) !void {
    const T = @TypeOf(expected);

    switch (@typeInfo(T)) {
        .Float => if (!math.approxEqRel(T, expected, actual, tolerance)) {
            std.debug.print("actual {}, not within relative tolerance {} of expected {}\n", .{ actual, tolerance, expected });
            return error.TestExpectedApproxEqRel;
        },

        .ComptimeFloat => @compileError("Cannot approximately compare two comptime_float values"),

        else => @compileError("Unable to compare non floating point values"),
    }
}

test "expectApproxEqRel" {
    inline for ([_]type{ f16, f32, f64, f128 }) |T| {
        const eps_value = comptime math.epsilon(T);
        const sqrt_eps_value = comptime math.sqrt(eps_value);

        const pos_x: T = 12.0;
        const pos_y: T = pos_x + 2 * eps_value;
        const neg_x: T = -12.0;
        const neg_y: T = neg_x - 2 * eps_value;

        try expectApproxEqRel(pos_x, pos_y, sqrt_eps_value);
        try expectApproxEqRel(neg_x, neg_y, sqrt_eps_value);
    }
}

/// This function is intended to be used only in tests. When the two slices are not
/// equal, prints diagnostics to stderr to show exactly how they are not equal,
/// then aborts.
/// If your inputs are UTF-8 encoded strings, consider calling `expectEqualStrings` instead.
pub fn expectEqualSlices(comptime T: type, expected: []const T, actual: []const T) !void {
    // TODO better printing of the difference
    // If the arrays are small enough we could print the whole thing
    // If the child type is u8 and no weird bytes, we could print it as strings
    // Even for the length difference, it would be useful to see the values of the slices probably.
    if (expected.len != actual.len) {
        std.debug.print("slice lengths differ. expected {d}, found {d}\n", .{ expected.len, actual.len });
        return error.TestExpectedEqual;
    }
    var i: usize = 0;
    while (i < expected.len) : (i += 1) {
        if (!std.meta.eql(expected[i], actual[i])) {
            std.debug.print("index {} incorrect. expected {any}, found {any}\n", .{ i, expected[i], actual[i] });
            return error.TestExpectedEqual;
        }
    }
}

/// This function is intended to be used only in tests. When `ok` is false, the test fails.
/// A message is printed to stderr and then abort is called.
pub fn expect(ok: bool) !void {
    if (!ok) return error.TestUnexpectedResult;
}

pub const TmpDir = struct {
    dir: std.fs.Dir,
    parent_dir: std.fs.Dir,
    sub_path: [sub_path_len]u8,

    const random_bytes_count = 12;
    const sub_path_len = std.fs.base64_encoder.calcSize(random_bytes_count);

    pub fn cleanup(self: *TmpDir) void {
        self.dir.close();
        self.parent_dir.deleteTree(&self.sub_path) catch {};
        self.parent_dir.close();
        self.* = undefined;
    }
};

fn getCwdOrWasiPreopen() std.fs.Dir {
    if (std.builtin.os.tag == .wasi) {
        var preopens = std.fs.wasi.PreopenList.init(allocator);
        defer preopens.deinit();
        preopens.populate() catch
            @panic("unable to make tmp dir for testing: unable to populate preopens");
        const preopen = preopens.find(std.fs.wasi.PreopenType{ .Dir = "." }) orelse
            @panic("unable to make tmp dir for testing: didn't find '.' in the preopens");

        return std.fs.Dir{ .fd = preopen.fd };
    } else {
        return std.fs.cwd();
    }
}

pub fn tmpDir(opts: std.fs.Dir.OpenDirOptions) TmpDir {
    var random_bytes: [TmpDir.random_bytes_count]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);
    var sub_path: [TmpDir.sub_path_len]u8 = undefined;
    _ = std.fs.base64_encoder.encode(&sub_path, &random_bytes);

    var cwd = getCwdOrWasiPreopen();
    var cache_dir = cwd.makeOpenPath("zig-cache", .{}) catch
        @panic("unable to make tmp dir for testing: unable to make and open zig-cache dir");
    defer cache_dir.close();
    var parent_dir = cache_dir.makeOpenPath("tmp", .{}) catch
        @panic("unable to make tmp dir for testing: unable to make and open zig-cache/tmp dir");
    var dir = parent_dir.makeOpenPath(&sub_path, opts) catch
        @panic("unable to make tmp dir for testing: unable to make and open the tmp dir");

    return .{
        .dir = dir,
        .parent_dir = parent_dir,
        .sub_path = sub_path,
    };
}

test "expectEqual nested array" {
    const a = [2][2]f32{
        [_]f32{ 1.0, 0.0 },
        [_]f32{ 0.0, 1.0 },
    };

    const b = [2][2]f32{
        [_]f32{ 1.0, 0.0 },
        [_]f32{ 0.0, 1.0 },
    };

    try expectEqual(a, b);
}

test "expectEqual vector" {
    var a = @splat(4, @as(u32, 4));
    var b = @splat(4, @as(u32, 4));

    try expectEqual(a, b);
}

pub fn expectEqualStrings(expected: []const u8, actual: []const u8) !void {
    if (std.mem.indexOfDiff(u8, actual, expected)) |diff_index| {
        print("\n====== expected this output: =========\n", .{});
        printWithVisibleNewlines(expected);
        print("\n======== instead found this: =========\n", .{});
        printWithVisibleNewlines(actual);
        print("\n======================================\n", .{});

        var diff_line_number: usize = 1;
        for (expected[0..diff_index]) |value| {
            if (value == '\n') diff_line_number += 1;
        }
        print("First difference occurs on line {d}:\n", .{diff_line_number});

        print("expected:\n", .{});
        printIndicatorLine(expected, diff_index);

        print("found:\n", .{});
        printIndicatorLine(actual, diff_index);

        return error.TestExpectedEqual;
    }
}

pub fn expectStringEndsWith(actual: []const u8, expected_ends_with: []const u8) !void {
    if (std.mem.endsWith(u8, actual, expected_ends_with))
        return;

    const shortened_actual = if (actual.len >= expected_ends_with.len)
        actual[0..expected_ends_with.len]
    else
        actual;

    print("\n====== expected to end with: =========\n", .{});
    printWithVisibleNewlines(expected_ends_with);
    print("\n====== instead ended with: ===========\n", .{});
    printWithVisibleNewlines(shortened_actual);
    print("\n========= full output: ==============\n", .{});
    printWithVisibleNewlines(actual);
    print("\n======================================\n", .{});

    return error.TestExpectedEndsWith;
}

/// Define rules for log statements that should be tracked by the test runner.
/// Each time a log is written during a test, the test runner will check if it should be
/// counted. At the end of the test, `std.testing.expectLogCounts()` can be used to test
/// if the expected number of logs were recorded.
///
/// The available rules are:
/// * .scope - Match all logs with the given scope (must set this using `@tagName(.scope)`)
/// * .exact_level - Match all logs with the given level
/// * .min_level - Match all logs at *at least* the given level
/// * .text - Match all logs which print this exact message
/// * .prefix - Match all logs which print a message that starts with this prefix
pub fn setupLogTests(log_settings: LogTestSettings) void {
    log_test_settings = log_settings;
}

/// Pass the expected number of logs for each rule that was set with `std.testing.setupLogTests()`. 
pub fn expectLogCounts(counts: LogTestSettings.LogCounts) !void {
    const count_fields = std.meta.fields(LogTestSettings.LogCounts);
    inline for (count_fields) |field| {
        const expected = @field(counts, field.name);
        const actual = @field(log_test_settings.seen, field.name);

        if (actual != expected) {
            print("[Log Test] For rule {s}: Expected: {}, Actual: {}\n", .{ field.name, expected, actual });
            return error.TestExpectedLogs;
        }
    }
}

test "watch logs by scope" {
    std.testing.setupLogTests(.{ 
        .scope = @tagName(.a), 
        .exact_level = .debug, 
    });
    
    const scope_a = std.log.scoped(.a);
    const scope_b = std.log.scoped(.b);

    scope_a.debug("Count scope and level", .{});
    scope_b.debug("Count level", .{});
    scope_a.debug("Count scope and level", .{});
    scope_a.warn("Count scope", .{});

    try std.testing.expectLogCounts(.{
        .scope = 3,
        .exact_level = 3,
    });
}

test "watch logs for text" {
    std.testing.setupLogTests(.{ .text = "Looking for this text\n" });

    const scope_a = std.log.scoped(.a);

    scope_a.debug("Looking for this text\n", .{});
    scope_a.warn("Looking for {s} text\n", .{"this"});
    scope_a.debug("Not looking for this text\n", .{});

    try std.testing.expectLogCounts(.{
        .text = 2
    });
}

test "ignore logs scoped by 'testing'" {
    std.testing.setupLogTests(.{ .exact_level = .debug });

    const scope_a = std.log.scoped(.a);

    scope_a.debug("Should match this\n", .{});
    std.log.testing.debug("Should not match this\n", .{});

    try std.testing.expectLogCounts(.{
        .exact_level = 1
    });
}

test "0 logs recorded by default" {
    const scope_a = std.log.scoped(.a);
    const scope_b = std.log.scoped(.b);

    scope_a.debug("Count scope and level", .{});
    scope_b.debug("Count level", .{});
    scope_a.debug("Count scope and level", .{});
    scope_a.warn("Count scope", .{});

    scope_a.debug("Looking for this text\n", .{});
    scope_a.warn("Looking for {s} text\n", .{"this"});
    scope_a.debug("Not looking for this text\n", .{});

    scope_a.debug("Should match this\n", .{});
    std.log.testing.debug("Should not match this\n", .{});

    try std.testing.expectLogCounts(.{});
}

test "multiple checks within one test" {
    std.testing.setupLogTests(.{ .exact_level = .debug });

    const scope_a = std.log.scoped(.a);

    scope_a.debug("Should match this\n", .{});
    std.log.testing.debug("Should not match this\n", .{});

    try std.testing.expectLogCounts(.{
        .exact_level = 1
    });

    std.testing.setupLogTests(.{ .text = "Looking for this text\n" });

    scope_a.debug("Looking for this text\n", .{});
    scope_a.warn("Looking for {s} text\n", .{"this"});
    scope_a.debug("Not looking for this text\n", .{});

    try std.testing.expectLogCounts(.{
        .text = 2
    });
}

fn printIndicatorLine(source: []const u8, indicator_index: usize) void {
    const line_begin_index = if (std.mem.lastIndexOfScalar(u8, source[0..indicator_index], '\n')) |line_begin|
        line_begin + 1
    else
        0;
    const line_end_index = if (std.mem.indexOfScalar(u8, source[indicator_index..], '\n')) |line_end|
        (indicator_index + line_end)
    else
        source.len;

    printLine(source[line_begin_index..line_end_index]);
    {
        var i: usize = line_begin_index;
        while (i < indicator_index) : (i += 1)
            print(" ", .{});
    }
    print("^\n", .{});
}

fn printWithVisibleNewlines(source: []const u8) void {
    var i: usize = 0;
    while (std.mem.indexOfScalar(u8, source[i..], '\n')) |nl| : (i += nl + 1) {
        printLine(source[i .. i + nl]);
    }
    print("{s}␃\n", .{source[i..]}); // End of Text symbol (ETX)
}

fn printLine(line: []const u8) void {
    if (line.len != 0) switch (line[line.len - 1]) {
        ' ', '\t' => return print("{s}⏎\n", .{line}), // Carriage return symbol,
        else => {},
    };
    print("{s}\n", .{line});
}

test {
    try expectEqualStrings("foo", "foo");
}

/// Given a type, reference all the declarations inside, so that the semantic analyzer sees them.
pub fn refAllDecls(comptime T: type) void {
    if (!std.builtin.is_test) return;
    inline for (std.meta.declarations(T)) |decl| {
        _ = decl;
    }
}

const LogTestSettings = struct {
    pub const LogCounts = struct {
        // Add a field here if another settings field is added
        scope: usize = 0,
        text: usize = 0,
        prefix: usize = 0,
        exact_level: usize = 0,
        min_level: usize = 0
    };

    scope: ?[]const u8 = null,
    text: ?[]const u8 = null,
    prefix: ?[]const u8 = null,
    exact_level: ?std.log.Level = null,
    min_level: ?std.log.Level = null,

    seen: LogCounts = .{},

    /// Given the log message, increment the `seen` counters for each rule the log matches.
    pub fn countMatches(self: *LogTestSettings, comptime message_level: std.log.Level, comptime scope: @Type(.EnumLiteral), comptime format: []const u8, args: anytype) void {
        if (self.scope) |test_scope| {
            if (std.mem.eql(u8, test_scope, @tagName(scope))) {
                self.seen.scope += 1;
            }
        }

        if (self.text) |test_text| {
            var buf: [format.len * 2]u8 = undefined;
            // If there's an error formatting the message, skip checking it
            if (std.fmt.bufPrint(buf[0..], format, args)) |base_output| {
                if (std.mem.eql(u8, test_text, base_output)) {
                    self.seen.text += 1;
                }
            } else |_| {}
        }

        if (self.prefix) |test_prefix| {
            var buf: [format.len * 2]u8 = undefined;
            // If there's an error formatting the message, skip checking it
            if (std.fmt.bufPrint(buf[0..], format, args)) |base_output| {
                if (std.mem.startsWith(u8, base_output, test_prefix)) {
                    self.seen.prefix += 1;
                }
            } else |_| {}
        }

        if (self.exact_level) |test_exact_level| {            // break :blk @enumToInt(message_level) == @enumToInt(test_exact_level);
            if (@enumToInt(message_level) == @enumToInt(test_exact_level)) {
                self.seen.exact_level += 1;
            }
        }

        if (self.min_level) |test_min_level| {
            if (@enumToInt(message_level) >= @enumToInt(test_min_level)) {
                self.seen.min_level += 1;
            }
        }
    }
};
