//! Caller-orchestrated cross-peer coordination for three-party handoff.
//!
//! A `Peer` owns exactly one direct session, so a three-vat handoff spans
//! several peers: the gifter's session to the recipient, the recipient's session
//! to the exporter, and the exporter's session that authorizes the withdrawal.
//! These free functions take a `*Peer` for each participating session and route
//! frames between them; the borrow checker enforces that no two participants
//! alias, so there is no shared mutable state and no lock discipline.
//!
//! Signatures stay opaque in the no-I/O core. Verification is an injected hook
//! (`SignatureVerifier`); the core pulls in no crypto dependency. A substrate
//! that wants real Ed25519 supplies a verifier that performs it.

const std = @import("std");

const model = @import("../model/mod.zig");
const runtime = @import("mod.zig");

const Peer = runtime.Peer;

pub const Error = error{
    SignatureRejected,
    NoOutboundFrame,
};

/// One queued relayed resolution for a handoff-imported promise (ADR-0009
/// § `op:listen` on `desc:import-promise`). The introducing session forwards the
/// resolution of a third-party-hosted promise; [`drainRelayedResolutions`]
/// records it on the target session, drains the imported-promise listeners, and
/// synthesizes a fire `op:deliver` for each. Owns its `resolution` until drained.
pub const PendingRelayedResolution = struct {
    import_id: u64,
    resolution: model.Resolution,
};

/// Drain `peer.pending_relayed_resolutions`. For each entry, fire the listeners
/// installed on that third-party import with the forwarded resolution, then
/// store the resolution so a late `op:listen` fires immediately (ADR-0009).
/// Returns whether any entry was processed.
///
/// Single-peer today (every entry mutates one session); it lives here for
/// API-location parity with the canonical runtime and the future cross-session
/// forwarding that would also take the introducing session.
pub fn drainRelayedResolutions(peer: *Peer) !bool {
    if (peer.pending_relayed_resolutions.items.len == 0) return false;
    const pending = try peer.pending_relayed_resolutions.toOwnedSlice(peer.allocator);
    defer peer.allocator.free(pending);

    var index: usize = 0;
    // `applyRelayedResolution` owns each entry's resolution on both outcomes;
    // the errdefer releases the resolutions not yet applied.
    errdefer for (pending[index..]) |entry| model.freeResolution(peer.allocator, entry.resolution);
    while (index < pending.len) {
        const entry = pending[index];
        index += 1;
        try peer.applyRelayedResolution(entry.import_id, entry.resolution);
    }
    return true;
}

/// An injected signature-verification hook. The core treats signatures as opaque
/// bytes and defers the cryptographic decision to the caller's substrate.
pub const SignatureVerifier = struct {
    context: *anyopaque,
    verify_fn: *const fn (context: *anyopaque, payload: []const u8, signature: []const u8) bool,

    pub fn verify(self: SignatureVerifier, payload: []const u8, signature: []const u8) bool {
        return self.verify_fn(self.context, payload, signature);
    }
};

var accepting_context: u8 = 0;

fn alwaysAccept(_: *anyopaque, _: []const u8, _: []const u8) bool {
    return true;
}

/// A verifier that accepts every signature. Only for in-process tests and
/// trusted substrates; never the default for an untrusted network.
pub fn acceptingVerifier() SignatureVerifier {
    return .{ .context = &accepting_context, .verify_fn = alwaysAccept };
}

/// Gifter -> exporter (deposit) and gifter -> recipient (give).
///
/// The exporter records the gift so a subsequent withdrawal can be authorized, then
/// the gifter sends the signed handoff-give to the recipient, who surfaces it as
/// a handoff event.
pub fn deliverGive(
    gifter: *Peer,
    recipient: *Peer,
    exporter: *Peer,
    give: model.HandoffGive,
) !void {
    try exporter.session_state.depositGift(give.gift_id, give.recipient_key);
    try gifter.sendCopying(.{ .handoff = .{ .give = give } });
    try pumpFrame(gifter, recipient);
}

/// Recipient -> exporter (withdraw).
///
/// The recipient's signature over the gift is checked at the boundary by the
/// injected verifier, then the recipient sends the handoff-receive to the
/// exporter, whose session authorizes the withdrawal against its gift table
/// (gift existence, recipient match, handoff-count monotonicity).
pub fn withdrawGift(
    recipient: *Peer,
    exporter: *Peer,
    receive: model.HandoffReceive,
    verifier: SignatureVerifier,
) !void {
    if (!verifier.verify(receive.signed_give.gift_id, receive.signature)) {
        return Error.SignatureRejected;
    }
    try recipient.sendCopying(.{ .handoff = .{ .receive = receive } });
    try pumpFrame(recipient, exporter);
}

/// Encode the `from` peer's single pending message and dispatch it on `to`.
fn pumpFrame(from: *Peer, to: *Peer) !void {
    _ = try from.step();
    const frame = from.takeOutbound() orelse return Error.NoOutboundFrame;
    try to.feedInbound(frame);
    _ = try to.step();
}
