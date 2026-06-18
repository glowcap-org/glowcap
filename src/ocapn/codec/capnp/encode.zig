//! Cap'n Proto encode path.
//!
//! This module renders the codec-neutral `model.Message` tree into pancake's
//! self-consistent Cap'n Proto dialect. It owns builder allocation and canonical
//! set ordering; it does not decode or materialize owned values.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const shared = @import("shared.zig");
const wire = shared.wire;

const Error = shared.Error;
const EncodeError = shared.EncodeError;
const Kind = shared.Kind;
const RefKind = shared.RefKind;
const ArgKind = shared.ArgKind;
const ResolutionKind = shared.ResolutionKind;
const PipelineOpKind = shared.PipelineOpKind;
const HandoffKind = shared.HandoffKind;
const StructLoc = shared.StructLoc;

/// Encode for a wire profile — the codec-dispatch boundary's counterpart to
/// `syrup.encodeMessageForProfile`. Cap'n Proto is pancake's self-consistent
/// dialect (ADR-0026): the struct schema always carries `resolve_me_desc` /
/// `wants_partial`, and the engine applies the V1.0 semantic translation
/// (resolver-callback projection) before handing a `model.Message` here, so the
/// word layout is profile-independent. The parameter is accepted for boundary
/// uniformity and intentionally unused.
pub fn encodeMessageForProfile(
    allocator: std.mem.Allocator,
    _: model.WireProfile,
    message: model.Message,
) EncodeError!foundation.Frame {
    return encodeMessage(allocator, message);
}

pub fn encodeMessage(allocator: std.mem.Allocator, message: model.Message) EncodeError!foundation.Frame {
    var builder = wire.Builder{};
    defer builder.deinit(allocator);

    const root_idx = try builder.allocWords(allocator, 1);
    const env = try allocStruct(&builder, allocator, 1, 1);
    setStructPtr(&builder, root_idx, env);
    builder.set(env.data_idx, @intFromEnum(messageKind(message)));

    const body = try encodeBody(&builder, allocator, message);
    setStructPtr(&builder, env.data_idx + env.data_words, body);

    return builder.finish(allocator);
}

fn messageKind(message: model.Message) Kind {
    return switch (message) {
        .deliver => .deliver,
        .resolve => .resolve,
        .gc_export => .gc_export,
        .gc_answer => .gc_answer,
        .handoff => .handoff,
        .start_session => .start_session,
        .abort => .abort,
        .listen => .listen,
        .get => .get,
        .index => .index,
        .untag => .untag,
    };
}

fn encodeBody(b: *wire.Builder, allocator: std.mem.Allocator, message: model.Message) EncodeError!StructLoc {
    return switch (message) {
        .gc_answer => |gc| blk: {
            const loc = try allocStruct(b, allocator, 0, 1);
            try setU64List(b, allocator, loc, 0, gc.positions);
            break :blk loc;
        },
        .gc_export => |gc| blk: {
            const loc = try allocStruct(b, allocator, 0, 2);
            try setU64List(b, allocator, loc, 0, gc.positions);
            try setU64List(b, allocator, loc, 1, gc.deltas);
            break :blk loc;
        },
        .abort => |abort| blk: {
            const loc = try allocStruct(b, allocator, 1, 1);
            b.set(loc.data_idx, @intFromEnum(abort.kind));
            try setData(b, allocator, loc, 0, abort.message);
            break :blk loc;
        },
        .resolve => |resolve| blk: {
            const loc = try allocStruct(b, allocator, 1, 1);
            b.set(loc.data_idx, resolve.answer);
            setStructPtr(b, ptrIndex(loc, 0), try encodeResolution(b, allocator, resolve.resolution));
            break :blk loc;
        },
        .deliver => |deliver| try encodeDeliver(b, allocator, deliver),
        .listen => |listen| blk: {
            const loc = try allocStruct(b, allocator, 1, 2);
            b.set(loc.data_idx, @intFromBool(listen.wants_partial));
            setStructPtr(b, ptrIndex(loc, 0), try encodeReference(b, allocator, listen.target));
            setStructPtr(b, ptrIndex(loc, 1), try encodeReference(b, allocator, listen.listener));
            break :blk loc;
        },
        .get => |get| blk: {
            const loc = try allocStruct(b, allocator, 1, 2);
            b.set(loc.data_idx, get.answer);
            setStructPtr(b, ptrIndex(loc, 0), try encodeReference(b, allocator, get.receiver));
            try setData(b, allocator, loc, 1, get.field);
            break :blk loc;
        },
        .index => |index| blk: {
            const loc = try allocStruct(b, allocator, 2, 1);
            b.set(loc.data_idx, @bitCast(index.index));
            b.set(loc.data_idx + 1, index.answer);
            setStructPtr(b, ptrIndex(loc, 0), try encodeReference(b, allocator, index.receiver));
            break :blk loc;
        },
        .untag => |untag| blk: {
            const loc = try allocStruct(b, allocator, 1, 2);
            b.set(loc.data_idx, untag.answer);
            setStructPtr(b, ptrIndex(loc, 0), try encodeReference(b, allocator, untag.receiver));
            try setData(b, allocator, loc, 1, untag.tag);
            break :blk loc;
        },
        .start_session => |ss| try encodeStartSession(b, allocator, ss),
        .handoff => |handoff| try encodeHandoff(b, allocator, handoff),
    };
}

