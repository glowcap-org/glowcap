//! The warm inbound turn the allocation, footprint, and dispatch budgets all
//! drive: one borrowed `op:deliver` to a live local export, then a drain of every
//! surfaced event. Tests and benches share this body so the figures they quote
//! are the same turn.

const glowcap = @import("glowcap");

const engine = glowcap.ocapn.engine;

/// A no-answer (`#f` answer position) `op:deliver` to local export 7 carrying one
/// inline bytes argument, the fire-and-forget one-way send. The argument
/// exercises the borrowed-validate path without retained owned message
/// materialization, so a budget measures the irreducible owned-frame copy
/// rather than transient validation clones. With no answer position every turn
/// installs no inbound answer row, so a steady stream mutates no table and the
/// same frame can be re-applied to one peer. A distinct-answer deliver would
/// both grow the answer table per turn and, on a reused position, trip the
/// live-answer-reuse refusal. Export 7 must be live on the peer.
pub const deliver_to_live_export = "<10'op:deliver<11'desc:export7+>[5:hello]ff>";

/// Drive one wire turn: dispatch the borrowed deliver and drain every surfaced
/// event (releasing each owned frame), matching how a host pumps the peer. The
/// final empty poll lets the peer reclaim its event-queue slots, so a long-lived
/// session reuses backing capacity instead of growing one entry per turn.
pub fn driveOneTurn(peer: *engine.Peer) !void {
    try peer.recvBorrowed(.{ .bytes = deliver_to_live_export, .shape = .byte });
    while (peer.pollEvent()) |event_in| {
        var event = event_in;
        event.deinit();
    }
}
