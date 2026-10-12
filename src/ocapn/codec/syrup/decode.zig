//! The Syrup decoder's public framing and message-dispatch index.
//!
//! This is the decode half of the Syrup codec. It owns the borrowed
//! codec-neutral projection (`decodeBody` / `decodePrefix`), the structural
//! stream framer (`framePrefix`, ADR-0110), the owned materializer (`decodeOwned`,
//! which is `decodeBody` followed by `model.view.Body.toOwned`, one decode
//! vocabulary, full fidelity). Borrowed Passable projection lives in `values`,
//! locator/hint projection in `locator`, and untrusted-byte leaves in `syntax`.
//! The streaming entry still owns cap timing and this module owns profile and
//! message dispatch. It reads bytes and holds no session authority.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const framing = @import("framing");

const shared = @import("shared.zig");
const syntax = @import("decode/syntax.zig");
const locator = @import("decode/locator.zig");
const values = @import("decode/values.zig");

const Error = shared.Error;

const DecodePosture = enum {
    v1_0,
    next,
    framing,

    fn forProfile(profile: model.CaptpVersion) DecodePosture {
        return switch (profile) {
            .v1_0 => .v1_0,
            .next => .next,
        };
    }
};

pub const max_decode_nesting = syntax.max_decode_nesting;
pub const SignatureView = syntax.SignatureView;

/// Materialize an owned `model.Message` from a complete `frame`: the
/// borrowed codec-neutral projection (`decodeBody`) followed by
/// `model.view.Body.toOwned`. One decode vocabulary, every *argument* arm the
/// encoder emits reads back with full fidelity (strings stay strings, symbols
/// stay symbols, numeric/list/set/tagged arms included), mirroring
/// `capnp.decodeOwned` and the symmetric-refusal posture of ADR-0003. Non-empty
/// locator hints ride `BorrowedHints` and materialize through `toOwned`
/// (same path as Cap'n Proto). Empty `#f` / `{}` spellings are the `.empty` arm.
pub fn decodeOwned(allocator: std.mem.Allocator, frame: foundation.FrameView) !model.Message {
    return (try decodeBody(frame)).toOwned(allocator);
}

/// Project the borrowed codec-neutral `model.view.Body` over a complete
/// `frame`. A frame is exactly one message with no trailing bytes. A short
/// read is therefore a malformed frame here. Streaming callers with incomplete
/// input use `decodePrefix`, which shares the same parser.
pub fn decodeBody(frame: foundation.FrameView) Error!model.view.Body {
    return decodeBodyWithPosture(.v1_0, frame);
}

pub fn decodeBodyForProfile(profile: model.CaptpVersion, frame: foundation.FrameView) Error!model.view.Body {
    return decodeBodyWithPosture(.forProfile(profile), frame);
}

fn decodeBodyWithPosture(posture: DecodePosture, frame: foundation.FrameView) Error!model.view.Body {
    if (frame.shape != .byte) return Error.InvalidFrameShape;

    var cursor: usize = 0;
    const body = decodeBodyAt(posture, frame.bytes, &cursor, syntax.no_limit) catch |err| switch (err) {
        Error.Incomplete => return Error.MalformedFrame,
        else => |other| return other,
    };
    try syntax.expectEnd(frame.bytes, cursor);
    return body;
}

