//! The Syrup decoder: wire bytes to borrowed views and owned messages.
//!
//! This is the decode half of the Syrup codec. It owns the borrowed-view
//! decoder (`decodeView` / `decodeBody` / `decodePrefix`, which doubles as the
//! stream framer, see ADR-0029), the owned materializer (`decodeOwned` /
//! `ownedFromView`), the codec-neutral view projection, and the `read*` /
//! skip/scan leaf readers beneath them. Every frame here is potentially hostile,
//! so the length math on each prefix is checked and the recursive readers stop
//! at `max_decode_nesting`. The shared `*View` types and `Error` live in
//! [`core`]; this file reads bytes and holds no session authority. The encode
//! half is [`encode`].

const std = @import("std");

const foundation = @import("../../foundation/mod.zig");
const model = @import("../../model/mod.zig");
const framing = @import("../framing.zig");

const core = @import("core.zig");

const Error = core.Error;
const WalkError = core.WalkError;
const AbortView = core.AbortView;
const PositionListView = core.PositionListView;
const GcExportView = core.GcExportView;
const GcAnswerView = core.GcAnswerView;
const ReferenceView = core.ReferenceView;
const ArgumentView = core.ArgumentView;
const ArgumentListView = core.ArgumentListView;
const ResolutionView = core.ResolutionView;
const DeliverView = core.DeliverView;
const ResolveView = core.ResolveView;
const ListenView = core.ListenView;
const GetView = core.GetView;
const IndexView = core.IndexView;
const SignatureView = core.SignatureView;
const StartSessionView = core.StartSessionView;
const HandoffView = core.HandoffView;
const MessageView = core.MessageView;

/// Decode-time recursion bound for the neutral argument walker. The arg tree is
/// attacker-controlled, and slicing a nested `list` / `set` / `user-record`
/// recurses one native frame per level, so an unbounded nesting depth is a
/// one-frame stack overflow during decode — *before* the session's
/// authority-level [`SessionLimits.max_nesting_depth`] (default 64) can reject
/// it. This cap fails such a frame loud as `MalformedFrame` instead. It sits
/// well above the session cap so it never rejects a frame authority would
/// admit; a frame deeper than the session cap but shallower than this still
/// decodes and is rejected by validation as `resource_exhausted`.
const max_decode_nesting: usize = 512;

/// Project a borrowed [`MessageView`] over a complete `frame`. The view spans
/// every message kind and the reference / handoff / error structure callers
/// inspect; deliver argument *payloads* are projected coarsely (see
/// [`ArgumentView`]), so a deliver whose arguments include numeric, list, set,
/// tagged, or keyword values is rejected as `UnsupportedArgument` — those decode
/// through the codec-neutral [`decodeBody`]. Like [`decodeBody`], a frame must
/// decode whole, so a short read is a malformed frame; the shared leaf readers
/// signal truncation as `Incomplete`, which this whole-frame entry folds back
/// into `MalformedFrame`.
pub fn decodeView(frame: foundation.FrameView) Error!MessageView {
    return decodeViewInner(frame) catch |err| switch (err) {
        Error.Incomplete => Error.MalformedFrame,
        else => |other| other,
    };
}

fn decodeViewInner(frame: foundation.FrameView) Error!MessageView {
    if (frame.shape != .byte) {
        return Error.InvalidFrameShape;
    }

    var cursor: usize = 0;
    try readByte(frame.bytes, &cursor, '<');
    const op = try readSymbol(frame.bytes, &cursor);

    if (std.mem.eql(u8, op, "op:abort")) {
        const message = try readString(frame.bytes, &cursor);
        try readByte(frame.bytes, &cursor, '>');
        try expectEnd(frame.bytes, cursor);
        const abort = model.AbortReason.parseV1_0(message);
        return .{
            .abort = .{
                .kind = abort.kind,
                .message = abort.message,
            },
        };
    }

    if (std.mem.eql(u8, op, "op:deliver")) {
        const target = try readReference(frame.bytes, &cursor);
        const args = try readArgumentList(frame.bytes, &cursor);
        const answer = try readOptionalPositiveInt(frame.bytes, &cursor);
        const resolve_me_desc = try readOptionalReference(frame.bytes, &cursor);
        try readByte(frame.bytes, &cursor, '>');
        try expectEnd(frame.bytes, cursor);
        return .{ .deliver = .{
            .target = target,
            .args = args,
            .answer = answer,
            .resolve_me_desc = resolve_me_desc,
        } };
    }

    if (std.mem.eql(u8, op, "op:resolve")) {
        const answer = try readPositiveInt(frame.bytes, &cursor);
        const resolution = try readResolution(frame.bytes, &cursor);
        try readByte(frame.bytes, &cursor, '>');
        try expectEnd(frame.bytes, cursor);
        return .{ .resolve = .{ .answer = answer, .resolution = resolution } };
    }

    if (std.mem.eql(u8, op, "op:gc-exports")) {
        const positions = try readPositionList(frame.bytes, &cursor);
        const deltas = try readPositionList(frame.bytes, &cursor);
        try readByte(frame.bytes, &cursor, '>');
        try expectEnd(frame.bytes, cursor);
        return .{ .gc_export = .{ .positions = positions, .deltas = deltas } };
    }

    if (std.mem.eql(u8, op, "op:gc-answers")) {
        const positions = try readPositionList(frame.bytes, &cursor);
        try readByte(frame.bytes, &cursor, '>');
        try expectEnd(frame.bytes, cursor);
        return .{ .gc_answer = .{ .positions = positions } };
    }

    if (std.mem.eql(u8, op, "op:get")) {
        const receiver = try readReference(frame.bytes, &cursor);
        const field = try readSymbol(frame.bytes, &cursor);
        const answer = try readPositiveInt(frame.bytes, &cursor);
        try readByte(frame.bytes, &cursor, '>');
        try expectEnd(frame.bytes, cursor);
        return .{ .get = .{ .receiver = receiver, .field = field, .answer = answer } };
    }

    if (std.mem.eql(u8, op, "op:index")) {
        const receiver = try readReference(frame.bytes, &cursor);
        const index = try readInteger(frame.bytes, &cursor);
        const answer = try readPositiveInt(frame.bytes, &cursor);
        try readByte(frame.bytes, &cursor, '>');
        try expectEnd(frame.bytes, cursor);
        return .{ .index = .{ .receiver = receiver, .index = index, .answer = answer } };
    }

    if (std.mem.eql(u8, op, "op:listen")) {
        const target = try readReference(frame.bytes, &cursor);
        const listener = try readReference(frame.bytes, &cursor);
        const wants_partial = if (cursor < frame.bytes.len and frame.bytes[cursor] != '>')
            try readBool(frame.bytes, &cursor)
        else
            false;
        try readByte(frame.bytes, &cursor, '>');
        try expectEnd(frame.bytes, cursor);
        return .{ .listen = .{
            .target = target,
            .listener = listener,
            .wants_partial = wants_partial,
        } };
    }

    if (std.mem.eql(u8, op, "op:start-session")) {
        const version_wire = try readString(frame.bytes, &cursor);
        const captp_version = model.CaptpVersion.fromWireString(version_wire) orelse return Error.MalformedFrame;
        const session_pubkey = model.SessionPubkey{ .bytes = try readPeerKeyQ(frame.bytes, &cursor) };
        const acceptable_location = try readLocator(frame.bytes, &cursor);
        const acceptable_location_sig = try readSignatureView(frame.bytes, &cursor);
        try readByte(frame.bytes, &cursor, '>');
        try expectEnd(frame.bytes, cursor);
        return .{ .start_session = .{
            .captp_version = captp_version,
            .session_pubkey = session_pubkey,
            .acceptable_location = acceptable_location,
            .acceptable_location_sig = acceptable_location_sig,
        } };
    }

    if (std.mem.eql(u8, op, "desc:sig-envelope")) {
        const payload_start = cursor;
        try readByte(frame.bytes, &cursor, '<');
        const payload_tag = try readSymbol(frame.bytes, &cursor);
        cursor = payload_start;
        try skipSyrupValue(frame.bytes, &cursor);
        _ = try readSignatureView(frame.bytes, &cursor);
        try readByte(frame.bytes, &cursor, '>');
        try expectEnd(frame.bytes, cursor);
        return .{ .handoff = .{
            .bytes = frame.bytes,
            .envelope_tag = op,
            .payload_tag = payload_tag,
        } };
    }

    return Error.UnsupportedMessage;
}

