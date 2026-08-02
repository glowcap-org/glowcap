//! The durable-key-attestation contract at the engine chokepoint (ADR-0097
//! step 2). A peer under `requirePartnerAttestation` admits a partner hello
//! claiming a key-designator location only when its `session-key-attestation`
//! hint verifies under that durable key over the canonical
//! `<session-key-attestation-v1 transport designator session-pubkey>` record.
//! The positive arm drives two contracted peers to an open session with
//! production-assembled hints (`engine.keyedHelloHints`); the negative arms
//! prove every mutation class ADR-0097's evidence names — missing credential,
//! wrong durable signer, and a signature bound to a different transport,
//! designator, or session key — refuses the hello before the session opens,
//! with the typed handshake abort queued and the session still negotiating.
//! An address-placeholder hello (an ephemeral dialer) claims no durable
//! identity and passes the contract untouched.
//!
//! The sibling contract for authenticated transports
//! (`expectPartnerDurableKey`, the binding iroh's accept paths install from
//! the QUIC-verified remote endpoint key) is held at the bottom: a hello may
//! claim the proved identity or an address, never someone else's key — and
//! `session_pubkey` stays unconstrained, since an ephemeral client's session
//! key is not its endpoint key.

const std = @import("std");
const pancake = @import("pancake");

const foundation = pancake.foundation;
const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const session = pancake.ocapn.session;
const codec = pancake.ocapn.codec;

const crypto = foundation.crypto;

const transport = "keyed-tcp";

fn contractedVerifier(allocator: std.mem.Allocator) engine.Peer {
    var peer = engine.Peer.initNegotiating(allocator);
    peer.verify_partner_handshake = true;
    peer.requirePartnerAttestation();
    return peer;
}

/// Build one keyed hello frame: a sender peer signs `(transport, designator,
/// hints)` under `secret` and the encoded `op:start-session` frame is returned
/// owned. The location signature is always valid, so the negative arms
/// isolate the attestation check rather than riding a broken hello.
fn helloFrame(
    allocator: std.mem.Allocator,
    secret: crypto.SecretKey,
    designator: []const u8,
    hints: model.Hints,
) !foundation.Frame {
    var sender = engine.Peer.initNegotiating(allocator);
    defer sender.deinit();
    try sender.sendKeyedStartSession(.v1_0, .{
        .transport = transport,
        .designator = designator,
        .hints = hints,
    }, secret);
    _ = try sender.step();
    return sender.takeOutbound().?;
}

fn attestationEntry(sig: *const crypto.Signature) model.HintEntry {
    return .{
        .name = model.transport.hint_session_key_attestation,
        .value = .{ .bytes = sig.asBytes() },
    };
}

fn expectHandshakeRefusal(verifier: *engine.Peer, expected: anyerror) !void {
    try std.testing.expectError(expected, verifier.step());
    try std.testing.expectEqual(session.State.negotiating, verifier.session_state.state);
    var abort_frame = verifier.takeOutbound().?;
    defer abort_frame.deinit();
    const view = try codec.syrup.decodeBody(abort_frame.view());
    try std.testing.expectEqual(model.AbortKind.invalid_start_session_signature, view.abort.kind);
}

test "two contracted peers with production-minted credentials open a session" {
    const allocator = std.testing.allocator;
    const a_secret = crypto.SecretKey.fromSeed([_]u8{0x51} ** crypto.SEED_BYTES);
    const b_secret = crypto.SecretKey.fromSeed([_]u8{0x52} ** crypto.SEED_BYTES);
    const a_designator = a_secret.publicKey().toDesignator();
    const b_designator = b_secret.publicKey().toDesignator();

    var a = contractedVerifier(allocator);
    defer a.deinit();
    var b = contractedVerifier(allocator);
    defer b.deinit();

    var a_entries: [2]model.HintEntry = undefined;
    var a_sig: crypto.Signature = undefined;
    const a_hints = try engine.keyedHelloHints(&a_entries, &a_sig, "127.0.0.1:19001", true, &a_secret, a_secret.publicKey(), transport, a_designator[0..]);
    try a.sendKeyedStartSession(.v1_0, .{ .transport = transport, .designator = a_designator[0..], .hints = a_hints }, a_secret);

    var b_entries: [2]model.HintEntry = undefined;
    var b_sig: crypto.Signature = undefined;
    const b_hints = try engine.keyedHelloHints(&b_entries, &b_sig, "127.0.0.1:19002", true, &b_secret, b_secret.publicKey(), transport, b_designator[0..]);
    try b.sendKeyedStartSession(.v1_0, .{ .transport = transport, .designator = b_designator[0..], .hints = b_hints }, b_secret);

    _ = try a.step();
    _ = try b.step();
    try b.feedOwned(a.takeOutbound().?);
    try a.feedOwned(b.takeOutbound().?);
    _ = try a.step();
    _ = try b.step();

    try std.testing.expectEqual(session.State.open, a.session_state.state);
    try std.testing.expectEqual(session.State.open, b.session_state.state);
}