/// Whether the front of `bytes` can hold a whole frame yet, resuming from
/// where the last ask left off.
///
/// A CapTP frame is one record, so this is the balance walk `readBalanced`
/// already runs over nested records, kept resumable: length-prefixed leaves are
/// stepped over by their declared length rather than read, so a payload byte
/// that happens to spell a delimiter cannot move the depth. The resume point is
/// only ever a position between elements, so a leaf that is still arriving is
/// re-stepped from its length prefix on the next ask, which costs the prefix
/// and nothing else.
///
/// `need_more` is the only answer that withholds the decoder, and it is given
/// only after consuming every available byte with the record still open, where
/// no closing delimiter exists to be found. Everything else, including bytes
/// this walk cannot classify, hands the question to the decoder.
pub fn scanStream(bytes: []const u8, state: *framing.StreamScan, max_frame_bytes: usize) framing.StreamScan.Verdict {
    if (state.settled) return .ready;
    var cursor = state.cursor;
    var depth: u32 = state.depth;
    if (depth == 0) {
        if (cursor >= bytes.len) return .need_more;
        // Not a record: the decoder owns that verdict.
        if (bytes[cursor] != '<') return state.settle();
        cursor += 1;
        depth = 1;
    }
    while (cursor < bytes.len) {
        if (cursor > max_frame_bytes) return state.settle();
        const between = cursor;
        const byte = bytes[cursor];
        cursor += 1;
        switch (byte) {
            '<' => depth += 1,
            '>' => {
                depth -= 1;
                if (depth == 0) return state.settle();
            },
            '0'...'9', ':', '"', '\'' => {
                cursor = between;
                syntax.skipByteStringLike(bytes, &cursor, max_frame_bytes) catch |err| switch (err) {
                    Error.Incomplete => return state.park(between, depth),
                    else => return state.settle(),
                };
            },
            // A `D`-tagged binary64 is eight raw payload bytes after the
            // marker; stepping over them is what stops a payload byte equal to
            // a delimiter from moving the depth.
            'D' => {
                if (bytes.len - cursor < 8) return state.park(between, depth);
                cursor += 8;
            },
            else => {},
        }
    }
    return state.park(cursor, depth);
}

/// Decode the one message at the front of `bytes` under one CapTP profile,
/// returning its borrowed body and the number of bytes it consumed, or a
/// structural verdict. `framePrefix` uses the same parser with a profile-less
/// posture that accepts the union of supported wire grammars but returns only
/// the boundary. `scanStream` may run ahead on a growing buffer, but never
/// names where a frame ends.
///
/// `max_frame_bytes` caps an accepted frame, and the cap is enforced *during*
/// the decode (ADR-0029): a length prefix that declares a body past the cap is
/// refused `.too_large` the moment the prefix is read, before those bytes ever
/// arrive, and a walk that crosses the cap element by element is refused as it
/// crosses. A frame that is merely longer than `bytes` (still arriving, within
/// the cap) reports `.incomplete`. An incomplete prefix already *longer* than
/// the cap can never complete within it, so it is `.too_large`, never
/// `.incomplete`, streaming callers bound their buffering on exactly this
/// (ADR-0041), so it is a contract, not a courtesy.
pub fn decodePrefix(bytes: []const u8, max_frame_bytes: usize) framing.Prefix {
    return decodePrefixWithPosture(.v1_0, bytes, max_frame_bytes);
}

pub fn decodePrefixForProfile(profile: model.CaptpVersion, bytes: []const u8, max_frame_bytes: usize) framing.Prefix {
    return decodePrefixWithPosture(.forProfile(profile), bytes, max_frame_bytes);
}

