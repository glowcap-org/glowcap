//! The Syrup codec hub: shared types, and the public entry points.
//!
//! Syrup is the byte-record format, the self-delimiting alternative to Cap'n
//! Proto. It carries the same `model.Message` tree as length-prefixed records
//! (`<...>`), lists (`[...]`), symbols, strings, and integers. This file owns the
//! types both halves of the codec share: the borrowed `MessageView` and its
//! `*View` types, the `Error` and `WalkError` sets, and the `CodecDescriptor`.
//! The encode half lives in [`encode`] (`encodeMessage` and the `write*`
//! primitives beneath it) and the decode half lives in [`decode`] (`decodeView`,
//! `decodeBody`, `decodePrefix`, which doubles as the stream framer per ADR-0029,
//! and `decodeOwned` / `ownedFromView`). Both halves are re-exported here so the
//! whole codec comes out through `codec.syrup`, and `codec.capnp` is the
//! word-aligned counterpart.
//!
//! As everywhere in the codec layer, this only describes and routes bytes. It
//! holds no session authority. Every frame the decoder reads is potentially
//! hostile, so the length math on each prefix is checked and the recursive
//! readers stop at a fixed nesting bound, which means a deeply nested frame fails
//! loudly instead of running off the stack.

const std = @import("std");

const foundation = @import("../../foundation/mod.zig");
const model = @import("../../model/mod.zig");

const encode = @import("encode.zig");
const decode = @import("decode.zig");

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

/// The error set of the mutually-recursive encode/decode walkers — the encoder
/// cycle, where `writeArgument`, `writeArgumentList`, and `writeCanonicalSet`
/// call one another, and the handoff readers. Zig cannot infer an error set
/// around a recursive cycle, so
/// these would otherwise have to fall back to the fully-erased error set and lose
/// exhaustiveness at every call site. Naming the union — the codec's structural
/// `Error`, the allocator's `OutOfMemory`, and `NoSpaceLeft` from the
/// fixed-buffer length-prefix formatter the encoders use — keeps them precisely
/// typed. (`NoSpaceLeft` is unreachable in practice: the buffer is sized for the
/// widest integer; it is named here only because the formatter's type carries it.)
pub const WalkError = Error || std.mem.Allocator.Error || error{NoSpaceLeft};

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
            _ = try decode.readPositiveInt(self.bytes, &cursor);
            total += 1;
        }
        return total;
    }

    pub fn at(self: PositionListView, index: usize) Error!u64 {
        var cursor: usize = 0;
        var current: usize = 0;
        while (cursor < self.bytes.len) {
            const value = try decode.readPositiveInt(self.bytes, &cursor);
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
            value.* = try decode.readPositiveInt(self.bytes, &cursor);
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
    sturdy: SturdyRefView,

    pub const SturdyRefView = struct {
        peer: model.PeerLocator,
        swissnum: []const u8,
    };

    pub fn toModel(self: ReferenceView) model.Reference {
        return switch (self) {
            .near => |near| .{ .near = near },
            .far => |far| .{ .far = far },
            .promise => |promise| .{ .promise = promise },
            .sturdy => |sturdy| .{ .sturdy = .{ .peer = sturdy.peer, .swissnum = sturdy.swissnum } },
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
            _ = try decode.readArgument(self.bytes, &cursor);
            total += 1;
        }
        return total;
    }

    pub fn at(self: ArgumentListView, index: usize) Error!ArgumentView {
        var cursor: usize = 0;
        var current: usize = 0;
        while (cursor < self.bytes.len) {
            const argument = try decode.readArgument(self.bytes, &cursor);
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
                decode.freeOwnedArgument(allocator, value);
            }
        }

        for (values) |*value| {
            value.* = try (try decode.readArgument(self.bytes, &cursor)).toOwned(allocator);
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

// ── Encode entry points (implemented in `encode`) ────────────────────────────

pub const encodeMessage = encode.encodeMessage;
pub const encodeMessageForProfile = encode.encodeMessageForProfile;
pub const canonicalLocationSignedBytes = encode.canonicalLocationSignedBytes;
pub const canonicalLocationSignedBytesRaw = encode.canonicalLocationSignedBytesRaw;
pub const canonicalHandoffGiveSignedBytes = encode.canonicalHandoffGiveSignedBytes;
pub const handoffGiveRecordBytesRawLocation = encode.handoffGiveRecordBytesRawLocation;
pub const wrapSignedHandoffGive = encode.wrapSignedHandoffGive;
pub const canonicalHandoffReceiveSignedBytes = encode.canonicalHandoffReceiveSignedBytes;

// ── Decode entry points (implemented in `decode`) ────────────────────────────

pub const decodeView = decode.decodeView;
pub const decodeOwned = decode.decodeOwned;
pub const ownedFromView = decode.ownedFromView;
pub const decodeBody = decode.decodeBody;
pub const decodePrefix = decode.decodePrefix;
pub const readBytes = decode.readBytes;
pub const readHintsOwned = decode.readHintsOwned;
pub const readLocatorOwned = decode.readLocatorOwned;
pub const spanSignedHandoffGive = decode.spanSignedHandoffGive;
