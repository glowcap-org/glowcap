const std = @import("std");
const model = @import("../model/mod.zig");

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
    /// Exporter↔Receiver sessions tracked for replay rejection (ADR-0025).
    HandoffCountCapExceeded,
    /// The deposited-gift table exceeded [`SessionLimits.max_deposited_gifts`] —
    /// the load-bearing bound against deposit-without-withdraw (ADR-0025).
    DepositedGiftCapExceeded,
};

/// The fixed bootstrap export id installed when a session reaches `open`
/// (ADR-0006). An inbound `op:deliver` to `<desc:export 0>` with method
/// `'fetch` is the bootstrap-fetch entry point. The initiator side lives in
/// `runtime.fetch`; serving an inbound `'fetch` here is not implemented.
pub const BOOTSTRAP_EXPORT_ID: u64 = 0;

/// One `answer` ↔ resolver-id association for the Goblins V1.0 resolver-callback
/// translation (ADR-0023). Goblins V1.0 has no wire `op:resolve`; a promise's
/// resolution rides as an `op:deliver` to a synthesized resolver capability, so
/// the runtime keeps these links to translate semantic `Resolve` ↔ wire deliver
/// in both directions. Both ids are `u64` — the link owns no heap memory.
const ResolverLink = struct {
    /// The answer-id whose resolution this resolver carries.
    answer: u64,
    /// The resolver capability id: an export on the outbound side (the id we
    /// advertised in `resolve_me_desc`), an import on the inbound side (the id
    /// the partner advertised to us).
    resolver: u64,
};

pub const State = enum {
    negotiating,
    open,
    draining,
    closed,
};

/// Bounds on pipelining state (ADR-0007), keeping a peer from being driven into
/// unbounded memory by a partner that pipelines or listens without ever
/// resolving. Each overflow is a loud session error, never a silent drop. The
/// `max_local_deliveries` bound is enforced by the runtime's resolution drain;
/// the rest are enforced here in the session. Defaults mirror the canonical
/// runtime's `SessionLimits`.
pub const SessionLimits = struct {
    /// Max pipelined calls queued against a single pending answer.
    queue_cap: usize = 1024,
    /// Max inbound answer rows held at once.
    max_inbound_answers: usize = 65_536,
    /// Max listeners registered against a single target.
    max_listeners_per_target: usize = 64,
    /// Max local deliveries surfaced from one resolution drain (runtime-enforced).
    max_local_deliveries: usize = 4096,
    /// Max import-table rows — bounds a partner introducing unboundedly many
    /// imports (ADR-0025). Each new partner-driven import registration checks it;
    /// locally-allocated exports are bounded by our own sends, so exports are
    /// uncapped.
    max_imports: usize = 1_048_576,
    /// Max distinct Exporter↔Receiver session ids tracked in the handoff replay
    /// set (ADR-0025). Each row holds one monotonic `last_count`.
    max_seen_handoff_counts: usize = 16_384,
    /// Max deposited-gift rows — load-bearing against a gifter depositing gifts
    /// that are never withdrawn (ADR-0025).
    max_deposited_gifts: usize = 65_536,
    /// Max resolved sturdyref enlivenments cached for dedup (ADR-0013). The cache
    /// is non-load-bearing — a miss costs one extra bootstrap-fetch round-trip,
    /// never correctness — so an overflow evicts the oldest entry instead of
    /// erroring. A cap of 0 disables caching.
    max_sturdyref_cache_entries: usize = 256,
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

pub const AnswerEntry = struct {
    id: u64,
    status: AnswerStatus,
    /// Single-reference wire-delta count per ADR-0008 `op:gc-answers`.
    /// Initialized to 1 on install; decremented to 0 (and the row removed)
    /// on the matching GC message. Answers are single-ref, so the delta is
    /// implicitly 1.
    count: u64 = 1,
    /// Pipelined `op:deliver`s that arrived for this answer while it was still
    /// `pending` (ADR-0007). FIFO; each is an owned [`model.Message`] this entry
    /// releases on drain or removal. Empty until the first pipelined call lands.
    queue: std.ArrayList(model.Message) = .empty,
    /// Parties listening for this answer's resolution. Each owns its `target`.
    listeners: std.ArrayList(ListenerEntry) = .empty,
    /// The resolution, stored once the answer resolves so a late `op:listen`
    /// fires immediately. Owned; released on removal.
    resolution: ?model.Resolution = null,
};

/// A promise imported from a *third party* via handoff (ADR-0009 § `op:listen`
/// on `desc:import-promise`). The introducing partner gave us this import; its
/// eventual resolution lives on the third-party `host`, not on the direct
/// partner, so it is forwarded to us as a *relayed resolution* rather than a
/// direct `op:resolve`.
///
/// The presence of a row marks `import_id` third-party-hosted — the distinction
/// that lets an inbound `op:listen` on this import install a listener here rather
/// than be rejected. (The canonical runtime keeps `host` on the import-table
/// entry and the listeners / resolution in separate maps; grouping all three in
/// one owned row is the Zig-idiomatic single-lifecycle equivalent.)
pub const ImportedPromise = struct {
    import_id: u64,
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

/// One resolved sturdyref enlivenment (ADR-0013 dedup cache): the swiss-number
/// and the `(import_id, kind)` it resolved to. The kind is preserved verbatim so
/// the cache-hit short-circuit reconstructs the `FarRef` with its wire-tag
/// discriminator intact (ADR-0010 § Decision 5). Owns its `swissnum`.
pub const SturdyrefCacheEntry = struct {
    swissnum: []u8,
    import_id: u64,
    kind: model.ImportKind,
};

/// One in-flight sturdyref enliven (ADR-0013 dedup): a bootstrap-fetch for
/// `swissnum` is outstanding on `answer_id`. A second enliven for the same
/// swiss-number collapses onto this answer instead of issuing a duplicate fetch.
/// Owns its `swissnum`.
pub const PendingEnliven = struct {
    swissnum: []u8,
    answer_id: u64,
};

/// Wire-delta refcount table for the export / import id spaces per
/// ADR-0008.
///
/// Each id carries a count (installed at 1); `op:gc-exports` decrements by the
/// wire delta, and the row is removed when the count reaches zero. Underflow
/// is a loud error, never a silent clamp.
const RefTable = struct {
    entries: std.ArrayList(Entry),

    const Entry = struct { id: u64, count: u64 };

    const empty: RefTable = .{ .entries = .empty };

    fn deinit(self: *RefTable, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
    }

    fn findPtr(self: *RefTable, id: u64) ?*Entry {
        for (self.entries.items) |*entry| {
            if (entry.id == id) return entry;
        }
        return null;
    }

    fn contains(self: *RefTable, id: u64) bool {
        return self.findPtr(id) != null;
    }

    fn count(self: *RefTable, id: u64) u64 {
        if (self.findPtr(id)) |entry| return entry.count;
        return 0;
    }

    /// Register `id` live at count 1 if absent; idempotent no-op otherwise.
    fn register(self: *RefTable, allocator: std.mem.Allocator, id: u64) !void {
        if (self.findPtr(id) != null) return;
        try self.entries.append(allocator, .{ .id = id, .count = 1 });
    }

    /// Decrement `id` by `delta`, removing the row at zero. Underflow or an
    /// unknown id with `delta > 0` returns [`Error.GcUnderflow`].
    fn decrement(self: *RefTable, id: u64, delta: u64) Error!void {
        const entry = self.findPtr(id) orelse {
            if (delta == 0) return;
            return Error.GcUnderflow;
        };
        if (delta > entry.count) return Error.GcUnderflow;
        entry.count -= delta;
        if (entry.count == 0) self.removeId(id);
    }

    fn removeId(self: *RefTable, id: u64) void {
        for (self.entries.items, 0..) |entry, i| {
            if (entry.id == id) {
                _ = self.entries.orderedRemove(i);
                return;
            }
        }
    }
};

/// Maps swiss-numbers to the local export id that serves them (ADR-0006
/// responder half). Owns each swissnum slice. The session is a passive table
/// owner — `lookup` is the only read; the runtime recognizes the inbound
/// `'fetch` shape and synthesizes the reply.
const BootstrapTable = struct {
    entries: std.ArrayList(Entry),

    const Entry = struct { swissnum: []u8, export_id: u64 };

    const empty: BootstrapTable = .{ .entries = .empty };

    fn deinit(self: *BootstrapTable, allocator: std.mem.Allocator) void {
        for (self.entries.items) |entry| allocator.free(entry.swissnum);
        self.entries.deinit(allocator);
    }

    fn register(self: *BootstrapTable, allocator: std.mem.Allocator, swissnum: []const u8, export_id: u64) !void {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.swissnum, swissnum)) {
                entry.export_id = export_id;
                return;
            }
        }
        const owned = try allocator.dupe(u8, swissnum);
        errdefer allocator.free(owned);
        try self.entries.append(allocator, .{ .swissnum = owned, .export_id = export_id });
    }

    fn lookup(self: *const BootstrapTable, swissnum: []const u8) ?u64 {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.swissnum, swissnum)) return entry.export_id;
        }
        return null;
    }
};

