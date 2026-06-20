//! The Syrup signing domain: the exact bytes a `desc:sig-envelope` or an
//! `op:start-session` signature is computed over.
//!
//! This is deliberately a surface of its own, distinct from the wire encoder in
//! `encode.zig`. A signature covers the **Syrup-canonical** encoding of a decoded
//! record (ADR-0009 / ADR-0003), regardless of which codec carried the wrapping
//! envelope, so a `desc:handoff-give` re-encoded into Cap'n Proto stays
//! verifiable by re-canonicalizing the typed record back to these bytes. The
//! functions here name that signing domain; they build their byte products from
//! `encode.zig`'s record writers, so the domain can never drift from what goes on
//! the wire, while the wire encoder's leaf primitives stay private to it.
//!
//! Codecs never sign or verify; they transport the typed object plus signature
//! bytes. The handoff and handshake drivers compute canonical bytes here and call
//! `foundation.crypto.sign` / `verify` at the wrap-and-intercept boundary.

const std = @import("std");

const model = @import("model");

const shared = @import("shared.zig");
const decode = @import("decode.zig");
const encode = @import("encode.zig");

const Error = shared.Error;

/// Canonical signed bytes for an `op:start-session` `acceptable-location`: the
/// Syrup encoding of `<my-location $acceptable-location>` (Goblins `captp.rkt`).
/// This is the exact byte domain `acceptable_location_sig` covers; both ends must
/// produce identical bytes for verification to succeed. Caller owns the slice.
pub fn canonicalLocationSignedBytes(
    allocator: std.mem.Allocator,
    location: model.PeerLocator,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try encode.writeMyLocationRecord(allocator, &out, location);
    return out.toOwnedSlice(allocator);
}

/// As `canonicalLocationSignedBytes`, but wraps the *exact received*
/// location-record bytes instead of re-encoding a decoded locator, so a verifier
/// agrees byte-for-byte with the signer even for a locator whose hints the
/// borrowed decode did not retain. Pass the `acceptable_location_raw` a Syrup
/// `op:start-session` decode captured. Caller owns the slice.
pub fn canonicalLocationSignedBytesRaw(
    allocator: std.mem.Allocator,
    location_record_bytes: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try encode.writeMyLocationRecordRaw(allocator, &out, location_record_bytes);
    return out.toOwnedSlice(allocator);
}

/// Canonical signed bytes for a `desc:handoff-give`: the Syrup encoding of the
/// inner `<desc:handoff-give recipient-key exporter-location
/// gifter-exporter-session gifter-side gift-id>` record, exactly the byte domain
/// the gifter's `desc:sig-envelope` signature covers. Hand this to `crypto.sign`
/// or `crypto.verify`. A give carrying verbatim signed bytes (`raw_signed`, a
/// forwarded give) re-derives the payload from those bytes so the exporter
/// re-verifies over what the gifter signed. Caller owns the slice.
pub fn canonicalHandoffGiveSignedBytes(
    allocator: std.mem.Allocator,
    give: model.HandoffGive,
) ![]u8 {
    if (give.raw_signed) |raw| {
        return handoffGiveSignedPayloadBytes(allocator, raw);
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try encode.writeHandoffGiveRecord(allocator, &out, give);
    return out.toOwnedSlice(allocator);
}

/// Build the inner `<desc:handoff-give …>` record taking the exporter location as
/// verbatim Syrup bytes (see `encode.writeHandoffGiveRecordRawLocation`). The
/// returned bytes are the signing domain (caller owns them) and feed
/// `wrapSignedHandoffGive`.
pub fn handoffGiveRecordBytesRawLocation(
    allocator: std.mem.Allocator,
    recipient_key: []const u8,
    exporter_location_raw: []const u8,
    gifter_exporter_session: []const u8,
    gifter_side: []const u8,
    gift_id: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try encode.writeHandoffGiveRecordRawLocation(
        allocator,
        &out,
        recipient_key,
        exporter_location_raw,
        gifter_exporter_session,
        gifter_side,
        gift_id,
    );
    return out.toOwnedSlice(allocator);
}

/// Wrap an inner `desc:handoff-give` record and its 64-byte signature into the
/// `<desc:sig-envelope <record> <sig-val …>>` a recipient forwards or a gifter
/// returns. Caller owns the result.
pub fn wrapSignedHandoffGive(
    allocator: std.mem.Allocator,
    give_record: []const u8,
    signature: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try encode.writeSigEnvelope(allocator, &out, give_record, signature);
    return out.toOwnedSlice(allocator);
}

/// Canonical signed bytes for a `desc:handoff-receive`: the Syrup encoding of the
/// inner `<desc:handoff-receive receiving-session receiving-side handoff-count
/// <signed-give>>` record, the byte domain the recipient's `desc:sig-envelope`
/// signature covers. The record embeds the already-signed give envelope, so
/// verifying the receive does not re-derive the give's signature. Caller owns the
/// slice.
pub fn canonicalHandoffReceiveSignedBytes(
    allocator: std.mem.Allocator,
    receive: model.HandoffReceive,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try encode.writeHandoffReceiveRecord(allocator, &out, receive);
    return out.toOwnedSlice(allocator);
}

/// Recover the inner `<desc:handoff-give …>` payload bytes from a verbatim signed
/// `<desc:sig-envelope <desc:handoff-give …> <sig-val …>>`, the byte domain the
/// gifter signed. Used when a forwarded give carries `raw_signed`.
fn handoffGiveSignedPayloadBytes(allocator: std.mem.Allocator, raw_signed: []const u8) ![]u8 {
    var cursor: usize = 0;
    try decode.readByte(raw_signed, &cursor, '<');
    const envelope_tag = try decode.readSymbol(raw_signed, &cursor);
    if (!std.mem.eql(u8, envelope_tag, "desc:sig-envelope")) return Error.MalformedFrame;

    const payload_start = cursor;
    try decode.readByte(raw_signed, &cursor, '<');
    const payload_tag = try decode.readSymbol(raw_signed, &cursor);
    if (!std.mem.eql(u8, payload_tag, "desc:handoff-give")) return Error.MalformedFrame;

    cursor = payload_start;
    _ = try decode.readBalanced(raw_signed, &cursor, '<', '>');
    const payload_end = cursor;
    _ = try decode.readSignatureView(raw_signed, &cursor);
    try decode.readByte(raw_signed, &cursor, '>');
    try decode.expectEnd(raw_signed, cursor);

    return allocator.dupe(u8, raw_signed[payload_start..payload_end]);
}
