//! Syrup signing-domain and locator records.
//!
//! These writers build the exact records that signatures cover and the locator
//! records those domains embed. The message encoder reuses the same writers
//! when a signed handoff or hinted locator rides on the wire, so signing bytes
//! and wire bytes have one owner. Every writer takes the borrowed record
//! (`model.view`), so an owned record, a decoded frame, and a caller's values
//! all reach the wire through one walk. An owned record projects through its
//! view's `fromOwned`, which copies nothing.

const std = @import("std");

const model = @import("model");
const canonical_collection = @import("canonical_collection.zig");
const render = @import("render.zig");
const scalar = @import("scalar.zig");
const shared = @import("shared.zig");

const view = model.view;

const Error = shared.Error;
const WalkError = shared.WalkError;

const beginRecord = scalar.beginRecord;
const openRecord = scalar.openRecord;
const endRecord = scalar.endRecord;
const beginList = scalar.beginList;
const endList = scalar.endList;
const writeSymbol = scalar.writeSymbol;
const writeLabel = scalar.writeLabel;
const writeString = scalar.writeString;
const writeBytes = scalar.writeBytes;
const writeInteger = scalar.writeInteger;
const writePositiveInt = scalar.writePositiveInt;
const writeBool = scalar.writeBool;

pub fn writeSignedGive(allocator: std.mem.Allocator, sink: anytype, give: view.HandoffGive) WalkError!void {
    // A forwarded give carries the gifter's exact signed bytes; emit them
    // verbatim so the exporter verifies the same bytes the gifter signed.
    if (give.raw_signed) |raw| {
        try sink.appendSlice(raw);
        return;
    }
    try openRecord(sink, "desc:sig-envelope");
    try writeHandoffGiveRecord(sink, allocator, give);
    try writeSignature(sink, give.signature);
    try endRecord(sink);
}

pub fn writeSignedReceive(
    allocator: std.mem.Allocator,
    sink: anytype,
    receive: view.HandoffReceive,
) WalkError!void {
    try openRecord(sink, "desc:sig-envelope");
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
    location: view.PeerLocator,
) WalkError!void {
    try openRecord(sink, "my-location");
    try writePeerLocatorRecord(sink, allocator, location);
    try endRecord(sink);
}

/// As `writeMyLocationRecord`, but splices the exact received location-record
/// bytes instead of re-encoding a decoded locator.
pub fn writeMyLocationRecordRaw(sink: anytype, location_record_bytes: []const u8) !void {
    try openRecord(sink, "my-location");
    try sink.appendSlice(location_record_bytes);
    try endRecord(sink);
}

pub fn writeHandoffGiveRecord(
    sink: anytype,
    allocator: std.mem.Allocator,
    give: view.HandoffGive,
) WalkError!void {
    try openRecord(sink, "desc:handoff-give");
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
    try openRecord(sink, "desc:handoff-give");
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
    receive: view.HandoffReceive,
) WalkError!void {
    try openRecord(sink, "desc:handoff-receive");
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
    try openRecord(sink, "desc:sig-envelope");
    try sink.appendSlice(signed_record);
    try writeSignature(sink, .{ .raw = signature });
    try endRecord(sink);
}

pub fn writePeerKey(sink: anytype, q: []const u8) !void {
    try beginList(sink);
    try writeLabel(sink, "public-key");
    try beginList(sink);
    try writeLabel(sink, "ecc");
    try beginList(sink);
    try writeLabel(sink, "curve");
    try writeLabel(sink, "Ed25519");
    try endList(sink);
    try beginList(sink);
    try writeLabel(sink, "flags");
    try writeLabel(sink, "eddsa");
    try endList(sink);
    try beginList(sink);
    try writeLabel(sink, "q");
    try writeBytes(sink, q);
    try endList(sink);
    try endList(sink);
    try endList(sink);
}

