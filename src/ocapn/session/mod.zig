//! The authoritative state for one CapTP session.
//!
//! `Session` owns the export, import, answer, handshake, pipelining, GC,
//! handoff, and sturdyref tables for one direct conversation. `recordSend` and
//! `recordRecv*` are the validate-then-apply state-machine entries; codecs and
//! adapters only move bytes.
//!
//! The layout favors O(1) position lookups and short-lived receive scratch.
//! `docs/architecture.md` and the memory rule carry the wider derivation.

const std = @import("std");
const model = @import("model");
const answers = @import("answers/store.zig");
const answer_notifications = @import("answers/notifications.zig");
const slot_table = @import("slot_table.zig");
pub const slot = @import("slot.zig");
const sturdyref_cache = @import("sturdyref_cache.zig");
const imported_promise = @import("promises/imported.zig");
const local_promise = @import("local_promise.zig");
const gc = @import("gc.zig");
const resolver_export = @import("resolver_export.zig");
const shortening = @import("shortening.zig");
const v1_0 = @import("v1_0.zig");
const handshake = @import("handshake.zig");
const limits = @import("limits.zig");
const protocol = @import("protocol.zig");
const positions = @import("references/positions.zig");
const bootstrap_references = @import("references/bootstrap.zig");
const pipeline = @import("answers/pipeline.zig");
const answer_lifecycle = @import("answers/lifecycle.zig");
const promise_types = @import("promises/types.zig");
const lifecycle = @import("lifecycle.zig");

/// Re-exported so a caller that must keep the recv-turn's introduced-import
/// record alive across validate and apply (`validateInboundDeliverView`'s caller,
/// `engine.inbound.applyDecodedOwnedFrame`) can name `validate.IntroducedImports`
/// without reaching past this module into `session/validate.zig` directly.
pub const validate = @import("validate.zig");
pub const parsePreferenceHints = validate.parsePreferenceHints;

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

pub const Error = @import("errors.zig").Error;

/// The fixed bootstrap export position installed when a session reaches `open`
/// (ADR-0006). An inbound `op:deliver` to `<desc:export 0>` with method
/// `'fetch` is the bootstrap-fetch entry point. The initiator side lives in
/// `engine.fetch`; the inbound-`'fetch` responder lives in `engine.bootstrap`,
/// not the session.
///
/// Position 0 is pinned outside wire-delta GC in both directions: it is never
/// retained by send-side export accounting, an inbound
/// `op:gc-exports` naming it is a no-op skip (`checkGcExportDecrement` /
/// `applyGcExportDecrement`), and an outbound one is refused
/// (`validateSend`). The bootstrap export therefore lives exactly as long as
/// the session.
pub const BOOTSTRAP_POSITION: u64 = 0;

/// Resolver-link bookkeeping: the two position-keyed maps that say which of our
/// outbound answers a local export settles, and which resolver import the
/// partner gave us for each of its inbound answers.
///
/// The outbound half is version-neutral (`resolver_export.zig`): both profiles
/// receive answer and listener notifications through resolver callbacks. The
/// inbound half is V1.0's alone because only V1.0 advertises a resolver in an
/// answered `op:deliver`; next follows every answered operation with
/// `op:listen` instead.
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
/// Both links are bijections held in `BiMap`s so each direction stays in
/// lockstep by construction rather than by comment. The outbound link binds a
/// resolver-export position to the answer-pos it settles: the hot lookup
/// (`answerForResolverExport`, run per inbound deliver) reads it forward, and
/// the `op:gc-answers` retirement reads it by its answer side, both O(1). A
/// retired purpose keeps an in-flight callback from becoming an ordinary
/// deliver until the partner releases the resolver's wire mention. The inbound
/// link binds an answer-pos to the partner's
/// resolver import (`resolverForInboundAnswer` forward, `answerForResolverImport`
/// reverse). Keying each on its position newtype makes the direction a property
/// of the type. Neither owns heap beyond its two map backings.
pub const PromiseIncarnation = promise_types.PromiseIncarnation;
pub const RetiredResolverState = promise_types.RetiredResolverState;
pub const RetiredResolver = promise_types.RetiredResolver;
pub const NodeSettlingResolver = promise_types.NodeSettlingResolver;
pub const ResolverPurpose = promise_types.ResolverPurpose;
pub const ShorteningNomination = shortening.Nomination;
pub const SettlingMovePlan = imported_promise.SettlingMovePlan;
const OutboundResolverLink = promise_types.OutboundResolverLink;
const InboundResolverLink = promise_types.InboundResolverLink;

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
pub const AnswerDirection = answer_lifecycle.Direction;

