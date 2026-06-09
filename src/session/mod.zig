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
const model = @import("../model/mod.zig");
const slot_table = @import("slot_table.zig");

/// Position-keyed wire-delta refcount table (exports / imports). See
/// [`slot_table`] for why partner-controlled positions use an integer-keyed
/// hash rather than a raw index vector.
const SlotTable = slot_table.SlotTable;

/// Error set for the borrowed-view recv walkers: session authority errors plus
/// the lazy projection errors a codec-backed [`model.view.Args`] can raise while
/// walking. Named explicitly so the mutually-recursive argument walkers don't
/// form an inferred-error-set dependency loop.
pub const RecvViewError = Error || model.view.ProjectError || std.mem.Allocator.Error;

pub const Error = error{
    MalformedMessage,
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
    /// match this session's negotiated [`model.WireProfile`] version.
    CaptpVersionMismatch,
    /// A pipelined-call queue for one answer exceeded [`SessionLimits.queue_cap`]
    /// (ADR-0007). A loud bound on a partner flooding calls against a promise it
    /// never resolves, never a silent drop.
    QueueCapExceeded,
    /// The inbound answer table exceeded [`SessionLimits.max_inbound_answers`].
    InboundAnswerCapExceeded,
    /// One target's listener list exceeded
    /// [`SessionLimits.max_listeners_per_target`].
    ListenerCapExceeded,
    /// A promise resolved (directly or transitively) to an answer already on the
    /// resolution chain being drained — requeueing the pipelined calls would
    /// loop forever (ADR-0007). Surfaced loudly instead of spinning.
    ResolutionCycle,
    /// A third-party import (ADR-0009) was re-rooted at a different host than the
    /// one it was first installed with. An import's host is fixed for its
    /// lifetime; a conflicting re-root is a loud protocol error, never a silent
    /// overwrite.
    HostMismatch,
    /// The import table exceeded [`SessionLimits.max_imports`]. A loud bound on a
    /// partner introducing unboundedly many imports (ADR-0025); never a silent
    /// drop. Projects to a `ResourceExhausted` abort.
    ImportCapExceeded,
    /// The seen-handoff-count table exceeded
    /// [`SessionLimits.max_seen_handoff_counts`] — too many distinct
    /// Exporter-to-Receiver sessions tracked for replay rejection (ADR-0025).
    HandoffCountCapExceeded,
    /// The deposited-gift table exceeded [`SessionLimits.max_deposited_gifts`] —
    /// the load-bearing bound against deposit-without-withdraw (ADR-0025).
    DepositedGiftCapExceeded,
    /// An inbound argument tree nested deeper than
    /// [`SessionLimits.max_nesting_depth`]. The recursive validate / install walk
    /// is bounded so a malicious deeply-nested frame fails loud instead of
    /// overflowing the native stack. Projects to `resource_exhausted`.
    NestingTooDeep,
};

/// The fixed bootstrap export id installed when a session reaches `open`
/// (ADR-0006). An inbound `op:deliver` to `<desc:export 0>` with method
/// `'fetch` is the bootstrap-fetch entry point. The initiator side lives in
/// `engine.fetch`; the inbound-`'fetch` responder lives in `engine.bootstrap`,
/// not the session.
pub const BOOTSTRAP_EXPORT_ID: u64 = 0;

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
/// `OutboundResolvers` maps a resolver-export id to an answer-pos, because the
/// hot lookup (`answerForResolverExport`, run per inbound deliver) needs that
/// reverse direction. `InboundResolvers` maps an answer-pos to a resolver
/// import. Neither owns heap memory beyond its map backing.
const OutboundResolvers = std.AutoHashMapUnmanaged(u64, u64);
const InboundResolvers = std.AutoHashMapUnmanaged(u64, u64);

pub const State = enum {
    negotiating,
    open,
    draining,
    closed,
};

/// Bounds on pipelining state (ADR-0007), keeping a peer from being driven into
/// unbounded memory by a partner that pipelines or listens without ever
/// resolving. Each overflow is a loud session error, never a silent drop. The
/// `max_local_deliveries` bound is enforced by the engine's resolution drain;
/// the rest are enforced here in the session. Defaults mirror the canonical
/// engine's `SessionLimits`.
pub const SessionLimits = struct {
    /// Max pipelined calls queued against a single pending answer.
    queue_cap: usize = 1024,
    /// Max inbound answer rows held at once.
    max_inbound_answers: usize = 65_536,
    /// Max listeners registered against a single target.
    max_listeners_per_target: usize = 64,
    /// Max local deliveries surfaced from one resolution drain (engine-enforced).
    max_local_deliveries: usize = 4096,
    /// Max import-table rows — bounds a partner introducing unboundedly many
    /// imports (ADR-0025). Each new partner-driven import registration checks it;
    /// locally-allocated exports are bounded by our own sends, so exports are
    /// uncapped.
    max_imports: usize = 1_048_576,
    /// Max distinct Exporter-to-Receiver session ids tracked in the handoff
    /// replay set (ADR-0025). Each row holds one monotonic `last_count`.
    max_seen_handoff_counts: usize = 16_384,
    /// Max deposited-gift rows — load-bearing against a gifter depositing gifts
    /// that are never withdrawn (ADR-0025).
    max_deposited_gifts: usize = 65_536,
    /// Max resolved sturdyref enlivenments cached for dedup (ADR-0012). The cache
    /// is non-load-bearing — a miss costs one extra bootstrap-fetch round-trip,
    /// never correctness — so an overflow evicts the oldest entry instead of
    /// erroring. A cap of 0 disables caching.
    max_sturdyref_cache_entries: usize = 256,
    /// Max nesting depth of an inbound argument tree (`list` / `set` / `tagged`).
    /// The value tree is attacker-controlled until validated, and the validate /
    /// install walk recurses per level, so an unbounded depth is a one-frame
    /// native-stack overflow (a few KB of nested `[` markers). A loud bound,
    /// projecting to `resource_exhausted`, sibling to the ADR-0025 table caps.
    max_nesting_depth: usize = 64,
    /// Max bytes in a single inbound frame admitted off a byte stream. The
    /// stream framer caps a frame at this size *during* decode (cap-on-parse),
    /// so a hostile length claim or never-completing frame fails loud as
    /// `resource_exhausted` rather than growing a buffer without bound. A
    /// byte-stream adapter sizes its read buffer to this cap (the
    /// loopback-testing simplification; a production small-buffer + overflow
    /// path is a named follow-up). Not consulted by the frame boundary, which is
    /// handed an already-framed buffer.
    max_frame_bytes: usize = 1 << 20,
};

pub const AnswerStatus = enum {
    pending,
    fulfilled,
    broken,
};

/// A party that asked (via `op:listen`) to be told when an answer resolves. The
/// `target` is the capability the resolution is delivered to; `wants_partial`
/// requests intermediate notifications when the answer resolves to another
/// promise rather than only the final value. The entry owns `target`.
pub const ListenerEntry = struct {
    target: model.Reference,
    wants_partial: bool,
};

/// Cold pipelining payload for an answer (ADR-0007), allocated lazily only when
/// an answer actually accrues a queued call, a listener, or a stored
/// resolution. The overwhelming majority of answers never do, so keeping this
/// off the hot [`AnswerEntry`] row (which is then just a status + refcount)
/// shrinks the common answer from ~80 bytes to a handful.
const AnswerPayload = struct {
    /// Pipelined `op:deliver`s that arrived for this answer while it was still
    /// `pending`. FIFO; each is an owned [`model.Message`] released on drain or
    /// removal.
    queue: std.ArrayList(model.Message) = .empty,
    /// Parties listening for this answer's resolution. Each owns its `target`.
    listeners: std.ArrayList(ListenerEntry) = .empty,
    /// The resolution, stored once the answer resolves so a late `op:listen`
    /// fires immediately. Owned; released on removal.
    resolution: ?model.Resolution = null,
};

