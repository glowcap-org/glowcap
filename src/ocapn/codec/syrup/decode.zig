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
const scalar = @import("scalar.zig");
const syntax = @import("decode/syntax.zig");
const locator = @import("decode/locator.zig");
const values = @import("decode/values.zig");

const Error = shared.Error;

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
    var body: model.view.Body = undefined;
    try decodeBodyInto(profile, frame, &slab, &body);
    return body;
}

/// `decodeBodyForProfile` writing the body where it will live, with room
/// for the message's top-level argument list, so the list is parsed once
/// (`values.readArgumentList`) and the body is written once. The views
/// written to `slab` borrow `frame` and the body written to `body` borrows
/// them. On a refusal `body` is undefined.
pub fn decodeBodyInto(profile: model.CaptpVersion, frame: foundation.FrameView, slab: *model.view.ValueSlab, body: *model.view.Body) Error!void {
    return decodeBodyUnder(.{ .profile = profile, .slab = slab }, frame, body);
}

/// What every message decoder reads under: the profile and the room lent for
/// the argument list.
const Decode = struct {
    profile: model.CaptpVersion,
    slab: *model.view.ValueSlab,
};

fn decodeBodyUnder(d: Decode, frame: foundation.FrameView, body: *model.view.Body) Error!void {
    if (frame.shape != .byte) return Error.InvalidFrameShape;

    var cursor: usize = 0;
    try decodeBodyAt(d, frame.bytes, &cursor, body);
    try syntax.expectEnd(frame.bytes, cursor);
}

