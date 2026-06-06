//! The Syrup codec, top to bottom.
//!
//! Syrup is the byte-record format, the self-delimiting alternative to Cap'n
//! Proto. It carries the same `model.Message` tree as length-prefixed records
//! (`<...>`), lists (`[...]`), symbols, strings, and integers. Everything for that
//! lives in this one file: the borrowed `MessageView` and its `*View` types, the
//! encoder (`encodeMessage` and the little `write*` helpers beneath it), the
//! borrowed-view decoder (`decodeView` / `decodeBody` / `decodePrefix`, which
//! doubles as the stream framer, see ADR-0029), and the owned materializer
//! (`decodeOwned` / `ownedFromView`). It all comes out through `codec.syrup`, and
//! `codec.capnp` is the word-aligned counterpart.
//!
//! Every frame here is potentially hostile, so the length math on each prefix is
//! checked, and the recursive readers stop at `max_decode_nesting`, which means a
//! deeply nested frame fails loudly instead of running off the stack. And, as
//! everywhere in the codec layer, this only reads and writes bytes. It holds no
//! session authority.

const std = @import("std");

const foundation = @import("../../foundation/mod.zig");
const model = @import("../../model/mod.zig");
const framing = @import("../framing.zig");

pub const AdmittedMessage = enum {
    deliver,
    resolve,
    gc_export,
    gc_answer,
    handoff,
    start_session,
    abort,
    listen,
    get,
    index,
};

const pre_spec_admitted = [_]AdmittedMessage{
    .deliver,
    .resolve,
    .gc_export,
    .gc_answer,
    .handoff,
    .abort,
    .listen,
    .get,
    .index,
};

const v1_0_admitted = [_]AdmittedMessage{
    .deliver,
    .resolve,
    .gc_export,
    .gc_answer,
    .handoff,
    .start_session,
    .abort,
    .listen,
    .get,
    .index,
};

pub const CodecDescriptor = struct {
    name: []const u8,
    frame_shape: foundation.FrameShape,

    pub fn supportsProfile(_: CodecDescriptor, profile: model.WireProfile) bool {
        return profile.captp_version == .pre_spec or profile.isGoblinsV1_0();
    }

    pub fn admittedMessages(_: CodecDescriptor, profile: model.WireProfile) []const AdmittedMessage {
        if (profile.isGoblinsV1_0()) return v1_0_admitted[0..];
        return pre_spec_admitted[0..];
    }
};

pub const descriptor = CodecDescriptor{
    .name = "syrup",
    .frame_shape = .byte,
};

pub fn admits(messages: []const AdmittedMessage, kind: AdmittedMessage) bool {
    for (messages) |message| {
        if (message == kind) return true;
    }
    return false;
}

pub const Error = error{
    InvalidFrameShape,
    MalformedFrame,
    UnsupportedArgument,
    UnsupportedMessage,
    UnsupportedReference,
    /// The buffer ends inside a message — a leaf reader ran past the available
    /// bytes. This is an internal framing signal, not a public decode failure:
    /// the whole-frame [`decodeBody`] folds it into `MalformedFrame` (a frame
    /// must be complete), while the streaming [`decodePrefix`] surfaces it as
    /// `.incomplete` so the caller reads more bytes. No structurally-valid
    /// frame ever yields it from `decodeBody`.
    Incomplete,
};

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

pub const AbortView = struct {
    kind: model.AbortKind,
    message: []const u8,
};

pub const PositionListView = struct {
    bytes: []const u8,

    pub fn count(self: PositionListView) Error!usize {
        var cursor: usize = 0;
        var total: usize = 0;
        while (cursor < self.bytes.len) {
            _ = try readPositiveInt(self.bytes, &cursor);
            total += 1;
        }
        return total;
    }

    pub fn at(self: PositionListView, index: usize) Error!u64 {
        var cursor: usize = 0;
        var current: usize = 0;
        while (cursor < self.bytes.len) {
            const value = try readPositiveInt(self.bytes, &cursor);
            if (current == index) return value;
            current += 1;
        }
        return Error.MalformedFrame;
    }

    pub fn toOwnedSlice(self: PositionListView, allocator: std.mem.Allocator) ![]u64 {
        const total = try self.count();
        const values = try allocator.alloc(u64, total);
        errdefer allocator.free(values);

        var cursor: usize = 0;
        for (values) |*value| {
            value.* = try readPositiveInt(self.bytes, &cursor);
        }
        return values;
    }
};

