// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.
// JSON parser conforming to RFC8259.
//
// https://tools.ietf.org/html/rfc8259

const std = @import("std.zig");
const debug = std.debug;
const assert = debug.assert;
const testing = std.testing;
const mem = std.mem;
const maxInt = std.math.maxInt;

pub const WriteStream = @import("json/write_stream.zig").WriteStream;
pub const writeStream = @import("json/write_stream.zig").writeStream;

const StringEscapes = union(enum) {
    None,

    Some: struct {
        size_diff: isize,
    },
};

/// Checks to see if a string matches what it would be as a json-encoded string
/// Assumes that `encoded` is a well-formed json string
fn encodesTo(decoded: []const u8, encoded: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (i < decoded.len) {
        if (j >= encoded.len) return false;
        if (encoded[j] != '\\') {
            if (decoded[i] != encoded[j]) return false;
            j += 1;
            i += 1;
        } else {
            const escape_type = encoded[j + 1];
            if (escape_type != 'u') {
                const t: u8 = switch (escape_type) {
                    '\\' => '\\',
                    '/' => '/',
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    'f' => 12,
                    'b' => 8,
                    '"' => '"',
                    else => unreachable,
                };
                if (decoded[i] != t) return false;
                j += 2;
                i += 1;
            } else {
                var codepoint = std.fmt.parseInt(u21, encoded[j + 2 .. j + 6], 16) catch unreachable;
                j += 6;
                if (codepoint >= 0xD800 and codepoint < 0xDC00) {
                    // surrogate pair
                    assert(encoded[j] == '\\');
                    assert(encoded[j + 1] == 'u');
                    const low_surrogate = std.fmt.parseInt(u21, encoded[j + 2 .. j + 6], 16) catch unreachable;
                    codepoint = 0x10000 + (((codepoint & 0x03ff) << 10) | (low_surrogate & 0x03ff));
                    j += 6;
                }
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(codepoint, &buf) catch unreachable;
                if (i + len > decoded.len) return false;
                if (!mem.eql(u8, decoded[i .. i + len], buf[0..len])) return false;
                i += len;
            }
        }
    }
    assert(i == decoded.len);
    assert(j == encoded.len);
    return true;
}

test "encodesTo" {
    // same
    try testing.expectEqual(true, encodesTo("false", "false"));
    // totally different
    try testing.expectEqual(false, encodesTo("false", "true"));
    // different lengths
    try testing.expectEqual(false, encodesTo("false", "other"));
    // with escape
    try testing.expectEqual(true, encodesTo("\\", "\\\\"));
    try testing.expectEqual(true, encodesTo("with\nescape", "with\\nescape"));
    // with unicode
    try testing.expectEqual(true, encodesTo("ą", "\\u0105"));
    try testing.expectEqual(true, encodesTo("😂", "\\ud83d\\ude02"));
    try testing.expectEqual(true, encodesTo("withąunicode😂", "with\\u0105unicode\\ud83d\\ude02"));
}

/// A single token slice into the parent string.
///
/// Use `token.slice()` on the input at the current position to get the current slice.
pub const Token = union(enum) {
    ObjectBegin,
    ObjectEnd,
    ArrayBegin,
    ArrayEnd,
    String: struct {
        /// How many bytes the token is.
        count: usize,

        /// Whether string contains an escape sequence and cannot be zero-copied
        escapes: StringEscapes,

        pub fn decodedLength(self: @This()) usize {
            return self.count +% switch (self.escapes) {
                .None => 0,
                .Some => |s| @bitCast(usize, s.size_diff),
            };
        }

        /// Slice into the underlying input string.
        pub fn slice(self: @This(), input: []const u8, i: usize) []const u8 {
            return input[i - self.count .. i];
        }
    },
    Number: struct {
        /// How many bytes the token is.
        count: usize,

        /// Whether number is simple and can be represented by an integer (i.e. no `.` or `e`)
        is_integer: bool,

        /// Slice into the underlying input string.
        pub fn slice(self: @This(), input: []const u8, i: usize) []const u8 {
            return input[i - self.count .. i];
        }
    },
    True,
    False,
    Null,
};