pub fn decodeOwned(allocator: std.mem.Allocator, frame: foundation.FrameView) !model.Message {
    return ownedFromView(allocator, try decodeView(frame));
}

/// Materialize an owned [`model.Message`] from an already-decoded borrowed
/// [`MessageView`]. Split out so callers that already hold a view (e.g. the
/// engine's inbound dispatch, which needs the view's event tag first) convert
/// without re-parsing the frame.
pub fn ownedFromView(allocator: std.mem.Allocator, view: MessageView) !model.Message {
    return switch (view) {
        .deliver => |deliver| .{
            .deliver = .{
                .target = deliver.target.toModel(),
                .args = try deliver.args.toOwnedSlice(allocator),
                .answer = deliver.answer,
                .resolve_me_desc = if (deliver.resolve_me_desc) |reference| reference.toModel() else null,
            },
        },
        .resolve => |resolve| .{
            .resolve = .{
                .answer = resolve.answer,
                .resolution = try resolve.resolution.toOwned(allocator),
            },
        },
        .abort => |abort| .{
            .abort = .{
                .kind = abort.kind,
                .message = try allocator.dupe(u8, abort.message),
            },
        },
        .gc_export => |gc_export| blk: {
            const positions = try gc_export.positions.toOwnedSlice(allocator);
            errdefer allocator.free(positions);
            const deltas = try gc_export.deltas.toOwnedSlice(allocator);
            break :blk .{ .gc_export = .{ .positions = positions, .deltas = deltas } };
        },
        .gc_answer => |gc_answer| .{
            .gc_answer = .{ .positions = try gc_answer.positions.toOwnedSlice(allocator) },
        },
        .listen => |listen| .{
            .listen = .{
                .target = listen.target.toModel(),
                .listener = listen.listener.toModel(),
                .wants_partial = listen.wants_partial,
            },
        },
        .get => |get| .{
            .get = .{
                .receiver = get.receiver.toModel(),
                .field = try allocator.dupe(u8, get.field),
                .answer = get.answer,
            },
        },
        .index => |index| .{
            .index = .{
                .receiver = index.receiver.toModel(),
                .index = index.index,
                .answer = index.answer,
            },
        },
        .start_session => |start_session| .{ .start_session = try startSessionViewToOwned(allocator, start_session) },
        .handoff => |handoff| .{ .handoff = try handoffViewToOwned(allocator, handoff) },
    };
}

// ── Codec-neutral view projection ────────────────────────────────────────────
//
// `decodeBody` projects the borrowed codec-neutral `model.view.Body` over the
// frame's bytes — the single message shape the engine dispatches on. The
// unbounded sequences (`Args`, `PositionList`) are reached through inline
// vtable backings whose `Ctx.bytes` borrow the list region; `at` re-walks the
// Syrup bytes lazily. Argument projection is full fidelity — every arm the
// encoder emits decodes back.

const neutral_args_vtable = model.view.Args.VTable{
    .len = neutralArgsLen,
    .at = neutralArgsAt,
    .next = neutralArgsNext,
};

const neutral_positions_vtable = model.view.PositionList.VTable{
    .len = neutralPositionsLen,
    .at = neutralPositionsAt,
    .next = neutralPositionsNext,
};

fn neutralArgsLen(ctx: model.view.Args.Ctx) model.view.ProjectError!usize {
    var cursor: usize = 0;
    var total: usize = 0;
    while (cursor < ctx.bytes.len) : (total += 1) {
        _ = readNeutralArgument(ctx.bytes, &cursor, 0) catch return error.MalformedView;
    }
    return total;
}

fn neutralArgsAt(ctx: model.view.Args.Ctx, index: usize) model.view.ProjectError!model.view.Argument {
    var cursor: usize = 0;
    var current: usize = 0;
    while (cursor < ctx.bytes.len) : (current += 1) {
        const argument = readNeutralArgument(ctx.bytes, &cursor, 0) catch return error.MalformedView;
        if (current == index) return argument;
    }
    return error.MalformedView;
}

/// Forward cursor: `cursor` is a byte offset into the list region. One
/// `readNeutralArgument` advances it past the element it returns, so a full
/// walk is a single linear pass — not the per-`at` re-scan from byte 0.
fn neutralArgsNext(ctx: model.view.Args.Ctx, cursor: *u64) model.view.ProjectError!?model.view.Argument {
    var c: usize = @intCast(cursor.*);
    if (c >= ctx.bytes.len) return null;
    const argument = readNeutralArgument(ctx.bytes, &c, 0) catch return error.MalformedView;
    cursor.* = @intCast(c);
    return argument;
}

fn neutralPositionsLen(ctx: model.view.Args.Ctx) model.view.ProjectError!usize {
    var cursor: usize = 0;
    var total: usize = 0;
    while (cursor < ctx.bytes.len) : (total += 1) {
        _ = readPositiveInt(ctx.bytes, &cursor) catch return error.MalformedView;
    }
    return total;
}

fn neutralPositionsAt(ctx: model.view.Args.Ctx, index: usize) model.view.ProjectError!u64 {
    var cursor: usize = 0;
    var current: usize = 0;
    while (cursor < ctx.bytes.len) : (current += 1) {
        const value = readPositiveInt(ctx.bytes, &cursor) catch return error.MalformedView;
        if (current == index) return value;
    }
    return error.MalformedView;
}

fn neutralPositionsNext(ctx: model.view.Args.Ctx, cursor: *u64) model.view.ProjectError!?u64 {
    var c: usize = @intCast(cursor.*);
    if (c >= ctx.bytes.len) return null;
    const value = readPositiveInt(ctx.bytes, &c) catch return error.MalformedView;
    cursor.* = @intCast(c);
    return value;
}

fn neutralArgs(list_body: []const u8) model.view.Args {
    return model.view.Args.fromBacking(.{ .bytes = list_body }, &neutral_args_vtable);
}

fn neutralPositions(list_body: []const u8) model.view.PositionList {
    return model.view.PositionList.fromBacking(.{ .bytes = list_body }, &neutral_positions_vtable);
}

fn neutralReference(reference: ReferenceView) model.view.Reference {
    return switch (reference) {
        .near => |near| .{ .near = near },
        .far => |far| .{ .far = far },
        // Syrup's `desc:answer` carries no path operand (single-hop only), so a
        // decoded promise target always has the empty path.
        .promise => |promise| .{ .promise = .{ .answer_id = promise.answer_id } },
        .sturdy => |sturdy| .{ .sturdy = .{
            .peer = .{
                .transport = sturdy.peer.transport,
                .designator = sturdy.peer.designator,
                .hints = sturdy.peer.hints,
            },
            .swissnum = sturdy.swissnum,
        } },
    };
}

