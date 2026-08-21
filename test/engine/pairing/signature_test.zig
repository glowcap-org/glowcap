//! Start-session signatures: real Ed25519 verification, the pinned-key
//! contract, hinted-locator handshakes checked on received bytes and refused
//! when tampered, and the recorded partner keys later checks read.

const std = @import("std");
const pancake = @import("pancake");

const foundation = pancake.foundation;
const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const session = pancake.ocapn.session;
const codec = pancake.ocapn.codec;
const pairing = engine.pairing;
const handshake = @import("../../support/handshake.zig");

const crypto = foundation.crypto;

const pairing_support = @import("harness.zig");
const pairedWithOffers = pairing_support.pairedWithOffers;

test "a verifying peer aborts an op:start-session whose signature does not match the claimed key" {
    const allocator = std.testing.allocator;

    var verifier = engine.Peer.initNegotiating(allocator);
    defer verifier.deinit();
    verifier.verify_partner_handshake = true;

    // A sender that emits a structurally valid keyed start-session, but advertises
    // one key while carrying a signature only a *different* key could have made
    // over this location, the signature does not match the claimed key.
    var sender = engine.Peer.initNegotiating(allocator);
    defer sender.deinit();

    const loc: model.PeerLocator = .{ .transport = "tcp", .designator = "127.0.0.1:9", .hints = model.Hints.emptyFalse() };
    const honest = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x33)));
    const imposter = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x44)));

    const signed = try codec.syrup.canonicalLocationSignedBytes(allocator, loc);
    defer allocator.free(signed);
    const sig = crypto.sign(&honest, signed);

    try sender.sendCopying(.{ .start_session = .{
        .captp_version = .v1_0,
        .session_pubkey = .{ .bytes = imposter.publicKey().asBytes() },
        .acceptable_location = loc,
        .acceptable_location_sig = .{ .bytes = sig.asBytes() },
    } });
    _ = try sender.step();
    const forged = sender.takeOutbound().?;

    // The verifier refuses the forged handshake and does not open the session.
    try verifier.feedOwned(forged);
    try std.testing.expectError(error.InvalidStartSessionSignature, verifier.step());
    try std.testing.expectEqual(session.State.closed, verifier.session_state.state);

    // The refusal is fail-loud: a typed op:abort is queued for the partner.
    var abort_frame = verifier.takeOutbound().?;
    defer abort_frame.deinit();
    const view = try codec.syrup.decodeBody(abort_frame.view());
    try std.testing.expectEqual(model.AbortKind.invalid_start_session_signature, view.abort.kind);
}

test "a pinned peer opens when the partner's start-session carries exactly the expected key" {
    const allocator = std.testing.allocator;

    var p1 = engine.Peer.initNegotiating(allocator);
    defer p1.deinit();
    var p2 = engine.Peer.initNegotiating(allocator);
    defer p2.deinit();

    const secret1 = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x11)));
    const secret2 = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x22)));
    // Each side's realizer proved the other's durable identity, and each
    // advertises its own: both handshakes must still open.
    p1.bindVerifiedChannelKey(secret2.publicKey());
    p2.bindVerifiedChannelKey(secret1.publicKey());

    const designator1 = secret1.publicKey().toDesignator();
    const designator2 = secret2.publicKey().toDesignator();
    const loc1: model.PeerLocator = .{ .transport = "keyed-tcp", .designator = designator1[0..], .hints = model.Hints.emptyFalse() };
    const loc2: model.PeerLocator = .{ .transport = "keyed-tcp", .designator = designator2[0..], .hints = model.Hints.emptyFalse() };
    try p1.sendKeyedStartSession(loc1, secret1);
    try p2.sendKeyedStartSession(loc2, secret2);

    var i: usize = 0;
    while (i < 8 and !(p1.sessionIsOpen() and p2.sessionIsOpen())) : (i += 1) {
        _ = try p1.step();
        _ = try p2.step();
        while (p1.takeOutbound()) |frame| try p2.feedOwned(frame);
        while (p2.takeOutbound()) |frame| try p1.feedOwned(frame);
    }

    try std.testing.expect(p1.sessionIsOpen());
    try std.testing.expect(p2.sessionIsOpen());
}

