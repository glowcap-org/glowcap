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
const builtin = @import("builtin");

const codec = @import("codec");
const foundation = @import("foundation");
const model = @import("model");
const session = @import("session");

pub const abort_projection = @import("abort_projection.zig");
const abort_info = @import("abort_info.zig");
pub const AbortInfo = abort_info.AbortInfo;
pub const bootstrap = @import("bootstrap.zig");
pub const cross_peer = @import("cross_peer.zig");
pub const events = @import("events.zig");
pub const fetch = @import("fetch.zig");
pub const handoff_gifter = @import("handoff_gifter.zig");
const hello = @import("hello.zig");
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
/// Narrow white-box support for engine tests. Empty in production builds so
/// fixture constructors and budget constants never become library API.
pub const testing = if (builtin.is_test) struct {
    /// The queue-retention bound, exposed so a test can size a burst past it
    /// without hardcoding the production value.
    pub const queue_retain_bytes = steady_queue_bytes;

    /// Already-open v1.0 peer for tests that inject frames directly. Real
    /// sessions start with `Peer.initNegotiating` and authenticate
    /// `op:start-session`.
    pub fn initRawOpenPeer(allocator: std.mem.Allocator) Peer {
        return Peer.initWithSession(allocator, session.Session.initWith(allocator, .{
            .captp_version = model.CaptpVersion.v1_0,
        }));
    }
} else struct {};
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

/// A pending outbound item plus the one admission charge computed when it was
/// staged. The charge is deliberately carried with the item: encoded-frame
/// admission never walks a message tree a second time.
pub const PendingOutbound = struct {
    item: outbound.Outbound,
    charge: usize,
};

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

/// Decode a borrowed body view from an encoded frame — the same projection
/// `Event.view` performs on an inbound frame, surfaced so the host tier can
/// inspect an outbound frame it drained (the live trace's outbound seat)
/// without reaching past the engine into the codec.
pub const decodeBodyView = codec.dispatch.decodeBody;
/// Resolve the registered wire shape for a negotiated codec without exposing
/// codec internals to higher layers that already depend on the engine.
pub const frameShape = codec.dispatch.frameShape;

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

/// What a session knows about the durable identities at the other end of it
/// (ADR-0105). Two parties, so two keys: the CapTP partner this session
/// converses with, and the far end of the byte channel those bytes travel
/// over. They are the same node on a direct dial and different nodes the
/// moment a byte-transparent relay (ADR-0086) sits between them, so one field
/// could hold only one of the two facts and would be read as the other.
///
/// Every consumer asks about a designator, and each field answers for the key
/// it names and no other. That is the whole shape: a name that indexes
/// evidence carries whose namespace it belongs to, or the evidence gets read
/// against the wrong party.
pub const DurablePin = struct {
    /// The durable identity a dial named. This is a target requirement, not
    /// evidence that the connection authenticated that identity.
    demanded_partner: ?foundation.crypto.PeerKey = null,
    /// The durable key the code that realized this connection verified its far
    /// end holds: iroh's QUIC handshake, or WebRTC's DTLS binding under
    /// authorized signaling. Only a realizer may say so
    /// (`Peer.bindVerifiedChannelKey`).
    ///
    /// This is the *byte channel's* far end, which under a relay is the
    /// carrier rather than the partner. It never refuses a partner's claim; it
    /// upgrades provenance to `.authenticated_transport` when the partner
    /// turns out to be that same endpoint, and says nothing when it does not.
    channel: ?foundation.crypto.PeerKey = null,
};

/// What authenticated the durable identity a partner advertised (ADR-0105).
/// Derived from the evidence one session actually holds, never from its
/// transport symbol: same transport name, different code realizing the
/// connection, different answer. `Peer.partnerDurableProvenance` is the one
/// derivation; `driver_core.vocab.DurableProvenance` aliases this type so the
/// byte-fed tier, the trace, and the C ABI all read one verdict.
pub const DurableProvenance = enum {
    /// A lower layer proved the partner holds the durable key it claims, and
    /// the claim names the far end of the byte channel this session runs
    /// over, so the partner and the endpoint this session is encrypted to are
    /// one node.
    authenticated_transport,
    /// Nothing proved the name. A partner that claimed no durable identity at
    /// all lands here too, having no identity to have authenticated.
    unauthenticated,
};

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
    /// A `field` pipeline step reached the Syrup decomposer, which has no wire
    /// shape for it (`pipeline.decomposeOutboundDeliver`).
    UnsupportedPipelineOp,
    /// The partner's `op:start-session` location signature failed to verify.
    InvalidStartSessionSignature,
    /// The partner's selected key-designator route claimed a durable identity
    /// different from the one this dial named (`Peer.demandPartnerDurableKey`,
    /// ADR-0105). An address route makes no durable claim at all and is weighed
    /// by the channel realizer or trusted netlayer instead (ADR-0109).
    PartnerDesignatorMismatch,
    /// The partner selected an extension transport whose designation semantics
    /// are unknown to this node, so its durable locator claim cannot be weighed.
    UnknownTransportSemantics,
    /// A streamed inbound frame exceeded `SessionLimits.max_frame_bytes`
    /// (`Peer.recvStreamPrefix`).
    FrameTooLarge,
    /// The engine-owned staged-plus-encoded outbound budget is full. This is
    /// local backpressure: no protocol state was discarded, and the caller
    /// must drain frames before retrying the send.
    OutboundBackpressure,
};

