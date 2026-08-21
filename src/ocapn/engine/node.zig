//! `Node` — the sans-io cross-session handoff router (ADR-0066 / ADR-0079).
//!
//! A `Node` is the **router half** of Goblins' `mycapn`: the tables distinct from
//! a per-partner CapTP session. The multi-session CapTP **endpoint** (identity +
//! many partners + handoff) is `driver_core.Host`, which owns one `Node`. The
//! node owns durable identity, advertised locator snapshots and their selected
//! acceptable location,
//! the set of `engine.Peer`s it routes between (keyed by an integer `peer_handle`),
//! a live-session directory that lets a recipient-session withdraw reach the
//! gifter session's `GiftRegistry` (ADR-0100), and the two routing
//! tables that make three-party handoff transparent: `redeemed` routes to
//! exporter sessions that host handed-off capabilities, while
//! `foreign_imports` routes fetched capabilities to their home sessions and
//! real wire references (ADR-0069). Both are keyed by the typed, Node-local
//! identity carried in `Reference.routed`, never a synthetic wire position.
//!
//! It is **sans-io**: it owns no sockets and no event loop. The embedder keeps
//! its own transport and async loop, registers each live session's peer with
//! the node, feeds the peer the bytes it reads, drains the bytes the peer
//! produces, and asks the node to route sends. Every route value is an integer
//! `peer_handle` or owned bytes, so the router is pure data, which is exactly why it
//! lives here in the sync, no-I/O engine core (not the I/O-bearing driver layer)
//! instead of being reimplemented per binding, and why the sans-io
//! `libpancake_ocapn` archive can project it (ADR-0066). The vat (turn loop,
//! promise resolution, behavior dispatch) stays above the node; the standard
//! `driver_core.Host` owns one beside the Node, while embedders still own the
//! scheduler and transport policy above this core boundary.
//!
//! The node owns each registered `engine.Peer` (heap-pinned, since a live
//! session borrows the peer's stable address) and frees it when the
//! session is removed or the node is torn down. The node itself must not move
//! once a session is registered because every Peer services vtable points back
//! to it (the C ABI heap-pins the node for this reason).

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("mod.zig");
const export_ranges = @import("export_ranges.zig");
const fifo = @import("fifo.zig");
const node_actions = @import("node/actions.zig");
const passable = @import("node/passable.zig");
const passable_batches = @import("node/passable/batches.zig");
const passable_leases = @import("node/passable/leases.zig");
const handoff_gifts = @import("node/handoffs/gifts.zig");
const gift_origination = @import("node/handoffs/gifts/origination.zig");
const gift_recipe = @import("node/handoffs/gifts/recipe.zig");
const gift_tickets = @import("node/handoffs/gifts/tickets.zig");
const handoff_waiters = @import("node/handoffs/waiters.zig");
const locator_catalog = @import("node/locators.zig");
const peer_membership = @import("node/peers/membership.zig");
const peer_routes = @import("node/peers/routes.zig");
const proxy_admission = @import("node/proxies/admission.zig");
const proxy_settlement = @import("node/proxies/settlement.zig");
const proxy_topology = @import("node/proxies/topology.zig");
const redeem = @import("node/redeem.zig");
const redeem_dials = @import("node/redeem/dials.zig");
const redeem_plan = @import("node/redeem/plan.zig");
const redeem_withdrawals = @import("node/redeem/withdrawals.zig");

const crypto = foundation.crypto;
pub const PeerHandle = @import("peer_handle.zig").PeerHandle;

const Route = peer_routes.Route;

pub const HandoffWaiterIterator = handoff_waiters.Iterator;

const PeerSlot = peer_membership.Slot;

/// How a session's own signing key is obtained (ADR-0097).
///
/// A `desc:handoff-give` names the gifter–exporter *session*, and its
/// signature must therefore be made by that session's key. The node holds one
/// durable key and does not own session key material, so the layer that does
/// answers here. `resolve` returns null for a peer it does not know, and the
/// node falls back to its durable key.
pub const SessionSecretResolver = struct {
    ctx: ?*anyopaque,
    resolve: *const fn (ctx: ?*anyopaque, peer_handle: PeerHandle) ?crypto.SecretKey,
};

