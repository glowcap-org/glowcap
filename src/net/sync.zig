//! Short-critical-section synchronization primitives for the I/O adapter layer,
//! not the sans-io core. A spin-lock is right for a refcount decrement or a
//! hash-map removal — never for a wait that could block.
//!
//! These live here rather than in `foundation` because `foundation` is `core =
//! true` under the arch-check, which bans `std.atomic`. Adapter consumers in
//! `net` and transport C-ABI packages share this home.

const std = @import("std");

/// A mutex that spins on `tryLock` instead of parking the thread. Use only for
/// critical sections shorter than a kernel wakeup — refcount adjustments, flag
/// writes, queue head updates. Never hold a SpinLock across a blocking call or
/// an I/O operation.
pub const SpinLock = struct {
    inner: std.atomic.Mutex = .unlocked,

    pub fn lock(self: *SpinLock) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn unlock(self: *SpinLock) void {
        self.inner.unlock();
    }
};