pub const AnswerStatus = answers.AnswerStatus;
pub const pendingInboundSlot = answers.pendingInboundSlot;
pub const answerSlot = answers.answerSlot;
pub const AnswerCell = answers.AnswerCell;
pub const AnswerPayload = answers.AnswerPayload;
pub const AnswerTarget = answers.AnswerTarget;
pub const ListenerEntry = answers.ListenerEntry;
pub const Projection = answers.Projection;
pub const ProjectionKind = answers.ProjectionKind;
pub const ProjectionIndex = answers.ProjectionIndex;
pub const deinitProjection = answers.deinitProjection;
pub const AnswerView = answers.AnswerView;
pub const InboundAnswerTable = answers.InboundAnswerTable;
pub const OutboundAnswerTable = answers.OutboundAnswerTable;

pub const inspect = @import("inspect.zig");
pub const ExportView = inspect.ExportView;
pub const ImportView = inspect.ImportView;
pub const AnswerRowView = inspect.AnswerRowView;
pub const deinitAnswerCell = answers.deinitAnswerCell;

pub const PromiseListenCell = promise_types.PromiseListenCell;
pub const ImportedPromise = promise_types.ImportedPromise;

/// Supported alias for the row owned by `sturdyref_cache.zig`.
pub const SturdyrefCacheEntry = sturdyref_cache.Entry;

