//! Cap'n Proto encode path.
//!
//! This module renders the codec-neutral `model.Message` tree into glowcap's
//! self-consistent Cap'n Proto dialect. It owns builder allocation and canonical
//! set ordering; it does not decode or materialize owned values.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const codec_order = @import("codec_order");
const layout = @import("encode_layout.zig");
const shared = @import("shared.zig");
const validation = @import("encode_validation.zig");
const wire = shared.wire;

const Error = shared.Error;
const EncodeError = shared.EncodeError;
const Kind = shared.Kind;
const RefTag = shared.RefTag;
const ArgKind = shared.ArgKind;
const ResolutionKind = shared.ResolutionKind;
const HandoffKind = shared.HandoffKind;
const StructLoc = shared.StructLoc;
const ListContent = layout.ListContent;
const allocStruct = layout.allocStruct;
const ptrIndex = layout.ptrIndex;
const setStructPtr = layout.setStructPtr;
const setListPtr = layout.setListPtr;
const setU64List = layout.setU64List;
const setData = layout.setData;

/// Encode for a CapTP version, the codec-dispatch boundary's counterpart to
/// `syrup.encodeMessageForProfile`. Cap'n Proto is glowcap's self-consistent
/// dialect (ADR-0026): the struct schema always carries `resolve_me_desc` /
/// `wants_partial`, and word layout stays profile-independent. The profile
/// still gates what may be encoded: `.next` refuses wire `op:resolve` and a
/// deliver that still carries `resolve_me_desc`, matching the listen-mode
/// profile split on the decode path.
pub fn encodeMessageForProfile(
    allocator: std.mem.Allocator,
    profile: model.CaptpVersion,
    message: model.Message,
) EncodeError!foundation.Frame {
    return encodeMessageOptionalProfile(allocator, profile, message);
}

pub fn encodeMessage(allocator: std.mem.Allocator, message: model.Message) EncodeError!foundation.Frame {
    return encodeMessageOptionalProfile(allocator, null, message);
}

fn encodeMessageOptionalProfile(allocator: std.mem.Allocator, profile: ?model.CaptpVersion, message: model.Message) EncodeError!foundation.Frame {
    if (profile == .next and message == .resolve) return Error.UnsupportedMessage;
    if (profile == .next and message == .deliver and message.deliver.resolve_me_desc != null)
        return Error.UnsupportedMessage;
    // Validate model text before the builder obtains its first word. The walk
    // borrows every slice and allocates nothing, so malformed outbound text is
    // a protocol refusal rather than an allocation-dependent partial encode.
    try validation.validateMessageUtf8(message);

    var builder = try wire.Builder.init(allocator);
    defer builder.deinit(allocator);

    const root_idx = try builder.allocWords(allocator, 1);
    const env = try allocStruct(&builder, allocator, 1, 1);
    setStructPtr(&builder, root_idx, env);
    builder.set(env.data_idx, @backingInt(messageKind(message)));

    const body = try encodeBody(&builder, allocator, profile, message);
    setStructPtr(&builder, env.data_idx + env.data_words, body);

    return builder.finishOwned(allocator);
}

fn messageKind(message: model.Message) Kind {
    // Exhaustive over `model.Message` tags; `Kind` mirrors them via
    // `assertMirrorsMessageKinds`, so a new arm fails here and in decode's
    // `bodyProjector` together. Wire ids stay the explicit `Kind` enum values.
    return switch (message) {
        inline else => |_, tag| @field(Kind, @tagName(tag)),
    };
}

