//! The authoritative state for one CapTP session.
//!
//! `Session` owns the export, import, answer, handshake, pipelining, GC,
//! handoff, and sturdyref tables for one direct conversation. `recordSend` and
//! `recordRecv*` are the validate-then-apply state-machine entries. Codecs and
//! adapters only move bytes.
//!
//! The layout favors O(1) position lookups and short-lived receive scratch.
//! `docs/architecture.md` and the memory rule carry the wider derivation.

const std = @import("std");
const foundation = @import("foundation");
const model = @import("model");
const answers = @import("answers/store.zig");
const resolution_store = @import("answers/resolution_store.zig");
const answer_notifications = @import("answers/notifications.zig");
const export_table = @import("export_table.zig");
const import_table = @import("import_table.zig");
pub const slot = @import("slot.zig");
const sturdyref_cache = @import("sturdyref_cache.zig");
const imported_promise = @import("promises/imported.zig");
const local_promise = @import("local_promise.zig");
const gc = @import("gc.zig");
const resolver_export = @import("resolver_export.zig");
const shortening = @import("shortening.zig");
const v1_0 = @import("v1_0.zig");
const deliver_resolver = @import("deliver_resolver.zig");
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
/// `engine.inbound.dispatchOwnedFrame`) can name `validate.IntroducedImports`
/// without reaching past this module into `session/validate.zig` directly.
pub const validate = @import("validate.zig");
pub const inventory = @import("inventory.zig");
pub const Inventory = inventory.Inventory;
pub const Freight = @import("validate/freight.zig").Freight;
pub const id_route = @import("id_route.zig");
pub const parsePreferenceHints = validate.parsePreferenceHints;

/// Position-keyed wire-delta refcount tables, one per allocator: a slab over
/// the positions we mint (`export_table`) and a hashed table over the
/// partner's (`import_table` explains why partner-controlled positions
/// cannot use a raw index vector), in distinct types so the
/// cap that bounds partner-driven imports is a property of `ImportTable`, not a
/// rule each call site must restate.
const ExportTable = export_table.ExportTable;
const ImportTable = import_table.ImportTable;

/// Error set for the borrowed-view recv walkers: session authority errors plus
/// the lazy projection errors a codec-backed `model.view.Args` can raise while
/// walking. Named explicitly so the mutually-recursive argument walkers don't
/// form an inferred-error-set dependency loop.
pub const RecvViewError = Error || model.view.ProjectError || std.mem.Allocator.Error;

pub const Error = @import("errors.zig").Error;

/// The fixed bootstrap export position installed when a session reaches `open`
/// (ADR-0002). An inbound `op:deliver` to `<desc:export 0>` with method
/// `'fetch` is the bootstrap-fetch entry point. The initiator side lives in
/// `engine.fetch`. The inbound-`'fetch` responder lives in `engine.bootstrap`,
/// not the session.
///
/// Position 0 is pinned outside wire-delta GC in both directions: it is never
/// retained by send-side export accounting, an inbound
/// `op:gc-exports` naming it is a no-op skip (`checkGcExportDecrement` /
/// `applyGcExportDecrement`), and an outbound one is refused
/// (`validateSend`). The bootstrap export therefore lives as long as
/// the session.
pub const bootstrap_position: u64 = 0;

pub const PromiseIncarnation = promise_types.PromiseIncarnation;
pub const RetiredResolverState = promise_types.RetiredResolverState;
pub const RetiredResolver = promise_types.RetiredResolver;
pub const ResolverPurpose = promise_types.ResolverPurpose;
pub const ShorteningNomination = shortening.Nomination;
pub const SettlingMovePlan = imported_promise.SettlingMovePlan;
/// `promise_types` documents the inbound resolver link and the purposes an
/// export row carries.
const InboundResolverLink = promise_types.InboundResolverLink;

pub const State = enum {
    negotiating,
    open,
    closed,
};