pub const Session = struct {
    allocator: std.mem.Allocator,
    state: State,
    /// The active profile with `codec`: what the handshake settled, not what
    /// either side asked for. Holds the preference until a partner's hello
    /// settles it.
    captp_version: model.CaptpVersion,
    /// The wire codec negotiated for this direct session. The
    /// authoritative record of the codec choice; the engine's codec-dispatch
    /// boundary (`codec.dispatch`) reads it to route each frame, and every event
    /// the session produces is tagged with it. Defaults to `.syrup` for the
    /// non-negotiating constructors.
    codec: model.CodecId,
    /// What this side asked for, and what the partner asked for: the two
    /// inputs `engine.negotiation.settle` reads to produce the active profile
    /// above. Both are a whole `model.Preference` rather than loose fields,
    /// because they are the same kind of thing and every reader wants them
    /// whole — a decomposed side would be rebuilt at each use site.
    ///
    /// Kept beside the active values rather than folded into them because
    /// they answer a different question. The active pair is a property of the
    /// two peers; these are properties of one peer each, and they are what
    /// answers "why is this session on the baseline". The hello advertises
    /// `preferred`, so it has to survive the settle that overwrites the
    /// active values — including `features`, which is why the offered set
    /// lives here and the negotiated set lives above.
    preferred: model.Preference,
    /// The partner's, or the baseline before its hello has arrived. The
    /// session records the claim; the engine decides with it.
    partner_preference: model.Preference = .{},
    /// Whether this partner is known to be pancake before our hello states a
    /// preference, which on onion is the licence to state one at all
    /// (ADR-0118). The engine mints it at exactly two seams, and the pinned
    /// Goblins onion netlayer can produce neither: a dial handed a
    /// `pancake/*`-hinted locator (`Peer.noteKnownPancakePartner`), and a
    /// deferred onion accept whose inbound hello stated a non-baseline
    /// preference (`Peer.answerDeferredHello`).
    partner_known_pancake: bool = false,
    features: model.FeatureSet,
    limits: SessionLimits,
    next_export_position: u64,
    /// The first export position this session may hand out. Paired with
    /// `export_position_end`: together they are the range that says which
    /// export numbers are *this* session's to name.
    ///
    /// A host gives each session a disjoint range so a capability offered to
    /// the wrong session is absent there rather than ambiguous.
    export_base: u64 = BOOTSTRAP_POSITION + 1,
    /// One past the last export position this session may hand out.
    ///
    /// The range only protects the session while it stays inside: the
    /// allocator is monotonic and counts positions ever minted, not live ones,
    /// so a long-lived session that mints and releases would otherwise walk
    /// into its neighbour's range and silently start naming another session's
    /// objects. Running out is a loud refusal instead. `maxInt` when no range
    /// was imposed.
    export_position_end: u64 = std.math.maxInt(u64),
    /// Monotonic allocator for the answer-pos we put on outbound `op:deliver`s
    /// (bootstrap-fetch, pipeline decomposition). Per-direction namespace: our
    /// outbound answers are independent of the partner's inbound answer positions.
    next_outbound_answer: u64 = 0,
    /// Virtual answers allocated by V1.0 resolver-only fetches (the partner sent
    /// `resolve_me_desc` with no `answer_position`). This counter belongs to a
    /// typed namespace disjoint from every partner-selected wire answer.
    next_virtual_inbound_answer: u64 = 1,
    /// Bump arena for monotonic byte keys: bootstrap swissnums, handshake bytes,
    /// and interned third-party host designators. Churned rows stay on the gpa.
    key_arena: std.heap.ArenaAllocator,
    /// Per-turn arena for recv validation and temporary owned fallbacks. Recv
    /// entry points reset it; apply dupes anything session-lived onto `allocator`.
    recv_scratch: std.heap.ArenaAllocator,
    exports: ExportTable,
    imports: ImportTable,
    inbound_answers: InboundAnswerTable,
    outbound_answers: OutboundAnswerTable,
    /// Lazy store for notification obligations whose partner-owned
    /// pipelining name has been GC'd and may already have been reused. Null in
    /// the steady state; rows are keyed by the session's monotonic row stamp.
    detached_inbound_answers: ?*answers.DetachedAnswerStore = null,
    /// Owned bytes in resolutions retained by sent inbound-answer rows. The
    /// Peer includes this in its existing outbound waterline until answer GC
    /// or local promise retirement releases the row.
    retained_sent_answer_bytes: usize = 0,
    /// Promises imported from a third party via handoff (ADR-0009), keyed by
    /// import position for O(1) lookup. Host designators are interned in
    /// `key_arena`; each row owns its listen cell and stored relayed resolution.
    imported_promises: std.AutoHashMapUnmanaged(model.ImportPosition, ImportedPromise),
    /// Session-wide monotonic source for every store-row identity stamp a
    /// queued fire carrier checks at encode: `AnswerCell.row_id` and
    /// `PromiseListenCell.row_id`. One counter for all (not per-row seeds) so no
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
    /// This side's own session public key, learned from the `op:start-session`
    /// half we sent. Kept as opaque bytes in `key_arena` beside the partner's,
    /// for the one job that needs to know who *we* are on this session: an
    /// exporter deriving the session name a `desc:handoff-receive` must carry
    /// (ADR-0009), so a withdrawal cannot name a session it does not belong to.
    /// Empty on an unkeyed session, which is also every session on which no
    /// handoff can be redeemed.
    local_session_key: []const u8 = &.{},
    /// The partner's location designator from its `op:start-session`. When
    /// `partner_acceptable_location_raw` is set, this is a view into that
    /// buffer; otherwise a designator-only arena dupe (owned-message apply).
    /// Empty until the handshake half arrives.
    partner_designator: []const u8 = &.{},
    /// The partner's verbatim `<ocapn-peer ...>` location-record bytes, exactly as
    /// they arrived on its `op:start-session`. Sole owner of peer-location
    /// content on the decode path (`partner_designator` views into it). A gifter
    /// embeds these in a `desc:handoff-give`'s exporter-location so a peer
    /// comparing the give's location to the session's matches byte-for-byte
    /// (ADR-0009). Empty until the partner's handshake half arrives with raw
    /// bytes (owned-message apply has none). Lives in `key_arena`.
    partner_acceptable_location_raw: []const u8 = &.{},
    /// The resolver-export link (ADR-0010, ADR-0095): a resolver-export
    /// position bound to the outbound answer-pos it settles. An inbound
    /// deliver to that export is the partner settling the answer
    /// (`answerForResolverExport`, forward, per inbound deliver); a
    /// fully-released answer retires that purpose on the `op:gc-answers` path
    /// by its answer side. The tombstone remains until any racing callback and
    /// the partner's export mention are concluded. One `BiMap` holds both
    /// directions, so no half-installed link can survive. Version-neutral
    /// (`resolver_export.zig`).
    outbound_resolver_link: OutboundResolverLink,
    /// V1.0 inbound resolver link (ADR-0010): an answer-pos bound to the
    /// resolver import position we target when we send our resolution
    /// (`resolverForInboundAnswer` forward, `answerForResolverImport` reverse).
    /// One `BiMap`, pruned whole when the answer is fully released by
    /// `op:gc-answers`.
    v1_0_inbound_resolver_link: InboundResolverLink,
    /// Resolved sturdyref enlivenments, mapping a swissnum to its `(import, kind)`
    /// (ADR-0012 dedup).
    /// FIFO-evicting (cap `max_sturdyref_cache_entries`), so it keeps insertion
    /// order and owns each swissnum on the gpa — freed precisely on eviction.
    sturdyref_cache: std.ArrayList(SturdyrefCacheEntry),
    /// Side index for `sturdyref_cache`: swissnum to FIFO row index, O(1) lookup.
    /// Keys are the same owned slices the ArrayList rows hold (one owner); kept
    /// in lockstep on insert and FIFO eviction (`sturdyref_cache.zig`).
    sturdyref_cache_index: std.StringHashMapUnmanaged(usize),
    /// In-flight sturdyref enlivens, mapping a swissnum to its outstanding answer
    /// (ADR-0012 dedup). O(1) lookup; rows are removed on completion, so swissnum
    /// keys are gpa-owned and freed on removal.
    pending_enlivens: std.StringHashMapUnmanaged(model.AnswerPosition),
    /// Reverse index for `pending_enlivens`: answer to the same owned swissnum
    /// slice (borrowed, not a second owner). Kept in lockstep on insert and
    /// removal (`sturdyref_cache.zig`).
    pending_enliven_by_answer: std.AutoHashMapUnmanaged(model.AnswerPosition, []const u8),
    /// The swissnum-to-export registry the inbound-`'fetch` responder consults
    /// (ADR-0006). Keys live in `key_arena`; O(1) lookup. Never removed.
    bootstrap: std.StringHashMapUnmanaged(model.ExportPosition),

    /// Maximum receive scratch retained after a turn. The footprint and
    /// big-set scratch tests pin this bound.
    pub const steady_recv_scratch_bytes: usize = 384;

    pub const Options = lifecycle.Options;
    pub const setExportBase = lifecycle.setExportBase;
    pub const init = lifecycle.init;
    pub const initNegotiating = lifecycle.initNegotiating;
    pub const preferenceOf = lifecycle.preferenceOf;
    pub const initWith = lifecycle.initWith;
    pub const deinit = lifecycle.deinit;

    /// The version-neutral resolver-export link lives in `resolver_export.zig`;
    /// these aliases keep the call sites reading as ordinary `Session` methods
    /// while the bodies sit beside the link they operate on. The field itself
    /// stays on `Session`.
    pub const nominateResolverExport = resolver_export.nominateResolverExport;
    pub const bindFreshResolverExport = resolver_export.bindFreshResolverExport;
    pub const mintMentionedResolverExport = resolver_export.mintMentionedResolverExport;
    pub const abandonMentionedResolverExport = resolver_export.abandonMentionedResolverExport;
    pub const abandonResolverExport = resolver_export.abandonResolverExport;
    pub const abandonResolverNomination = resolver_export.abandonResolverNomination;
    pub const installOutboundResolver = resolver_export.installOutboundResolver;
    pub const removeOutboundResolver = resolver_export.removeOutboundResolver;
    pub const answerForResolverExport = resolver_export.answerForResolverExport;
    pub const retireApplicationResolver = resolver_export.retireApplicationResolver;
    pub const retiredResolverState = resolver_export.retiredResolverState;
    pub const completeRetiredResolverCallback = resolver_export.completeRetiredResolverCallback;
    pub const isNodeSettlingResolver = resolver_export.isNodeSettlingResolver;
    pub const installNodeSettlingResolver = resolver_export.installNodeSettlingResolver;
    pub const completeNodeSettlingResolverCallback = resolver_export.completeNodeSettlingResolverCallback;
    pub const retireNodeSettlingResolver = resolver_export.retireNodeSettlingResolver;
    pub const releaseRetiredResolverIfUnmentioned = resolver_export.releaseRetiredResolverIfUnmentioned;
    pub const nominateShorteningResolver = shortening.nominate;
    pub const abandonShorteningResolver = shortening.abandon;
    pub const sourceForShorteningResolver = shortening.sourceForResolver;
    pub const shorteningSourceIsHeld = shortening.sourceIsHeld;
    pub const validateShorteningCompletion = shortening.validateCompletion;
    pub const completeShortening = shortening.complete;
    pub const releaseShorteningSourceAuthority = shortening.releaseSourceAuthority;
    pub const shorteningIncarnationForImport = shortening.incarnationForImport;
    pub const releaseShorteningResolverExport = shortening.releaseResolverExport;
    pub const expandShorteningGcExportReleases = shortening.expandGcExportReleases;
    pub const rewriteShortenedMessage = shortening.rewriteMessage;
    pub const rewriteShortenedResolution = shortening.rewriteResolution;

    /// V1.0 resolver-callback translation lives in `v1_0.zig`; these aliases keep
    /// the call sites reading as ordinary `Session` methods while the bodies sit
    /// beside the rest of the V1.0 bridge. The resolver-link fields they operate
    /// on stay on `Session`.
    pub const needsV1_0Translation = v1_0.needsV1_0Translation;
    pub const validateHandoffGiftId = validate.validateHandoffGiftId;
    pub const validateSentResolutionValue = validate.validateSentResolutionValue;
    pub const mintOutboundResolver = v1_0.mintOutboundResolver;
    pub const installInboundResolver = v1_0.installInboundResolver;
    pub const resolverForInboundAnswer = v1_0.resolverForInboundAnswer;
    pub const answerForResolverImport = v1_0.answerForResolverImport;
    pub const allocateInboundAnswer = v1_0.allocateInboundAnswer;
    pub const answerTargetNamed = answer_notifications.answerTargetNamed;
    pub const answerPayloadForTarget = answer_notifications.payload;
    pub const beginAnswerSettlementNamed = answer_notifications.beginNamed;
    pub const beginAnswerSettlement = answer_notifications.begin;
    pub const validateAnswerSettlement = answer_notifications.validateSettlement;
    pub const retainAnswerPayload = answer_notifications.retainPayload;
    pub const releaseAnswerPayload = answer_notifications.releasePayload;
    pub const answerPayloadResolution = answer_notifications.resolution;
    pub const answerPayloadResolver = answer_notifications.resolver;
    pub const takeAnswerPayloadListeners = answer_notifications.takeListeners;
    pub const restoreAnswerPayloadListeners = answer_notifications.restoreListeners;
    pub const clearAnswerPayloadResolver = answer_notifications.clearResolver;
    pub const retireDetachedAnswer = answer_notifications.retireDetached;
    pub const retireVirtualAnswer = answer_notifications.retireVirtual;
    pub const prepareAnswerGc = answer_notifications.prepareGc;
    pub const commitFinalAnswerGc = answer_notifications.commitFinalGc;

    pub const recordSentResolutionTarget = protocol.recordSentResolutionTarget;

    /// The `op:start-session` handshake state lives in `handshake.zig`; these
    /// aliases keep the call sites reading as ordinary `Session` methods. The
    /// handshake fields they operate on stay on `Session`.
    pub const handshakeComplete = handshake.handshakeComplete;
    pub const awaitsPartnerHello = handshake.awaitsPartnerHello;
    pub const transitionToOpen = handshake.transitionToOpen;
    pub const partnerSessionKey = handshake.partnerSessionKey;
    pub const partnerKnownPancake = handshake.partnerKnownPancake;
    pub const statesUpgradedProfile = handshake.statesUpgradedProfile;
    pub const localSessionKey = handshake.localSessionKey;
    pub const partnerDesignator = handshake.partnerDesignator;
    pub const partnerLocatorRaw = handshake.partnerLocatorRaw;

    pub const close = protocol.close;

    /// Import/export namespace operations live together in `positions.zig`;
    /// these aliases preserve Session as the deliberate public method index.
    pub const admitExportPositionForMarshal = positions.admitExportPositionForMarshal;
    pub const validateExportPositionForMarshal = positions.validateExportPositionForMarshal;
    pub const registerExport = positions.registerExport;
    pub const reserveExport = positions.reserveExport;
    pub const registerImport = positions.registerImport;

    pub const installInboundAnswer = answer_lifecycle.installInbound;
    pub const installInboundAnswerNamed = apply.installInboundAnswerNamed;
    pub const installOutboundAnswer = answer_lifecycle.installOutbound;

    pub const admits = protocol.admits;

    pub const recordSend = protocol.recordSend;
    pub const recordSentResolutionNamed = protocol.recordSentResolutionNamed;
    pub const recordRecv = protocol.recordRecv;

    pub const recordRecvView = protocol.recordRecvView;

    pub const validateInboundDeliverView = protocol.validateInboundDeliverView;
    pub const applyValidatedInboundDeliverView = protocol.applyValidatedInboundDeliverView;
    pub const recordResolverCallbackResolve = protocol.recordResolverCallbackResolve;
    pub const validateResolverCallbackResolve = protocol.validateResolverCallbackResolve;
    pub const applyValidatedResolverCallbackResolve = protocol.applyValidatedResolverCallbackResolve;

    // Per-kind validate/apply live in `validate.zig` (the module-level
    // `validate` re-export above) and `apply.zig`; the public spine is
    // `recordSend` / `recordRecv` / `recordRecvView` / `admits`. Three
    // per-kind entry points stay public because one engine pre-step must run
    // the same rule before `recordRecv*`.
    const apply = @import("apply.zig");

    /// Validate an inbound `op:listen` before the engine installs its
    /// listener. Engine caller: `engine.pipeline.maybeInstallInboundListener`.
    pub const validateInboundListen = validate.validateInboundListen;
    /// Pre-commit rule for a locally supplied resolution bound for a store
    /// (the relayed-resolution seam). Engine caller:
    /// `engine.Peer.applyRelayedResolution`.
    pub const validateStoredResolution = validate.validateStoredResolution;
    pub const validateListenerFireTarget = validate.validateListenerFireTarget;
    /// Retain the wire mention of a sent export reference that bypasses
    /// `recordSend`. Engine caller: `engine.v1_0.prepareOutboundDeliver`.
    pub const retainSentExportRef = apply.retainSentExportRef;
    pub const ensureSentResolutionExportCapacity = apply.ensureSentResolutionExportCapacity;

    pub const commitPreparedListenerFire = protocol.commitPreparedListenerFire;

    pub const nextStoreStamp = answer_lifecycle.nextStoreStamp;

    // Read-only answer lookups live in `inspect.zig` beside the other
    // non-mutating table walks; each is presented as this Session's own.
    pub const inboundAnswer = inspect.inboundAnswer;
    pub const inboundAnswerNamed = inspect.inboundAnswerNamed;
    pub const inboundAnswerSlot = inspect.inboundAnswerSlot;
    pub const hasInboundAnswer = inspect.hasInboundAnswer;
    pub const hasInboundAnswerNamed = inspect.hasInboundAnswerNamed;
    pub const inboundAnswerRowId = inspect.inboundAnswerRowId;
    pub const inboundAnswerRowIdNamed = inspect.inboundAnswerRowIdNamed;
    pub const outboundAnswer = inspect.outboundAnswer;
    pub const outboundAnswerSlot = inspect.outboundAnswerSlot;

    pub const hasExport = positions.hasExport;
    pub const hasImport = positions.hasImport;
    pub const holdsImport = positions.holdsImport;
    pub const exportSlot = positions.exportSlot;
    pub const importSlot = positions.importSlot;
    pub const exportRefcount = positions.exportRefcount;
    pub const importRefcount = positions.importRefcount;
    pub const allocateExport = positions.allocateExport;
    pub const allocatePromiseExport = positions.allocatePromiseExport;

    pub const allocateLocalPromiseProjection = local_promise.allocate;
    pub const answerForLocalPromiseExport = local_promise.answerForExport;
    pub const isLocalPromiseAnswer = local_promise.isAnswer;
    pub const abandonLocalPromiseProjection = local_promise.abandon;
    pub const retireReleasedLocalPromiseAnswer = local_promise.retireReleased;

    pub const releaseUnsharedExport = positions.releaseUnsharedExport;
    pub const releaseImportRetain = positions.releaseImportRetain;

    pub const abandonOutboundAnswer = answer_lifecycle.abandonOutbound;
    pub const abandonUnsharedInboundAnswer = answer_lifecycle.abandonUnsharedInbound;
    pub const abandonUnsharedInboundAnswerNamed = answer_lifecycle.abandonUnsharedInboundNamed;
    pub const releaseInboundAnswerCell = answer_lifecycle.releaseInboundCell;

    pub const HostImportIdentity = ImportTable.HostIdentity;
    pub const foreignRouteIdFor = positions.foreignRouteIdFor;
    pub const noteForeignRouteId = positions.noteForeignRouteId;
    pub const abandonForeignRouteId = positions.abandonForeignRouteId;
    pub const hostCapabilityFor = positions.hostCapabilityFor;
    pub const hostImportIdentity = positions.hostImportIdentity;
    pub const noteHostCapability = positions.noteHostCapability;
    pub const claimHostCapabilityRetain = positions.claimHostCapabilityRetain;
    pub const releaseHostCapabilityRetains = positions.releaseHostCapabilityRetains;
    pub const forgetHostCapability = positions.forgetHostCapability;

    pub const durable_swiss_prefix = bootstrap_references.durable_swiss_prefix;
    pub const durable_swiss_entropy_len = bootstrap_references.durable_swiss_entropy_len;
    pub const durable_swiss_len = bootstrap_references.durable_swiss_len;
    pub const isDurableSwiss = bootstrap_references.isDurableSwiss;
    pub const registerBootstrapCap = bootstrap_references.register;
    pub const bindBootstrapCap = bootstrap_references.bind;
    pub const bootstrapLookup = bootstrap_references.lookup;
    pub const restoreBootstrapMapping = bootstrap_references.restore;

    // Pipelined calls, listeners, and projections share one answer-consequence
    // owner; Session remains their deliberate public method index.
    pub const allocateOutboundAnswer = pipeline.allocateOutboundAnswer;
    pub const reserveOutboundAnswers = pipeline.reserveOutboundAnswers;
    pub const enqueuePipelinedCall = pipeline.enqueuePipelinedCall;
    pub const enqueuePipelinedCallNamed = pipeline.enqueuePipelinedCallNamed;
    pub const takePipelinedCalls = pipeline.takePipelinedCalls;
    pub const takePipelinedCallsNamed = pipeline.takePipelinedCallsNamed;
    pub const takePipelinedListeners = pipeline.takePipelinedListeners;
    pub const takePipelinedListenersNamed = pipeline.takePipelinedListenersNamed;
    pub const requeuePipelinedCall = pipeline.requeuePipelinedCall;
    pub const installListener = pipeline.installListener;
    pub const installListenerNamed = pipeline.installListenerNamed;
    pub const installProjection = pipeline.installProjection;
    pub const installProjectionNamed = pipeline.installProjectionNamed;
    pub const takeProjections = pipeline.takeProjections;
    pub const takeProjectionsNamed = pipeline.takeProjectionsNamed;

    pub const storeResolution = answers.storeResolution;
    pub const storeResolutionNamed = answers.storeResolutionNamed;
    pub const retainedSentAnswerBytes = answers.retainedSentAnswerBytes;
    pub const peekResolution = answers.peekResolution;
    pub const peekResolutionNamed = answers.peekResolutionNamed;
    pub const answerResolved = answers.answerResolved;
    pub const answerResolvedNamed = answers.answerResolvedNamed;

    // Imported-promise metadata: third-party relay state from ADR-0009 plus the
    // next profile's shortening and settling claims. Bodies live in
    // `promises/imported.zig` and are aliased here.
    pub const installThirdPartyImport = imported_promise.installThirdPartyImport;
    pub const abandonUnsharedThirdPartyImport = imported_promise.abandonUnsharedThirdPartyImport;
    pub const isThirdPartyImport = imported_promise.isThirdPartyImport;
    pub const installImportedPromiseListener = imported_promise.installImportedPromiseListener;
    pub const recordRelayedResolution = imported_promise.recordRelayedResolution;
    pub const takeImportedPromiseListeners = imported_promise.takeImportedPromiseListeners;
    pub const restoreImportedPromiseListeners = imported_promise.restoreImportedPromiseListeners;
    pub const importedPromiseResolution = imported_promise.importedPromiseResolution;
    pub const pendingImportedPromiseFire = imported_promise.pendingImportedPromiseFire;
    pub const importedPromiseRowId = imported_promise.importedPromiseRowId;
    pub const findImportedPromise = imported_promise.findImportedPromise;
    pub const claimPromiseSettlingListener = imported_promise.claimSettlingListener;
    pub const abandonPromiseSettlingListener = imported_promise.abandonSettlingListener;
    pub const promiseSettlingAnswer = imported_promise.settlingAnswer;
    pub const promiseSettlingListenerExport = imported_promise.settlingListenerExport;
    pub const promiseSettlingNodeClaimed = imported_promise.settlingNodeClaimed;
    pub const promiseSettlingConsumerClaimed = imported_promise.settlingConsumerClaimed;
    pub const discardUnconsumedPromiseSettlingListener = imported_promise.discardUnconsumedSettlingListener;
    pub const detachPromiseSettlingNodeConsumer = imported_promise.detachSettlingNodeConsumer;
    pub const promiseSettlingFollowersForAnswer = imported_promise.settlingFollowersForAnswer;
    pub const validatePromiseSettlingFollowers = imported_promise.validateSettlingFollowers;
    pub const applyPromiseSettlingFollowers = imported_promise.applySettlingFollowers;
    pub const takePromiseSettlingFollowers = imported_promise.takeSettlingFollowers;
    pub const unlinkPromiseSettlingAnswer = imported_promise.unlinkSettlingAnswer;
    pub const promiseSettlingListenerClaimed = imported_promise.settlingListenerClaimed;
    pub const preparePromiseSettlingMove = imported_promise.prepareSettlingMove;
    pub const commitPromiseSettlingMove = imported_promise.commitSettlingMove;
    pub const shortenedPromiseTarget = imported_promise.shortenedTarget;

    // Sturdyref-enliven dedup (ADR-0012): the resolved-enlivenment cache and the
    // in-flight enliven set. Bodies live in `sturdyref_cache.zig`; aliased here
    // so `sess.cacheSturdyrefEnlivenment(...)` still resolves.
    pub const sturdyrefCacheLookup = sturdyref_cache.sturdyrefCacheLookup;
    pub const cacheSturdyrefEnlivenment = sturdyref_cache.cacheSturdyrefEnlivenment;
    pub const pendingEnlivenAnswer = sturdyref_cache.pendingEnlivenAnswer;
    pub const pendingEnlivenSwissnum = sturdyref_cache.pendingEnlivenSwissnum;
    pub const notePendingEnliven = sturdyref_cache.notePendingEnliven;
    pub const finishPendingEnliven = sturdyref_cache.finishPendingEnliven;
    pub const settlePendingEnlivenIntoCache = sturdyref_cache.settlePendingEnlivenIntoCache;
    pub const forgetSturdyrefEnlivenmentsAt = sturdyref_cache.forgetSturdyrefEnlivenmentsAt;
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

/// Release the listen cell an `ImportedPromise` holds (host is `key_arena`-interned).
/// Body in `promises/imported.zig`.
pub const deinitImportedPromise = imported_promise.deinitImportedPromise;