fn decodePrefixWithPosture(posture: DecodePosture, bytes: []const u8, max_frame_bytes: usize) framing.Prefix {
    var cursor: usize = 0;
    const body = decodeBodyAt(posture, bytes, &cursor, max_frame_bytes) catch |err| switch (err) {
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

/// Delimit a structurally valid Syrup frame without choosing a CapTP profile.
/// V1's optional boolean and next's integer listen mode have distinct Syrup
/// forms, so the generalized parse can validate either while its body remains
/// private to this function.
pub fn framePrefix(bytes: []const u8, max_frame_bytes: usize) framing.Boundary {
    const prefix = decodePrefixWithPosture(.framing, bytes, max_frame_bytes);
    return switch (prefix) {
        .decoded => |decoded| .{ .complete = decoded.consumed },
        .incomplete => .incomplete,
        .malformed => .malformed,
        .too_large => .too_large,
    };
}

/// Decode exactly one message starting at `cursor.*`, advancing `cursor` to the
/// byte just past it and leaving any trailing bytes untouched. The cursor it
/// leaves *is* the frame boundary. `Error.Incomplete` means the buffer ends
/// mid-message (read more). `Error.FrameTooLarge` means the message cannot fit
/// inside `limit` bytes no matter how many more arrive. Every other error means
/// the bytes are structurally invalid regardless of how many more arrive.
fn decodeBodyAt(posture: DecodePosture, bytes: []const u8, cursor: *usize, limit: usize) Error!model.view.Body {
    try syntax.readByte(bytes, cursor, '<');
    const op = try syntax.readSymbolLimited(bytes, cursor, limit);

    // Length-bucketed dispatch: `op.len` first, then equality only among the
    // `messageOp` strings that share that length. Exhaustiveness still rides on
    // `shared.messageOp` and `decoderFor` both switching over
    // `std.meta.Tag(model.Message)`, a new kind cannot compile without a wire
    // op *and* a decoder, and this table picks it up automatically.
    if (messageOpDecoder(op)) |decode| {
        return decode(posture, bytes, cursor, limit);
    }
    return Error.UnsupportedMessage;
}

/// Resolve `op` to its decoder by length bucket, then string equality among the
/// few same-length candidates. Lengths and candidates are derived at comptime
/// from `shared.messageOp` over every `model.Message` tag.
fn messageOpDecoder(op: []const u8) ?OpDecoder {
    const Tag = std.meta.Tag(model.Message);
    const max_len = comptime blk: {
        var m: usize = 0;
        for (@typeInfo(Tag).@"enum".field_values) |field_value| {
            const kind: Tag = @fromBackingInt(@intCast(field_value));
            m = @max(m, shared.messageOp(kind).len);
        }
        break :blk m;
    };
    if (op.len == 0 or op.len > max_len) return null;
    switch (op.len) {
        inline 1...max_len => |len| return messageOpDecoderForLen(len, op),
        else => return null,
    }
}

fn messageOpDecoderForLen(comptime len: usize, op: []const u8) ?OpDecoder {
    const Tag = std.meta.Tag(model.Message);
    const any_at_len = comptime blk: {
        for (@typeInfo(Tag).@"enum".field_values) |field_value| {
            const kind: Tag = @fromBackingInt(@intCast(field_value));
            if (shared.messageOp(kind).len == len) break :blk true;
        }
        break :blk false;
    };
    if (!any_at_len) return null;

    inline for (@typeInfo(Tag).@"enum".field_values) |field_value| {
        const kind: Tag = @fromBackingInt(@intCast(field_value));
        const wire = comptime shared.messageOp(kind);
        if (comptime wire.len == len) {
            if (std.mem.eql(u8, op, wire)) return decoderFor(kind);
        }
    }
    return null;
}

/// One decoder reads one message body from just past its op symbol, advancing
/// `cursor` to the byte after the closing `>`.
const OpDecoder = *const fn (DecodePosture, []const u8, *usize, usize) Error!model.view.Body;

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
    };
}

fn decodeAbortBody(posture: DecodePosture, bytes: []const u8, cursor: *usize, limit: usize) Error!model.view.Body {
    _ = posture;
    const message = try syntax.readStringLimited(bytes, cursor, limit);
    try syntax.readByte(bytes, cursor, '>');
    const abort = parseAbortWireString(message);
    return .{ .abort = .{ .kind = abort.kind, .message = abort.message } };
}