test "a key-designator claim without the credential is refused before open" {
    const allocator = std.testing.allocator;
    const secret = crypto.SecretKey.fromSeed([_]u8{0x53} ** crypto.SEED_BYTES);
    const designator = secret.publicKey().toDesignator();

    var verifier = contractedVerifier(allocator);
    defer verifier.deinit();

    // A well-signed keyed hello whose hints carry only the dial address —
    // exactly what every keyed-tcp listener sent before the credential.
    var entry = [_]model.HintEntry{.{
        .name = model.transport.hint_direct_addresses,
        .value = .{ .string = "127.0.0.1:19003" },
    }};
    const frame = try helloFrame(allocator, secret, designator[0..], .{ .entries = entry[0..] });
    try verifier.feedOwned(frame);
    try expectHandshakeRefusal(&verifier, error.PartnerAttestationMissing);
}

test "an attestation by the wrong durable key is refused" {
    const allocator = std.testing.allocator;
    const secret = crypto.SecretKey.fromSeed([_]u8{0x54} ** crypto.SEED_BYTES);
    const imposter = crypto.SecretKey.fromSeed([_]u8{0x55} ** crypto.SEED_BYTES);
    const designator = secret.publicKey().toDesignator();

    var verifier = contractedVerifier(allocator);
    defer verifier.deinit();

    const sig = try engine.mintSessionKeyAttestation(&imposter, transport, designator[0..], secret.publicKey().asBytes());
    var entry = [_]model.HintEntry{attestationEntry(&sig)};
    const frame = try helloFrame(allocator, secret, designator[0..], .{ .entries = entry[0..] });
    try verifier.feedOwned(frame);
    try expectHandshakeRefusal(&verifier, error.PartnerAttestationInvalid);
}

test "an attestation bound to a different transport is refused" {
    const allocator = std.testing.allocator;
    const secret = crypto.SecretKey.fromSeed([_]u8{0x56} ** crypto.SEED_BYTES);
    const designator = secret.publicKey().toDesignator();

    var verifier = contractedVerifier(allocator);
    defer verifier.deinit();

    const sig = try engine.mintSessionKeyAttestation(&secret, "keyed-relay", designator[0..], secret.publicKey().asBytes());
    var entry = [_]model.HintEntry{attestationEntry(&sig)};
    const frame = try helloFrame(allocator, secret, designator[0..], .{ .entries = entry[0..] });
    try verifier.feedOwned(frame);
    try expectHandshakeRefusal(&verifier, error.PartnerAttestationInvalid);
}

test "an attestation bound to a different designator is refused" {
    const allocator = std.testing.allocator;
    const secret = crypto.SecretKey.fromSeed([_]u8{0x57} ** crypto.SEED_BYTES);
    const other = crypto.SecretKey.fromSeed([_]u8{0x58} ** crypto.SEED_BYTES);
    const designator = secret.publicKey().toDesignator();
    const other_designator = other.publicKey().toDesignator();

    var verifier = contractedVerifier(allocator);
    defer verifier.deinit();

    const sig = try engine.mintSessionKeyAttestation(&secret, transport, other_designator[0..], secret.publicKey().asBytes());
    var entry = [_]model.HintEntry{attestationEntry(&sig)};
    const frame = try helloFrame(allocator, secret, designator[0..], .{ .entries = entry[0..] });
    try verifier.feedOwned(frame);
    try expectHandshakeRefusal(&verifier, error.PartnerAttestationInvalid);
}

