//! The Cap'n Proto decode path, hand-rolled for the pancake-to-pancake wire.
//!
//! Cap'n Proto is the word-aligned alternative to Syrup. It carries the same
//! `model.Message` tree, just laid out as a run of 8-byte words instead of
//! Syrup's byte records. There's no schema compiler in the loop: we read the
//! struct and list layout directly against the wire primitives in `wire.zig`
//! (ADR-0026), so the codec stands on its own and the layout tracks the model.
//! Rendering lives in `encode.zig`; the layout and reader vocabulary both
//! sides share lives in `shared.zig`.
//!
//! Decode reads before it copies. `decodeBody` projects the borrowed
//! codec-neutral view over the frame without copying anything, and
//! `decodeOwned` is just that followed by `model.view.Body.toOwned` — one
//! decode vocabulary, the same shape as `syrup.decodeOwned` — so owned
//! materialization only happens when you ask for it.
//!
//! References flip perspective every time they cross the wire (ADR-0010), the
//! same way Syrup does. Something we export goes out as a `near`, and the partner
//! reads it back as a `far` import; the reverse happens too. The flip is a fixed
//! relabel of the wire arm. It never consults a table, so the codec still holds
//! no authority.
//!
//! Every `Message` arm decodes, along with everything the arms share:
//! `Reference`, every `Argument` arm, `Resolution`, `BreakReason`,
//! `PeerLocator`, `Handoff`, `Tagged`, and `PipelineOp`.
//!
//! [ADR-0026]: ../../../docs/decisions/adr/ADR-0026-hand-rolled-capnp-codec.md

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const framing = @import("framing");
const shared = @import("shared.zig");

const wire = shared.wire;
const Error = shared.Error;
const Kind = shared.Kind;

const RefTag = shared.RefTag;
const ArgKind = shared.ArgKind;
const ResolutionKind = shared.ResolutionKind;
const PipelineOpKind = shared.PipelineOpKind;
const HandoffKind = shared.HandoffKind;
const StructLoc = shared.StructLoc;
const CompositeList = shared.CompositeList;
const followList = shared.followList;
const enumFromWire = shared.enumFromWire;
const compositeList = shared.compositeList;

const Reader = shared.Reader;

// ── Views ────────────────────────────────────────────────────────────────────

/// Borrowed projection of a decoded message: the reader plus the located body
/// struct and its discriminant. Copies nothing; `toOwned` materializes through
/// the same codec-neutral view walk `decodeBody` projects.
pub const MessageView = struct {
    reader: Reader,
    kind: Kind,
    body: StructLoc,

    pub fn toOwned(self: MessageView, allocator: std.mem.Allocator) !model.Message {
        return (try neutralBody(self)).toOwned(allocator);
    }
};

pub fn decodeMessageView(frame: foundation.FrameView) Error!MessageView {
    if (frame.shape != .word) return Error.InvalidFrameShape;
    const reader = try shared.readerFromFrame(frame.bytes);

    const root_word = try reader.word(0);
    if (wire.pointerKind(root_word) != .@"struct") return Error.InvalidPointer;
    const root = wire.decodeStructPointer(root_word);
    const env = StructLoc{ .data_idx = try reader.target(0, root.offset), .data_words = root.data_words, .ptr_words = root.ptr_words };

    const kind = try enumFromWire(Kind, try reader.dataWord(env, 0));
    const body = (try reader.followStruct(env, 0)) orelse return Error.MalformedFrame;

    return .{ .reader = reader, .kind = kind, .body = body };
}

/// Materialize an owned `model.Message` from a complete `frame`: the
/// borrowed codec-neutral projection (`decodeBody`) followed by
/// `model.view.Body.toOwned`. One decode vocabulary — every argument arm the
/// encoder emits reads back with full fidelity — mirroring `syrup.decodeOwned`,
/// so the owned path can never drift from the view path the engine dispatches.
pub fn decodeOwned(allocator: std.mem.Allocator, frame: foundation.FrameView) !model.Message {
    return (try decodeBody(frame)).toOwned(allocator);
}

/// Frame the front of `bytes` as one Cap'n Proto message. The segment table at
/// the head of the frame is self-delimiting: the single-segment header word
/// gives the frame length directly, so the frame boundary comes from the same
/// header the decoder reads — there is no separate scanner. The body is then
/// decoded over exactly that slice and ratifies the length.
pub fn decodePrefix(bytes: []const u8, max_frame_bytes: usize) framing.Prefix {
    return decodePrefixForProfile(.v1_0, bytes, max_frame_bytes);
}

pub fn decodePrefixForProfile(profile: model.CaptpVersion, bytes: []const u8, max_frame_bytes: usize) framing.Prefix {
    const frame = switch (prefixFrame(bytes, max_frame_bytes)) {
        .frame => |frame| frame,
        .incomplete => return .incomplete,
        .malformed => return .malformed,
        .too_large => return .too_large,
    };
    const body = decodeBodyForProfile(profile, frame.view) catch return .malformed;
    return .{ .decoded = .{ .body = body, .consumed = frame.consumed } };
}

/// Delimit one structurally valid Cap'n Proto frame without assigning
/// profile-dependent meaning to it. In particular, raw listen mode 1 means
/// different things in V1.0 and next; a peer-less `FrameStream` must carry the
/// bytes to the session rather than guess.
pub fn framePrefix(bytes: []const u8, max_frame_bytes: usize) framing.Boundary {
    const frame = switch (prefixFrame(bytes, max_frame_bytes)) {
        .frame => |frame| frame,
        .incomplete => return .incomplete,
        .malformed => return .malformed,
        .too_large => return .too_large,
    };
    validateBodyForFraming(frame.view) catch return .malformed;
    return .{ .complete = frame.consumed };
}