/// A gift deposited by a gifter on the exporter, awaiting withdrawal by the
/// recipient named in `recipient_key`. The exporter session is the authority for
/// whether a `handoff-receive` may withdraw it.
pub const GiftEntry = struct {
    gift_id: []u8,
    recipient_key: []u8,
    withdrawn: bool,
};

/// The highest `handoff_count` accepted from a given receiving session, used to
/// reject replayed or out-of-order withdrawals.
const HandoffCounter = struct {
    session: []u8,
    last_count: u64,
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    state: State,
    wire_profile: model.WireProfile,
    /// The wire codec negotiated for this direct session (Invariant 4). The
    /// authoritative record of the codec choice; the runtime's codec-dispatch
    /// seam ([`codec.dispatch`]) reads it to route each frame, and every event
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
    exports: RefTable,
    imports: RefTable,
    inbound_answers: std.ArrayList(AnswerEntry),
    outbound_answers: std.ArrayList(AnswerEntry),
    gifts: std.ArrayList(GiftEntry),
    handoff_counts: std.ArrayList(HandoffCounter),
    /// Promises imported from a third party via handoff (ADR-0009). Each row
    /// owns its host designator, listener targets, and stored relayed resolution.
    imported_promises: std.ArrayList(ImportedPromise),
    /// Whether this side has sent its `op:start-session` half (ADR-0006).
    handshake_local_sent: bool,
    /// Whether the partner's `op:start-session` half has been observed.
    handshake_remote_received: bool,
    /// V1.0 resolver-callback links for our *outbound* answers: `answer` is a
    /// promise we asked the partner, `resolver` is the local export we put in
    /// `resolve_me_desc`. An inbound deliver to that export is the partner
    /// resolving the answer.
    v1_0_outbound_resolvers: std.ArrayList(ResolverLink),
    /// V1.0 resolver-callback links for the partner's *inbound* answers:
    /// `answer` is a promise the partner asked us, `resolver` is the partner's
    /// import id we target when we send our (semantic) resolution as a deliver.
    v1_0_inbound_resolvers: std.ArrayList(ResolverLink),
    /// Resolved sturdyref enlivenments (ADR-0013 dedup): swissnum → (import,kind).
    sturdyref_cache: std.ArrayList(SturdyrefCacheEntry),
    /// In-flight sturdyref enlivens (ADR-0013 dedup): swissnum → outstanding answer.
    pending_enlivens: std.ArrayList(PendingEnliven),
    /// Swissnum→export registry the inbound-`'fetch` responder consults (ADR-0006).
    bootstrap: BootstrapTable,

    pub fn init(allocator: std.mem.Allocator) Session {
        return initWithAllocatorProfileAndFeatures(
            allocator,
            model.WireProfile.pre_spec,
            model.FeatureSet.full(),
        );
    }

    pub fn initWithAllocatorProfileAndFeatures(
        allocator: std.mem.Allocator,
        wire_profile: model.WireProfile,
        features: model.FeatureSet,
    ) Session {
        return .{
            .allocator = allocator,
            .state = .open,
            .wire_profile = wire_profile,
            .codec = .syrup,
            .features = features,
            .limits = .{},
            .next_export_id = 0,
            .exports = .empty,
            .imports = .empty,
            .inbound_answers = .empty,
            .outbound_answers = .empty,
            .gifts = .empty,
            .handoff_counts = .empty,
            .imported_promises = .empty,
            .handshake_local_sent = false,
            .handshake_remote_received = false,
            .v1_0_outbound_resolvers = .empty,
            .v1_0_inbound_resolvers = .empty,
            .sturdyref_cache = .empty,
            .pending_enlivens = .empty,
            .bootstrap = .empty,
        };
    }

    pub fn initNegotiating(allocator: std.mem.Allocator) Session {
        return initNegotiatingWithProfileAndFeatures(
            allocator,
            model.WireProfile.pre_spec,
            model.FeatureSet.full(),
        );
    }

    /// A session that begins in `negotiating`, awaiting the `op:start-session`
    /// handshake on the given wire profile / feature set. The in-process
    /// handshake driver ([`runtime.factories`]) constructs both peers this way.
    pub fn initNegotiatingWithProfileAndFeatures(
        allocator: std.mem.Allocator,
        wire_profile: model.WireProfile,
        features: model.FeatureSet,
    ) Session {
        var session = initWithAllocatorProfileAndFeatures(allocator, wire_profile, features);
        session.state = .negotiating;
        return session;
    }

    /// As [`initNegotiatingWithProfileAndFeatures`], recording the
    /// handshake-negotiated [`model.CodecId`] ([`runtime.negotiation`]
    /// `Negotiated.chosen`) so the runtime dispatches this session's frames to
    /// the right codec (Invariant 4).
    pub fn initNegotiatingWithCodecProfileAndFeatures(
        allocator: std.mem.Allocator,
        codec: model.CodecId,
        wire_profile: model.WireProfile,
        features: model.FeatureSet,
    ) Session {
        var session = initNegotiatingWithProfileAndFeatures(allocator, wire_profile, features);
        session.codec = codec;
        return session;
    }

    pub fn deinit(self: *Session) void {
        self.exports.deinit(self.allocator);
        self.imports.deinit(self.allocator);
        for (self.inbound_answers.items) |*entry| deinitAnswerEntry(self.allocator, entry);
        self.inbound_answers.deinit(self.allocator);
        for (self.outbound_answers.items) |*entry| deinitAnswerEntry(self.allocator, entry);
        self.outbound_answers.deinit(self.allocator);
        for (self.gifts.items) |gift| {
            self.allocator.free(gift.gift_id);
            self.allocator.free(gift.recipient_key);
        }
        self.gifts.deinit(self.allocator);
        for (self.handoff_counts.items) |counter| {
            self.allocator.free(counter.session);
        }
        self.handoff_counts.deinit(self.allocator);
        for (self.imported_promises.items) |*entry| deinitImportedPromise(self.allocator, entry);
        self.imported_promises.deinit(self.allocator);
        self.v1_0_outbound_resolvers.deinit(self.allocator);
        self.v1_0_inbound_resolvers.deinit(self.allocator);
        for (self.sturdyref_cache.items) |entry| self.allocator.free(entry.swissnum);
        self.sturdyref_cache.deinit(self.allocator);
        for (self.pending_enlivens.items) |entry| self.allocator.free(entry.swissnum);
        self.pending_enlivens.deinit(self.allocator);
        self.bootstrap.deinit(self.allocator);
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
        try self.v1_0_outbound_resolvers.append(self.allocator, .{ .answer = answer, .resolver = resolver_export });
    }

    /// Record that the partner's inbound `answer` is resolved via their resolver
    /// import `resolver_import` (advertised in the deliver's `resolve_me_desc`).
    pub fn installInboundResolver(self: *Session, answer: u64, resolver_import: u64) !void {
        try self.registerImport(resolver_import);
        try self.v1_0_inbound_resolvers.append(self.allocator, .{ .answer = answer, .resolver = resolver_import });
    }

    /// The partner's resolver import for an inbound `answer`, if one was
    /// advertised — the target our outbound resolution deliver addresses.
    pub fn resolverForInboundAnswer(self: *const Session, answer: u64) ?u64 {
        for (self.v1_0_inbound_resolvers.items) |link| {
            if (link.answer == answer) return link.resolver;
        }
        return null;
    }

    /// Our outbound `answer` an inbound deliver to `resolver_export` resolves, if
    /// that export is a known resolver — the signal to translate the inbound
    /// deliver into a semantic `Resolve`.
    pub fn answerForResolverExport(self: *const Session, resolver_export: u64) ?u64 {
        for (self.v1_0_outbound_resolvers.items) |link| {
            if (link.resolver == resolver_export) return link.answer;
        }
        return null;
    }

    pub fn open(self: *Session) void {
        self.state = .open;
    }

    /// Both handshake halves observed — the precondition for `open`.
    pub fn handshakeComplete(self: *const Session) bool {
        return self.handshake_local_sent and self.handshake_remote_received;
    }

    /// `Negotiating → Open`: installs the fixed bootstrap export at
    /// [`BOOTSTRAP_EXPORT_ID`] (the only fallible step) then flips state, so a
    /// failed registration leaves the session untouched. Called from the
    /// `start_session` apply arms once both handshake halves are observed.
    fn transitionToOpen(self: *Session) !void {
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

    /// Register a partner-driven import live at count 1 (idempotent). A *new* id
    /// is bounded by [`SessionLimits.max_imports`] (ADR-0025) — a partner cannot
    /// grow our import table without limit. Already-held ids are a no-op and
    /// never trip the cap.
    pub fn registerImport(self: *Session, id: u64) !void {
        if (!self.imports.contains(id) and
            self.imports.entries.items.len >= self.limits.max_imports)
        {
            return Error.ImportCapExceeded;
        }
        try self.imports.register(self.allocator, id);
    }

    /// Install `id` as a pending inbound answer we owe resolution for. Idempotent;
    /// bounded by [`SessionLimits.max_inbound_answers`]. Used when the runtime
    /// redirects a drained pipelined call to a local export — the forwarded
    /// call's own answer becomes one we must resolve, even though no wire
    /// `op:deliver` installed it through `recordRecv`.
    pub fn installInboundAnswer(self: *Session, id: u64) !void {
        try self.installAnswer(&self.inbound_answers, id);
    }

    pub fn recordSend(self: *Session, message: model.Message) !void {
        if (self.state == .closed) {
            return Error.SessionClosed;
        }
        try self.validateSend(message);
        try self.applySend(message);
    }

    pub fn recordRecv(self: *Session, message: model.Message) !void {
        if (self.state == .closed) {
            return Error.SessionClosed;
        }
        try self.validateRecv(message);
        try self.applyRecv(message);
    }

    fn validateSend(self: *Session, message: model.Message) !void {
        // Handshake state gate (ADR-0006): `op:start-session` is the only
        // non-abort traffic the negotiating state admits; everything else
        // waits for `open`.
        switch (message) {
            .start_session => {
                if (self.state != .negotiating) return Error.UnexpectedMessage;
                if (self.handshake_local_sent) return Error.DuplicateStartSession;
                return;
            },
            .abort => {},
            else => if (self.state == .negotiating) return Error.UnexpectedMessage,
        }
        switch (message) {
            .deliver => |deliver| try self.validateOutboundDeliver(deliver),
            .resolve => |resolve| {
                if (self.findAnswer(self.inbound_answers.items, resolve.answer) == null) {
                    return Error.InvalidReference;
                }
            },
            .gc_export => |gc_export| {
                if (!self.features.wire_delta) return Error.FeatureNotNegotiated;
                try validateGcExport(gc_export);
                // Outbound `op:gc-exports` releases our refs to the partner's
                // exports — decrements the import table.
                try checkGcExportDecrement(&self.imports, gc_export);
            },
            .gc_answer => |gc_answer| {
                if (!self.features.wire_delta) return Error.FeatureNotNegotiated;
                // Outbound `op:gc-answers` releases answer-pos the partner
                // allocated for us — decrements inbound answers.
                try checkGcAnswerDecrement(self.inbound_answers.items, gc_answer.positions);
            },
            .listen => |listen| {
                if (!self.features.pipelining) return Error.FeatureNotNegotiated;
                try self.validateOutboundReference(listen.target);
                try self.validateOutboundReference(listen.listener);
            },
            .handoff => |handoff| {
                if (!self.features.handoff) return Error.FeatureNotNegotiated;
                try validateHandoffWellFormed(handoff);
            },
            else => {},
        }
    }

    fn validateRecv(self: *Session, message: model.Message) !void {
        // Handshake state gate (ADR-0006). Inbound `op:start-session` also
        // checks the partner's CapTP version against this session's profile.
        switch (message) {
            .start_session => |ss| {
                if (self.state != .negotiating) return Error.UnexpectedMessage;
                if (self.handshake_remote_received) return Error.DuplicateStartSession;
                if (ss.captp_version != self.wire_profile.captp_version) {
                    return Error.CaptpVersionMismatch;
                }
                return;
            },
            .abort => {},
            else => if (self.state == .negotiating) return Error.UnexpectedMessage,
        }
        switch (message) {
            .deliver => |deliver| try self.validateInboundDeliver(deliver),
            .resolve => |resolve| {
                if (self.findAnswer(self.outbound_answers.items, resolve.answer) == null) {
                    return Error.InvalidReference;
                }
            },
            .gc_export => |gc_export| {
                if (!self.features.wire_delta) return Error.FeatureNotNegotiated;
                try validateGcExport(gc_export);
                // Inbound `op:gc-exports` is the partner releasing refs to our
                // exports — decrements the export table.
                try checkGcExportDecrement(&self.exports, gc_export);
            },
            .gc_answer => |gc_answer| {
                if (!self.features.wire_delta) return Error.FeatureNotNegotiated;
                // Inbound `op:gc-answers` is the partner releasing answer-pos
                // they allocated (our outbound answers).
                try checkGcAnswerDecrement(self.outbound_answers.items, gc_answer.positions);
            },
            .listen => |listen| {
                if (!self.features.pipelining) return Error.FeatureNotNegotiated;
                try self.validateInboundReference(listen.target);
                try self.validateInboundReference(listen.listener);
            },
            .handoff => |handoff| {
                if (!self.features.handoff) return Error.FeatureNotNegotiated;
                try validateHandoffWellFormed(handoff);
                switch (handoff) {
                    .receive => |receive| try self.validateInboundWithdraw(receive),
                    .give => {},
                }
            },
            .abort => {},
            else => {},
        }
    }

    fn applySend(self: *Session, message: model.Message) !void {
        switch (message) {
            .deliver => |deliver| {
                if (deliver.answer) |answer| {
                    try self.installAnswer(&self.outbound_answers, answer);
                }
            },
            .resolve => |resolve| {
                if (self.findAnswer(self.inbound_answers.items, resolve.answer)) |entry| {
                    entry.status = switch (resolve.resolution) {
                        .fulfill => .fulfilled,
                        .break_ => .broken,
                    };
                }
            },
            .gc_export => |gc_export| {
                try applyGcExportDecrement(&self.imports, gc_export);
                // ADR-0009: a fully-released third-party import can never receive
                // a relayed resolution, so drop its imported-promise row (host +
                // listeners + stored resolution) alongside the import.
                for (gc_export.positions) |pos| {
                    if (!self.imports.contains(pos)) {
                        if (self.findImportedPromise(pos)) |entry| {
                            deinitImportedPromise(self.allocator, entry);
                            removeImportedPromise(&self.imported_promises, pos);
                        }
                    }
                }
            },
            // Outbound `op:gc-answers` releases the partner's answer-pos we hold
            // (inbound answers) — prune any inbound resolver links we recorded.
            .gc_answer => |gc_answer| try self.applyGcAnswerDecrement(&self.inbound_answers, gc_answer.positions, &self.v1_0_inbound_resolvers),
            .start_session => {
                // Transition first (the only fallible step); set local_sent only
                // after it succeeds so a failed bootstrap install stays atomic.
                if (self.handshake_remote_received) try self.transitionToOpen();
                self.handshake_local_sent = true;
            },
            else => {},
        }
    }

    fn applyRecv(self: *Session, message: model.Message) !void {
        switch (message) {
            .abort => self.close(),
            .deliver => |deliver| {
                if (deliver.answer) |answer| {
                    try self.installAnswer(&self.inbound_answers, answer);
                }
                // A `far` argument is the partner introducing one of its exports
                // as our import (ADR-0010); install it so we hold the import we
                // were just handed (capability-passing + V1.0 resolver-callback
                // fulfill payloads).
                try self.installIntroducedImports(deliver.args);
            },
            .resolve => |resolve| {
                if (self.findAnswer(self.outbound_answers.items, resolve.answer)) |entry| {
                    entry.status = switch (resolve.resolution) {
                        .fulfill => .fulfilled,
                        .break_ => .broken,
                    };
                }
                // A canonical `op:resolve` fulfilling with a `far` reference hands
                // us a new import (the resolved capability) — install it.
                if (resolve.resolution == .fulfill) {
                    try self.installIntroducedImports(&.{resolve.resolution.fulfill});
                }
            },
            .gc_export => |gc_export| try applyGcExportDecrement(&self.exports, gc_export),
            // Inbound `op:gc-answers` releases the answer-pos we allocated
            // (outbound answers) — prune any outbound resolver links we committed.
            .gc_answer => |gc_answer| try self.applyGcAnswerDecrement(&self.outbound_answers, gc_answer.positions, &self.v1_0_outbound_resolvers),
            .start_session => {
                // Bootstrap-install (the only fallible step) before flipping the
                // received flag, so apply stays all-or-nothing.
                if (self.handshake_local_sent) try self.transitionToOpen();
                self.handshake_remote_received = true;
            },
            .handoff => |handoff| switch (handoff) {
                .receive => |receive| try self.applyInboundWithdraw(receive),
                .give => {},
            },
            else => {},
        }
    }

    pub fn inboundAnswer(self: *Session, id: u64) ?*const AnswerEntry {
        return self.findAnswer(self.inbound_answers.items, id);
    }

    pub fn outboundAnswer(self: *Session, id: u64) ?*const AnswerEntry {
        return self.findAnswer(self.outbound_answers.items, id);
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

    /// Expose a local capability behind `swissnum` for inbound bootstrap-fetch
    /// (ADR-0006 responder half): allocate a fresh export and map the swissnum to
    /// it. Returns the export id. Re-registering a swissnum replaces its mapping.
    pub fn registerBootstrapCap(self: *Session, swissnum: []const u8) !u64 {
        const export_id = try self.allocateExport();
        try self.bootstrap.register(self.allocator, swissnum, export_id);
        return export_id;
    }

    /// The local export serving `swissnum`, or null if none is registered.
    pub fn bootstrapLookup(self: *const Session, swissnum: []const u8) ?u64 {
        return self.bootstrap.lookup(swissnum);
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
    /// recipient named in `recipient_key`. Duplicate gift ids are rejected.
    pub fn depositGift(self: *Session, gift_id: []const u8, recipient_key: []const u8) !void {
        if (gift_id.len == 0 or recipient_key.len == 0) return Error.MalformedMessage;
        if (self.findGift(gift_id) != null) return Error.InvalidGift;
        if (self.gifts.items.len >= self.limits.max_deposited_gifts) {
            return Error.DepositedGiftCapExceeded;
        }

        const id_copy = try self.allocator.dupe(u8, gift_id);
        errdefer self.allocator.free(id_copy);
        const key_copy = try self.allocator.dupe(u8, recipient_key);
        errdefer self.allocator.free(key_copy);

        try self.gifts.append(self.allocator, .{
            .gift_id = id_copy,
            .recipient_key = key_copy,
            .withdrawn = false,
        });
    }

    pub fn giftDeposited(self: *Session, gift_id: []const u8) bool {
        return self.findGift(gift_id) != null;
    }

    pub fn giftWithdrawn(self: *Session, gift_id: []const u8) bool {
        if (self.findGift(gift_id)) |gift| return gift.withdrawn;
        return false;
    }

    fn validateInboundWithdraw(self: *Session, receive: model.HandoffReceive) Error!void {
        const gift = self.findGift(receive.signed_give.gift_id) orelse return Error.InvalidGift;
        if (gift.withdrawn) return Error.InvalidGift;
        if (!std.mem.eql(u8, gift.recipient_key, receive.signed_give.recipient_key)) {
            return Error.InvalidGift;
        }
        if (self.lastHandoffCount(receive.receiving_session)) |last| {
            if (receive.handoff_count <= last) return Error.HandoffReplay;
        }
    }

    fn applyInboundWithdraw(self: *Session, receive: model.HandoffReceive) !void {
        // Record the count first (the only fallible step); marking the gift
        // withdrawn afterwards cannot fail, so the apply stays atomic.
        try self.recordHandoffCount(receive.receiving_session, receive.handoff_count);
        if (self.findGiftMut(receive.signed_give.gift_id)) |gift| {
            gift.withdrawn = true;
        }
    }

    fn recordHandoffCount(self: *Session, session_id: []const u8, count: u64) !void {
        for (self.handoff_counts.items) |*entry| {
            if (std.mem.eql(u8, entry.session, session_id)) {
                entry.last_count = count;
                return;
            }
        }
        if (self.handoff_counts.items.len >= self.limits.max_seen_handoff_counts) {
            return Error.HandoffCountCapExceeded;
        }
        const copy = try self.allocator.dupe(u8, session_id);
        errdefer self.allocator.free(copy);
        try self.handoff_counts.append(self.allocator, .{ .session = copy, .last_count = count });
    }

    fn lastHandoffCount(self: *Session, session_id: []const u8) ?u64 {
        for (self.handoff_counts.items) |entry| {
            if (std.mem.eql(u8, entry.session, session_id)) return entry.last_count;
        }
        return null;
    }

    fn findGift(self: *Session, gift_id: []const u8) ?*const GiftEntry {
        for (self.gifts.items) |*gift| {
            if (std.mem.eql(u8, gift.gift_id, gift_id)) return gift;
        }
        return null;
    }

    fn findGiftMut(self: *Session, gift_id: []const u8) ?*GiftEntry {
        for (self.gifts.items) |*gift| {
            if (std.mem.eql(u8, gift.gift_id, gift_id)) return gift;
        }
        return null;
    }

    fn validateOutboundDeliver(self: *Session, deliver: model.Deliver) !void {
        try self.validateOutboundReference(deliver.target);
        if (deliver.resolve_me_desc) |reference| {
            try self.validateOutboundReference(reference);
        }
        try self.validateArguments(deliver.args);
    }

    fn validateInboundDeliver(self: *Session, deliver: model.Deliver) !void {
        try self.validateInboundReference(deliver.target);
        if (deliver.resolve_me_desc) |reference| {
            try self.validateInboundReference(reference);
        }
        try self.validateInboundArguments(deliver.args);
    }

    fn validateOutboundReference(self: *Session, reference: model.Reference) !void {
        switch (reference) {
            // The partner's bootstrap (import 0) is always reachable on an open
            // session (ADR-0006) — symmetric with our own bootstrap export, which
            // `transitionToOpen` installs — so a far ref to it needs no prior
            // import-table entry. This is the outbound bootstrap-fetch /
            // sturdyref-enliven send target; every other import must be held.
            .far => |far| if (far.import_id != BOOTSTRAP_EXPORT_ID and
                !self.imports.contains(far.import_id))
                return Error.InvalidReference,
            .near => |near| if (!self.exports.contains(near.export_id)) return Error.InvalidReference,
            .promise, .broken => {},
            .sturdy => if (!self.features.sturdyref) return Error.FeatureNotNegotiated,
        }
    }

    fn validateInboundReference(self: *Session, reference: model.Reference) !void {
        // The codec decodes inbound descriptors into the receiver's perspective
        // (ADR-0010 perspective flip), so a decoded `near` already names *our*
        // export and a decoded `far` names an import we hold — the inbound check
        // mirrors `validateOutboundReference` table-for-table. The partner's
        // resolver import (`resolve_me_desc`) and listener imports are registered
        // ahead of `recordRecv`, so a `far` here is always already held.
        switch (reference) {
            .near => |near| if (!self.exports.contains(near.export_id)) return Error.InvalidReference,
            .far => |far| if (far.import_id != BOOTSTRAP_EXPORT_ID and
                !self.imports.contains(far.import_id))
                return Error.InvalidReference,
            .promise, .broken => {},
            .sturdy => if (!self.features.sturdyref) return Error.FeatureNotNegotiated,
        }
    }

    fn validateArguments(self: *Session, args: []const model.Argument) Error!void {
        for (args) |arg| {
            try self.validateArgument(arg);
        }
    }

    fn validateArgument(self: *Session, arg: model.Argument) Error!void {
        switch (arg) {
            .reference => |reference| try self.validateOutboundReference(reference),
            .list => |items| try self.validateArguments(items),
            .set => |items| try self.validateArguments(items),
            .tagged => |tagged| try self.validateArguments(tagged.value),
            else => {},
        }
    }

    /// Validate the references carried in an inbound deliver's arguments. A
    /// `near` arg names one of *our* exports (post-flip, ADR-0010) and must be
    /// held; a `far` arg is the partner *introducing* an import to us — a new
    /// `<desc:import-object>` is always a valid introduction, so it is accepted
    /// here and installed in `applyRecv` rather than rejected as unknown.
    fn validateInboundArguments(self: *Session, args: []const model.Argument) Error!void {
        for (args) |arg| {
            try self.validateInboundArgument(arg);
        }
    }

    fn validateInboundArgument(self: *Session, arg: model.Argument) Error!void {
        switch (arg) {
            .reference => |reference| switch (reference) {
                .near => |near| if (!self.exports.contains(near.export_id)) return Error.InvalidReference,
                .far, .promise, .broken => {},
                .sturdy => if (!self.features.sturdyref) return Error.FeatureNotNegotiated,
            },
            .list => |items| try self.validateInboundArguments(items),
            .set => |items| try self.validateInboundArguments(items),
            .tagged => |tagged| try self.validateInboundArguments(tagged.value),
            else => {},
        }
    }

    /// Install the imports introduced by the `far` references in `args` (an
    /// inbound deliver's arguments or a resolution's fulfill payload). Each
    /// `far` is a `<desc:import-object>` the partner sent naming one of its
    /// exports; registering it records the import we now hold. Already-held ids
    /// are a no-op. The bootstrap import (0) is implicitly held — never tracked.
    fn installIntroducedImports(self: *Session, args: []const model.Argument) !void {
        for (args) |arg| {
            switch (arg) {
                .reference => |reference| switch (reference) {
                    .far => |far| if (far.import_id != BOOTSTRAP_EXPORT_ID) {
                        try self.registerImport(far.import_id);
                    },
                    else => {},
                },
                .list => |items| try self.installIntroducedImports(items),
                .set => |items| try self.installIntroducedImports(items),
                .tagged => |tagged| try self.installIntroducedImports(tagged.value),
                else => {},
            }
        }
    }

    fn applyGcAnswerDecrement(
        self: *Session,
        table: *std.ArrayList(AnswerEntry),
        positions: []const u64,
        resolvers: *std.ArrayList(ResolverLink),
    ) Error!void {
        for (positions) |id| {
            // A fully-released answer can never resolve again, so drop its V1.0
            // resolver-callback link (ADR-0023) along with the answer entry.
            if (try decrementAnswer(self, table, id)) {
                removeResolverByAnswer(resolvers, id);
            }
        }
    }

    /// Decrement an answer's refcount, removing it at zero. Returns whether the
    /// answer was fully released (count reached zero). Releasing an answer frees
    /// any queued pipelined calls, listeners, and stored resolution it owns.
    fn decrementAnswer(self: *Session, table: *std.ArrayList(AnswerEntry), id: u64) Error!bool {
        const entry = self.findAnswer(table.items, id) orelse return Error.GcUnderflow;
        if (entry.count == 0) return Error.GcUnderflow;
        entry.count -= 1;
        if (entry.count == 0) {
            deinitAnswerEntry(self.allocator, entry);
            removeAnswer(table, id);
            return true;
        }
        return false;
    }

    fn installAnswer(self: *Session, table: *std.ArrayList(AnswerEntry), id: u64) !void {
        if (self.findAnswer(table.items, id) != null) return;
        // The row cap bounds the partner's answers we hold (the inbound table);
        // outbound answers are ones we allocate and are bounded by our own sends.
        if (table == &self.inbound_answers and
            table.items.len >= self.limits.max_inbound_answers)
        {
            return Error.InboundAnswerCapExceeded;
        }
        try table.append(self.allocator, .{ .id = id, .status = .pending, .count = 1 });
    }

    fn findAnswer(_: *Session, entries: []AnswerEntry, id: u64) ?*AnswerEntry {
        for (entries) |*entry| {
            if (entry.id == id) {
                return entry;
            }
        }
        return null;
    }

    // --- Pipelining substrate (ADR-0007) ---------------------------------
    //
    // A pipelined `op:deliver` targets an answer the partner has not resolved
    // yet, so the session holds it (owned) on that answer's queue until the
    // resolution arrives, then the runtime drains and redirects it. `op:listen`
    // registers a party to be told when the answer resolves; the resolution is
    // stored so a late listener fires immediately. These operate on the inbound
    // answer table — the partner's answers we hold — mirroring the canonical
    // runtime's `InboundAnswers`.

    /// Queue a pipelined call (an owned `op:deliver` whose target is the pending
    /// answer `answer_id`), taking ownership of `message`. On any failure the
    /// message is freed so the caller never double-frees. The answer must exist
    /// and be `pending`; a resolved or unknown answer is the caller's contract
    /// violation, surfaced as [`Error.InvalidReference`].
    pub fn enqueuePipelinedCall(self: *Session, answer_id: u64, message: model.Message) !void {
        errdefer model.freeMessage(self.allocator, message);
        const entry = self.findAnswer(self.inbound_answers.items, answer_id) orelse
            return Error.InvalidReference;
        if (entry.status != .pending) return Error.InvalidReference;
        if (entry.queue.items.len >= self.limits.queue_cap) return Error.QueueCapExceeded;
        try entry.queue.append(self.allocator, message);
    }

    /// Hand the caller the queued pipelined calls for `answer_id`, transferring
    /// ownership of every message and leaving the answer's queue empty. Returns
    /// an empty slice for an unknown answer or empty queue. The caller owns the
    /// returned slice (free each message, then free the slice with `allocator`).
    pub fn takePipelinedCalls(self: *Session, answer_id: u64) ![]model.Message {
        const entry = self.findAnswer(self.inbound_answers.items, answer_id) orelse
            return &.{};
        if (entry.queue.items.len == 0) return &.{};
        const drained = try entry.queue.toOwnedSlice(self.allocator);
        return drained;
    }

    /// Hand the caller the listeners registered on `answer_id`, transferring
    /// ownership of every entry's target and leaving the answer's listener list
    /// empty. Returns an empty slice for an unknown answer or no listeners. The
    /// caller owns the returned slice (release each entry's target, then free the
    /// slice with `allocator`).
    pub fn takePipelinedListeners(self: *Session, answer_id: u64) ![]ListenerEntry {
        const entry = self.findAnswer(self.inbound_answers.items, answer_id) orelse
            return &.{};
        if (entry.listeners.items.len == 0) return &.{};
        const drained = try entry.listeners.toOwnedSlice(self.allocator);
        return drained;
    }

    /// Move a batch of pipelined `calls` (owned messages, e.g. drained from an
    /// answer that resolved to another promise) onto `target`'s queue, taking
    /// ownership of the slice and every message. `seen` is the set of answer ids
    /// already on the resolution chain; if `target` is among them the requeue
    /// would loop, so it fails with [`Error.ResolutionCycle`]. On any failure the
    /// whole batch is freed (no partial move — capacity is reserved up front so
    /// the moves are infallible). `target` must be a pending inbound answer.
    pub fn requeuePipelinedCalls(self: *Session, target: u64, seen: []const u64, calls: []model.Message) !void {
        var moved = false;
        errdefer if (!moved) {
            for (calls) |message| model.freeMessage(self.allocator, message);
            self.allocator.free(calls);
        };

        for (seen) |id| {
            if (id == target) return Error.ResolutionCycle;
        }
        const entry = self.findAnswer(self.inbound_answers.items, target) orelse
            return Error.InvalidReference;
        if (entry.status != .pending) return Error.InvalidReference;
        if (entry.queue.items.len + calls.len > self.limits.queue_cap) return Error.QueueCapExceeded;

        // Reserve first (the only fallible step); the moves are then infallible,
        // so ownership transfers atomically — no message is half-moved.
        try entry.queue.ensureUnusedCapacity(self.allocator, calls.len);
        for (calls) |message| entry.queue.appendAssumeCapacity(message);
        moved = true;
        self.allocator.free(calls);
    }

    /// Register `listener` (taking ownership of its `target`) as wanting
    /// `answer_id`'s resolution. On failure the target is freed. The answer must
    /// exist; it may be `pending` or already resolved (a late listener — the
    /// runtime fires it immediately from the stored resolution).
    pub fn installListener(self: *Session, answer_id: u64, listener: ListenerEntry) !void {
        errdefer model.freeReference(self.allocator, listener.target);
        const entry = self.findAnswer(self.inbound_answers.items, answer_id) orelse
            return Error.InvalidReference;
        if (entry.listeners.items.len >= self.limits.max_listeners_per_target) {
            return Error.ListenerCapExceeded;
        }
        try entry.listeners.append(self.allocator, listener);
    }

    /// Store `resolution` on `answer_id` (taking ownership), marking the answer
    /// resolved. Replaces any prior stored resolution. On failure the resolution
    /// is freed.
    pub fn storeResolution(self: *Session, answer_id: u64, resolution: model.Resolution) !void {
        const entry = self.findAnswer(self.inbound_answers.items, answer_id) orelse {
            model.freeResolution(self.allocator, resolution);
            return Error.InvalidReference;
        };
        if (entry.resolution) |prior| model.freeResolution(self.allocator, prior);
        entry.resolution = resolution;
        entry.status = switch (resolution) {
            .fulfill => .fulfilled,
            .break_ => .broken,
        };
    }

    /// Borrow the stored resolution for `answer_id`, if the answer resolved and
    /// retained it. The borrow is valid until the answer is mutated or removed.
    pub fn peekResolution(self: *Session, answer_id: u64) ?*const model.Resolution {
        const entry = self.findAnswer(self.inbound_answers.items, answer_id) orelse return null;
        if (entry.resolution) |*resolution| return resolution;
        return null;
    }

    /// Whether `answer_id` is a known inbound answer that has resolved.
    pub fn answerResolved(self: *Session, answer_id: u64) bool {
        const entry = self.findAnswer(self.inbound_answers.items, answer_id) orelse return false;
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
        try self.imported_promises.append(self.allocator, .{ .import_id = import_id, .host = host_copy });
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

    fn findImportedPromise(self: *Session, import_id: u64) ?*ImportedPromise {
        for (self.imported_promises.items) |*entry| {
            if (entry.import_id == import_id) return entry;
        }
        return null;
    }

    /// The cached import id that `swissnum` enlivened to, or null on a cache miss
    /// (ADR-0013). Pair with [`sturdyrefKindFor`] to rebuild the `FarRef` on the
    /// cache-hit short-circuit.
    pub fn sturdyrefImportFor(self: *Session, swissnum: []const u8) ?u64 {
        if (self.findSturdyrefCache(swissnum)) |entry| return entry.import_id;
        return null;
    }

    /// The cached wire-kind that `swissnum` enlivened to, or null on a cache miss.
    /// Preserved verbatim per ADR-0010 § Decision 5.
    pub fn sturdyrefKindFor(self: *Session, swissnum: []const u8) ?model.ImportKind {
        if (self.findSturdyrefCache(swissnum)) |entry| return entry.kind;
        return null;
    }

    /// Cache a resolved enlivenment for future repeat-enlivens (ADR-0013). Bounded
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
    /// `swissnum`, or null when none is pending (ADR-0013 in-flight dedup).
    pub fn pendingEnlivenAnswer(self: *Session, swissnum: []const u8) ?u64 {
        for (self.pending_enlivens.items) |entry| {
            if (std.mem.eql(u8, entry.swissnum, swissnum)) return entry.answer_id;
        }
        return null;
    }

    /// Record an in-flight enliven so a concurrent enliven for the same
    /// `swissnum` collapses onto `answer_id`. Idempotent: a no-op when one is
    /// already outstanding (the caller checks [`pendingEnlivenAnswer`] first).
    pub fn notePendingEnliven(self: *Session, swissnum: []const u8, answer_id: u64) !void {
        if (self.pendingEnlivenAnswer(swissnum) != null) return;
        const owned = try self.allocator.dupe(u8, swissnum);
        errdefer self.allocator.free(owned);
        try self.pending_enlivens.append(self.allocator, .{ .swissnum = owned, .answer_id = answer_id });
    }

    /// Clear the in-flight marker for `swissnum` once its enliven settles. A
    /// no-op when none is outstanding.
    pub fn finishPendingEnliven(self: *Session, swissnum: []const u8) void {
        var index: usize = 0;
        while (index < self.pending_enlivens.items.len) : (index += 1) {
            if (std.mem.eql(u8, self.pending_enlivens.items[index].swissnum, swissnum)) {
                const removed = self.pending_enlivens.orderedRemove(index);
                self.allocator.free(removed.swissnum);
                return;
            }
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
fn checkGcExportDecrement(table: *RefTable, gc_export: model.GcExport) Error!void {
    for (gc_export.positions) |pos| {
        var required: u64 = 0;
        for (gc_export.positions, gc_export.deltas) |p, d| {
            if (p == pos) required += d;
        }
        if (required > table.count(pos)) return Error.GcUnderflow;
    }
}

fn applyGcExportDecrement(table: *RefTable, gc_export: model.GcExport) Error!void {
    for (gc_export.positions, gc_export.deltas) |pos, delta| {
        try table.decrement(pos, delta);
    }
}

/// Reject an `op:gc-answers` whose per-id occurrence count exceeds the answer's
/// (single-reference) refcount, or that names an unknown answer-pos.
fn checkGcAnswerDecrement(entries: []AnswerEntry, positions: []const u64) Error!void {
    for (positions) |pos| {
        var required: u64 = 0;
        for (positions) |p| {
            if (p == pos) required += 1;
        }
        const have = answerCount(entries, pos);
        if (required > have) return Error.GcUnderflow;
    }
}

fn answerCount(entries: []AnswerEntry, id: u64) u64 {
    for (entries) |entry| {
        if (entry.id == id) return entry.count;
    }
    return 0;
}

/// Drop every V1.0 resolver-callback link recorded for a (now fully-released)
/// answer. Linear scan with stable order; the lists hold only a handful of u64
/// pairs over a session's lifetime.
fn removeResolverByAnswer(resolvers: *std.ArrayList(ResolverLink), answer: u64) void {
    var i: usize = 0;
    while (i < resolvers.items.len) {
        if (resolvers.items[i].answer == answer) {
            _ = resolvers.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

fn removeAnswer(table: *std.ArrayList(AnswerEntry), id: u64) void {
    for (table.items, 0..) |entry, i| {
        if (entry.id == id) {
            _ = table.orderedRemove(i);
            return;
        }
    }
}

/// Release the owned memory an [`AnswerEntry`] holds: queued pipelined calls,
/// listener targets, and any stored resolution. The entry's queue / listener
/// lists are emptied so the struct is safe to drop or remove afterward.
fn deinitAnswerEntry(allocator: std.mem.Allocator, entry: *AnswerEntry) void {
    for (entry.queue.items) |message| model.freeMessage(allocator, message);
    entry.queue.deinit(allocator);
    for (entry.listeners.items) |listener| model.freeReference(allocator, listener.target);
    entry.listeners.deinit(allocator);
    if (entry.resolution) |resolution| model.freeResolution(allocator, resolution);
    entry.resolution = null;
}

/// Release the owned memory an [`ImportedPromise`] holds: the host designator,
/// listener targets, and any stored relayed resolution. The listener list is
/// emptied so the struct is safe to drop or remove afterward.
fn deinitImportedPromise(allocator: std.mem.Allocator, entry: *ImportedPromise) void {
    allocator.free(entry.host);
    for (entry.listeners.items) |listener| model.freeReference(allocator, listener.target);
    entry.listeners.deinit(allocator);
    if (entry.resolution) |resolution| model.freeResolution(allocator, resolution);
    entry.resolution = null;
}

fn removeImportedPromise(table: *std.ArrayList(ImportedPromise), import_id: u64) void {
    for (table.items, 0..) |entry, i| {
        if (entry.import_id == import_id) {
            _ = table.orderedRemove(i);
            return;
        }
    }
}

fn validateGcExport(gc_export: model.GcExport) Error!void {
    if (gc_export.positions.len != gc_export.deltas.len) {
        return Error.MalformedMessage;
    }
}

fn validateHandoffWellFormed(handoff: model.Handoff) Error!void {
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