fn encodeDeliver(b: *wire.Builder, allocator: std.mem.Allocator, deliver: model.Deliver) EncodeError!StructLoc {
    const loc = try allocStruct(b, allocator, 2, 3);
    var flags: u64 = 0;
    if (deliver.answer) |answer| {
        flags |= shared.deliver_has_answer;
        b.set(loc.data_idx + 1, answer);
    }
    if (deliver.resolve_me_desc != null) flags |= shared.deliver_has_resolve_me;
    b.set(loc.data_idx, flags);
    setStructPtr(b, ptrIndex(loc, 0), try encodeReference(b, allocator, deliver.target));
    setListPtr(b, ptrIndex(loc, 1), try encodeArgumentList(b, allocator, deliver.args));
    if (deliver.resolve_me_desc) |desc| setStructPtr(b, ptrIndex(loc, 2), try encodeReference(b, allocator, desc));
    return loc;
}

fn encodeStartSession(b: *wire.Builder, allocator: std.mem.Allocator, ss: model.StartSession) EncodeError!StructLoc {
    const loc = try allocStruct(b, allocator, 0, 4);
    try setData(b, allocator, loc, 0, ss.captp_version.wireString());
    try setData(b, allocator, loc, 1, ss.session_pubkey.bytes);
    setStructPtr(b, ptrIndex(loc, 2), try encodePeerLocator(b, allocator, ss.acceptable_location));
    try setData(b, allocator, loc, 3, ss.acceptable_location_sig.bytes);
    return loc;
}

fn encodeResolution(b: *wire.Builder, allocator: std.mem.Allocator, resolution: model.Resolution) EncodeError!StructLoc {
    const loc = try allocStruct(b, allocator, 1, 1);
    switch (resolution) {
        .fulfill => |arg| {
            b.set(loc.data_idx, @intFromEnum(ResolutionKind.fulfill));
            setStructPtr(b, ptrIndex(loc, 0), try encodeArgument(b, allocator, arg));
        },
        .@"break" => |err| {
            b.set(loc.data_idx, @intFromEnum(ResolutionKind.@"break"));
            setStructPtr(b, ptrIndex(loc, 0), try encodeError(b, allocator, err));
        },
    }
    return loc;
}

fn encodeHandoff(b: *wire.Builder, allocator: std.mem.Allocator, handoff: model.Handoff) EncodeError!StructLoc {
    const loc = try allocStruct(b, allocator, 1, 1);
    switch (handoff) {
        .give => |give| {
            b.set(loc.data_idx, @intFromEnum(HandoffKind.give));
            setStructPtr(b, ptrIndex(loc, 0), try encodeHandoffGive(b, allocator, give));
        },
        .receive => |receive| {
            b.set(loc.data_idx, @intFromEnum(HandoffKind.receive));
            setStructPtr(b, ptrIndex(loc, 0), try encodeHandoffReceive(b, allocator, receive));
        },
    }
    return loc;
}

