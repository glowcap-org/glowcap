//! The Syrup signing domain: the exact bytes a `desc:sig-envelope` or an
//! `op:start-session` signature is computed over.
//!
//! A signature covers the Syrup-canonical encoding of a decoded record
//! (ADR-0009 / ADR-0003), regardless of which codec carried the envelope. These
//! functions name that signing domain and render it through `signing.zig`, the
//! same record owner the wire encoder uses.
//!
//! Codecs never sign or verify; they transport the typed object plus signature
//! bytes. The handoff and handshake drivers compute canonical bytes here and call
//! `foundation.crypto.sign` / `verify` at the wrap-and-intercept boundary.

const std = @import("std");

const model = @import("model");

const shared = @import("shared.zig");
const decode = @import("decode.zig");
const render = @import("render.zig");
const signing = @import("signing.zig");

const Error = shared.Error;

/// Canonical signed bytes for an `op:start-session` `acceptable-location`: the
/// Syrup encoding of `<my-location $acceptable-location>` (Goblins `captp.rkt`).
/// This is the exact byte domain `acceptable_location_sig` covers; both ends must
/// produce identical bytes for verification to succeed. Caller owns the slice.
pub fn canonicalLocationSignedBytes(
    allocator: std.mem.Allocator,
    location: model.PeerLocator,
) ![]u8 {
    return render.renderRecordExact(allocator, signing.writeMyLocationRecord, .{ allocator, location });
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
    return render.renderRecordExact(allocator, signing.writeMyLocationRecordRaw, .{location_record_bytes});
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
    return render.renderRecordExact(allocator, signing.writeHandoffGiveRecord, .{ allocator, give });
}

/// Canonical signed bytes for a borrowed handoff give. The view remains
/// borrowed throughout; only a lazy hint list, when present, is materialized as
/// canonical-encoding scratch and freed before return. A Syrup-forwarded give
/// carries its exact signed envelope, so that path reads no typed hints at all.
pub fn canonicalHandoffGiveViewSignedBytes(
    allocator: std.mem.Allocator,
    give: model.view.HandoffGive,
) ![]u8 {
    if (give.raw_signed) |raw| {
        return handoffGiveSignedPayloadBytes(allocator, raw);
    }
    var owned_hints: ?model.Hints = null;
    defer if (owned_hints) |hints| model.freeHints(allocator, hints);
    const hints = switch (give.exporter.hints) {
        .empty => |wire_form| model.Hints{ .wire_form = wire_form },
        .projected => |projected| projected,
        .lazy => blk: {
            const materialized = try give.exporter.hints.toOwned(allocator);
            owned_hints = materialized;
            break :blk materialized;
        },
    };
    const projected: model.HandoffGive = .{
        .recipient_key = give.recipient_key,
        .exporter = .{
            .transport = give.exporter.transport,
            .designator = give.exporter.designator,
            .hints = hints,
        },
        .gifter_exporter_session = give.gifter_exporter_session,
        .gifter_side = give.gifter_side,
        .gift_id = give.gift_id,
        .signature = "",
    };
    return canonicalHandoffGiveSignedBytes(allocator, projected);
}

/// Build the inner `<desc:handoff-give ...>` record taking the exporter location as
/// verbatim Syrup bytes (see `signing.writeHandoffGiveRecordRawLocation`). The
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
    return render.renderRecordExact(allocator, signing.writeHandoffGiveRecordRawLocation, .{
        recipient_key,
        exporter_location_raw,
        gifter_exporter_session,
        gifter_side,
        gift_id,
    });
}

/// Wrap an inner `desc:handoff-give` record and its 64-byte signature into the
/// `<desc:sig-envelope <record> <sig-val …>>` a recipient forwards or a gifter
/// returns. Caller owns the result.
pub fn wrapSignedHandoffGive(
    allocator: std.mem.Allocator,
    give_record: []const u8,
    signature: []const u8,
) ![]u8 {
    return render.renderRecordExact(allocator, signing.writeSigEnvelope, .{ give_record, signature });
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
    return render.renderRecordExact(allocator, signing.writeHandoffReceiveRecord, .{ allocator, receive });
}

/// Canonical signed bytes for a borrowed handoff receive. The signed give is
/// projected only for the duration of the encoder call; no owned receive is
/// built. Syrup's split signature is joined in a fixed stack buffer. A Syrup
/// receive also carries the give's exact signed envelope; when present, the
/// encoder uses it verbatim and typed give hints/signature are not materialized.
pub fn canonicalHandoffReceiveViewSignedBytes(
    allocator: std.mem.Allocator,
    receive: model.view.HandoffReceive,
) ![]u8 {
    var owned_hints: ?model.Hints = null;
    defer if (owned_hints) |hints| model.freeHints(allocator, hints);
    const hints = if (receive.signed_give.raw_signed != null)
        model.Hints.emptyFalse()
    else switch (receive.signed_give.exporter.hints) {
        .empty => |wire_form| model.Hints{ .wire_form = wire_form },
        .projected => |projected| projected,
        .lazy => blk: {
            const materialized = try receive.signed_give.exporter.hints.toOwned(allocator);
            owned_hints = materialized;
            break :blk materialized;
        },
    };
    var signature_buffer: [64]u8 = undefined;
    const give_signature = if (receive.signed_give.raw_signed != null)
        ""
    else switch (receive.signed_give.signature) {
        .raw => |raw| raw,
        .halves => |halves| blk: {
            if (halves.r.len + halves.s.len != signature_buffer.len) return Error.MalformedFrame;
            @memcpy(signature_buffer[0..halves.r.len], halves.r);
            @memcpy(signature_buffer[halves.r.len..], halves.s);
            break :blk signature_buffer[0..];
        },
    };
    const projected: model.HandoffReceive = .{
        .receiving_session = receive.receiving_session,
        .receiving_side = receive.receiving_side,
        .handoff_count = receive.handoff_count,
        .signed_give = .{
            .recipient_key = receive.signed_give.recipient_key,
            .exporter = .{
                .transport = receive.signed_give.exporter.transport,
                .designator = receive.signed_give.exporter.designator,
                .hints = hints,
            },
            .gifter_exporter_session = receive.signed_give.gifter_exporter_session,
            .gifter_side = receive.signed_give.gifter_side,
            .gift_id = receive.signed_give.gift_id,
            .signature = give_signature,
            .raw_signed = receive.signed_give.raw_signed,
        },
        .signature = "",
    };
    return canonicalHandoffReceiveSignedBytes(allocator, projected);
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