pub const GcExportView = struct {
    positions: PositionListView,
    deltas: PositionListView,
};

pub const GcAnswerView = struct {
    positions: PositionListView,
};

pub const ReferenceView = union(enum) {
    near: model.NearRef,
    far: model.FarRef,
    promise: model.PromiseRef,

    pub fn toModel(self: ReferenceView) model.Reference {
        return switch (self) {
            .near => |near| .{ .near = near },
            .far => |far| .{ .far = far },
            .promise => |promise| .{ .promise = promise },
        };
    }
};

/// A coarse borrowed view of a deliver argument, carrying the structure the
/// engine inspects directly: references, handoffs, errors, void, and raw bytes
/// (strings and symbols read back as `.bytes` — the byte-fidelity distinction is
/// dropped here). Numeric, boolean, float, list, set, tagged, and keyword
/// argument kinds are not modeled; a deliver carrying them decodes through the
/// codec-neutral [`decodeBody`] / [`model.view.Body`], which is full fidelity.
pub const ArgumentView = union(enum) {
    bytes: []const u8,
    reference: ReferenceView,
    @"error": model.Error,
    handoff: model.view.Handoff,
    void: void,

    pub fn toOwned(self: ArgumentView, allocator: std.mem.Allocator) !model.Argument {
        return switch (self) {
            .bytes => |bytes| .{ .bytes = try allocator.dupe(u8, bytes) },
            .reference => |reference| .{ .reference = reference.toModel() },
            .@"error" => |err| .{ .@"error" = .{ .message = try allocator.dupe(u8, err.message) } },
            .handoff => |handoff| blk: {
                const boxed = try allocator.create(model.Handoff);
                errdefer allocator.destroy(boxed);
                boxed.* = try handoff.toOwned(allocator);
                break :blk .{ .handoff = boxed };
            },
            .void => .{ .void = {} },
        };
    }
};

pub const ArgumentListView = struct {
    bytes: []const u8,

    pub fn count(self: ArgumentListView) Error!usize {
        var cursor: usize = 0;
        var total: usize = 0;
        while (cursor < self.bytes.len) {
            _ = try readArgument(self.bytes, &cursor);
            total += 1;
        }
        return total;
    }

    pub fn at(self: ArgumentListView, index: usize) Error!ArgumentView {
        var cursor: usize = 0;
        var current: usize = 0;
        while (cursor < self.bytes.len) {
            const argument = try readArgument(self.bytes, &cursor);
            if (current == index) return argument;
            current += 1;
        }
        return Error.MalformedFrame;
    }

    pub fn toOwnedSlice(self: ArgumentListView, allocator: std.mem.Allocator) ![]model.Argument {
        const total = try self.count();
        const values = try allocator.alloc(model.Argument, total);
        errdefer allocator.free(values);

        var cursor: usize = 0;
        var initialized: usize = 0;
        errdefer {
            for (values[0..initialized]) |value| {
                freeOwnedArgument(allocator, value);
            }
        }

        for (values) |*value| {
            value.* = try (try readArgument(self.bytes, &cursor)).toOwned(allocator);
            initialized += 1;
        }
        return values;
    }
};

pub const ResolutionView = union(enum) {
    fulfill: ArgumentView,
    break_: model.Error,

    pub fn toOwned(self: ResolutionView, allocator: std.mem.Allocator) !model.Resolution {
        return switch (self) {
            .fulfill => |arg| .{ .fulfill = try arg.toOwned(allocator) },
            .break_ => |err| .{ .break_ = .{ .message = try allocator.dupe(u8, err.message) } },
        };
    }
};

pub const DeliverView = struct {
    target: ReferenceView,
    args: ArgumentListView,
    answer: ?u64,
    resolve_me_desc: ?ReferenceView,
};

pub const ResolveView = struct {
    answer: u64,
    resolution: ResolutionView,
};

pub const ListenView = struct {
    target: ReferenceView,
    listener: ReferenceView,
    wants_partial: bool,
};

pub const GetView = struct {
    receiver: ReferenceView,
    field: []const u8,
    answer: u64,
};

pub const IndexView = struct {
    receiver: ReferenceView,
    index: i64,
    answer: u64,
};

pub const SignatureView = struct {
    r: []const u8,
    s: []const u8,

    pub fn len(self: SignatureView) usize {
        return self.r.len + self.s.len;
    }
};

