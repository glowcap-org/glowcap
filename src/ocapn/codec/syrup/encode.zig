//! The Syrup encoder: a borrowed `model.view.Body` to wire bytes.
//!
//! This is the encode half of the Syrup codec. It owns `encodeBody` and
//! `encodeBodyForProfile`, which walk a borrowed body, and `encodeMessage`
//! and `encodeMessageForProfile`, which project an owned `model.Message`
//! through `view.Body.fromOwned` onto the same walk. One walk serves every
//! source a view can borrow: an owned tree, a decoded frame, or a caller's
//! values behind a sequence table. Signing records and locator records live
//! in `signing.zig`. Canonical set/struct ordering lives in
//! `canonical_collection.zig`. The shared errors live in `shared`. This file
//! builds bytes and holds no session authority. The decode half is `decode`.
//!
//! Every entry point renders measure-then-fill: one non-allocating length pass
//! over the message, then a single exact allocation filled in place, one
//! allocation per encode, zero growth reallocs, zero shrink
//! (`test/codec/encode_budget_test.zig` pins both). Both passes run the same
//! generic walker parameterized on a sink that either counts or writes, so the
//! measured length and the emitted bytes cannot drift. The fill sink ratifies
//! that agreement with a bounds check that is live in every build mode, because
//! an overrun would be an out-of-bounds write, not just a wrong answer.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");

const shared = @import("shared.zig");
const canonical_collection = @import("canonical_collection.zig");
const render = @import("render.zig");
const scalar = @import("scalar.zig");
const signing = @import("signing.zig");

const view = model.view;

const Error = shared.Error;
const WalkError = shared.WalkError;
const EncodeError = shared.EncodeError;

const beginRecord = scalar.beginRecord;
const openRecord = scalar.openRecord;
const endRecord = scalar.endRecord;
const beginList = scalar.beginList;
const endList = scalar.endList;
const writeSymbol = scalar.writeSymbol;
const writeLabel = scalar.writeLabel;
const writeString = scalar.writeString;
const writeAbortWireString = scalar.writeAbortWireString;
const writeBytes = scalar.writeBytes;
const writeInteger = scalar.writeInteger;
const writePositiveInt = scalar.writePositiveInt;
const writeBool = scalar.writeBool;
const writeFloat64 = scalar.writeFloat64;
const writeIntegerValue = scalar.writeIntegerValue;
const writeBigInteger = scalar.writeBigInteger;
const writeError = scalar.writeError;

pub fn encodeMessage(allocator: std.mem.Allocator, message: model.Message) EncodeError!foundation.Frame {
    const body = view.Body.fromOwned(&message);
    return encodeBody(allocator, &body);
}

pub fn encodeMessageForProfile(
    allocator: std.mem.Allocator,
    profile: model.CaptpVersion,
    message: model.Message,
) EncodeError!foundation.Frame {
    const body = view.Body.fromOwned(&message);
    return encodeBodyForProfile(allocator, profile, &body);
}

/// Encode a borrowed body with the `1.0` profile's spellings.
pub fn encodeBody(allocator: std.mem.Allocator, body: *const view.Body) EncodeError!foundation.Frame {
    return renderBody(allocator, null, body);
}

/// Encode a borrowed body for a CapTP version. The body is read, never
/// materialized: a lazy record is projected where it is written, and a
/// malformed one refuses the encode as `MalformedView`.
pub fn encodeBodyForProfile(
    allocator: std.mem.Allocator,
    profile: model.CaptpVersion,
    body: *const view.Body,
) EncodeError!foundation.Frame {
    return renderBody(allocator, profile, body);
}

fn renderBody(allocator: std.mem.Allocator, profile: ?model.CaptpVersion, body: *const view.Body) EncodeError!foundation.Frame {
    const storage = try render.renderRecordExact(allocator, writeMessage, .{ allocator, profile, body });
    return try foundation.Frame.initOwned(allocator, storage, .byte, .fromByteUnits(1));
}