fn encodeHandoffGive(b: *wire.Builder, allocator: std.mem.Allocator, give: model.HandoffGive) EncodeError!StructLoc {
    const loc = try allocStruct(b, allocator, 0, 6);
    try setData(b, allocator, loc, 0, give.recipient_key);
    try setData(b, allocator, loc, 1, give.exporter_location);
    try setData(b, allocator, loc, 2, give.gifter_exporter_session);
    try setData(b, allocator, loc, 3, give.gifter_side);
    try setData(b, allocator, loc, 4, give.gift_id);
    try setData(b, allocator, loc, 5, give.signature);
    return loc;
}

fn encodeHandoffReceive(b: *wire.Builder, allocator: std.mem.Allocator, receive: model.HandoffReceive) EncodeError!StructLoc {
    const loc = try allocStruct(b, allocator, 1, 4);
    b.set(loc.data_idx, receive.handoff_count);
    try setData(b, allocator, loc, 0, receive.receiving_session);
    try setData(b, allocator, loc, 1, receive.receiving_side);
    setStructPtr(b, ptrIndex(loc, 2), try encodeHandoffGive(b, allocator, receive.signed_give));
    try setData(b, allocator, loc, 3, receive.signature);
    return loc;
}

fn encodeReference(b: *wire.Builder, allocator: std.mem.Allocator, reference: model.Reference) EncodeError!StructLoc {
    const loc = try allocStruct(b, allocator, 2, 2);
    switch (reference) {
        .near => |near| {
            b.set(loc.data_idx, @intFromEnum(RefKind.near) | (if (near.kind == .promise) shared.data0_flag else 0));
            b.set(loc.data_idx + 1, near.export_position);
        },
        .far => |far| {
            b.set(loc.data_idx, @intFromEnum(RefKind.far) | (if (far.kind == .promise) shared.data0_flag else 0));
            b.set(loc.data_idx + 1, far.import_position);
        },
        .promise => |promise| {
            b.set(loc.data_idx, @intFromEnum(RefKind.promise));
            b.set(loc.data_idx + 1, promise.answer_position);
            if (promise.path.ops.len != 0) setListPtr(b, ptrIndex(loc, 0), try encodePipelinePath(b, allocator, promise.path.ops));
        },
        .sturdy => |sturdy| {
            b.set(loc.data_idx, @intFromEnum(RefKind.sturdy));
            setStructPtr(b, ptrIndex(loc, 0), try encodePeerLocator(b, allocator, sturdy.peer));
            try setData(b, allocator, loc, 1, sturdy.swissnum);
        },
        .broken => return Error.UnsupportedReference,
    }
    return loc;
}

fn encodePeerLocator(b: *wire.Builder, allocator: std.mem.Allocator, locator: model.PeerLocator) EncodeError!StructLoc {
    // The layout carries only the two empty hint spellings (the `#f` bit). A
    // locator carrying hint entries is refused loudly: silently dropping the
    // entries would put a different locator on the wire than the caller named.
    if (locator.hints.entries.len != 0) return Error.UnsupportedArgument;
    const loc = try allocStruct(b, allocator, 1, 2);
    if (locator.hints.wire_form == .boolean_false) b.set(loc.data_idx, 1);
    try setData(b, allocator, loc, 0, locator.transport);
    try setData(b, allocator, loc, 1, locator.designator);
    return loc;
}

fn encodeError(b: *wire.Builder, allocator: std.mem.Allocator, err: model.BreakReason) EncodeError!StructLoc {
    const loc = try allocStruct(b, allocator, 0, 1);
    try setData(b, allocator, loc, 0, err.message);
    return loc;
}

fn encodeTagged(b: *wire.Builder, allocator: std.mem.Allocator, tagged: model.Tagged) EncodeError!StructLoc {
    const loc = try allocStruct(b, allocator, 0, 2);
    try setData(b, allocator, loc, 0, tagged.tag);
    setListPtr(b, ptrIndex(loc, 1), try encodeArgumentList(b, allocator, tagged.value));
    return loc;
}