/// Project one borrowed full-fidelity [`model.view.Argument`] and advance
/// `cursor` past it. Nested `list` / `set` / `tagged` arms project lazily as
/// backed [`model.view.Args`] over their byte sub-region.
fn readNeutralArgument(bytes: []const u8, cursor: *usize, depth: usize) Error!model.view.Argument {
    if (depth > max_decode_nesting) return Error.MalformedFrame;
    if (cursor.* >= bytes.len) return Error.Incomplete;
    return switch (bytes[cursor.*]) {
        '0'...'9' => blk: {
            const marker_index = cursor.* + countDigits(bytes[cursor.*..]);
            if (marker_index >= bytes.len) return Error.Incomplete;
            break :blk switch (bytes[marker_index]) {
                ':' => .{ .bytes = try readBytes(bytes, cursor) },
                '"' => .{ .string = try readString(bytes, cursor) },
                '\'' => .{ .symbol = try readSymbol(bytes, cursor) },
                '+', '-' => .{ .integer = try readInteger(bytes, cursor) },
                else => Error.UnsupportedArgument,
            };
        },
        't', 'f' => .{ .boolean = try readBool(bytes, cursor) },
        'D' => .{ .float64 = try readFloat64(bytes, cursor) },
        '[' => .{ .list = neutralArgs(try sliceArgumentListNeutral(bytes, cursor, depth + 1)) },
        '#' => .{ .set = neutralArgs(try sliceSetNeutral(bytes, cursor, depth + 1)) },
        '<' => blk: {
            if (isSignedHandoffEnvelope(bytes, cursor.*)) {
                break :blk .{ .handoff = try readBorrowedSignedHandoff(bytes, cursor) };
            }
            if (isReferenceRecord(bytes, cursor.*)) {
                break :blk .{ .reference = neutralReference(try readReference(bytes, cursor)) };
            }
            try readByte(bytes, cursor, '<');
            const tag = try readSymbol(bytes, cursor);
            if (std.mem.eql(u8, tag, "void")) {
                try readByte(bytes, cursor, '>');
                break :blk .{ .void = {} };
            }
            if (std.mem.eql(u8, tag, "error")) {
                const message = try readString(bytes, cursor);
                try readByte(bytes, cursor, '>');
                break :blk .{ .@"error" = .{ .message = message } };
            }
            if (std.mem.eql(u8, tag, "user-record")) {
                const record_tag = try readSymbol(bytes, cursor);
                const value_body = try sliceArgumentListNeutral(bytes, cursor, depth + 1);
                try readByte(bytes, cursor, '>');
                break :blk .{ .tagged = .{ .tag = record_tag, .value = neutralArgs(value_body) } };
            }
            if (std.mem.eql(u8, tag, "kw")) {
                const name = try readSymbol(bytes, cursor);
                try readByte(bytes, cursor, '>');
                break :blk .{ .keyword = name };
            }
            if (std.mem.eql(u8, tag, "ocapn-sturdyref")) {
                const peer_locator = try readLocator(bytes, cursor);
                const swissnum = try readBytes(bytes, cursor);
                try readByte(bytes, cursor, '>');
                break :blk .{ .reference = .{ .sturdy = .{
                    .peer = .{
                        .transport = peer_locator.transport,
                        .designator = peer_locator.designator,
                        .hints = peer_locator.hints,
                    },
                    .swissnum = swissnum,
                } } };
            }
            break :blk Error.UnsupportedArgument;
        },
        else => Error.UnsupportedArgument,
    };
}

/// Slice a `[ … ]` argument list body (between the brackets) using the
/// full-fidelity walker, advancing `cursor` past the closing `]`. `depth` is
/// the nesting level entered (bounded by [`max_decode_nesting`]).
fn sliceArgumentListNeutral(bytes: []const u8, cursor: *usize, depth: usize) Error![]const u8 {
    try readByte(bytes, cursor, '[');
    const body_start = cursor.*;
    while (cursor.* < bytes.len and bytes[cursor.*] != ']') {
        _ = try readNeutralArgument(bytes, cursor, depth);
    }
    if (cursor.* >= bytes.len) return Error.Incomplete;
    const body = bytes[body_start..cursor.*];
    cursor.* += 1;
    return body;
}

/// Slice a `# … $` set body, advancing `cursor` past the closing `$`.
fn sliceSetNeutral(bytes: []const u8, cursor: *usize, depth: usize) Error![]const u8 {
    try readByte(bytes, cursor, '#');
    const body_start = cursor.*;
    while (cursor.* < bytes.len and bytes[cursor.*] != '$') {
        _ = try readNeutralArgument(bytes, cursor, depth);
    }
    if (cursor.* >= bytes.len) return Error.Incomplete;
    const body = bytes[body_start..cursor.*];
    cursor.* += 1;
    return body;
}

fn readNeutralResolution(bytes: []const u8, cursor: *usize) Error!model.view.Resolution {
    try readByte(bytes, cursor, '<');
    const tag = try readSymbol(bytes, cursor);
    if (std.mem.eql(u8, tag, "resolve:fulfill")) {
        const argument = try readNeutralArgument(bytes, cursor, 0);
        try readByte(bytes, cursor, '>');
        return .{ .fulfill = argument };
    }
    if (std.mem.eql(u8, tag, "resolve:break")) {
        const err = try readError(bytes, cursor);
        try readByte(bytes, cursor, '>');
        return .{ .break_ = .{ .message = err.message } };
    }
    return Error.MalformedFrame;
}

/// Project the borrowed codec-neutral [`model.view.Body`] over a complete
/// `frame`. A frame is exactly one message with no trailing bytes; a short
/// read is therefore a malformed frame here. Streaming callers with incomplete
/// input use [`decodePrefix`], which shares the same parser.
pub fn decodeBody(frame: foundation.FrameView) Error!model.view.Body {
    if (frame.shape != .byte) return Error.InvalidFrameShape;

    var cursor: usize = 0;
    const body = decodeBodyAt(frame.bytes, &cursor) catch |err| switch (err) {
        Error.Incomplete => return Error.MalformedFrame,
        else => |other| return other,
    };
    try expectEnd(frame.bytes, cursor);
    return body;
}

/// Decode the one message at the front of `bytes`, returning its borrowed body
/// and the number of bytes it consumed, or a structural verdict. This is the
/// single stream framer: the decoder *is* the framer, so there is no second
/// boundary scanner to disagree with it.
///
/// `max_frame_bytes` caps an accepted frame — a fully-decoded message longer
/// than the cap is rejected as `.too_large` rather than admitted. A frame that
/// is merely longer than `bytes` (still arriving) reports `.incomplete`; the
/// caller's read buffer bound is what stops an unbounded never-completing
/// stream, so the buffer must be sized to the cap.
pub fn decodePrefix(bytes: []const u8, max_frame_bytes: usize) framing.Prefix {
    var cursor: usize = 0;
    const body = decodeBodyAt(bytes, &cursor) catch |err| switch (err) {
        Error.Incomplete => return .incomplete,
        else => return .malformed,
    };
    if (cursor > max_frame_bytes) return .too_large;
    return .{ .decoded = .{ .body = body, .consumed = cursor } };
}

/// Decode exactly one message starting at `cursor.*`, advancing `cursor` to the
/// byte just past it and leaving any trailing bytes untouched. The cursor it
/// leaves *is* the frame boundary. `Error.Incomplete` means the buffer ends
/// mid-message (read more); every other error means the bytes are structurally
/// invalid regardless of how many more arrive.
fn decodeBodyAt(bytes: []const u8, cursor: *usize) Error!model.view.Body {
    try readByte(bytes, cursor, '<');
    const op = try readSymbol(bytes, cursor);

    if (std.mem.eql(u8, op, "op:abort")) {
        const message = try readString(bytes, cursor);
        try readByte(bytes, cursor, '>');
        const abort = model.AbortReason.parseV1_0(message);
        return .{ .abort = .{ .kind = abort.kind, .message = abort.message } };
    }

    if (std.mem.eql(u8, op, "op:deliver")) {
        const target = try readReference(bytes, cursor);
        const args_body = try sliceArgumentListNeutral(bytes, cursor, 0);
        const answer = try readOptionalPositiveInt(bytes, cursor);
        const resolve_me_desc = try readOptionalReference(bytes, cursor);
        try readByte(bytes, cursor, '>');
        return .{ .deliver = .{
            .target = neutralReference(target),
            .args = neutralArgs(args_body),
            .answer = answer,
            .resolve_me_desc = if (resolve_me_desc) |reference| neutralReference(reference) else null,
        } };
    }

    if (std.mem.eql(u8, op, "op:resolve")) {
        const answer = try readPositiveInt(bytes, cursor);
        const resolution = try readNeutralResolution(bytes, cursor);
        try readByte(bytes, cursor, '>');
        return .{ .resolve = .{ .answer = answer, .resolution = resolution } };
    }

    if (std.mem.eql(u8, op, "op:gc-exports")) {
        const positions = try readPositionList(bytes, cursor);
        const deltas = try readPositionList(bytes, cursor);
        try readByte(bytes, cursor, '>');
        return .{ .gc_export = .{
            .positions = neutralPositions(positions.bytes),
            .deltas = neutralPositions(deltas.bytes),
        } };
    }

    if (std.mem.eql(u8, op, "op:gc-answers")) {
        const positions = try readPositionList(bytes, cursor);
        try readByte(bytes, cursor, '>');
        return .{ .gc_answer = .{ .positions = neutralPositions(positions.bytes) } };
    }

    if (std.mem.eql(u8, op, "op:get")) {
        const receiver = try readReference(bytes, cursor);
        const field = try readSymbol(bytes, cursor);
        const answer = try readPositiveInt(bytes, cursor);
        try readByte(bytes, cursor, '>');
        return .{ .get = .{ .receiver = neutralReference(receiver), .field = field, .answer = answer } };
    }

    if (std.mem.eql(u8, op, "op:index")) {
        const receiver = try readReference(bytes, cursor);
        const index = try readInteger(bytes, cursor);
        const answer = try readPositiveInt(bytes, cursor);
        try readByte(bytes, cursor, '>');
        return .{ .index = .{ .receiver = neutralReference(receiver), .index = index, .answer = answer } };
    }

    if (std.mem.eql(u8, op, "op:listen")) {
        const target = try readReference(bytes, cursor);
        const listener = try readReference(bytes, cursor);
        const wants_partial = if (cursor.* < bytes.len and bytes[cursor.*] != '>')
            try readBool(bytes, cursor)
        else
            false;
        try readByte(bytes, cursor, '>');
        return .{ .listen = .{
            .target = neutralReference(target),
            .listener = neutralReference(listener),
            .wants_partial = wants_partial,
        } };
    }

    if (std.mem.eql(u8, op, "op:start-session")) {
        const version_wire = try readString(bytes, cursor);
        const captp_version = model.CaptpVersion.fromWireString(version_wire) orelse return Error.MalformedFrame;
        const session_pubkey = try readPeerKeyQ(bytes, cursor);
        // Span the exact `<ocapn-peer …>` location-record bytes around the read so
        // a verifier checks the signature over what was received, not a re-encode.
        const location_start = cursor.*;
        const acceptable_location = try readLocator(bytes, cursor);
        const location_raw = bytes[location_start..cursor.*];
        const acceptable_location_sig = try readSignatureView(bytes, cursor);
        try readByte(bytes, cursor, '>');
        return .{ .start_session = .{
            .captp_version = captp_version,
            .session_pubkey = session_pubkey,
            .acceptable_location = .{
                .transport = acceptable_location.transport,
                .designator = acceptable_location.designator,
                .hints = acceptable_location.hints,
            },
            .acceptable_location_sig = .{ .halves = .{ .r = acceptable_location_sig.r, .s = acceptable_location_sig.s } },
            .acceptable_location_raw = location_raw,
        } };
    }

    if (std.mem.eql(u8, op, "desc:sig-envelope")) {
        // The signed-handoff reader re-parses the whole envelope from the
        // start, so its cursor — not the outer one — marks the frame end.
        var envelope_cursor: usize = 0;
        const handoff = try readBorrowedSignedHandoff(bytes, &envelope_cursor);
        cursor.* = envelope_cursor;
        return .{ .handoff = handoff };
    }

    return Error.UnsupportedMessage;
}