/// The one message-level walk both passes share. `allocator` feeds only the
/// canonical-collection emit scratch and a lazy hint list's projection. The
/// measure pass touches it for the hint list alone.
fn writeMessage(
    sink: anytype,
    allocator: std.mem.Allocator,
    profile: ?model.CaptpVersion,
    body: *const view.Body,
) WalkError!void {
    switch (body.*) {
        .abort => |*abort| {
            try openRecord(sink, shared.messageOp(.abort));
            try writeAbortWireString(sink, .{ .kind = abort.kind, .message = abort.message });
            try endRecord(sink);
        },
        .deliver => |*deliver| {
            // A no-answer deliver is a single `op:deliver` with a `#f` answer
            // position, the fire-and-forget one-way send. There is no separate
            // one-way record on the wire.
            try openRecord(sink, shared.messageOp(.deliver));
            try writeTargetReference(allocator, sink, deliver.target);
            try writeArgumentList(allocator, sink, deliver.args);
            if (deliver.answer) |answer| {
                try writePositiveInt(sink, answer.int());
            } else {
                try writeBool(sink, false);
            }
            switch (profile orelse .v1_0) {
                .v1_0 => if (deliver.resolve_me_desc) |resolver|
                    try writePayloadReference(allocator, sink, resolver)
                else
                    try writeBool(sink, false),
                .next => {
                    if (deliver.resolve_me_desc != null) return Error.UnsupportedMessage;
                },
            }
            try endRecord(sink);
        },
        .resolve => |*resolve| {
            if (profile == .next) return Error.UnsupportedMessage;
            try openRecord(sink, shared.messageOp(.resolve));
            try writePositiveInt(sink, resolve.answer.int());
            switch (resolve.resolution) {
                .fulfill => |*arg| {
                    try openRecord(sink, "resolve:fulfill");
                    try writeArgument(allocator, sink, arg);
                    try endRecord(sink);
                },
                .@"break" => |err| {
                    try openRecord(sink, "resolve:break");
                    try writeError(sink, .{ .message = err.message });
                    try endRecord(sink);
                },
            }
            try endRecord(sink);
        },
        .gc_export => |*gc_export| {
            try openRecord(sink, shared.messageOp(.gc_export));
            try writePositionList(sink, gc_export.positions);
            try writePositionList(sink, gc_export.deltas);
            try endRecord(sink);
        },
        .gc_answer => |*gc_answer| {
            try openRecord(sink, shared.messageOp(.gc_answer));
            try writePositionList(sink, gc_answer.positions);
            try endRecord(sink);
        },
        .get => |*get| {
            try openRecord(sink, shared.messageOp(.get));
            try writeTargetReference(allocator, sink, get.receiver);
            // The field name is a String on the wire (CapTP § op:get; Goblins
            // guards `string?` on receipt), not a Symbol.
            try writeString(sink, get.field);
            try writePositiveInt(sink, get.answer.int());
            try endRecord(sink);
        },
        .index => |*index| {
            try openRecord(sink, shared.messageOp(.index));
            try writeTargetReference(allocator, sink, index.receiver);
            try writeIntegerValue(sink, index.index);
            try writePositiveInt(sink, index.answer.int());
            try endRecord(sink);
        },
        .untag => |*untag| {
            try openRecord(sink, shared.messageOp(.untag));
            try writeTargetReference(allocator, sink, untag.receiver);
            // The expected tag is a String on the wire (CapTP § op:untag),
            // matching op:get's field-name choice.
            try writeString(sink, untag.tag);
            try writePositiveInt(sink, untag.answer.int());
            try endRecord(sink);
        },
        .listen => |*listen| {
            try openRecord(sink, shared.messageOp(.listen));
            try writePayloadReference(allocator, sink, listen.target);
            try writePayloadReference(allocator, sink, listen.listener);
            switch (profile orelse .v1_0) {
                .v1_0 => try writeBool(sink, listen.mode.toV1_0WantsPartial() orelse return Error.UnsupportedMessage),
                .next => try writePositiveInt(sink, @backingInt(listen.mode)),
            }
            try endRecord(sink);
        },
        .start_session => |*start_session| {
            try openRecord(sink, shared.messageOp(.start_session));
            // As in the capnp encoder: outbound the version is ours, so a
            // null is a message this codebase never builds. Refuse it.
            const version = start_session.captp_version orelse return Error.MalformedFrame;
            try writeString(sink, version.wireString());
            try signing.writePeerKey(sink, start_session.session_pubkey);
            // The entry-carrying locator writer: a keyed-tcp responder's
            // location carries its bound address as a `direct-addresses`
            // hint, and the empty spellings (`#f`/`{}`) stay byte-identical
            // through the `writeLocator` delegation.
            try signing.writePeerLocatorRecord(sink, allocator, start_session.acceptable_location);
            try signing.writeSignature(sink, start_session.acceptable_location_sig);
            try endRecord(sink);
        },
    }
}