/// A small streaming JSON parser. This accepts input one byte at a time and returns tokens as
/// they are encountered. No copies or allocations are performed during parsing and the entire
/// parsing state requires ~40-50 bytes of stack space.
///
/// Conforms strictly to RFC8259.
///
/// For a non-byte based wrapper, consider using TokenStream instead.
pub const StreamingParser = struct {
    // Current state
    state: State,
    // How many bytes we have counted for the current token
    count: usize,
    // What state to follow after parsing a string (either property or value string)
    after_string_state: State,
    // What state to follow after parsing a value (either top-level or value end)
    after_value_state: State,
    // If we stopped now, would the complete parsed string to now be a valid json string
    complete: bool,
    // Current token flags to pass through to the next generated, see Token.
    string_escapes: StringEscapes,
    // When in .String states, was the previous character a high surrogate?
    string_last_was_high_surrogate: bool,
    // Used inside of StringEscapeHexUnicode* states
    string_unicode_codepoint: u21,
    // The first byte needs to be stored to validate 3- and 4-byte sequences.
    sequence_first_byte: u8 = undefined,
    // When in .Number states, is the number a (still) valid integer?
    number_is_integer: bool,

    // Bit-stack for nested object/map literals (max 255 nestings).
    stack: u256,
    stack_used: u8,

    const object_bit = 0;
    const array_bit = 1;
    const max_stack_size = maxInt(u8);

    pub fn init() StreamingParser {
        var p: StreamingParser = undefined;
        p.reset();
        return p;
    }

    pub fn reset(p: *StreamingParser) void {
        p.state = .TopLevelBegin;
        p.count = 0;
        // Set before ever read in main transition function
        p.after_string_state = undefined;
        p.after_value_state = .ValueEnd; // handle end of values normally
        p.stack = 0;
        p.stack_used = 0;
        p.complete = false;
        p.string_escapes = undefined;
        p.string_last_was_high_surrogate = undefined;
        p.string_unicode_codepoint = undefined;
        p.number_is_integer = undefined;
    }

    pub const State = enum(u8) {
        // These must be first with these explicit values as we rely on them for indexing the
        // bit-stack directly and avoiding a branch.
        ObjectSeparator = 0,
        ValueEnd = 1,

        TopLevelBegin,
        TopLevelEnd,

        ValueBegin,
        ValueBeginNoClosing,

        String,
        StringUtf8Byte2Of2,
        StringUtf8Byte2Of3,
        StringUtf8Byte3Of3,
        StringUtf8Byte2Of4,
        StringUtf8Byte3Of4,
        StringUtf8Byte4Of4,
        StringEscapeCharacter,
        StringEscapeHexUnicode4,
        StringEscapeHexUnicode3,
        StringEscapeHexUnicode2,
        StringEscapeHexUnicode1,

        Number,
        NumberMaybeDotOrExponent,
        NumberMaybeDigitOrDotOrExponent,
        NumberFractionalRequired,
        NumberFractional,
        NumberMaybeExponent,
        NumberExponent,
        NumberExponentDigitsRequired,
        NumberExponentDigits,

        TrueLiteral1,
        TrueLiteral2,
        TrueLiteral3,

        FalseLiteral1,
        FalseLiteral2,
        FalseLiteral3,
        FalseLiteral4,

        NullLiteral1,
        NullLiteral2,
        NullLiteral3,

        // Only call this function to generate array/object final state.
        pub fn fromInt(x: anytype) State {
            debug.assert(x == 0 or x == 1);
            const T = std.meta.Tag(State);
            return @intToEnum(State, @intCast(T, x));
        }
    };

    pub const Error = error{
        InvalidTopLevel,
        TooManyNestedItems,
        TooManyClosingItems,
        InvalidValueBegin,
        InvalidValueEnd,
        UnbalancedBrackets,
        UnbalancedBraces,
        UnexpectedClosingBracket,
        UnexpectedClosingBrace,
        InvalidNumber,
        InvalidSeparator,
        InvalidLiteral,
        InvalidEscapeCharacter,
        InvalidUnicodeHexSymbol,
        InvalidUtf8Byte,
        InvalidTopLevelTrailing,
        InvalidControlCharacter,
    };

    /// Give another byte to the parser and obtain any new tokens. This may (rarely) return two
    /// tokens. token2 is always null if token1 is null.
    ///
    /// There is currently no error recovery on a bad stream.
    pub fn feed(p: *StreamingParser, c: u8, token1: *?Token, token2: *?Token) Error!void {
        token1.* = null;
        token2.* = null;
        p.count += 1;

        // unlikely
        if (try p.transition(c, token1)) {
            _ = try p.transition(c, token2);
        }
    }

    // Perform a single transition on the state machine and return any possible token.
    fn transition(p: *StreamingParser, c: u8, token: *?Token) Error!bool {
        switch (p.state) {
            .TopLevelBegin => switch (c) {
                '{' => {
                    p.stack <<= 1;
                    p.stack |= object_bit;
                    p.stack_used += 1;

                    p.state = .ValueBegin;
                    p.after_string_state = .ObjectSeparator;

                    token.* = Token.ObjectBegin;
                },
                '[' => {
                    p.stack <<= 1;
                    p.stack |= array_bit;
                    p.stack_used += 1;

                    p.state = .ValueBegin;
                    p.after_string_state = .ValueEnd;

                    token.* = Token.ArrayBegin;
                },
                '-' => {
                    p.number_is_integer = true;
                    p.state = .Number;
                    p.after_value_state = .TopLevelEnd;
                    p.count = 0;
                },
                '0' => {
                    p.number_is_integer = true;
                    p.state = .NumberMaybeDotOrExponent;
                    p.after_value_state = .TopLevelEnd;
                    p.count = 0;
                },
                '1'...'9' => {
                    p.number_is_integer = true;
                    p.state = .NumberMaybeDigitOrDotOrExponent;
                    p.after_value_state = .TopLevelEnd;
                    p.count = 0;
                },
                '"' => {
                    p.state = .String;
                    p.after_value_state = .TopLevelEnd;
                    // We don't actually need the following since after_value_state should override.
                    p.after_string_state = .ValueEnd;
                    p.string_escapes = .None;
                    p.string_last_was_high_surrogate = false;
                    p.count = 0;
                },
                't' => {
                    p.state = .TrueLiteral1;
                    p.after_value_state = .TopLevelEnd;
                    p.count = 0;
                },
                'f' => {
                    p.state = .FalseLiteral1;
                    p.after_value_state = .TopLevelEnd;
                    p.count = 0;
                },
                'n' => {
                    p.state = .NullLiteral1;
                    p.after_value_state = .TopLevelEnd;
                    p.count = 0;
                },
                0x09, 0x0A, 0x0D, 0x20 => {
                    // whitespace
                },
                else => {
                    return error.InvalidTopLevel;
                },
            },

            .TopLevelEnd => switch (c) {
                0x09, 0x0A, 0x0D, 0x20 => {
                    // whitespace
                },
                else => {
                    return error.InvalidTopLevelTrailing;
                },
            },

            .ValueBegin => switch (c) {
                // NOTE: These are shared in ValueEnd as well, think we can reorder states to
                // be a bit clearer and avoid this duplication.
                '}' => {
                    // unlikely
                    if (p.stack & 1 != object_bit) {
                        return error.UnexpectedClosingBrace;
                    }
                    if (p.stack_used == 0) {
                        return error.TooManyClosingItems;
                    }

                    p.state = .ValueBegin;
                    p.after_string_state = State.fromInt(p.stack & 1);

                    p.stack >>= 1;
                    p.stack_used -= 1;

                    switch (p.stack_used) {
                        0 => {
                            p.complete = true;
                            p.state = .TopLevelEnd;
                        },
                        else => {
                            p.state = .ValueEnd;
                        },
                    }

                    token.* = Token.ObjectEnd;
                },
                ']' => {
                    if (p.stack & 1 != array_bit) {
                        return error.UnexpectedClosingBracket;
                    }
                    if (p.stack_used == 0) {
                        return error.TooManyClosingItems;
                    }

                    p.state = .ValueBegin;
                    p.after_string_state = State.fromInt(p.stack & 1);

                    p.stack >>= 1;
                    p.stack_used -= 1;

                    switch (p.stack_used) {
                        0 => {
                            p.complete = true;
                            p.state = .TopLevelEnd;
                        },
                        else => {
                            p.state = .ValueEnd;
                        },
                    }

                    token.* = Token.ArrayEnd;
                },
                '{' => {
                    if (p.stack_used == max_stack_size) {
                        return error.TooManyNestedItems;
                    }

                    p.stack <<= 1;
                    p.stack |= object_bit;
                    p.stack_used += 1;

                    p.state = .ValueBegin;
                    p.after_string_state = .ObjectSeparator;

                    token.* = Token.ObjectBegin;
                },
                '[' => {
                    if (p.stack_used == max_stack_size) {
                        return error.TooManyNestedItems;
                    }

                    p.stack <<= 1;
                    p.stack |= array_bit;
                    p.stack_used += 1;

                    p.state = .ValueBegin;
                    p.after_string_state = .ValueEnd;

                    token.* = Token.ArrayBegin;
                },
                '-' => {
                    p.number_is_integer = true;
                    p.state = .Number;
                    p.count = 0;
                },
                '0' => {
                    p.number_is_integer = true;
                    p.state = .NumberMaybeDotOrExponent;
                    p.count = 0;
                },
                '1'...'9' => {
                    p.number_is_integer = true;
                    p.state = .NumberMaybeDigitOrDotOrExponent;
                    p.count = 0;
                },
                '"' => {
                    p.state = .String;
                    p.string_escapes = .None;
                    p.string_last_was_high_surrogate = false;
                    p.count = 0;
                },
                't' => {
                    p.state = .TrueLiteral1;
                    p.count = 0;
                },
                'f' => {
                    p.state = .FalseLiteral1;
                    p.count = 0;
                },
                'n' => {
                    p.state = .NullLiteral1;
                    p.count = 0;
                },
                0x09, 0x0A, 0x0D, 0x20 => {
                    // whitespace
                },
                else => {
                    return error.InvalidValueBegin;
                },
            },

            // TODO: A bit of duplication here and in the following state, redo.
            .ValueBeginNoClosing => switch (c) {
                '{' => {
                    if (p.stack_used == max_stack_size) {
                        return error.TooManyNestedItems;
                    }

                    p.stack <<= 1;
                    p.stack |= object_bit;
                    p.stack_used += 1;

                    p.state = .ValueBegin;
                    p.after_string_state = .ObjectSeparator;

                    token.* = Token.ObjectBegin;
                },
                '[' => {
                    if (p.stack_used == max_stack_size) {
                        return error.TooManyNestedItems;
                    }

                    p.stack <<= 1;
                    p.stack |= array_bit;
                    p.stack_used += 1;

                    p.state = .ValueBegin;
                    p.after_string_state = .ValueEnd;

                    token.* = Token.ArrayBegin;
                },
                '-' => {
                    p.number_is_integer = true;
                    p.state = .Number;
                    p.count = 0;
                },
                '0' => {
                    p.number_is_integer = true;
                    p.state = .NumberMaybeDotOrExponent;
                    p.count = 0;
                },
                '1'...'9' => {
                    p.number_is_integer = true;
                    p.state = .NumberMaybeDigitOrDotOrExponent;
                    p.count = 0;
                },
                '"' => {
                    p.state = .String;
                    p.string_escapes = .None;
                    p.string_last_was_high_surrogate = false;
                    p.count = 0;
                },
                't' => {
                    p.state = .TrueLiteral1;
                    p.count = 0;
                },
                'f' => {
                    p.state = .FalseLiteral1;
                    p.count = 0;
                },
                'n' => {
                    p.state = .NullLiteral1;
                    p.count = 0;
                },
                0x09, 0x0A, 0x0D, 0x20 => {
                    // whitespace
                },
                else => {
                    return error.InvalidValueBegin;
                },
            },

            .ValueEnd => switch (c) {
                ',' => {
                    p.after_string_state = State.fromInt(p.stack & 1);
                    p.state = .ValueBeginNoClosing;
                },
                ']' => {
                    if (p.stack & 1 != array_bit) {
                        return error.UnexpectedClosingBracket;
                    }
                    if (p.stack_used == 0) {
                        return error.TooManyClosingItems;
                    }

                    p.state = .ValueEnd;
                    p.after_string_state = State.fromInt(p.stack & 1);

                    p.stack >>= 1;
                    p.stack_used -= 1;

                    if (p.stack_used == 0) {
                        p.complete = true;
                        p.state = .TopLevelEnd;
                    }

                    token.* = Token.ArrayEnd;
                },
                '}' => {
                    // unlikely
                    if (p.stack & 1 != object_bit) {
                        return error.UnexpectedClosingBrace;
                    }
                    if (p.stack_used == 0) {
                        return error.TooManyClosingItems;
                    }

                    p.state = .ValueEnd;
                    p.after_string_state = State.fromInt(p.stack & 1);

                    p.stack >>= 1;
                    p.stack_used -= 1;

                    if (p.stack_used == 0) {
                        p.complete = true;
                        p.state = .TopLevelEnd;
                    }

                    token.* = Token.ObjectEnd;
                },
                0x09, 0x0A, 0x0D, 0x20 => {
                    // whitespace
                },
                else => {
                    return error.InvalidValueEnd;
                },
            },

            .ObjectSeparator => switch (c) {
                ':' => {
                    p.state = .ValueBeginNoClosing;
                    p.after_string_state = .ValueEnd;
                },
                0x09, 0x0A, 0x0D, 0x20 => {
                    // whitespace
                },
                else => {
                    return error.InvalidSeparator;
                },
            },

            .String => switch (c) {
                0x00...0x1F => {
                    return error.InvalidControlCharacter;
                },
                '"' => {
                    p.state = p.after_string_state;
                    if (p.after_value_state == .TopLevelEnd) {
                        p.state = .TopLevelEnd;
                        p.complete = true;
                    }

                    token.* = .{
                        .String = .{
                            .count = p.count - 1,
                            .escapes = p.string_escapes,
                        },
                    };
                    p.string_escapes = undefined;
                    p.string_last_was_high_surrogate = undefined;
                },
                '\\' => {
                    p.state = .StringEscapeCharacter;
                    switch (p.string_escapes) {
                        .None => {
                            p.string_escapes = .{ .Some = .{ .size_diff = 0 } };
                        },
                        .Some => {},
                    }
                },
                0x20, 0x21, 0x23...0x5B, 0x5D...0x7F => {
                    // non-control ascii
                    p.string_last_was_high_surrogate = false;
                },
                0xC2...0xDF => {
                    p.state = .StringUtf8Byte2Of2;
                },
                0xE0...0xEF => {
                    p.state = .StringUtf8Byte2Of3;
                    p.sequence_first_byte = c;
                },
                0xF0...0xF4 => {
                    p.state = .StringUtf8Byte2Of4;
                    p.sequence_first_byte = c;
                },
                else => {
                    return error.InvalidUtf8Byte;
                },
            },

            .StringUtf8Byte2Of2 => switch (c >> 6) {
                0b10 => p.state = .String,
                else => return error.InvalidUtf8Byte,
            },
            .StringUtf8Byte2Of3 => {
                switch (p.sequence_first_byte) {
                    0xE0 => switch (c) {
                        0xA0...0xBF => {},
                        else => return error.InvalidUtf8Byte,
                    },
                    0xE1...0xEF => switch (c) {
                        0x80...0xBF => {},
                        else => return error.InvalidUtf8Byte,
                    },
                    else => return error.InvalidUtf8Byte,
                }
                p.state = .StringUtf8Byte3Of3;
            },
            .StringUtf8Byte3Of3 => switch (c) {
                0x80...0xBF => p.state = .String,
                else => return error.InvalidUtf8Byte,
            },
            .StringUtf8Byte2Of4 => {
                switch (p.sequence_first_byte) {
                    0xF0 => switch (c) {
                        0x90...0xBF => {},
                        else => return error.InvalidUtf8Byte,
                    },
                    0xF1...0xF3 => switch (c) {
                        0x80...0xBF => {},
                        else => return error.InvalidUtf8Byte,
                    },
                    0xF4 => switch (c) {
                        0x80...0x8F => {},
                        else => return error.InvalidUtf8Byte,
                    },
                    else => return error.InvalidUtf8Byte,
                }
                p.state = .StringUtf8Byte3Of4;
            },
            .StringUtf8Byte3Of4 => switch (c) {
                0x80...0xBF => p.state = .StringUtf8Byte4Of4,
                else => return error.InvalidUtf8Byte,
            },
            .StringUtf8Byte4Of4 => switch (c) {
                0x80...0xBF => p.state = .String,
                else => return error.InvalidUtf8Byte,
            },

            .StringEscapeCharacter => switch (c) {
                // NOTE: '/' is allowed as an escaped character but it also is allowed
                // as unescaped according to the RFC. There is a reported errata which suggests
                // removing the non-escaped variant but it makes more sense to simply disallow
                // it as an escape code here.
                //
                // The current JSONTestSuite tests rely on both of this behaviour being present
                // however, so we default to the status quo where both are accepted until this
                // is further clarified.
                '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => {
                    p.string_escapes.Some.size_diff -= 1;
                    p.state = .String;
                    p.string_last_was_high_surrogate = false;
                },
                'u' => {
                    p.state = .StringEscapeHexUnicode4;
                },
                else => {
                    return error.InvalidEscapeCharacter;
                },
            },

            .StringEscapeHexUnicode4 => {
                var codepoint: u21 = undefined;
                switch (c) {
                    else => return error.InvalidUnicodeHexSymbol,
                    '0'...'9' => {
                        codepoint = c - '0';
                    },
                    'A'...'F' => {
                        codepoint = c - 'A' + 10;
                    },
                    'a'...'f' => {
                        codepoint = c - 'a' + 10;
                    },
                }
                p.state = .StringEscapeHexUnicode3;
                p.string_unicode_codepoint = codepoint << 12;
            },

            .StringEscapeHexUnicode3 => {
                var codepoint: u21 = undefined;
                switch (c) {
                    else => return error.InvalidUnicodeHexSymbol,
                    '0'...'9' => {
                        codepoint = c - '0';
                    },
                    'A'...'F' => {
                        codepoint = c - 'A' + 10;
                    },
                    'a'...'f' => {
                        codepoint = c - 'a' + 10;
                    },
                }
                p.state = .StringEscapeHexUnicode2;
                p.string_unicode_codepoint |= codepoint << 8;
            },

            .StringEscapeHexUnicode2 => {
                var codepoint: u21 = undefined;
                switch (c) {
                    else => return error.InvalidUnicodeHexSymbol,
                    '0'...'9' => {
                        codepoint = c - '0';
                    },
                    'A'...'F' => {
                        codepoint = c - 'A' + 10;
                    },
                    'a'...'f' => {
                        codepoint = c - 'a' + 10;
                    },
                }
                p.state = .StringEscapeHexUnicode1;
                p.string_unicode_codepoint |= codepoint << 4;
            },

            .StringEscapeHexUnicode1 => {
                var codepoint: u21 = undefined;
                switch (c) {
                    else => return error.InvalidUnicodeHexSymbol,
                    '0'...'9' => {
                        codepoint = c - '0';
                    },
                    'A'...'F' => {
                        codepoint = c - 'A' + 10;
                    },
                    'a'...'f' => {
                        codepoint = c - 'a' + 10;
                    },
                }
                p.state = .String;
                p.string_unicode_codepoint |= codepoint;
                if (p.string_unicode_codepoint < 0xD800 or p.string_unicode_codepoint >= 0xE000) {
                    // not part of surrogate pair
                    p.string_escapes.Some.size_diff -= @as(isize, 6 - (std.unicode.utf8CodepointSequenceLength(p.string_unicode_codepoint) catch unreachable));
                    p.string_last_was_high_surrogate = false;
                } else if (p.string_unicode_codepoint < 0xDC00) {
                    // 'high' surrogate
                    // takes 3 bytes to encode a half surrogate pair into wtf8
                    p.string_escapes.Some.size_diff -= 6 - 3;
                    p.string_last_was_high_surrogate = true;
                } else {
                    // 'low' surrogate
                    p.string_escapes.Some.size_diff -= 6;
                    if (p.string_last_was_high_surrogate) {
                        // takes 4 bytes to encode a full surrogate pair into utf8
                        // 3 bytes are already reserved by high surrogate
                        p.string_escapes.Some.size_diff -= -1;
                    } else {
                        // takes 3 bytes to encode a half surrogate pair into wtf8
                        p.string_escapes.Some.size_diff -= -3;
                    }
                    p.string_last_was_high_surrogate = false;
                }
                p.string_unicode_codepoint = undefined;
            },

            .Number => {
                p.complete = p.after_value_state == .TopLevelEnd;
                switch (c) {
                    '0' => {
                        p.state = .NumberMaybeDotOrExponent;
                    },
                    '1'...'9' => {
                        p.state = .NumberMaybeDigitOrDotOrExponent;
                    },
                    else => {
                        return error.InvalidNumber;
                    },
                }
            },

            .NumberMaybeDotOrExponent => {
                p.complete = p.after_value_state == .TopLevelEnd;
                switch (c) {
                    '.' => {
                        p.number_is_integer = false;
                        p.state = .NumberFractionalRequired;
                    },
                    'e', 'E' => {
                        p.number_is_integer = false;
                        p.state = .NumberExponent;
                    },
                    else => {
                        p.state = p.after_value_state;
                        token.* = .{
                            .Number = .{
                                .count = p.count,
                                .is_integer = p.number_is_integer,
                            },
                        };
                        p.number_is_integer = undefined;
                        return true;
                    },
                }
            },

            .NumberMaybeDigitOrDotOrExponent => {
                p.complete = p.after_value_state == .TopLevelEnd;
                switch (c) {
                    '.' => {
                        p.number_is_integer = false;
                        p.state = .NumberFractionalRequired;
                    },
                    'e', 'E' => {
                        p.number_is_integer = false;
                        p.state = .NumberExponent;
                    },
                    '0'...'9' => {
                        // another digit
                    },
                    else => {
                        p.state = p.after_value_state;
                        token.* = .{
                            .Number = .{
                                .count = p.count,
                                .is_integer = p.number_is_integer,
                            },
                        };
                        return true;
                    },
                }
            },

            .NumberFractionalRequired => {
                p.complete = p.after_value_state == .TopLevelEnd;
                switch (c) {
                    '0'...'9' => {
                        p.state = .NumberFractional;
                    },
                    else => {
                        return error.InvalidNumber;
                    },
                }
            },

            .NumberFractional => {
                p.complete = p.after_value_state == .TopLevelEnd;
                switch (c) {
                    '0'...'9' => {
                        // another digit
                    },
                    'e', 'E' => {
                        p.number_is_integer = false;
                        p.state = .NumberExponent;
                    },
                    else => {
                        p.state = p.after_value_state;
                        token.* = .{
                            .Number = .{
                                .count = p.count,
                                .is_integer = p.number_is_integer,
                            },
                        };
                        return true;
                    },
                }
            },

            .NumberMaybeExponent => {
                p.complete = p.after_value_state == .TopLevelEnd;
                switch (c) {
                    'e', 'E' => {
                        p.number_is_integer = false;
                        p.state = .NumberExponent;
                    },
                    else => {
                        p.state = p.after_value_state;
                        token.* = .{
                            .Number = .{
                                .count = p.count,
                                .is_integer = p.number_is_integer,
                            },
                        };
                        return true;
                    },
                }
            },

            .NumberExponent => switch (c) {
                '-', '+' => {
                    p.complete = false;
                    p.state = .NumberExponentDigitsRequired;
                },
                '0'...'9' => {
                    p.complete = p.after_value_state == .TopLevelEnd;
                    p.state = .NumberExponentDigits;
                },
                else => {
                    return error.InvalidNumber;
                },
            },

            .NumberExponentDigitsRequired => switch (c) {
                '0'...'9' => {
                    p.complete = p.after_value_state == .TopLevelEnd;
                    p.state = .NumberExponentDigits;
                },
                else => {
                    return error.InvalidNumber;
                },
            },

            .NumberExponentDigits => {
                p.complete = p.after_value_state == .TopLevelEnd;
                switch (c) {
                    '0'...'9' => {
                        // another digit
                    },
                    else => {
                        p.state = p.after_value_state;
                        token.* = .{
                            .Number = .{
                                .count = p.count,
                                .is_integer = p.number_is_integer,
                            },
                        };
                        return true;
                    },
                }
            },

            .TrueLiteral1 => switch (c) {
                'r' => p.state = .TrueLiteral2,
                else => return error.InvalidLiteral,
            },

            .TrueLiteral2 => switch (c) {
                'u' => p.state = .TrueLiteral3,
                else => return error.InvalidLiteral,
            },

            .TrueLiteral3 => switch (c) {
                'e' => {
                    p.state = p.after_value_state;
                    p.complete = p.state == .TopLevelEnd;
                    token.* = Token.True;
                },
                else => {
                    return error.InvalidLiteral;
                },
            },

            .FalseLiteral1 => switch (c) {
                'a' => p.state = .FalseLiteral2,
                else => return error.InvalidLiteral,
            },

            .FalseLiteral2 => switch (c) {
                'l' => p.state = .FalseLiteral3,
                else => return error.InvalidLiteral,
            },

            .FalseLiteral3 => switch (c) {
                's' => p.state = .FalseLiteral4,
                else => return error.InvalidLiteral,
            },

            .FalseLiteral4 => switch (c) {
                'e' => {
                    p.state = p.after_value_state;
                    p.complete = p.state == .TopLevelEnd;
                    token.* = Token.False;
                },
                else => {
                    return error.InvalidLiteral;
                },
            },

            .NullLiteral1 => switch (c) {
                'u' => p.state = .NullLiteral2,
                else => return error.InvalidLiteral,
            },

            .NullLiteral2 => switch (c) {
                'l' => p.state = .NullLiteral3,
                else => return error.InvalidLiteral,
            },

            .NullLiteral3 => switch (c) {
                'l' => {
                    p.state = p.after_value_state;
                    p.complete = p.state == .TopLevelEnd;
                    token.* = Token.Null;
                },
                else => {
                    return error.InvalidLiteral;
                },
            },
        }

        return false;
    }
};

