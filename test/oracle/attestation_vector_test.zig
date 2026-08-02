//! ADR-0097 provisional credential vectors (migration step 1).
//!
//! These vectors pin the durable-key `session-key-attestation` credential's
//! canonical bytes and signing domain, committed before the implementation so
//! the shape proposed upstream and the shape the code speaks cannot drift
//! apart silently; the keyed hello mint and the engine's verifier both build
//! the same record through `codec.signed.sessionKeyAttestationBytes`, the
//! builder under test here. The committed
//! fixtures are serialized by the upstream Racket Syrup encoder
//! (`generate.rkt`, held by `zig build fixture-gen-check`); this test derives
//! the same bytes from the deterministic seeds, verifies the positive
//! signature, and proves every mutation class the ADR names — transport,
//! designator, session key, signer, and signature bytes — fails verification.
//!
//! Deterministic material: durable Ed25519 seed `0x0D * 32`, session seed
//! `0x5E * 32`. The signing domain is the canonical Syrup record
//! `<session-key-attestation-v1 transport designator session-pubkey>`, signed
//! by the durable key whose canonical hex spelling is the locator designator.

const std = @import("std");
const pancake = @import("pancake");
const protocol_oracle = @import("protocol_oracle.zig");

const crypto = pancake.foundation.crypto;
const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const signed = pancake.ocapn.codec.signed;

const durable_seed = [_]u8{0x0d} ** crypto.SEED_BYTES;
const session_seed = [_]u8{0x5e} ** crypto.SEED_BYTES;

const attestation_hint_name = "session-key-attestation";
const vector_transport = "keyed-tcp";

/// The production signing-domain builder; the committed fixture stays the
/// byte authority (tied to the upstream Racket encoder by
/// `fixture-gen-check`), and this test holds the production encoder to it.
fn buildAttestationRecord(
    buf: *[signed.session_key_attestation_max_bytes]u8,
    transport: []const u8,
    designator: []const u8,
    session_pubkey: []const u8,
) ![]const u8 {
    return signed.sessionKeyAttestationBytes(buf, transport, designator, session_pubkey);
}

test "attestation record fixture reproduces from the deterministic seeds" {
    const durable = crypto.SecretKey.fromSeed(durable_seed);
    const session = crypto.SecretKey.fromSeed(session_seed);
    const designator = durable.publicKey().toDesignator();

    var buf: [signed.session_key_attestation_max_bytes]u8 = undefined;
    const record = try buildAttestationRecord(
        &buf,
        vector_transport,
        designator[0..],
        session.publicKey().asBytes(),
    );

    const fixture = protocol_oracle.fixtureByName("cred_session_key_attestation_v1.bin").?;
    try std.testing.expectEqualSlices(u8, fixture.bytes(), record);
}

test "attestation positive vector signs and verifies under the durable key" {
    const durable = crypto.SecretKey.fromSeed(durable_seed);
    const fixture = protocol_oracle.fixtureByName("cred_session_key_attestation_v1.bin").?;

    const sig = crypto.sign(&durable, fixture.bytes());
    try crypto.verify(durable.publicKey(), fixture.bytes(), sig);

    // The locator fixture carries this exact signature as its hint value, so
    // the two fixtures stay one self-consistent vector.
    const locator_fixture = protocol_oracle.fixtureByName("cred_locator_keyed_tcp_hint.bin").?;
    try std.testing.expect(std.mem.indexOf(u8, locator_fixture.bytes(), sig.asBytes()) != null);
}