const PrefixFrame = struct {
    view: foundation.FrameView,
    consumed: usize,
};

const PrefixFrameResult = union(enum) {
    frame: PrefixFrame,
    incomplete,
    malformed,
    too_large,
};

fn prefixFrame(bytes: []const u8, max_frame_bytes: usize) PrefixFrameResult {
    // Header word not fully arrived yet.
    if (bytes.len < wire.WORD_BYTES) return .incomplete;
    const reader = shared.readerFromFrame(bytes) catch |err| switch (err) {
        // Single-segment only (segment_count - 1 == 0); multi-segment is a
        // structural rejection, not a short read.
        Error.UnsupportedSegmentCount => return .malformed,
        // The header word is complete, so `Truncated` means the declared frame
        // end lies past the buffer. While the declared length still fits the
        // cap the frame is `.incomplete` (read more); a length past the cap —
        // including one that overflows `usize` on a 32-bit target — can never
        // complete within it, so it is `.too_large` (ADR-0041).
        Error.Truncated => {
            const declared = declaredFrameLen(bytes) orelse return .too_large;
            return if (declared > max_frame_bytes) .too_large else .incomplete;
        },
        else => return .malformed,
    };
    // `readerFromFrame` proved the declared frame fits the buffer, so the
    // length math cannot overflow here.
    const frame_len = (reader.seg_words + 1) * wire.WORD_BYTES;
    if (frame_len > max_frame_bytes) return .too_large;
    const frame: foundation.FrameView = .{ .shape = .word, .bytes = bytes[0..frame_len] };
    return .{ .frame = .{ .view = frame, .consumed = frame_len } };
}

/// The frame length a (complete) header word declares, or null when the checked
/// `(seg_words + 1) * 8` does not fit `usize` (32-bit targets).
fn declaredFrameLen(bytes: []const u8) ?usize {
    const header = std.mem.readInt(u64, bytes[0..wire.WORD_BYTES], .little);
    const seg_words: usize = @intCast(header >> 32);
    const frame_words = std.math.add(usize, seg_words, 1) catch return null;
    return std.math.mul(usize, frame_words, wire.WORD_BYTES) catch return null;
}

// ── Decode: borrowed codec-neutral view projection (ADR-0026) ────────────────
//
// `decodeBody` projects the shared `model.view.Body` directly over the
// frame's words — the codec-neutral shape the engine dispatches on, identical
// to the one [`syrup.decodeBody`](../syrup/decode.zig) produces. Copies nothing:
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

const neutral_args_vtable = model.view.Args.VTable{ .len = neutralArgsLen, .at = neutralArgsAt, .next = neutralArgsNext };
const neutral_positions_vtable = model.view.PositionList.VTable{ .len = neutralPositionsLen, .at = neutralPositionsAt, .next = neutralPositionsNext };
const neutral_path_vtable = model.view.PipelinePath.VTable{ .len = neutralPathLen, .at = neutralPathAt, .next = neutralPathNext };

/// Pack a composite (struct-list) pointer field into a backing `Ctx`. A null /
/// empty list packs a zero count; otherwise the composite tag word supplies the
/// per-element section sizes and element count.
fn compositeListCtx(reader: Reader, loc: StructLoc, i: u16) Error!model.view.Args.Ctx {
    const clist = (try compositeList(reader, loc, i)) orelse return .{ .bytes = reader.bytes };
    return ctxFromComposite(reader, clist);
}

fn ctxFromComposite(reader: Reader, clist: CompositeList) model.view.Args.Ctx {
    return .{
        .bytes = reader.bytes,
        .w0 = clist.tag_idx + 1,
        .w1 = (@as(u64, clist.data_words) << 16) | clist.ptr_words,
        .w2 = clist.element_count,
    };
}

fn primitiveListCtx(reader: Reader, loc: StructLoc, i: u16) Error!model.view.Args.Ctx {
    const list = try followList(reader, loc, i);
    // Its one caller is the position list, whose elements are words read at
    // `data_idx + index`, so the pointer must declare eight-byte elements;
    // reject any other size (the encoder always writes `.eight_bytes`). `data_idx`
    // and `count` are attacker-controlled, so prove the run fits the segment up
    // front — the same bound `ownedU64List` applies — so a consumer that trusts
    // the projected `len()` to size an allocation cannot be amplified past it.
    if (list.count != 0 and list.elem != .eight_bytes) return Error.InvalidPointer;
    const end = std.math.add(usize, list.data_idx, list.count) catch return Error.Truncated;
    if (end > reader.seg_words) return Error.Truncated;
    return .{ .bytes = reader.bytes, .w0 = list.data_idx, .w2 = list.count };
}

/// Reconstruct the `index`-th composite element's `StructLoc` from a `Ctx`.
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
    const reader = shared.readerFromFrame(ctx.bytes) catch return error.MalformedView;
    return neutralArgument(reader, compositeElem(ctx, index)) catch return error.MalformedView;
}

/// Forward cursor over a composite list: `cursor` is the element index. Element
/// access is already O(1) stride math here, so this is `at` plus a bounds-gated
/// increment, the iterator interface is uniform across codecs.
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
    const reader = shared.readerFromFrame(ctx.bytes) catch return error.MalformedView;
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
    const reader = shared.readerFromFrame(ctx.bytes) catch return error.MalformedView;
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

/// Borrow text or bytes as a slice straight into the segment, with no copy.
fn borrowedData(reader: Reader, loc: StructLoc, i: u16) Error![]const u8 {
    const list = try followList(reader, loc, i);
    if (list.count == 0) return &.{};
    return reader.byteSlice(list.data_idx, list.count);
}