fn decodeDeliverBody(posture: DecodePosture, bytes: []const u8, cursor: *usize, limit: usize) Error!model.view.Body {
    const target = try values.readReference(bytes, cursor, limit);
    const args_body = try values.sliceArgumentListNeutral(bytes, cursor, 0, limit);
    const answer = try syntax.readOptionalPositiveInt(bytes, cursor);
    const resolve_me_desc = switch (posture) {
        .v1_0 => try values.readOptionalReference(bytes, cursor, limit),
        .next => null,
        .framing => blk: {
            if (cursor.* >= bytes.len) return Error.Incomplete;
            break :blk if (bytes[cursor.*] == '>') null else try values.readOptionalReference(bytes, cursor, limit);
        },
    };
    try syntax.readByte(bytes, cursor, '>');
    return .{ .deliver = .{
        .target = values.neutralReference(target),
        .args = values.neutralArgs(args_body),
        .answer = if (answer) |a| model.AnswerPosition.from(a) else null,
        .resolve_me_desc = if (resolve_me_desc) |reference| values.neutralReference(reference) else null,
    } };
}

fn decodeResolveBody(posture: DecodePosture, bytes: []const u8, cursor: *usize, limit: usize) Error!model.view.Body {
    if (posture == .next) return Error.UnsupportedMessage;
    const answer = try syntax.readPositiveInt(bytes, cursor);
    const resolution = try values.readNeutralResolution(bytes, cursor, limit);
    try syntax.readByte(bytes, cursor, '>');
    return .{ .resolve = .{ .answer = model.AnswerPosition.from(answer), .resolution = resolution } };
}

fn decodeGcExportBody(posture: DecodePosture, bytes: []const u8, cursor: *usize, limit: usize) Error!model.view.Body {
    _ = posture;
    const positions = try syntax.readPositionList(bytes, cursor, limit);
    const deltas = try syntax.readPositionList(bytes, cursor, limit);
    try syntax.readByte(bytes, cursor, '>');
    return .{ .gc_export = .{
        .positions = values.neutralPositions(positions),
        .deltas = values.neutralPositions(deltas),
    } };
}

fn decodeGcAnswerBody(posture: DecodePosture, bytes: []const u8, cursor: *usize, limit: usize) Error!model.view.Body {
    _ = posture;
    const positions = try syntax.readPositionList(bytes, cursor, limit);
    try syntax.readByte(bytes, cursor, '>');
    return .{ .gc_answer = .{ .positions = values.neutralPositions(positions) } };
}

fn decodeGetBody(posture: DecodePosture, bytes: []const u8, cursor: *usize, limit: usize) Error!model.view.Body {
    _ = posture;
    const receiver = try values.readReference(bytes, cursor, limit);
    // A String per the spec (and what Goblins sends); see the encoder.
    const field = try syntax.readStringLimited(bytes, cursor, limit);
    const answer = try syntax.readPositiveInt(bytes, cursor);
    try syntax.readByte(bytes, cursor, '>');
    return .{ .get = .{ .receiver = values.neutralReference(receiver), .field = field, .answer = model.AnswerPosition.from(answer) } };
}

fn decodeIndexBody(posture: DecodePosture, bytes: []const u8, cursor: *usize, limit: usize) Error!model.view.Body {
    _ = posture;
    const receiver = try values.readReference(bytes, cursor, limit);
    const index = try syntax.readIntegerValue(bytes, cursor);
    const answer = try syntax.readPositiveInt(bytes, cursor);
    try syntax.readByte(bytes, cursor, '>');
    return .{ .index = .{ .receiver = values.neutralReference(receiver), .index = index, .answer = model.AnswerPosition.from(answer) } };
}

fn decodeUntagBody(posture: DecodePosture, bytes: []const u8, cursor: *usize, limit: usize) Error!model.view.Body {
    _ = posture;
    const receiver = try values.readReference(bytes, cursor, limit);
    // A String per the spec; see the encoder.
    const tag = try syntax.readStringLimited(bytes, cursor, limit);
    const answer = try syntax.readPositiveInt(bytes, cursor);
    try syntax.readByte(bytes, cursor, '>');
    return .{ .untag = .{ .receiver = values.neutralReference(receiver), .tag = tag, .answer = model.AnswerPosition.from(answer) } };
}