/// Hot answer row: just the state-machine fields read on every lookup. The
/// pipelining payload hangs off `payload`, present only when needed.
pub const AnswerEntry = struct {
    status: AnswerStatus,
    /// Single-reference wire-delta count per ADR-0008 `op:gc-answers`.
    /// Initialized to 1 on install; decremented to 0 (and the row removed)
    /// on the matching GC message. Answers are single-ref, so the delta is
    /// implicitly 1.
    count: u64 = 1,
    /// Lazily-allocated cold payload (queued calls / listeners / resolution).
    payload: ?*AnswerPayload = null,
};

/// By-value snapshot of an answer's observable state, returned by the public
/// [`Session.inboundAnswer`] / [`Session.outboundAnswer`] accessors. The hot
/// row is now stored struct-of-arrays style (and its payload is behind a
/// pointer), so callers get a stable value rather than a borrow into the table.
pub const AnswerView = struct {
    status: AnswerStatus,
    count: u64,
    /// Number of pipelined calls queued against this answer.
    queued_calls: usize,
    /// Number of listeners registered on this answer.
    listeners: usize,
    /// Whether a resolution has been stored for this answer.
    resolved: bool,

    fn of(entry: *const AnswerEntry) AnswerView {
        return .{
            .status = entry.status,
            .count = entry.count,
            .queued_calls = if (entry.payload) |p| p.queue.items.len else 0,
            .listeners = if (entry.payload) |p| p.listeners.items.len else 0,
            .resolved = if (entry.payload) |p| p.resolution != null else false,
        };
    }
};

/// Position-keyed answer table (ADR-0007). Inbound and outbound answers are
/// addressed by dense, monotonic answer-pos; this maps the position straight to
/// its row in O(1) instead of the prior linear scan. Same integer-keyed-hash
/// rationale as [`SlotTable`]: partner-allocated inbound positions must not size
/// a raw index vector. The row count is bounded by the resilience caps.
pub const AnswerTable = struct {
    rows: std.AutoHashMapUnmanaged(u64, AnswerEntry) = .empty,

    const empty: AnswerTable = .{};

    fn deinit(self: *AnswerTable, allocator: std.mem.Allocator) void {
        var it = self.rows.valueIterator();
        while (it.next()) |entry| deinitAnswerEntry(allocator, entry);
        self.rows.deinit(allocator);
    }

    /// Mutable borrow of the row for `id`, or null when absent. Valid until the
    /// next insert into this table (a `put` may rehash and move rows).
    pub fn getPtr(self: *AnswerTable, id: u64) ?*AnswerEntry {
        return self.rows.getPtr(id);
    }

    pub fn contains(self: *const AnswerTable, id: u64) bool {
        return self.rows.contains(id);
    }

    /// Refcount of `id`, or 0 if the answer is not held.
    pub fn count(self: *const AnswerTable, id: u64) u64 {
        if (self.rows.getPtr(id)) |entry| return entry.count;
        return 0;
    }

    /// Number of live answer rows — the value the inbound-answer cap bounds.
    pub fn len(self: *const AnswerTable) usize {
        return self.rows.count();
    }

    pub fn put(self: *AnswerTable, allocator: std.mem.Allocator, id: u64, entry: AnswerEntry) !void {
        try self.rows.put(allocator, id, entry);
    }

    pub fn remove(self: *AnswerTable, id: u64) void {
        _ = self.rows.remove(id);
    }
};

/// Borrow the answer's payload, allocating it on first use. The returned pointer
/// is owned by the entry and freed by [`deinitAnswerEntry`].
fn ensureAnswerPayload(allocator: std.mem.Allocator, entry: *AnswerEntry) !*AnswerPayload {
    if (entry.payload) |payload| return payload;
    const payload = try allocator.create(AnswerPayload);
    payload.* = .{};
    entry.payload = payload;
    return payload;
}

/// A promise imported from a *third party* via handoff (ADR-0009 § `op:listen`
/// on `desc:import-promise`). The introducing partner gave us this import; its
/// eventual resolution lives on the third-party `host`, not on the direct
/// partner, so it is forwarded to us as a *relayed resolution* rather than a
/// direct `op:resolve`.
///
/// The presence of a row marks `import_id` third-party-hosted — the distinction
/// that lets an inbound `op:listen` on this import install a listener here rather
/// than be rejected. Grouping the host, listeners, and resolution in one owned
/// row gives the third-party promise a single lifecycle.
pub const ImportedPromise = struct {
    /// The third-party host this promise lives on (owned designator bytes). Held
    /// so a re-root with a conflicting host is rejected ([`Error.HostMismatch`]).
    host: []u8,
    /// Parties listening (via `op:listen` on `desc:import-promise`) for the
    /// relayed resolution. Each owns its `target`.
    listeners: std.ArrayList(ListenerEntry) = .empty,
    /// The relayed resolution once forwarded, stored so a late `op:listen` fires
    /// immediately. Owned; released on removal.
    resolution: ?model.Resolution = null,
};

/// One resolved sturdyref enlivenment (ADR-0012 dedup cache): the swiss-number
/// and the `(import_id, kind)` it resolved to. The kind is preserved verbatim so
/// the cache-hit short-circuit reconstructs the `FarRef` with its wire-tag
/// discriminator intact (ADR-0010 § The far-kind is preserved across enliven).
/// Owns its `swissnum`.
pub const SturdyrefCacheEntry = struct {
    swissnum: []u8,
    import_id: u64,
    kind: model.ImportKind,
};

