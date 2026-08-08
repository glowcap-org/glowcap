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
pub const slot = @import("slot.zig");
const sturdyref_cache = @import("sturdyref_cache.zig");
const imported_promise = @import("imported_promise.zig");
const gc = @import("gc.zig");
const resolver_export = @import("resolver_export.zig");
const shortening = @import("shortening.zig");
const v1_0 = @import("v1_0.zig");
const bimap = @import("bimap.zig");
const handshake = @import("handshake.zig");
const limits = @import("limits.zig");

/// Re-exported so a caller that must keep the recv-turn's introduced-import
/// record alive across validate and apply (`validateInboundDeliverView`'s caller,
/// `engine.inbound.applyDecodedOwnedFrame`) can name `validate.IntroducedImports`
/// without reaching past this module into `session/validate.zig` directly.
pub const validate = @import("validate.zig");

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
    /// A caller-chosen mutable bootstrap name lies inside the reserved
    /// durable swiss namespace (ADR-0098); only the Host's durable mint may
    /// produce such names.
    ReservedDurableNamespace,
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
    /// A `desc:handoff-receive` named a receiving session or side that is not
    /// the one derived from the give's recipient key and this node's own
    /// session key. The receiving `Peer` owns one scalar replay guard, so these
    /// names are checked against the live session derivation rather than trusted
    /// from the wire (ADR-0009).
    InvalidHandoffSession,
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
    /// match this session's negotiated `model.CaptpVersion` version.
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
    /// The session's deposited-gift table (`engine.bootstrap.GiftRegistry`) exceeded
    /// `SessionLimits.max_deposited_gifts` — the load-bearing bound against
    /// deposit-without-withdraw (ADR-0025).
    DepositedGiftCapExceeded,
    /// The parked-withdraw table exceeded `SessionLimits.max_pending_withdraws`
    /// — the bound against a partner flooding `withdraw-gift`s whose deposits
    /// never arrive (each parks until its gift is deposited, ADR-0100).
    PendingWithdrawCapExceeded,
    /// An inbound argument tree nested deeper than
    /// `SessionLimits.max_nesting_depth`. The recursive validate / install walk
    /// is bounded so a malicious deeply-nested frame fails loud instead of
    /// overflowing the native stack. Projects to `resource_exhausted`.
    NestingTooDeep,
    /// One inbound message asked for more equality-comparison work than
    /// `SessionLimits.max_compare_visits` allows. Comparing two sets is
    /// comparing two multisets, so a pair of equal-hashed wide sets costs on
    /// the order of the square of their width, and the commutative set hash
    /// lets a partner construct that pair. The bound is what keeps a single
    /// frame from buying unbounded CPU. Projects to `resource_exhausted`.
    CompareBudgetExhausted,
    /// This session handed out every export position in the range its host
    /// gave it. The range is what keeps one session's capabilities from
    /// naming another's, so walking past it is refused rather than allowed to
    /// alias. Projects to `resource_exhausted`.
    ExportRangeExhausted,
    /// A set argument carried two Equal elements. A set admits each member
    /// once, so a duplicate is a second wire encoding of one value and is
    /// refused rather than admitted: inbound as the codec-neutral twin of the
    /// Syrup decoder's ascending-element byte refusal (projects to
    /// `protocol_error`), and on send pre-commit, before `retainSentExports`
    /// records wire deltas. The send fold is at least as strict as the
    /// encoders' byte-level refusal (ADR-0003): Equal-but-byte-distinct
    /// forms refuse only in validation, matching the inbound rule. The
    /// relayed-resolution store holds the same rule pre-commit
    /// (`validateStoredResolution`).
    DuplicateSetElement,
    /// A send-side struct argument carried two entries with the same key.
    /// Same contract as `DuplicateSetElement`'s send arm: the canonical-order
    /// encoders refuse the duplicate anyway, so validation refuses it before
    /// any authority commits. Inbound duplicates never reach the session:
    /// both codecs refuse non-ascending keys at decode.
    DuplicateStructKey,
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
/// resolver-only fetch pattern). An inbound claim at or above it is refused
/// (`Error.InvalidReference`); the refusal classifies through
/// `model.AnswerName`, never a re-typed compare.
///
/// The value lives with the space it partitions, in `model/position.zig`,
/// beside `model.AnswerName` which is the only thing that reads it directly.
/// Two declarations of one boundary is the drift this re-export prevents.
pub const VIRTUAL_INBOUND_ANSWER_BASE: u64 = model.VIRTUAL_INBOUND_ANSWER_BASE;

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
///
/// The value lives with the space it partitions, in `model/position.zig`,
/// beside `model.ImportName` which is the only thing that reads it directly.
/// Two declarations of one boundary is the drift this re-export prevents.
pub const REDEEMED_TOKEN_BASE: u64 = model.REDEEMED_TOKEN_BASE;

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
pub const PromiseIncarnation = struct {
    position: model.ImportPosition,
    row_id: u64,
};

