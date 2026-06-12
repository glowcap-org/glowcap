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

const RefKind = shared.RefKind;
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
    const body = decodeBody(.{ .shape = .word, .bytes = bytes[0..frame_len] }) catch return .malformed;
    return .{ .decoded = .{ .body = body, .consumed = frame_len } };
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

/// Project a borrowed reference in the receiver's perspective (the ADR-0010
/// flip).
fn neutralReferenceView(reader: Reader, loc: StructLoc) Error!model.view.Reference {
    const data0 = try reader.dataWord(loc, 0);
    const disc = try enumFromWire(RefKind, data0);
    const scalar = try reader.dataWord(loc, 1);
    const is_promise = data0 & shared.data0_flag != 0;
    return switch (disc) {
        .near => .{ .far = .{ .import_position = scalar, .kind = if (is_promise) .promise else .object } },
        .far => .{ .near = .{ .export_position = scalar, .kind = if (is_promise) .promise else .object } },
        .promise => .{ .promise = .{ .answer_position = scalar, .path = try neutralPathBacking(reader, loc, 0) } },
        .sturdy => .{ .sturdy = .{
            .peer = try neutralPeerLocator(reader, (try reader.followStruct(loc, 0)) orelse return Error.MalformedFrame),
            .swissnum = try borrowedData(reader, loc, 1),
        } },
    };
}

fn neutralPeerLocator(reader: Reader, loc: StructLoc) Error!model.view.PeerLocator {
    const empty_false = (try reader.dataWord(loc, 0)) & 1 != 0;
    return .{
        .transport = try borrowedData(reader, loc, 0),
        .designator = try borrowedData(reader, loc, 1),
        .hints = if (empty_false) model.Hints.emptyFalse() else model.Hints.emptyMap(),
    };
}

fn neutralErrorView(reader: Reader, loc: StructLoc) Error!model.view.BreakReason {
    return .{ .message = try borrowedData(reader, loc, 0) };
}

fn neutralPipelineOp(reader: Reader, loc: StructLoc) Error!model.view.PipelineOp {
    const disc = try enumFromWire(PipelineOpKind, try reader.dataWord(loc, 0));
    return switch (disc) {
        .field => .{ .field = try borrowedData(reader, loc, 0) },
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
        .symbol => .{ .symbol = try borrowedData(reader, loc, 0) },
        .reference => .{ .reference = try neutralReferenceView(reader, (try reader.followStruct(loc, 0)) orelse return Error.MalformedFrame) },
        .@"error" => .{ .@"error" = try neutralErrorView(reader, (try reader.followStruct(loc, 0)) orelse return Error.MalformedFrame) },
        .handoff => .{ .handoff = try neutralHandoffFromStruct(reader, (try reader.followStruct(loc, 0)) orelse return Error.MalformedFrame) },
        .string => .{ .string = try borrowedData(reader, loc, 0) },
        .integer => .{ .integer = @bitCast(try reader.dataWord(loc, 1)) },
        .boolean => .{ .boolean = data0 & shared.data0_flag != 0 },
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
    const key = try borrowedData(reader, elem, 0);
    const value_loc = (try reader.followStruct(elem, 1)) orelse return Error.MalformedFrame;
    return .{ .key = key, .value = try neutralArgument(reader, value_loc) };
}

/// Build the lazy struct backing, refusing duplicate keys up front. The walk
/// enforces the OCapN Struct key rule at the codec boundary (ADR-0046 /
/// Model.md § Struct): every key must be non-Equal to every other, so each
/// entry's key — borrowed text at pointer 0, a String by construction — is
/// compared against every prior key the moment the backing is built. Borrowed
/// slices only, no allocation — the same eager codec-boundary refusal the
/// Syrup decoder applies while scanning a dict; width is bounded by the frame
/// cap.
fn neutralStructBacking(reader: Reader, loc: StructLoc, i: u16) Error!model.view.StructEntries {
    const clist = (try compositeList(reader, loc, i)) orelse
        return model.view.StructEntries.fromBacking(.{ .bytes = reader.bytes }, &neutral_struct_vtable);
    var idx: usize = 1;
    while (idx < clist.element_count) : (idx += 1) {
        const key = try borrowedData(reader, clist.elem(idx), 0);
        var prior: usize = 0;
        while (prior < idx) : (prior += 1) {
            if (std.mem.eql(u8, key, try borrowedData(reader, clist.elem(prior), 0))) return Error.MalformedFrame;
        }
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
        .@"break" => .{ .@"break" = try neutralErrorView(reader, inner) },
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

/// Project the borrowed codec-neutral `model.view.Body` over `frame`.
pub fn decodeBody(frame: foundation.FrameView) Error!model.view.Body {
    return neutralBody(try decodeMessageView(frame));
}

/// The one neutral body walk, shared by `decodeBody` and
/// `MessageView.toOwned` so there is no second decoder to drift.
fn neutralBody(view: MessageView) Error!model.view.Body {
    const reader = view.reader;
    const body = view.body;
    return switch (view.kind) {
        .deliver => blk: {
            const flags = try reader.dataWord(body, 0);
            var resolve_me: ?model.view.Reference = null;
            if (flags & shared.deliver_has_resolve_me != 0) {
                if (try reader.followStruct(body, 2)) |ref_loc| resolve_me = try neutralReferenceView(reader, ref_loc);
            }
            break :blk .{ .deliver = .{
                .target = try neutralReferenceView(reader, (try reader.followStruct(body, 0)) orelse return Error.MalformedFrame),
                .args = try neutralArgsBacking(reader, body, 1),
                .answer = if (flags & shared.deliver_has_answer != 0) try reader.dataWord(body, 1) else null,
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
            .kind = try enumFromWire(model.AbortKind, try reader.dataWord(body, 0)),
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
        .untag => .{ .untag = .{
            .receiver = try neutralReferenceView(reader, (try reader.followStruct(body, 0)) orelse return Error.MalformedFrame),
            .tag = try borrowedData(reader, body, 1),
            .answer = try reader.dataWord(body, 0),
        } },
        .start_session => .{ .start_session = try neutralStartSession(reader, body) },
        .handoff => .{ .handoff = try neutralHandoffFromStruct(reader, body) },
    };
}
