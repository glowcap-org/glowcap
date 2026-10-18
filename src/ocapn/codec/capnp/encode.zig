//! Cap'n Proto encode path.
//!
//! This module renders a borrowed `model.view.Body` into glowcap's
//! self-consistent Cap'n Proto dialect. `encodeBody` and
//! `encodeBodyForProfile` walk a borrowed body, and `encodeMessage` and
//! `encodeMessageForProfile` project an owned `model.Message` through
//! `view.Body.fromOwned` onto the same walk, so one walk serves an owned
//! tree, a decoded frame, and a caller's values behind a sequence table. It
//! owns builder allocation and the message-level layout. The record layouts
//! live in `encode_records.zig` and the argument tree in
//! `encode_arguments.zig`. It does not decode or materialize owned values.
//!
//! Text is validated where it is written (`encode_records.setText`), so a
//! malformed string refuses the encode before any bytes leave: the builder is
//! the only effect, and it is dropped on refusal.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const arguments = @import("encode_arguments.zig");
const layout = @import("encode_layout.zig");
const records = @import("encode_records.zig");
const shared = @import("shared.zig");
const wire = shared.wire;
const view = model.view;

const Error = shared.Error;
const EncodeError = shared.EncodeError;
const Kind = shared.Kind;
const ResolutionKind = shared.ResolutionKind;
const StructLoc = shared.StructLoc;
const allocStruct = layout.allocStruct;
const ptrIndex = layout.ptrIndex;
const setStructPtr = layout.setStructPtr;
const setListPtr = layout.setListPtr;
const setData = layout.setData;
const setText = records.setText;
const encodeReference = records.encodeReference;
const encodePeerLocator = records.encodePeerLocator;
const encodeError = records.encodeError;
const encodeArgument = arguments.encodeArgument;
const encodeArgumentList = arguments.encodeArgumentList;

/// Encode for a CapTP version, the codec-dispatch boundary's counterpart to
/// `syrup.encodeMessageForProfile`. Cap'n Proto is glowcap's self-consistent
/// dialect (ADR-0026): the struct schema always carries `resolve_me_desc` /
/// `wants_partial`, and word layout stays profile-independent. The profile
/// still gates what may be encoded: `.next` refuses wire `op:resolve` and
/// removed projection operations. Next delivers require an inline resolver
/// and listen mode 1 or 3 whenever they request a result.
pub fn encodeMessageForProfile(
    allocator: std.mem.Allocator,
    profile: model.CaptpVersion,
    message: model.Message,
) EncodeError!foundation.Frame {
    const body = view.Body.fromOwned(&message);
    return render(allocator, profile, &body);
}

pub fn encodeMessage(allocator: std.mem.Allocator, message: model.Message) EncodeError!foundation.Frame {
    const body = view.Body.fromOwned(&message);
    return render(allocator, .v1_0, &body);
}

/// Encode a borrowed body with the `1.0` profile's spellings.
pub fn encodeBody(allocator: std.mem.Allocator, body: *const view.Body) EncodeError!foundation.Frame {
    return render(allocator, .v1_0, body);
}

/// Encode a borrowed body for a CapTP version. The body is read, never
/// materialized: a lazy record is projected where it is written, and a
/// malformed one refuses the encode as `MalformedView`. Cap'n Proto sizes
/// its own segments and declares no meter, so `values` is always null here.
pub fn encodeBodyForProfile(
    allocator: std.mem.Allocator,
    profile: model.CaptpVersion,
    body: *const view.Body,
    values: ?usize,
) EncodeError!foundation.Frame {
    std.debug.assert(values == null);
    return render(allocator, profile, body);
}