/// One in-flight sturdyref enliven (ADR-0012 dedup): a bootstrap-fetch for
/// `swissnum` is outstanding on `answer_id`. A second enliven for the same
/// swiss-number collapses onto this answer instead of issuing a duplicate fetch.
/// Owns its `swissnum`.
/// A gift deposited by a gifter on the exporter, awaiting withdrawal by the
/// recipient named in `recipient_key`. The exporter session is the authority for
/// whether a `handoff-receive` may withdraw it. Keyed by gift id in the [`gifts`]
/// table; `recipient_key` and `gifter_key` bytes live in the session key arena.
///
/// `gifter_key` is the session public key of the gifter that deposited the gift —
/// the partner key of the gifter-to-exporter session. The session stores it as
/// opaque provenance bytes (it runs no crypto) so an embedder can verify the
/// gifter's `desc:handoff-give` signature against the key the exporter recorded at
/// deposit, the way it verifies a location signature with a session key
/// (ADR-0009). It is empty only for a gift deposited without a known gifter key.
pub const GiftEntry = struct {
    recipient_key: []const u8,
    gifter_key: []const u8,
    withdrawn: bool,
    /// The capability the gifter deposited, returned on a successful withdraw.
    /// Owned by the session GPA; freed at teardown.
    gifted: ?model.Reference = null,
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    state: State,
    wire_profile: model.WireProfile,
    /// The wire codec negotiated for this direct session. The
    /// authoritative record of the codec choice; the engine's codec-dispatch
    /// boundary ([`codec.dispatch`]) reads it to route each frame, and every event
    /// the session produces is tagged with it. Defaults to `.syrup` for the
    /// non-negotiating constructors.
    codec: model.CodecId,
    features: model.FeatureSet,
    limits: SessionLimits,
    next_export_id: u64,
    /// Monotonic allocator for the answer-pos we put on outbound `op:deliver`s
    /// (bootstrap-fetch, pipeline decomposition). Per-direction namespace: our
    /// outbound answers are independent of the partner's inbound answer ids.
    next_outbound_answer: u64 = 0,
    /// Virtual answers allocated by V1.0 resolver-only fetches (the partner sent
    /// `resolve_me_desc` with no `answer_position`). Uses a separate namespace
    /// starting at a high sentinel so it cannot collide with the partner's actual
    /// answer-position choices.
    next_virtual_inbound_answer: u64 = 0x8000_0000_0000_0000,
    /// V1.0 resolver exports use a separate namespace starting at a high sentinel
    /// so they never collide with actor/bootstrap exports. The V1.0 translation
    /// allocates these for outbound `op:deliver`s that need a resolver callback.
    next_v1_0_resolver_export: u64 = 0x4000_0000_0000_0000,
    /// One per-session bump arena owning the byte keys/values of the *monotonic*
    /// byte-keyed tables — `bootstrap` swissnums, `gifts` ids + recipient keys,
    /// and `handoff_counts` session ids — none of which ever free an individual
    /// row. Teardown is one `key_arena.deinit()` instead of three per-row free
    /// loops. The evicting / individually-removed tables (`sturdyref_cache`,
    /// `pending_enlivens`, imported-promise hosts) deliberately stay on the gpa
    /// with precise per-row frees: a bump arena cannot reclaim an evicted row and
    /// would leak under churn.
    key_arena: std.heap.ArenaAllocator,
    /// Per-turn scratch arena for the recv owned-fallback kinds (`gc_*`,
    /// `handoff`, `get`/`index`). Those few sub-structure-heavy messages
    /// materialize one transient owned `Message` to feed the shared owned
    /// validate / apply, then it dies when the turn ends — exactly an arena's
    /// lifetime. Reset (retaining capacity) at the end of every `recordRecvView`,
    /// so the scratch never outlives one turn and the per-message
    /// dupe-then-`freeMessage` choreography collapses to one bump-and-reset. The
    /// hot path (deliver / resolve / ...) validates from the borrowed view and
    /// never touches this. Apply dupes anything session-lived onto `allocator`,
    /// so resetting the scratch can never dangle a table row.
    recv_scratch: std.heap.ArenaAllocator,
    exports: SlotTable,
    imports: SlotTable,
    inbound_answers: AnswerTable,
    outbound_answers: AnswerTable,
    /// Deposited gifts keyed by gift id (ADR-0009). Key + `recipient_key` bytes
    /// live in `key_arena`; O(1) lookup. Gifts are never individually removed.
    gifts: std.StringHashMapUnmanaged(GiftEntry),
    /// Highest accepted `handoff_count` per receiving session id (replay guard).
    /// Session-id keys live in `key_arena`; O(1) lookup. Never removed.
    handoff_counts: std.StringHashMapUnmanaged(u64),
    /// Promises imported from a third party via handoff (ADR-0009), keyed by
    /// import id. Each row owns its host designator, listener targets, and stored
    /// relayed resolution. O(1) lookup; the prior linear scan is gone.
    imported_promises: std.AutoHashMapUnmanaged(u64, ImportedPromise),
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
    /// V1.0 resolver-callback links for our *outbound* answers, mapping a
    /// resolver-export id to an answer-pos. An inbound deliver to that export is
    /// the partner resolving the answer. Keyed for the reverse lookup that runs
    /// per inbound deliver. See [`OutboundResolvers`].
    v1_0_outbound_resolvers: OutboundResolvers,
    /// V1.0 resolver-callback links for the partner's *inbound* answers, mapping
    /// an answer-pos to the resolver import id we target when we send our
    /// resolution. See [`InboundResolvers`].
    v1_0_inbound_resolvers: InboundResolvers,
    /// Resolved sturdyref enlivenments, mapping a swissnum to its `(import, kind)`
    /// (ADR-0012 dedup).
    /// FIFO-evicting (cap `max_sturdyref_cache_entries`), so it keeps insertion
    /// order and owns each swissnum on the gpa — freed precisely on eviction.
    sturdyref_cache: std.ArrayList(SturdyrefCacheEntry),
    /// In-flight sturdyref enlivens, mapping a swissnum to its outstanding answer
    /// (ADR-0012 dedup). O(1) lookup; rows are removed on completion, so swissnum
    /// keys are gpa-owned and freed on removal.
    pending_enlivens: std.StringHashMapUnmanaged(u64),
    /// The swissnum-to-export registry the inbound-`'fetch` responder consults
    /// (ADR-0006). Keys live in `key_arena`; O(1) lookup. Never removed.
    bootstrap: std.StringHashMapUnmanaged(u64),

    /// Construction knobs for [`initWith`]. Every field has a default, so a
    /// caller names only what it overrides: `Session.init(allocator)` is
    /// `initWith(allocator, .{})`. The four knobs are orthogonal — `negotiating`
    /// selects the starting [`State`], the rest set the negotiated
    /// profile / codec / features the handshake would otherwise install.
    pub const Options = struct {
        /// Start in `negotiating` (awaiting `op:start-session`) instead of `open`.
        negotiating: bool = false,
        codec: model.CodecId = .syrup,
        wire_profile: model.WireProfile = model.WireProfile.pre_spec,
        features: model.FeatureSet = model.FeatureSet.full(),
    };

    /// Open session, all defaults — `initWith(allocator, .{})`.
    pub fn init(allocator: std.mem.Allocator) Session {
        return initWith(allocator, .{});
    }

    /// Session that begins in `negotiating`, awaiting the `op:start-session`
    /// handshake on the default profile / feature set. The in-process handshake
    /// driver ([`engine.pairing`]) constructs both peers this way; use
    /// [`initWith`] with `.negotiating = true` to override the negotiated knobs.
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
            .limits = .{},
            .next_export_id = 0,
            .key_arena = std.heap.ArenaAllocator.init(allocator),
            .recv_scratch = std.heap.ArenaAllocator.init(allocator),
            .exports = .empty,
            .imports = .empty,
            .inbound_answers = .empty,
            .outbound_answers = .empty,
            .gifts = .empty,
            .handoff_counts = .empty,
            .imported_promises = .empty,
            .handshake_local_sent = false,
            .handshake_remote_received = false,
            .partner_session_key = &.{},
            .partner_designator = &.{},
            .v1_0_outbound_resolvers = .empty,
            .v1_0_inbound_resolvers = .empty,
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
        // gifts / handoff_counts / bootstrap key + value bytes live in
        // `key_arena`, freed wholesale below; gifted refs use the GPA.
        var gift_it = self.gifts.iterator();
        while (gift_it.next()) |entry| {
            if (entry.value_ptr.gifted) |gifted| model.freeReference(self.allocator, gifted);
        }
        self.gifts.deinit(self.allocator);
        self.handoff_counts.deinit(self.allocator);
        self.bootstrap.deinit(self.allocator);
        var imported_it = self.imported_promises.valueIterator();
        while (imported_it.next()) |entry| deinitImportedPromise(self.allocator, entry);
        self.imported_promises.deinit(self.allocator);
        self.v1_0_outbound_resolvers.deinit(self.allocator);
        self.v1_0_inbound_resolvers.deinit(self.allocator);
        for (self.sturdyref_cache.items) |entry| self.allocator.free(entry.swissnum);
        self.sturdyref_cache.deinit(self.allocator);
        var enliven_it = self.pending_enlivens.keyIterator();
        while (enliven_it.next()) |key| self.allocator.free(key.*);
        self.pending_enlivens.deinit(self.allocator);
        self.key_arena.deinit();
        self.recv_scratch.deinit();
    }

    /// Whether this session's negotiated wire profile is Goblins V1.0, which has
    /// no native `op:resolve` and therefore needs resolver-callback translation.
    pub fn needsV1_0Translation(self: *const Session) bool {
        return self.wire_profile.isGoblinsV1_0();
    }

    /// Record that our outbound `answer` is resolved via local resolver export
    /// `resolver_export` (the id we advertised in `resolve_me_desc`). Committed
    /// after the augmented deliver is accepted.
    pub fn installOutboundResolver(self: *Session, answer: u64, resolver_export: u64) !void {
        try self.v1_0_outbound_resolvers.put(self.allocator, resolver_export, answer);
    }

    /// Record that the partner's inbound `answer` is resolved via their resolver
    /// import `resolver_import` (advertised in the deliver's `resolve_me_desc`).
    pub fn installInboundResolver(self: *Session, answer: u64, resolver_import: u64) !void {
        try self.registerImport(resolver_import);
        try self.v1_0_inbound_resolvers.put(self.allocator, answer, resolver_import);
    }

    /// The partner's resolver import for an inbound `answer`, if one was
    /// advertised — the target our outbound resolution deliver addresses.
    pub fn resolverForInboundAnswer(self: *const Session, answer: u64) ?u64 {
        return self.v1_0_inbound_resolvers.get(answer);
    }

    /// The inbound `answer` a resolver import was installed for — the reverse
    /// of `resolverForInboundAnswer`. Used by bootstrap-fetch detection when the
    /// V1.0 resolver-only pattern has no wire answer-position.
    pub fn answerForResolverImport(self: *const Session, resolver_import: u64) ?u64 {
        var it = self.v1_0_inbound_resolvers.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* == resolver_import) return entry.key_ptr.*;
        }
        return null;
    }

    /// Allocate a fresh virtual inbound answer for V1.0 resolver-only fetches.
    pub fn allocateInboundAnswer(self: *Session) u64 {
        const id = self.next_virtual_inbound_answer;
        self.next_virtual_inbound_answer +%= 1;
        return id;
    }

    /// Allocate a V1.0 resolver export from a separate namespace that cannot
    /// collide with actor/bootstrap exports.
    pub fn allocateV1_0ResolverExport(self: *Session) !u64 {
        const id = self.next_v1_0_resolver_export;
        try self.exports.register(self.allocator, id);
        self.next_v1_0_resolver_export +%= 1;
        return id;
    }

    /// Our outbound `answer` an inbound deliver to `resolver_export` resolves, if
    /// that export is a known resolver — the signal to translate the inbound
    /// deliver into a semantic `Resolve`.
    pub fn answerForResolverExport(self: *const Session, resolver_export: u64) ?u64 {
        return self.v1_0_outbound_resolvers.get(resolver_export);
    }

    pub fn open(self: *Session) void {
        self.state = .open;
    }

    /// Both handshake halves observed — the precondition for `open`.
    pub fn handshakeComplete(self: *const Session) bool {
        return self.handshake_local_sent and self.handshake_remote_received;
    }

    /// Moves the session from `Negotiating` to `Open`. It installs the fixed
    /// bootstrap export at
    /// [`BOOTSTRAP_EXPORT_ID`] (the only fallible step) then flips state, so a
    /// failed registration leaves the session untouched. Called from the
    /// `start_session` apply arms once both handshake halves are observed.
    pub fn transitionToOpen(self: *Session) !void {
        try self.exports.register(self.allocator, BOOTSTRAP_EXPORT_ID);
        // Reserve the bootstrap id: locally-allocated exports (resolver callbacks,
        // promises, gifts) start past it so `allocateExport` never aliases it.
        if (self.next_export_id <= BOOTSTRAP_EXPORT_ID) {
            self.next_export_id = BOOTSTRAP_EXPORT_ID + 1;
        }
        self.state = .open;
    }

    pub fn beginDrain(self: *Session) void {
        self.state = .draining;
    }

    pub fn close(self: *Session) void {
        self.state = .closed;
    }

    pub fn registerExport(self: *Session, id: u64) !void {
        try self.exports.register(self.allocator, id);
        if (id >= self.next_export_id) {
            self.next_export_id = id + 1;
        }
    }

    /// Retain a partner-driven import. A *new* id is bounded by
    /// [`SessionLimits.max_imports`] (ADR-0025) — a partner cannot grow our import
    /// table without limit. Already-held ids increment their wire-delta refcount:
    /// a partner may introduce the same export multiple times, and our later
    /// `op:gc-exports` must release the same total delta.
    pub fn registerImport(self: *Session, id: u64) !void {
        if (!self.imports.contains(id) and
            self.imports.len() >= self.limits.max_imports)
        {
            return Error.ImportCapExceeded;
        }
        try self.imports.retain(self.allocator, id);
    }

    /// Install `id` as a pending inbound answer we owe resolution for. Idempotent;
    /// bounded by [`SessionLimits.max_inbound_answers`]. Used when the engine
    /// redirects a drained pipelined call to a local export — the forwarded
    /// call's own answer becomes one we must resolve, even though no wire
    /// `op:deliver` installed it through `recordRecv`.
    pub fn installInboundAnswer(self: *Session, id: u64) !void {
        try self.installAnswer(&self.inbound_answers, id);
    }

    /// Exhaustive session-state admission gate (ADR-0006), run at every dispatch
    /// head. The `switch (self.state)` is *total*: a new `State` variant will not
    /// compile until it declares what it admits, so "admit everything" can never
    /// be the silent default a buried `else if (state == .negotiating)` left it.
    /// `closed` admits nothing; `negotiating` admits only the handshake
    /// (`op:start-session`) and `op:abort`; `open` and `draining` admit every
    /// kind so in-flight traffic finishes. Kind-specific rules (a second
    /// `op:start-session`, target authority, feature gates) stay in the
    /// per-message validators; this is purely the state machine. Accepts either
    /// an owned `model.Message` or a borrowed `model.view.Body` — both share the
    /// op-kind tag names the gate switches on.
    fn admitInState(self: *const Session, message: anytype) Error!void {
        switch (self.state) {
            .closed => return Error.SessionClosed,
            .negotiating => switch (message) {
                .start_session, .abort => {},
                else => return Error.UnexpectedMessage,
            },
            .open, .draining => {},
        }
    }

    /// The state-admission gate, exposed so the engine can apply it *before* any
    /// pre-`recordRecv` authority mutation it performs (a pipelined-call enqueue, a
    /// listener install, a V1.0 resolver registration). `recordRecv*` gate
    /// themselves, but those engine pre-steps run ahead of `recordRecv` and the
    /// pipelined path returns without ever reaching it — so a closed session would
    /// otherwise queue a pipelined deliver, failing open. Checking here keeps
    /// `closed` a terminal refusal for every inbound kind.
    pub fn admits(self: *const Session, body: model.view.Body) Error!void {
        return self.admitInState(body);
    }

    pub fn recordSend(self: *Session, message: model.Message) !void {
        try self.admitInState(message);
        try self.validateSend(message);
        try self.applySend(message);
    }

    pub fn recordRecv(self: *Session, message: model.Message) !void {
        try self.admitInState(message);
        try self.validateRecv(message);
        try self.applyRecv(message);
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
    /// The rarer, sub-structure-heavy kinds (`gc_*`, `handoff`, `get`/`index`)
    /// fall back to one owned materialization for the existing owned validate /
    /// apply — they are off the hot path and not worth a second borrowed walk.
    pub fn recordRecvView(self: *Session, body: model.view.Body) !void {
        try self.admitInState(body);
        switch (body) {
            .deliver, .resolve, .listen, .start_session, .abort => {
                try self.validateRecvView(body);
                try self.applyRecvView(body);
            },
            .gc_export, .gc_answer, .handoff, .get, .index => {
                // One transient owned copy to feed the shared owned validate /
                // apply. It is pure turn-scratch — apply dupes anything
                // session-lived onto `self.allocator` — so it lives in the
                // per-turn arena and dies with one reset, no per-row free walk.
                defer _ = self.recv_scratch.reset(.retain_capacity);
                const owned = try body.toOwned(self.recv_scratch.allocator());
                try self.validateRecv(owned);
                try self.applyRecv(owned);
            },
        }
    }

    // Validation lives in `validate.zig`; apply lives in `apply.zig`. Both are
    // methods of `Session` aliased here, so `self.validateSend(msg)` and
    // `self.applySend(msg)` resolve as before. Validation never mutates; apply
    // commits only after validation passes.
    const validate = @import("validate.zig");
    const apply = @import("apply.zig");

    pub const validateRecvView = validate.validateRecvView;
    pub const validateInboundResolve = validate.validateInboundResolve;
    pub const validateSend = validate.validateSend;
    pub const validateRecv = validate.validateRecv;
    pub const validateOutboundDeliver = validate.validateOutboundDeliver;
    pub const validateInboundDeliverAny = validate.validateInboundDeliverAny;
    pub const validatePipelinedDeliver = validate.validatePipelinedDeliver;
    pub const validateTargetReference = validate.validateTargetReference;
    pub const validateArgumentReference = validate.validateArgumentReference;
    pub const validateInboundArguments = validate.validateInboundArguments;
    pub const validateInboundArgument = validate.validateInboundArgument;
    pub const validateOutboundReference = validate.validateOutboundReference;
    pub const validateArguments = validate.validateArguments;
    pub const validateArgument = validate.validateArgument;

    pub const applyRecvView = apply.applyRecvView;
    pub const applySend = apply.applySend;
    pub const applyRecv = apply.applyRecv;
    pub const installIntroducedImports = apply.installIntroducedImports;
    pub const installIntroducedImport = apply.installIntroducedImport;
    pub const retainSentExports = apply.retainSentExports;
    pub const retainSentExportRef = apply.retainSentExportRef;
    pub const retainSentExportArgs = apply.retainSentExportArgs;
    pub const retainSentExportArg = apply.retainSentExportArg;
    pub const applyGcAnswerDecrementInbound = apply.applyGcAnswerDecrementInbound;
    pub const applyGcAnswerDecrementOutbound = apply.applyGcAnswerDecrementOutbound;
    pub const removeOutboundResolverByAnswer = apply.removeOutboundResolverByAnswer;
    pub const decrementAnswer = apply.decrementAnswer;
    pub const installAnswer = apply.installAnswer;

    pub fn inboundAnswer(self: *Session, id: u64) ?AnswerView {
        const entry = self.inbound_answers.getPtr(id) orelse return null;
        return AnswerView.of(entry);
    }

    pub fn outboundAnswer(self: *Session, id: u64) ?AnswerView {
        const entry = self.outbound_answers.getPtr(id) orelse return null;
        return AnswerView.of(entry);
    }

    pub fn hasExport(self: *Session, id: u64) bool {
        return self.exports.contains(id);
    }

    pub fn hasImport(self: *Session, id: u64) bool {
        return self.imports.contains(id);
    }

    /// Current wire-delta refcount for a local export (0 if not live).
    pub fn exportRefcount(self: *Session, id: u64) u64 {
        return self.exports.count(id);
    }

    /// Current wire-delta refcount for an import of a partner export (0 if
    /// not live).
    pub fn importRefcount(self: *Session, id: u64) u64 {
        return self.imports.count(id);
    }

    pub fn allocateExport(self: *Session) !u64 {
        const id = self.next_export_id;
        try self.exports.register(self.allocator, id);
        self.next_export_id = id + 1;
        return id;
    }

    /// Release an export this session just allocated with `allocateExport` and
    /// never handed to the partner — the rollback half of a locally-aborted
    /// operation that allocated an export before a later step failed. The slot is
    /// live at count 1 by construction, so the decrement removes it and cannot
    /// underflow. The monotonic `next_export_id` is left advanced: a skipped id is
    /// not a leak, and ids are never reused.
    pub fn releaseUnsharedExport(self: *Session, id: u64) void {
        self.exports.decrement(id, 1) catch {};
    }

    /// Expose a local capability behind `swissnum` for inbound bootstrap-fetch
    /// (ADR-0006 responder half): allocate a fresh export and map the swissnum to
    /// it. Returns the export id. Re-registering a swissnum replaces its mapping.
    pub fn registerBootstrapCap(self: *Session, swissnum: []const u8) !u64 {
        const export_id = try self.allocateExport();
        const gop = try self.bootstrap.getOrPut(self.allocator, swissnum);
        if (!gop.found_existing) {
            // getOrPut left the slot keyed on the borrowed `swissnum`; replace it
            // with an arena-owned copy, removing the slot if the copy fails so no
            // dangling borrowed key survives.
            gop.key_ptr.* = self.key_arena.allocator().dupe(u8, swissnum) catch |err| {
                _ = self.bootstrap.remove(swissnum);
                return err;
            };
        }
        gop.value_ptr.* = export_id;
        return export_id;
    }

    /// The local export serving `swissnum`, or null if none is registered.
    pub fn bootstrapLookup(self: *const Session, swissnum: []const u8) ?u64 {
        return self.bootstrap.get(swissnum);
    }

    /// Reserve the next outbound answer-pos. The id is installed in the outbound
    /// answer table when the carrying `op:deliver` is recorded on send; this only
    /// advances the counter so concurrent fetches / decompositions don't collide.
    pub fn allocateOutboundAnswer(self: *Session) u64 {
        const id = self.next_outbound_answer;
        self.next_outbound_answer += 1;
        return id;
    }

    /// Deposit a gift on this (exporter) session, making it withdrawable by the
    /// recipient named in `recipient_key`. `gifter_key` is the depositing gifter's
    /// session public key (the partner key of the gifter-to-exporter session),
    /// stored as opaque provenance so an embedder can later verify the gifter's
    /// `desc:handoff-give` signature against it; pass an empty slice when no gifter
    /// key is known. Duplicate gift ids are rejected.
    /// Bootstrap `deposit-gift`: record `gifted` under `gift_id`. `recipient_key`
    /// may be empty — the handoff-give names the recipient at withdraw time.
    pub fn depositGiftCap(self: *Session, gift_id: []const u8, gifted: model.Reference, gifter_key: []const u8) !void {
        if (gift_id.len == 0) return Error.MalformedMessage;
        if (self.findGift(gift_id) != null) return Error.InvalidGift;
        if (self.gifts.count() >= self.limits.max_deposited_gifts) {
            return Error.DepositedGiftCapExceeded;
        }

        const arena = self.key_arena.allocator();
        const id_copy = try arena.dupe(u8, gift_id);
        const gifter_copy = try arena.dupe(u8, gifter_key);
        const gifted_copy = try model.cloneReference(self.allocator, gifted);
        errdefer model.freeReference(self.allocator, gifted_copy);

        const gop = try self.gifts.getOrPut(self.allocator, id_copy);
        gop.key_ptr.* = id_copy;
        gop.value_ptr.* = .{
            .recipient_key = "",
            .gifter_key = gifter_copy,
            .withdrawn = false,
            .gifted = gifted_copy,
        };
    }

    pub fn depositGift(self: *Session, gift_id: []const u8, recipient_key: []const u8, gifter_key: []const u8) !void {
        if (gift_id.len == 0 or recipient_key.len == 0) return Error.MalformedMessage;
        if (self.findGift(gift_id) != null) return Error.InvalidGift;
        if (self.gifts.count() >= self.limits.max_deposited_gifts) {
            return Error.DepositedGiftCapExceeded;
        }

        // Gifts are never individually removed, so the id key and the recipient-
        // and gifter-key value bytes live in the per-session arena (one free at
        // teardown).
        const arena = self.key_arena.allocator();
        const id_copy = try arena.dupe(u8, gift_id);
        const key_copy = try arena.dupe(u8, recipient_key);
        const gifter_copy = try arena.dupe(u8, gifter_key);
        const gop = try self.gifts.getOrPut(self.allocator, id_copy);
        gop.key_ptr.* = id_copy;
        gop.value_ptr.* = .{ .recipient_key = key_copy, .gifter_key = gifter_copy, .withdrawn = false };
    }

    pub fn giftDeposited(self: *Session, gift_id: []const u8) bool {
        return self.findGift(gift_id) != null;
    }

    /// The session public key the depositing gifter signed its `desc:handoff-give`
    /// with, recorded at deposit. An embedder verifies the give certificate against
    /// it; null if the gift is unknown, empty if it was deposited without a key.
    pub fn giftGifterKey(self: *Session, gift_id: []const u8) ?[]const u8 {
        if (self.findGift(gift_id)) |gift| return gift.gifter_key;
        return null;
    }

    /// The partner's session public key, learned from its `op:start-session`, or
    /// null if the partner's handshake half has not yet arrived with a key. An
    /// embedder verifies the partner's signatures against it — for a
    /// gifter-to-exporter session, this is the key the gifter's `desc:handoff-give`
    /// is signed with, so the exporter can record it with a deposited gift.
    pub fn partnerSessionKey(self: *const Session) ?[]const u8 {
        if (self.partner_session_key.len == 0) return null;
        return self.partner_session_key;
    }

    /// The partner's location designator from its `op:start-session`, or null if
    /// the handshake half has not arrived with one.
    pub fn partnerDesignator(self: *const Session) ?[]const u8 {
        if (self.partner_designator.len == 0) return null;
        return self.partner_designator;
    }

    pub fn giftWithdrawn(self: *Session, gift_id: []const u8) bool {
        if (self.findGift(gift_id)) |gift| return gift.withdrawn;
        return false;
    }

    /// The capability deposited for `gift_id`, or null when unknown or already withdrawn.
    pub fn giftedCap(self: *Session, gift_id: []const u8) ?model.Reference {
        const gift = self.findGift(gift_id) orelse return null;
        if (gift.withdrawn) return null;
        return gift.gifted;
    }

    pub fn validateInboundWithdraw(self: *Session, receive: model.HandoffReceive) Error!void {
        const gift = self.findGift(receive.signed_give.gift_id) orelse return Error.InvalidGift;
        if (gift.withdrawn) return Error.InvalidGift;
        if (gift.recipient_key.len > 0 and
            !std.mem.eql(u8, gift.recipient_key, receive.signed_give.recipient_key))
        {
            return Error.InvalidGift;
        }
        if (self.lastHandoffCount(receive.receiving_session)) |last| {
            if (receive.handoff_count <= last) return Error.HandoffReplay;
        }
    }

    pub fn applyInboundWithdraw(self: *Session, receive: model.HandoffReceive) !void {
        // Record the count first (the only fallible step); marking the gift
        // withdrawn afterwards cannot fail, so the apply stays atomic.
        try self.recordHandoffCount(receive.receiving_session, receive.handoff_count);
        if (self.findGiftMut(receive.signed_give.gift_id)) |gift| {
            gift.withdrawn = true;
        }
    }

    fn recordHandoffCount(self: *Session, session_id: []const u8, count: u64) !void {
        if (self.handoff_counts.getPtr(session_id)) |last_count| {
            last_count.* = count;
            return;
        }
        if (self.handoff_counts.count() >= self.limits.max_seen_handoff_counts) {
            return Error.HandoffCountCapExceeded;
        }
        // Handoff counters are never removed, so the session-id key lives in the
        // per-session arena (one free at teardown).
        const copy = try self.key_arena.allocator().dupe(u8, session_id);
        const gop = try self.handoff_counts.getOrPut(self.allocator, copy);
        gop.key_ptr.* = copy;
        gop.value_ptr.* = count;
    }

    fn lastHandoffCount(self: *Session, session_id: []const u8) ?u64 {
        return self.handoff_counts.get(session_id);
    }

    fn findGift(self: *Session, gift_id: []const u8) ?*const GiftEntry {
        return self.gifts.getPtr(gift_id);
    }

    fn findGiftMut(self: *Session, gift_id: []const u8) ?*GiftEntry {
        return self.gifts.getPtr(gift_id);
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
    /// answer `answer_id`), taking ownership of `message`. On any failure the
    /// message is freed so the caller never double-frees. The answer must exist
    /// and be `pending`; a resolved or unknown answer is the caller's contract
    /// violation, surfaced as [`Error.InvalidReference`].
    pub fn enqueuePipelinedCall(self: *Session, answer_id: u64, message: model.Message) !void {
        errdefer model.freeMessage(self.allocator, message);
        const entry = self.inbound_answers.getPtr(answer_id) orelse
            return Error.InvalidReference;
        if (entry.status != .pending) return Error.InvalidReference;
        const queued = if (entry.payload) |p| p.queue.items.len else 0;
        if (queued >= self.limits.queue_cap) return Error.QueueCapExceeded;
        const payload = try ensureAnswerPayload(self.allocator, entry);
        try payload.queue.append(self.allocator, message);
    }

    /// Hand the caller the queued pipelined calls for `answer_id`, transferring
    /// ownership of every message and leaving the answer's queue empty. Returns
    /// an empty slice for an unknown answer or empty queue. The caller owns the
    /// returned slice (free each message, then free the slice with `allocator`).
    pub fn takePipelinedCalls(self: *Session, answer_id: u64) ![]model.Message {
        const entry = self.inbound_answers.getPtr(answer_id) orelse
            return &.{};
        const payload = entry.payload orelse return &.{};
        if (payload.queue.items.len == 0) return &.{};
        const drained = try payload.queue.toOwnedSlice(self.allocator);
        return drained;
    }

    /// Hand the caller the listeners registered on `answer_id`, transferring
    /// ownership of every entry's target and leaving the answer's listener list
    /// empty. Returns an empty slice for an unknown answer or no listeners. The
    /// caller owns the returned slice (release each entry's target, then free the
    /// slice with `allocator`).
    pub fn takePipelinedListeners(self: *Session, answer_id: u64) ![]ListenerEntry {
        const entry = self.inbound_answers.getPtr(answer_id) orelse
            return &.{};
        const payload = entry.payload orelse return &.{};
        if (payload.listeners.items.len == 0) return &.{};
        const drained = try payload.listeners.toOwnedSlice(self.allocator);
        return drained;
    }

    /// Move a batch of pipelined `calls` (owned messages, e.g. drained from an
    /// answer that resolved to another promise) onto `target`'s queue, taking
    /// ownership of the slice and every message. `seen` is the set of answer ids
    /// the caller knows are on this resolution chain; if `target` is among them
    /// the requeue would loop, so it fails with [`Error.ResolutionCycle`].
    ///
    /// The engine caller passes the single just-resolved answer, so the `seen`
    /// check catches a promise that resolves directly to itself. A longer chain
    /// (A resolves to B, then B back to A) is caught by a second, stronger
    /// invariant: `target` must be `.pending`, and resolving an answer settles it
    /// before its calls drain (`recordSend` runs at send time). So to move a batch
    /// onward from A you resolve A — settling it — and any later attempt to requeue
    /// the batch back onto A finds A no longer pending and fails with
    /// `InvalidReference`, freeing the batch. A resolution chain therefore cannot
    /// loop: it can only move forward through still-pending answers (bounded by the
    /// inbound-answer cap) until it reaches a non-promise resolution or a settled
    /// answer. No chain history is needed, and there is no infinite bounce or
    /// amplification — see the "multi-hop pipeline cycle terminates" engine test.
    ///
    /// On any failure the whole batch is freed (no partial move — capacity is
    /// reserved up front so the moves are infallible). `target` must be a pending
    /// inbound answer.
    pub fn requeuePipelinedCalls(self: *Session, target: u64, seen: []const u64, calls: []model.Message) !void {
        var moved = false;
        errdefer if (!moved) {
            for (calls) |message| model.freeMessage(self.allocator, message);
            self.allocator.free(calls);
        };

        for (seen) |id| {
            if (id == target) return Error.ResolutionCycle;
        }
        const entry = self.inbound_answers.getPtr(target) orelse
            return Error.InvalidReference;
        if (entry.status != .pending) return Error.InvalidReference;
        const queued = if (entry.payload) |p| p.queue.items.len else 0;
        if (queued + calls.len > self.limits.queue_cap) return Error.QueueCapExceeded;

        // Reserve first (the only fallible step); the moves are then infallible,
        // so ownership transfers atomically — no message is half-moved.
        const payload = try ensureAnswerPayload(self.allocator, entry);
        try payload.queue.ensureUnusedCapacity(self.allocator, calls.len);
        for (calls) |message| payload.queue.appendAssumeCapacity(message);
        moved = true;
        self.allocator.free(calls);
    }

    /// Register `listener` (taking ownership of its `target`) as wanting
    /// `answer_id`'s resolution. On failure the target is freed. The answer must
    /// exist; it may be `pending` or already resolved (a late listener — the
    /// engine fires it immediately from the stored resolution).
    pub fn installListener(self: *Session, answer_id: u64, listener: ListenerEntry) !void {
        errdefer model.freeReference(self.allocator, listener.target);
        const entry = self.inbound_answers.getPtr(answer_id) orelse
            return Error.InvalidReference;
        const installed = if (entry.payload) |p| p.listeners.items.len else 0;
        if (installed >= self.limits.max_listeners_per_target) {
            return Error.ListenerCapExceeded;
        }
        const payload = try ensureAnswerPayload(self.allocator, entry);
        try payload.listeners.append(self.allocator, listener);
    }

    /// Store `resolution` on `answer_id` (taking ownership), marking the answer
    /// resolved. Replaces any prior stored resolution. On failure the resolution
    /// is freed.
    pub fn storeResolution(self: *Session, answer_id: u64, resolution: model.Resolution) !void {
        const entry = self.inbound_answers.getPtr(answer_id) orelse {
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
            .break_ => .broken,
        };
    }

    /// Borrow the stored resolution for `answer_id`, if the answer resolved and
    /// retained it. The borrow is valid until the answer is mutated or removed.
    pub fn peekResolution(self: *Session, answer_id: u64) ?*const model.Resolution {
        const entry = self.inbound_answers.getPtr(answer_id) orelse return null;
        const payload = entry.payload orelse return null;
        if (payload.resolution) |*resolution| return resolution;
        return null;
    }

    /// Whether `answer_id` is a known inbound answer that has resolved.
    pub fn answerResolved(self: *Session, answer_id: u64) bool {
        const entry = self.inbound_answers.getPtr(answer_id) orelse return false;
        return entry.status != .pending;
    }

    // --- Third-party handoff-imported promises (ADR-0009) ----------------
    //
    // A `desc:import-promise` handed to us by an introducing partner names a
    // promise hosted on a *third* peer. Its resolution reaches us as a relayed
    // resolution (forwarded by the introducing session), not a direct
    // `op:resolve`. `op:listen` on such an import installs a listener here; the
    // relay fires it. These mirror the answer-side pipelining substrate above,
    // keyed on import id instead of answer id.

    /// Root `import_id` at a third-party `host`, registering the import (so it
    /// validates as a reference) and marking it handoff-imported. Idempotent for
    /// the same host; a re-root with a different host is [`Error.HostMismatch`].
    /// `host` is duped into session-owned storage.
    pub fn installThirdPartyImport(self: *Session, import_id: u64, host: []const u8) !void {
        if (self.findImportedPromise(import_id)) |existing| {
            if (!std.mem.eql(u8, existing.host, host)) return Error.HostMismatch;
            return;
        }
        const host_copy = try self.allocator.dupe(u8, host);
        errdefer self.allocator.free(host_copy);
        try self.registerImport(import_id);
        try self.imported_promises.put(self.allocator, import_id, .{ .host = host_copy });
    }

    /// Whether `import_id` is a promise imported from a third party (ADR-0009) —
    /// the gate that admits an `op:listen` on this import as a relayed-resolution
    /// listener rather than rejecting it.
    pub fn isThirdPartyImport(self: *Session, import_id: u64) bool {
        return self.findImportedPromise(import_id) != null;
    }

    /// Register `listener` (taking ownership of its `target`) as wanting the
    /// relayed resolution of third-party import `import_id`. On failure the
    /// target is freed. The import must be third-party-hosted.
    pub fn installImportedPromiseListener(self: *Session, import_id: u64, listener: ListenerEntry) !void {
        errdefer model.freeReference(self.allocator, listener.target);
        const entry = self.findImportedPromise(import_id) orelse return Error.InvalidReference;
        if (entry.listeners.items.len >= self.limits.max_listeners_per_target) {
            return Error.ListenerCapExceeded;
        }
        try entry.listeners.append(self.allocator, listener);
    }

    /// Store the relayed `resolution` for third-party import `import_id` (taking
    /// ownership), so a late `op:listen` fires immediately. Replaces any prior
    /// stored resolution. On an unknown import the resolution is freed.
    pub fn recordRelayedResolution(self: *Session, import_id: u64, resolution: model.Resolution) !void {
        const entry = self.findImportedPromise(import_id) orelse {
            model.freeResolution(self.allocator, resolution);
            return Error.InvalidReference;
        };
        if (entry.resolution) |prior| model.freeResolution(self.allocator, prior);
        entry.resolution = resolution;
    }

    /// Hand the caller the listeners registered on third-party import
    /// `import_id`, transferring ownership of every entry's target and leaving
    /// the import's listener list empty. Returns an empty slice for an unknown
    /// import or no listeners. The caller owns the returned slice (release each
    /// entry's target, then free the slice with `allocator`).
    pub fn takeImportedPromiseListeners(self: *Session, import_id: u64) ![]ListenerEntry {
        const entry = self.findImportedPromise(import_id) orelse return &.{};
        if (entry.listeners.items.len == 0) return &.{};
        return entry.listeners.toOwnedSlice(self.allocator);
    }

    /// Borrow the stored relayed resolution for third-party import `import_id`,
    /// if one was forwarded. The borrow is valid until the row is mutated or
    /// removed.
    pub fn importedPromiseResolution(self: *Session, import_id: u64) ?*const model.Resolution {
        const entry = self.findImportedPromise(import_id) orelse return null;
        if (entry.resolution) |*resolution| return resolution;
        return null;
    }

    pub fn findImportedPromise(self: *Session, import_id: u64) ?*ImportedPromise {
        return self.imported_promises.getPtr(import_id);
    }

    /// The cached import id that `swissnum` enlivened to, or null on a cache miss
    /// (ADR-0012). Pair with [`sturdyrefKindFor`] to rebuild the `FarRef` on the
    /// cache-hit short-circuit.
    pub fn sturdyrefImportFor(self: *Session, swissnum: []const u8) ?u64 {
        if (self.findSturdyrefCache(swissnum)) |entry| return entry.import_id;
        return null;
    }

    /// The cached wire-kind that `swissnum` enlivened to, or null on a cache miss.
    /// Preserved verbatim per ADR-0010 § The far-kind is preserved across enliven.
    pub fn sturdyrefKindFor(self: *Session, swissnum: []const u8) ?model.ImportKind {
        if (self.findSturdyrefCache(swissnum)) |entry| return entry.kind;
        return null;
    }

    /// Cache a resolved enlivenment for future repeat-enlivens (ADR-0012). Bounded
    /// by [`SessionLimits.max_sturdyref_cache_entries`]; idempotent on `swissnum`
    /// (last-wins overwrite, no extra allocation); on overflow it evicts the
    /// oldest entry (the cache is non-load-bearing). A cap of 0 disables caching.
    pub fn cacheSturdyrefEnlivenment(
        self: *Session,
        swissnum: []const u8,
        import_id: u64,
        kind: model.ImportKind,
    ) !void {
        if (self.limits.max_sturdyref_cache_entries == 0) return;
        if (self.findSturdyrefCache(swissnum)) |entry| {
            entry.import_id = import_id;
            entry.kind = kind;
            return;
        }
        if (self.sturdyref_cache.items.len >= self.limits.max_sturdyref_cache_entries) {
            const evicted = self.sturdyref_cache.orderedRemove(0);
            self.allocator.free(evicted.swissnum);
        }
        const owned = try self.allocator.dupe(u8, swissnum);
        errdefer self.allocator.free(owned);
        try self.sturdyref_cache.append(self.allocator, .{
            .swissnum = owned,
            .import_id = import_id,
            .kind = kind,
        });
    }

    /// The outstanding bootstrap-fetch answer for an in-flight enliven of
    /// `swissnum`, or null when none is pending (ADR-0012 in-flight dedup).
    pub fn pendingEnlivenAnswer(self: *Session, swissnum: []const u8) ?u64 {
        return self.pending_enlivens.get(swissnum);
    }

    /// Record an in-flight enliven so a concurrent enliven for the same
    /// `swissnum` collapses onto `answer_id`. Idempotent: a no-op when one is
    /// already outstanding (the caller checks [`pendingEnlivenAnswer`] first).
    pub fn notePendingEnliven(self: *Session, swissnum: []const u8, answer_id: u64) !void {
        const gop = try self.pending_enlivens.getOrPut(self.allocator, swissnum);
        if (gop.found_existing) return;
        // Rows are removed on completion, so the key is gpa-owned and freed then;
        // replace the borrowed key with an owned copy, undoing the slot on OOM.
        gop.key_ptr.* = self.allocator.dupe(u8, swissnum) catch |err| {
            _ = self.pending_enlivens.remove(swissnum);
            return err;
        };
        gop.value_ptr.* = answer_id;
    }

    /// Clear the in-flight marker for `swissnum` once its enliven settles. A
    /// no-op when none is outstanding.
    pub fn finishPendingEnliven(self: *Session, swissnum: []const u8) void {
        if (self.pending_enlivens.fetchRemove(swissnum)) |kv| {
            self.allocator.free(kv.key);
        }
    }

    fn findSturdyrefCache(self: *Session, swissnum: []const u8) ?*SturdyrefCacheEntry {
        for (self.sturdyref_cache.items) |*entry| {
            if (std.mem.eql(u8, entry.swissnum, swissnum)) return entry;
        }
        return null;
    }
};

/// Reject an `op:gc-exports` whose cumulative deltas would drive any export /
/// import refcount below zero (or release an unknown id). Validates the whole
/// message before [`applyGcExportDecrement`] mutates, so apply stays atomic.
pub fn checkGcExportDecrement(
    allocator: std.mem.Allocator,
    table: *const SlotTable,
    gc_export: model.GcExport,
) Error!void {
    // Single pass over the wire deltas (O(1) `count` per position now that the
    // table is position-keyed): accumulate each position's running total and
    // reject the moment it would exceed the live refcount. The scratch map
    // tolerates repeated positions in one message without the prior O(n^2)
    // re-scan; it is GC-validation scratch, freed before apply.
    var pending: std.AutoHashMapUnmanaged(u64, u64) = .empty;
    defer pending.deinit(allocator);
    for (gc_export.positions, gc_export.deltas) |pos, delta| {
        const gop = pending.getOrPut(allocator, pos) catch return Error.GcUnderflow;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* = std.math.add(u64, gop.value_ptr.*, delta) catch return Error.GcUnderflow;
        if (gop.value_ptr.* > table.count(pos)) return Error.GcUnderflow;
    }
}

pub fn applyGcExportDecrement(table: *SlotTable, gc_export: model.GcExport) Error!void {
    for (gc_export.positions, gc_export.deltas) |pos, delta| {
        try table.decrement(pos, delta);
    }
}

/// Reject an `op:gc-answers` whose per-id occurrence count exceeds the answer's
/// (single-reference) refcount, or that names an unknown answer-pos. Single pass
/// with O(1) per-position `count`; the scratch map folds repeated positions
/// without re-scanning the message.
pub fn checkGcAnswerDecrement(
    allocator: std.mem.Allocator,
    table: *const AnswerTable,
    positions: []const u64,
) Error!void {
    var pending: std.AutoHashMapUnmanaged(u64, u64) = .empty;
    defer pending.deinit(allocator);
    for (positions) |pos| {
        const gop = pending.getOrPut(allocator, pos) catch return Error.GcUnderflow;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
        if (gop.value_ptr.* > table.count(pos)) return Error.GcUnderflow;
    }
}

/// Release the owned memory an [`AnswerEntry`] holds: queued pipelined calls,
/// listener targets, and any stored resolution. The entry's queue / listener
/// lists are emptied so the struct is safe to drop or remove afterward.
pub fn deinitAnswerEntry(allocator: std.mem.Allocator, entry: *AnswerEntry) void {
    const payload = entry.payload orelse return;
    for (payload.queue.items) |message| model.freeMessage(allocator, message);
    payload.queue.deinit(allocator);
    for (payload.listeners.items) |listener| model.freeReference(allocator, listener.target);
    payload.listeners.deinit(allocator);
    if (payload.resolution) |resolution| model.freeResolution(allocator, resolution);
    allocator.destroy(payload);
    entry.payload = null;
}

/// Release the owned memory an [`ImportedPromise`] holds: the host designator,
/// listener targets, and any stored relayed resolution. The listener list is
/// emptied so the struct is safe to drop or remove afterward.
pub fn deinitImportedPromise(allocator: std.mem.Allocator, entry: *ImportedPromise) void {
    allocator.free(entry.host);
    for (entry.listeners.items) |listener| model.freeReference(allocator, listener.target);
    entry.listeners.deinit(allocator);
    if (entry.resolution) |resolution| model.freeResolution(allocator, resolution);
    entry.resolution = null;
}

pub fn validateGcExport(gc_export: model.GcExport) Error!void {
    if (gc_export.positions.len != gc_export.deltas.len) {
        return Error.MalformedMessage;
    }
}

pub fn validateHandoffWellFormed(handoff: model.Handoff) Error!void {
    switch (handoff) {
        .give => |give| {
            if (give.gift_id.len == 0 or give.recipient_key.len == 0) {
                return Error.MalformedMessage;
            }
        },
        .receive => |receive| {
            if (receive.receiving_session.len == 0) return Error.MalformedMessage;
            if (receive.signed_give.gift_id.len == 0 or receive.signed_give.recipient_key.len == 0) {
                return Error.MalformedMessage;
            }
        },
    }
}
