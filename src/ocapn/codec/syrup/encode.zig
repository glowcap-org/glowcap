//! The Syrup encoder: `model.Message` to wire bytes.
//!
//! This is the encode half of the Syrup codec. It owns `encodeMessage` and
//! `encodeMessageForProfile`, the canonical signed-byte builders the handshake
//! and handoff drivers sign over (`canonicalLocationSignedBytes` and friends),
//! and the little `write*` record/list/leaf primitives beneath them. The shared
//! `Error` and `WalkError` sets live in `shared`; this file builds
//! bytes and holds no session authority. The decode half is `decode`.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");

const shared = @import("shared.zig");
const decode = @import("decode.zig");

const Error = shared.Error;
const WalkError = shared.WalkError;
const EncodeError = shared.EncodeError;

pub fn encodeMessage(allocator: std.mem.Allocator, message: model.Message) EncodeError!foundation.Frame {
    return encodeMessageForProfile(allocator, model.WireProfile.v1_0, message);
}

/// ADR-0006 canonical signed bytes for an `op:start-session`
/// `acceptable-location`: the Syrup encoding of the wrapping record
/// `<my-location $acceptable-location>` (per Goblins `captp.rkt`).
///
/// This is the exact byte domain `acceptable_location_sig` signs over. Both
/// ends must produce identical bytes for verification to succeed, so it is
/// single-sourced here against the codec's own locator encoder rather than
/// re-derived at the signing site. Caller owns the returned slice.
pub fn canonicalLocationSignedBytes(
    allocator: std.mem.Allocator,
    location: model.PeerLocator,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try beginRecord(allocator, &out);
    try writeSymbol(allocator, &out, "my-location");
    try writeLocator(allocator, &out, location);
    try endRecord(allocator, &out);
    return out.toOwnedSlice(allocator);
}

/// As `canonicalLocationSignedBytes`, but wraps the *exact received*
/// location-record bytes instead of re-encoding a decoded locator. The
/// `<my-location …>` framing is single-sourced against the same record writers,
/// so a peer that signs via `canonicalLocationSignedBytes` and a peer that
/// verifies via this function agree byte-for-byte — and verification stays
/// correct for a locator whose hints the borrowed decode does not retain. Pass
/// the `acceptable_location_raw` a Syrup `op:start-session` decode captured.
/// Caller owns the returned slice.
pub fn canonicalLocationSignedBytesRaw(
    allocator: std.mem.Allocator,
    location_record_bytes: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try beginRecord(allocator, &out);
    try writeSymbol(allocator, &out, "my-location");
    try out.appendSlice(allocator, location_record_bytes);
    try endRecord(allocator, &out);
    return out.toOwnedSlice(allocator);
}

/// Canonical signed bytes for a `desc:handoff-give`: the Syrup encoding of the
/// inner `<desc:handoff-give recipient-key exporter-location
/// gifter-exporter-session gifter-side gift-id>` record. That record is exactly
/// the byte domain the gifter's `desc:sig-envelope` signature covers, so this is
/// what you hand to `crypto.verify` (or `crypto.sign`) to check a handoff the
/// same way `canonicalLocationSignedBytes` lets you check an `op:start-session`
/// location signature. It is single-sourced against the wire encoder
/// (`writeHandoffGiveRecord`), so the signing domain can never drift from the
/// bytes that go on the wire. Caller owns the returned slice.
pub fn canonicalHandoffGiveSignedBytes(
    allocator: std.mem.Allocator,
    give: model.HandoffGive,
) ![]u8 {
    if (give.raw_signed) |raw| {
        return handoffGiveSignedPayloadBytes(allocator, raw);
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try writeHandoffGiveRecord(allocator, &out, give);
    return out.toOwnedSlice(allocator);
}

/// Build the inner `<desc:handoff-give recipient-key exporter-location
/// gifter-exporter-session gifter-side gift-id>` record, taking the exporter
/// location as **verbatim** Syrup bytes rather than a flattened
/// `transport:designator`. A gifter that learned the exporter's location from its
/// `op:start-session` must reproduce it byte-for-byte — hints and all — so a peer
/// comparing the give's exporter location to the session location matches; the
/// locator encoder cannot round-trip arbitrary hints. The returned bytes are the
/// signing domain (caller owns them) and feed `wrapSignedHandoffGive`.
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
    try beginRecord(allocator, &out);
    try writeSymbol(allocator, &out, "desc:handoff-give");
    try writePeerKey(allocator, &out, recipient_key);
    try out.appendSlice(allocator, exporter_location_raw);
    try writeBytes(allocator, &out, gifter_exporter_session);
    try writeBytes(allocator, &out, gifter_side);
    try writeBytes(allocator, &out, gift_id);
    try endRecord(allocator, &out);
    return out.toOwnedSlice(allocator);
}

