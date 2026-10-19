//! Cap'n Proto argument tree for the encoder: the 2-data / 1-pointer
//! `Argument` struct, composite lists, the integer word run, canonical set and
//! struct ordering, and the graft that installs a pre-encoded set element.
//! Every writer takes either source (`*const model.Argument` or
//! `*const view.Argument`), and the elements of a list, set, tagged value, or
//! struct are walked where they stand (`view.sequenceOf`): an owned slice is
//! a slice walk, and a borrowed sequence lends each element through
//! `nextRef`, so the owned walk pays no per-element projection. A borrowed
//! sequence an owner built from its own slice (`ownedSlice`) walks that slice
//! directly.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const codec_order = @import("codec_order");
const layout = @import("encode_layout.zig");
const records = @import("encode_records.zig");
const shared = @import("shared.zig");
const wire = shared.wire;
const view = model.view;

const Error = shared.Error;
const EncodeError = shared.EncodeError;
const ArgKind = shared.ArgKind;
const StructLoc = shared.StructLoc;
const ListContent = layout.ListContent;
const allocStruct = layout.allocStruct;
const allocComposite = layout.allocComposite;
const ptrIndex = layout.ptrIndex;
const setStructPtr = layout.setStructPtr;
const setListPtr = layout.setListPtr;
const setData = layout.setData;
const setText = records.setText;

const argument_data_words: u16 = 2;
const argument_ptr_words: u16 = 1;
const argument_stride: usize = argument_data_words + argument_ptr_words;

pub fn encodeArgument(b: *wire.Builder, allocator: std.mem.Allocator, arg: anytype) EncodeError!StructLoc {
    const loc = try allocStruct(b, allocator, argument_data_words, argument_ptr_words);
    try encodeArgumentInto(b, allocator, arg, loc);
    return loc;
}

/// Fill an already-allocated 2-data / 1-pointer Argument struct at `loc`. Used
/// both standalone and for composite-list elements.
fn encodeArgumentInto(b: *wire.Builder, allocator: std.mem.Allocator, arg: anytype, loc: StructLoc) EncodeError!void {
    switch (arg.*) {
        .bytes => |bytes| {
            b.set(loc.data_idx, @backingInt(ArgKind.bytes));
            try setData(b, allocator, loc, 0, bytes);
        },
        .symbol => |symbol| {
            b.set(loc.data_idx, @backingInt(ArgKind.symbol));
            try setText(b, allocator, loc, 0, symbol);
        },
        .reference => |reference| {
            b.set(loc.data_idx, @backingInt(ArgKind.reference));
            setStructPtr(b, ptrIndex(loc, 0), try records.encodeReference(b, allocator, reference));
        },
        .@"error" => |err| {
            b.set(loc.data_idx, @backingInt(ArgKind.@"error"));
            setStructPtr(b, ptrIndex(loc, 0), try records.encodeError(b, allocator, err.message));
        },
        .handoff => |handoff| {
            b.set(loc.data_idx, @backingInt(ArgKind.handoff));
            setStructPtr(b, ptrIndex(loc, 0), try records.encodeHandoff(b, allocator, try view.borrowHandoff(handoff)));
        },
        .string => |string| {
            b.set(loc.data_idx, @backingInt(ArgKind.string));
            try setText(b, allocator, loc, 0, string);
        },
        .integer => |integer| {
            b.set(loc.data_idx, @backingInt(ArgKind.integer));
            b.set(loc.data_idx + 1, @bitCast(integer));
        },
        .boolean => |boolean| {
            b.set(loc.data_idx, @backingInt(ArgKind.boolean) | (if (boolean) shared.data0_flag else 0));
        },
        .big_integer => |big| {
            // Symmetric refusal (ADR-0001): a non-canonical big integer,
            // leading zeros, non-digits, or a magnitude that belongs to the
            // `integer` arm, never reaches the wire.
            if (!big.isCanonical()) return Error.UnsupportedArgument;
            b.set(loc.data_idx, @backingInt(ArgKind.big_integer) | (if (big.negative) shared.data0_flag else 0));
            try setData(b, allocator, loc, 0, big.digits);
        },
        .list => |list| {
            b.set(loc.data_idx, @backingInt(ArgKind.list));
            const content = if (try isIntegerRun(list)) try encodeIntegerRun(b, allocator, list) else try encodeArgumentList(b, allocator, list);
            try setListPtr(b, ptrIndex(loc, 0), content);
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
            const tagged_loc = try allocStruct(b, allocator, 0, 2);
            try setText(b, allocator, tagged_loc, 0, tagged.tag);
            try setListPtr(b, ptrIndex(tagged_loc, 1), try encodeArgumentList(b, allocator, tagged.value));
            setStructPtr(b, ptrIndex(loc, 0), tagged_loc);
        },
        .keyword => |keyword| {
            b.set(loc.data_idx, @backingInt(ArgKind.keyword));
            try setText(b, allocator, loc, 0, keyword);
        },
        .@"struct" => |entries| {
            b.set(loc.data_idx, @backingInt(ArgKind.@"struct"));
            try setListPtr(b, ptrIndex(loc, 0), try encodeStructEntries(b, allocator, entries));
        },
    }
}