/// Borrow a model String or Symbol directly from the frame and reject malformed
/// Unicode at the codec boundary. Validation scans in place and never allocates
/// or copies; raw ByteArray fields continue to use `borrowedData`.
fn borrowedText(reader: Reader, loc: StructLoc, i: u16) Error![]const u8 {
    const text = try borrowedData(reader, loc, i);
    if (!std.unicode.utf8ValidateSlice(text)) return Error.MalformedFrame;
    return text;
}

/// Project a borrowed reference in the receiver's perspective (the ADR-0010
/// flip).
fn neutralReferenceView(reader: Reader, loc: StructLoc) Error!model.view.Reference {
    const data0 = try reader.dataWord(loc, 0);
    const disc = try enumFromWire(RefTag, data0);
    const scalar = try reader.dataWord(loc, 1);
    const is_promise = data0 & shared.data0_flag != 0;
    return switch (disc) {
        .near => .{ .far = .{ .import_position = model.ImportPosition.from(scalar), .kind = if (is_promise) .promise else .object } },
        .far => .{ .near = .{ .export_position = model.ExportPosition.from(scalar), .kind = if (is_promise) .promise else .object } },
        .promise => .{ .promise = .{ .answer_position = model.AnswerPosition.from(scalar), .path = try neutralPathBacking(reader, loc, 0) } },
        .sturdy => .{ .sturdy = .{
            .peer = try neutralPeerLocator(reader, (try reader.followStruct(loc, 0)) orelse return Error.MalformedFrame),
            .swissnum = try borrowedData(reader, loc, 1),
        } },
    };
}

fn hintEntryAt(reader: Reader, hl: model.view.HintList, index: usize) Error!model.HintEntry {
    const data_words: u16 = @truncate(hl.w1 >> 16);
    const ptr_words: u16 = @truncate(hl.w1);
    const stride = @as(usize, data_words) + ptr_words;
    const entry_loc = StructLoc{
        .data_idx = @as(usize, @intCast(hl.w0)) + index * stride,
        .data_words = data_words,
        .ptr_words = ptr_words,
    };
    return decodeHintEntry(reader, entry_loc);
}

/// Borrowed find over the typed entry list: decode entries in place until the
/// name matches without allocating. Authority-bearing callers validate the hint
/// map as a dictionary before lookup; this helper is the allocation-free lookup
/// primitive, not the policy.
fn capnpFindHint(hl: model.view.HintList, name: []const u8) model.view.Error!?model.HintValue {
    const count: usize = @intCast(hl.w2);
    if (count == 0) return null;
    const reader = shared.readerFromFrame(hl.bytes) catch return error.MalformedView;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const entry = hintEntryAt(reader, hl, index) catch return error.MalformedView;
        if (std.mem.eql(u8, entry.name, name)) return entry.value;
    }
    return null;
}

fn capnpValidateHintNamesUnique(hl: model.view.HintList) model.view.ProjectError!void {
    const count: usize = @intCast(hl.w2);
    if (count == 0) return;
    const reader = shared.readerFromFrame(hl.bytes) catch return error.MalformedView;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const entry = hintEntryAt(reader, hl, index) catch return error.MalformedView;
        var prior: usize = 0;
        while (prior < index) : (prior += 1) {
            const seen = hintEntryAt(reader, hl, prior) catch return error.MalformedView;
            if (std.mem.eql(u8, seen.name, entry.name)) return error.MalformedView;
        }
    }
}

/// One frame-header parse, then every entry — the handshake / `toOwned` path.
fn capnpMaterializeHintList(
    allocator: std.mem.Allocator,
    hl: model.view.HintList,
    wire_form: model.Hints.WireForm,
) model.view.Error!model.Hints {
    const count: usize = @intCast(hl.w2);
    if (count == 0) return .{ .wire_form = wire_form };
    const reader = shared.readerFromFrame(hl.bytes) catch return error.MalformedView;
    const entries = try allocator.alloc(model.HintEntry, count);
    errdefer allocator.free(entries);
    var initialized: usize = 0;
    errdefer for (entries[0..initialized]) |entry| model.freeHintEntry(allocator, entry);
    while (initialized < count) : (initialized += 1) {
        const borrowed = hintEntryAt(reader, hl, initialized) catch return error.MalformedView;
        // A repeated name is malformed: hints are a dictionary. The encoder
        // emits entries in model order with no uniqueness pass, so a duplicate
        // admitted here would be re-emitted as a dict pancake's own decoder
        // rejects.
        for (entries[0..initialized]) |seen| {
            if (std.mem.eql(u8, seen.name, borrowed.name)) return error.MalformedView;
        }
        const name = try allocator.dupe(u8, borrowed.name);
        errdefer allocator.free(name);
        entries[initialized] = .{
            .name = name,
            .value = try model.cloneHintValue(allocator, borrowed.value),
        };
    }
    return .{ .entries = entries, .wire_form = wire_form };
}

const capnp_hint_list_vtable = model.view.HintList.VTable{
    .materialize = capnpMaterializeHintList,
    .validate_unique_names = capnpValidateHintNamesUnique,
    .find = capnpFindHint,
};

fn decodeHintEntry(reader: Reader, loc: StructLoc) Error!model.HintEntry {
    const data0 = try reader.dataWord(loc, 0);
    const kind = try enumFromWire(shared.HintValueKind, data0);
    const name = try borrowedText(reader, loc, 0);
    const value: model.HintValue = switch (kind) {
        .string => .{ .string = try borrowedText(reader, loc, 1) },
        .bytes => .{ .bytes = try borrowedData(reader, loc, 1) },
        .boolean => .{ .boolean = data0 & shared.data0_flag != 0 },
        .integer => .{ .integer = @bitCast(try reader.dataWord(loc, 1)) },
    };
    return .{ .name = name, .value = value };
}

