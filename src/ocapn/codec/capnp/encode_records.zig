//! Cap'n Proto record layouts for the encoder: references, peer locators and
//! their hint entries, handoff certificates, break reasons, signatures, and
//! validated text. Every writer takes the borrowed record (`model.view`), or
//! either source where an argument tree reaches it, so an owned record and a
//! decoded one share one layout. This leaf knows no message or argument
//! structure.

const std = @import("std");

const model = @import("model");
const layout = @import("encode_layout.zig");
const shared = @import("shared.zig");
const wire = shared.wire;
const view = model.view;

const Error = shared.Error;
const EncodeError = shared.EncodeError;
const RefTag = shared.RefTag;
const HandoffKind = shared.HandoffKind;
const StructLoc = shared.StructLoc;
const ListContent = layout.ListContent;
const allocStruct = layout.allocStruct;
const ptrIndex = layout.ptrIndex;
const setStructPtr = layout.setStructPtr;
const setListPtr = layout.setListPtr;
const setData = layout.setData;

/// Write a text field, refusing malformed UTF-8 as `UnsupportedArgument`.
/// Validating where the text is written is the one pass over it, and the
/// refusal commits nothing: the builder is dropped with the error.
pub fn setText(b: *wire.Builder, allocator: std.mem.Allocator, loc: StructLoc, i: u16, text: []const u8) EncodeError!void {
    if (!@import("foundation").utf8.valid(text)) return Error.UnsupportedArgument;
    try setData(b, allocator, loc, i, text);
}

/// Write an Ed25519 signature as one 64-byte Data field from whichever shape
/// its source carried: the raw bytes as they are, or Syrup's two halves
/// joined in the field's own words.
pub fn setSignature(b: *wire.Builder, allocator: std.mem.Allocator, loc: StructLoc, i: u16, sig: view.Signature) EncodeError!void {
    switch (sig) {
        .raw => |raw| try setData(b, allocator, loc, i, raw),
        .halves => |halves| {
            if (halves.r.len != 32 or halves.s.len != 32) return Error.UnsupportedArgument;
            const start = try b.allocWords(allocator, wire.wordsForBytes(64));
            b.setBytes(start, halves.r);
            b.setBytes(start + wire.wordsForBytes(32), halves.s);
            try setListPtr(b, ptrIndex(loc, i), .{ .data_idx = start, .elem = .byte, .count = 64 });
        },
    }
}

pub fn encodeError(b: *wire.Builder, allocator: std.mem.Allocator, message: []const u8) EncodeError!StructLoc {
    const loc = try allocStruct(b, allocator, 0, 1);
    try setText(b, allocator, loc, 0, message);
    return loc;
}

/// Write a reference from either source (`model.Reference` or
/// `view.Reference`).
pub fn encodeReference(b: *wire.Builder, allocator: std.mem.Allocator, reference: anytype) EncodeError!StructLoc {
    const loc = try allocStruct(b, allocator, 2, 2);
    switch (reference) {
        .near => |near| {
            b.set(loc.data_idx, @backingInt(RefTag.near) | (if (near.kind == .promise) shared.data0_flag else 0));
            b.set(loc.data_idx + 1, near.export_position.int());
        },
        .far => |far| {
            b.set(loc.data_idx, @backingInt(RefTag.far) | (if (far.kind == .promise) shared.data0_flag else 0));
            b.set(loc.data_idx + 1, far.import_position.int());
        },
        .routed => return Error.UnsupportedReference,
        .promise => |promise| {
            b.set(loc.data_idx, @backingInt(RefTag.promise));
            b.set(loc.data_idx + 1, promise.answer_position.int());
        },
        .sturdy => |source| {
            const sturdy = try view.borrowSturdy(source);
            b.set(loc.data_idx, @backingInt(RefTag.sturdy));
            setStructPtr(b, ptrIndex(loc, 0), try encodePeerLocator(b, allocator, sturdy.peer));
            try setData(b, allocator, loc, 1, sturdy.swissnum);
        },
        .broken => return Error.UnsupportedReference,
    }
    return loc;
}

/// Encode a `PeerLocator`, including hint entries when present. Sturdyrefs,
/// `op:start-session` `acceptable_location`, and `desc:handoff-give` exporters
/// all share this one layout, so a hint-carrying locator round-trips on every
/// arm instead of being refused or silently dropped. A lazy codec hint list
/// (a decoded frame's) is projected into scratch for this one write and freed
/// before return (memory-ledger "Handoff canonicalization").
pub fn encodePeerLocator(b: *wire.Builder, allocator: std.mem.Allocator, locator: view.PeerLocator) EncodeError!StructLoc {
    model.validateLocatorTransportDesignator(locator.transport, locator.designator) catch return Error.UnsupportedArgument;
    const loc = try allocStruct(b, allocator, 1, 3);
    if (locator.hints.wireForm() == .boolean_false) b.set(loc.data_idx, 1);
    try setText(b, allocator, loc, 0, locator.transport);
    try setText(b, allocator, loc, 1, locator.designator);
    switch (locator.hints) {
        .empty => try setListPtr(b, ptrIndex(loc, 2), try encodeHintEntries(b, allocator, &.{})),
        .projected => |hints| try setHintEntries(b, allocator, loc, hints),
        .lazy => {
            const hints = try locator.hints.toOwned(allocator);
            defer model.freeHints(allocator, hints);
            try setHintEntries(b, allocator, loc, hints);
        },
    }
    return loc;
}

