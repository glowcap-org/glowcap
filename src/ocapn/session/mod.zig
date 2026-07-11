//! The session: the part of pancake that holds the truth.
//!
//! A `Session` owns the export, import, and answer tables for one direct session,
//! plus all the handshake, pipelining, gc, handoff, and sturdyref bookkeeping.
//! More to the point, it's the only layer allowed to decide whether a message is
//! valid. `recordSend` and `recordRecvView` run the protocol state machine: first
//! an exhaustive check that the message is even allowed in the current state, then
//! the rules specific to its kind. If it passes, they apply its effect. If it
//! doesn't, they hand back a typed `Error`, and the engine turns that into an
//! `op:abort`. Codecs and adapters just move bytes. They never get a vote on
//! what's valid.
//!
//! Inside, the layout is built for speed; there's more in `docs/architecture.md`
//! under Session Representation. Protocol positions are dense integers, so the
//! export, import, and answer tables are O(1) lookups instead of scans. Byte keys
//! all live in one per-session arena. And in the common case the receive path
//! checks a message straight off the borrowed codec view, only building an owned
//! copy when something actually needs to hold onto it past the turn.

const std = @import("std");
const model = @import("model");
const answers = @import("answers.zig");
const slot_table = @import("slot_table.zig");
const sturdyref_cache = @import("sturdyref_cache.zig");
const imported_promise = @import("imported_promise.zig");
const gc = @import("gc.zig");
const v1_0 = @import("v1_0.zig");
const handshake = @import("handshake.zig");
const limits = @import("limits.zig");

/// Position-keyed wire-delta refcount tables. Exports and imports share one
/// integer-keyed hash core (`slot_table` explains why partner-controlled
/// positions cannot use a raw index vector) but wrap it in distinct types so the
/// cap that bounds partner-driven imports is a property of `ImportTable`, not a
/// rule each call site must restate.
const ExportTable = slot_table.ExportTable;
const ImportTable = slot_table.ImportTable;

/// Error set for the borrowed-view recv walkers: session authority errors plus
/// the lazy projection errors a codec-backed `model.view.Args` can raise while
/// walking. Named explicitly so the mutually-recursive argument walkers don't
/// form an inferred-error-set dependency loop.
pub const RecvViewError = Error || model.view.ProjectError || std.mem.Allocator.Error;

pub const Error = error{
    MalformedMessage,
    /// A reference or position claim that does not exist for this session: an
    /// unheld import/export named where a held one is required, an unknown
    /// answer, or an inbound `answer-pos` at or above
    /// `VIRTUAL_INBOUND_ANSWER_BASE`, the range reserved for
    /// session-allocated virtual answers.
    InvalidReference,
    FeatureNotNegotiated,
    SessionClosed,
    InvalidGift,
    HandoffReplay,
    /// A wire-delta GC message (`op:gc-exports` / `op:gc-answers`) tried to
    /// decrement a refcount below zero or release an id the table never held.
    /// Per ADR-0008 wire-delta reference counting this is a loud protocol
    /// error, never a silent clamp.
    GcUnderflow,
    /// A message arrived (or was sent) in a state that does not admit it:
    /// `op:start-session` outside `negotiating`, or non-handshake traffic
    /// before the session reaches `open` (ADR-0006).
    UnexpectedMessage,
    /// A second `op:start-session` was observed on the same half of the
    /// handshake (already sent locally, or already received from the partner).
    DuplicateStartSession,
    /// The partner's `op:start-session` declared a CapTP version that does not
    /// match this session's negotiated `model.WireProfile` version.
    CaptpVersionMismatch,
    /// A pipelined-call queue for one answer exceeded `SessionLimits.queue_cap`
    /// (ADR-0007). A loud bound on a partner flooding calls against a promise it
    /// never resolves, never a silent drop.
    QueueCapExceeded,
    /// The inbound answer table exceeded `SessionLimits.max_inbound_answers`.
    InboundAnswerCapExceeded,
    /// One target's listener list exceeded
    /// `SessionLimits.max_listeners_per_target`.
    ListenerCapExceeded,
    /// One answer's `op:get` / `op:index` projection list exceeded
    /// `SessionLimits.max_listeners_per_target` (the same partner-driven
    /// fan-out class as listeners, bounded by the same knob, ADR-0050).
    ProjectionCapExceeded,
    /// A promise resolved (directly or transitively) to an answer already on the
    /// resolution chain being drained — requeueing the pipelined calls would
    /// loop forever (ADR-0007). Surfaced loudly instead of spinning.
    ResolutionCycle,
    /// A third-party import (ADR-0009) was re-rooted at a different host than the
    /// one it was first installed with. An import's host is fixed for its
    /// lifetime; a conflicting re-root is a loud protocol error, never a silent
    /// overwrite.
    HostMismatch,
    /// The import table exceeded `SessionLimits.max_imports`. A loud bound on a
    /// partner introducing unboundedly many imports (ADR-0025); never a silent
    /// drop. Projects to a `ResourceExhausted` abort.
    ImportCapExceeded,
    /// The vat's seen-handoff-count table (`engine.bootstrap.GiftRegistry`)
    /// exceeded `SessionLimits.max_seen_handoff_counts` — too many distinct
    /// Exporter-to-Receiver sessions tracked for replay rejection (ADR-0025).
    HandoffCountCapExceeded,
    /// The vat's deposited-gift table (`engine.bootstrap.GiftRegistry`) exceeded
    /// `SessionLimits.max_deposited_gifts` — the load-bearing bound against
    /// deposit-without-withdraw (ADR-0025).
    DepositedGiftCapExceeded,
    /// The parked-withdraw table exceeded `SessionLimits.max_pending_withdraws`
    /// — the bound against a partner flooding `withdraw-gift`s whose deposits
    /// never arrive (each parks until its gift is deposited, ADR-0056).
    PendingWithdrawCapExceeded,
    /// An inbound argument tree nested deeper than
    /// `SessionLimits.max_nesting_depth`. The recursive validate / install walk
    /// is bounded so a malicious deeply-nested frame fails loud instead of
    /// overflowing the native stack. Projects to `resource_exhausted`.
    NestingTooDeep,
};

/// The fixed bootstrap export position installed when a session reaches `open`
/// (ADR-0006). An inbound `op:deliver` to `<desc:export 0>` with method
/// `'fetch` is the bootstrap-fetch entry point. The initiator side lives in
/// `engine.fetch`; the inbound-`'fetch` responder lives in `engine.bootstrap`,
/// not the session.
///
/// Position 0 is pinned outside wire-delta GC in both directions: it is never
/// retained when mentioned on the wire (`retainSentExports`), an inbound
/// `op:gc-exports` naming it is a no-op skip (`checkGcExportDecrement` /
/// `applyGcExportDecrement`), and an outbound one is refused
/// (`validateSend`). The bootstrap export therefore lives exactly as long as
/// the session.
pub const BOOTSTRAP_POSITION: u64 = 0;

