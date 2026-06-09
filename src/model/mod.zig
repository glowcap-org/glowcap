//! The message, described once, with no codec attached.
//!
//! Both codecs produce this same shape, and the engine works against it, so all
//! of pancake shares one vocabulary for what a message actually is. That's what
//! lives here: the value types (`Message` and its arms, `Reference`, `Argument`,
//! `Resolution`, and the handshake, handoff, and gc shapes), plus the words two
//! peers negotiate with (`CodecId`, `CaptpVersion`, `WireProfile`, `FeatureSet`,
//! `AbortKind`).
//!
//! None of it carries a codec, an allocation policy, or any authority. It's just
//! the shape. `session` is what decides whether a given message is valid, and
//! `codec` is what turns it into bytes. Three sibling files finish the story:
//! `owned` handles who clones and frees the tree, `view` is the borrowed look at
//! it over live wire bytes, and `equality` is how two values compare.

const std = @import("std");

/// Who owns a `Message` once the frame it arrived on is gone, and how it gets
/// released. It all lives in `owned.zig` so there's a single `clone` / `free`
/// contract for everyone who keeps a message around: the session's pipelining
/// tables, and the one copy we make on the way out.
pub const owned = @import("owned.zig");
pub const cloneMessage = owned.cloneMessage;
pub const freeMessage = owned.freeMessage;
pub const cloneArgument = owned.cloneArgument;
pub const freeArgument = owned.freeArgument;
pub const cloneArgumentSlice = owned.cloneArgumentSlice;
pub const freeArgumentSlice = owned.freeArgumentSlice;
pub const cloneResolution = owned.cloneResolution;
pub const freeResolution = owned.freeResolution;
pub const cloneReference = owned.cloneReference;
pub const freeReference = owned.freeReference;
pub const clonePipelinePath = owned.clonePipelinePath;
pub const freePipelinePath = owned.freePipelinePath;
pub const freeHandoffGive = owned.freeHandoffGive;
pub const freeHandoff = owned.freeHandoff;

/// The borrowed look at a message, read straight off the wire bytes with no
/// copy. Both codecs produce this one shape, and the engine works against it.
/// See `view`.
pub const view = @import("view.zig");

/// Whether two value trees are structurally equal. This is the in-memory
/// evidence behind distributed equality: per ADR-0012, two references that name
/// the same thing compare equal here. See `equality`.
pub const equality = @import("equality.zig");
pub const referencesEqual = equality.referencesEqual;
pub const argumentsEqual = equality.argumentsEqual;

/// OCapN locator ⇄ `ocapn://` URI: the out-of-band bootstrap form a peer or
/// sturdyref address is shared in. Pure parse/emit over the locator types here;
/// no netlayer, no I/O. See `uri`.
pub const uri = @import("uri.zig");
pub const peerLocatorsEqual = equality.peerLocatorsEqual;

/// Which wire codec a direct session speaks. The two built-ins are `capnp` (the
/// native word-aligned fast path) and `syrup` (the byte-record one everyone can
/// fall back to); negotiation lists them best-first and breaks ties on that
/// order.
///
/// The enum is non-exhaustive on purpose: a consumer can mint their own codec id
/// (`@enumFromInt` past the built-ins) and register it with `codec.registry`, so
/// "bring your own codec" needs no fork of this type. The tag is a stable `u16`
/// wire identity — built-in values never move.
///
/// This lives in `model` rather than `codec`, and that's deliberate. The session
/// has to record which codec it picked, but it must not depend on a codec to do
/// it; the choice stays the session's to make. So the id sits down here,
/// `codec.registry`/`codec.dispatch` resolve it to an implementation, and
/// `engine.negotiation` is what settles it during the handshake.
pub const CodecId = enum(u16) {
    capnp = 0,
    syrup = 1,
    _,
};

pub const CaptpVersion = enum {
    v1_0,
    pre_spec,

    pub fn wireString(self: CaptpVersion) []const u8 {
        return switch (self) {
            .v1_0 => "1.0",
            .pre_spec => "pancake-pre-spec",
        };
    }

    pub fn fromWireString(wire: []const u8) ?CaptpVersion {
        if (std.mem.eql(u8, wire, "1.0")) return .v1_0;
        if (std.mem.eql(u8, wire, "ocapn-1.0")) return .v1_0;
        if (std.mem.eql(u8, wire, "pancake-pre-spec")) return .pre_spec;
        return null;
    }
};

pub const ProfileFlags = struct {
    goblins_canonical: bool = false,
};