fn neutralPeerLocator(reader: Reader, loc: StructLoc) Error!model.view.PeerLocator {
    const empty_false = (try reader.dataWord(loc, 0)) & 1 != 0;
    const wire_form: model.Hints.WireForm = if (empty_false) .boolean_false else .map;
    const clist = (try compositeList(reader, loc, 2)) orelse {
        return .{
            .transport = try borrowedText(reader, loc, 0),
            .designator = try borrowedText(reader, loc, 1),
            .hints = .{ .empty = wire_form },
        };
    };
    if (clist.element_count == 0) {
        return .{
            .transport = try borrowedText(reader, loc, 0),
            .designator = try borrowedText(reader, loc, 1),
            .hints = .{ .empty = wire_form },
        };
    }
    // The hint list is packed lazily below, which means the eager walk reads
    // its header and nothing else. That is the one composite list a naive
    // charge pass never enumerates, while `capnpMaterializeHintList` later
    // dupes a name and a value for every entry, so N entries aliasing one blob
    // amplify a small frame into an arbitrarily large heap. A locator rides
    // `op:start-session`, and the handshake materializes its hints to rebuild
    // the signing domain, so that runs before the partner's signature is
    // checked. Charge the entries here, on the metered pass, so hints answer to
    // the same counter every other list does.
    //
    // Only when a budget is attached: the lazy re-walk that `toOwned` performs
    // runs unmetered by design, having already been proven to fit, and
    // repeating the enumeration there would be pure duplicate work.
    if (reader.budget != null) {
        for (0..clist.element_count) |i| {
            try reader.spend(1);
            _ = try decodeHintEntry(reader, clist.elem(i));
        }
    }

    // Cap'n Proto encodes hint entries on the PeerLocator; project them through
    // a lazy list so borrowed decode stays allocation-free and `toOwned`
    // materializes full fidelity (encode/decode symmetry for start-session).
    return .{
        .transport = try borrowedText(reader, loc, 0),
        .designator = try borrowedText(reader, loc, 1),
        .hints = .{
            .lazy = .{
                .wire_form = wire_form,
                .list = .{
                    .bytes = reader.bytes,
                    .w0 = clist.tag_idx + 1,
                    .w1 = (@as(u64, clist.data_words) << 16) | clist.ptr_words,
                    .w2 = clist.element_count,
                    .vtable = &capnp_hint_list_vtable,
                },
            },
        },
    };
}

fn neutralErrorView(reader: Reader, loc: StructLoc) Error!model.view.BreakReason {
    return .{ .message = try borrowedText(reader, loc, 0) };
}

fn neutralPipelineOp(reader: Reader, loc: StructLoc) Error!model.view.PipelineOp {
    const disc = try enumFromWire(PipelineOpKind, try reader.dataWord(loc, 0));
    return switch (disc) {
        .field => .{ .field = try borrowedText(reader, loc, 0) },
        .call => .{ .call = try neutralArgsBacking(reader, loc, 0) },
    };
}

/// Project a borrowed argument with full fidelity. Nested
/// `list` / `set` / `tagged` arms are lazy `Args` backings (no allocation).
fn neutralArgument(reader: Reader, loc: StructLoc) Error!model.view.Argument {
    const data0 = try reader.dataWord(loc, 0);
    const disc = try enumFromWire(ArgKind, data0);
    return switch (disc) {
        .bytes => .{ .bytes = try borrowedData(reader, loc, 0) },
        .symbol => .{ .symbol = try borrowedText(reader, loc, 0) },
        .reference => .{ .reference = try neutralReferenceView(reader, (try reader.followStruct(loc, 0)) orelse return Error.MalformedFrame) },
        .@"error" => .{ .@"error" = try neutralErrorView(reader, (try reader.followStruct(loc, 0)) orelse return Error.MalformedFrame) },
        .handoff => .{ .handoff = try neutralHandoffFromStruct(reader, (try reader.followStruct(loc, 0)) orelse return Error.MalformedFrame) },
        .string => .{ .string = try borrowedText(reader, loc, 0) },
        .integer => .{ .integer = @bitCast(try reader.dataWord(loc, 1)) },
        .boolean => .{ .boolean = data0 & shared.data0_flag != 0 },
        .list => .{ .list = try neutralArgsBacking(reader, loc, 0) },
        .void => .{ .void = {} },
        .float64 => .{ .float64 = @bitCast(try reader.dataWord(loc, 1)) },
        // Unlike the struct arm below, decode does not enforce a set's canonical
        // order or uniqueness here. The struct check is one cheap compare of
        // adjacent raw key bytes; a set's members are whole `Argument`s, so the
        // equivalent would eagerly encode each element just to compare — the
        // work the lazy backing exists to defer. Uniqueness is instead held one
        // layer up: `session.validate.checkInboundSetUniqueness` folds over the
        // full inbound argument tree (every deliver arg and resolve-fulfill
        // value, nested through list/set/tagged/struct), so a duplicate-element
        // set is refused there. Order needs no check: a set is unordered, this
        // codec re-canonicalizes on encode (`encodeArgumentSetList`), and set
        // equality is order-independent, so a non-canonically-ordered set is a
        // harmless spelling, not a distinct value.
        .set => .{ .set = try neutralArgsBacking(reader, loc, 0) },
        .tagged => blk: {
            const tagged_loc = (try reader.followStruct(loc, 0)) orelse return Error.MalformedFrame;
            break :blk .{ .tagged = .{
                .tag = try borrowedText(reader, tagged_loc, 0),
                .value = try neutralArgsBacking(reader, tagged_loc, 1),
            } };
        },
        .keyword => .{ .keyword = try borrowedText(reader, loc, 0) },
        .@"struct" => .{ .@"struct" = try neutralStructBacking(reader, loc, 0) },
        .big_integer => blk: {
            const big = model.BigInteger{
                .negative = data0 & shared.data0_flag != 0,
                .digits = try borrowedData(reader, loc, 0),
            };
            // The codec owns parse validity: leading zeros, non-digits, or a
            // magnitude the `integer` arm should carry are malformed bytes,
            // mirroring the Syrup decoder's canonical-digit refusal.
            if (!big.isCanonical()) return Error.MalformedFrame;
            break :blk .{ .big_integer = big };
        },
    };
}