fn readBorrowedSignedHandoff(bytes: []const u8, cursor: *usize) Error!model.view.Handoff {
    const envelope_start = cursor.*;
    try readByte(bytes, cursor, '<');
    const envelope_tag = try readSymbol(bytes, cursor);
    if (!std.mem.eql(u8, envelope_tag, "desc:sig-envelope")) return Error.MalformedFrame;

    try readByte(bytes, cursor, '<');
    const payload_tag = try readSymbol(bytes, cursor);

    if (std.mem.eql(u8, payload_tag, "desc:handoff-give")) {
        var give = try readBorrowedHandoffGivePayload(bytes, cursor);
        try readByte(bytes, cursor, '>');
        const sig = try readSignatureView(bytes, cursor);
        give.signature = .{ .halves = .{ .r = sig.r, .s = sig.s } };
        try readByte(bytes, cursor, '>');
        give.raw_signed = bytes[envelope_start..cursor.*];
        return .{ .give = give };
    }

    if (std.mem.eql(u8, payload_tag, "desc:handoff-receive")) {
        var receive = try readBorrowedHandoffReceivePayload(bytes, cursor);
        try readByte(bytes, cursor, '>');
        const sig = try readSignatureView(bytes, cursor);
        receive.signature = .{ .halves = .{ .r = sig.r, .s = sig.s } };
        try readByte(bytes, cursor, '>');
        return .{ .receive = receive };
    }

    return Error.UnsupportedMessage;
}

fn readBorrowedHandoffGivePayload(bytes: []const u8, cursor: *usize) Error!model.view.HandoffGive {
    const recipient_key = try readPeerKeyQ(bytes, cursor);
    const locator = try readLocator(bytes, cursor);
    // Accept `#f` hints (`empty_wire_was_false`) as well as strictly-empty hints:
    // a real Goblins handoff-give writes the exporter location with `#f` hints,
    // exactly as it does for an op:start-session location. Only hints carrying
    // entries (which pancake does not model) are unsupported.
    if (locator.hints.entries.len != 0) {
        return Error.UnsupportedMessage;
    }
    const gifter_exporter_session = try readBytes(bytes, cursor);
    const gifter_side = try readBytes(bytes, cursor);
    const gift_id = try readBytes(bytes, cursor);
    return .{
        .recipient_key = recipient_key,
        .exporter_location = .{ .locator = .{ .transport = locator.transport, .designator = locator.designator } },
        .gifter_exporter_session = gifter_exporter_session,
        .gifter_side = gifter_side,
        .gift_id = gift_id,
        // Filled by the envelope wrapper from the trailing `sig-val`.
        .signature = .{ .raw = &.{} },
    };
}

fn readBorrowedHandoffReceivePayload(bytes: []const u8, cursor: *usize) Error!model.view.HandoffReceive {
    const receiving_session = try readBytes(bytes, cursor);
    const receiving_side = try readBytes(bytes, cursor);
    const handoff_count = try readPositiveInt(bytes, cursor);
    const signed = try readBorrowedSignedHandoff(bytes, cursor);
    const signed_give = switch (signed) {
        .give => |give| give,
        .receive => return Error.MalformedFrame,
    };
    return .{
        .receiving_session = receiving_session,
        .receiving_side = receiving_side,
        .handoff_count = handoff_count,
        .signed_give = signed_give,
        .signature = .{ .raw = &.{} },
    };
}

fn handoffViewToOwned(allocator: std.mem.Allocator, view: HandoffView) WalkError!model.Handoff {
    var cursor: usize = 0;
    const handoff = try readSignedHandoff(allocator, view.bytes, &cursor);
    errdefer freeOwnedHandoff(allocator, handoff);
    try expectEnd(view.bytes, cursor);
    return handoff;
}

fn readSignedHandoff(allocator: std.mem.Allocator, bytes: []const u8, cursor: *usize) WalkError!model.Handoff {
    const envelope_start = cursor.*;
    try readByte(bytes, cursor, '<');
    const envelope_tag = try readSymbol(bytes, cursor);
    if (!std.mem.eql(u8, envelope_tag, "desc:sig-envelope")) {
        return Error.MalformedFrame;
    }

    try readByte(bytes, cursor, '<');
    const payload_tag = try readSymbol(bytes, cursor);

    // The signature lives outside the payload record, so it is read after the
    // payload closes. It is bound to a local (not stitched into the struct until
    // the final return) because the payload freer already covers a struct's
    // `signature` field: writing the owned signature in early and *also* keeping
    // the whole-struct errdefer would double-free it if the trailing `>` fails.
    // The payload's placeholder `signature = &.{}` is zero-length, so the
    // whole-struct errdefer frees it as a no-op until the real one is attached.
    if (std.mem.eql(u8, payload_tag, "desc:handoff-give")) {
        const give = try readHandoffGivePayload(allocator, bytes, cursor);
        errdefer freeOwnedHandoffGive(allocator, give);
        try readByte(bytes, cursor, '>');
        const signature = try signatureViewToOwned(allocator, try readSignatureView(bytes, cursor));
        errdefer allocator.free(signature);
        try readByte(bytes, cursor, '>');
        const raw_signed = try allocator.dupe(u8, bytes[envelope_start..cursor.*]);
        errdefer allocator.free(raw_signed);
        var result = give;
        result.signature = signature;
        result.raw_signed = raw_signed;
        return .{ .give = result };
    }

    if (std.mem.eql(u8, payload_tag, "desc:handoff-receive")) {
        const receive = try readHandoffReceivePayload(allocator, bytes, cursor);
        errdefer freeOwnedHandoffReceive(allocator, receive);
        try readByte(bytes, cursor, '>');
        const signature = try signatureViewToOwned(allocator, try readSignatureView(bytes, cursor));
        errdefer allocator.free(signature);
        try readByte(bytes, cursor, '>');
        var result = receive;
        result.signature = signature;
        return .{ .receive = result };
    }

    return Error.UnsupportedMessage;
}

