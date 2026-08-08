//! The message, described once, with no codec attached.
//!
//! Both codecs produce this same shape, and the engine works against it, so all
//! of pancake shares one vocabulary for what a message actually is. The
//! mutually-recursive value-tree core lives here directly — `Message` and its
//! arms, `Reference`, `Argument`, `Resolution`, and the handshake/locator and gc
//! shapes — because those types reference one another and read best as one unit.
//! The separable leaves are sibling files this hub re-exports: `negotiated` (the
//! words two peers settle on — `CodecId`, `CaptpVersion`,
//! `FeatureSet`), `handoff` (the three-party handoff payloads), `abort`
//! (`AbortKind`, `AbortReason`), and `transport` (locator transport symbols and
//! the shared `direct-addresses` hint name).
//!
//! None of it carries a codec, an allocation policy, or any authority. It's just
//! the shape. `session` is what decides whether a given message is valid, and
//! `codec` is what turns it into bytes. Three more sibling files finish the
//! story: `owned` handles who clones and frees the tree, `view` is the borrowed
//! look at it over live wire bytes, and `equality` is how two values compare.

const std = @import("std");

const negotiated = @import("negotiated.zig");
const handoff_types = @import("handoff.zig");
const abort_types = @import("abort.zig");
const position = @import("position.zig");

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
pub const measureArgumentSliceOwnedBytes = owned.measureArgumentSliceOwnedBytes;
pub const freeArgumentSlice = owned.freeArgumentSlice;
pub const freePipelineOp = owned.freePipelineOp;
pub const freeResolution = owned.freeResolution;
pub const materializeResolutionForStore = owned.materializeResolutionForStore;
pub const cloneReference = owned.cloneReference;
pub const freeReference = owned.freeReference;
pub const freeHandoffGive = owned.freeHandoffGive;
pub const freeHandoff = owned.freeHandoff;
pub const freePeerLocator = owned.freePeerLocator;
pub const cloneHints = owned.cloneHints;
pub const freeHints = owned.freeHints;
pub const freeHintEntry = owned.freeHintEntry;
pub const cloneHintValue = owned.cloneHintValue;
pub const freeHintValue = owned.freeHintValue;

/// The borrowed look at a message, read straight off the wire bytes with no
/// copy. Both codecs produce this one shape, and the engine works against it.
/// See `view`.
pub const view = @import("view.zig");

/// Whether two reference representations are structurally equal. Far and
/// promise positions are meaningful only in their session; this does not
/// canonicalize targets across sessions or arbitrary network paths.
pub const equality = @import("equality.zig");
pub const referencesStructurallyEqual = equality.referencesStructurallyEqual;
pub const argumentsEqual = equality.argumentsEqual;
pub const peerLocatorsEqual = equality.peerLocatorsEqual;
pub const handoffsEqual = equality.handoffsEqual;

/// OCapN locators to and from `ocapn://` URIs: the out-of-band bootstrap form
/// a peer or sturdyref address is shared in. It is pure parse/emit over the
/// locator types here, with no netlayer and no I/O. See `uri`.
pub const uri = @import("uri.zig");

/// Transport symbols carried in a `PeerLocator` (`tcp`, `keyed-tcp`, …) and the
/// shared `direct-addresses` hint name. Netlayers and `driver_core` both import
/// these so the strings cannot drift across the I/O ban. See `transport`.
pub const transport = @import("transport.zig");

/// The one hard ceiling on value-tree recursion depth, shared by `view`'s
/// owned materialization and `equality`'s comparison walk so the two bounds
/// cannot drift apart. The session validates inbound data against its own,
/// lower `SessionLimits.max_nesting_depth` first; this is the model-layer
/// backstop for trees that skipped session validation.
pub const max_value_depth: usize = 256;

/// The words two peers settle on at handshake (`negotiated`): which codec frames
/// the bytes, which CapTP version is spoken, and which optional features both
/// advertised. `CodecId` lives in `model` rather than `codec` on purpose, the
/// session records its choice without depending on a codec to do it.
pub const CodecId = negotiated.CodecId;
pub const CaptpVersion = negotiated.CaptpVersion;
pub const FeatureSet = negotiated.FeatureSet;
pub const Preference = negotiated.Preference;

