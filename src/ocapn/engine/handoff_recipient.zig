//! Recipient-side handoff helpers (ADR-0009): session/side naming and signed
//! `desc:handoff-receive` construction. I/O-bound withdraw choreography stays in
//! the adapter; these are the crypto/session primitives any host needs.

const std = @import("std");

const model = @import("model");
const codec = @import("codec");
const crypto = @import("foundation").crypto;
const session_mod = @import("session");
const bootstrap = @import("bootstrap.zig");

/// Goblins "side name" for a session public key — the OCapN Public Identifier
/// (`crypto.derivePublicIdentifier`), surfaced as its raw 32 bytes for the
/// handoff records that carry it. Single-sourced against the foundation
/// derivation so the side a handoff names can never drift from the side a
/// handshake derives. The key must be exactly a 32-byte Ed25519 public key — the
/// only width the protocol uses; any other length is `MalformedKey`.
pub fn sideName(key: []const u8) error{MalformedKey}![32]u8 {
    const peer_key = crypto.PeerKey.fromSlice(key) catch return error.MalformedKey;
    return crypto.derivePublicIdentifier(peer_key).bytes;
}

/// Goblins "session name" for two side names, the OCapN Session ID
/// (`crypto.sessionIdFromPeerIds`) computed from sides the caller already holds.
pub fn sessionName(side_a: [32]u8, side_b: [32]u8) [32]u8 {
    return crypto.sessionIdFromPeerIds(.fromBytes(side_a), .fromBytes(side_b)).bytes;
}

/// A signed `desc:handoff-receive` that owns its derived bytes, including the
/// gifter's give it parsed from `give_bytes` (`give` carries both `raw_signed`,
/// for a Syrup session's verbatim fast path, and the typed fields a Cap'n Proto
/// session encodes instead — so the receive rides *this* session's codec, not
/// just Syrup's). The session and side names and the signature live inline, so
/// the `model.HandoffReceive` that `message` projects borrows only this value,
/// no dangling stack references once the builder returns. The caller holds the
/// `SignedReceive` until the withdraw it carries has been encoded, then
/// releases it with `deinit`.
pub const SignedReceive = struct {
    receiving_session: [32]u8,
    receiving_side: [32]u8,
    signature: [crypto.SIGNATURE_BYTES]u8,
    give: model.HandoffGive,
    handoff_count: u64,

    /// Project the borrowed wire `desc:handoff-receive`. The returned value
    /// borrows `self`, so `self` must outlive every use of it.
    pub fn message(self: *const SignedReceive) model.HandoffReceive {
        return .{
            .receiving_session = &self.receiving_session,
            .receiving_side = &self.receiving_side,
            .handoff_count = self.handoff_count,
            .signed_give = self.give,
            .signature = &self.signature,
        };
    }

    /// Release the give `signedReceiveFromGiveBytes` parsed and owns. Safe to
    /// call once the withdraw `message()` projected has been encoded —
    /// `sendCopying` deep-copies before it returns, so the caller's one send
    /// call always finishes first.
    pub fn deinit(self: *const SignedReceive, allocator: std.mem.Allocator) void {
        model.freeHandoffGive(allocator, self.give);
    }
};

/// Build a signed `desc:handoff-receive` embedding the gifter's give, returning
/// a self-contained `SignedReceive` the caller keeps alive while it encodes the
/// withdraw, then releases with `SignedReceive.deinit`. `give_bytes` is the
/// Syrup-encoded `<desc:sig-envelope …>` a gifter returned (or a binding's
/// `pancake_build_handoff_give` built); it is parsed once here into a typed,
/// codec-neutral give. `secret` is the recipient's session key — the one the
/// gifter named as the give's recipient key — so the exporter verifies the
/// receive against it. The `handoff_count` is minted from `registry` against the
/// derived receiving session, so the monotonic replay counter is owned by the
/// vat-scoped registry here rather than re-tracked by every caller (ADR-0056).
pub fn signedReceiveFromGiveBytes(
    allocator: std.mem.Allocator,
    limits: session_mod.SessionLimits,
    registry: *bootstrap.GiftRegistry,
    secret: crypto.SecretKey,
    our_pubkey: crypto.PeerKey,
    exporter_partner_key: []const u8,
    give_bytes: []const u8,
) !SignedReceive {
    const give = try codec.syrup.decodeSignedHandoffGiveOwned(allocator, give_bytes);
    errdefer model.freeHandoffGive(allocator, give);
    const our_side = try sideName(our_pubkey.asBytes());
    const exporter_side = try sideName(exporter_partner_key);
    const receiving_session = sessionName(our_side, exporter_side);
    const handoff_count = try registry.nextEmittedCount(allocator, limits, &receiving_session);
    var result: SignedReceive = .{
        .receiving_session = receiving_session,
        .receiving_side = our_side,
        .signature = [_]u8{0} ** crypto.SIGNATURE_BYTES,
        .give = give,
        .handoff_count = handoff_count,
    };
    const receive_signed = try codec.syrup.canonicalHandoffReceiveSignedBytes(allocator, result.message());
    defer allocator.free(receive_signed);
    result.signature = crypto.sign(&secret, receive_signed).bytes;
    return result;
}

/// Project a give's exporter location into the dialable `ocapn://…` URI a
/// recipient hands its dialer, through the one core URI grammar. A verbatim
/// locator record re-parses with hints (an iroh exporter's direct addresses);
/// a hint-less flat locator formats directly. Returns null for a `.raw` opaque
/// location — the recipient cannot dial it — and `MalformedLocatorRecord` for
/// a record that no longer parses. The caller owns the returned bytes.
pub const LocatorUriError = error{ OutOfMemory, MalformedLocatorRecord };
pub fn exporterLocatorUri(
    allocator: std.mem.Allocator,
    location: model.view.ExporterLocation,
) LocatorUriError!?[]u8 {
    switch (location) {
        .raw => return null,
        .locator => |loc| {
            if (loc.record.len > 0) {
                var cursor: usize = 0;
                const parsed = codec.syrup.readLocatorOwned(allocator, loc.record, &cursor) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.MalformedLocatorRecord,
                };
                defer model.freePeerLocator(allocator, parsed);
                return model.uri.writePeer(allocator, parsed) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.MalformedLocatorRecord,
                };
            }
            return model.uri.writePeer(allocator, .{
                .transport = loc.transport,
                .designator = loc.designator,
                .hints = model.Hints.emptyFalse(),
            }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.MalformedLocatorRecord,
            };
        },
    }
}
