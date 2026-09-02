//! Shared Cap'n Proto layout vocabulary for the hand-rolled codec.
//!
//! This module owns only wire-layout discriminants and bounds-checked borrowed
//! reader helpers. Decode, owned materialization, and encode import it rather
//! than depending on each other.

const std = @import("std");

const model = @import("model");

pub const wire = @import("wire.zig");

/// The structural decode error set. The borrowed decode path never allocates,
/// so this set carries no allocator error; encode, which does allocate, uses
/// `EncodeError` — the same Error/WalkError split the Syrup codec makes.
pub const Error = error{
    InvalidFrameShape,
    Truncated,
    InvalidPointer,
    UnsupportedSegmentCount,
    MalformedFrame,
    UnsupportedMessage,
    UnsupportedArgument,
    UnsupportedReference,
};

/// The encode-side error set: the structural refusals plus the allocator
/// failure the builder can hit while it grows the segment.
pub const EncodeError = Error || std.mem.Allocator.Error;

/// Union discriminant for the `model.Message` body. The explicit values are the
/// Cap'n Proto wire ids and must stay stable; the comptime mirror below binds
/// the *set* to `model.Message` so a new arm cannot land without a wire id,
/// while leaving the id itself an explicit wire-contract choice.
pub const Kind = enum(u16) {
    deliver = 0,
    resolve = 1,
    gc_export = 2,
    gc_answer = 3,
    start_session = 5,
    abort = 6,
    listen = 7,
    get = 8,
    index = 9,
    untag = 10,
};

comptime {
    model.assertMirrorsMessageKinds(Kind);
}

pub const RefTag = enum(u16) { near = 0, far = 1, promise = 2, sturdy = 3 };
pub const ArgKind = enum(u16) {
    bytes = 0,
    symbol = 1,
    reference = 2,
    @"error" = 3,
    handoff = 4,
    string = 5,
    integer = 6,
    boolean = 7,
    list = 8,
    void = 9,
    float64 = 10,
    set = 11,
    tagged = 12,
    keyword = 13,
    @"struct" = 14,
    /// Sign in data word 0 bit 16 (the boolean arm's bit), canonical decimal
    /// magnitude digits as the pointer-0 data field.
    big_integer = 15,
};

comptime {
    // The one capnp kind registry bound to its model union by set, not order:
    // the wire discriminants above (`@"struct"` = 14, `big_integer` = 15) are an
    // external contract that diverges from `model.Argument`'s declaration order,
    // so a new `Argument` arm that lands without an `ArgKind` (or the reverse)
    // is a compile error here, the same drift guard `Kind` holds over `Message`.
    model.assertKindSetMatches(model.Argument, ArgKind);
}

/// Bit 16 of data word 0 carries the promise flag for a RefTag, the value for
/// a boolean ArgKind, and the sign for a BigInteger.
pub const data0_flag: u64 = 1 << 16;
/// Deliver data word 0 flag bits.
pub const deliver_has_answer: u64 = 1;
pub const deliver_has_resolve_me: u64 = 2;
/// `op:index` data word 2 flags. Old compact-index frames omit this word and
/// therefore read as zero.
pub const index_big_integer: u64 = 1;
pub const index_negative: u64 = 2;

pub const ResolutionKind = enum(u16) { fulfill = 0, @"break" = 1 };
pub const HandoffKind = enum(u16) { give = 0, receive = 1 };

/// A `model.HintValue` entry's discriminant, carried in a hint-entry element's
/// data word 0 (bit 16 doubles as the boolean value, mirroring `ArgKind`'s
/// boolean/big-integer bit reuse).
pub const HintValueKind = enum(u16) { string = 0, bytes = 1, boolean = 2, integer = 3 };

comptime {
    model.assertKindSetMatches(model.HintValue, HintValueKind);
}

/// A struct's location: the segment index of its data section plus its section
/// sizes. The pointer section begins at `data_idx + data_words`.
pub const StructLoc = struct {
    data_idx: usize,
    data_words: u16,
    ptr_words: u16,
};

