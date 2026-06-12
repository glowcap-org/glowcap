//! Gifter-side handoff helpers (ADR-0009): building the signed
//! `desc:handoff-give` a gifter returns to a recipient once it has deposited the
//! gift with the exporter. The session and side naming is the recipient half's
//! (`handoff_recipient`); this adds the give construction. The I/O-bound
//! enliven / fetch / deposit choreography stays in the host adapter — these are
//! the crypto and encoding primitives any gifter needs.

const std = @import("std");

const codec = @import("codec");
const crypto = @import("foundation").crypto;
const recipient = @import("handoff_recipient.zig");

/// Goblins side name for a session public key (`sha256d` of its Syrup encoding).
pub const sideName = recipient.sideName;
/// Goblins session name for two sorted side names.
pub const sessionName = recipient.sessionName;
/// Double-SHA-256 a gifter uses to derive a stable gift id from a swissnum.
pub const sha256d = recipient.sha256d;

/// Build a signed `desc:handoff-give` the gifter returns to the recipient,
/// signed with the gifter's exporter-session key `secret`. `recipient_key` is
/// the recipient's session public key (32 bytes); `exporter_location_raw` is the
/// exporter's verbatim `op:start-session` locator bytes, embedded exactly so a
/// peer comparing the give's exporter location to the session location matches.
/// `gifter_exporter_session` is the session name shared by the gifter and the
/// exporter, and `gifter_side` is the gifter's own side name. The caller owns the
/// returned bytes and sets them as `model.HandoffGive.raw_signed` so the encoder
/// emits them verbatim.
pub fn buildSignedGive(
    allocator: std.mem.Allocator,
    secret: crypto.SecretKey,
    recipient_key: []const u8,
    exporter_location_raw: []const u8,
    gifter_exporter_session: []const u8,
    gifter_side: []const u8,
    gift_id: []const u8,
) ![]u8 {
    const record = try codec.syrup.handoffGiveRecordBytesRawLocation(
        allocator,
        recipient_key,
        exporter_location_raw,
        gifter_exporter_session,
        gifter_side,
        gift_id,
    );
    defer allocator.free(record);
    const sig = crypto.sign(&secret, record);
    return codec.syrup.wrapSignedHandoffGive(allocator, record, &sig.bytes);
}
