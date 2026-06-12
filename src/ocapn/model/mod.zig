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
pub const freePipelineOp = owned.freePipelineOp;
pub const cloneResolution = owned.cloneResolution;
pub const freeResolution = owned.freeResolution;
pub const cloneReference = owned.cloneReference;
pub const freeReference = owned.freeReference;
pub const clonePipelinePath = owned.clonePipelinePath;
pub const freePipelinePath = owned.freePipelinePath;
pub const freeHandoffGive = owned.freeHandoffGive;
pub const freeHandoff = owned.freeHandoff;
pub const clonePeerLocator = owned.clonePeerLocator;
pub const freePeerLocator = owned.freePeerLocator;
pub const cloneHints = owned.cloneHints;
pub const freeHints = owned.freeHints;
pub const cloneHintEntry = owned.cloneHintEntry;
pub const freeHintEntry = owned.freeHintEntry;
pub const cloneHintValue = owned.cloneHintValue;
pub const freeHintValue = owned.freeHintValue;

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
pub const peerLocatorsEqual = equality.peerLocatorsEqual;

/// OCapN locators to and from `ocapn://` URIs: the out-of-band bootstrap form
/// a peer or sturdyref address is shared in. It is pure parse/emit over the
/// locator types here, with no netlayer and no I/O. See `uri`.
pub const uri = @import("uri.zig");

/// The one hard ceiling on value-tree recursion depth, shared by `view`'s
/// owned materialization and `equality`'s comparison walk so the two bounds
/// cannot drift apart. The session validates inbound data against its own,
/// lower `SessionLimits.max_nesting_depth` first; this is the model-layer
/// backstop for trees that skipped session validation.
pub const max_value_depth: usize = 256;

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
        // "ocapn-1.0" is accepted leniently for interop: no fixture in the
        // conformance corpus pins a peer that emits it, but it is a plausible
        // spelling of the same version and refusing it would buy nothing.
        if (std.mem.eql(u8, wire, "ocapn-1.0")) return .v1_0;
        if (std.mem.eql(u8, wire, "pancake-pre-spec")) return .pre_spec;
        return null;
    }
};