pub const WireProfile = struct {
    captp_version: CaptpVersion,
    flags: ProfileFlags = .{},

    pub const v1_0 = WireProfile{
        .captp_version = .v1_0,
        .flags = .{ .goblins_canonical = true },
    };
    pub const pre_spec = WireProfile{
        .captp_version = .pre_spec,
    };

    pub fn name(self: WireProfile) []const u8 {
        return switch (self.captp_version) {
            .v1_0 => "ocapn-v1.0",
            .pre_spec => "pancake-pre-spec",
        };
    }

    pub fn isGoblinsV1_0(self: WireProfile) bool {
        return self.captp_version == .v1_0 and self.flags.goblins_canonical;
    }
};

pub const FeatureSet = struct {
    pipelining: bool = false,
    handoff: bool = false,
    wire_delta: bool = false,
    sturdyref: bool = false,
    stream: bool = false,
    equality: bool = false,

    /// The minimal set: Deliver, Resolve, and Abort only.
    pub fn minimum() FeatureSet {
        return .{};
    }

    /// Full pancake-native feature set.
    pub fn full() FeatureSet {
        return .{
            .pipelining = true,
            .handoff = true,
            .wire_delta = true,
            .sturdyref = true,
            .stream = true,
            .equality = true,
        };
    }

    /// Pipelining, handoff, and wire-delta, without sturdyrefs or equality
    /// (ADR-0008, ADR-0009).
    pub fn pipeliningAndHandoff() FeatureSet {
        return .{ .pipelining = true, .handoff = true, .wire_delta = true };
    }

    /// Everything except streaming: pipelining, handoff, wire-delta, sturdyrefs,
    /// and equality (ADR-0012).
    pub fn fullExceptStreaming() FeatureSet {
        return .{
            .pipelining = true,
            .handoff = true,
            .wire_delta = true,
            .sturdyref = true,
            .equality = true,
        };
    }

    /// Per-feature intersection — the handshake-negotiated set is the AND of the
    /// two peers' advertised sets, so neither side exercises a capability the
    /// other did not advertise. Pure and symmetric:
    /// `a.intersect(b) == b.intersect(a)`. The feature half of
    /// [`engine.negotiation.negotiate`]; the codec half lives there.
    pub fn intersect(self: FeatureSet, other: FeatureSet) FeatureSet {
        return .{
            .pipelining = self.pipelining and other.pipelining,
            .handoff = self.handoff and other.handoff,
            .wire_delta = self.wire_delta and other.wire_delta,
            .sturdyref = self.sturdyref and other.sturdyref,
            .stream = self.stream and other.stream,
            .equality = self.equality and other.equality,
        };
    }
};

pub const HintValue = union(enum) {
    string: []const u8,
    bytes: []const u8,
    boolean: bool,
    integer: i64,
};

pub const HintEntry = struct {
    name: []const u8,
    value: HintValue,
};

pub const Hints = struct {
    entries: []const HintEntry = &.{},
    empty_wire_was_false: bool = false,

    pub fn emptyMap() Hints {
        return .{};
    }

    pub fn emptyFalse() Hints {
        return .{ .empty_wire_was_false = true };
    }
};

pub const PeerLocator = struct {
    transport: []const u8,
    designator: []const u8,
    hints: Hints = .{},
};

pub const SessionPubkey = struct {
    bytes: []const u8,
};

pub const LocationSig = struct {
    bytes: []const u8,
};

/// Make a deep copy of a `PeerLocator` (its transport, designator, and hint map).
/// Free it again with `freePeerLocator`. The engine reaches for this when it
/// needs to hold onto a locator past the frame it came in on: a borrowed
/// `op:start-session` or `desc:sturdyref` gets queued for sending, and it has to
/// outlive the borrowed frame.
pub fn clonePeerLocator(allocator: std.mem.Allocator, locator: PeerLocator) !PeerLocator {
    const transport = try allocator.dupe(u8, locator.transport);
    errdefer allocator.free(transport);
    const designator = try allocator.dupe(u8, locator.designator);
    errdefer allocator.free(designator);
    const hints = try cloneHints(allocator, locator.hints);
    return .{
        .transport = transport,
        .designator = designator,
        .hints = hints,
    };
}

pub fn freePeerLocator(allocator: std.mem.Allocator, locator: PeerLocator) void {
    allocator.free(locator.transport);
    allocator.free(locator.designator);
    freeHints(allocator, locator.hints);
}

