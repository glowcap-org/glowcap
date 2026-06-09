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
const codec = @import("../codec/mod.zig");
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

/// Run the gifter's two outbound legs: the deposit to the exporter and the give
/// to the recipient.
///
/// The exporter records the gift — including the depositing gifter's session
/// public key — so a subsequent withdrawal can verify the gifter's give
/// certificate against it. The key comes from `gifter_key` when the caller threads
/// one through; otherwise it is the partner key the exporter learned from the
/// gifter-to-exporter handshake (`partnerSessionKey`), so a handshaked exporter
/// records the right key with no argument. It is empty only when neither is known.
pub fn deliverGive(
    gifter: *Peer,
    recipient: *Peer,
    exporter: *Peer,
    give: model.HandoffGive,
    gifter_key: []const u8,
) !void {
    const learned = if (gifter_key.len > 0)
        gifter_key
    else
        exporter.session_state.partnerSessionKey() orelse "";
    try exporter.session_state.depositGift(give.gift_id, give.recipient_key, learned);
    try gifter.sendCopying(.{ .handoff = .{ .give = give } });
    try pumpFrame(gifter, recipient);
}

/// Run the recipient's withdraw leg to the exporter.
///
/// Before the recipient sends the handoff-receive and the exporter's session
/// authorizes the withdrawal (gift existence, recipient match, handoff-count
/// monotonicity), both certificates are checked at the boundary by the injected
/// verifier — each over its *canonical signed bytes* (ADR-0009): the gifter's
/// signature over the embedded `desc:handoff-give` record, and the recipient's
/// signature over the `desc:handoff-receive` record. The signed domain is the
/// whole envelope, not the gift-id field alone; verifying a single field would
/// accept a signature lifted from any other envelope carrying that gift-id. A
/// production verifier routes each payload to the right key (the gifter's
/// session key for the give, the recipient key for the receive); the test seam
/// (`acceptingVerifier`) is key-agnostic.
pub fn withdrawGift(
    recipient: *Peer,
    exporter: *Peer,
    receive: model.HandoffReceive,
    verifier: SignatureVerifier,
) !void {
    const allocator = exporter.allocator;

    const give_signed = try codec.syrup.canonicalHandoffGiveSignedBytes(allocator, receive.signed_give);
    defer allocator.free(give_signed);
    if (!verifier.verify(give_signed, receive.signed_give.signature)) {
        return Error.SignatureRejected;
    }

    const receive_signed = try codec.syrup.canonicalHandoffReceiveSignedBytes(allocator, receive);
    defer allocator.free(receive_signed);
    if (!verifier.verify(receive_signed, receive.signature)) {
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