/// Base of the inbound-answer position range reserved for virtual answers the
/// session allocates itself (`Session.allocateInboundAnswer`, the V1.0
/// resolver-only fetch pattern). Answer positions are partner-named, so the
/// reservation is enforced in validation: an inbound `op:deliver` claiming an
/// answer-pos at or above this base is refused (`Error.InvalidReference`), and
/// only that refusal makes the virtual namespace collision-free.
pub const VIRTUAL_INBOUND_ANSWER_BASE: u64 = 0x8000_0000_0000_0000;

/// The base of the reserved redeemed-handoff-token far-id range (ADR-0066): the
/// cross-connection node (`engine.Node`) mints application-facing tokens from
/// this value upward and routes any far id at or above it to a redeemed
/// capability. Those tokens never travel the wire, so a partner-introduced far
/// import at or above this base could only alias one — the node would reroute
/// the application's send to a different connection's capability. Session
/// validation refuses a partner introduction in this range, exactly as it
/// refuses a partner answer claim in the virtual range above, so a far id the
/// application holds at or above the base is provably a node token, never a
/// partner import. `engine.Node` re-exports this as `REDEEMED_TOKEN_BASE`.
pub const REDEEMED_TOKEN_BASE: u64 = 1 << 60;

comptime {
    // The virtual inbound-answer base must sit above the partner-named answer
    // range it reserves against; a base of 0 would reserve everything and admit
    // nothing. Export ids need no such base: every export — actor, bootstrap,
    // and V1.0 resolver alike — is minted by the one session allocator
    // (`allocateExport`), so export collision is impossible by construction.
    std.debug.assert(0 < VIRTUAL_INBOUND_ANSWER_BASE);
    // The two reserved ranges must not overlap: the token range sits strictly
    // below the virtual-answer range, so refusing one never admits the other.
    std.debug.assert(REDEEMED_TOKEN_BASE < VIRTUAL_INBOUND_ANSWER_BASE);
}

/// Goblins V1.0 resolver-callback bookkeeping (ADR-0010). V1.0 has no wire
/// `op:resolve`; a promise's resolution rides as an `op:deliver` to a
/// synthesized resolver capability, so the session keeps two position-keyed
/// maps to translate between a semantic `Resolve` and a wire deliver in both
/// directions.
///
/// These are not folded onto the answer rows: the inbound resolver is installed
/// while classifying an inbound deliver, *before* `recordRecv` installs the
/// answer row, so binding it to the row would break the all-or-nothing apply.
/// Keeping them as O(1) integer-keyed maps preserves that lifecycle.
///
/// A resolver export is an ordinary export minted by the session's own
/// allocator (`allocateExport`); it shares the one export namespace with the
/// actor and bootstrap exports, and collision is impossible because the
/// session is the single minter.
///
/// `OutboundResolvers` maps a resolver-export position to an answer-pos, because the
/// hot lookup (`answerForResolverExport`, run per inbound deliver) needs that
/// reverse direction; its inverse `OutboundResolverAnswers` serves the
/// per-position removal on the `op:gc-answers` path
/// (`removeOutboundResolverByAnswer`), which would otherwise scan every
/// outstanding link per released answer — O(Q²) across a full release wave.
/// `InboundResolverImports` maps an answer-pos to a resolver import; its
/// inverse `InboundResolverAnswers` (`answerForResolverImport`, on the
/// inbound-deliver break-propagation path) needs the other direction. Each
/// forward/inverse pair is written and pruned in lockstep rather than
/// scanning. Keying each on its position newtype makes the direction a
/// property of the type. None owns heap memory beyond its map backing.
const OutboundResolvers = std.AutoHashMapUnmanaged(model.ExportPosition, model.AnswerPosition);
const OutboundResolverAnswers = std.AutoHashMapUnmanaged(model.AnswerPosition, model.ExportPosition);
const InboundResolverImports = std.AutoHashMapUnmanaged(model.AnswerPosition, model.ImportPosition);
const InboundResolverAnswers = std.AutoHashMapUnmanaged(model.ImportPosition, model.AnswerPosition);

pub const State = enum {
    negotiating,
    open,
    closed,
};

/// Resource bounds a session enforces against a partner. Defined in
/// `limits.zig`; aliased here so call sites keep reading `session.SessionLimits`.
pub const SessionLimits = limits.SessionLimits;

/// Which answer table an install targets. Inbound rows are partner-named and
/// bounded by `SessionLimits.max_inbound_answers`; outbound rows are
/// positions we allocate ourselves, bounded by our own sends, so they carry no
/// cap.
pub const AnswerDirection = enum { inbound, outbound };

pub const AnswerStatus = answers.AnswerStatus;
pub const ListenerEntry = answers.ListenerEntry;
const ListenerList = answers.ListenerList;
pub const Projection = answers.Projection;
pub const ProjectionKind = answers.ProjectionKind;
pub const deinitProjection = answers.deinitProjection;
const AnswerView = answers.AnswerView;
pub const AnswerTable = answers.AnswerTable;
const ensureAnswerPayload = answers.ensureAnswerPayload;
pub const deinitAnswerEntry = answers.deinitAnswerEntry;

/// A promise imported from a *third party* via handoff (ADR-0009 § `op:listen`
/// on `desc:import-promise`). The introducing partner gave us this import; its
/// eventual resolution lives on the third-party `host`, not on the direct
/// partner, so it is forwarded to us as a *relayed resolution* rather than a
/// direct `op:resolve`.
///
/// The presence of a row marks `import_position` third-party-hosted, the distinction
/// that lets an inbound `op:listen` on this import install a listener here rather
/// than be rejected. Grouping the host, listeners, and resolution in one owned
/// row gives the third-party promise a single lifecycle.
pub const ImportedPromise = struct {
    /// The third-party host this promise lives on (owned designator bytes). Held
    /// so a re-root with a conflicting host is rejected (`Error.HostMismatch`).
    host: []u8,
    /// Parties listening (via `op:listen` on `desc:import-promise`) for the
    /// relayed resolution. Entries are POD `FarRef` values.
    listeners: ListenerList = .empty,
    /// The relayed resolution once forwarded, stored so a late `op:listen` fires
    /// immediately. Owned; released on removal or overwrite.
    resolution: ?model.Resolution = null,
    /// This row instance's identity, stamped from `Session.store_stamp_counter`
    /// at registration (`installThirdPartyImport`). A queued fire carrier
    /// compares it at encode: a mismatch means the row it was accounted
    /// against was torn down (GC co-eviction) and a *different* third-party
    /// promise now lives at the same import position, so the fire is moot —
    /// emitting would deliver another promise's value to the stale
    /// listener. No default: registration must stamp. (No per-payload stamp is
    /// needed beside it: a live row's stored resolution is written exactly once
    /// — `recordRelayedResolution` refuses a second relay — so a matching
    /// `row_id` proves the stored value is the one the fire was accounted
    /// against.)
    row_id: u64,
};