fn writePositionList(sink: anytype, positions: view.PositionList) WalkError!void {
    try beginList(sink);
    const count = try positions.len();
    var visited: usize = 0;
    var it = positions.iterator();
    while (try it.next()) |position| : (visited += 1) {
        if (visited == count) return error.MalformedView;
        try writePositiveInt(sink, position);
    }
    if (visited != count) return error.MalformedView;
    try endList(sink);
}

/// The elements of a list, set, tagged value, or struct are walked where they
/// stand (`view.sequenceOf`): an owned slice is a slice walk, and a borrowed
/// sequence lends each element through `nextRef`. The argument writers below
/// take either, so one source serves the owned tree and the borrowed one, and
/// the owned walk pays no per-element projection. A borrowed sequence an
/// owner built from its own slice (`ownedSlice`) walks that slice directly.
fn writeArgumentList(allocator: std.mem.Allocator, sink: anytype, items: anytype) WalkError!void {
    if (comptime @TypeOf(items) == view.Args) {
        if (items.ownedSlice()) |owned| return writeArgumentList(allocator, sink, owned);
        if (items.wordRun()) |words| {
            try sink.append('[');
            var offset: usize = 0;
            while (offset < words.len) : (offset += 8)
                try writeInteger(sink, std.mem.readInt(i64, words[offset..][0..8], .little));
            return sink.append(']');
        }
    }
    try sink.append('[');
    const sequence = view.sequenceOf(items);
    const count = try sequence.len();
    var visited: usize = 0;
    var it = sequence.iterator();
    while (try it.nextRef()) |arg| : (visited += 1) {
        if (visited == count) return error.MalformedView;
        try writeArgument(allocator, sink, arg);
    }
    if (visited != count) return error.MalformedView;
    try sink.append(']');
}

/// Write one argument, owned (`*const model.Argument`) or borrowed
/// (`*const view.Argument`).
fn writeArgument(allocator: std.mem.Allocator, sink: anytype, arg: anytype) WalkError!void {
    switch (arg.*) {
        .bytes => |bytes| try writeBytes(sink, bytes),
        .symbol => |symbol| try writeSymbol(sink, symbol),
        .reference => |reference| try writePayloadReference(allocator, sink, reference),
        .string => |string| try writeString(sink, string),
        .handoff => |handoff| try writeHandoff(allocator, sink, try view.borrowHandoff(handoff)),
        .integer => |integer| try writeInteger(sink, integer),
        .float64 => |value| try writeFloat64(sink, value),
        .boolean => |value| try writeBool(sink, value),
        .list => |items| try writeArgumentList(allocator, sink, items),
        .void => {
            try openRecord(sink, "void");
            try endRecord(sink);
        },
        .set => |items| {
            try sink.append('#');
            try writeCanonicalSet(allocator, sink, items);
            try sink.append('$');
        },
        .@"struct" => |entries| {
            try sink.append('{');
            try writeCanonicalStruct(allocator, sink, entries);
            try sink.append('}');
        },
        .tagged => |tagged| {
            try openRecord(sink, "user-record");
            try writeSymbol(sink, tagged.tag);
            try writeArgumentList(allocator, sink, tagged.value);
            try endRecord(sink);
        },
        .keyword => |keyword| {
            try openRecord(sink, "kw");
            try writeSymbol(sink, keyword);
            try endRecord(sink);
        },
        // An `<error message>` in argument position, symmetric with the decoder,
        // which reads this record back into `.@"error"` (`readNeutralArgument`).
        // The main case is a V1.0 resolver-callback `break`
        // resolution, which ships its `model.BreakReason` as a deliver argument.
        .@"error" => |err| try writeError(sink, .{ .message = err.message }),
        .big_integer => |big| try writeBigInteger(sink, big),
    }
}

