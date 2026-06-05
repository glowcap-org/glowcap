const std = @import("std");

/// Ownership lifecycle for the owned [`Message`] tree (and its sub-trees): who
/// owns a message past its originating frame, and how it is released. Single
/// sourced in `owned.zig` so the session's pipelining tables and the one
/// outbound boundary copy share one acquire (`clone`) / release (`free`)
/// contract. See [`owned`].
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

/// Codec-neutral borrowed views over wire memory — the single message shape
/// both codecs project and the runtime dispatches on (Invariant 1). See
/// [`view`].
pub const view = @import("view.zig");

/// Structural equality on the codec-neutral value tree — the in-memory evidence
/// for distributed (Pass Invariant) equality per ADR-0013 § Decision 5. See
/// [`equality`].
pub const equality = @import("equality.zig");
pub const referencesEqual = equality.referencesEqual;
pub const argumentsEqual = equality.argumentsEqual;
pub const peerLocatorsEqual = equality.peerLocatorsEqual;

/// Which wire codec carries a direct session. Declaration order is the
/// negotiation tie-break (most-preferred first): `capnp` is the native
/// word-aligned fast path, `syrup` the byte-record compatibility path.
///
/// Lives in `model` (not `codec`) so the codec-neutral session
/// ([`session`](../session/mod.zig)) can record which codec it negotiated
/// without importing a codec — authority over the choice stays in the session
/// per Invariant 5, and the codec dispatch seam ([`codec.dispatch`]) switches
/// on it. The runtime's handshake negotiation
/// ([`runtime.negotiation`](../runtime/negotiation.zig)) produces it.
pub const CodecId = enum {
    capnp,
    syrup,
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
    pub fn goblinsV1_0() WireProfile {
        return v1_0;
    }

    pub fn preSpec() WireProfile {
        return pre_spec;
    }

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

    /// Stage 0 minimum — Deliver / Resolve / Abort only.
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

    /// Stage 1 default — pipelining only (ADR-0007).
    pub fn pipeliningCapable() FeatureSet {
        return .{ .pipelining = true };
    }

    /// Stage 2 default — pipelining + handoff + wire_delta (ADR-0008, ADR-0009).
    pub fn stage2Default() FeatureSet {
        return .{ .pipelining = true, .handoff = true, .wire_delta = true };
    }

    /// Stage 3 default — stage 2 + sturdyref + equality (ADR-0012, ADR-0013).
    pub fn stage3Default() FeatureSet {
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
    /// [`runtime.negotiation.negotiate`]; the codec half lives there.
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

    pub fn withPipelining(self: FeatureSet, on: bool) FeatureSet {
        var next = self;
        next.pipelining = on;
        return next;
    }

    pub fn withHandoff(self: FeatureSet, on: bool) FeatureSet {
        var next = self;
        next.handoff = on;
        return next;
    }

    pub fn withWireDelta(self: FeatureSet, on: bool) FeatureSet {
        var next = self;
        next.wire_delta = on;
        return next;
    }

    pub fn withSturdyref(self: FeatureSet, on: bool) FeatureSet {
        var next = self;
        next.sturdyref = on;
        return next;
    }

    pub fn withStream(self: FeatureSet, on: bool) FeatureSet {
        var next = self;
        next.stream = on;
        return next;
    }

    pub fn withEquality(self: FeatureSet, on: bool) FeatureSet {
        var next = self;
        next.equality = on;
        return next;
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

/// Deep-clone a [`PeerLocator`] (transport, designator, and the hint map) with
/// `allocator`. Mirrored by [`freePeerLocator`]. Used by the runtime's
/// owned-message path ([`cloneMessage`] / `freeMessage`) when a borrowed
/// `op:start-session` or `desc:sturdyref` is queued for outbound encode and
/// must outlive the borrowed frame it came from.
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

pub const GiftId = struct {
    bytes: []const u8,
};

pub const ExportId = struct {
    value: u64,

    pub fn init(value: u64) ExportId {
        return .{ .value = value };
    }

    pub fn raw(self: ExportId) u64 {
        return self.value;
    }
};

pub const ImportId = struct {
    value: u64,

    pub fn init(value: u64) ImportId {
        return .{ .value = value };
    }

    pub fn raw(self: ImportId) u64 {
        return self.value;
    }
};

pub const AnswerId = struct {
    value: u64,

    pub fn init(value: u64) AnswerId {
        return .{ .value = value };
    }

    pub fn raw(self: AnswerId) u64 {
        return self.value;
    }
};

/// Wire-tag discriminator on [`NearRef`].
///
/// Records whether the local export the sender refers to is object-shaped or
/// promise-shaped, so the stateless encoder emits the matching descriptor
/// (`<desc:import-object>` vs `<desc:import-promise>`). Most exports are
/// object-shaped; promise-shaped exports (vow / resolver-callback /
/// handoff-imported promise) carry `.promise`.
pub const NearKind = enum { object, promise };

/// Wire-tag discriminator on [`FarRef`].
///
/// Records which payload-position descriptor named the import:
/// `<desc:import-object>` lifts to `.object`, `<desc:import-promise>` to
/// `.promise`. Symmetric with [`NearKind`] on the encode side.
pub const ImportKind = enum { object, promise };

pub const NearRef = struct {
    export_id: u64,
    /// `.object` (default) emits `<desc:import-object N>`; `.promise` emits
    /// `<desc:import-promise N>`.
    kind: NearKind = .object,

    /// Object-shaped local export — the common case.
    pub fn object(export_id: u64) NearRef {
        return .{ .export_id = export_id, .kind = .object };
    }

    /// Promise-shaped local export (vow / resolver-callback / handoff vow).
    pub fn promise(export_id: u64) NearRef {
        return .{ .export_id = export_id, .kind = .promise };
    }
};

pub const FarRef = struct {
    import_id: u64,
    /// Wire-tag discriminator preserved from decode. Defaults to `.object`.
    kind: ImportKind = .object,

    /// Object-shaped import — the common case.
    pub fn object(import_id: u64) FarRef {
        return .{ .import_id = import_id, .kind = .object };
    }

    /// Promise-shaped import (`<desc:import-promise>`-decoded refs).
    pub fn promise(import_id: u64) FarRef {
        return .{ .import_id = import_id, .kind = .promise };
    }
};

/// A single step along a promise pipeline path.
///
/// - `call` is admitted by both codecs. On Syrup it is decomposed into chained
///   single-hop `op:deliver`s at the runtime layer
///   ([`runtime.pipeline.decomposeOutboundDeliver`]); capnp encodes the path
///   natively once that codec lands.
/// - `field` is Cap'n Proto-only; the Syrup decomposer and encoders reject it
///   because the OCapN spec admits no structural-navigation analog on
///   `op:deliver`.
pub const PipelineOp = union(enum) {
    field: []const u8,
    call: []const Argument,
};

/// Sequence of pipeline operations relative to a promise's eventual
/// resolution. An empty path means "the resolution itself."
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

/// Persistent locator for an object that may outlive its current session.
///
/// Structural shape is `(peer, swissnum)`: the peer locator names where the
/// object lives, the swiss-number names the specific object. Equality is
/// structural on `(peer, swissnum)`.
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

/// Identifier of a CapTP stream within a session, allocated by the originator
/// (the side holding the source object).
///
/// OCapN specifies no stream wire shape. A stream is modelled as ordinary
/// capability calls (`Sink.write`, `FlowControl.ready`, `close` / `abort`)
/// riding `op:deliver` / `op:resolve`, so `StreamId` is codec-neutral and
/// constructible only from a typed value — it carries no wire encoding. The
/// `FeatureSet.stream` flag negotiates the capability; stream credit and
/// lifecycle tracking are not implemented.
pub const StreamId = struct {
    value: u64,
};

pub const Argument = union(enum) {
    bytes: []const u8,
    symbol: []const u8,
    reference: Reference,
    @"error": Error,
    handoff: Handoff,
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

    pub fn toV1_0Wire(self: AbortReason) []const u8 {
        // Allocating combined typed abort strings belongs at encode time.
        return switch (self.kind) {
            .version_mismatch => if (@import("std").mem.eql(u8, self.message, "expected ocapn-1.0"))
                "VersionMismatch: expected ocapn-1.0"
            else
                self.message,
            .other => self.message,
            else => self.message,
        };
    }

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
