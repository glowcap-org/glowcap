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
/// Asking the partner how a promise we hold settles (CapTP `op:listen`), the
/// recipient half of a relayed resolution (ADR-0095).
pub const listen = @import("listen.zig");
/// Lowering node-local foreign-import tokens to their wire reference at the
/// outbound chokepoint (ADR-0069). A node hands the application synthetic far
/// tokens; the peer swaps each back to its wire reference in `send`, so a token
/// never leaks onto the wire.
pub const lower = @import("lower.zig");
pub const node_services = @import("node_services.zig");
/// A reference could not be lowered to a wire name on the connection it is being
/// emitted on, re-exported so a `send` caller can catch it.
pub const LoweringError = node_services.LoweringError;
/// The per-peer composition link a `Node` installs at registration.
pub const NodeServices = node_services.NodeServices;
pub const negotiation = @import("negotiation.zig");
const outbound = @import("outbound.zig");
const node = @import("node.zig");
/// The sans-io cross-connection handoff router (ADR-0066): a tier above the
/// per-connection `Peer` that owns the retained node identity, live-session
/// directory, and redeemed-token / foreign-home routing that makes
/// three-party handoff transparent. It lives in the engine core (not the
/// I/O-bearing driver) because it is pure routing data, so the sans-io C ABI and
/// native callers reach it without dragging in a transport.
pub const Node = node.Node;
const fifo = @import("fifo.zig");
/// The head-indexed FIFO spine shared by the peer's queues and the action
/// queues, so their compaction and reclaim rules cannot drift apart.
pub const ActionFifo = fifo.ActionFifo;
/// The per-queue steady backing bound: capacity above this is burst, and the
/// drain-reset in `Queue.pop` frees it back to the allocator instead of
/// pinning one chatty chunk's worth of slots for the peer's life (at 500k
/// connections, kilobytes pinned per queue is gigabytes). Capacity at or
/// under the bound is retained, so steady turns — whose queues never grow
/// past it — stay allocation-free; `test/engine/alloc_budget_test.zig` holds
/// that contract. The price of freeing is one growth re-allocation at the
/// start of the *next* burst episode, never per turn. The burst side is held
/// by `test/engine/footprint_budget_test.zig`'s burst-drain scenario: a
/// drained peer must fit back under the 2 KiB warmed per-connection budget,
/// which freeing (rather than shrinking-to-bound) satisfies by construction.
const steady_queue_bytes = 4096;
/// The same bound, exposed so a test can size a burst past it rather than
/// hardcoding the number.
pub const fifo_steady_bytes = steady_queue_bytes;
/// A `Node` connection handle (ADR-0066), re-exported alongside `Node`.
pub const PeerId = @import("peer_id.zig").PeerId;
pub const pairing = @import("pairing.zig");
pub const pipeline = @import("pipeline.zig");
/// Outbound queue carriers and encode helpers; `FireTarget` is re-exported here
/// for `pipeline` and binding docs that name `engine.FireTarget`.
pub const FireTarget = outbound.FireTarget;
pub const StoreTarget = outbound.StoreTarget;
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
pub const encodePeerLocatorRecord = codec.signed.encodeLocatorRecord;

/// Parse a verbatim `<ocapn-peer …>` Syrup record into an owned `PeerLocator`.
/// The matching decode of `encodePeerLocatorRecord`; the C ABI's
/// `set_exporter_location` boundary uses this so a URI (or any non-record)
/// fails loud instead of being spliced into a signed give.
pub const readLocatorOwned = codec.signed.readLocatorOwned;

/// The well-known bootstrap export position every OCapN peer answers `fetch` on,
/// owned by the session and surfaced here so consumers above the engine name the
/// one authoritative value rather than re-deriving the magic `0`.
pub const BOOTSTRAP_POSITION = session.BOOTSTRAP_POSITION;

/// Session resource bounds; re-exported so the driver C ABI can mirror the
/// default frame cap without a direct `session` import.
pub const SessionLimits = session.SessionLimits;

/// The reserved durable swiss namespace (ADR-0098), re-exported so the host
/// tier's durable mint and mutable-alias guards name the session's one
/// authority without a direct `session` import.
pub const durable_swiss_prefix = session.Session.durable_swiss_prefix;
pub const durable_swiss_entropy_len = session.Session.durable_swiss_entropy_len;
pub const durable_swiss_len = session.Session.durable_swiss_len;
pub const isDurableSwiss = session.Session.isDurableSwiss;

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
/// Why a session expects a particular durable identity (ADR-0097).
pub const DurableKeyBasis = enum {
    /// A lower layer verified the remote: iroh's QUIC handshake, or WebRTC's
    /// DTLS binding under capability-authorized signaling. Evidence.
    transport_verified,
    /// A dial asked for this identity. It makes the claim check meaningful —
    /// a peer advertising another name is refused — but it proves nothing on
    /// its own; what proves it is the transport or the hello's attestation.
    dial_expectation,
};