fn setHintEntries(b: *wire.Builder, allocator: std.mem.Allocator, loc: StructLoc, hints: model.Hints) EncodeError!void {
    model.validateHints(hints) catch return Error.UnsupportedArgument;
    try setListPtr(b, ptrIndex(loc, 2), try encodeHintEntries(b, allocator, hints.entries));
}

/// Composite list of hint entries: each element is a 2-data / 2-pointer struct
/// holding a discriminant plus inline payload in the data words (data word 0
/// bit 16 doubles as the boolean value. Data word 1 carries an integer value),
/// the entry's String name at pointer 0, and a String/Bytes payload at pointer
/// 1 for the `string`/`bytes` value kinds. Model order is preserved. The peer
/// locator validation above owns the dictionary invariants.
fn encodeHintEntries(b: *wire.Builder, allocator: std.mem.Allocator, entries: []const model.HintEntry) EncodeError!ListContent {
    const data_words: u16 = 2;
    const ptr_words: u16 = 2;
    const stride: usize = data_words + ptr_words;
    const tag_idx = try b.allocWords(allocator, 1 + entries.len * stride);
    b.set(tag_idx, wire.Builder.compositeTag(@intCast(entries.len), data_words, ptr_words));
    const block = tag_idx + 1;
    for (entries, 0..) |entry, i| {
        const loc = StructLoc{ .data_idx = block + i * stride, .data_words = data_words, .ptr_words = ptr_words };
        try setText(b, allocator, loc, 0, entry.name);
        switch (entry.value) {
            .string => |s| {
                b.set(loc.data_idx, @backingInt(shared.HintValueKind.string));
                try setText(b, allocator, loc, 1, s);
            },
            .bytes => |by| {
                b.set(loc.data_idx, @backingInt(shared.HintValueKind.bytes));
                try setData(b, allocator, loc, 1, by);
            },
            .boolean => |bo| {
                b.set(loc.data_idx, @backingInt(shared.HintValueKind.boolean) | (if (bo) shared.data0_flag else 0));
            },
            .integer => |int| {
                b.set(loc.data_idx, @backingInt(shared.HintValueKind.integer));
                b.set(loc.data_idx + 1, @bitCast(int));
            },
        }
    }
    return .{ .data_idx = tag_idx, .elem = .composite, .count = entries.len * stride };
}

pub fn encodeHandoff(b: *wire.Builder, allocator: std.mem.Allocator, handoff: view.Handoff) EncodeError!StructLoc {
    const loc = try allocStruct(b, allocator, 1, 1);
    switch (handoff) {
        .give => |give| {
            b.set(loc.data_idx, @backingInt(HandoffKind.give));
            setStructPtr(b, ptrIndex(loc, 0), try encodeHandoffGive(b, allocator, give));
        },
        .receive => |receive| {
            b.set(loc.data_idx, @backingInt(HandoffKind.receive));
            setStructPtr(b, ptrIndex(loc, 0), try encodeHandoffReceive(b, allocator, receive));
        },
    }
    return loc;
}

fn encodeHandoffGive(b: *wire.Builder, allocator: std.mem.Allocator, give: view.HandoffGive) EncodeError!StructLoc {
    const loc = try allocStruct(b, allocator, 0, 6);
    try setData(b, allocator, loc, 0, give.recipient_key);
    // Structural PeerLocator (same layout as sturdyref / start-session).
    setStructPtr(b, ptrIndex(loc, 1), try encodePeerLocator(b, allocator, give.exporter));
    try setData(b, allocator, loc, 2, give.gifter_exporter_session);
    try setData(b, allocator, loc, 3, give.gifter_side);
    try setData(b, allocator, loc, 4, give.gift_id);
    try setSignature(b, allocator, loc, 5, give.signature);
    return loc;
}

fn encodeHandoffReceive(b: *wire.Builder, allocator: std.mem.Allocator, receive: view.HandoffReceive) EncodeError!StructLoc {
    const loc = try allocStruct(b, allocator, 1, 4);
    b.set(loc.data_idx, receive.handoff_count);
    try setData(b, allocator, loc, 0, receive.receiving_session);
    try setData(b, allocator, loc, 1, receive.receiving_side);
    setStructPtr(b, ptrIndex(loc, 2), try encodeHandoffGive(b, allocator, receive.signed_give));
    try setSignature(b, allocator, loc, 3, receive.signature);
    return loc;
}