/// One resolved sturdyref enlivenment (ADR-0012 dedup cache): the swiss-number
/// and the `FarRef` it resolved to. Storing the whole `FarRef` (import position +
/// kind), not a loose pair, is what carries ADR-0010 § The far-kind is preserved
/// across enliven: the cache-hit short-circuit hands the reference back with its
/// wire-tag discriminator intact, with no destructure-and-reconstruct seam where
/// the kind could be dropped. Owns its `swissnum`.
pub const SturdyrefCacheEntry = struct {
    swissnum: []u8,
    far: model.FarRef,
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    state: State,
    wire_profile: model.WireProfile,
    /// The wire codec negotiated for this direct session. The
    /// authoritative record of the codec choice; the engine's codec-dispatch
    /// boundary (`codec.dispatch`) reads it to route each frame, and every event
    /// the session produces is tagged with it. Defaults to `.syrup` for the
    /// non-negotiating constructors.
    codec: model.CodecId,
    features: model.FeatureSet,
    limits: SessionLimits,
    next_export_position: u64,
    /// Monotonic allocator for the answer-pos we put on outbound `op:deliver`s
    /// (bootstrap-fetch, pipeline decomposition). Per-direction namespace: our
    /// outbound answers are independent of the partner's inbound answer positions.
    next_outbound_answer: u64 = 0,
    /// Virtual answers allocated by V1.0 resolver-only fetches (the partner sent
    /// `resolve_me_desc` with no `answer_position`). Allocated from
    /// `VIRTUAL_INBOUND_ANSWER_BASE` upward; the partner is refused that range
    /// in validation, which is what keeps the namespaces disjoint (answer
    /// positions are partner-named, so a bare offset alone would not).
    next_virtual_inbound_answer: u64 = VIRTUAL_INBOUND_ANSWER_BASE,
    /// One per-session bump arena owning the byte keys/values of the *monotonic*
    /// byte-keyed tables — `bootstrap` swissnums and the partner key/designator
    /// bytes — none of which ever free an individual row. Teardown is one
    /// `key_arena.deinit()` instead of per-row free loops. The evicting /
    /// individually-removed tables (`sturdyref_cache`, `pending_enlivens`,
    /// imported-promise hosts) deliberately stay on the gpa with precise per-row
    /// frees: a bump arena cannot reclaim an evicted row and would leak under
    /// churn.
    key_arena: std.heap.ArenaAllocator,
    /// Per-turn scratch arena for the inbound record spine. It backs the
    /// introduced-import record every recv turn's validate walk fills and
    /// apply consumes (`validate.IntroducedImports` — allocation-free for the
    /// common no-reference message), the owned-fallback kinds' (`gc_*`,
    /// `handoff`, `get`/`index`/`untag`) one transient owned `Message`, and
    /// the inbound GC validators' duplicate-position scratch maps
    /// (`checkGcExportDecrement` / `checkGcAnswerDecrement` in
    /// `validateRecv`). All of it dies when the turn ends — exactly an
    /// arena's lifetime: reset (retaining capacity) at the end of every
    /// `recordRecvView`, `recordRecv`, and `recordResolverCallbackResolve`,
    /// so the scratch never outlives one turn and the per-message
    /// dupe-then-`freeMessage` choreography collapses to one bump-and-reset.
    /// Apply dupes anything session-lived onto `allocator`, so resetting the
    /// scratch can never dangle a table row.
    recv_scratch: std.heap.ArenaAllocator,
    exports: ExportTable,
    imports: ImportTable,
    inbound_answers: AnswerTable,
    outbound_answers: AnswerTable,
    /// Promises imported from a third party via handoff (ADR-0009), keyed by
    /// import position for O(1) lookup. Each row owns its host designator, listener
    /// caps, and stored relayed resolution.
    imported_promises: std.AutoHashMapUnmanaged(model.ImportPosition, ImportedPromise),
    /// Session-wide monotonic source for every store-row identity stamp a
    /// queued fire carrier checks at encode: `AnswerEntry.row_id` and
    /// `ImportedPromise.row_id`. One counter for both (not per-row seeds) so no
    /// two row instances ever share a value — a carrier stamped against a row
    /// since released and re-registered at the same position must miss, never
    /// false-match.
    store_stamp_counter: u64 = 0,
    /// Whether this side has sent its `op:start-session` half (ADR-0006).
    handshake_local_sent: bool,
    /// Whether the partner's `op:start-session` half has been observed.
    handshake_remote_received: bool,
    /// The partner's session public key, learned from its `op:start-session`. The
    /// session keeps it as opaque bytes in `key_arena` (it runs no crypto); an
    /// embedder reads it to verify the partner's signatures — for example, the
    /// gifter's `desc:handoff-give` when this is a gifter-to-exporter session
    /// (ADR-0009). Empty until the partner's handshake half arrives with a key.
    partner_session_key: []const u8 = &.{},
    /// The partner's location designator, learned from its `op:start-session`
    /// acceptable-location. Empty until the handshake half arrives. A host routing
    /// across sessions — a gifter matching a sturdyref's exporter location to the
    /// session it already holds with that exporter — reads it. Lives in `key_arena`.
    partner_designator: []const u8 = &.{},
    /// The partner's verbatim `<ocapn-peer ...>` location-record bytes, exactly as
    /// they arrived on its `op:start-session`. A gifter embeds these in a
    /// `desc:handoff-give`'s exporter-location so a peer comparing the give's
    /// location to the session's matches byte-for-byte (ADR-0009) — the designator
    /// alone is lossy for that match. Empty until the partner's handshake half
    /// arrives with raw bytes (the decode path captures them; an owned-message
    /// apply path does not). Lives in `key_arena`.
    partner_acceptable_location_raw: []const u8 = &.{},
    /// V1.0 resolver-callback links for our *outbound* answers, mapping a
    /// resolver-export position to an answer-pos. An inbound deliver to that export is
    /// the partner resolving the answer. Keyed for the reverse lookup that runs
    /// per inbound deliver. See `OutboundResolvers`.
    v1_0_outbound_resolvers: OutboundResolvers,
    /// The inverse of `v1_0_outbound_resolvers`, mapping an answer-pos back to
    /// its resolver export, so releasing an answer (`op:gc-answers`) drops its
    /// resolver link in O(1) instead of scanning every outstanding link — a
    /// client GCing Q answered delivers would otherwise pay O(Q²). Written and
    /// pruned in lockstep with the forward map: both rows appear together in
    /// `installOutboundResolver` and both drop together on answer release, so
    /// neither map outlives the answer it describes.
    v1_0_outbound_resolver_answers: OutboundResolverAnswers,
    /// V1.0 resolver-callback links for the partner's *inbound* answers, mapping
    /// an answer-pos to the resolver import position we target when we send our
    /// resolution. See `InboundResolvers`.
    v1_0_inbound_resolvers: InboundResolverImports,
    /// The inverse of `v1_0_inbound_resolvers`, mapping a resolver import position back
    /// to its answer-pos, so `answerForResolverImport` is O(1) instead of a scan.
    /// Written and pruned in lockstep with `v1_0_inbound_resolvers`: both rows
    /// appear together when a resolver is installed and both drop together when
    /// the answer is fully released by `op:gc-answers`, so neither map outlives
    /// the answer it describes.
    v1_0_inbound_resolver_answers: InboundResolverAnswers,
    /// Resolved sturdyref enlivenments, mapping a swissnum to its `(import, kind)`
    /// (ADR-0012 dedup).
    /// FIFO-evicting (cap `max_sturdyref_cache_entries`), so it keeps insertion
    /// order and owns each swissnum on the gpa — freed precisely on eviction.
    sturdyref_cache: std.ArrayList(SturdyrefCacheEntry),
    /// In-flight sturdyref enlivens, mapping a swissnum to its outstanding answer
    /// (ADR-0012 dedup). O(1) lookup; rows are removed on completion, so swissnum
    /// keys are gpa-owned and freed on removal.
    pending_enlivens: std.StringHashMapUnmanaged(model.AnswerPosition),
    /// The swissnum-to-export registry the inbound-`'fetch` responder consults
    /// (ADR-0006). Keys live in `key_arena`; O(1) lookup. Never removed.
    bootstrap: std.StringHashMapUnmanaged(model.ExportPosition),

    /// Construction knobs for `initWith`. Every field has a default, so a
    /// caller names only what it overrides: `Session.init(allocator)` is
    /// `initWith(allocator, .{})`. The knobs are orthogonal, `negotiating`
    /// selects the starting `State`, `limits` sets the resource bounds, and the
    /// rest set the negotiated profile / codec / features the handshake would
    /// otherwise install. The already-open default is v1.0; PreSpec is explicit.
    pub const Options = struct {
        /// Start in `negotiating` (awaiting `op:start-session`) instead of `open`.
        negotiating: bool = false,
        codec: model.CodecId = .syrup,
        wire_profile: model.WireProfile = model.WireProfile.v1_0,
        features: model.FeatureSet = model.FeatureSet.full(),
        limits: SessionLimits = .{},
    };

    /// Open v1.0 session, all defaults, `initWith(allocator, .{})`.
    pub fn init(allocator: std.mem.Allocator) Session {
        return initWith(allocator, .{});
    }

    /// Session that begins in `negotiating`, awaiting the `op:start-session`
    /// handshake on the default profile / feature set. The in-process handshake
    /// driver (`engine.pairing`) constructs both peers this way; use
    /// `initWith` with `.negotiating = true` to override the negotiated knobs.
    pub fn initNegotiating(allocator: std.mem.Allocator) Session {
        return initWith(allocator, .{ .negotiating = true });
    }

    /// The one full constructor; every `init*` shorthand delegates here.
    pub fn initWith(allocator: std.mem.Allocator, options: Options) Session {
        return .{
            .allocator = allocator,
            .state = if (options.negotiating) .negotiating else .open,
            .wire_profile = options.wire_profile,
            .codec = options.codec,
            .features = options.features,
            .limits = options.limits,
            // Start past the bootstrap id so `allocateExport` never aliases the
            // bootstrap object (export 0), true from construction, not only once
            // `transitionToOpen` runs, so a cap registered before the session
            // opens (e.g. a vat published on accept, hosting on the completion
            // loop) still gets a fresh export rather than colliding with 0.
            .next_export_position = BOOTSTRAP_POSITION + 1,
            .key_arena = std.heap.ArenaAllocator.init(allocator),
            .recv_scratch = std.heap.ArenaAllocator.init(allocator),
            .exports = .empty,
            .imports = .empty,
            .inbound_answers = .empty,
            .outbound_answers = .empty,
            .imported_promises = .empty,
            .handshake_local_sent = false,
            .handshake_remote_received = false,
            .partner_session_key = &.{},
            .partner_designator = &.{},
            .partner_acceptable_location_raw = &.{},
            .v1_0_outbound_resolvers = .empty,
            .v1_0_outbound_resolver_answers = .empty,
            .v1_0_inbound_resolvers = .empty,
            .v1_0_inbound_resolver_answers = .empty,
            .sturdyref_cache = .empty,
            .pending_enlivens = .empty,
            .bootstrap = .empty,
        };
    }

    pub fn deinit(self: *Session) void {
        self.exports.deinit(self.allocator);
        self.imports.deinit(self.allocator);
        self.inbound_answers.deinit(self.allocator);
        self.outbound_answers.deinit(self.allocator);
        // bootstrap key bytes live in `key_arena`, freed wholesale below.
        self.bootstrap.deinit(self.allocator);
        var imported_it = self.imported_promises.valueIterator();
        while (imported_it.next()) |entry| deinitImportedPromise(self.allocator, entry);
        self.imported_promises.deinit(self.allocator);
        self.v1_0_outbound_resolvers.deinit(self.allocator);
        self.v1_0_outbound_resolver_answers.deinit(self.allocator);
        self.v1_0_inbound_resolvers.deinit(self.allocator);
        self.v1_0_inbound_resolver_answers.deinit(self.allocator);
        for (self.sturdyref_cache.items) |entry| self.allocator.free(entry.swissnum);
        self.sturdyref_cache.deinit(self.allocator);
        var enliven_it = self.pending_enlivens.keyIterator();
        while (enliven_it.next()) |key| self.allocator.free(key.*);
        self.pending_enlivens.deinit(self.allocator);
        self.key_arena.deinit();
        self.recv_scratch.deinit();
    }

    /// V1.0 resolver-callback translation lives in `v1_0.zig`; these aliases keep
    /// the call sites reading as ordinary `Session` methods while the bodies sit
    /// beside the rest of the V1.0 bridge. The resolver-link fields they operate
    /// on stay on `Session`.
    pub const needsV1_0Translation = v1_0.needsV1_0Translation;
    pub const installOutboundResolver = v1_0.installOutboundResolver;
    pub const mintOutboundResolver = v1_0.mintOutboundResolver;
    pub const installInboundResolver = v1_0.installInboundResolver;
    pub const resolverForInboundAnswer = v1_0.resolverForInboundAnswer;
    pub const answerForResolverImport = v1_0.answerForResolverImport;
    pub const allocateInboundAnswer = v1_0.allocateInboundAnswer;
    pub const answerForResolverExport = v1_0.answerForResolverExport;

    /// The `op:start-session` handshake state lives in `handshake.zig`; these
    /// aliases keep the call sites reading as ordinary `Session` methods. The
    /// handshake fields they operate on stay on `Session`.
    pub const handshakeComplete = handshake.handshakeComplete;
    pub const transitionToOpen = handshake.transitionToOpen;
    pub const partnerSessionKey = handshake.partnerSessionKey;
    pub const partnerDesignator = handshake.partnerDesignator;
    pub const partnerLocatorRaw = handshake.partnerLocatorRaw;

    pub fn close(self: *Session) void {
        self.state = .closed;
    }

    /// Register `id` as a *granted* export: the row is installed at its local
    /// baseline and one addressability grant is retained on top, so the
    /// partner may address the position immediately, without waiting for the
    /// capability's first marshal. This is the explicit out-of-band grant verb
    /// (`Peer.exportObject` rides it); a capability that should stay
    /// unaddressable until its reference first crosses the wire is reserved
    /// with `reserveExport` / `allocateExport` instead. Idempotent on an
    /// already-granted row. The pinned bootstrap position is always
    /// addressable and never takes a grant.
    pub fn registerExport(self: *Session, id: model.ExportPosition) !void {
        try self.exports.register(self.allocator, id);
        if (id.int() != BOOTSTRAP_POSITION and self.exports.wireHeld(id) == 0) {
            try self.exports.retain(self.allocator, id);
        }
        if (id.int() >= self.next_export_position) {
            self.next_export_position = id.int() + 1;
        }
    }

    /// Reserve `id` as an export at its local baseline only: the object can
    /// marshal (send-side validation needs a live row), but the partner
    /// cannot address the position until the capability's reference first
    /// crosses the wire — or `registerExport` grants it explicitly. The
    /// positional twin of `allocateExport`. Idempotent, and it never
    /// downgrades: reserving an already-granted position leaves the grant
    /// standing.
    pub fn reserveExport(self: *Session, id: model.ExportPosition) !void {
        try self.exports.register(self.allocator, id);
        if (id.int() >= self.next_export_position) {
            self.next_export_position = id.int() + 1;
        }
    }

    /// Retain a partner-driven import. A *new* id is bounded by
    /// `SessionLimits.max_imports` (ADR-0025), a partner cannot grow our import
    /// table without limit. Already-held ids increment their wire-delta refcount:
    /// a partner may introduce the same export multiple times, and our later
    /// `op:gc-exports` must release the same total delta.
    pub fn registerImport(self: *Session, id: model.ImportPosition) !void {
        try self.imports.retain(self.allocator, id, self.limits.max_imports);
    }

    /// Install `id` as a pending inbound answer we owe resolution for.
    /// Idempotent; bounded by `SessionLimits.max_inbound_answers`. Used when
    /// the engine installs a queued pipelined call's answer, or redirects a
    /// drained pipelined call to a local export, the forwarded call's own
    /// answer becomes one we must resolve, even though no wire `op:deliver`
    /// installed it through `recordRecv`. The engine installs the same answer
    /// at queue time and again at local-redirect time, hence the idempotency.
    pub fn installInboundAnswer(self: *Session, id: model.AnswerPosition) !void {
        try self.installAnswer(.inbound, id);
    }

    /// Exhaustive session-state admission gate (ADR-0006), run at every dispatch
    /// head. The `switch (self.state)` is *total*: a new `State` variant will not
    /// compile until it declares what it admits, so "admit everything" can never
    /// be the silent default a buried `else if (state == .negotiating)` left it.
    /// `closed` admits nothing; `negotiating` admits only the handshake
    /// (`op:start-session`) and `op:abort`; `open` admits every kind.
    /// Kind-specific rules (a second `op:start-session`, target authority,
    /// feature gates) stay in the per-message validators; this is purely the
    /// state machine. Accepts either an owned `model.Message` or a borrowed
    /// `model.view.Body` — both share the op-kind tag names the gate switches on.
    fn admitInState(self: *const Session, message: anytype) Error!void {
        switch (self.state) {
            .closed => return Error.SessionClosed,
            .negotiating => switch (message) {
                .start_session, .abort => {},
                else => return Error.UnexpectedMessage,
            },
            .open => {},
        }
    }

    /// The state-admission gate, exposed so the engine can apply it *before* any
    /// pre-`recordRecv` authority mutation it performs (a pipelined-call enqueue, a
    /// listener install, a V1.0 resolver registration). `recordRecv*` gate
    /// themselves, but those engine pre-steps run ahead of `recordRecv` and the
    /// pipelined path returns without ever reaching it, so a closed session would
    /// otherwise queue a pipelined deliver, failing open. Checking here keeps
    /// `closed` a terminal refusal for every inbound kind. Exactly the state
    /// gate, nothing more: kind-specific rules (e.g. a wire `op:resolve` on a
    /// V1.0 session) belong to the validators (`validateRecvView`).
    pub fn admits(self: *const Session, body: model.view.Body) Error!void {
        try self.admitInState(body);
    }

    pub fn recordSend(self: *Session, message: model.Message) !void {
        // Admit and validate are ownership-neutral — they read the message, never
        // take its heap — so one pair of calls fronts every kind. Ownership forks
        // only at apply: a sent `op:resolve` is *consumed* (its resolution moves
        // into the inbound answer's store, `applySentResolve`), so a pre-apply
        // refusal must free it; every other kind is borrowed and freed by the
        // outbound queue after emit. `apply_owns_resolution` marks the handoff —
        // once apply runs it owns the resolution's fate (moved on success, freed
        // on its own failure), so the errdefer must not also free it.
        var apply_owns_resolution = false;
        errdefer if (message == .resolve and !apply_owns_resolution)
            model.freeResolution(self.allocator, message.resolve.resolution);
        try self.admitInState(message);
        try self.validateSend(message);
        apply_owns_resolution = true;
        switch (message) {
            .resolve => |resolve| try self.applySentResolve(resolve),
            else => try self.applySend(message),
        }
    }

    pub fn recordRecv(self: *Session, message: model.Message) !void {
        try self.admitInState(message);
        // The introduced-import record the validate walk fills and apply
        // consumes (one argument traversal per message, see
        // `validate.IntroducedImports`). Turn-scratch in `recv_scratch`,
        // reclaimed by the reset below.
        defer _ = self.recv_scratch.reset(.retain_capacity);
        var introduced: validate.IntroducedImports = .init(self.recv_scratch.allocator());
        try self.validateRecv(message, &introduced);
        try self.applyRecv(message, &introduced);
    }

    /// Borrowed-validate / owned-on-retain inbound path (the steady-state wire
    /// path). The session is codec-neutral but `model.view.Body` is a codec-
    /// neutral *borrowed* projection over the frame, so the common message kinds
    /// validate and apply authority directly from it — no owned materialization,
    /// no per-turn allocation. The only retained inbound copy is then the owned
    /// frame the event model requires; a pipelined deliver that must be queued
    /// materializes its own owned message on the retain path
    /// (`Peer.maybeEnqueuePipelinedCall`).
    ///
    /// The rarer, sub-structure-heavy kinds (`gc_*`, `handoff`, and the
    /// `get`/`index`/`untag` projection ops) fall back to one owned
    /// materialization for the existing owned validate / apply — they are off
    /// the hot path and not worth a second borrowed walk.
    pub fn recordRecvView(self: *Session, body: model.view.Body) !void {
        try self.admitInState(body);
        // Everything both branches bump into `recv_scratch` is turn-scratch —
        // the introduced-import record the validate walk fills and apply
        // consumes (`validate.IntroducedImports`), and the owned-fallback
        // materialization below — so one reset reclaims the whole turn. Apply
        // dupes anything session-lived onto `self.allocator`, so the reset can
        // never dangle a table row.
        defer _ = self.recv_scratch.reset(.retain_capacity);
        var introduced: validate.IntroducedImports = .init(self.recv_scratch.allocator());
        switch (body) {
            .deliver, .resolve, .listen, .start_session, .abort => {
                try self.validateRecvView(body, &introduced);
                try self.applyRecvView(body, &introduced);
            },
            .gc_export, .gc_answer, .handoff, .get, .index, .untag => {
                // One transient owned copy to feed the shared owned validate /
                // apply; it dies in the same reset, no per-row free walk.
                const owned = try body.toOwned(self.recv_scratch.allocator());
                try self.validateRecv(owned, &introduced);
                try self.applyRecv(owned, &introduced);
            },
        }
    }

    /// Record the inbound resolve the engine synthesizes when a V1.0 partner
    /// fulfills a promise by delivering to its resolver callback (ADR-0010).
    /// Validates and applies straight from the borrowed resolution view, so the
    /// V1.0 hot path materializes no owned resolution.
    ///
    /// This is deliberately *not* `recordRecvView`: that path refuses a
    /// wire `op:resolve` on a V1.0 session, and this resolve never arrived on
    /// the wire, the partner sent an `op:deliver` to the resolver and the
    /// engine surfaces the settlement as a semantic resolve. The shared
    /// inbound-resolve validation and apply run exactly as the canonical
    /// resolve path does, minus that wire refusal. The borrowed `resolve` must
    /// outlive this call; the engine keeps the frame it borrows alive on the
    /// event queue before applying.
    pub fn recordResolverCallbackResolve(self: *Session, resolve: model.view.Resolve) !void {
        const body = model.view.Body{ .resolve = resolve };
        try self.admitInState(body);
        // Same turn-scratch introduced-import record as `recordRecvView`; the
        // fulfill payload is walked once in validation and apply consumes the
        // record.
        defer _ = self.recv_scratch.reset(.retain_capacity);
        var introduced: validate.IntroducedImports = .init(self.recv_scratch.allocator());
        try validate.validateInboundResolve(self, resolve, &introduced);
        try self.applyRecvView(body, &introduced);
    }

    // Per-kind validate/apply live in `validate.zig` and `apply.zig`; the
    // public spine is `recordSend` / `recordRecv` / `recordRecvView` /
    // `admits`. Three per-kind entry points stay public because one engine
    // pre-step must run the same rule before `recordRecv*`.
    const validate = @import("validate.zig");
    const apply = @import("apply.zig");

    const validateRecvView = validate.validateRecvView;
    const validateSend = validate.validateSend;
    const validateRecv = validate.validateRecv;
    const applyRecvView = apply.applyRecvView;
    const applySend = apply.applySend;
    const applySentResolve = apply.applySentResolve;
    const applyRecv = apply.applyRecv;

    /// Validate a pipelined inbound deliver before the engine queues or
    /// redirects it. Engine caller: `engine.pipeline.maybeEnqueuePipelinedCall`.
    pub const validatePipelinedDeliver = validate.validatePipelinedDeliver;
    /// Validate an inbound `op:listen` before the engine installs its
    /// listener. Engine caller: `engine.pipeline.maybeInstallInboundListener`.
    pub const validateInboundListen = validate.validateInboundListen;
    /// Retain the wire mention of a sent export reference that bypasses
    /// `recordSend`. Engine caller: `engine.v1_0.installResolverForOutboundDeliver`.
    pub const retainSentExportRef = apply.retainSentExportRef;

    const installAnswer = apply.installAnswer;

    /// Mint the next store-row stamp (see `store_stamp_counter`). Never
    /// returns 0, so a zero-initialized stamp can never false-match one.
    pub fn nextStoreStamp(self: *Session) u64 {
        self.store_stamp_counter += 1;
        return self.store_stamp_counter;
    }

    pub fn inboundAnswer(self: *Session, id: model.AnswerPosition) ?AnswerView {
        const entry = self.inbound_answers.getPtr(id) orelse return null;
        return AnswerView.of(entry);
    }

    /// Whether `id` is a known inbound answer — the existence probe the
    /// pipeline's guards read, without materializing an `AnswerView`.
    pub fn hasInboundAnswer(self: *const Session, id: model.AnswerPosition) bool {
        return self.inbound_answers.contains(id);
    }

    /// The identity stamp of the live inbound-answer row at `id`, or null when
    /// absent — the value a queued listener-fire carrier compares at encode to
    /// tell this row instance from a released-and-reused position.
    pub fn inboundAnswerRowId(self: *Session, id: model.AnswerPosition) ?u64 {
        const entry = self.inbound_answers.getPtr(id) orelse return null;
        return entry.row_id;
    }

    pub fn outboundAnswer(self: *Session, id: model.AnswerPosition) ?AnswerView {
        const entry = self.outbound_answers.getPtr(id) orelse return null;
        return AnswerView.of(entry);
    }

    pub fn hasExport(self: *const Session, id: model.ExportPosition) bool {
        return self.exports.contains(id);
    }

    pub fn hasImport(self: *const Session, id: model.ImportPosition) bool {
        return self.imports.contains(id);
    }

    /// Current wire-delta refcount for a local export (0 if not live).
    pub fn exportRefcount(self: *const Session, id: model.ExportPosition) u64 {
        return self.exports.count(id);
    }

    /// Current wire-delta refcount for an import of a partner export (0 if
    /// not live).
    pub fn importRefcount(self: *const Session, id: model.ImportPosition) u64 {
        return self.imports.count(id);
    }

    /// Allocate the next free export position as a *reservation*: the row is
    /// installed at its local baseline, so the object can marshal, but the
    /// partner cannot address the position until the capability's reference
    /// first crosses the wire (or `registerExport` grants it explicitly).
    pub fn allocateExport(self: *Session) !model.ExportPosition {
        const id = model.ExportPosition.from(self.next_export_position);
        try self.exports.register(self.allocator, id);
        self.next_export_position += 1;
        return id;
    }

    /// Release an export this session just allocated with `allocateExport` and
    /// never handed to the partner, the rollback half of a locally-aborted
    /// operation that allocated an export before a later step failed. The slot is
    /// live at count 1 by construction, so the decrement removes it and cannot
    /// underflow; a failure would mean the caller broke that construction, and
    /// `unreachable` keeps the drift loud in safe builds instead of silently
    /// leaving a phantom export row. The monotonic `next_export_position` is left
    /// advanced: a skipped id is not a leak, and ids are never reused.
    pub fn releaseUnsharedExport(self: *Session, id: model.ExportPosition) void {
        self.exports.decrement(id, 1) catch unreachable;
    }

    /// Expose a local capability behind `swissnum` for inbound bootstrap-fetch
    /// (ADR-0006 responder half): allocate a fresh export and map the swissnum to
    /// it. Returns the export position. Re-registering a swissnum replaces its mapping.
    pub fn registerBootstrapCap(self: *Session, swissnum: []const u8) !model.ExportPosition {
        const export_position = try self.allocateExport();
        // The export was never handed out, so a failure to map the swissnum
        // rolls it back instead of leaving a phantom export row.
        errdefer self.releaseUnsharedExport(export_position);
        const gop = try self.bootstrap.getOrPut(self.allocator, swissnum);
        if (!gop.found_existing) {
            // getOrPut left the slot keyed on the borrowed `swissnum`; replace it
            // with an arena-owned copy, removing the slot if the copy fails so no
            // dangling borrowed key survives.
            gop.key_ptr.* = self.key_arena.allocator().dupe(u8, swissnum) catch |err| {
                std.debug.assert(self.bootstrap.remove(swissnum));
                return err;
            };
        }
        gop.value_ptr.* = export_position;
        return export_position;
    }

    /// The local export serving `swissnum`, or null if none is registered.
    pub fn bootstrapLookup(self: *const Session, swissnum: []const u8) ?model.ExportPosition {
        return self.bootstrap.get(swissnum);
    }

    /// The swissnum a local export serves, or null if `export_position` is not a
    /// bootstrap-published cap on this session, the reverse of `bootstrapLookup`.
    /// A gifted near resolved through this names the vat-scoped object identity a
    /// cross-session withdrawal re-resolves against the withdrawing session
    /// (ADR-0009 exporter half). The returned slice aliases this session's
    /// arena-owned key and lives as long as the session.
    pub fn bootstrapSwissForExport(self: *const Session, export_position: model.ExportPosition) ?[]const u8 {
        var it = self.bootstrap.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* == export_position) return entry.key_ptr.*;
        }
        return null;
    }

    /// Reserve the next outbound answer-pos. The id is installed in the outbound
    /// answer table when the carrying `op:deliver` is recorded on send; this only
    /// advances the counter so concurrent fetches / decompositions don't collide.
    pub fn allocateOutboundAnswer(self: *Session) model.AnswerPosition {
        const id = model.AnswerPosition.from(self.next_outbound_answer);
        self.next_outbound_answer += 1;
        return id;
    }

    // --- Pipelining substrate (ADR-0007) ---------------------------------
    //
    // A pipelined `op:deliver` targets an answer the partner has not resolved
    // yet, so the session holds it (owned) on that answer's queue until the
    // resolution arrives, then the engine drains and redirects it. `op:listen`
    // registers a party to be told when the answer resolves; the resolution is
    // stored so a late listener fires immediately. These operate on the inbound
    // answer table — the partner's answers we hold — mirroring the canonical
    // engine's `InboundAnswers`.

    /// Queue a pipelined call (an owned `op:deliver` whose target is the pending
    /// answer `answer_position`), taking ownership of `message`. On any failure the
    /// message is freed so the caller never double-frees. The answer must exist
    /// and be `pending`; a resolved or unknown answer is the caller's contract
    /// violation, surfaced as `Error.InvalidReference`.
    pub fn enqueuePipelinedCall(self: *Session, answer_position: model.AnswerPosition, message: model.Message) !void {
        errdefer model.freeMessage(self.allocator, message);
        const entry = self.inbound_answers.getPtr(answer_position) orelse
            return Error.InvalidReference;
        if (entry.status != .pending) return Error.InvalidReference;
        const queued = if (entry.payload) |p| p.queue.items.len else 0;
        if (queued >= self.limits.queue_cap) return Error.QueueCapExceeded;
        const payload = try ensureAnswerPayload(self.allocator, entry);
        try payload.queue.append(self.allocator, message);
    }

    /// Hand the caller the queued pipelined calls for `answer_position`, transferring
    /// ownership of every message and leaving the answer's queue empty. Returns
    /// an empty slice for an unknown answer or empty queue. The caller owns the
    /// returned slice (free each message, then free the slice with `allocator`).
    pub fn takePipelinedCalls(self: *Session, answer_position: model.AnswerPosition) ![]model.Message {
        const entry = self.inbound_answers.getPtr(answer_position) orelse
            return &.{};
        const payload = entry.payload orelse return &.{};
        if (payload.queue.items.len == 0) return &.{};
        const drained = try payload.queue.toOwnedSlice(self.allocator);
        return drained;
    }

    /// Hand the caller the listeners registered on `answer_position`, leaving
    /// the answer's listener list empty. Returns an empty slice for an unknown
    /// answer or no listeners. The caller owns the returned slice and frees it
    /// with `allocator`; the entries themselves are POD.
    pub fn takePipelinedListeners(self: *Session, answer_position: model.AnswerPosition) ![]ListenerEntry {
        const entry = self.inbound_answers.getPtr(answer_position) orelse
            return &.{};
        const payload = entry.payload orelse return &.{};
        return payload.listeners.take(self.allocator);
    }

    /// Move one pipelined `call` (an owned message drained from an answer that
    /// resolved to another promise) onto `target`'s queue, taking ownership of
    /// the message: appended on success, freed on any refusal. `seen` is the
    /// set of answer positions the caller knows are on this resolution chain; if
    /// `target` is among them the requeue would loop, so it fails with
    /// `Error.ResolutionCycle`.
    ///
    /// The engine caller passes the single just-resolved answer, so the `seen`
    /// check catches a promise that resolves directly to itself. A longer chain
    /// (A resolves to B, then B back to A) is caught by a second, stronger
    /// invariant: `target` must be `.pending`, and resolving an answer settles it
    /// before its calls drain (`recordSend` runs at send time). So to move a call
    /// onward from A you resolve A — settling it — and any later attempt to requeue
    /// the call back onto A finds A already settled and fails with
    /// `InvalidReference`, freeing the call. A resolution chain therefore cannot
    /// loop: it can only move forward through still-pending answers (bounded by the
    /// inbound-answer cap) until it reaches a non-promise resolution or a settled
    /// answer. No chain history is needed, and there is no infinite bounce or
    /// amplification — see the "multi-hop pipeline cycle terminates" engine test.
    ///
    /// `target` must be a pending inbound answer, and its queue takes the same
    /// `queue_cap` bound `enqueuePipelinedCall` enforces.
    pub fn requeuePipelinedCall(self: *Session, target: model.AnswerPosition, seen: []const model.AnswerPosition, call: model.Message) !void {
        for (seen) |id| {
            if (id == target) {
                model.freeMessage(self.allocator, call);
                return Error.ResolutionCycle;
            }
        }
        // The delegate owns `call` on every outcome, so nothing here may touch
        // it again — the cycle check above is the only rule requeue adds.
        return self.enqueuePipelinedCall(target, call);
    }

    /// Register `listener` (a POD entry) as wanting `answer_position`'s
    /// resolution. The answer must exist; it may be `pending` or already
    /// resolved (a late listener, the engine fires it immediately from the
    /// stored resolution).
    pub fn installListener(self: *Session, answer_position: model.AnswerPosition, listener: ListenerEntry) !void {
        const entry = self.inbound_answers.getPtr(answer_position) orelse
            return Error.InvalidReference;
        const installed = if (entry.payload) |p| p.listeners.len() else 0;
        if (installed >= self.limits.max_listeners_per_target) {
            return Error.ListenerCapExceeded;
        }
        const payload = try ensureAnswerPayload(self.allocator, entry);
        try payload.listeners.append(self.allocator, listener);
    }

    /// Anchor `projection` (taking ownership of its `.field` bytes) on the
    /// pending inbound answer `answer_position` (ADR-0050). On failure the bytes
    /// are freed. The answer must exist and must still be pending: a projection
    /// fires once, from `drainProjections`, when the answer's resolve drains, so
    /// anchoring onto an already-settled answer would never fire. Settled is
    /// read as a stored resolution rather than the status flag, the two are
    /// equivalent for inbound answers (the `applySentResolve` invariant: status
    /// and resolution land together), and naming the resolution keeps this guard
    /// honest if that ever drifts. Symmetric with `installListener`, which the
    /// engine's `installAnswerListener` gates the same way (peek first, install
    /// only when pending).
    pub fn installProjection(self: *Session, answer_position: model.AnswerPosition, projection: Projection) !void {
        errdefer deinitProjection(self.allocator, projection);
        const entry = self.inbound_answers.getPtr(answer_position) orelse
            return Error.InvalidReference;
        const resolution_stored = if (entry.payload) |p| p.resolution != null else false;
        if (resolution_stored) return Error.InvalidReference;
        const installed = if (entry.payload) |p| p.projections.items.len else 0;
        if (installed >= self.limits.max_listeners_per_target) {
            return Error.ProjectionCapExceeded;
        }
        const payload = try ensureAnswerPayload(self.allocator, entry);
        try payload.projections.append(self.allocator, projection);
    }

    /// Hand the caller the projections anchored on `answer_position`, transferring
    /// ownership of every entry's `.field` bytes and leaving the answer's
    /// projection list empty. Returns an empty slice for an unknown answer or
    /// no projections. The caller owns the returned slice (release each entry
    /// with `deinitProjection`, then free the slice with `allocator`).
    pub fn takeProjections(self: *Session, answer_position: model.AnswerPosition) ![]Projection {
        const entry = self.inbound_answers.getPtr(answer_position) orelse
            return &.{};
        const payload = entry.payload orelse return &.{};
        if (payload.projections.items.len == 0) return &.{};
        return try payload.projections.toOwnedSlice(self.allocator);
    }

    /// Store `resolution` on `answer_position` (taking ownership), marking the answer
    /// resolved. Replaces any prior stored resolution. On failure the resolution
    /// is freed.
    pub fn storeResolution(self: *Session, answer_position: model.AnswerPosition, resolution: model.Resolution) !void {
        const entry = self.inbound_answers.getPtr(answer_position) orelse {
            model.freeResolution(self.allocator, resolution);
            return Error.InvalidReference;
        };
        const payload = ensureAnswerPayload(self.allocator, entry) catch |err| {
            model.freeResolution(self.allocator, resolution);
            return err;
        };
        if (payload.resolution) |prior| model.freeResolution(self.allocator, prior);
        payload.resolution = resolution;
        entry.status = switch (resolution) {
            .fulfill => .fulfilled,
            .@"break" => .broken,
        };
    }

    /// Borrow the stored resolution for `answer_position`, if the answer resolved and
    /// retained it. The borrow is valid until the answer is mutated or removed.
    pub fn peekResolution(self: *Session, answer_position: model.AnswerPosition) ?*const model.Resolution {
        const entry = self.inbound_answers.getPtr(answer_position) orelse return null;
        const payload = entry.payload orelse {
            std.debug.assert(entry.status == .pending);
            return null;
        };
        // The `applySentResolve` invariant every fire and projection reader
        // leans on: for an inbound answer, a stored resolution and a settled
        // status arrive together or not at all.
        std.debug.assert((payload.resolution != null) == (entry.status != .pending));
        if (payload.resolution) |*resolution| return resolution;
        return null;
    }

    /// Whether `answer_position` is a known inbound answer that has resolved.
    pub fn answerResolved(self: *Session, answer_position: model.AnswerPosition) bool {
        const entry = self.inbound_answers.getPtr(answer_position) orelse return false;
        return entry.status != .pending;
    }

    // Third-party handoff-imported promises (ADR-0009): a `desc:import-promise`
    // handed to us by an introducing partner names a promise hosted on a *third*
    // peer, whose resolution reaches us as a relayed resolution rather than a
    // direct `op:resolve`. The substrate mirrors the answer-side pipelining one
    // above, keyed on import position; bodies live in `imported_promise.zig`, aliased
    // here so `sess.installThirdPartyImport(...)` still resolves.
    pub const installThirdPartyImport = imported_promise.installThirdPartyImport;
    pub const isThirdPartyImport = imported_promise.isThirdPartyImport;
    pub const installImportedPromiseListener = imported_promise.installImportedPromiseListener;
    pub const recordRelayedResolution = imported_promise.recordRelayedResolution;
    pub const takeImportedPromiseListeners = imported_promise.takeImportedPromiseListeners;
    pub const importedPromiseResolution = imported_promise.importedPromiseResolution;
    pub const findImportedPromise = imported_promise.findImportedPromise;

    // Sturdyref-enliven dedup (ADR-0012): the resolved-enlivenment cache and the
    // in-flight enliven set. Bodies live in `sturdyref_cache.zig`; aliased here
    // so `sess.cacheSturdyrefEnlivenment(...)` still resolves.
    pub const sturdyrefCacheLookup = sturdyref_cache.sturdyrefCacheLookup;
    pub const cacheSturdyrefEnlivenment = sturdyref_cache.cacheSturdyrefEnlivenment;
    pub const pendingEnlivenAnswer = sturdyref_cache.pendingEnlivenAnswer;
    pub const notePendingEnliven = sturdyref_cache.notePendingEnliven;
    pub const finishPendingEnliven = sturdyref_cache.finishPendingEnliven;
};

// Wire-delta GC accounting and structural well-formedness checks (ADR-0008):
// stateless free functions over the tables/messages they validate. Bodies live
// in `gc.zig`; re-exported here so `session.checkGcExportDecrement` still
// resolves from the validate/apply spine.
pub const checkGcExportDecrement = gc.checkGcExportDecrement;
pub const applyGcExportDecrement = gc.applyGcExportDecrement;
pub const checkGcAnswerDecrement = gc.checkGcAnswerDecrement;
pub const validateGcExport = gc.validateGcExport;
pub const validateHandoffWellFormed = gc.validateHandoffWellFormed;

/// Release the owned memory an `ImportedPromise` holds (host designator,
/// listener-list backing, stored relayed resolution). Body in
/// `imported_promise.zig`.
pub const deinitImportedPromise = imported_promise.deinitImportedPromise;
