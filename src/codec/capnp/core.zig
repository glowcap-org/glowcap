//! The Cap'n Proto codec, hand-rolled for the pancake-to-pancake wire.
//!
//! Cap'n Proto is the word-aligned alternative to Syrup. It carries the same
//! `model.Message` tree, just laid out as a run of 8-byte words instead of
//! Syrup's byte records. There's no schema compiler in the loop: we write the
//! struct and list layout directly against the wire primitives in `wire.zig`
//! (ADR-0026), so the codec stands on its own and the layout tracks the model.
//!
//! Decode reads before it copies. `decodeView` lays a borrowed `MessageView` over
//! the frame without copying anything, and `decodeOwned` is just that followed by
//! building the owned tree, which only happens when you ask for it.
//!
//! References flip perspective every time they cross the wire (ADR-0010), the
//! same way Syrup does. Something we export goes out as a `near`, and the partner
//! reads it back as a `far` import; the reverse happens too. The flip is a fixed
//! relabel of the wire arm. It never consults a table, so the codec still holds
//! no authority.
//!
//! All ten `Message` arms encode and decode, along with everything they share:
//! `Reference`, `Argument` and its fourteen arms, `Resolution`, `Error`,
//! `PeerLocator`, `Handoff`, `Tagged`, and `PipelineOp`. The one holdout is
//! `BrokenRef`, which is local-only and gets rejected on encode with
//! `Error.UnsupportedReference`.
//!
//! [ADR-0026]: ../../../docs/decisions/adr/ADR-0026-hand-rolled-capnp-codec.md

const std = @import("std");

const foundation = @import("../../foundation/mod.zig");
const model = @import("../../model/mod.zig");
const framing = @import("../framing.zig");

pub const wire = @import("wire.zig");

pub const Error = error{
    InvalidFrameShape,
    Truncated,
    InvalidPointer,
    UnsupportedSegmentCount,
    MalformedFrame,
    UnsupportedMessage,
    UnsupportedArgument,
    UnsupportedReference,
} || std.mem.Allocator.Error;

/// Union discriminant for the [`Message`](model.Message) body.
pub const Kind = enum(u16) {
    deliver = 0,
    resolve = 1,
    gc_export = 2,
    gc_answer = 3,
    handoff = 4,
    start_session = 5,
    abort = 6,
    listen = 7,
    get = 8,
    index = 9,
};

const RefKind = enum(u16) { near = 0, far = 1, promise = 2, sturdy = 3 };
const ArgKind = enum(u16) {
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
};
const ResolutionKind = enum(u16) { fulfill = 0, break_ = 1 };
const PipelineOpKind = enum(u16) { field = 0, call = 1 };
const HandoffKind = enum(u16) { give = 0, receive = 1 };

// ── Decode: borrowed reader ──────────────────────────────────────────────────

/// A struct's location: the segment index of its data section plus its section
/// sizes. The pointer section begins at `data_idx + data_words`.
const StructLoc = struct {
    data_idx: usize,
    data_words: u16,
    ptr_words: u16,
};

/// Bounds-checked, segment-relative word reader over a framed message. Segment
/// index `i` is frame word `i + 1` (frame word 0 is the segment table). Holds
/// only a borrow of the frame bytes — copying nothing.
pub const Reader = struct {
    bytes: []const u8,
    seg_words: usize,

    fn word(self: Reader, seg_idx: usize) Error!u64 {
        if (seg_idx >= self.seg_words) return Error.Truncated;
        return std.mem.readInt(u64, self.bytes[(seg_idx + 1) * wire.WORD_BYTES ..][0..wire.WORD_BYTES], .little);
    }

    /// Resolve a pointer at segment index `ptr_idx` with signed `offset`. Empty
    /// aggregates legitimately point one word past the segment end, so this
    /// rejects only indices strictly past it; each real read is checked by `word`.
    fn target(self: Reader, ptr_idx: usize, offset: i32) Error!usize {
        const resolved = @as(i64, @intCast(ptr_idx)) + 1 + offset;
        if (resolved < 0) return Error.InvalidPointer;
        const idx: usize = @intCast(resolved);
        if (idx > self.seg_words) return Error.Truncated;
        return idx;
    }

    /// Borrowed byte slice of `len` bytes starting at segment word `seg_idx`.
    /// Points directly into the frame; copies nothing.
    fn byteSlice(self: Reader, seg_idx: usize, len: usize) Error![]const u8 {
        if (len == 0) return &.{};
        // `seg_idx` and `len` both derive from an attacker-controlled list
        // pointer, so add them checked: on a 32-bit target the sum could
        // otherwise wrap below `seg_words` and pass a bound meant to reject it.
        // This matches the checked arithmetic in `decodeView` and `compositeList`.
        const end = std.math.add(usize, seg_idx, wire.wordsForBytes(len)) catch return Error.Truncated;
        if (end > self.seg_words) return Error.Truncated;
        return self.bytes[(seg_idx + 1) * wire.WORD_BYTES ..][0..len];
    }

    /// Data word `i` of a struct, defaulting to 0 past the struct's data section
    /// (Cap'n Proto reads beyond the section as zero).
    fn dataWord(self: Reader, loc: StructLoc, i: u16) Error!u64 {
        if (i >= loc.data_words) return 0;
        return self.word(loc.data_idx + i);
    }

    fn ptrWordRaw(self: Reader, loc: StructLoc, i: u16) Error!u64 {
        if (i >= loc.ptr_words) return 0;
        return self.word(loc.data_idx + loc.data_words + i);
    }

    /// Follow pointer field `i` to a struct, or null if the slot is a null
    /// pointer (absent optional / past the pointer section).
    fn followStruct(self: Reader, loc: StructLoc, i: u16) Error!?StructLoc {
        const w = try self.ptrWordRaw(loc, i);
        if (w == 0) return null;
        if (wire.pointerKind(w) != .@"struct") return Error.InvalidPointer;
        const sp = wire.decodeStructPointer(w);
        const ptr_idx = loc.data_idx + loc.data_words + i;
        return .{ .data_idx = try self.target(ptr_idx, sp.offset), .data_words = sp.data_words, .ptr_words = sp.ptr_words };
    }
};

const ListLoc = struct { data_idx: usize, count: usize, elem: wire.ElementSize };

/// Follow pointer field `i` to a list. A null pointer reads as an empty list.
fn followList(reader: Reader, loc: StructLoc, i: u16) Error!ListLoc {
    const w = try reader.ptrWordRaw(loc, i);
    if (w == 0) return .{ .data_idx = 0, .count = 0, .elem = .void };
    if (wire.pointerKind(w) != .list) return Error.InvalidPointer;
    const lp = wire.decodeListPointer(w);
    const ptr_idx = loc.data_idx + loc.data_words + i;
    return .{ .data_idx = try reader.target(ptr_idx, lp.offset), .count = lp.count, .elem = lp.elem };
}

/// Map an untrusted wire discriminant to its enum, rejecting an out-of-range
/// value as a malformed frame instead of reaching `@enumFromInt`'s illegal
/// behavior (a panic in a safe build, undefined behavior otherwise). Every
/// union tag a partner controls — `RefKind`, `ArgKind`, `ResolutionKind`,
/// `HandoffKind`, `PipelineOpKind` — decodes through here, exactly as `Kind`
/// and `abortKindFromWire` already range-check their discriminants.
fn enumFromWire(comptime E: type, raw: u64) Error!E {
    const value: u16 = @truncate(raw);
    inline for (@typeInfo(E).@"enum".fields) |field| {
        if (value == field.value) return @enumFromInt(value);
    }
    return Error.MalformedFrame;
}