pub const StartSessionView = struct {
    captp_version: model.CaptpVersion,
    session_pubkey: model.SessionPubkey,
    acceptable_location: model.PeerLocator,
    acceptable_location_sig: SignatureView,
};

pub const HandoffView = struct {
    bytes: []const u8,
    envelope_tag: []const u8,
    payload_tag: []const u8,
};

pub const MessageView = union(enum) {
    deliver: DeliverView,
    resolve: ResolveView,
    abort: AbortView,
    gc_export: GcExportView,
    gc_answer: GcAnswerView,
    listen: ListenView,
    get: GetView,
    index: IndexView,
    start_session: StartSessionView,
    handoff: HandoffView,
};

pub fn encodeMessage(allocator: std.mem.Allocator, message: model.Message) !foundation.Frame {
    return encodeMessageForProfile(allocator, model.WireProfile.pre_spec, message);
}

/// ADR-0015 canonical signed bytes for an `op:start-session`
/// `acceptable-location`: the Syrup encoding of the wrapping record
/// `<my-location $acceptable-location>` (per Goblins `captp.rkt`).
///
/// This is the exact byte domain `acceptable_location_sig` signs over. Both
/// ends must produce identical bytes for verification to succeed, so it is
/// single-sourced here against the codec's own locator encoder rather than
/// re-derived at the signing site. Caller owns the returned slice.
pub fn canonicalLocationSignedBytes(
    allocator: std.mem.Allocator,
    location: model.PeerLocator,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try beginRecord(allocator, &out);
    try writeSymbol(allocator, &out, "my-location");
    try writeLocator(allocator, &out, location);
    try endRecord(allocator, &out);
    return out.toOwnedSlice(allocator);
}

