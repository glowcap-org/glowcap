//! Completion-loop owner-thread claim and transfer.
//!
//! Setup may happen before a driver owns the loop. Once claimed, every public
//! mutation stays on that thread and the embedder receives exactly one
//! quiescent transfer when the driver returns.

const std = @import("std");

pub const tracks_thread_affinity = std.debug.runtime_safety;
const unclaimed_owner_thread_id: u64 = 0;
pub const OwnerThreadId = if (tracks_thread_affinity) u64 else void;
pub const initial_owner_thread_id: OwnerThreadId = if (tracks_thread_affinity) unclaimed_owner_thread_id else {};

fn currentOwnerThreadId() OwnerThreadId {
    if (comptime !tracks_thread_affinity) return {};
    const token = @as(u64, @intCast(std.Thread.getCurrentId())) +% 1;
    std.debug.assert(token != unclaimed_owner_thread_id);
    return token;
}

/// Latch the owning thread at `run` entry. Setup (`init`, `dial`, `attach`)
/// may run on a different thread before the loop starts; only the run thread
/// may call `armOutbound`/`closeSlot`.
pub fn latch(self: anytype) bool {
    if (comptime !tracks_thread_affinity) return false;
    const tid = currentOwnerThreadId();
    if (self.owner_tid != unclaimed_owner_thread_id) {
        std.debug.assert(self.owner_tid == tid);
        return false;
    }
    self.owner_tid = tid;
    return true;
}

/// Setup may mutate an unclaimed loop before a driver starts; once a driver
/// owns it, every public operation must run on that same thread. This does not
/// latch an unclaimed loop: only a driver lifetime owns the transfer.
pub fn assertOwnerOrUnclaimed(self: anytype) void {
    if (comptime !tracks_thread_affinity) return;
    if (self.owner_tid != unclaimed_owner_thread_id)
        std.debug.assert(self.owner_tid == currentOwnerThreadId());
}

/// Return the loop and its adapter-owned state to the quiescent owner.
pub fn release(self: anytype) void {
    if (self.on_driver_exit) |on_exit| on_exit(self.make_ctx);
    if (comptime !tracks_thread_affinity) return;
    std.debug.assert(self.owner_tid != unclaimed_owner_thread_id);
    std.debug.assert(self.owner_tid == currentOwnerThreadId());
    self.owner_tid = unclaimed_owner_thread_id;
}