/// Parse and ratify a frame's segment header, returning the bounds-checked
/// `Reader` over it. This is the one checked constructor every decode entry
/// point goes through: it refuses a short header (`Truncated`), a multi-segment
/// frame (`UnsupportedSegmentCount`), a segment count whose length math
/// overflows `usize` on a 32-bit target (`Truncated`, checked add/mul), and a
/// buffer shorter than the `(seg_words + 1) * 8` bytes the header declares
/// (`Truncated`), so no caller can build a `Reader` whose declared segment
/// extends past the bytes it borrows.
pub fn readerFromFrame(bytes: []const u8) Error!Reader {
    if (bytes.len < wire.WORD_BYTES) return Error.Truncated;
    const header = std.mem.readInt(u64, bytes[0..wire.WORD_BYTES], .little);
    if (@as(u32, @truncate(header)) != 0) return Error.UnsupportedSegmentCount;
    const seg_words: usize = @intCast(header >> 32);
    const frame_words = std.math.add(usize, seg_words, 1) catch return Error.Truncated;
    const frame_len = std.math.mul(usize, frame_words, wire.WORD_BYTES) catch return Error.Truncated;
    if (bytes.len < frame_len) return Error.Truncated;
    return .{ .bytes = bytes, .seg_words = seg_words };
}

/// Refuse bytes past the length a frame's own header declares.
///
/// `readerFromFrame` is deliberately lenient about this: the framing layer
/// hands it a buffer that may hold several frames back to back and expects it
/// to read the first. A caller that has already been given one delimited frame
/// wants the strict rule, and calls this.
pub fn expectExactFrameLength(bytes: []const u8) Error!void {
    if (bytes.len < wire.WORD_BYTES) return Error.Truncated;
    const header = std.mem.readInt(u64, bytes[0..wire.WORD_BYTES], .little);
    const seg_words: usize = @intCast(header >> 32);
    const frame_words = std.math.add(usize, seg_words, 1) catch return Error.Truncated;
    const frame_len = std.math.mul(usize, frame_words, wire.WORD_BYTES) catch return Error.Truncated;
    if (bytes.len != frame_len) return Error.MalformedFrame;
}

/// Words a legitimate frame is allowed to (re-)read per segment word before the
/// per-frame traversal budget refuses it. A well-formed frame is a *tree*: the
/// segment words partition into node data/pointer sections and list bodies, and
/// the decode walk visits each node once, so it reads each segment word a small
/// constant number of times (locate + discriminant + payload). 32× that count
/// leaves generous headroom for a tree while an aliasing DAG — composite-list
/// pointers that resolve to a shared child re-read the same words K^D times —
/// exhausts it within a few thousand node visits for a 2 KB frame. This is the
/// glowcap sibling of Cap'n Proto's `traversalLimitInWords`; the tighter,
/// per-frame bound is chosen over a fixed cap because a real frame's read count
/// scales with its own size, not the deployment's `max_frame_bytes`.
pub const traversal_budget_words_per_segment_word: usize = 32;

/// Floor for a tiny frame, so a handful-of-words message keeps ample headroom
/// even though `32 × seg_words` would be small.
pub const traversal_budget_floor_words: usize = 512;

/// Seed a per-frame word-traversal budget from a frame's segment word count.
/// Threaded (by pointer) onto every `Reader` copy the eager charge walk makes
/// and spent in `word`/`byteSlice` and per composite element resolved, this is
/// the single counter every re-resolution of the same words shares, so aliasing
/// cannot dodge it.
pub fn traversalBudget(seg_words: usize) usize {
    const scaled = std.math.mul(usize, seg_words + 1, traversal_budget_words_per_segment_word) catch
        return std.math.maxInt(usize);
    return @max(scaled, traversal_budget_floor_words);
}

