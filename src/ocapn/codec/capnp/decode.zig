//! The Cap'n Proto decode path, hand-rolled for the glowcap-to-glowcap wire.
//!
//! Cap'n Proto is the word-aligned alternative to Syrup. It carries the same
//! `model.Message` tree, just laid out as a run of 8-byte words instead of
//! Syrup's byte records. There's no schema compiler in the loop: we read the
//! struct and list layout directly against the wire primitives in `wire.zig`
//! (ADR-0026), so the codec stands on its own and the layout tracks the model.
//! Rendering lives in `encode.zig`. The layout and reader vocabulary both
//! sides share lives in `shared.zig`.
//!
//! Decode reads before it copies. `decodeBody` projects the borrowed
//! codec-neutral view over the frame without copying anything, and
//! `decodeOwned` is just that followed by `model.view.Body.toOwned`, one
//! decode vocabulary, the same shape as `syrup.decodeOwned`, so owned
//! materialization only happens when you ask for it.
//!
//! References flip perspective every time they cross the wire (ADR-0010), the
//! same way Syrup does. Something we export goes out as a `near`, and the partner
//! reads it back as a `far` import. The reverse happens too. The flip is a fixed
//! relabel of the wire arm. It never consults a table, so the codec still holds
//! no authority.
//!
//! Every `Message` arm decodes, along with everything the arms share:
//! `Reference`, every `Argument` arm, `Resolution`, `BreakReason`,
//! `PeerLocator`, `Handoff`, and `Tagged`.
//!
//! [ADR-0026]: ../../../docs/decisions/adr/ADR-0026-hand-rolled-capnp-codec.md

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const shared = @import("shared.zig");
const values = @import("decode/values.zig");

const wire = shared.wire;
const Error = shared.Error;
const Kind = shared.Kind;

const StructLoc = shared.StructLoc;
const enumFromWire = shared.enumFromWire;

const Reader = shared.Reader;

// ── Views ────────────────────────────────────────────────────────────────────

/// Borrowed projection of a decoded message: the reader plus the located body
/// struct and its discriminant. Copies nothing. `toOwned` materializes through
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
/// `model.view.Body.toOwned`. One decode vocabulary, every argument arm the
/// encoder emits reads back with full fidelity, mirroring `syrup.decodeOwned`,
/// so the owned path can never drift from the view path the engine dispatches.
pub fn decodeOwned(allocator: std.mem.Allocator, frame: foundation.FrameView) !model.Message {
    return (try decodeBody(frame)).toOwned(allocator);
}

/// Project the borrowed codec-neutral `model.view.Body` over `frame`.
/// Decode one delimited frame.
///
/// The frame must be exactly the length its own header declares. Syrup refuses
/// trailing bytes the same way (`expectEnd`), and without the rule two
/// different byte strings decode to the same message, so anything that treats
/// a frame's bytes as its identity ends up with two names for one thing. The
/// framing layer is where a buffer legitimately holds more than one frame.
/// `shared.readerFromFrame` stays lenient for it, and this is the entry point
/// that has already been handed a single frame.
pub fn decodeBody(frame: foundation.FrameView) Error!model.view.Body {
    return decodeBodyForProfile(.v1_0, frame);
}

/// Validate the frame once and cache collection views in the lent head.
/// Integer runs borrow the wire directly. Collections that outgrow the head
/// remain wire-backed after the same metered validation.
pub fn decodeBodyInto(profile: model.CaptpVersion, frame: foundation.FrameView, slab: *model.view.ValueSlab) Error!model.view.Body {
    const view = try decodeMessageView(frame);
    try shared.expectExactFrameLength(frame.bytes);
    if (profile == .next and view.kind == .resolve) return Error.UnsupportedMessage;
    if (profile == .next and (view.kind == .get or view.kind == .index or view.kind == .untag)) return Error.UnsupportedMessage;
    return neutralBodyForProfile(view, profile, slab);
}

pub fn decodeBodyForProfile(profile: model.CaptpVersion, frame: foundation.FrameView) Error!model.view.Body {
    var slab = model.view.ValueSlab.empty;
    return decodeBodyInto(profile, frame, &slab);
}

