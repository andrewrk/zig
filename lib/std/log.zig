// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.

//! std.log is a standardized interface for logging which allows for the logging
//! of programs and libraries using this interface to be formatted and filtered
//! by the implementer of the root.log function.
//!
//! Each log message has an associated scope enum, which can be used to give
//! context to the logging. The logging functions in std.log implicitly use a
//! scope of .default.
//!
//! A logging namespace using a custom scope can be created using the
//! std.log.scoped function, passing the scope as an argument; the logging
//! functions in the resulting struct use the provided scope parameter.
//! For example, a library called 'libfoo' might use
//! `const log = std.log.scoped(.libfoo);` to use .libfoo as the scope of its
//! log messages.
//!
//! An example root.log might look something like this:
//!
//! ```
//! const std = @import("std");
//!
//! // Set the log level to warning
//! pub const log_level: std.log.Level = .warn;
//!
//! // Define root.log to override the std implementation
//! pub fn log(
//!     comptime level: std.log.Level,
//!     comptime scope: @TypeOf(.EnumLiteral),
//!     comptime format: []const u8,
//!     args: anytype,
//! ) void {
//!     // Ignore all non-critical logging from sources other than
//!     // .my_project, .nice_library and .default
//!     const scope_prefix = "(" ++ switch (scope) {
//!         .my_project, .nice_library, .default => @tagName(scope),
//!         else => if (@enumToInt(level) <= @enumToInt(std.log.Level.crit))
//!             @tagName(scope)
//!         else
//!             return,
//!     } ++ "): ";
//!
//!     const prefix = "[" ++ @tagName(level) ++ "] " ++ scope_prefix;
//!
//!     // Print the message to stderr, silently ignoring any errors
//!     const held = std.debug.getStderrMutex().acquire();
//!     defer held.release();
//!     const stderr = std.io.getStdErr().writer();
//!     nosuspend stderr.print(prefix ++ format ++ "\n", args) catch return;
//! }
//!
//! pub fn main() void {
//!     // Using the default scope:
//!     std.log.info("Just a simple informational log message", .{}); // Won't be printed as log_level is .warn
//!     std.log.warn("Flux capacitor is starting to overheat", .{});
//!
//!     // Using scoped logging:
//!     const my_project_log = std.log.scoped(.my_project);
//!     const nice_library_log = std.log.scoped(.nice_library);
//!     const verbose_lib_log = std.log.scoped(.verbose_lib);
//!
//!     my_project_log.info("Starting up", .{}); // Won't be printed as log_level is .warn
//!     nice_library_log.err("Something went very wrong, sorry", .{});
//!     verbose_lib_log.err("Added 1 + 1: {}", .{1 + 1}); // Won't be printed as it gets filtered out by our log function
//! }
//! ```
//! Which produces the following output:
//! ```
//! [warn] (default): Flux capacitor is starting to overheat
//! [err] (nice_library): Something went very wrong, sorry
//! ```

const std = @import("std.zig");
const builtin = std.builtin;
const root = @import("root");

pub const Level = enum {
    /// Emergency: a condition that cannot be handled, usually followed by a
    /// panic.
    emerg,
    /// Alert: a condition that should be corrected immediately (e.g. database
    /// corruption).
    alert,
    /// Critical: A bug has been detected or something has gone wrong and it
    /// will have an effect on the operation of the program.
    crit,
    /// Error: A bug has been detected or something has gone wrong but it is
    /// recoverable.
    err,
    /// Warning: it is uncertain if something has gone wrong or not, but the
    /// circumstances would be worth investigating.
    warn,
    /// Notice: non-error but significant conditions.
    notice,
    /// Informational: general messages about the state of the program.
    info,
    /// Debug: messages only useful for debugging.
    debug,
};

/// The default log level is based on build mode.
pub const default_level: Level = switch (builtin.mode) {
    .Debug => .debug,
    .ReleaseSafe => .notice,
    .ReleaseFast => .err,
    .ReleaseSmall => .err,
};

/// The current log level. This is set to root.log_level if present, otherwise
/// log.default_level.
pub const level: Level = if (@hasDecl(root, "log_level"))
    root.log_level
else
    default_level;

pub const ScopeLevel = struct {
    scope: @Type(.EnumLiteral),
    level: Level,
};

const scope_levels = if (@hasDecl(root, "scope_levels"))
    root.scope_levels
else
    [0]ScopeLevel{};

