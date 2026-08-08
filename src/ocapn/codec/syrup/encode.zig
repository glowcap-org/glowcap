//! The Syrup encoder: `model.Message` to wire bytes.
//!
//! This is the encode half of the Syrup codec. It owns `encodeMessage` and
//! `encodeMessageForProfile`, the `write*` record/list/leaf primitives beneath
//! them, and the `pub` record writers the signing domain composes (`canonical`
//! builds the signed-byte products from them, so the bytes a signature covers
//! never drift from the wire). The shared `Error` and `WalkError` sets live in
//! `shared`; this file builds bytes and holds no session authority. The decode
//! half is `decode`.
//!
//! Every entry point renders measure-then-fill: one non-allocating length pass
//! over the message, then a single exact allocation filled in place — one
//! allocation per encode, zero growth reallocs, zero shrink
//! (`test/codec/encode_budget_test.zig` pins both). Both passes run the same
//! generic walker parameterized on a sink that either counts or writes, so the
//! measured length and the emitted bytes cannot drift; the fill sink ratifies
//! that agreement with a bounds check that is live in every build mode, because
//! an overrun would be an out-of-bounds write, not just a wrong answer.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const codec_order = @import("codec_order");

const shared = @import("shared.zig");

const Error = shared.Error;
const WalkError = shared.WalkError;
const EncodeError = shared.EncodeError;

// ── Sinks ────────────────────────────────────────────────────────────────────
//
// The walker below is generic over a byte sink with `append`/`appendSlice`.
// `CountSink` is the measure pass (never allocates, never fails), `SliceSink`
// is the fill pass over the one exact allocation, and `ListSink` adapts a
// caller-owned ArrayList for the growable products (`canonical`'s scratch and
// the canonical-collection element encodes).

const CountSink = struct {
    total: usize = 0,

    const counting = true;

    fn append(self: *CountSink, byte: u8) error{}!void {
        _ = byte;
        self.total += 1;
    }

    fn appendSlice(self: *CountSink, bytes: []const u8) error{}!void {
        self.total += bytes.len;
    }
};

const SliceSink = struct {
    buf: []u8,
    cursor: usize = 0,

    const counting = false;

    // The bounds checks are the measure/emit agreement assertion, live in every
    // build mode: past this point a divergence would write out of bounds.
    fn append(self: *SliceSink, byte: u8) error{}!void {
        if (self.cursor >= self.buf.len) @panic("syrup encode: emit overran the measured length");
        self.buf[self.cursor] = byte;
        self.cursor += 1;
    }

    fn appendSlice(self: *SliceSink, bytes: []const u8) error{}!void {
        if (self.buf.len - self.cursor < bytes.len) @panic("syrup encode: emit overran the measured length");
        @memcpy(self.buf[self.cursor..][0..bytes.len], bytes);
        self.cursor += bytes.len;
    }
};

const ListSink = struct {
    allocator: std.mem.Allocator,
    list: *std.ArrayList(u8),

    const counting = false;

    fn append(self: *ListSink, byte: u8) std.mem.Allocator.Error!void {
        try self.list.append(self.allocator, byte);
    }

    fn appendSlice(self: *ListSink, bytes: []const u8) std.mem.Allocator.Error!void {
        try self.list.appendSlice(self.allocator, bytes);
    }
};

/// True when `SinkPtr` is the measure pass's sink. The canonical-collection
/// writers branch on this: measuring skips the sort/dedup scratch (a canonical
/// order is a permutation, so the total length is order-independent), and the
/// duplicate refusals fire on the emit pass.
fn sinkCounts(comptime SinkPtr: type) bool {
    return @typeInfo(SinkPtr).pointer.child.counting;
}

/// Render one record measure-then-fill: a counting pass, one exact allocation,
/// then the fill pass over the same walker. `writeFn`'s first parameter must be
/// the sink; `args` carries the rest. Caller owns the returned slice. This is
/// the single seam `encodeMessageForProfile` and the `canonical` signed-byte
/// products share, so every rendered record pays exactly one allocation (plus
/// any canonical-collection emit scratch) and the two passes cannot drift.
pub fn renderRecordExact(
    allocator: std.mem.Allocator,
    comptime writeFn: anytype,
    args: anytype,
) WalkError![]u8 {
    var count: CountSink = .{};
    try @call(.auto, writeFn, .{&count} ++ args);

    const storage = try allocator.alloc(u8, count.total);
    var fill: SliceSink = .{ .buf = storage };
    @call(.auto, writeFn, .{&fill} ++ args) catch |err| {
        allocator.free(storage);
        return err;
    };
    // Guards memory safety, so it stays live in every build mode: a short fill
    // would hand out uninitialized storage as wire bytes.
    if (fill.cursor != storage.len) @panic("syrup encode: emit cursor diverged from the measured length");
    return storage;
}