/// Wrap an inner `desc:handoff-give` record and its 64-byte signature into the
/// `<desc:sig-envelope <record> <sig-val …>>` a recipient forwards or a gifter
/// returns. The caller owns the result.
pub fn wrapSignedHandoffGive(
    allocator: std.mem.Allocator,
    give_record: []const u8,
    signature: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try beginRecord(allocator, &out);
    try writeSymbol(allocator, &out, "desc:sig-envelope");
    try out.appendSlice(allocator, give_record);
    try writeSignature(allocator, &out, signature);
    try endRecord(allocator, &out);
    return out.toOwnedSlice(allocator);
}

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

/// Canonical signed bytes for a `desc:handoff-receive`: the Syrup encoding of the
/// inner `<desc:handoff-receive receiving-session receiving-side handoff-count
/// <signed-give>>` record — the byte domain the recipient's `desc:sig-envelope`
/// signature covers. The record embeds the already-signed give envelope, so
/// verifying the receive certificate does not re-derive the give's signature.
/// Single-sourced against `writeHandoffReceiveRecord`. Caller owns the slice.
pub fn canonicalHandoffReceiveSignedBytes(
    allocator: std.mem.Allocator,
    receive: model.HandoffReceive,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try writeHandoffReceiveRecord(allocator, &out, receive);
    return out.toOwnedSlice(allocator);
}