const neutral_struct_vtable = model.view.StructEntries.VTable{ .len = neutralStructLen, .at = neutralStructAt, .next = neutralStructNext };

fn neutralStructLen(ctx: model.view.StructEntries.Ctx) model.view.ProjectError!usize {
    return @intCast(ctx.w2);
}

fn neutralStructAt(ctx: model.view.StructEntries.Ctx, index: usize) model.view.ProjectError!model.view.StructEntry {
    if (index >= ctx.w2) return error.MalformedView;
    const reader = shared.readerFromFrame(ctx.bytes) catch return error.MalformedView;
    return neutralStructEntry(reader, compositeElem(ctx, index)) catch return error.MalformedView;
}

fn neutralStructNext(ctx: model.view.StructEntries.Ctx, cursor: *u64) model.view.ProjectError!?model.view.StructEntry {
    if (cursor.* >= ctx.w2) return null;
    const out = try neutralStructAt(ctx, @intCast(cursor.*));
    cursor.* += 1;
    return out;
}

/// Borrowed (key, value) entry from one composite-list element: key text at
/// pointer 0, value Argument struct at pointer 1.
fn neutralStructEntry(reader: Reader, elem: StructLoc) Error!model.view.StructEntry {
    const key = try borrowedText(reader, elem, 0);
    const value_loc = (try reader.followStruct(elem, 1)) orelse return Error.MalformedFrame;
    return .{ .key = key, .value = try neutralArgument(reader, value_loc) };
}

/// Build the lazy struct backing, enforcing the OCapN Struct key rule at the
/// codec boundary (ADR-0046 / Model.md § Struct): keys must be pairwise
/// non-Equal, and pancake's own capnp encoder emits them sorted ascending by
/// raw key bytes (`canonicalStructOrder`). Decode therefore requires strictly
/// ascending keys — one comparison of each key against its predecessor, the
/// same O(n) refusal the Syrup decoder applies (`sliceStructNeutral`). A
/// duplicate is never strictly ascending, so this refuses it without the
/// all-pairs scan an attacker could drive to n² over a frame-cap-many struct.
/// Borrowed slices only, no allocation; width is bounded by the frame cap.
fn neutralStructBacking(reader: Reader, loc: StructLoc, i: u16) Error!model.view.StructEntries {
    const clist = (try compositeList(reader, loc, i)) orelse
        return model.view.StructEntries.fromBacking(.{ .bytes = reader.bytes }, &neutral_struct_vtable);
    var idx: usize = 1;
    while (idx < clist.element_count) : (idx += 1) {
        const key = try borrowedText(reader, clist.elem(idx), 0);
        const prior = try borrowedText(reader, clist.elem(idx - 1), 0);
        if (std.mem.order(u8, prior, key) != .lt) return Error.MalformedFrame;
    }
    return model.view.StructEntries.fromBacking(ctxFromComposite(reader, clist), &neutral_struct_vtable);
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
    const peer_loc = (try reader.followStruct(loc, 1)) orelse return Error.MalformedFrame;
    const peer = try neutralPeerLocator(reader, peer_loc);
    return .{
        .recipient_key = try borrowedData(reader, loc, 0),
        .exporter = peer,
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
        .@"break" => .{ .@"break" = try neutralErrorView(reader, inner) },
    };
}

fn neutralStartSession(reader: Reader, body: StructLoc) Error!model.view.StartSession {
    const version_text = try borrowedText(reader, body, 0);
    return .{
        // A token this build does not know decodes as null; `session.validate`
        // is what refuses it, and refuses it as a version mismatch.
        .captp_version = model.CaptpVersion.fromWireString(version_text),
        .session_pubkey = try borrowedData(reader, body, 1),
        .acceptable_location = try neutralPeerLocator(reader, (try reader.followStruct(body, 2)) orelse return Error.MalformedFrame),
        .acceptable_location_sig = .{ .raw = try borrowedData(reader, body, 3) },
    };
}

/// Project the borrowed codec-neutral `model.view.Body` over `frame`.
/// Decode one delimited frame.
///
/// The frame must be exactly the length its own header declares. Syrup refuses
/// trailing bytes the same way (`expectEnd`), and without the rule two
/// different byte strings decode to the same message, so anything that treats
/// a frame's bytes as its identity ends up with two names for one thing. The
/// framing layer is where a buffer legitimately holds more than one frame;
/// `shared.readerFromFrame` stays lenient for it, and this is the entry point
/// that has already been handed a single frame.
pub fn decodeBody(frame: foundation.FrameView) Error!model.view.Body {
    return decodeBodyForProfile(.v1_0, frame);
}

pub fn decodeBodyForProfile(profile: model.CaptpVersion, frame: foundation.FrameView) Error!model.view.Body {
    const view = try decodeMessageView(frame);
    try shared.expectExactFrameLength(frame.bytes);
    if (profile == .next and view.kind == .resolve) return Error.UnsupportedMessage;
    if (profile == .next and view.kind == .deliver) {
        const flags = try view.reader.dataWord(view.body, 0);
        if (flags & shared.deliver_has_resolve_me != 0) return Error.UnsupportedMessage;
    }
    return neutralBodyForProfile(view, profile);
}