/// The Cap'n Proto name for the shared codec decode recursion bound, which
/// the metered walk in `decode/values.zig` holds.
pub const max_charge_depth: usize = values.max_charge_depth;

/// The one neutral body walk, shared by `decodeBody` and `MessageView.toOwned`
/// so there is no second decoder to drift.
fn neutralBody(view: MessageView) Error!model.view.Body {
    var slab = model.view.ValueSlab.empty;
    return neutralBodyForProfile(view, .v1_0, &slab);
}

// ── The metered walk (the remote-DoS bound) ──────────────────────────────────
//
// Cap'n Proto pointers may alias, so a small frame whose composite-list
// elements resolve to one shared child (repeated D levels, K children each)
// would drive K^D node visits on a walk that follows every edge, a remote,
// unauthenticated DoS on the single-threaded turn loop. The body projection
// below closes it: it walks the whole logical tree once against a reader
// metered with a single per-frame word budget (seeded from the segment size,
// spent in `Reader.word`/`byteSlice` and once per composite element), so an
// aliasing graph that re-reads the same words burns the one shared counter
// and is refused in bounded time, before any borrowed view escapes. The
// walk parses each list it meets into `slab` when the slab has room, so the
// views that escape are read from the slab and never from the wire again,
// and it descends every subtree it leaves wire-backed (`values.neutralArgs`,
// `values.neutralStructBacking`, the hint observer `values.chargeHintList`),
// so the later lazy re-walk of such a subtree is bounded by the same budget.
// A legitimate tree reads each segment word a small constant number of
// times, well under the budget. The exhaustive `Kind`/`ArgKind`/`RefTag`/
// `ResolutionKind` switches make a new wire arm a compile error here, and
// the round-trip tests catch any pointer-index drift.

fn neutralBodyForProfile(view: MessageView, profile: model.CaptpVersion, slab: *model.view.ValueSlab) Error!model.view.Body {
    var budget: usize = shared.traversalBudget(view.reader.seg_words);
    const metered = view.reader.withBudget(&budget);
    if (view.kind == .listen) return projectListenBodyForProfile(metered, view.body, profile);
    var body = try projectBody(metered, view.kind, view.body, slab);
    if (body == .deliver) {
        const flags = try metered.dataWord(view.body, 0);
        const allowed = shared.deliver_has_answer | shared.deliver_has_resolve_me |
            (if (profile == .next) shared.deliver_listen_mask else @as(u64, 0));
        if (flags & ~allowed != 0) return Error.MalformedFrame;
        if (profile == .next) {
            if (body.deliver.resolve_me_desc) |resolver| {
                if (resolver != .far) return Error.MalformedFrame;
                body.deliver.listen_mode = model.ListenMode.fromInt((flags & shared.deliver_listen_mask) >> shared.deliver_listen_shift) orelse return Error.MalformedFrame;
                if (body.deliver.listen_mode == .settling_only) return Error.MalformedFrame;
            } else if (body.deliver.answer != null or flags & shared.deliver_listen_mask != 0) return Error.MalformedFrame;
        }
    }
    return body;
}

/// One body projector per Cap'n Proto `Kind` wire id, the same comptime table
/// shape Syrup uses with `decoderFor` / `messageOp`. `Kind`'s explicit `enum(u16)`
/// values in `shared.zig` are the stable wire discriminants. `inline else` plus
/// `bodyProjector` make a new arm a compile error in both places at once.
const BodyProjector = *const fn (reader: Reader, body: StructLoc, slab: *model.view.ValueSlab) Error!model.view.Body;

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

/// Project the borrowed body arm-for-arm on the metered walk: a composite
/// sequence is parsed into `slab` when it has room and becomes a backing
/// walked on demand otherwise.
fn projectBody(reader: Reader, kind: Kind, body: StructLoc, slab: *model.view.ValueSlab) Error!model.view.Body {
    return switch (kind) {
        inline else => |k| bodyProjector(k)(reader, body, slab),
    };
}

