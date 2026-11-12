//! Owner-thread tokens for single-owner state that checks affinity.
//!
//! A completion loop and a byte-fed Host each belong to one thread once a
//! driver claims them, and each asserts that claim on every public mutation
//! in the builds where the check is worth its cost. The policy for *when* to
//! track is the owner's (the loop tracks under runtime safety, a Host under
//! its explicit checked policy). This layer owns no threads, so the raw
//! thread id comes from the layer that does, and every owner mints its token
//! here, where the owners cannot drift on what "this thread" means.

const std = @import("std");

/// Where an owner that may not read threads learns which thread is calling.
/// The embedder that owns threads supplies it, and `read` returns the calling
/// thread's raw OS id. The owner mints that id into a token with
/// `OwnerThread.token`.
pub const Reader = struct {
    ctx: ?*anyopaque = null,
    read: *const fn (?*anyopaque) u64,

    pub fn token(self: Reader) u64 {
        return OwnerThread(true).token(self.read(self.ctx));
    }
};

/// The token vocabulary for one owner. With `tracks` false every member is
/// `void` and the owner pays nothing. With it true the token is a thread id
/// plus one, so the unclaimed value can never be a live thread.
pub fn OwnerThread(comptime tracks: bool) type {
    return struct {
        pub const unclaimed: u64 = 0;
        pub const Id = if (tracks) u64 else void;
        pub const initial: Id = if (tracks) unclaimed else {};

        /// The token for the thread whose raw id the owner read.
        pub fn token(raw_thread_id: u64) Id {
            if (comptime !tracks) return {};
            const claimed = raw_thread_id +% 1;
            std.debug.assert(claimed != unclaimed);
            return claimed;
        }
    };
}