/// The three position spaces a session keys on, one zero-cost newtype each, so a
/// partner-named import position can never be passed where a local export position is meant
/// (`position`). Scalar id fields carry these end to end; cross the `u64`
/// wire/ABI boundary with `ExportPosition.from` / `.int` and friends.
pub const ExportPosition = position.ExportPosition;
pub const ImportPosition = position.ImportPosition;
/// An id this node minted for a redeemed-handoff capability (ADR-0069), and
/// the union that says which of the two kinds an import id is (ADR-0091).
pub const REDEEMED_TOKEN_BASE = position.REDEEMED_TOKEN_BASE;
pub const RedeemedToken = position.RedeemedToken;
pub const ImportName = position.ImportName;
pub const AnswerPosition = position.AnswerPosition;
/// An answer the session synthesized for a V1.0 resolver-only call (ADR-0010),
/// and the union that says which of the two kinds an answer id is (ADR-0091).
pub const VIRTUAL_INBOUND_ANSWER_BASE = position.VIRTUAL_INBOUND_ANSWER_BASE;
pub const VirtualAnswer = position.VirtualAnswer;
pub const AnswerName = position.AnswerName;

const hint_types = @import("hints.zig");
pub const HintValue = hint_types.HintValue;
pub const HintEntry = hint_types.HintEntry;
pub const Hints = hint_types.Hints;

const peer_locator = @import("peer_locator.zig");
pub const PeerLocator = peer_locator.PeerLocator;

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
    export_position: ExportPosition,
    /// `.object` (the default) encodes as `<desc:import-object N>`, `.promise` as
    /// `<desc:import-promise N>`.
    kind: RefKind = .object,

    /// A plain object export at wire position `n`. The common case.
    pub fn object(n: u64) NearRef {
        return .{ .export_position = .from(n), .kind = .object };
    }

    /// A promise export at wire position `n`: a vow, a resolver callback, or a
    /// handoff vow.
    pub fn promise(n: u64) NearRef {
        return .{ .export_position = .from(n), .kind = .promise };
    }
};