/// The exact `<ocapn-peer …>` record a hint-sending partner (a Goblins
/// `tcp-testing-only` netlayer) puts in its `op:start-session`. The wire bytes
/// are written verbatim rather than produced by pancake's encoder, because
/// the point under test is verification over the *received* bytes — whatever
/// hint representation the partner chose — not over a re-encode.
const hinted_locator_bytes = "<10'ocapn-peer3'tcp14\"127.0.0.1:9001{4\"host9\"127.0.0.14\"port9001+}>";

/// Build the complete keyed `op:start-session` frame a partner would send for
/// `hinted_locator_bytes` (optionally tampered after signing), signed with
/// `secret` over the canonical `<my-location …>` wrapping of the locator bytes.
fn hintedStartSessionFrame(
    allocator: std.mem.Allocator,
    secret: crypto.SecretKey,
    locator_bytes: []const u8,
) !foundation.Frame {
    const signed_domain = try codec.syrup.canonicalLocationSignedBytesRaw(allocator, hinted_locator_bytes);
    defer allocator.free(signed_domain);
    const sig = crypto.sign(&secret, signed_domain);
    const sig_bytes = sig.asBytes();
    const pubkey = secret.publicKey();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "<16'op:start-session3\"1.0");
    try out.appendSlice(allocator, "[10'public-key[3'ecc[5'curve7'Ed25519][5'flags5'eddsa][1'q32:");
    try out.appendSlice(allocator, pubkey.asBytes());
    try out.appendSlice(allocator, "]]]");
    try out.appendSlice(allocator, locator_bytes);
    try out.appendSlice(allocator, "[7'sig-val[5'eddsa[1'r32:");
    try out.appendSlice(allocator, sig_bytes[0..32]);
    try out.appendSlice(allocator, "][1's32:");
    try out.appendSlice(allocator, sig_bytes[32..64]);
    try out.appendSlice(allocator, "]]]>");
    const storage = try out.toOwnedSlice(allocator);
    return foundation.Frame.initOwned(allocator, storage, .byte, .fromByteUnits(1));
}

test "a verifying peer accepts a hinted-locator handshake (signature checked on received bytes)" {
    const allocator = std.testing.allocator;
    var verifier = engine.Peer.initNegotiating(allocator);
    defer verifier.deinit();
    verifier.verify_partner_handshake = true;

    const partner_secret = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x55)));
    const verifier_secret = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x66)));
    const verifier_loc: model.PeerLocator = .{
        .transport = "tcp",
        .designator = "127.0.0.1:9002",
        .hints = model.Hints.emptyFalse(),
    };

    try verifier.sendKeyedStartSession(verifier_loc, verifier_secret);
    _ = try verifier.step();
    var hello = verifier.takeOutbound().?;
    hello.deinit();

    // The partner's hello carries hint entries in its locator. Borrowed decode
    // projects them through `BorrowedHints`, but the signing domain is the
    // received `acceptable_location_raw` octets — re-encoding the structured
    // locator can miss the partner's exact representation and fail a valid signature.
    const frame = try hintedStartSessionFrame(allocator, partner_secret, hinted_locator_bytes);
    try verifier.feedOwned(frame);
    _ = try verifier.step();
    try std.testing.expect(verifier.sessionIsOpen());
}

test "a verifying peer refuses a hinted-locator handshake whose hint bytes were tampered" {
    const allocator = std.testing.allocator;
    var verifier = engine.Peer.initNegotiating(allocator);
    defer verifier.deinit();
    verifier.verify_partner_handshake = true;

    const partner_secret = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x55)));
    const verifier_secret = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x66)));
    const verifier_loc: model.PeerLocator = .{
        .transport = "tcp",
        .designator = "127.0.0.1:9002",
        .hints = model.Hints.emptyFalse(),
    };

    try verifier.sendKeyedStartSession(verifier_loc, verifier_secret);
    _ = try verifier.step();
    var hello = verifier.takeOutbound().?;
    hello.deinit();

    // Flip one digit inside the hint map after signing. The frame stays
    // structurally valid, so only a signature computed over the received hint
    // bytes can notice, proving the hints participate in the signed domain.
    const tampered = try allocator.dupe(u8, hinted_locator_bytes);
    defer allocator.free(tampered);
    tampered[std.mem.lastIndexOfScalar(u8, tampered, '1').?] = '2';
    const frame = try hintedStartSessionFrame(allocator, partner_secret, tampered);
    try verifier.feedOwned(frame);
    try std.testing.expectError(error.InvalidStartSessionSignature, verifier.step());
    try std.testing.expectEqual(session.State.closed, verifier.session_state.state);
}

