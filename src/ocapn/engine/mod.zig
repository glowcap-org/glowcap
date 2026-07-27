//! The `Peer` you hold, and the loop that drives it. Synchronous, no I/O.
//!
//! We call this the engine, not the runtime, and that difference is the whole
//! point. pancake has no runtime in the usual sense: no scheduler, no background
//! tasks, no ambient executor driving things behind your back. The engine is the
//! explicit, synchronous alternative, you feed it frames, you call `step`, you
//! drain and poll. When the project's values say "no hidden runtime", this layer
//! is what they mean stays absent.
//!
//! A `Peer` is the engine object an adapter hangs onto. It owns a `Session`,
//! keeps one queue of inbound frames and one of outbound messages, and surfaces
//! events for your application to handle. It does no I/O and runs no scheduler of
//! its own. You drive it: feed it frames with `feedOwned` or `recvBorrowed`,
//! call `step` to turn queued work into wire bytes, drain `outbound`, and poll for
//! events. Everything that touches the outside world lives above this layer.

const std = @import("std");

const codec = @import("codec");
const foundation = @import("foundation");
const model = @import("model");
const session = @import("session");

pub const abort_projection = @import("abort_projection.zig");
pub const bootstrap = @import("bootstrap.zig");
pub const cross_peer = @import("cross_peer.zig");
pub const events = @import("events.zig");
pub const fetch = @import("fetch.zig");
pub const handoff_gifter = @import("handoff_gifter.zig");
pub const handoff_recipient = @import("handoff_recipient.zig");
pub const handoff_names = @import("handoff_names.zig");
/// Lowering node-local foreign-import tokens to their wire reference at the
/// outbound chokepoint (ADR-0069). A node hands the application synthetic far
/// tokens; the peer swaps each back to its wire reference in `send`, so a token
/// never leaks onto the wire.
pub const lower = @import("lower.zig");
/// A reference could not be lowered to a wire name on the connection it is being
/// emitted on, re-exported so a `send` caller can catch it.
pub const LoweringError = lower.LoweringError;
/// The per-peer lowering hook a `Node` installs at registration.
pub const Lowering = lower.Lowering;
pub const negotiation = @import("negotiation.zig");
const outbound = @import("outbound.zig");
const node = @import("node.zig");
/// The sans-io cross-connection handoff router (ADR-0066): a tier above the
/// per-connection `Peer` that owns the retained node identity, the shared gift
/// registry, and the redeemed-token / foreign-home routing that makes
/// three-party handoff transparent. It lives in the engine core (not the
/// I/O-bearing driver) because it is pure routing data, so the sans-io C ABI and
/// native callers reach it without dragging in a transport.
pub const Node = node.Node;
pub const ActionFifo = @import("action_fifo.zig").ActionFifo;
/// A `Node` connection handle (ADR-0066), re-exported alongside `Node`.
pub const PeerId = node.PeerId;
pub const pairing = @import("pairing.zig");
pub const pipeline = @import("pipeline.zig");
/// Outbound queue carriers and encode helpers; `FireTarget` is re-exported here
/// for `pipeline` and binding docs that name `engine.FireTarget`.
pub const FireTarget = outbound.FireTarget;
pub const sturdyref = @import("sturdyref.zig");
pub const v1_0 = @import("v1_0.zig");

pub const StepOutcome = events.StepOutcome;
pub const EventKind = events.EventKind;
pub const Event = events.Event;

/// Encode a verbatim `<ocapn-peer …>` Syrup record carrying hint entries, so a
/// gifter can name an exporter reachable only by a dial hint (an iroh exporter's
/// direct addresses). Decode materializes a structural `PeerLocator`; redeem
/// URI projection reads that peer (`handoff_recipient.exporterLocatorUri`).
/// Surfaced here so the C ABI builds a give location without reaching past the
/// engine into the codec.
pub const encodePeerLocatorRecord = codec.syrup.encodePeerLocatorRecord;

/// Parse a verbatim `<ocapn-peer …>` Syrup record into an owned `PeerLocator`.
/// The matching decode of `encodePeerLocatorRecord`; the C ABI's
/// `set_exporter_location` boundary uses this so a URI (or any non-record)
/// fails loud instead of being spliced into a signed give.
pub const readLocatorOwned = codec.syrup.readLocatorOwned;

/// The well-known bootstrap export position every OCapN peer answers `fetch` on,
/// owned by the session and surfaced here so consumers above the engine name the
/// one authoritative value rather than re-deriving the magic `0`.
pub const BOOTSTRAP_POSITION = session.BOOTSTRAP_POSITION;

/// Session resource bounds; re-exported so the driver C ABI can mirror the
/// default frame cap without a direct `session` import.
pub const SessionLimits = session.SessionLimits;

/// The inbound receive/dispatch spine (`recvBorrowed`/`recvStreamPrefix`/`step`
/// call in here). Factored out of the `Peer` body as free functions over
/// `*Peer`, the same shape `v1_0`/`pipeline` use.
const inbound = @import("inbound.zig");

/// The errors the engine itself mints on the dispatch / step spine, as opposed
/// to the codec and session error sets it forwards. Enumerated as one explicit
/// set so the abort taxonomy gate (`test/engine/error_taxonomy_test.zig`) can
/// sweep it: a new engine-minted error that falls through
/// `abort_projection.classify` to `.foreign` fails the gate instead of silently
/// surfacing as a host-internal failure with no abort.
pub const EngineError = error{
    /// One resolution's drain produced more local deliveries than
    /// `SessionLimits.max_local_deliveries` admits (`pipeline.deliverDrainedCallLocally`).
    LocalDeliveryCapExceeded,
    /// A V1.0 `op:resolve` reached encode with no resolver row recorded for its
    /// answer (`v1_0.encodeResolveAsCallback`).
    MissingV1_0Resolver,
    /// A `field` pipeline step reached the Syrup decomposer, which has no wire
    /// shape for it (`pipeline.decomposeOutboundDeliver`).
    UnsupportedPipelineOp,
    /// The partner's `op:start-session` location signature failed to verify.
    InvalidStartSessionSignature,
    /// The partner's `op:start-session` session key does not match the key this
    /// peer was pinned to expect (`Peer.expectPartnerKey`): a key-designator
    /// dial reached something that is not the key it dialed.
    PartnerKeyMismatch,
    /// A streamed inbound frame exceeded `SessionLimits.max_frame_bytes`
    /// (`Peer.recvStreamPrefix`).
    FrameTooLarge,
};

