//! Syrup signing-domain and locator records.
//!
//! These writers build the exact records that signatures cover and the locator
//! records those domains embed. The message encoder reuses the same writers
//! when a signed handoff or hinted locator rides on the wire, so signing bytes
//! and wire bytes have one owner.

const std = @import("std");

const model = @import("model");
const canonical_collection = @import("canonical_collection.zig");
const render = @import("render.zig");
const scalar = @import("scalar.zig");
const shared = @import("shared.zig");

const Error = shared.Error;
const WalkError = shared.WalkError;

const beginRecord = scalar.beginRecord;
const endRecord = scalar.endRecord;
const beginList = scalar.beginList;
const endList = scalar.endList;
const writeSymbol = scalar.writeSymbol;
const writeString = scalar.writeString;
const writeBytes = scalar.writeBytes;
const writeInteger = scalar.writeInteger;
const writePositiveInt = scalar.writePositiveInt;
const writeBool = scalar.writeBool;

pub fn writeSignedGive(allocator: std.mem.Allocator, sink: anytype, give: model.HandoffGive) WalkError!void {
    // A forwarded give carries the gifter's exact signed bytes; emit them
    // verbatim so the exporter verifies the same bytes the gifter signed.
    if (give.raw_signed) |raw| {
        try sink.appendSlice(raw);
        return;
    }
    try beginRecord(sink);
    try writeSymbol(sink, "desc:sig-envelope");
    try writeHandoffGiveRecord(sink, allocator, give);
    try writeSignature(sink, give.signature);
    try endRecord(sink);
}

pub fn writeSignedReceive(
    allocator: std.mem.Allocator,
    sink: anytype,
    receive: model.HandoffReceive,
) WalkError!void {
    try beginRecord(sink);
    try writeSymbol(sink, "desc:sig-envelope");
    try writeHandoffReceiveRecord(sink, allocator, receive);
    try writeSignature(sink, receive.signature);
    try endRecord(sink);
}

/// Wrap an `acceptable-location` in the `<my-location $loc>` record an
/// `op:start-session` signature covers. Uses the entry-carrying locator
/// writer, so hinted locations sign over the same bytes the wire frame carries.
pub fn writeMyLocationRecord(
    sink: anytype,
    allocator: std.mem.Allocator,
    location: model.PeerLocator,
) !void {
    try beginRecord(sink);
    try writeSymbol(sink, "my-location");
    try writePeerLocatorRecord(sink, allocator, location);
    try endRecord(sink);
}

/// As `writeMyLocationRecord`, but splices the exact received location-record
/// bytes instead of re-encoding a decoded locator.
pub fn writeMyLocationRecordRaw(sink: anytype, location_record_bytes: []const u8) !void {
    try beginRecord(sink);
    try writeSymbol(sink, "my-location");
    try sink.appendSlice(location_record_bytes);
    try endRecord(sink);
}

pub fn writeHandoffGiveRecord(
    sink: anytype,
    allocator: std.mem.Allocator,
    give: model.HandoffGive,
) WalkError!void {
    try beginRecord(sink);
    try writeSymbol(sink, "desc:handoff-give");
    try writePeerKey(sink, give.recipient_key);
    try writePeerLocatorRecord(sink, allocator, give.exporter);
    try writeBytes(sink, give.gifter_exporter_session);
    try writeBytes(sink, give.gifter_side);
    try writeBytes(sink, give.gift_id);
    try endRecord(sink);
}

/// Build the inner `<desc:handoff-give ...>` record with exporter location as
/// verbatim Syrup bytes, preserving hinted locator spellings byte-for-byte.
pub fn writeHandoffGiveRecordRawLocation(
    sink: anytype,
    recipient_key: []const u8,
    exporter_location_raw: []const u8,
    gifter_exporter_session: []const u8,
    gifter_side: []const u8,
    gift_id: []const u8,
) !void {
    try beginRecord(sink);
    try writeSymbol(sink, "desc:handoff-give");
    try writePeerKey(sink, recipient_key);
    try sink.appendSlice(exporter_location_raw);
    try writeBytes(sink, gifter_exporter_session);
    try writeBytes(sink, gifter_side);
    try writeBytes(sink, gift_id);
    try endRecord(sink);
}