pub fn encodeMessageForProfile(
    allocator: std.mem.Allocator,
    profile: model.WireProfile,
    message: model.Message,
) !foundation.Frame {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    switch (message) {
        .abort => |abort| {
            try beginRecord(allocator, &out);
            try writeSymbol(allocator, &out, "op:abort");
            try writeAbortWireString(allocator, &out, abort);
            try endRecord(allocator, &out);
        },
        .deliver => |deliver| {
            // A no-answer deliver is a single `op:deliver` with a `#f` answer
            // position — the fire-and-forget one-way send. There is no separate
            // one-way record on the wire.
            try beginRecord(allocator, &out);
            try writeSymbol(allocator, &out, "op:deliver");
            try writeTargetReference(allocator, &out, deliver.target);
            try writeArgumentList(allocator, &out, deliver.args);
            if (deliver.answer) |answer| {
                try writePositiveInt(allocator, &out, answer);
            } else {
                try writeBool(allocator, &out, false);
            }
            if (profile.isGoblinsV1_0() and deliver.resolve_me_desc != null) {
                try writePayloadReference(allocator, &out, deliver.resolve_me_desc.?);
            } else {
                try writeBool(allocator, &out, false);
            }
            try endRecord(allocator, &out);
        },
        .resolve => |resolve| {
            try beginRecord(allocator, &out);
            try writeSymbol(allocator, &out, "op:resolve");
            try writePositiveInt(allocator, &out, resolve.answer);
            switch (resolve.resolution) {
                .fulfill => |arg| {
                    try beginRecord(allocator, &out);
                    try writeSymbol(allocator, &out, "resolve:fulfill");
                    try writeArgument(allocator, &out, arg);
                    try endRecord(allocator, &out);
                },
                .break_ => |err| {
                    try beginRecord(allocator, &out);
                    try writeSymbol(allocator, &out, "resolve:break");
                    try writeError(allocator, &out, err);
                    try endRecord(allocator, &out);
                },
            }
            try endRecord(allocator, &out);
        },
        .gc_export => |gc_export| {
            try beginRecord(allocator, &out);
            try writeSymbol(allocator, &out, "op:gc-exports");
            try writeUnsignedList(allocator, &out, gc_export.positions);
            try writeUnsignedList(allocator, &out, gc_export.deltas);
            try endRecord(allocator, &out);
        },
        .gc_answer => |gc_answer| {
            try beginRecord(allocator, &out);
            try writeSymbol(allocator, &out, "op:gc-answers");
            try writeUnsignedList(allocator, &out, gc_answer.positions);
            try endRecord(allocator, &out);
        },
        .get => |get| {
            try beginRecord(allocator, &out);
            try writeSymbol(allocator, &out, "op:get");
            try writeTargetReference(allocator, &out, get.receiver);
            try writeSymbol(allocator, &out, get.field);
            try writePositiveInt(allocator, &out, get.answer);
            try endRecord(allocator, &out);
        },
        .index => |index| {
            try beginRecord(allocator, &out);
            try writeSymbol(allocator, &out, "op:index");
            try writeTargetReference(allocator, &out, index.receiver);
            try writeInteger(allocator, &out, index.index);
            try writePositiveInt(allocator, &out, index.answer);
            try endRecord(allocator, &out);
        },
        .listen => |listen| {
            try beginRecord(allocator, &out);
            try writeSymbol(allocator, &out, "op:listen");
            try writePayloadReference(allocator, &out, listen.target);
            try writePayloadReference(allocator, &out, listen.listener);
            if (profile.isGoblinsV1_0()) {
                try writeBool(allocator, &out, listen.wants_partial);
            }
            try endRecord(allocator, &out);
        },
        .start_session => |start_session| {
            try beginRecord(allocator, &out);
            try writeSymbol(allocator, &out, "op:start-session");
            try writeString(allocator, &out, start_session.captp_version.wireString());
            try writePeerKey(allocator, &out, start_session.session_pubkey.bytes);
            try writeLocator(allocator, &out, start_session.acceptable_location);
            try writeSignature(allocator, &out, start_session.acceptable_location_sig.bytes);
            try endRecord(allocator, &out);
        },
        .handoff => |handoff| try writeHandoff(allocator, &out, handoff),
    }

    const storage = try out.toOwnedSlice(allocator);
    return try foundation.Frame.initOwned(allocator, storage, .byte, .fromByteUnits(1));
}

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
        const acceptable_location = try readLocator(bytes, cursor);
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
    if (locator.hints.entries.len != 0 or locator.hints.empty_wire_was_false) {
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

fn handoffViewToOwned(allocator: std.mem.Allocator, view: HandoffView) anyerror!model.Handoff {
    var cursor: usize = 0;
    const handoff = try readSignedHandoff(allocator, view.bytes, &cursor);
    errdefer freeOwnedHandoff(allocator, handoff);
    try expectEnd(view.bytes, cursor);
    return handoff;
}

fn readSignedHandoff(allocator: std.mem.Allocator, bytes: []const u8, cursor: *usize) anyerror!model.Handoff {
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
        var result = give;
        result.signature = signature;
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
) anyerror!model.HandoffReceive {
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
    if (locator.hints.entries.len != 0 or locator.hints.empty_wire_was_false) {
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
}

fn beginRecord(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    try out.append(allocator, '<');
}

fn endRecord(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    try out.append(allocator, '>');
}

fn writeSymbol(allocator: std.mem.Allocator, out: *std.ArrayList(u8), symbol: []const u8) !void {
    try writeUnsigned(allocator, out, symbol.len);
    try out.append(allocator, '\'');
    try out.appendSlice(allocator, symbol);
}

fn writeString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), string: []const u8) !void {
    try writeUnsigned(allocator, out, string.len);
    try out.append(allocator, '"');
    try out.appendSlice(allocator, string);
}

fn writeAbortWireString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), abort: model.AbortReason) !void {
    if (abort.kind == .other) {
        try writeString(allocator, out, abort.message);
        return;
    }

    const label = abort.kind.wireName();
    try writeUnsigned(allocator, out, label.len + ": ".len + abort.message.len);
    try out.append(allocator, '"');
    try out.appendSlice(allocator, label);
    try out.appendSlice(allocator, ": ");
    try out.appendSlice(allocator, abort.message);
}

fn writeBytes(allocator: std.mem.Allocator, out: *std.ArrayList(u8), bytes: []const u8) !void {
    try writeUnsigned(allocator, out, bytes.len);
    try out.append(allocator, ':');
    try out.appendSlice(allocator, bytes);
}

fn writeInteger(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: i64) !void {
    if (value < 0) {
        try writeSignedMagnitude(allocator, out, value);
        try out.append(allocator, '-');
    } else {
        try writePositiveInt(allocator, out, @intCast(value));
    }
}

fn writePositiveInt(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u64) !void {
    try writeUnsigned(allocator, out, value);
    try out.append(allocator, '+');
}

fn writeBool(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: bool) !void {
    try out.append(allocator, if (value) 't' else 'f');
}