/// A FIFO with a drain cursor: `push` appends, `pop` advances a head index and
/// reclaims the backing once fully drained — rewind the head, retain capacity
/// up to `steady_queue_bytes`, free anything above it — so steady
/// enqueue/dequeue neither grows without bound nor shifts on every pop, and a
/// burst's capacity does not stay pinned for the peer's life. The four peer
/// queues (inbound frames, pending sends, outbound frames, events) share this
/// one shape instead of open-coding a parallel `_head` field.
fn Queue(comptime T: type) type {
    return struct {
        items: std.ArrayList(T) = .empty,
        head: usize = 0,

        const Self = @This();

        /// Append to the back. `pub` so the `pipeline` drain half (the same
        /// engine, split by file) can surface a synthesized local-delivery
        /// event; the queue type itself stays private to the engine.
        pub fn push(self: *Self, allocator: std.mem.Allocator, value: T) !void {
            try self.items.append(allocator, value);
        }

        /// Reserve room for one more `push`, so a follow-up `pushAssumeCapacity`
        /// cannot fail. The pair lets a caller make the *enqueue* infallible after
        /// a fallible step that has already transferred ownership (a sent resolve
        /// whose resolution moved into the answer store — or the session
        /// accounting a listener-fire carrier commits), keeping record+enqueue
        /// atomic without an undo path. `pub` like `push`, for the `pipeline`
        /// drain half (the same engine, split by file).
        pub fn ensureUnusedCapacityForOne(self: *Self, allocator: std.mem.Allocator) !void {
            try self.items.ensureUnusedCapacity(allocator, 1);
        }

        pub fn pushAssumeCapacity(self: *Self, value: T) void {
            self.items.appendAssumeCapacity(value);
        }

        /// The per-queue steady backing bound: capacity above this is burst, and
        /// the drain-reset in `pop` frees it back to the allocator instead of
        /// pinning one chatty chunk's worth of slots for the peer's life (at
        /// 500k connections, kilobytes pinned per queue is gigabytes). Capacity
        /// at or under the bound is retained, so steady turns — whose queues
        /// never grow past it — stay allocation-free;
        /// `test/engine/alloc_budget_test.zig` holds that contract. The price
        /// of freeing is one growth re-allocation at the start of the *next*
        /// burst episode, never per turn. The burst side is held by
        /// `test/engine/footprint_budget_test.zig`'s burst-drain scenario: a
        /// drained peer must fit back under the 2 KiB warmed per-connection
        /// budget, which freeing (rather than shrinking-to-bound) satisfies by
        /// construction.
        const steady_queue_bytes = 4096;

        /// Dequeue the front element, or null when drained, reclaiming the
        /// backing slots at that point: rewind the head, retain steady capacity,
        /// free burst capacity above `steady_queue_bytes` entirely. The reclaim
        /// runs on every empty observation, not only when the head is ahead,
        /// because the tail-slide below can consume the final element with the
        /// head already rewound to zero — burst capacity must not survive that
        /// path either.
        /// Dequeue front; pub so `outbound.zig` can drain encoded frames.
        pub fn pop(self: *Self, allocator: std.mem.Allocator) ?T {
            if (self.head == self.items.items.len) {
                self.items.clearRetainingCapacity();
                self.head = 0;
                if (self.items.capacity * @sizeOf(T) > steady_queue_bytes) {
                    self.items.clearAndFree(allocator);
                }
                return null;
            }
            const value = self.items.items[self.head];
            self.head += 1;
            // A queue kept non-empty under sustained load never reaches the
            // drain-reset above, so the consumed prefix would grow without
            // bound. Once the dead prefix dominates the backing, slide the live
            // tail to the front, holding the backing to O(live depth).
            if (self.head >= 64 and self.head * 2 >= self.items.items.len) {
                const live = self.items.items[self.head..];
                std.mem.copyForwards(T, self.items.items[0..live.len], live);
                self.items.shrinkRetainingCapacity(live.len);
                self.head = 0;
            }
            return value;
        }

        /// Remove and return the most-recently pushed element, for `errdefer`
        /// undo of an append whose follow-up failed. Null when empty, which
        /// asks `isEmpty` so a drained-but-unreclaimed backing can never hand
        /// back an element the cursor already moved out.
        pub fn popBack(self: *Self) ?T {
            if (self.isEmpty()) return null;
            return self.items.pop();
        }

        /// A mutable pointer to the most-recently pushed element, for a
        /// follow-up step that fills in a field the pusher could not know
        /// yet (`inbound.applyDecodedOwnedFrame` patching a deliver event's
        /// introduced-far-imports record once apply has run). Null when
        /// empty. Valid only until the next queue mutation — nothing may grow
        /// or shrink the queue between the push this borrows and the read
        /// through it.
        pub fn backPtr(self: *Self) ?*T {
            if (self.isEmpty()) return null;
            return &self.items.items[self.items.items.len - 1];
        }

        /// A borrowed pointer to the front element without dequeuing it, or null
        /// when drained. The pointer aliases the queued element and stays valid
        /// until the next queue mutation, read through it, do not own it.
        fn peek(self: *Self) ?*const T {
            if (self.isEmpty()) return null;
            return &self.items.items[self.head];
        }

        /// Whether the queue holds nothing to dequeue — the queue owns its own
        /// emptiness question, so no reader reaches into the cursor fields.
        /// Pub so `outbound.zig` can probe without popping.
        pub fn isEmpty(self: *const Self) bool {
            return self.head == self.items.items.len;
        }

        /// The not-yet-dequeued elements, for type-specific teardown before
        /// `deinit` (the queue owns the slots, not how to free a `T`).
        fn pending(self: *Self) []T {
            return self.items.items[self.head..];
        }

        fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.items.deinit(allocator);
        }
    };
}

/// The typed cause of a locally-detected failure, kept readable on the peer so
/// an adapter-level consumer can diagnose a refusal without bypassing the
/// adapter (a `PumpError.ProtocolAbort` names only the family; this names the
/// member). Every field is plain data or a static string from the projection
/// table / `@errorName`, so holding one allocates nothing and frees nothing.
/// This is strictly the *locally projected* side: a partner's `op:abort`
/// arrives as an `Event` of kind `.abort` and is not recorded here.
pub const AbortInfo = struct {
    /// Whether the codec, the session, or a host-internal (`foreign`) failure
    /// refused the dispatch.
    domain: abort_projection.Domain,
    /// The `op:abort` kind projected onto the wire, or null when the failure
    /// surfaces without one (`SessionClosed`, host-internal errors).
    kind: ?model.AbortKind,
    /// The static diagnostic the projected abort carried ("" when none).
    message: []const u8,
    /// `@errorName` of the originating Zig error.
    error_name: []const u8,
};

/// One inbound `withdraw-gift` parked until its gift is deposited (ADR-0056).
/// Owns `handoff` (always the `.receive` arm); freed when the withdraw settles
/// or at `Peer.deinit`.
const PendingWithdraw = struct {
    handoff: model.Handoff,
    answer: model.AnswerPosition,
};