/// A bounds-validated composite (struct) list. A composite list pointer's word
/// count and the per-element sizes in its tag word are attacker-controlled, so
/// before a caller allocates `element_count` rows or stride-walks the elements
/// this proves the tag is consistent with the words the list pointer reserved
/// (`element_count * stride == count`) and that the tag word plus body fit the
/// segment. An inconsistent tag — one claiming more elements than the list has
/// room for — would otherwise amplify a few wire bytes into an oversized
/// allocation the per-element reads could never fill. pancake's own dialect
/// never emits a zero-width composite element (ADR-0026), so a zero stride is
/// rejected rather than admitting an unbounded element count over no words.
const CompositeList = struct {
    /// Segment index of the list's tag word; element `n`'s data section begins
    /// at `tag_idx + 1 + n * stride`.
    tag_idx: usize,
    element_count: usize,
    data_words: u16,
    ptr_words: u16,

    fn elem(self: CompositeList, index: usize) StructLoc {
        const stride = @as(usize, self.data_words) + self.ptr_words;
        return .{
            .data_idx = self.tag_idx + 1 + index * stride,
            .data_words = self.data_words,
            .ptr_words = self.ptr_words,
        };
    }
};

/// Decode and bounds-validate composite list field `i`, or null for an
/// absent/empty list. See [`CompositeList`] for the invariants proven here.
fn compositeList(reader: Reader, loc: StructLoc, i: u16) Error!?CompositeList {
    const list = try followList(reader, loc, i);
    if (list.count == 0) return null;
    if (list.elem != .composite) return Error.InvalidPointer;
    if (list.data_idx >= reader.seg_words) return Error.Truncated;
    const tag = wire.decodeCompositeTag(try reader.word(list.data_idx));
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

// ── Views ────────────────────────────────────────────────────────────────────

/// Borrowed projection of a decoded message: the reader plus the located body
/// struct and its discriminant. Copies nothing; `toOwned` materializes.
pub const MessageView = struct {
    reader: Reader,
    kind: Kind,
    body: StructLoc,

    pub fn toOwned(self: MessageView, allocator: std.mem.Allocator) Error!model.Message {
        return ownedMessage(allocator, self.reader, self.kind, self.body);
    }
};

pub fn decodeView(frame: foundation.FrameView) Error!MessageView {
    if (frame.shape != .word) return Error.InvalidFrameShape;
    if (frame.bytes.len < wire.WORD_BYTES) return Error.Truncated;

    const header = std.mem.readInt(u64, frame.bytes[0..wire.WORD_BYTES], .little);
    if (@as(u32, @truncate(header)) != 0) return Error.UnsupportedSegmentCount;
    const seg_words: usize = @intCast(header >> 32);
    // Checked: `seg_words` is the attacker's header value (up to 2^32-1), so on a
    // 32-bit target (wasm32) `(1 + seg_words) * 8` can overflow `usize` and panic.
    // Fail closed with a typed error instead.
    const frame_words = std.math.add(usize, seg_words, 1) catch return Error.Truncated;
    const frame_len = std.math.mul(usize, frame_words, wire.WORD_BYTES) catch return Error.Truncated;
    if (frame.bytes.len < frame_len) return Error.Truncated;

    const reader = Reader{ .bytes = frame.bytes, .seg_words = seg_words };

    const root_word = try reader.word(0);
    if (wire.pointerKind(root_word) != .@"struct") return Error.InvalidPointer;
    const root = wire.decodeStructPointer(root_word);
    const env = StructLoc{ .data_idx = try reader.target(0, root.offset), .data_words = root.data_words, .ptr_words = root.ptr_words };

    const which: u16 = @truncate(try reader.dataWord(env, 0));
    if (which > @intFromEnum(Kind.index)) return Error.UnsupportedMessage;
    const body = (try reader.followStruct(env, 0)) orelse return Error.MalformedFrame;

    return .{ .reader = reader, .kind = @enumFromInt(which), .body = body };
}

pub fn decodeOwned(allocator: std.mem.Allocator, frame: foundation.FrameView) Error!model.Message {
    return ownedFromView(allocator, try decodeView(frame));
}

/// Frame the front of `bytes` as one Cap'n Proto message. The segment table at
/// the head of the frame is self-delimiting: the single-segment header word
/// gives the frame length directly, so the frame boundary comes from the same
/// header the decoder reads — there is no separate scanner. The body is then
/// decoded over exactly that slice and ratifies the length.
pub fn decodePrefix(bytes: []const u8, max_frame_bytes: usize) framing.Prefix {
    // Header word not fully arrived yet.
    if (bytes.len < wire.WORD_BYTES) return .incomplete;
    const header = std.mem.readInt(u64, bytes[0..wire.WORD_BYTES], .little);
    // Single-segment only (segment_count - 1 == 0); multi-segment is a
    // structural rejection, not a short read.
    if (@as(u32, @truncate(header)) != 0) return .malformed;
    const seg_words: usize = @intCast(header >> 32);
    // Checked against `usize` overflow on 32-bit targets (see decodeView): a
    // seg-count that can't fit the length math is, in effect, oversized.
    const frame_words = std.math.add(usize, seg_words, 1) catch return .too_large;
    const frame_len = std.math.mul(usize, frame_words, wire.WORD_BYTES) catch return .too_large;
    if (frame_len > max_frame_bytes) return .too_large;
    if (bytes.len < frame_len) return .incomplete;
    const body = decodeBody(.{ .shape = .word, .bytes = bytes[0..frame_len] }) catch return .malformed;
    return .{ .decoded = .{ .body = body, .consumed = frame_len } };
}

pub fn ownedFromView(allocator: std.mem.Allocator, view: MessageView) Error!model.Message {
    return view.toOwned(allocator);
}

// ── Decode: owned materialization ────────────────────────────────────────────

fn ownedMessage(allocator: std.mem.Allocator, reader: Reader, kind: Kind, body: StructLoc) Error!model.Message {
    return switch (kind) {
        .gc_answer => .{ .gc_answer = .{ .positions = try ownedU64List(allocator, reader, body, 0) } },
        .gc_export => blk: {
            const positions = try ownedU64List(allocator, reader, body, 0);
            errdefer allocator.free(positions);
            const deltas = try ownedU64List(allocator, reader, body, 1);
            break :blk .{ .gc_export = .{ .positions = positions, .deltas = deltas } };
        },
        .abort => .{ .abort = .{
            .kind = try abortKindFromWire(@truncate(try reader.dataWord(body, 0))),
            .message = try ownedText(allocator, reader, body, 0),
        } },
        .resolve => .{ .resolve = .{
            .answer = try reader.dataWord(body, 0),
            .resolution = try ownedResolution(allocator, reader, (try reader.followStruct(body, 0)) orelse return Error.MalformedFrame),
        } },
        .deliver => try ownedDeliver(allocator, reader, body),
        .listen => blk: {
            const target = try ownedRefAt(allocator, reader, body, 0, 0);
            errdefer model.freeReference(allocator, target);
            const listener = try ownedRefAt(allocator, reader, body, 1, 0);
            errdefer model.freeReference(allocator, listener);
            const wants_partial = (try reader.dataWord(body, 0)) & 1 != 0;
            break :blk .{ .listen = .{ .target = target, .listener = listener, .wants_partial = wants_partial } };
        },
        .get => blk: {
            const receiver = try ownedRefAt(allocator, reader, body, 0, 0);
            errdefer model.freeReference(allocator, receiver);
            const field = try ownedText(allocator, reader, body, 1);
            errdefer allocator.free(field);
            const answer = try reader.dataWord(body, 0);
            break :blk .{ .get = .{ .receiver = receiver, .field = field, .answer = answer } };
        },
        .index => blk: {
            const receiver = try ownedRefAt(allocator, reader, body, 0, 0);
            errdefer model.freeReference(allocator, receiver);
            const index: i64 = @bitCast(try reader.dataWord(body, 0));
            const answer = try reader.dataWord(body, 1);
            break :blk .{ .index = .{ .receiver = receiver, .index = index, .answer = answer } };
        },
        .start_session => try ownedStartSession(allocator, reader, body),
        .handoff => .{ .handoff = try ownedHandoff(allocator, reader, body) },
    };
}

fn ownedDeliver(allocator: std.mem.Allocator, reader: Reader, body: StructLoc) Error!model.Message {
    const flags = try reader.dataWord(body, 0);
    const target = try ownedRefAt(allocator, reader, body, 0, 0);
    errdefer model.freeReference(allocator, target);
    const args = try ownedArgumentList(allocator, reader, body, 1, 0);
    errdefer model.freeArgumentSlice(allocator, args);
    var deliver = model.Deliver{
        .target = target,
        .args = args,
        .answer = if (flags & 1 != 0) try reader.dataWord(body, 1) else null,
        .resolve_me_desc = null,
    };
    if (flags & 2 != 0) {
        if (try reader.followStruct(body, 2)) |ref_loc| deliver.resolve_me_desc = try ownedReference(allocator, reader, ref_loc, 0);
    }
    return .{ .deliver = deliver };
}

fn ownedStartSession(allocator: std.mem.Allocator, reader: Reader, body: StructLoc) Error!model.Message {
    // The version text is purely transient — only the parsed `version` outlives
    // it. Scope it to a block with `defer` so it is freed exactly once on every
    // exit (the `orelse return` and the normal break alike); a function-scoped
    // `errdefer` plus an explicit free would double-free if a later field fails.
    const version = blk: {
        const version_text = try ownedText(allocator, reader, body, 0);
        defer allocator.free(version_text);
        break :blk model.CaptpVersion.fromWireString(version_text) orelse return Error.MalformedFrame;
    };
    const session_pubkey = try ownedData(allocator, reader, body, 1);
    errdefer allocator.free(session_pubkey);
    const acceptable_location = try ownedPeerLocator(allocator, reader, (try reader.followStruct(body, 2)) orelse return Error.MalformedFrame);
    errdefer model.freePeerLocator(allocator, acceptable_location);
    const acceptable_location_sig = try ownedData(allocator, reader, body, 3);
    return .{ .start_session = .{
        .captp_version = version,
        .session_pubkey = .{ .bytes = session_pubkey },
        .acceptable_location = acceptable_location,
        .acceptable_location_sig = .{ .bytes = acceptable_location_sig },
    } };
}

fn ownedResolution(allocator: std.mem.Allocator, reader: Reader, loc: StructLoc) Error!model.Resolution {
    const disc = try enumFromWire(ResolutionKind, try reader.dataWord(loc, 0));
    const inner = (try reader.followStruct(loc, 0)) orelse return Error.MalformedFrame;
    return switch (disc) {
        .fulfill => .{ .fulfill = try ownedArgument(allocator, reader, inner, 0) },
        .break_ => .{ .break_ = try ownedError(allocator, reader, inner) },
    };
}

fn ownedHandoff(allocator: std.mem.Allocator, reader: Reader, body: StructLoc) Error!model.Handoff {
    const disc = try enumFromWire(HandoffKind, try reader.dataWord(body, 0));
    const inner = (try reader.followStruct(body, 0)) orelse return Error.MalformedFrame;
    return switch (disc) {
        .give => .{ .give = try ownedHandoffGive(allocator, reader, inner) },
        .receive => try ownedHandoffReceive(allocator, reader, inner),
    };
}

fn ownedHandoffGive(allocator: std.mem.Allocator, reader: Reader, loc: StructLoc) Error!model.HandoffGive {
    const recipient_key = try ownedData(allocator, reader, loc, 0);
    errdefer allocator.free(recipient_key);
    const exporter_location = try ownedData(allocator, reader, loc, 1);
    errdefer allocator.free(exporter_location);
    const gifter_exporter_session = try ownedData(allocator, reader, loc, 2);
    errdefer allocator.free(gifter_exporter_session);
    const gifter_side = try ownedData(allocator, reader, loc, 3);
    errdefer allocator.free(gifter_side);
    const gift_id = try ownedData(allocator, reader, loc, 4);
    errdefer allocator.free(gift_id);
    const signature = try ownedData(allocator, reader, loc, 5);
    return .{
        .recipient_key = recipient_key,
        .exporter_location = exporter_location,
        .gifter_exporter_session = gifter_exporter_session,
        .gifter_side = gifter_side,
        .gift_id = gift_id,
        .signature = signature,
    };
}

fn ownedHandoffReceive(allocator: std.mem.Allocator, reader: Reader, loc: StructLoc) Error!model.Handoff {
    const receiving_session = try ownedData(allocator, reader, loc, 0);
    errdefer allocator.free(receiving_session);
    const receiving_side = try ownedData(allocator, reader, loc, 1);
    errdefer allocator.free(receiving_side);
    const handoff_count = try reader.dataWord(loc, 0);
    const signed_give = try ownedHandoffGive(allocator, reader, (try reader.followStruct(loc, 2)) orelse return Error.MalformedFrame);
    errdefer model.freeHandoffGive(allocator, signed_give);
    const signature = try ownedData(allocator, reader, loc, 3);
    return .{ .receive = .{
        .receiving_session = receiving_session,
        .receiving_side = receiving_side,
        .handoff_count = handoff_count,
        .signed_give = signed_give,
        .signature = signature,
    } };
}

fn ownedRefAt(allocator: std.mem.Allocator, reader: Reader, loc: StructLoc, i: u16, depth: usize) Error!model.Reference {
    return ownedReference(allocator, reader, (try reader.followStruct(loc, i)) orelse return Error.MalformedFrame, depth);
}

fn ownedReference(allocator: std.mem.Allocator, reader: Reader, loc: StructLoc, depth: usize) Error!model.Reference {
    const data0 = try reader.dataWord(loc, 0);
    const disc = try enumFromWire(RefKind, data0);
    const scalar = try reader.dataWord(loc, 1);
    const is_promise = data0 & (1 << 16) != 0;
    return switch (disc) {
        // Perspective flip (ADR-0010): the wire arm is the sender's, so a wire
        // `near` (the sender's export) decodes to a `far` import on the receiver,
        // and a wire `far` (the sender's import) to a `near` export — matching the
        // Syrup decoder's `<desc:import-object>`→`far`, `<desc:export>`→`near`.
        .near => .{ .far = .{ .import_id = scalar, .kind = if (is_promise) .promise else .object } },
        .far => .{ .near = .{ .export_id = scalar, .kind = if (is_promise) .promise else .object } },
        .promise => .{ .promise = .{ .answer_id = scalar, .path = .{ .ops = try ownedPipelinePath(allocator, reader, loc, 0, depth) } } },
        .sturdy => blk: {
            const peer = try ownedPeerLocator(allocator, reader, (try reader.followStruct(loc, 0)) orelse return Error.MalformedFrame);
            errdefer model.freePeerLocator(allocator, peer);
            const swissnum = try ownedData(allocator, reader, loc, 1);
            break :blk .{ .sturdy = .{ .peer = peer, .swissnum = swissnum } };
        },
    };
}

fn ownedPeerLocator(allocator: std.mem.Allocator, reader: Reader, loc: StructLoc) Error!model.PeerLocator {
    const transport = try ownedText(allocator, reader, loc, 0);
    errdefer allocator.free(transport);
    const designator = try ownedText(allocator, reader, loc, 1);
    errdefer allocator.free(designator);
    const empty_false = (try reader.dataWord(loc, 0)) & 1 != 0;
    return .{
        .transport = transport,
        .designator = designator,
        .hints = if (empty_false) model.Hints.emptyFalse() else model.Hints.emptyMap(),
    };
}

fn ownedError(allocator: std.mem.Allocator, reader: Reader, loc: StructLoc) Error!model.Error {
    return .{ .message = try ownedText(allocator, reader, loc, 0) };
}

/// Maximum owned-decode nesting. A composite list pointer can address words
/// earlier in the segment, so a crafted single-segment frame could otherwise
/// drive `ownedArgument` to recurse one native stack frame per nesting level and
/// overflow the stack. This is the same backstop the engine's borrowed-view
/// materialization enforces (`model.view.max_owned_depth`); naming the codec's
/// own `decodeOwned` entry point to it keeps both public decode paths hardened
/// identically. `depth` counts argument-nesting levels, checked at the single
/// choke point below — every deeper recursion passes through here.
const max_owned_nesting: usize = model.view.max_owned_depth;

fn ownedArgument(allocator: std.mem.Allocator, reader: Reader, loc: StructLoc, depth: usize) Error!model.Argument {
    if (depth > max_owned_nesting) return Error.MalformedFrame;
    const next = depth + 1;
    const data0 = try reader.dataWord(loc, 0);
    const disc = try enumFromWire(ArgKind, data0);
    return switch (disc) {
        .bytes => .{ .bytes = try ownedData(allocator, reader, loc, 0) },
        .symbol => .{ .symbol = try ownedText(allocator, reader, loc, 0) },
        .reference => .{ .reference = try ownedReference(allocator, reader, (try reader.followStruct(loc, 0)) orelse return Error.MalformedFrame, next) },
        .@"error" => .{ .@"error" = try ownedError(allocator, reader, (try reader.followStruct(loc, 0)) orelse return Error.MalformedFrame) },
        .handoff => blk: {
            const handoff = try handoffFromStruct(allocator, reader, (try reader.followStruct(loc, 0)) orelse return Error.MalformedFrame);
            errdefer model.owned.freeHandoff(allocator, handoff);
            const boxed = try allocator.create(model.Handoff);
            boxed.* = handoff;
            break :blk .{ .handoff = boxed };
        },
        .string => .{ .string = try ownedText(allocator, reader, loc, 0) },
        .integer => .{ .integer = @bitCast(try reader.dataWord(loc, 1)) },
        .boolean => .{ .boolean = data0 & (1 << 16) != 0 },
        .list => .{ .list = try ownedArgumentList(allocator, reader, loc, 0, next) },
        .void => .{ .void = {} },
        .float64 => .{ .float64 = @bitCast(try reader.dataWord(loc, 1)) },
        .set => .{ .set = try ownedArgumentList(allocator, reader, loc, 0, next) },
        .tagged => .{ .tagged = try ownedTagged(allocator, reader, (try reader.followStruct(loc, 0)) orelse return Error.MalformedFrame, next) },
        .keyword => .{ .keyword = try ownedText(allocator, reader, loc, 0) },
    };
}

/// Materialize a handoff envelope reached through an `Argument`. The handoff
/// struct carries its own give/receive discriminant.
fn handoffFromStruct(allocator: std.mem.Allocator, reader: Reader, loc: StructLoc) Error!model.Handoff {
    const disc = try enumFromWire(HandoffKind, try reader.dataWord(loc, 0));
    const inner = (try reader.followStruct(loc, 0)) orelse return Error.MalformedFrame;
    return switch (disc) {
        .give => .{ .give = try ownedHandoffGive(allocator, reader, inner) },
        .receive => try ownedHandoffReceive(allocator, reader, inner),
    };
}

fn ownedTagged(allocator: std.mem.Allocator, reader: Reader, loc: StructLoc, depth: usize) Error!model.Tagged {
    const tag = try ownedText(allocator, reader, loc, 0);
    errdefer allocator.free(tag);
    const value = try ownedArgumentList(allocator, reader, loc, 1, depth);
    return .{ .tag = tag, .value = value };
}

fn ownedPipelinePath(allocator: std.mem.Allocator, reader: Reader, loc: StructLoc, i: u16, depth: usize) Error![]const model.PipelineOp {
    const clist = (try compositeList(reader, loc, i)) orelse return &.{};
    const ops = try allocator.alloc(model.PipelineOp, clist.element_count);
    var filled: usize = 0;
    // Free only the ops materialized so far: the unwritten tail is still
    // uninitialized union memory, so a whole-slice free would read garbage tags.
    errdefer {
        for (ops[0..filled]) |op| freePipelineOp(allocator, op);
        allocator.free(ops);
    }
    for (ops) |*op| {
        const elem = clist.elem(filled);
        const disc = try enumFromWire(PipelineOpKind, try reader.dataWord(elem, 0));
        op.* = switch (disc) {
            .field => .{ .field = try ownedText(allocator, reader, elem, 0) },
            .call => .{ .call = try ownedArgumentSlice(allocator, reader, elem, 0, depth) },
        };
        filled += 1;
    }
    return ops;
}

fn ownedArgumentList(allocator: std.mem.Allocator, reader: Reader, loc: StructLoc, i: u16, depth: usize) Error![]const model.Argument {
    return ownedArgumentSlice(allocator, reader, loc, i, depth);
}

fn ownedArgumentSlice(allocator: std.mem.Allocator, reader: Reader, loc: StructLoc, i: u16, depth: usize) Error![]const model.Argument {
    const clist = (try compositeList(reader, loc, i)) orelse return &.{};
    const args = try allocator.alloc(model.Argument, clist.element_count);
    var filled: usize = 0;
    errdefer {
        for (args[0..filled]) |arg| model.freeArgument(allocator, arg);
        allocator.free(args);
    }
    for (args) |*arg| {
        arg.* = try ownedArgument(allocator, reader, clist.elem(filled), depth);
        filled += 1;
    }
    return args;
}

fn ownedU64List(allocator: std.mem.Allocator, reader: Reader, loc: StructLoc, i: u16) Error![]const u64 {
    const list = try followList(reader, loc, i);
    if (list.count == 0) return &.{};
    // `data_idx` and `count` both come from the attacker-controlled list pointer;
    // add them checked so a wrap can't slip past this segment bound (the same
    // hardening `decodeView`/`compositeList` apply).
    const end = std.math.add(usize, list.data_idx, list.count) catch return Error.Truncated;
    if (end > reader.seg_words) return Error.Truncated;
    const out = try allocator.alloc(u64, list.count);
    errdefer allocator.free(out);
    for (out, 0..) |*value, idx| value.* = try reader.word(list.data_idx + idx);
    return out;
}

fn ownedText(allocator: std.mem.Allocator, reader: Reader, loc: StructLoc, i: u16) Error![]const u8 {
    return ownedData(allocator, reader, loc, i);
}

fn ownedData(allocator: std.mem.Allocator, reader: Reader, loc: StructLoc, i: u16) Error![]const u8 {
    const list = try followList(reader, loc, i);
    if (list.count == 0) return allocator.dupe(u8, "");
    return allocator.dupe(u8, try reader.byteSlice(list.data_idx, list.count));
}

fn freePipelineOp(allocator: std.mem.Allocator, op: model.PipelineOp) void {
    switch (op) {
        .field => |field| allocator.free(field),
        .call => |call| model.freeArgumentSlice(allocator, call),
    }
}

fn abortKindFromWire(value: u16) Error!model.AbortKind {
    if (value > @intFromEnum(model.AbortKind.other)) return Error.MalformedFrame;
    return @enumFromInt(value);
}

// ── Decode: borrowed codec-neutral view projection (ADR-0026) ────────────────
//
// `decodeBody` projects the shared [`model.view.Body`] directly over the
// frame's words — the codec-neutral shape the engine dispatches on, identical
// to the one [`syrup.decodeBody`](../syrup/core.zig) produces. Copies nothing:
// scalar and reference fields read straight from the words, borrowed text/bytes
// slice into the segment (`byteSlice`), and the unbounded sequences (`Args`,
// `PositionList`, `PipelinePath`) are reached through inline vtable backings —
// `at` re-walks the words lazily, so a nested `list` / `set` / `tagged` arm is
// itself another backing with no per-node allocation. `toOwned` (on the
// returned view) materializes.
//
// The `Ctx` packing, shared by every composite (struct-list) backing:
//   `bytes` = the full frame (the backing re-derives `seg_words` from the
//   segment header), `w0` = element-0 data-word index, `w1` =
//   `(data_words << 16) | ptr_words`, `w2` = element count. A primitive u64
//   list (`PositionList`) packs `w0` = content word index, `w2` = count
//   (one-word stride).

fn readerFromFrameBytes(bytes: []const u8) Error!Reader {
    if (bytes.len < wire.WORD_BYTES) return Error.Truncated;
    const header = std.mem.readInt(u64, bytes[0..wire.WORD_BYTES], .little);
    if (@as(u32, @truncate(header)) != 0) return Error.UnsupportedSegmentCount;
    return .{ .bytes = bytes, .seg_words = @intCast(header >> 32) };
}

const neutral_args_vtable = model.view.Args.VTable{ .len = neutralArgsLen, .at = neutralArgsAt, .next = neutralArgsNext };
const neutral_positions_vtable = model.view.PositionList.VTable{ .len = neutralPositionsLen, .at = neutralPositionsAt, .next = neutralPositionsNext };
const neutral_path_vtable = model.view.PipelinePath.VTable{ .len = neutralPathLen, .at = neutralPathAt, .next = neutralPathNext };

/// Pack a composite (struct-list) pointer field into a backing `Ctx`. A null /
/// empty list packs a zero count; otherwise the composite tag word supplies the
/// per-element section sizes and element count.
fn compositeListCtx(reader: Reader, loc: StructLoc, i: u16) Error!model.view.Args.Ctx {
    const clist = (try compositeList(reader, loc, i)) orelse return .{ .bytes = reader.bytes };
    return .{
        .bytes = reader.bytes,
        .w0 = clist.tag_idx + 1,
        .w1 = (@as(u64, clist.data_words) << 16) | clist.ptr_words,
        .w2 = clist.element_count,
    };
}

fn primitiveListCtx(reader: Reader, loc: StructLoc, i: u16) Error!model.view.Args.Ctx {
    const list = try followList(reader, loc, i);
    return .{ .bytes = reader.bytes, .w0 = list.data_idx, .w2 = list.count };
}

/// Reconstruct the `index`-th composite element's [`StructLoc`] from a `Ctx`.
fn compositeElem(ctx: model.view.Args.Ctx, index: usize) StructLoc {
    const data_words: u16 = @truncate(ctx.w1 >> 16);
    const ptr_words: u16 = @truncate(ctx.w1);
    const stride = @as(usize, data_words) + ptr_words;
    return .{
        .data_idx = @as(usize, @intCast(ctx.w0)) + index * stride,
        .data_words = data_words,
        .ptr_words = ptr_words,
    };
}

fn neutralArgsLen(ctx: model.view.Args.Ctx) model.view.ProjectError!usize {
    return @intCast(ctx.w2);
}

fn neutralArgsAt(ctx: model.view.Args.Ctx, index: usize) model.view.ProjectError!model.view.Argument {
    if (index >= ctx.w2) return error.MalformedView;
    const reader = readerFromFrameBytes(ctx.bytes) catch return error.MalformedView;
    return neutralArgument(reader, compositeElem(ctx, index)) catch return error.MalformedView;
}

/// Forward cursor over a composite list: `cursor` is the element index. Element
/// access is already O(1) stride math here, so this is `at` plus a bounds-gated
/// increment — the iterator interface is uniform across codecs.
fn neutralArgsNext(ctx: model.view.Args.Ctx, cursor: *u64) model.view.ProjectError!?model.view.Argument {
    if (cursor.* >= ctx.w2) return null;
    const out = try neutralArgsAt(ctx, @intCast(cursor.*));
    cursor.* += 1;
    return out;
}

fn neutralPositionsLen(ctx: model.view.PositionList.Ctx) model.view.ProjectError!usize {
    return @intCast(ctx.w2);
}

fn neutralPositionsAt(ctx: model.view.PositionList.Ctx, index: usize) model.view.ProjectError!u64 {
    if (index >= ctx.w2) return error.MalformedView;
    const reader = readerFromFrameBytes(ctx.bytes) catch return error.MalformedView;
    return reader.word(@as(usize, @intCast(ctx.w0)) + index) catch return error.MalformedView;
}

fn neutralPositionsNext(ctx: model.view.PositionList.Ctx, cursor: *u64) model.view.ProjectError!?u64 {
    if (cursor.* >= ctx.w2) return null;
    const out = try neutralPositionsAt(ctx, @intCast(cursor.*));
    cursor.* += 1;
    return out;
}

fn neutralPathLen(ctx: model.view.PipelinePath.Ctx) model.view.ProjectError!usize {
    return @intCast(ctx.w2);
}

fn neutralPathAt(ctx: model.view.PipelinePath.Ctx, index: usize) model.view.ProjectError!model.view.PipelineOp {
    if (index >= ctx.w2) return error.MalformedView;
    const reader = readerFromFrameBytes(ctx.bytes) catch return error.MalformedView;
    return neutralPipelineOp(reader, compositeElem(ctx, index)) catch return error.MalformedView;
}

fn neutralPathNext(ctx: model.view.PipelinePath.Ctx, cursor: *u64) model.view.ProjectError!?model.view.PipelineOp {
    if (cursor.* >= ctx.w2) return null;
    const out = try neutralPathAt(ctx, @intCast(cursor.*));
    cursor.* += 1;
    return out;
}

fn neutralArgsBacking(reader: Reader, loc: StructLoc, i: u16) Error!model.view.Args {
    return model.view.Args.fromBacking(try compositeListCtx(reader, loc, i), &neutral_args_vtable);
}

fn neutralPositionsBacking(reader: Reader, loc: StructLoc, i: u16) Error!model.view.PositionList {
    return model.view.PositionList.fromBacking(try primitiveListCtx(reader, loc, i), &neutral_positions_vtable);
}

fn neutralPathBacking(reader: Reader, loc: StructLoc, i: u16) Error!model.view.PipelinePath {
    return model.view.PipelinePath.fromBacking(try compositeListCtx(reader, loc, i), &neutral_path_vtable);
}

/// Borrowed text/bytes: a slice straight into the segment (no copy). Mirror of
/// `ownedData` minus the dupe.
fn borrowedData(reader: Reader, loc: StructLoc, i: u16) Error![]const u8 {
    const list = try followList(reader, loc, i);
    if (list.count == 0) return &.{};
    return reader.byteSlice(list.data_idx, list.count);
}

/// Borrowed reference, receiver-perspective (ADR-0010 flip) — mirror of
/// `ownedReference`.
fn neutralReferenceView(reader: Reader, loc: StructLoc) Error!model.view.Reference {
    const data0 = try reader.dataWord(loc, 0);
    const disc = try enumFromWire(RefKind, data0);
    const scalar = try reader.dataWord(loc, 1);
    const is_promise = data0 & (1 << 16) != 0;
    return switch (disc) {
        .near => .{ .far = .{ .import_id = scalar, .kind = if (is_promise) .promise else .object } },
        .far => .{ .near = .{ .export_id = scalar, .kind = if (is_promise) .promise else .object } },
        .promise => .{ .promise = .{ .answer_id = scalar, .path = try neutralPathBacking(reader, loc, 0) } },
        .sturdy => .{ .sturdy = .{
            .peer = try neutralPeerLocator(reader, (try reader.followStruct(loc, 0)) orelse return Error.MalformedFrame),
            .swissnum = try borrowedData(reader, loc, 1),
        } },
    };
}

fn neutralPeerLocator(reader: Reader, loc: StructLoc) Error!model.view.PeerLocatorView {
    const empty_false = (try reader.dataWord(loc, 0)) & 1 != 0;
    return .{
        .transport = try borrowedData(reader, loc, 0),
        .designator = try borrowedData(reader, loc, 1),
        .hints = if (empty_false) model.Hints.emptyFalse() else model.Hints.emptyMap(),
    };
}

fn neutralErrorView(reader: Reader, loc: StructLoc) Error!model.view.ErrorValue {
    return .{ .message = try borrowedData(reader, loc, 0) };
}

fn neutralPipelineOp(reader: Reader, loc: StructLoc) Error!model.view.PipelineOp {
    const disc = try enumFromWire(PipelineOpKind, try reader.dataWord(loc, 0));
    return switch (disc) {
        .field => .{ .field = try borrowedData(reader, loc, 0) },
        .call => .{ .call = try neutralArgsBacking(reader, loc, 0) },
    };
}

/// Borrowed argument — full fidelity, mirror of `ownedArgument`. Nested
/// `list` / `set` / `tagged` arms are lazy `Args` backings (no allocation).
fn neutralArgument(reader: Reader, loc: StructLoc) Error!model.view.Argument {
    const data0 = try reader.dataWord(loc, 0);
    const disc = try enumFromWire(ArgKind, data0);
    return switch (disc) {
        .bytes => .{ .bytes = try borrowedData(reader, loc, 0) },
        .symbol => .{ .symbol = try borrowedData(reader, loc, 0) },
        .reference => .{ .reference = try neutralReferenceView(reader, (try reader.followStruct(loc, 0)) orelse return Error.MalformedFrame) },
        .@"error" => .{ .@"error" = try neutralErrorView(reader, (try reader.followStruct(loc, 0)) orelse return Error.MalformedFrame) },
        .handoff => .{ .handoff = try neutralHandoffFromStruct(reader, (try reader.followStruct(loc, 0)) orelse return Error.MalformedFrame) },
        .string => .{ .string = try borrowedData(reader, loc, 0) },
        .integer => .{ .integer = @bitCast(try reader.dataWord(loc, 1)) },
        .boolean => .{ .boolean = data0 & (1 << 16) != 0 },
        .list => .{ .list = try neutralArgsBacking(reader, loc, 0) },
        .void => .{ .void = {} },
        .float64 => .{ .float64 = @bitCast(try reader.dataWord(loc, 1)) },
        .set => .{ .set = try neutralArgsBacking(reader, loc, 0) },
        .tagged => blk: {
            const tagged_loc = (try reader.followStruct(loc, 0)) orelse return Error.MalformedFrame;
            break :blk .{ .tagged = .{
                .tag = try borrowedData(reader, tagged_loc, 0),
                .value = try neutralArgsBacking(reader, tagged_loc, 1),
            } };
        },
        .keyword => .{ .keyword = try borrowedData(reader, loc, 0) },
    };
}

fn neutralHandoffFromStruct(reader: Reader, loc: StructLoc) Error!model.view.Handoff {
    const disc = try enumFromWire(HandoffKind, try reader.dataWord(loc, 0));
    const inner = (try reader.followStruct(loc, 0)) orelse return Error.MalformedFrame;
    return switch (disc) {
        .give => .{ .give = try neutralHandoffGive(reader, inner) },
        .receive => try neutralHandoffReceive(reader, inner),
    };
}

fn neutralHandoffGive(reader: Reader, loc: StructLoc) Error!model.view.HandoffGive {
    return .{
        .recipient_key = try borrowedData(reader, loc, 0),
        // Cap'n Proto carries the exporter location as opaque bytes and the
        // signature contiguously (ADR-0026), so both are the `raw` arm.
        .exporter_location = .{ .raw = try borrowedData(reader, loc, 1) },
        .gifter_exporter_session = try borrowedData(reader, loc, 2),
        .gifter_side = try borrowedData(reader, loc, 3),
        .gift_id = try borrowedData(reader, loc, 4),
        .signature = .{ .raw = try borrowedData(reader, loc, 5) },
    };
}

fn neutralHandoffReceive(reader: Reader, loc: StructLoc) Error!model.view.Handoff {
    return .{ .receive = .{
        .receiving_session = try borrowedData(reader, loc, 0),
        .receiving_side = try borrowedData(reader, loc, 1),
        .handoff_count = try reader.dataWord(loc, 0),
        .signed_give = try neutralHandoffGive(reader, (try reader.followStruct(loc, 2)) orelse return Error.MalformedFrame),
        .signature = .{ .raw = try borrowedData(reader, loc, 3) },
    } };
}

fn neutralResolution(reader: Reader, loc: StructLoc) Error!model.view.Resolution {
    const disc = try enumFromWire(ResolutionKind, try reader.dataWord(loc, 0));
    const inner = (try reader.followStruct(loc, 0)) orelse return Error.MalformedFrame;
    return switch (disc) {
        .fulfill => .{ .fulfill = try neutralArgument(reader, inner) },
        .break_ => .{ .break_ = try neutralErrorView(reader, inner) },
    };
}

fn neutralStartSession(reader: Reader, body: StructLoc) Error!model.view.StartSession {
    const version_text = try borrowedData(reader, body, 0);
    const version = model.CaptpVersion.fromWireString(version_text) orelse return Error.MalformedFrame;
    return .{
        .captp_version = version,
        .session_pubkey = try borrowedData(reader, body, 1),
        .acceptable_location = try neutralPeerLocator(reader, (try reader.followStruct(body, 2)) orelse return Error.MalformedFrame),
        .acceptable_location_sig = .{ .raw = try borrowedData(reader, body, 3) },
    };
}

/// Project the borrowed codec-neutral [`model.view.Body`] over `frame`.
pub fn decodeBody(frame: foundation.FrameView) Error!model.view.Body {
    const view = try decodeView(frame);
    const reader = view.reader;
    const body = view.body;
    return switch (view.kind) {
        .deliver => blk: {
            const flags = try reader.dataWord(body, 0);
            var resolve_me: ?model.view.Reference = null;
            if (flags & 2 != 0) {
                if (try reader.followStruct(body, 2)) |ref_loc| resolve_me = try neutralReferenceView(reader, ref_loc);
            }
            break :blk .{ .deliver = .{
                .target = try neutralReferenceView(reader, (try reader.followStruct(body, 0)) orelse return Error.MalformedFrame),
                .args = try neutralArgsBacking(reader, body, 1),
                .answer = if (flags & 1 != 0) try reader.dataWord(body, 1) else null,
                .resolve_me_desc = resolve_me,
            } };
        },
        .resolve => .{ .resolve = .{
            .answer = try reader.dataWord(body, 0),
            .resolution = try neutralResolution(reader, (try reader.followStruct(body, 0)) orelse return Error.MalformedFrame),
        } },
        .gc_export => .{ .gc_export = .{
            .positions = try neutralPositionsBacking(reader, body, 0),
            .deltas = try neutralPositionsBacking(reader, body, 1),
        } },
        .gc_answer => .{ .gc_answer = .{ .positions = try neutralPositionsBacking(reader, body, 0) } },
        .abort => .{ .abort = .{
            .kind = try abortKindFromWire(@truncate(try reader.dataWord(body, 0))),
            .message = try borrowedData(reader, body, 0),
        } },
        .listen => .{ .listen = .{
            .target = try neutralReferenceView(reader, (try reader.followStruct(body, 0)) orelse return Error.MalformedFrame),
            .listener = try neutralReferenceView(reader, (try reader.followStruct(body, 1)) orelse return Error.MalformedFrame),
            .wants_partial = (try reader.dataWord(body, 0)) & 1 != 0,
        } },
        .get => .{ .get = .{
            .receiver = try neutralReferenceView(reader, (try reader.followStruct(body, 0)) orelse return Error.MalformedFrame),
            .field = try borrowedData(reader, body, 1),
            .answer = try reader.dataWord(body, 0),
        } },
        .index => .{ .index = .{
            .receiver = try neutralReferenceView(reader, (try reader.followStruct(body, 0)) orelse return Error.MalformedFrame),
            .index = @bitCast(try reader.dataWord(body, 0)),
            .answer = try reader.dataWord(body, 1),
        } },
        .start_session => .{ .start_session = try neutralStartSession(reader, body) },
        .handoff => .{ .handoff = try neutralHandoffFromStruct(reader, body) },
    };
}

// ── Encode ───────────────────────────────────────────────────────────────────

/// Encode for a wire profile — the codec-dispatch boundary's counterpart to
/// [`syrup.encodeMessageForProfile`](../syrup/core.zig). Cap'n Proto is
/// pancake's self-consistent dialect (ADR-0026): the struct schema always
/// carries `resolve_me_desc` / `wants_partial`, and the engine applies the
/// V1.0 semantic translation (resolver-callback projection) *before* handing a
/// `model.Message` here, so the word layout is profile-independent. The
/// parameter is accepted for boundary uniformity and intentionally unused.
pub fn encodeMessageForProfile(
    allocator: std.mem.Allocator,
    profile: model.WireProfile,
    message: model.Message,
) Error!foundation.Frame {
    _ = profile;
    return encodeMessage(allocator, message);
}

pub fn encodeMessage(allocator: std.mem.Allocator, message: model.Message) Error!foundation.Frame {
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
    };
}