pub const WireProfile = struct {
    captp_version: CaptpVersion,

    pub const v1_0 = WireProfile{
        .captp_version = .v1_0,
    };
    pub const pre_spec = WireProfile{
        .captp_version = .pre_spec,
    };

    /// A diagnostic label for logs and error text, not a wire token: the
    /// handshake puts `CaptpVersion.wireString()` on the wire, never this.
    pub fn name(self: WireProfile) []const u8 {
        return switch (self.captp_version) {
            .v1_0 => "ocapn-v1.0",
            .pre_spec => "pancake-pre-spec",
        };
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

    /// Full pancake-native feature set: every feature field, driven off the
    /// field list itself so a new feature joins automatically.
    pub fn full() FeatureSet {
        var out: FeatureSet = .{};
        inline for (@typeInfo(FeatureSet).@"struct".fields) |field| {
            @field(out, field.name) = true;
        }
        return out;
    }

    /// Pipelining, handoff, and wire-delta, without sturdyrefs or equality
    /// (ADR-0008, ADR-0009).
    pub fn pipeliningAndHandoff() FeatureSet {
        return .{ .pipelining = true, .handoff = true, .wire_delta = true };
    }

    /// Everything except streaming: the full set with `stream` switched off
    /// (ADR-0012).
    pub fn fullExceptStreaming() FeatureSet {
        var out = full();
        out.stream = false;
        return out;
    }

    /// Per-feature intersection — the handshake-negotiated set is the AND of the
    /// two peers' advertised sets, so neither side exercises a capability the
    /// other did not advertise. Pure and symmetric:
    /// `a.intersect(b) == b.intersect(a)`. The feature half of
    /// `engine.negotiation.negotiate`; the codec half lives there.
    pub fn intersect(self: FeatureSet, other: FeatureSet) FeatureSet {
        var out: FeatureSet = .{};
        inline for (@typeInfo(FeatureSet).@"struct".fields) |field| {
            @field(out, field.name) = @field(self, field.name) and @field(other, field.name);
        }
        return out;
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
    /// Which wire spelling an empty hint set uses. Goblins writes an absent
    /// hint map as the boolean `#f` while an empty map is `{}`; the two are
    /// semantically the same empty hints, but a signature computed over one
    /// spelling does not verify over the other, so the decoded form is
    /// remembered and reproduced on encode.
    wire_form: WireForm = .map,

    pub const WireForm = enum { map, boolean_false };

    pub fn emptyMap() Hints {
        return .{};
    }

    pub fn emptyFalse() Hints {
        return .{ .wire_form = .boolean_false };
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

/// Whether a reference points at a plain object or a promise — the one
/// object/promise axis a `NearRef` and a `FarRef` share. The wire mapping is
/// fixed: `<desc:import-object>` carries `.object` and `<desc:import-promise>`
/// carries `.promise`, and exports are objects or promises the same way. Most
/// references are plain objects; the promise ones are the special cases — a
/// vow, a resolver callback, a promise imported through a handoff.
pub const RefKind = enum { object, promise };

pub const NearRef = struct {
    export_position: u64,
    /// `.object` (the default) encodes as `<desc:import-object N>`, `.promise` as
    /// `<desc:import-promise N>`.
    kind: RefKind = .object,

    /// A plain object export. The common case.
    pub fn object(export_position: u64) NearRef {
        return .{ .export_position = export_position, .kind = .object };
    }

    /// A promise export: a vow, a resolver callback, or a handoff vow.
    pub fn promise(export_position: u64) NearRef {
        return .{ .export_position = export_position, .kind = .promise };
    }
};

pub const FarRef = struct {
    import_position: u64,
    /// Which descriptor named this import on the wire. Defaults to `.object`.
    kind: RefKind = .object,

    /// A plain object import. The common case.
    pub fn object(import_position: u64) FarRef {
        return .{ .import_position = import_position, .kind = .object };
    }

    /// A promise import, decoded from `<desc:import-promise>`.
    pub fn promise(import_position: u64) FarRef {
        return .{ .import_position = import_position, .kind = .promise };
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
    answer_position: u64,
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

    /// The wire position this reference names: a near export's `export_position` or a
    /// far import's `import_position` (they live in one integer space). Null for a
    /// reference that names no position (promise / sturdy / broken).
    pub fn position(self: Reference) ?u64 {
        return switch (self) {
            .near => |near| near.export_position,
            .far => |far| far.import_position,
            else => null,
        };
    }

    /// The local export position this reference names, but only when it is a
    /// `.near` export this peer hosts. A resolver-export lookup must use this,
    /// never `position`: a resolver callback always targets one of our `.near`
    /// exports, and keying an export-indexed map on a partner-named `.far` import
    /// id (the same integer space) would let a coincidental collision misclassify
    /// an ordinary deliver as a resolver callback.
    pub fn exportPosition(self: Reference) ?u64 {
        return switch (self) {
            .near => |near| near.export_position,
            else => null,
        };
    }
};

pub const Argument = union(enum) {
    bytes: []const u8,
    symbol: []const u8,
    reference: Reference,
    @"error": BreakReason,
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
    /// An OCapN Integer whose magnitude is outside `i64` (Model.md § Integer:
    /// the Integer is arbitrary-precision). The `integer` arm above is the fast
    /// path for the `i64` range; decode produces this arm only when the value
    /// cannot be an `integer`, so the two arms never spell the same arithmetic
    /// value and `BigInteger` equality stays bytewise.
    big_integer: BigInteger,
    /// An OCapN Struct: an unordered collection of (String key, Value) entries
    /// (Model.md § Struct). Keys are Strings, non-Equal to one another. The wire
    /// order does not matter for equality, so two structs are Equal when each key
    /// in one is present in the other with an Equal value
    /// (`equality.structsEqualDepth`); a struct may round-trip into a different
    /// key order and stay Equal. Note: OCapN Undefined is the `.void` arm above,
    /// the `<void>` record Goblins uses for the unspecified value; OCapN Null has
    /// no settled wire encoding and is refused at decode (ADR-0046).
    @"struct": []const StructEntry,
};

/// One (key, value) pair of an OCapN `Argument.@"struct"`. The key is a String.
pub const StructEntry = struct {
    key: []const u8,
    value: Argument,
};

/// An arbitrary-precision OCapN Integer outside the `i64` range, as a sign
/// plus its canonical decimal magnitude. Decimal digits are what Syrup already
/// carries on the wire and what the Cap'n Proto codec stores as its digits
/// data, so both codecs borrow this representation without converting and the
/// zero-copy view stays zero-copy. Canonical means non-empty ASCII `0-9` with
/// no leading zero, and a magnitude that does not fit `i64` — both enforced
/// where bytes are parsed — so two equal arithmetic values are always the same
/// bytes and `equality.argumentsEqual` compares without arithmetic.
pub const BigInteger = struct {
    negative: bool,
    /// Canonical decimal magnitude: ASCII digits, no leading zero, magnitude
    /// outside `i64`.
    digits: []const u8,

    /// Whether this value satisfies the type's invariant: a non-empty
    /// no-leading-zero ASCII decimal magnitude outside the `i64` range. Codecs
    /// refuse a non-canonical value symmetrically — on decode it is a malformed
    /// frame, on encode an unsupported argument — so canonical bytes are the
    /// only bytes that ever cross the wire and bytewise equality stays
    /// arithmetic equality.
    pub fn isCanonical(self: BigInteger) bool {
        if (self.digits.len == 0 or self.digits[0] == '0') return false;
        for (self.digits) |d| {
            if (d < '0' or d > '9') return false;
        }
        // More than 20 digits cannot fit u64, so it is certainly outside i64.
        const magnitude = std.fmt.parseInt(u64, self.digits, 10) catch return true;
        const max_positive: u64 = @intCast(std.math.maxInt(i64));
        // minInt(i64)'s magnitude is one past maxInt and representable only
        // when negative, so the negative arm's floor sits one higher.
        if (self.negative) return magnitude > max_positive + 1;
        return magnitude > max_positive;
    }
};

pub const Resolution = union(enum) {
    fulfill: Argument,
    @"break": BreakReason,
};

pub const BreakReason = struct {
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

    /// The inverse of `wireName`, derived from it: every variant is matched by
    /// the exact string `wireName` emits, so the two directions cannot drift and
    /// a new variant is covered the moment it has a `wireName` arm.
    pub fn fromWireName(name: []const u8) ?AbortKind {
        inline for (@typeInfo(AbortKind).@"enum".fields) |field| {
            const kind: AbortKind = @enumFromInt(field.value);
            if (std.mem.eql(u8, kind.wireName(), name)) return kind;
        }
        return null;
    }
};

/// A typed abort reason: the kind plus a human-readable message. The V1.0
/// single-string wire form `"<Label>: <message>"` is the codec's vocabulary,
/// not the model's — the Syrup encoder builds it from `kind.wireName()` and
/// the Syrup decoder recovers the kind from the prefix, falling back to
/// `.other` when no label matches.
pub const AbortReason = struct {
    kind: AbortKind,
    message: []const u8,
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

pub const Untag = struct {
    receiver: Reference,
    tag: []const u8,
    answer: u64,
};

/// If you hand this to an owning sink like `Peer.send`, every slice in it must
/// be owned by that peer's allocator; otherwise use `Peer.sendCopying`.
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
    untag: Untag,
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
    .{ .tag_name = "untag", .model_name = "Untag" },
};
