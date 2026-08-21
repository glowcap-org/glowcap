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
const limits = @import("codec_limits");
const shared = @import("shared.zig");
const values = @import("decode/values.zig");

const wire = shared.wire;
const Error = shared.Error;
const Kind = shared.Kind;

const RefTag = shared.RefTag;
const ResolutionKind = shared.ResolutionKind;
const StructLoc = shared.StructLoc;
const CompositeList = shared.CompositeList;
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

/// Cap'n Proto charge-pass name for the shared codec decode recursion bound.
pub const max_charge_depth: usize = limits.max_decode_nesting;

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
    const arg = try values.neutralArgument(reader, loc, &chargeHintList);
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

/// Enumerate one locator's hint list on the eager metered pass. The value leaf
/// discovers the list while projecting and calls this observer exactly once;
/// ordinary projection passes null and stays lazy.
fn chargeHintList(reader: Reader, hints: CompositeList) Error!void {
    for (0..hints.element_count) |i| {
        try reader.spend(1);
        _ = try values.hintEntry(reader, hints.elem(i));
    }
}

/// Charge and recurse a reference: read+validate the node, then walk a promise
/// reference's pipeline path (the only reference arm with a composite vector).
fn chargeReference(reader: Reader, loc: StructLoc, depth: usize) Error!void {
    if (depth > max_charge_depth) return Error.MalformedFrame;
    _ = try values.neutralReferenceView(reader, loc, &chargeHintList);
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
        const op = try values.neutralPipelineOp(reader, clist.elem(idx));
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
        _ = try values.borrowedText(reader, elem, 0);
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
        // read. The value projector reports an already-found locator hint list
        // to `chargeHintList`, which owns enumeration and budget spending.
        .gc_export, .gc_answer, .abort => _ = try projectBody(reader, kind, body),
        .start_session => _ = try values.neutralStartSession(reader, body, &chargeHintList),
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
        .@"break" => _ = try values.neutralErrorView(reader, arm),
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
        if (try reader.followStruct(body, 2)) |ref_loc| resolve_me = try values.neutralReferenceView(reader, ref_loc, null);
    }
    return .{ .deliver = .{
        .target = try values.neutralReferenceView(reader, (try reader.followStruct(body, 0)) orelse return Error.MalformedFrame, null),
        .args = try values.neutralArgsBacking(reader, body, 1),
        .answer = if (flags & shared.deliver_has_answer != 0) model.AnswerPosition.from(try reader.dataWord(body, 1)) else null,
        .resolve_me_desc = resolve_me,
    } };
}

fn projectResolveBody(reader: Reader, body: StructLoc) Error!model.view.Body {
    return .{ .resolve = .{
        .answer = model.AnswerPosition.from(try reader.dataWord(body, 0)),
        .resolution = try values.neutralResolution(reader, (try reader.followStruct(body, 0)) orelse return Error.MalformedFrame, null),
    } };
}

fn projectGcExportBody(reader: Reader, body: StructLoc) Error!model.view.Body {
    return .{ .gc_export = .{
        .positions = try values.neutralPositionsBacking(reader, body, 0),
        .deltas = try values.neutralPositionsBacking(reader, body, 1),
    } };
}

fn projectGcAnswerBody(reader: Reader, body: StructLoc) Error!model.view.Body {
    return .{ .gc_answer = .{ .positions = try values.neutralPositionsBacking(reader, body, 0) } };
}

fn projectAbortBody(reader: Reader, body: StructLoc) Error!model.view.Body {
    return .{ .abort = .{
        .kind = try enumFromWire(model.AbortKind, try reader.dataWord(body, 0)),
        .message = try values.borrowedText(reader, body, 0),
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
        .target = try values.neutralReferenceView(reader, (try reader.followStruct(body, 0)) orelse return Error.MalformedFrame, null),
        .listener = try values.neutralReferenceView(reader, (try reader.followStruct(body, 1)) orelse return Error.MalformedFrame, null),
        .mode = mode,
    } };
}

fn projectGetBody(reader: Reader, body: StructLoc) Error!model.view.Body {
    return .{ .get = .{
        .receiver = try values.neutralReferenceView(reader, (try reader.followStruct(body, 0)) orelse return Error.MalformedFrame, null),
        .field = try values.borrowedText(reader, body, 1),
        .answer = model.AnswerPosition.from(try reader.dataWord(body, 0)),
    } };
}

fn projectIndexBody(reader: Reader, body: StructLoc) Error!model.view.Body {
    return .{ .index = .{
        .receiver = try values.neutralReferenceView(reader, (try reader.followStruct(body, 0)) orelse return Error.MalformedFrame, null),
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
        .digits = try values.borrowedData(reader, body, 1),
    };
    if (!big.isCanonical()) return Error.MalformedFrame;
    return .{ .big_integer = big };
}

fn projectUntagBody(reader: Reader, body: StructLoc) Error!model.view.Body {
    return .{ .untag = .{
        .receiver = try values.neutralReferenceView(reader, (try reader.followStruct(body, 0)) orelse return Error.MalformedFrame, null),
        .tag = try values.borrowedText(reader, body, 1),
        .answer = model.AnswerPosition.from(try reader.dataWord(body, 0)),
    } };
}

fn projectStartSessionBody(reader: Reader, body: StructLoc) Error!model.view.Body {
    return .{ .start_session = try values.neutralStartSession(reader, body, null) };
}