fn encodeBody(b: *wire.Builder, allocator: std.mem.Allocator, message: model.Message) Error!StructLoc {
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
            try setText(b, allocator, loc, 0, abort.message);
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
            try setText(b, allocator, loc, 1, get.field);
            break :blk loc;
        },
        .index => |index| blk: {
            const loc = try allocStruct(b, allocator, 2, 1);
            b.set(loc.data_idx, @bitCast(index.index));
            b.set(loc.data_idx + 1, index.answer);
            setStructPtr(b, ptrIndex(loc, 0), try encodeReference(b, allocator, index.receiver));
            break :blk loc;
        },
        .start_session => |ss| try encodeStartSession(b, allocator, ss),
        .handoff => |handoff| try encodeHandoff(b, allocator, handoff),
    };
}

fn encodeDeliver(b: *wire.Builder, allocator: std.mem.Allocator, deliver: model.Deliver) Error!StructLoc {
    const loc = try allocStruct(b, allocator, 2, 3);
    var flags: u64 = 0;
    if (deliver.answer) |answer| {
        flags |= 1;
        b.set(loc.data_idx + 1, answer);
    }
    if (deliver.resolve_me_desc != null) flags |= 2;
    b.set(loc.data_idx, flags);
    setStructPtr(b, ptrIndex(loc, 0), try encodeReference(b, allocator, deliver.target));
    setListPtr(b, ptrIndex(loc, 1), try encodeArgumentList(b, allocator, deliver.args));
    if (deliver.resolve_me_desc) |desc| setStructPtr(b, ptrIndex(loc, 2), try encodeReference(b, allocator, desc));
    return loc;
}