fn encodeArgument(b: *wire.Builder, allocator: std.mem.Allocator, arg: model.Argument) EncodeError!StructLoc {
    const loc = try allocStruct(b, allocator, 2, 1);
    try encodeArgumentInto(b, allocator, arg, loc);
    return loc;
}

/// Fill an already-allocated 2-data / 1-pointer Argument struct at `loc`. Used
/// both standalone and for composite-list elements.
fn encodeArgumentInto(b: *wire.Builder, allocator: std.mem.Allocator, arg: model.Argument, loc: StructLoc) EncodeError!void {
    switch (arg) {
        .bytes => |bytes| {
            b.set(loc.data_idx, @intFromEnum(ArgKind.bytes));
            try setData(b, allocator, loc, 0, bytes);
        },
        .symbol => |symbol| {
            b.set(loc.data_idx, @intFromEnum(ArgKind.symbol));
            try setData(b, allocator, loc, 0, symbol);
        },
        .reference => |reference| {
            b.set(loc.data_idx, @intFromEnum(ArgKind.reference));
            setStructPtr(b, ptrIndex(loc, 0), try encodeReference(b, allocator, reference));
        },
        .@"error" => |err| {
            b.set(loc.data_idx, @intFromEnum(ArgKind.@"error"));
            setStructPtr(b, ptrIndex(loc, 0), try encodeError(b, allocator, err));
        },
        .handoff => |handoff| {
            b.set(loc.data_idx, @intFromEnum(ArgKind.handoff));
            setStructPtr(b, ptrIndex(loc, 0), try encodeHandoff(b, allocator, handoff.*));
        },
        .string => |string| {
            b.set(loc.data_idx, @intFromEnum(ArgKind.string));
            try setData(b, allocator, loc, 0, string);
        },
        .integer => |integer| {
            b.set(loc.data_idx, @intFromEnum(ArgKind.integer));
            b.set(loc.data_idx + 1, @bitCast(integer));
        },
        .boolean => |boolean| {
            b.set(loc.data_idx, @intFromEnum(ArgKind.boolean) | (if (boolean) shared.data0_flag else 0));
        },
        .big_integer => |big| {
            // Symmetric refusal (ADR-0003): a non-canonical big integer —
            // leading zeros, non-digits, or a magnitude that belongs to the
            // `integer` arm — never reaches the wire.
            if (!big.isCanonical()) return Error.UnsupportedArgument;
            b.set(loc.data_idx, @intFromEnum(ArgKind.big_integer) | (if (big.negative) shared.data0_flag else 0));
            try setData(b, allocator, loc, 0, big.digits);
        },
        .list => |list| {
            b.set(loc.data_idx, @intFromEnum(ArgKind.list));
            setListPtr(b, ptrIndex(loc, 0), try encodeArgumentList(b, allocator, list));
        },
        .void => b.set(loc.data_idx, @intFromEnum(ArgKind.void)),
        .float64 => |float64| {
            b.set(loc.data_idx, @intFromEnum(ArgKind.float64));
            b.set(loc.data_idx + 1, @bitCast(float64));
        },
        .set => |set| {
            b.set(loc.data_idx, @intFromEnum(ArgKind.set));
            const ordered = try canonicalSetOrder(allocator, set);
            defer allocator.free(ordered);
            setListPtr(b, ptrIndex(loc, 0), try encodeArgumentList(b, allocator, ordered));
        },
        .tagged => |tagged| {
            b.set(loc.data_idx, @intFromEnum(ArgKind.tagged));
            setStructPtr(b, ptrIndex(loc, 0), try encodeTagged(b, allocator, tagged));
        },
        .keyword => |keyword| {
            b.set(loc.data_idx, @intFromEnum(ArgKind.keyword));
            try setData(b, allocator, loc, 0, keyword);
        },
        .@"struct" => |entries| {
            b.set(loc.data_idx, @intFromEnum(ArgKind.@"struct"));
            setListPtr(b, ptrIndex(loc, 0), try encodeStructEntries(b, allocator, entries));
        },
    }
}