/// A small wrapper over a StreamingParser for full slices. Returns a stream of json Tokens.
pub const TokenStream = struct {
    i: usize,
    slice: []const u8,
    parser: StreamingParser,
    token: ?Token,

    pub const Error = StreamingParser.Error || error{UnexpectedEndOfJson};

    pub fn init(slice: []const u8) TokenStream {
        return TokenStream{
            .i = 0,
            .slice = slice,
            .parser = StreamingParser.init(),
            .token = null,
        };
    }

    fn stackUsed(self: *TokenStream) u8 {
        return self.parser.stack_used + if (self.token != null) @as(u8, 1) else 0;
    }

    pub fn next(self: *TokenStream) Error!?Token {
        if (self.token) |token| {
            self.token = null;
            return token;
        }

        var t1: ?Token = undefined;
        var t2: ?Token = undefined;

        while (self.i < self.slice.len) {
            try self.parser.feed(self.slice[self.i], &t1, &t2);
            self.i += 1;

            if (t1) |token| {
                self.token = t2;
                return token;
            }
        }

        // Without this a bare number fails, the streaming parser doesn't know the input ended
        try self.parser.feed(' ', &t1, &t2);
        self.i += 1;

        if (t1) |token| {
            return token;
        } else if (self.parser.complete) {
            return null;
        } else {
            return error.UnexpectedEndOfJson;
        }
    }
};

fn checkNext(p: *TokenStream, id: std.meta.Tag(Token)) !void {
    const token = (p.next() catch unreachable).?;
    try testing.expect(std.meta.activeTag(token) == id);
}

test "json.token" {
    const s =
        \\{
        \\  "Image": {
        \\      "Width":  800,
        \\      "Height": 600,
        \\      "Title":  "View from 15th Floor",
        \\      "Thumbnail": {
        \\          "Url":    "http://www.example.com/image/481989943",
        \\          "Height": 125,
        \\          "Width":  100
        \\      },
        \\      "Animated" : false,
        \\      "IDs": [116, 943, 234, 38793]
        \\    }
        \\}
    ;

    var p = TokenStream.init(s);

    try checkNext(&p, .ObjectBegin);
    try checkNext(&p, .String); // Image
    try checkNext(&p, .ObjectBegin);
    try checkNext(&p, .String); // Width
    try checkNext(&p, .Number);
    try checkNext(&p, .String); // Height
    try checkNext(&p, .Number);
    try checkNext(&p, .String); // Title
    try checkNext(&p, .String);
    try checkNext(&p, .String); // Thumbnail
    try checkNext(&p, .ObjectBegin);
    try checkNext(&p, .String); // Url
    try checkNext(&p, .String);
    try checkNext(&p, .String); // Height
    try checkNext(&p, .Number);
    try checkNext(&p, .String); // Width
    try checkNext(&p, .Number);
    try checkNext(&p, .ObjectEnd);
    try checkNext(&p, .String); // Animated
    try checkNext(&p, .False);
    try checkNext(&p, .String); // IDs
    try checkNext(&p, .ArrayBegin);
    try checkNext(&p, .Number);
    try checkNext(&p, .Number);
    try checkNext(&p, .Number);
    try checkNext(&p, .Number);
    try checkNext(&p, .ArrayEnd);
    try checkNext(&p, .ObjectEnd);
    try checkNext(&p, .ObjectEnd);

    try testing.expect((try p.next()) == null);
}

test "json.token mismatched close" {
    var p = TokenStream.init("[102, 111, 111 }");
    try checkNext(&p, .ArrayBegin);
    try checkNext(&p, .Number);
    try checkNext(&p, .Number);
    try checkNext(&p, .Number);
    try testing.expectError(error.UnexpectedClosingBrace, p.next());
}

test "json.token premature object close" {
    var p = TokenStream.init("{ \"key\": }");
    try checkNext(&p, .ObjectBegin);
    try checkNext(&p, .String);
    try testing.expectError(error.InvalidValueBegin, p.next());
}

/// Validate a JSON string. This does not limit number precision so a decoder may not necessarily
/// be able to decode the string even if this returns true.
pub fn validate(s: []const u8) bool {
    var p = StreamingParser.init();

    for (s) |c| {
        var token1: ?Token = undefined;
        var token2: ?Token = undefined;

        p.feed(c, &token1, &token2) catch {
            return false;
        };
    }

    return p.complete;
}

test "json.validate" {
    try testing.expectEqual(true, validate("{}"));
    try testing.expectEqual(true, validate("[]"));
    try testing.expectEqual(true, validate("[{[[[[{}]]]]}]"));
    try testing.expectEqual(false, validate("{]"));
    try testing.expectEqual(false, validate("[}"));
    try testing.expectEqual(false, validate("{{{{[]}}}]"));
}

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const StringArrayHashMap = std.StringArrayHashMap;

pub const ValueTree = struct {
    arena: ArenaAllocator,
    root: Value,

    pub fn deinit(self: *ValueTree) void {
        self.arena.deinit();
    }
};

pub const ObjectMap = StringArrayHashMap(Value);
pub const Array = ArrayList(Value);

/// Represents a JSON value
/// Currently only supports numbers that fit into i64 or f64.
pub const Value = union(enum) {
    Null,
    Bool: bool,
    Integer: i64,
    Float: f64,
    NumberString: []const u8,
    String: []const u8,
    Array: Array,
    Object: ObjectMap,

    pub fn jsonStringify(
        value: @This(),
        options: StringifyOptions,
        out_stream: anytype,
    ) @TypeOf(out_stream).Error!void {
        switch (value) {
            .Null => try stringify(null, options, out_stream),
            .Bool => |inner| try stringify(inner, options, out_stream),
            .Integer => |inner| try stringify(inner, options, out_stream),
            .Float => |inner| try stringify(inner, options, out_stream),
            .NumberString => |inner| try out_stream.writeAll(inner),
            .String => |inner| try stringify(inner, options, out_stream),
            .Array => |inner| try stringify(inner.items, options, out_stream),
            .Object => |inner| {
                try out_stream.writeByte('{');
                var field_output = false;
                var child_options = options;
                if (child_options.whitespace) |*child_whitespace| {
                    child_whitespace.indent_level += 1;
                }
                var it = inner.iterator();
                while (it.next()) |entry| {
                    if (!field_output) {
                        field_output = true;
                    } else {
                        try out_stream.writeByte(',');
                    }
                    if (child_options.whitespace) |child_whitespace| {
                        try out_stream.writeByte('\n');
                        try child_whitespace.outputIndent(out_stream);
                    }

                    try stringify(entry.key_ptr.*, options, out_stream);
                    try out_stream.writeByte(':');
                    if (child_options.whitespace) |child_whitespace| {
                        if (child_whitespace.separator) {
                            try out_stream.writeByte(' ');
                        }
                    }
                    try stringify(entry.value_ptr.*, child_options, out_stream);
                }
                if (field_output) {
                    if (options.whitespace) |whitespace| {
                        try out_stream.writeByte('\n');
                        try whitespace.outputIndent(out_stream);
                    }
                }
                try out_stream.writeByte('}');
            },
        }
    }

    pub fn dump(self: Value) void {
        var held = std.debug.getStderrMutex().acquire();
        defer held.release();

        const stderr = std.io.getStdErr().writer();
        std.json.stringify(self, std.json.StringifyOptions{ .whitespace = null }, stderr) catch return;
    }
};

test "Value.jsonStringify" {
    {
        var buffer: [10]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buffer);
        try @as(Value, .Null).jsonStringify(.{}, fbs.writer());
        try testing.expectEqualSlices(u8, fbs.getWritten(), "null");
    }
    {
        var buffer: [10]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buffer);
        try (Value{ .Bool = true }).jsonStringify(.{}, fbs.writer());
        try testing.expectEqualSlices(u8, fbs.getWritten(), "true");
    }
    {
        var buffer: [10]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buffer);
        try (Value{ .Integer = 42 }).jsonStringify(.{}, fbs.writer());
        try testing.expectEqualSlices(u8, fbs.getWritten(), "42");
    }
    {
        var buffer: [10]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buffer);
        try (Value{ .NumberString = "43" }).jsonStringify(.{}, fbs.writer());
        try testing.expectEqualSlices(u8, fbs.getWritten(), "43");
    }
    {
        var buffer: [10]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buffer);
        try (Value{ .Float = 42 }).jsonStringify(.{}, fbs.writer());
        try testing.expectEqualSlices(u8, fbs.getWritten(), "4.2e+01");
    }
    {
        var buffer: [10]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buffer);
        try (Value{ .String = "weeee" }).jsonStringify(.{}, fbs.writer());
        try testing.expectEqualSlices(u8, fbs.getWritten(), "\"weeee\"");
    }
    {
        var buffer: [10]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buffer);
        var vals = [_]Value{
            .{ .Integer = 1 },
            .{ .Integer = 2 },
            .{ .NumberString = "3" },
        };
        try (Value{
            .Array = Array.fromOwnedSlice(undefined, &vals),
        }).jsonStringify(.{}, fbs.writer());
        try testing.expectEqualSlices(u8, fbs.getWritten(), "[1,2,3]");
    }
    {
        var buffer: [10]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buffer);
        var obj = ObjectMap.init(testing.allocator);
        defer obj.deinit();
        try obj.putNoClobber("a", .{ .String = "b" });
        try (Value{ .Object = obj }).jsonStringify(.{}, fbs.writer());
        try testing.expectEqualSlices(u8, fbs.getWritten(), "{\"a\":\"b\"}");
    }
}