fn render(allocator: std.mem.Allocator, profile: model.CaptpVersion, body: *const view.Body) EncodeError!foundation.Frame {
    if (!profile.carries(body.*)) return Error.UnsupportedMessage;
    if (profile == .next) switch (body.*) {
        .deliver => |deliver| {
            if (deliver.answer != null and deliver.resolve_me_desc == null) return Error.UnsupportedMessage;
            if (deliver.resolve_me_desc) |resolver| {
                if (resolver != .near or deliver.listen_mode == .settling_only) return Error.UnsupportedMessage;
            }
        },
        else => {},
    };

    var builder = try wire.Builder.init(allocator);
    defer builder.deinit(allocator);

    const root_idx = try builder.allocWords(allocator, 1);
    const env = try allocStruct(&builder, allocator, 1, 1);
    setStructPtr(&builder, root_idx, env);
    builder.set(env.data_idx, @backingInt(messageKind(body.*)));

    const loc = try encodeBodyInto(&builder, allocator, profile, body);
    setStructPtr(&builder, env.data_idx + env.data_words, loc);

    return builder.finishOwned(allocator);
}

fn messageKind(body: view.Body) Kind {
    // Exhaustive over the body tags, which mirror `model.Message`; `Kind`
    // mirrors them via `assertMirrorsMessageKinds`, so a new arm fails here
    // and in decode's `bodyProjector` together. Wire ids stay the explicit
    // `Kind` enum values.
    return switch (body) {
        inline else => |_, tag| @field(Kind, @tagName(tag)),
    };
}

fn encodeBodyInto(b: *wire.Builder, allocator: std.mem.Allocator, profile: model.CaptpVersion, body: *const view.Body) EncodeError!StructLoc {
    return switch (body.*) {
        .gc_answer => |gc| blk: {
            const loc = try allocStruct(b, allocator, 0, 1);
            try setPositionList(b, allocator, loc, 0, gc.positions);
            break :blk loc;
        },
        .gc_export => |gc| blk: {
            const loc = try allocStruct(b, allocator, 0, 2);
            try setPositionList(b, allocator, loc, 0, gc.positions);
            try setPositionList(b, allocator, loc, 1, gc.deltas);
            break :blk loc;
        },
        .abort => |abort| blk: {
            const loc = try allocStruct(b, allocator, 1, 1);
            b.set(loc.data_idx, @backingInt(abort.kind));
            try setText(b, allocator, loc, 0, abort.message);
            break :blk loc;
        },
        .resolve => |*resolve| blk: {
            const loc = try allocStruct(b, allocator, 1, 1);
            b.set(loc.data_idx, resolve.answer.int());
            setStructPtr(b, ptrIndex(loc, 0), try encodeResolution(b, allocator, &resolve.resolution));
            break :blk loc;
        },
        .deliver => |*deliver| try encodeDeliver(b, allocator, profile, deliver),
        .listen => |listen| blk: {
            const loc = try allocStruct(b, allocator, 1, 2);
            b.set(loc.data_idx, switch (profile) {
                .v1_0 => @intFromBool(listen.mode.toV1_0WantsPartial() orelse return Error.UnsupportedMessage),
                .next => @backingInt(listen.mode),
            });
            setStructPtr(b, ptrIndex(loc, 0), try encodeReference(b, allocator, listen.target));
            setStructPtr(b, ptrIndex(loc, 1), try encodeReference(b, allocator, listen.listener));
            break :blk loc;
        },
        .get => |get| blk: {
            const loc = try allocStruct(b, allocator, 1, 2);
            b.set(loc.data_idx, get.answer.int());
            setStructPtr(b, ptrIndex(loc, 0), try encodeReference(b, allocator, get.receiver));
            try setText(b, allocator, loc, 1, get.field);
            break :blk loc;
        },
        .index => |index| blk: {
            switch (index.index) {
                .integer => |value| {
                    // Preserve the original compact layout for ordinary indexes.
                    const loc = try allocStruct(b, allocator, 2, 1);
                    b.set(loc.data_idx, @bitCast(value));
                    b.set(loc.data_idx + 1, index.answer.int());
                    setStructPtr(b, ptrIndex(loc, 0), try encodeReference(b, allocator, index.receiver));
                    break :blk loc;
                },
                .big_integer => |big| {
                    if (!big.isCanonical()) return Error.UnsupportedArgument;
                    const loc = try allocStruct(b, allocator, 3, 2);
                    b.set(loc.data_idx, 0);
                    b.set(loc.data_idx + 1, index.answer.int());
                    b.set(loc.data_idx + 2, @bitCast(shared.IndexFlags{ .big_integer = true, .negative = big.negative }));
                    setStructPtr(b, ptrIndex(loc, 0), try encodeReference(b, allocator, index.receiver));
                    try setData(b, allocator, loc, 1, big.digits);
                    break :blk loc;
                },
            }
        },
        .untag => |untag| blk: {
            const loc = try allocStruct(b, allocator, 1, 2);
            b.set(loc.data_idx, untag.answer.int());
            setStructPtr(b, ptrIndex(loc, 0), try encodeReference(b, allocator, untag.receiver));
            try setText(b, allocator, loc, 1, untag.tag);
            break :blk loc;
        },
        .start_session => |ss| try encodeStartSession(b, allocator, ss),
    };
}