fn readHandoffGivePayload(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    cursor: *usize,
) !model.HandoffGive {
    const recipient_key = try allocator.dupe(u8, try readPeerKeyQ(bytes, cursor));
    errdefer allocator.free(recipient_key);

    const exporter_location = try readLocatorStringOwned(allocator, bytes, cursor);
    errdefer allocator.free(exporter_location);

    const gifter_exporter_session = try allocator.dupe(u8, try readBytes(bytes, cursor));
    errdefer allocator.free(gifter_exporter_session);

    const gifter_side = try allocator.dupe(u8, try readBytes(bytes, cursor));
    errdefer allocator.free(gifter_side);

    const gift_id = try allocator.dupe(u8, try readBytes(bytes, cursor));
    errdefer allocator.free(gift_id);

    return .{
        .recipient_key = recipient_key,
        .exporter_location = exporter_location,
        .gifter_exporter_session = gifter_exporter_session,
        .gifter_side = gifter_side,
        .gift_id = gift_id,
        .signature = &.{},
    };
}

fn readHandoffReceivePayload(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    cursor: *usize,
) WalkError!model.HandoffReceive {
    const receiving_session = try allocator.dupe(u8, try readBytes(bytes, cursor));
    errdefer allocator.free(receiving_session);

    const receiving_side = try allocator.dupe(u8, try readBytes(bytes, cursor));
    errdefer allocator.free(receiving_side);

    const handoff_count = try readPositiveInt(bytes, cursor);

    const signed_handoff = try readSignedHandoff(allocator, bytes, cursor);
    const signed_give = switch (signed_handoff) {
        .give => |give| give,
        .receive => |receive| {
            freeOwnedHandoffReceive(allocator, receive);
            return Error.MalformedFrame;
        },
    };
    errdefer freeOwnedHandoffGive(allocator, signed_give);

    return .{
        .receiving_session = receiving_session,
        .receiving_side = receiving_side,
        .handoff_count = handoff_count,
        .signed_give = signed_give,
        .signature = &.{},
    };
}

fn readLocatorStringOwned(allocator: std.mem.Allocator, bytes: []const u8, cursor: *usize) ![]u8 {
    const locator = try readLocator(bytes, cursor);
    // Accept `#f` hints as well as strictly-empty ones — a real Goblins
    // handoff-give writes the exporter location with `#f` hints (as op:start-session
    // does). Only hints carrying entries pancake does not model are unsupported.
    if (locator.hints.entries.len != 0) {
        return Error.UnsupportedMessage;
    }

    const location = try allocator.alloc(u8, locator.transport.len + ":".len + locator.designator.len);
    @memcpy(location[0..locator.transport.len], locator.transport);
    location[locator.transport.len] = ':';
    @memcpy(location[locator.transport.len + 1 ..], locator.designator);
    return location;
}

fn startSessionViewToOwned(allocator: std.mem.Allocator, view: StartSessionView) !model.StartSession {
    const session_pubkey = try allocator.dupe(u8, view.session_pubkey.bytes);
    errdefer allocator.free(session_pubkey);

    const acceptable_location = try peerLocatorToOwned(allocator, view.acceptable_location);
    errdefer freeOwnedPeerLocator(allocator, acceptable_location);

    const acceptable_location_sig = try signatureViewToOwned(allocator, view.acceptable_location_sig);
    errdefer allocator.free(acceptable_location_sig);

    return .{
        .captp_version = view.captp_version,
        .session_pubkey = .{ .bytes = session_pubkey },
        .acceptable_location = acceptable_location,
        .acceptable_location_sig = .{ .bytes = acceptable_location_sig },
    };
}

fn signatureViewToOwned(allocator: std.mem.Allocator, view: SignatureView) ![]u8 {
    const bytes = try allocator.alloc(u8, view.len());
    @memcpy(bytes[0..view.r.len], view.r);
    @memcpy(bytes[view.r.len..], view.s);
    return bytes;
}

fn peerLocatorToOwned(allocator: std.mem.Allocator, locator: model.PeerLocator) !model.PeerLocator {
    const transport = try allocator.dupe(u8, locator.transport);
    errdefer allocator.free(transport);

    const designator = try allocator.dupe(u8, locator.designator);
    errdefer allocator.free(designator);

    const hints = try hintsToOwned(allocator, locator.hints);
    errdefer freeOwnedHints(allocator, hints);

    return .{
        .transport = transport,
        .designator = designator,
        .hints = hints,
    };
}

fn freeOwnedPeerLocator(allocator: std.mem.Allocator, locator: model.PeerLocator) void {
    allocator.free(locator.transport);
    allocator.free(locator.designator);
    freeOwnedHints(allocator, locator.hints);
}

fn hintsToOwned(allocator: std.mem.Allocator, hints: model.Hints) !model.Hints {
    const entries = try allocator.alloc(model.HintEntry, hints.entries.len);
    errdefer allocator.free(entries);

    var initialized: usize = 0;
    errdefer {
        for (entries[0..initialized]) |entry| {
            freeOwnedHintEntry(allocator, entry);
        }
    }

    for (hints.entries, 0..) |entry, i| {
        entries[i] = try hintEntryToOwned(allocator, entry);
        initialized += 1;
    }

    return .{
        .entries = entries,
        .empty_wire_was_false = hints.empty_wire_was_false,
    };
}

fn freeOwnedHints(allocator: std.mem.Allocator, hints: model.Hints) void {
    for (hints.entries) |entry| {
        freeOwnedHintEntry(allocator, entry);
    }
    allocator.free(hints.entries);
}

fn hintEntryToOwned(allocator: std.mem.Allocator, entry: model.HintEntry) !model.HintEntry {
    const name = try allocator.dupe(u8, entry.name);
    errdefer allocator.free(name);

    return .{
        .name = name,
        .value = try hintValueToOwned(allocator, entry.value),
    };
}

fn freeOwnedHintEntry(allocator: std.mem.Allocator, entry: model.HintEntry) void {
    allocator.free(entry.name);
    freeOwnedHintValue(allocator, entry.value);
}

fn hintValueToOwned(allocator: std.mem.Allocator, value: model.HintValue) !model.HintValue {
    return switch (value) {
        .string => |string| .{ .string = try allocator.dupe(u8, string) },
        .bytes => |bytes| .{ .bytes = try allocator.dupe(u8, bytes) },
        .boolean, .integer => value,
    };
}

fn freeOwnedHintValue(allocator: std.mem.Allocator, value: model.HintValue) void {
    switch (value) {
        .string => |string| allocator.free(string),
        .bytes => |bytes| allocator.free(bytes),
        .boolean, .integer => {},
    }
}

fn freeOwnedHandoff(allocator: std.mem.Allocator, handoff: model.Handoff) void {
    switch (handoff) {
        .give => |give| freeOwnedHandoffGive(allocator, give),
        .receive => |receive| freeOwnedHandoffReceive(allocator, receive),
    }
}

fn freeOwnedHandoffReceive(allocator: std.mem.Allocator, receive: model.HandoffReceive) void {
    allocator.free(receive.receiving_session);
    allocator.free(receive.receiving_side);
    freeOwnedHandoffGive(allocator, receive.signed_give);
    allocator.free(receive.signature);
}

fn freeOwnedHandoffGive(allocator: std.mem.Allocator, give: model.HandoffGive) void {
    allocator.free(give.recipient_key);
    allocator.free(give.exporter_location);
    allocator.free(give.gifter_exporter_session);
    allocator.free(give.gifter_side);
    allocator.free(give.gift_id);
    allocator.free(give.signature);
    if (give.raw_signed) |raw| allocator.free(raw);
}

fn readString(bytes: []const u8, cursor: *usize) Error![]const u8 {
    const len_start = cursor.*;
    while (cursor.* < bytes.len and std.ascii.isDigit(bytes[cursor.*])) {
        cursor.* += 1;
    }
    if (cursor.* >= bytes.len) return Error.Incomplete;
    if (cursor.* == len_start or bytes[cursor.*] != '"') {
        return Error.MalformedFrame;
    }

    const len = std.fmt.parseInt(usize, bytes[len_start..cursor.*], 10) catch {
        return Error.MalformedFrame;
    };
    cursor.* += 1;

    const body_start = cursor.*;
    if (len > bytes.len - body_start) {
        return Error.Incomplete;
    }
    const body_end = body_start + len;
    cursor.* = body_end;
    return bytes[body_start..body_end];
}