pub fn encodeMessage(allocator: std.mem.Allocator, message: model.Message) EncodeError!foundation.Frame {
    const storage = try renderRecordExact(allocator, writeMessage, .{ allocator, null, message });
    return try foundation.Frame.initOwned(allocator, storage, .byte, .fromByteUnits(1));
}

pub fn encodeMessageForProfile(
    allocator: std.mem.Allocator,
    profile: model.CaptpVersion,
    message: model.Message,
) EncodeError!foundation.Frame {
    const storage = try renderRecordExact(allocator, writeMessage, .{ allocator, profile, message });
    return try foundation.Frame.initOwned(allocator, storage, .byte, .fromByteUnits(1));
}

/// The one message-level walk both passes share. `allocator` feeds only the
/// canonical-collection emit scratch; the measure pass never touches it.
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
                .next => try writePositiveInt(sink, @intFromEnum(listen.mode)),
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
            try writePeerKey(sink, start_session.session_pubkey.bytes);
            // The entry-carrying locator writer: a keyed-tcp responder's
            // location carries its bound address as a `direct-addresses`
            // hint, and the empty spellings (`#f`/`{}`) stay byte-identical
            // through the `writeLocator` delegation.
            try writePeerLocatorRecord(sink, allocator, start_session.acceptable_location);
            try writeSignature(sink, start_session.acceptable_location_sig.bytes);
            try endRecord(sink);
        },
    }
}

fn beginRecord(sink: anytype) !void {
    try sink.append('<');
}

fn endRecord(sink: anytype) !void {
    try sink.append('>');
}

fn writeSymbol(sink: anytype, symbol: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(symbol)) return Error.UnsupportedArgument;
    try writeUnsigned(sink, symbol.len);
    try sink.append('\'');
    try sink.appendSlice(symbol);
}

fn writeString(sink: anytype, string: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(string)) return Error.UnsupportedArgument;
    try writeUnsigned(sink, string.len);
    try sink.append('"');
    try sink.appendSlice(string);
}

fn writeAbortWireString(sink: anytype, abort: model.AbortReason) !void {
    if (abort.kind == .other) {
        try writeString(sink, abort.message);
        return;
    }

    if (!std.unicode.utf8ValidateSlice(abort.message)) return Error.UnsupportedArgument;
    const label = abort.kind.wireName();
    try writeUnsigned(sink, label.len + ": ".len + abort.message.len);
    try sink.append('"');
    try sink.appendSlice(label);
    try sink.appendSlice(": ");
    try sink.appendSlice(abort.message);
}

fn writeBytes(sink: anytype, bytes: []const u8) !void {
    try writeUnsigned(sink, bytes.len);
    try sink.append(':');
    try sink.appendSlice(bytes);
}

fn writeInteger(sink: anytype, value: i64) !void {
    if (value < 0) {
        try writeSignedMagnitude(sink, value);
        try sink.append('-');
    } else {
        try writePositiveInt(sink, @intCast(value));
    }
}

fn writePositiveInt(sink: anytype, value: u64) !void {
    try writeUnsigned(sink, value);
    try sink.append('+');
}

fn writeBool(sink: anytype, value: bool) !void {
    try sink.append(if (value) 't' else 'f');
}

/// Syrup encodes a `binary64` double as `'D'` followed by 8 bytes IEEE-754
/// big-endian. The model carries only `float64`; `'F'` (binary32) is not a
/// pancake passable.
fn writeFloat64(sink: anytype, value: f64) !void {
    try sink.append('D');
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, @bitCast(value), .big);
    try sink.appendSlice(buf[0..]);
}

fn writeArgumentList(allocator: std.mem.Allocator, sink: anytype, args: []const model.Argument) WalkError!void {
    try sink.append('[');
    for (args) |arg| {
        try writeArgument(allocator, sink, arg);
    }
    try sink.append(']');
}