test "an attestation authorizing a different session key is refused" {
    const allocator = std.testing.allocator;
    const secret = crypto.SecretKey.fromSeed([_]u8{0x59} ** crypto.SEED_BYTES);
    const other = crypto.SecretKey.fromSeed([_]u8{0x5a} ** crypto.SEED_BYTES);
    const designator = secret.publicKey().toDesignator();

    var verifier = contractedVerifier(allocator);
    defer verifier.deinit();

    // The durable key really signed this credential, but for another session
    // key — the replay ADR-0097 exists to stop once session keys are fresh.
    const sig = try engine.mintSessionKeyAttestation(&secret, transport, designator[0..], other.publicKey().asBytes());
    var entry = [_]model.HintEntry{attestationEntry(&sig)};
    const frame = try helloFrame(allocator, secret, designator[0..], .{ .entries = entry[0..] });
    try verifier.feedOwned(frame);
    try expectHandshakeRefusal(&verifier, error.PartnerAttestationInvalid);
}

test "an address-placeholder hello claims no durable identity and passes" {
    const allocator = std.testing.allocator;
    const secret = crypto.SecretKey.fromSeed([_]u8{0x5b} ** crypto.SEED_BYTES);

    var verifier = contractedVerifier(allocator);
    defer verifier.deinit();

    // The ephemeral-dialer hello every keyed-tcp client sends: the session
    // transport is keyed, but the claimed location is the unreachable address
    // placeholder, so there is no durable claim to attest.
    const frame = try helloFrame(allocator, secret, "127.0.0.1:0", model.Hints.emptyFalse());
    try verifier.feedOwned(frame);
    _ = try verifier.step();
    try std.testing.expect(verifier.takeOutbound() == null);
}

// ── The authenticated-transport binding (`expectPartnerDurableKey`) ────────

test "a hello claiming the transport-verified identity passes the binding" {
    const allocator = std.testing.allocator;
    const partner = crypto.SecretKey.fromSeed([_]u8{0x5c} ** crypto.SEED_BYTES);
    const designator = partner.publicKey().toDesignator();

    var verifier = engine.Peer.initNegotiating(allocator);
    defer verifier.deinit();
    verifier.verify_partner_handshake = true;
    verifier.expectPartnerDurableKey(partner.publicKey(), .transport_verified);

    const frame = try helloFrame(allocator, partner, designator[0..], model.Hints.emptyFalse());
    try verifier.feedOwned(frame);
    _ = try verifier.step();
    try std.testing.expect(verifier.takeOutbound() == null);
}

test "a hello claiming a key the transport did not prove is refused" {
    const allocator = std.testing.allocator;
    const partner = crypto.SecretKey.fromSeed([_]u8{0x5d} ** crypto.SEED_BYTES);
    const someone_else = crypto.SecretKey.fromSeed([_]u8{0x5e} ** crypto.SEED_BYTES);
    const claimed = someone_else.publicKey().toDesignator();

    var verifier = engine.Peer.initNegotiating(allocator);
    defer verifier.deinit();
    verifier.verify_partner_handshake = true;
    verifier.expectPartnerDurableKey(partner.publicKey(), .transport_verified);

    // Well-signed by the partner's own session key, but naming another
    // durable identity as its location — the claim QUIC never proved.
    const frame = try helloFrame(allocator, partner, claimed[0..], model.Hints.emptyFalse());
    try verifier.feedOwned(frame);
    try expectHandshakeRefusal(&verifier, error.PartnerDesignatorMismatch);
}

test "an address claim passes an authenticated-transport binding untouched" {
    const allocator = std.testing.allocator;
    const partner = crypto.SecretKey.fromSeed([_]u8{0x5f} ** crypto.SEED_BYTES);
    const anchor = crypto.SecretKey.fromSeed([_]u8{0x60} ** crypto.SEED_BYTES);

    var verifier = engine.Peer.initNegotiating(allocator);
    defer verifier.deinit();
    verifier.verify_partner_handshake = true;
    verifier.expectPartnerDurableKey(anchor.publicKey(), .transport_verified);

    // An ephemeral client over an authenticated transport: its session key is
    // not its endpoint key, and its address claim names no durable identity.
    const frame = try helloFrame(allocator, partner, "127.0.0.1:0", model.Hints.emptyFalse());
    try verifier.feedOwned(frame);
    _ = try verifier.step();
    try std.testing.expect(verifier.takeOutbound() == null);
}