pub fn readSymbol(bytes: []const u8, cursor: *usize) Error![]const u8 {
    const len_start = cursor.*;
    while (cursor.* < bytes.len and std.ascii.isDigit(bytes[cursor.*])) {
        cursor.* += 1;
    }
    if (cursor.* >= bytes.len) return Error.Incomplete;
    if (cursor.* == len_start or bytes[cursor.*] != '\'') {
        return Error.MalformedFrame;
    }

    const len = std.fmt.parseInt(usize, bytes[len_start..cursor.*], 10) catch {
        return Error.MalformedFrame;
    };
    cursor.* += 1;

    const body_start = cursor.*;
    if (len > bytes.len - body_start) {
        return Error.Incomplete;
    }
    const body_end = body_start + len;
    cursor.* = body_end;
    return bytes[body_start..body_end];
}

fn readPositionList(bytes: []const u8, cursor: *usize) Error!PositionListView {
    try readByte(bytes, cursor, '[');
    const body_start = cursor.*;
    while (cursor.* < bytes.len and bytes[cursor.*] != ']') {
        _ = try readPositiveInt(bytes, cursor);
    }
    if (cursor.* >= bytes.len) {
        return Error.Incomplete;
    }

    const view = PositionListView{ .bytes = bytes[body_start..cursor.*] };
    cursor.* += 1;
    return view;
}

fn readArgumentList(bytes: []const u8, cursor: *usize) Error!ArgumentListView {
    try readByte(bytes, cursor, '[');
    const body_start = cursor.*;
    while (cursor.* < bytes.len and bytes[cursor.*] != ']') {
        _ = try readArgument(bytes, cursor);
    }
    if (cursor.* >= bytes.len) {
        return Error.Incomplete;
    }

    const view = ArgumentListView{ .bytes = bytes[body_start..cursor.*] };
    cursor.* += 1;
    return view;
}

pub fn readArgument(bytes: []const u8, cursor: *usize) Error!ArgumentView {
    if (cursor.* >= bytes.len) return Error.Incomplete;
    return switch (bytes[cursor.*]) {
        '0'...'9' => blk: {
            const len_start = cursor.*;
            while (cursor.* < bytes.len and std.ascii.isDigit(bytes[cursor.*])) {
                cursor.* += 1;
            }
            if (cursor.* >= bytes.len) return Error.Incomplete;
            cursor.* = len_start;
            break :blk switch (bytes[cursor.* + countDigits(bytes[cursor.*..])]) {
                ':' => .{ .bytes = try readBytes(bytes, cursor) },
                '"' => .{ .bytes = try readString(bytes, cursor) },
                '\'' => .{ .bytes = try readSymbol(bytes, cursor) },
                else => Error.UnsupportedArgument,
            };
        },
        '<' => blk: {
            if (isSignedHandoffEnvelope(bytes, cursor.*)) {
                break :blk .{ .handoff = try readBorrowedSignedHandoff(bytes, cursor) };
            }
            if (isReferenceRecord(bytes, cursor.*)) {
                break :blk .{ .reference = try readReference(bytes, cursor) };
            }
            try readByte(bytes, cursor, '<');
            const tag = try readSymbol(bytes, cursor);
            if (std.mem.eql(u8, tag, "void")) {
                try readByte(bytes, cursor, '>');
                break :blk .{ .void = {} };
            }
            if (std.mem.eql(u8, tag, "error")) {
                const message = try readString(bytes, cursor);
                try readByte(bytes, cursor, '>');
                break :blk .{ .@"error" = .{ .message = message } };
            }
            if (std.mem.eql(u8, tag, "ocapn-sturdyref")) {
                const peer_locator = try readLocator(bytes, cursor);
                const swissnum = try readBytes(bytes, cursor);
                try readByte(bytes, cursor, '>');
                break :blk .{ .reference = .{ .sturdy = .{
                    .peer = peer_locator,
                    .swissnum = swissnum,
                } } };
            }
            break :blk Error.UnsupportedArgument;
        },
        else => Error.UnsupportedArgument,
    };
}

/// Decode a payload/target-position descriptor into a model `Reference` in the
/// **receiver's** perspective (ADR-0010 perspective flip, matching Goblins's
/// `incoming-post-unmarshall!`). The flip is a fixed wire-tag
/// relabel — no table lookup, so the codec still owns no authority:
///
/// - `<desc:export N>` — the sender names *our* export — lifts to `.near`.
/// - `<desc:import-object N>` / `<desc:import-promise N>` — the sender names one
///   of *its* exports for us to import — lift to `.far`, preserving the
///   object/promise kind.
/// - `<desc:answer N>` lifts to `.promise`.
///
/// The encoder is the mirror: it writes `near` as `desc:import-object` and `far`
/// as `desc:export`, so a reference sent and echoed back swaps arms — that swap *is* the
/// perspective change, not a round-trip bug.
fn readReference(bytes: []const u8, cursor: *usize) Error!ReferenceView {
    try readByte(bytes, cursor, '<');
    const tag = try readSymbol(bytes, cursor);
    if (std.mem.eql(u8, tag, "desc:export")) {
        const export_id = try readPositiveInt(bytes, cursor);
        try readByte(bytes, cursor, '>');
        return .{ .near = .{ .export_id = export_id, .kind = .object } };
    }
    if (std.mem.eql(u8, tag, "desc:import-object")) {
        const import_id = try readPositiveInt(bytes, cursor);
        try readByte(bytes, cursor, '>');
        return .{ .far = .{ .import_id = import_id, .kind = .object } };
    }
    if (std.mem.eql(u8, tag, "desc:import-promise")) {
        const import_id = try readPositiveInt(bytes, cursor);
        try readByte(bytes, cursor, '>');
        return .{ .far = .{ .import_id = import_id, .kind = .promise } };
    }
    if (std.mem.eql(u8, tag, "desc:answer")) {
        const answer_id = try readPositiveInt(bytes, cursor);
        try readByte(bytes, cursor, '>');
        return .{ .promise = .{ .answer_id = answer_id } };
    }
    return Error.UnsupportedReference;
}

fn readOptionalReference(bytes: []const u8, cursor: *usize) Error!?ReferenceView {
    if (cursor.* < bytes.len and bytes[cursor.*] == 'f') {
        cursor.* += 1;
        return null;
    }
    return try readReference(bytes, cursor);
}

fn readResolution(bytes: []const u8, cursor: *usize) Error!ResolutionView {
    try readByte(bytes, cursor, '<');
    const tag = try readSymbol(bytes, cursor);
    if (std.mem.eql(u8, tag, "resolve:fulfill")) {
        const argument = try readArgument(bytes, cursor);
        try readByte(bytes, cursor, '>');
        return .{ .fulfill = argument };
    }
    if (std.mem.eql(u8, tag, "resolve:break")) {
        const err = try readError(bytes, cursor);
        try readByte(bytes, cursor, '>');
        return .{ .break_ = err };
    }
    return Error.MalformedFrame;
}

fn readError(bytes: []const u8, cursor: *usize) Error!model.Error {
    try readByte(bytes, cursor, '<');
    const tag = try readSymbol(bytes, cursor);
    if (!std.mem.eql(u8, tag, "error")) {
        return Error.MalformedFrame;
    }
    const message = try readString(bytes, cursor);
    try readByte(bytes, cursor, '>');
    return .{ .message = message };
}

fn readPeerKeyQ(bytes: []const u8, cursor: *usize) Error![]const u8 {
    // `readBalanced` consumes against the live buffer, so a truncated list is a
    // genuine `Incomplete` (read more). `list` is then a *complete* slice, so a
    // short read while re-parsing it is malformed, not stream-incomplete.
    const list = try readBalanced(bytes, cursor, '[', ']');
    return parsePeerKeyQ(list) catch |err| switch (err) {
        Error.Incomplete => Error.MalformedFrame,
        else => |other| other,
    };
}

fn parsePeerKeyQ(list: []const u8) Error![]const u8 {
    var inner: usize = 0;
    while (inner < list.len) {
        if (list[inner] == '[') {
            var entry_cursor = inner;
            try readByte(list, &entry_cursor, '[');
            const tag = readSymbol(list, &entry_cursor) catch {
                inner += 1;
                continue;
            };
            if (std.mem.eql(u8, tag, "q")) {
                const q = try readBytes(list, &entry_cursor);
                try readByte(list, &entry_cursor, ']');
                return q;
            }
        }
        inner += 1;
    }
    return Error.MalformedFrame;
}