fn encodeBody(b: *wire.Builder, allocator: std.mem.Allocator, profile: ?model.CaptpVersion, message: model.Message) EncodeError!StructLoc {
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
            b.set(loc.data_idx, @backingInt(abort.kind));
            try setData(b, allocator, loc, 0, abort.message);
            break :blk loc;
        },
        .resolve => |resolve| blk: {
            const loc = try allocStruct(b, allocator, 1, 1);
            b.set(loc.data_idx, resolve.answer.int());
            setStructPtr(b, ptrIndex(loc, 0), try encodeResolution(b, allocator, resolve.resolution));
            break :blk loc;
        },
        .deliver => |deliver| try encodeDeliver(b, allocator, deliver),
        .listen => |listen| blk: {
            const loc = try allocStruct(b, allocator, 1, 2);
            b.set(loc.data_idx, switch (profile orelse .v1_0) {
                .v1_0 => @intFromBool(listen.mode.toV1_0WantsPartial() orelse return Error.UnsupportedMessage),
                .next => @backingInt(listen.mode),
            });
            setStructPtr(b, ptrIndex(loc, 0), try encodeReference(b, allocator, listen.target));
            setStructPtr(b, ptrIndex(loc, 1), try encodeReference(b, allocator, listen.listener));
            break :blk loc;
        },
        .get => |get| blk: {
            const loc = try allocStruct(b, allocator, 1, 2);
            b.set(loc.data_idx, get.answer.int());
            setStructPtr(b, ptrIndex(loc, 0), try encodeReference(b, allocator, get.receiver));
            try setData(b, allocator, loc, 1, get.field);
            break :blk loc;
        },
        .index => |index| blk: {
            switch (index.index) {
                .integer => |value| {
                    // Preserve the original compact layout for ordinary indexes.
                    const loc = try allocStruct(b, allocator, 2, 1);
                    b.set(loc.data_idx, @bitCast(value));
                    b.set(loc.data_idx + 1, index.answer.int());
                    setStructPtr(b, ptrIndex(loc, 0), try encodeReference(b, allocator, index.receiver));
                    break :blk loc;
                },
                .big_integer => |big| {
                    if (!big.isCanonical()) return Error.UnsupportedArgument;
                    const loc = try allocStruct(b, allocator, 3, 2);
                    b.set(loc.data_idx, 0);
                    b.set(loc.data_idx + 1, index.answer.int());
                    b.set(loc.data_idx + 2, shared.index_big_integer |
                        (if (big.negative) shared.index_negative else 0));
                    setStructPtr(b, ptrIndex(loc, 0), try encodeReference(b, allocator, index.receiver));
                    try setData(b, allocator, loc, 1, big.digits);
                    break :blk loc;
                },
            }
        },
        .untag => |untag| blk: {
            const loc = try allocStruct(b, allocator, 1, 2);
            b.set(loc.data_idx, untag.answer.int());
            setStructPtr(b, ptrIndex(loc, 0), try encodeReference(b, allocator, untag.receiver));
            try setData(b, allocator, loc, 1, untag.tag);
            break :blk loc;
        },
        .start_session => |ss| try encodeStartSession(b, allocator, ss),
    };
}

fn encodeDeliver(b: *wire.Builder, allocator: std.mem.Allocator, deliver: model.Deliver) EncodeError!StructLoc {
    const loc = try allocStruct(b, allocator, 2, 3);
    var flags: u64 = 0;
    if (deliver.answer) |answer| {
        flags |= shared.deliver_has_answer;
        b.set(loc.data_idx + 1, answer.int());
    }
    if (deliver.resolve_me_desc != null) flags |= shared.deliver_has_resolve_me;
    b.set(loc.data_idx, flags);
    setStructPtr(b, ptrIndex(loc, 0), try encodeReference(b, allocator, deliver.target));
    try setListPtr(b, ptrIndex(loc, 1), try encodeArgumentList(b, allocator, deliver.args));
    if (deliver.resolve_me_desc) |desc| setStructPtr(b, ptrIndex(loc, 2), try encodeReference(b, allocator, desc));
    return loc;
}

fn encodeStartSession(b: *wire.Builder, allocator: std.mem.Allocator, ss: model.StartSession) EncodeError!StructLoc {
    const loc = try allocStruct(b, allocator, 0, 4);
    // A hello with no version is one this codebase never builds: outbound the
    // version is ours. Refuse rather than invent one.
    const version = ss.captp_version orelse return Error.MalformedFrame;
    try setData(b, allocator, loc, 0, version.wireString());
    try setData(b, allocator, loc, 1, ss.session_pubkey.bytes);
    setStructPtr(b, ptrIndex(loc, 2), try encodePeerLocator(b, allocator, ss.acceptable_location));
    try setData(b, allocator, loc, 3, ss.acceptable_location_sig.bytes);
    return loc;
}

fn encodeResolution(b: *wire.Builder, allocator: std.mem.Allocator, resolution: model.Resolution) EncodeError!StructLoc {
    const loc = try allocStruct(b, allocator, 1, 1);
    switch (resolution) {
        .fulfill => |arg| {
            b.set(loc.data_idx, @backingInt(ResolutionKind.fulfill));
            setStructPtr(b, ptrIndex(loc, 0), try encodeArgument(b, allocator, arg));
        },
        .@"break" => |err| {
            b.set(loc.data_idx, @backingInt(ResolutionKind.@"break"));
            setStructPtr(b, ptrIndex(loc, 0), try encodeError(b, allocator, err));
        },
    }
    return loc;
}