fn decodeListenBody(posture: DecodePosture, bytes: []const u8, cursor: *usize, limit: usize) Error!model.view.Body {
    const target = try values.readReference(bytes, cursor, limit);
    const listener = try values.readReference(bytes, cursor, limit);
    const mode: model.ListenMode = switch (posture) {
        .v1_0 => model.ListenMode.fromV1_0WantsPartial(if (cursor.* < bytes.len and bytes[cursor.*] != '>')
            try syntax.readBool(bytes, cursor)
        else
            false),
        .next => model.ListenMode.fromInt(try syntax.readPositiveInt(bytes, cursor)) orelse return Error.MalformedFrame,
        .framing => switch (if (cursor.* < bytes.len) bytes[cursor.*] else return Error.Incomplete) {
            '>' => .settling_only,
            't', 'f' => model.ListenMode.fromV1_0WantsPartial(try syntax.readBool(bytes, cursor)),
            '0'...'9' => model.ListenMode.fromInt(try syntax.readPositiveInt(bytes, cursor)) orelse return Error.MalformedFrame,
            else => return Error.MalformedFrame,
        },
    };
    try syntax.readByte(bytes, cursor, '>');
    return .{ .listen = .{
        .target = values.neutralReference(target),
        .listener = values.neutralReference(listener),
        .mode = mode,
    } };
}

fn decodeStartSessionBody(posture: DecodePosture, bytes: []const u8, cursor: *usize, limit: usize) Error!model.view.Body {
    _ = posture;
    const version_wire = try syntax.readStringLimited(bytes, cursor, limit);
    // A token this build does not know decodes as null; `session.validate` is
    // what refuses it, and refuses it as a version mismatch.
    const captp_version = model.CaptpVersion.fromWireString(version_wire);
    const session_pubkey = try syntax.readPeerKeyQ(bytes, cursor, limit);
    // Span the exact `<ocapn-peer …>` location-record bytes around the read so
    // a verifier checks the signature over what was received, not a re-encode.
    const location_start = cursor.*;
    const acceptable_location = try locator.readPeerLocatorView(bytes, cursor, limit);
    const location_raw = bytes[location_start..cursor.*];
    const acceptable_location_sig = try syntax.readSignatureViewLimited(bytes, cursor, limit);
    try syntax.readByte(bytes, cursor, '>');
    return .{ .start_session = .{
        .captp_version = captp_version,
        .session_pubkey = session_pubkey,
        .acceptable_location = acceptable_location,
        .acceptable_location_sig = .{ .halves = .{ .r = acceptable_location_sig.r, .s = acceptable_location_sig.s } },
        .acceptable_location_raw = location_raw,
    } };
}

/// Turn a V1.0 abort wire string back into a typed reason. V1.0 writes aborts
/// as `"<Label>: <message>"`. If the label is one the model recognizes, that
/// kind is recovered. Otherwise the whole string is kept as an `.other` reason.
/// The inverse lives beside this in `encode`: `writeAbortWireString` builds
/// the `"<label>: <message>"` form from `kind.wireName()`, the codec owns the
/// wire string format in both directions, the model only the typed reason.
fn parseAbortWireString(wire: []const u8) model.AbortReason {
    if (std.mem.indexOf(u8, wire, ": ")) |split| {
        if (model.AbortKind.fromWireName(wire[0..split])) |kind| {
            return .{ .kind = kind, .message = wire[split + 2 ..] };
        }
    }
    return .{ .kind = .other, .message = wire };
}

// Public decode index: callers share the leaf implementations directly.
pub const readSymbol = syntax.readSymbol;
pub const readBalanced = syntax.readBalanced;
pub const readSignatureView = syntax.readSignatureView;
pub const readByte = syntax.readByte;
pub const expectEnd = syntax.expectEnd;
pub const readLocatorOwned = locator.readLocatorOwned;
pub const readLocatorView = locator.readLocatorView;
pub const decodeSignedHandoffGiveOwned = values.decodeSignedHandoffGiveOwned;