pub fn cloneHints(allocator: std.mem.Allocator, hints: Hints) !Hints {
    const entries = try allocator.alloc(HintEntry, hints.entries.len);
    errdefer allocator.free(entries);

    var initialized: usize = 0;
    errdefer {
        for (entries[0..initialized]) |entry| {
            freeHintEntry(allocator, entry);
        }
    }

    for (hints.entries, 0..) |entry, i| {
        entries[i] = try cloneHintEntry(allocator, entry);
        initialized += 1;
    }

    return .{
        .entries = entries,
        .empty_wire_was_false = hints.empty_wire_was_false,
    };
}

pub fn freeHints(allocator: std.mem.Allocator, hints: Hints) void {
    for (hints.entries) |entry| {
        freeHintEntry(allocator, entry);
    }
    allocator.free(hints.entries);
}

pub fn cloneHintEntry(allocator: std.mem.Allocator, entry: HintEntry) !HintEntry {
    const name = try allocator.dupe(u8, entry.name);
    errdefer allocator.free(name);
    return .{
        .name = name,
        .value = try cloneHintValue(allocator, entry.value),
    };
}

pub fn freeHintEntry(allocator: std.mem.Allocator, entry: HintEntry) void {
    allocator.free(entry.name);
    freeHintValue(allocator, entry.value);
}

pub fn cloneHintValue(allocator: std.mem.Allocator, value: HintValue) !HintValue {
    return switch (value) {
        .string => |string| .{ .string = try allocator.dupe(u8, string) },
        .bytes => |bytes| .{ .bytes = try allocator.dupe(u8, bytes) },
        .boolean, .integer => value,
    };
}

pub fn freeHintValue(allocator: std.mem.Allocator, value: HintValue) void {
    switch (value) {
        .string => |string| allocator.free(string),
        .bytes => |bytes| allocator.free(bytes),
        .boolean, .integer => {},
    }
}

/// Whether a `NearRef` points at a plain object or a promise.
///
/// The encoder needs to know which, because the two get different wire
/// descriptors: an object is `<desc:import-object>`, a promise is
/// `<desc:import-promise>`. Most exports are plain objects. The promise ones are
/// the special cases: a vow, a resolver callback, a promise imported through a
/// handoff.
pub const NearKind = enum { object, promise };

/// Whether a `FarRef` points at a plain object or a promise. It remembers which
/// descriptor named the import on the wire: `<desc:import-object>` becomes
/// `.object`, `<desc:import-promise>` becomes `.promise`. It's the decode-side
/// mirror of `NearKind`.
pub const ImportKind = enum { object, promise };

pub const NearRef = struct {
    export_id: u64,
    /// `.object` (the default) encodes as `<desc:import-object N>`, `.promise` as
    /// `<desc:import-promise N>`.
    kind: NearKind = .object,

    /// A plain object export. The common case.
    pub fn object(export_id: u64) NearRef {
        return .{ .export_id = export_id, .kind = .object };
    }

    /// A promise export: a vow, a resolver callback, or a handoff vow.
    pub fn promise(export_id: u64) NearRef {
        return .{ .export_id = export_id, .kind = .promise };
    }
};

pub const FarRef = struct {
    import_id: u64,
    /// Which descriptor named this import on the wire. Defaults to `.object`.
    kind: ImportKind = .object,

    /// A plain object import. The common case.
    pub fn object(import_id: u64) FarRef {
        return .{ .import_id = import_id, .kind = .object };
    }

    /// A promise import, decoded from `<desc:import-promise>`.
    pub fn promise(import_id: u64) FarRef {
        return .{ .import_id = import_id, .kind = .promise };
    }
};

/// One step along a promise pipeline path.
///
/// A `call` works in both codecs. Syrup can't carry a multi-hop path on the
/// wire, so the engine breaks it into a chain of single-hop `op:deliver`s
/// (`engine.pipeline.decomposeOutboundDeliver`); Cap'n Proto just encodes the
/// path as-is. A `field` is Cap'n Proto only. Syrup rejects it, because OCapN
/// has no way to express "navigate into a field" on an `op:deliver`.
pub const PipelineOp = union(enum) {
    field: []const u8,
    call: []const Argument,
};

/// A sequence of pipeline steps taken relative to a promise's eventual answer.
/// An empty path just means the answer itself.
pub const PipelinePath = struct {
    ops: []const PipelineOp = &.{},

    pub fn empty() PipelinePath {
        return .{};
    }

    pub fn isEmpty(self: PipelinePath) bool {
        return self.ops.len == 0;
    }
};

pub const PromiseRef = struct {
    answer_id: u64,
    /// Optional pipeline path targeting relative to the eventual resolution.
    /// Empty (default) means the resolution itself.
    path: PipelinePath = .{},
};

