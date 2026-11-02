//! The monotonic clock every bench times with. `.awake` is `CLOCK_MONOTONIC`.
//! The reading is the widest integer the clock gives, and a caller casts at
//! its own use.

const std = @import("std");

/// Monotonic nanoseconds since an arbitrary origin.
pub fn nowNs(io: std.Io) i128 {
    return std.Io.Clock.now(.awake, io).nanoseconds;
}