/// Encode a set's elements in canonical order. A set is unordered, so the emit
/// pass refuses a duplicate element (ADR-0003), matching the decoder's
/// strictly-ascending refusal.
fn writeCanonicalSet(allocator: std.mem.Allocator, sink: anytype, items: anytype) WalkError!void {
    if (comptime @TypeOf(items) == view.Args) {
        if (items.ownedSlice()) |owned| return writeCanonicalSet(allocator, sink, owned);
    }
    const sequence = view.sequenceOf(items);
    try canonical_collection.write(allocator, sink, sequence, true, writeArgument);
}

fn structKey(entry: anytype) []const u8 {
    return entry.key;
}

/// The per-entry writer for a struct: its String key followed by its value.
/// Sorting whole `key ++ value` encodings orders by key because keys are
/// self-delimiting netstrings, so no key encoding is a prefix of another and two
/// entries always first differ within their key bytes.
fn writeStructEntry(allocator: std.mem.Allocator, sink: anytype, entry: anytype) WalkError!void {
    try writeString(sink, entry.key);
    try writeArgument(allocator, sink, &entry.value);
}

/// Emit entries in their encoded String-key order, refusing duplicate keys.
fn writeCanonicalStruct(allocator: std.mem.Allocator, sink: anytype, entries: anytype) WalkError!void {
    if (comptime @TypeOf(entries) == view.StructEntries) {
        if (entries.ownedSlice()) |owned| return writeCanonicalStruct(allocator, sink, owned);
    }
    const sequence = view.sequenceOf(entries);
    try canonical_collection.writeKeyed(allocator, sink, sequence, true, structKey, writeStructEntry);
}

fn writeHandoff(allocator: std.mem.Allocator, sink: anytype, handoff: view.Handoff) WalkError!void {
    switch (handoff) {
        .give => |give| try signing.writeSignedGive(allocator, sink, give),
        .receive => |receive| try signing.writeSignedReceive(allocator, sink, receive),
    }
}

fn writeTargetReference(allocator: std.mem.Allocator, sink: anytype, reference: anytype) WalkError!void {
    // A target is the partner's export or an answer, never one of our own nears,
    // and never a sturdyref: you enliven a sturdyref (a bootstrap fetch), you do
    // not deliver to one. Cap'n Proto carries a sturdy target; Syrup
    // refuses it (the ADR-0003 dialect boundary the codec-equivalence test names).
    if (reference == .near or reference == .sturdy) return Error.UnsupportedReference;
    return writePayloadReference(allocator, sink, reference);
}

/// Write a reference in payload position, owned or borrowed.
fn writePayloadReference(allocator: std.mem.Allocator, sink: anytype, reference: anytype) WalkError!void {
    switch (reference) {
        .near => |near| {
            try beginRecord(sink);
            switch (near.kind) {
                .object => try writeLabel(sink, "desc:import-object"),
                .promise => try writeLabel(sink, "desc:import-promise"),
            }
            try writePositiveInt(sink, near.export_position.int());
            try endRecord(sink);
        },
        .far => |far| {
            try openRecord(sink, "desc:export");
            try writePositiveInt(sink, far.import_position.int());
            try endRecord(sink);
        },
        .promise => |promise| {
            try openRecord(sink, "desc:answer");
            try writePositiveInt(sink, promise.answer_position.int());
            try endRecord(sink);
        },
        // A sturdyref rides argument / fulfill position as `<ocapn-sturdyref
        // <ocapn-peer …> swissnum>`, the exact grammar the decoder reads back
        // (`readNeutralArgument`), so a Syrup-decoded sturdyref argument
        // re-encodes and round-trips like its Cap'n Proto twin, including
        // hint entries via `writePeerLocatorRecord`. A sturdyref *deliver
        // target* never reaches here: `writeTargetReference` refuses it first.
        .sturdy => |source| {
            const sturdy = try view.borrowSturdy(source);
            try openRecord(sink, "ocapn-sturdyref");
            try signing.writePeerLocatorRecord(sink, allocator, sturdy.peer);
            try writeBytes(sink, sturdy.swissnum);
            try endRecord(sink);
        },
        else => return Error.UnsupportedReference,
    }
}