/// A lasting handle to an object, one that can outlive the session you found it
/// in. It's a pair: the peer locator says where the object lives, and the
/// swiss-number says which object. Two sturdyrefs are equal when both halves
/// match.
pub const SturdyRef = struct {
    peer: PeerLocator,
    swissnum: []const u8,
};

pub const BrokenRef = struct {
    message: []const u8,
};

pub const Reference = union(enum) {
    near: NearRef,
    far: FarRef,
    promise: PromiseRef,
    sturdy: SturdyRef,
    broken: BrokenRef,
};

pub const Argument = union(enum) {
    bytes: []const u8,
    symbol: []const u8,
    reference: Reference,
    @"error": Error,
    /// This one is boxed, and here's why. A handoff payload is about 160 bytes,
    /// and a handoff almost never shows up as an argument. If we stored it inline,
    /// every `Argument` would be 160 bytes wide, so a plain integer in a deliver
    /// list would carry the weight of a handoff arm it never uses. Boxing it means
    /// we only pay an allocation when a handoff genuinely appears as an argument.
    /// `cloneArgument` and `freeArgument` own the box. The borrowed `view.Argument`
    /// keeps its handoff inline, since it borrows wire bytes and never allocates.
    handoff: *Handoff,
    string: []const u8,
    integer: i64,
    boolean: bool,
    list: []const Argument,
    void: void,
    float64: f64,
    set: []const Argument,
    tagged: Tagged,
    keyword: []const u8,
};

pub const Resolution = union(enum) {
    fulfill: Argument,
    break_: Error,
};

pub const Error = struct {
    message: []const u8,
};

pub const Tagged = struct {
    tag: []const u8,
    value: []const Argument,
};

pub const AbortKind = enum {
    normal_shutdown,
    version_mismatch,
    protocol_error,
    timeout,
    unauthorized,
    invalid_handoff_signature,
    handoff_replay,
    queue_cap_exceeded,
    pipelining_not_negotiated,
    wire_delta_not_negotiated,
    handoffs_not_negotiated,
    sturdyrefs_not_negotiated,
    invalid_start_session_signature,
    crossed_hellos,
    connection_lost,
    graceful_shutdown,
    malformed_frame,
    resource_exhausted,
    other,

    pub fn wireName(self: AbortKind) []const u8 {
        return switch (self) {
            .normal_shutdown => "NormalShutdown",
            .version_mismatch => "VersionMismatch",
            .protocol_error => "ProtocolError",
            .timeout => "Timeout",
            .unauthorized => "Unauthorized",
            .invalid_handoff_signature => "InvalidHandoffSignature",
            .handoff_replay => "HandoffReplay",
            .queue_cap_exceeded => "QueueCapExceeded",
            .pipelining_not_negotiated => "PipeliningNotNegotiated",
            .wire_delta_not_negotiated => "WireDeltaNotNegotiated",
            .handoffs_not_negotiated => "HandoffsNotNegotiated",
            .sturdyrefs_not_negotiated => "SturdyrefsNotNegotiated",
            .invalid_start_session_signature => "InvalidStartSessionSignature",
            .crossed_hellos => "CrossedHellos",
            .connection_lost => "ConnectionLost",
            .graceful_shutdown => "GracefulShutdown",
            .malformed_frame => "MalformedFrame",
            .resource_exhausted => "ResourceExhausted",
            .other => "Other",
        };
    }

    pub fn fromWireName(name: []const u8) ?AbortKind {
        if (std.mem.eql(u8, name, "NormalShutdown")) return .normal_shutdown;
        if (std.mem.eql(u8, name, "VersionMismatch")) return .version_mismatch;
        if (std.mem.eql(u8, name, "ProtocolError")) return .protocol_error;
        if (std.mem.eql(u8, name, "Timeout")) return .timeout;
        if (std.mem.eql(u8, name, "Unauthorized")) return .unauthorized;
        if (std.mem.eql(u8, name, "InvalidHandoffSignature")) return .invalid_handoff_signature;
        if (std.mem.eql(u8, name, "HandoffReplay")) return .handoff_replay;
        if (std.mem.eql(u8, name, "QueueCapExceeded")) return .queue_cap_exceeded;
        if (std.mem.eql(u8, name, "PipeliningNotNegotiated")) return .pipelining_not_negotiated;
        if (std.mem.eql(u8, name, "WireDeltaNotNegotiated")) return .wire_delta_not_negotiated;
        if (std.mem.eql(u8, name, "HandoffsNotNegotiated")) return .handoffs_not_negotiated;
        if (std.mem.eql(u8, name, "SturdyrefsNotNegotiated")) return .sturdyrefs_not_negotiated;
        if (std.mem.eql(u8, name, "InvalidStartSessionSignature")) return .invalid_start_session_signature;
        if (std.mem.eql(u8, name, "CrossedHellos")) return .crossed_hellos;
        if (std.mem.eql(u8, name, "ConnectionLost")) return .connection_lost;
        if (std.mem.eql(u8, name, "GracefulShutdown")) return .graceful_shutdown;
        if (std.mem.eql(u8, name, "MalformedFrame")) return .malformed_frame;
        if (std.mem.eql(u8, name, "ResourceExhausted")) return .resource_exhausted;
        if (std.mem.eql(u8, name, "Other")) return .other;
        return null;
    }
};