pub const FarRef = struct {
    import_position: ImportPosition,
    /// Which descriptor named this import on the wire. Defaults to `.object`.
    kind: RefKind = .object,

    /// A plain object import at wire position `n`. The common case.
    pub fn object(n: u64) FarRef {
        return .{ .import_position = .from(n), .kind = .object };
    }

    /// A promise import at wire position `n`, decoded from `<desc:import-promise>`.
    pub fn promise(n: u64) FarRef {
        return .{ .import_position = .from(n), .kind = .promise };
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

    pub fn isEmpty(self: PipelinePath) bool {
        return self.ops.len == 0;
    }
};

pub const PromiseRef = struct {
    answer_position: AnswerPosition,
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

/// A broken reference's reason. The same shape as a promise's `BreakReason` and
/// an `error` argument's payload — a borrowed-or-owned message string — so it is
/// that one type under a name that reads at the `Reference.broken` use site. The
/// borrowed view already collapses all three to one `view.records.BreakReason`.
pub const BrokenRef = BreakReason;

pub const Reference = union(enum) {
    near: NearRef,
    far: FarRef,
    promise: PromiseRef,
    // Boxed, like `Argument.handoff`, and for the same reason. A `SturdyRef` is a
    // `PeerLocator` plus a swissnum, ~72 bytes, so inline it sets the width of the
    // whole union: every `near`/`far`/`promise`/`broken` `Reference` — the common
    // arms, and a value type stored in session tables under the per-session
    // footprint budget — would carry ~48 bytes it never uses, just to keep the rare
    // sturdy arm inline. An *owned* `Reference` is only ever minted from the wire
    // through `view.toOwned`, which already holds an allocator and already dupes the
    // peer and swissnum, so the box costs one `create` there and one `destroy` in
    // `freeReference`, and nothing else pays for it. The borrowed `view.Reference`
    // keeps its `sturdy` inline: it never allocates, so the boxing is owned-side only.
    sturdy: *const SturdyRef,
    broken: BrokenRef,

    /// The raw wire position this reference names: a near export's
    /// `export_position` or a far import's `import_position`, collapsed to the
    /// one `u64` integer space they share on the wire. Null for a reference that
    /// names no position (promise / sturdy / broken). This is the escape hatch
    /// for code that genuinely wants the bare integer; prefer `exportPosition`
    /// when you mean "the local export this names," so the type keeps an import
    /// id out of an export-keyed lookup.
    pub fn position(self: Reference) ?u64 {
        return switch (self) {
            .near => |near| near.export_position.int(),
            .far => |far| far.import_position.int(),
            else => null,
        };
    }

    /// The local export position this reference names, but only when it is a
    /// `.near` export this peer hosts, typed, so it cannot be mistaken for a
    /// partner-named import position. A resolver-export lookup must use this, never
    /// `position`: a resolver callback always targets one of our `.near`
    /// exports, and keying an export-indexed map on a `.far` import position (the same
    /// integer space) would let a coincidental collision misclassify an ordinary
    /// deliver as a resolver callback. The type now makes that misuse a compile
    /// error rather than a comment.
    pub fn exportPosition(self: Reference) ?ExportPosition {
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
    /// In an owned tree the box must live on the message's allocator, because
    /// `freeArgument` destroys it there; a stack-boxed handoff is legal only
    /// behind `Peer.sendCopying`, whose clone re-boxes it onto the heap.
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

/// One arbitrary-precision OCapN Integer. Values in the `i64` range use the
/// compact arm; larger magnitudes borrow or own canonical decimal digits.
pub const Integer = union(enum) {
    integer: i64,
    big_integer: BigInteger,

    pub fn eql(a: Integer, b: Integer) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .integer => |value| value == b.integer,
            .big_integer => |big| big.negative == b.big_integer.negative and
                std.mem.eql(u8, big.digits, b.big_integer.digits),
        };
    }
};

pub const Resolution = union(enum) {
    fulfill: Argument,
    @"break": BreakReason,
};

comptime {
    // The handoff arm of `Argument`/`Resolution` is boxed (`*Handoff`) so the
    // common arm sets the struct size; un-boxing it would balloon every
    // element of a deliver's args. These ceilings make that a build failure,
    // not a measurement. The borrowed view twins carry their own bounds in
    // `test/model/model_test.zig`.
    std.debug.assert(@sizeOf(Argument) <= 40);
    std.debug.assert(@sizeOf(Resolution) <= 48);
    std.debug.assert(@sizeOf(Reference) <= 32);
}

pub const BreakReason = struct {
    message: []const u8,
};

pub const Tagged = struct {
    tag: []const u8,
    value: []const Argument,
};

/// Why a session tore down (`abort`): the closed set of reasons and a reason
/// paired with a human-readable message.
pub const AbortKind = abort_types.AbortKind;
pub const AbortReason = abort_types.AbortReason;

pub const Deliver = struct {
    target: Reference,
    args: []const Argument,
    answer: ?AnswerPosition = null,
    resolve_me_desc: ?Reference = null,
};

/// Which promise transition an `op:listen` asks to observe. The current OCapN
/// proposal assigns these exact integers on the next-profile wire. V1.0 keeps
/// its Boolean `wants-partial?` operand and is translated at the codec edge.
pub const ListenMode = enum(u2) {
    shortening_only = 1,
    settling_only = 2,
    shortening_or_settling = 3,

    pub fn fromInt(value: u64) ?ListenMode {
        return switch (value) {
            1 => .shortening_only,
            2 => .settling_only,
            3 => .shortening_or_settling,
            else => null,
        };
    }

    pub fn wantsShortening(self: ListenMode) bool {
        return self != .settling_only;
    }

    pub fn wantsSettling(self: ListenMode) bool {
        return self != .shortening_only;
    }

    pub fn fromV1_0WantsPartial(wants_partial: bool) ListenMode {
        return if (wants_partial) .shortening_or_settling else .settling_only;
    }

    pub fn toV1_0WantsPartial(self: ListenMode) ?bool {
        return switch (self) {
            .shortening_only => null,
            .settling_only => false,
            .shortening_or_settling => true,
        };
    }
};

pub const Resolve = struct {
    answer: AnswerPosition,
    resolution: Resolution,
};

pub const GcExport = struct {
    positions: []const u64,
    deltas: []const u64,
};

pub const GcAnswer = struct {
    positions: []const u64,
};

/// The three-party handoff payloads (`handoff`): the gifter's signed give and
/// the recipient's redemption of it (ADR-0009).
pub const HandoffGive = handoff_types.HandoffGive;
pub const HandoffReceive = handoff_types.HandoffReceive;
pub const Handoff = handoff_types.Handoff;
pub const HANDOFF_GIFT_ID_BYTES = handoff_types.GIFT_ID_BYTES;

pub const StartSession = struct {
    /// Optional for one reason: this type is also what a decoded hello
    /// materializes into, and a partner may name a version this build does
    /// not know. Outbound it is always set — the version is ours to choose —
    /// and the encoders refuse a null they could not have produced.
    /// `session.validate` is the one place that decides an unknown version is
    /// unacceptable, and it reads this shape and the borrowed view's
    /// identically because they agree.
    captp_version: ?CaptpVersion,
    session_pubkey: SessionPubkey,
    acceptable_location: PeerLocator,
    acceptable_location_sig: LocationSig,
};

pub const Listen = struct {
    target: Reference,
    listener: Reference,
    mode: ListenMode,
};

pub const Get = struct {
    receiver: Reference,
    field: []const u8,
    answer: AnswerPosition,
};

pub const Index = struct {
    receiver: Reference,
    index: Integer,
    answer: AnswerPosition,
};

pub const Untag = struct {
    receiver: Reference,
    tag: []const u8,
    answer: AnswerPosition,
};

/// If you hand this to an owning sink like `Peer.send`, every slice in it must
/// be owned by that peer's allocator; otherwise use `Peer.sendCopying`.
pub const Message = union(enum) {
    deliver: Deliver,
    resolve: Resolve,
    gc_export: GcExport,
    gc_answer: GcAnswer,
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
    .{ .tag_name = "start_session", .model_name = "StartSession" },
    .{ .tag_name = "abort", .model_name = "Abort" },
    .{ .tag_name = "listen", .model_name = "Listen" },
    .{ .tag_name = "get", .model_name = "Get" },
    .{ .tag_name = "index", .model_name = "Index" },
    .{ .tag_name = "untag", .model_name = "Untag" },
};

/// Bind a satellite kind registry to `Message` at compile time: assert that
/// `Registry`'s fields mirror `Message`'s arms by name and order. Each registry
/// that restates the message-kind set — the engine's `EventKind`, the Cap'n
/// Proto wire `Kind`, the C `PANCAKE_EVENT_*` block through its `EventKind`
/// mirror — calls this so a new `Message` arm cannot land without its mirror.
/// The wire ids and C discriminants stay explicit (they are external contracts,
/// not derivations); this only forbids the set from drifting. `Registry` may be
/// an `enum` or a `union` so the same assert covers `view.Body` too.
pub fn assertMirrorsMessageKinds(comptime Registry: type) void {
    const arms = @typeInfo(Message).@"union".fields;
    const mirror = switch (@typeInfo(Registry)) {
        .@"enum" => |info| info.fields,
        .@"union" => |info| info.fields,
        else => @compileError("kind registry must be an enum or union"),
    };
    if (arms.len != mirror.len)
        @compileError("kind registry arity drifted from model.Message");
    inline for (arms, mirror) |arm, field| {
        if (!std.mem.eql(u8, arm.name, field.name))
            @compileError("kind registry must mirror model.Message arm '" ++
                arm.name ++ "' in order, found '" ++ field.name ++ "'");
    }
}

// The owned (`model.*`) and borrowed (`model.view.*`) shapes of one wire
// value stay arm-for-arm mirrored without a dedicated assertion: `fromOwned`
// switches exhaustively over the owned arms and must produce a view arm for
// each, and `toOwned` does the reverse, so an arm added to either shape alone
// is a compile error in the projection rather than a drift.

/// Bind a wire kind registry to a model union by *set*: every arm name appears
/// on both sides and the counts match, without pinning the order. This is the
/// order-independent sibling of `assertMirrorsMessageKinds`, for the one pair
/// whose orders legitimately differ: a wire enum's discriminants are an external
/// contract, and the Cap'n Proto `ArgKind` numbers `@"struct"` and `big_integer`
/// in wire order — not the order `model.Argument` declares them. So only the set
/// is asserted. A new `Model` arm without its registry field (or the reverse) is
/// a compile error, so the two cannot drift apart even though neither derives
/// from the other. Equal arity plus every model arm matched proves the bijection,
/// since names are unique within each type.
pub fn assertKindSetMatches(comptime Model: type, comptime Registry: type) void {
    const arms = @typeInfo(Model).@"union".fields;
    const fields = switch (@typeInfo(Registry)) {
        .@"enum" => |info| info.fields,
        else => @compileError("kind registry must be an enum"),
    };
    if (arms.len != fields.len)
        @compileError("kind registry arity drifted from " ++ @typeName(Model));
    inline for (arms) |arm| {
        comptime var found = false;
        inline for (fields) |field| {
            if (std.mem.eql(u8, arm.name, field.name)) found = true;
        }
        if (!found)
            @compileError(@typeName(Model) ++ " arm '" ++ arm.name ++
                "' has no matching " ++ @typeName(Registry) ++ " field");
    }
}
