//! The Syrup encoder: `model.Message` to wire bytes.
//!
//! This is the encode half of the Syrup codec. It owns `encodeMessage` and
//! `encodeMessageForProfile` plus the message, argument, and reference writers
//! beneath them. Signing records and locator records live in `signing.zig`.
//! Canonical set/struct ordering lives in `canonical_collection.zig`. The shared
//! errors live in `shared`. This file builds bytes and holds no session
//! authority. The decode half is `decode`.
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
const codec_order = @import("codec_order");

const shared = @import("shared.zig");
const canonical_collection = @import("canonical_collection.zig");
const render = @import("render.zig");
const scalar = @import("scalar.zig");
const signing = @import("signing.zig");

const Error = shared.Error;
const WalkError = shared.WalkError;
const EncodeError = shared.EncodeError;

const sinkCounts = render.sinkCounts;
const beginRecord = scalar.beginRecord;
const endRecord = scalar.endRecord;
const beginList = scalar.beginList;
const endList = scalar.endList;
const writeSymbol = scalar.writeSymbol;
const writeString = scalar.writeString;
const writeAbortWireString = scalar.writeAbortWireString;
const writeBytes = scalar.writeBytes;
const writeInteger = scalar.writeInteger;
const writePositiveInt = scalar.writePositiveInt;
const writeBool = scalar.writeBool;
const writeFloat64 = scalar.writeFloat64;
const writeUnsignedList = scalar.writeUnsignedList;
const writeIntegerValue = scalar.writeIntegerValue;
const writeBigInteger = scalar.writeBigInteger;
const writeError = scalar.writeError;

pub fn encodeMessage(allocator: std.mem.Allocator, message: model.Message) EncodeError!foundation.Frame {
    const storage = try render.renderRecordExact(allocator, writeMessage, .{ allocator, null, message });
    return try foundation.Frame.initOwned(allocator, storage, .byte, .fromByteUnits(1));
}

pub fn encodeMessageForProfile(
    allocator: std.mem.Allocator,
    profile: model.CaptpVersion,
    message: model.Message,
) EncodeError!foundation.Frame {
    const storage = try render.renderRecordExact(allocator, writeMessage, .{ allocator, profile, message });
    return try foundation.Frame.initOwned(allocator, storage, .byte, .fromByteUnits(1));
}