fn readLocator(bytes: []const u8, cursor: *usize) Error!model.PeerLocator {
    try readByte(bytes, cursor, '<');
    const tag = try readSymbol(bytes, cursor);
    if (!std.mem.eql(u8, tag, "ocapn-peer")) {
        return Error.MalformedFrame;
    }
    const transport = try readSymbol(bytes, cursor);
    const designator = try readString(bytes, cursor);
    const hints = try readHints(bytes, cursor);
    try readByte(bytes, cursor, '>');
    return .{
        .transport = transport,
        .designator = designator,
        .hints = hints,
    };
}

fn readHints(bytes: []const u8, cursor: *usize) Error!model.Hints {
    if (cursor.* >= bytes.len) return Error.Incomplete;
    if (bytes[cursor.*] == 'f') {
        cursor.* += 1;
        return model.Hints.emptyFalse();
    }
    if (bytes[cursor.*] == '{') {
        if (cursor.* + 2 > bytes.len) return Error.Incomplete;
        if (bytes[cursor.* + 1] == '}') {
            cursor.* += 2;
            return model.Hints.emptyMap();
        }
        // Non-empty hints: consumed so the frame decodes whole. The session
        // path does not surface entries (it keys off designator + session key).
        // Callers that need entries (sturdyref arguments) use the allocating
        // `readHintsOwned` path.
        _ = try readBalanced(bytes, cursor, '{', '}');
        return model.Hints.emptyMap();
    }
    return Error.MalformedFrame;
}

/// Parse hints with allocation — entries are heap-owned. Keys and values are
/// duped so the result outlives the frame. Free with `model.freeHints`.
pub fn readHintsOwned(allocator: std.mem.Allocator, bytes: []const u8, cursor: *usize) Error!model.Hints {
    if (cursor.* >= bytes.len) return Error.Incomplete;
    if (bytes[cursor.*] == 'f') {
        cursor.* += 1;
        return model.Hints.emptyFalse();
    }
    if (bytes[cursor.*] == '{') {
        if (cursor.* + 2 > bytes.len) return Error.Incomplete;
        if (bytes[cursor.* + 1] == '}') {
            cursor.* += 2;
            return model.Hints.emptyMap();
        }
        cursor.* += 1;
        var entries: std.ArrayList(model.HintEntry) = .empty;
        errdefer {
            for (entries.items) |entry| model.freeHintEntry(allocator, entry);
            entries.deinit(allocator);
        }
        while (cursor.* < bytes.len and bytes[cursor.*] != '}') {
            const name_raw = readStringOrSymbol(bytes, cursor) catch return Error.MalformedFrame;
            const value_raw = try readHintValueBorrowed(bytes, cursor);
            const name = allocator.dupe(u8, name_raw) catch return Error.MalformedFrame;
            errdefer allocator.free(name);
            const value = model.cloneHintValue(allocator, value_raw) catch return Error.MalformedFrame;
            entries.append(allocator, .{ .name = name, .value = value }) catch return Error.MalformedFrame;
        }
        try readByte(bytes, cursor, '}');
        return .{
            .entries = entries.toOwnedSlice(allocator) catch return Error.MalformedFrame,
            .empty_wire_was_false = false,
        };
    }
    return Error.MalformedFrame;
}

/// Like `readLocator` but allocates hint entries. Free the result's hints with
/// `model.freeHints`. Used for sturdyref arguments where the actor needs the
/// hints (e.g. sturdyref enlivener extracting host/port).
pub fn readLocatorOwned(allocator: std.mem.Allocator, bytes: []const u8, cursor: *usize) Error!model.PeerLocator {
    try readByte(bytes, cursor, '<');
    const tag = try readSymbol(bytes, cursor);
    if (!std.mem.eql(u8, tag, "ocapn-peer")) return Error.MalformedFrame;
    const transport = try readSymbol(bytes, cursor);
    const designator = try readString(bytes, cursor);
    const hints = try readHintsOwned(allocator, bytes, cursor);
    errdefer model.freeHints(allocator, hints);
    try readByte(bytes, cursor, '>');
    const t = allocator.dupe(u8, transport) catch return Error.MalformedFrame;
    errdefer allocator.free(t);
    const d = allocator.dupe(u8, designator) catch return Error.MalformedFrame;
    return .{ .transport = t, .designator = d, .hints = hints };
}

fn readStringOrSymbol(bytes: []const u8, cursor: *usize) Error![]const u8 {
    if (cursor.* >= bytes.len) return Error.Incomplete;
    const start = cursor.* + countDigits(bytes[cursor.*..]);
    if (start >= bytes.len) return Error.Incomplete;
    return switch (bytes[start]) {
        '"' => readString(bytes, cursor),
        '\'' => readSymbol(bytes, cursor),
        else => Error.MalformedFrame,
    };
}

fn readHintValueBorrowed(bytes: []const u8, cursor: *usize) Error!model.HintValue {
    if (cursor.* >= bytes.len) return Error.Incomplete;
    return switch (bytes[cursor.*]) {
        '0'...'9' => blk: {
            const marker_index = cursor.* + countDigits(bytes[cursor.*..]);
            if (marker_index >= bytes.len) return Error.Incomplete;
            break :blk switch (bytes[marker_index]) {
                '"' => .{ .string = try readString(bytes, cursor) },
                ':' => .{ .bytes = try readBytes(bytes, cursor) },
                '+', '-' => .{ .integer = try readInteger(bytes, cursor) },
                else => Error.MalformedFrame,
            };
        },
        't', 'f' => .{ .boolean = try readBool(bytes, cursor) },
        else => Error.MalformedFrame,
    };
}

pub fn readSignatureView(bytes: []const u8, cursor: *usize) Error!SignatureView {
    // See `readPeerKeyQ`: `list` is complete, so a short re-parse is malformed.
    const list = try readBalanced(bytes, cursor, '[', ']');
    return parseSignatureView(list) catch |err| switch (err) {
        Error.Incomplete => Error.MalformedFrame,
        else => |other| other,
    };
}

fn parseSignatureView(list: []const u8) Error!SignatureView {
    var inner: usize = 0;
    var r: ?[]const u8 = null;
    var s: ?[]const u8 = null;
    while (inner < list.len) {
        if (list[inner] == '[') {
            var entry_cursor = inner;
            try readByte(list, &entry_cursor, '[');
            const tag = readSymbol(list, &entry_cursor) catch {
                inner += 1;
                continue;
            };
            if (std.mem.eql(u8, tag, "r")) {
                r = try readBytes(list, &entry_cursor);
            } else if (std.mem.eql(u8, tag, "s")) {
                s = try readBytes(list, &entry_cursor);
            }
        }
        inner += 1;
    }
    return .{
        .r = r orelse return Error.MalformedFrame,
        .s = s orelse return Error.MalformedFrame,
    };
}

fn readOptionalPositiveInt(bytes: []const u8, cursor: *usize) Error!?u64 {
    if (cursor.* < bytes.len and bytes[cursor.*] == 'f') {
        cursor.* += 1;
        return null;
    }
    return try readPositiveInt(bytes, cursor);
}

pub fn readPositiveInt(bytes: []const u8, cursor: *usize) Error!u64 {
    const start = cursor.*;
    while (cursor.* < bytes.len and std.ascii.isDigit(bytes[cursor.*])) {
        cursor.* += 1;
    }
    if (cursor.* >= bytes.len) return Error.Incomplete;
    if (cursor.* == start or bytes[cursor.*] != '+') {
        return Error.MalformedFrame;
    }

    const value = std.fmt.parseInt(u64, bytes[start..cursor.*], 10) catch {
        return Error.MalformedFrame;
    };
    cursor.* += 1;
    return value;
}