test "attestation mutation negatives all fail verification" {
    const durable = crypto.SecretKey.fromSeed(durable_seed);
    const session = crypto.SecretKey.fromSeed(session_seed);
    const durable_pub = durable.publicKey();
    const designator = durable_pub.toDesignator();
    const session_pub = session.publicKey();

    const fixture = protocol_oracle.fixtureByName("cred_session_key_attestation_v1.bin").?;
    const sig = crypto.sign(&durable, fixture.bytes());

    var buf: [signed.session_key_attestation_max_bytes]u8 = undefined;

    // Mutated transport: the same designator and session key under `tcp`.
    {
        const record = try buildAttestationRecord(&buf, "tcp", designator[0..], session_pub.asBytes());
        try std.testing.expectError(crypto.CryptoError.InvalidSignature, crypto.verify(durable_pub, record, sig));
    }

    // Mutated designator: one hex character changed.
    {
        var mutated = designator;
        mutated[0] = if (mutated[0] == '0') '1' else '0';
        const record = try buildAttestationRecord(&buf, vector_transport, mutated[0..], session_pub.asBytes());
        try std.testing.expectError(crypto.CryptoError.InvalidSignature, crypto.verify(durable_pub, record, sig));
    }

    // Mutated session key: the durable public key substituted for the session's.
    {
        const record = try buildAttestationRecord(&buf, vector_transport, designator[0..], durable_pub.asBytes());
        try std.testing.expectError(crypto.CryptoError.InvalidSignature, crypto.verify(durable_pub, record, sig));
    }

    // Wrong signer: the session key's own signature must not verify as the
    // durable key's authorization.
    {
        const forged = crypto.sign(&session, fixture.bytes());
        try std.testing.expectError(crypto.CryptoError.InvalidSignature, crypto.verify(durable_pub, fixture.bytes(), forged));
    }

    // Corrupted signature byte.
    {
        var corrupt = sig;
        corrupt.bytes[17] ^= 0x01;
        try std.testing.expectError(crypto.CryptoError.InvalidSignature, crypto.verify(durable_pub, fixture.bytes(), corrupt));
    }

    // Truncated record: the domain label alone must not verify.
    {
        try std.testing.expectError(
            crypto.CryptoError.InvalidSignature,
            crypto.verify(durable_pub, fixture.bytes()[0 .. fixture.bytes().len - 1], sig),
        );
    }
}

test "hinted locator fixture round-trips through the production codec" {
    const allocator = std.testing.allocator;
    const durable = crypto.SecretKey.fromSeed(durable_seed);
    const designator = durable.publicKey().toDesignator();

    const record_fixture = protocol_oracle.fixtureByName("cred_session_key_attestation_v1.bin").?;
    const sig = crypto.sign(&durable, record_fixture.bytes());

    // Encode: the production verbatim locator encoder produces the committed
    // bytes for a keyed-tcp locator whose hint dict carries the credential.
    const entries = [_]model.HintEntry{.{
        .name = attestation_hint_name,
        .value = .{ .bytes = sig.asBytes() },
    }};
    const locator = model.PeerLocator{
        .transport = vector_transport,
        .designator = designator[0..],
        .hints = .{ .entries = entries[0..] },
    };
    const encoded = try engine.encodePeerLocatorRecord(allocator, locator);
    defer allocator.free(encoded);

    const locator_fixture = protocol_oracle.fixtureByName("cred_locator_keyed_tcp_hint.bin").?;
    try std.testing.expectEqualSlices(u8, locator_fixture.bytes(), encoded);

    // Decode: the production reader surfaces the credential entry exactly,
    // and re-encoding reproduces the fixture byte-for-byte.
    var cursor: usize = 0;
    const parsed = try engine.readLocatorOwned(allocator, locator_fixture.bytes(), &cursor);
    defer model.freePeerLocator(allocator, parsed);
    try std.testing.expectEqual(locator_fixture.bytes().len, cursor);
    try std.testing.expectEqualStrings(vector_transport, parsed.transport);
    try std.testing.expectEqualStrings(designator[0..], parsed.designator);
    try std.testing.expectEqual(@as(usize, 1), parsed.hints.entries.len);
    try std.testing.expectEqualStrings(attestation_hint_name, parsed.hints.entries[0].name);
    try std.testing.expectEqualSlices(u8, sig.asBytes(), parsed.hints.entries[0].value.bytes);

    const reencoded = try engine.encodePeerLocatorRecord(allocator, parsed);
    defer allocator.free(reencoded);
    try std.testing.expectEqualSlices(u8, locator_fixture.bytes(), reencoded);
}