/// The one message-level walk both passes share. `allocator` feeds only the
/// canonical-collection emit scratch. The measure pass never touches it.
fn writeMessage(
    sink: anytype,
    allocator: std.mem.Allocator,
    profile: ?model.CaptpVersion,
    message: model.Message,
) WalkError!void {
    switch (message) {
        .abort => |abort| {
            try beginRecord(sink);
            try writeSymbol(sink, shared.messageOp(.abort));
            try writeAbortWireString(sink, abort);
            try endRecord(sink);
        },
        .deliver => |deliver| {
            // A no-answer deliver is a single `op:deliver` with a `#f` answer
            // position, the fire-and-forget one-way send. There is no separate
            // one-way record on the wire.
            try beginRecord(sink);
            try writeSymbol(sink, shared.messageOp(.deliver));
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
        .resolve => |resolve| {
            if (profile == .next) return Error.UnsupportedMessage;
            try beginRecord(sink);
            try writeSymbol(sink, shared.messageOp(.resolve));
            try writePositiveInt(sink, resolve.answer.int());
            switch (resolve.resolution) {
                .fulfill => |arg| {
                    try beginRecord(sink);
                    try writeSymbol(sink, "resolve:fulfill");
                    try writeArgument(allocator, sink, arg);
                    try endRecord(sink);
                },
                .@"break" => |err| {
                    try beginRecord(sink);
                    try writeSymbol(sink, "resolve:break");
                    try writeError(sink, err);
                    try endRecord(sink);
                },
            }
            try endRecord(sink);
        },
        .gc_export => |gc_export| {
            try beginRecord(sink);
            try writeSymbol(sink, shared.messageOp(.gc_export));
            try writeUnsignedList(sink, gc_export.positions);
            try writeUnsignedList(sink, gc_export.deltas);
            try endRecord(sink);
        },
        .gc_answer => |gc_answer| {
            try beginRecord(sink);
            try writeSymbol(sink, shared.messageOp(.gc_answer));
            try writeUnsignedList(sink, gc_answer.positions);
            try endRecord(sink);
        },
        .get => |get| {
            try beginRecord(sink);
            try writeSymbol(sink, shared.messageOp(.get));
            try writeTargetReference(allocator, sink, get.receiver);
            // The field name is a String on the wire (CapTP § op:get; Goblins
            // guards `string?` on receipt), not a Symbol.
            try writeString(sink, get.field);
            try writePositiveInt(sink, get.answer.int());
            try endRecord(sink);
        },
        .index => |index| {
            try beginRecord(sink);
            try writeSymbol(sink, shared.messageOp(.index));
            try writeTargetReference(allocator, sink, index.receiver);
            try writeIntegerValue(sink, index.index);
            try writePositiveInt(sink, index.answer.int());
            try endRecord(sink);
        },
        .untag => |untag| {
            try beginRecord(sink);
            try writeSymbol(sink, shared.messageOp(.untag));
            try writeTargetReference(allocator, sink, untag.receiver);
            // The expected tag is a String on the wire (CapTP § op:untag),
            // matching op:get's field-name choice.
            try writeString(sink, untag.tag);
            try writePositiveInt(sink, untag.answer.int());
            try endRecord(sink);
        },
        .listen => |listen| {
            try beginRecord(sink);
            try writeSymbol(sink, shared.messageOp(.listen));
            try writePayloadReference(allocator, sink, listen.target);
            try writePayloadReference(allocator, sink, listen.listener);
            switch (profile orelse .v1_0) {
                .v1_0 => try writeBool(sink, listen.mode.toV1_0WantsPartial() orelse return Error.UnsupportedMessage),
                .next => try writePositiveInt(sink, @backingInt(listen.mode)),
            }
            try endRecord(sink);
        },
        .start_session => |start_session| {
            try beginRecord(sink);
            try writeSymbol(sink, shared.messageOp(.start_session));
            // As in the capnp encoder: outbound the version is ours, so a
            // null is a message this codebase never builds. Refuse it.
            const version = start_session.captp_version orelse return Error.MalformedFrame;
            try writeString(sink, version.wireString());
            try signing.writePeerKey(sink, start_session.session_pubkey.bytes);
            // The entry-carrying locator writer: a keyed-tcp responder's
            // location carries its bound address as a `direct-addresses`
            // hint, and the empty spellings (`#f`/`{}`) stay byte-identical
            // through the `writeLocator` delegation.
            try signing.writePeerLocatorRecord(sink, allocator, start_session.acceptable_location);
            try signing.writeSignature(sink, start_session.acceptable_location_sig.bytes);
            try endRecord(sink);
        },
    }
}

fn writeArgumentList(allocator: std.mem.Allocator, sink: anytype, args: []const model.Argument) WalkError!void {
    try sink.append('[');
    for (args) |arg| {
        try writeArgument(allocator, sink, arg);
    }
    try sink.append(']');
}

fn writeArgument(allocator: std.mem.Allocator, sink: anytype, arg: model.Argument) WalkError!void {
    switch (arg) {
        .bytes => |bytes| try writeBytes(sink, bytes),
        .symbol => |symbol| try writeSymbol(sink, symbol),
        .reference => |reference| try writePayloadReference(allocator, sink, reference),
        .string => |string| try writeString(sink, string),
        .handoff => |handoff| try writeHandoff(allocator, sink, handoff.*),
        .integer => |integer| try writeInteger(sink, integer),
        .float64 => |value| try writeFloat64(sink, value),
        .boolean => |value| try writeBool(sink, value),
        .list => |items| try writeArgumentList(allocator, sink, items),
        .void => {
            try beginRecord(sink);
            try writeSymbol(sink, "void");
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
            try beginRecord(sink);
            try writeSymbol(sink, "user-record");
            try writeSymbol(sink, tagged.tag);
            try writeArgumentList(allocator, sink, tagged.value);
            try endRecord(sink);
        },
        .keyword => |keyword| {
            try beginRecord(sink);
            try writeSymbol(sink, "kw");
            try writeSymbol(sink, keyword);
            try endRecord(sink);
        },
        // An `<error message>` in argument position, symmetric with the decoder,
        // which reads this record back into `.@"error"` (`readNeutralArgument`).
        // The main case is a V1.0 resolver-callback `break`
        // resolution, which ships its `model.BreakReason` as a deliver argument.
        .@"error" => |err| try writeError(sink, err),
        .big_integer => |big| try writeBigInteger(sink, big),
    }
}

/// Encode a set's elements in canonical order. A set is unordered, so the emit
/// pass refuses a duplicate element (ADR-0003), matching the decoder's
/// strictly-ascending refusal.
fn writeCanonicalSet(allocator: std.mem.Allocator, sink: anytype, items: []const model.Argument) WalkError!void {
    if (items.len == 0) return;
    try canonical_collection.write(model.Argument, allocator, sink, items, true, writeArgument);
}

/// Refuse a struct carrying two entries with the same key. Sorts a shallow copy
/// of the keys so a repeat is an adjacent pair, an O(n log n) pass over the
/// borrowed key slices with no value encoding.
fn refuseDuplicateStructKeys(allocator: std.mem.Allocator, entries: []const model.StructEntry) WalkError!void {
    if (entries.len < 2) return;
    const keys = try allocator.alloc([]const u8, entries.len);
    defer allocator.free(keys);
    for (entries, 0..) |entry, i| keys[i] = entry.key;
    std.mem.sort([]const u8, keys, {}, codec_order.lessByteSlice([]const u8));
    try codec_order.refuseAdjacentEqualKeys(WalkError, keys);
}

/// The per-entry writer for a struct: its String key followed by its value.
/// Sorting whole `key ++ value` encodings orders by key because keys are
/// self-delimiting netstrings, so no key encoding is a prefix of another and two
/// entries always first differ within their key bytes.
fn writeStructEntry(allocator: std.mem.Allocator, sink: anytype, entry: model.StructEntry) WalkError!void {
    try writeString(sink, entry.key);
    try writeArgument(allocator, sink, entry.value);
}

/// Encode a struct's entries in canonical key order, the encode-side partner of
/// the order-independent struct equality in `model.equality`. The upstream Syrup
/// encoder sorts dictionary entries by the fully-encoded key, which
/// the canonical collection writer reproduces.
///
/// Symmetric refusal (ADR-0003): the decoder rejects a struct whose keys are not
/// strictly ascending as `MalformedFrame`, which a duplicate key violates, so a
/// duplicate is refused here rather than shipped. The check is on the model keys,
/// not the `key ++ value` encodings, because two entries with the same key and
/// different values encode to distinct, strictly-ordered byte strings that a
/// full-encoding compare would miss. It runs on the fill pass only, mirroring the
/// generic's own count-branch skip.
fn writeCanonicalStruct(allocator: std.mem.Allocator, sink: anytype, entries: []const model.StructEntry) WalkError!void {
    if (entries.len == 0) return;
    if (comptime !sinkCounts(@TypeOf(sink))) try refuseDuplicateStructKeys(allocator, entries);
    try canonical_collection.write(model.StructEntry, allocator, sink, entries, false, writeStructEntry);
}

fn writeHandoff(allocator: std.mem.Allocator, sink: anytype, handoff: model.Handoff) WalkError!void {
    switch (handoff) {
        .give => |give| try signing.writeSignedGive(allocator, sink, give),
        .receive => |receive| try signing.writeSignedReceive(allocator, sink, receive),
    }
}

fn writeTargetReference(allocator: std.mem.Allocator, sink: anytype, reference: model.Reference) !void {
    // A target is the partner's export or an answer, never one of our own nears,
    // and never a sturdyref: you enliven a sturdyref (a bootstrap fetch), you do
    // not deliver to one. Cap'n Proto carries a sturdy target; Syrup
    // refuses it (the ADR-0003 dialect boundary the codec-equivalence test names).
    if (reference == .near or reference == .sturdy) return Error.UnsupportedReference;
    return writePayloadReference(allocator, sink, reference);
}

fn writePayloadReference(allocator: std.mem.Allocator, sink: anytype, reference: model.Reference) !void {
    switch (reference) {
        .near => |near| {
            try beginRecord(sink);
            try writeSymbol(sink, switch (near.kind) {
                .object => "desc:import-object",
                .promise => "desc:import-promise",
            });
            try writePositiveInt(sink, near.export_position.int());
            try endRecord(sink);
        },
        .far => |far| {
            try beginRecord(sink);
            try writeSymbol(sink, "desc:export");
            try writePositiveInt(sink, far.import_position.int());
            try endRecord(sink);
        },
        .promise => |promise| {
            try beginRecord(sink);
            try writeSymbol(sink, "desc:answer");
            try writePositiveInt(sink, promise.answer_position.int());
            try endRecord(sink);
        },
        // A sturdyref rides argument / fulfill position as `<ocapn-sturdyref
        // <ocapn-peer …> swissnum>`, the exact grammar the decoder reads back
        // (`readNeutralArgument`), so a Syrup-decoded sturdyref argument
        // re-encodes and round-trips like its Cap'n Proto twin, including
        // hint entries via `writePeerLocatorRecord`. A sturdyref *deliver
        // target* never reaches here: `writeTargetReference` refuses it first.
        .sturdy => |sturdy| {
            try beginRecord(sink);
            try writeSymbol(sink, "ocapn-sturdyref");
            try signing.writePeerLocatorRecord(sink, allocator, sturdy.peer);
            try writeBytes(sink, sturdy.swissnum);
            try endRecord(sink);
        },
        else => return Error.UnsupportedReference,
    }
}