pub fn encodeMessageForProfile(
    allocator: std.mem.Allocator,
    profile: model.WireProfile,
    message: model.Message,
) EncodeError!foundation.Frame {
    if (profile.captp_version == .v1_0 and message == .resolve) return Error.UnsupportedMessage;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    switch (message) {
        .abort => |abort| {
            try beginRecord(allocator, &out);
            try writeSymbol(allocator, &out, shared.messageOp(.abort));
            try writeAbortWireString(allocator, &out, abort);
            try endRecord(allocator, &out);
        },
        .deliver => |deliver| {
            // A no-answer deliver is a single `op:deliver` with a `#f` answer
            // position — the fire-and-forget one-way send. There is no separate
            // one-way record on the wire.
            try beginRecord(allocator, &out);
            try writeSymbol(allocator, &out, shared.messageOp(.deliver));
            try writeTargetReference(allocator, &out, deliver.target);
            try writeArgumentList(allocator, &out, deliver.args);
            if (deliver.answer) |answer| {
                try writePositiveInt(allocator, &out, answer);
            } else {
                try writeBool(allocator, &out, false);
            }
            if (profile.captp_version == .v1_0 and deliver.resolve_me_desc != null) {
                try writePayloadReference(allocator, &out, deliver.resolve_me_desc.?);
            } else {
                try writeBool(allocator, &out, false);
            }
            try endRecord(allocator, &out);
        },
        .resolve => |resolve| {
            try beginRecord(allocator, &out);
            try writeSymbol(allocator, &out, shared.messageOp(.resolve));
            try writePositiveInt(allocator, &out, resolve.answer);
            switch (resolve.resolution) {
                .fulfill => |arg| {
                    try beginRecord(allocator, &out);
                    try writeSymbol(allocator, &out, "resolve:fulfill");
                    try writeArgument(allocator, &out, arg);
                    try endRecord(allocator, &out);
                },
                .@"break" => |err| {
                    try beginRecord(allocator, &out);
                    try writeSymbol(allocator, &out, "resolve:break");
                    try writeError(allocator, &out, err);
                    try endRecord(allocator, &out);
                },
            }
            try endRecord(allocator, &out);
        },
        .gc_export => |gc_export| {
            try beginRecord(allocator, &out);
            try writeSymbol(allocator, &out, shared.messageOp(.gc_export));
            try writeUnsignedList(allocator, &out, gc_export.positions);
            try writeUnsignedList(allocator, &out, gc_export.deltas);
            try endRecord(allocator, &out);
        },
        .gc_answer => |gc_answer| {
            try beginRecord(allocator, &out);
            try writeSymbol(allocator, &out, shared.messageOp(.gc_answer));
            try writeUnsignedList(allocator, &out, gc_answer.positions);
            try endRecord(allocator, &out);
        },
        .get => |get| {
            try beginRecord(allocator, &out);
            try writeSymbol(allocator, &out, shared.messageOp(.get));
            try writeTargetReference(allocator, &out, get.receiver);
            // The field name is a String on the wire (CapTP § op:get; Goblins
            // guards `string?` on receipt), not a Symbol.
            try writeString(allocator, &out, get.field);
            try writePositiveInt(allocator, &out, get.answer);
            try endRecord(allocator, &out);
        },
        .index => |index| {
            try beginRecord(allocator, &out);
            try writeSymbol(allocator, &out, shared.messageOp(.index));
            try writeTargetReference(allocator, &out, index.receiver);
            try writeInteger(allocator, &out, index.index);
            try writePositiveInt(allocator, &out, index.answer);
            try endRecord(allocator, &out);
        },
        .untag => |untag| {
            try beginRecord(allocator, &out);
            try writeSymbol(allocator, &out, shared.messageOp(.untag));
            try writeTargetReference(allocator, &out, untag.receiver);
            // The expected tag is a String on the wire (CapTP § op:untag),
            // matching op:get's field-name choice.
            try writeString(allocator, &out, untag.tag);
            try writePositiveInt(allocator, &out, untag.answer);
            try endRecord(allocator, &out);
        },
        .listen => |listen| {
            try beginRecord(allocator, &out);
            try writeSymbol(allocator, &out, shared.messageOp(.listen));
            try writePayloadReference(allocator, &out, listen.target);
            try writePayloadReference(allocator, &out, listen.listener);
            if (profile.captp_version == .v1_0) {
                try writeBool(allocator, &out, listen.wants_partial);
            }
            try endRecord(allocator, &out);
        },
        .start_session => |start_session| {
            try beginRecord(allocator, &out);
            try writeSymbol(allocator, &out, shared.messageOp(.start_session));
            try writeString(allocator, &out, start_session.captp_version.wireString());
            try writePeerKey(allocator, &out, start_session.session_pubkey.bytes);
            try writeLocator(allocator, &out, start_session.acceptable_location);
            try writeSignature(allocator, &out, start_session.acceptable_location_sig.bytes);
            try endRecord(allocator, &out);
        },
        .handoff => |handoff| try writeHandoff(allocator, &out, handoff),
    }

    const storage = try out.toOwnedSlice(allocator);
    return try foundation.Frame.initOwned(allocator, storage, .byte, .fromByteUnits(1));
}

fn beginRecord(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    try out.append(allocator, '<');
}

fn endRecord(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    try out.append(allocator, '>');
}

fn writeSymbol(allocator: std.mem.Allocator, out: *std.ArrayList(u8), symbol: []const u8) !void {
    try writeUnsigned(allocator, out, symbol.len);
    try out.append(allocator, '\'');
    try out.appendSlice(allocator, symbol);
}

fn writeString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), string: []const u8) !void {
    try writeUnsigned(allocator, out, string.len);
    try out.append(allocator, '"');
    try out.appendSlice(allocator, string);
}

fn writeAbortWireString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), abort: model.AbortReason) !void {
    if (abort.kind == .other) {
        try writeString(allocator, out, abort.message);
        return;
    }

    const label = abort.kind.wireName();
    try writeUnsigned(allocator, out, label.len + ": ".len + abort.message.len);
    try out.append(allocator, '"');
    try out.appendSlice(allocator, label);
    try out.appendSlice(allocator, ": ");
    try out.appendSlice(allocator, abort.message);
}

fn writeBytes(allocator: std.mem.Allocator, out: *std.ArrayList(u8), bytes: []const u8) !void {
    try writeUnsigned(allocator, out, bytes.len);
    try out.append(allocator, ':');
    try out.appendSlice(allocator, bytes);
}