/// Syrup encodes a `binary64` double as `'D'` followed by 8 bytes IEEE-754
/// big-endian. The model carries only `float64`; `'F'` (binary32) is not a
/// pancake passable.
fn writeFloat64(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: f64) !void {
    try out.append(allocator, 'D');
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, @bitCast(value), .big);
    try out.appendSlice(allocator, buf[0..]);
}

fn writeArgumentList(allocator: std.mem.Allocator, out: *std.ArrayList(u8), args: []const model.Argument) anyerror!void {
    try out.append(allocator, '[');
    for (args) |arg| {
        try writeArgument(allocator, out, arg);
    }
    try out.append(allocator, ']');
}

fn writeUnsignedList(allocator: std.mem.Allocator, out: *std.ArrayList(u8), values: []const u64) !void {
    try out.append(allocator, '[');
    for (values) |value| {
        try writePositiveInt(allocator, out, value);
    }
    try out.append(allocator, ']');
}

fn beginList(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    try out.append(allocator, '[');
}

fn endList(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    try out.append(allocator, ']');
}

fn writeArgument(allocator: std.mem.Allocator, out: *std.ArrayList(u8), arg: model.Argument) anyerror!void {
    switch (arg) {
        .bytes => |bytes| try writeBytes(allocator, out, bytes),
        .symbol => |symbol| try writeSymbol(allocator, out, symbol),
        .reference => |reference| try writePayloadReference(allocator, out, reference),
        .string => |string| try writeString(allocator, out, string),
        .handoff => |handoff| try writeHandoff(allocator, out, handoff.*),
        .integer => |integer| try writeInteger(allocator, out, integer),
        .float64 => |value| try writeFloat64(allocator, out, value),
        .boolean => |value| try writeBool(allocator, out, value),
        .list => |items| try writeArgumentList(allocator, out, items),
        .void => {
            try beginRecord(allocator, out);
            try writeSymbol(allocator, out, "void");
            try endRecord(allocator, out);
        },
        .set => |items| {
            try out.append(allocator, '#');
            try writeCanonicalSet(allocator, out, items);
            try out.append(allocator, '$');
        },
        .tagged => |tagged| {
            try beginRecord(allocator, out);
            try writeSymbol(allocator, out, "user-record");
            try writeSymbol(allocator, out, tagged.tag);
            try writeArgumentList(allocator, out, tagged.value);
            try endRecord(allocator, out);
        },
        .keyword => |keyword| {
            try beginRecord(allocator, out);
            try writeSymbol(allocator, out, "kw");
            try writeSymbol(allocator, out, keyword);
            try endRecord(allocator, out);
        },
        else => return Error.UnsupportedArgument,
    }
}

/// Encode a set's elements in canonical order: each element is encoded
/// independently, the encodings are sorted lexicographically by byte, and
/// emitted in that order. A set is unordered, so its wire form must not depend
/// on the order the model held it in — the encode-side partner of the
/// order-agnostic set equality in `model.equality`.
fn writeCanonicalSet(allocator: std.mem.Allocator, out: *std.ArrayList(u8), items: []const model.Argument) anyerror!void {
    if (items.len == 0) return;

    const encoded = try allocator.alloc([]u8, items.len);
    var built: usize = 0;
    defer {
        for (encoded[0..built]) |element| allocator.free(element);
        allocator.free(encoded);
    }

    for (items) |item| {
        var element: std.ArrayList(u8) = .empty;
        errdefer element.deinit(allocator);
        try writeArgument(allocator, &element, item);
        encoded[built] = try element.toOwnedSlice(allocator);
        built += 1;
    }

    std.mem.sort([]u8, encoded, {}, lessByteSlice);
    for (encoded) |element| try out.appendSlice(allocator, element);
}