pub const AbortReason = struct {
    kind: AbortKind,
    message: []const u8,

    /// Turn a V1.0 abort string back into a typed reason. V1.0 writes aborts as
    /// `"<Label>: <message>"`. If the label is one we recognize, we recover that
    /// kind; if it isn't, we keep the whole string as an `.other` reason. The
    /// other direction is the codec's job: `syrup.writeAbortWireString` builds
    /// that `"<label>: <message>"` form from `kind.wireName()` when it encodes.
    pub fn parseV1_0(wire: []const u8) AbortReason {
        if (std.mem.indexOf(u8, wire, ": ")) |split| {
            const label = wire[0..split];
            if (AbortKind.fromWireName(label)) |kind| {
                return .{
                    .kind = kind,
                    .message = wire[split + 2 ..],
                };
            }
        }
        return .{
            .kind = .other,
            .message = wire,
        };
    }
};

pub const Deliver = struct {
    target: Reference,
    args: []const Argument,
    answer: ?u64 = null,
    resolve_me_desc: ?Reference = null,
};

pub const Resolve = struct {
    answer: u64,
    resolution: Resolution,
};

pub const GcExport = struct {
    positions: []const u64,
    deltas: []const u64,
};

pub const GcAnswer = struct {
    positions: []const u64,
};

pub const HandoffGive = struct {
    recipient_key: []const u8,
    exporter_location: []const u8,
    gifter_exporter_session: []const u8,
    gifter_side: []const u8,
    gift_id: []const u8,
    signature: []const u8,
    /// Optional verbatim `<desc:sig-envelope <desc:handoff-give …> <sig-val …>>`
    /// bytes. When set, the encoder emits these exactly instead of re-encoding the
    /// fields above. A recipient forwarding a gifter's give to the exporter uses
    /// this so the exporter re-verifies the gifter's signature over the *exact*
    /// bytes the gifter signed — re-encoding could differ (e.g. `#f` vs `{}` hints)
    /// and fail verification.
    raw_signed: ?[]const u8 = null,
};

pub const HandoffReceive = struct {
    receiving_session: []const u8,
    receiving_side: []const u8,
    handoff_count: u64,
    signed_give: HandoffGive,
    signature: []const u8,
};

pub const Handoff = union(enum) {
    give: HandoffGive,
    receive: HandoffReceive,
};

pub const StartSession = struct {
    captp_version: CaptpVersion,
    session_pubkey: SessionPubkey,
    acceptable_location: PeerLocator,
    acceptable_location_sig: LocationSig,
};

pub const Listen = struct {
    target: Reference,
    listener: Reference,
    wants_partial: bool,
};

pub const Get = struct {
    receiver: Reference,
    field: []const u8,
    answer: u64,
};

pub const Index = struct {
    receiver: Reference,
    index: i64,
    answer: u64,
};

pub const Message = union(enum) {
    deliver: Deliver,
    resolve: Resolve,
    gc_export: GcExport,
    gc_answer: GcAnswer,
    handoff: Handoff,
    start_session: StartSession,
    abort: AbortReason,
    listen: Listen,
    get: Get,
    index: Index,
};

pub const MessageKind = struct {
    tag_name: []const u8,
    model_name: []const u8,
};

pub const message_kinds = [_]MessageKind{
    .{ .tag_name = "deliver", .model_name = "Deliver" },
    .{ .tag_name = "resolve", .model_name = "Resolve" },
    .{ .tag_name = "gc_export", .model_name = "GcExport" },
    .{ .tag_name = "gc_answer", .model_name = "GcAnswer" },
    .{ .tag_name = "handoff", .model_name = "Handoff" },
    .{ .tag_name = "start_session", .model_name = "StartSession" },
    .{ .tag_name = "abort", .model_name = "Abort" },
    .{ .tag_name = "listen", .model_name = "Listen" },
    .{ .tag_name = "get", .model_name = "Get" },
    .{ .tag_name = "index", .model_name = "Index" },
};