fn writeInteger(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: i64) !void {
    if (value < 0) {
        try writeSignedMagnitude(allocator, out, value);
        try out.append(allocator, '-');
    } else {
        try writePositiveInt(allocator, out, @intCast(value));
    }
}

fn writePositiveInt(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u64) !void {
    try writeUnsigned(allocator, out, value);
    try out.append(allocator, '+');
}

fn writeBool(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: bool) !void {
    try out.append(allocator, if (value) 't' else 'f');
}

/// Syrup encodes a `binary64` double as `'D'` followed by 8 bytes IEEE-754
/// big-endian. The model carries only `float64`; `'F'` (binary32) is not a
/// pancake passable.
fn writeFloat64(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: f64) !void {
    try out.append(allocator, 'D');
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, @bitCast(value), .big);
    try out.appendSlice(allocator, buf[0..]);
}

fn writeArgumentList(allocator: std.mem.Allocator, out: *std.ArrayList(u8), args: []const model.Argument) WalkError!void {
    try out.append(allocator, '[');
    for (args) |arg| {
        try writeArgument(allocator, out, arg);
    }
    try out.append(allocator, ']');
}

fn writeUnsignedList(allocator: std.mem.Allocator, out: *std.ArrayList(u8), values: []const u64) !void {
    try out.append(allocator, '[');
    for (values) |value| {
        try writePositiveInt(allocator, out, value);
    }
    try out.append(allocator, ']');
}

fn beginList(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    try out.append(allocator, '[');
}

fn endList(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    try out.append(allocator, ']');
}

fn writeArgument(allocator: std.mem.Allocator, out: *std.ArrayList(u8), arg: model.Argument) WalkError!void {
    switch (arg) {
        .bytes => |bytes| try writeBytes(allocator, out, bytes),
        .symbol => |symbol| try writeSymbol(allocator, out, symbol),
        .reference => |reference| try writePayloadReference(allocator, out, reference),
        .string => |string| try writeString(allocator, out, string),
        .handoff => |handoff| try writeHandoff(allocator, out, handoff.*),
        .integer => |integer| try writeInteger(allocator, out, integer),
        .float64 => |value| try writeFloat64(allocator, out, value),
        .boolean => |value| try writeBool(allocator, out, value),
        .list => |items| try writeArgumentList(allocator, out, items),
        .void => {
            try beginRecord(allocator, out);
            try writeSymbol(allocator, out, "void");
            try endRecord(allocator, out);
        },
        .set => |items| {
            try out.append(allocator, '#');
            try writeCanonicalSet(allocator, out, items);
            try out.append(allocator, '$');
        },
        .@"struct" => |entries| {
            try out.append(allocator, '{');
            try writeCanonicalStruct(allocator, out, entries);
            try out.append(allocator, '}');
        },
        .tagged => |tagged| {
            try beginRecord(allocator, out);
            try writeSymbol(allocator, out, "user-record");
            try writeSymbol(allocator, out, tagged.tag);
            try writeArgumentList(allocator, out, tagged.value);
            try endRecord(allocator, out);
        },
        .keyword => |keyword| {
            try beginRecord(allocator, out);
            try writeSymbol(allocator, out, "kw");
            try writeSymbol(allocator, out, keyword);
            try endRecord(allocator, out);
        },
        // An `<error message>` in argument position — symmetric with the decoder,
        // which reads this record back into `.@"error"` (`readNeutralArgument`).
        // The load-bearing case is a Goblins V1.0 resolver-callback `break`
        // resolution, which ships its `model.BreakReason` as a deliver argument.
        .@"error" => |err| try writeError(allocator, out, err),
        .big_integer => |big| {
            // Symmetric refusal (ADR-0003): a non-canonical big integer —
            // leading zeros, non-digits, or a magnitude that belongs to the
            // `integer` arm — never reaches the wire.
            if (!big.isCanonical()) return Error.UnsupportedArgument;
            try out.appendSlice(allocator, big.digits);
            try out.append(allocator, if (big.negative) '-' else '+');
        },
    }
}

