// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.
const std = @import("std.zig");
const builtin = std.builtin;
const assert = std.debug.assert;
const testing = std.testing;
const os = std.os;
const math = std.math;
const is_windows = std.Target.current.os.tag == .windows;

pub const epoch = @import("time/epoch.zig");

/// Spurious wakeups are possible and no precision of timing is guaranteed.
pub fn sleep(nanoseconds: u64) void {
    // TODO: opting out of async sleeping?
    if (std.io.is_async)
        return std.event.Loop.instance.?.sleep(nanoseconds);

    if (is_windows) {
        const big_ms_from_ns = nanoseconds / ns_per_ms;
        const ms = math.cast(os.windows.DWORD, big_ms_from_ns) catch math.maxInt(os.windows.DWORD);
        os.windows.kernel32.Sleep(ms);
        return;
    }
    if (builtin.os.tag == .wasi) {
        const w = std.os.wasi;
        const userdata: w.userdata_t = 0x0123_45678;
        const clock = w.subscription_clock_t{
            .id = w.CLOCK_MONOTONIC,
            .timeout = nanoseconds,
            .precision = 0,
            .flags = 0,
        };
        const in = w.subscription_t{
            .userdata = userdata,
            .u = w.subscription_u_t{
                .tag = w.EVENTTYPE_CLOCK,
                .u = w.subscription_u_u_t{
                    .clock = clock,
                },
            },
        };

        var event: w.event_t = undefined;
        var nevents: usize = undefined;
        _ = w.poll_oneoff(&in, &event, 1, &nevents);
        return;
    }

    const s = nanoseconds / ns_per_s;
    const ns = nanoseconds % ns_per_s;
    std.os.nanosleep(s, ns);
}

/// Get a calendar timestamp, in seconds, relative to UTC 1970-01-01.
/// Precision of timing depends on the hardware and operating system.
/// The return value is signed because it is possible to have a date that is
/// before the epoch.
/// See `std.os.clock_gettime` for a POSIX timestamp.
pub fn timestamp() i64 {
    return @divFloor(milliTimestamp(), ms_per_s);
}

/// Get a calendar timestamp, in milliseconds, relative to UTC 1970-01-01.
/// Precision of timing depends on the hardware and operating system.
/// The return value is signed because it is possible to have a date that is
/// before the epoch.
/// See `std.os.clock_gettime` for a POSIX timestamp.
pub fn milliTimestamp() i64 {
    return @intCast(i64, @divFloor(nanoTimestamp(), ns_per_ms));
}

/// Get a calendar timestamp, in nanoseconds, relative to UTC 1970-01-01.
/// Precision of timing depends on the hardware and operating system.
/// On Windows this has a maximum granularity of 100 nanoseconds.
/// The return value is signed because it is possible to have a date that is
/// before the epoch.
/// See `std.os.clock_gettime` for a POSIX timestamp.
pub fn nanoTimestamp() i128 {
    if (is_windows) {
        // FileTime has a granularity of 100 nanoseconds and uses the NTFS/Windows epoch,
        // which is 1601-01-01.
        const epoch_adj = epoch.windows * (ns_per_s / 100);
        var ft: os.windows.FILETIME = undefined;
        os.windows.kernel32.GetSystemTimeAsFileTime(&ft);
        const ft64 = (@as(u64, ft.dwHighDateTime) << 32) | ft.dwLowDateTime;
        return @as(i128, @bitCast(i64, ft64) + epoch_adj) * 100;
    }
    if (builtin.os.tag == .wasi and !builtin.link_libc) {
        var ns: os.wasi.timestamp_t = undefined;
        const err = os.wasi.clock_time_get(os.wasi.CLOCK_REALTIME, 1, &ns);
        assert(err == os.wasi.ESUCCESS);
        return ns;
    }
    var ts: os.timespec = undefined;
    os.clock_gettime(os.CLOCK_REALTIME, &ts) catch |err| switch (err) {
        error.UnsupportedClock, error.Unexpected => return 0, // "Precision of timing depends on hardware and OS".
    };
    return (@as(i128, ts.tv_sec) * ns_per_s) + ts.tv_nsec;
}

// Divisions of a nanosecond.
pub const ns_per_us = 1000;
pub const ns_per_ms = 1000 * ns_per_us;
pub const ns_per_s = 1000 * ns_per_ms;
pub const ns_per_min = 60 * ns_per_s;
pub const ns_per_hour = 60 * ns_per_min;
pub const ns_per_day = 24 * ns_per_hour;
pub const ns_per_week = 7 * ns_per_day;

