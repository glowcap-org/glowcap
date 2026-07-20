//! The one monotonic elapsed-time source for pancake's adapters.
//!
//! Zig 0.16 removed `std.time.milliTimestamp`; the replacement is a clock you
//! choose deliberately. `std.Io.Clock` names `.real` for the wall clock and
//! `.awake` for the monotonic one. Deadlines and timeouts are elapsed-time
//! questions, so they read the monotonic clock: an NTP step moves the wall
//! clock and would make a wall-clock deadline fire early or starve. Only the
//! difference between two readings is meaningful.
//!
//! One rule decides which reader a caller takes: **a component reads time
//! through the same seam it reads I/O through.**
//!
//!   * `nowMs(io)` reads the monotonic clock through the host `std.Io`. Every
//!     adapter that already runs its I/O on a `std.Io` (the blocking session
//!     over a `net.Connection`, the demo clients, the driver) reads here, so a
//!     virtual `Io` — a simulator — controls their clock exactly as it controls
//!     their sockets.
//!   * `nowMonotonicMs()` reads the kernel's monotonic clock directly, for the
//!     one component that is not a `std.Io` consumer: the io_uring completion
//!     loop. It drives io_uring directly for the registered provided-buffer ring
//!     and multishot recv the 500k-connection path depends on (ADR-0054,
//!     ADR-0057) — machinery `std.Io.Uring` does not expose — so it is not built
//!     on the `std.Io` seam and reads the kernel clock the same way it drives the
//!     ring. Its only clock reads are the coarse park-reap sweep and the
//!     test/interop `runUntil` deadline, both off the connection hot path. If
//!     `std.Io.Uring` ever grows provided buffers and the loop adopts it, these
//!     reads ride `std.Io` like the rest.
//!
//! One monotonic *reading rule*, two seams — not one syscall. On Linux both are
//! `CLOCK_MONOTONIC` (`.awake` maps to it), so they are the same clock; on macOS
//! `.awake` is `CLOCK_UPTIME_RAW` while `nowMonotonicMs` is `CLOCK_MONOTONIC`.
//! That divergence is immaterial because every wait subtracts two readings from
//! the same function: the io_uring loop and the CLI operability timers read only
//! `nowMonotonicMs`, the blocking session and demo clients read only `nowMs`, so
//! no reading from one seam is ever subtracted from a reading of the other.
//!
//! This lives in `net` because `net` is the lowest layer the build permits I/O
//! in and `net/completion/loop.zig` needs it; the sync no-I/O core above must
//! never read a clock, so this is deliberately out of their reach.
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