/// parse tokens from a stream, returning `false` if they do not decode to `value`
fn parsesTo(comptime T: type, value: T, tokens: *TokenStream, options: ParseOptions) !bool {
    // TODO: should be able to write this function to not require an allocator
    const tmp = try parse(T, tokens, options);
    defer parseFree(T, tmp, options);

    return parsedEqual(tmp, value);
}

/// Returns if a value returned by `parse` is deep-equal to another value
fn parsedEqual(a: anytype, b: @TypeOf(a)) bool {
    switch (@typeInfo(@TypeOf(a))) {
        .Optional => {
            if (a == null and b == null) return true;
            if (a == null or b == null) return false;
            return parsedEqual(a.?, b.?);
        },
        .Union => {
            if (info.tag_type) |UnionTag| {
                const tag_a = std.meta.activeTag(a);
                const tag_b = std.meta.activeTag(b);
                if (tag_a != tag_b) return false;

                inline for (info.fields) |field_info| {
                    if (@field(UnionTag, field_info.name) == tag_a) {
                        return parsedEqual(@field(a, field_info.name), @field(b, field_info.name));
                    }
                }
                return false;
            } else {
                unreachable;
            }
        },
        .Array => {
            for (a) |e, i|
                if (!parsedEqual(e, b[i])) return false;
            return true;
        },
        .Struct => |info| {
            inline for (info.fields) |field_info| {
                if (!parsedEqual(@field(a, field_info.name), @field(b, field_info.name))) return false;
            }
            return true;
        },
        .Pointer => |ptrInfo| switch (ptrInfo.size) {
            .One => return parsedEqual(a.*, b.*),
            .Slice => {
                if (a.len != b.len) return false;
                for (a) |e, i|
                    if (!parsedEqual(e, b[i])) return false;
                return true;
            },
            .Many, .C => unreachable,
        },
        else => return a == b,
    }
    unreachable;
}

pub const ParseOptions = struct {
    allocator: ?*Allocator = null,

    /// Behaviour when a duplicate field is encountered.
    duplicate_field_behavior: enum {
        UseFirst,
        Error,
        UseLast,
    } = .Error,

    /// If false, finding an unknown field returns an error.
    ignore_unknown_fields: bool = false,

    allow_trailing_data: bool = false,
};

const SkipValueError = error{UnexpectedJsonDepth} || TokenStream.Error;

fn skipValue(tokens: *TokenStream) SkipValueError!void {
    const original_depth = tokens.stackUsed();

    // Return an error if no value is found
    _ = try tokens.next();
    if (tokens.stackUsed() < original_depth) return error.UnexpectedJsonDepth;
    if (tokens.stackUsed() == original_depth) return;

    while (try tokens.next()) |_| {
        if (tokens.stackUsed() == original_depth) return;
    }
}

test "skipValue" {
    try skipValue(&TokenStream.init("false"));
    try skipValue(&TokenStream.init("true"));
    try skipValue(&TokenStream.init("null"));
    try skipValue(&TokenStream.init("42"));
    try skipValue(&TokenStream.init("42.0"));
    try skipValue(&TokenStream.init("\"foo\""));
    try skipValue(&TokenStream.init("[101, 111, 121]"));
    try skipValue(&TokenStream.init("{}"));
    try skipValue(&TokenStream.init("{\"foo\": \"bar\"}"));

    { // An absurd number of nestings
        const nestings = 256;

        try testing.expectError(
            error.TooManyNestedItems,
            skipValue(&TokenStream.init("[" ** nestings ++ "]" ** nestings)),
        );
    }

    { // Would a number token cause problems in a deeply-nested array?
        const nestings = 255;
        const deeply_nested_array = "[" ** nestings ++ "0.118, 999, 881.99, 911.9, 725, 3" ++ "]" ** nestings;

        try skipValue(&TokenStream.init(deeply_nested_array));

        try testing.expectError(
            error.TooManyNestedItems,
            skipValue(&TokenStream.init("[" ++ deeply_nested_array ++ "]")),
        );
    }

    // Mismatched brace/square bracket
    try testing.expectError(
        error.UnexpectedClosingBrace,
        skipValue(&TokenStream.init("[102, 111, 111}")),
    );

    { // should fail if no value found (e.g. immediate close of object)
        var empty_object = TokenStream.init("{}");
        assert(.ObjectBegin == (try empty_object.next()).?);
        try testing.expectError(error.UnexpectedJsonDepth, skipValue(&empty_object));

        var empty_array = TokenStream.init("[]");
        assert(.ArrayBegin == (try empty_array.next()).?);
        try testing.expectError(error.UnexpectedJsonDepth, skipValue(&empty_array));
    }
}

fn ParseInternalError(comptime T: type) type {
    // `inferred_types` is used to avoid infinite recursion for recursive type definitions.
    const inferred_types = [_]type{};
    return ParseInternalErrorImpl(T, &inferred_types);
}

fn ParseInternalErrorImpl(comptime T: type, comptime inferred_types: []const type) type {
    for (inferred_types) |ty| {
        if (T == ty) return error{};
    }

    switch (@typeInfo(T)) {
        .Bool => return error{UnexpectedToken},
        .Float, .ComptimeFloat => return error{UnexpectedToken} || std.fmt.ParseFloatError,
        .Int, .ComptimeInt => {
            return error{ UnexpectedToken, InvalidNumber, Overflow, InvalidCharacter } ||
                std.fmt.ParseIntError || std.fmt.ParseFloatError;
        },
        .Optional => |optionalInfo| {
            return ParseInternalErrorImpl(optionalInfo.child, inferred_types ++ [_]type{T});
        },
        .Enum => return error{UnexpectedToken} || std.fmt.ParseIntError || std.meta.IntToEnumError,
        .Union => |unionInfo| {
            if (unionInfo.tag_type) |_| {
                var errors = error{NoUnionMembersMatched};
                for (unionInfo.fields) |u_field| {
                    errors = errors || ParseInternalErrorImpl(u_field.field_type, inferred_types ++ [_]type{T});
                }
                return errors;
            } else {
                @compileError("Unable to parse into untagged union '" ++ @typeName(T) ++ "'");
            }
        },
        .Struct => |structInfo| {
            var errors = error{
                DuplicateJSONField,
                UnexpectedEndOfJson,
                UnexpectedToken,
                UnexpectedValue,
                UnknownField,
                MissingField,
            } || SkipValueError;
            for (structInfo.fields) |field| {
                errors = errors || ParseInternalErrorImpl(field.field_type, inferred_types ++ [_]type{T});
            }
            return errors;
        },
        .Array => |arrayInfo| {
            return error{ UnexpectedEndOfJson, UnexpectedToken } || TokenStream.Error ||
                UnescapeValidStringError ||
                ParseInternalErrorImpl(arrayInfo.child, inferred_types ++ [_]type{T});
        },
        .Pointer => |ptrInfo| {
            var errors = error{AllocatorRequired} || std.mem.Allocator.Error;
            switch (ptrInfo.size) {
                .One => {
                    return errors || ParseInternalErrorImpl(ptrInfo.child, inferred_types ++ [_]type{T});
                },
                .Slice => {
                    return errors || error{ UnexpectedEndOfJson, UnexpectedToken } ||
                        ParseInternalErrorImpl(ptrInfo.child, inferred_types ++ [_]type{T}) ||
                        UnescapeValidStringError || TokenStream.Error;
                },
                else => @compileError("Unable to parse into type '" ++ @typeName(T) ++ "'"),
            }
        },
        else => return error{},
    }
    unreachable;
}

fn parseInternal(
    comptime T: type,
    token: Token,
    tokens: *TokenStream,
    options: ParseOptions,
) ParseInternalError(T)!T {
    switch (@typeInfo(T)) {
        .Bool => {
            return switch (token) {
                .True => true,
                .False => false,
                else => error.UnexpectedToken,
            };
        },
        .Float, .ComptimeFloat => {
            const numberToken = switch (token) {
                .Number => |n| n,
                else => return error.UnexpectedToken,
            };
            return try std.fmt.parseFloat(T, numberToken.slice(tokens.slice, tokens.i - 1));
        },
        .Int, .ComptimeInt => {
            const numberToken = switch (token) {
                .Number => |n| n,
                else => return error.UnexpectedToken,
            };
            if (numberToken.is_integer)
                return try std.fmt.parseInt(T, numberToken.slice(tokens.slice, tokens.i - 1), 10);
            const float = try std.fmt.parseFloat(f128, numberToken.slice(tokens.slice, tokens.i - 1));
            if (std.math.round(float) != float) return error.InvalidNumber;
            if (float > std.math.maxInt(T) or float < std.math.minInt(T)) return error.Overflow;
            return @floatToInt(T, float);
        },
        .Optional => |optionalInfo| {
            if (token == .Null) {
                return null;
            } else {
                return try parseInternal(optionalInfo.child, token, tokens, options);
            }
        },
        .Enum => |enumInfo| {
            switch (token) {
                .Number => |numberToken| {
                    if (!numberToken.is_integer) return error.UnexpectedToken;
                    const n = try std.fmt.parseInt(enumInfo.tag_type, numberToken.slice(tokens.slice, tokens.i - 1), 10);
                    return try std.meta.intToEnum(T, n);
                },
                .String => |stringToken| {
                    const source_slice = stringToken.slice(tokens.slice, tokens.i - 1);
                    switch (stringToken.escapes) {
                        .None => return std.meta.stringToEnum(T, source_slice) orelse return error.InvalidEnumTag,
                        .Some => {
                            inline for (enumInfo.fields) |field| {
                                if (field.name.len == stringToken.decodedLength() and encodesTo(field.name, source_slice)) {
                                    return @field(T, field.name);
                                }
                            }
                            return error.InvalidEnumTag;
                        },
                    }
                },
                else => return error.UnexpectedToken,
            }
        },
        .Union => |unionInfo| {
            if (unionInfo.tag_type) |_| {
                // try each of the union fields until we find one that matches
                inline for (unionInfo.fields) |u_field| {
                    // take a copy of tokens so we can withhold mutations until success
                    var tokens_copy = tokens.*;
                    if (parseInternal(u_field.field_type, token, &tokens_copy, options)) |value| {
                        tokens.* = tokens_copy;
                        return @unionInit(T, u_field.name, value);
                    } else |err| {
                        // Bubble up error.OutOfMemory
                        // Parsing some types won't have OutOfMemory in their
                        // error-sets, for the condition to be valid, merge it in.
                        if (@as(@TypeOf(err) || error{OutOfMemory}, err) == error.OutOfMemory) return err;
                        // Bubble up AllocatorRequired, as it indicates missing option
                        if (@as(@TypeOf(err) || error{AllocatorRequired}, err) == error.AllocatorRequired) return err;
                        // otherwise continue through the `inline for`
                    }
                }
                return error.NoUnionMembersMatched;
            } else {
                @compileError("Unable to parse into untagged union '" ++ @typeName(T) ++ "'");
            }
        },
        .Struct => |structInfo| {
            switch (token) {
                .ObjectBegin => {},
                else => return error.UnexpectedToken,
            }
            var r: T = undefined;
            var fields_seen = [_]bool{false} ** structInfo.fields.len;
            errdefer {
                inline for (structInfo.fields) |field, i| {
                    if (fields_seen[i] and !field.is_comptime) {
                        parseFree(field.field_type, @field(r, field.name), options);
                    }
                }
            }

            while (true) {
                switch ((try tokens.next()) orelse return error.UnexpectedEndOfJson) {
                    .ObjectEnd => break,
                    .String => |stringToken| {
                        const key_source_slice = stringToken.slice(tokens.slice, tokens.i - 1);
                        var child_options = options;
                        child_options.allow_trailing_data = true;
                        var found = false;
                        inline for (structInfo.fields) |field, i| {
                            // TODO: using switches here segfault the compiler (#2727?)
                            if ((stringToken.escapes == .None and mem.eql(u8, field.name, key_source_slice)) or (stringToken.escapes == .Some and (field.name.len == stringToken.decodedLength() and encodesTo(field.name, key_source_slice)))) {
                                // if (switch (stringToken.escapes) {
                                //     .None => mem.eql(u8, field.name, key_source_slice),
                                //     .Some => (field.name.len == stringToken.decodedLength() and encodesTo(field.name, key_source_slice)),
                                // }) {
                                if (fields_seen[i]) {
                                    // switch (options.duplicate_field_behavior) {
                                    //     .UseFirst => {},
                                    //     .Error => {},
                                    //     .UseLast => {},
                                    // }
                                    if (options.duplicate_field_behavior == .UseFirst) {
                                        // unconditonally ignore value. for comptime fields, this skips check against default_value
                                        parseFree(field.field_type, try parse(field.field_type, tokens, child_options), child_options);
                                        found = true;
                                        break;
                                    } else if (options.duplicate_field_behavior == .Error) {
                                        return error.DuplicateJSONField;
                                    } else if (options.duplicate_field_behavior == .UseLast) {
                                        if (!field.is_comptime) {
                                            parseFree(field.field_type, @field(r, field.name), child_options);
                                        }
                                        fields_seen[i] = false;
                                    }
                                }
                                if (field.is_comptime) {
                                    if (!try parsesTo(field.field_type, field.default_value.?, tokens, child_options)) {
                                        return error.UnexpectedValue;
                                    }
                                } else {
                                    @field(r, field.name) = try parse(field.field_type, tokens, child_options);
                                }
                                fields_seen[i] = true;
                                found = true;
                                break;
                            }
                        }
                        if (!found) {
                            if (options.ignore_unknown_fields) {
                                try skipValue(tokens);
                                continue;
                            } else {
                                return error.UnknownField;
                            }
                        }
                    },
                    else => return error.UnexpectedToken,
                }
            }
            inline for (structInfo.fields) |field, i| {
                if (!fields_seen[i]) {
                    if (field.default_value) |default| {
                        if (!field.is_comptime) {
                            @field(r, field.name) = default;
                        }
                    } else {
                        return error.MissingField;
                    }
                }
            }
            return r;
        },
        .Array => |arrayInfo| {
            switch (token) {
                .ArrayBegin => {
                    var r: T = undefined;
                    var i: usize = 0;
                    var child_options = options;
                    child_options.allow_trailing_data = true;
                    errdefer {
                        // Without the r.len check `r[i]` is not allowed
                        if (r.len > 0) while (true) : (i -= 1) {
                            parseFree(arrayInfo.child, r[i], options);
                            if (i == 0) break;
                        };
                    }
                    while (i < r.len) : (i += 1) {
                        r[i] = try parse(arrayInfo.child, tokens, child_options);
                    }
                    const tok = (try tokens.next()) orelse return error.UnexpectedEndOfJson;
                    switch (tok) {
                        .ArrayEnd => {},
                        else => return error.UnexpectedToken,
                    }
                    return r;
                },
                .String => |stringToken| {
                    if (arrayInfo.child != u8) return error.UnexpectedToken;
                    var r: T = undefined;
                    const source_slice = stringToken.slice(tokens.slice, tokens.i - 1);
                    switch (stringToken.escapes) {
                        .None => mem.copy(u8, &r, source_slice),
                        .Some => try unescapeValidString(&r, source_slice),
                    }
                    return r;
                },
                else => return error.UnexpectedToken,
            }
        },
        .Pointer => |ptrInfo| {
            const allocator = options.allocator orelse return error.AllocatorRequired;
            switch (ptrInfo.size) {
                .One => {
                    const r: T = try allocator.create(ptrInfo.child);
                    errdefer allocator.destroy(r);
                    r.* = try parseInternal(ptrInfo.child, token, tokens, options);
                    return r;
                },
                .Slice => {
                    switch (token) {
                        .ArrayBegin => {
                            var arraylist = std.ArrayList(ptrInfo.child).init(allocator);
                            errdefer {
                                while (arraylist.popOrNull()) |v| {
                                    parseFree(ptrInfo.child, v, options);
                                }
                                arraylist.deinit();
                            }

                            while (true) {
                                const tok = (try tokens.next()) orelse return error.UnexpectedEndOfJson;
                                switch (tok) {
                                    .ArrayEnd => break,
                                    else => {},
                                }

                                try arraylist.ensureCapacity(arraylist.items.len + 1);
                                const v = try parseInternal(ptrInfo.child, tok, tokens, options);
                                arraylist.appendAssumeCapacity(v);
                            }
                            return arraylist.toOwnedSlice();
                        },
                        .String => |stringToken| {
                            if (ptrInfo.child != u8) return error.UnexpectedToken;
                            const source_slice = stringToken.slice(tokens.slice, tokens.i - 1);
                            switch (stringToken.escapes) {
                                .None => return allocator.dupe(u8, source_slice),
                                .Some => {
                                    const output = try allocator.alloc(u8, stringToken.decodedLength());
                                    errdefer allocator.free(output);
                                    try unescapeValidString(output, source_slice);
                                    return output;
                                },
                            }
                        },
                        else => return error.UnexpectedToken,
                    }
                },
                else => @compileError("Unable to parse into type '" ++ @typeName(T) ++ "'"),
            }
        },
        else => @compileError("Unable to parse into type '" ++ @typeName(T) ++ "'"),
    }
    unreachable;
}

