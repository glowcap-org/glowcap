//! The one monotonic elapsed-time source for pancake's adapters.
//!
//! Zig 0.16 removed `std.time.milliTimestamp`; the replacement is a clock you
//! choose deliberately. `std.Io.Clock` names `.real` for the wall clock and
//! `.awake` for the monotonic one. Deadlines and timeouts are elapsed-time
//! questions, so they read the monotonic clock: an NTP step moves the wall
//! clock and would make a wall-clock deadline fire early or starve. Only the
//! difference between two readings is meaningful.
//!
//! A component reads time through the same seam it reads I/O through, which is
//! why there are two readers. `nowMs(io)` goes through the host `std.Io`, so a
//! virtual `Io` controls a caller's clock exactly as it controls its sockets.
//! `nowMonotonicMs()` reads the kernel directly, for the one component that is
//! not a `std.Io` consumer: the io_uring completion loop drives the ring itself
//! for the provided-buffer and multishot machinery `std.Io.Uring` does not
//! expose (ADR-0054, ADR-0057).
//!
//! The two are the same clock on Linux, where `.awake` maps to
//! `CLOCK_MONOTONIC`. On macOS `.awake` is `CLOCK_UPTIME_RAW` while
//! `nowMonotonicMs` is `CLOCK_MONOTONIC`. That divergence is immaterial because
//! a reading from one seam is never subtracted from a reading of the other:
//! each caller uses one function throughout.
const std = @import("std");

/// Monotonic milliseconds through the host `std.Io` seam, so a virtual `Io`
/// controls it. Only differences are meaningful.
pub fn nowMs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .awake).toMilliseconds();
}

/// Monotonic milliseconds read straight from the kernel, for the io_uring
/// completion loop: it drives the ring directly for the provided-buffer /
/// multishot scale path `std.Io.Uring` does not expose, so it is not a `std.Io`
/// consumer and reads the kernel clock directly. Only differences are meaningful.
pub fn nowMonotonicMs() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    switch (std.posix.errno(std.posix.system.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts))) {
        // The monotonic clock with a valid out-pointer cannot fail; a zero
        // "epoch" fallback would silently poison every deadline downstream.
        .SUCCESS => {},
        else => unreachable,
    }
    return @as(i64, @intCast(ts.sec)) * std.time.ms_per_s +
        @divFloor(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}