fn validateBodyForFraming(frame: foundation.FrameView) Error!void {
    const view = try decodeMessageView(frame);
    try shared.expectExactFrameLength(frame.bytes);
    var budget: usize = shared.traversalBudget(view.reader.seg_words);
    try chargeBody(view.reader.withBudget(&budget), view.kind, view.body, 0);
    if (view.kind == .listen) {
        const raw = try view.reader.dataWord(view.body, 0);
        if (raw > 3) return Error.MalformedFrame;
        return;
    }
    _ = try projectBody(view.reader, view.kind, view.body);
}

/// Decode-time recursion bound for the eager traversal charge pass, the capnp
/// sibling of the Syrup decoder's `max_decode_nesting`. The charge pass walks
/// the whole tree once (following every aliasing edge) to spend the per-frame
/// budget, so it recurses one native frame per nesting level; without a bound a
/// deeply nested frame would overflow the stack here before the budget or the
/// session's nesting cap could speak. It sits above `model.max_value_depth`
/// (256) so it never refuses a frame the owned materializer would still admit:
/// a frame deeper than 256 but under this bound charges fine and is refused by
/// `toOwnedSliceDepth` as `MalformedView`, exactly as before this pass existed.
/// `codec/mod.zig` pins it equal to the Syrup bound and above
/// `model.max_value_depth` at compile time, so the two codecs' refusal depth
/// cannot drift apart.
pub const max_charge_depth: usize = 512;

// ── Eager traversal-budget charge pass (the remote-DoS bound) ────────────────
//
// `decodeBody`/`toOwned` are lazy: the borrowed backings re-resolve composite
// elements through `neutralArgsAt` on demand, and Cap'n Proto pointers may
// alias/overlap, so a small frame whose composite-list elements resolve to one
// shared child (repeated D levels, K children each) drives K^D node visits on
// the later walk — a remote, unauthenticated DoS on the single-threaded turn
// loop. `chargeBody` closes it at decode time: it walks the whole logical tree
// once with a single per-frame word budget (seeded from the segment size,
// spent in `Reader.word`/`byteSlice` and per composite element resolved), so an
// aliasing DAG that re-reads the same words burns the one shared counter and is
// refused in bounded time — before any borrowed view escapes `neutralBody`.
// Because the charge pass follows the same edges the lazy walk would, a frame
// that passes it has a bounded total node count, so the later lazy walk is
// bounded too. A legitimate tree reads each segment word a small constant
// number of times, well under the budget. `chargeBody` mirrors `projectBody`'s
// descent arm-for-arm; the exhaustive `Kind`/`ArgKind`/`RefTag`/
// `ResolutionKind` switches make a new wire arm a compile error here, and the
// round-trip tests catch any pointer-index drift (a wrong follow errors on a
// valid frame).

/// Spend one node plus recurse into an `Argument`'s composite children,
/// mirroring `neutralArgument`. `neutralArgument` reads and validates this
/// node's own words (charging through the metered reader); the switch adds the
/// recursion the lazy backings defer. `depth` is the value-nesting level; it
/// increments once at each composite descent so it tracks `toOwnedSliceDepth`.
fn chargeArgument(reader: Reader, loc: StructLoc, depth: usize) Error!void {
    if (depth > max_charge_depth) return Error.MalformedFrame;
    const arg = try neutralArgument(reader, loc);
    switch (arg) {
        .list, .set => try chargeArgsField(reader, loc, 0, depth + 1),
        .tagged => {
            const tagged_loc = (try reader.followStruct(loc, 0)) orelse return Error.MalformedFrame;
            try chargeArgsField(reader, tagged_loc, 1, depth + 1);
        },
        .@"struct" => try chargeStructField(reader, loc, 0, depth + 1),
        .reference => {
            const ref_loc = (try reader.followStruct(loc, 0)) orelse return Error.MalformedFrame;
            const disc = try enumFromWire(RefTag, try reader.dataWord(ref_loc, 0));
            if (disc == .promise) try chargePathField(reader, ref_loc, 0, depth + 1);
        },
        // Leaves and the fixed-depth handoff/error arms are fully read (and so
        // charged) by `neutralArgument`; none carries a composite-list vector.
        .bytes, .symbol, .@"error", .handoff, .string, .integer, .boolean, .void, .float64, .keyword, .big_integer => {},
    }
}

/// Charge and recurse a reference: read+validate the node, then walk a promise
/// reference's pipeline path (the only reference arm with a composite vector).
fn chargeReference(reader: Reader, loc: StructLoc, depth: usize) Error!void {
    if (depth > max_charge_depth) return Error.MalformedFrame;
    _ = try neutralReferenceView(reader, loc);
    const disc = try enumFromWire(RefTag, try reader.dataWord(loc, 0));
    if (disc == .promise) try chargePathField(reader, loc, 0, depth + 1);
}

/// Charge each element of a composite `Args` list at pointer `i`. The caller
/// has already accounted this list's nesting level in `depth`, so each element
/// is charged at that same level.
fn chargeArgsField(reader: Reader, loc: StructLoc, i: u16, depth: usize) Error!void {
    if (depth > max_charge_depth) return Error.MalformedFrame;
    const clist = (try compositeList(reader, loc, i)) orelse return;
    var idx: usize = 0;
    while (idx < clist.element_count) : (idx += 1) {
        try reader.spend(1);
        try chargeArgument(reader, clist.elem(idx), depth);
    }
}