pub const RetiredResolverState = enum {
    pending,
    complete,
};

/// Resolver export whose application answer is gone while the partner may
/// still hold or invoke its wire mention. The export position in the value
/// keeps retired purposes unique in the resolver `BiMap`.
pub const RetiredResolver = struct {
    resolver_export: model.ExportPosition,
    settling_source: ?PromiseIncarnation = null,
    state: RetiredResolverState,
};

pub const NodeSettlingResolver = struct {
    resolver_export: model.ExportPosition,
    settling_source: ?PromiseIncarnation = null,
};

pub const ResolverPurpose = union(enum) {
    application_answer: model.AnswerPosition,
    node_settling: NodeSettlingResolver,
    retired: RetiredResolver,
    shortening_pending: PromiseIncarnation,
    shortening_complete: PromiseIncarnation,
};
pub const ShorteningNomination = shortening.Nomination;
pub const SettlingMovePlan = imported_promise.SettlingMovePlan;
const OutboundResolverLink = bimap.BiMap(model.ExportPosition, ResolverPurpose);
const InboundResolverLink = bimap.BiMap(model.AnswerPosition, model.ImportPosition);

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
pub const pendingInboundSlot = answers.pendingInboundSlot;
pub const answerSlot = answers.answerSlot;
pub const AnswerCell = answers.AnswerCell;
pub const ListenerEntry = answers.ListenerEntry;
const ListenerList = answers.ListenerList;
pub const Projection = answers.Projection;
pub const ProjectionKind = answers.ProjectionKind;
pub const ProjectionIndex = answers.ProjectionIndex;
pub const deinitProjection = answers.deinitProjection;
pub const AnswerView = answers.AnswerView;
pub const AnswerTable = answers.AnswerTable;

pub const inspect = @import("inspect.zig");
pub const ExportView = inspect.ExportView;
pub const ImportView = inspect.ImportView;
pub const AnswerRowView = inspect.AnswerRowView;
const ensureAnswerPayload = answers.ensureAnswerPayload;
pub const deinitAnswerCell = answers.deinitAnswerCell;

/// Listen/settle cell for third-party imported promises (ADR-0009): listeners,
/// one stored resolution for late `op:listen`, and a `row_id` for queued fire
/// carriers. The ADR-0007 answer side keeps its own listeners/resolution in
/// `AnswerPayload`, so this cell has one embedder (`ImportedPromise`). Keying and
/// host provenance stay on the wrapper tables; this is only the cell.
pub const PromiseListenCell = struct {
    listeners: ListenerList = .empty,
    resolution: ?model.Resolution = null,
    /// Row identity for queued fire carriers. No default: registration stamps.
    row_id: u64,
};