fn encodeHandoff(b: *wire.Builder, allocator: std.mem.Allocator, handoff: model.Handoff) EncodeError!StructLoc {
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

fn encodeHandoffGive(b: *wire.Builder, allocator: std.mem.Allocator, give: model.HandoffGive) EncodeError!StructLoc {
    const loc = try allocStruct(b, allocator, 0, 6);
    try setData(b, allocator, loc, 0, give.recipient_key);
    // Structural PeerLocator (same layout as sturdyref / start-session).
    setStructPtr(b, ptrIndex(loc, 1), try encodePeerLocator(b, allocator, give.exporter));
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
        .sturdy => |sturdy| {
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
/// arm instead of being refused or silently dropped.
fn encodePeerLocator(b: *wire.Builder, allocator: std.mem.Allocator, locator: model.PeerLocator) EncodeError!StructLoc {
    model.validatePeerLocator(locator) catch return Error.UnsupportedArgument;
    const loc = try allocStruct(b, allocator, 1, 3);
    if (locator.hints.wire_form == .boolean_false) b.set(loc.data_idx, 1);
    try setData(b, allocator, loc, 0, locator.transport);
    try setData(b, allocator, loc, 1, locator.designator);
    try setListPtr(b, ptrIndex(loc, 2), try encodeHintEntries(b, allocator, locator.hints.entries));
    return loc;
}

/// Composite list of hint entries: each element is a 2-data / 2-pointer struct
/// holding a discriminant plus inline payload in the data words (data word 0
/// bit 16 doubles as the boolean value; data word 1 carries an integer value),
/// the entry's String name at pointer 0, and a String/Bytes payload at pointer
/// 1 for the `string`/`bytes` value kinds. Model order is preserved; the peer
/// locator validation above owns the dictionary invariants.
fn encodeHintEntries(b: *wire.Builder, allocator: std.mem.Allocator, entries: []const model.HintEntry) EncodeError!ListContent {
    const data_words: u16 = 2;
    const ptr_words: u16 = 2;
    const stride: usize = data_words + ptr_words;
    const tag_idx = try b.allocWords(allocator, 1);
    b.set(tag_idx, wire.Builder.compositeTag(@intCast(entries.len), data_words, ptr_words));
    const block = try b.allocWords(allocator, entries.len * stride);
    for (entries, 0..) |entry, i| {
        const loc = StructLoc{ .data_idx = block + i * stride, .data_words = data_words, .ptr_words = ptr_words };
        try setData(b, allocator, loc, 0, entry.name);
        switch (entry.value) {
            .string => |s| {
                b.set(loc.data_idx, @backingInt(shared.HintValueKind.string));
                try setData(b, allocator, loc, 1, s);
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

fn encodeError(b: *wire.Builder, allocator: std.mem.Allocator, err: model.BreakReason) EncodeError!StructLoc {
    const loc = try allocStruct(b, allocator, 0, 1);
    try setData(b, allocator, loc, 0, err.message);
    return loc;
}

fn encodeTagged(b: *wire.Builder, allocator: std.mem.Allocator, tagged: model.Tagged) EncodeError!StructLoc {
    const loc = try allocStruct(b, allocator, 0, 2);
    try setData(b, allocator, loc, 0, tagged.tag);
    try setListPtr(b, ptrIndex(loc, 1), try encodeArgumentList(b, allocator, tagged.value));
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
            b.set(loc.data_idx, @backingInt(ArgKind.bytes));
            try setData(b, allocator, loc, 0, bytes);
        },
        .symbol => |symbol| {
            b.set(loc.data_idx, @backingInt(ArgKind.symbol));
            try setData(b, allocator, loc, 0, symbol);
        },
        .reference => |reference| {
            b.set(loc.data_idx, @backingInt(ArgKind.reference));
            setStructPtr(b, ptrIndex(loc, 0), try encodeReference(b, allocator, reference));
        },
        .@"error" => |err| {
            b.set(loc.data_idx, @backingInt(ArgKind.@"error"));
            setStructPtr(b, ptrIndex(loc, 0), try encodeError(b, allocator, err));
        },
        .handoff => |handoff| {
            b.set(loc.data_idx, @backingInt(ArgKind.handoff));
            setStructPtr(b, ptrIndex(loc, 0), try encodeHandoff(b, allocator, handoff.*));
        },
        .string => |string| {
            b.set(loc.data_idx, @backingInt(ArgKind.string));
            try setData(b, allocator, loc, 0, string);
        },
        .integer => |integer| {
            b.set(loc.data_idx, @backingInt(ArgKind.integer));
            b.set(loc.data_idx + 1, @bitCast(integer));
        },
        .boolean => |boolean| {
            b.set(loc.data_idx, @backingInt(ArgKind.boolean) | (if (boolean) shared.data0_flag else 0));
        },
        .big_integer => |big| {
            // Symmetric refusal (ADR-0003): a non-canonical big integer —
            // leading zeros, non-digits, or a magnitude that belongs to the
            // `integer` arm — never reaches the wire.
            if (!big.isCanonical()) return Error.UnsupportedArgument;
            b.set(loc.data_idx, @backingInt(ArgKind.big_integer) | (if (big.negative) shared.data0_flag else 0));
            try setData(b, allocator, loc, 0, big.digits);
        },
        .list => |list| {
            b.set(loc.data_idx, @backingInt(ArgKind.list));
            try setListPtr(b, ptrIndex(loc, 0), try encodeArgumentList(b, allocator, list));
        },
        .void => b.set(loc.data_idx, @backingInt(ArgKind.void)),
        .float64 => |float64| {
            b.set(loc.data_idx, @backingInt(ArgKind.float64));
            b.set(loc.data_idx + 1, @bitCast(float64));
        },
        .set => |set| {
            b.set(loc.data_idx, @backingInt(ArgKind.set));
            try setListPtr(b, ptrIndex(loc, 0), try encodeArgumentSetList(b, allocator, set));
        },
        .tagged => |tagged| {
            b.set(loc.data_idx, @backingInt(ArgKind.tagged));
            setStructPtr(b, ptrIndex(loc, 0), try encodeTagged(b, allocator, tagged));
        },
        .keyword => |keyword| {
            b.set(loc.data_idx, @backingInt(ArgKind.keyword));
            try setData(b, allocator, loc, 0, keyword);
        },
        .@"struct" => |entries| {
            b.set(loc.data_idx, @backingInt(ArgKind.@"struct"));
            try setListPtr(b, ptrIndex(loc, 0), try encodeStructEntries(b, allocator, entries));
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

/// Return a struct's entries in canonical key order. The caller owns and frees
/// the returned slice (the entries' bytes stay borrowed from the model).
///
/// Symmetric refusal (ADR-0003): the decoder rejects a struct whose keys are not
/// strictly ascending as `MalformedFrame`, which a duplicate key violates, so an
/// encoder that emitted one would ship a frame glowcap and a Goblins peer both
/// reject remotely. A duplicate key is refused here with `UnsupportedArgument`,
/// the same shape the big-integer arm uses, rather than shipped. Keys are
/// adjacent after the sort, so one linear pass finds any repeat.
fn canonicalStructOrder(allocator: std.mem.Allocator, entries: []const model.StructEntry) EncodeError![]model.StructEntry {
    return codec_order.orderedCopyByKey(
        model.StructEntry,
        EncodeError,
        allocator,
        entries,
        struct {
            fn key(entry: model.StructEntry) []const u8 {
                return entry.key;
            }
        }.key,
        true,
    );
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

const EncodedSetElement = struct {
    /// The element's standalone message bytes, the canonical sort key. It is a
    /// copying snapshot because `builder` stays live afterward, holding the
    /// encoded struct the graft reads directly.
    key_frame: foundation.Frame,
    builder: wire.Builder,
    loc: StructLoc,
};

fn deinitEncodedSetElements(allocator: std.mem.Allocator, encoded: []EncodedSetElement) void {
    for (encoded) |*enc| {
        enc.key_frame.deinit();
        enc.builder.deinit(allocator);
    }
}

/// Composite list of `Argument` in canonical set order. Each element is encoded
/// once into a scratch builder; the standalone message bytes are the sort key,
/// then the encoded subgraph is grafted into the list slot without a second
/// model walk (the Syrup codec's encode-once / append-sorted shape).
fn encodeArgumentSetList(b: *wire.Builder, allocator: std.mem.Allocator, args: []const model.Argument) EncodeError!ListContent {
    const data_words: u16 = 2;
    const ptr_words: u16 = 1;
    const stride: usize = data_words + ptr_words;
    if (args.len < 2) return encodeArgumentList(b, allocator, args);

    const encoded = try allocator.alloc(EncodedSetElement, args.len);
    defer allocator.free(encoded);
    var built: usize = 0;
    // One cleanup for success and error — never pair errdefer + defer on the
    // same `built` slice (UnsupportedArgument would double-free).
    defer deinitEncodedSetElements(allocator, encoded[0..built]);

    for (args) |arg| {
        var tb = try wire.Builder.init(allocator);
        errdefer tb.deinit(allocator);
        const root_idx = try tb.allocWords(allocator, 1);
        const loc = try encodeArgument(&tb, allocator, arg);
        setStructPtr(&tb, root_idx, loc);
        // The builder must stay live for the graft below, so this is the one
        // named copying finish. Its frame is itself the sort key, so those
        // bytes are never copied a second time.
        const frame = try tb.finishCopying(allocator);
        encoded[built] = .{
            .key_frame = frame,
            .builder = tb,
            .loc = loc,
        };
        tb = undefined;
        built += 1;
    }

    const order = try allocator.alloc(usize, args.len);
    defer allocator.free(order);
    for (order, 0..) |*o, i| o.* = i;
    const keys = try allocator.alloc([]const u8, args.len);
    defer allocator.free(keys);
    for (encoded[0..built], 0..) |enc, i| keys[i] = enc.key_frame.bytes();
    // Symmetric refusal (ADR-0003): a set's elements are unique, so a duplicate
    // element (equal canonical key, adjacent after the sort) is refused here
    // rather than emitted, matching the Syrup codec and the duplicate-key struct.
    try codec_order.sortIndicesByKeys(EncodeError, order, keys, true);

    const tag_idx = try b.allocWords(allocator, 1);
    b.set(tag_idx, wire.Builder.compositeTag(@intCast(args.len), data_words, ptr_words));
    const block = try b.allocWords(allocator, args.len * stride);
    for (order, 0..) |src, i| {
        const enc = encoded[src];
        const copy_start: usize = wire.Builder.frame_header_words + 1;
        const src_tail = enc.builder.words.items[copy_start..];
        const base = try b.allocWords(allocator, src_tail.len);
        for (src_tail, 0..) |word, j| b.set(base + j, word);
        const struct_main = base + enc.loc.data_idx - copy_start;
        const list_slot = block + i * stride;
        installArgumentSlot(b, struct_main, enc.loc, list_slot);
    }
    return .{ .data_idx = tag_idx, .elem = .composite, .count = args.len * stride };
}

/// Copy an encoded Argument struct from `src_struct_idx` into composite-list
/// slot `dst_struct_idx`, adjusting pointer offsets for the relocation.
fn installArgumentSlot(
    b: *wire.Builder,
    src_struct_idx: usize,
    loc: StructLoc,
    dst_struct_idx: usize,
) void {
    const delta = @as(i32, @intCast(src_struct_idx)) - @as(i32, @intCast(dst_struct_idx));
    const words = b.words.items;
    for (0..loc.data_words) |d| {
        b.set(dst_struct_idx + d, words[src_struct_idx + d]);
    }
    for (0..loc.ptr_words) |p| {
        const src_ptr = src_struct_idx + loc.data_words + p;
        const dst_ptr = dst_struct_idx + loc.data_words + p;
        b.set(dst_ptr, relocatePointerOffset(words[src_ptr], delta));
    }
}

fn relocatePointerOffset(word: u64, delta: i32) u64 {
    // A null pointer word (0) names no target, so it never relocates. Grafting a
    // scalar Argument arm (`.integer`, `.boolean`, `.void`, `.float64`) copies
    // its single pointer word, which the scalar left null; without this guard the
    // struct-kind branch would turn that 0 into `encodeStructPointer(delta, 0, 0)`
    // — a spurious non-null pointer where canonical wire form requires 0.
    if (word == 0) return 0;
    return switch (wire.pointerKind(word)) {
        .@"struct" => blk: {
            const sp = wire.decodeStructPointer(word);
            break :blk wire.encodeStructPointer(sp.offset + delta, sp.data_words, sp.ptr_words);
        },
        .list => blk: {
            const lp = wire.decodeListPointer(word);
            break :blk wire.encodeListPointer(lp.offset + delta, lp.elem, lp.count);
        },
        else => word,
    };
}