/// Decode exactly one message starting at `cursor.*` into `body`, advancing
/// `cursor` to the byte just past it. The caller holds the frame to end there.
fn decodeBodyAt(d: Decode, bytes: []const u8, cursor: *usize, body: *model.view.Body) Error!void {
    try syntax.readByte(bytes, cursor, '<');
    // Each op has one canonical label, so dispatch is one comparison per
    // kind in `message_op_order`, with no digit scan. Exhaustiveness rides on
    // `shared.messageOp` and `decoderFor` both switching over
    // `std.meta.Tag(model.Message)` and on the order naming every kind: a new
    // kind cannot compile without a wire op, a decoder, and a place in line.
    if (syntax.readKnownLabel(bytes, cursor, "op:deliver-only")) {
        if (d.profile != .next) return Error.UnsupportedMessage;
        const target = try values.readReference(bytes, cursor);
        const args = try values.readArgumentList(d.slab, bytes, cursor);
        try syntax.readByte(bytes, cursor, '>');
        body.* = .{ .deliver = .{ .target = values.neutralReference(target), .args = args } };
        return;
    }
    inline for (message_op_order) |kind| {
        if (syntax.readKnownLabel(bytes, cursor, comptime shared.messageOp(kind))) {
            if (!d.profile.carries(kind)) return Error.UnsupportedMessage;
            return decoderFor(kind)(d, bytes, cursor, body);
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

/// One decoder reads one message body from just past its op symbol into
/// `body`, advancing `cursor` to the byte after the closing `>`.
const OpDecoder = *const fn (Decode, []const u8, *usize, *model.view.Body) Error!void;

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

fn decodeAbortBody(d: Decode, bytes: []const u8, cursor: *usize, body: *model.view.Body) Error!void {
    _ = d;
    const message = try syntax.readString(bytes, cursor);
    try syntax.readByte(bytes, cursor, '>');
    const abort = scalar.abortReasonFromWireString(message);
    body.* = .{ .abort = .{ .kind = abort.kind, .message = abort.message } };
}

fn decodeDeliverBody(d: Decode, bytes: []const u8, cursor: *usize, body: *model.view.Body) Error!void {
    const target = try values.readReference(bytes, cursor);
    const args = try values.readArgumentList(d.slab, bytes, cursor);
    const answer = try syntax.readOptionalPositiveInt(bytes, cursor);
    const resolve_me_desc = switch (d.profile) {
        .v1_0 => try values.readOptionalReference(bytes, cursor),
        .next => try values.readReference(bytes, cursor),
    };
    const mode: model.ListenMode = if (d.profile == .next)
        model.ListenMode.fromInt(try syntax.readPositiveInt(bytes, cursor)) orelse return Error.MalformedFrame
    else
        .shortening_or_settling;
    if (d.profile == .next and (mode == .settling_only or values.neutralReference(resolve_me_desc.?) != .far)) return Error.MalformedFrame;
    try syntax.readByte(bytes, cursor, '>');
    body.* = .{ .deliver = .{
        .target = values.neutralReference(target),
        .args = args,
        .answer = if (answer) |a| model.AnswerPosition.from(a) else null,
        .listen_mode = mode,
        .resolve_me_desc = if (resolve_me_desc) |reference| values.neutralReference(reference) else null,
    } };
}

fn decodeResolveBody(d: Decode, bytes: []const u8, cursor: *usize, body: *model.view.Body) Error!void {
    if (d.profile == .next) return Error.UnsupportedMessage;
    const answer = try syntax.readPositiveInt(bytes, cursor);
    const resolution = try values.readNeutralResolution(d.slab, bytes, cursor);
    try syntax.readByte(bytes, cursor, '>');
    body.* = .{ .resolve = .{ .answer = model.AnswerPosition.from(answer), .resolution = resolution } };
}

fn decodeGcExportBody(d: Decode, bytes: []const u8, cursor: *usize, body: *model.view.Body) Error!void {
    _ = d;
    const positions = try syntax.readPositionList(bytes, cursor);
    const deltas = try syntax.readPositionList(bytes, cursor);
    try syntax.readByte(bytes, cursor, '>');
    body.* = .{ .gc_export = .{
        .positions = values.neutralPositions(positions),
        .deltas = values.neutralPositions(deltas),
    } };
}

fn decodeGcAnswerBody(d: Decode, bytes: []const u8, cursor: *usize, body: *model.view.Body) Error!void {
    _ = d;
    const positions = try syntax.readPositionList(bytes, cursor);
    try syntax.readByte(bytes, cursor, '>');
    body.* = .{ .gc_answer = .{ .positions = values.neutralPositions(positions) } };
}

fn decodeGetBody(d: Decode, bytes: []const u8, cursor: *usize, body: *model.view.Body) Error!void {
    _ = d;
    const receiver = try values.readReference(bytes, cursor);
    // A String per the spec (and what Goblins sends); see the encoder.
    const field = try syntax.readString(bytes, cursor);
    const answer = try syntax.readPositiveInt(bytes, cursor);
    try syntax.readByte(bytes, cursor, '>');
    body.* = .{ .get = .{ .receiver = values.neutralReference(receiver), .field = field, .answer = model.AnswerPosition.from(answer) } };
}

fn decodeIndexBody(d: Decode, bytes: []const u8, cursor: *usize, body: *model.view.Body) Error!void {
    _ = d;
    const receiver = try values.readReference(bytes, cursor);
    const index = try syntax.readIntegerValue(bytes, cursor);
    const answer = try syntax.readPositiveInt(bytes, cursor);
    try syntax.readByte(bytes, cursor, '>');
    body.* = .{ .index = .{ .receiver = values.neutralReference(receiver), .index = index, .answer = model.AnswerPosition.from(answer) } };
}

fn decodeUntagBody(d: Decode, bytes: []const u8, cursor: *usize, body: *model.view.Body) Error!void {
    _ = d;
    const receiver = try values.readReference(bytes, cursor);
    // A String per the spec; see the encoder.
    const tag = try syntax.readString(bytes, cursor);
    const answer = try syntax.readPositiveInt(bytes, cursor);
    try syntax.readByte(bytes, cursor, '>');
    body.* = .{ .untag = .{ .receiver = values.neutralReference(receiver), .tag = tag, .answer = model.AnswerPosition.from(answer) } };
}

fn decodeListenBody(d: Decode, bytes: []const u8, cursor: *usize, body: *model.view.Body) Error!void {
    const target = try values.readReference(bytes, cursor);
    const listener = try values.readReference(bytes, cursor);
    const mode: model.ListenMode = switch (d.profile) {
        .v1_0 => model.ListenMode.fromV1_0WantsPartial(if (cursor.* < bytes.len and bytes[cursor.*] != '>')
            try syntax.readBool(bytes, cursor)
        else
            false),
        .next => model.ListenMode.fromInt(try syntax.readPositiveInt(bytes, cursor)) orelse return Error.MalformedFrame,
    };
    try syntax.readByte(bytes, cursor, '>');
    body.* = .{ .listen = .{
        .target = values.neutralReference(target),
        .listener = values.neutralReference(listener),
        .mode = mode,
    } };
}

fn decodeStartSessionBody(d: Decode, bytes: []const u8, cursor: *usize, body: *model.view.Body) Error!void {
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
    body.* = .{ .start_session = .{
        .captp_version = captp_version,
        .session_pubkey = session_pubkey,
        .acceptable_location = acceptable_location,
        .acceptable_location_sig = .{ .halves = .{ .r = acceptable_location_sig.r, .s = acceptable_location_sig.s } },
        .acceptable_location_raw = location_raw,
    } };
}

// Public decode index: callers share the leaf implementations directly.
pub const readSymbol = syntax.readSymbol;
pub const readLabel = syntax.readLabel;
pub const readSignatureView = syntax.readSignatureView;
pub const readByte = syntax.readByte;
pub const expectEnd = syntax.expectEnd;
pub const readLocatorOwned = locator.readLocatorOwned;
pub const readLocatorView = locator.readLocatorView;
pub const decodeSignedHandoffGiveOwned = values.decodeSignedHandoffGiveOwned;
pub const signedGivePayload = values.signedGivePayload;