fn writeUnsignedList(sink: anytype, values: []const u64) !void {
    try sink.append('[');
    for (values) |value| {
        try writePositiveInt(sink, value);
    }
    try sink.append(']');
}

fn beginList(sink: anytype) !void {
    try sink.append('[');
}

fn endList(sink: anytype) !void {
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
        // An `<error message>` in argument position — symmetric with the decoder,
        // which reads this record back into `.@"error"` (`readNeutralArgument`).
        // The load-bearing case is a V1.0 resolver-callback `break`
        // resolution, which ships its `model.BreakReason` as a deliver argument.
        .@"error" => |err| try writeError(sink, err),
        .big_integer => |big| try writeBigInteger(sink, big),
    }
}

fn writeIntegerValue(sink: anytype, integer: model.Integer) WalkError!void {
    switch (integer) {
        .integer => |value| try writeInteger(sink, value),
        .big_integer => |big| try writeBigInteger(sink, big),
    }
}

fn writeBigInteger(sink: anytype, big: model.BigInteger) WalkError!void {
    // A non-canonical big integer could duplicate the compact arm or assign
    // multiple byte forms to one value, so it never reaches the wire.
    if (!big.isCanonical()) return Error.UnsupportedArgument;
    try sink.appendSlice(big.digits);
    try sink.append(if (big.negative) '-' else '+');
}

/// Encode a canonical unordered collection: each element is encoded
/// independently, the encodings are sorted lexicographically by byte, and
/// emitted in that order, so the wire form never depends on the order the model
/// held the elements in. This is the encode-side partner of the order-agnostic
/// set and struct equality in `model.equality`, and the one place the measure /
/// sort-scratch / emit shape lives: Syrup sets, structs, and hint dicts all
/// route through it, each supplying its own per-element writer.
///
/// The measure pass takes the counting branch, because a canonical order is a
/// permutation of the elements, so the encoded length is the sum of the
/// elements' lengths in any order and no sort scratch is needed. When
/// `refuse_adjacent_dupes` is set, the emit pass rejects two equal encodings
/// (they sort adjacent) as a duplicate, the emit-side half of ADR-0003's
/// symmetric refusal, so a duplicate fails the fill pass after the measure pass
/// already succeeded and the caller frees the measured buffer.
fn writeCanonicalCollection(
    comptime Elem: type,
    allocator: std.mem.Allocator,
    sink: anytype,
    items: []const Elem,
    comptime refuse_adjacent_dupes: bool,
    comptime writeElem: anytype,
) WalkError!void {
    if (comptime sinkCounts(@TypeOf(sink))) {
        for (items) |item| try writeElem(allocator, sink, item);
        return;
    }

    const encoded = try allocator.alloc([]u8, items.len);
    var built: usize = 0;
    defer {
        for (encoded[0..built]) |element| allocator.free(element);
        allocator.free(encoded);
    }

    for (items) |item| {
        var element: std.ArrayList(u8) = .empty;
        errdefer element.deinit(allocator);
        var element_sink: ListSink = .{ .allocator = allocator, .list = &element };
        try writeElem(allocator, &element_sink, item);
        encoded[built] = try element.toOwnedSlice(allocator);
        built += 1;
    }

    std.mem.sort([]u8, encoded, {}, codec_order.lessByteSlice([]u8));
    if (comptime refuse_adjacent_dupes) {
        // The decoder rejects a set whose elements are not strictly ascending,
        // which a duplicate violates, so an encoder that emitted one would ship a
        // frame pancake's own decoder rejects. A set element is its whole value,
        // so two equal elements encode to equal bytes and land adjacent after the
        // sort — one linear pass finds a duplicate.
        try codec_order.refuseAdjacentEqualKeys(WalkError, encoded);
    }
    for (encoded) |element| try sink.appendSlice(element);
}

/// Encode a set's elements in canonical order. A set is unordered, so the emit
/// pass refuses a duplicate element (ADR-0003), matching the decoder's
/// strictly-ascending refusal.
fn writeCanonicalSet(allocator: std.mem.Allocator, sink: anytype, items: []const model.Argument) WalkError!void {
    if (items.len == 0) return;
    try writeCanonicalCollection(model.Argument, allocator, sink, items, true, writeArgument);
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
/// `writeCanonicalCollection` reproduces.
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
    try writeCanonicalCollection(model.StructEntry, allocator, sink, entries, false, writeStructEntry);
}