fn log(
    comptime message_level: Level,
    comptime scope: @Type(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const effective_log_level = blk: {
        inline for (scope_levels) |scope_level| {
            if (scope_level.scope == scope) break :blk scope_level.level;
        }
        break :blk level;
    };

    if (@enumToInt(message_level) <= @enumToInt(effective_log_level)) {
        if (@hasDecl(root, "log")) {
            if (@typeInfo(@TypeOf(root.log)) != .Fn)
                @compileError("Expected root.log to be a function");
            root.log(message_level, scope, format, args);
        } else if (std.Target.current.os.tag == .freestanding) {
            // On freestanding one must provide a log function; we do not have
            // any I/O configured.
            return;
        } else {
            const level_txt = switch (message_level) {
                .emerg => "emergency",
                .alert => "alert",
                .crit => "critical",
                .err => "error",
                .warn => "warning",
                .notice => "notice",
                .info => "info",
                .debug => "debug",
            };
            const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
            const stderr = std.io.getStdErr().writer();
            const held = std.debug.getStderrMutex().acquire();
            defer held.release();
            nosuspend stderr.print(level_txt ++ prefix2 ++ format ++ "\n", args) catch return;
        }
    }
}

/// Returns a scoped logging namespace that logs all messages using the scope
/// provided here.
pub fn scoped(comptime scope: @Type(.EnumLiteral)) type {
    return struct {
        /// Log an emergency message. This log level is intended to be used
        /// for conditions that cannot be handled and is usually followed by a panic.
        pub fn emerg(
            comptime format: []const u8,
            args: anytype,
        ) void {
            @setCold(true);
            log(.emerg, scope, format, args);
        }

        /// Log an alert message. This log level is intended to be used for
        /// conditions that should be corrected immediately (e.g. database corruption).
        pub fn alert(
            comptime format: []const u8,
            args: anytype,
        ) void {
            @setCold(true);
            log(.alert, scope, format, args);
        }

        /// Log a critical message. This log level is intended to be used
        /// when a bug has been detected or something has gone wrong and it will have
        /// an effect on the operation of the program.
        pub fn crit(
            comptime format: []const u8,
            args: anytype,
        ) void {
            @setCold(true);
            log(.crit, scope, format, args);
        }

        /// Log an error message. This log level is intended to be used when
        /// a bug has been detected or something has gone wrong but it is recoverable.
        pub fn err(
            comptime format: []const u8,
            args: anytype,
        ) void {
            @setCold(true);
            log(.err, scope, format, args);
        }

        /// Log a warning message. This log level is intended to be used if
        /// it is uncertain whether something has gone wrong or not, but the
        /// circumstances would be worth investigating.
        pub fn warn(
            comptime format: []const u8,
            args: anytype,
        ) void {
            log(.warn, scope, format, args);
        }

        /// Log a notice message. This log level is intended to be used for
        /// non-error but significant conditions.
        pub fn notice(
            comptime format: []const u8,
            args: anytype,
        ) void {
            log(.notice, scope, format, args);
        }

        /// Log an info message. This log level is intended to be used for
        /// general messages about the state of the program.
        pub fn info(
            comptime format: []const u8,
            args: anytype,
        ) void {
            log(.info, scope, format, args);
        }

        /// Log a debug message. This log level is intended to be used for
        /// messages which are only useful for debugging.
        pub fn debug(
            comptime format: []const u8,
            args: anytype,
        ) void {
            log(.debug, scope, format, args);
        }
    };
}

/// The default scoped logging namespace.
pub const default = scoped(.default);

/// This scope is ignored by `std.testing`'s log testing features. If used inside of a test, it is always printed.
pub const testing = scoped(.testing);

/// Log an emergency message using the default scope. This log level is
/// intended to be used for conditions that cannot be handled and is usually
/// followed by a panic.
pub const emerg = default.emerg;

/// Log an alert message using the default scope. This log level is intended to
/// be used for conditions that should be corrected immediately (e.g. database
/// corruption).
pub const alert = default.alert;

/// Log a critical message using the default scope. This log level is intended
/// to be used when a bug has been detected or something has gone wrong and it
/// will have an effect on the operation of the program.
pub const crit = default.crit;

/// Log an error message using the default scope. This log level is intended to
/// be used when a bug has been detected or something has gone wrong but it is
/// recoverable.
pub const err = default.err;

/// Log a warning message using the default scope. This log level is intended
/// to be used if it is uncertain whether something has gone wrong or not, but
/// the circumstances would be worth investigating.
pub const warn = default.warn;

/// Log a notice message using the default scope. This log level is intended to
/// be used for non-error but significant conditions.
pub const notice = default.notice;

/// Log an info message using the default scope. This log level is intended to
/// be used for general messages about the state of the program.
pub const info = default.info;

/// Log a debug message using the default scope. This log level is intended to
/// be used for messages which are only useful for debugging.
pub const debug = default.debug;