/// Encode a set's elements in canonical order: each element is encoded
/// independently, the encodings are sorted lexicographically by byte, and
/// emitted in that order. A set is unordered, so its wire form must not depend
/// on the order the model held it in — the encode-side partner of the
/// order-agnostic set equality in `model.equality`.
fn writeCanonicalSet(allocator: std.mem.Allocator, out: *std.ArrayList(u8), items: []const model.Argument) WalkError!void {
    if (items.len == 0) return;

    const encoded = try allocator.alloc([]u8, items.len);
    var built: usize = 0;
    defer {
        for (encoded[0..built]) |element| allocator.free(element);
        allocator.free(encoded);
    }

    for (items) |item| {
        var element: std.ArrayList(u8) = .empty;
        errdefer element.deinit(allocator);
        try writeArgument(allocator, &element, item);
        encoded[built] = try element.toOwnedSlice(allocator);
        built += 1;
    }

    std.mem.sort([]u8, encoded, {}, lessByteSlice);
    for (encoded) |element| try out.appendSlice(allocator, element);
}

fn lessByteSlice(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Encode a struct's entries in canonical key order: each entry is encoded as its
/// String key followed by its value, the encoded entries are sorted
/// lexicographically by byte, and emitted in that order. The upstream Syrup
/// encoder sorts dictionary entries by the fully-encoded key; sorting whole
/// `key ++ value` encodings is equivalent here because keys are unique, self-
/// delimiting netstrings, so no key encoding is a prefix of another and two
/// entries always first differ within their key bytes. This is the encode-side
/// partner of the order-independent struct equality in `model.equality`.
fn writeCanonicalStruct(allocator: std.mem.Allocator, out: *std.ArrayList(u8), entries: []const model.StructEntry) WalkError!void {
    if (entries.len == 0) return;

    const encoded = try allocator.alloc([]u8, entries.len);
    var built: usize = 0;
    defer {
        for (encoded[0..built]) |element| allocator.free(element);
        allocator.free(encoded);
    }

    for (entries) |entry| {
        var element: std.ArrayList(u8) = .empty;
        errdefer element.deinit(allocator);
        try writeString(allocator, &element, entry.key);
        try writeArgument(allocator, &element, entry.value);
        encoded[built] = try element.toOwnedSlice(allocator);
        built += 1;
    }

    std.mem.sort([]u8, encoded, {}, lessByteSlice);
    for (encoded) |element| try out.appendSlice(allocator, element);
}

fn writeHandoff(allocator: std.mem.Allocator, out: *std.ArrayList(u8), handoff: model.Handoff) !void {
    switch (handoff) {
        .give => |give| try writeSignedGive(allocator, out, give),
        .receive => |receive| try writeSignedReceive(allocator, out, receive),
    }
}

fn writeSignedGive(allocator: std.mem.Allocator, out: *std.ArrayList(u8), give: model.HandoffGive) !void {
    // A forwarded give carries the gifter's exact signed bytes; emit them verbatim
    // so the exporter re-verifies the gifter's signature over the same bytes the
    // gifter signed (re-encoding could differ, e.g. `#f` vs `{}` location hints).
    if (give.raw_signed) |raw| {
        try out.appendSlice(allocator, raw);
        return;
    }
    try beginRecord(allocator, out);
    try writeSymbol(allocator, out, "desc:sig-envelope");
    try writeHandoffGiveRecord(allocator, out, give);
    try writeSignature(allocator, out, give.signature);
    try endRecord(allocator, out);
}

fn writeSignedReceive(allocator: std.mem.Allocator, out: *std.ArrayList(u8), receive: model.HandoffReceive) !void {
    try beginRecord(allocator, out);
    try writeSymbol(allocator, out, "desc:sig-envelope");
    try writeHandoffReceiveRecord(allocator, out, receive);
    try writeSignature(allocator, out, receive.signature);
    try endRecord(allocator, out);
}

fn writeHandoffGiveRecord(allocator: std.mem.Allocator, out: *std.ArrayList(u8), give: model.HandoffGive) !void {
    try beginRecord(allocator, out);
    try writeSymbol(allocator, out, "desc:handoff-give");
    try writePeerKey(allocator, out, give.recipient_key);
    try writeLocatorString(allocator, out, give.exporter_location);
    try writeBytes(allocator, out, give.gifter_exporter_session);
    try writeBytes(allocator, out, give.gifter_side);
    try writeBytes(allocator, out, give.gift_id);
    try endRecord(allocator, out);
}

fn writeHandoffReceiveRecord(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    receive: model.HandoffReceive,
) !void {
    try beginRecord(allocator, out);
    try writeSymbol(allocator, out, "desc:handoff-receive");
    try writeBytes(allocator, out, receive.receiving_session);
    try writeBytes(allocator, out, receive.receiving_side);
    try writePositiveInt(allocator, out, receive.handoff_count);
    try writeSignedGive(allocator, out, receive.signed_give);
    try endRecord(allocator, out);
}

fn writePeerKey(allocator: std.mem.Allocator, out: *std.ArrayList(u8), q: []const u8) !void {
    try beginList(allocator, out);
    try writeSymbol(allocator, out, "public-key");
    try beginList(allocator, out);
    try writeSymbol(allocator, out, "ecc");
    try beginList(allocator, out);
    try writeSymbol(allocator, out, "curve");
    try writeSymbol(allocator, out, "Ed25519");
    try endList(allocator, out);
    try beginList(allocator, out);
    try writeSymbol(allocator, out, "flags");
    try writeSymbol(allocator, out, "eddsa");
    try endList(allocator, out);
    try beginList(allocator, out);
    try writeSymbol(allocator, out, "q");
    try writeBytes(allocator, out, q);
    try endList(allocator, out);
    try endList(allocator, out);
    try endList(allocator, out);
}

fn writeSignature(allocator: std.mem.Allocator, out: *std.ArrayList(u8), sig: []const u8) !void {
    // A value-shape refusal: the Ed25519 wire record carries exactly two
    // 32-byte halves, so any other length cannot be rendered.
    if (sig.len != 64) {
        return Error.UnsupportedArgument;
    }

    try beginList(allocator, out);
    try writeSymbol(allocator, out, "sig-val");
    try beginList(allocator, out);
    try writeSymbol(allocator, out, "eddsa");
    try beginList(allocator, out);
    try writeSymbol(allocator, out, "r");
    try writeBytes(allocator, out, sig[0..32]);
    try endList(allocator, out);
    try beginList(allocator, out);
    try writeSymbol(allocator, out, "s");
    try writeBytes(allocator, out, sig[32..64]);
    try endList(allocator, out);
    try endList(allocator, out);
    try endList(allocator, out);
}

fn writeLocator(allocator: std.mem.Allocator, out: *std.ArrayList(u8), location: model.PeerLocator) !void {
    // This encoder renders only the two empty hint spellings (`#f` and `{}`).
    // A locator carrying hint entries is refused loudly: silently dropping the
    // entries would put a different locator on the wire than the caller named,
    // and change the bytes a location signature is computed over.
    if (location.hints.entries.len != 0) return Error.UnsupportedArgument;
    try beginRecord(allocator, out);
    try writeSymbol(allocator, out, "ocapn-peer");
    try writeSymbol(allocator, out, location.transport);
    try writeString(allocator, out, location.designator);
    if (location.hints.wire_form == .boolean_false) {
        try writeBool(allocator, out, false);
    } else {
        try out.appendSlice(allocator, "{}");
    }
    try endRecord(allocator, out);
}

/// Encode a verbatim `<ocapn-peer transport designator hints>` Syrup record,
/// **including** hint entries as a `{…}` dict. `writeLocator` renders only the
/// two empty hint spellings (`#f`, `{}`); this is its entry-carrying
/// counterpart, for a gifter naming an exporter reachable only by a dial hint —
/// an iroh exporter's direct-address list, say. Entries are emitted in canonical
/// (encoded-key-sorted) order. Caller owns the returned slice. An empty hint set
/// delegates to `writeLocator` so the `#f`/`{}` spelling is preserved.
pub fn encodePeerLocatorRecord(allocator: std.mem.Allocator, location: model.PeerLocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    if (location.hints.entries.len == 0) {
        try writeLocator(allocator, &out, location);
        return out.toOwnedSlice(allocator);
    }
    try beginRecord(allocator, &out);
    try writeSymbol(allocator, &out, "ocapn-peer");
    try writeSymbol(allocator, &out, location.transport);
    try writeString(allocator, &out, location.designator);
    try writeHintDict(allocator, &out, location.hints.entries);
    try endRecord(allocator, &out);
    return out.toOwnedSlice(allocator);
}

/// Emit a Syrup `{…}` dict for hint entries, each `key value` pair encoded then
/// sorted lexicographically by its bytes — the canonical order the upstream
/// Syrup encoder uses (see `writeCanonicalStruct` for why sorting whole
/// `key ++ value` encodings is equivalent to sorting keys when keys are unique).
fn writeHintDict(allocator: std.mem.Allocator, out: *std.ArrayList(u8), entries: []const model.HintEntry) WalkError!void {
    try out.append(allocator, '{');
    const encoded = try allocator.alloc([]u8, entries.len);
    var built: usize = 0;
    defer {
        for (encoded[0..built]) |element| allocator.free(element);
        allocator.free(encoded);
    }
    for (entries) |entry| {
        var element: std.ArrayList(u8) = .empty;
        errdefer element.deinit(allocator);
        try writeString(allocator, &element, entry.name);
        try writeHintValue(allocator, &element, entry.value);
        encoded[built] = try element.toOwnedSlice(allocator);
        built += 1;
    }
    std.mem.sort([]u8, encoded, {}, lessByteSlice);
    for (encoded) |element| try out.appendSlice(allocator, element);
    try out.append(allocator, '}');
}

fn writeHintValue(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: model.HintValue) !void {
    switch (value) {
        .string => |string| try writeString(allocator, out, string),
        .bytes => |bytes| try writeBytes(allocator, out, bytes),
        .integer => |integer| try writeInteger(allocator, out, integer),
        .boolean => |boolean| try writeBool(allocator, out, boolean),
    }
}

fn writeLocatorString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), location: []const u8) !void {
    // The flattened `transport:designator` form splits on the first ':'. A
    // location with no ':' has no transport/designator boundary at all, so it
    // is refused before the split. The producer side
    // (`model.view.ExporterLocation.toOwned`) refuses a transport containing
    // ':', which is what keeps the first ':' unambiguous here.
    const split = std.mem.indexOfScalar(u8, location, ':') orelse return Error.UnsupportedArgument;
    return writeLocator(allocator, out, .{
        .transport = location[0..split],
        .designator = location[split + 1 ..],
        .hints = .{},
    });
}