/// Composite list of struct entries: each element is a 0-data / 2-pointer struct
/// holding the String key text (pointer 0) and the value Argument struct
/// (pointer 1). Entries are emitted in canonical key order so the wire form does
/// not depend on the order the model held them in.
fn encodeStructEntries(b: *wire.Builder, allocator: std.mem.Allocator, entries: []const model.StructEntry) EncodeError!ListContent {
    const data_words: u16 = 0;
    const ptr_words: u16 = 2;
    const stride: usize = data_words + ptr_words;
    const ordered = try canonicalStructOrder(allocator, entries);
    defer allocator.free(ordered);
    const tag_idx = try b.allocWords(allocator, 1);
    b.set(tag_idx, wire.Builder.compositeTag(@intCast(ordered.len), data_words, ptr_words));
    const block = try b.allocWords(allocator, ordered.len * stride);
    for (ordered, 0..) |entry, i| {
        const loc = StructLoc{ .data_idx = block + i * stride, .data_words = data_words, .ptr_words = ptr_words };
        try setData(b, allocator, loc, 0, entry.key);
        setStructPtr(b, ptrIndex(loc, 1), try encodeArgument(b, allocator, entry.value));
    }
    return .{ .data_idx = tag_idx, .elem = .composite, .count = ordered.len * stride };
}

/// Return a struct's entries in canonical key order. Keys are unique Strings, so a
/// shallow copy sorted by raw key bytes is deterministic; the caller owns and frees
/// the returned slice (the entries' bytes stay borrowed from the model).
fn canonicalStructOrder(allocator: std.mem.Allocator, entries: []const model.StructEntry) EncodeError![]model.StructEntry {
    const ordered = try allocator.alloc(model.StructEntry, entries.len);
    errdefer allocator.free(ordered);
    for (entries, 0..) |entry, i| ordered[i] = entry;
    std.mem.sort(model.StructEntry, ordered, {}, lessByEntryKey);
    return ordered;
}

fn lessByEntryKey(_: void, a: model.StructEntry, b: model.StructEntry) bool {
    return std.mem.lessThan(u8, a.key, b.key);
}

/// Composite list of `Argument` (2 data words, 1 pointer word per element).
fn encodeArgumentList(b: *wire.Builder, allocator: std.mem.Allocator, args: []const model.Argument) EncodeError!ListContent {
    const data_words: u16 = 2;
    const ptr_words: u16 = 1;
    const stride: usize = data_words + ptr_words;
    const tag_idx = try b.allocWords(allocator, 1);
    b.set(tag_idx, wire.Builder.compositeTag(@intCast(args.len), data_words, ptr_words));
    const block = try b.allocWords(allocator, args.len * stride);
    for (args, 0..) |arg, i| {
        try encodeArgumentInto(b, allocator, arg, .{ .data_idx = block + i * stride, .data_words = data_words, .ptr_words = ptr_words });
    }
    return .{ .data_idx = tag_idx, .elem = .composite, .count = args.len * stride };
}

/// Return a set's elements in canonical order: each element is encoded to its
/// own standalone Cap'n Proto message, the elements are sorted by those encoded
/// bytes, and the reordered (shallow) slice is returned for the caller to encode
/// in place. Caller owns the returned slice.
fn canonicalSetOrder(allocator: std.mem.Allocator, args: []const model.Argument) EncodeError![]model.Argument {
    const ordered = try allocator.alloc(model.Argument, args.len);
    errdefer allocator.free(ordered);
    for (args, 0..) |arg, i| ordered[i] = arg;
    if (args.len < 2) return ordered;

    const keys = try allocator.alloc([]u8, args.len);
    var built: usize = 0;
    defer {
        for (keys[0..built]) |key| allocator.free(key);
        allocator.free(keys);
    }
    for (args) |arg| {
        keys[built] = try encodeArgumentKey(allocator, arg);
        built += 1;
    }

    const order = try allocator.alloc(usize, args.len);
    defer allocator.free(order);
    for (order, 0..) |*o, i| o.* = i;
    std.mem.sort(usize, order, keys, lessByKeyBytes);
    for (order, 0..) |src, i| ordered[i] = args[src];
    return ordered;
}