fn encodeStartSession(b: *wire.Builder, allocator: std.mem.Allocator, ss: model.StartSession) Error!StructLoc {
    const loc = try allocStruct(b, allocator, 0, 4);
    try setText(b, allocator, loc, 0, ss.captp_version.wireString());
    try setData(b, allocator, loc, 1, ss.session_pubkey.bytes);
    setStructPtr(b, ptrIndex(loc, 2), try encodePeerLocator(b, allocator, ss.acceptable_location));
    try setData(b, allocator, loc, 3, ss.acceptable_location_sig.bytes);
    return loc;
}

fn encodeResolution(b: *wire.Builder, allocator: std.mem.Allocator, resolution: model.Resolution) Error!StructLoc {
    const loc = try allocStruct(b, allocator, 1, 1);
    switch (resolution) {
        .fulfill => |arg| {
            b.set(loc.data_idx, @intFromEnum(ResolutionKind.fulfill));
            setStructPtr(b, ptrIndex(loc, 0), try encodeArgument(b, allocator, arg));
        },
        .break_ => |err| {
            b.set(loc.data_idx, @intFromEnum(ResolutionKind.break_));
            setStructPtr(b, ptrIndex(loc, 0), try encodeError(b, allocator, err));
        },
    }
    return loc;
}

fn encodeHandoff(b: *wire.Builder, allocator: std.mem.Allocator, handoff: model.Handoff) Error!StructLoc {
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

fn encodeHandoffGive(b: *wire.Builder, allocator: std.mem.Allocator, give: model.HandoffGive) Error!StructLoc {
    const loc = try allocStruct(b, allocator, 0, 6);
    try setData(b, allocator, loc, 0, give.recipient_key);
    try setData(b, allocator, loc, 1, give.exporter_location);
    try setData(b, allocator, loc, 2, give.gifter_exporter_session);
    try setData(b, allocator, loc, 3, give.gifter_side);
    try setData(b, allocator, loc, 4, give.gift_id);
    try setData(b, allocator, loc, 5, give.signature);
    return loc;
}

fn encodeHandoffReceive(b: *wire.Builder, allocator: std.mem.Allocator, receive: model.HandoffReceive) Error!StructLoc {
    const loc = try allocStruct(b, allocator, 1, 4);
    b.set(loc.data_idx, receive.handoff_count);
    try setData(b, allocator, loc, 0, receive.receiving_session);
    try setData(b, allocator, loc, 1, receive.receiving_side);
    setStructPtr(b, ptrIndex(loc, 2), try encodeHandoffGive(b, allocator, receive.signed_give));
    try setData(b, allocator, loc, 3, receive.signature);
    return loc;
}

fn encodeReference(b: *wire.Builder, allocator: std.mem.Allocator, reference: model.Reference) Error!StructLoc {
    const loc = try allocStruct(b, allocator, 2, 2);
    switch (reference) {
        .near => |near| {
            b.set(loc.data_idx, @intFromEnum(RefKind.near) | (@as(u64, @intFromBool(near.kind == .promise)) << 16));
            b.set(loc.data_idx + 1, near.export_id);
        },
        .far => |far| {
            b.set(loc.data_idx, @intFromEnum(RefKind.far) | (@as(u64, @intFromBool(far.kind == .promise)) << 16));
            b.set(loc.data_idx + 1, far.import_id);
        },
        .promise => |promise| {
            b.set(loc.data_idx, @intFromEnum(RefKind.promise));
            b.set(loc.data_idx + 1, promise.answer_id);
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

fn encodePeerLocator(b: *wire.Builder, allocator: std.mem.Allocator, locator: model.PeerLocator) Error!StructLoc {
    const loc = try allocStruct(b, allocator, 1, 2);
    if (locator.hints.entries.len == 0 and locator.hints.empty_wire_was_false) b.set(loc.data_idx, 1);
    try setText(b, allocator, loc, 0, locator.transport);
    try setText(b, allocator, loc, 1, locator.designator);
    return loc;
}

fn encodeError(b: *wire.Builder, allocator: std.mem.Allocator, err: model.Error) Error!StructLoc {
    const loc = try allocStruct(b, allocator, 0, 1);
    try setText(b, allocator, loc, 0, err.message);
    return loc;
}

fn encodeTagged(b: *wire.Builder, allocator: std.mem.Allocator, tagged: model.Tagged) Error!StructLoc {
    const loc = try allocStruct(b, allocator, 0, 2);
    try setText(b, allocator, loc, 0, tagged.tag);
    setListPtr(b, ptrIndex(loc, 1), try encodeArgumentList(b, allocator, tagged.value));
    return loc;
}

fn encodeArgument(b: *wire.Builder, allocator: std.mem.Allocator, arg: model.Argument) Error!StructLoc {
    const loc = try allocStruct(b, allocator, 2, 1);
    try encodeArgumentInto(b, allocator, arg, loc);
    return loc;
}

/// Fill an already-allocated 2-data / 1-pointer Argument struct at `loc`. Used
/// both standalone and for composite-list elements.
fn encodeArgumentInto(b: *wire.Builder, allocator: std.mem.Allocator, arg: model.Argument, loc: StructLoc) Error!void {
    switch (arg) {
        .bytes => |bytes| {
            b.set(loc.data_idx, @intFromEnum(ArgKind.bytes));
            try setData(b, allocator, loc, 0, bytes);
        },
        .symbol => |symbol| {
            b.set(loc.data_idx, @intFromEnum(ArgKind.symbol));
            try setText(b, allocator, loc, 0, symbol);
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
            try setText(b, allocator, loc, 0, string);
        },
        .integer => |integer| {
            b.set(loc.data_idx, @intFromEnum(ArgKind.integer));
            b.set(loc.data_idx + 1, @bitCast(integer));
        },
        .boolean => |boolean| {
            b.set(loc.data_idx, @intFromEnum(ArgKind.boolean) | (@as(u64, @intFromBool(boolean)) << 16));
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
            try setText(b, allocator, loc, 0, keyword);
        },
    }
}

/// Composite list of `Argument` (2 data words, 1 pointer word per element).
fn encodeArgumentList(b: *wire.Builder, allocator: std.mem.Allocator, args: []const model.Argument) Error!ListContent {
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
/// in place. A set is unordered, so its wire form must not leak the order the
/// model held it in — the Cap'n Proto partner of the same canonicalization the
/// Syrup codec applies, each codec sorting by its own encoded bytes. The
/// per-element encodings are scratch keys, freed before returning; only the
/// reordered slice (which the caller frees) survives. Caller owns it.
fn canonicalSetOrder(allocator: std.mem.Allocator, args: []const model.Argument) Error![]model.Argument {
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

    // Sort an index permutation by key bytes, then materialize the reorder.
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
fn encodeArgumentKey(allocator: std.mem.Allocator, arg: model.Argument) Error![]u8 {
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
fn encodePipelinePath(b: *wire.Builder, allocator: std.mem.Allocator, ops: []const model.PipelineOp) Error!ListContent {
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
                try setText(b, allocator, loc, 0, field);
            },
            .call => |call| {
                b.set(loc.data_idx, @intFromEnum(PipelineOpKind.call));
                setListPtr(b, ptrIndex(loc, 0), try encodeArgumentList(b, allocator, call));
            },
        }
    }
    return .{ .data_idx = tag_idx, .elem = .composite, .count = ops.len * stride };
}

// ── Encode helpers ───────────────────────────────────────────────────────────

const ListContent = struct { data_idx: usize, elem: wire.ElementSize, count: usize };

fn allocStruct(b: *wire.Builder, allocator: std.mem.Allocator, data_words: u16, ptr_words: u16) Error!StructLoc {
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

fn setU64List(b: *wire.Builder, allocator: std.mem.Allocator, loc: StructLoc, i: u16, values: []const u64) Error!void {
    const start = try b.allocWords(allocator, values.len);
    for (values, 0..) |value, idx| b.set(start + idx, value);
    setListPtr(b, ptrIndex(loc, i), .{ .data_idx = start, .elem = .eight_bytes, .count = values.len });
}

fn setText(b: *wire.Builder, allocator: std.mem.Allocator, loc: StructLoc, i: u16, text: []const u8) Error!void {
    return setData(b, allocator, loc, i, text);
}

fn setData(b: *wire.Builder, allocator: std.mem.Allocator, loc: StructLoc, i: u16, bytes: []const u8) Error!void {
    const start = try b.allocWords(allocator, wire.wordsForBytes(bytes.len));
    b.setBytes(start, bytes);
    setListPtr(b, ptrIndex(loc, i), .{ .data_idx = start, .elem = .byte, .count = bytes.len });
}