/// The caller-owned CapTP engine: one peer per session, no I/O, no hidden
/// scheduler. The host feeds inbound frames (`recvBorrowed` / `feedOwned`),
/// advances the peer with `step`, drains `outbound`, and reads surfaced
/// events; everything the peer queues is allocated on its `allocator` and
/// freed in `deinit`.
pub const Peer = struct {
    allocator: std.mem.Allocator,
    session_state: session.Session,
    inbound: Queue(foundation.Frame),
    pending_send: Queue(outbound.Outbound),
    outbound: Queue(foundation.Frame),
    events: Queue(Event),
    /// The peer's private gift / handoff-count authority (ADR-0056), consulted
    /// through `giftRegistry` unless a host shares one across peers via
    /// `shared_gift_registry`. Owned: freed in `deinit`.
    own_gift_registry: bootstrap.GiftRegistry = .{},
    /// Inbound `withdraw-gift`s parked because their gift is not deposited yet
    /// (ADR-0056): the deposit travels on a different session, so the withdraw
    /// can arrive first. Each entry owns its handoff-receive; `step` retries
    /// them against `giftRegistry()` and settles the answer once the gift
    /// lands. Bounded by `SessionLimits.max_pending_withdraws`.
    pending_withdraws: std.ArrayList(PendingWithdraw) = .empty,
    /// Optional vat-scoped gift registry shared across direct sessions to the
    /// same local vat — `deposit-gift` arrives on the gifter session, while
    /// `withdraw-gift` arrives on the recipient session. Borrowed, never owned:
    /// the host that wires several peers to one registry keeps it alive past
    /// every peer's `deinit`, frees it itself, and owns any cross-thread locking
    /// (the engine is externally synchronized).
    shared_gift_registry: ?*bootstrap.GiftRegistry = null,
    /// Bounds the chain of local deliveries a single resolution can trigger
    /// (a drained pipelined call resolving to a local export, whose own
    /// resolution drains more calls). Capped by `SessionLimits.max_local_deliveries`.
    local_delivery_depth: usize = 0,
    /// When set, an inbound `op:start-session` is admitted only if its location
    /// signature verifies against the claimed `session_pubkey` over the canonical
    /// `<my-location …>` bytes (ADR-0006), at the engine boundary — the session
    /// core still runs no crypto. A failure projects an
    /// `InvalidStartSessionSignature` abort and the session never opens.
    /// `initNegotiating` turns this on: a peer doing a real keyed handshake
    /// authenticates its partner by default (the secure default the whole
    /// application surface inherits). The raw `init` peer leaves it off (it
    /// never handshakes), and the stub-key in-process fixtures opt out through
    /// `NegotiatingOptions` because their handshakes carry no real signature.
    verify_partner_handshake: bool = false,
    /// When set (`expectPartnerKey`), the partner's `op:start-session` is
    /// admitted only if its `session_pubkey` equals this key, checked at the
    /// same inbound chokepoint as the signature — before the session opens, so
    /// a mismatched partner never gets a single post-handshake frame applied.
    /// This is the dial-side half of key unification: a dialer that resolved a
    /// key-designator locator (iroh's node id, keyed TCP's key) pins the
    /// session identity to the key it dialed, and a mismatch projects a
    /// `PartnerKeyMismatch` handshake abort.
    expected_partner_key: ?foundation.crypto.PeerKey = null,
    /// The typed cause of the most recent local dispatch failure — read it
    /// through `lastAbort`. Overwritten on each failure; never reset on
    /// success, so it stays readable after the error has propagated.
    last_abort: ?AbortInfo = null,
    /// The node-installed hook that lowers a node-local foreign-import token to
    /// its wire reference before an outbound message is encoded (ADR-0069). Set
    /// only for a peer registered under a `Node` (`registerPeer` /
    /// `registerPeerOver`); a standalone peer leaves it null and never lowers.
    /// See `lower.zig`.
    lowering: ?Lowering = null,

    /// Peer over an already-open v1.0 session with default limits, no
    /// handshake will run. A real connection starts with `initNegotiating`
    /// and authenticates `op:start-session` instead.
    pub fn init(allocator: std.mem.Allocator) Peer {
        return initWithSession(allocator, session.Session.init(allocator));
    }

    /// Already-open v1.0 fixture peer for tests that inject frames directly.
    /// Real sessions should start with `initNegotiating` and authenticate
    /// `op:start-session`; `next` should arrive through negotiation, not through
    /// this raw-open shortcut.
    pub fn initRawOpenFixture(allocator: std.mem.Allocator) Peer {
        return initWithSession(allocator, session.Session.initWith(allocator, .{
            .captp_version = model.CaptpVersion.v1_0,
        }));
    }

    /// Negotiated knobs for `initNegotiatingWith`. Version, codec, and feature
    /// set are independent axes; both peers of a pair must carry the same
    /// negotiated values so neither exercises a version, codec, or capability the
    /// other did not advertise. Defaults match the v1.0 / Syrup interop floor:
    /// authenticated OCapN v1.0 over Syrup.
    pub const NegotiatingOptions = struct {
        captp_version: model.CaptpVersion = model.CaptpVersion.v1_0,
        codec: model.CodecId = .syrup,
        features: model.FeatureSet = model.FeatureSet.full(),
        /// Resource bounds for the session (`session.SessionLimits`), fixed at
        /// construction so a caller never has to reach into `session_state`.
        limits: session.SessionLimits = .{},
        /// Verify the partner's `op:start-session` signature (`Peer.verify_partner_handshake`).
        /// On by default: a keyed handshake authenticates its partner. Only the
        /// stub-key in-process fixtures set this false.
        verify_partner_handshake: bool = true,
    };

    /// A peer that begins in the `negotiating` state on the v1.0 / Syrup
    /// interop floor, awaiting the `op:start-session`
    /// handshake. Use `initNegotiatingWith` when Pancake-to-Pancake negotiation
    /// selected a different profile or codec.
    pub fn initNegotiating(allocator: std.mem.Allocator) Peer {
        return initNegotiatingWith(allocator, .{});
    }

    /// A negotiating peer carrying the handshake-negotiated `codec` and
    /// `features` (`negotiation.Negotiated`). The in-process driver
    /// (`pairing`) constructs both peers of a pair from one negotiated result.
    pub fn initNegotiatingWith(allocator: std.mem.Allocator, options: NegotiatingOptions) Peer {
        var peer = initWithSession(allocator, session.Session.initWith(allocator, .{
            .negotiating = true,
            .codec = options.codec,
            .captp_version = options.captp_version,
            .features = options.features,
            .limits = options.limits,
        }));
        peer.verify_partner_handshake = options.verify_partner_handshake;
        return peer;
    }

    /// Re-posture a freshly constructed negotiating peer before its first byte
    /// moves. The host's adoption path (`registerPeerOver`) constructs the peer
    /// elsewhere; this verb is the engine's checked imposition of the same
    /// knobs `initNegotiatingWith` would have set, so session tables stay
    /// behind the engine instead of the host poking `session_state` fields.
    pub fn reposture(self: *Peer, options: NegotiatingOptions) void {
        std.debug.assert(self.session_state.state == .negotiating);
        std.debug.assert(self.outbound.isEmpty() and self.pending_send.isEmpty());
        self.session_state.codec = options.codec;
        self.session_state.captp_version = options.captp_version;
        self.session_state.features = options.features;
        self.session_state.limits = options.limits;
        self.verify_partner_handshake = options.verify_partner_handshake;
    }

    /// Peer adopting a caller-built session; every `init*` shorthand
    /// delegates here. The peer owns `session_state` from this call on and
    /// tears it down in `deinit`.
    pub fn initWithSession(allocator: std.mem.Allocator, session_state: session.Session) Peer {
        return .{
            .allocator = allocator,
            .session_state = session_state,
            .inbound = .{},
            .pending_send = .{},
            .outbound = .{},
            .events = .{},
        };
    }

    /// Frees everything the peer still owns: queued inbound/outbound frames,
    /// pending messages and events, parked withdraws, the private gift
    /// registry, and the session with its tables. A shared gift registry
    /// (`shared_gift_registry`) is the one thing not freed here, its owner
    /// outlives every peer pointed at it.
    pub fn deinit(self: *Peer) void {
        for (self.inbound.pending()) |*frame| {
            frame.deinit();
        }
        self.inbound.deinit(self.allocator);

        for (self.pending_send.pending()) |*item| {
            item.deinit(self.allocator);
        }
        self.pending_send.deinit(self.allocator);

        for (self.outbound.pending()) |*frame| {
            frame.deinit();
        }
        self.outbound.deinit(self.allocator);

        for (self.events.pending()) |*event| {
            event.deinit();
        }
        self.events.deinit(self.allocator);

        for (self.pending_withdraws.items) |pending| {
            model.freeHandoff(self.allocator, pending.handoff);
        }
        self.pending_withdraws.deinit(self.allocator);
        self.own_gift_registry.deinit(self.allocator);
        self.session_state.deinit();
    }

    /// The gift / handoff-count authority this peer consults: the host-shared
    /// registry when one is wired, otherwise the peer's own.
    pub fn giftRegistry(self: *Peer) *bootstrap.GiftRegistry {
        return self.shared_gift_registry orelse &self.own_gift_registry;
    }

    /// Pin the partner's session identity to `key` before the handshake runs:
    /// an inbound `op:start-session` whose `session_pubkey` is any other key is
    /// refused with `PartnerKeyMismatch` and the session never opens. Set by a
    /// dialer that resolved a key-designator locator, where the designator *is*
    /// the key the partner must prove; must be called before the partner's
    /// start-session is dispatched to have any effect.
    pub fn expectPartnerKey(self: *Peer, key: foundation.crypto.PeerKey) void {
        self.expected_partner_key = key;
    }

    /// Enqueue an owned `message` for outbound encode, taking ownership of its
    /// heap on every outcome. The canonical, copy-free path: a caller that
    /// built the message moves it in and never frees it. Most kinds are freed
    /// by the peer after `step` encodes them (or here, if recording fails). A
    /// sent `op:resolve` is the exception: its resolution moves into the
    /// answer store at record time (`Session.applySentResolve`) and is freed
    /// on overwrite or answer teardown — possibly without ever being encoded,
    /// when GC drops the row first (see `Outbound`). Borrowed or static input
    /// goes through `sendCopying` instead.
    pub fn send(self: *Peer, message: model.Message) !void {
        // A multi-hop pipelined deliver (promise target carrying a non-empty
        // path) has no single-frame Syrup shape — `desc:answer` carries no path
        // operand — so it decomposes into a chain of single-hop links, each
        // recorded + enqueued through this same path
        // (ADR-0007 § Multi-hop decomposition at the sender). The Cap'n Proto
        // codec is the only shape that would carry a path operand directly,
        // without decomposition.
        if (message == .deliver and
            message.deliver.target == .promise and
            !message.deliver.target.promise.path.isEmpty())
        {
            return self.sendDecomposedPipeline(message);
        }

        return outbound.enqueueRecorded(self, message);
    }

    /// Commit a prepared bootstrap-fetch (`fetch.prepareFetchSwissnum`, or
    /// `sturdyref.prepareEnliven`'s fresh arm) onto the wire. On a V1.0 session
    /// the prepared deliver advertises its own resolver export in
    /// `resolve_me_desc`; this installs the answer-to-resolver link the encoder's
    /// own deliver synthesis would otherwise mint, so the partner's
    /// resolver-callback deliver projects back as a resolve keyed on
    /// `prepared.answer_position`. Consumes `prepared.message` (moved into `send`,
    /// or freed if the resolver install fails). The V1.0 resolver link is engine
    /// authority; callers route through this verb rather than touching the
    /// session table.
    pub fn sendPreparedFetch(self: *Peer, prepared: fetch.PreparedFetch) !void {
        if (prepared.message.deliver.resolve_me_desc != null) {
            self.session_state.installOutboundResolver(prepared.answer_position, prepared.resolver_export) catch |err| {
                freeMessage(self.allocator, prepared.message);
                return err;
            };
        }
        try self.send(prepared.message);
    }

    /// Record and enqueue one *flat* (no-decomposition) `message` for outbound
    /// encode. Delegates to `outbound.enqueueRecorded`.
    fn enqueueRecorded(self: *Peer, message_in: model.Message) !void {
        return outbound.enqueueRecorded(self, message_in);
    }

    /// Decompose a multi-hop pipelined deliver and enqueue each single-hop link
    /// in send order (ADR-0007 § Multi-hop decomposition at the sender), taking
    /// ownership of `message`. Each
    /// link is flat by construction, so it enqueues through `enqueueRecorded`
    /// directly. On a mid-chain failure the unsent remainder is released; links
    /// already handed to `enqueueRecorded` are owned by it.
    fn sendDecomposedPipeline(self: *Peer, message: model.Message) !void {
        const chain = pipeline.decomposeOutboundDeliver(self.allocator, &self.session_state, message) catch |err| {
            // Decomposition never partially consumes `message` before failing.
            freeMessage(self.allocator, message);
            return err;
        };
        defer self.allocator.free(chain.intermediates);

        var next: usize = 0;
        var terminal_owned = true;
        errdefer {
            for (chain.intermediates[next..]) |link| freeMessage(self.allocator, link);
            if (terminal_owned) freeMessage(self.allocator, chain.terminal);
        }
        while (next < chain.intermediates.len) {
            const link = chain.intermediates[next];
            // `enqueueRecorded` owns `link` on both outcomes (consumed on success,
            // freed on error); advance past it before the call so the errdefer
            // can't double-free it.
            next += 1;
            try self.enqueueRecorded(link);
        }
        terminal_owned = false;
        try self.enqueueRecorded(chain.terminal);
    }

    /// Boundary convenience over `send` for callers that hold *borrowed* or
    /// static message data they keep owning (the handshake / handoff drivers,
    /// tests, the FFI edge). Names the one copy explicitly per project values;
    /// the internal spine moves through `send` and never lands here.
    pub fn sendCopying(self: *Peer, message: model.Message) !void {
        const owned = try cloneMessage(self.allocator, message);
        return self.send(owned);
    }

    /// Send a settled `withdraw-gift` outcome and reclaim the one owned arm it
    /// may carry. `bootstrap.resolveForWithdraw` moves a verbatim gifted
    /// capability into the message, so once `sendCopying` has copied it onto
    /// the wire we free that owned reference. The free runs whether the send
    /// succeeds or fails: `sendCopying` frees only its own clone on failure,
    /// never the borrowed argument. The POD near arm and the static break arms
    /// free as no-ops.
    pub fn sendWithdrawSettled(self: *Peer, message: model.Message) !void {
        defer bootstrap.freeSettledWithdrawOwned(self.allocator, message);
        try self.sendCopying(message);
    }

    /// Queue a keyed `op:start-session` over `secret`'s Ed25519 key. The canonical
    /// signing input for `<my-location …>` is profile-defined and lives in the
    /// codec, so this is the one place that builds it: it signs the canonical
    /// bytes of `locator`, then enqueues a `start_session` carrying the session
    /// public key, the locator, and the signature. A negotiating peer drives this
    /// to an open session once the partner's own start-session arrives. The signed
    /// locator is what the partner verifies, so `locator` must be the one the
    /// partner expects (for a Goblins partner, a `tcp` transport with `#f`-encoded
    /// empty hints). Borrowed inputs are cloned into the outbound queue, exactly
    /// as `sendCopying` documents.
    pub fn sendKeyedStartSession(
        self: *Peer,
        version: model.CaptpVersion,
        locator: model.PeerLocator,
        secret: foundation.crypto.SecretKey,
    ) !void {
        const pubkey = secret.publicKey();
        const signed = try codec.syrup.canonicalLocationSignedBytes(self.allocator, locator);
        defer self.allocator.free(signed);
        const sig = foundation.crypto.sign(&secret, signed);
        try self.sendCopying(.{ .start_session = .{
            .captp_version = version,
            .session_pubkey = .{ .bytes = pubkey.asBytes() },
            .acceptable_location = locator,
            .acceptable_location_sig = .{ .bytes = sig.asBytes() },
        } });
    }

    /// Queue the recipient half of a three-party handoff: sign a
    /// `desc:handoff-receive` over `give_bytes` keyed by `secret`, mint the
    /// monotonic handoff-count from this peer's gift registry, and queue
    /// `withdraw-gift` to the exporter's bootstrap object under `answer`. The
    /// exporter session must be open — its partner key names the receive's
    /// session — or this fails with `error.NoExporterKey`. This is the one
    /// definition of the withdraw deliver shape; the `Node` redeem path and the
    /// C ABI both drive it. `give_bytes` is borrowed for the call.
    pub fn sendWithdrawGift(
        self: *Peer,
        secret: foundation.crypto.SecretKey,
        give_bytes: []const u8,
        answer: model.AnswerPosition,
    ) !void {
        const exporter_key = self.session_state.partnerSessionKey() orelse return error.NoExporterKey;
        const signed = try handoff_recipient.signedReceiveFromGiveBytes(
            self.allocator,
            self.session_state.limits,
            self.giftRegistry(),
            secret,
            secret.publicKey(),
            exporter_key,
            give_bytes,
        );
        defer signed.deinit(self.allocator);
        // `signed.message()` borrows `signed`; both outlive `sendCopying`, which
        // deep-copies the deliver before this returns.
        var handoff = model.Handoff{ .receive = signed.message() };
        try self.sendCopying(.{ .deliver = .{
            .target = .{ .far = model.FarRef.object(BOOTSTRAP_POSITION) },
            .args = &.{ .{ .symbol = "withdraw-gift" }, .{ .handoff = &handoff } },
            .answer = answer,
        } });
    }

    /// Queue a `deposit-gift` to this (exporter) session's bootstrap object: a
    /// fire-and-forget `op:deliver` carrying the gift id and the gifted
    /// reference, so the exporter records the gift a later `withdraw-gift`
    /// redeems. This is the one definition of the deposit deliver shape;
    /// `Node.originateGive` and the C ABI both drive it. `gift_id` is borrowed
    /// and `gifted` is borrowed; both are cloned into the outbound queue.
    pub fn sendDepositGift(self: *Peer, gift_id: []const u8, gifted: model.Reference) !void {
        try self.sendCopying(.{ .deliver = .{
            .target = .{ .far = model.FarRef.object(BOOTSTRAP_POSITION) },
            .args = &.{ .{ .symbol = "deposit-gift" }, .{ .bytes = gift_id }, .{ .reference = gifted } },
            .answer = null,
        } });
    }

    /// Resolve `answer` (a question a recipient asked this gifter) with a signed
    /// `desc:handoff-give`: queue an `op:resolve` whose fulfill carries the give
    /// `give_bytes` names. `give_bytes` is the Syrup-encoded
    /// `<desc:sig-envelope …>` `handoff_gifter.buildSignedGive` (or a binding's
    /// `pancake_build_handoff_give`) returns; this parses it into a typed
    /// `model.HandoffGive` carrying both `raw_signed` (so a Syrup session still
    /// emits the exact bytes the gifter signed) and the typed fields a Cap'n
    /// Proto session encodes instead — a binding-originated give rides *this*
    /// session's codec, not just Syrup's. This is the one definition of the
    /// resolve-give shape; `Node.originateGive` and the C ABI both drive it.
    /// `give_bytes` is borrowed for the call.
    pub fn sendResolveHandoffGive(self: *Peer, answer: model.AnswerPosition, give_bytes: []const u8) !void {
        const give = try codec.syrup.decodeSignedHandoffGiveOwned(self.allocator, give_bytes);
        defer model.freeHandoffGive(self.allocator, give);
        var handoff = model.Handoff{ .give = give };
        try self.sendCopying(.{ .resolve = .{
            .answer = answer,
            .resolution = .{ .fulfill = .{ .handoff = &handoff } },
        } });
    }

    /// Whether the session has completed the `op:start-session` handshake and is
    /// open for traffic. An adapter pumps the handshake frames, then checks this
    /// before sending application messages.
    pub fn sessionIsOpen(self: *const Peer) bool {
        return self.session_state.state == .open;
    }

    /// The session's resource bounds (`session.SessionLimits`), fixed at
    /// construction. The read accessor for embedders — a netlayer sizing its
    /// receive path against `max_frame_bytes`, say. Setting limits stays an
    /// init-time write by the embedder that constructs the peer.
    pub fn limits(self: *const Peer) session.SessionLimits {
        return self.session_state.limits;
    }

    /// The codec the session speaks on the wire, fixed at construction or
    /// settled by negotiation.
    pub fn codecId(self: *const Peer) model.CodecId {
        return self.session_state.codec;
    }

    /// The CapTP version the session speaks (`next` or `v1_0`), fixed at
    /// construction or settled by negotiation.
    pub fn captpVersion(self: *const Peer) model.CaptpVersion {
        return self.session_state.captp_version;
    }

    /// The partner's session public key, learned from its `op:start-session`,
    /// or null if the partner's handshake half has not yet arrived with a key.
    /// Borrowed from session state, valid until `deinit`. An embedder verifies
    /// partner signatures against it (ADR-0009).
    pub fn partnerSessionKey(self: *const Peer) ?[]const u8 {
        return self.session_state.partnerSessionKey();
    }

    /// The partner's verbatim `<ocapn-peer ...>` location-record bytes from its
    /// `op:start-session`, or null when the handshake half has not arrived with
    /// raw bytes. Borrowed from session state, valid until `deinit`. A gifter
    /// embeds these as a `desc:handoff-give`'s exporter-location (ADR-0009).
    pub fn partnerLocatorRaw(self: *const Peer) ?[]const u8 {
        return self.session_state.partnerLocatorRaw();
    }

    /// Expose a local capability behind `swissnum` for inbound bootstrap-fetch
    /// (ADR-0006 responder half). Allocates a fresh export, maps the swissnum to
    /// it, and returns the export position. The adapter calls this at config time; an
    /// inbound `'fetch` for the swissnum is then served automatically by
    /// `dispatchOwnedFrameInner`.
    pub fn registerBootstrapCap(self: *Peer, swissnum: []const u8) !u64 {
        return (try self.session_state.registerBootstrapCap(swissnum)).int();
    }

    /// Publish a local object at export position `id` and *grant* it: inbound
    /// deliveries to the position are admitted immediately, without waiting
    /// for the capability's first marshal (ADR-0074). This is the deliberate
    /// "make this addressable now" verb for objects a partner learns about
    /// out-of-band; capabilities are driven through the peer, and the
    /// session's authoritative tables stay encapsulated.
    pub fn exportObject(self: *Peer, id: u64) !void {
        return self.session_state.registerExport(model.ExportPosition.from(id));
    }

    /// Reserve export position `id` for a local object without granting the
    /// partner addressability: the object can marshal onto the wire, and the
    /// partner may address the position only after that first marshal — or an
    /// explicit `exportObject` grant. The positional twin of
    /// `exportNextObject`; `Vat.bindExport` rides it, so binding an actor is
    /// not a grant.
    pub fn reserveExport(self: *Peer, id: u64) !void {
        return self.session_state.reserveExport(model.ExportPosition.from(id));
    }

    /// Allocate the next free export position for a local object and return
    /// it. The position is a *reservation*, unaddressable by the partner
    /// until the capability first marshals onto the wire (or `exportObject`
    /// grants it explicitly).
    pub fn exportNextObject(self: *Peer) !u64 {
        return (try self.session_state.allocateExport()).int();
    }

    /// Track a partner-hosted object held as import position `id`, so a `far` send
    /// to it is admitted (e.g. an import handed back by a bootstrap fetch).
    pub fn importObject(self: *Peer, id: u64) !void {
        return self.session_state.registerImport(model.ImportPosition.from(id));
    }

    /// Allocate the next outbound answer position, the question id for a deliver
    /// that wants a reply. The actor layer rides this to back an eventual-send's
    /// promise; the partner's `op:resolve` for this id settles it.
    pub fn allocateAnswer(self: *Peer) u64 {
        return self.session_state.allocateOutboundAnswer().int();
    }

    /// Our outbound answer an inbound deliver to `resolver_export` resolves, if
    /// that export is a known V1.0 resolver (ADR-0065). The driver's GC path
    /// uses it to retire the answer when the partner drops the resolver.
    pub fn answerForResolverExport(self: *const Peer, resolver_export: model.ExportPosition) ?model.AnswerPosition {
        return self.session_state.answerForResolverExport(resolver_export);
    }

    /// The inbound answer a V1.0 resolver import was installed for (ADR-0065).
    /// The vat uses it to route a resolver-only deliver's reply when the wire
    /// carried no answer position.
    pub fn answerForResolverImport(self: *const Peer, resolver_import: model.ImportPosition) ?model.AnswerPosition {
        return self.session_state.answerForResolverImport(resolver_import);
    }

    /// The inbound answer a deliver settles: its wire answer, or the virtual
    /// answer the engine installed for a V1.0 resolver-only deliver (ADR-0065).
    /// This is the single seam the actor layer routes through, so a resolver-only
    /// deliver's reply reaches the partner without `actors` decoding the CapTP
    /// resolver descriptor. It is generic over the borrowed `model.view.Deliver`
    /// and the owned `model.Deliver` (see `bootstrap.answerForDeliver`).
    pub fn answerForDeliver(self: *const Peer, deliver: anytype) ?model.AnswerPosition {
        return bootstrap.answerForDeliver(deliver, &self.session_state);
    }

    /// Clear the in-flight enliven marker for `swissnum` once its enliven
    /// settles (ADR-0012). A no-op when none is outstanding. The embedder that
    /// began an enliven calls this on the settling resolution.
    pub fn finishPendingEnliven(self: *Peer, swissnum: []const u8) void {
        self.session_state.finishPendingEnliven(swissnum);
    }

    /// Apply one forwarded resolution (ADR-0009), taking ownership of
    /// `resolution`: move it into the import's stored slot first
    /// (`recordRelayedResolution` owns it on every outcome, and refuses a
    /// second relay — a promise resolves once), then fire the listeners
    /// installed on `import_position` from the store — each fire is a POD
    /// carrier whose encode borrows the stored value, no clone anywhere.
    /// Store-then-fire, not fire-then-store, because the carriers must find a
    /// durable owner already in place when `step` encodes them. Production
    /// caller: `Node.consumeProxyListenerFire` (enroll-stamped `row_id`).
    ///
    /// The application supplies this resolution directly — it never funnels
    /// through `send`'s lowering chokepoint — so any node-local foreign-import
    /// token it carries is lowered to its wire reference here (ADR-0069),
    /// before the store owns it, keeping "a token never reaches the wire" true
    /// for the relayed path too.
    pub fn applyRelayedResolution(self: *Peer, import_position: model.ImportPosition, row_id: u64, resolution_in: model.Resolution) !void {
        var resolution = resolution_in;
        if (self.lowering) |lowering| {
            if (lowering.active.*) lower.lowerResolution(lowering, &resolution) catch |err| {
                freeResolution(self.allocator, resolution);
                return err;
            };
        }
        // The one entry point that stores an application-supplied value
        // without a `send`: hold it to the same pre-commit rule (depth bound,
        // set / struct-key uniqueness) `validateSend` holds for messages, so
        // a refusable value never commits to the store and then aborts the
        // session from a queued fire's own accounting.
        self.session_state.validateStoredResolution(resolution) catch |err| {
            freeResolution(self.allocator, resolution);
            return err;
        };
        // A `row_id` mismatch means the row this relay was queued against was
        // torn down and a different third-party promise re-registered at this
        // position; the stale relay is moot, so fire nothing — exactly as a
        // `listener_fire` carrier whose stamp misses drops at encode.
        if (try self.session_state.recordRelayedResolution(import_position, row_id, resolution))
            try pipeline.fireImportedPromiseListeners(self, import_position);
    }

    /// Transfer an owned inbound frame into the peer for the next `step`
    /// dispatch, consuming `frame` on every outcome: queued on success,
    /// released here on failure. The caller never frees it — the owned mirror
    /// of `recvBorrowed`, and the contract the C ABI's `feed_frame` already
    /// promises.
    pub fn feedOwned(self: *Peer, frame: foundation.Frame) !void {
        var owned = frame;
        self.inbound.push(self.allocator, owned) catch |err| {
            owned.deinit();
            return err;
        };
    }

    /// Drive the peer one unit of work: dispatch one queued inbound frame, or
    /// encode one pending outbound message onto `outbound`. Returns `.progress`
    /// when it did either and `.idle` when both queues were empty. Any failure
    /// fails closed, exactly like the inbound boundary: it is recorded as the
    /// typed `lastAbort`, projected to an outbound `op:abort` when the
    /// projection has one, and closes the session per the projection, before
    /// the error propagates. Host-internal errors (out of memory, …) carry no
    /// abort and leave the session as it was.
    pub fn step(self: *Peer) !StepOutcome {
        return self.stepInner() catch |err| {
            inbound.emitAbortForError(self, err);
            return err;
        };
    }

    /// Project `err` to a typed outbound `op:abort` (and `lastAbort`) when a
    /// failure did not already pass through `step` / `recvStreamPrefix`. The
    /// host pump's `driveFed` catch uses this so an outbound resolve refusal
    /// is not silent to the partner.
    pub fn emitFailure(self: *Peer, err: anyerror) void {
        inbound.emitAbortForError(self, err);
    }

    /// Drive `step` until both queues are idle. The caller then drains
    /// `takeOutbound` (encoded frames) and `pollEvent` (surfaced events). The one
    /// spelling of "encode everything pending" every driver and adapter shares.
    pub fn stepToIdle(self: *Peer) !void {
        while ((try self.step()) != .idle) {}
    }

    /// Read the typed cause of the most recent local dispatch failure, or null
    /// if none has occurred. The fields are static — nothing to free — and the
    /// value is overwritten by the next failure, so copy it out before driving
    /// the peer again if it must outlive the next call.
    pub fn lastAbort(self: *const Peer) ?AbortInfo {
        return self.last_abort;
    }

    /// Classify `err` and keep it readable through `lastAbort`. Overwritten by
    /// the next failure at the same error boundary that calls this.
    pub fn recordFailure(self: *Peer, err: anyerror) void {
        const classified = abort_projection.classify(err);
        self.last_abort = .{
            .domain = classified.domain,
            .kind = if (classified.abort) |a| a.kind else null,
            .message = if (classified.abort) |a| a.message else "",
            .error_name = @errorName(err),
        };
    }

    fn stepInner(self: *Peer) !StepOutcome {
        // A parked `withdraw-gift` settles once its deposit arrives — possibly
        // on another peer sharing this registry — so every step re-checks
        // before other work. The empty-list fast path costs one length read.
        try self.settlePendingWithdraws();

        // One unit of work per step: dispatch one inbound frame, else encode one
        // pending outbound message. `pop` transfers ownership into dispatch (on
        // success the frame moves into the surfaced event, zero copy; on error
        // dispatch frees it) and reclaims the backing once inbound is drained,
        // the consumed frames below the head were moved out, so reclaim never
        // double-frees. The inner dispatch is used here (not `dispatchOwnedFrame`)
        // because `step`'s own exit projects the abort for every failure; the
        // wrapped form would emit it twice.
        if (self.inbound.pop(self.allocator)) |frame| {
            try inbound.dispatchOwnedFrameInner(self, frame);
            return .progress;
        }

        if (self.pending_send.pop(self.allocator)) |item| {
            try outbound.stepPending(self, item);
            return .progress;
        }
        return .idle;
    }

    /// Encode a wire `message` for the session's codec and CapTP profile and push
    /// the frame onto the outbound queue. The one encode-then-queue seam every
    /// outbound path shares; the frame is freed on a push failure and owned by the
    /// queue on success.
    pub fn pushEncoded(self: *Peer, message: model.Message) !void {
        var frame = try codec.dispatch.encodeMessageForProfile(
            self.session_state.codec,
            self.allocator,
            self.session_state.captp_version,
            message,
        );
        errdefer frame.deinit();
        try self.outbound.push(self.allocator, frame);
    }

    /// Encode `op:abort` onto outbound. When `disposition` is `.close`, CapTP
    /// closes only after a successful queue push so the partner can still take
    /// the frame. Handshake refusals pass `.keep_negotiating`. Fatal projected
    /// refusals that must close even when encode/push fails close themselves
    /// in their `catch` after calling this.
    pub fn commitAbortOutbound(
        self: *Peer,
        abort: model.AbortReason,
        disposition: abort_projection.AbortDisposition,
    ) !void {
        try self.pushEncoded(.{ .abort = abort });
        if (disposition == .close) self.session_state.close();
    }

    /// Retry every parked `withdraw-gift` whose gift is already deposited: re-run
    /// the verified withdraw responder and enqueue its answer. An entry whose
    /// gift is still missing stays parked; a settled entry (fulfilled *or*
    /// refused with a typed break) is freed here.
    fn settlePendingWithdraws(self: *Peer) !void {
        if (self.pending_withdraws.items.len == 0) return;
        var index: usize = 0;
        while (index < self.pending_withdraws.items.len) {
            const entry = &self.pending_withdraws.items[index];
            if (!self.giftRegistry().giftLive(entry.handoff.receive.signed_give.gift_id)) {
                index += 1;
                continue;
            }
            const view_handoff = model.view.Handoff.fromOwned(&entry.handoff);
            switch (try bootstrap.resolveForWithdraw(self.allocator, &self.session_state, self.giftRegistry(), .{
                .receive = view_handoff.receive,
                .answer = entry.answer,
            })) {
                .settled => |msg| try self.sendWithdrawSettled(msg),
                // The row vanished between the deposited check and the resolve;
                // leave the entry parked for the next step.
                .awaiting_deposit => {
                    index += 1;
                    continue;
                },
            }
            const settled = self.pending_withdraws.swapRemove(index);
            model.freeHandoff(self.allocator, settled.handoff);
        }
    }

    /// Dequeue the next encoded outbound frame, transferring ownership to the
    /// caller (who frees it with `Frame.deinit` or hands it to a transport that
    /// does). Returns null when the queue is drained.
    pub fn takeOutbound(self: *Peer) ?foundation.Frame {
        return self.outbound.pop(self.allocator);
    }

    /// Whether an encoded outbound frame is queued (`takeOutbound` would
    /// return one) — the cheap emptiness probe a drain loop reads without
    /// popping.
    pub fn hasOutbound(self: *const Peer) bool {
        return !self.outbound.isEmpty();
    }

    /// Whether an inbound `withdraw-gift` is parked awaiting its deposit
    /// (ADR-0056). A shared-registry owner reads this to track which sessions
    /// need re-stepping when a sibling session's deposit lands; `step` settles
    /// the parked withdraw against the shared registry on its next drive.
    pub fn hasPendingWithdraws(self: *const Peer) bool {
        return self.pending_withdraws.items.len > 0;
    }

    /// Dispatch a borrowed inbound frame. The borrowed bytes are transient, so
    /// the engine copies them once into an owned frame to retain the event. This
    /// is the single intentional copy on the borrowed inbound path.
    pub fn recvBorrowed(self: *Peer, frame: foundation.FrameView) !void {
        const owned = try ownedFrameFromView(self.allocator, frame);
        try inbound.dispatchOwnedFrame(self, owned);
    }

    /// Outcome of framing one message off the front of a byte-stream buffer.
    pub const RecvStream = union(enum) {
        /// A complete frame was decoded, validated, and applied; the caller may
        /// drop (`toss`) the first `consumed` bytes of the buffer.
        consumed: usize,
        /// The buffer holds only part of a frame; the caller reads more and
        /// retries with the extended buffer (the leading bytes are unchanged).
        incomplete,
    };

    /// Frame, decode, validate, and apply the one message at the front of a
    /// borrowed byte-stream `buffer`, reporting how many bytes it consumed — or
    /// that more bytes are needed. This is the byte-stream generalization of
    /// `recvBorrowed`: the active codec's decoder finds the frame boundary as
    /// it decodes (one parse, no separate scanner), authority is applied through
    /// the same borrowed-validate path, and only then is the frame retained
    /// (the single intentional copy, as on `recvBorrowed`). `buffer` must stay
    /// valid for the call; afterwards the consumed bytes may be discarded.
    ///
    /// A malformed frame or one exceeding `SessionLimits.max_frame_bytes`
    /// projects to a typed outbound `op:abort` and closes the session
    /// (`abort_projection`) before the error surfaces, exactly as the frame
    /// boundary does. `.incomplete` is not an error: no abort, no state change.
    pub fn recvStreamPrefix(self: *Peer, buffer: []const u8) !RecvStream {
        const prefix = codec.dispatch.decodePrefix(
            self.session_state.codec,
            buffer,
            self.session_state.limits.max_frame_bytes,
        );
        switch (prefix) {
            .incomplete => return .incomplete,
            .malformed => {
                inbound.emitAbortForError(self, error.MalformedFrame);
                return error.MalformedFrame;
            },
            .too_large => {
                inbound.emitAbortForError(self, error.FrameTooLarge);
                return error.FrameTooLarge;
            },
            .decoded => |decoded| {
                // The prefix decoded under this same codec, so its shape is
                // registered; a null would mean the dispatchers disagree.
                const shape = codec.dispatch.frameShape(self.session_state.codec) orelse {
                    inbound.emitAbortForError(self, error.MalformedFrame);
                    return error.MalformedFrame;
                };
                // A failed materialization is recorded like every other inbound
                // failure (it is foreign — no abort — but `lastAbort` must
                // still name it).
                const owned = ownedFrameFromView(self.allocator, .{
                    .bytes = buffer[0..decoded.consumed],
                    .shape = shape,
                }) catch |err| {
                    self.recordFailure(err);
                    return err;
                };
                inbound.applyDecodedOwnedFrame(self, owned, decoded.body) catch |err| {
                    inbound.emitAbortForError(self, err);
                    return err;
                };
                return .{ .consumed = decoded.consumed };
            },
        }
    }

    /// Like `recvStreamPrefix`, plus the ADR-0029/0041 incomplete-at-cap
    /// mirror: an incomplete prefix whose buffer is already at or past
    /// `max_frame_bytes` can never complete within the cap, so this fails
    /// closed with `error.FrameTooLarge` (and projects an abort) instead of
    /// returning `.incomplete` for the caller to grow forever. Every
    /// byte-stream consumer (`Host.feedBytes`, `Connection.pumpOver`,
    /// `frame_stream.drainWholeFrames`, `pancake_peer_recv_stream`) must use
    /// this rather than re-implementing the mirror beside `recvStreamPrefix`.
    pub fn applyStreamPrefix(self: *Peer, buffer: []const u8) !RecvStream {
        const outcome = try self.recvStreamPrefix(buffer);
        switch (outcome) {
            .consumed => |n| return .{ .consumed = n },
            .incomplete => {
                if (buffer.len >= self.limits().max_frame_bytes) {
                    inbound.emitAbortForError(self, error.FrameTooLarge);
                    return error.FrameTooLarge;
                }
                return .incomplete;
            },
        }
    }

    /// Take the next surfaced event, or null when none is queued. The caller
    /// owns the returned event and must `deinit` it after dispatch.
    pub fn pollEvent(self: *Peer) ?Event {
        return self.events.pop(self.allocator);
    }

    /// Borrow a const pointer to the next surfaced event without consuming it, or
    /// null when none is queued. The pointer aliases the still-queued event's
    /// frame, so you can read it (`view()`) but cannot `deinit` it, that is the
    /// queue's to do when a following `pollEvent` consumes and owns the real one.
    /// The borrow stays valid until the next `pollEvent`. This lets a consumer
    /// that may reject the event (a typed projection that cannot represent an
    /// argument) leave it queued for the opaque-frame fallback instead of
    /// dequeuing it into the void.
    pub fn peekEvent(self: *Peer) ?*const Event {
        return self.events.peek();
    }

    /// The kind of the next queued event without consuming it, so a caller can
    /// route to a kind-specific decode (the C ABI's typed `poll_event_*` path).
    pub fn peekEventKind(self: *Peer) ?EventKind {
        return (self.events.peek() orelse return null).tag;
    }
};