/// Resource bounds a session enforces against a partner. Defined in
/// `limits.zig`. Aliased here so call sites keep reading `session.SessionLimits`.
pub const SessionLimits = limits.SessionLimits;

/// Which answer table an install targets. Inbound rows and detached accepted
/// consequences share `SessionLimits.max_inbound_answers`. Outbound rows are
/// positions we allocate ourselves, bounded by our own sends, so they carry no
/// cap.
pub const AnswerStatus = answers.AnswerStatus;
pub const pendingInboundSlot = answers.pendingInboundSlot;
pub const answerSlot = answers.answerSlot;
pub const AnswerCell = answers.AnswerCell;
pub const QueuedCall = answers.QueuedCall;
pub const AnswerPayload = answers.AnswerPayload;
pub const AnswerTarget = answers.AnswerTarget;
pub const OutboundAnswerTarget = answers.OutboundAnswerTarget;
pub const PositionSlab = @import("position_slab.zig").PositionSlab;
pub const StoredResolution = answers.StoredResolution;
pub const ListenerEntry = answers.ListenerEntry;
pub const Projection = answers.Projection;
pub const ProjectionKind = answers.ProjectionKind;
pub const ProjectionIndex = answers.ProjectionIndex;
pub const deinitProjection = answers.deinitProjection;
pub const PreparedPipelinedCallQueue = pipeline.PreparedCallQueue;
pub const InboundAnswerTable = answers.InboundAnswerTable;
pub const OutboundAnswerTable = answers.OutboundAnswerTable;

pub const inspect = @import("inspect.zig");
pub const ExportView = inspect.ExportView;
pub const ImportView = inspect.ImportView;
pub const AnswerRowView = inspect.AnswerRowView;

pub const ImportedPromise = promise_types.ImportedPromise;

/// Supported alias for the row owned by `sturdyref_cache.zig`.
pub const SturdyrefCacheEntry = sturdyref_cache.Entry;
pub const PreparedDeliveryResolver = deliver_resolver.Prepared;