fn readInteger(bytes: []const u8, cursor: *usize) Error!i64 {
    const start = cursor.*;
    while (cursor.* < bytes.len and std.ascii.isDigit(bytes[cursor.*])) {
        cursor.* += 1;
    }
    if (cursor.* >= bytes.len) return Error.Incomplete;
    if (cursor.* == start) {
        return Error.MalformedFrame;
    }
    // Parse the magnitude as u64, not i64: `writeSignedMagnitude` emits
    // `minInt(i64)` as the unsigned magnitude 2^63 (`9223372036854775808`), which
    // does not fit i64 — parsing it as i64 would reject a frame this codec itself
    // produced. Apply the sign afterwards, handling the minInt boundary so the
    // full i64 range round-trips and matches the Cap'n Proto codec.
    const magnitude = std.fmt.parseInt(u64, bytes[start..cursor.*], 10) catch {
        return Error.MalformedFrame;
    };
    const max_positive: u64 = @intCast(std.math.maxInt(i64));
    switch (bytes[cursor.*]) {
        '+' => {
            cursor.* += 1;
            if (magnitude > max_positive) return Error.MalformedFrame;
            return @intCast(magnitude);
        },
        '-' => {
            cursor.* += 1;
            if (magnitude == max_positive + 1) return std.math.minInt(i64);
            if (magnitude > max_positive) return Error.MalformedFrame;
            return -@as(i64, @intCast(magnitude));
        },
        else => return Error.MalformedFrame,
    }
}

fn readBool(bytes: []const u8, cursor: *usize) Error!bool {
    if (cursor.* >= bytes.len) return Error.Incomplete;
    switch (bytes[cursor.*]) {
        't' => {
            cursor.* += 1;
            return true;
        },
        'f' => {
            cursor.* += 1;
            return false;
        },
        else => return Error.MalformedFrame,
    }
}

/// Read a `'D'`-tagged `binary64` double: the marker then 8 bytes IEEE-754
/// big-endian. Advances `cursor` past all 9 bytes.
fn readFloat64(bytes: []const u8, cursor: *usize) Error!f64 {
    if (cursor.* >= bytes.len or bytes[cursor.*] != 'D') return Error.MalformedFrame;
    if (cursor.* + 9 > bytes.len) return Error.Incomplete;
    const raw = std.mem.readInt(u64, bytes[cursor.* + 1 ..][0..8], .big);
    cursor.* += 9;
    return @bitCast(raw);
}

/// Read a Syrup byte-string (`<len>:<bytes>`) at `cursor` and advance past it,
/// returning the borrowed payload. The length prefix is parsed with overflow
/// rejection and the body is bound-checked without wrappable arithmetic, so a
/// hostile length fails closed (`Incomplete` / `MalformedFrame`) rather than
/// reading out of bounds. Exposed so callers that need a raw byte-string at a
/// known offset reuse this reader instead of re-deriving the wire grammar.
pub fn readBytes(bytes: []const u8, cursor: *usize) Error![]const u8 {
    const len_start = cursor.*;
    while (cursor.* < bytes.len and std.ascii.isDigit(bytes[cursor.*])) {
        cursor.* += 1;
    }
    if (cursor.* >= bytes.len) return Error.Incomplete;
    if (cursor.* == len_start or bytes[cursor.*] != ':') {
        return Error.MalformedFrame;
    }

    const len = std.fmt.parseInt(usize, bytes[len_start..cursor.*], 10) catch {
        return Error.MalformedFrame;
    };
    cursor.* += 1;

    const body_start = cursor.*;
    if (len > bytes.len - body_start) {
        return Error.Incomplete;
    }
    const body_end = body_start + len;
    cursor.* = body_end;
    return bytes[body_start..body_end];
}

pub fn readBalanced(bytes: []const u8, cursor: *usize, open: u8, close: u8) Error![]const u8 {
    const start = cursor.*;
    try readByte(bytes, cursor, open);
    var depth: usize = 1;
    while (cursor.* < bytes.len) {
        const byte = bytes[cursor.*];
        cursor.* += 1;
        if (byte == open) {
            depth += 1;
        } else if (byte == close) {
            depth -= 1;
            if (depth == 0) {
                return bytes[start..cursor.*];
            }
        } else if (std.ascii.isDigit(byte)) {
            cursor.* -= 1;
            try skipByteStringLike(bytes, cursor);
        } else if (byte == ':' or byte == '"' or byte == '\'') {
            cursor.* -= 1;
            try skipByteStringLike(bytes, cursor);
        } else if (byte == 'D') {
            // A `D`-tagged binary64 is the marker plus 8 raw IEEE-754 payload
            // bytes (the marker is already consumed). Skip the payload as opaque
            // so a payload byte equal to `<`/`>`/`[`/`]` or a digit cannot
            // corrupt the depth count or trigger a bogus length parse.
            if (bytes.len - cursor.* < 8) return Error.Incomplete;
            cursor.* += 8;
        }
    }
    return Error.Incomplete;
}

fn skipSyrupValue(bytes: []const u8, cursor: *usize) Error!void {
    if (cursor.* >= bytes.len) return Error.Incomplete;
    switch (bytes[cursor.*]) {
        '<' => _ = try readBalanced(bytes, cursor, '<', '>'),
        '[' => _ = try readBalanced(bytes, cursor, '[', ']'),
        '{' => _ = try readBalanced(bytes, cursor, '{', '}'),
        't', 'f' => cursor.* += 1,
        // A `D`-tagged binary64: the marker plus 8 raw IEEE-754 payload bytes.
        'D' => {
            if (bytes.len - cursor.* < 9) return Error.Incomplete;
            cursor.* += 9;
        },
        '0'...'9' => try skipByteStringLike(bytes, cursor),
        else => return Error.MalformedFrame,
    }
}

fn skipByteStringLike(bytes: []const u8, cursor: *usize) Error!void {
    const len_start = cursor.*;
    while (cursor.* < bytes.len and std.ascii.isDigit(bytes[cursor.*])) {
        cursor.* += 1;
    }
    if (cursor.* >= bytes.len) return Error.Incomplete;
    if (cursor.* == len_start) {
        return Error.MalformedFrame;
    }
    const marker = bytes[cursor.*];
    if (marker == '+' or marker == '-') {
        cursor.* += 1;
        return;
    }
    if (marker != ':' and marker != '"' and marker != '\'') {
        return Error.MalformedFrame;
    }
    const len = std.fmt.parseInt(usize, bytes[len_start..cursor.*], 10) catch {
        return Error.MalformedFrame;
    };
    cursor.* += 1;
    if (len > bytes.len - cursor.*) {
        return Error.Incomplete;
    }
    cursor.* += len;
}

pub fn readByte(bytes: []const u8, cursor: *usize, expected: u8) Error!void {
    if (cursor.* >= bytes.len) return Error.Incomplete;
    if (bytes[cursor.*] != expected) return Error.MalformedFrame;
    cursor.* += 1;
}

pub fn expectEnd(bytes: []const u8, cursor: usize) Error!void {
    if (cursor != bytes.len) {
        return Error.MalformedFrame;
    }
}

fn isReferenceRecord(bytes: []const u8, cursor: usize) bool {
    return std.mem.startsWith(u8, bytes[cursor..], "<11'desc:export") or
        std.mem.startsWith(u8, bytes[cursor..], "<18'desc:import-object") or
        std.mem.startsWith(u8, bytes[cursor..], "<19'desc:import-promise") or
        std.mem.startsWith(u8, bytes[cursor..], "<11'desc:answer");
}

fn isSignedHandoffEnvelope(bytes: []const u8, cursor: usize) bool {
    return std.mem.startsWith(u8, bytes[cursor..], "<17'desc:sig-envelope");
}

/// Find the `<desc:sig-envelope <desc:handoff-give …> <sig-val …>>` record inside
/// `frame` and return its verbatim byte span, or null if the frame carries no
/// signed handoff-give. The span is the exact byte domain a recipient relays or a
/// gifter returns, so it must be reproduced unaltered. The scan honors Syrup
/// length prefixes through the codec's own value walker, so a key or signature
/// byte that happens to equal `<`, `>`, `[`, `]`, or a digit cannot truncate the
/// span — the failure mode of a naive bracket matcher. The returned slice borrows
/// `frame`.
pub fn spanSignedHandoffGive(frame: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, frame, "<17'desc:sig-envelope") orelse return null;
    var cursor = start;
    skipSyrupValue(frame, &cursor) catch return null;
    return frame[start..cursor];
}

fn countDigits(bytes: []const u8) usize {
    var count: usize = 0;
    while (count < bytes.len and std.ascii.isDigit(bytes[count])) {
        count += 1;
    }
    return count;
}

pub fn freeOwnedArgument(allocator: std.mem.Allocator, argument: model.Argument) void {
    model.freeArgument(allocator, argument);
}