/// A FIFO with a drain cursor: `push` appends, `pop` advances a head index and
/// reclaims the backing once fully drained — rewind the head, retain capacity
/// up to `steady_queue_bytes`, free anything above it — so steady
/// enqueue/dequeue neither grows without bound nor shifts on every pop, and a
/// burst's capacity does not stay pinned for the peer's life. The four peer
/// queues (inbound frames, pending sends, outbound frames, events) share this
/// one shape instead of open-coding a parallel `_head` field.
fn Queue(comptime T: type, comptime weightOf: ?*const fn (*const T) usize) type {
    return struct {
        items: std.ArrayList(T) = .empty,
        head: usize = 0,
        queued_weight: if (weightOf != null) usize else void = if (weightOf != null) 0 else {},

        const Self = @This();

        /// Append to the back. `pub` so the `pipeline` drain half (the same
        /// engine, split by file) can surface a synthesized local-delivery
        /// event; the queue type itself stays private to the engine.
        pub fn push(self: *Self, allocator: std.mem.Allocator, value: T) !void {
            try self.items.append(allocator, value);
            self.addWeight(&value);
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

        pub fn ensureUnusedCapacity(self: *Self, allocator: std.mem.Allocator, count: usize) !void {
            try self.items.ensureUnusedCapacity(allocator, count);
        }

        pub fn pushAssumeCapacity(self: *Self, value: T) void {
            self.items.appendAssumeCapacity(value);
            self.addWeight(&value);
        }

        /// Dequeue the front element, or null when drained. The rewind, the
        /// dead-prefix slide, and the burst reclaim are `fifo.popHead`, shared
        /// with the engine's action queues so the two cannot drift.
        /// Pub so `outbound.zig` can drain encoded frames.
        pub fn pop(self: *Self, allocator: std.mem.Allocator) ?T {
            const value = fifo.popHead(T, &self.items, &self.head, allocator, steady_queue_bytes) orelse return null;
            self.subtractWeight(&value);
            return value;
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
            const value = self.items.pop().?;
            self.subtractWeight(&value);
            return value;
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

        fn weight(self: *const Self) usize {
            if (weightOf == null) @compileError("weight is available only on an accounted queue");
            return self.queued_weight;
        }

        fn addWeight(self: *Self, value: *const T) void {
            if (weightOf) |measure| {
                self.queued_weight = std.math.add(usize, self.queued_weight, measure(value)) catch unreachable;
            }
        }

        fn subtractWeight(self: *Self, value: *const T) void {
            if (weightOf) |measure| {
                self.queued_weight -= measure(value);
            }
        }

        fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.items.deinit(allocator);
        }
    };
}

fn frameByteLen(frame: *const foundation.Frame) usize {
    return frame.bytes().len;
}

/// One inbound `withdraw-gift` parked until its gift is deposited (ADR-0100).
/// Owns `handoff` (always the `.receive` arm); freed when the withdraw settles
/// or at `Peer.deinit`.
const PendingWithdraw = struct {
    receive: bootstrap.PendingReceive,
    answer: model.AnswerName,
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
    inbound: Queue(foundation.Frame, null),
    pending_send: Queue(PendingOutbound, null),
    /// Bytes charged to staged outbound rows. Each row stores its charge so
    /// dequeueing is O(1) and cannot accidentally re-walk a message tree.
    pending_send_bytes: usize = 0,
    outbound: Queue(foundation.Frame, frameByteLen),
    /// One shared ceiling for staged messages plus encoded frames. A standalone
    /// Peer is deliberately unlimited; Hosts install their explicit high-water
    /// at the negotiating seam.
    outbound_budget: usize = std.math.maxInt(usize),
    events: Queue(Event, null),
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
    /// verifies the session signature over its locator claim by default.
    /// Durable locator ownership still requires matching channel provenance.
    /// The raw `init` peer leaves verification off (it
    /// never handshakes), and the stub-key in-process fixtures opt out through
    /// `NegotiatingOptions` because their handshakes carry no real signature.
    verify_partner_handshake: bool = false,
    /// Stored relayed settlements whose listener carriers could not be
    /// prepared at the terminal commit. Nonzero makes `step` retry one row;
    /// the imported-promise table itself is the authority, so row teardown can
    /// leave this count conservatively high and the next scan repairs it.
    pending_imported_fire_retries: u32 = 0,
    /// What this session knows about durable identity at the other end: the
    /// target a dial named and the byte channel's far end a realizer verified.
    /// Both are installed before any partner byte is fed. Both empty is every
    /// address-transport session and every byte-fed session whose embedder
    /// proved nothing.
    ///
    /// It constrains *durable* names, never `session_pubkey`: each connection
    /// signs with its own key, so a session key is not an identity and
    /// comparing the two proves nothing.
    ///
    /// Nothing outside this file names this field. Reads go through
    /// `demandedPartnerKey`, `verifiedChannelKey`, and
    /// `partnerDurableProvenance`; writes go through the two verbs below,
    /// which is what makes them the whole story. `source-check`'s
    /// `checkDurablePinWriters` holds both halves.
    durable_pin: DurablePin = .{},
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

    /// Negotiated knobs for `initNegotiatingWith`. Version, codec, and feature
    /// set are independent axes; both peers of a pair must carry the same
    /// negotiated values so neither exercises a version, codec, or capability
    /// the other did not advertise. The defaults are read from
    /// Version and codec default to `model.Preference.baseline`, while a new
    /// Pancake peer offers every implemented optional feature. A silent
    /// partner is still interpreted as `Preference.baseline` when its hello is
    /// parsed; local capability and remote compatibility are separate facts.
    pub const NegotiatingOptions = struct {
        captp_version: model.CaptpVersion = model.Preference.baseline.captp_version,
        codec: model.CodecId = model.Preference.baseline.codec,
        features: model.FeatureSet = model.FeatureSet.full(),
        /// Resource bounds for the session (`session.SessionLimits`), fixed at
        /// construction so a caller never has to reach into `session_state`.
        limits: session.SessionLimits = .{},
        /// Verify the partner's `op:start-session` signature (`Peer.verify_partner_handshake`).
        /// On by default: a keyed handshake authenticates its partner. Only the
        /// stub-key in-process fixtures set this false.
        verify_partner_handshake: bool = true,
        /// Shared staged-plus-encoded outbound ceiling. Null leaves a
        /// standalone peer unlimited.
        outbound_high_water_bytes: ?usize = null,
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
        // so the option set has exactly one applier. Listing the fields
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
        // One input, two roles, exactly as the constructor reads it: what a
        // host configures is what this side asks for, and what it speaks
        // until a partner's hello settles otherwise.
        self.session_state.codec = options.codec;
        self.session_state.captp_version = options.captp_version;
        self.session_state.preferred = session.Session.preferenceOf(
            options.captp_version,
            options.codec,
            options.features,
        );
        self.session_state.features = options.features;
        self.session_state.limits = options.limits;
        self.verify_partner_handshake = options.verify_partner_handshake;
        self.outbound_budget = options.outbound_high_water_bytes orelse std.math.maxInt(usize);
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

        for (self.pending_send.pending()) |*pending| {
            pending.item.deinit(self.allocator);
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

    /// Retire every piece of session authority that depends on this peer's Node,
    /// then sever the borrowed services pointer. In particular, local-target
    /// gifts must release their captured actor roots while the Node's projection
    /// callback is still valid; doing that after clearing `node_services` would
    /// silently strand those roots. Node removal calls this before its own tables
    /// move; standalone peers and repeated teardown are no-ops.
    pub fn detachNodeServices(self: *Peer) void {
        const services = self.node_services orelse return;
        var dependencies = self.pending_withdraws.keyIterator();
        while (dependencies.next()) |dependency| services.pendingWithdrawRemoved(dependency.*);
        self.pending_handoff_change = null;
        self.gift_registry.deinit(self.allocator, services.localObjectProjection());
        self.gift_registry = .{};
        self.node_services = null;
    }

    /// Demand the durable identity a dial named, before any partner byte is
    /// fed (ADR-0105). A partner hello that selects a key-designator route must
    /// claim exactly `key`; an independently selected address route makes no
    /// durable claim and is admitted on the realizer or netlayer's evidence.
    ///
    /// This is what the dialer asked for, not evidence. Only a matching
    /// realizer assertion through `bindVerifiedChannelKey` proves it.
    ///
    /// One dial names one identity, so calling this twice with two keys is a
    /// caller bug rather than a partner's doing, and it is asserted rather
    /// than returned: there is no attacker input on this path and no session
    /// state to unwind.
    pub fn demandPartnerDurableKey(self: *Peer, key: foundation.crypto.PeerKey) void {
        if (self.durable_pin.demanded_partner) |existing| std.debug.assert(existing.eql(key));
        self.durable_pin.demanded_partner = key;
    }

    /// Assert that a lower layer proved the far end of this connection's byte
    /// channel holds `key` (ADR-0105). The assertion is made by supplying the
    /// key, so only code that can name a verified remote can make it: the iroh
    /// resident reading a QUIC connection's remote node id, the WebRTC
    /// resident under authorized signaling, `driver.Bridge` through
    /// `net.completion.Loop.verifiedChannelKey`, and the byte-fed Host itself
    /// when a sealed session's Noise handshake completes (ADR-0107). An
    /// unsealed Host has no in-library realizer, so the realizer above it
    /// speaks this through `pancake_host_session_bind_verified_channel_key`,
    /// and a Host whose embedder says nothing asserts nothing.
    ///
    /// The transport *symbol* proves nothing; the code that realized the
    /// connection does, which is why this names the remote rather than the
    /// transport.
    ///
    /// It names the byte channel and never the CapTP partner, so it neither
    /// contradicts nor is contradicted by what a dial demanded: a
    /// byte-transparent relay makes those two different parties, and a session
    /// through one holds both facts at once. What the two together decide is
    /// provenance (`partnerDurableProvenance`), not admission.
    ///
    /// One connection has one realizer, so a second call naming a second key
    /// is a caller bug and is asserted, like the demand above.
    pub fn bindVerifiedChannelKey(self: *Peer, key: foundation.crypto.PeerKey) void {
        if (self.durable_pin.channel) |existing| std.debug.assert(existing.eql(key));
        self.durable_pin.channel = key;
    }

    /// The durable identity a dial demanded of this session's partner, or null
    /// where none did (every accept leg, and every dial on an address
    /// transport). The pre-open chokepoint reads it to weigh the partner's
    /// claim; it is the demand alone, never a realizer's proof, because only a
    /// demand says who this session was supposed to be talking to.
    pub fn demandedPartnerKey(self: *const Peer) ?foundation.crypto.PeerKey {
        return self.durable_pin.demanded_partner;
    }

    /// The durable key the code that realized this connection verified its far
    /// end holds, or null where nothing did. The byte channel's endpoint,
    /// which is the CapTP partner only when the partner's own claim names it.
    pub fn verifiedChannelKey(self: *const Peer) ?foundation.crypto.PeerKey {
        return self.durable_pin.channel;
    }

    /// What authenticated the durable identity the partner advertised, for the
    /// `designator` its hello claimed (ADR-0105). One ordered derivation over
    /// the evidence this session holds, read by the demand at the chokepoint
    /// and by every consumer that reports provenance, so the two cannot drift.
    ///
    /// Every arm answers for the key `designator` names and no other, which is
    /// what makes the argument load-bearing throughout: each fact the pin
    /// holds is a statement about one key, so reading one against a different
    /// name would report a fact about somebody else.
    ///
    /// The proof names the far end of the byte channel, so it authenticates the
    /// partner only when the hello claims that same key. A relay may make the
    /// channel endpoint and CapTP partner different parties.
    pub fn partnerDurableProvenance(self: *const Peer, designator: []const u8) DurableProvenance {
        // An address designator can never encode a key, so failing to parse one
        // also rules out a partner that claimed no durable identity.
        const claimed = foundation.crypto.PeerKey.fromDesignator(designator) orelse return .unauthenticated;
        if (self.durable_pin.channel) |channel| {
            if (channel.eql(claimed)) return .authenticated_transport;
        }
        return .unauthenticated;
    }

    /// Measure one staged outbound carrier once, at the admission boundary.
    /// Store-backed carriers are POD; owned messages account for their retained
    /// model bytes. The result is carried by `PendingOutbound` until dequeue.
    pub fn pendingOutboundCharge(item: outbound.Outbound) !usize {
        return switch (item) {
            .message => |message| model.measureMessageOwnedBytes(message),
            .next_answered => |pair| blk: {
                const operation = try model.measureMessageOwnedBytes(pair.operation);
                const listener = try model.measureMessageOwnedBytes(pair.listener);
                break :blk std.math.add(usize, operation, listener) catch error.MalformedView;
            },
            .settled_answer, .listener_fire => @sizeOf(outbound.Outbound),
        };
    }

    /// Reserve the shared outbound budget and queue capacity before a caller
    /// commits session state. The high-water is a waterline: one producer may
    /// cross it, and the next producer is refused. A single producer must fit
    /// within the mark; otherwise "one may cross" would make the memory bound
    /// arbitrary. The returned reservation must be committed with
    /// `pushPendingAssume` or canceled on the same unwind path.
    pub fn reservePending(self: *Peer, item: outbound.Outbound) !PendingReservation {
        const charge = try pendingOutboundCharge(item);
        const is_handshake = switch (item) {
            .message => |message| message == .start_session,
            else => false,
        };
        if (!is_handshake) {
            // The waterline permits one ordinary producer to cross, but never
            // permits one producer whose retained model is itself larger than
            // the whole budget. That keeps overshoot bounded while allowing a
            // normal atomic operation to finish.
            if (charge > self.outbound_budget) return error.OutboundBackpressure;
            try self.checkOutboundWaterline();
        }
        try self.pending_send.ensureUnusedCapacityForOne(self.allocator);
        self.pending_send_bytes = std.math.add(usize, self.pending_send_bytes, charge) catch
            return error.OutboundBackpressure;
        return .{ .charge = charge };
    }

    pub const PendingReservation = struct { charge: usize };

    pub const InlinePassableStagingReservation = struct { charge: usize };

    /// Admit one complete outbound message retained outside `pending_send`
    /// while its foreign Passable references are projected. Bytes share the
    /// ordinary outbound accounting domain, so later producers observe the
    /// parked work without re-walking its tree.
    pub fn reserveInlinePassableStaging(
        self: *Peer,
        charge: usize,
    ) !InlinePassableStagingReservation {
        if (charge > self.outbound_budget) return error.OutboundBackpressure;
        try self.checkOutboundWaterline();
        self.pending_send_bytes = std.math.add(usize, self.pending_send_bytes, charge) catch
            return error.OutboundBackpressure;
        return .{ .charge = charge };
    }

    pub fn cancelInlinePassableStaging(
        self: *Peer,
        reservation: InlinePassableStagingReservation,
    ) void {
        std.debug.assert(self.pending_send_bytes >= reservation.charge);
        self.pending_send_bytes -= reservation.charge;
    }

    /// One authority transaction that may stage several outbound carriers.
    /// The transaction is one producer for waterline purposes: admission is
    /// checked before its first reservation, while its cumulative retained
    /// model must still fit within the whole budget. Each returned reservation
    /// remains independently cancelable by the caller's unwind path.
    pub const PendingBatch = struct {
        peer: *Peer,
        charge: usize = 0,
        admitted: bool = false,

        pub fn reserve(self: *PendingBatch, item: outbound.Outbound) !PendingReservation {
            const item_charge = try pendingOutboundCharge(item);
            const batch_charge = std.math.add(usize, self.charge, item_charge) catch
                return error.OutboundBackpressure;
            if (batch_charge > self.peer.outbound_budget)
                return error.OutboundBackpressure;
            if (!self.admitted) {
                try self.peer.checkOutboundWaterline();
                self.admitted = true;
            }
            self.peer.pending_send_bytes = std.math.add(
                usize,
                self.peer.pending_send_bytes,
                item_charge,
            ) catch return error.OutboundBackpressure;
            self.charge = batch_charge;
            return .{ .charge = item_charge };
        }
    };

    /// Reserve queue storage once for a multi-carrier authority transaction.
    /// The first actual reservation performs admission, so an upper-bound
    /// `max_items` that produces no carrier does not reject unrelated inbound
    /// work merely because an older producer crossed the waterline.
    pub fn beginPendingBatch(self: *Peer, max_items: usize) !PendingBatch {
        try self.ensurePendingCapacity(max_items);
        return .{ .peer = self };
    }

    /// Reserve queue storage for a group of staged carriers that will be
    /// committed after one authority transaction. `reservePending` still
    /// reserves the common one-row case; preparation code uses this seam when
    /// several reservations must coexist before any row is appended. Without
    /// the batch preflight, repeated `ensureUnusedCapacity(1)` calls all see
    /// the same current length and can leave a later `pushAssumeCapacity`
    /// without a slot.
    pub fn ensurePendingCapacity(self: *Peer, count: usize) !void {
        try self.pending_send.ensureUnusedCapacity(self.allocator, count);
    }

    /// Commit a previously reserved pending row. The reservation makes this
    /// append infallible and avoids recording protocol state without a carrier.
    pub fn pushPendingAssume(self: *Peer, reservation: PendingReservation, item: outbound.Outbound) void {
        self.pending_send.pushAssumeCapacity(.{ .item = item, .charge = reservation.charge });
    }

    /// Cancel a reservation whose item was never committed.
    pub fn cancelPendingReservation(self: *Peer, reservation: PendingReservation) void {
        std.debug.assert(self.pending_send_bytes >= reservation.charge);
        self.pending_send_bytes -= reservation.charge;
    }

    /// Dequeue a staged carrier and transfer its charge to the encoded queue's
    /// accounting domain. The item is owned by the caller after this returns.
    pub fn takePending(self: *Peer) PendingOutbound {
        const pending = self.pending_send.consumeFront(self.allocator);
        std.debug.assert(self.pending_send_bytes >= pending.charge);
        self.pending_send_bytes -= pending.charge;
        return pending;
    }

    /// Undo the most recent staged append on an error path.
    pub fn popPendingBack(self: *Peer) ?PendingOutbound {
        const pending = self.pending_send.popBack() orelse return null;
        std.debug.assert(self.pending_send_bytes >= pending.charge);
        self.pending_send_bytes -= pending.charge;
        return pending;
    }

    /// Refuse a new producer once retained outbound work has reached the
    /// waterline. The producer that crosses it remains admitted atomically;
    /// its retained model bytes or encoded frame bytes are then charged by the
    /// owning queue, so the next producer observes the pressure in O(1). The
    /// initial retained charge must itself fit the budget; only later encoding
    /// expansion may cross it, because that authority is already committed.
    pub fn checkOutboundWaterline(self: *const Peer) !void {
        const current = std.math.add(usize, self.pending_send_bytes, self.outbound.weight()) catch
            return error.OutboundBackpressure;
        if (current >= self.outbound_budget) return error.OutboundBackpressure;
    }

    /// Admit an encoded representation while its staged carrier is still in
    /// the queue. The staged charge is replaced by the encoded charge in one
    /// later infallible commit; checking against it here would double-charge
    /// the same operation and reject a legitimate representation expansion.
    pub fn checkOutboundTransferWaterline(self: *const Peer, staged_charge: usize) !void {
        std.debug.assert(staged_charge <= self.pending_send_bytes);
        const staged_other = self.pending_send_bytes - staged_charge;
        const current = std.math.add(usize, staged_other, self.outbound.weight()) catch
            return error.OutboundBackpressure;
        if (current >= self.outbound_budget) return error.OutboundBackpressure;
    }

    /// Preflight the encoded queue before a staged carrier is consumed. After
    /// this returns, `pushAssumeCapacity` plus `takePending` is the transfer
    /// commit and cannot lose either the frame or its authority carrier.
    pub fn ensureOutboundCapacity(self: *Peer, count: usize) !void {
        try self.outbound.ensureUnusedCapacity(self.allocator, count);
    }

    /// A constant-time view of all outbound work retained by this peer: staged
    /// carriers plus encoded frames. This is the one admission counter exposed
    /// to Host and adapters; neither path walks queued payloads.
    pub fn queuedOutboundBytes(self: *const Peer) usize {
        return std.math.add(usize, self.pending_send_bytes, self.outbound.weight()) catch
            std.math.maxInt(usize);
    }

    /// Whether an encoded outbound frame is queued (`takeOutbound` would
    /// return one) — the cheap emptiness probe a drain loop reads without
    /// popping.
    pub fn hasOutbound(self: *const Peer) bool {
        return !self.outbound.isEmpty();
    }

    /// Whether a decoded inbound event still awaits the caller's serve step.
    /// Host fairness uses this probe to resume one session without draining a
    /// sibling's queued events in a single turn.
    pub fn hasEvent(self: *const Peer) bool {
        return !self.events.isEmpty();
    }

    /// Enqueue an owned `message` for outbound encode, taking ownership of its
    /// heap on every outcome. The canonical, copy-free path: a caller that
    /// built the message moves it in and never frees it. Most kinds are freed
    /// by the peer after `step` encodes them (or here, if recording fails). A
    /// settlement message is the exception: its resolution moves into the
    /// answer store at record time (`Session.applySentResolve`). V1.0 later
    /// encodes a resolver callback; next notifies the mandatory listener. The
    /// store frees it on overwrite or answer teardown. Borrowed or static input
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
        if (prepared.resolver_export) |resolver_export| {
            self.session_state.installOutboundResolver(prepared.answer_position, resolver_export) catch |err| {
                self.session_state.releaseUnsharedExport(resolver_export);
                freeMessage(self.allocator, prepared.message);
                return err;
            };
            self.send(prepared.message) catch |err| {
                // The resolver mention never reached recordSend, so it still
                // has only prepareFetchSwissnum's reservation retain. Retire
                // the link and export together; a retry prepares a fresh,
                // self-consistent answer/resolver pair.
                self.session_state.abandonResolverExport(resolver_export);
                return err;
            };
            return;
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

    /// Borrowed boundary for settling an inbound answer whose identity may be
    /// wire-selected or session-local. The owned queue/store spine consumes the
    /// clone on every outcome.
    pub fn sendAnswerResolutionCopying(
        self: *Peer,
        answer: model.AnswerName,
        resolution: model.Resolution,
    ) !void {
        const owned: model.Resolution = switch (resolution) {
            .fulfill => |value| .{ .fulfill = try model.cloneArgument(self.allocator, value) },
            .@"break" => |reason| .{ .@"break" = .{
                .message = try self.allocator.dupe(u8, reason.message),
            } },
        };
        return outbound.enqueueAnswerResolutionOwned(self, answer, owned);
    }

    /// Commit a prepared `withdraw-gift` settlement. Preparation already owns
    /// the one outbound clone and carries the accepted replay count. `send`
    /// either owns the message or refuses before the
    /// gift moves; only a successful enqueue is followed by the infallible gift
    /// commit.
    pub fn sendWithdrawSettled(self: *Peer, prepared_in: bootstrap.PreparedWithdraw) !void {
        var prepared = prepared_in;
        defer prepared.deinit(self.allocator);
        try outbound.enqueueAnswerResolutionOwned(self, prepared.answer, try prepared.takeResolution());
        prepared.apply(self.allocator, self.localObjectProjection(), self.giftRegistry());
    }

    /// Admit one verified early withdraw without leaving replay authority or a
    /// Node scheduler row half-installed on OOM. A new exact-gift group reserves
    /// both its local row and its Node dependency before the replay count moves;
    /// every operation after `acceptValidatedPendingWithdraw` is infallible.
    pub fn parkPendingWithdraw(
        self: *Peer,
        receive: bootstrap.PendingReceive,
        answer: model.AnswerName,
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

    // ── The keyed hello (`hello.zig`) ────────────────────────────────────────
    // `op:start-session` assembly: hint stamping, transport canonicalization,
    // signing, the partner-knowledge seams (ADR-0118), and the profile
    // settle. `hello.zig` owns the bodies behind these aliases.
    pub const sendKeyedStartSession = hello.sendKeyedStartSession;
    pub const sendKeyedStartSessionAdvertised = hello.sendKeyedStartSessionAdvertised;
    pub const sendKeyedStartSessionExact = hello.sendKeyedStartSessionExact;
    pub const noteKnownPancakePartner = hello.noteKnownPancakePartner;
    pub const dialedLocatorIdentifiesPancake = hello.dialedLocatorIdentifiesPancake;
    pub const answerDeferredHello = hello.answerDeferredHello;
    pub const advertisedLocator = hello.advertisedLocator;
    pub const HelloHints = hello.HelloHints;
    pub const settleNegotiatedProfile = hello.settleNegotiatedProfile;

    /// Queue the recipient half of a three-party handoff. Body lives in
    /// `handoff_recipient.sendWithdrawGift` — the one withdraw deliver shape.
    pub fn sendWithdrawGift(
        self: *Peer,
        secret: foundation.crypto.SecretKey,
        give_bytes: []const u8,
        answer: model.AnswerPosition,
    ) !void {
        return handoff_recipient.sendWithdrawGift(self, secret, give_bytes, answer);
    }

    /// Queue a `deposit-gift` to this (exporter) session's bootstrap object.
    pub fn sendDepositGift(self: *Peer, gift_id: []const u8, gifted: model.Reference) !void {
        return handoff_gifter.sendDepositGift(self, gift_id, gifted);
    }

    /// Resolve `answer` with a signed `desc:handoff-give`. Body lives in
    /// `handoff_gifter.sendResolveHandoffGive`.
    pub fn sendResolveHandoffGive(self: *Peer, answer: model.AnswerName, give_bytes: []const u8) !void {
        return handoff_gifter.sendResolveHandoffGive(self, answer, give_bytes);
    }

    /// Store a signed `desc:handoff-give` as the relayed resolution of
    /// `import_position`. Body lives in `handoff_gifter.applyRelayedHandoffGive`.
    pub fn applyRelayedHandoffGive(
        self: *Peer,
        import_position: model.ImportPosition,
        row_id: u64,
        give_bytes: []const u8,
    ) !void {
        return handoff_gifter.applyRelayedHandoffGive(self, import_position, row_id, give_bytes);
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

    /// The codec an arriving frame is in, which is not the session's codec
    /// until the session is open.
    ///
    /// A handshake cannot be encoded in the result of the handshake. That is
    /// `codec.signed`'s rule one message earlier, and for the same reason.
    ///
    /// Neither side announces the switch. A peer sends nothing but its hello
    /// until its own session opens, and frames are ordered, so the hello that
    /// opens the partner's session is processed before the first frame that
    /// assumes the settled codec.
    pub fn inboundCodec(self: *const Peer) model.CodecId {
        return switch (self.session_state.state) {
            .negotiating => .syrup,
            .open, .closed => self.session_state.codec,
        };
    }

    /// The CapTP profile that admits an arriving frame. Like the codec, the
    /// handshake profile cannot be the result of its own negotiation: every
    /// `op:start-session` is the baseline hello, with preferences in locator
    /// hints. Retained events carry this exact value so later projection reads
    /// the frame under the same profile that admitted it.
    pub fn inboundProfile(self: *const Peer) model.CaptpVersion {
        return switch (self.session_state.state) {
            .negotiating => model.Preference.baseline.captp_version,
            .open, .closed => self.session_state.captp_version,
        };
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
    /// promise; the partner's resolver callback for this id settles it.
    pub fn allocateAnswer(self: *Peer) u64 {
        return self.session_state.allocateOutboundAnswer().int();
    }

    /// The inbound answer a V1.0 resolver import was installed for (ADR-0065).
    /// The vat uses it to route a resolver-only deliver's reply when the wire
    /// carried no answer position.
    pub fn answerForResolverImport(self: *const Peer, resolver_import: model.ImportPosition) ?model.AnswerName {
        return self.session_state.answerForResolverImport(resolver_import);
    }

    /// The inbound answer a deliver settles: its wire answer, or the virtual
    /// answer the engine installed for a V1.0 resolver-only deliver (ADR-0065).
    /// This is the single seam the actor layer routes through, so a resolver-only
    /// deliver's reply reaches the partner without `actors` decoding the CapTP
    /// resolver descriptor. It is generic over the borrowed `model.view.Deliver`
    /// and the owned `model.Deliver` (see `bootstrap.answerForDeliver`).
    pub fn answerForDeliver(self: *const Peer, deliver: anytype) ?model.AnswerName {
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
    /// caller: `Node.RelayRecipient.adopt` (enroll-stamped `row_id`).
    ///
    /// The application supplies this resolution directly — it never funnels
    /// through `send`'s lowering chokepoint — so any node-local foreign-import
    /// token it carries is lowered to its wire reference here (ADR-0069),
    /// before the store owns it, keeping "a token never reaches the wire" true
    /// for the relayed path too. Pinned by `test/engine/node_test.zig`'s
    /// "a relayed resolution carrying a routing token emits the wire import
    /// position, never the token".
    pub fn applyRelayedResolution(self: *Peer, import_position: model.ImportPosition, row_id: u64, resolution_in: model.Resolution) !void {
        return self.applyRelayedResolutionWithPolicy(import_position, row_id, resolution_in, false);
    }

    /// Terminal Node relay: the source fire has been consumed, so allocator or
    /// outbound pressure may delay listener carriers but may not delay the
    /// authoritative recipient store. `step` retries those carriers later.
    pub fn applyRelayedResolutionGuaranteed(self: *Peer, import_position: model.ImportPosition, row_id: u64, resolution_in: model.Resolution) !void {
        return self.applyRelayedResolutionWithPolicy(import_position, row_id, resolution_in, true);
    }

    fn applyRelayedResolutionWithPolicy(
        self: *Peer,
        import_position: model.ImportPosition,
        row_id: u64,
        resolution_in: model.Resolution,
        commit_under_pressure: bool,
    ) !void {
        var resolution = resolution_in;
        self.session_state.rewriteShortenedResolution(&resolution);
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
        const row = self.session_state.findImportedPromise(import_position) orelse {
            freeResolution(self.allocator, resolution);
            return session.Error.InvalidReference;
        };
        if (row.cell.row_id != row_id) {
            freeResolution(self.allocator, resolution);
            return;
        }
        if (row.cell.resolution != null) {
            freeResolution(self.allocator, resolution);
            return session.Error.UnexpectedMessage;
        }

        // Detach listeners reversibly and reserve every fire before the store
        // moves `resolution`. From the store commit onward, listener accounting
        // and carrier publication are allocation-free and cannot lose a
        // subscriber under host pressure.
        var prepared_fires = pipeline.prepareImportedPromiseFires(self, import_position, row_id, resolution) catch |err| {
            if (commit_under_pressure and (err == error.OutOfMemory or err == error.OutboundBackpressure)) {
                // Preparation restored the listener list before returning.
                // Recording owns the preowned resolution on every outcome.
                // Keep its ordinary typed refusals intact even though the row
                // checks above make them lifecycle invariants here: a library
                // must return a violated invariant to its owner, not terminate
                // the process on the owner's behalf.
                const stored = try self.session_state.recordRelayedResolution(import_position, row_id, resolution);
                if (!stored) return;
                std.debug.assert(self.pending_imported_fire_retries < std.math.maxInt(u32));
                self.pending_imported_fire_retries += 1;
                return;
            }
            freeResolution(self.allocator, resolution);
            return err;
        };
        errdefer prepared_fires.abandon(self, import_position);
        // A `row_id` mismatch means the row this relay was queued against was
        // torn down and a different third-party promise re-registered at this
        // position; the stale relay is moot, so fire nothing — exactly as a
        // `listener_fire` carrier whose stamp misses drops at encode.
        if (!(try self.session_state.recordRelayedResolution(import_position, row_id, resolution))) {
            prepared_fires.abandon(self, import_position);
            return;
        }
        const stored = self.session_state.importedPromiseResolution(import_position) orelse unreachable;
        prepared_fires.commit(self, import_position, row_id, stored.*);
    }

    /// Retry one listener batch whose store committed under pressure. Returning
    /// progress keeps `stepToIdle` on the row until every such store is clear;
    /// an OOM leaves both the stored resolution and listener list untouched.
    fn retryImportedPromiseFire(self: *Peer) !bool {
        if (self.pending_imported_fire_retries == 0) return false;
        const import_position = self.session_state.pendingImportedPromiseFire() orelse {
            self.pending_imported_fire_retries = 0;
            return false;
        };
        try pipeline.fireImportedPromiseListeners(self, import_position);
        self.pending_imported_fire_retries -= 1;
        return true;
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
    /// encode one pending outbound item onto `outbound`. A next-profile answered
    /// operation and its mandatory listener are one item and publish two frames
    /// atomically. Returns `.progress`
    /// when it did either and `.idle` when both queues were empty. A queued
    /// inbound frame that fails dispatch takes the same fail-closed path as
    /// `recvBorrowed`: it records `lastAbort`, projects an outbound `op:abort`
    /// when the error has wire meaning, and closes per that projection.
    /// Allocation and outbound pressure from deferred or encode work propagate
    /// without blaming the partner; their carriers remain queued for retry.
    pub fn step(self: *Peer) !StepOutcome {
        return self.stepInner();
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
    /// implementation of "encode everything pending" shared by every driver and adapter.
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
        abort_info.record(&self.last_abort, err);
    }

    /// Record one exact primary plus its bounded cleanup consequences without
    /// replaying them through scalar mutation calls.
    pub fn recordFailureChain(self: *Peer, chain: foundation.FailureChain) void {
        abort_info.recordChain(&self.last_abort, chain);
    }

    /// Attach the consequence that prevented a projected abort from reaching
    /// outbound. The originating failure remains authoritative in `lastAbort`;
    /// this second name prevents its delivery failure from disappearing. A
    /// direct embedder that reports delivery failure without first recording
    /// an origin still gets a truthful primary failure instead of a process
    /// trap; there is no earlier cause for it to displace in that case.
    pub fn recordAbortDeliveryFailure(self: *Peer, err: anyerror) void {
        abort_info.recordAbortDelivery(&self.last_abort, err);
    }

    /// Attach a cleanup or consequence failure without replacing the first
    /// failure at this boundary. If no first failure exists, `err` becomes it;
    /// callers therefore cannot accidentally manufacture a secondary-only
    /// diagnostic.
    pub fn recordSecondaryFailure(self: *Peer, err: anyerror) void {
        abort_info.recordSecondary(&self.last_abort, err);
    }

    fn stepInner(self: *Peer) !StepOutcome {
        if (self.retryImportedPromiseFire() catch |err| {
            projectDeferredStepFailure(self, err);
            return err;
        }) return .progress;
        // A parked `withdraw-gift` settles once its deposit arrives on the live
        // Gifter–Exporter Peer. Node scheduling targets this receiver after
        // that sibling changes, and every step re-checks before other work. The
        // empty-list fast path costs one length read.
        self.settlePendingWithdraws() catch |err| {
            projectDeferredStepFailure(self, err);
            return err;
        };

        // One unit of work per step: dispatch one inbound frame, else encode one
        // pending outbound item. `pop` transfers ownership into dispatch (on
        // success the frame moves into the surfaced event, zero copy; on error
        // dispatch frees it) and reclaims the backing once inbound is drained,
        // the consumed frames below the head were moved out, so reclaim never
        // double-frees. This arm alone owns inbound error projection. The
        // deferred-work arms above and outbound arm below retain their
        // carriers on pressure and therefore propagate without blaming the
        // partner; classifying by error name cannot distinguish those phases.
        if (self.inbound.pop(self.allocator)) |frame| {
            try inbound.dispatchOwnedFrame(self, frame);
            return .progress;
        }

        if (self.pending_send.peek() != null) {
            outbound.stepPending(self) catch |err| {
                projectDeferredStepFailure(self, err);
                return err;
            };
            return .progress;
        }
        return .idle;
    }

    /// Deferred work can expose a protocol violation (for example a queued
    /// pipelined call forming a resolution cycle), but allocator and outbound
    /// pressure leave its authority carrier available for retry. Classify at
    /// this phase boundary instead of treating the same error name as inbound.
    fn projectDeferredStepFailure(self: *Peer, err: anyerror) void {
        switch (err) {
            error.OutOfMemory, error.OutboundBackpressure => {},
            else => inbound.emitAbortForError(self, err),
        }
    }

    fn encodeOutbound(self: *Peer, message: model.Message) !foundation.Frame {
        // A hello cannot use the profile it is negotiating, and deferred
        // encoding means the session may already be open when its queued hello
        // reaches this seam. A pre-open abort belongs to that same baseline
        // envelope: the rejected partner has not settled another codec yet.
        // After open, abort and ordinary traffic use the active session pair.
        const active = model.Preference{
            .captp_version = self.session_state.captp_version,
            .codec = self.session_state.codec,
            .features = self.session_state.features,
        };
        const wire = switch (message) {
            .start_session => model.Preference.baseline,
            .abort => if (self.session_state.state == .negotiating)
                model.Preference.baseline
            else
                active,
            else => active,
        };
        return codec.dispatch.encodeMessageForProfile(
            wire.codec,
            self.allocator,
            wire.captp_version,
            message,
        );
    }

    /// Encode a wire `message` for the session's codec and CapTP profile and push
    /// the frame onto the outbound queue. The one ordinary encode-then-queue seam;
    /// the frame is freed on a push failure and owned by the queue on success.
    pub fn pushEncoded(self: *Peer, message: model.Message) !void {
        var frame = try self.encodeOutbound(message);
        errdefer frame.deinit();
        try self.checkOutboundWaterline();
        try self.outbound.push(self.allocator, frame);
    }

    /// Encode one frame for the front staged carrier without removing that
    /// carrier. Encoding, waterline admission, and outbound capacity are all
    /// fallible while the staged row remains retryable. The caller consumes
    /// the row only after this function succeeds.
    pub fn pushEncodedFromPending(self: *Peer, staged_charge: usize, message: model.Message) !void {
        var frame = try self.encodeOutbound(message);
        errdefer frame.deinit();
        try self.checkOutboundTransferWaterline(staged_charge);
        try self.outbound.ensureUnusedCapacity(self.allocator, 1);
        self.outbound.pushAssumeCapacity(frame);
    }

    /// Encode `op:abort` onto outbound, then close CapTP. A terminal frame is
    /// admitted even when ordinary retained work has crossed its waterline:
    /// suppressing the failure signal would leave the partner waiting on a
    /// session this side has already condemned. The queue still charges the
    /// frame, so the bounded exception is visible until the adapter drains it.
    /// The close follows the successful push so the partner can still take the
    /// terminal frame. Callers that must close even when encode/push fails do so
    /// in their `catch` after calling this.
    pub fn commitAbortOutbound(
        self: *Peer,
        abort: model.AbortReason,
    ) !void {
        var frame = try self.encodeOutbound(.{ .abort = abort });
        errdefer frame.deinit();
        try self.outbound.push(self.allocator, frame);
        self.closeSession();
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
        const wire_profile = self.inboundProfile();
        // A frame still arriving is asked about once per read, and the decoder
        // answers by walking from its first byte every time, so a frame
        // delivered in pieces is walked once per piece. The scan carries the
        // codec's position across those asks and withholds the decoder only
        // when every available byte is consumed with the frame still open —
        // exactly when the decoder could only have answered `.incomplete`.
        //
        const prefix = codec.dispatch.framePrefixForProfile(
            self.inboundCodec(),
            wire_profile,
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
                const shape = codec.dispatch.frameShape(self.inboundCodec()) orelse {
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
                inbound.applyDecodedOwnedFrame(self, owned, decoded.body, wire_profile) catch |err| {
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
/// ADR-0105 added storage for two distinct durable-key facts: the target a dial
/// named and the far end the byte-channel realizer verified. A
/// byte-transparent relay can make those different parties, so one slot cannot
/// represent both without confusing a target requirement with evidence.
/// Weighed deliberately: identity is
/// per-session state by design, the second key is paid only in the struct (the
/// keys are fixed-width and nothing here allocates), and the warmed 2 KiB
/// per-session ceiling in `docs/ladder.md` step 2 still holds
/// (`test/engine/footprint_budget_test.zig`).
///
/// The number is where a 64-bit build measures today, so a field added here is
/// a build failure rather than a withdrawal nobody watches.
///
/// It is still a ceiling and not an equality, unlike the `Conn` slot overhead
/// in `src/net/completion/loop.zig`. That one measures a *difference* between
/// two sizes on whatever target is building, which is stable across targets;
/// this one measures a whole struct full of pointers and `usize`s, and
/// `wasm32` (the sans-io core under `zig build cross-check`) makes it
/// genuinely smaller. So no single number is the measurement on every target,
/// and an equality here would fail the narrow ones.
pub const peer_session_struct_budget_bytes = 1136;
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
/// Goblins-style hint encoding is preserved; codecs without that raw capture
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