/// Bounds-checked, segment-relative word reader over a framed message. Segment
/// index `i` is frame word `i + 1` (frame word 0 is the segment table). Holds
/// only a borrow of the frame bytes, copying nothing. Construct through
/// `readerFromFrame`, which validates the segment header first.
pub const Reader = struct {
    bytes: []const u8,
    seg_words: usize,
    /// Optional per-frame traversal budget, shared by every copy of this reader
    /// (it is a pointer). Null means unmetered: the header-locate reads and the
    /// lazy re-walks run without a counter, because the eager `decode` pass has
    /// already proven the whole tree fits the budget. `word`/`byteSlice` spend
    /// it when it is set, so the metered eager walk that follows aliasing edges
    /// burns one shared counter and refuses a DAG in bounded time.
    budget: ?*usize = null,

    /// Return a copy of this reader metered against `budget`. The copy shares
    /// the counter with the original through the pointer, so any further copies
    /// made while walking spend the same budget.
    pub fn withBudget(self: Reader, budget: *usize) Reader {
        var copy = self;
        copy.budget = budget;
        return copy;
    }

    /// Spend `words` from the traversal budget, if one is attached. Returns
    /// `MalformedFrame` when the budget cannot cover the read: a glowcap frame
    /// is a tree, so a walk that outruns a size-derived budget is reading an
    /// aliasing DAG glowcap never emits — a structural refusal, the same
    /// verdict `InvalidPointer`/`Truncated` carry (a distinct codec error would
    /// fall through `engine.abort_projection.classify` to `.foreign`; the
    /// tree-shape refusal is honestly `malformed_frame`).
    pub fn spend(self: Reader, words: usize) Error!void {
        const budget = self.budget orelse return;
        if (budget.* < words) {
            budget.* = 0;
            return Error.MalformedFrame;
        }
        budget.* -= words;
    }

    pub fn word(self: Reader, seg_idx: usize) Error!u64 {
        if (seg_idx >= self.seg_words) return Error.Truncated;
        try self.spend(1);
        return std.mem.readInt(u64, self.bytes[(seg_idx + 1) * wire.WORD_BYTES ..][0..wire.WORD_BYTES], .little);
    }

    /// Resolve a pointer at segment index `ptr_idx` with signed `offset`. Empty
    /// aggregates legitimately point one word past the segment end, so this
    /// rejects only indices strictly past it; each real read is checked by `word`.
    pub fn target(self: Reader, ptr_idx: usize, offset: i32) Error!usize {
        const resolved = @as(i64, @intCast(ptr_idx)) + 1 + offset;
        if (resolved < 0) return Error.InvalidPointer;
        const idx: usize = @intCast(resolved);
        if (idx > self.seg_words) return Error.Truncated;
        return idx;
    }

    /// Borrowed byte slice of `len` bytes starting at segment word `seg_idx`.
    /// Points directly into the frame; copies nothing.
    pub fn byteSlice(self: Reader, seg_idx: usize, len: usize) Error![]const u8 {
        if (len == 0) return &.{};
        // `seg_idx` and `len` both derive from an attacker-controlled list
        // pointer, so add them checked: on a 32-bit target the sum could
        // otherwise wrap below `seg_words` and pass a bound meant to reject it.
        // This matches the checked arithmetic in `readerFromFrame` and
        // `compositeList`.
        const span = wire.wordsForBytes(len);
        const end = std.math.add(usize, seg_idx, span) catch return Error.Truncated;
        if (end > self.seg_words) return Error.Truncated;
        try self.spend(span);
        return self.bytes[(seg_idx + 1) * wire.WORD_BYTES ..][0..len];
    }

    /// Data word `i` of a struct, defaulting to 0 past the struct's data section
    /// (Cap'n Proto reads beyond the section as zero).
    pub fn dataWord(self: Reader, loc: StructLoc, i: u16) Error!u64 {
        if (i >= loc.data_words) return 0;
        return self.word(loc.data_idx + i);
    }

    fn ptrWordRaw(self: Reader, loc: StructLoc, i: u16) Error!u64 {
        if (i >= loc.ptr_words) return 0;
        return self.word(loc.data_idx + loc.data_words + i);
    }

    /// Whether pointer field `i` is absent. Used when a larger replacement
    /// layout must reject data in a field the selected compact arm does not own.
    pub fn pointerIsNull(self: Reader, loc: StructLoc, i: u16) Error!bool {
        return try self.ptrWordRaw(loc, i) == 0;
    }

    /// Follow pointer field `i` to a struct, or null if the slot is a null
    /// pointer (absent optional / past the pointer section).
    pub fn followStruct(self: Reader, loc: StructLoc, i: u16) Error!?StructLoc {
        const w = try self.ptrWordRaw(loc, i);
        if (w == 0) return null;
        if (wire.pointerKind(w) != .@"struct") return Error.InvalidPointer;
        const sp = wire.decodeStructPointer(w);
        const ptr_idx = loc.data_idx + loc.data_words + i;
        return .{ .data_idx = try self.target(ptr_idx, sp.offset), .data_words = sp.data_words, .ptr_words = sp.ptr_words };
    }
};

