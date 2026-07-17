//! Embedder-facing host action FIFO payloads and their free helpers.
//! `Host` owns the queue; this module owns only the payload shapes and how
//! their owned bytes are released.

const std = @import("std");

const model = @import("model");
const engine = @import("engine");

/// What the embedder must do next. `Host.nextAction` pops borrowed: a
/// completion's value views are host-owned and stay valid until the next
/// `Host.nextAction` call, which frees them — the same borrow contract
/// `engine.Node.nextAction` carries for node-level actions. `Host.takeAction`
/// pops owned instead: the caller adopts the payload and frees it with
/// `Host.freeAction` (or moves it into a durable owner first).
///
/// `dial` carries only the pending ticket; the dial view lives on the node
/// pending row (`Host.pendingDial` / C `pancake_host_pending_dial`).
pub const HostAction = union(enum) {
    /// Dial the exporter named by this ticket's pending dial view with this
    /// host's identity, then report `exporterDialed(ticket, conn)` — or
    /// `dialFailed(ticket, reason)` if any step refuses.
    dial: struct { ticket: engine.Node.PendingId },
    /// Outbound frames may be ready on this session: drain
    /// `Conn.takeOutbound` until empty and write them.
    flush: engine.PeerId,
    /// The host condemned this session mid-pump (its local turns amplified
    /// past `Options.local_turn_budget`): flush its queued outbound — the
    /// typed `resource_exhausted` abort — then tear its transport down and
    /// release the session. Without this action a byte-fed embedder has no
    /// way to learn a session died inside the pump; `condemned` alone only
    /// refuses future verbs.
    close: engine.PeerId,
    /// Draw 32 bytes of gift-id entropy and feed them back through
    /// `provideGiftId(ticket, bytes)`. Entropy is a host effect like dialing;
    /// the sans-io host never generates it.
    need_gift_id: struct { ticket: u64 },
    /// A host vow with no in-process listener settled fulfilled: `value` is a
    /// deep clone the host owns, valid until the next `nextAction` call,
    /// which frees it. Route it to whatever awaits the vow.
    settled: struct { vow_id: u64, value: model.Argument },
    /// A host vow with no in-process listener settled broken: `message` is
    /// host-owned with the same until-next-`nextAction` lifetime (empty when
    /// the break carried no reason, or when retaining one failed).
    failed: struct { vow_id: u64, message: []const u8 },
};

/// Free every owned byte view a `HostAction` may carry. POD arms are no-ops.
pub fn freeAction(allocator: std.mem.Allocator, action: HostAction) void {
    switch (action) {
        .settled => |s| model.freeArgument(allocator, s.value),
        .failed => |f| if (f.message.len != 0) allocator.free(f.message),
        .dial, .flush, .close, .need_gift_id => {},
    }
}