pub fn writeHandoffReceiveRecord(
    sink: anytype,
    allocator: std.mem.Allocator,
    receive: model.HandoffReceive,
) WalkError!void {
    try beginRecord(sink);
    try writeSymbol(sink, "desc:handoff-receive");
    try writeBytes(sink, receive.receiving_session);
    try writeBytes(sink, receive.receiving_side);
    try writePositiveInt(sink, receive.handoff_count);
    try writeSignedGive(allocator, sink, receive.signed_give);
    try endRecord(sink);
}

/// Wrap an already-signed inner record and signature into a sig-envelope.
pub fn writeSigEnvelope(
    sink: anytype,
    signed_record: []const u8,
    signature: []const u8,
) !void {
    try beginRecord(sink);
    try writeSymbol(sink, "desc:sig-envelope");
    try sink.appendSlice(signed_record);
    try writeSignature(sink, signature);
    try endRecord(sink);
}

pub fn writePeerKey(sink: anytype, q: []const u8) !void {
    try beginList(sink);
    try writeSymbol(sink, "public-key");
    try beginList(sink);
    try writeSymbol(sink, "ecc");
    try beginList(sink);
    try writeSymbol(sink, "curve");
    try writeSymbol(sink, "Ed25519");
    try endList(sink);
    try beginList(sink);
    try writeSymbol(sink, "flags");
    try writeSymbol(sink, "eddsa");
    try endList(sink);
    try beginList(sink);
    try writeSymbol(sink, "q");
    try writeBytes(sink, q);
    try endList(sink);
    try endList(sink);
    try endList(sink);
}

pub fn writeSignature(sink: anytype, sig: []const u8) !void {
    if (sig.len != 64) return Error.UnsupportedArgument;

    try beginList(sink);
    try writeSymbol(sink, "sig-val");
    try beginList(sink);
    try writeSymbol(sink, "eddsa");
    try beginList(sink);
    try writeSymbol(sink, "r");
    try writeBytes(sink, sig[0..32]);
    try endList(sink);
    try beginList(sink);
    try writeSymbol(sink, "s");
    try writeBytes(sink, sig[32..64]);
    try endList(sink);
    try endList(sink);
    try endList(sink);
}

fn writeLocator(sink: anytype, location: model.PeerLocator) !void {
    // Preserve the two empty hint spellings. A locator carrying entries must use
    // `writePeerLocatorRecord`; silently dropping entries would change signed
    // bytes and wire bytes.
    if (location.hints.entries.len != 0) return Error.UnsupportedArgument;
    try beginRecord(sink);
    try writeSymbol(sink, "ocapn-peer");
    try writeSymbol(sink, location.transport);
    try writeString(sink, location.designator);
    if (location.hints.wire_form == .boolean_false) {
        try writeBool(sink, false);
    } else {
        try sink.appendSlice("{}");
    }
    try endRecord(sink);
}

/// Encode a verbatim `<ocapn-peer transport designator hints>` Syrup record,
/// including hint entries as a canonical `{...}` dict. Caller owns the result.
pub fn encodePeerLocatorRecord(allocator: std.mem.Allocator, location: model.PeerLocator) ![]u8 {
    return render.renderRecordExact(allocator, writePeerLocatorRecord, .{ allocator, location });
}

pub fn writePeerLocatorRecord(
    sink: anytype,
    allocator: std.mem.Allocator,
    location: model.PeerLocator,
) WalkError!void {
    model.validatePeerLocator(location) catch return Error.UnsupportedArgument;
    if (location.hints.entries.len == 0) {
        return writeLocator(sink, location);
    }
    try beginRecord(sink);
    try writeSymbol(sink, "ocapn-peer");
    try writeSymbol(sink, location.transport);
    try writeString(sink, location.designator);
    try writeHintDict(allocator, sink, location.hints.entries);
    try endRecord(sink);
}

fn writeHintEntry(allocator: std.mem.Allocator, sink: anytype, entry: model.HintEntry) WalkError!void {
    _ = allocator;
    try writeString(sink, entry.name);
    try writeHintValue(sink, entry.value);
}

fn writeHintDict(allocator: std.mem.Allocator, sink: anytype, entries: []const model.HintEntry) WalkError!void {
    try sink.append('{');
    try canonical_collection.write(model.HintEntry, allocator, sink, entries, false, writeHintEntry);
    try sink.append('}');
}

fn writeHintValue(sink: anytype, value: model.HintValue) !void {
    switch (value) {
        .string => |string| try writeString(sink, string),
        .bytes => |bytes| try writeBytes(sink, bytes),
        .integer => |integer| try writeInteger(sink, integer),
        .boolean => |boolean| try writeBool(sink, boolean),
    }
}