/// `List(UInt64)` of positions, one word per element and no tag word,
/// walked from an owned slice or a decoded run alike.
fn setPositionList(b: *wire.Builder, allocator: std.mem.Allocator, loc: StructLoc, i: u16, positions: view.PositionList) EncodeError!void {
    const count = try positions.len();
    const start = try b.allocWords(allocator, count);
    var it = positions.iterator();
    var filled: usize = 0;
    while (try it.next()) |position| : (filled += 1) {
        // A sequence whose walk and `len` disagree is malformed, and the
        // check stays live in every build mode because the alternative is
        // an out-of-bounds write.
        if (filled == count) return error.MalformedView;
        b.set(start + filled, position);
    }
    if (filled != count) return error.MalformedView;
    try setListPtr(b, ptrIndex(loc, i), .{ .data_idx = start, .elem = .eight_bytes, .count = count });
}

fn encodeDeliver(b: *wire.Builder, allocator: std.mem.Allocator, profile: model.CaptpVersion, deliver: *const view.Deliver) EncodeError!StructLoc {
    const loc = try allocStruct(b, allocator, 2, 3);
    var flags: shared.DeliverFlags = .{};
    if (deliver.answer) |answer| {
        flags.has_answer = true;
        b.set(loc.data_idx + 1, answer.int());
    }
    if (deliver.resolve_me_desc != null) {
        flags.has_resolve_me = true;
        if (profile == .next) flags.listen_mode = @backingInt(deliver.listen_mode);
    }
    b.set(loc.data_idx, @bitCast(flags));
    setStructPtr(b, ptrIndex(loc, 0), try encodeReference(b, allocator, deliver.target));
    try setListPtr(b, ptrIndex(loc, 1), try encodeArgumentList(b, allocator, deliver.args));
    if (deliver.resolve_me_desc) |desc| setStructPtr(b, ptrIndex(loc, 2), try encodeReference(b, allocator, desc));
    return loc;
}

fn encodeStartSession(b: *wire.Builder, allocator: std.mem.Allocator, ss: view.StartSession) EncodeError!StructLoc {
    const loc = try allocStruct(b, allocator, 0, 4);
    // A hello with no version is one this codebase never builds: outbound the
    // version is ours. Refuse rather than invent one.
    const version = ss.captp_version orelse return Error.MalformedFrame;
    try setData(b, allocator, loc, 0, version.wireString());
    try setData(b, allocator, loc, 1, ss.session_pubkey);
    setStructPtr(b, ptrIndex(loc, 2), try encodePeerLocator(b, allocator, ss.acceptable_location));
    try records.setSignature(b, allocator, loc, 3, ss.acceptable_location_sig);
    return loc;
}

fn encodeResolution(b: *wire.Builder, allocator: std.mem.Allocator, resolution: *const view.Resolution) EncodeError!StructLoc {
    const loc = try allocStruct(b, allocator, 1, 1);
    switch (resolution.*) {
        .fulfill => |*arg| {
            b.set(loc.data_idx, @backingInt(ResolutionKind.fulfill));
            setStructPtr(b, ptrIndex(loc, 0), try encodeArgument(b, allocator, arg));
        },
        .@"break" => |err| {
            b.set(loc.data_idx, @backingInt(ResolutionKind.@"break"));
            setStructPtr(b, ptrIndex(loc, 0), try encodeError(b, allocator, err.message));
        },
    }
    return loc;
}
