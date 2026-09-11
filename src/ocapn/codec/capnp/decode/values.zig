//! Allocation-free Cap'n Proto projection of borrowed semantic values.
//!
//! This leaf owns the one Reference, Argument, collection-backing, locator,
//! hint, handoff, Resolution, and StartSession vocabulary used by both body
//! projection and the eager charge pass. It borrows directly from one bounded
//! Reader and owns no session authority. The parent decoder optionally observes
//! hint lists while projecting so traversal-budget spending stays in
//! `decode.zig` without a second walk.

const std = @import("std");
const model = @import("model");
const shared = @import("../shared.zig");

const Error = shared.Error;
const RefTag = shared.RefTag;
const ArgKind = shared.ArgKind;
const ResolutionKind = shared.ResolutionKind;
const HandoffKind = shared.HandoffKind;
const StructLoc = shared.StructLoc;
const CompositeList = shared.CompositeList;
const followList = shared.followList;
const enumFromWire = shared.enumFromWire;
const compositeList = shared.compositeList;
const Reader = shared.Reader;

const HintListObserver = *const fn (reader: Reader, hints: CompositeList) Error!void;

// ── Decode: borrowed codec-neutral view projection (ADR-0026) ────────────────
//
// The parent decoder projects the shared `model.view.Body` directly over the
// frame's words — the codec-neutral shape the engine dispatches on, identical
// to the one [`syrup.decodeBody`](../../syrup/decode.zig) produces. Copies nothing:
// scalar and reference fields read straight from the words, borrowed text/bytes
// slice into the segment (`byteSlice`), and the unbounded sequences (`Args`,
// `PositionList`) are reached through inline vtable backings —
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
    // and `count` are untrusted, so prove the run fits the segment up
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
    return neutralArgument(reader, compositeElem(ctx, index), null) catch return error.MalformedView;
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

pub fn neutralArgsBacking(reader: Reader, loc: StructLoc, i: u16) Error!model.view.Args {
    return model.view.Args.fromBacking(try compositeListCtx(reader, loc, i), &neutral_args_vtable);
}

pub fn neutralPositionsBacking(reader: Reader, loc: StructLoc, i: u16) Error!model.view.PositionList {
    return model.view.PositionList.fromBacking(try primitiveListCtx(reader, loc, i), &neutral_positions_vtable);
}

/// Borrow text or bytes as a slice straight into the segment, with no copy.
pub fn borrowedData(reader: Reader, loc: StructLoc, i: u16) Error![]const u8 {
    const list = try followList(reader, loc, i);
    if (list.count == 0) return &.{};
    return reader.byteSlice(list.data_idx, list.count);
}

/// Borrow a model String or Symbol directly from the frame and reject malformed
/// Unicode at the codec boundary. Validation scans in place and never allocates
/// or copies; raw ByteArray fields continue to use `borrowedData`.
pub fn borrowedText(reader: Reader, loc: StructLoc, i: u16) Error![]const u8 {
    const text = try borrowedData(reader, loc, i);
    if (!std.unicode.utf8ValidateSlice(text)) return Error.MalformedFrame;
    return text;
}