/// Collect into caller room, spilling to an owned slice only when needed,
/// and refuse a sequence whose walk and `len` disagree. The check stays live in every build mode because
/// the alternative is an out-of-bounds write.
fn collect(allocator: std.mem.Allocator, sequence: anytype, room: []@TypeOf(sequence).Elem) EncodeError![]@TypeOf(sequence).Elem {
    const count = try sequence.len();
    const items = if (count <= room.len) room[0..count] else try allocator.alloc(@TypeOf(sequence).Elem, count);
    errdefer if (count > room.len) allocator.free(items);
    var it = sequence.iterator();
    var filled: usize = 0;
    while (try it.nextRef()) |item| : (filled += 1) {
        if (filled == count) return error.MalformedView;
        items[filled] = item.*;
    }
    if (filled != count) return error.MalformedView;
    return items;
}

/// Composite list of struct entries: each element is a 0-data / 2-pointer struct
/// holding the String key text (pointer 0) and the value Argument struct
/// (pointer 1). Entries are emitted in canonical key order so the wire form does
/// not depend on the order the model held them in.
///
/// Symmetric refusal (ADR-0001): the decoder rejects a struct whose keys are not
/// strictly ascending as `MalformedFrame`, which a duplicate key violates, so an
/// encoder that emitted one would ship a frame glowcap and a Goblins peer both
/// reject remotely. A duplicate key is refused here with `UnsupportedArgument`,
/// the same shape the big-integer arm uses, rather than shipped. Keys are
/// adjacent after the sort, so one linear pass finds any repeat.
fn encodeStructEntries(b: *wire.Builder, allocator: std.mem.Allocator, entries: anytype) EncodeError!ListContent {
    if (comptime @TypeOf(entries) == view.StructEntries) {
        if (entries.ownedSlice()) |owned| return encodeStructEntries(b, allocator, owned);
    }
    const sequence = view.sequenceOf(entries);
    const Entry = @TypeOf(sequence).Elem;
    var room: [8]Entry = undefined;
    const ordered = try collect(allocator, sequence, &room);
    defer if (ordered.len > room.len) allocator.free(ordered);
    try codec_order.orderByKey(Entry, EncodeError, ordered, struct {
        fn key(entry: Entry) []const u8 {
            return entry.key;
        }
    }.key, true);
    const list = try allocComposite(b, allocator, ordered.len, 0, 2);
    for (ordered, 0..) |*entry, i| {
        const loc = list.elem(i);
        try setText(b, allocator, loc, 0, entry.key);
        setStructPtr(b, ptrIndex(loc, 1), try encodeArgument(b, allocator, &entry.value));
    }
    return list.content();
}

/// Whether a list takes the word-run form (ADR-0010): at least one element,
/// every one an integer. The decoder reads such a run in place, and the
/// empty list keeps its composite form so each value has one encoding. A
/// decoded run is one by construction.
fn isIntegerRun(items: anytype) EncodeError!bool {
    if (comptime @TypeOf(items) == view.Args) {
        if (items.wordRun()) |run| return run.len != 0;
        if (items.ownedSlice()) |owned| return isIntegerRun(owned);
    }
    const sequence = view.sequenceOf(items);
    if ((try sequence.len()) == 0) return false;
    var it = sequence.iterator();
    while (try it.nextRef()) |arg| if (arg.* != .integer) return false;
    return true;
}

