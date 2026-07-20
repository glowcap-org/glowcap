//! Monotonic elapsed-time for CLI operability timers (deadlines, spinners).
//!
//! These are real-process UI concerns beneath the CapTP `std.Io` seam — a
//! spinner and an idle timeout, not session I/O — so they read the monotonic
//! clock directly and take no `io`. The one clock implementation lives in
//! `net.clock`; this is its CLI-facing name so every operability wait shares it.
const net = @import("pancake").net;

/// Monotonic milliseconds. Only differences are meaningful.
pub const nowMs = net.clock.nowMonotonicMs;