/// Charge each element of a composite `PipelinePath` list at pointer `i`.
fn chargePathField(reader: Reader, loc: StructLoc, i: u16, depth: usize) Error!void {
    if (depth > max_charge_depth) return Error.MalformedFrame;
    const clist = (try compositeList(reader, loc, i)) orelse return;
    var idx: usize = 0;
    while (idx < clist.element_count) : (idx += 1) {
        try reader.spend(1);
        const op = try neutralPipelineOp(reader, clist.elem(idx));
        switch (op) {
            .field => {},
            .call => try chargeArgsField(reader, clist.elem(idx), 0, depth + 1),
        }
    }
}

/// Charge each (key, value) entry of a composite struct list at pointer `i`,
/// recursing into each value `Argument` at the list's already-accounted level.
fn chargeStructField(reader: Reader, loc: StructLoc, i: u16, depth: usize) Error!void {
    if (depth > max_charge_depth) return Error.MalformedFrame;
    const clist = (try compositeList(reader, loc, i)) orelse return;
    var idx: usize = 0;
    while (idx < clist.element_count) : (idx += 1) {
        try reader.spend(1);
        const elem = clist.elem(idx);
        _ = try borrowedText(reader, elem, 0);
        const value_loc = (try reader.followStruct(elem, 1)) orelse return Error.MalformedFrame;
        try chargeArgument(reader, value_loc, depth);
    }
}

/// Walk the whole logical tree once against the metered `reader`, spending its
/// per-frame budget so an aliasing DAG is refused before any borrowed view
/// escapes. Mirrors `projectBody`; the non-recursive arms delegate to it so
/// their leaf reads are charged and validated identically. Dispatch is
/// exhaustive over `Kind` (the Cap'n Proto wire ids in `shared.zig`).
fn chargeBody(reader: Reader, kind: Kind, body: StructLoc, depth: usize) Error!void {
    switch (kind) {
        .deliver => try chargeDeliverBody(reader, body, depth),
        .resolve => try chargeResolveBody(reader, body, depth),
        .listen => try chargeListenBody(reader, body, depth),
        .get, .untag => try chargeReceiverBody(reader, body, depth),
        .index => {
            try chargeReceiverBody(reader, body, depth);
            _ = try projectIndexValue(reader, body);
        },
        // No composite-list amplification vector of their own. Delegate to
        // `projectBody` so the metered reader charges and validates every leaf
        // read; the hint list a `start_session` locator carries is charged by
        // `neutralPeerLocator` on this same metered pass.
        .gc_export, .gc_answer, .abort, .start_session => _ = try projectBody(reader, kind, body),
    }
}

fn chargeDeliverBody(reader: Reader, body: StructLoc, depth: usize) Error!void {
    const target = (try reader.followStruct(body, 0)) orelse return Error.MalformedFrame;
    try chargeReference(reader, target, depth);
    try chargeArgsField(reader, body, 1, depth);
    const flags = try reader.dataWord(body, 0);
    if (flags & shared.deliver_has_resolve_me != 0) {
        if (try reader.followStruct(body, 2)) |ref_loc| try chargeReference(reader, ref_loc, depth);
    }
}

fn chargeResolveBody(reader: Reader, body: StructLoc, depth: usize) Error!void {
    const res_loc = (try reader.followStruct(body, 0)) orelse return Error.MalformedFrame;
    const disc = try enumFromWire(ResolutionKind, try reader.dataWord(res_loc, 0));
    const arm = (try reader.followStruct(res_loc, 0)) orelse return Error.MalformedFrame;
    switch (disc) {
        .fulfill => try chargeArgument(reader, arm, depth),
        .@"break" => _ = try neutralErrorView(reader, arm),
    }
}

fn chargeListenBody(reader: Reader, body: StructLoc, depth: usize) Error!void {
    try chargeReference(reader, (try reader.followStruct(body, 0)) orelse return Error.MalformedFrame, depth);
    try chargeReference(reader, (try reader.followStruct(body, 1)) orelse return Error.MalformedFrame, depth);
}

fn chargeReceiverBody(reader: Reader, body: StructLoc, depth: usize) Error!void {
    try chargeReference(reader, (try reader.followStruct(body, 0)) orelse return Error.MalformedFrame, depth);
}

/// The one neutral body walk, shared by `decodeBody` and `MessageView.toOwned`
/// so there is no second decoder to drift. Every path that hands out a borrowed
/// body first runs the eager traversal-budget charge pass, so a frame whose
/// aliasing composite lists would amplify the later lazy walk is refused here,
/// in bounded time, on the inbound turn loop (see the charge-pass note above).
fn neutralBody(view: MessageView) Error!model.view.Body {
    return neutralBodyForProfile(view, .v1_0);
}

fn neutralBodyForProfile(view: MessageView, profile: model.CaptpVersion) Error!model.view.Body {
    var budget: usize = shared.traversalBudget(view.reader.seg_words);
    try chargeBody(view.reader.withBudget(&budget), view.kind, view.body, 0);
    if (view.kind == .listen) return projectListenBodyForProfile(view.reader, view.body, profile);
    return projectBody(view.reader, view.kind, view.body);
}

/// One body projector per Cap'n Proto `Kind` wire id — the same comptime table
/// shape Syrup uses with `decoderFor` / `messageOp`. `Kind`'s explicit `enum(u16)`
/// values in `shared.zig` are the stable wire discriminants; `inline else` plus
/// `bodyProjector` make a new arm a compile error in both places at once.
const BodyProjector = *const fn (reader: Reader, body: StructLoc) Error!model.view.Body;

fn bodyProjector(comptime kind: Kind) BodyProjector {
    return switch (kind) {
        .deliver => projectDeliverBody,
        .resolve => projectResolveBody,
        .gc_export => projectGcExportBody,
        .gc_answer => projectGcAnswerBody,
        .abort => projectAbortBody,
        .listen => projectListenBody,
        .get => projectGetBody,
        .index => projectIndexBody,
        .untag => projectUntagBody,
        .start_session => projectStartSessionBody,
    };
}

