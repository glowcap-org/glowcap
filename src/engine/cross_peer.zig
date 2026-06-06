//! Wiring several peers together for a three-party handoff.
//!
//! A `Peer` only ever owns one direct session, but a three-vat handoff touches
//! several at once: the gifter talking to the recipient, the recipient talking to
//! the exporter, and the exporter's session that signs off on the withdrawal. The
//! functions here take a `*Peer` for each session involved and route frames
//! between them. Since each is a separate mutable borrow, the compiler already
//! guarantees no two of them are the same peer, so there's no shared state to
//! guard and no locking to get right.
//!
//! The core never looks inside a signature. Verification is a hook you pass in
//! (`SignatureVerifier`), which keeps the core free of any crypto dependency. If
//! you want real Ed25519, hand it a verifier that does real Ed25519.

const std = @import("std");

const model = @import("../model/mod.zig");
const engine = @import("mod.zig");

const Peer = engine.Peer;

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
/// Single-peer today (every entry mutates one session). Cross-session
/// forwarding — an entry that also takes the introducing session — is not
/// implemented.
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