// Divisions of a microsecond.
pub const us_per_ms = 1000;
pub const us_per_s = 1000 * us_per_ms;
pub const us_per_min = 60 * us_per_s;
pub const us_per_hour = 60 * us_per_min;
pub const us_per_day = 24 * us_per_hour;
pub const us_per_week = 7 * us_per_day;

// Divisions of a millisecond.
pub const ms_per_s = 1000;
pub const ms_per_min = 60 * ms_per_s;
pub const ms_per_hour = 60 * ms_per_min;
pub const ms_per_day = 24 * ms_per_hour;
pub const ms_per_week = 7 * ms_per_day;

// Divisions of a second.
pub const s_per_min = 60;
pub const s_per_hour = s_per_min * 60;
pub const s_per_day = s_per_hour * 24;
pub const s_per_week = s_per_day * 7;

/// A monotonic high-performance timer.
/// Timer.start() must be called to initialize the struct, which captures
/// the counter frequency on windows and darwin, records the resolution,
/// and gives the user an opportunity to check for the existnece of
/// monotonic clocks without forcing them to check for error on each read.
/// .resolution is in nanoseconds on all platforms but .start_time's meaning
/// depends on the OS. On Windows and Darwin it is a hardware counter
/// value that requires calculation to convert to a meaninful unit.
pub const Timer = struct {
    ///if we used resolution's value when performing the
    ///  performance counter calc on windows/darwin, it would
    ///  be less precise
    frequency: switch (builtin.os.tag) {
        .windows => u64,
        .macos, .ios, .tvos, .watchos => os.darwin.mach_timebase_info_data,
        else => void,
    },
    resolution: u64,
    start_time: u64,

    pub const Error = error{TimerUnsupported};

    /// At some point we may change our minds on RAW, but for now we're
    /// sticking with posix standard MONOTONIC. For more information, see:
    /// https://github.com/ziglang/zig/pull/933
    const monotonic_clock_id = os.CLOCK_MONOTONIC;

    /// Initialize the timer structure.
    /// Can only fail when running in a hostile environment that intentionally injects
    /// error values into syscalls, such as using seccomp on Linux to intercept
    /// `clock_gettime`.
    pub fn start() Error!Timer {
        // This gives us an opportunity to grab the counter frequency in windows.
        // On Windows: QueryPerformanceCounter will succeed on anything >= XP/2000.
        // On Posix: CLOCK_MONOTONIC will only fail if the monotonic counter is not
        // supported, or if the timespec pointer is out of bounds, which should be
        // impossible here barring cosmic rays or other such occurrences of
        // incredibly bad luck.
        // On Darwin: This cannot fail, as far as I am able to tell.
        if (is_windows) {
            const freq = os.windows.QueryPerformanceFrequency();
            return Timer{
                .frequency = freq,
                .resolution = @divFloor(ns_per_s, freq),
                .start_time = os.windows.QueryPerformanceCounter(),
            };
        } else if (comptime std.Target.current.isDarwin()) {
            var freq: os.darwin.mach_timebase_info_data = undefined;
            os.darwin.mach_timebase_info(&freq);

            return Timer{
                .frequency = freq,
                .resolution = @divFloor(freq.numer, freq.denom),
                .start_time = os.darwin.mach_absolute_time(),
            };
        } else {
            // On Linux, seccomp can do arbitrary things to our ability to call
            // syscalls, including return any errno value it wants and
            // inconsistently throwing errors. Since we can't account for
            // abuses of seccomp in a reasonable way, we'll assume that if
            // seccomp is going to block us it will at least do so consistently
            var res: os.timespec = undefined;
            os.clock_getres(monotonic_clock_id, &res) catch return error.TimerUnsupported;

            var ts: os.timespec = undefined;
            os.clock_gettime(monotonic_clock_id, &ts) catch return error.TimerUnsupported;

            return Timer{
                .resolution = @intCast(u64, res.tv_sec) * ns_per_s + @intCast(u64, res.tv_nsec),
                .start_time = @intCast(u64, ts.tv_sec) * ns_per_s + @intCast(u64, ts.tv_nsec),
                .frequency = {},
            };
        }

        return self;
    }

    /// Reads the timer value since start or the last reset in nanoseconds
    pub fn read(self: Timer) u64 {
        var clock = clockNative() - self.start_time;
        return self.nativeDurationToNanos(clock);
    }

    /// Resets the timer value to 0/now.
    pub fn reset(self: *Timer) void {
        self.start_time = clockNative();
    }

    /// Returns the current value of the timer in nanoseconds, then resets it
    pub fn lap(self: *Timer) u64 {
        var now = clockNative();
        var lap_time = self.nativeDurationToNanos(now - self.start_time);
        self.start_time = now;
        return lap_time;
    }

    fn clockNative() u64 {
        if (is_windows) {
            return os.windows.QueryPerformanceCounter();
        }
        if (comptime std.Target.current.isDarwin()) {
            return os.darwin.mach_absolute_time();
        }
        var ts: os.timespec = undefined;
        os.clock_gettime(monotonic_clock_id, &ts) catch unreachable;
        return @intCast(u64, ts.tv_sec) * @as(u64, ns_per_s) + @intCast(u64, ts.tv_nsec);
    }

    fn nativeDurationToNanos(self: Timer, duration: u64) u64 {
        if (is_windows) {
            return safeMulDiv(duration, ns_per_s, self.frequency);
        }
        if (comptime std.Target.current.isDarwin()) {
            return safeMulDiv(duration, self.frequency.numer, self.frequency.denom);
        }
        return duration;
    }
};