pub fn ParseError(comptime T: type) type {
    return ParseInternalError(T) || error{UnexpectedEndOfJson} || TokenStream.Error;
}

pub fn parse(comptime T: type, tokens: *TokenStream, options: ParseOptions) ParseError(T)!T {
    const token = (try tokens.next()) orelse return error.UnexpectedEndOfJson;
    const r = try parseInternal(T, token, tokens, options);
    errdefer parseFree(T, r, options);
    if (!options.allow_trailing_data) {
        if ((try tokens.next()) != null) unreachable;
        assert(tokens.i >= tokens.slice.len);
    }
    return r;
}

/// Releases resources created by `parse`.
/// Should be called with the same type and `ParseOptions` that were passed to `parse`
pub fn parseFree(comptime T: type, value: T, options: ParseOptions) void {
    switch (@typeInfo(T)) {
        .Bool, .Float, .ComptimeFloat, .Int, .ComptimeInt, .Enum => {},
        .Optional => {
            if (value) |v| {
                return parseFree(@TypeOf(v), v, options);
            }
        },
        .Union => |unionInfo| {
            if (unionInfo.tag_type) |UnionTagType| {
                inline for (unionInfo.fields) |u_field| {
                    if (value == @field(UnionTagType, u_field.name)) {
                        parseFree(u_field.field_type, @field(value, u_field.name), options);
                        break;
                    }
                }
            } else {
                unreachable;
            }
        },
        .Struct => |structInfo| {
            inline for (structInfo.fields) |field| {
                if (!field.is_comptime) {
                    parseFree(field.field_type, @field(value, field.name), options);
                }
            }
        },
        .Array => |arrayInfo| {
            for (value) |v| {
                parseFree(arrayInfo.child, v, options);
            }
        },
        .Pointer => |ptrInfo| {
            const allocator = options.allocator orelse unreachable;
            switch (ptrInfo.size) {
                .One => {
                    parseFree(ptrInfo.child, value.*, options);
                    allocator.destroy(value);
                },
                .Slice => {
                    for (value) |v| {
                        parseFree(ptrInfo.child, v, options);
                    }
                    allocator.free(value);
                },
                else => unreachable,
            }
        },
        else => unreachable,
    }
}

test "parse" {
    try testing.expectEqual(false, try parse(bool, &TokenStream.init("false"), ParseOptions{}));
    try testing.expectEqual(true, try parse(bool, &TokenStream.init("true"), ParseOptions{}));
    try testing.expectEqual(@as(u1, 1), try parse(u1, &TokenStream.init("1"), ParseOptions{}));
    try testing.expectError(error.Overflow, parse(u1, &TokenStream.init("50"), ParseOptions{}));
    try testing.expectEqual(@as(u64, 42), try parse(u64, &TokenStream.init("42"), ParseOptions{}));
    try testing.expectEqual(@as(f64, 42), try parse(f64, &TokenStream.init("42.0"), ParseOptions{}));
    try testing.expectEqual(@as(?bool, null), try parse(?bool, &TokenStream.init("null"), ParseOptions{}));
    try testing.expectEqual(@as(?bool, true), try parse(?bool, &TokenStream.init("true"), ParseOptions{}));

    try testing.expectEqual(@as([3]u8, "foo".*), try parse([3]u8, &TokenStream.init("\"foo\""), ParseOptions{}));
    try testing.expectEqual(@as([3]u8, "foo".*), try parse([3]u8, &TokenStream.init("[102, 111, 111]"), ParseOptions{}));
    try testing.expectEqual(@as([0]u8, undefined), try parse([0]u8, &TokenStream.init("[]"), ParseOptions{}));
}

test "parse into enum" {
    const T = enum(u32) {
        Foo = 42,
        Bar,
        @"with\\escape",
    };
    try testing.expectEqual(@as(T, .Foo), try parse(T, &TokenStream.init("\"Foo\""), ParseOptions{}));
    try testing.expectEqual(@as(T, .Foo), try parse(T, &TokenStream.init("42"), ParseOptions{}));
    try testing.expectEqual(@as(T, .@"with\\escape"), try parse(T, &TokenStream.init("\"with\\\\escape\""), ParseOptions{}));
    try testing.expectError(error.InvalidEnumTag, parse(T, &TokenStream.init("5"), ParseOptions{}));
    try testing.expectError(error.InvalidEnumTag, parse(T, &TokenStream.init("\"Qux\""), ParseOptions{}));
}

test "parse with trailing data" {
    try testing.expectEqual(false, try parse(bool, &TokenStream.init("falsed"), ParseOptions{ .allow_trailing_data = true }));
    try testing.expectError(error.InvalidTopLevelTrailing, parse(bool, &TokenStream.init("falsed"), ParseOptions{ .allow_trailing_data = false }));
    // trailing whitespace is okay
    try testing.expectEqual(false, try parse(bool, &TokenStream.init("false \n"), ParseOptions{ .allow_trailing_data = false }));
}

test "parse into that allocates a slice" {
    try testing.expectError(error.AllocatorRequired, parse([]u8, &TokenStream.init("\"foo\""), ParseOptions{}));

    const options = ParseOptions{ .allocator = testing.allocator };
    {
        const r = try parse([]u8, &TokenStream.init("\"foo\""), options);
        defer parseFree([]u8, r, options);
        try testing.expectEqualSlices(u8, "foo", r);
    }
    {
        const r = try parse([]u8, &TokenStream.init("[102, 111, 111]"), options);
        defer parseFree([]u8, r, options);
        try testing.expectEqualSlices(u8, "foo", r);
    }
    {
        const r = try parse([]u8, &TokenStream.init("\"with\\\\escape\""), options);
        defer parseFree([]u8, r, options);
        try testing.expectEqualSlices(u8, "with\\escape", r);
    }
}

test "parse into tagged union" {
    {
        const T = union(enum) {
            int: i32,
            float: f64,
            string: []const u8,
        };
        try testing.expectEqual(T{ .float = 1.5 }, try parse(T, &TokenStream.init("1.5"), ParseOptions{}));
    }

    { // failing allocations should be bubbled up instantly without trying next member
        var fail_alloc = testing.FailingAllocator.init(testing.allocator, 0);
        const options = ParseOptions{ .allocator = &fail_alloc.allocator };
        const T = union(enum) {
            // both fields here match the input
            string: []const u8,
            array: [3]u8,
        };
        try testing.expectError(error.OutOfMemory, parse(T, &TokenStream.init("[1,2,3]"), options));
    }

    {
        // if multiple matches possible, takes first option
        const T = union(enum) {
            x: u8,
            y: u8,
        };
        try testing.expectEqual(T{ .x = 42 }, try parse(T, &TokenStream.init("42"), ParseOptions{}));
    }

    { // needs to back out when first union member doesn't match
        const T = union(enum) {
            A: struct { x: u32 },
            B: struct { y: u32 },
        };
        try testing.expectEqual(T{ .B = .{ .y = 42 } }, try parse(T, &TokenStream.init("{\"y\":42}"), ParseOptions{}));
    }
}

test "parse union bubbles up AllocatorRequired" {
    { // string member first in union (and not matching)
        const T = union(enum) {
            string: []const u8,
            int: i32,
        };
        try testing.expectError(error.AllocatorRequired, parse(T, &TokenStream.init("42"), ParseOptions{}));
    }

    { // string member not first in union (and matching)
        const T = union(enum) {
            int: i32,
            float: f64,
            string: []const u8,
        };
        try testing.expectError(error.AllocatorRequired, parse(T, &TokenStream.init("\"foo\""), ParseOptions{}));
    }
}

test "parseFree descends into tagged union" {
    var fail_alloc = testing.FailingAllocator.init(testing.allocator, 1);
    const options = ParseOptions{ .allocator = &fail_alloc.allocator };
    const T = union(enum) {
        int: i32,
        float: f64,
        string: []const u8,
    };
    // use a string with unicode escape so we know result can't be a reference to global constant
    const r = try parse(T, &TokenStream.init("\"with\\u0105unicode\""), options);
    try testing.expectEqual(std.meta.Tag(T).string, @as(std.meta.Tag(T), r));
    try testing.expectEqualSlices(u8, "withąunicode", r.string);
    try testing.expectEqual(@as(usize, 0), fail_alloc.deallocations);
    parseFree(T, r, options);
    try testing.expectEqual(@as(usize, 1), fail_alloc.deallocations);
}

test "parse with comptime field" {
    {
        const T = struct {
            comptime a: i32 = 0,
            b: bool,
        };
        try testing.expectEqual(T{ .a = 0, .b = true }, try parse(T, &TokenStream.init(
            \\{
            \\  "a": 0,
            \\  "b": true
            \\}
        ), ParseOptions{}));
    }

    { // string comptime values currently require an allocator
        const T = union(enum) {
            foo: struct {
                comptime kind: []const u8 = "boolean",
                b: bool,
            },
            bar: struct {
                comptime kind: []const u8 = "float",
                b: f64,
            },
        };

        const options = ParseOptions{
            .allocator = std.testing.allocator,
        };

        const r = try parse(T, &TokenStream.init(
            \\{
            \\  "kind": "float",
            \\  "b": 1.0
            \\}
        ), options);

        // check that parseFree doesn't try to free comptime fields
        parseFree(T, r, options);
    }
}

test "parse into struct with no fields" {
    const T = struct {};
    try testing.expectEqual(T{}, try parse(T, &TokenStream.init("{}"), ParseOptions{}));
}