pub const EngineError = error{
    /// One resolution's drain produced more local deliveries than
    /// `SessionLimits.max_local_deliveries` admits (`pipeline.deliverDrainedCallLocally`).
    LocalDeliveryCapExceeded,
    /// A `field` pipeline step reached the Syrup decomposer, which has no wire
    /// shape for it (`pipeline.decomposeOutboundDeliver`).
    UnsupportedPipelineOp,
    /// The partner's `op:start-session` location signature failed to verify.
    InvalidStartSessionSignature,
    /// The partner's hello claimed a key-designator location naming a durable
    /// key other than the one this session was pinned to expect
    /// (`Peer.expectPartnerDurableKey`, ADR-0097): a key-designator dial
    /// reached something that is not the identity it dialed, or an
    /// authenticated transport's remote claimed a name it did not prove.
    PartnerDesignatorMismatch,
    /// Under the durable-key-attestation contract, the partner's hello claimed
    /// a key-designator location without the required `session-key-attestation`
    /// hint (`Peer.requirePartnerAttestation`, ADR-0097).
    PartnerAttestationMissing,
    /// The partner hello's `session-key-attestation` hint did not verify: a
    /// malformed value, an over-long field, or a signature that does not bind
    /// this transport, designator, and session key under the claimed durable
    /// key.
    PartnerAttestationInvalid,
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

        /// Dequeue the front element, or null when drained. The rewind, the
        /// dead-prefix slide, and the burst reclaim are `fifo.popHead`, shared
        /// with the engine's action queues so the two cannot drift.
        /// Pub so `outbound.zig` can drain encoded frames.
        pub fn pop(self: *Self, allocator: std.mem.Allocator) ?T {
            return fifo.popHead(T, &self.items, &self.head, allocator, steady_queue_bytes);
        }

        /// Commit removal of the borrowed front row after its fallible use
        /// succeeds. The empty observation performs the queue's drain reset
        /// immediately, because a peek-first consumer has no later failed pop
        /// on which to hang that housekeeping.
        pub fn consumeFront(self: *Self, allocator: std.mem.Allocator) T {
            const value = self.pop(allocator) orelse unreachable;
            if (self.isEmpty()) std.debug.assert(self.pop(allocator) == null);
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
        pub fn peek(self: *const Self) ?*const T {
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

/// One inbound `withdraw-gift` parked until its gift is deposited (ADR-0100).
/// Owns `handoff` (always the `.receive` arm); freed when the withdraw settles
/// or at `Peer.deinit`.
const PendingWithdraw = struct {
    receive: bootstrap.PendingReceive,
    answer: model.AnswerPosition,
};

/// All parked receives for one scheduler identity. The exact signed gift id
/// remains in every owned handoff; the fixed-size key only selects the bounded
/// group to retry after a deposit or gifter close.
const PendingWithdrawGroup = struct {
    rows: std.ArrayListUnmanaged(PendingWithdraw) = .empty,
};

/// The caller-owned CapTP engine: one peer per session, no I/O, no hidden
/// scheduler. The host feeds inbound frames (`recvBorrowed` / `feedOwned`),
/// advances the peer with `step`, drains `outbound`, and reads surfaced
/// events; everything the peer queues is allocated on its `allocator` and
/// freed in `deinit`.
pub const Peer = struct {
    allocator: std.mem.Allocator,
    session_state: session.Session,
    /// How far the codec has got framing the partial frame at the front of
    /// whatever pending buffer the consumer is feeding from. It lives on the
    /// peer because every byte-stream consumer reaches the decoder through
    /// `recvStreamPrefix`, so one scan serves the completion loop, the byte-fed
    /// host, the blocking pump, and the C ABI alike, and no consumer has to
    /// remember to keep one. Reset when a frame is consumed.
    stream_scan: codec.framing.StreamScan = .{},
    inbound: Queue(foundation.Frame),
    pending_send: Queue(outbound.Outbound),
    outbound: Queue(foundation.Frame),
    events: Queue(Event),
    /// This session's gift and handoff-count authority. A cross-session
    /// withdrawal reaches a sibling's deposits only through the live-session
    /// resolver; the Vat does not own protocol transcript state.
    gift_registry: bootstrap.GiftRegistry = .{},
    /// Inbound `withdraw-gift`s grouped by exact scheduler dependency because
    /// the deposit travels on a different session and can arrive second. The
    /// grouping makes a deposit retry only its own waits, never all 4096 rows;
    /// each row still owns the exact verified receive and its accepted replay
    /// count. `pending_withdraw_count` is bounded by
    /// `SessionLimits.max_pending_withdraws`.
    pending_withdraws: std.AutoHashMapUnmanaged(node_services.HandoffDependency, PendingWithdrawGroup) = .empty,
    pending_withdraw_count: usize = 0,
    /// Variable bytes retained by parked receives. The fixed certificate subset
    /// lives inline; only exact gift ids count here, and their aggregate may not
    /// exceed this session's already-configured frame cap.
    pending_withdraw_bytes: usize = 0,
    /// One exact Node wake at a time. Host consumes scheduler changes one at a
    /// time and drives this Peer before taking another, so no second queue or
    /// allocation is needed after deposit authority commits.
    pending_handoff_change: ?node_services.HandoffDependency = null,
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
    /// The durable-key-attestation verification contract (ADR-0097), installed
    /// pre-feed by the adapter for a session whose transport authenticates its
    /// key designator by hello credential (`keyed-tcp`, `keyed-relay`). When
    /// set, an inbound `op:start-session` claiming a key-designator location
    /// must carry a verifying `session-key-attestation` hint
    /// (`verifyPartnerAttestation`), checked at the same pre-open chokepoint
    /// as the signature and the key pin. The engine never turns this on from a
    /// transport string or a key-shaped designator; the adapter's transport
    /// table selects the contract.
    require_partner_attestation: bool = false,
    /// The durable identity this session's partner must claim, installed
    /// pre-feed by the adapter (ADR-0097). An inbound hello whose location
    /// designator is a key spelling must name exactly this key; an address
    /// claim names no durable identity and passes.
    ///
    /// It constrains the *durable* name, never `session_pubkey`: each
    /// connection signs with its own key, so a session key is not an identity
    /// and comparing the two proves nothing. What makes the claim
    /// trustworthy is the transport (iroh's QUIC handshake, WebRTC's DTLS
    /// binding) or the hello's `session-key-attestation`, and which of those
    /// applies is the transport's declared mechanism.
    expected_durable_key: ?foundation.crypto.PeerKey = null,
    /// Whether `expected_durable_key` came from a transport that actually
    /// proved the remote, rather than from what a dial merely asked for
    /// (ADR-0097). Both install the same claim check; only this one is
    /// evidence, and conflating them would report an unproven peer as
    /// authenticated.
    durable_key_transport_proved: bool = false,
    /// The typed cause of the most recent local dispatch failure — read it
    /// through `lastAbort`. Overwritten on each failure; never reset on
    /// success, so it stays readable after the error has propagated.
    last_abort: ?AbortInfo = null,
    /// The node-installed composition link: outbound token lowering, exact
    /// local-object projection, and live gifter-session resolution. Set only
    /// for a peer registered under a `Node`; a standalone peer leaves it null.
    /// See `lower.zig`.
    node_services: ?NodeServices = null,

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
        // Build a blank negotiating peer and let `reposture` apply every knob,
        // so the option set has exactly one applier. Spelling the fields out
        // here as well is how a knob came to be honoured on one path and
        // dropped on the other; a field added to `NegotiatingOptions` now
        // reaches both paths or neither.
        //
        // The export range is deliberately not among these knobs. It is
        // `engine.Node`'s to hand out at registration, so no posture can carry
        // one and no later reposture can overwrite one.
        var peer = initWithSession(allocator, session.Session.initWith(allocator, .{ .negotiating = true }));
        peer.reposture(options);
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
    /// pending messages and events, parked withdraws, the session-owned gift
    /// registry, and the session with its tables.
    pub fn deinit(self: *Peer) void {
        self.clearPendingWithdraws();
        self.detachNodeServices();
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

        self.gift_registry.deinit(self.allocator, self.localObjectProjection());
        self.session_state.deinit();
    }

    /// This CapTP session's gift and handoff-count authority.
    pub fn giftRegistry(self: *Peer) *bootstrap.GiftRegistry {
        return &self.gift_registry;
    }

    /// The Host-wide exact-gift projection seam, when this Peer belongs to a
    /// Node composition. Standalone peers deliberately have no such seam.
    pub fn localObjectProjection(self: *const Peer) ?bootstrap.LocalObjectProjection {
        const services = self.node_services orelse return null;
        return services.localObjectProjection();
    }

    pub fn gifterSessionResolver(self: *const Peer) ?bootstrap.GifterSessionResolver {
        const services = self.node_services orelse return null;
        return services.gifterSessionResolver();
    }

    pub fn pendingWithdrawCount(self: *const Peer) usize {
        return self.pending_withdraw_count;
    }

    pub fn pendingWithdrawCapacity(self: *const Peer) usize {
        return self.pending_withdraws.capacity();
    }

    /// Remove every scheduler dependency this peer registered with its Node,
    /// then sever the borrowed services pointer. Node removal calls this before
    /// its own tables move; standalone peers and repeated teardown are no-ops.
    pub fn detachNodeServices(self: *Peer) void {
        const services = self.node_services orelse return;
        var dependencies = self.pending_withdraws.keyIterator();
        while (dependencies.next()) |dependency| services.pendingWithdrawRemoved(dependency.*);
        self.pending_handoff_change = null;
        self.node_services = null;
    }

    /// Install the durable-key-attestation contract (ADR-0097) before any
    /// partner byte is fed: an inbound hello claiming a key-designator
    /// location must then prove that durable key authorized its session key.
    /// Called by the adapter whose transport table selects durable-key
    /// attestation for this session's transport (`keyed-tcp`, `keyed-relay`),
    /// on both the dial and accept legs.
    pub fn requirePartnerAttestation(self: *Peer) void {
        self.require_partner_attestation = true;
    }

    /// Pin the durable identity this session's partner must claim, before any
    /// partner byte is fed (ADR-0097): an inbound hello whose location
    /// designator is a key spelling must name exactly `key`, or it is refused
    /// with `PartnerDesignatorMismatch` before the session opens. An address
    /// claim carries no durable identity and is unaffected.
    ///
    /// Installed by a dialer that resolved a key-designator locator (the key
    /// it dialed) and by an adapter whose transport proved the remote. It is
    /// the claim check; the transport's mechanism decides what proves it.
    pub fn expectPartnerDurableKey(self: *Peer, key: foundation.crypto.PeerKey, basis: DurableKeyBasis) void {
        self.expected_durable_key = key;
        self.durable_key_transport_proved = basis == .transport_verified;
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

    /// Commit a prepared `withdraw-gift` settlement. Preparation already owns
    /// the one outbound clone and carries the accepted replay count. `send`
    /// either owns the message or refuses before the
    /// gift moves; only a successful enqueue is followed by the infallible gift
    /// commit.
    pub fn sendWithdrawSettled(self: *Peer, prepared_in: bootstrap.PreparedWithdraw) !void {
        var prepared = prepared_in;
        defer prepared.deinit(self.allocator);
        try self.send(prepared.takeMessage());
        prepared.apply(self.allocator, self.localObjectProjection(), self.giftRegistry());
    }

    /// Admit one verified early withdraw without leaving replay authority or a
    /// Node scheduler row half-installed on OOM. A new exact-gift group reserves
    /// both its local row and its Node dependency before the replay count moves;
    /// every operation after `acceptValidatedPendingWithdraw` is infallible.
    pub fn parkPendingWithdraw(
        self: *Peer,
        receive: bootstrap.PendingReceive,
        answer: model.AnswerPosition,
        gifter_peer_id: PeerId,
    ) !void {
        if (receive.retainedBytes() > self.session_state.limits.max_frame_bytes -| self.pending_withdraw_bytes)
            return session.Error.PendingWithdrawCapExceeded;
        const dependency = node_services.HandoffDependency.init(
            gifter_peer_id,
            receive.gift_id,
        );
        if (self.pending_withdraws.getPtr(dependency)) |group| {
            try group.rows.ensureUnusedCapacity(self.allocator, 1);
            self.giftRegistry().acceptValidatedPendingWithdraw(receive.handoff_count);
            group.rows.appendAssumeCapacity(.{ .receive = receive, .answer = answer });
            self.pending_withdraw_count += 1;
            self.pending_withdraw_bytes += receive.retainedBytes();
            return;
        }

        var group: PendingWithdrawGroup = .{};
        errdefer group.rows.deinit(self.allocator);
        try group.rows.ensureUnusedCapacity(self.allocator, 1);
        try self.pending_withdraws.ensureUnusedCapacity(self.allocator, 1);
        if (self.node_services) |services| try services.pendingWithdrawAdded(dependency);
        self.pending_withdraws.putAssumeCapacity(dependency, group);
        const installed = self.pending_withdraws.getPtr(dependency).?;
        self.giftRegistry().acceptValidatedPendingWithdraw(receive.handoff_count);
        installed.rows.appendAssumeCapacity(.{ .receive = receive, .answer = answer });
        self.pending_withdraw_count += 1;
        self.pending_withdraw_bytes += receive.retainedBytes();
    }

    /// Record the exact scheduler wake the Host will drive next. The Host
    /// consumes Node changes one at a time and reaches quiescence between them;
    /// accepting a distinct second key here would violate that composition.
    pub fn noteHandoffChange(self: *Peer, dependency: node_services.HandoffDependency) void {
        std.debug.assert(self.pending_handoff_change == null or std.meta.eql(self.pending_handoff_change.?, dependency));
        self.pending_handoff_change = dependency;
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
        const signed = try codec.signed.locationBytes(self.allocator, locator);
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
        // Two different keys, deliberately (ADR-0097).
        //
        // `secret` signs, and it is the key of the session the *give arrived
        // on*, because that is the identity the give named as its
        // `recipient_key` and the exporter verifies this receive against that
        // name. The side and session names below are this session's — the
        // recipient–exporter one — because they name where the withdrawal is
        // happening. Goblins draws the same distinction: its receive is signed
        // by the coordinator that received the give while its names come from
        // the exporter session's coordinator. Conflating them works only while
        // one key serves every session.
        const local_key = self.session_state.localSessionKey() orelse
            return error.NoLocalSessionKey;
        const our_side_key = foundation.crypto.PeerKey.fromSlice(local_key) catch
            return error.NoLocalSessionKey;
        const signed = try handoff_recipient.signedReceiveFromGiveBytes(
            self.allocator,
            self.session_state.limits,
            self.giftRegistry(),
            secret,
            our_side_key,
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
        const give = try codec.signed.decodeGiveOwned(self.allocator, give_bytes);
        defer model.freeHandoffGive(self.allocator, give);
        var handoff = model.Handoff{ .give = give };
        try self.sendCopying(.{ .resolve = .{
            .answer = answer,
            .resolution = .{ .fulfill = .{ .handoff = &handoff } },
        } });
    }

    /// Store a signed `desc:handoff-give` as the relayed resolution of
    /// `import_position`, the handoff sibling of `sendResolveHandoffGive`.
    ///
    /// A promise this node introduced to a third party can settle to a
    /// capability the recipient has no way to name, and the answer to that is
    /// a handoff rather than a break: the draft CapTP specification allows a
    /// `desc:handoff-give` wherever a Passable value is allowed, and requires
    /// a handoff when a message would carry a reference imported from another
    /// session. The give is stored, not sent, because the recipient is waiting
    /// on a promise the store fires — the same fan-out every relayed
    /// resolution uses.
    ///
    /// `give_bytes` is borrowed. Ownership of the decoded handoff passes to
    /// `applyRelayedResolution`, which consumes it on every outcome.
    pub fn applyRelayedHandoffGive(
        self: *Peer,
        import_position: model.ImportPosition,
        row_id: u64,
        give_bytes: []const u8,
    ) !void {
        const give = try codec.signed.decodeGiveOwned(self.allocator, give_bytes);
        const boxed = self.allocator.create(model.Handoff) catch |err| {
            model.freeHandoffGive(self.allocator, give);
            return err;
        };
        boxed.* = .{ .give = give };
        return self.applyRelayedResolution(import_position, row_id, .{ .fulfill = .{ .handoff = boxed } });
    }

    /// Whether the session has completed the `op:start-session` handshake and is
    /// open for traffic. An adapter pumps the handshake frames, then checks this
    /// before sending application messages.
    pub fn sessionIsOpen(self: *const Peer) bool {
        return self.session_state.state == .open;
    }

    /// Retire all CapTP handoff authority at the close transition, even when
    /// the embedder retains the Peer shell to drain its final abort frame.
    pub fn retireClosedSessionAuthority(self: *Peer) void {
        std.debug.assert(self.session_state.state == .closed);
        self.clearPendingWithdraws();
        self.gift_registry.deinit(self.allocator, self.localObjectProjection());
        self.gift_registry = .{};
        if (self.node_services) |services| services.sessionClosed();
    }

    pub fn closeSession(self: *Peer) void {
        if (self.session_state.state == .closed) return;
        self.session_state.close();
        self.retireClosedSessionAuthority();
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
    /// for the relayed path too. Pinned by `test/engine/node_test.zig`'s
    /// "a relayed resolution carrying a routing token emits the wire import
    /// position, never the token".
    pub fn applyRelayedResolution(self: *Peer, import_position: model.ImportPosition, row_id: u64, resolution_in: model.Resolution) !void {
        var resolution = resolution_in;
        if (self.node_services) |services| {
            if (services.lowering_active.*) lower.lowerResolution(services, &resolution) catch |err| {
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
        // A parked `withdraw-gift` settles once its deposit arrives on the live
        // Gifter–Exporter Peer. Node scheduling targets this receiver after
        // that sibling changes, and every step re-checks before other work. The
        // empty-list fast path costs one length read.
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

        if (self.pending_send.peek() != null) {
            try outbound.stepPending(self);
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
        if (disposition == .close) self.closeSession();
    }

    fn clearPendingWithdraws(self: *Peer) void {
        const services = self.node_services;
        var groups = self.pending_withdraws.iterator();
        while (groups.next()) |entry| {
            if (services) |link| link.pendingWithdrawRemoved(entry.key_ptr.*);
            for (entry.value_ptr.rows.items) |*pending| pending.receive.deinit(self.allocator);
            entry.value_ptr.rows.deinit(self.allocator);
        }
        self.pending_withdraws.deinit(self.allocator);
        self.pending_withdraws = .empty;
        self.pending_withdraw_count = 0;
        self.pending_withdraw_bytes = 0;
        self.pending_handoff_change = null;
    }

    /// Retry only the exact parked-withdraw group whose gift changed. A
    /// standalone Peer with a custom resolver has no Node scheduler, so it
    /// retains the explicit-drive fallback and checks each group; production
    /// Node compositions never pay that broad scan.
    fn settlePendingWithdraws(self: *Peer) !void {
        if (self.pending_withdraw_count == 0) {
            self.pending_handoff_change = null;
            return;
        }
        if (self.node_services != null) {
            const dependency = self.pending_handoff_change orelse return;
            try self.settlePendingWithdrawGroup(dependency);
            self.pending_handoff_change = null;
            return;
        }

        // Removing the iterator's current entry only tombstones that slot; it
        // neither reallocates nor moves the backing, so the iterator can keep
        // walking without an auxiliary attacker-sized key copy.
        var it = self.pending_withdraws.iterator();
        while (it.next()) |entry| try self.settlePendingWithdrawGroup(entry.key_ptr.*);
    }

    fn settlePendingWithdrawGroup(self: *Peer, dependency: node_services.HandoffDependency) !void {
        const group = self.pending_withdraws.getPtr(dependency) orelse return;
        var index: usize = 0;
        while (index < group.rows.items.len) {
            const entry = &group.rows.items[index];
            const scope = if (self.node_services) |services| services.peer_id else null;
            const settled_withdraw = (try bootstrap.resolvePendingWithdraw(
                self.allocator,
                self.gifterSessionResolver(),
                self.localObjectProjection(),
                scope,
                entry.receive,
                entry.answer,
            )) orelse {
                index += 1;
                continue;
            };
            try self.sendWithdrawSettled(settled_withdraw);
            var settled = group.rows.swapRemove(index);
            self.pending_withdraw_bytes -= settled.receive.retainedBytes();
            settled.receive.deinit(self.allocator);
            self.pending_withdraw_count -= 1;
        }
        if (group.rows.items.len != 0) return;

        if (self.node_services) |services| services.pendingWithdrawRemoved(dependency);
        const removed = self.pending_withdraws.fetchRemove(dependency).?;
        var empty_group = removed.value;
        empty_group.rows.deinit(self.allocator);
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
    /// it decodes, and nothing else reports one (the scan below only withholds
    /// the question while no whole frame can be there yet), authority is applied through
    /// the same borrowed-validate path, and only then is the frame retained
    /// (the single intentional copy, as on `recvBorrowed`). `buffer` must stay
    /// valid for the call; afterwards the consumed bytes may be discarded.
    ///
    /// This is the only stream entry point, and it fails closed on a prefix
    /// that has reached `max_frame_bytes` and is still open: such a frame can
    /// never complete within the cap, so refusing it is what stops a partner
    /// growing a consumer's buffer without end. That refusal used to live in a
    /// second, wider entry point beside this one, which meant the safe reading
    /// of the same bytes depended on which name a consumer happened to call.
    ///
    /// Successive calls describe one stream: `buffer` may grow, and a partial
    /// frame may move into storage of the consumer's own, but its first byte
    /// stays the first unconsumed byte of the stream. Framing progress is
    /// carried on the peer, so re-pointing it at unrelated bytes mid-frame
    /// makes it withhold frames that are in fact complete.
    ///
    /// A malformed frame or one exceeding `SessionLimits.max_frame_bytes`
    /// projects to a typed outbound `op:abort` and closes the session
    /// (`abort_projection`) before the error surfaces, exactly as the frame
    /// boundary does. `.incomplete` is not an error: no abort, no state change.
    pub fn recvStreamPrefix(self: *Peer, buffer: []const u8) !RecvStream {
        const cap = self.session_state.limits.max_frame_bytes;
        // A frame still arriving is asked about once per read, and the decoder
        // answers by walking from its first byte every time, so a frame
        // delivered in pieces is walked once per piece. The scan carries the
        // codec's position across those asks and withholds the decoder only
        // when every available byte is consumed with the frame still open —
        // exactly when the decoder could only have answered `.incomplete`.
        //
        const prefix = codec.dispatch.framePrefix(
            self.session_state.codec,
            buffer,
            &self.stream_scan,
            cap,
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

    /// Take the next surfaced event, or null when none is queued. The caller
    /// owns the returned event and must `deinit` it after dispatch.
    pub fn pollEvent(self: *Peer) ?Event {
        return self.events.pop(self.allocator);
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
///
/// The most recent 24 of these bytes are two deliberate purchases. Sixteen are
/// the stream scan, bought by giving two others back: Every byte-stream consumer reaches the decoder
/// through `recvStreamPrefix`, so holding the scan here serves the completion
/// loop, the byte-fed host, the blocking pump, and the C ABI from one place —
/// where holding it per consumer served two of them and charged a Bridge
/// connection twice, once in its `Conn` slot and again in its `HostSession`
/// shell, for a frame only one of the two ever framed. The other eight are the
/// end of the session's export range. The allocator is monotonic and counts
/// positions ever minted rather than live ones, so without a far end a
/// long-lived session that mints and releases walks into the next session's
/// range and silently starts naming its objects — the whole hazard the ranges
/// exist to remove. Eight bytes buys a typed refusal instead.
///
/// The most recent eight are the import table's enrolled-token side, one word
/// for a map that is only allocated once a session actually enrolls a
/// capability under a node-unique token (ADR-0069). Most sessions never do, so
/// the ordinary session pays the word and nothing else. It is held on
/// the import row rather than in a node-side memo so it is forgotten when the
/// import is released; a token that outlived its row would name whatever
/// capability the partner put at that position next.
///
/// The most recent eight are the low end of the session's export range. The
/// high end alone stops the allocator being dragged past the range, which is
/// the half that kills a session outright; it says nothing about a position
/// from *below* the range, which names an object this session does not host
/// just as surely. Half a check is what leaves a class of bug alive to be
/// rediscovered, and this class — a name used in a namespace that is not its
/// own — is the one this core has paid for most.
/// 1064 rose to 1104 for ADR-0097's per-session verification contract: the
/// optional 32-byte `expected_durable_key` binding (40 bytes with its tag
/// and alignment) plus the `require_partner_attestation` flag. Weighed
/// deliberately: identity policy is per-session state by design, and the
/// warmed 2 KiB per-session ceiling in `docs/ladder.md` step 2 still holds
/// (`test/engine/footprint_budget_test.zig`).
pub const peer_session_struct_budget_bytes = 1104;
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
        try codec.signed.locationBytesRaw(allocator, raw)
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
        break :signed try codec.signed.locationBytes(allocator, location);
    };
    defer allocator.free(signed);
    crypto.verify(pubkey, signed, sig) catch return error.InvalidStartSessionSignature;
}

/// Verify the partner hello's durable-key credential (ADR-0097): under the
/// `require_partner_attestation` contract, a hello whose claimed location
/// designator parses as a durable Ed25519 key must carry a
/// `session-key-attestation` hint whose 64-byte signature verifies under that
/// durable key over the canonical
/// `<session-key-attestation-v1 transport designator session-pubkey>` record.
/// A claim whose designator is not a key spelling (an ephemeral dialer's
/// address placeholder) names no durable identity, so there is nothing to
/// attest and the hello passes this check. Allocation-free: the hint lookup
/// walks the borrowed view and the record builds in stack scratch, once per
/// hello. Runs at the same pre-open chokepoint as the location signature, so
/// a failed credential refuses the hello before any later frame in the same
/// chunk can apply.
pub fn verifyPartnerAttestation(ss: model.view.StartSession) !void {
    const crypto = foundation.crypto;
    const durable = crypto.PeerKey.fromDesignator(ss.acceptable_location.designator) orelse return;
    const value = ss.acceptable_location.hints.findNamed(model.transport.hint_session_key_attestation) catch
        return error.PartnerAttestationInvalid;
    const sig_bytes = switch (value orelse return error.PartnerAttestationMissing) {
        .bytes => |bytes| bytes,
        else => return error.PartnerAttestationInvalid,
    };
    const sig = crypto.Signature.fromSlice(sig_bytes) catch return error.PartnerAttestationInvalid;
    var buf: [codec.signed.session_key_attestation_max_bytes]u8 = undefined;
    const record = codec.signed.sessionKeyAttestationBytes(
        &buf,
        ss.acceptable_location.transport,
        ss.acceptable_location.designator,
        ss.session_pubkey,
    ) catch return error.PartnerAttestationInvalid;
    crypto.verify(durable, record, sig) catch return error.PartnerAttestationInvalid;
}

/// Sign the ADR-0097 durable-key credential: the durable `secret`'s Ed25519
/// signature over the canonical attestation record for `(transport,
/// designator, session_pubkey)`. The adapter that builds a keyed hello for a
/// durable-key-attestation transport mints this into the hello's
/// `session-key-attestation` hint; while sessions reuse the host key, the
/// durable secret and the session key are the same pair, and the credential
/// stays valid unchanged when step 4 makes the session key fresh. Errors only
/// when a field cannot fit the signing-domain bound.
pub fn mintSessionKeyAttestation(
    secret: *const foundation.crypto.SecretKey,
    transport: []const u8,
    designator: []const u8,
    session_pubkey: []const u8,
) !foundation.crypto.Signature {
    var buf: [codec.signed.session_key_attestation_max_bytes]u8 = undefined;
    const record = try codec.signed.sessionKeyAttestationBytes(&buf, transport, designator, session_pubkey);
    return foundation.crypto.sign(secret, record);
}

/// Assemble a keyed hello's hint entries — the one place the
/// direct-addresses entry, the ADR-0097 credential, and the `#f` empty
/// spelling compose, shared by every keyed hello builder (the byte-fed
/// `Host`'s open tail and the blocking driver's connect/accept) so their
/// hellos sign identical byte shapes. `attest` is the adapter's transport
/// table selecting durable-key attestation; the credential is minted only
/// when the hello's own `designator` is a key spelling — a dialer advertising
/// the unreachable address placeholder claims no durable identity and mints
/// nothing. The returned hints borrow `entry_buf`, `attestation_sig`, and the
/// caller's slices; every hello sender clones them at `sendCopying`. Empty
/// stays the `#f` spelling: a partner verifies the location signature over
/// the exact spelling, and `#f` and `{}` do not verify against each other.
/// `durable_secret` signs the credential and `session_pubkey` is what it
/// authorizes — two different keys, which is the credential's entire point
/// (ADR-0097). They are the same value only while a host signs every session
/// with its durable key, and passing one for both would mint a credential
/// binding a session key the hello does not carry, which the verifier
/// correctly refuses.
pub fn keyedHelloHints(
    entry_buf: *[2]model.HintEntry,
    attestation_sig: *foundation.crypto.Signature,
    direct_addresses_hint: []const u8,
    attest: bool,
    durable_secret: *const foundation.crypto.SecretKey,
    session_pubkey: foundation.crypto.PeerKey,
    transport: []const u8,
    designator: []const u8,
) !model.Hints {
    var entries: usize = 0;
    if (direct_addresses_hint.len != 0) {
        entry_buf[entries] = .{
            .name = model.transport.hint_direct_addresses,
            .value = .{ .string = direct_addresses_hint },
        };
        entries += 1;
    }
    if (attest and foundation.crypto.PeerKey.fromDesignator(designator) != null) {
        attestation_sig.* = try mintSessionKeyAttestation(
            durable_secret,
            transport,
            designator,
            session_pubkey.asBytes(),
        );
        entry_buf[entries] = .{
            .name = model.transport.hint_session_key_attestation,
            .value = .{ .bytes = attestation_sig.asBytes() },
        };
        entries += 1;
    }
    if (entries == 0) return model.Hints.emptyFalse();
    return .{ .entries = entry_buf[0..entries] };
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