/// Returns the current timestamp using the system's high-precision, monotonically increasing, timestamp.
pub fn now() u64 {
    const MonotonicTimestamp = struct {
        var timer: Timer = undefined;
        var once = std.once(init_timer);

        fn init_timer() void {
            timer = Timer.start() catch unreachable;
        }

        fn measure() u64 {
            once.call();
            return timer.read();
        }
    };

    const MonotonicProperty = struct {
        var mutex = std.Thread.Mutex{};
        var last_value = std.atomic.Atomic(u64).init(0);

        // https://doc.rust-lang.org/src/std/time.rs.html#220-260
        const is_already_monotonic = switch (std.Target.current.os.tag) {
            .windows => false,
            .openbsd => std.Target.current.cpu.arch != .x86_64,
            .linux => switch (std.Target.current.cpu.arch) {
                .aarch64, .aarch64_be, .aarch64_32, .s390x => false,
                else => true,
            },
            else => true,
        };

        fn apply(value: u64) u64 {
            if (is_already_monotonic) {
                return value;
            }

            if (@sizeOf(usize) >= @sizeOf(u64)) {
                return applyLockFree(value);
            }

            self.mutex.acquire();
            defer self.mutex.release();

            const last = last_value.loadUnchecked();
            if (value <= last) {
                return last;
            }

            last_value.storeUnchecked(value);
            return value;
        } 

        fn applyLockFree(value: u64) u64 {
            var last = last_value.load(.Monotonic);
            while (true) {
                if (value <= last) {
                    return last;
                }

                last = last_value.tryCompareAndSwap(
                    last,
                    value,
                    .Monotonic,
                    .Monotonic,
                ) orelse return value;
            }
        }
    };

    var current_time = MonotonicTimestamp.measure();
    current_time = MonotonicProperty.apply(current_time);
    return current_time; 
}

test "now" {
    var i: usize = 10;
    while (i > 0) : (i -= 1) {
        const before = now();
        sleep(1);
        const after = now();
        try testing.expect(after >= before);
    }
}

// Calculate (a * b) / c without risk of overflowing too early because of the
// multiplication.
fn safeMulDiv(a: u64, b: u64, c: u64) u64 {
    const q = a / c;
    const r = a % c;
    // (a * b) / c == (a / c) * b + ((a % c) * b) / c
    return (q * b) + (r * b) / c;
}

test "sleep" {
    sleep(1);
}

test "timestamp" {
    const margin = ns_per_ms * 50;

    const time_0 = milliTimestamp();
    sleep(ns_per_ms);
    const time_1 = milliTimestamp();
    const interval = time_1 - time_0;
    try testing.expect(interval > 0);
    // Tests should not depend on timings: skip test if outside margin.
    if (!(interval < margin)) return error.SkipZigTest;
}

test "Timer" {
    const margin = ns_per_ms * 150;

    var timer = try Timer.start();
    sleep(10 * ns_per_ms);
    const time_0 = timer.read();
    try testing.expect(time_0 > 0);
    // Tests should not depend on timings: skip test if outside margin.
    if (!(time_0 < margin)) return error.SkipZigTest;

    const time_1 = timer.lap();
    try testing.expect(time_1 >= time_0);

    timer.reset();
    try testing.expect(timer.read() < time_1);
}