test "parse into struct with misc fields" {
    @setEvalBranchQuota(10000);
    const options = ParseOptions{ .allocator = testing.allocator };
    const T = struct {
        int: i64,
        float: f64,
        @"with\\escape": bool,
        @"withąunicode😂": bool,
        language: []const u8,
        optional: ?bool,
        default_field: i32 = 42,
        static_array: [3]f64,
        dynamic_array: []f64,

        complex: struct {
            nested: []const u8,
        },

        veryComplex: []struct {
            foo: []const u8,
        },

        a_union: Union,
        const Union = union(enum) {
            x: u8,
            float: f64,
            string: []const u8,
        };
    };
    const r = try parse(T, &TokenStream.init(
        \\{
        \\  "int": 420,
        \\  "float": 3.14,
        \\  "with\\escape": true,
        \\  "with\u0105unicode\ud83d\ude02": false,
        \\  "language": "zig",
        \\  "optional": null,
        \\  "static_array": [66.6, 420.420, 69.69],
        \\  "dynamic_array": [66.6, 420.420, 69.69],
        \\  "complex": {
        \\    "nested": "zig"
        \\  },
        \\  "veryComplex": [
        \\    {
        \\      "foo": "zig"
        \\    }, {
        \\      "foo": "rocks"
        \\    }
        \\  ],
        \\  "a_union": 100000
        \\}
    ), options);
    defer parseFree(T, r, options);
    try testing.expectEqual(@as(i64, 420), r.int);
    try testing.expectEqual(@as(f64, 3.14), r.float);
    try testing.expectEqual(true, r.@"with\\escape");
    try testing.expectEqual(false, r.@"withąunicode😂");
    try testing.expectEqualSlices(u8, "zig", r.language);
    try testing.expectEqual(@as(?bool, null), r.optional);
    try testing.expectEqual(@as(i32, 42), r.default_field);
    try testing.expectEqual(@as(f64, 66.6), r.static_array[0]);
    try testing.expectEqual(@as(f64, 420.420), r.static_array[1]);
    try testing.expectEqual(@as(f64, 69.69), r.static_array[2]);
    try testing.expectEqual(@as(usize, 3), r.dynamic_array.len);
    try testing.expectEqual(@as(f64, 66.6), r.dynamic_array[0]);
    try testing.expectEqual(@as(f64, 420.420), r.dynamic_array[1]);
    try testing.expectEqual(@as(f64, 69.69), r.dynamic_array[2]);
    try testing.expectEqualSlices(u8, r.complex.nested, "zig");
    try testing.expectEqualSlices(u8, "zig", r.veryComplex[0].foo);
    try testing.expectEqualSlices(u8, "rocks", r.veryComplex[1].foo);
    try testing.expectEqual(T.Union{ .float = 100000 }, r.a_union);
}

test "parse into struct with duplicate field" {
    // allow allocator to detect double frees by keeping bucket in use
    const ballast = try testing.allocator.alloc(u64, 1);
    defer testing.allocator.free(ballast);

    const options_first = ParseOptions{ .allocator = testing.allocator, .duplicate_field_behavior = .UseFirst };

    const options_last = ParseOptions{
        .allocator = testing.allocator,
        .duplicate_field_behavior = .UseLast,
    };

    const str = "{ \"a\": 1, \"a\": 0.25 }";

    const T1 = struct { a: *u64 };
    // both .UseFirst and .UseLast should fail because second "a" value isn't a u64
    try testing.expectError(error.InvalidNumber, parse(T1, &TokenStream.init(str), options_first));
    try testing.expectError(error.InvalidNumber, parse(T1, &TokenStream.init(str), options_last));

    const T2 = struct { a: f64 };
    try testing.expectEqual(T2{ .a = 1.0 }, try parse(T2, &TokenStream.init(str), options_first));
    try testing.expectEqual(T2{ .a = 0.25 }, try parse(T2, &TokenStream.init(str), options_last));

    const T3 = struct { comptime a: f64 = 1.0 };
    // .UseFirst should succeed because second "a" value is unconditionally ignored (even though != 1.0)
    const t3 = T3{ .a = 1.0 };
    try testing.expectEqual(t3, try parse(T3, &TokenStream.init(str), options_first));
    // .UseLast should fail because second "a" value is 0.25 which is not equal to default value of 1.0
    try testing.expectError(error.UnexpectedValue, parse(T3, &TokenStream.init(str), options_last));
}

test "parse into struct ignoring unknown fields" {
    const T = struct {
        int: i64,
        language: []const u8,
    };

    const ops = ParseOptions{
        .allocator = testing.allocator,
        .ignore_unknown_fields = true,
    };

    const r = try parse(T, &std.json.TokenStream.init(
        \\{
        \\  "int": 420,
        \\  "float": 3.14,
        \\  "with\\escape": true,
        \\  "with\u0105unicode\ud83d\ude02": false,
        \\  "optional": null,
        \\  "static_array": [66.6, 420.420, 69.69],
        \\  "dynamic_array": [66.6, 420.420, 69.69],
        \\  "complex": {
        \\    "nested": "zig"
        \\  },
        \\  "veryComplex": [
        \\    {
        \\      "foo": "zig"
        \\    }, {
        \\      "foo": "rocks"
        \\    }
        \\  ],
        \\  "a_union": 100000,
        \\  "language": "zig"
        \\}
    ), ops);
    defer parseFree(T, r, ops);

    try testing.expectEqual(@as(i64, 420), r.int);
    try testing.expectEqualSlices(u8, "zig", r.language);
}

const ParseIntoRecursiveUnionDefinitionValue = union(enum) {
    integer: i64,
    array: []const ParseIntoRecursiveUnionDefinitionValue,
};

test "parse into recursive union definition" {
    const T = struct {
        values: ParseIntoRecursiveUnionDefinitionValue,
    };
    const ops = ParseOptions{ .allocator = testing.allocator };

    const r = try parse(T, &std.json.TokenStream.init("{\"values\":[58]}"), ops);
    defer parseFree(T, r, ops);

    try testing.expectEqual(@as(i64, 58), r.values.array[0].integer);
}

const ParseIntoDoubleRecursiveUnionValueFirst = union(enum) {
    integer: i64,
    array: []const ParseIntoDoubleRecursiveUnionValueSecond,
};

const ParseIntoDoubleRecursiveUnionValueSecond = union(enum) {
    boolean: bool,
    array: []const ParseIntoDoubleRecursiveUnionValueFirst,
};

test "parse into double recursive union definition" {
    const T = struct {
        values: ParseIntoDoubleRecursiveUnionValueFirst,
    };
    const ops = ParseOptions{ .allocator = testing.allocator };

    const r = try parse(T, &std.json.TokenStream.init("{\"values\":[[58]]}"), ops);
    defer parseFree(T, r, ops);

    try testing.expectEqual(@as(i64, 58), r.values.array[0].array[0].integer);
}

/// A non-stream JSON parser which constructs a tree of Value's.
pub const Parser = struct {
    allocator: *Allocator,
    state: State,
    copy_strings: bool,
    // Stores parent nodes and un-combined Values.
    stack: Array,

    const State = enum {
        ObjectKey,
        ObjectValue,
        ArrayValue,
        Simple,
    };

    pub fn init(allocator: *Allocator, copy_strings: bool) Parser {
        return Parser{
            .allocator = allocator,
            .state = .Simple,
            .copy_strings = copy_strings,
            .stack = Array.init(allocator),
        };
    }

    pub fn deinit(p: *Parser) void {
        p.stack.deinit();
    }

    pub fn reset(p: *Parser) void {
        p.state = .Simple;
        p.stack.shrinkRetainingCapacity(0);
    }

    pub fn parse(p: *Parser, input: []const u8) !ValueTree {
        var s = TokenStream.init(input);

        var arena = ArenaAllocator.init(p.allocator);
        errdefer arena.deinit();

        while (try s.next()) |token| {
            try p.transition(&arena.allocator, input, s.i - 1, token);
        }

        debug.assert(p.stack.items.len == 1);

        return ValueTree{
            .arena = arena,
            .root = p.stack.items[0],
        };
    }

    // Even though p.allocator exists, we take an explicit allocator so that allocation state
    // can be cleaned up on error correctly during a `parse` on call.
    fn transition(p: *Parser, allocator: *Allocator, input: []const u8, i: usize, token: Token) !void {
        switch (p.state) {
            .ObjectKey => switch (token) {
                .ObjectEnd => {
                    if (p.stack.items.len == 1) {
                        return;
                    }

                    var value = p.stack.pop();
                    try p.pushToParent(&value);
                },
                .String => |s| {
                    try p.stack.append(try p.parseString(allocator, s, input, i));
                    p.state = .ObjectValue;
                },
                else => {
                    // The streaming parser would return an error eventually.
                    // To prevent invalid state we return an error now.
                    // TODO make the streaming parser return an error as soon as it encounters an invalid object key
                    return error.InvalidLiteral;
                },
            },
            .ObjectValue => {
                var object = &p.stack.items[p.stack.items.len - 2].Object;
                var key = p.stack.items[p.stack.items.len - 1].String;

                switch (token) {
                    .ObjectBegin => {
                        try p.stack.append(Value{ .Object = ObjectMap.init(allocator) });
                        p.state = .ObjectKey;
                    },
                    .ArrayBegin => {
                        try p.stack.append(Value{ .Array = Array.init(allocator) });
                        p.state = .ArrayValue;
                    },
                    .String => |s| {
                        try object.put(key, try p.parseString(allocator, s, input, i));
                        _ = p.stack.pop();
                        p.state = .ObjectKey;
                    },
                    .Number => |n| {
                        try object.put(key, try p.parseNumber(n, input, i));
                        _ = p.stack.pop();
                        p.state = .ObjectKey;
                    },
                    .True => {
                        try object.put(key, Value{ .Bool = true });
                        _ = p.stack.pop();
                        p.state = .ObjectKey;
                    },
                    .False => {
                        try object.put(key, Value{ .Bool = false });
                        _ = p.stack.pop();
                        p.state = .ObjectKey;
                    },
                    .Null => {
                        try object.put(key, Value.Null);
                        _ = p.stack.pop();
                        p.state = .ObjectKey;
                    },
                    .ObjectEnd, .ArrayEnd => {
                        unreachable;
                    },
                }
            },
            .ArrayValue => {
                var array = &p.stack.items[p.stack.items.len - 1].Array;

                switch (token) {
                    .ArrayEnd => {
                        if (p.stack.items.len == 1) {
                            return;
                        }

                        var value = p.stack.pop();
                        try p.pushToParent(&value);
                    },
                    .ObjectBegin => {
                        try p.stack.append(Value{ .Object = ObjectMap.init(allocator) });
                        p.state = .ObjectKey;
                    },
                    .ArrayBegin => {
                        try p.stack.append(Value{ .Array = Array.init(allocator) });
                        p.state = .ArrayValue;
                    },
                    .String => |s| {
                        try array.append(try p.parseString(allocator, s, input, i));
                    },
                    .Number => |n| {
                        try array.append(try p.parseNumber(n, input, i));
                    },
                    .True => {
                        try array.append(Value{ .Bool = true });
                    },
                    .False => {
                        try array.append(Value{ .Bool = false });
                    },
                    .Null => {
                        try array.append(Value.Null);
                    },
                    .ObjectEnd => {
                        unreachable;
                    },
                }
            },
            .Simple => switch (token) {
                .ObjectBegin => {
                    try p.stack.append(Value{ .Object = ObjectMap.init(allocator) });
                    p.state = .ObjectKey;
                },
                .ArrayBegin => {
                    try p.stack.append(Value{ .Array = Array.init(allocator) });
                    p.state = .ArrayValue;
                },
                .String => |s| {
                    try p.stack.append(try p.parseString(allocator, s, input, i));
                },
                .Number => |n| {
                    try p.stack.append(try p.parseNumber(n, input, i));
                },
                .True => {
                    try p.stack.append(Value{ .Bool = true });
                },
                .False => {
                    try p.stack.append(Value{ .Bool = false });
                },
                .Null => {
                    try p.stack.append(Value.Null);
                },
                .ObjectEnd, .ArrayEnd => {
                    unreachable;
                },
            },
        }
    }

    fn pushToParent(p: *Parser, value: *const Value) !void {
        switch (p.stack.items[p.stack.items.len - 1]) {
            // Object Parent -> [ ..., object, <key>, value ]
            Value.String => |key| {
                _ = p.stack.pop();

                var object = &p.stack.items[p.stack.items.len - 1].Object;
                try object.put(key, value.*);
                p.state = .ObjectKey;
            },
            // Array Parent -> [ ..., <array>, value ]
            Value.Array => |*array| {
                try array.append(value.*);
                p.state = .ArrayValue;
            },
            else => {
                unreachable;
            },
        }
    }

    fn parseString(p: *Parser, allocator: *Allocator, s: std.meta.TagPayload(Token, Token.String), input: []const u8, i: usize) !Value {
        const slice = s.slice(input, i);
        switch (s.escapes) {
            .None => return Value{ .String = if (p.copy_strings) try allocator.dupe(u8, slice) else slice },
            .Some => {
                const output = try allocator.alloc(u8, s.decodedLength());
                errdefer allocator.free(output);
                try unescapeValidString(output, slice);
                return Value{ .String = output };
            },
        }
    }

    fn parseNumber(p: *Parser, n: std.meta.TagPayload(Token, Token.Number), input: []const u8, i: usize) !Value {
        _ = p;
        return if (n.is_integer)
            Value{
                .Integer = std.fmt.parseInt(i64, n.slice(input, i), 10) catch |e| switch (e) {
                    error.Overflow => return Value{ .NumberString = n.slice(input, i) },
                    error.InvalidCharacter => |err| return err,
                },
            }
        else
            Value{ .Float = try std.fmt.parseFloat(f64, n.slice(input, i)) };
    }
};