/// Project the borrowed body arm-for-arm. Lazy: composite sequences become
/// backings walked on demand. `neutralBody` runs `chargeBody` first, so this
/// only runs on a frame already proven to fit the traversal budget.
fn projectBody(reader: Reader, kind: Kind, body: StructLoc) Error!model.view.Body {
    return switch (kind) {
        inline else => |k| bodyProjector(k)(reader, body),
    };
}

fn projectDeliverBody(reader: Reader, body: StructLoc) Error!model.view.Body {
    const flags = try reader.dataWord(body, 0);
    var resolve_me: ?model.view.Reference = null;
    if (flags & shared.deliver_has_resolve_me != 0) {
        if (try reader.followStruct(body, 2)) |ref_loc| resolve_me = try neutralReferenceView(reader, ref_loc);
    }
    return .{ .deliver = .{
        .target = try neutralReferenceView(reader, (try reader.followStruct(body, 0)) orelse return Error.MalformedFrame),
        .args = try neutralArgsBacking(reader, body, 1),
        .answer = if (flags & shared.deliver_has_answer != 0) model.AnswerPosition.from(try reader.dataWord(body, 1)) else null,
        .resolve_me_desc = resolve_me,
    } };
}

fn projectResolveBody(reader: Reader, body: StructLoc) Error!model.view.Body {
    return .{ .resolve = .{
        .answer = model.AnswerPosition.from(try reader.dataWord(body, 0)),
        .resolution = try neutralResolution(reader, (try reader.followStruct(body, 0)) orelse return Error.MalformedFrame),
    } };
}

fn projectGcExportBody(reader: Reader, body: StructLoc) Error!model.view.Body {
    return .{ .gc_export = .{
        .positions = try neutralPositionsBacking(reader, body, 0),
        .deltas = try neutralPositionsBacking(reader, body, 1),
    } };
}

fn projectGcAnswerBody(reader: Reader, body: StructLoc) Error!model.view.Body {
    return .{ .gc_answer = .{ .positions = try neutralPositionsBacking(reader, body, 0) } };
}

fn projectAbortBody(reader: Reader, body: StructLoc) Error!model.view.Body {
    return .{ .abort = .{
        .kind = try enumFromWire(model.AbortKind, try reader.dataWord(body, 0)),
        .message = try borrowedText(reader, body, 0),
    } };
}

fn projectListenBody(reader: Reader, body: StructLoc) Error!model.view.Body {
    return projectListenBodyForProfile(reader, body, .v1_0);
}

fn projectListenBodyForProfile(reader: Reader, body: StructLoc, profile: model.CaptpVersion) Error!model.view.Body {
    const raw = try reader.dataWord(body, 0);
    const mode: model.ListenMode = switch (profile) {
        .v1_0 => switch (raw) {
            0 => .settling_only,
            1 => .shortening_or_settling,
            else => return Error.MalformedFrame,
        },
        .next => model.ListenMode.fromInt(raw) orelse return Error.MalformedFrame,
    };
    return projectListenFields(reader, body, mode);
}

fn projectListenFields(reader: Reader, body: StructLoc, mode: model.ListenMode) Error!model.view.Body {
    return .{ .listen = .{
        .target = try neutralReferenceView(reader, (try reader.followStruct(body, 0)) orelse return Error.MalformedFrame),
        .listener = try neutralReferenceView(reader, (try reader.followStruct(body, 1)) orelse return Error.MalformedFrame),
        .mode = mode,
    } };
}

fn projectGetBody(reader: Reader, body: StructLoc) Error!model.view.Body {
    return .{ .get = .{
        .receiver = try neutralReferenceView(reader, (try reader.followStruct(body, 0)) orelse return Error.MalformedFrame),
        .field = try borrowedText(reader, body, 1),
        .answer = model.AnswerPosition.from(try reader.dataWord(body, 0)),
    } };
}

fn projectIndexBody(reader: Reader, body: StructLoc) Error!model.view.Body {
    return .{ .index = .{
        .receiver = try neutralReferenceView(reader, (try reader.followStruct(body, 0)) orelse return Error.MalformedFrame),
        .index = try projectIndexValue(reader, body),
        .answer = model.AnswerPosition.from(try reader.dataWord(body, 1)),
    } };
}

fn projectIndexValue(reader: Reader, body: StructLoc) Error!model.Integer {
    const flags = try reader.dataWord(body, 2);
    if (flags & ~(shared.index_big_integer | shared.index_negative) != 0) return Error.MalformedFrame;
    if (flags & shared.index_big_integer == 0) {
        if (flags != 0) return Error.MalformedFrame;
        if (!try reader.pointerIsNull(body, 1)) return Error.MalformedFrame;
        return .{ .integer = @bitCast(try reader.dataWord(body, 0)) };
    }
    if (try reader.dataWord(body, 0) != 0) return Error.MalformedFrame;
    const big: model.BigInteger = .{
        .negative = flags & shared.index_negative != 0,
        .digits = try borrowedData(reader, body, 1),
    };
    if (!big.isCanonical()) return Error.MalformedFrame;
    return .{ .big_integer = big };
}

fn projectUntagBody(reader: Reader, body: StructLoc) Error!model.view.Body {
    return .{ .untag = .{
        .receiver = try neutralReferenceView(reader, (try reader.followStruct(body, 0)) orelse return Error.MalformedFrame),
        .tag = try borrowedText(reader, body, 1),
        .answer = model.AnswerPosition.from(try reader.dataWord(body, 0)),
    } };
}

fn projectStartSessionBody(reader: Reader, body: StructLoc) Error!model.view.Body {
    return .{ .start_session = try neutralStartSession(reader, body) };
}