fn writeError(allocator: std.mem.Allocator, out: *std.ArrayList(u8), err: model.BreakReason) !void {
    try beginRecord(allocator, out);
    try writeSymbol(allocator, out, "error");
    try writeString(allocator, out, err.message);
    try endRecord(allocator, out);
}

fn writeUnsigned(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: anytype) !void {
    var buf: [20]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{d}", .{value});
    try out.appendSlice(allocator, text);
}

fn writeSignedMagnitude(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: i64) !void {
    const magnitude: u64 = if (value == std.math.minInt(i64))
        @as(u64, 1) << 63
    else
        @intCast(-value);
    try writeUnsigned(allocator, out, magnitude);
}

fn writeTargetReference(allocator: std.mem.Allocator, out: *std.ArrayList(u8), reference: model.Reference) !void {
    // A target is the partner's export or an answer, never one of our own nears.
    if (reference == .near) return Error.UnsupportedReference;
    return writePayloadReference(allocator, out, reference);
}

fn writePayloadReference(allocator: std.mem.Allocator, out: *std.ArrayList(u8), reference: model.Reference) !void {
    switch (reference) {
        .near => |near| {
            try beginRecord(allocator, out);
            try writeSymbol(allocator, out, switch (near.kind) {
                .object => "desc:import-object",
                .promise => "desc:import-promise",
            });
            try writePositiveInt(allocator, out, near.export_position);
            try endRecord(allocator, out);
        },
        .far => |far| {
            try beginRecord(allocator, out);
            try writeSymbol(allocator, out, "desc:export");
            try writePositiveInt(allocator, out, far.import_position);
            try endRecord(allocator, out);
        },
        // `desc:answer` carries no path operand: a non-empty path must have been
        // decomposed into single-hop links by the engine before encode (ADR-0007
        // § Multi-hop decomposition at the sender). One reaching here is an
        // engine bug — fail loud rather than silently drop the path.
        .promise => |promise| {
            if (!promise.path.isEmpty()) return Error.UnsupportedReference;
            try beginRecord(allocator, out);
            try writeSymbol(allocator, out, "desc:answer");
            try writePositiveInt(allocator, out, promise.answer_position);
            try endRecord(allocator, out);
        },
        else => return Error.UnsupportedReference,
    }
}