fn lessByteSlice(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn writeHandoff(allocator: std.mem.Allocator, out: *std.ArrayList(u8), handoff: model.Handoff) !void {
    switch (handoff) {
        .give => |give| try writeSignedGive(allocator, out, give),
        .receive => |receive| try writeSignedReceive(allocator, out, receive),
    }
}

fn writeSignedGive(allocator: std.mem.Allocator, out: *std.ArrayList(u8), give: model.HandoffGive) !void {
    try beginRecord(allocator, out);
    try writeSymbol(allocator, out, "desc:sig-envelope");
    try writeHandoffGiveRecord(allocator, out, give);
    try writeSignature(allocator, out, give.signature);
    try endRecord(allocator, out);
}

fn writeSignedReceive(allocator: std.mem.Allocator, out: *std.ArrayList(u8), receive: model.HandoffReceive) !void {
    try beginRecord(allocator, out);
    try writeSymbol(allocator, out, "desc:sig-envelope");
    try writeHandoffReceiveRecord(allocator, out, receive);
    try writeSignature(allocator, out, receive.signature);
    try endRecord(allocator, out);
}

fn writeHandoffGiveRecord(allocator: std.mem.Allocator, out: *std.ArrayList(u8), give: model.HandoffGive) !void {
    try beginRecord(allocator, out);
    try writeSymbol(allocator, out, "desc:handoff-give");
    try writePeerKey(allocator, out, give.recipient_key);
    try writeLocatorString(allocator, out, give.exporter_location);
    try writeBytes(allocator, out, give.gifter_exporter_session);
    try writeBytes(allocator, out, give.gifter_side);
    try writeBytes(allocator, out, give.gift_id);
    try endRecord(allocator, out);
}

fn writeHandoffReceiveRecord(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    receive: model.HandoffReceive,
) !void {
    try beginRecord(allocator, out);
    try writeSymbol(allocator, out, "desc:handoff-receive");
    try writeBytes(allocator, out, receive.receiving_session);
    try writeBytes(allocator, out, receive.receiving_side);
    try writePositiveInt(allocator, out, receive.handoff_count);
    try writeSignedGive(allocator, out, receive.signed_give);
    try endRecord(allocator, out);
}

fn writePeerKey(allocator: std.mem.Allocator, out: *std.ArrayList(u8), q: []const u8) !void {
    try beginList(allocator, out);
    try writeSymbol(allocator, out, "public-key");
    try beginList(allocator, out);
    try writeSymbol(allocator, out, "ecc");
    try beginList(allocator, out);
    try writeSymbol(allocator, out, "curve");
    try writeSymbol(allocator, out, "Ed25519");
    try endList(allocator, out);
    try beginList(allocator, out);
    try writeSymbol(allocator, out, "flags");
    try writeSymbol(allocator, out, "eddsa");
    try endList(allocator, out);
    try beginList(allocator, out);
    try writeSymbol(allocator, out, "q");
    try writeBytes(allocator, out, q);
    try endList(allocator, out);
    try endList(allocator, out);
    try endList(allocator, out);
}

fn writeSignature(allocator: std.mem.Allocator, out: *std.ArrayList(u8), sig: []const u8) !void {
    if (sig.len != 64) {
        return Error.UnsupportedMessage;
    }

    try beginList(allocator, out);
    try writeSymbol(allocator, out, "sig-val");
    try beginList(allocator, out);
    try writeSymbol(allocator, out, "eddsa");
    try beginList(allocator, out);
    try writeSymbol(allocator, out, "r");
    try writeBytes(allocator, out, sig[0..32]);
    try endList(allocator, out);
    try beginList(allocator, out);
    try writeSymbol(allocator, out, "s");
    try writeBytes(allocator, out, sig[32..64]);
    try endList(allocator, out);
    try endList(allocator, out);
    try endList(allocator, out);
}

fn writeLocator(allocator: std.mem.Allocator, out: *std.ArrayList(u8), location: model.PeerLocator) !void {
    try beginRecord(allocator, out);
    try writeSymbol(allocator, out, "ocapn-peer");
    try writeSymbol(allocator, out, location.transport);
    try writeString(allocator, out, location.designator);
    if (location.hints.entries.len == 0 and location.hints.empty_wire_was_false) {
        try writeBool(allocator, out, false);
    } else {
        try out.appendSlice(allocator, "{}");
    }
    try endRecord(allocator, out);
}

fn writeLocatorString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), location: []const u8) !void {
    const split = std.mem.indexOfScalar(u8, location, ':') orelse return Error.UnsupportedMessage;
    return writeLocator(allocator, out, .{
        .transport = location[0..split],
        .designator = location[split + 1 ..],
        .hints = .{},
    });
}

fn writeError(allocator: std.mem.Allocator, out: *std.ArrayList(u8), err: model.Error) !void {
    try beginRecord(allocator, out);
    try writeSymbol(allocator, out, "error");
    try writeString(allocator, out, err.message);
    try endRecord(allocator, out);
}

