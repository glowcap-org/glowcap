//! The Syrup decoder: wire bytes to borrowed views and owned messages.
//!
//! This is the decode half of the Syrup codec. It owns the borrowed
//! codec-neutral projection (`decodeBody` / `decodePrefix`, which doubles as
//! the stream framer, see ADR-0029), the owned materializer (`decodeOwned`,
//! which is `decodeBody` followed by `model.view.Body.toOwned` — one decode
//! vocabulary, full fidelity), and the `read*` / skip/scan leaf readers beneath
//! them. Every frame here is potentially hostile, so the length math on each
//! prefix is checked, the recursive readers stop at `max_decode_nesting`, a
//! single collection stops at `max_collection_elements`, and the streaming
//! entry refuses a frame that crosses its byte cap while it is still
//! arriving. The shared `Error` set lives in `shared`; this file reads
//! bytes and holds no session authority. The encode half is `encode`.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const framing = @import("framing");

const shared = @import("shared.zig");

const Error = shared.Error;

/// Decode-time recursion bound for the neutral argument walker. The arg tree is
/// attacker-controlled, and slicing a nested `list` / `set` / `user-record`
/// recurses one native frame per level, so an unbounded nesting depth is a
/// one-frame stack overflow during decode — *before* the session's
/// authority-level `SessionLimits.max_nesting_depth` (default 64) can reject
/// it. This cap fails such a frame loud as `MalformedFrame` instead. It sits
/// well above the session cap so it never rejects a frame authority would
/// admit; a frame deeper than the session cap but shallower than this still
/// decodes and is rejected by validation as `resource_exhausted`.
const max_decode_nesting: usize = 512;

/// Decode-time width bound for a single `list` / `set` / `struct` collection —
/// the width sibling of `max_decode_nesting`. Collection width is
/// attacker-controlled, and every later walk over a collection — the lazy
/// view's `len`/`at`, session validation, owned materialization — is linear in
/// the element count, so width needs an explicit bound rather than being an
/// emergent property of whatever byte cap a deployment configures. An
/// over-wide collection fails loud as `MalformedFrame` during the slice walk,
/// before any of those walks run. The bound sits just above what the *default*
/// streaming byte cap can even carry (one-byte elements under the 1 MiB
/// `max_frame_bytes`), so on the streaming path with default limits the byte
/// cap's `.too_large` verdict always fires first (the ADR-0041 contract the
/// C ABI pins); this cap binds the uncapped whole-frame entry points and any
/// deployment that raises the byte cap. Ordinary CapTP messages carry a
/// handful of arguments, six orders of magnitude below it.
const max_collection_elements: usize = 1 << 20;

/// Byte-position cap threaded through the decode walk. Whole-frame entry
/// points (`decodeBody`, the owned readers, re-parses of already-bounded
/// sub-slices) pass this no-op limit; only the streaming `decodePrefix`
/// passes its `max_frame_bytes`, so a length prefix that declares a body past
/// the cap fails `FrameTooLarge` the moment the prefix is read — per ADR-0029
/// the in-flight frame is refused *during* decode, not after the adapter has
/// buffered the whole cap.
const no_limit: usize = std.math.maxInt(usize);

/// Borrowed reference descriptor exactly as the wire carries it, before the
/// projection into the codec-neutral `model.view.Reference`.
pub const ReferenceView = union(enum) {
    near: model.NearRef,
    far: model.FarRef,
    promise: model.PromiseRef,
    sturdy: SturdyRefView,

    pub const SturdyRefView = struct {
        peer: model.PeerLocator,
        swissnum: []const u8,
    };
};

/// The two halves of a decoded `sig-val` record, borrowed from the frame.
pub const SignatureView = struct {
    r: []const u8,
    s: []const u8,

    pub fn len(self: SignatureView) usize {
        return self.r.len + self.s.len;
    }
};

/// Materialize an owned `model.Message` from a complete `frame`: the
/// borrowed codec-neutral projection (`decodeBody`) followed by
/// `model.view.Body.toOwned`. One decode vocabulary — every *argument* arm the
/// encoder emits reads back with full fidelity (strings stay strings, symbols
/// stay symbols, numeric/list/set/tagged arms included), mirroring
/// `capnp.decodeOwned` and the symmetric-refusal posture of ADR-0003. Locator
/// hints are the one exception: this path consumes a non-empty hints map and
/// projects it as empty; hint entries survive only through the allocating
/// `readLocatorOwned`.
pub fn decodeOwned(allocator: std.mem.Allocator, frame: foundation.FrameView) !model.Message {
    return (try decodeBody(frame)).toOwned(allocator);
}

// ── Codec-neutral view projection ────────────────────────────────────────────
//
// `decodeBody` projects the borrowed codec-neutral `model.view.Body` over the
// frame's bytes — the single message shape the engine dispatches on. The
// unbounded sequences (`Args`, `PositionList`) are reached through inline
// vtable backings whose `Ctx.bytes` borrow the list region; `at` re-walks the
// Syrup bytes lazily. Argument projection is full fidelity — every arm the
// encoder emits decodes back. The backings re-walk a region that already
// framed successfully, so they pass `no_limit`.

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
        _ = readNeutralArgument(ctx.bytes, &cursor, 0, no_limit) catch return error.MalformedView;
    }
    return total;
}