pub const Session = struct {
    allocator: std.mem.Allocator,
    state: State,
    /// The active profile with `codec`: what the handshake settled, not what
    /// either side asked for. Holds the preference until a partner's hello
    /// settles it.
    captp_version: model.CaptpVersion,
    /// The wire codec negotiated for this direct session. The
    /// authoritative record of the codec choice. The engine's codec-dispatch
    /// boundary (`codec.dispatch`) reads it to route each frame, and every event
    /// the session produces is tagged with it. Defaults to `.syrup` for the
    /// non-negotiating constructors.
    codec: model.CodecId,
    /// What this side asked for, and what the partner asked for: the two
    /// inputs `engine.negotiation.settle` reads to produce the active profile
    /// above. Both are a whole `model.Preference` rather than loose fields,
    /// because they are the same kind of thing and every reader wants them
    /// whole, a decomposed side would be rebuilt at each use site.
    ///
    /// Kept beside the active values rather than folded into them because
    /// they answer a different question. The active pair is a property of the
    /// two peers. These are properties of one peer each, and they are what
    /// answers "why is this session on the baseline". The hello advertises
    /// `preferred`, but the transport may lower what it signs. Both
    /// facts survive the settle that overwrites the active values, including
    /// `features`.
    preferred: model.Preference,
    /// What this side's own `op:start-session` stated on the wire, or the
    /// baseline until that half is sent.
    local_preference: model.Preference = model.Preference.baseline,
    /// The partner's, or the baseline before its hello has arrived. The
    /// session records the claim. The engine decides with it.
    partner_preference: model.Preference = model.Preference.baseline,
    /// Whether this partner is known to be glowcap before our hello states a
    /// preference, which on onion is the licence to state one at all
    /// (ADR-0042). The engine mints it at exactly two seams, and the pinned
    /// Goblins onion netlayer can produce neither: a dial handed a
    /// `glowcap/*`-hinted locator (`Peer.noteKnownGlowcapPartner`), and a
    /// deferred onion accept whose inbound hello stated a non-baseline
    /// preference (`Peer.answerDeferredHello`).
    partner_known_glowcap: bool = false,
    features: model.FeatureSet,
    limits: SessionLimits,
    /// Virtual answers allocated by V1.0 resolver-only fetches (the partner sent
    /// `resolve_me_desc` with no `answer_position`). This counter belongs to a
    /// typed namespace disjoint from every partner-selected wire answer.
    next_virtual_inbound_answer: u64 = 1,
    /// Bump arena for monotonic byte keys: bootstrap swissnums, handshake bytes,
    /// and interned third-party host designators. Churned rows stay on the gpa.
    key_arena: std.heap.ArenaAllocator,
    /// Per-turn arena for recv validation and temporary owned fallbacks. Recv
    /// entry points reset it. Apply dupes anything session-lived onto `allocator`.
    recv_scratch: std.heap.ArenaAllocator,
    exports: ExportTable,
    imports: ImportTable,
    inbound_answers: InboundAnswerTable,
    outbound_answers: OutboundAnswerTable,
    /// Lazy store for notification obligations whose partner-owned
    /// pipelining name has been GC'd and may already have been reused. Null in
    /// the steady state. Rows are keyed by the session's monotonic row stamp.
    detached_inbound_answers: ?*answers.DetachedAnswerStore = null,
    local_promises: ?*local_promise.Registry = null,
    /// Owned bytes in resolutions retained by sent inbound-answer rows. This
    /// durable store has its own Session limit. Transient outbound flow
    /// accounting ends when a settlement moves here. Answer GC, local-promise
    /// retirement, and teardown release the exact charge.
    retained_sent_answer_bytes: usize = 0,
    /// Owned bytes in pipelined calls queued against pending inbound answers,
    /// bounded by `limits.max_queued_call_bytes`. A drain or a payload release
    /// returns each call's exact charge. `u32` like its limit.
    queued_call_bytes: u32 = 0,
    import_release_outbox: ?*@import("import_release_outbox.zig").Outbox = null,
    /// Promises imported from a third party via handoff (ADR-0039), keyed by
    /// import position for O(1) lookup. Host designators are interned in
    /// `key_arena`. Each row owns its listen cell and stored relayed resolution.
    imported_promises: foundation.identity_hash.MapOf(.wire, model.ImportPosition, ImportedPromise),
    /// The secret every table keyed by positions the peer chooses hashes
    /// under (ADR-0037). A Node hands one to each session at registration,
    /// through `keyWireTables`, and each such table carries a copy because
    /// its verbs run without the session in hand.
    wire_hash_multiplier: u64,
    /// The secret the tables keyed by names the peer chooses (`bootstrap`,
    /// `sturdyref_cache_index`) hash under, handed to each verb because
    /// `foundation.bearer_table` stores none (ADR-0037). Its own derivation,
    /// never the position multiplier, so neither table's buckets tell a peer
    /// about the other's.
    bearer_secret: u64,
    /// Session-wide monotonic source for every store-row identity stamp a
    /// queued fire carrier checks at encode: `AnswerCell.row_id` and
    /// `ImportedPromise.row_id`. One counter for all (not per-row seeds) so no
    /// two row instances ever share a value, a carrier stamped against a row
    /// since released and re-registered at the same position must miss, never
    /// false-match.
    store_stamp_counter: u64 = 0,
    /// Whether this side has sent its `op:start-session` half (ADR-0002).
    handshake_local_sent: bool,
    /// Whether the partner's `op:start-session` half has been observed.
    handshake_remote_received: bool,
    /// The partner's session public key, learned from its `op:start-session`. The
    /// session keeps it as opaque bytes in `key_arena` (it runs no crypto). An
    /// embedder reads it to verify the partner's signatures, for example, the
    /// gifter's `desc:handoff-give` when this is a gifter-to-exporter session
    /// (ADR-0039). Empty until the partner's handshake half arrives with a key.
    partner_session_key: []const u8 = &.{},
    /// This side's own session public key, learned from the `op:start-session`
    /// half we sent. Kept as opaque bytes in `key_arena` beside the partner's,
    /// for the one job that needs to know who *we* are on this session: an
    /// exporter deriving the session name a `desc:handoff-receive` must carry
    /// (ADR-0039), so a withdrawal cannot name a session it does not belong to.
    /// Empty on an unkeyed session, which is also every session on which no
    /// handoff can be redeemed.
    local_session_key: []const u8 = &.{},
    /// The partner's location designator from its `op:start-session`. When
    /// `partner_acceptable_location_raw` is set, this is a view into that
    /// buffer. Otherwise a designator-only arena dupe (owned-message apply).
    /// Empty until the handshake half arrives.
    partner_designator: []const u8 = &.{},
    /// The partner's verbatim `<ocapn-peer ...>` location-record bytes, as
    /// they arrived on its `op:start-session`. Sole owner of peer-location
    /// content on the decode path (`partner_designator` views into it). A gifter
    /// embeds these in a `desc:handoff-give`'s exporter-location so a peer
    /// comparing the give's location to the session's matches byte-for-byte
    /// (ADR-0039). Empty until the partner's handshake half arrives with raw
    /// bytes (owned-message apply has none). Lives in `key_arena`.
    partner_acceptable_location_raw: []const u8 = &.{},
    /// V1.0 inbound resolver link (ADR-0006): an answer-pos bound to the
    /// resolver import position we target when we send our resolution
    /// (`resolverForInboundAnswer` forward, `answerForResolverImport` reverse).
    /// One `BiMap`, pruned whole when the answer is fully released by
    /// `op:gc-answers`.
    v1_0_inbound_resolver_link: InboundResolverLink,
    /// Resolved sturdyref enlivenments, mapping a swissnum to its `(import, kind)`
    /// (ADR-0007 dedup).
    /// FIFO-evicting (cap `max_sturdyref_cache_entries`), with inline row links
    /// preserving insertion order through dense removal. Owns each swissnum on
    /// the gpa, freed on eviction.
    sturdyref_cache: std.ArrayList(SturdyrefCacheEntry),
    /// Side index for `sturdyref_cache`: swissnum to dense row index, O(1) lookup.
    /// Keys are the same owned slices the ArrayList rows hold (one owner). Kept
    /// in lockstep on insert and FIFO eviction (`sturdyref_cache.zig`).
    sturdyref_cache_index: foundation.bearer_table.Table(usize),
    /// In-flight sturdyref enlivens, mapping a swissnum to its outstanding answer
    /// (ADR-0007 dedup). O(1) lookup. Rows are removed on completion, so swissnum
    /// keys are gpa-owned and freed on removal.
    pending_enlivens: std.StringHashMapUnmanaged(model.AnswerPosition),
    /// Reverse index for `pending_enlivens`: answer to the same owned swissnum
    /// slice (borrowed, not a second owner). Kept in lockstep on insert and
    /// removal (`sturdyref_cache.zig`).
    pending_enliven_by_answer: foundation.identity_hash.Map(model.AnswerPosition, []const u8),
    /// The swissnum-to-export registry the inbound-`'fetch` responder consults
    /// (ADR-0002). Keys live in `key_arena`, O(1) lookup, compared in constant
    /// time because the name looked up is the partner's guess. Never removed.
    bootstrap: foundation.bearer_table.Table(model.ExportPosition),

    /// Maximum receive scratch retained after a turn. The footprint and
    /// big-set scratch tests pin this bound.
    pub const steady_recv_scratch_bytes: usize = 384;

    pub const Options = lifecycle.Options;
    pub const setExportBase = lifecycle.setExportBase;
    pub const init = lifecycle.init;
    pub const initNegotiating = lifecycle.initNegotiating;
    pub const preferenceOf = lifecycle.preferenceOf;
    pub const initWith = lifecycle.initWith;
    pub const keyWireTables = lifecycle.keyWireTables;
    pub const deinit = lifecycle.deinit;

    /// The version-neutral resolver-export link lives in `resolver_export.zig`.
    /// These aliases keep the call sites reading as ordinary `Session` methods
    /// while the bodies sit beside the link they operate on. The field itself
    /// stays on `Session`.
    pub const nominateResolverExport = resolver_export.nominateResolverExport;
    pub const mintMentionedResolverExport = resolver_export.mintMentionedResolverExport;
    pub const abandonMentionedResolverExport = resolver_export.abandonMentionedResolverExport;
    pub const abandonResolverExport = resolver_export.abandonResolverExport;
    pub const abandonResolverNomination = resolver_export.abandonResolverNomination;
    pub const bindFreshResolverExport = resolver_export.bindFreshResolverExport;
    pub const installOutboundResolver = resolver_export.installOutboundResolver;
    pub const resolverPurpose = resolver_export.resolverPurpose;
    pub const resolverExportForAnswer = resolver_export.resolverExportForAnswer;
    pub const replaceResolverPurpose = resolver_export.replaceResolverPurpose;
    pub const removeOutboundResolver = resolver_export.removeOutboundResolver;
    pub const answerForResolverExport = resolver_export.answerForResolverExport;
    pub const retireApplicationResolver = resolver_export.retireApplicationResolver;
    pub const retiredResolverState = resolver_export.retiredResolverState;
    pub const completeRetiredResolverCallback = resolver_export.completeRetiredResolverCallback;
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
    pub const expandSessionGcExportReleases = shortening.expandSessionGcExportReleases;
    pub const rewriteShortenedMessage = shortening.rewriteMessage;
    pub const rewriteShortenedResolution = shortening.rewriteResolution;
    pub const certifyFreight = @import("validate/freight.zig").certifyFreight;

    /// V1.0 resolver-callback translation lives in `v1_0.zig`. These aliases keep
    /// the call sites reading as ordinary `Session` methods while the bodies sit
    /// beside the rest of the V1.0 bridge. The resolver-link fields they operate
    /// on stay on `Session`.
    pub const needsV1_0Translation = v1_0.needsV1_0Translation;
    pub const requireNegotiatedLocator = validate.requireNegotiatedLocator;
    pub const parseNegotiatedIdLocator = validate.parseNegotiatedIdLocator;
    pub const validateHandoffGiftId = validate.validateHandoffGiftId;
    pub const validateSentResolutionValue = validate.validateSentResolutionValue;
    pub const mintOutboundResolver = v1_0.mintOutboundResolver;
    pub const installInboundResolver = v1_0.installInboundResolver;
    pub const prepareInboundResolver = v1_0.prepareInboundResolver;
    pub const resolverForInboundAnswer = v1_0.resolverForInboundAnswer;
    pub const answerForResolverImport = v1_0.answerForResolverImport;
    pub const prepareDeliveryResolver = deliver_resolver.prepare;
    pub const allocateInboundAnswer = deliver_resolver.allocateInboundAnswer;
    pub const answerTargetNamed = answer_notifications.answerTargetNamed;
    pub const answerPayloadForTarget = answer_notifications.payload;
    pub const inboundAnswerObligationCount = answer_notifications.obligationCount;
    pub const beginAnswerSettlementNamed = answer_notifications.beginNamed;
    pub const beginAnswerSettlement = answer_notifications.begin;
    pub const validateAnswerSettlement = answer_notifications.validateSettlement;
    pub const retainAnswerPayload = answer_notifications.retainPayload;
    pub const releaseAnswerPayload = answer_notifications.releasePayload;
    pub const returnReleasedCharges = answer_notifications.returnReleasedCharges;
    pub const answerPayloadResolution = answer_notifications.resolution;
    pub const answerPayloadStoredResolution = answer_notifications.storedResolution;
    pub const answerPayloadResolver = answer_notifications.resolver;
    pub const takeAnswerPayloadListeners = answer_notifications.takeListeners;
    pub const restoreAnswerPayloadListeners = answer_notifications.restoreListeners;
    pub const clearAnswerPayloadResolver = answer_notifications.clearResolver;
    pub const retireDetachedAnswer = answer_notifications.retireDetached;
    pub const retireVirtualAnswer = answer_notifications.retireVirtual;
    pub const releaseAnswerCarrier = answer_notifications.releaseCarrier;

    /// Whether a stored-result import release is waiting to leave.
    pub fn hasImportRelease(self: *const Session) bool {
        const outbox = self.import_release_outbox orelse return false;
        return outbox.head != null;
    }
    pub const prepareAnswerGc = answer_notifications.prepareGc;
    pub const commitFinalAnswerGc = answer_notifications.commitFinalGc;

    pub const recordSentResolutionTarget = protocol.recordSentResolutionTarget;

    /// The `op:start-session` handshake state lives in `handshake.zig`. These
    /// aliases keep the call sites reading as ordinary `Session` methods. The
    /// handshake fields they operate on stay on `Session`.
    pub const handshakeComplete = handshake.handshakeComplete;
    pub const awaitsPartnerHello = handshake.awaitsPartnerHello;
    pub const transitionToOpen = handshake.transitionToOpen;
    pub const partnerSessionKey = handshake.partnerSessionKey;
    pub const partnerKnownGlowcap = handshake.partnerKnownGlowcap;
    pub const statesUpgradedProfile = handshake.statesUpgradedProfile;
    pub const localSessionKey = handshake.localSessionKey;
    pub const partnerDesignator = handshake.partnerDesignator;
    pub const partnerLocatorRaw = handshake.partnerLocatorRaw;

    pub const close = protocol.close;

    /// Import/export namespace operations live together in `positions.zig`.
    /// These aliases preserve Session as the deliberate public method index.
    pub const validateExportPositionForMarshal = positions.validateExportPositionForMarshal;
    pub const registerExport = positions.registerExport;
    pub const reserveExport = positions.reserveExport;
    pub const registerImport = positions.registerImport;
    pub const retainImportForSession = positions.retainImportForSession;
    pub const adoptImportRetain = positions.adoptImportRetain;
    pub const listenerRetainHeld = positions.listenerRetainHeld;
    pub const importRequiresWireRelease = positions.importRequiresWireRelease;

    pub const installInboundAnswer = answer_lifecycle.installInbound;
    pub const installInboundAnswerNamed = apply.installInboundAnswerNamed;
    pub const prepareFreshInboundAnswerNamed = answer_lifecycle.prepareFreshInboundNamed;
    pub const commitFreshInboundAnswerNamed = answer_lifecycle.commitFreshInboundNamed;
    pub const installOutboundAnswer = apply.installOutboundAnswer;

    pub const admits = protocol.admits;

    pub const recordSend = protocol.recordSend;
    pub const recordSendInventoried = protocol.recordSendInventoried;
    pub const inventoryMessage = inventory.ofMessage;
    pub const inventoryResolution = inventory.ofResolution;
    pub const inventoryArguments = inventory.ofArguments;
    pub const retractSend = protocol.retractSend;
    pub const validateSendInventoried = protocol.validateSendInventoried;
    pub const applyValidatedSend = protocol.applyValidatedSend;
    pub const listSentExports = apply.listSentExports;
    pub const retractPreparedListen = protocol.retractPreparedListen;
    pub const recordPreparedSend = protocol.recordPreparedSend;
    pub const recordSessionImportRelease = protocol.recordSessionImportRelease;
    pub const recordSentResolutionNamed = protocol.recordSentResolutionNamed;
    pub const recordRecv = protocol.recordRecv;

    pub const recordRecvView = protocol.recordRecvView;

    pub const validateInboundDeliverView = protocol.validateInboundDeliverView;
    pub const prepareValidatedInboundDeliver = protocol.prepareValidatedInboundDeliver;
    pub const prepareIntroducedImports = protocol.prepareIntroducedImports;
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
    pub const validateListenerFireTarget = validate.validateListenerFireTarget;
    /// Retain the wire mention of one sent export reference, the step
    /// `recordSend` takes per reference.
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
    pub const outboundAnswerTarget = inspect.outboundAnswerTarget;
    pub const hasLiveOutboundAnswer = inspect.hasLiveOutboundAnswer;
    pub const outboundAnswerReleaseClaimed = inspect.outboundAnswerReleaseClaimed;
    pub const outboundAnswerSlot = inspect.outboundAnswerSlot;

    pub const hasExport = positions.hasExport;
    pub const hasImport = positions.hasImport;
    pub const holdsImport = positions.holdsImport;
    pub const exportSlot = positions.exportSlot;
    pub const exportReference = positions.exportReference;
    pub const exportRefcount = positions.exportRefcount;
    pub const importRefcount = positions.importRefcount;
    pub const importReleasable = positions.importReleasable;
    pub const allocateExport = positions.allocateExport;
    pub const allocatePromiseExport = positions.allocatePromiseExport;
    pub const allocateExportMentioned = positions.allocateExportMentioned;

    pub const LocalPromiseProjection = local_promise.Projection;
    pub const allocateLocalPromiseProjection = local_promise.allocate;
    pub const answerForLocalPromiseExport = local_promise.answerForExport;
    pub const LocalPromiseCustody = local_promise.Custody;
    pub const abandonLocalPromiseProjection = local_promise.abandon;
    pub const deferLocalPromiseSettlement = local_promise.deferSettlement;
    pub const deferredLocalPromiseSettlement = local_promise.deferredSettlement;
    pub const clearDeferredLocalPromiseSettlement = local_promise.clearDeferredSettlement;
    pub const collectLocalPromiseProjections = local_promise.collect;
    pub const releaseUnsharedExport = positions.releaseUnsharedExport;
    pub const releaseImportRetain = positions.releaseImportRetain;
    pub const releaseSessionImportRetain = positions.releaseSessionImportRetain;

    pub const abandonOutboundAnswer = answer_lifecycle.abandonOutbound;
    pub const claimOutboundAnswerRelease = answer_lifecycle.claimOutboundRelease;
    pub const consumeOutboundAnswerNotification = answer_lifecycle.consumeOutboundNotification;
    pub const releaseOutboundAnswer = answer_lifecycle.releaseOutbound;
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
    pub const bootstrapLookup = bootstrap_references.lookup;
    pub const restoreBootstrapMapping = bootstrap_references.restore;

    // Pipelined calls, listeners, and projections share one answer-consequence
    // owner; Session remains their deliberate public method index.
    pub const allocateOutboundAnswer = pipeline.allocateOutboundAnswer;
    pub const enqueuePipelinedCall = pipeline.enqueuePipelinedCall;
    pub const preparePipelinedCallNamed = pipeline.preparePipelinedCallNamed;
    pub const enqueuePipelinedCallTarget = pipeline.enqueuePipelinedCallTarget;
    pub const takePipelinedCalls = pipeline.takePipelinedCalls;
    pub const takeAnswerPayloadCalls = pipeline.takePayloadCalls;
    pub const takePipelinedListeners = pipeline.takePipelinedListeners;
    pub const takePipelinedListenersNamed = pipeline.takePipelinedListenersNamed;
    pub const installListener = pipeline.installListener;
    pub const installListenerNamed = pipeline.installListenerNamed;
    pub const PreparedListenerBatch = pipeline.PreparedListenerBatch;
    pub const prepareListenerBatchTarget = pipeline.prepareListenerBatchTarget;
    pub const installProjection = pipeline.installProjection;
    pub const installProjectionTarget = pipeline.installProjectionTarget;
    pub const takeAnswerPayloadProjections = pipeline.takePayloadProjections;

    pub const storeResolution = resolution_store.storeResolution;
    pub const storeResolutionNamed = resolution_store.storeResolutionNamed;
    pub const retainedSentAnswerBytes = resolution_store.retainedSentAnswerBytes;
    pub const peekResolution = resolution_store.peekResolution;
    pub const peekResolutionNamed = resolution_store.peekResolutionNamed;
    pub const peekStoredResolutionNamed = resolution_store.peekStoredResolutionNamed;
    pub const promiseTargetForResolution = local_promise.targetForResolution;
    pub const answerResolved = resolution_store.answerResolved;
    pub const answerResolvedNamed = resolution_store.answerResolvedNamed;

    // Imported-promise metadata: the next profile's shortening and settling
    // claims. Bodies live in `promises/imported.zig` and are aliased here.
    pub const findImportedPromise = imported_promise.findImportedPromise;
    pub const claimPromiseSettlingListener = imported_promise.claimSettlingListener;
    pub const abandonPromiseSettlingListener = imported_promise.abandonSettlingListener;
    pub const promiseSettlingAnswer = imported_promise.settlingAnswer;
    pub const promiseSettlingListenerExport = imported_promise.settlingListenerExport;
    pub const promiseSettlingNodeClaimed = imported_promise.settlingNodeClaimed;
    pub const promiseSettlingConsumerClaimed = imported_promise.settlingConsumerClaimed;
    pub const discardUnconsumedPromiseSettlingListener = imported_promise.discardUnconsumedSettlingListener;
    pub const detachPromiseSettlingNodeConsumer = imported_promise.detachSettlingNodeConsumer;
    pub const validatePromiseSettlingFollowers = imported_promise.validateSettlingFollowers;
    pub const applyPromiseSettlingFollowers = imported_promise.applySettlingFollowers;
    pub const takePromiseSettlingFollowers = imported_promise.takeSettlingFollowers;
    pub const unlinkPromiseSettlingAnswer = imported_promise.unlinkSettlingAnswer;
    pub const promiseSettlingListenerClaimed = imported_promise.settlingListenerClaimed;
    pub const preparePromiseSettlingMove = imported_promise.prepareSettlingMove;
    pub const commitPromiseSettlingMove = imported_promise.commitSettlingMove;
    pub const shortenedPromiseTarget = imported_promise.shortenedTarget;

    /// The position the partner keys a promise by: on next the shortened
    /// target of the import, otherwise the import itself.
    pub fn promiseWirePosition(self: *Session, import_position: model.ImportPosition) model.ImportPosition {
        return if (self.captp_version == .next) self.shortenedPromiseTarget(import_position) else import_position;
    }

    // Sturdyref-enliven dedup (ADR-0007): the resolved-enlivenment cache and the
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

// Wire-delta GC accounting and structural well-formedness checks (ADR-0004):
// stateless free functions over the tables/messages they validate. Bodies live
// in `gc.zig`; re-exported here so `session.checkGcExportDecrement` still
// resolves from the validate/apply spine.
pub const checkGcExportDecrement = gc.checkGcExportDecrement;
pub const applyGcExportDecrement = gc.applyGcExportDecrement;
pub const checkGcAnswerDecrement = gc.checkGcAnswerDecrement;
pub const validateGcExport = gc.validateGcExport;
pub const validateHandoffWellFormed = gc.validateHandoffWellFormed;

/// Release what an `ImportedPromise` row owns. Body in `promises/imported.zig`.
pub const deinitImportedPromise = imported_promise.deinitImportedPromise;
pub const ForwardedReply = @import("forwarding.zig").ForwardedReply;
pub const ImportRelease = @import("import_release_outbox.zig").Batch;