/// The per-session inline footprint budget, held by the compiler.
///
/// A `Peer` is what one CapTP session costs before it touches the heap, and the
/// 500k-connection destination treats that cost as a budget: a field added here
/// is a withdrawal from it. One kilobyte is the committed ceiling, so half a
/// million idle sessions stay under 0.5 GiB of inline state and the heap-warmed
/// footprint stays the number the ladder's step 2 quotes. The runtime half of the
/// budget — the heap a warmed session grows — is held by
/// `test/engine/footprint_budget_test.zig`. Crossing this ceiling is not a build
/// failure to route around; it is a design event that raises the budget here, in
/// the ladder, and in the vision, together, with the bytes justified.
pub const peer_session_struct_budget_bytes = 1024;
comptime {
    if (@sizeOf(Peer) > peer_session_struct_budget_bytes) @compileError(std.fmt.comptimePrint(
        "engine.Peer is {d} bytes, over the {d}-byte per-session struct budget (docs/ladder.md step 2). " ++
            "A larger session struct is a withdrawal from the 500k footprint budget — raise the budget deliberately, do not route around it.",
        .{ @sizeOf(Peer), peer_session_struct_budget_bytes },
    ));
}

/// Verify the partner's `op:start-session` location signature: real Ed25519 over
/// the profile-level canonical `<my-location …>` signing input, against the
/// claimed `session_pubkey`. Syrup supplies the exact received location bytes so
/// Goblins-style hint spelling is preserved; codecs without that raw capture
/// canonicalize the neutral locator into the same signing domain. A malformed
/// key/signature or failed check is `InvalidStartSessionSignature`, which the
/// abort projection maps to a handshake-time `invalid_start_session_signature`.
/// Allocates the canonical bytes transiently; nothing is retained. The one
/// start-session verification body: `Peer`'s inbound dispatch runs it when
/// `verify_partner_handshake` is set, and the in-process keyed pairing driver
/// (`pairing.pairedWithKeys`) runs the same body over each drained handshake
/// event, so the two paths cannot drift.
pub fn verifyPartnerStartSession(allocator: std.mem.Allocator, ss: model.view.StartSession) !void {
    const crypto = foundation.crypto;
    const pubkey = crypto.PeerKey.fromSlice(ss.session_pubkey) catch
        return error.InvalidStartSessionSignature;
    const sig = switch (ss.acceptable_location_sig) {
        .halves => |h| crypto.Signature.fromParts(h.r, h.s) catch
            return error.InvalidStartSessionSignature,
        .raw => |raw| crypto.Signature.fromSlice(raw) catch
            return error.InvalidStartSessionSignature,
    };
    const signed = if (ss.acceptable_location_raw) |raw|
        try codec.syrup.canonicalLocationSignedBytesRaw(allocator, raw)
    else signed: {
        // Borrow transport/designator (and projected hints); materialize only
        // the lazy arm. Signing must see full hint fidelity, not URI export.
        var owned_hints: ?model.Hints = null;
        defer if (owned_hints) |h| model.freeHints(allocator, h);
        const hints: model.Hints = switch (ss.acceptable_location.hints) {
            .empty => |wf| .{ .wire_form = wf },
            .projected => |h| h,
            .lazy => blk: {
                owned_hints = try ss.acceptable_location.hints.toOwned(allocator);
                break :blk owned_hints.?;
            },
        };
        const location: model.PeerLocator = .{
            .transport = ss.acceptable_location.transport,
            .designator = ss.acceptable_location.designator,
            .hints = hints,
        };
        break :signed try codec.syrup.canonicalLocationSignedBytes(allocator, location);
    };
    defer allocator.free(signed);
    crypto.verify(pubkey, signed, sig) catch return error.InvalidStartSessionSignature;
}

/// Copy borrowed wire bytes into an owned frame that respects the frame shape's
/// alignment, so a surfaced event (or a netlayer's owned frame handed across the
/// C ABI) can outlive the borrowed inbound buffer. The single shape-aware
/// materialization: a `word` frame is over-aligned to 8 bytes so it satisfies
/// `Frame` shape validation; a `byte` frame takes natural alignment. The copy is
/// named here, the one boundary that retains.
pub fn ownedFrameFromView(allocator: std.mem.Allocator, frame: foundation.FrameView) !foundation.Frame {
    switch (frame.shape) {
        .byte => {
            const storage = try allocator.dupe(u8, frame.bytes);
            return foundation.Frame.initOwned(allocator, storage, .byte, .fromByteUnits(1));
        },
        .word => {
            const storage = try allocator.alignedAlloc(u8, .fromByteUnits(8), frame.bytes.len);
            @memcpy(storage, frame.bytes);
            return foundation.Frame.initOwned(allocator, storage, .word, .fromByteUnits(8));
        },
    }
}

const cloneMessage = model.cloneMessage;
const freeMessage = model.freeMessage;
const freeResolution = model.freeResolution;