fn neutralArgsAt(ctx: model.view.Args.Ctx, index: usize) model.view.ProjectError!model.view.Argument {
    var cursor: usize = 0;
    var current: usize = 0;
    while (cursor < ctx.bytes.len) : (current += 1) {
        const argument = readNeutralArgument(ctx.bytes, &cursor, 0, no_limit) catch return error.MalformedView;
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
    const argument = readNeutralArgument(ctx.bytes, &c, 0, no_limit) catch return error.MalformedView;
    cursor.* = @intCast(c);
    return argument;
}

fn neutralPositionsLen(ctx: model.view.PositionList.Ctx) model.view.ProjectError!usize {
    var cursor: usize = 0;
    var total: usize = 0;
    while (cursor < ctx.bytes.len) : (total += 1) {
        _ = readPositiveInt(ctx.bytes, &cursor) catch return error.MalformedView;
    }
    return total;
}

fn neutralPositionsAt(ctx: model.view.PositionList.Ctx, index: usize) model.view.ProjectError!u64 {
    var cursor: usize = 0;
    var current: usize = 0;
    while (cursor < ctx.bytes.len) : (current += 1) {
        const value = readPositiveInt(ctx.bytes, &cursor) catch return error.MalformedView;
        if (current == index) return value;
    }
    return error.MalformedView;
}

fn neutralPositionsNext(ctx: model.view.PositionList.Ctx, cursor: *u64) model.view.ProjectError!?u64 {
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
        .promise => |promise| .{ .promise = .{ .answer_position = promise.answer_position } },
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

/// Project one borrowed full-fidelity `model.view.Argument` and advance
/// `cursor` past it. Nested `list` / `set` / `tagged` arms project lazily as
/// backed `model.view.Args` over their byte sub-region.
fn readNeutralArgument(bytes: []const u8, cursor: *usize, depth: usize, limit: usize) Error!model.view.Argument {
    if (depth > max_decode_nesting) return Error.MalformedFrame;
    // A frame built of many small elements crosses the cap one element at a
    // time; refuse as soon as the walk passes it instead of after a full decode.
    if (cursor.* > limit) return Error.FrameTooLarge;
    if (cursor.* >= bytes.len) return Error.Incomplete;
    return switch (bytes[cursor.*]) {
        '0'...'9' => blk: {
            const marker_index = cursor.* + countDigits(bytes[cursor.*..]);
            if (marker_index >= bytes.len) return Error.Incomplete;
            break :blk switch (bytes[marker_index]) {
                ':' => .{ .bytes = try readBytesLimited(bytes, cursor, limit) },
                '"' => .{ .string = try readStringLimited(bytes, cursor, limit) },
                '\'' => .{ .symbol = try readSymbolLimited(bytes, cursor, limit) },
                '+', '-' => try readIntegerArgument(bytes, cursor),
                else => Error.UnsupportedArgument,
            };
        },
        't', 'f' => .{ .boolean = try readBool(bytes, cursor) },
        'D' => .{ .float64 = try readFloat64(bytes, cursor) },
        '[' => .{ .list = neutralArgs(try sliceArgumentListNeutral(bytes, cursor, depth + 1, limit)) },
        '#' => .{ .set = neutralArgs(try sliceSetNeutral(bytes, cursor, depth + 1, limit)) },
        '{' => .{ .@"struct" = neutralStructEntries(try sliceStructNeutral(bytes, cursor, depth + 1, limit)) },
        '<' => blk: {
            if (isSignedHandoffEnvelope(bytes, cursor.*)) {
                break :blk .{ .handoff = try readBorrowedSignedHandoff(bytes, cursor, limit) };
            }
            if (isReferenceRecord(bytes, cursor.*)) {
                break :blk .{ .reference = neutralReference(try readReference(bytes, cursor, limit)) };
            }
            try readByte(bytes, cursor, '<');
            const tag = try readSymbolLimited(bytes, cursor, limit);
            if (std.mem.eql(u8, tag, "void")) {
                try readByte(bytes, cursor, '>');
                break :blk .{ .void = {} };
            }
            if (std.mem.eql(u8, tag, "error")) {
                const message = try readStringLimited(bytes, cursor, limit);
                try readByte(bytes, cursor, '>');
                break :blk .{ .@"error" = .{ .message = message } };
            }
            if (std.mem.eql(u8, tag, "user-record")) {
                const record_tag = try readSymbolLimited(bytes, cursor, limit);
                const value_body = try sliceArgumentListNeutral(bytes, cursor, depth + 1, limit);
                try readByte(bytes, cursor, '>');
                break :blk .{ .tagged = .{ .tag = record_tag, .value = neutralArgs(value_body) } };
            }
            if (std.mem.eql(u8, tag, "kw")) {
                const name = try readSymbolLimited(bytes, cursor, limit);
                try readByte(bytes, cursor, '>');
                break :blk .{ .keyword = name };
            }
            if (std.mem.eql(u8, tag, "ocapn-sturdyref")) {
                const peer_locator = try readLocator(bytes, cursor, limit);
                const swissnum = try readBytesLimited(bytes, cursor, limit);
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

/// Slice one delimited sequence body (between `open` and `close`) using the
/// full-fidelity walker, advancing `cursor` past the closing delimiter. The
/// list and set slicers share this one walk and differ only in their
/// delimiters. `depth` is the nesting level entered (bounded by
/// `max_decode_nesting`); width is bounded by `max_collection_elements`.
fn sliceSequenceNeutral(
    bytes: []const u8,
    cursor: *usize,
    depth: usize,
    limit: usize,
    comptime open: u8,
    comptime close: u8,
) Error![]const u8 {
    try readByte(bytes, cursor, open);
    const body_start = cursor.*;
    var elements: usize = 0;
    while (cursor.* < bytes.len and bytes[cursor.*] != close) {
        elements += 1;
        if (elements > max_collection_elements) return Error.MalformedFrame;
        _ = try readNeutralArgument(bytes, cursor, depth, limit);
    }
    if (cursor.* >= bytes.len) return Error.Incomplete;
    const body = bytes[body_start..cursor.*];
    cursor.* += 1;
    return body;
}

/// Slice a `[ … ]` argument list body, advancing `cursor` past the closing `]`.
fn sliceArgumentListNeutral(bytes: []const u8, cursor: *usize, depth: usize, limit: usize) Error![]const u8 {
    return sliceSequenceNeutral(bytes, cursor, depth, limit, '[', ']');
}

/// Slice a `# … $` set body, advancing `cursor` past the closing `$`.
fn sliceSetNeutral(bytes: []const u8, cursor: *usize, depth: usize, limit: usize) Error![]const u8 {
    return sliceSequenceNeutral(bytes, cursor, depth, limit, '#', '$');
}

/// Slice a `{ … }` dictionary body (between the braces) into the bytes the lazy
/// struct backing walks, advancing `cursor` past the closing `}`. The walk
/// enforces the OCapN Struct grammar at the codec boundary (Model.md § Struct):
/// every key must be a String, and no key may repeat. A non-String key fails when
/// the key read demands the `"` marker. Canonical Syrup orders dictionary
/// entries by the fully-encoded key, lowest octets first (the upstream
/// draft-specification's Sorting Algorithm), and every encoder this decoder
/// faces — the upstream Racket encoder Goblins and the fixture corpus use, the
/// conformance suite's Python encoder, and this codec's own `writeStruct` —
/// emits that order. So each key's encoded span need only compare against the
/// previous one: a non-ascending key is a non-canonical wire spelling of the
/// message, refused like a non-canonical length digit, and a duplicate key
/// (ADR-0046) is never strictly ascending, so the same O(1) comparison refuses
/// it without re-walking the prior entries.
fn sliceStructNeutral(bytes: []const u8, cursor: *usize, depth: usize, limit: usize) Error![]const u8 {
    if (depth > max_decode_nesting) return Error.MalformedFrame;
    try readByte(bytes, cursor, '{');
    const body_start = cursor.*;
    var previous_key_encoded: ?[]const u8 = null;
    var entries: usize = 0;
    while (cursor.* < bytes.len and bytes[cursor.*] != '}') {
        entries += 1;
        if (entries > max_collection_elements) return Error.MalformedFrame;
        const key_start = cursor.*;
        _ = try readStringLimited(bytes, cursor, limit);
        const key_encoded = bytes[key_start..cursor.*];
        if (previous_key_encoded) |previous| {
            if (std.mem.order(u8, previous, key_encoded) != .lt) return Error.MalformedFrame;
        }
        previous_key_encoded = key_encoded;
        _ = try readNeutralArgument(bytes, cursor, depth, limit);
    }
    if (cursor.* >= bytes.len) return Error.Incomplete;
    const body = bytes[body_start..cursor.*];
    cursor.* += 1;
    return body;
}

const neutral_struct_vtable = model.view.StructEntries.VTable{
    .len = neutralStructLen,
    .at = neutralStructAt,
    .next = neutralStructNext,
};

fn neutralStructLen(ctx: model.view.StructEntries.Ctx) model.view.ProjectError!usize {
    var cursor: usize = 0;
    var total: usize = 0;
    while (cursor < ctx.bytes.len) : (total += 1) {
        _ = readStructEntry(ctx.bytes, &cursor) catch return error.MalformedView;
    }
    return total;
}

fn neutralStructAt(ctx: model.view.StructEntries.Ctx, index: usize) model.view.ProjectError!model.view.StructEntry {
    var cursor: usize = 0;
    var current: usize = 0;
    while (cursor < ctx.bytes.len) : (current += 1) {
        const entry = readStructEntry(ctx.bytes, &cursor) catch return error.MalformedView;
        if (current == index) return entry;
    }
    return error.MalformedView;
}

fn neutralStructNext(ctx: model.view.StructEntries.Ctx, cursor: *u64) model.view.ProjectError!?model.view.StructEntry {
    var c: usize = @intCast(cursor.*);
    if (c >= ctx.bytes.len) return null;
    const entry = readStructEntry(ctx.bytes, &c) catch return error.MalformedView;
    cursor.* = @intCast(c);
    return entry;
}

/// Read one (String key, Value) pair from a struct body and advance `cursor`. The
/// body was validated at slice time, so a read failure here is `MalformedView`.
fn readStructEntry(bytes: []const u8, cursor: *usize) Error!model.view.StructEntry {
    const key = try readStringLimited(bytes, cursor, no_limit);
    const value = try readNeutralArgument(bytes, cursor, 0, no_limit);
    return .{ .key = key, .value = value };
}

fn neutralStructEntries(struct_body: []const u8) model.view.StructEntries {
    return model.view.StructEntries.fromBacking(.{ .bytes = struct_body }, &neutral_struct_vtable);
}

fn readNeutralResolution(bytes: []const u8, cursor: *usize, limit: usize) Error!model.view.Resolution {
    try readByte(bytes, cursor, '<');
    const tag = try readSymbolLimited(bytes, cursor, limit);
    if (std.mem.eql(u8, tag, "resolve:fulfill")) {
        const argument = try readNeutralArgument(bytes, cursor, 0, limit);
        try readByte(bytes, cursor, '>');
        return .{ .fulfill = argument };
    }
    if (std.mem.eql(u8, tag, "resolve:break")) {
        const err = try readError(bytes, cursor, limit);
        try readByte(bytes, cursor, '>');
        return .{ .@"break" = .{ .message = err.message } };
    }
    return Error.MalformedFrame;
}

/// Project the borrowed codec-neutral `model.view.Body` over a complete
/// `frame`. A frame is exactly one message with no trailing bytes; a short
/// read is therefore a malformed frame here. Streaming callers with incomplete
/// input use `decodePrefix`, which shares the same parser.
pub fn decodeBody(frame: foundation.FrameView) Error!model.view.Body {
    if (frame.shape != .byte) return Error.InvalidFrameShape;

    var cursor: usize = 0;
    const body = decodeBodyAt(frame.bytes, &cursor, no_limit) catch |err| switch (err) {
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
/// `max_frame_bytes` caps an accepted frame, and the cap is enforced *during*
/// the decode (ADR-0029): a length prefix that declares a body past the cap is
/// refused `.too_large` the moment the prefix is read — before those bytes ever
/// arrive — and a walk that crosses the cap element by element is refused as it
/// crosses. A frame that is merely longer than `bytes` (still arriving, within
/// the cap) reports `.incomplete`; an incomplete prefix already *longer* than
/// the cap can never complete within it, so it is `.too_large`, never
/// `.incomplete` — streaming callers bound their buffering on exactly this
/// (ADR-0041), so it is a contract, not a courtesy.
pub fn decodePrefix(bytes: []const u8, max_frame_bytes: usize) framing.Prefix {
    var cursor: usize = 0;
    const body = decodeBodyAt(bytes, &cursor, max_frame_bytes) catch |err| switch (err) {
        // The in-walk checks fire at element entries, so a prefix can run out
        // a few leaf bytes past the cap without crossing one; ratify here.
        Error.Incomplete => return if (bytes.len > max_frame_bytes) .too_large else .incomplete,
        Error.FrameTooLarge => return .too_large,
        else => return .malformed,
    };
    // Backstop for the fixed-width trailing leaves (ints, bools, floats) the
    // in-walk checks don't cover individually: ratify the final length.
    if (cursor > max_frame_bytes) return .too_large;
    return .{ .decoded = .{ .body = body, .consumed = cursor } };
}

/// Decode exactly one message starting at `cursor.*`, advancing `cursor` to the
/// byte just past it and leaving any trailing bytes untouched. The cursor it
/// leaves *is* the frame boundary. `Error.Incomplete` means the buffer ends
/// mid-message (read more); `Error.FrameTooLarge` means the message cannot fit
/// inside `limit` bytes no matter how many more arrive; every other error means
/// the bytes are structurally invalid regardless of how many more arrive.
fn decodeBodyAt(bytes: []const u8, cursor: *usize, limit: usize) Error!model.view.Body {
    const message_start = cursor.*;
    try readByte(bytes, cursor, '<');
    const op = try readSymbolLimited(bytes, cursor, limit);

    // Dispatch by op symbol over the message-kind tag set. Both the op string
    // (`shared.messageOp`) and the decoder (`decoderFor`) are exhaustive
    // switches over `std.meta.Tag(model.Message)`, so a new kind cannot compile
    // without a wire op *and* a decoder — the silent fall-through that let the
    // encoder's exhaustive switch drift ahead of the decoder is gone.
    inline for (std.meta.fields(std.meta.Tag(model.Message))) |field| {
        const kind: std.meta.Tag(model.Message) = @enumFromInt(field.value);
        if (std.mem.eql(u8, op, comptime shared.messageOp(kind))) {
            return decoderFor(kind)(bytes, cursor, limit, message_start);
        }
    }

    return Error.UnsupportedMessage;
}

/// One decoder reads one message body from just past its op symbol, advancing
/// `cursor` to the byte after the closing `>`. `message_start` is the offset of
/// the opening `<`; only the handoff decoder needs it (it re-parses the whole
/// signed envelope from there), but every decoder takes it so the dispatch
/// table is one uniform function-pointer type.
const OpDecoder = *const fn (bytes: []const u8, cursor: *usize, limit: usize, message_start: usize) Error!model.view.Body;

fn decoderFor(comptime kind: std.meta.Tag(model.Message)) OpDecoder {
    return switch (kind) {
        .abort => decodeAbortBody,
        .deliver => decodeDeliverBody,
        .resolve => decodeResolveBody,
        .gc_export => decodeGcExportBody,
        .gc_answer => decodeGcAnswerBody,
        .get => decodeGetBody,
        .index => decodeIndexBody,
        .untag => decodeUntagBody,
        .listen => decodeListenBody,
        .start_session => decodeStartSessionBody,
        .handoff => decodeHandoffBody,
    };
}

fn decodeAbortBody(bytes: []const u8, cursor: *usize, limit: usize, message_start: usize) Error!model.view.Body {
    _ = message_start;
    const message = try readStringLimited(bytes, cursor, limit);
    try readByte(bytes, cursor, '>');
    const abort = parseAbortWireString(message);
    return .{ .abort = .{ .kind = abort.kind, .message = abort.message } };
}

fn decodeDeliverBody(bytes: []const u8, cursor: *usize, limit: usize, message_start: usize) Error!model.view.Body {
    _ = message_start;
    const target = try readReference(bytes, cursor, limit);
    const args_body = try sliceArgumentListNeutral(bytes, cursor, 0, limit);
    const answer = try readOptionalPositiveInt(bytes, cursor);
    const resolve_me_desc = try readOptionalReference(bytes, cursor, limit);
    try readByte(bytes, cursor, '>');
    return .{ .deliver = .{
        .target = neutralReference(target),
        .args = neutralArgs(args_body),
        .answer = answer,
        .resolve_me_desc = if (resolve_me_desc) |reference| neutralReference(reference) else null,
    } };
}

fn decodeResolveBody(bytes: []const u8, cursor: *usize, limit: usize, message_start: usize) Error!model.view.Body {
    _ = message_start;
    const answer = try readPositiveInt(bytes, cursor);
    const resolution = try readNeutralResolution(bytes, cursor, limit);
    try readByte(bytes, cursor, '>');
    return .{ .resolve = .{ .answer = answer, .resolution = resolution } };
}

fn decodeGcExportBody(bytes: []const u8, cursor: *usize, limit: usize, message_start: usize) Error!model.view.Body {
    _ = message_start;
    const positions = try readPositionList(bytes, cursor, limit);
    const deltas = try readPositionList(bytes, cursor, limit);
    try readByte(bytes, cursor, '>');
    return .{ .gc_export = .{
        .positions = neutralPositions(positions),
        .deltas = neutralPositions(deltas),
    } };
}

fn decodeGcAnswerBody(bytes: []const u8, cursor: *usize, limit: usize, message_start: usize) Error!model.view.Body {
    _ = message_start;
    const positions = try readPositionList(bytes, cursor, limit);
    try readByte(bytes, cursor, '>');
    return .{ .gc_answer = .{ .positions = neutralPositions(positions) } };
}

fn decodeGetBody(bytes: []const u8, cursor: *usize, limit: usize, message_start: usize) Error!model.view.Body {
    _ = message_start;
    const receiver = try readReference(bytes, cursor, limit);
    // A String per the spec (and what Goblins sends); see the encoder.
    const field = try readStringLimited(bytes, cursor, limit);
    const answer = try readPositiveInt(bytes, cursor);
    try readByte(bytes, cursor, '>');
    return .{ .get = .{ .receiver = neutralReference(receiver), .field = field, .answer = answer } };
}

fn decodeIndexBody(bytes: []const u8, cursor: *usize, limit: usize, message_start: usize) Error!model.view.Body {
    _ = message_start;
    const receiver = try readReference(bytes, cursor, limit);
    const index = try readInteger(bytes, cursor);
    const answer = try readPositiveInt(bytes, cursor);
    try readByte(bytes, cursor, '>');
    return .{ .index = .{ .receiver = neutralReference(receiver), .index = index, .answer = answer } };
}

fn decodeUntagBody(bytes: []const u8, cursor: *usize, limit: usize, message_start: usize) Error!model.view.Body {
    _ = message_start;
    const receiver = try readReference(bytes, cursor, limit);
    // A String per the spec; see the encoder.
    const tag = try readStringLimited(bytes, cursor, limit);
    const answer = try readPositiveInt(bytes, cursor);
    try readByte(bytes, cursor, '>');
    return .{ .untag = .{ .receiver = neutralReference(receiver), .tag = tag, .answer = answer } };
}

fn decodeListenBody(bytes: []const u8, cursor: *usize, limit: usize, message_start: usize) Error!model.view.Body {
    _ = message_start;
    const target = try readReference(bytes, cursor, limit);
    const listener = try readReference(bytes, cursor, limit);
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

fn decodeStartSessionBody(bytes: []const u8, cursor: *usize, limit: usize, message_start: usize) Error!model.view.Body {
    _ = message_start;
    const version_wire = try readStringLimited(bytes, cursor, limit);
    const captp_version = model.CaptpVersion.fromWireString(version_wire) orelse return Error.MalformedFrame;
    const session_pubkey = try readPeerKeyQ(bytes, cursor, limit);
    // Span the exact `<ocapn-peer …>` location-record bytes around the read so
    // a verifier checks the signature over what was received, not a re-encode.
    const location_start = cursor.*;
    const acceptable_location = try readLocator(bytes, cursor, limit);
    const location_raw = bytes[location_start..cursor.*];
    const acceptable_location_sig = try readSignatureViewLimited(bytes, cursor, limit);
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

fn decodeHandoffBody(bytes: []const u8, cursor: *usize, limit: usize, message_start: usize) Error!model.view.Body {
    // The signed-handoff reader re-parses the whole envelope from where this
    // message began, so its cursor — not the outer one — marks the message end.
    var envelope_cursor: usize = message_start;
    const handoff = try readBorrowedSignedHandoff(bytes, &envelope_cursor, limit);
    cursor.* = envelope_cursor;
    return .{ .handoff = handoff };
}

/// Turn a V1.0 abort wire string back into a typed reason. V1.0 writes aborts
/// as `"<Label>: <message>"`. If the label is one the model recognizes, that
/// kind is recovered; otherwise the whole string is kept as an `.other` reason.
/// The inverse lives beside this in `encode`: `writeAbortWireString` builds
/// the `"<label>: <message>"` form from `kind.wireName()` — the codec owns the
/// wire string format in both directions, the model only the typed reason.
fn parseAbortWireString(wire: []const u8) model.AbortReason {
    if (std.mem.indexOf(u8, wire, ": ")) |split| {
        if (model.AbortKind.fromWireName(wire[0..split])) |kind| {
            return .{ .kind = kind, .message = wire[split + 2 ..] };
        }
    }
    return .{ .kind = .other, .message = wire };
}

fn readBorrowedSignedHandoff(bytes: []const u8, cursor: *usize, limit: usize) Error!model.view.Handoff {
    const envelope_start = cursor.*;
    try readByte(bytes, cursor, '<');
    const envelope_tag = try readSymbolLimited(bytes, cursor, limit);
    if (!std.mem.eql(u8, envelope_tag, "desc:sig-envelope")) return Error.MalformedFrame;

    try readByte(bytes, cursor, '<');
    const payload_tag = try readSymbolLimited(bytes, cursor, limit);

    if (std.mem.eql(u8, payload_tag, "desc:handoff-give")) {
        var give = try readBorrowedHandoffGivePayload(bytes, cursor, limit);
        try readByte(bytes, cursor, '>');
        const sig = try readSignatureViewLimited(bytes, cursor, limit);
        give.signature = .{ .halves = .{ .r = sig.r, .s = sig.s } };
        try readByte(bytes, cursor, '>');
        give.raw_signed = bytes[envelope_start..cursor.*];
        return .{ .give = give };
    }

    if (std.mem.eql(u8, payload_tag, "desc:handoff-receive")) {
        var receive = try readBorrowedHandoffReceivePayload(bytes, cursor, limit);
        try readByte(bytes, cursor, '>');
        const sig = try readSignatureViewLimited(bytes, cursor, limit);
        receive.signature = .{ .halves = .{ .r = sig.r, .s = sig.s } };
        try readByte(bytes, cursor, '>');
        return .{ .receive = receive };
    }

    return Error.UnsupportedMessage;
}

fn readBorrowedHandoffGivePayload(bytes: []const u8, cursor: *usize, limit: usize) Error!model.view.HandoffGive {
    const recipient_key = try readPeerKeyQ(bytes, cursor, limit);
    // Capture the verbatim `<ocapn-peer …>` span so a consumer can recover hint
    // entries the borrowed session reader discards. A real Goblins give writes
    // `#f` hints (no entries); an exporter reachable only by direct address
    // names them here, and the redeem projection re-parses this span to dial.
    const locator_start = cursor.*;
    const locator = try readLocator(bytes, cursor, limit);
    const locator_record = bytes[locator_start..cursor.*];
    const gifter_exporter_session = try readBytesLimited(bytes, cursor, limit);
    const gifter_side = try readBytesLimited(bytes, cursor, limit);
    const gift_id = try readBytesLimited(bytes, cursor, limit);
    return .{
        .recipient_key = recipient_key,
        .exporter_location = .{ .locator = .{ .transport = locator.transport, .designator = locator.designator, .record = locator_record } },
        .gifter_exporter_session = gifter_exporter_session,
        .gifter_side = gifter_side,
        .gift_id = gift_id,
        // Filled by the envelope wrapper from the trailing `sig-val`.
        .signature = .{ .raw = &.{} },
    };
}

fn readBorrowedHandoffReceivePayload(bytes: []const u8, cursor: *usize, limit: usize) Error!model.view.HandoffReceive {
    const receiving_session = try readBytesLimited(bytes, cursor, limit);
    const receiving_side = try readBytesLimited(bytes, cursor, limit);
    const handoff_count = try readPositiveInt(bytes, cursor);
    const signed = try readBorrowedSignedHandoff(bytes, cursor, limit);
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

/// Read one length-prefixed Syrup leaf — `<len><marker><payload>` — at
/// `cursor`, advancing past it and returning the borrowed payload. The three
/// leaf kinds share this one reader and differ only in their `marker` byte:
/// `:` for byte-strings, `"` for strings, `'` for symbols. The length digits
/// are canonical-checked and parsed with overflow rejection, and the body is
/// bound-checked without wrappable arithmetic, so a hostile length fails
/// closed (`Incomplete` / `MalformedFrame` / `FrameTooLarge`) rather than
/// reading out of bounds.
fn readLengthPrefixed(bytes: []const u8, cursor: *usize, comptime marker: u8, limit: usize) Error![]const u8 {
    const len_start = cursor.*;
    while (cursor.* < bytes.len and std.ascii.isDigit(bytes[cursor.*])) {
        cursor.* += 1;
    }
    if (cursor.* >= bytes.len) return Error.Incomplete;
    if (cursor.* == len_start or bytes[cursor.*] != marker) {
        return Error.MalformedFrame;
    }
    try rejectNonCanonicalDigits(bytes, len_start, cursor.*);

    const len = std.fmt.parseInt(usize, bytes[len_start..cursor.*], 10) catch {
        return Error.MalformedFrame;
    };
    cursor.* += 1;

    const body_start = cursor.*;
    if (len > limit -| body_start) return Error.FrameTooLarge;
    if (len > bytes.len - body_start) {
        return Error.Incomplete;
    }
    const body_end = body_start + len;
    cursor.* = body_end;
    return bytes[body_start..body_end];
}

fn readString(bytes: []const u8, cursor: *usize) Error![]const u8 {
    return readStringLimited(bytes, cursor, no_limit);
}

fn readStringLimited(bytes: []const u8, cursor: *usize, limit: usize) Error![]const u8 {
    return readLengthPrefixed(bytes, cursor, '"', limit);
}

pub fn readSymbol(bytes: []const u8, cursor: *usize) Error![]const u8 {
    return readSymbolLimited(bytes, cursor, no_limit);
}

fn readSymbolLimited(bytes: []const u8, cursor: *usize, limit: usize) Error![]const u8 {
    return readLengthPrefixed(bytes, cursor, '\'', limit);
}

/// Read a `[ … ]` list of positive ints, returning the borrowed body slice
/// between the brackets and advancing `cursor` past the closing `]`. Width is
/// bounded by `max_collection_elements` and the walk refuses to cross `limit`,
/// like its sibling collection readers.
fn readPositionList(bytes: []const u8, cursor: *usize, limit: usize) Error![]const u8 {
    try readByte(bytes, cursor, '[');
    const body_start = cursor.*;
    var elements: usize = 0;
    while (cursor.* < bytes.len and bytes[cursor.*] != ']') {
        elements += 1;
        if (elements > max_collection_elements) return Error.MalformedFrame;
        if (cursor.* > limit) return Error.FrameTooLarge;
        _ = try readPositiveInt(bytes, cursor);
    }
    if (cursor.* >= bytes.len) {
        return Error.Incomplete;
    }

    const body = bytes[body_start..cursor.*];
    cursor.* += 1;
    return body;
}

/// Decode a payload/target-position descriptor into a reference in the
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
fn readReference(bytes: []const u8, cursor: *usize, limit: usize) Error!ReferenceView {
    try readByte(bytes, cursor, '<');
    const tag = try readSymbolLimited(bytes, cursor, limit);
    if (std.mem.eql(u8, tag, "desc:export")) {
        const export_position = try readPositiveInt(bytes, cursor);
        try readByte(bytes, cursor, '>');
        return .{ .near = .{ .export_position = export_position, .kind = .object } };
    }
    if (std.mem.eql(u8, tag, "desc:import-object")) {
        const import_position = try readPositiveInt(bytes, cursor);
        try readByte(bytes, cursor, '>');
        return .{ .far = .{ .import_position = import_position, .kind = .object } };
    }
    if (std.mem.eql(u8, tag, "desc:import-promise")) {
        const import_position = try readPositiveInt(bytes, cursor);
        try readByte(bytes, cursor, '>');
        return .{ .far = .{ .import_position = import_position, .kind = .promise } };
    }
    if (std.mem.eql(u8, tag, "desc:answer")) {
        const answer_position = try readPositiveInt(bytes, cursor);
        try readByte(bytes, cursor, '>');
        return .{ .promise = .{ .answer_position = answer_position } };
    }
    return Error.UnsupportedReference;
}

fn readOptionalReference(bytes: []const u8, cursor: *usize, limit: usize) Error!?ReferenceView {
    if (cursor.* < bytes.len and bytes[cursor.*] == 'f') {
        cursor.* += 1;
        return null;
    }
    return try readReference(bytes, cursor, limit);
}

fn readError(bytes: []const u8, cursor: *usize, limit: usize) Error!model.BreakReason {
    try readByte(bytes, cursor, '<');
    const tag = try readSymbolLimited(bytes, cursor, limit);
    if (!std.mem.eql(u8, tag, "error")) {
        return Error.MalformedFrame;
    }
    const message = try readStringLimited(bytes, cursor, limit);
    try readByte(bytes, cursor, '>');
    return .{ .message = message };
}

fn readPeerKeyQ(bytes: []const u8, cursor: *usize, limit: usize) Error![]const u8 {
    // `readBalanced` consumes against the live buffer, so a truncated list is a
    // genuine `Incomplete` (read more). `list` is then a *complete* slice, so a
    // short read while re-parsing it is malformed, not stream-incomplete.
    const list = try readBalancedLimited(bytes, cursor, '[', ']', limit);
    return parsePeerKeyQ(list) catch |err| switch (err) {
        Error.Incomplete => Error.MalformedFrame,
        else => |other| other,
    };
}

/// Parse the spec-pinned public-key record (CapTP spec § Public Key):
///
/// ```text
/// ['public-key ['ecc ['curve 'Ed25519] ['flags 'eddsa] ['q q_value]]]
/// ```
///
/// The grammar is matched exactly, algorithm tags included. A record that
/// claims any other curve or scheme is refused as malformed: accepting it and
/// then verifying its `q` as an Ed25519 key would silently coerce the claimed
/// algorithm — exactly the mis-decode ADR-0003's symmetric refusal forbids.
fn parsePeerKeyQ(list: []const u8) Error![]const u8 {
    var cursor: usize = 0;
    try readByte(list, &cursor, '[');
    try expectSymbol(list, &cursor, "public-key");
    try readByte(list, &cursor, '[');
    try expectSymbol(list, &cursor, "ecc");
    try readByte(list, &cursor, '[');
    try expectSymbol(list, &cursor, "curve");
    try expectSymbol(list, &cursor, "Ed25519");
    try readByte(list, &cursor, ']');
    try readByte(list, &cursor, '[');
    try expectSymbol(list, &cursor, "flags");
    try expectSymbol(list, &cursor, "eddsa");
    try readByte(list, &cursor, ']');
    try readByte(list, &cursor, '[');
    try expectSymbol(list, &cursor, "q");
    const q = try readBytes(list, &cursor);
    try readByte(list, &cursor, ']');
    try readByte(list, &cursor, ']');
    try readByte(list, &cursor, ']');
    try expectEnd(list, cursor);
    return q;
}

fn expectSymbol(bytes: []const u8, cursor: *usize, expected: []const u8) Error!void {
    const symbol = try readSymbol(bytes, cursor);
    if (!std.mem.eql(u8, symbol, expected)) return Error.MalformedFrame;
}

fn readLocator(bytes: []const u8, cursor: *usize, limit: usize) Error!model.PeerLocator {
    try readByte(bytes, cursor, '<');
    const tag = try readSymbolLimited(bytes, cursor, limit);
    if (!std.mem.eql(u8, tag, "ocapn-peer")) {
        return Error.MalformedFrame;
    }
    const transport = try readSymbolLimited(bytes, cursor, limit);
    const designator = try readStringLimited(bytes, cursor, limit);
    const hints = try readHints(bytes, cursor, limit);
    try readByte(bytes, cursor, '>');
    return .{
        .transport = transport,
        .designator = designator,
        .hints = hints,
    };
}

fn readHints(bytes: []const u8, cursor: *usize, limit: usize) Error!model.Hints {
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
        _ = try readBalancedLimited(bytes, cursor, '{', '}', limit);
        return model.Hints.emptyMap();
    }
    return Error.MalformedFrame;
}

/// Parse hints with allocation — entries are heap-owned. Keys and values are
/// duped so the result outlives the frame. Free with `model.freeHints`.
/// Allocation failure propagates as `OutOfMemory`, never as a frame error:
/// running out of heap is not evidence the partner sent hostile bytes.
pub fn readHintsOwned(allocator: std.mem.Allocator, bytes: []const u8, cursor: *usize) shared.WalkError!model.Hints {
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
            const name = try allocator.dupe(u8, name_raw);
            errdefer allocator.free(name);
            const value = try model.cloneHintValue(allocator, value_raw);
            errdefer model.freeHintValue(allocator, value);
            try entries.append(allocator, .{ .name = name, .value = value });
        }
        try readByte(bytes, cursor, '}');
        return .{
            .entries = try entries.toOwnedSlice(allocator),
            .wire_form = .map,
        };
    }
    return Error.MalformedFrame;
}

/// Like `readLocator` but allocates hint entries. Free the result's hints with
/// `model.freeHints`. Used for sturdyref arguments where the actor needs the
/// hints (e.g. sturdyref enlivener extracting host/port).
pub fn readLocatorOwned(allocator: std.mem.Allocator, bytes: []const u8, cursor: *usize) shared.WalkError!model.PeerLocator {
    try readByte(bytes, cursor, '<');
    const tag = try readSymbol(bytes, cursor);
    if (!std.mem.eql(u8, tag, "ocapn-peer")) return Error.MalformedFrame;
    const transport = try readSymbol(bytes, cursor);
    const designator = try readString(bytes, cursor);
    const hints = try readHintsOwned(allocator, bytes, cursor);
    errdefer model.freeHints(allocator, hints);
    try readByte(bytes, cursor, '>');
    const t = try allocator.dupe(u8, transport);
    errdefer allocator.free(t);
    const d = try allocator.dupe(u8, designator);
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
    return readSignatureViewLimited(bytes, cursor, no_limit);
}

fn readSignatureViewLimited(bytes: []const u8, cursor: *usize, limit: usize) Error!SignatureView {
    // See `readPeerKeyQ`: `list` is complete, so a short re-parse is malformed.
    const list = try readBalancedLimited(bytes, cursor, '[', ']', limit);
    return parseSignatureView(list) catch |err| switch (err) {
        Error.Incomplete => Error.MalformedFrame,
        else => |other| other,
    };
}

/// Parse the spec-pinned signature record (CapTP spec § Signature):
///
/// ```text
/// ['sig-val ['eddsa ['r r_value] ['s s_value]]]
/// ```
///
/// As with `parsePeerKeyQ`, the grammar is matched exactly: a record claiming
/// any signature scheme other than `eddsa` is refused rather than having its
/// `r`/`s` bytes verified as Ed25519 anyway.
fn parseSignatureView(list: []const u8) Error!SignatureView {
    var cursor: usize = 0;
    try readByte(list, &cursor, '[');
    try expectSymbol(list, &cursor, "sig-val");
    try readByte(list, &cursor, '[');
    try expectSymbol(list, &cursor, "eddsa");
    try readByte(list, &cursor, '[');
    try expectSymbol(list, &cursor, "r");
    const r = try readBytes(list, &cursor);
    try readByte(list, &cursor, ']');
    try readByte(list, &cursor, '[');
    try expectSymbol(list, &cursor, "s");
    const s = try readBytes(list, &cursor);
    try readByte(list, &cursor, ']');
    try readByte(list, &cursor, ']');
    try readByte(list, &cursor, ']');
    try expectEnd(list, cursor);
    return .{ .r = r, .s = s };
}

fn readOptionalPositiveInt(bytes: []const u8, cursor: *usize) Error!?u64 {
    if (cursor.* < bytes.len and bytes[cursor.*] == 'f') {
        cursor.* += 1;
        return null;
    }
    return try readPositiveInt(bytes, cursor);
}

/// Canonical Syrup forbids a superfluous leading zero in any digit run — a
/// length prefix or an integer magnitude. `007"…` and `00+` spell the same
/// value as `7"…` and `0+`, so a lenient read would admit several wire
/// spellings of one message and quietly void byte-level canonicality.
fn rejectNonCanonicalDigits(bytes: []const u8, start: usize, end: usize) Error!void {
    if (end - start > 1 and bytes[start] == '0') return Error.MalformedFrame;
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
    try rejectNonCanonicalDigits(bytes, start, cursor.*);

    const value = std.fmt.parseInt(u64, bytes[start..cursor.*], 10) catch {
        return Error.MalformedFrame;
    };
    cursor.* += 1;
    return value;
}

/// Read an OCapN Integer argument: the `i64` arm when the magnitude fits, the
/// borrowed `big_integer` arm when it does not (Model.md § Integer is
/// arbitrary-precision). The split is canonical — a value representable as
/// `integer` never decodes as `big_integer` — so the two arms never spell one
/// arithmetic value and big-integer equality stays bytewise. Protocol-position
/// integers (export positions, answer positions, list indexes) go through
/// `readInteger` instead and stay `i64`-only.
fn readIntegerArgument(bytes: []const u8, cursor: *usize) Error!model.view.Argument {
    const start = cursor.*;
    while (cursor.* < bytes.len and std.ascii.isDigit(bytes[cursor.*])) {
        cursor.* += 1;
    }
    if (cursor.* >= bytes.len) return Error.Incomplete;
    if (cursor.* == start) return Error.MalformedFrame;
    try rejectNonCanonicalDigits(bytes, start, cursor.*);
    const digits = bytes[start..cursor.*];
    // A magnitude past u64 is certainly past i64; the digits are all decimal
    // here, so the only parse failure is overflow.
    const magnitude: ?u64 = std.fmt.parseInt(u64, digits, 10) catch null;
    const max_positive: u64 = @intCast(std.math.maxInt(i64));
    switch (bytes[cursor.*]) {
        '+' => {
            cursor.* += 1;
            if (magnitude) |m| {
                if (m <= max_positive) return .{ .integer = @intCast(m) };
            }
            return .{ .big_integer = .{ .negative = false, .digits = digits } };
        },
        '-' => {
            cursor.* += 1;
            if (magnitude) |m| {
                // The spec has exactly one zero, `0+`; `0-` is not a valid integer.
                if (m == 0) return Error.MalformedFrame;
                if (m == max_positive + 1) return .{ .integer = std.math.minInt(i64) };
                if (m <= max_positive) return .{ .integer = -@as(i64, @intCast(m)) };
            }
            return .{ .big_integer = .{ .negative = true, .digits = digits } };
        },
        else => return Error.MalformedFrame,
    }
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
    try rejectNonCanonicalDigits(bytes, start, cursor.*);
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
            // The spec has exactly one zero, `0+`; `0-` is not a valid integer.
            if (magnitude == 0) return Error.MalformedFrame;
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
    return readBytesLimited(bytes, cursor, no_limit);
}

fn readBytesLimited(bytes: []const u8, cursor: *usize, limit: usize) Error![]const u8 {
    return readLengthPrefixed(bytes, cursor, ':', limit);
}

pub fn readBalanced(bytes: []const u8, cursor: *usize, open: u8, close: u8) Error![]const u8 {
    return readBalancedLimited(bytes, cursor, open, close, no_limit);
}

fn readBalancedLimited(bytes: []const u8, cursor: *usize, open: u8, close: u8, limit: usize) Error![]const u8 {
    const start = cursor.*;
    try readByte(bytes, cursor, open);
    var depth: usize = 1;
    while (cursor.* < bytes.len) {
        if (cursor.* > limit) return Error.FrameTooLarge;
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
            try skipByteStringLike(bytes, cursor, limit);
        } else if (byte == ':' or byte == '"' or byte == '\'') {
            cursor.* -= 1;
            try skipByteStringLike(bytes, cursor, limit);
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
        '0'...'9' => try skipByteStringLike(bytes, cursor, no_limit),
        else => return Error.MalformedFrame,
    }
}

fn skipByteStringLike(bytes: []const u8, cursor: *usize, limit: usize) Error!void {
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
    try rejectNonCanonicalDigits(bytes, len_start, cursor.*);
    const len = std.fmt.parseInt(usize, bytes[len_start..cursor.*], 10) catch {
        return Error.MalformedFrame;
    };
    cursor.* += 1;
    if (len > limit -| cursor.*) return Error.FrameTooLarge;
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

/// The wire prefix of a Syrup record whose label is `tag`: `<` followed by the
/// label as a length-prefixed symbol, computed at `comptime` so the length can
/// never drift from the tag it counts.
fn recordPrefix(comptime tag: []const u8) []const u8 {
    return std.fmt.comptimePrint("<{d}'{s}", .{ tag.len, tag });
}

fn isReferenceRecord(bytes: []const u8, cursor: usize) bool {
    return std.mem.startsWith(u8, bytes[cursor..], recordPrefix("desc:export")) or
        std.mem.startsWith(u8, bytes[cursor..], recordPrefix("desc:import-object")) or
        std.mem.startsWith(u8, bytes[cursor..], recordPrefix("desc:import-promise")) or
        std.mem.startsWith(u8, bytes[cursor..], recordPrefix("desc:answer"));
}

fn isSignedHandoffEnvelope(bytes: []const u8, cursor: usize) bool {
    return std.mem.startsWith(u8, bytes[cursor..], recordPrefix("desc:sig-envelope"));
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
    const start = std.mem.indexOf(u8, frame, recordPrefix("desc:sig-envelope")) orelse return null;
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