/// `List(Int64)`: one little-endian word per element and no tag word. A
/// decoded run copies its words, and any other source walks its elements.
fn encodeIntegerRun(b: *wire.Builder, allocator: std.mem.Allocator, items: anytype) EncodeError!ListContent {
    if (comptime @TypeOf(items) == view.Args) {
        if (items.wordRun()) |run| {
            const count = run.len / wire.word_bytes;
            const start = try b.allocWords(allocator, count);
            b.setBytes(start, run);
            return .{ .data_idx = start, .elem = .eight_bytes, .count = count };
        }
        if (items.ownedSlice()) |owned| return encodeIntegerRun(b, allocator, owned);
    }
    const sequence = view.sequenceOf(items);
    const count = try sequence.len();
    const start = try b.allocWords(allocator, count);
    var it = sequence.iterator();
    var filled: usize = 0;
    while (try it.nextRef()) |arg| : (filled += 1) {
        if (filled == count) return error.MalformedView;
        b.set(start + filled, @bitCast(arg.integer));
    }
    if (filled != count) return error.MalformedView;
    return .{ .data_idx = start, .elem = .eight_bytes, .count = count };
}

/// Composite list of `Argument` (2 data words, 1 pointer word per element),
/// reserved as one run of words with its tag.
pub fn encodeArgumentList(b: *wire.Builder, allocator: std.mem.Allocator, items: anytype) EncodeError!ListContent {
    if (comptime @TypeOf(items) == view.Args) {
        if (items.ownedSlice()) |owned| return encodeArgumentList(b, allocator, owned);
    }
    const sequence = view.sequenceOf(items);
    const count = try sequence.len();
    const list = try allocComposite(b, allocator, count, argument_data_words, argument_ptr_words);
    var it = sequence.iterator();
    var filled: usize = 0;
    while (try it.nextRef()) |arg| : (filled += 1) {
        if (filled == count) return error.MalformedView;
        try encodeArgumentInto(b, allocator, arg, list.elem(filled));
    }
    if (filled != count) return error.MalformedView;
    return list.content();
}

const EncodedSetElement = struct {
    /// The element's standalone message bytes, the canonical sort key. It is a
    /// copying snapshot because `builder` stays live afterward, holding the
    /// encoded struct the graft reads directly.
    key_frame: foundation.Frame,
    builder: wire.Builder,
    loc: StructLoc,

    fn key(self: EncodedSetElement) []const u8 {
        return self.key_frame.bytes();
    }
};

fn deinitEncodedSetElements(allocator: std.mem.Allocator, encoded: []EncodedSetElement) void {
    for (encoded) |*enc| {
        enc.key_frame.deinit();
        enc.builder.deinit(allocator);
    }
}

/// Composite list of `Argument` in canonical set order. Each element is encoded
/// once into a scratch builder. The standalone message bytes are the sort key,
/// then the encoded subgraph is grafted into the list slot without a second
/// model walk (the Syrup codec's encode-once / append-sorted shape).
fn encodeArgumentSetList(b: *wire.Builder, allocator: std.mem.Allocator, items: anytype) EncodeError!ListContent {
    if (comptime @TypeOf(items) == view.Args) {
        if (items.ownedSlice()) |owned| return encodeArgumentSetList(b, allocator, owned);
    }
    const sequence = view.sequenceOf(items);
    const count = try sequence.len();
    if (count < 2) return encodeArgumentList(b, allocator, sequence);

    const encoded = try allocator.alloc(EncodedSetElement, count);
    defer allocator.free(encoded);
    var built: usize = 0;
    // One cleanup for success and error, never pair errdefer + defer on the
    // same `built` slice (UnsupportedArgument would double-free).
    defer deinitEncodedSetElements(allocator, encoded[0..built]);

    var it = sequence.iterator();
    while (try it.nextRef()) |arg| {
        if (built == count) return error.MalformedView;
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
    if (built != count) return error.MalformedView;

    // Symmetric refusal (ADR-0001): a set's elements are unique, so a duplicate
    // element (equal canonical key, adjacent after the sort) is refused here
    // rather than emitted, matching the Syrup codec and the duplicate-key struct.
    try codec_order.orderByKey(EncodedSetElement, EncodeError, encoded, EncodedSetElement.key, true);

    const list = try allocComposite(b, allocator, count, argument_data_words, argument_ptr_words);
    for (encoded, 0..) |enc, i| {
        const copy_start: usize = wire.Builder.frame_header_words + 1;
        const src_tail = enc.builder.words.items[copy_start..];
        const base = try b.allocWords(allocator, src_tail.len);
        for (src_tail, 0..) |word, j| b.set(base + j, word);
        const struct_main = base + enc.loc.data_idx - copy_start;
        installArgumentSlot(b, struct_main, enc.loc, list.elem(i).data_idx);
    }
    return list.content();
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
    // (a spurious non-null pointer where canonical wire form requires 0).
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