/// Resolve runtime transport designation semantics for peers composed under a
/// Host. A standalone Node uses the built-in model vocabulary; a Host installs
/// its provider registry once the Node has a stable address.
pub const TransportDesignatorResolver = struct {
    ctx: ?*anyopaque,
    resolve: *const fn (ctx: ?*anyopaque, transport: []const u8) ?model.transport.DesignatorScheme,
};

pub const Node = struct {
    /// Max third parties one introducing-session proxy row will introduce to a
    /// single home promise (ADR-0009).
    ///
    /// The recipient side drives this count — it asks, and the application
    /// answers each time with the same foreign promise — while the *home* side
    /// pays when that promise settles to a capability: one signed give and one
    /// `deposit-gift` per recipient, on a session that did one thing. Without
    /// a bound the amplification is unbounded and aimed at a peer that is not
    /// party to it.
    ///
    /// A node constant rather than a `SessionLimits` field: the proxy row is
    /// node-owned, so a per-session field would spend a word on every one of
    /// the connections the footprint budget counts to hold a number only the
    /// node ever reads.
    pub const max_proxy_recipients = proxy_topology.max_recipients;

    /// Bounds the recipient's work when an exporter supplies alternative
    /// locator advice. These are Node-owned limits because the hint is consumed
    /// while staging a cross-session redeem, before any one CapTP session's
    /// `SessionLimits` exists on the dial path. The count includes only
    /// alternatives; the primary locator is always one additional path.
    pub const max_alt_locator_count = redeem_plan.max_alt_locator_count;
    pub const max_alt_locator_bytes = redeem_plan.max_alt_locator_bytes;

    allocator: std.mem.Allocator,
    /// The node's durable identity, expanded once at construction. Hosts draw
    /// fresh keys for their sessions; a standalone Node may use this key as its
    /// session identity through `sessionSecret`. `SecretKey.seed` recovers the
    /// 32 bytes it was built from, so they are not stored twice.
    secret: crypto.SecretKey,
    /// Gifter–Exporter session -> fixed-size gift tag -> receiver sessions whose
    /// parked withdrawals depend on that exact gift. This is scheduler state,
    /// never capability authority: each Peer still owns the signed receive,
    /// exact gift id, and replay count. The nested owner makes gifter closure
    /// proportional to that session's groups, not every Node tenant. Admission
    /// reserves the corresponding changed-list slot, so deposit and close
    /// notification are allocation-free after authority moves.
    handoff_waiters: handoff_waiters.Gifters = .empty,
    handoff_group_count: usize = 0,
    handoff_changes: handoff_waiters.Changes = .empty,
    /// Optional Host-owned mapping between a Port-local export position and
    /// the exact local actor it names. This is node-wide because all Ports of
    /// one Host project the same Vat; keeping it here spends no bytes per Peer.
    local_object_projection: ?engine.bootstrap.gifts.LocalObjectProjection = null,
    /// Optional Host-owned directory used to authenticate a signed give before
    /// its out-of-order deposit exists. Node-wide, so it costs no bytes per
    /// registered Peer.
    gifter_session_resolver: ?engine.bootstrap.gifts.GifterSessionResolver = null,
    /// How a session's own signing key is obtained (ADR-0097). A handoff
    /// record names a session, so the layer above supplies that session's key.
    /// A standalone Node falls back to its durable key.
    session_secret_resolver: ?SessionSecretResolver = null,
    /// Host-owned runtime transport semantics, shared by every registered
    /// Peer through `NodeServices` without spending a field per session.
    transport_designator_resolver: ?TransportDesignatorResolver = null,
    /// Registered CapTP sessions keyed by `peer_handle`: the node-owned,
    /// heap-pinned peer for each live session, whose stable address the
    /// embedder's `net.Connection` borrows. Presence is the entire liveness
    /// marker, and a removed session's row leaves with it, so the table holds
    /// live sessions rather than every session the node has ever registered. A
    /// dense array of slots could not do that, because a slot cannot be
    /// reclaimed without reusing its handle.
    ///
    /// Handles are drawn from `next_peer_handle` and never reused. That is not
    /// bookkeeping: a redeemed route keeps naming its exporter session
    /// after that session dies, and `routeReference` reads the missing peer to
    /// fail the route closed. Hand the same handle to a later session and the
    /// stale route would forward a redeemed capability onto it instead.
    peers: std.AutoHashMapUnmanaged(PeerHandle, PeerSlot) = .empty,
    /// The next peer handle to hand out. Monotonic, so no handle is ever reused;
    /// at one session per nanosecond a `u64` lasts longer than the hardware.
    next_peer_handle: u64 = 0,
    /// V1 Goblins compares a receive count against state on its long-lived
    /// Gifter-Exporter coordinator, not the fresh Receiver-Exporter session
    /// named by the certificate. Automatic V1 redeems therefore issue from one
    /// Node-lifetime cursor so reconnects remain monotonic for that peer. This
    /// is issuance compatibility only: accepted replay state stays on each
    /// Receiver-Exporter Peer, and next uses the session-local emitted cursor.
    next_v1_emitted_handoff_count: u64 = 0,
    /// Where this node's next session starts handing out export positions; see
    /// `initialExportBase`. A plain counter, not an atomic: one thread drives a
    /// node, which is what lets every other table here be a plain map too.
    next_export_base: u64,
    /// One past the last range this node may draw — the top of its own slot.
    /// The counter stops here instead of carrying into the next node's slot,
    /// which would alias that node's sessions one for one.
    export_base_end: u64,
    /// Ranges released sessions gave back, reused oldest-first. Reclamation is
    /// what keeps the session field a bound on *concurrent* sessions rather
    /// than on how many a node may ever mint: a node that churns connections
    /// would otherwise spend its slot and stop minting, which an attacker who
    /// can open and close connections reaches on purpose. Oldest-first, so a
    /// range is reused only after every other freed one has been, and a stale
    /// capability from the released session is as far as it can be from naming
    /// a live object in the session that inherits its numbers.
    freed_export_bases: fifo.ActionFifo(u64) = .{},
    /// One preallocated return slot per live session. Session registration
    /// reserves before publishing its export range; release then recycles that
    /// range without allocation or a failure channel it cannot honestly use.
    export_base_return_reservations: usize = 0,
    /// Capability route id -> exporter route. Applications hold these through
    /// the explicit
    /// `Reference.routed` arm, never a synthetic wire import.
    redeemed: std.AutoHashMapUnmanaged(model.CapabilityRouteId, Route) = .empty,
    /// A fetched far import enrolled under a node-unique route id (ADR-0069), so two
    /// imports at the same wire position on different CapTP sessions never collide.
    /// The `Route` names the home session and the real `far(position)` to
    /// address there — the same shape a redeemed route uses. Sends route through
    /// it, the gifter-side interceptor re-gifts through it, and it is swept in
    /// `removePeer`. Ids are drawn from the shared `next_route_id` counter, so a
    /// given id is in `redeemed` or here, never both.
    foreign_imports: std.AutoHashMapUnmanaged(model.CapabilityRouteId, Route) = .empty,
    /// Latches true the first time this node mints a capability route (ADR-0069),
    /// and stays true thereafter. It is the gate each registered peer reads before
    /// walking an outbound message to lower routes (`Peer.node_services`): a node that
    /// never fetches a foreign capability leaves it false, so every send skips the
    /// walk for one bool load. The peer holds a `*const bool` into this field, so
    /// the node must not move once a session is registered.
    route_lowering_active: bool = false,
    /// One stack-bound Host lowering transaction, present only while the
    /// caller is synchronously entering `Peer.send`/`tell`. The Node claims
    /// the exact opaque retains whose routes it moves into a delayed inline
    /// gift batch; unclaimed retains remain the caller's rollback authority.
    outbound_staging_leases: ?[]OutboundStagingLease = null,
    /// The next node-local capability route id.
    next_route_id: model.CapabilityRouteId = .from(1),
    /// Complete advertised locator snapshots and the explicitly selected
    /// acceptable route. The Catalog is inline; Node remains its aggregate.
    locators: locator_catalog.Catalog = .{},
    /// Recipient-side exporter discovery, dial deduplication, and tracked
    /// withdrawals. The aggregate is inline; its child modules own the complete
    /// transaction without adding a runtime object.
    redeems: redeem.State = .{},
    /// Gifter-side entropy tickets and canonical exporter location recipes.
    /// The aggregate is inline; its leaves own the complete origination.
    gifts: handoff_gifts.State = .{},
    /// Delayed cross-session Passable projections, inline in the Node while
    /// their batch owner holds the complete transaction and its pressure facts.
    inline_passable_batches: passable_batches.Batches = .{},
    /// Reserved host effects and their borrowed drain, inline in the Node.
    actions: node_actions.State = .{},
    /// Introducing-session foreign-promise proxies keyed by home wire import
    /// (ADR-0009). Rows are only inserted once the home `op:listen` is armed.
    promise_proxies: proxy_topology.Proxies = .empty,
    /// Home listener export → home-wire key, for O(1) fire dispatch.
    proxy_by_listener: proxy_topology.ByListener = .empty,
    /// Current shortening target -> stable root key in `promise_proxies`.
    proxy_by_source: proxy_topology.BySource = .empty,

    // ── Export ranges (`export_ranges.zig`) ─────────────────────────────────
    // Disjoint per-session export numbering: the slot arithmetic, the range
    // allocator, and the recycle queue. `export_ranges.zig` owns the bodies
    // and the width constants.
    const initialExportBase = export_ranges.initialExportBase;
    const applyExportRange = export_ranges.applyExportRange;
    const takeExportBase = export_ranges.takeExportBase;
    const recycleExportBase = export_ranges.recycleExportBase;
    const exportBaseEndFor = export_ranges.exportBaseEndFor;

    /// A node bound to a caller-supplied durable identity `seed`, with empty
    /// tables. Draw it at the embedder's I/O boundary because the sans-io core
    /// never generates entropy.
    pub fn init(allocator: std.mem.Allocator, seed: [crypto.SEED_BYTES]u8) Node {
        const base = initialExportBase(seed);
        return .{
            .allocator = allocator,
            .secret = crypto.SecretKey.fromSeed(seed),
            .next_export_base = base,
            .export_base_end = exportBaseEndFor(base),
        };
    }

    /// Tear down the node: detach every registered peer, free the peers the Node
    /// owns, and release the routing tables (including references owned by the
    /// redeemed table). Borrowed peers survive with their Node-dependent session
    /// authority already retired and their services pointer severed.
    pub fn deinit(self: *Node) void {
        // Batches charge recipient Peers and may own a consumed proxy fire, so
        // retire them while every borrowed recipient store is still reachable.
        passable_batches.deinitAll(self);

        // Spend every committed recipient's terminal escrow while borrowed
        // Peer stores are still reachable. Node-owned peers are destroyed
        // immediately afterward; borrowed peers retain the correlated break.
        proxy_settlement.deinitAll(self);

        var peer_it = self.peers.valueIterator();
        while (peer_it.next()) |s| {
            // Retire projection-owned gifts and scheduler dependencies before
            // the callbacks and tables they name disappear with the Node.
            s.peer.detachNodeServices();
            if (s.ownership == .node_owned) {
                s.peer.deinit();
                self.allocator.destroy(s.peer);
            }
        }
        self.peers.deinit(self.allocator);
        handoff_waiters.deinit(self);
        self.freed_export_bases.deinit(self.allocator);

        var route_it = self.redeemed.valueIterator();
        while (route_it.next()) |entry| model.freeReference(self.allocator, entry.reference);
        self.redeemed.deinit(self.allocator);

        var foreign_it = self.foreign_imports.valueIterator();
        while (foreign_it.next()) |entry| model.freeReference(self.allocator, entry.reference);
        self.foreign_imports.deinit(self.allocator);

        self.locators.deinit(self.allocator);

        redeem.deinit(self);
        handoff_gifts.deinit(self);

        node_actions.deinit(self);

        std.crypto.secureZero(u8, std.mem.asBytes(&self.secret));
    }

    pub const setAdvertisedLocator = locator_catalog.setAdvertisedLocator;
    pub const retainAdvertisedLocator = locator_catalog.retainAdvertisedLocator;
    pub const ensureAdvertisedLocator = locator_catalog.ensureAdvertisedLocator;
    pub const removeAdvertisedLocator = locator_catalog.removeAdvertisedLocator;
    pub const selectAdvertisedLocator = locator_catalog.selectAdvertisedLocator;
    pub const advertisedLocator = locator_catalog.advertisedLocator;
    pub const acceptableLocator = locator_catalog.acceptableLocator;

    /// Install the local-object seam used to retain exact gifts across Ports.
    /// A standalone sans-io Node leaves this unset and keeps protocol
    /// references verbatim.
    pub fn setLocalObjectProjection(self: *Node, projection: engine.bootstrap.gifts.LocalObjectProjection) void {
        self.local_object_projection = projection;
    }

    pub fn localObjectProjection(self: *Node) ?engine.bootstrap.gifts.LocalObjectProjection {
        return self.local_object_projection;
    }

    /// Install the seam that answers "what key does this session sign with"
    /// (ADR-0097). The Host installs it once; a standalone node without one
    /// signs with its durable key.
    pub fn setSessionSecretResolver(self: *Node, resolver: SessionSecretResolver) void {
        self.session_secret_resolver = resolver;
    }

    pub fn setTransportDesignatorResolver(self: *Node, resolver: TransportDesignatorResolver) void {
        self.transport_designator_resolver = resolver;
    }

    fn designatorScheme(self: *const Node, transport: []const u8) ?model.transport.DesignatorScheme {
        const resolver = self.transport_designator_resolver orelse {
            const known = model.transport.parseKnown(transport) orelse return null;
            return known.metadata().designator_scheme;
        };
        return resolver.resolve(resolver.ctx, transport);
    }

    /// The key `peer_handle`'s session signs handoff records with: the session's
    /// own where a resolver knows it, else the node's durable key. The one
    /// place that fallback is expressed, so ADR-0097's fresh-key switch has a
    /// single seam rather than a search for `secretKey()` call sites.
    fn sessionSecret(self: *const Node, peer_handle: PeerHandle) ?crypto.SecretKey {
        const resolver = self.session_secret_resolver orelse return self.secretKey();
        // Once a Host installs session-key authority, a missing session is
        // terminal. Falling back to the Node key would deliberately sign a
        // receive or give with an identity the named session never held.
        return resolver.resolve(resolver.ctx, peer_handle);
    }

    pub fn setGifterSessionResolver(self: *Node, resolver: engine.bootstrap.gifts.GifterSessionResolver) void {
        self.gifter_session_resolver = resolver;
    }

    pub fn gifterSessionResolver(self: *Node) ?engine.bootstrap.gifts.GifterSessionResolver {
        return self.gifter_session_resolver;
    }

    pub const registerPeer = peer_membership.registerPeer;

    pub const registerPeerOver = peer_membership.registerPeerOver;

    pub const removePeer = peer_membership.removePeer;

    pub const routeIdOf = peer_routes.routeIdOf;

    pub const redeemedRouteId = peer_routes.redeemedRouteId;

    pub const peer = peer_membership.peer;
    const peerAt = peer_membership.peerAt;

    const enrollRedeemed = peer_routes.enrollRedeemed;

    const route = peer_routes.route;

    const foreignRoute = peer_routes.foreignRoute;

    pub const exporterPeerFor = peer_routes.exporterPeerFor;

    pub const ForeignEnrollmentRollback = peer_routes.ForeignEnrollmentRollback;
    pub const ForeignEnrollment = peer_routes.ForeignEnrollment;

    pub const prepareForeignEnrollment = peer_routes.prepareForeignEnrollment;

    pub const rollbackForeignEnrollment = peer_routes.rollbackForeignEnrollment;

    pub const enrollForeign = peer_routes.enrollForeign;

    const homeOf = peer_routes.homeOf;

    pub const argIsForeign = peer_routes.argIsForeign;

    pub const lowerForConn = peer_routes.lowerForConn;

    pub const OutboundStagingLease = passable_leases.Lease;
    pub const beginOutboundStagingLeases = passable_leases.begin;
    pub const endOutboundStagingLeases = passable_leases.end;
    pub const inlineProjectionRoute = passable_leases.inlineProjectionRoute;

    fn prepareV1HandoffCount(self: *Node) engine.node_services.HandoffCountError!engine.bootstrap.gifts.PreparedHandoffCount {
        const handoff_count = self.next_v1_emitted_handoff_count;
        if (handoff_count == std.math.maxInt(u64)) return error.HandoffCountExhausted;
        return engine.bootstrap.gifts.PreparedHandoffCount.bind(self, handoff_count, commitV1HandoffCount);
    }

    fn commitV1HandoffCount(self: *Node, prepared: u64) engine.bootstrap.gifts.HandoffCountCommitError!void {
        if (self.next_v1_emitted_handoff_count != prepared or prepared == std.math.maxInt(u64))
            return error.StaleHandoffCountPreparation;
        self.next_v1_emitted_handoff_count = prepared + 1;
    }

    pub const nextHandoffChange = handoff_waiters.nextChange;

    pub const handoffWaiterCount = handoff_waiters.countForGifter;

    pub const handoffWaiters = handoff_waiters.iterate;

    pub const consumeHandoffChange = handoff_waiters.consume;

    /// Logical close, not later shell destruction, is the handoff authority
    /// boundary. Retire recipient batches while their outbound reservations
    /// still name a live Peer, and fail batches that depended on this home.
    fn sessionClosed(self: *Node, peer_handle: PeerHandle) void {
        handoff_waiters.markGifterClosed(self, peer_handle);
        passable_batches.retireRecipient(self, peer_handle);
        passable_batches.failForHome(self, peer_handle);
        proxy_settlement.sweepForPeer(self, peer_handle);
    }

    pub const Routed = peer_routes.Routed;

    pub const routeReference = peer_routes.routeReference;

    pub const routeCapability = peer_routes.routeCapability;

    pub const retireReleasedRoute = peer_routes.retireReleasedRoute;

    pub const consumeRedeemedRoute = peer_routes.consumeRedeemedRoute;

    // ── Recipient withdraw (the redeem half) ─────────────────────────────────

    /// The node's durable secret, derived from its retained seed. A Host uses
    /// this for durable identity and supplies each session's fresh signing
    /// key through `SessionSecretResolver`.
    pub fn secretKey(self: *const Node) crypto.SecretKey {
        return self.secret;
    }

    /// The public half of this node's durable identity. Transport adapters
    /// use this to advertise a key designator without copying the retained
    /// signing secret across the engine boundary.
    pub fn publicKey(self: *const Node) crypto.PeerKey {
        return self.secret.publicKey();
    }

    // ── The sans-io redeem serve-step API ─────────────────────────────────────

    pub const PendingId = redeem_dials.PendingId;
    pub const RedeemDestination = redeem.Destination;

    pub const FailureDestination = node_actions.FailureDestination;

    pub const PendingDialView = redeem_dials.PendingDialView;

    pub const FailureReason = node_actions.FailureReason;

    pub const DialFailure = redeem_dials.Failure;

    pub const Action = node_actions.Action;

    pub const pendingDial = redeem_dials.pendingDial;
    pub const beginDialEffect = redeem_dials.beginEffect;
    pub const rollbackDialEffect = redeem_dials.rollbackEffect;
    pub const DialCancellationIterator = redeem_dials.CancellationIterator;
    pub const requestDialCancellations = redeem_dials.requestCancellations;
    pub const pendingDialCount = redeem_dials.count;

    pub const pendingGiftEffects = gift_tickets.count;
    pub const hasPendingGift = gift_tickets.contains;

    pub const cancelInlineGive = redeem_dials.cancelInlineGive;

    /// Terminal owner cancellation spends every entropy request before an
    /// embedder can turn it into new handoff work. Queued ticket actions become
    /// stale no-ops; failure storage and scheduler reservations retire here.
    pub fn cancelPendingGifts(self: *Node) void {
        passable_batches.cancelAll(self);
        gift_tickets.cancelAll(self);
    }

    pub const dialCancelled = redeem_dials.cancelled;

    pub const hasAction = node_actions.hasAction;
    pub const peekAction = node_actions.peekAction;
    pub const consumePeekedAction = node_actions.consumePeekedAction;
    pub const nextAction = node_actions.nextAction;

    pub const acceptGive = redeem_dials.acceptGive;
    pub const acceptInlineGive = redeem_dials.acceptInlineGive;
    pub const DialStage = redeem_dials.Stage;
    pub const stageDial = redeem_dials.stage;
    pub const exporterDialed = redeem_dials.exporterDialed;
    pub const exporterSelected = redeem_dials.exporterSelected;
    pub const exporterApplicationOwned = redeem_dials.exporterApplicationOwned;
    pub const claimExporterRetirement = redeem_dials.claimExporterRetirement;
    pub const dialFailed = redeem_dials.failed;
    pub const RedeemOutcome = redeem_withdrawals.Outcome;
    pub const claimResolve = redeem_withdrawals.claim;

    pub const setExporterLocation = gift_recipe.set;

    pub const proxyForeignPromiseFulfill = proxy_admission.foreignPromiseFulfill;

    /// Whether `(home_peer, listener_export)` is an armed proxy home-listener.
    /// Host peeks this before materializing a deliver's resolution so ordinary
    /// listen fires pay no clone on the miss path.
    pub const isProxyHomeListener = proxy_settlement.isHomeListener;

    /// Peek → materialize → consume a proxy home-listener fire. Miss path never
    /// allocates. Hit path takes ownership of the materialized resolution and
    /// never returns false after `toOwned`.
    pub const claimProjectedProxyListenerFire = proxy_settlement.claimProjectedListenerFire;

    pub const RelayRecipient = proxy_settlement.RelayRecipient;

    pub const projectProxyListenerFire = proxy_settlement.projectListenerFire;

    /// Consume a proxy fire whose owning Host could not lift/project. Every
    /// recipient already owns a terminal seat, so failure is correlated and
    /// allocation-free rather than escaping as a host-wide step error.
    pub const breakProxyListenerFire = proxy_settlement.breakListenerFire;

    /// Consume a complete resolution that is already expressed in Node
    /// identity: ordinary data plus enrolled foreign routes, never raw
    /// positions borrowed from some other session. This is the low-level peer
    /// face of the Host projection above. Every recipient materializes and
    /// stages independently; `resolution` remains one owner until all
    /// projections have adopted or broken, then is freed exactly once.
    pub const consumeProjectedProxyListenerFire = proxy_settlement.consumeProjectedListenerFire;

    pub const interceptFulfilledRoute = gift_origination.interceptFulfilledRoute;
    pub const interceptFulfilledRouteNamed = gift_origination.interceptFulfilledRouteNamed;
    pub const provideGiftId = gift_origination.provideGiftId;
    pub const giftIdFailed = gift_origination.giftIdFailed;
};

