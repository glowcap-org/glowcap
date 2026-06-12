//! Recipient-side handoff helpers (ADR-0009): session/side naming and signed
//! `desc:handoff-receive` construction. I/O-bound withdraw choreography stays in
//! the adapter; these are the crypto/session primitives any host needs.

const std = @import("std");

const model = @import("model");
const codec = @import("codec");
const crypto = @import("foundation").crypto;

const Sha256 = std.crypto.hash.sha2.Sha256;

pub fn sha256d(data: []const u8) [32]u8 {
    var once: [32]u8 = undefined;
    Sha256.hash(data, &once, .{});
    var twice: [32]u8 = undefined;
    Sha256.hash(&once, &twice, .{});
    return twice;
}

/// Render the canonical `public-key` s-expression Goblins hashes into a side
/// name. The key must be exactly a 32-byte Ed25519 public key — the only width
/// the protocol uses. A non-32-byte key is rejected (`MalformedKey`) rather than
/// silently producing a Goblins-incompatible name, and the rejection forecloses
/// an over-long key overflowing `buf`. The literal `32:` length prefix below is
/// pinned to `crypto.PEER_KEY_BYTES` by the comptime assert.
pub fn pubkeySyrup(buf: []u8, key: []const u8) error{MalformedKey}![]u8 {
    comptime std.debug.assert(crypto.PEER_KEY_BYTES == 32);
    if (key.len != crypto.PEER_KEY_BYTES) return error.MalformedKey;
    const prefix = "[10'public-key[3'ecc[5'curve7'Ed25519][5'flags5'eddsa][1'q32:";
    var w: usize = 0;
    @memcpy(buf[w..][0..prefix.len], prefix);
    w += prefix.len;
    @memcpy(buf[w..][0..key.len], key);
    w += key.len;
    const suffix = "]]]";
    @memcpy(buf[w..][0..suffix.len], suffix);
    w += suffix.len;
    return buf[0..w];
}

pub fn sideName(key: []const u8) error{MalformedKey}![32]u8 {
    var buf: [128]u8 = undefined;
    return sha256d(try pubkeySyrup(&buf, key));
}

pub fn sessionName(side_a: [32]u8, side_b: [32]u8) [32]u8 {
    const first, const second = if (std.mem.lessThan(u8, &side_a, &side_b)) .{ side_a, side_b } else .{ side_b, side_a };
    var buf: [5 + 32 + 32]u8 = undefined;
    @memcpy(buf[0..5], "prot0");
    @memcpy(buf[5..37], &first);
    @memcpy(buf[37..69], &second);
    return sha256d(&buf);
}

/// A signed `desc:handoff-receive` that owns its derived bytes. The session and
/// side names and the signature live inline, so the `model.HandoffReceive` that
/// `message` projects borrows only this value — no dangling stack references
/// once the builder returns. The caller holds the `SignedReceive` until the
/// withdraw it carries has been encoded, and keeps owning `give_bytes`.
pub const SignedReceive = struct {
    receiving_session: [32]u8,
    receiving_side: [32]u8,
    signature: [crypto.SIGNATURE_BYTES]u8,
    give_bytes: []const u8,
    handoff_count: u64,

    /// Project the borrowed wire `desc:handoff-receive`. The returned value
    /// borrows `self`, so `self` must outlive every use of it.
    pub fn message(self: *const SignedReceive) model.HandoffReceive {
        return .{
            .receiving_session = &self.receiving_session,
            .receiving_side = &self.receiving_side,
            .handoff_count = self.handoff_count,
            .signed_give = .{
                .recipient_key = "",
                .exporter_location = "",
                .gifter_exporter_session = "",
                .gifter_side = "",
                .gift_id = "",
                .signature = "",
                .raw_signed = self.give_bytes,
            },
            .signature = &self.signature,
        };
    }
};

/// Build a signed `desc:handoff-receive` embedding the gifter's exact give bytes,
/// returning a self-contained `SignedReceive` the caller keeps alive while it
/// encodes the withdraw. `secret` is the recipient's session key — the one the
/// gifter named as the give's recipient key — so the exporter verifies the
/// receive against it.
pub fn signedReceiveFromGiveBytes(
    allocator: std.mem.Allocator,
    secret: crypto.SecretKey,
    our_pubkey: crypto.PeerKey,
    exporter_partner_key: []const u8,
    give_bytes: []const u8,
    handoff_count: u64,
) !SignedReceive {
    const our_side = try sideName(our_pubkey.asBytes());
    const exporter_side = try sideName(exporter_partner_key);
    var result: SignedReceive = .{
        .receiving_session = sessionName(our_side, exporter_side),
        .receiving_side = our_side,
        .signature = [_]u8{0} ** crypto.SIGNATURE_BYTES,
        .give_bytes = give_bytes,
        .handoff_count = handoff_count,
    };
    const receive_signed = try codec.syrup.canonicalHandoffReceiveSignedBytes(allocator, result.message());
    defer allocator.free(receive_signed);
    result.signature = crypto.sign(&secret, receive_signed).bytes;
    return result;
}