pub const UnescapeValidStringError = error{InvalidUnicodeHexSymbol};

/// Unescape a JSON string
/// Only to be used on strings already validated by the parser
/// (note the unreachable statements and lack of bounds checking)
pub fn unescapeValidString(output: []u8, input: []const u8) UnescapeValidStringError!void {
    var inIndex: usize = 0;
    var outIndex: usize = 0;

    while (inIndex < input.len) {
        if (input[inIndex] != '\\') {
            // not an escape sequence
            output[outIndex] = input[inIndex];
            inIndex += 1;
            outIndex += 1;
        } else if (input[inIndex + 1] != 'u') {
            // a simple escape sequence
            output[outIndex] = @as(u8, switch (input[inIndex + 1]) {
                '\\' => '\\',
                '/' => '/',
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                'f' => 12,
                'b' => 8,
                '"' => '"',
                else => unreachable,
            });
            inIndex += 2;
            outIndex += 1;
        } else {
            // a unicode escape sequence
            const firstCodeUnit = std.fmt.parseInt(u16, input[inIndex + 2 .. inIndex + 6], 16) catch unreachable;

            // guess optimistically that it's not a surrogate pair
            if (std.unicode.utf8Encode(firstCodeUnit, output[outIndex..])) |byteCount| {
                outIndex += byteCount;
                inIndex += 6;
            } else |err| {
                // it might be a surrogate pair
                if (err != error.Utf8CannotEncodeSurrogateHalf) {
                    return error.InvalidUnicodeHexSymbol;
                }
                // check if a second code unit is present
                if (inIndex + 7 >= input.len or input[inIndex + 6] != '\\' or input[inIndex + 7] != 'u') {
                    return error.InvalidUnicodeHexSymbol;
                }

                const secondCodeUnit = std.fmt.parseInt(u16, input[inIndex + 8 .. inIndex + 12], 16) catch unreachable;

                const utf16le_seq = [2]u16{
                    mem.nativeToLittle(u16, firstCodeUnit),
                    mem.nativeToLittle(u16, secondCodeUnit),
                };
                if (std.unicode.utf16leToUtf8(output[outIndex..], &utf16le_seq)) |byteCount| {
                    outIndex += byteCount;
                    inIndex += 12;
                } else |_| {
                    return error.InvalidUnicodeHexSymbol;
                }
            }
        }
    }
    assert(outIndex == output.len);
}

test "json.parser.dynamic" {
    var p = Parser.init(testing.allocator, false);
    defer p.deinit();

    const s =
        \\{
        \\  "Image": {
        \\      "Width":  800,
        \\      "Height": 600,
        \\      "Title":  "View from 15th Floor",
        \\      "Thumbnail": {
        \\          "Url":    "http://www.example.com/image/481989943",
        \\          "Height": 125,
        \\          "Width":  100
        \\      },
        \\      "Animated" : false,
        \\      "IDs": [116, 943, 234, 38793],
        \\      "ArrayOfObject": [{"n": "m"}],
        \\      "double": 1.3412,
        \\      "LargeInt": 18446744073709551615
        \\    }
        \\}
    ;

    var tree = try p.parse(s);
    defer tree.deinit();

    var root = tree.root;

    var image = root.Object.get("Image").?;

    const width = image.Object.get("Width").?;
    try testing.expect(width.Integer == 800);

    const height = image.Object.get("Height").?;
    try testing.expect(height.Integer == 600);

    const title = image.Object.get("Title").?;
    try testing.expect(mem.eql(u8, title.String, "View from 15th Floor"));

    const animated = image.Object.get("Animated").?;
    try testing.expect(animated.Bool == false);

    const array_of_object = image.Object.get("ArrayOfObject").?;
    try testing.expect(array_of_object.Array.items.len == 1);

    const obj0 = array_of_object.Array.items[0].Object.get("n").?;
    try testing.expect(mem.eql(u8, obj0.String, "m"));

    const double = image.Object.get("double").?;
    try testing.expect(double.Float == 1.3412);

    const large_int = image.Object.get("LargeInt").?;
    try testing.expect(mem.eql(u8, large_int.NumberString, "18446744073709551615"));
}

test "import more json tests" {
    _ = @import("json/test.zig");
    _ = @import("json/write_stream.zig");
}

test "write json then parse it" {
    var out_buffer: [1000]u8 = undefined;

    var fixed_buffer_stream = std.io.fixedBufferStream(&out_buffer);
    const out_stream = fixed_buffer_stream.writer();
    var jw = writeStream(out_stream, 4);

    try jw.beginObject();

    try jw.objectField("f");
    try jw.emitBool(false);

    try jw.objectField("t");
    try jw.emitBool(true);

    try jw.objectField("int");
    try jw.emitNumber(1234);

    try jw.objectField("array");
    try jw.beginArray();

    try jw.arrayElem();
    try jw.emitNull();

    try jw.arrayElem();
    try jw.emitNumber(12.34);

    try jw.endArray();

    try jw.objectField("str");
    try jw.emitString("hello");

    try jw.endObject();

    var parser = Parser.init(testing.allocator, false);
    defer parser.deinit();
    var tree = try parser.parse(fixed_buffer_stream.getWritten());
    defer tree.deinit();

    try testing.expect(tree.root.Object.get("f").?.Bool == false);
    try testing.expect(tree.root.Object.get("t").?.Bool == true);
    try testing.expect(tree.root.Object.get("int").?.Integer == 1234);
    try testing.expect(tree.root.Object.get("array").?.Array.items[0].Null == {});
    try testing.expect(tree.root.Object.get("array").?.Array.items[1].Float == 12.34);
    try testing.expect(mem.eql(u8, tree.root.Object.get("str").?.String, "hello"));
}

fn test_parse(arena_allocator: *std.mem.Allocator, json_str: []const u8) !Value {
    var p = Parser.init(arena_allocator, false);
    return (try p.parse(json_str)).root;
}

test "parsing empty string gives appropriate error" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    try testing.expectError(error.UnexpectedEndOfJson, test_parse(&arena_allocator.allocator, ""));
}

test "integer after float has proper type" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const json = try test_parse(&arena_allocator.allocator,
        \\{
        \\  "float": 3.14,
        \\  "ints": [1, 2, 3]
        \\}
    );
    try std.testing.expect(json.Object.get("ints").?.Array.items[0] == .Integer);
}

test "parse exponential into int" {
    const T = struct { int: i64 };
    const r = try parse(T, &TokenStream.init("{ \"int\": 4.2e2 }"), ParseOptions{});
    try testing.expectEqual(@as(i64, 420), r.int);
    try testing.expectError(error.InvalidNumber, parse(T, &TokenStream.init("{ \"int\": 0.042e2 }"), ParseOptions{}));
    try testing.expectError(error.Overflow, parse(T, &TokenStream.init("{ \"int\": 18446744073709551616.0 }"), ParseOptions{}));
}

test "escaped characters" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const input =
        \\{
        \\  "backslash": "\\",
        \\  "forwardslash": "\/",
        \\  "newline": "\n",
        \\  "carriagereturn": "\r",
        \\  "tab": "\t",
        \\  "formfeed": "\f",
        \\  "backspace": "\b",
        \\  "doublequote": "\"",
        \\  "unicode": "\u0105",
        \\  "surrogatepair": "\ud83d\ude02"
        \\}
    ;

    const obj = (try test_parse(&arena_allocator.allocator, input)).Object;

    try testing.expectEqualSlices(u8, obj.get("backslash").?.String, "\\");
    try testing.expectEqualSlices(u8, obj.get("forwardslash").?.String, "/");
    try testing.expectEqualSlices(u8, obj.get("newline").?.String, "\n");
    try testing.expectEqualSlices(u8, obj.get("carriagereturn").?.String, "\r");
    try testing.expectEqualSlices(u8, obj.get("tab").?.String, "\t");
    try testing.expectEqualSlices(u8, obj.get("formfeed").?.String, "\x0C");
    try testing.expectEqualSlices(u8, obj.get("backspace").?.String, "\x08");
    try testing.expectEqualSlices(u8, obj.get("doublequote").?.String, "\"");
    try testing.expectEqualSlices(u8, obj.get("unicode").?.String, "ą");
    try testing.expectEqualSlices(u8, obj.get("surrogatepair").?.String, "😂");
}

test "string copy option" {
    const input =
        \\{
        \\  "noescape": "aą😂",
        \\  "simple": "\\\/\n\r\t\f\b\"",
        \\  "unicode": "\u0105",
        \\  "surrogatepair": "\ud83d\ude02"
        \\}
    ;

    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();

    const tree_nocopy = try Parser.init(&arena_allocator.allocator, false).parse(input);
    const obj_nocopy = tree_nocopy.root.Object;

    const tree_copy = try Parser.init(&arena_allocator.allocator, true).parse(input);
    const obj_copy = tree_copy.root.Object;

    for ([_][]const u8{ "noescape", "simple", "unicode", "surrogatepair" }) |field_name| {
        try testing.expectEqualSlices(u8, obj_nocopy.get(field_name).?.String, obj_copy.get(field_name).?.String);
    }

    const nocopy_addr = &obj_nocopy.get("noescape").?.String[0];
    const copy_addr = &obj_copy.get("noescape").?.String[0];

    var found_nocopy = false;
    for (input) |_, index| {
        try testing.expect(copy_addr != &input[index]);
        if (nocopy_addr == &input[index]) {
            found_nocopy = true;
        }
    }
    try testing.expect(found_nocopy);
}

pub const StringifyOptions = struct {
    pub const Whitespace = struct {
        /// How many indentation levels deep are we?
        indent_level: usize = 0,

        /// What character(s) should be used for indentation?
        indent: union(enum) {
            Space: u8,
            Tab: void,
        } = .{ .Space = 4 },

        /// After a colon, should whitespace be inserted?
        separator: bool = true,

        pub fn outputIndent(
            whitespace: @This(),
            out_stream: anytype,
        ) @TypeOf(out_stream).Error!void {
            var char: u8 = undefined;
            var n_chars: usize = undefined;
            switch (whitespace.indent) {
                .Space => |n_spaces| {
                    char = ' ';
                    n_chars = n_spaces;
                },
                .Tab => {
                    char = '\t';
                    n_chars = 1;
                },
            }
            n_chars *= whitespace.indent_level;
            try out_stream.writeByteNTimes(char, n_chars);
        }
    };

    /// Controls the whitespace emitted
    whitespace: ?Whitespace = null,

    string: StringOptions = StringOptions{ .String = .{} },

    /// Should []u8 be serialised as a string? or an array?
    pub const StringOptions = union(enum) {
        Array,
        String: StringOutputOptions,

        /// String output options
        const StringOutputOptions = struct {
            /// Should '/' be escaped in strings?
            escape_solidus: bool = false,

            /// Should unicode characters be escaped in strings?
            escape_unicode: bool = false,
        };
    };
};

fn outputUnicodeEscape(
    codepoint: u21,
    out_stream: anytype,
) !void {
    if (codepoint <= 0xFFFF) {
        // If the character is in the Basic Multilingual Plane (U+0000 through U+FFFF),
        // then it may be represented as a six-character sequence: a reverse solidus, followed
        // by the lowercase letter u, followed by four hexadecimal digits that encode the character's code point.
        try out_stream.writeAll("\\u");
        try std.fmt.formatIntValue(codepoint, "x", std.fmt.FormatOptions{ .width = 4, .fill = '0' }, out_stream);
    } else {
        assert(codepoint <= 0x10FFFF);
        // To escape an extended character that is not in the Basic Multilingual Plane,
        // the character is represented as a 12-character sequence, encoding the UTF-16 surrogate pair.
        const high = @intCast(u16, (codepoint - 0x10000) >> 10) + 0xD800;
        const low = @intCast(u16, codepoint & 0x3FF) + 0xDC00;
        try out_stream.writeAll("\\u");
        try std.fmt.formatIntValue(high, "x", std.fmt.FormatOptions{ .width = 4, .fill = '0' }, out_stream);
        try out_stream.writeAll("\\u");
        try std.fmt.formatIntValue(low, "x", std.fmt.FormatOptions{ .width = 4, .fill = '0' }, out_stream);
    }
}