/// Session metadata for one imported promise. Every next-profile remote promise
/// uses the shortening fields; a non-null `host` additionally marks a promise
/// introduced through third-party handoff (ADR-0009), whose relayed resolution
/// and proxy listeners use `cell`.
pub const ImportedPromise = struct {
    /// The third-party host this promise lives on (`key_arena`-interned). Held
    /// so a re-root with a conflicting host is rejected (`Error.HostMismatch`).
    host: ?[]const u8,
    /// Listeners + stored relayed resolution + row identity.
    cell: PromiseListenCell,
    /// Next-profile forwarding edge. A self-edge means the shortening
    /// subscription is still pending. A completed edge stays stable because
    /// it also records which callback-introduced import retain this source
    /// owns and must release when the source dies.
    shortening_target: model.ImportPosition,
    /// This promise incarnation already spent PR 282's one settling-listener
    /// allowance. Claimed before the send and rolled back if the send fails.
    settling_listener_claimed: bool = false,
    /// The one resolver export named by the surviving wire settling listener.
    /// Meaningful only while `settling_listener_claimed` is true.
    settling_listener_export: model.ExportPosition = .from(0),
    /// The application answer awaiting this subscription, null when the Node
    /// is its only local consumer.
    settling_answer: ?model.AnswerPosition = null,
    /// Additional application answers sharing the one wire callback. Empty in
    /// the common one-consumer case; capacity is reused when a released answer
    /// is replaced by another converging source.
    settling_followers: std.ArrayListUnmanaged(model.AnswerPosition) = .empty,
    /// Whether a Node promise proxy also consumes this subscription.
    settling_node_claimed: bool = false,
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
    /// `resolve_me_desc` with no `answer_position`). Allocated from
    /// `VIRTUAL_INBOUND_ANSWER_BASE` upward; the partner is refused that range
    /// in validation, which is what keeps the namespaces disjoint (answer
    /// positions are partner-named, so a bare offset alone would not).
    next_virtual_inbound_answer: u64 = VIRTUAL_INBOUND_ANSWER_BASE,
    /// One per-session bump arena owning the byte keys/values of the *monotonic*
    /// byte-keyed tables — `bootstrap` swissnums, partner key/location bytes,
    /// and interned third-party import host designators — none of which ever
    /// free an individual string. Teardown is one `key_arena.deinit()` instead
    /// of per-row free loops. The evicting / individually-removed tables
    /// (`sturdyref_cache`, `pending_enlivens`, `pending_enliven_by_answer`) stay on the gpa with precise
    /// per-row frees: a bump arena cannot reclaim an evicted row and would leak
    /// under churn.
    key_arena: std.heap.ArenaAllocator,
    /// Per-turn scratch arena for the inbound record spine. It backs the
    /// introduced-import record every recv turn's validate walk fills and
    /// apply consumes (`validate.IntroducedImports` — allocation-free for the
    /// common no-reference message), the owned-fallback kinds' (`gc_*`,
    /// `handoff`, `get`/`index`/`untag`) one transient owned `Message`, the
    /// inbound GC validators' duplicate-position fold (`checkGcExportDecrement`
    /// / `checkGcAnswerDecrement` in `validateRecv` — stack for small vectors,
    /// map spill above threshold), and the inbound set-uniqueness fold
    /// (`checkInboundSetUniqueness` — view handles + hash rows for Cap'n Proto
    /// duplicate refusal; small sets stay on the stack). All of it dies when the turn ends: every
    /// recv entry point (`recordRecv`, `recordRecvView`,
    /// `validateInboundDeliverView`, `recordResolverCallbackResolve`) resets it,
    /// so the per-message dupe-then-`freeMessage` choreography collapses to one
    /// bump-and-reset, and apply dupes anything session-lived onto `allocator`,
    /// so the reset can never dangle a table row. The reset retains at most
    /// `steady_recv_scratch_bytes`, not the whole peak: one admissible frame
    /// runs to `max_frame_bytes`, and its set / owned-fallback materialization
    /// is several times that in owned `Argument`s, so retaining a burst's peak
    /// would pin megabytes per session for the connection's life.
    recv_scratch: std.heap.ArenaAllocator,
    exports: ExportTable,
    imports: ImportTable,
    inbound_answers: AnswerTable,
    outbound_answers: AnswerTable,
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

    /// The steady capacity `recv_scratch` retains across turns, trimming a
    /// burst's peak on reset. Deliberately smaller than the vat and engine
    /// arenas' 4096: the per-connection footprint budget is 2 KiB total
    /// (`test/engine/footprint_budget_test.zig`, docs/ladder.md step 2), so this
    /// bound must leave room for the tables beside it.
    /// `test/engine/deliver_set_scratch_budget_test.zig` pins a big-set frame's
    /// scratch back under it after the frame drains.
    pub const steady_recv_scratch_bytes: usize = 384;

    /// Construction knobs for `initWith`. Every field has a default, so a
    /// caller names only what it overrides: `Session.init(allocator)` is
    /// `initWith(allocator, .{})`. The knobs are orthogonal, `negotiating`
    /// selects the starting `State`, `limits` sets the resource bounds, and the
    /// rest set the negotiated profile / codec / features the handshake would
    /// otherwise install. The already-open default is v1.0; next is explicit.
    pub const Options = struct {
        /// Start in `negotiating` (awaiting `op:start-session`) instead of `open`.
        negotiating: bool = false,
        codec: model.CodecId = model.Preference.baseline.codec,
        captp_version: model.CaptpVersion = model.Preference.baseline.captp_version,
        features: model.FeatureSet = model.FeatureSet.full(),
        limits: SessionLimits = .{},
        /// The first export position this session hands out.
        ///
        /// A near reference carries only this integer, so it means whatever the
        /// session reading it says it means. Two sessions that both count from
        /// the same place therefore name different objects with the same
        /// number, and a capability offered to the wrong one is not refused —
        /// it silently resolves to whatever that session keeps at that
        /// position. Handing each session of a host a disjoint range makes the
        /// foreign position absent instead of ambiguous, so the existing
        /// held-export check refuses it. The bootstrap export keeps position 0
        /// on every session (ADR-0006); this is where the rest begin.
        export_base: u64 = BOOTSTRAP_POSITION + 1,
        /// How many positions past `export_base` this session may hand out
        /// before refusing. Unbounded when no host imposed a range.
        export_span: u64 = std.math.maxInt(u64),
    };

    /// Move the export allocator to the range this session was given, before
    /// it has handed anything out. Asserted rather than tolerated: a base moved
    /// after an export exists would renumber a position a partner already
    /// holds.
    pub fn setExportBase(self: *Session, base: u64, span: u64) void {
        std.debug.assert(self.exports.len() == 0);
        self.export_base = base;
        self.next_export_position = base;
        self.export_position_end = base +| span;
    }

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

    /// One input, two roles: a configured profile is both what this side asks
    /// for and what it speaks until a partner's hello settles otherwise. Named
    /// once here because two tiers impose a profile — construction and
    /// `engine.Peer.reposture` — and a third that encoded it independently would
    /// advertise something the session does not speak.
    pub fn preferenceOf(
        captp_version: model.CaptpVersion,
        codec: model.CodecId,
        features: model.FeatureSet,
    ) model.Preference {
        return .{ .captp_version = captp_version, .codec = codec, .features = features };
    }

    /// The one full constructor; every `init*` shorthand delegates here.
    pub fn initWith(allocator: std.mem.Allocator, options: Options) Session {
        return .{
            .allocator = allocator,
            .state = if (options.negotiating) .negotiating else .open,
            .captp_version = options.captp_version,
            .codec = options.codec,
            .preferred = preferenceOf(options.captp_version, options.codec, options.features),
            .features = options.features,
            .limits = options.limits,
            // Start past the bootstrap id so `allocateExport` never aliases the
            // bootstrap object (export 0), true from construction, not only once
            // `transitionToOpen` runs, so a cap registered before the session
            // opens (e.g. a vat published on accept, hosting on the completion
            // loop) still gets a fresh export rather than colliding with 0.
            .export_base = options.export_base,
            .next_export_position = options.export_base,
            .export_position_end = options.export_base +| options.export_span,
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
            .local_session_key = &.{},
            .partner_designator = &.{},
            .partner_acceptable_location_raw = &.{},
            .outbound_resolver_link = .empty,
            .v1_0_inbound_resolver_link = .empty,
            .sturdyref_cache = .empty,
            .sturdyref_cache_index = .empty,
            .pending_enlivens = .empty,
            .pending_enliven_by_answer = .empty,
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
        self.outbound_resolver_link.deinit(self.allocator);
        self.v1_0_inbound_resolver_link.deinit(self.allocator);
        // Drop the index before freeing row swissnums (keys alias those slices).
        self.sturdyref_cache_index.deinit(self.allocator);
        for (self.sturdyref_cache.items) |entry| self.allocator.free(entry.swissnum);
        self.sturdyref_cache.deinit(self.allocator);
        var enliven_it = self.pending_enlivens.keyIterator();
        while (enliven_it.next()) |key| self.allocator.free(key.*);
        self.pending_enlivens.deinit(self.allocator);
        self.pending_enliven_by_answer.deinit(self.allocator);
        self.key_arena.deinit();
        self.recv_scratch.deinit();
    }

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
    pub const mintOutboundResolver = v1_0.mintOutboundResolver;
    pub const installInboundResolver = v1_0.installInboundResolver;
    pub const resolverForInboundAnswer = v1_0.resolverForInboundAnswer;
    pub const answerForResolverImport = v1_0.answerForResolverImport;
    pub const allocateInboundAnswer = v1_0.allocateInboundAnswer;

    /// The `op:start-session` handshake state lives in `handshake.zig`; these
    /// aliases keep the call sites reading as ordinary `Session` methods. The
    /// handshake fields they operate on stay on `Session`.
    pub const handshakeComplete = handshake.handshakeComplete;
    pub const awaitsPartnerHello = handshake.awaitsPartnerHello;
    pub const transitionToOpen = handshake.transitionToOpen;
    pub const partnerSessionKey = handshake.partnerSessionKey;
    pub const localSessionKey = handshake.localSessionKey;
    pub const partnerDesignator = handshake.partnerDesignator;
    pub const partnerLocatorRaw = handshake.partnerLocatorRaw;

    pub fn close(self: *Session) void {
        self.state = .closed;
    }

    /// The marshal-side door into `admitExportPosition`, for `apply`'s
    /// first-mention branch. Same rule, reachable from the sibling module.
    pub fn admitExportPositionForMarshal(self: *Session, id: model.ExportPosition) Error!void {
        return self.admitExportPosition(id);
    }

    /// Admit an export position that did not come from this session's own
    /// allocator, and advance past it.
    ///
    /// An export position is a name in *this* session's namespace and nowhere
    /// else, so one from outside the session's range names nothing here.
    /// Minting a row for it would answer a partner with an object this session
    /// does not host, and dragging the allocator up to it would spend the
    /// range the session has left, after which it can export nothing at all.
    /// Every door a position can arrive through — an explicit grant, a
    /// reservation, or a first marshal in a sent resolve — comes through here,
    /// so the rule is the session's rather than each caller's to remember.
    ///
    /// The bootstrap position sits below every range by construction and is
    /// always this session's own.
    fn admitExportPosition(self: *Session, id: model.ExportPosition) Error!void {
        if (id.int() == BOOTSTRAP_POSITION) return;
        if (id.int() < self.export_base or id.int() >= self.export_position_end) {
            return Error.InvalidReference;
        }
        if (id.int() >= self.next_export_position) {
            self.next_export_position = id.int() + 1;
        }
    }

    pub fn registerExport(self: *Session, id: model.ExportPosition) !void {
        try self.admitExportPosition(id);
        try self.exports.register(self.allocator, id);
        if (id.int() != BOOTSTRAP_POSITION and self.exports.wireHeld(id) == 0) {
            try self.exports.retain(self.allocator, id);
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
        try self.admitExportPosition(id);
        try self.exports.register(self.allocator, id);
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

    /// Install `id` as a pending outbound answer we await resolution for.
    /// The position must be fresh; one live row cannot name two questions.
    pub fn installOutboundAnswer(self: *Session, id: model.AnswerPosition) !void {
        try self.installAnswer(.outbound, id);
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
    /// gate, nothing more: kind-specific rules such as refusing wire
    /// `op:resolve` belong to the validators (`validateRecvView`).
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
        defer _ = self.recv_scratch.reset(.{ .retain_with_limit = steady_recv_scratch_bytes });
        var introduced: validate.IntroducedImports = .init(self.recv_scratch.allocator(), self.limits);
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
    /// The rarer kinds that validate or apply over sub-structure the borrowed
    /// walkers do not yet read (`gc_*`'s position vectors, `handoff`'s deep
    /// record) fall back to one owned materialization for the existing owned
    /// validate / apply. The projection ops (`get`/`index`/`untag`) stay
    /// borrowed: the session reads only their receiver and answer position,
    /// and the engine re-reads the field or tag from the frame itself, so an
    /// owned copy here would materialize bytes nobody reads.
    pub fn recordRecvView(self: *Session, body: model.view.Body) !void {
        try self.admitInState(body);
        // Everything both branches bump into `recv_scratch` is turn-scratch —
        // the introduced-import record the validate walk fills and apply
        // consumes (`validate.IntroducedImports`), and the owned-fallback
        // materialization below — so one reset reclaims the whole turn. Apply
        // dupes anything session-lived onto `self.allocator`, so the reset can
        // never dangle a table row.
        defer _ = self.recv_scratch.reset(.{ .retain_with_limit = steady_recv_scratch_bytes });
        var introduced: validate.IntroducedImports = .init(self.recv_scratch.allocator(), self.limits);
        switch (body) {
            .deliver, .resolve, .listen, .start_session, .abort, .get, .index, .untag => {
                try self.validateRecvView(body, &introduced);
                try self.applyRecvView(body, &introduced);
            },
            .gc_export, .gc_answer => {
                // The feature gate reads the kind alone, so it runs against the
                // borrowed view first. Otherwise a kind this session never
                // negotiated could make us materialize its whole payload and
                // only then be told it was never admissible, which is a copy an
                // unauthorized partner chose the size of.
                try refuseUnnegotiatedKind(self, body);
                // One transient owned copy to feed the shared owned validate /
                // apply; it dies in the same reset, no per-row free walk.
                const owned = try body.toOwned(self.recv_scratch.allocator());
                try self.validateRecv(owned, &introduced);
                try self.applyRecv(owned, &introduced);
            },
        }
    }

    /// Refuse an inbound kind this session's negotiated feature set does not
    /// admit, reading the kind and nothing else. `validateRecv` makes the same
    /// refusal on the owned message, which is where every other dispatch path
    /// reaches it; this runs earlier, on the borrowed view, so the refusal
    /// lands before the copy rather than after it.
    fn refuseUnnegotiatedKind(self: *const Session, body: model.view.Body) Error!void {
        switch (body) {
            .gc_export, .gc_answer => if (!self.features.wire_delta) return Error.FeatureNotNegotiated,
            else => {},
        }
    }

    /// Validate a borrowed inbound deliver before the engine performs any of
    /// its deliver-specific authority mutations (V1.0 resolver registration or
    /// pipeline retention). The caller-owned `introduced` record survives into
    /// `applyValidatedInboundDeliverView`, so the argument tree is walked once.
    /// Validation scratch remains turn-local and is reset before returning.
    pub fn validateInboundDeliverView(self: *Session, deliver: model.view.Deliver, introduced: *validate.IntroducedImports) !void {
        const body = model.view.Body{ .deliver = deliver };
        try self.admitInState(body);
        defer _ = self.recv_scratch.reset(.{ .retain_with_limit = steady_recv_scratch_bytes });
        try self.validateRecvView(body, introduced);
    }

    /// Apply a deliver already accepted by `validateInboundDeliverView`.
    /// Engine-only in practice: keeping this separate is what lets validation
    /// precede resolver and pipeline mutation without validating the same
    /// argument tree again when an ordinary deliver reaches session apply.
    pub fn applyValidatedInboundDeliverView(self: *Session, deliver: model.view.Deliver, introduced: *const validate.IntroducedImports) !void {
        const body = model.view.Body{ .deliver = deliver };
        try self.applyRecvView(body, introduced);
    }

    /// Record the inbound resolve the engine synthesizes when a partner
    /// fulfills a promise by delivering to its resolver callback (ADR-0010,
    /// ADR-0111).
    /// Validates and applies straight from the borrowed resolution view, so the
    /// callback hot path materializes no owned resolution.
    ///
    /// This is deliberately *not* `recordRecvView`: that path refuses a
    /// wire `op:resolve`, and this resolve never arrived on the wire. The
    /// partner sent an `op:deliver` to the resolver and the
    /// engine surfaces the settlement as a semantic resolve. The shared
    /// inbound-resolve validation and apply run exactly as the canonical
    /// resolve path does, minus that wire refusal. The borrowed `resolve` must
    /// outlive this call; the engine keeps the frame it borrows alive on the
    /// event queue before applying.
    pub fn recordResolverCallbackResolve(self: *Session, resolve: model.view.Resolve) !void {
        defer _ = self.recv_scratch.reset(.{ .retain_with_limit = steady_recv_scratch_bytes });
        var introduced: validate.IntroducedImports = .init(self.recv_scratch.allocator(), self.limits);
        try self.validateResolverCallbackResolve(resolve, &introduced);
        try self.applyValidatedResolverCallbackResolve(resolve, &introduced);
    }

    /// Engine split of `recordResolverCallbackResolve`: validate before an
    /// event is committed, then apply the same introduced-import record after.
    pub fn validateResolverCallbackResolve(self: *Session, resolve: model.view.Resolve, introduced: *validate.IntroducedImports) !void {
        const body = model.view.Body{ .resolve = resolve };
        try self.admitInState(body);
        try validate.validateInboundResolve(self, resolve, introduced);
    }

    pub fn applyValidatedResolverCallbackResolve(self: *Session, resolve: model.view.Resolve, introduced: *const validate.IntroducedImports) !void {
        try self.applyRecvView(.{ .resolve = resolve }, introduced);
    }

    // Per-kind validate/apply live in `validate.zig` (the module-level
    // `validate` re-export above) and `apply.zig`; the public spine is
    // `recordSend` / `recordRecv` / `recordRecvView` / `admits`. Three
    // per-kind entry points stay public because one engine pre-step must run
    // the same rule before `recordRecv*`.
    const apply = @import("apply.zig");

    const validateRecvView = validate.validateRecvView;
    const validateSend = validate.validateSend;
    const validateRecv = validate.validateRecv;
    const applyRecvView = apply.applyRecvView;
    const applySend = apply.applySend;
    const applySentResolve = apply.applySentResolve;
    const applyRecv = apply.applyRecv;

    /// Validate an inbound `op:listen` before the engine installs its
    /// listener. Engine caller: `engine.pipeline.maybeInstallInboundListener`.
    pub const validateInboundListen = validate.validateInboundListen;
    /// Pre-commit rule for a locally supplied resolution bound for a store
    /// (the relayed-resolution seam). Engine caller:
    /// `engine.Peer.applyRelayedResolution`.
    pub const validateStoredResolution = validate.validateStoredResolution;
    /// Retain the wire mention of a sent export reference that bypasses
    /// `recordSend`. Engine caller: `engine.v1_0.installResolverForOutboundDeliver`.
    pub const retainSentExportRef = apply.retainSentExportRef;

    const installAnswer = apply.installAnswer;

    /// Mint the next store-row stamp (see `store_stamp_counter`). Never
    /// returns 0, so a zero-initialized stamp can never false-match one.
    pub fn nextStoreStamp(self: *Session) u64 {
        self.store_stamp_counter += 1;
        // A wrapped counter could hand two row instances one stamp, which is
        // exactly the false-match the stamp exists to prevent; pin it.
        std.debug.assert(self.store_stamp_counter != 0);
        return self.store_stamp_counter;
    }

    pub fn inboundAnswer(self: *Session, id: model.AnswerPosition) ?AnswerView {
        const entry = self.inbound_answers.getPtr(id) orelse return null;
        return AnswerView.of(entry);
    }

    /// Live inbound answer to Slot.
    pub fn inboundAnswerSlot(self: *Session, id: model.AnswerPosition) ?slot.Slot {
        const cell = self.inbound_answers.getPtr(id) orelse return null;
        return cell.binding;
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

    /// Live outbound answer to Slot.
    pub fn outboundAnswerSlot(self: *Session, id: model.AnswerPosition) ?slot.Slot {
        const cell = self.outbound_answers.getPtr(id) orelse return null;
        return cell.binding;
    }

    pub fn hasExport(self: *const Session, id: model.ExportPosition) bool {
        return self.exports.contains(id);
    }

    pub fn hasImport(self: *const Session, id: model.ImportPosition) bool {
        return self.imports.contains(id);
    }

    /// Whether this session can name `id` as a far reference: a row it holds,
    /// or the partner's pinned bootstrap, which is always addressable and
    /// carries no row (ADR-0006). Wider than `hasImport` by exactly that
    /// bootstrap case.
    ///
    /// The one definition of "an import this session holds". The send-side
    /// reference rule asks it before letting a far onto the wire, and
    /// `driver_core.Host.enrollCapability` asks it before minting a routing
    /// token for one, so the two cannot drift into disagreeing about which
    /// positions this session may name.
    pub fn holdsImport(self: *const Session, id: model.ImportPosition) bool {
        return id.int() == BOOTSTRAP_POSITION or self.imports.contains(id);
    }

    /// Live export row's CapTP `Slot` (object or promise), or null if absent.
    pub fn exportSlot(self: *const Session, id: model.ExportPosition) ?slot.Slot {
        return self.exports.slotOf(id);
    }

    /// Live import row's CapTP `Slot`, or null if absent.
    pub fn importSlot(self: *const Session, id: model.ImportPosition) ?slot.Slot {
        return self.imports.slotOf(id);
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
        if (self.next_export_position >= self.export_position_end) return Error.ExportRangeExhausted;
        const id = model.ExportPosition.from(self.next_export_position);
        try self.exports.register(self.allocator, id);
        self.next_export_position += 1;
        return id;
    }

    /// Allocate the next free export position as a *promise* reservation: the
    /// row is installed unresolved (`local_unresolved`) at its local baseline,
    /// the promise twin of `allocateExport`. A synthesized V1.0 resolver export
    /// is minted here so its slot is authoritative before any wire mention
    /// projects it — the render path reads the row, it does not decide the kind
    /// (ADR-0080).
    pub fn allocatePromiseExport(self: *Session) !model.ExportPosition {
        const id = model.ExportPosition.from(self.next_export_position);
        try self.exports.registerPromise(self.allocator, id);
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

    /// Unwind one `registerImport` retain that never became observable (a
    /// failed prepare), the import-table mirror of `releaseUnsharedExport`.
    /// Infallible for the same reason: the caller just took the retain, so
    /// the row exists and cannot underflow.
    pub fn releaseImportRetain(self: *Session, id: model.ImportPosition) void {
        self.imports.decrement(id, 1) catch unreachable;
    }

    /// Unwind one `installOutboundAnswer` whose position never reached the
    /// wire (a failed send after the install), the answer-table member of the
    /// `releaseUnsharedExport` family. Only valid while the row is still the
    /// pending count-1 installation the caller just made; an answer the
    /// partner has seen is released through `op:gc-answers`, never this. Like
    /// the export half, the monotonic position counter is left advanced.
    pub fn abandonOutboundAnswer(self: *Session, id: model.AnswerPosition) void {
        const entry = self.outbound_answers.getPtr(id) orelse unreachable;
        std.debug.assert(entry.status() == .pending and entry.count == 1);
        deinitAnswerCell(self.allocator, entry);
        self.outbound_answers.remove(id);
    }

    /// The node-unique token this session's import `position` was enrolled
    /// under (ADR-0069), or null when it has none yet. Enrolling the same
    /// import twice must name it by the same token, or one capability would
    /// wear two identities and each enrollment would leave a routing row
    /// behind, so the node reads this before minting.
    pub fn foreignTokenFor(self: *const Session, position: model.ImportPosition) ?u64 {
        return self.imports.tokenOf(position);
    }

    /// Record the token an import was enrolled under. The token is kept on the
    /// import row, so releasing the import forgets it in the same step.
    pub fn noteForeignToken(self: *Session, position: model.ImportPosition, token: u64) !void {
        return self.imports.noteToken(self.allocator, position, token);
    }

    /// Opaque Host capability attached to this live import incarnation.
    pub fn hostCapabilityFor(self: *const Session, position: model.ImportPosition) ?u64 {
        return self.imports.hostRefOf(position);
    }

    pub const HostImportIdentity = ImportTable.HostIdentity;

    pub fn hostImportIdentity(self: *const Session, position: model.ImportPosition) ?HostImportIdentity {
        return self.imports.hostIdentityOf(position);
    }

    /// Attach one Host capability id to the live import row. Session retains
    /// only the scalar identity; Host owns its meaning and lifetime.
    pub fn noteHostCapability(self: *Session, position: model.ImportPosition, ref: u64) !void {
        return self.imports.noteHostRef(self.allocator, position, ref);
    }

    pub fn claimHostCapabilityRetain(self: *Session, position: model.ImportPosition, ref: u64) !void {
        return self.imports.claimHostRetain(position, ref);
    }

    pub fn releaseHostCapabilityRetains(self: *Session, position: model.ImportPosition, ref: u64, delta: u64) void {
        self.imports.releaseHostRetains(position, ref, delta);
    }

    /// Forget the expected Host identity without disturbing a Node token that
    /// may coexist on the row during migration.
    pub fn forgetHostCapability(self: *Session, position: model.ImportPosition, ref: u64) void {
        self.imports.forgetHostRef(position, ref);
    }

    /// The reserved, versioned namespace for randomly minted durable swiss
    /// names (ADR-0098): a fixed domain prefix followed by the hex encoding of
    /// `durable_swiss_entropy_len` cryptographically random bytes. Mutable
    /// bootstrap binds structurally refuse this prefix, and the Host's durable
    /// mint produces only names inside it, so the two namespaces cannot
    /// collide — including across a process restart, where no in-memory
    /// tombstone could survive to police it.
    pub const durable_swiss_prefix = "pancake-durable-1-";
    /// Random bytes behind the prefix, encoded as lowercase hex.
    pub const durable_swiss_entropy_len = 16;
    /// A minted durable swiss name's exact byte length.
    pub const durable_swiss_len = durable_swiss_prefix.len + durable_swiss_entropy_len * 2;

    /// Whether `swissnum` lies in the reserved durable namespace.
    pub fn isDurableSwiss(swissnum: []const u8) bool {
        return std.mem.startsWith(u8, swissnum, durable_swiss_prefix);
    }

    /// Expose a local capability behind `swissnum` for inbound bootstrap-fetch
    /// (ADR-0006 responder half): allocate a fresh export and map the swissnum to
    /// it. Returns the export position. Re-registering a swissnum replaces its mapping.
    pub fn registerBootstrapCap(self: *Session, swissnum: []const u8) !model.ExportPosition {
        const export_position = try self.allocateExport();
        // The export was never handed out, so a failure to map the swissnum
        // rolls it back instead of leaving a phantom export row.
        errdefer self.releaseUnsharedExport(export_position);
        try self.bindBootstrapCap(swissnum, export_position);
        return export_position;
    }

    /// Bind a bootstrap name to an already-held export. The caller owns that
    /// export's lifetime; replacing discovery never releases the displaced
    /// object because capabilities already issued to it remain live.
    pub fn bindBootstrapCap(self: *Session, swissnum: []const u8, export_position: model.ExportPosition) !void {
        // A caller-chosen mutable name structurally cannot enter the durable
        // namespace (ADR-0098): the prefix, not a retained tombstone, is what
        // keeps an old sturdyref from being retargeted after restart.
        if (isDurableSwiss(swissnum)) return Error.ReservedDurableNamespace;
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
    }

    /// The local export serving `swissnum`, or null if none is registered.
    pub fn bootstrapLookup(self: *const Session, swissnum: []const u8) ?model.ExportPosition {
        return self.bootstrap.get(swissnum);
    }

    /// Unwind a `registerBootstrapCap` grant that never became observable: put
    /// the mapping back to `prior` (or remove it when there was none). The
    /// publish verbs pair this with `releaseUnsharedExport` so a failed
    /// publish leaves neither a dangling name nor a phantom export row. The
    /// bootstrap registry is otherwise monotonic; a removed row's key bytes
    /// stay in `key_arena`, which is the arena posture, and this runs only on
    /// a failed publish. Infallible: restoring overwrites a live slot, and a
    /// remove of the just-inserted key always finds it.
    pub fn restoreBootstrapMapping(self: *Session, swissnum: []const u8, prior: ?model.ExportPosition) void {
        if (prior) |position| {
            self.bootstrap.getPtr(swissnum).?.* = position;
        } else {
            std.debug.assert(self.bootstrap.remove(swissnum));
        }
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
        if (entry.status() != .pending) return Error.InvalidReference;
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
        if (entry.status() == .pending) {
            switch (resolution) {
                .fulfill => entry.fulfill() catch unreachable,
                .@"break" => entry.breakCell() catch unreachable,
            }
        }
    }

    /// Borrow the stored resolution for `answer_position`, if the answer resolved and
    /// retained it. The borrow is valid until the answer is mutated or removed.
    pub fn peekResolution(self: *Session, answer_position: model.AnswerPosition) ?*const model.Resolution {
        const entry = self.inbound_answers.getPtr(answer_position) orelse return null;
        const payload = entry.payload orelse {
            std.debug.assert(entry.status() == .pending);
            return null;
        };
        // The `applySentResolve` invariant every fire and projection reader
        // leans on: for an inbound answer, a stored resolution and a settled
        // status arrive together or not at all.
        std.debug.assert((payload.resolution != null) == (entry.status() != .pending));
        if (payload.resolution) |*resolution| return resolution;
        return null;
    }

    /// Whether `answer_position` is a known inbound answer that has resolved.
    pub fn answerResolved(self: *Session, answer_position: model.AnswerPosition) bool {
        const entry = self.inbound_answers.getPtr(answer_position) orelse return false;
        return entry.status() != .pending;
    }

    // Imported-promise metadata: third-party relay state from ADR-0009 plus the
    // next profile's shortening and settling claims. Bodies live in
    // `imported_promise.zig` and are aliased here.
    pub const installThirdPartyImport = imported_promise.installThirdPartyImport;
    pub const isThirdPartyImport = imported_promise.isThirdPartyImport;
    pub const installImportedPromiseListener = imported_promise.installImportedPromiseListener;
    pub const recordRelayedResolution = imported_promise.recordRelayedResolution;
    pub const takeImportedPromiseListeners = imported_promise.takeImportedPromiseListeners;
    pub const importedPromiseResolution = imported_promise.importedPromiseResolution;
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
/// Body in `imported_promise.zig`.
pub const deinitImportedPromise = imported_promise.deinitImportedPromise;