/// File-private friend index for Node's extracted child authorities.
///
/// `Node` remains the supported API. These direct aliases let the extracted
/// modules preserve teardown order and callback identity without a forwarding
/// call layer or a second state owner.
pub const Internal = struct {
    pub const peerAt = Node.peerAt;
    pub const retireInlinePassableRecipientBatchesForPeer = passable_batches.retireRecipient;
    pub const markGifterHandoffsChanged = handoff_waiters.markGifterClosed;
    pub const evictExporterCache = redeem_dials.evictExporterCache;
    pub const failWithdrawsForPeer = redeem_withdrawals.failForPeer;
    pub const failInlinePassableBatchesForHome = passable_batches.failForHome;
    pub const sweepPromiseProxiesForPeer = proxy_settlement.sweepForPeer;
    pub const stageOutbound = passable_batches.stageOutbound;
    pub const stageInlinePassable = passable_batches.stage;
    pub const claimOutboundStagingLease = passable_leases.claim;
    pub const unclaimOutboundStagingLease = passable_leases.unclaim;
    pub const sessionSecret = Node.sessionSecret;
    pub const foreignRoute = Node.foreignRoute;
    pub const homeOf = Node.homeOf;
    pub const InlinePassablePayload = passable.Payload;
    pub const InlinePassableDestination = passable_batches.Destination;
    pub const addHandoffWaiter = handoff_waiters.add;
    pub const removeHandoffWaiter = handoff_waiters.remove;
    pub const markHandoffChanged = handoff_waiters.markChanged;
    pub const sessionClosed = Node.sessionClosed;
    pub const prepareV1HandoffCount = Node.prepareV1HandoffCount;
    pub const prepareProxyPromiseShortening = proxy_topology.prepareShortening;
    pub const commitProxyPromiseShortening = proxy_topology.commitShortening;
    pub const designatorScheme = Node.designatorScheme;
};