fn lessByKeyBytes(keys: []const []u8, a: usize, b: usize) bool {
    return std.mem.lessThan(u8, keys[a], keys[b]);
}

/// Encode a single `Argument` as a standalone Cap'n Proto message and return its
/// owned bytes — the canonical sort key for set ordering. Caller owns the slice.
fn encodeArgumentKey(allocator: std.mem.Allocator, arg: model.Argument) EncodeError![]u8 {
    var builder = wire.Builder{};
    defer builder.deinit(allocator);
    const root_idx = try builder.allocWords(allocator, 1);
    const loc = try encodeArgument(&builder, allocator, arg);
    setStructPtr(&builder, root_idx, loc);
    var frame = try builder.finish(allocator);
    defer frame.deinit();
    return allocator.dupe(u8, frame.bytes());
}

/// Composite list of `PipelineOp` (1 data word, 1 pointer word per element).
fn encodePipelinePath(b: *wire.Builder, allocator: std.mem.Allocator, ops: []const model.PipelineOp) EncodeError!ListContent {
    const data_words: u16 = 1;
    const ptr_words: u16 = 1;
    const stride: usize = data_words + ptr_words;
    const tag_idx = try b.allocWords(allocator, 1);
    b.set(tag_idx, wire.Builder.compositeTag(@intCast(ops.len), data_words, ptr_words));
    const block = try b.allocWords(allocator, ops.len * stride);
    for (ops, 0..) |op, i| {
        const loc = StructLoc{ .data_idx = block + i * stride, .data_words = data_words, .ptr_words = ptr_words };
        switch (op) {
            .field => |field| {
                b.set(loc.data_idx, @intFromEnum(PipelineOpKind.field));
                try setData(b, allocator, loc, 0, field);
            },
            .call => |call| {
                b.set(loc.data_idx, @intFromEnum(PipelineOpKind.call));
                setListPtr(b, ptrIndex(loc, 0), try encodeArgumentList(b, allocator, call));
            },
        }
    }
    return .{ .data_idx = tag_idx, .elem = .composite, .count = ops.len * stride };
}

const ListContent = struct { data_idx: usize, elem: wire.ElementSize, count: usize };

fn allocStruct(b: *wire.Builder, allocator: std.mem.Allocator, data_words: u16, ptr_words: u16) EncodeError!StructLoc {
    const idx = try b.allocWords(allocator, @as(usize, data_words) + ptr_words);
    return .{ .data_idx = idx, .data_words = data_words, .ptr_words = ptr_words };
}

fn ptrIndex(loc: StructLoc, i: u16) usize {
    return loc.data_idx + loc.data_words + i;
}

fn setStructPtr(b: *wire.Builder, ptr_idx: usize, loc: StructLoc) void {
    b.set(ptr_idx, wire.encodeStructPointer(wire.Builder.offsetTo(ptr_idx, loc.data_idx), loc.data_words, loc.ptr_words));
}

fn setListPtr(b: *wire.Builder, ptr_idx: usize, content: ListContent) void {
    b.set(ptr_idx, wire.encodeListPointer(wire.Builder.offsetTo(ptr_idx, content.data_idx), content.elem, @intCast(content.count)));
}

fn setU64List(b: *wire.Builder, allocator: std.mem.Allocator, loc: StructLoc, i: u16, values: []const u64) EncodeError!void {
    const start = try b.allocWords(allocator, values.len);
    for (values, 0..) |value, idx| b.set(start + idx, value);
    setListPtr(b, ptrIndex(loc, i), .{ .data_idx = start, .elem = .eight_bytes, .count = values.len });
}

fn setData(b: *wire.Builder, allocator: std.mem.Allocator, loc: StructLoc, i: u16, bytes: []const u8) EncodeError!void {
    const start = try b.allocWords(allocator, wire.wordsForBytes(bytes.len));
    b.setBytes(start, bytes);
    setListPtr(b, ptrIndex(loc, i), .{ .data_idx = start, .elem = .byte, .count = bytes.len });
}