pub fn stringify(
    value: anytype,
    options: StringifyOptions,
    out_stream: anytype,
) @TypeOf(out_stream).Error!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .Float, .ComptimeFloat => {
            return std.fmt.formatFloatScientific(value, std.fmt.FormatOptions{}, out_stream);
        },
        .Int, .ComptimeInt => {
            return std.fmt.formatIntValue(value, "", std.fmt.FormatOptions{}, out_stream);
        },
        .Bool => {
            return out_stream.writeAll(if (value) "true" else "false");
        },
        .Null => {
            return out_stream.writeAll("null");
        },
        .Optional => {
            if (value) |payload| {
                return try stringify(payload, options, out_stream);
            } else {
                return try stringify(null, options, out_stream);
            }
        },
        .Enum => {
            if (comptime std.meta.trait.hasFn("jsonStringify")(T)) {
                return value.jsonStringify(options, out_stream);
            }

            @compileError("Unable to stringify enum '" ++ @typeName(T) ++ "'");
        },
        .Union => {
            if (comptime std.meta.trait.hasFn("jsonStringify")(T)) {
                return value.jsonStringify(options, out_stream);
            }

            const info = @typeInfo(T).Union;
            if (info.tag_type) |UnionTagType| {
                inline for (info.fields) |u_field| {
                    if (value == @field(UnionTagType, u_field.name)) {
                        return try stringify(@field(value, u_field.name), options, out_stream);
                    }
                }
            } else {
                @compileError("Unable to stringify untagged union '" ++ @typeName(T) ++ "'");
            }
        },
        .Struct => |S| {
            if (comptime std.meta.trait.hasFn("jsonStringify")(T)) {
                return value.jsonStringify(options, out_stream);
            }

            try out_stream.writeByte('{');
            comptime var field_output = false;
            var child_options = options;
            if (child_options.whitespace) |*child_whitespace| {
                child_whitespace.indent_level += 1;
            }
            inline for (S.fields) |Field| {
                // don't include void fields
                if (Field.field_type == void) continue;

                if (!field_output) {
                    field_output = true;
                } else {
                    try out_stream.writeByte(',');
                }
                if (child_options.whitespace) |child_whitespace| {
                    try out_stream.writeByte('\n');
                    try child_whitespace.outputIndent(out_stream);
                }
                try stringify(Field.name, options, out_stream);
                try out_stream.writeByte(':');
                if (child_options.whitespace) |child_whitespace| {
                    if (child_whitespace.separator) {
                        try out_stream.writeByte(' ');
                    }
                }
                try stringify(@field(value, Field.name), child_options, out_stream);
            }
            if (field_output) {
                if (options.whitespace) |whitespace| {
                    try out_stream.writeByte('\n');
                    try whitespace.outputIndent(out_stream);
                }
            }
            try out_stream.writeByte('}');
            return;
        },
        .ErrorSet => return stringify(@as([]const u8, @errorName(value)), options, out_stream),
        .Pointer => |ptr_info| switch (ptr_info.size) {
            .One => switch (@typeInfo(ptr_info.child)) {
                .Array => {
                    const Slice = []const std.meta.Elem(ptr_info.child);
                    return stringify(@as(Slice, value), options, out_stream);
                },
                else => {
                    // TODO: avoid loops?
                    return stringify(value.*, options, out_stream);
                },
            },
            // TODO: .Many when there is a sentinel (waiting for https://github.com/ziglang/zig/pull/3972)
            .Slice => {
                if (ptr_info.child == u8 and options.string == .String and std.unicode.utf8ValidateSlice(value)) {
                    try out_stream.writeByte('\"');
                    var i: usize = 0;
                    while (i < value.len) : (i += 1) {
                        switch (value[i]) {
                            // normal ascii character
                            0x20...0x21, 0x23...0x2E, 0x30...0x5B, 0x5D...0x7F => |c| try out_stream.writeByte(c),
                            // only 2 characters that *must* be escaped
                            '\\' => try out_stream.writeAll("\\\\"),
                            '\"' => try out_stream.writeAll("\\\""),
                            // solidus is optional to escape
                            '/' => {
                                if (options.string.String.escape_solidus) {
                                    try out_stream.writeAll("\\/");
                                } else {
                                    try out_stream.writeByte('/');
                                }
                            },
                            // control characters with short escapes
                            // TODO: option to switch between unicode and 'short' forms?
                            0x8 => try out_stream.writeAll("\\b"),
                            0xC => try out_stream.writeAll("\\f"),
                            '\n' => try out_stream.writeAll("\\n"),
                            '\r' => try out_stream.writeAll("\\r"),
                            '\t' => try out_stream.writeAll("\\t"),
                            else => {
                                const ulen = std.unicode.utf8ByteSequenceLength(value[i]) catch unreachable;
                                // control characters (only things left with 1 byte length) should always be printed as unicode escapes
                                if (ulen == 1 or options.string.String.escape_unicode) {
                                    const codepoint = std.unicode.utf8Decode(value[i .. i + ulen]) catch unreachable;
                                    try outputUnicodeEscape(codepoint, out_stream);
                                } else {
                                    try out_stream.writeAll(value[i .. i + ulen]);
                                }
                                i += ulen - 1;
                            },
                        }
                    }
                    try out_stream.writeByte('\"');
                    return;
                }

                try out_stream.writeByte('[');
                var child_options = options;
                if (child_options.whitespace) |*whitespace| {
                    whitespace.indent_level += 1;
                }
                for (value) |x, i| {
                    if (i != 0) {
                        try out_stream.writeByte(',');
                    }
                    if (child_options.whitespace) |child_whitespace| {
                        try out_stream.writeByte('\n');
                        try child_whitespace.outputIndent(out_stream);
                    }
                    try stringify(x, child_options, out_stream);
                }
                if (value.len != 0) {
                    if (options.whitespace) |whitespace| {
                        try out_stream.writeByte('\n');
                        try whitespace.outputIndent(out_stream);
                    }
                }
                try out_stream.writeByte(']');
                return;
            },
            else => @compileError("Unable to stringify type '" ++ @typeName(T) ++ "'"),
        },
        .Array => return stringify(&value, options, out_stream),
        .Vector => |info| {
            const array: [info.len]info.child = value;
            return stringify(&array, options, out_stream);
        },
        else => @compileError("Unable to stringify type '" ++ @typeName(T) ++ "'"),
    }
    unreachable;
}

fn teststringify(expected: []const u8, value: anytype, options: StringifyOptions) !void {
    const ValidationWriter = struct {
        const Self = @This();
        pub const Writer = std.io.Writer(*Self, Error, write);
        pub const Error = error{
            TooMuchData,
            DifferentData,
        };

        expected_remaining: []const u8,

        fn init(exp: []const u8) Self {
            return .{ .expected_remaining = exp };
        }

        pub fn writer(self: *Self) Writer {
            return .{ .context = self };
        }

        fn write(self: *Self, bytes: []const u8) Error!usize {
            if (self.expected_remaining.len < bytes.len) {
                std.debug.warn(
                    \\====== expected this output: =========
                    \\{s}
                    \\======== instead found this: =========
                    \\{s}
                    \\======================================
                , .{
                    self.expected_remaining,
                    bytes,
                });
                return error.TooMuchData;
            }
            if (!mem.eql(u8, self.expected_remaining[0..bytes.len], bytes)) {
                std.debug.warn(
                    \\====== expected this output: =========
                    \\{s}
                    \\======== instead found this: =========
                    \\{s}
                    \\======================================
                , .{
                    self.expected_remaining[0..bytes.len],
                    bytes,
                });
                return error.DifferentData;
            }
            self.expected_remaining = self.expected_remaining[bytes.len..];
            return bytes.len;
        }
    };

    var vos = ValidationWriter.init(expected);
    try stringify(value, options, vos.writer());
    if (vos.expected_remaining.len > 0) return error.NotEnoughData;
}

test "stringify basic types" {
    try teststringify("false", false, StringifyOptions{});
    try teststringify("true", true, StringifyOptions{});
    try teststringify("null", @as(?u8, null), StringifyOptions{});
    try teststringify("null", @as(?*u32, null), StringifyOptions{});
    try teststringify("42", 42, StringifyOptions{});
    try teststringify("4.2e+01", 42.0, StringifyOptions{});
    try teststringify("42", @as(u8, 42), StringifyOptions{});
    try teststringify("42", @as(u128, 42), StringifyOptions{});
    try teststringify("4.2e+01", @as(f32, 42), StringifyOptions{});
    try teststringify("4.2e+01", @as(f64, 42), StringifyOptions{});
    try teststringify("\"ItBroke\"", @as(anyerror, error.ItBroke), StringifyOptions{});
}

test "stringify string" {
    try teststringify("\"hello\"", "hello", StringifyOptions{});
    try teststringify("\"with\\nescapes\\r\"", "with\nescapes\r", StringifyOptions{});
    try teststringify("\"with\\nescapes\\r\"", "with\nescapes\r", StringifyOptions{ .string = .{ .String = .{ .escape_unicode = true } } });
    try teststringify("\"with unicode\\u0001\"", "with unicode\u{1}", StringifyOptions{});
    try teststringify("\"with unicode\\u0001\"", "with unicode\u{1}", StringifyOptions{ .string = .{ .String = .{ .escape_unicode = true } } });
    try teststringify("\"with unicode\u{80}\"", "with unicode\u{80}", StringifyOptions{});
    try teststringify("\"with unicode\\u0080\"", "with unicode\u{80}", StringifyOptions{ .string = .{ .String = .{ .escape_unicode = true } } });
    try teststringify("\"with unicode\u{FF}\"", "with unicode\u{FF}", StringifyOptions{});
    try teststringify("\"with unicode\\u00ff\"", "with unicode\u{FF}", StringifyOptions{ .string = .{ .String = .{ .escape_unicode = true } } });
    try teststringify("\"with unicode\u{100}\"", "with unicode\u{100}", StringifyOptions{});
    try teststringify("\"with unicode\\u0100\"", "with unicode\u{100}", StringifyOptions{ .string = .{ .String = .{ .escape_unicode = true } } });
    try teststringify("\"with unicode\u{800}\"", "with unicode\u{800}", StringifyOptions{});
    try teststringify("\"with unicode\\u0800\"", "with unicode\u{800}", StringifyOptions{ .string = .{ .String = .{ .escape_unicode = true } } });
    try teststringify("\"with unicode\u{8000}\"", "with unicode\u{8000}", StringifyOptions{});
    try teststringify("\"with unicode\\u8000\"", "with unicode\u{8000}", StringifyOptions{ .string = .{ .String = .{ .escape_unicode = true } } });
    try teststringify("\"with unicode\u{D799}\"", "with unicode\u{D799}", StringifyOptions{});
    try teststringify("\"with unicode\\ud799\"", "with unicode\u{D799}", StringifyOptions{ .string = .{ .String = .{ .escape_unicode = true } } });
    try teststringify("\"with unicode\u{10000}\"", "with unicode\u{10000}", StringifyOptions{});
    try teststringify("\"with unicode\\ud800\\udc00\"", "with unicode\u{10000}", StringifyOptions{ .string = .{ .String = .{ .escape_unicode = true } } });
    try teststringify("\"with unicode\u{10FFFF}\"", "with unicode\u{10FFFF}", StringifyOptions{});
    try teststringify("\"with unicode\\udbff\\udfff\"", "with unicode\u{10FFFF}", StringifyOptions{ .string = .{ .String = .{ .escape_unicode = true } } });
    try teststringify("\"/\"", "/", StringifyOptions{});
    try teststringify("\"\\/\"", "/", StringifyOptions{ .string = .{ .String = .{ .escape_solidus = true } } });
}

test "stringify tagged unions" {
    try teststringify("42", union(enum) {
        Foo: u32,
        Bar: bool,
    }{ .Foo = 42 }, StringifyOptions{});
}

test "stringify struct" {
    try teststringify("{\"foo\":42}", struct {
        foo: u32,
    }{ .foo = 42 }, StringifyOptions{});
}

test "stringify struct with indentation" {
    try teststringify(
        \\{
        \\    "foo": 42,
        \\    "bar": [
        \\        1,
        \\        2,
        \\        3
        \\    ]
        \\}
    ,
        struct {
            foo: u32,
            bar: [3]u32,
        }{
            .foo = 42,
            .bar = .{ 1, 2, 3 },
        },
        StringifyOptions{
            .whitespace = .{},
        },
    );
    try teststringify(
        "{\n\t\"foo\":42,\n\t\"bar\":[\n\t\t1,\n\t\t2,\n\t\t3\n\t]\n}",
        struct {
            foo: u32,
            bar: [3]u32,
        }{
            .foo = 42,
            .bar = .{ 1, 2, 3 },
        },
        StringifyOptions{
            .whitespace = .{
                .indent = .Tab,
                .separator = false,
            },
        },
    );
}

test "stringify struct with void field" {
    try teststringify("{\"foo\":42}", struct {
        foo: u32,
        bar: void = {},
    }{ .foo = 42 }, StringifyOptions{});
}

test "stringify array of structs" {
    const MyStruct = struct {
        foo: u32,
    };
    try teststringify("[{\"foo\":42},{\"foo\":100},{\"foo\":1000}]", [_]MyStruct{
        MyStruct{ .foo = 42 },
        MyStruct{ .foo = 100 },
        MyStruct{ .foo = 1000 },
    }, StringifyOptions{});
}

test "stringify struct with custom stringifier" {
    try teststringify("[\"something special\",42]", struct {
        foo: u32,
        const Self = @This();
        pub fn jsonStringify(
            value: Self,
            options: StringifyOptions,
            out_stream: anytype,
        ) !void {
            _ = value;
            try out_stream.writeAll("[\"something special\",");
            try stringify(42, options, out_stream);
            try out_stream.writeByte(']');
        }
    }{ .foo = 42 }, StringifyOptions{});
}

test "stringify vector" {
    try teststringify("[1,1]", @splat(2, @as(u32, 1)), StringifyOptions{});
}