fn projectDeliverBody(reader: Reader, body: StructLoc, slab: *model.view.ValueSlab) Error!model.view.Body {
    const flags = try reader.dataWord(body, 0);
    var resolve_me: ?model.view.Reference = null;
    if (flags & shared.deliver_has_resolve_me != 0) {
        if (try reader.followStruct(body, 2)) |ref_loc| resolve_me = try values.neutralReferenceView(reader, ref_loc, &values.chargeHintList);
    }
    return .{ .deliver = .{
        .target = try values.neutralReferenceView(reader, (try reader.followStruct(body, 0)) orelse return Error.MalformedFrame, &values.chargeHintList),
        .args = try values.neutralArgs(reader, body, 1, &values.chargeHintList, slab, 0),
        .answer = if (flags & shared.deliver_has_answer != 0) model.AnswerPosition.from(try reader.dataWord(body, 1)) else null,
        .resolve_me_desc = resolve_me,
    } };
}

fn projectResolveBody(reader: Reader, body: StructLoc, slab: *model.view.ValueSlab) Error!model.view.Body {
    return .{ .resolve = .{
        .answer = model.AnswerPosition.from(try reader.dataWord(body, 0)),
        .resolution = try values.neutralResolution(reader, (try reader.followStruct(body, 0)) orelse return Error.MalformedFrame, &values.chargeHintList, slab),
    } };
}

fn projectGcExportBody(reader: Reader, body: StructLoc, slab: *model.view.ValueSlab) Error!model.view.Body {
    _ = slab;
    return .{ .gc_export = .{
        .positions = try values.neutralPositionsBacking(reader, body, 0),
        .deltas = try values.neutralPositionsBacking(reader, body, 1),
    } };
}

fn projectGcAnswerBody(reader: Reader, body: StructLoc, slab: *model.view.ValueSlab) Error!model.view.Body {
    _ = slab;
    return .{ .gc_answer = .{ .positions = try values.neutralPositionsBacking(reader, body, 0) } };
}

fn projectAbortBody(reader: Reader, body: StructLoc, slab: *model.view.ValueSlab) Error!model.view.Body {
    _ = slab;
    return .{ .abort = .{
        .kind = try enumFromWire(model.AbortKind, try reader.dataWord(body, 0)),
        .message = try values.borrowedText(reader, body, 0),
    } };
}

fn projectListenBody(reader: Reader, body: StructLoc, slab: *model.view.ValueSlab) Error!model.view.Body {
    _ = slab;
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
        .target = try values.neutralReferenceView(reader, (try reader.followStruct(body, 0)) orelse return Error.MalformedFrame, &values.chargeHintList),
        .listener = try values.neutralReferenceView(reader, (try reader.followStruct(body, 1)) orelse return Error.MalformedFrame, &values.chargeHintList),
        .mode = mode,
    } };
}

fn projectGetBody(reader: Reader, body: StructLoc, slab: *model.view.ValueSlab) Error!model.view.Body {
    _ = slab;
    return .{ .get = .{
        .receiver = try values.neutralReferenceView(reader, (try reader.followStruct(body, 0)) orelse return Error.MalformedFrame, &values.chargeHintList),
        .field = try values.borrowedText(reader, body, 1),
        .answer = model.AnswerPosition.from(try reader.dataWord(body, 0)),
    } };
}

fn projectIndexBody(reader: Reader, body: StructLoc, slab: *model.view.ValueSlab) Error!model.view.Body {
    _ = slab;
    return .{ .index = .{
        .receiver = try values.neutralReferenceView(reader, (try reader.followStruct(body, 0)) orelse return Error.MalformedFrame, &values.chargeHintList),
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

fn projectUntagBody(reader: Reader, body: StructLoc, slab: *model.view.ValueSlab) Error!model.view.Body {
    _ = slab;
    return .{ .untag = .{
        .receiver = try values.neutralReferenceView(reader, (try reader.followStruct(body, 0)) orelse return Error.MalformedFrame, &values.chargeHintList),
        .tag = try values.borrowedText(reader, body, 1),
        .answer = model.AnswerPosition.from(try reader.dataWord(body, 0)),
    } };
}

fn projectStartSessionBody(reader: Reader, body: StructLoc, slab: *model.view.ValueSlab) Error!model.view.Body {
    _ = slab;
    return .{ .start_session = try values.neutralStartSession(reader, body, &values.chargeHintList) };
}