test "the handshake records each partner's session key for later signature checks" {
    const allocator = std.testing.allocator;
    const p1_seed = @as([crypto.SEED_BYTES]u8, @splat(0x11));
    const p2_seed = @as([crypto.SEED_BYTES]u8, @splat(0x22));

    var pair = try pairing.pairedWithKeys(allocator, p1_seed, p2_seed);
    defer pair.deinit();

    // Each side should have learned the other's session public key from the
    // partner's op:start-session, the key an embedder verifies the partner's
    // signatures against (e.g. a gifter's handoff-give on a gifter-to-exporter
    // session, ADR-0009).
    const p1_pub = (crypto.SecretKey.fromSeed(p1_seed)).publicKey();
    const p2_pub = (crypto.SecretKey.fromSeed(p2_seed)).publicKey();

    const p1_learned = pair.p1.session_state.partnerSessionKey() orelse return error.NoPartnerKey;
    const p2_learned = pair.p2.session_state.partnerSessionKey() orelse return error.NoPartnerKey;
    try std.testing.expectEqualSlices(u8, p2_pub.asBytes(), p1_learned);
    try std.testing.expectEqualSlices(u8, p1_pub.asBytes(), p2_learned);
}

test "v1.0 resolver-callback accepts a record-shaped break reason (Goblins interop), not only desc:error" {
    const allocator = std.testing.allocator;
    var pair = try pairing.pairedV1_0Syrup(allocator);
    defer pair.deinit();

    // p1 calls the partner bootstrap, allocating answer 42 and a resolver export.
    try pair.p1.session_state.registerImport(.from(session.BOOTSTRAP_POSITION));
    try pair.p1.sendCopying(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(session.BOOTSTRAP_POSITION) } },
        .args = &.{.{ .bytes = "ping" }},
        .answer = .from(42),
        .resolve_me_desc = null,
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p1.step());
    const resolver_export = pair.p1.session_state.next_export_position - 1;

    const deliver_frame = pair.p1.takeOutbound().?;
    try pair.p2.feedOwned(deliver_frame);
    try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p2.step());
    {
        var event = pair.p2.pollEvent().?;
        event.deinit();
    }

    // A real Goblins promise that breaks from a thrown exception marshals the
    // reason as a record, not a desc:error. Simulate that shape: deliver
    // `['break, <exn:fail:mystery>]` to p1's resolver export (the V1.0
    // resolver-callback form), where the reason is a tagged record. pancake
    // cannot *emit* this (its breaks are desc:error), so it is sent by hand.
    try pair.p2.session_state.registerImport(.from(resolver_export));
    try pair.p2.sendCopying(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(resolver_export) } },
        .args = &.{ .{ .symbol = "break" }, .{ .tagged = .{ .tag = "exn:fail:mystery", .value = &.{} } } },
        .answer = null,
        .resolve_me_desc = null,
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p2.step());

    const break_frame = pair.p2.takeOutbound().?;
    try pair.p1.feedOwned(break_frame);
    // Before the fix this faulted (MalformedView → dispatch error); now p1
    // surfaces a resolve-break carrying the record's tag as the reason.
    try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p1.step());

    var event = pair.p1.pollEvent().?;
    defer event.deinit();
    try std.testing.expectEqual(engine.EventKind.resolve, event.kind());
    const view = try event.view();
    try std.testing.expectEqual(@as(u64, 42), view.resolve.answer.int());
    try std.testing.expect(view.resolve.resolution == .@"break");
    try std.testing.expectEqualSlices(u8, "exn:fail:mystery", view.resolve.resolution.@"break".message);
}