/// Write an Ed25519 signature as the `<sig-val <eddsa <r …> <s …>>>` form,
/// from whichever shape its codec carried: the 64 raw bytes or the two halves.
pub fn writeSignature(sink: anytype, sig: view.Signature) !void {
    const r, const s = switch (sig) {
        .raw => |bytes| blk: {
            if (bytes.len != 64) return Error.UnsupportedArgument;
            break :blk .{ bytes[0..32], bytes[32..64] };
        },
        .halves => |halves| blk: {
            if (halves.r.len != 32 or halves.s.len != 32) return Error.UnsupportedArgument;
            break :blk .{ halves.r, halves.s };
        },
    };
    try beginList(sink);
    try writeLabel(sink, "sig-val");
    try beginList(sink);
    try writeLabel(sink, "eddsa");
    try beginList(sink);
    try writeLabel(sink, "r");
    try writeBytes(sink, r);
    try endList(sink);
    try beginList(sink);
    try writeLabel(sink, "s");
    try writeBytes(sink, s);
    try endList(sink);
    try endList(sink);
    try endList(sink);
}

/// The locator record with no hint entries, in whichever of the two empty
/// spellings (`#f` or `{}`) the locator remembers, because a signature over
/// one spelling does not verify over the other.
fn writeEmptyHintLocator(sink: anytype, location: view.PeerLocator, wire_form: model.Hints.WireForm) !void {
    try openRecord(sink, "ocapn-peer");
    try writeSymbol(sink, location.transport);
    try writeString(sink, location.designator);
    if (wire_form == .boolean_false) {
        try writeBool(sink, false);
    } else {
        try sink.appendSlice("{}");
    }
    try endRecord(sink);
}

/// Encode a verbatim `<ocapn-peer transport designator hints>` Syrup record,
/// including hint entries as a canonical `{...}` dict. Caller owns the result.
pub fn encodePeerLocatorRecord(allocator: std.mem.Allocator, location: model.PeerLocator) ![]u8 {
    return render.renderRecordExact(allocator, writePeerLocatorRecord, .{ allocator, view.PeerLocator.fromOwned(&location) });
}

/// Write a borrowed locator record. Owned and projected hints are written in
/// place. A lazy codec hint list has no forward cursor, so each render pass
/// parses it into scratch freed before the pass returns: the one allocation
/// the measure pass makes, reached only when a decoded frame's hinted locator
/// is re-encoded (memory-ledger "Handoff canonicalization").
pub fn writePeerLocatorRecord(
    sink: anytype,
    allocator: std.mem.Allocator,
    location: view.PeerLocator,
) WalkError!void {
    model.validateLocatorTransportDesignator(location.transport, location.designator) catch return Error.UnsupportedArgument;
    switch (location.hints) {
        .empty => |wire_form| try writeEmptyHintLocator(sink, location, wire_form),
        .projected => |hints| try writeHintedLocator(allocator, sink, location, hints),
        .lazy => {
            const hints = try location.hints.toOwned(allocator);
            defer model.freeHints(allocator, hints);
            try writeHintedLocator(allocator, sink, location, hints);
        },
    }
}

fn writeHintedLocator(
    allocator: std.mem.Allocator,
    sink: anytype,
    location: view.PeerLocator,
    hints: model.Hints,
) WalkError!void {
    model.validateHints(hints) catch return Error.UnsupportedArgument;
    if (hints.entries.len == 0) return writeEmptyHintLocator(sink, location, hints.wire_form);
    try openRecord(sink, "ocapn-peer");
    try writeSymbol(sink, location.transport);
    try writeString(sink, location.designator);
    try writeHintDict(allocator, sink, hints.entries);
    try endRecord(sink);
}

fn writeHintEntry(allocator: std.mem.Allocator, sink: anytype, entry: *const model.HintEntry) WalkError!void {
    _ = allocator;
    try writeString(sink, entry.name);
    try writeHintValue(sink, entry.value);
}

fn hintKey(entry: *const model.HintEntry) []const u8 {
    return entry.name;
}

fn writeHintDict(allocator: std.mem.Allocator, sink: anytype, entries: []const model.HintEntry) WalkError!void {
    try sink.append('{');
    try canonical_collection.writeKeyed(allocator, sink, view.sequenceOf(entries), false, hintKey, writeHintEntry);
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
