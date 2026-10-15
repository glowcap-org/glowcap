//! The Syrup decoder's message-dispatch index.
//!
//! This is the decode half of the Syrup codec. It owns the borrowed
//! codec-neutral projection (`decodeBody`) and the owned materializer
//! (`decodeOwned`, which is `decodeBody` followed by `model.view.Body.toOwned`,
//! one decode vocabulary, full fidelity). Borrowed Passable projection lives in
//! `values`, locator/hint projection in `locator`, and untrusted-byte leaves in
//! `syntax`. A frame reaches this module whole: the byte-stream envelope
//! (ADR-0110) or the transport's own message boundary delimits it before it
//! is decoded, so this module owns profile and message dispatch and never a
//! stream boundary. It reads bytes and holds no session authority.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");

const shared = @import("shared.zig");
const syntax = @import("decode/syntax.zig");
const locator = @import("decode/locator.zig");
const values = @import("decode/values.zig");

const Error = shared.Error;

const DecodePosture = enum {
    v1_0,
    next,

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
/// `frame`. A frame is exactly one message with no trailing bytes, so a
/// short read is a malformed frame here.
pub fn decodeBody(frame: foundation.FrameView) Error!model.view.Body {
    return decodeBodyForProfile(.v1_0, frame);
}

pub fn decodeBodyForProfile(profile: model.CaptpVersion, frame: foundation.FrameView) Error!model.view.Body {
    var slab = model.view.ValueSlab.empty;
    return decodeBodyInto(profile, frame, &slab);
}

/// `decodeBodyForProfile` with room for the message's top-level argument
/// list, so the list is parsed once (`values.readArgumentList`). The views
/// written to `slab` borrow `frame` and the body returned borrows them.
pub fn decodeBodyInto(profile: model.CaptpVersion, frame: foundation.FrameView, slab: *model.view.ValueSlab) Error!model.view.Body {
    return decodeBodyWithPosture(.{ .posture = .forProfile(profile), .slab = slab }, frame);
}

/// What every message decoder reads under: the profile's posture and the
/// room lent for the argument list.
const Decode = struct {
    posture: DecodePosture,
    slab: *model.view.ValueSlab,
};

fn decodeBodyWithPosture(d: Decode, frame: foundation.FrameView) Error!model.view.Body {
    if (frame.shape != .byte) return Error.InvalidFrameShape;

    var cursor: usize = 0;
    const body = decodeBodyAt(d, frame.bytes, &cursor) catch |err| switch (err) {
        Error.Incomplete => return Error.MalformedFrame,
        else => |other| return other,
    };
    try syntax.expectEnd(frame.bytes, cursor);
    return body;
}

/// Decode exactly one message starting at `cursor.*`, advancing `cursor` to the
/// byte just past it and leaving any trailing bytes untouched. The cursor it
/// leaves *is* the frame boundary. `Error.Incomplete` means the buffer ends
/// mid-message (read more). Every other error means the bytes are structurally
/// invalid regardless of how many more arrive.
fn decodeBodyAt(d: Decode, bytes: []const u8, cursor: *usize) Error!model.view.Body {
    try syntax.readByte(bytes, cursor, '<');
    // Each op has one canonical label, so dispatch is one comparison per
    // kind in `message_op_order`, with no digit scan. Exhaustiveness rides on
    // `shared.messageOp` and `decoderFor` both switching over
    // `std.meta.Tag(model.Message)` and on the order naming every kind: a new
    // kind cannot compile without a wire op, a decoder, and a place in line.
    inline for (message_op_order) |kind| {
        if (syntax.readKnownLabel(bytes, cursor, comptime shared.messageOp(kind))) {
            return decoderFor(kind)(d, bytes, cursor);
        }
    }
    // Not a message glowcap models: read the label in full for its verdict,
    // incomplete or malformed before unsupported.
    _ = try syntax.readLabel(bytes, cursor);
    return Error.UnsupportedMessage;
}

/// Every message kind, the ones a call round trip carries first.
const message_op_order = [_]std.meta.Tag(model.Message){
    .deliver,
    .resolve,
    .gc_export,
    .gc_answer,
    .abort,
    .get,
    .index,
    .untag,
    .listen,
    .start_session,
};

comptime {
    const Tag = std.meta.Tag(model.Message);
    for (@typeInfo(Tag).@"enum".field_values) |field_value| {
        const kind: Tag = @fromBackingInt(@intCast(field_value));
        std.debug.assert(std.mem.indexOfScalar(Tag, &message_op_order, kind) != null);
    }
}

/// One decoder reads one message body from just past its op symbol, advancing
/// `cursor` to the byte after the closing `>`.
const OpDecoder = *const fn (Decode, []const u8, *usize) Error!model.view.Body;

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

fn decodeAbortBody(d: Decode, bytes: []const u8, cursor: *usize) Error!model.view.Body {
    _ = d;
    const message = try syntax.readString(bytes, cursor);
    try syntax.readByte(bytes, cursor, '>');
    const abort = parseAbortWireString(message);
    return .{ .abort = .{ .kind = abort.kind, .message = abort.message } };
}

fn decodeDeliverBody(d: Decode, bytes: []const u8, cursor: *usize) Error!model.view.Body {
    const target = try values.readReference(bytes, cursor);
    const args = try values.readArgumentList(d.slab, bytes, cursor);
    const answer = try syntax.readOptionalPositiveInt(bytes, cursor);
    const resolve_me_desc = switch (d.posture) {
        .v1_0 => try values.readOptionalReference(bytes, cursor),
        .next => null,
    };
    try syntax.readByte(bytes, cursor, '>');
    return .{ .deliver = .{
        .target = values.neutralReference(target),
        .args = args,
        .answer = if (answer) |a| model.AnswerPosition.from(a) else null,
        .resolve_me_desc = if (resolve_me_desc) |reference| values.neutralReference(reference) else null,
    } };
}

fn decodeResolveBody(d: Decode, bytes: []const u8, cursor: *usize) Error!model.view.Body {
    if (d.posture == .next) return Error.UnsupportedMessage;
    const answer = try syntax.readPositiveInt(bytes, cursor);
    const resolution = try values.readNeutralResolution(d.slab, bytes, cursor);
    try syntax.readByte(bytes, cursor, '>');
    return .{ .resolve = .{ .answer = model.AnswerPosition.from(answer), .resolution = resolution } };
}

fn decodeGcExportBody(d: Decode, bytes: []const u8, cursor: *usize) Error!model.view.Body {
    _ = d;
    const positions = try syntax.readPositionList(bytes, cursor);
    const deltas = try syntax.readPositionList(bytes, cursor);
    try syntax.readByte(bytes, cursor, '>');
    return .{ .gc_export = .{
        .positions = values.neutralPositions(positions),
        .deltas = values.neutralPositions(deltas),
    } };
}

fn decodeGcAnswerBody(d: Decode, bytes: []const u8, cursor: *usize) Error!model.view.Body {
    _ = d;
    const positions = try syntax.readPositionList(bytes, cursor);
    try syntax.readByte(bytes, cursor, '>');
    return .{ .gc_answer = .{ .positions = values.neutralPositions(positions) } };
}

fn decodeGetBody(d: Decode, bytes: []const u8, cursor: *usize) Error!model.view.Body {
    _ = d;
    const receiver = try values.readReference(bytes, cursor);
    // A String per the spec (and what Goblins sends); see the encoder.
    const field = try syntax.readString(bytes, cursor);
    const answer = try syntax.readPositiveInt(bytes, cursor);
    try syntax.readByte(bytes, cursor, '>');
    return .{ .get = .{ .receiver = values.neutralReference(receiver), .field = field, .answer = model.AnswerPosition.from(answer) } };
}

fn decodeIndexBody(d: Decode, bytes: []const u8, cursor: *usize) Error!model.view.Body {
    _ = d;
    const receiver = try values.readReference(bytes, cursor);
    const index = try syntax.readIntegerValue(bytes, cursor);
    const answer = try syntax.readPositiveInt(bytes, cursor);
    try syntax.readByte(bytes, cursor, '>');
    return .{ .index = .{ .receiver = values.neutralReference(receiver), .index = index, .answer = model.AnswerPosition.from(answer) } };
}

fn decodeUntagBody(d: Decode, bytes: []const u8, cursor: *usize) Error!model.view.Body {
    _ = d;
    const receiver = try values.readReference(bytes, cursor);
    // A String per the spec; see the encoder.
    const tag = try syntax.readString(bytes, cursor);
    const answer = try syntax.readPositiveInt(bytes, cursor);
    try syntax.readByte(bytes, cursor, '>');
    return .{ .untag = .{ .receiver = values.neutralReference(receiver), .tag = tag, .answer = model.AnswerPosition.from(answer) } };
}

fn decodeListenBody(d: Decode, bytes: []const u8, cursor: *usize) Error!model.view.Body {
    const target = try values.readReference(bytes, cursor);
    const listener = try values.readReference(bytes, cursor);
    const mode: model.ListenMode = switch (d.posture) {
        .v1_0 => model.ListenMode.fromV1_0WantsPartial(if (cursor.* < bytes.len and bytes[cursor.*] != '>')
            try syntax.readBool(bytes, cursor)
        else
            false),
        .next => model.ListenMode.fromInt(try syntax.readPositiveInt(bytes, cursor)) orelse return Error.MalformedFrame,
    };
    try syntax.readByte(bytes, cursor, '>');
    return .{ .listen = .{
        .target = values.neutralReference(target),
        .listener = values.neutralReference(listener),
        .mode = mode,
    } };
}

fn decodeStartSessionBody(d: Decode, bytes: []const u8, cursor: *usize) Error!model.view.Body {
    _ = d;
    const version_wire = try syntax.readString(bytes, cursor);
    // A token this build does not know decodes as null; `session.validate` is
    // what refuses it, and refuses it as a version mismatch.
    const captp_version = model.CaptpVersion.fromWireString(version_wire);
    const session_pubkey = try syntax.readPeerKeyQ(bytes, cursor);
    // Span the exact `<ocapn-peer …>` location-record bytes around the read so
    // a verifier checks the signature over what was received, not a re-encode.
    const location_start = cursor.*;
    const acceptable_location = try locator.readPeerLocatorView(bytes, cursor);
    const location_raw = bytes[location_start..cursor.*];
    const acceptable_location_sig = try syntax.readSignatureView(bytes, cursor);
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
pub const readLabel = syntax.readLabel;
pub const readBalanced = syntax.readBalanced;
pub const readSignatureView = syntax.readSignatureView;
pub const readByte = syntax.readByte;
pub const expectEnd = syntax.expectEnd;
pub const readLocatorOwned = locator.readLocatorOwned;
pub const readLocatorView = locator.readLocatorView;
pub const decodeSignedHandoffGiveOwned = values.decodeSignedHandoffGiveOwned;