/// Project a borrowed reference in the receiver's perspective (the ADR-0010
/// flip).
pub fn neutralReferenceView(reader: Reader, loc: StructLoc, comptime observe_hints: ?HintListObserver) Error!model.view.Reference {
    const data0 = try reader.dataWord(loc, 0);
    const disc = try enumFromWire(RefTag, data0);
    const scalar = try reader.dataWord(loc, 1);
    const is_promise = data0 & shared.data0_flag != 0;
    return switch (disc) {
        .near => .{ .far = .{ .import_position = model.ImportPosition.from(scalar), .kind = if (is_promise) .promise else .object } },
        .far => .{ .near = .{ .export_position = model.ExportPosition.from(scalar), .kind = if (is_promise) .promise else .object } },
        // A promise owns no pointer fields. Rejecting a non-null slot prevents
        // unsupported derived semantics from collapsing silently to the root
        // `desc:answer`.
        .promise => if (!try reader.pointerIsNull(loc, 0))
            Error.UnsupportedReference
        else
            .{ .promise = .{ .answer_position = model.AnswerPosition.from(scalar) } },
        .sturdy => .{ .sturdy = .{
            .peer = try neutralPeerLocator(reader, (try reader.followStruct(loc, 0)) orelse return Error.MalformedFrame, observe_hints),
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
    return hintEntry(reader, entry_loc);
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

fn capnpValidateHintShape(
    hl: model.view.HintList,
    wire_form: model.Hints.WireForm,
) model.view.ProjectError!void {
    const count: usize = @intCast(hl.w2);
    if (count == 0) return;
    if (count > model.max_locator_hint_count or wire_form == .boolean_false)
        return error.MalformedView;
    const reader = shared.readerFromFrame(hl.bytes) catch return error.MalformedView;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const entry = hintEntryAt(reader, hl, index) catch return error.MalformedView;
        model.validateHintName(entry.name) catch return error.MalformedView;
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
    try capnpValidateHintShape(hl, wire_form);
    const reader = shared.readerFromFrame(hl.bytes) catch return error.MalformedView;
    const entries = try allocator.alloc(model.HintEntry, count);
    errdefer allocator.free(entries);
    var initialized: usize = 0;
    errdefer for (entries[0..initialized]) |entry| model.freeHintEntry(allocator, entry);
    while (initialized < count) : (initialized += 1) {
        const borrowed = hintEntryAt(reader, hl, initialized) catch return error.MalformedView;
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
    .validate_shape = capnpValidateHintShape,
    .find = capnpFindHint,
};

pub fn hintEntry(reader: Reader, loc: StructLoc) Error!model.HintEntry {
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

fn neutralPeerLocator(reader: Reader, loc: StructLoc, comptime observe_hints: ?HintListObserver) Error!model.view.PeerLocator {
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
    if (clist.element_count > model.max_locator_hint_count)
        return Error.MalformedFrame;
    // The eager pass supplies an observer that owns enumeration and budget
    // spending. Ordinary borrowed projection supplies null, so the later lazy
    // walk neither repeats the enumeration nor charges twice.
    if (observe_hints) |observe| try observe(reader, clist);
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

pub fn neutralErrorView(reader: Reader, loc: StructLoc) Error!model.view.BreakReason {
    return .{ .message = try borrowedText(reader, loc, 0) };
}

/// Project a borrowed argument with full fidelity. Nested
/// `list` / `set` / `tagged` arms are lazy `Args` backings (no allocation).
pub fn neutralArgument(reader: Reader, loc: StructLoc, comptime observe_hints: ?HintListObserver) Error!model.view.Argument {
    const data0 = try reader.dataWord(loc, 0);
    const disc = try enumFromWire(ArgKind, data0);
    return switch (disc) {
        .bytes => .{ .bytes = try borrowedData(reader, loc, 0) },
        .symbol => .{ .symbol = try borrowedText(reader, loc, 0) },
        .reference => .{ .reference = try neutralReferenceView(reader, (try reader.followStruct(loc, 0)) orelse return Error.MalformedFrame, observe_hints) },
        .@"error" => .{ .@"error" = try neutralErrorView(reader, (try reader.followStruct(loc, 0)) orelse return Error.MalformedFrame) },
        .handoff => .{ .handoff = try neutralHandoffFromStruct(reader, (try reader.followStruct(loc, 0)) orelse return Error.MalformedFrame, observe_hints) },
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
        // layer up: `session/validate/passable.zig`'s set-uniqueness fold walks the
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
    return .{ .key = key, .value = try neutralArgument(reader, value_loc, null) };
}

/// Build the lazy struct backing, enforcing the OCapN Struct key rule at the
/// codec boundary (ADR-0046 / Model.md § Struct): keys must be pairwise
/// non-Equal, and glowcap's own capnp encoder emits them sorted ascending by
/// raw key bytes (`canonicalStructOrder`). Decode therefore requires strictly
/// ascending keys — one comparison of each key against its predecessor, the
/// same O(n) refusal the Syrup decoder applies (`sliceStructNeutral`). A
/// duplicate is never strictly ascending, so this refuses it without the
/// all-pairs scan a peer could drive to n² over a frame-cap-many struct.
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

fn neutralHandoffFromStruct(reader: Reader, loc: StructLoc, comptime observe_hints: ?HintListObserver) Error!model.view.Handoff {
    const disc = try enumFromWire(HandoffKind, try reader.dataWord(loc, 0));
    const inner = (try reader.followStruct(loc, 0)) orelse return Error.MalformedFrame;
    return switch (disc) {
        .give => .{ .give = try neutralHandoffGive(reader, inner, observe_hints) },
        .receive => try neutralHandoffReceive(reader, inner, observe_hints),
    };
}

fn neutralHandoffGive(reader: Reader, loc: StructLoc, comptime observe_hints: ?HintListObserver) Error!model.view.HandoffGive {
    const peer_loc = (try reader.followStruct(loc, 1)) orelse return Error.MalformedFrame;
    const peer = try neutralPeerLocator(reader, peer_loc, observe_hints);
    return .{
        .recipient_key = try borrowedData(reader, loc, 0),
        .exporter = peer,
        .gifter_exporter_session = try borrowedData(reader, loc, 2),
        .gifter_side = try borrowedData(reader, loc, 3),
        .gift_id = try borrowedData(reader, loc, 4),
        .signature = .{ .raw = try borrowedData(reader, loc, 5) },
    };
}

fn neutralHandoffReceive(reader: Reader, loc: StructLoc, comptime observe_hints: ?HintListObserver) Error!model.view.Handoff {
    return .{ .receive = .{
        .receiving_session = try borrowedData(reader, loc, 0),
        .receiving_side = try borrowedData(reader, loc, 1),
        .handoff_count = try reader.dataWord(loc, 0),
        .signed_give = try neutralHandoffGive(reader, (try reader.followStruct(loc, 2)) orelse return Error.MalformedFrame, observe_hints),
        .signature = .{ .raw = try borrowedData(reader, loc, 3) },
    } };
}

pub fn neutralResolution(reader: Reader, loc: StructLoc, comptime observe_hints: ?HintListObserver) Error!model.view.Resolution {
    const disc = try enumFromWire(ResolutionKind, try reader.dataWord(loc, 0));
    const inner = (try reader.followStruct(loc, 0)) orelse return Error.MalformedFrame;
    return switch (disc) {
        .fulfill => .{ .fulfill = try neutralArgument(reader, inner, observe_hints) },
        .@"break" => .{ .@"break" = try neutralErrorView(reader, inner) },
    };
}

pub fn neutralStartSession(reader: Reader, body: StructLoc, comptime observe_hints: ?HintListObserver) Error!model.view.StartSession {
    const version_text = try borrowedText(reader, body, 0);
    return .{
        // A token this build does not know decodes as null; `session.validate`
        // is what refuses it, and refuses it as a version mismatch.
        .captp_version = model.CaptpVersion.fromWireString(version_text),
        .session_pubkey = try borrowedData(reader, body, 1),
        .acceptable_location = try neutralPeerLocator(reader, (try reader.followStruct(body, 2)) orelse return Error.MalformedFrame, observe_hints),
        .acceptable_location_sig = .{ .raw = try borrowedData(reader, body, 3) },
    };
}