fn writeHandoff(allocator: std.mem.Allocator, sink: anytype, handoff: model.Handoff) WalkError!void {
    switch (handoff) {
        .give => |give| try writeSignedGive(allocator, sink, give),
        .receive => |receive| try writeSignedReceive(allocator, sink, receive),
    }
}

fn writeSignedGive(allocator: std.mem.Allocator, sink: anytype, give: model.HandoffGive) WalkError!void {
    // A forwarded give carries the gifter's exact signed bytes; emit them verbatim
    // so the exporter re-verifies the gifter's signature over the same bytes the
    // gifter signed (re-encoding could differ, e.g. `#f` vs `{}` location hints).
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

fn writeSignedReceive(allocator: std.mem.Allocator, sink: anytype, receive: model.HandoffReceive) WalkError!void {
    try beginRecord(sink);
    try writeSymbol(sink, "desc:sig-envelope");
    try writeHandoffReceiveRecord(sink, allocator, receive);
    try writeSignature(sink, receive.signature);
    try endRecord(sink);
}

// The record-level writers below are the signing-domain seam: `canonical.zig`
// builds the byte products a `desc:sig-envelope` signature covers by rendering
// them through `renderRecordExact`, so the signing domain is single-sourced
// against the wire encoder and the leaf primitives stay private to this file.
// Each takes the generic sink first so `renderRecordExact` can drive both
// passes over it.

/// Wrap an `acceptable-location` in the `<my-location $loc>` record an
/// `op:start-session` signature covers. Uses the entry-carrying locator
/// writer, so a hinted location (a keyed-tcp responder's bound address) signs
/// over the same bytes the wire frame carries; `allocator` is the hint dict's
/// canonical-order sort scratch, freed before this returns.
pub fn writeMyLocationRecord(sink: anytype, allocator: std.mem.Allocator, location: model.PeerLocator) !void {
    try beginRecord(sink);
    try writeSymbol(sink, "my-location");
    try writePeerLocatorRecord(sink, allocator, location);
    try endRecord(sink);
}

/// As `writeMyLocationRecord`, but splices the *exact received* location-record
/// bytes instead of re-encoding a decoded locator, so verification stays correct
/// for a locator whose hints the borrowed decode did not retain.
pub fn writeMyLocationRecordRaw(sink: anytype, location_record_bytes: []const u8) !void {
    try beginRecord(sink);
    try writeSymbol(sink, "my-location");
    try sink.appendSlice(location_record_bytes);
    try endRecord(sink);
}

pub fn writeHandoffGiveRecord(sink: anytype, allocator: std.mem.Allocator, give: model.HandoffGive) WalkError!void {
    try beginRecord(sink);
    try writeSymbol(sink, "desc:handoff-give");
    try writePeerKey(sink, give.recipient_key);
    try writePeerLocatorRecord(sink, allocator, give.exporter);
    try writeBytes(sink, give.gifter_exporter_session);
    try writeBytes(sink, give.gifter_side);
    try writeBytes(sink, give.gift_id);
    try endRecord(sink);
}

/// Build the inner `<desc:handoff-give …>` record taking the exporter location
/// as **verbatim** Syrup bytes (hints and all) rather than a flattened
/// `transport:designator`, so a peer comparing the give's exporter location to
/// the session location matches a hinted locator the encoder cannot round-trip.
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

/// Wrap an already-signed inner record and its 64-byte signature into the
/// `<desc:sig-envelope <record> <sig-val …>>` a recipient forwards or a gifter
/// returns.
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

fn writePeerKey(sink: anytype, q: []const u8) !void {
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

fn writeSignature(sink: anytype, sig: []const u8) !void {
    // A value-shape refusal: the Ed25519 wire record carries exactly two
    // 32-byte halves, so any other length cannot be rendered.
    if (sig.len != 64) {
        return Error.UnsupportedArgument;
    }

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
    // This encoder renders only the two empty hint spellings (`#f` and `{}`).
    // A locator carrying hint entries is refused loudly: silently dropping the
    // entries would put a different locator on the wire than the caller named,
    // and change the bytes a location signature is computed over.
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
/// **including** hint entries as a `{…}` dict. `writeLocator` renders only the
/// two empty hint spellings (`#f`, `{}`); this is its entry-carrying
/// counterpart, for a gifter naming an exporter reachable only by a dial hint,
/// an iroh exporter's direct-address list, say. Entries are emitted in canonical
/// (encoded-key-sorted) order. Caller owns the returned slice. An empty hint set
/// delegates to `writeLocator` so the `#f`/`{}` spelling is preserved.
pub fn encodePeerLocatorRecord(allocator: std.mem.Allocator, location: model.PeerLocator) ![]u8 {
    return renderRecordExact(allocator, writePeerLocatorRecord, .{ allocator, location });
}

fn writePeerLocatorRecord(sink: anytype, allocator: std.mem.Allocator, location: model.PeerLocator) WalkError!void {
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

/// The per-entry writer for a hint dict: its String name followed by its value.
fn writeHintEntry(allocator: std.mem.Allocator, sink: anytype, entry: model.HintEntry) WalkError!void {
    _ = allocator;
    try writeString(sink, entry.name);
    try writeHintValue(sink, entry.value);
}

/// Emit a Syrup `{…}` dict for hint entries in the canonical `key value` order
/// the upstream Syrup encoder uses (`writeCanonicalCollection`). Hint names are
/// unique by construction, so no duplicate refusal is needed.
fn writeHintDict(allocator: std.mem.Allocator, sink: anytype, entries: []const model.HintEntry) WalkError!void {
    try sink.append('{');
    try writeCanonicalCollection(model.HintEntry, allocator, sink, entries, false, writeHintEntry);
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

fn writeError(sink: anytype, err: model.BreakReason) !void {
    try beginRecord(sink);
    try writeSymbol(sink, "error");
    try writeString(sink, err.message);
    try endRecord(sink);
}

fn writeUnsigned(sink: anytype, value: anytype) !void {
    var buf: [20]u8 = undefined;
    // Hand-rolled decimal: same canonical digit spelling as `{d}` (no leading
    // zero except for `0` itself), sized for a u64 / usize magnitude. Avoids
    // the formatter on every length prefix and positive int.
    const text = formatDecimal(&buf, value);
    try sink.appendSlice(text);
}

fn formatDecimal(buf: *[20]u8, value: anytype) []const u8 {
    var remaining: u64 = value;
    if (remaining == 0) {
        buf[19] = '0';
        return buf[19..20];
    }
    var i: usize = buf.len;
    while (remaining > 0) {
        i -= 1;
        buf[i] = @intCast((remaining % 10) + '0');
        remaining /= 10;
    }
    return buf[i..];
}

fn writeSignedMagnitude(sink: anytype, value: i64) !void {
    const magnitude: u64 = if (value == std.math.minInt(i64))
        @as(u64, 1) << 63
    else
        @intCast(-value);
    try writeUnsigned(sink, magnitude);
}

fn writeTargetReference(allocator: std.mem.Allocator, sink: anytype, reference: model.Reference) !void {
    // A target is the partner's export or an answer, never one of our own nears,
    // and never a sturdyref: you enliven a sturdyref (a bootstrap fetch), you do
    // not deliver to one. Cap'n Proto carries a sturdy target; Syrup deliberately
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
        // `desc:answer` carries no path operand: a non-empty path must have been
        // decomposed into single-hop links by the engine before encode (ADR-0007
        // § Multi-hop decomposition at the sender). One reaching here is an
        // engine bug, fail loud rather than silently drop the path.
        .promise => |promise| {
            if (!promise.path.isEmpty()) return Error.UnsupportedReference;
            try beginRecord(sink);
            try writeSymbol(sink, "desc:answer");
            try writePositiveInt(sink, promise.answer_position.int());
            try endRecord(sink);
        },
        // A sturdyref rides argument / fulfill position as `<ocapn-sturdyref
        // <ocapn-peer …> swissnum>`, the exact grammar the decoder reads back
        // (`readNeutralArgument`), so a Syrup-decoded sturdyref argument
        // re-encodes and round-trips like its Cap'n Proto twin — including
        // hint entries via `writePeerLocatorRecord`. A sturdyref *deliver
        // target* never reaches here: `writeTargetReference` refuses it first.
        .sturdy => |sturdy| {
            try beginRecord(sink);
            try writeSymbol(sink, "ocapn-sturdyref");
            try writePeerLocatorRecord(sink, allocator, sturdy.peer);
            try writeBytes(sink, sturdy.swissnum);
            try endRecord(sink);
        },
        else => return Error.UnsupportedReference,
    }
}