fn writeUnsigned(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: anytype) !void {
    var buf: [20]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{d}", .{value});
    try out.appendSlice(allocator, text);
}

fn writeSignedMagnitude(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: i64) !void {
    const magnitude: u64 = if (value == std.math.minInt(i64))
        @as(u64, 1) << 63
    else
        @intCast(-value);
    try writeUnsigned(allocator, out, magnitude);
}

fn writeTargetReference(allocator: std.mem.Allocator, out: *std.ArrayList(u8), reference: model.Reference) !void {
    switch (reference) {
        .far => |far| {
            try beginRecord(allocator, out);
            try writeSymbol(allocator, out, "desc:export");
            try writePositiveInt(allocator, out, far.import_id);
            try endRecord(allocator, out);
        },
        // A pipelined deliver targets the (still-unresolved) answer position.
        // `desc:answer` carries no path operand: a non-empty path must have been
        // decomposed into single-hop links by the engine before encode (ADR-0007
        // § Multi-hop decomposition at the sender). One reaching here is an
        // engine bug — fail loud rather
        // than silently drop the path.
        .promise => |promise| {
            if (!promise.path.isEmpty()) return Error.UnsupportedReference;
            try beginRecord(allocator, out);
            try writeSymbol(allocator, out, "desc:answer");
            try writePositiveInt(allocator, out, promise.answer_id);
            try endRecord(allocator, out);
        },
        else => return Error.UnsupportedReference,
    }
}

fn writePayloadReference(allocator: std.mem.Allocator, out: *std.ArrayList(u8), reference: model.Reference) !void {
    switch (reference) {
        .near => |near| {
            try beginRecord(allocator, out);
            try writeSymbol(allocator, out, switch (near.kind) {
                .object => "desc:import-object",
                .promise => "desc:import-promise",
            });
            try writePositiveInt(allocator, out, near.export_id);
            try endRecord(allocator, out);
        },
        .far => |far| {
            try beginRecord(allocator, out);
            try writeSymbol(allocator, out, "desc:export");
            try writePositiveInt(allocator, out, far.import_id);
            try endRecord(allocator, out);
        },
        .promise => |promise| {
            if (!promise.path.isEmpty()) return Error.UnsupportedReference;
            try beginRecord(allocator, out);
            try writeSymbol(allocator, out, "desc:answer");
            try writePositiveInt(allocator, out, promise.answer_id);
            try endRecord(allocator, out);
        },
        else => return Error.UnsupportedReference,
    }
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

fn readSymbol(bytes: []const u8, cursor: *usize) Error![]const u8 {
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

fn readArgument(bytes: []const u8, cursor: *usize) Error!ArgumentView {
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
/// The encoder is the mirror (`near`→`desc:import-object`, `far`→`desc:export`),
/// so a reference sent and echoed back swaps arms — that swap *is* the
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
        if (bytes[cursor.* + 1] != '}') return Error.MalformedFrame;
        cursor.* += 2;
        return model.Hints.emptyMap();
    }
    return Error.MalformedFrame;
}

fn readSignatureView(bytes: []const u8, cursor: *usize) Error!SignatureView {
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

fn readPositiveInt(bytes: []const u8, cursor: *usize) Error!u64 {
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
    const value = std.fmt.parseInt(i64, bytes[start..cursor.*], 10) catch {
        return Error.MalformedFrame;
    };
    switch (bytes[cursor.*]) {
        '+' => {
            cursor.* += 1;
            return value;
        },
        '-' => {
            cursor.* += 1;
            return -value;
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

fn readBytes(bytes: []const u8, cursor: *usize) Error![]const u8 {
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

fn readBalanced(bytes: []const u8, cursor: *usize, open: u8, close: u8) Error![]const u8 {
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

fn readByte(bytes: []const u8, cursor: *usize, expected: u8) Error!void {
    if (cursor.* >= bytes.len) return Error.Incomplete;
    if (bytes[cursor.*] != expected) return Error.MalformedFrame;
    cursor.* += 1;
}

fn expectEnd(bytes: []const u8, cursor: usize) Error!void {
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

fn countDigits(bytes: []const u8) usize {
    var count: usize = 0;
    while (count < bytes.len and std.ascii.isDigit(bytes[count])) {
        count += 1;
    }
    return count;
}

fn freeOwnedArgument(allocator: std.mem.Allocator, argument: model.Argument) void {
    model.freeArgument(allocator, argument);
}