pub const ListLoc = struct { data_idx: usize, count: usize, elem: wire.ElementSize };

/// Follow pointer field `i` to a list. A null pointer reads as an empty list.
pub fn followList(reader: Reader, loc: StructLoc, i: u16) Error!ListLoc {
    const w = try reader.ptrWordRaw(loc, i);
    if (w == 0) return .{ .data_idx = 0, .count = 0, .elem = .void };
    if (wire.pointerKind(w) != .list) return Error.InvalidPointer;
    const lp = wire.decodeListPointer(w);
    const ptr_idx = loc.data_idx + loc.data_words + i;
    return .{ .data_idx = try reader.target(ptr_idx, lp.offset), .count = lp.count, .elem = lp.elem };
}

/// Map an untrusted wire discriminant to its enum, rejecting an out-of-range
/// value as a malformed frame instead of reaching `@enumFromInt`'s illegal
/// behavior (a panic in a safe build, undefined behavior otherwise).
pub fn enumFromWire(comptime E: type, raw: u64) Error!E {
    // The discriminant occupies the low sixteen bits and `data0_flag` sits
    // directly above it, so bit 16 is dropped on purpose. Nothing writes any
    // bit above that, and silently ignoring them would let two different words
    // spell the same message.
    if (raw >> 17 != 0) return Error.MalformedFrame;
    const value: u16 = @truncate(raw);
    inline for (@typeInfo(E).@"enum".field_values) |field_value| {
        if (value == field_value) return @fromBackingInt(@intCast(value));
    }
    return Error.MalformedFrame;
}

/// A bounds-validated composite (struct) list. A composite list pointer's word
/// count and the per-element sizes in its tag word are attacker-controlled, so
/// before a caller allocates `element_count` rows or stride-walks the elements
/// this proves the tag is consistent with the words the list pointer reserved.
pub const CompositeList = struct {
    /// Segment index of the list's tag word; element `n`'s data section begins
    /// at `tag_idx + 1 + n * stride`.
    tag_idx: usize,
    element_count: usize,
    data_words: u16,
    ptr_words: u16,

    pub fn elem(self: CompositeList, index: usize) StructLoc {
        const stride = @as(usize, self.data_words) + self.ptr_words;
        return .{
            .data_idx = self.tag_idx + 1 + index * stride,
            .data_words = self.data_words,
            .ptr_words = self.ptr_words,
        };
    }
};

/// Decode and bounds-validate composite list field `i`, or null for an
/// absent/empty list. See `CompositeList` for the invariants proven here.
pub fn compositeList(reader: Reader, loc: StructLoc, i: u16) Error!?CompositeList {
    const list = try followList(reader, loc, i);
    if (list.count == 0) return null;
    if (list.elem != .composite) return Error.InvalidPointer;
    if (list.data_idx >= reader.seg_words) return Error.Truncated;
    const tag_word = try reader.word(list.data_idx);
    // The tag is a struct-pointer-shaped word and its kind bits must say so:
    // `decodeCompositeTag` reads only the field bits, so accepting a stray
    // kind here would let two different words spell the same list.
    if (wire.pointerKind(tag_word) != .@"struct") return Error.InvalidPointer;
    const tag = wire.decodeCompositeTag(tag_word);
    const stride = @as(usize, tag.data_words) + tag.ptr_words;
    if (stride == 0) return Error.MalformedFrame;
    const body = std.math.mul(usize, tag.element_count, stride) catch return Error.MalformedFrame;
    if (body != list.count) return Error.MalformedFrame;
    const end = std.math.add(usize, list.data_idx + 1, list.count) catch return Error.Truncated;
    if (end > reader.seg_words) return Error.Truncated;
    return .{
        .tag_idx = list.data_idx,
        .element_count = tag.element_count,
        .data_words = tag.data_words,
        .ptr_words = tag.ptr_words,
    };
}
