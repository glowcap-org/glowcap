//! Three-party handoff choreography for tests: route the give and withdraw
//! legs between the peers of each session, with signature verification
//! injected through the engine's `SignatureVerifier` seam.
//!
//! This is host wiring, not engine semantics. A production host owns the
//! equivalent routing (and a real Ed25519 verifier) in its adapter, so it
//! lives in test support. The engine keeps the seams these helpers drive:
//! `engine.cross_peer.SignatureVerifier` and the vat-scoped
//! `engine.bootstrap.GiftRegistry`. Each helper takes a `*Peer` per
//! participating session; the compiler's exclusive mutable borrows already
//! guarantee no two of them alias, so there is no shared state to guard.

const pancake = @import("pancake");

const model = pancake.ocapn.model;
const codec = pancake.ocapn.codec;
const engine = pancake.ocapn.engine;

const Peer = engine.Peer;

/// The engine's injection seam, re-exported so a test that builds a verifier
/// imports one module.
pub const SignatureVerifier = engine.cross_peer.SignatureVerifier;

pub const Error = error{
    SignatureRejected,
    NoOutboundFrame,
    StrandedOutboundFrame,
};

fn alwaysAccept(_: ?*anyopaque, _: []const u8, _: []const u8) bool {
    return true;
}

/// A verifier that accepts every signature. **Test / trusted-substrate only.**
/// Production hosts verify handoff certificates with `foundation.crypto` on the
/// engine router path; this helper must never be wired as a network default.
pub fn testOnlyAcceptingVerifier() SignatureVerifier {
    return .{ .context = null, .verify_fn = alwaysAccept };
}

/// Run the gifter's two outbound legs: the deposit to the exporter and the give
/// to the recipient.
///
/// The exporter records the gift — including the depositing gifter's session
/// public key — so a subsequent withdrawal can verify the gifter's give
/// certificate against it. The key comes from `gifter_key` when the caller
/// threads one through; when `gifter_key` is null it is the partner key the
/// exporter learned from the gifter-to-exporter handshake (`partnerSessionKey`),
/// so a handshaked exporter records the right key with no argument. It is empty
/// only when neither is known.
///
/// Sibling copy: `examples/apps/accountability-on-pancake/zig/three_party_test.zig`.
/// That fork uses a real Ed25519 RoutingVerifier and threads an explicit gifter
/// key at deposit; here `deliverGive` accepts a null key (learn from handshake)
/// and tests use `testOnlyAcceptingVerifier()` for a key-agnostic seam.
pub fn deliverGive(
    gifter: *Peer,
    recipient: *Peer,
    exporter: *Peer,
    give: model.HandoffGive,
    gifter_key: ?[]const u8,
) !void {
    const learned = if (gifter_key) |key|
        key
    else
        exporter.partnerSessionKey() orelse "";
    try exporter.giftRegistry().deposit(
        exporter.allocator,
        exporter.limits(),
        give.gift_id,
        give.recipient_key,
        learned,
    );
    try gifter.sendCopying(.{ .handoff = .{ .give = give } });
    try pumpOne(gifter, recipient);
}

/// Run the recipient's withdraw leg to the exporter.
///
/// Before the recipient sends the handoff-receive and the exporter's gift
/// registry authorizes the withdrawal (gift existence, recipient match,
/// handoff-count monotonicity), both certificates are checked at the boundary by the injected
/// verifier, each over its *canonical signed bytes* (ADR-0009): the gifter's
/// signature over the embedded `desc:handoff-give` record, and the recipient's
/// signature over the `desc:handoff-receive` record. The signed domain is the
/// whole envelope, not the gift-id field alone; verifying a single field would
/// accept a signature lifted from any other envelope carrying that gift-id. A
/// production verifier routes each payload to the right key (the gifter's
/// session key for the give, the recipient key for the receive); the test seam
/// (`testOnlyAcceptingVerifier`) is key-agnostic.
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

    // Authority moves here, behind the verification above, not on the exporter's
    // generic inbound path, which refuses to consume a gift from an unauthenticated
    // handoff frame. The frame is still pumped so the exporter surfaces the
    // `.handoff` event, but the withdrawal is applied explicitly against the
    // exporter's gift registry.
    const registry = exporter.giftRegistry();
    try registry.validateWithdraw(receive);
    _ = try registry.applyWithdraw(exporter.allocator, exporter.limits(), receive);

    try recipient.sendCopying(.{ .handoff = .{ .receive = receive } });
    try pumpOne(recipient, exporter);
}

/// Encode exactly one pending message from `from` and dispatch it on `to`.
/// Sibling pump copy: `examples/apps/accountability-on-pancake/zig/three_party_test.zig`.
pub fn pumpOne(from: *Peer, to: *Peer) !void {
    _ = try from.step();
    const frame = from.takeOutbound() orelse return Error.NoOutboundFrame;
    if (from.takeOutbound()) |frame_value| {
        var stranded = frame_value;
        stranded.deinit();
        var owned = frame;
        owned.deinit();
        return Error.StrandedOutboundFrame;
    }
    try to.feedOwned(frame);
    _ = try to.step();
}

/// Drain every pending outbound message from `from` and dispatch each on `to`.
pub fn pumpAll(from: *Peer, to: *Peer) !void {
    _ = try from.step();
    while (from.takeOutbound()) |frame| try to.feedOwned(frame);
    _ = try to.step();
}
