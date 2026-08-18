//! `Node` — the sans-io cross-session handoff router (ADR-0066 / ADR-0079).
//!
//! A `Node` is the **router half** of Goblins' `mycapn`: the tables distinct from
//! a per-partner CapTP session. The multi-session CapTP **endpoint** (identity +
//! many partners + handoff) is `driver_core.Host`, which owns one `Node`. The
//! node owns durable identity, advertised locator snapshots and their selected
//! acceptable location,
//! the set of `engine.Peer`s it routes between (keyed by an integer `peer_id`),
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
//! `peer_id` or owned bytes, so the router is pure data, which is exactly why it
//! lives here in the sync, no-I/O engine core (not the I/O-bearing driver layer)
//! instead of being reimplemented per binding, and why the sans-io
//! `libpancake_ocapn` archive can project it (ADR-0066). The vat (turn loop,
//! promise resolution, behavior dispatch) stays
//! above the node, in the embedder, because that is the host-scheduler adapter
//! (ADR-0066 records the boundary).
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
const session_mod = @import("session");

const ActionFifo = @import("fifo.zig").ActionFifo;

const crypto = foundation.crypto;
pub const PeerId = @import("peer_id.zig").PeerId;
const HandoffDependency = engine.node_services.HandoffDependency;

/// Where a redeemed route routes: the exporter connection that hosts the real
/// capability, and the real exporter-side reference to swap in when forwarding.
/// The node owns `reference`.
const Route = struct {
    peer_id: PeerId,
    reference: model.Reference,
};

const no_handoff_change = std.math.maxInt(usize);
const exporter_closed_reason = "handoff redeem failed: exporter connection closed";
const proxy_failure_reason = "relayed promise could not be settled";
const HandoffReceivers = std.AutoHashMapUnmanaged(PeerId, void);

pub const HandoffWaiterIterator = struct {
    inner: HandoffReceivers.KeyIterator,

    pub fn next(self: *HandoffWaiterIterator) ?PeerId {
        const receiver = self.inner.next() orelse return null;
        return receiver.*;
    }
};

/// Scheduler-only dependencies for withdrawals awaiting one exact gift on one
/// live gifter session. A receiver owns at most one group for this key, so the
/// receiver set needs no duplicate count.
const HandoffWaiterGroup = struct {
    receivers: HandoffReceivers = .empty,
    changed_index: usize = no_handoff_change,
};

/// All exact gift groups rooted in one live Gifter–Exporter session. Making
/// the gifter the outer key means session close touches only its own groups;
/// unrelated tenants never enter that teardown path.
const GifterHandoffGroups = struct {
    gifts: std.AutoHashMapUnmanaged([16]u8, HandoffWaiterGroup) = .empty,
};

/// One recipient for an introducing-session foreign-promise proxy (ADR-0009).
/// `row_id` is stamped at enroll so a GC/re-register between enroll and fire
/// cannot satisfy a stale relay (same contract as `recordRelayedResolution`).
const ProxyRecipient = struct {
    peer: PeerId,
    import_pos: u64,
    row_id: u64,
    /// Admission escrow for the one terminal break this recipient is owed.
    /// Once the home fire is consumed, allocator pressure must not leave the
    /// relayed promise pending forever.
    failure_reason: ?[]u8,

    fn releaseFailure(self: *ProxyRecipient, allocator: std.mem.Allocator) void {
        if (self.failure_reason) |reason| allocator.free(reason);
        self.failure_reason = null;
    }

    fn takeFailure(self: *ProxyRecipient) []u8 {
        const reason = self.failure_reason orelse unreachable;
        self.failure_reason = null;
        return reason;
    }
};

/// Composite identity for a home-session wire import that is being proxied.
const ProxyHomeKey = struct {
    home: PeerId,
    wire_pos: u64,
};

/// Home-session listener export that receives the home `op:listen` fire.
const ProxyListenerKey = struct {
    home: PeerId,
    listener_export: u64,
};

/// Armed introducing-session proxy: **one** home `op:listen`, one or more
/// recipient third-party import rows. On fire the Host lifts once; each
/// recipient then materializes its independently lowered tree through Node's
/// bounded Passable transaction. Never N home listens.
const PromiseProxy = struct {
    listener_export: u64,
    current_wire_pos: u64,
    recipients: std.ArrayListUnmanaged(ProxyRecipient) = .empty,

    fn deinit(self: *PromiseProxy, allocator: std.mem.Allocator) void {
        for (self.recipients.items) |*recipient| recipient.releaseFailure(allocator);
        self.recipients.deinit(allocator);
    }
};

/// One registered connection: the peer plus who frees it. `registerPeer` mints
/// a node-owned peer (freed on removal and at `deinit`);
/// `registerPeerOver` adopts a peer the embedder pins (`.borrowed`, only
/// unregistered here), which is how a peer-owning driver like the completion
/// loop joins the node without surrendering its inline peer.
const PeerOwnership = enum {
    /// `registerPeer` allocated and owns the Peer; `removePeer` / `deinit` free it.
    node_owned,
    /// `registerPeerOver` adopted an embedder-owned Peer; the Node never frees it.
    borrowed,
};

const PeerSlot = struct {
    peer: *engine.Peer,
    /// Withdraws currently awaiting a resolve on this session. Kept beside
    /// ownership so a failed redeem can decide in O(1) whether it was the last
    /// use of a redeem-only exporter connection.
    pending_withdraw_count: u32 = 0,
    ownership: PeerOwnership,
    /// This session was opened solely to redeem a handoff and has not yet
    /// produced a capability or been selected by an application operation.
    provisional_exporter: bool = false,
};

/// How a session's own signing key is obtained (ADR-0097).
///
/// A `desc:handoff-give` names the gifter–exporter *session*, and its
/// signature must therefore be made by that session's key. The node holds one
/// durable key and does not own session key material, so the layer that does
/// answers here. `resolve` returns null for a peer it does not know, and the
/// node falls back to its durable key.
pub const SessionSecretResolver = struct {
    ctx: ?*anyopaque,
    resolve: *const fn (ctx: ?*anyopaque, peer_id: PeerId) ?crypto.SecretKey,
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
    pub const max_proxy_recipients: usize = 1_024;

    /// Bounds the recipient's work when an exporter supplies alternative
    /// locator advice. These are Node-owned limits because the hint is consumed
    /// while staging a cross-session redeem, before any one CapTP session's
    /// `SessionLimits` exists on the dial path. The count includes only
    /// alternatives; the primary locator is always one additional path.
    pub const max_alt_locator_count: usize = 8;
    pub const max_alt_locator_bytes: usize = 4 * 1024;

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
    handoff_waiters: std.AutoHashMapUnmanaged(PeerId, GifterHandoffGroups) = .empty,
    handoff_group_count: usize = 0,
    handoff_changes: std.ArrayListUnmanaged(HandoffDependency) = .empty,
    /// Optional Host-owned mapping between a Port-local export position and
    /// the exact local actor it names. This is node-wide because all Ports of
    /// one Host project the same Vat; keeping it here spends no bytes per Peer.
    local_object_projection: ?engine.bootstrap.LocalObjectProjection = null,
    /// Optional Host-owned directory used to authenticate a signed give before
    /// its out-of-order deposit exists. Node-wide, so it costs no bytes per
    /// registered Peer.
    gifter_session_resolver: ?engine.bootstrap.GifterSessionResolver = null,
    /// How a session's own signing key is obtained (ADR-0097). A handoff
    /// record names a session, so the layer above supplies that session's key.
    /// A standalone Node falls back to its durable key.
    session_secret_resolver: ?SessionSecretResolver = null,
    /// Host-owned runtime transport semantics, shared by every registered
    /// Peer through `NodeServices` without spending a field per session.
    transport_designator_resolver: ?TransportDesignatorResolver = null,
    /// Registered CapTP sessions keyed by `peer_id`: the node-owned, heap-pinned
    /// peer for each live session, whose stable address the embedder's
    /// `net.Connection` borrows. Presence is the entire liveness marker, and a
    /// removed session's row leaves with it, so the table holds live sessions
    /// rather than every session the node has ever registered. A dense array of
    /// slots could not do that, because a slot cannot be reclaimed without
    /// reusing its id.
    ///
    /// Ids are drawn from `next_peer_id` and never reused. That is not
    /// bookkeeping: a redeemed route keeps naming its exporter session
    /// after that session dies, and `routeReference` reads the missing peer to
    /// fail the route closed. Hand the same id to a later session and the stale
    /// route would forward a redeemed capability onto it instead.
    peers: std.AutoHashMapUnmanaged(PeerId, PeerSlot) = .empty,
    /// The next session id to hand out. Monotonic, so no id is ever reused; at
    /// one session per nanosecond a `u64` lasts longer than the hardware.
    next_peer_id: u64 = 0,
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
    freed_export_bases: std.ArrayListUnmanaged(u64) = .empty,
    /// One preallocated return slot per live session. Session registration
    /// reserves before publishing its export range; release then recycles that
    /// range without allocation or a failure channel it cannot honestly use.
    export_base_return_reservations: usize = 0,
    /// How much of `freed_export_bases` is already handed back out. The list is
    /// a queue read from this cursor and compacted in `takeExportBase`, so it
    /// stays proportional to the ranges actually outstanding.
    freed_export_head: usize = 0,
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
    /// This node's published locator snapshot for each transport. Map keys
    /// alias the corresponding value's owned `transport` bytes.
    advertised_locators: std.StringHashMapUnmanaged(model.PeerLocator) = .empty,
    /// The transport whose retained snapshot is this node's current
    /// `acceptable-location`. Aliases that map entry's owned transport bytes.
    /// Null means no route is selected; removal never chooses another route
    /// implicitly because route preference is deployment policy.
    acceptable_transport: ?[]const u8 = null,
    /// The serve step's exporter cache: canonical peer-identity URI → live
    /// CapTP session already dialed for that exporter (`uri.canonicalPeerIdentityUri`),
    /// so a second redeem reuses the session even when the give's encoded form
    /// or hints differ.
    exporters: std.StringHashMapUnmanaged(PeerId) = .empty,
    /// Dials in flight, keyed by the `PendingId` the `dial` action carried.
    pending_dials: std.AutoHashMapUnmanaged(PendingId, PendingDial) = .empty,
    /// Side index for `pending_dials`: canonical identity URI → ticket (keys
    /// alias the pending row's owned `identity`). O(1) join of a second redeem
    /// onto an in-flight dial — not a second locator owner.
    pending_dial_by_identity: std.StringHashMapUnmanaged(PendingId) = .empty,
    /// Withdraws awaiting resolution, keyed by (exporter conn, withdraw answer).
    pending_withdraws: std.AutoHashMapUnmanaged(WithdrawKey, PendingWithdraw) = .empty,
    /// Claimed gifter originations awaiting their host-drawn gift id, keyed by
    /// the `need_gift_id` ticket.
    pending_gifts: std.AutoHashMapUnmanaged(u64, PendingGift) = .empty,
    /// Complete outbound messages parked while every foreign capability in
    /// their Passable value tree is projected for the recipient. Object
    /// projections wait for host-drawn gift ids; promise projections prepare
    /// their proxy escrows in the same transaction. The Node owns the message
    /// until every consequence can commit together.
    pending_inline_passables: std.AutoHashMapUnmanaged(InlinePassableBatchId, InlinePassableBatch) = .empty,
    /// Aggregate staged projection occurrences by recipient. Batches are already
    /// individually queue-capped; this second bound prevents queue-cap batches
    /// from retaining queue-cap metadata each.
    pending_inline_passable_occurrences: std.AutoHashMapUnmanaged(PeerId, usize) = .empty,
    /// Per-connection give-location overrides (`setExporterLocation`),
    /// node-owned canonical Syrup locator-record bytes.
    exporter_locations: std.AutoHashMapUnmanaged(PeerId, []u8) = .empty,
    /// The serve step's action queue (`nextAction` drains it).
    actions: ActionFifo(Action) = .{},
    /// One future recipient drive action promised by each live proxy escrow,
    /// including escrows moved into `pending_gifts`. `reserveActions` protects
    /// these seats from unrelated immediate actions until settlement spends or
    /// releases them.
    proxy_action_reservations: usize = 0,
    /// One terminal failure seat per handoff redeem waiting on an exporter
    /// dial. Owner cancellation cannot allocate, so admission holds these
    /// seats until success transfers them to pending withdraws or a terminal
    /// path spends them directly.
    pending_dial_waiter_reservations: usize = 0,
    /// Future terminal seats held by inline-Passable batches. Success spends
    /// the required exporter/home FLUSH actions, one Host-retain release per
    /// occurrence, one future promise-settlement action per projected promise,
    /// and one recipient FLUSH. Failure spends the retain releases plus one
    /// correlated session failure and releases the surplus.
    inline_passable_action_reservations: usize = 0,
    /// The most recently popped action; its byte views stay valid until the
    /// next `nextAction`, which frees them.
    last_action: ?Action = null,
    /// The next pending-dial ticket.
    next_pending: PendingId = 0,
    next_inline_batch: u64 = 1,
    /// Introducing-session foreign-promise proxies keyed by home wire import
    /// (ADR-0009). Rows are only inserted once the home `op:listen` is armed.
    promise_proxies: std.AutoHashMapUnmanaged(ProxyHomeKey, PromiseProxy) = .empty,
    /// Home listener export → home-wire key, for O(1) fire dispatch.
    proxy_by_listener: std.AutoHashMapUnmanaged(ProxyListenerKey, ProxyHomeKey) = .empty,
    /// Current shortening target -> stable root key in `promise_proxies`.
    proxy_by_source: std.AutoHashMapUnmanaged(ProxyHomeKey, ProxyHomeKey) = .empty,

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
        // Inline batches charge their recipient Peer's outbound budget, so
        // cancel them before detaching or freeing any Peer. Host teardown owns
        // the aggregate capability registry and does not need per-lease release
        // actions after the Node itself is being destroyed.
        var inline_gift_it = self.pending_inline_passables.valueIterator();
        while (inline_gift_it.next()) |batch| batch.deinit(self);
        self.pending_inline_passables.deinit(self.allocator);
        std.debug.assert(self.inline_passable_action_reservations == 0);
        std.debug.assert(self.pending_inline_passable_occurrences.count() == 0);
        self.pending_inline_passable_occurrences.deinit(self.allocator);

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
        var gifter_it = self.handoff_waiters.valueIterator();
        while (gifter_it.next()) |gifter| {
            var gift_it = gifter.gifts.valueIterator();
            while (gift_it.next()) |group| group.receivers.deinit(self.allocator);
            gifter.gifts.deinit(self.allocator);
        }
        self.handoff_waiters.deinit(self.allocator);
        self.handoff_changes.deinit(self.allocator);
        self.freed_export_bases.deinit(self.allocator);

        var route_it = self.redeemed.valueIterator();
        while (route_it.next()) |entry| model.freeReference(self.allocator, entry.reference);
        self.redeemed.deinit(self.allocator);

        var foreign_it = self.foreign_imports.valueIterator();
        while (foreign_it.next()) |entry| model.freeReference(self.allocator, entry.reference);
        self.foreign_imports.deinit(self.allocator);

        var locator_it = self.advertised_locators.valueIterator();
        while (locator_it.next()) |locator| model.freePeerLocator(self.allocator, locator.*);
        self.advertised_locators.deinit(self.allocator);

        var exporter_keys = self.exporters.keyIterator();
        while (exporter_keys.next()) |key| self.allocator.free(key.*);
        self.exporters.deinit(self.allocator);

        var dial_it = self.pending_dials.valueIterator();
        while (dial_it.next()) |pending| {
            self.freePendingDialBytes(pending);
            for (pending.waiters.items) |waiter| self.allocator.free(waiter.give);
            self.releasePendingDialWaiterReservations(pending.waiters.items.len);
            pending.waiters.deinit(self.allocator);
        }
        std.debug.assert(self.pending_dial_waiter_reservations == 0);
        self.pending_dials.deinit(self.allocator);
        // Keys alias pending identity URIs freed above.
        self.pending_dial_by_identity.deinit(self.allocator);
        self.pending_withdraws.deinit(self.allocator);
        var gift_it = self.pending_gifts.valueIterator();
        while (gift_it.next()) |gift| {
            if (gift.failure_reason != null) self.releaseProxyActionReservation();
            gift.releaseFailure(self.allocator);
        }
        self.pending_gifts.deinit(self.allocator);

        var location_it = self.exporter_locations.valueIterator();
        while (location_it.next()) |location| self.allocator.free(location.*);
        self.exporter_locations.deinit(self.allocator);

        if (self.last_action) |last| self.freeAction(last);
        for (self.actions.unpopped()) |action| self.freeAction(action);
        self.actions.deinit(self.allocator);

        var proxy_it = self.promise_proxies.valueIterator();
        while (proxy_it.next()) |proxy| self.deinitProxyStorage(proxy);
        std.debug.assert(self.proxy_action_reservations == 0);
        self.promise_proxies.deinit(self.allocator);
        self.proxy_by_listener.deinit(self.allocator);
        self.proxy_by_source.deinit(self.allocator);
        std.crypto.secureZero(u8, std.mem.asBytes(&self.secret));
    }

    /// Replace the complete locator retained for its transport and select it
    /// as this node's `acceptable-location`. The node takes a deep copy before
    /// changing the registry, so failure preserves both the old snapshot and
    /// the old selection; the caller retains ownership of `locator`.
    pub fn setAdvertisedLocator(self: *Node, locator: model.PeerLocator) !void {
        try self.retainAdvertisedLocator(locator);
        std.debug.assert(self.selectAdvertisedLocator(locator.transport));
    }

    /// Replace the retained snapshot for `locator.transport` without changing
    /// which transport is selected. If this transport was already selected,
    /// keep it selected through the replacement while updating the borrowed
    /// key slice to the new owned allocation.
    pub fn retainAdvertisedLocator(self: *Node, locator: model.PeerLocator) !void {
        const owned = try model.view.PeerLocator.fromOwned(&locator).toOwned(self.allocator);
        errdefer model.freePeerLocator(self.allocator, owned);

        const entry = try self.advertised_locators.getOrPut(self.allocator, owned.transport);
        if (!entry.found_existing) {
            entry.value_ptr.* = owned;
            return;
        }

        const was_selected = if (self.acceptable_transport) |selected|
            std.mem.eql(u8, selected, entry.value_ptr.*.transport)
        else
            false;
        const previous = entry.value_ptr.*;
        entry.key_ptr.* = owned.transport;
        entry.value_ptr.* = owned;
        if (was_selected) self.acceptable_transport = owned.transport;
        model.freePeerLocator(self.allocator, previous);
    }

    /// Retain `locator` as a transport fallback without displacing an already
    /// selected acceptable location. If no route is selected, this first
    /// fallback becomes the selection. Existing snapshots are left intact.
    pub fn ensureAdvertisedLocator(self: *Node, locator: model.PeerLocator) !void {
        if (self.advertised_locators.get(locator.transport)) |stored| {
            if (self.acceptable_transport == null)
                self.acceptable_transport = stored.transport;
            return;
        }

        const owned = try model.view.PeerLocator.fromOwned(&locator).toOwned(self.allocator);
        errdefer model.freePeerLocator(self.allocator, owned);
        try self.advertised_locators.putNoClobber(self.allocator, owned.transport, owned);
        if (self.acceptable_transport == null)
            self.acceptable_transport = owned.transport;
    }

    /// Remove the retained locator for `transport`. Removing the selected
    /// locator leaves no acceptable location; selection is never inferred from
    /// another retained route.
    pub fn removeAdvertisedLocator(self: *Node, transport: []const u8) void {
        const removed = self.advertised_locators.fetchRemove(transport) orelse return;
        if (self.acceptable_transport) |selected| {
            if (std.mem.eql(u8, selected, transport)) self.acceptable_transport = null;
        }
        model.freePeerLocator(self.allocator, removed.value);
    }

    /// Select a locator already retained for `transport` as this node's
    /// `acceptable-location`. Selection is allocation-free and leaves the
    /// registry unchanged on an unknown transport.
    pub fn selectAdvertisedLocator(self: *Node, transport: []const u8) bool {
        const stored = self.advertised_locators.get(transport) orelse return false;
        self.acceptable_transport = stored.transport;
        return true;
    }

    /// Return a locator borrowed from the node. Its slices remain valid until
    /// this transport is replaced or removed, or the node is deinitialized.
    pub fn advertisedLocator(self: *const Node, transport: []const u8) ?model.PeerLocator {
        return self.advertised_locators.get(transport);
    }

    /// Return the node's selected `acceptable-location`, borrowed under the
    /// same lifetime as `advertisedLocator`.
    pub fn acceptableLocator(self: *const Node) ?model.PeerLocator {
        return self.advertised_locators.get(self.acceptable_transport orelse return null);
    }

    /// Install the local-object seam used to retain exact gifts across Ports.
    /// A standalone sans-io Node leaves this unset and keeps protocol
    /// references verbatim.
    pub fn setLocalObjectProjection(self: *Node, projection: engine.bootstrap.LocalObjectProjection) void {
        self.local_object_projection = projection;
    }

    pub fn localObjectProjection(self: *Node) ?engine.bootstrap.LocalObjectProjection {
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

    /// The key `peer_id`'s session signs handoff records with: the session's
    /// own where a resolver knows it, else the node's durable key. The one
    /// place that fallback is expressed, so ADR-0097's fresh-key switch has a
    /// single seam rather than a search for `secretKey()` call sites.
    fn sessionSecret(self: *const Node, peer_id: PeerId) ?crypto.SecretKey {
        const resolver = self.session_secret_resolver orelse return self.secretKey();
        // Once a Host installs session-key authority, a missing session is
        // terminal. Falling back to the Node key would deliberately sign a
        // receive or give with an identity the named session never held.
        return resolver.resolve(resolver.ctx, peer_id);
    }

    pub fn setGifterSessionResolver(self: *Node, resolver: engine.bootstrap.GifterSessionResolver) void {
        self.gifter_session_resolver = resolver;
    }

    pub fn gifterSessionResolver(self: *Node) ?engine.bootstrap.GifterSessionResolver {
        return self.gifter_session_resolver;
    }

    /// Register a fresh negotiating peer and return its `peer_id`. The embedder builds its live
    /// `net.Connection` over `node.peer(peer_id)` and pumps it; the peer's
    /// address is stable for the registration's life. The peer is negotiating, so
    /// the embedder completes the keyed `op:start-session` handshake (it owns the
    /// socket and the entropy) signing with `node.seed` for an identity the
    /// exporter will recognize across CapTP sessions. `options` are the same
    /// knobs `Peer.initNegotiatingWith` takes — applied at construction so the
    /// host never pokes session tables after the fact.
    pub fn registerPeer(self: *Node, options: engine.Peer.NegotiatingOptions) !PeerId {
        const new_peer = try self.allocator.create(engine.Peer);
        new_peer.* = engine.Peer.initNegotiatingWith(self.allocator, options);
        errdefer {
            new_peer.node_services = null;
            new_peer.deinit();
            self.allocator.destroy(new_peer);
        }
        try self.applyExportRange(new_peer);
        errdefer self.recycleExportBase(new_peer.session_state.export_base);

        const id: PeerId = .from(self.next_peer_id);
        new_peer.node_services = self.services(id);
        try self.peers.putNoClobber(self.allocator, id, .{ .peer = new_peer, .ownership = .node_owned });
        self.next_peer_id += 1;
        return id;
    }

    /// Register a connection over a peer the embedder already owns and pins at a
    /// stable address, joining it to the node's routing
    /// without the node taking ownership. `removePeer` and `deinit` unregister
    /// the slot but never free `peer`; the embedder frees it. This is how a
    /// peer-owning driver — the completion loop, whose fixed-slot `peers` hold
    /// each peer inline — puts its connections under one node so a redeemed route
    /// routes to them and a served reply can originate a gift. `peer` must
    /// outlive its registration.
    pub fn registerPeerOver(self: *Node, adopted: *engine.Peer) !PeerId {
        try self.applyExportRange(adopted);
        errdefer self.recycleExportBase(adopted.session_state.export_base);
        const id: PeerId = .from(self.next_peer_id);
        adopted.node_services = self.services(id);
        errdefer adopted.node_services = null;
        try self.peers.putNoClobber(self.allocator, id, .{ .peer = adopted, .ownership = .borrowed });
        self.next_peer_id += 1;
        return id;
    }

    /// Remove a registered CapTP session: drop its row and free the peer only
    /// when the Node owns it. A later route to a redeemed route whose exporter
    /// was this session fails closed (the peer is gone), rather than forwarding
    /// onto a dead socket. The `peer_id` is never reused.
    ///
    /// The exporter cache, pending withdraws, pending gifts, and capability
    /// routes naming this session are swept below. A stale `Reference.routed`
    /// still fails closed after its row is removed because its explicit union
    /// arm can never fall through as an ordinary wire import.
    pub fn removePeer(self: *Node, peer_id: PeerId) void {
        const live = self.peers.get(peer_id) orelse return;
        // A recipient batch carries a reservation charged on this exact Peer.
        // Retire it while the Peer is still alive; exporter-side failures are
        // projected only after liveness disappears, so a retry cannot route
        // back through the closing exporter.
        self.retireInlinePassableRecipientBatchesForPeer(peer_id);
        // Receiver-side dependencies must leave while the services back-pointer
        // is valid. This also makes an adopted peer safe to deinit later.
        live.peer.detachNodeServices();
        const removed = self.peers.fetchRemove(peer_id) orelse return;
        // Mark only receivers that name this exact Gifter–Exporter session,
        // after liveness disappears so their retry observes closure.
        self.markGifterHandoffsChanged(peer_id);
        // Only a node-owned peer is freed here; an adopted (`registerPeerOver`)
        // peer is the embedder's to free, so the node only unregisters it.
        // Give the range back before the peer goes, while it is still the only
        // record of which range this session held. Reclaiming is what makes the
        // slot bound live sessions rather than the node's lifetime.
        self.recycleExportBase(removed.value.peer.session_state.export_base);
        if (removed.value.ownership == .node_owned) {
            removed.value.peer.deinit();
            self.allocator.destroy(removed.value.peer);
        }
        if (self.exporter_locations.fetchRemove(peer_id)) |prev| self.allocator.free(prev.value);

        // Evict the exporter-cache rows naming this CapTP session, so a later
        // give for the same exporter dials a fresh session instead of
        // failing against the dead one forever.
        self.evictExporterCache(peer_id);

        // Break every withdraw still pending on this session. Admission kept
        // one action slot reserved per row, and the diagnostic is static, so
        // teardown cannot strand a live recipient answer behind allocator
        // pressure.
        self.failWithdrawsForPeer(peer_id);

        // A staged Passable projection names its recipient and every object or
        // promise home. Recipient loss makes the whole message moot; home loss
        // makes the already-admitted recipient operation terminal. Retire those
        // batches before foreign routes disappear so no effect can park them.
        self.failInlinePassableBatchesForHome(peer_id);

        // A claimed gifter origination whose recipient died settles nowhere;
        // retire its ticket so a late provideGiftId is a clean no-op.
        self.removeRowsForPeer(&self.pending_gifts, peer_id, struct {
            fn match(_: u64, gift: PendingGift, dying: PeerId) bool {
                return gift.recipient_peer == dying;
            }
        }.match, struct {
            fn cleanup(node: *Node, _: u64, gift: PendingGift) void {
                var owned = gift;
                if (owned.failure_reason != null) node.releaseProxyActionReservation();
                owned.releaseFailure(node.allocator);
            }
        }.cleanup);

        // Once a home is gone, neither a redeemed nor fetched route can ever
        // lower or re-gift. Reclaim both maps so connection churn cannot retain
        // one row per capability ever observed.
        self.removeCapabilityRoutesForPeer(&self.redeemed, peer_id);
        self.removeCapabilityRoutesForPeer(&self.foreign_imports, peer_id);

        // Drop promise proxies whose home or recipient peer died so a later
        // home fire cannot relay onto a gone session.
        self.sweepPromiseProxiesForPeer(peer_id);
    }

    fn removeCapabilityRoutesForPeer(
        self: *Node,
        routes: *std.AutoHashMapUnmanaged(model.CapabilityRouteId, Route),
        peer_id: PeerId,
    ) void {
        self.removeRowsForPeer(routes, peer_id, struct {
            fn match(_: model.CapabilityRouteId, route_row: Route, dying: PeerId) bool {
                return route_row.peer_id == dying;
            }
        }.match, struct {
            fn cleanup(node: *Node, _: model.CapabilityRouteId, route_row: Route) void {
                model.freeReference(node.allocator, route_row.reference);
            }
        }.cleanup);
    }

    fn retireInlinePassableRecipientBatchesForPeer(self: *Node, peer_id: PeerId) void {
        while (true) {
            var found: ?InlinePassableBatchId = null;
            var it = self.pending_inline_passables.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.recipient_peer == peer_id) {
                    found = entry.key_ptr.*;
                    break;
                }
            }
            const batch_id = found orelse break;
            var batch = (self.pending_inline_passables.fetchRemove(batch_id) orelse unreachable).value;
            self.cancelInlineGiftTickets(batch_id);
            self.spendInlinePassableTerminalReservations(&batch);
            self.queueInlineGiftLeaseReleases(batch.gifts);
            self.queueInlinePromiseLeaseReleases(batch.promises);
            batch.deinit(self);
        }
    }

    fn failInlinePassableBatchesForHome(self: *Node, peer_id: PeerId) void {
        while (true) {
            var found: ?InlinePassableBatchId = null;
            var it = self.pending_inline_passables.iterator();
            while (it.next()) |entry| {
                for (entry.value_ptr.gifts) |gift| if (gift.home == peer_id) {
                    found = entry.key_ptr.*;
                    break;
                };
                if (found == null) for (entry.value_ptr.promises) |promise| if (promise.home == peer_id) {
                    found = entry.key_ptr.*;
                    break;
                };
                if (found != null) break;
            }
            self.failInlinePassableBatch(found orelse break, error.RouteNotLowerable);
        }
    }

    fn evictExporterCache(self: *Node, peer_id: PeerId) void {
        self.removeRowsForPeer(&self.exporters, peer_id, struct {
            fn match(_: []const u8, home: PeerId, dying: PeerId) bool {
                return home == dying;
            }
        }.match, struct {
            fn cleanup(node: *Node, key: []const u8, _: PeerId) void {
                node.allocator.free(key);
            }
        }.cleanup);
    }

    /// Remove every row of `map` tied to the dying `peer_id` in one O(n),
    /// allocation-free pass. Removing the iterator's current row tombstones the
    /// slot without moving or reallocating the backing, so teardown cannot
    /// retain a stale cache/route merely because its allocator is exhausted.
    /// `cleanup` receives the removed ownership.
    fn removeRowsForPeer(
        self: *Node,
        map: anytype,
        peer_id: PeerId,
        comptime match: anytype,
        comptime cleanup: anytype,
    ) void {
        var it = map.iterator();
        while (it.next()) |entry| {
            if (!match(entry.key_ptr.*, entry.value_ptr.*, peer_id)) continue;
            const key = entry.key_ptr.*;
            const value = entry.value_ptr.*;
            map.removeByPtr(entry.key_ptr);
            cleanup(self, key, value);
        }
    }

    fn failWithdrawsForPeer(self: *Node, peer_id: PeerId) void {
        var it = self.pending_withdraws.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.peer_id != peer_id) continue;
            const pending = entry.value_ptr.*;
            self.actions.pushReserved(.{ .fail = .{
                .dest = .fromRedeem(pending.dest),
                .reason = .{ .static = exporter_closed_reason },
            } });
            // Removing the iterator's current row only tombstones its slot; it
            // does not reallocate or move the backing. Queue the infallible
            // consequence first, then retire the row and its reserved slot.
            std.debug.assert(self.pending_withdraws.remove(entry.key_ptr.*));
        }
    }

    /// The node-local route id `reference` names (ADR-0066), or null for every
    /// wire reference. The union arm, not arithmetic, is the discriminator.
    pub fn routeIdOf(reference: model.Reference) ?model.CapabilityRouteId {
        return switch (reference) {
            .routed => |routed| routed.id,
            else => null,
        };
    }

    /// The route `reference` names only when it is a live redeemed
    /// handoff route. Foreign-import routes share the Node counter but remain
    /// Node-owned routing identities for their full import lifetime; a Host
    /// lift may consume only this narrower redeemed family.
    pub fn redeemedRouteId(self: *const Node, reference: model.Reference) ?model.CapabilityRouteId {
        const route_id = routeIdOf(reference) orelse return null;
        return if (self.redeemed.contains(route_id)) route_id else null;
    }

    /// The node-owned peer for `peer_id`, or null when the id names no live
    /// connection. The embedder pumps I/O through this peer; the node routes
    /// across them.
    pub fn peer(self: *Node, peer_id: PeerId) ?*engine.Peer {
        return self.peerAt(peer_id);
    }

    fn peerAt(self: *Node, peer_id: PeerId) ?*engine.Peer {
        const slot = self.peers.get(peer_id) orelse return null;
        return slot.peer;
    }

    // ── Redeemed-route routing (the recipient half) ──────────────────────────

    /// Enroll a redeemed capability under a fresh Node route and return the
    /// explicit routed reference the application receives. A later
    /// `routeReference` of that
    /// reference forwards to `exporter_peer` with `reference` (the real
    /// exporter-side ref) swapped in. The node adopts a clone of `reference`; the
    /// caller keeps its own. The caller reserves one slot in `redeemed` first, so
    /// the only fallible step here is the clone, which commits nothing on
    /// failure. Without that, a plain `put` failing after the clone would leave a
    /// half-committed row and a bumped route behind a returned error.
    fn enrollRedeemed(self: *Node, exporter_peer: PeerId, reference: model.Reference) !model.Reference {
        const owned = try model.cloneReference(self.allocator, reference);
        if (self.next_route_id.int() == std.math.maxInt(u64)) return error.CapabilitySpaceExhausted;
        const route_id = self.next_route_id;
        self.redeemed.putAssumeCapacity(route_id, .{ .peer_id = exporter_peer, .reference = owned });
        self.next_route_id = .from(route_id.int() + 1);
        // The per-peer outbound walk is also what turns a redeemed route used
        // as Passable data into an inline give. Once a route has escaped, keep
        // that single cheap gate enabled for the Node lifetime.
        self.route_lowering_active = true;
        return .{ .routed = .{ .id = route_id, .kind = .object } };
    }

    /// The exporter route for `reference`, if it carries a node-local route.
    /// Ordinary wire references have no routed arm and return null.
    fn route(self: *Node, reference: model.Reference) ?Route {
        const id = routeIdOf(reference) orelse return null;
        if (self.redeemed.get(id)) |r| return r;
        // A foreign-import route (ADR-0069) routes to its home connection,
        // addressed with the real wire import — the same swap a redeemed route
        // gets, so a send to a fetched capability reaches its exporter.
        return self.foreignRoute(id);
    }

    /// The still-current foreign-import route for `id`.
    ///
    /// The import row's route id is its generation stamp. A missing or different
    /// id means the row was released (and perhaps reused) before a stale
    /// node map row was reclaimed, so every router reader goes through this
    /// check instead of addressing the position under its new meaning.
    fn foreignRoute(self: *Node, id: model.CapabilityRouteId) ?Route {
        const foreign = self.foreign_imports.get(id) orelse return null;
        const home = self.peerAt(foreign.peer_id) orelse return null;
        const position = switch (foreign.reference) {
            .far => |far| far.import_position,
            else => return null,
        };
        if (home.session_state.foreignRouteIdFor(position) != id) return null;
        return foreign;
    }

    /// The exporter peer a redeemed-handoff (or foreign-import) route names,
    /// or null for any reference that names no such route. This is the
    /// deterministic answer to "which connection does this handoff capability
    /// live on," so a redeem's originating send can name that exporter session
    /// from the reply it holds — never by guessing which dial was in flight.
    pub fn exporterPeerFor(self: *Node, reference: model.Reference) ?PeerId {
        const r = self.route(reference) orelse return null;
        return r.peer_id;
    }

    // ── Foreign-import routing (the gifter half) ─────────────────────────────

    pub const ForeignEnrollmentRollback = struct {
        activated_lowering: bool,
        home: PeerId,
        position: model.ImportPosition,
        route_id: model.CapabilityRouteId,
    };

    pub const ForeignEnrollment = struct {
        reference: model.Reference,
        rollback: ?ForeignEnrollmentRollback,
    };

    /// Prepare a fetched far import under a node-unique route id (ADR-0069).
    /// A fresh route carries rollback authority for a larger operation that
    /// has not yet made the route observable. Reusing a canonical enrollment
    /// produces none.
    pub fn prepareForeignEnrollment(self: *Node, home: PeerId, wire: model.Reference) !ForeignEnrollment {
        const far = switch (wire) {
            .far => |value| value,
            else => return error.NotAFarReference,
        };
        const home_peer = self.peer(home) orelse return error.UnknownPeer;
        const kind = far.kind;
        // Enrolling is idempotent per import: the same capability keeps the
        // route id it was first given. Minting a second one would give one object
        // two identities, which is what a caller comparing two fetches of the
        // same name sees, and would leave a routing row behind on every
        // enrollment, so a loop that re-fetches would grow the table without
        // bound. The route id is kept on the import row, so it is forgotten when
        // the import is released.
        if (home_peer.session_state.foreignRouteIdFor(far.import_position)) |existing| {
            // The kind comes off the enrolled row, not off this caller's
            // reference: the row is what routing reads, so a second caller
            // naming the same import with a different kind must not be handed
            // a reference that disagrees with where it points.
            const enrolled_kind = if (self.foreign_imports.get(existing)) |row|
                switch (row.reference) {
                    .far => |enrolled_far| enrolled_far.kind,
                    else => kind,
                }
            else
                kind;
            return .{
                .reference = .{ .routed = .{ .id = existing, .kind = enrolled_kind } },
                .rollback = null,
            };
        }
        if (!home_peer.session_state.hasImport(far.import_position)) return error.UnknownImport;
        try self.foreign_imports.ensureUnusedCapacity(self.allocator, 1);
        if (self.next_route_id.int() == std.math.maxInt(u64)) return error.CapabilitySpaceExhausted;
        const route_id = self.next_route_id;
        // The session row is the generation check `route` consults. Record it
        // before committing the node route so an allocation failure returns
        // no unusable route and leaves no half-installed map row.
        try home_peer.session_state.noteForeignRouteId(far.import_position, route_id);
        self.foreign_imports.putAssumeCapacity(route_id, .{ .peer_id = home, .reference = wire });
        self.next_route_id = .from(route_id.int() + 1);
        const activated_lowering = !self.route_lowering_active;
        self.route_lowering_active = true;
        return .{
            .reference = .{ .routed = .{ .id = route_id, .kind = kind } },
            .rollback = .{
                .activated_lowering = activated_lowering,
                .home = home,
                .position = far.import_position,
                .route_id = route_id,
            },
        };
    }

    /// Undo one fresh enrollment before its route becomes observable. The
    /// monotonic id remains burned; only the route and import-row memo move
    /// back, so stale ids can never acquire a later meaning.
    pub fn rollbackForeignEnrollment(self: *Node, rollback: ForeignEnrollmentRollback) void {
        const home = self.peer(rollback.home) orelse unreachable;
        std.debug.assert(home.session_state.foreignRouteIdFor(rollback.position) == rollback.route_id);
        home.session_state.abandonForeignRouteId(rollback.position, rollback.route_id);
        const removed = self.foreign_imports.fetchRemove(rollback.route_id) orelse unreachable;
        std.debug.assert(removed.value.peer_id == rollback.home);
        model.freeReference(self.allocator, removed.value.reference);
        if (rollback.activated_lowering) {
            std.debug.assert(self.foreign_imports.count() == 0);
            self.route_lowering_active = false;
        }
    }

    /// Enroll a fetched far import and publish its canonical route immediately.
    pub fn enrollForeign(self: *Node, home: PeerId, wire: model.Reference) !model.Reference {
        return (try self.prepareForeignEnrollment(home, wire)).reference;
    }

    /// The connection a fetched capability route lives on, or null when the
    /// node holds no enrollment for it. This is the home the gifter-side
    /// interceptor originates a handoff toward.
    fn homeOf(self: *Node, route_id: model.CapabilityRouteId) ?PeerId {
        if (self.foreignRoute(route_id)) |r| return r.peer_id;
        return null;
    }

    /// Whether a raw model reference lacks an argument name on `default_peer`.
    /// Raw Host verbs carry no capability retain that delayed inline handoff can
    /// adopt, so they use this verdict to refuse the argument. Owning `Value`
    /// verbs stage cross-session object routes through ADR-0116 instead.
    pub fn argIsForeign(self: *Node, default_peer: PeerId, reference: model.Reference) bool {
        const id = routeIdOf(reference) orelse return false;
        // A foreign-import route is foreign only away from its home. A redeemed
        // route has no wire home and is foreign everywhere; an unknown route
        // fails closed.
        if (self.foreignRoute(id)) |r| return r.peer_id != default_peer;
        return true;
    }

    /// Lower `reference` to the wire reference it names on `peer_id`, for the one
    /// place every outbound message is emitted (`Peer.send`, ADR-0069). This is
    /// the single chokepoint that keeps a node-local route off the wire in *every*
    /// position — target, argument, forwarded target, resolution — instead of one
    /// path at a time. The peer reaches it through the `engine.NodeServices` link this
    /// node installs at registration; the shared error type is
    /// `engine.LoweringError`.
    ///
    /// The fast path is an exhaustive union-tag check: every wire reference is
    /// returned untouched. Only a routed reference pays the map lookup. Any route whose
    /// home is this CapTP session — a redeemed capability whose exporter is this
    /// session, or a foreign import fetched on it — lowers to its wire
    /// reference. A route homed on another session has no wire name here and
    /// fails closed with `RouteNotLowerable`. Cross-session *routing* (a redeemed
    /// route's redirect to its exporter, a re-gift) is not this function's job —
    /// the driver and the resolve interceptor own it, because only they choose a
    /// different session. The lowered reference is a far (position-only, POD),
    /// so it is substituted into the message by value with no ownership transfer.
    pub fn lowerForConn(self: *Node, peer_id: PeerId, reference: model.Reference) engine.LoweringError!model.Reference {
        if (routeIdOf(reference) == null) return reference;
        const r = self.route(reference) orelse return error.RouteNotLowerable;
        if (r.peer_id != peer_id) return error.RouteNotLowerable;
        return r.reference;
    }

    /// The lowering hook for the peer registered as `peer_id`, installed on it at
    /// registration so `Peer.send` swaps routes to wire references (ADR-0069). It
    /// carries a `*const bool` into `route_lowering_active` as its gate, so the
    /// peer skips the walk entirely until this node mints its first route.
    fn services(self: *Node, peer_id: PeerId) engine.NodeServices {
        return engine.NodeServices.bind(self, peer_id, &self.route_lowering_active, .{
            .lower = lowerForConn,
            .stage_outbound = stageOutbound,
            .local_object_projection = localObjectProjection,
            .gifter_session_resolver = gifterSessionResolver,
            .pending_withdraw_added = addHandoffWaiter,
            .pending_withdraw_removed = removeHandoffWaiter,
            .gift_deposited = markHandoffChanged,
            .session_closed = sessionClosed,
            .prepare_v1_emitted_handoff_count = prepareV1HandoffCount,
            .prepare_promise_shortening = prepareProxyPromiseShortening,
            .commit_promise_shortening = commitProxyPromiseShortening,
            .designator_scheme = designatorScheme,
        });
    }

    const InlineProjectionRoute = struct {
        route_id: model.CapabilityRouteId,
        home: PeerId,
        source: model.Reference,
        kind: enum { object, promise },
    };

    const InlineProjectionCounts = struct {
        objects: usize = 0,
        promises: usize = 0,

        fn add(self: InlineProjectionCounts, other: InlineProjectionCounts) !InlineProjectionCounts {
            return .{
                .objects = std.math.add(usize, self.objects, other.objects) catch
                    return error.QueueCapExceeded,
                .promises = std.math.add(usize, self.promises, other.promises) catch
                    return error.QueueCapExceeded,
            };
        }

        fn total(self: InlineProjectionCounts) !usize {
            return std.math.add(usize, self.objects, self.promises) catch
                return error.QueueCapExceeded;
        }
    };

    pub const OutboundStagingLease = struct {
        route_id: model.CapabilityRouteId,
        capability: u64,
        claimed: bool = false,
    };

    pub fn beginOutboundStagingLeases(self: *Node, leases: []OutboundStagingLease) void {
        std.debug.assert(self.outbound_staging_leases == null);
        self.outbound_staging_leases = leases;
    }

    pub fn endOutboundStagingLeases(self: *Node) void {
        std.debug.assert(self.outbound_staging_leases != null);
        self.outbound_staging_leases = null;
    }

    fn claimOutboundStagingLease(self: *Node, route_id: model.CapabilityRouteId) ?u64 {
        const leases = self.outbound_staging_leases orelse return null;
        for (leases) |*lease| {
            if (lease.route_id != route_id or lease.claimed) continue;
            lease.claimed = true;
            return lease.capability;
        }
        return null;
    }

    fn unclaimOutboundStagingLease(self: *Node, route_id: model.CapabilityRouteId, capability_raw: u64) void {
        const leases = self.outbound_staging_leases orelse unreachable;
        for (leases) |*lease| {
            if (lease.route_id != route_id or lease.capability != capability_raw or !lease.claimed) continue;
            lease.claimed = false;
            return;
        }
        unreachable;
    }

    /// Adopt a complete outbound message when a Passable value contains an
    /// object homed on another live session. Ordinary targets are routing, not
    /// Passable data, and remain the responsibility of `lowerForConn`.
    fn stageOutbound(
        self: *Node,
        recipient_peer: PeerId,
        message: *model.Message,
    ) engine.node_services.OutboundStagingError!bool {
        var destination: InlinePassableDestination = .outbound;
        return self.stageInlinePassable(recipient_peer, message, &destination);
    }

    /// One recursive staging transaction for every Passable tree crossing a
    /// session boundary. Ordinary outbound messages and relayed promise
    /// settlements differ only at their terminal owner; capability discovery,
    /// handoff/proxy preparation, pressure accounting, and rollback must stay
    /// one mechanism.
    fn stageInlinePassable(
        self: *Node,
        recipient_peer: PeerId,
        message: *model.Message,
        destination: *InlinePassableDestination,
    ) engine.node_services.OutboundStagingError!bool {
        const recipient = self.peer(recipient_peer) orelse return error.RouteNotLowerable;
        // This shared model walk both measures the retained message and rejects
        // trees beyond the hard recursion ceiling before the staging-specific
        // recursive passes inspect them.
        const message_charge = try model.measureMessageOwnedBytes(message.*);
        const counts = try self.countInlineProjections(recipient_peer, message.*);
        const projection_count = try counts.total();
        if (projection_count == 0) return false;
        if (projection_count > recipient.limits().queue_cap or counts.objects > std.math.maxInt(u32))
            return error.QueueCapExceeded;
        const current_occurrences = self.pending_inline_passable_occurrences.get(recipient_peer) orelse 0;
        const next_occurrences = std.math.add(usize, current_occurrences, projection_count) catch
            return error.QueueCapExceeded;
        if (next_occurrences > recipient.limits().queue_cap) return error.QueueCapExceeded;
        if (self.pending_inline_passables.count() >= recipient.limits().queue_cap)
            return error.QueueCapExceeded;
        if (self.next_inline_batch == std.math.maxInt(u64))
            return error.CapabilitySpaceExhausted;
        if (counts.objects > std.math.maxInt(u64) - self.next_pending)
            return error.CapabilitySpaceExhausted;

        try self.pending_inline_passables.ensureUnusedCapacity(self.allocator, 1);
        try self.pending_gifts.ensureUnusedCapacity(self.allocator, @intCast(counts.objects));
        if (current_occurrences == 0)
            try self.pending_inline_passable_occurrences.ensureUnusedCapacity(self.allocator, 1);
        // Completion may need one Host-retain release per projection, one
        // exporter flush per object, and one home-listener flush plus one
        // future settlement flush per promise. An ordinary outbound message
        // also needs its recipient flush; a relayed destination already owns
        // that exact terminal seat in ProxyRecipient. Failure uses the same
        // final seat as a correlated session failure or recipient break.
        const object_completion = std.math.mul(usize, counts.objects, 2) catch
            return error.OutOfMemory;
        const promise_completion = std.math.mul(usize, counts.promises, 3) catch
            return error.OutOfMemory;
        const completion_without_recipient = std.math.add(
            usize,
            object_completion,
            promise_completion,
        ) catch return error.OutOfMemory;
        const recipient_completion: usize = if (destination.* == .outbound) 1 else 0;
        const terminal_reservations = std.math.add(
            usize,
            completion_without_recipient,
            recipient_completion,
        ) catch
            return error.OutOfMemory;
        const action_reservations = std.math.add(usize, counts.objects, terminal_reservations) catch
            return error.OutOfMemory;
        try self.reserveActions(action_reservations);

        const staging_reservation = try recipient.reserveInlinePassableStaging(message_charge);
        var staging_reservation_owned = true;
        errdefer if (staging_reservation_owned)
            recipient.cancelInlinePassableStaging(staging_reservation);

        const gifts = try recipient.allocator.alloc(InlineGift, counts.objects);
        var gifts_owned = true;
        errdefer if (gifts_owned) recipient.allocator.free(gifts);
        const promises = try recipient.allocator.alloc(InlinePromiseProjection, counts.promises);
        var promises_owned = true;
        errdefer if (promises_owned) recipient.allocator.free(promises);
        var gift_index: usize = 0;
        var promise_index: usize = 0;
        try self.collectInlineProjections(
            recipient_peer,
            message.*,
            gifts,
            promises,
            &gift_index,
            &promise_index,
        );
        std.debug.assert(gift_index == counts.objects);
        std.debug.assert(promise_index == counts.promises);
        var claimed_leases: usize = 0;
        errdefer {
            var remaining = claimed_leases;
            for (gifts) |gift| {
                if (remaining == 0) break;
                self.unclaimOutboundStagingLease(gift.route_id, gift.capability_lease.?);
                remaining -= 1;
            }
            for (promises) |promise| {
                if (remaining == 0) break;
                self.unclaimOutboundStagingLease(promise.route_id, promise.capability_lease.?);
                remaining -= 1;
            }
        }
        if (self.outbound_staging_leases != null) {
            for (gifts) |*gift| {
                gift.capability_lease = self.claimOutboundStagingLease(gift.route_id) orelse
                    return error.RouteNotLowerable;
                claimed_leases += 1;
            }
            for (promises) |*promise| {
                promise.capability_lease = self.claimOutboundStagingLease(promise.route_id) orelse
                    return error.RouteNotLowerable;
                claimed_leases += 1;
            }
        }

        const batch_id: InlinePassableBatchId = @enumFromInt(self.next_inline_batch);
        self.pending_inline_passables.putAssumeCapacity(batch_id, .{
            .recipient_peer = recipient_peer,
            .allocator = recipient.allocator,
            .message = message.*,
            .destination = destination.*,
            .staging_reservation = staging_reservation,
            .gifts = gifts,
            .promises = promises,
            .terminal_action_reservations = terminal_reservations,
        });
        if (current_occurrences == 0)
            self.pending_inline_passable_occurrences.putAssumeCapacity(recipient_peer, next_occurrences)
        else
            self.pending_inline_passable_occurrences.getPtr(recipient_peer).?.* = next_occurrences;
        staging_reservation_owned = false;
        gifts_owned = false;
        promises_owned = false;
        message.* = undefined;
        destination.* = undefined;
        self.next_inline_batch += 1;
        self.inline_passable_action_reservations += terminal_reservations;

        for (gifts, 0..) |gift, index| {
            const ticket = self.next_pending;
            self.next_pending += 1;
            self.pending_gifts.putAssumeCapacity(ticket, .{
                .recipient_peer = recipient_peer,
                .route_id = gift.route_id,
                .dest = .{ .inline_gift = .{
                    .batch = batch_id,
                    .gift_index = @intCast(index),
                } },
                .failure_reason = null,
            });
            self.actions.pushReserved(.{ .need_gift_id = .{ .ticket = ticket } });
        }
        if (gifts.len == 0) {
            self.finishInlinePassableBatch(batch_id) catch |err| {
                const failed = self.pending_inline_passables.getPtr(batch_id) orelse unreachable;
                if (!failed.message_owned) {
                    // The ordinary Peer send consumed the message before its
                    // final refusal. No caller-owned value remains to retry;
                    // settle through the correlated session barrier exactly as
                    // an entropy-delayed transaction would.
                    self.failInlinePassableBatch(batch_id, err);
                    return true;
                }
                var restored = (self.pending_inline_passables.fetchRemove(batch_id) orelse unreachable).value;
                self.spendInlinePassableTerminalReservations(&restored);
                self.unclaimInlineProjectionLeases(&restored);
                message.* = restored.message;
                restored.message_owned = false;
                destination.* = restored.destination;
                restored.destination = .outbound;
                restored.deinit(self);
                return err;
            };
        }
        return true;
    }

    fn inlineProjectionRoute(
        self: *Node,
        recipient_peer: PeerId,
        reference: model.Reference,
    ) engine.node_services.OutboundStagingError!?InlineProjectionRoute {
        const route_id = routeIdOf(reference) orelse return null;
        const gift_route = self.route(reference) orelse return error.RouteNotLowerable;
        if (gift_route.peer_id == recipient_peer) return null;
        const routed = switch (reference) {
            .routed => |value| value,
            else => return error.RouteNotLowerable,
        };
        return .{
            .route_id = route_id,
            .home = gift_route.peer_id,
            .source = gift_route.reference,
            .kind = switch (routed.kind) {
                .object => .object,
                .promise => .promise,
            },
        };
    }

    fn countInlineProjections(
        self: *Node,
        recipient_peer: PeerId,
        message: model.Message,
    ) engine.node_services.OutboundStagingError!InlineProjectionCounts {
        return switch (message) {
            .deliver => |deliver| self.countInlineProjectionArguments(recipient_peer, deliver.args),
            .resolve => |resolve| switch (resolve.resolution) {
                .fulfill => |arg| self.countInlineProjectionArgument(recipient_peer, arg),
                .@"break" => .{},
            },
            else => .{},
        };
    }

    fn countInlineProjectionArguments(
        self: *Node,
        recipient_peer: PeerId,
        args: []const model.Argument,
    ) engine.node_services.OutboundStagingError!InlineProjectionCounts {
        var count: InlineProjectionCounts = .{};
        for (args) |arg| count = try count.add(
            try self.countInlineProjectionArgument(recipient_peer, arg),
        );
        return count;
    }

    fn countInlineProjectionArgument(
        self: *Node,
        recipient_peer: PeerId,
        arg: model.Argument,
    ) engine.node_services.OutboundStagingError!InlineProjectionCounts {
        return switch (arg) {
            .reference => |reference| if (try self.inlineProjectionRoute(recipient_peer, reference)) |projection|
                switch (projection.kind) {
                    .object => .{ .objects = 1 },
                    .promise => .{ .promises = 1 },
                }
            else
                .{},
            .list, .set => |items| self.countInlineProjectionArguments(recipient_peer, items),
            .tagged => |tagged| self.countInlineProjectionArguments(recipient_peer, tagged.value),
            .@"struct" => |entries| blk: {
                var count: InlineProjectionCounts = .{};
                for (entries) |entry| count = try count.add(
                    try self.countInlineProjectionArgument(recipient_peer, entry.value),
                );
                break :blk count;
            },
            else => .{},
        };
    }

    fn collectInlineProjections(
        self: *Node,
        recipient_peer: PeerId,
        message: model.Message,
        gifts: []InlineGift,
        promises: []InlinePromiseProjection,
        gift_index: *usize,
        promise_index: *usize,
    ) engine.node_services.OutboundStagingError!void {
        switch (message) {
            .deliver => |deliver| try self.collectInlineProjectionArguments(
                recipient_peer,
                deliver.args,
                gifts,
                promises,
                gift_index,
                promise_index,
            ),
            .resolve => |resolve| switch (resolve.resolution) {
                .fulfill => |arg| try self.collectInlineProjectionArgument(
                    recipient_peer,
                    arg,
                    gifts,
                    promises,
                    gift_index,
                    promise_index,
                ),
                .@"break" => {},
            },
            else => {},
        }
    }

    fn collectInlineProjectionArguments(
        self: *Node,
        recipient_peer: PeerId,
        args: []const model.Argument,
        gifts: []InlineGift,
        promises: []InlinePromiseProjection,
        gift_index: *usize,
        promise_index: *usize,
    ) engine.node_services.OutboundStagingError!void {
        for (args) |arg| try self.collectInlineProjectionArgument(
            recipient_peer,
            arg,
            gifts,
            promises,
            gift_index,
            promise_index,
        );
    }

    fn collectInlineProjectionArgument(
        self: *Node,
        recipient_peer: PeerId,
        arg: model.Argument,
        gifts: []InlineGift,
        promises: []InlinePromiseProjection,
        gift_index: *usize,
        promise_index: *usize,
    ) engine.node_services.OutboundStagingError!void {
        switch (arg) {
            .reference => |reference| if (try self.inlineProjectionRoute(recipient_peer, reference)) |projection| {
                switch (projection.kind) {
                    .object => {
                        gifts[gift_index.*] = .{
                            .route_id = projection.route_id,
                            .home = projection.home,
                            .original = reference,
                            .gifted = projection.source,
                        };
                        gift_index.* += 1;
                    },
                    .promise => {
                        promises[promise_index.*] = .{
                            .route_id = projection.route_id,
                            .home = projection.home,
                            .original = reference,
                            .source = projection.source.far,
                        };
                        promise_index.* += 1;
                    },
                }
            },
            .list, .set => |items| try self.collectInlineProjectionArguments(
                recipient_peer,
                items,
                gifts,
                promises,
                gift_index,
                promise_index,
            ),
            .tagged => |tagged| try self.collectInlineProjectionArguments(
                recipient_peer,
                tagged.value,
                gifts,
                promises,
                gift_index,
                promise_index,
            ),
            .@"struct" => |entries| for (entries) |entry|
                try self.collectInlineProjectionArgument(
                    recipient_peer,
                    entry.value,
                    gifts,
                    promises,
                    gift_index,
                    promise_index,
                ),
            else => {},
        }
    }

    fn prepareV1HandoffCount(self: *Node) engine.node_services.HandoffCountError!engine.bootstrap.PreparedHandoffCount {
        const handoff_count = self.next_v1_emitted_handoff_count;
        if (handoff_count == std.math.maxInt(u64)) return error.HandoffCountExhausted;
        return engine.bootstrap.PreparedHandoffCount.bind(self, handoff_count, commitV1HandoffCount);
    }

    fn commitV1HandoffCount(self: *Node, prepared: u64) engine.bootstrap.HandoffCountCommitError!void {
        if (self.next_v1_emitted_handoff_count != prepared or prepared == std.math.maxInt(u64))
            return error.StaleHandoffCountPreparation;
        self.next_v1_emitted_handoff_count = prepared + 1;
    }

    fn prepareProxyPromiseShortening(
        self: *Node,
        home: PeerId,
        source: u64,
        target: u64,
        _: u64,
        _: bool,
    ) engine.node_services.PromiseShorteningError!void {
        const source_root = self.proxy_by_source.get(.{ .home = home, .wire_pos = source }) orelse
            return error.UnexpectedMessage;
        const source_proxy = self.promise_proxies.get(source_root) orelse return error.UnexpectedMessage;
        const target_root = self.proxy_by_source.get(.{ .home = home, .wire_pos = target }) orelse return;
        if (std.meta.eql(target_root, source_root)) return;
        const target_proxy = self.promise_proxies.getPtr(target_root) orelse return error.UnexpectedMessage;
        if (target_proxy.recipients.items.len + source_proxy.recipients.items.len > max_proxy_recipients)
            return error.ProxyRecipientCapExceeded;
        try target_proxy.recipients.ensureUnusedCapacity(self.allocator, source_proxy.recipients.items.len);
    }

    fn commitProxyPromiseShortening(
        self: *Node,
        home: PeerId,
        source: u64,
        target: u64,
        target_listener: u64,
        converges: bool,
    ) void {
        const source_key: ProxyHomeKey = .{ .home = home, .wire_pos = source };
        const target_key: ProxyHomeKey = .{ .home = home, .wire_pos = target };
        const source_root = self.proxy_by_source.get(source_key) orelse unreachable;
        if (self.proxy_by_source.get(target_key)) |target_root| {
            if (std.meta.eql(target_root, source_root)) return;
            const removed = self.promise_proxies.fetchRemove(source_root).?;
            var source_proxy = removed.value;
            const target_proxy = self.promise_proxies.getPtr(target_root).?;
            target_proxy.recipients.appendSliceAssumeCapacity(source_proxy.recipients.items);
            // Recipient rows own their terminal escrows. The append above is a
            // move into capacity reserved by `prepareProxyPromiseShortening`;
            // leave only the source list's backing allocation for deinit.
            source_proxy.recipients.items.len = 0;
            std.debug.assert(self.proxy_by_source.remove(source_key));
            std.debug.assert(self.proxy_by_listener.remove(.{
                .home = home,
                .listener_export = source_proxy.listener_export,
            }));
            source_proxy.deinit(self.allocator);
            return;
        }

        std.debug.assert(self.proxy_by_source.remove(source_key));
        self.proxy_by_source.putAssumeCapacity(target_key, source_root);
        const proxy = self.promise_proxies.getPtr(source_root).?;
        proxy.current_wire_pos = target;
        if (converges and proxy.listener_export != target_listener) {
            std.debug.assert(self.proxy_by_listener.remove(.{
                .home = home,
                .listener_export = proxy.listener_export,
            }));
            self.proxy_by_listener.putAssumeCapacity(.{
                .home = home,
                .listener_export = target_listener,
            }, source_root);
            proxy.listener_export = target_listener;
        }
    }

    fn addHandoffWaiter(self: *Node, receiver: PeerId, dependency: HandoffDependency) std.mem.Allocator.Error!void {
        if (self.handoffGroup(dependency)) |group| {
            if (group.receivers.contains(receiver)) return;
            try group.receivers.ensureUnusedCapacity(self.allocator, 1);
            group.receivers.putAssumeCapacity(receiver, {});
            return;
        }

        var group: HandoffWaiterGroup = .{};
        errdefer group.receivers.deinit(self.allocator);
        try group.receivers.ensureUnusedCapacity(self.allocator, 1);
        // One reserved change slot per exact gift group makes every later
        // authority notification infallible.
        try self.handoff_changes.ensureTotalCapacity(self.allocator, self.handoff_group_count + 1);
        group.receivers.putAssumeCapacity(receiver, {});

        if (self.handoff_waiters.getPtr(dependency.gifter)) |gifter| {
            try gifter.gifts.ensureUnusedCapacity(self.allocator, 1);
            gifter.gifts.putAssumeCapacity(dependency.gift_tag, group);
            self.handoff_group_count += 1;
            return;
        }

        var gifter: GifterHandoffGroups = .{};
        errdefer gifter.gifts.deinit(self.allocator);
        try gifter.gifts.ensureUnusedCapacity(self.allocator, 1);
        try self.handoff_waiters.ensureUnusedCapacity(self.allocator, 1);
        gifter.gifts.putAssumeCapacity(dependency.gift_tag, group);
        self.handoff_waiters.putAssumeCapacity(dependency.gifter, gifter);
        self.handoff_group_count += 1;
    }

    fn removeHandoffWaiter(self: *Node, receiver: PeerId, dependency: HandoffDependency) void {
        const gifter = self.handoff_waiters.getPtr(dependency.gifter) orelse return;
        const group = gifter.gifts.getPtr(dependency.gift_tag) orelse return;
        std.debug.assert(group.receivers.remove(receiver));
        if (group.receivers.count() != 0) return;
        if (group.changed_index != no_handoff_change) self.removeHandoffChange(group.changed_index);
        group.receivers.deinit(self.allocator);
        std.debug.assert(gifter.gifts.remove(dependency.gift_tag));
        self.handoff_group_count -= 1;
        if (gifter.gifts.count() == 0) {
            gifter.gifts.deinit(self.allocator);
            std.debug.assert(self.handoff_waiters.remove(dependency.gifter));
        }
        // Return a burst all the way to zero instead of retaining the Node's
        // historical scheduler high-water until teardown. A live gifter's gift
        // map retains its own peak capacity; the memory rule names that bounded
        // active-group tradeoff.
        if (self.handoff_waiters.count() == 0) {
            self.handoff_waiters.deinit(self.allocator);
            self.handoff_waiters = .empty;
            std.debug.assert(self.handoff_group_count == 0);
            self.handoff_changes.deinit(self.allocator);
            self.handoff_changes = .empty;
        }
    }

    fn markHandoffChanged(self: *Node, dependency: HandoffDependency) void {
        const group = self.handoffGroup(dependency) orelse return;
        if (group.changed_index != no_handoff_change) return;
        std.debug.assert(self.handoff_changes.items.len < self.handoff_changes.capacity);
        group.changed_index = self.handoff_changes.items.len;
        self.handoff_changes.appendAssumeCapacity(dependency);
    }

    /// A gifter close invalidates every gift dependency rooted in that exact
    /// session. Each group reserved one change slot when admitted, so marking
    /// all of them remains allocation-free at the authority transition.
    fn markGifterHandoffsChanged(self: *Node, gifter: PeerId) void {
        const groups = self.handoff_waiters.getPtr(gifter) orelse return;
        var it = groups.gifts.iterator();
        while (it.next()) |entry| {
            self.markHandoffChanged(.{ .gifter = gifter, .gift_tag = entry.key_ptr.* });
        }
    }

    /// Logical close, not later shell destruction, is the handoff authority
    /// boundary. Retire recipient batches while their outbound reservations
    /// still name a live Peer, and fail batches that depended on this home.
    fn sessionClosed(self: *Node, peer_id: PeerId) void {
        self.markGifterHandoffsChanged(peer_id);
        self.retireInlinePassableRecipientBatchesForPeer(peer_id);
        self.failInlinePassableBatchesForHome(peer_id);
    }

    fn removeHandoffChange(self: *Node, index: usize) void {
        const last = self.handoff_changes.items.len - 1;
        const moved = self.handoff_changes.items[last];
        const removed = self.handoff_changes.swapRemove(index);
        std.debug.assert(self.handoffGroup(removed).?.changed_index == index);
        if (index != last) self.handoffGroup(moved).?.changed_index = index;
    }

    fn handoffGroup(self: *Node, dependency: HandoffDependency) ?*HandoffWaiterGroup {
        const gifter = self.handoff_waiters.getPtr(dependency.gifter) orelse return null;
        return gifter.gifts.getPtr(dependency.gift_tag);
    }

    /// Peek one exact changed dependency without consuming it. Each Host shell
    /// reserves its dirty-queue seat at mint, and each gift group reserves this
    /// marker at admission, so notifying every receiver and consuming the marker
    /// are both infallible.
    pub fn nextHandoffChange(self: *const Node) ?HandoffDependency {
        return if (self.handoff_changes.items.len == 0) null else self.handoff_changes.items[self.handoff_changes.items.len - 1];
    }

    pub fn handoffWaiterCount(self: *const Node, gifter: PeerId) usize {
        const groups = self.handoff_waiters.get(gifter) orelse return 0;
        var total: usize = 0;
        var it = groups.gifts.valueIterator();
        while (it.next()) |group| total += group.receivers.count();
        return total;
    }

    pub fn handoffWaiters(self: *Node, dependency: HandoffDependency) HandoffWaiterIterator {
        const group = self.handoffGroup(dependency) orelse return .{
            .inner = HandoffReceivers.empty.keyIterator(),
        };
        return .{ .inner = group.receivers.keyIterator() };
    }

    pub fn consumeHandoffChange(self: *Node, dependency: HandoffDependency) void {
        const group = self.handoffGroup(dependency) orelse return;
        if (group.changed_index == no_handoff_change) return;
        self.removeHandoffChange(group.changed_index);
        group.changed_index = no_handoff_change;
    }

    // ── Routed send ──────────────────────────────────────────────────────────

    /// Where a routed deliver lands: which connection carries it, and the real
    /// reference to address (a redeemed route is rewritten to its exporter-side
    /// reference). The embedder turns this into an `op:deliver` on `peer_id`'s
    /// peer.
    pub const Routed = struct {
        peer_id: PeerId,
        target: model.Reference,
    };

    /// Resolve `target` to the connection and real reference a deliver to it
    /// rides. A redeemed route routes to its exporter connection with the real
    /// exporter-side reference; any other reference rides `default_peer` (the
    /// connection the application is addressing) unchanged. Returns null when a
    /// redeemed route names an exporter connection that is gone.
    pub fn routeReference(self: *Node, default_peer: PeerId, target: model.Reference) ?Routed {
        if (routeIdOf(target)) |id| return self.routeCapability(id);
        return .{ .peer_id = default_peer, .target = target };
    }

    /// Resolve a capability route, redeemed or foreign-import, to its home
    /// connection and the real wire reference to
    /// address there, with no default connection to fall back to: a caller
    /// that holds only a route routes here without inventing one. Null when
    /// the route routes nowhere — never minted, or
    /// its enrollment was reclaimed when its home closed (ADR-0069) — so a
    /// retired route fails closed rather than pass the local id onto the
    /// wire.
    pub fn routeCapability(self: *Node, route_id: model.CapabilityRouteId) ?Routed {
        const r = self.route(.{ .routed = .{ .id = route_id } }) orelse return null;
        if (self.peerAt(r.peer_id) == null) return null;
        return .{ .peer_id = r.peer_id, .target = r.reference };
    }

    /// Retire `route_id` once its real wire import has reached zero.
    ///
    /// The session import row is the lifetime authority: while it exists, a
    /// partial release must leave routing intact. Once it is gone, the partner
    /// may reuse that position, so retaining this route would let the old route
    /// address the new object. Unknown routes and routes whose home connection
    /// has already gone are no-ops; their existing teardown policy owns those
    /// rows.
    pub fn retireReleasedRoute(self: *Node, route_id: model.CapabilityRouteId) void {
        const kind: enum { redeemed, foreign } = if (self.redeemed.contains(route_id))
            .redeemed
        else if (self.foreign_imports.contains(route_id))
            .foreign
        else
            return;
        const route_row = switch (kind) {
            .redeemed => self.redeemed.get(route_id).?,
            .foreign => self.foreign_imports.get(route_id).?,
        };
        const home = self.peerAt(route_row.peer_id) orelse return;
        const position = switch (route_row.reference) {
            .far => |far| far.import_position,
            else => return,
        };
        switch (kind) {
            .redeemed => {
                if (home.session_state.hasImport(position)) return;
                const removed = self.redeemed.fetchRemove(route_id).?;
                model.freeReference(self.allocator, removed.value.reference);
            },
            .foreign => {
                // A reused row may already exist here. Its route id, not mere row
                // presence, decides whether this route still belongs to it.
                if (home.session_state.foreignRouteIdFor(position) == route_id) return;
                const removed = self.foreign_imports.fetchRemove(route_id).?;
                model.freeReference(self.allocator, removed.value.reference);
            },
        }
    }

    /// Consume a redeemed-handoff route when the Host lifts it into its own
    /// identity space. This is an ownership transfer: the Host retains the real
    /// import incarnation, and the Node route must stop being a
    /// second stale-capable handle. Foreign-import routes are the Node routing
    /// identity for ordinary fetched capabilities and remain on their rows.
    pub fn consumeRedeemedRoute(self: *Node, route_id: model.CapabilityRouteId) bool {
        const removed = self.redeemed.fetchRemove(route_id) orelse return false;
        model.freeReference(self.allocator, removed.value.reference);
        return true;
    }

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

    // ── The serve step: the sans-io redeem state machine ─────────────────────
    //
    // The router above answers "where does this reference route"; the serve
    // step owns "what happens next" for a three-party redeem, the sequencing
    // every embedder used to hand-roll: intercept a give, consult the exporter
    // cache, dial on a miss, withdraw once the keyed session is open, enroll
    // the withdrawn capability, and settle the application's original answer
    // with the routable route. The node holds the state (exporter cache,
    // pending dials, pending withdraws) and emits `Action`s; the embedder
    // performs the I/O each action names and feeds the outcome back. No
    // socket, no scheduler, no entropy lives here.

    /// A pending-dial ticket: the embedder's handle for reporting one dial's
    /// outcome (`exporterDialed` / `dialFailed`).
    pub const PendingId = u64;

    /// Where one redeemed give settles. An answer is the traditional returned
    /// handoff. A deferred id is Host-owned promise authority for a give found
    /// inline in a Passable value; the sans-I/O node only carries the opaque id
    /// back in its terminal action.
    pub const RedeemDestination = union(enum) {
        answer: struct { recipient_peer: PeerId, answer: model.AnswerPosition },
        deferred: struct { recipient_peer: PeerId, id: u64 },

        fn recipientPeer(self: RedeemDestination) PeerId {
            return switch (self) {
                .answer => |answer| answer.recipient_peer,
                .deferred => |deferred| deferred.recipient_peer,
            };
        }
    };

    /// A failed effect may also settle an inbound answer this Node claimed
    /// while originating a give. Success for that path is published directly
    /// by the two-peer transaction, so it deliberately is not a
    /// `RedeemDestination` and cannot appear in a `.settle` action.
    pub const FailureDestination = union(enum) {
        answer: struct { recipient_peer: PeerId, answer: model.AnswerPosition },
        served_answer: struct { recipient_peer: PeerId, answer: model.AnswerName },
        deferred: struct { recipient_peer: PeerId, id: u64 },

        fn fromRedeem(dest: RedeemDestination) FailureDestination {
            return switch (dest) {
                .answer => |answer| .{ .answer = .{
                    .recipient_peer = answer.recipient_peer,
                    .answer = answer.answer,
                } },
                .deferred => |deferred| .{ .deferred = .{
                    .recipient_peer = deferred.recipient_peer,
                    .id = deferred.id,
                } },
            };
        }
    };

    /// One redeem waiting on an exporter dial: its terminal destination and
    /// the verbatim signed give to withdraw. The node owns `give`.
    const Waiter = struct {
        dest: RedeemDestination,
        give: []u8,
    };

    /// One parsed dial path in a pending exporter dial. Every field is owned by
    /// the pending row; the URI is never reparsed when an embedder executes a
    /// retry. `hints` stays intact because a transport may need more than the
    /// generic direct-addresses projection.
    const DialPath = struct {
        transport: []const u8,
        designator: []const u8,
        hints: model.Hints,
    };

    /// One in-flight exporter dial, possibly carrying several redeems for the
    /// same exporter (a second give for one identity joins the waiters instead
    /// of dialing twice). `paths` is ordered primary-first. The node owns every
    /// heap string and parsed hint entry. Unparseable or over-budget gives
    /// never reach a pending row (`acceptGive` fails them closed). Dial
    /// authority is parsed path data — no verbatim URI copy.
    const PendingDial = struct {
        /// Canonical peer-identity URI (hints stripped); indexes
        /// `pending_dial_by_identity` / feeds `exporters` on dial success.
        identity: []u8,
        /// Parsed once at `acceptGive`, primary first, then alternatives.
        paths: []DialPath,
        /// Index of the path currently being attempted.
        path_index: usize = 0,
        /// A non-redeem operation joined or originated this dial, so the
        /// resulting session has an application owner even if every handoff
        /// withdrawal fails.
        application_owned: bool = false,
        /// The Host handed this ticket to an external dial executor and has
        /// not yet received success, failure, or cancellation completion.
        effect_in_flight: bool = false,
        /// Terminal Host close ordered the external executor to stop. Keep
        /// the row alive until ordinary teardown so its borrowed locator does
        /// not disappear beneath that executor.
        cancel_requested: bool = false,
        waiters: std.ArrayListUnmanaged(Waiter) = .empty,
    };

    fn freeDialPath(self: *Node, path: DialPath) void {
        self.allocator.free(path.transport);
        self.allocator.free(path.designator);
        model.freeHints(self.allocator, path.hints);
    }

    fn freeDialPaths(self: *Node, paths: []DialPath) void {
        for (paths) |path| self.freeDialPath(path);
        self.allocator.free(paths);
    }

    /// Dial paths (not identity). `exporterDialed` uses these before the
    /// exporters cache adopts identity; `dialFailed`/`deinit` free identity too.
    fn freePendingDialShell(self: *Node, pending: *const PendingDial) void {
        self.freeDialPaths(pending.paths);
    }

    fn freePendingDialBytes(self: *Node, pending: *const PendingDial) void {
        self.freePendingDialShell(pending);
        self.allocator.free(pending.identity);
    }

    /// Borrowed complete locator for one pending ticket. Valid until
    /// `exporterDialed` / `dialFailed` / teardown.
    pub const PendingDialView = model.PeerLocator;

    /// Parse identity + dial parts. Join / exporter-cache hits free this and
    /// never open a pending row.
    const StagedDial = struct {
        identity: []u8,
        paths: []DialPath,
    };

    fn freeStagedDial(self: *Node, staged: *const StagedDial) void {
        self.allocator.free(staged.identity);
        self.freeDialPaths(staged.paths);
    }

    /// One withdraw awaiting its resolution on an exporter connection, keyed
    /// by `(exporter conn, withdraw answer)`.
    const PendingWithdraw = struct {
        dest: RedeemDestination,
    };

    /// One claimed gifter origination awaiting its host-drawn gift id, keyed
    /// by the ticket the `need_gift_id` action carried.
    /// One recipient's stored slot for a relayed promise: the import position
    /// the recipient knows it by, stamped with the row identity that proves
    /// the row was not torn down and re-registered underneath (ADR-0069).
    const RelayedSlot = struct { import_pos: u64, row_id: u64 };

    /// Host-local identity of one complete staged outbound message. The Node
    /// is the owner dimension and monotonic issuance is its epoch.
    const InlinePassableBatchId = enum(u64) { _ };

    const InlinePassableDestination = union(enum) {
        outbound,
        relayed: ProxyRecipient,
    };

    const InlineGift = struct {
        route_id: model.CapabilityRouteId,
        home: PeerId,
        original: model.Reference,
        gifted: model.Reference,
        capability_lease: ?u64 = null,
        gift_id: [model.HANDOFF_GIFT_ID_BYTES]u8 = undefined,
        handoff: ?*model.Handoff = null,
        inserted_handoff: ?*model.Handoff = null,
    };

    const InlinePromiseProjection = struct {
        route_id: model.CapabilityRouteId,
        home: PeerId,
        original: model.Reference,
        source: model.FarRef,
        capability_lease: ?u64 = null,
        projected: ?model.Reference = null,
        /// Exact owned-tree leaf rewritten at commit preparation. Pointer
        /// identity, rather than reference equality, makes rollback immune to
        /// another argument legitimately carrying the same numeric position.
        inserted_at: ?*model.Argument = null,
    };

    const InlinePassableBatch = struct {
        recipient_peer: PeerId,
        allocator: std.mem.Allocator,
        message: model.Message,
        message_owned: bool = true,
        destination: InlinePassableDestination,
        staging_reservation: ?engine.Peer.InlinePassableStagingReservation,
        gifts: []InlineGift,
        promises: []InlinePromiseProjection,
        ready: usize = 0,
        terminal_action_reservations: usize,

        fn deinit(self: *InlinePassableBatch, node: *Node) void {
            const projection_count = self.gifts.len + self.promises.len;
            if (self.staging_reservation) |reservation| {
                const recipient = node.peer(self.recipient_peer) orelse unreachable;
                recipient.cancelInlinePassableStaging(reservation);
            }
            if (self.message_owned) model.freeMessage(self.allocator, self.message);
            switch (self.destination) {
                .outbound => {},
                .relayed => |*recipient| if (recipient.failure_reason != null) {
                    recipient.releaseFailure(self.allocator);
                    node.releaseProxyActionReservation();
                },
            }
            for (self.gifts) |gift| if (gift.handoff) |handoff| {
                model.freeHandoff(self.allocator, handoff.*);
                self.allocator.destroy(handoff);
            };
            self.allocator.free(self.gifts);
            self.allocator.free(self.promises);
            const occurrences = node.pending_inline_passable_occurrences.getPtr(self.recipient_peer) orelse unreachable;
            std.debug.assert(occurrences.* >= projection_count);
            occurrences.* -= projection_count;
            if (occurrences.* == 0)
                std.debug.assert(node.pending_inline_passable_occurrences.remove(self.recipient_peer));
            std.debug.assert(node.inline_passable_action_reservations >= self.terminal_action_reservations);
            node.inline_passable_action_reservations -= self.terminal_action_reservations;
            self.* = undefined;
        }
    };

    const PendingGift = struct {
        recipient_peer: PeerId,
        route_id: model.CapabilityRouteId,
        /// Where the minted give lands. Both destinations owe the recipient a
        /// handoff for the same reason — a message carrying a reference
        /// imported from another session must become one — and differ only in
        /// the slot the give resolves.
        dest: Dest,
        /// Only relayed destinations carry this. It moved from the proxy
        /// recipient's admission escrow and makes every terminal path after
        /// `need_gift_id` allocation-free.
        failure_reason: ?[]u8,

        fn releaseFailure(self: *PendingGift, allocator: std.mem.Allocator) void {
            if (self.failure_reason) |reason| allocator.free(reason);
            self.failure_reason = null;
        }

        fn takeFailure(self: *PendingGift) []u8 {
            const reason = self.failure_reason orelse unreachable;
            self.failure_reason = null;
            return reason;
        }

        /// `answer` is the reply-interception path: a served reply fulfilled
        /// with a foreign capability, so the give resolves the claimed answer.
        /// `relayed` is the introducing-session proxy path: a promise
        /// introduced to this recipient settled to a capability, so the give
        /// becomes the resolution stored in that import's slot.
        const Dest = union(enum) {
            answer: model.AnswerName,
            relayed: RelayedSlot,
            inline_gift: struct {
                batch: InlinePassableBatchId,
                gift_index: u32,
            },
        };
    };

    const WithdrawKey = struct {
        peer_id: PeerId,
        answer: u64,
    };

    pub const FailureReason = union(enum) {
        owned: []u8,
        static: []const u8,

        pub fn bytes(self: FailureReason) []const u8 {
            return switch (self) {
                .owned => |reason| reason,
                .static => |reason| reason,
            };
        }
    };

    /// Result of reporting one external dial attempt. Host uses this to keep
    /// a parked application operation pending across transport-path retries;
    /// only `.exhausted` is a terminal dial failure.
    pub const DialFailure = enum { retry, exhausted, stale };

    /// What the embedder must do next. Byte views are node-owned and valid
    /// until the next `nextAction` call (or node teardown); copy what outlives
    /// that. `dial` carries only the pending ticket — URI and dial pieces live
    /// on the pending row (`pendingDial`) so acceptGive owns them once.
    pub const Action = union(enum) {
        /// Dial the exporter named by `pending`'s dial view with the node's
        /// retained identity, register the CapTP session, open the keyed
        /// session, then feed `exporterDialed(pending, peer_id)` — or
        /// `dialFailed(pending, reason)` if any step refuses. Borrow via
        /// `pendingDial` until those reports consume the row.
        dial: struct { pending: PendingId },
        /// Pump this CapTP session's outbound queue to the wire.
        flush: PeerId,
        /// Settle the returned answer or Host-owned deferred promise with the
        /// redeemed capability's ordinary routable identity.
        settle: struct { dest: RedeemDestination, route_id: model.CapabilityRouteId },
        /// Break the returned answer or Host-owned deferred promise.
        fail: struct {
            dest: FailureDestination,
            /// Most failures own a copy of a call-scoped reason. Teardown uses
            /// one static diagnostic so its reserved consequence cannot fail
            /// allocation; the union makes those lifetimes non-interchangeable.
            reason: FailureReason,
        },
        /// Stop selecting and close an exporter session opened solely for
        /// handoff redemption after all of its withdrawals failed.
        retire_exporter: PeerId,
        /// Draw 32 bytes of gift-id entropy and feed them back through
        /// `provideGiftId(ticket, bytes)`. Entropy is a host effect like
        /// dialing: the sans-io node never generates it, and requesting it
        /// only when a reply actually becomes a gift keeps the ordinary reply
        /// path free of speculative draws.
        need_gift_id: struct { ticket: u64 },
        /// Release one Host capability retain transferred into a delayed
        /// inline-Passable transaction. This is terminal cleanup: Host consumes
        /// the retain even when its home session can no longer carry wire GC.
        release_capability: u64,
        /// A delayed inline-Passable transaction can fail after its application
        /// send already returned. Ask the Host to run the recipient session's
        /// complete terminal barrier; closing only the Peer would strand vows
        /// and admitted turns above it.
        fail_session: struct {
            peer_id: PeerId,
            reason: []const u8,
        },
    };

    /// Borrow the in-flight pending dial for `pending`, or null if the ticket
    /// already settled. `transport`/`designator` are always non-empty on a
    /// live row: `acceptGive` fails an unparseable give closed before a pending
    /// row exists. Every typed hint on the active path remains present; the
    /// transport that owns the locator decides which ones it consumes. Valid until `exporterDialed` /
    /// `dialFailed` / teardown. When a failed path advances, the same view
    /// begins borrowing the next already-parsed path under the same ticket.
    pub fn pendingDial(self: *const Node, pending: PendingId) ?PendingDialView {
        const entry = self.pending_dials.get(pending) orelse return null;
        if (entry.cancel_requested) return null;
        const path = entry.paths[entry.path_index];
        return .{
            .transport = path.transport,
            .designator = path.designator,
            .hints = path.hints,
        };
    }

    /// Commit delivery of one dial effect to an external executor. False
    /// means the ticket became stale or terminal before delivery committed.
    pub fn beginDialEffect(self: *Node, pending: PendingId) bool {
        const entry = self.pending_dials.getPtr(pending) orelse return false;
        if (entry.cancel_requested) return false;
        std.debug.assert(!entry.effect_in_flight);
        entry.effect_in_flight = true;
        return true;
    }

    /// Roll back an adapter callback that refused before publishing the
    /// external effect represented by its borrowed dial action.
    pub fn rollbackDialEffect(self: *Node, pending: PendingId) void {
        const entry = self.pending_dials.getPtr(pending) orelse return;
        std.debug.assert(entry.effect_in_flight);
        entry.effect_in_flight = false;
    }

    /// Seal every pending dial against future external delivery and yield each
    /// already in-flight effect exactly once for physical cancellation.
    /// Mutating values does not invalidate the map iterator.
    pub const DialCancellationIterator = struct {
        node: *Node,
        pending_dials: std.AutoHashMapUnmanaged(PendingId, PendingDial).Iterator,

        pub fn next(self: *DialCancellationIterator) ?PendingId {
            while (self.pending_dials.next()) |entry| {
                if (entry.value_ptr.cancel_requested) continue;
                entry.value_ptr.cancel_requested = true;
                self.node.settleCancelledDialWaiters(entry.value_ptr);
                if (entry.value_ptr.effect_in_flight) return entry.key_ptr.*;
                const pending = entry.value_ptr.*;
                std.debug.assert(self.node.pending_dial_by_identity.remove(pending.identity));
                self.node.pending_dials.removeByPtr(entry.key_ptr);
                self.node.freeCancelledDial(pending);
            }
            return null;
        }
    };

    pub fn requestDialCancellations(self: *Node) DialCancellationIterator {
        return .{ .node = self, .pending_dials = self.pending_dials.iterator() };
    }

    pub fn pendingDialCount(self: *const Node) usize {
        return self.pending_dials.count();
    }

    pub fn pendingGiftEffects(self: *const Node) usize {
        return self.pending_gifts.count();
    }

    pub fn hasPendingGift(self: *const Node, ticket: u64) bool {
        return self.pending_gifts.contains(ticket);
    }

    /// Cancel a Host-owned inline-give promise whose introducing session has
    /// died. A queued, not-yet-delivered dial becomes a stale action; a shared
    /// or already-running dial remains for its other owner, but this promise
    /// can no longer reach `beginWithdraw`.
    pub fn cancelInlineGive(self: *Node, recipient_peer: PeerId, deferred: u64) void {
        var dials = self.pending_dials.iterator();
        while (dials.next()) |entry| {
            var index: usize = 0;
            while (index < entry.value_ptr.waiters.items.len) {
                const waiter = entry.value_ptr.waiters.items[index];
                const matches = switch (waiter.dest) {
                    .answer => false,
                    .deferred => |dest| dest.recipient_peer == recipient_peer and dest.id == deferred,
                };
                if (!matches) {
                    index += 1;
                    continue;
                }
                const removed = entry.value_ptr.waiters.orderedRemove(index);
                self.releasePendingDialWaiterReservations(1);
                self.allocator.free(removed.give);
            }
            if (entry.value_ptr.waiters.items.len != 0 or
                entry.value_ptr.application_owned or
                entry.value_ptr.effect_in_flight)
                continue;
            const pending = entry.value_ptr.*;
            std.debug.assert(self.pending_dial_by_identity.remove(pending.identity));
            self.pending_dials.removeByPtr(entry.key_ptr);
            self.freeCancelledDial(pending);
        }
    }

    /// Terminal owner cancellation spends every entropy request before an
    /// embedder can turn it into new handoff work. Queued ticket actions become
    /// stale no-ops; failure storage and scheduler reservations retire here.
    pub fn cancelPendingGifts(self: *Node) void {
        var batches = self.pending_inline_passables.valueIterator();
        while (batches.next()) |batch| batch.deinit(self);
        self.pending_inline_passables.clearRetainingCapacity();
        var gifts = self.pending_gifts.valueIterator();
        while (gifts.next()) |gift| {
            if (gift.failure_reason != null) self.releaseProxyActionReservation();
            gift.releaseFailure(self.allocator);
        }
        self.pending_gifts.clearRetainingCapacity();
    }

    /// A cancellation effect has physically retired. Idempotent when an
    /// ordinary outcome won the race before the cancellation command ran.
    pub fn dialCancelled(self: *Node, pending: PendingId) void {
        const current = self.pending_dials.get(pending) orelse return;
        if (!current.cancel_requested) return;
        const entry = (self.pending_dials.fetchRemove(pending) orelse unreachable).value;
        std.debug.assert(self.pending_dial_by_identity.remove(entry.identity));
        self.freeCancelledDial(entry);
    }

    fn freeCancelledDial(self: *Node, pending: PendingDial) void {
        var entry = pending;
        std.debug.assert(entry.waiters.items.len == 0);
        entry.waiters.deinit(self.allocator);
        self.freePendingDialBytes(&entry);
    }

    fn settleCancelledDialWaiters(self: *Node, pending: *PendingDial) void {
        self.releasePendingDialWaiterReservations(pending.waiters.items.len);
        for (pending.waiters.items) |waiter| {
            self.actions.pushReserved(.{ .fail = .{
                .dest = .fromRedeem(waiter.dest),
                .reason = .{ .static = "handoff redeem failed: host closing" },
            } });
            self.allocator.free(waiter.give);
        }
        pending.waiters.deinit(self.allocator);
        pending.waiters = .empty;
    }

    fn hintValue(hints: model.Hints, name: []const u8) ?[]const u8 {
        for (hints.entries) |entry| {
            if (!std.mem.eql(u8, entry.name, name)) continue;
            return switch (entry.value) {
                .string, .bytes => |value| value,
                else => null,
            };
        }
        return null;
    }

    /// Parse one URI into an owned path. Only the primary locator's
    /// `alt-locators` hint ranks paths; an alternative's own hint is retained
    /// for its transport but is not recursively expanded.
    fn parseDialPath(self: *Node, uri: []const u8) error{ OutOfMemory, UnparseableExporterLocator }!DialPath {
        const parsed = model.uri.parsePeer(self.allocator, uri) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.UnparseableExporterLocator,
        };
        return .{ .transport = parsed.transport, .designator = parsed.designator, .hints = parsed.hints };
    }

    /// Parse once into identity + ordered dial paths. The primary locator's
    /// `alt-locators` hint is split and every complete URI is parsed before the
    /// pending row is retained. Unparseable or over-budget alternatives refuse
    /// the whole redeem, so a partial hint can never become a partial policy.
    fn stagePendingDial(self: *Node, exporter_locator: []const u8) error{ OutOfMemory, UnparseableExporterLocator }!StagedDial {
        const primary = model.uri.parsePeer(self.allocator, exporter_locator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.UnparseableExporterLocator,
        };
        var primary_owned = false;
        errdefer if (!primary_owned) model.freePeerLocator(self.allocator, primary);

        var paths: std.ArrayListUnmanaged(DialPath) = .empty;
        errdefer {
            for (paths.items) |path| self.freeDialPath(path);
            paths.deinit(self.allocator);
        }
        try paths.append(self.allocator, .{
            .transport = primary.transport,
            .designator = primary.designator,
            .hints = primary.hints,
        });
        primary_owned = true;

        if (hintValue(primary.hints, model.transport.hint_alt_locators)) |alternatives| {
            if (alternatives.len == 0 or alternatives.len > max_alt_locator_bytes)
                return error.UnparseableExporterLocator;

            var count: usize = 0;
            var list = std.mem.splitScalar(u8, alternatives, ',');
            while (list.next()) |raw_uri| {
                const alt_uri = std.mem.trim(u8, raw_uri, " \t");
                if (alt_uri.len == 0) return error.UnparseableExporterLocator;
                count += 1;
                if (count > max_alt_locator_count) return error.UnparseableExporterLocator;

                const path = try self.parseDialPath(alt_uri);
                var path_owned = true;
                errdefer if (path_owned) self.freeDialPath(path);
                try paths.append(self.allocator, path);
                path_owned = false;
            }
        }

        // writePeer on a just-parsed peer should only fail OOM; fold any other
        // encode refuse into the same unparseable path as parsePeer.
        const identity = model.uri.writePeer(self.allocator, .{
            .transport = paths.items[0].transport,
            .designator = paths.items[0].designator,
            .hints = model.Hints.emptyFalse(),
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.UnparseableExporterLocator,
        };
        errdefer self.allocator.free(identity);
        const owned_paths = try paths.toOwnedSlice(self.allocator);
        return .{
            .identity = identity,
            .paths = owned_paths,
        };
    }

    fn freeAction(self: *Node, action: Action) void {
        switch (action) {
            .fail => |f| switch (f.reason) {
                .owned => |reason| self.allocator.free(reason),
                .static => {},
            },
            .dial, .flush, .settle, .retire_exporter, .need_gift_id, .release_capability, .fail_session => {},
        }
    }

    fn queueAction(self: *Node, action: Action) !void {
        try self.reserveActions(1);
        self.actions.pushReserved(action);
    }

    /// Preserve one future exporter-close failure per pending redeem, plus the
    /// immediate actions the caller is about to commit. `ActionFifo.reserve`
    /// reuses a dead prefix before it grows the backing.
    fn reserveActions(self: *Node, immediate: usize) !void {
        const handoff_promised = std.math.add(
            usize,
            self.proxy_action_reservations,
            self.pending_dial_waiter_reservations,
        ) catch return error.OutOfMemory;
        const with_inline = std.math.add(
            usize,
            handoff_promised,
            self.inline_passable_action_reservations,
        ) catch return error.OutOfMemory;
        const promised = std.math.add(usize, self.pending_withdraws.count(), with_inline) catch
            return error.OutOfMemory;
        const total = std.math.add(usize, promised, immediate) catch return error.OutOfMemory;
        try self.actions.reserve(self.allocator, total);
    }

    fn releaseProxyActionReservation(self: *Node) void {
        std.debug.assert(self.proxy_action_reservations > 0);
        self.proxy_action_reservations -= 1;
    }

    fn releasePendingDialWaiterReservations(self: *Node, count: usize) void {
        std.debug.assert(self.pending_dial_waiter_reservations >= count);
        self.pending_dial_waiter_reservations -= count;
    }

    /// Spend one proxy's held action seat to drive the recipient Peer. This is
    /// required even for a plain relayed value: listener fires are queued on a
    /// sibling session that the home-session feed would not otherwise touch.
    fn queueProxyFlush(self: *Node, peer_id: PeerId) void {
        self.releaseProxyActionReservation();
        self.actions.pushReserved(.{ .flush = peer_id });
    }

    /// Queue a fail action carrying an owned copy of `reason`.
    fn queueFail(self: *Node, dest: RedeemDestination, reason: []const u8) !void {
        const owned = try self.allocator.dupe(u8, reason);
        errdefer self.allocator.free(owned);
        try self.queueAction(.{ .fail = .{ .dest = .fromRedeem(dest), .reason = .{ .owned = owned } } });
    }

    /// Commit one failed withdrawal and, when it was the final use of a
    /// redeem-only exporter, retire that exporter in the same reservation.
    fn queueWithdrawFailure(self: *Node, pending: PendingWithdraw, reason: []const u8, retire: ?PeerId) !void {
        const owned = try self.allocator.dupe(u8, reason);
        errdefer self.allocator.free(owned);
        try self.reserveActions(if (retire != null) 2 else 1);
        self.actions.pushReserved(.{ .fail = .{
            .dest = .fromRedeem(pending.dest),
            .reason = .{ .owned = owned },
        } });
        if (retire) |peer_id| self.actions.pushReserved(.{ .retire_exporter = peer_id });
    }

    /// Pop the next queued action. The previous action's byte views are freed
    /// here, so a popped action is valid until the next call. Null when no
    /// action is pending.
    pub fn hasAction(self: *const Node) bool {
        return self.actions.unpopped().len != 0;
    }

    /// Borrow the next action without transferring or freeing it. Host uses
    /// this two-phase form so a fallible Vat consequence commits before the
    /// Node action is destructively popped.
    pub fn peekAction(self: *const Node) ?Action {
        return self.actions.peek();
    }

    /// Commit the action returned by `peekAction`, freeing any owned payload.
    /// A direct embedder that did not actually peek receives a typed refusal;
    /// the Host's two-phase executor treats absence after its successful
    /// consequence as an internal transaction failure rather than trapping.
    pub fn consumePeekedAction(self: *Node) error{NoPendingAction}!void {
        const action = self.actions.pop(self.allocator) orelse return error.NoPendingAction;
        self.freeAction(action);
    }

    pub fn nextAction(self: *Node) ?Action {
        if (self.last_action) |last| {
            self.freeAction(last);
            self.last_action = null;
        }
        const action = self.actions.pop(self.allocator) orelse return null;
        self.last_action = action;
        return action;
    }

    /// Recipient intercept: the application answer `answer` on
    /// `recipient_peer` resolved to a handoff give instead of a value. The
    /// embedder must not surface that resolve; it feeds it here and executes
    /// the actions. `give` is the verbatim signed envelope and
    /// `exporter_locator` the give's dialable `ocapn://…` URI (both borrowed;
    /// the node copies what it keeps). A live exporter connection for that
    /// locator withdraws immediately; a dial already in flight is joined; an
    /// unknown exporter becomes a `dial` action. An empty locator fails the
    /// answer closed.
    pub fn acceptGive(
        self: *Node,
        recipient_peer: PeerId,
        answer: u64,
        give: []const u8,
        exporter_locator: []const u8,
    ) !void {
        return self.acceptGiveTo(
            .{ .answer = .{ .recipient_peer = recipient_peer, .answer = .from(answer) } },
            give,
            exporter_locator,
        );
    }

    /// Recipient intercept for a give found inline in a Passable value. The
    /// Host owns `deferred` and receives it back in exactly one terminal node
    /// action; the node shares all dial, retry, withdrawal, and cleanup logic
    /// with the returned-answer path above.
    pub fn acceptInlineGive(
        self: *Node,
        recipient_peer: PeerId,
        deferred: u64,
        give: []const u8,
        exporter_locator: []const u8,
    ) !void {
        return self.acceptGiveTo(.{ .deferred = .{ .recipient_peer = recipient_peer, .id = deferred } }, give, exporter_locator);
    }

    fn acceptGiveTo(
        self: *Node,
        dest: RedeemDestination,
        give: []const u8,
        exporter_locator: []const u8,
    ) !void {
        if (exporter_locator.len == 0) {
            return self.queueFail(dest, "handoff give names no dialable exporter locator");
        }
        // One parse yields identity + dial parts (ADR-0012 join on
        // transport+designator, not raw URI representation / hints). No verbatim
        // URI copy — dial authority is the staged parts alone.
        // Unparseable locator: fail closed — never queue a dial the embedder
        // cannot open (and never allocate a staged row for the refuse path).
        var staged = self.stagePendingDial(exporter_locator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UnparseableExporterLocator => return self.queueFail(
                dest,
                "handoff give names unparseable exporter locator",
            ),
        };
        var staged_owned = true;
        defer if (staged_owned) self.freeStagedDial(&staged);
        if (self.exporters.get(staged.identity)) |exporter_peer| {
            const slot = self.peers.getPtr(exporter_peer);
            const retire_on_failure = if (slot) |live|
                live.provisional_exporter and live.pending_withdraw_count == 0
            else
                false;
            if (retire_on_failure) try self.reserveActions(3);
            try self.beginWithdraw(exporter_peer, dest, give);
            if (retire_on_failure and slot.?.pending_withdraw_count == 0)
                self.actions.pushReserved(.{ .retire_exporter = exporter_peer });
            return;
        }

        const owned_give = try self.allocator.dupe(u8, give);
        errdefer self.allocator.free(owned_give);
        const waiter: Waiter = .{ .dest = dest, .give = owned_give };

        // A dial already in flight for this exporter adopts the redeem instead
        // of opening a second connection.
        if (self.pending_dial_by_identity.get(staged.identity)) |pending_id| {
            const entry = self.pending_dials.getPtr(pending_id).?;
            try self.reserveActions(1);
            try entry.waiters.append(self.allocator, waiter);
            self.pending_dial_waiter_reservations += 1;
            return;
        }

        // Every fallible step happens before any ownership transfer, so an
        // allocation failure can never leave the pending table owning bytes an
        // armed errdefer also frees (the memory rule: exactly one free on
        // every path). The pending row owns identity + dial parts; the dial
        // action carries only the ticket (no verbatim URI dupe).
        try self.pending_dials.ensureUnusedCapacity(self.allocator, 1);
        try self.pending_dial_by_identity.ensureUnusedCapacity(self.allocator, 1);
        // One immediate dial plus the waiter's allocation-free terminal seat.
        try self.reserveActions(2);
        var pending: PendingDial = .{
            .identity = staged.identity,
            .paths = staged.paths,
        };
        staged_owned = false;
        var pending_owned = true;
        errdefer if (pending_owned) self.freePendingDialBytes(&pending);
        try pending.waiters.append(self.allocator, waiter);

        const pending_id = self.next_pending;
        const identity = pending.identity;
        self.pending_dials.putAssumeCapacity(pending_id, pending);
        pending_owned = false;
        self.pending_dial_waiter_reservations += 1;
        // Index key aliases the pending row's identity (one owner).
        self.pending_dial_by_identity.putAssumeCapacity(identity, pending_id);
        self.next_pending += 1;
        self.actions.pushReserved(.{ .dial = .{ .pending = pending_id } });
    }

    /// What staging a bare dial found: a live exporter connection already reaches
    /// this locator's identity, or a dial is in flight under `pending`.
    pub const DialStage = union(enum) {
        /// A previously dialed exporter already reaches this identity.
        open: PeerId,
        /// A dial is in flight; its ticket is the one the `dial` action carries.
        pending: PendingId,
    };

    /// Stage a dial for `locator` with no redeem waiting on it, joining an
    /// in-flight dial for the same identity rather than opening a second
    /// connection (the same ADR-0012 identity join `acceptGive` performs).
    ///
    /// This is the node's dial *scheduling*, without a gift: an adapter above
    /// that needs a connection to a locator — the Host's select-or-dial
    /// enlivenment (ADR-0098) — reuses the one pending-dial ticket space and
    /// its `dial` action rather than minting a second namespace the embedder
    /// would have to tell apart. A row staged here carries no waiters, so the
    /// node's own `exporterDialed` / `dialFailed` continuations withdraw
    /// nothing; the caller keys its own continuation on the returned ticket.
    pub fn stageDial(self: *Node, locator: []const u8) !DialStage {
        if (locator.len == 0) return error.UnparseableExporterLocator;
        var staged = try self.stagePendingDial(locator);
        var staged_owned = true;
        defer if (staged_owned) self.freeStagedDial(&staged);
        if (self.exporters.get(staged.identity)) |exporter_peer| {
            if (self.peers.getPtr(exporter_peer)) |slot| slot.provisional_exporter = false;
            return .{ .open = exporter_peer };
        }
        if (self.pending_dial_by_identity.get(staged.identity)) |pending_id| {
            self.pending_dials.getPtr(pending_id).?.application_owned = true;
            return .{ .pending = pending_id };
        }

        try self.pending_dials.ensureUnusedCapacity(self.allocator, 1);
        try self.pending_dial_by_identity.ensureUnusedCapacity(self.allocator, 1);
        try self.reserveActions(1);
        const pending: PendingDial = .{
            .identity = staged.identity,
            .paths = staged.paths,
            .application_owned = true,
        };
        staged_owned = false;
        const pending_id = self.next_pending;
        const identity = pending.identity;
        self.pending_dials.putAssumeCapacity(pending_id, pending);
        self.pending_dial_by_identity.putAssumeCapacity(identity, pending_id);
        self.next_pending += 1;
        self.actions.pushReserved(.{ .dial = .{ .pending = pending_id } });
        return .{ .pending = pending_id };
    }

    /// Send one withdraw on a live exporter session and record it pending.
    /// `give` is borrowed. The `desc:handoff-receive` is signed by that
    /// session's signing key. The tracking row and the flush action are reserved before the withdraw is
    /// queued: once the withdraw is on the wire, failing to track it would let
    /// its resolve surface to the application as an answer it never asked.
    fn beginWithdraw(self: *Node, exporter_peer: PeerId, dest: RedeemDestination, give: []const u8) !void {
        const slot = self.peers.getPtr(exporter_peer) orelse
            return self.queueFail(dest, "handoff redeem failed: exporter session is gone");
        const session = slot.peer;
        try self.pending_withdraws.ensureUnusedCapacity(self.allocator, 1);
        // One immediate flush plus the new pending redeem's eventual close
        // failure. Once the row is inserted, ordinary pushes preserve that
        // latter slot through `reserveActions`.
        try self.reserveActions(2);
        const withdraw_answer = session.allocateAnswer();
        // Signed by the key of the session the give arrived on, not this
        // exporter session's: the give named that identity as its
        // `recipient_key`, and the exporter verifies this receive against
        // that name (ADR-0097). `sendWithdrawGift` takes its side and session
        // names from the exporter session itself.
        const recipient_secret = self.sessionSecret(dest.recipientPeer()) orelse
            return self.queueFail(dest, "handoff redeem failed: introducing session is gone");
        session.sendWithdrawGift(
            recipient_secret,
            give,
            model.AnswerPosition.from(withdraw_answer),
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                var buf: [128]u8 = undefined;
                const reason = std.fmt.bufPrint(&buf, "handoff redeem failed: {s}", .{@errorName(err)}) catch "handoff redeem failed";
                return self.queueFail(dest, reason);
            },
        };
        self.pending_withdraws.putAssumeCapacity(
            .{ .peer_id = exporter_peer, .answer = withdraw_answer },
            .{ .dest = dest },
        );
        std.debug.assert(slot.pending_withdraw_count < std.math.maxInt(u32));
        slot.pending_withdraw_count += 1;
        self.actions.pushReserved(.{ .flush = exporter_peer });
    }

    /// Report a dial's success: the exporter for `pending` is registered as
    /// `exporter_peer` with an open keyed session. The node caches the exporter
    /// and withdraws every waiting give on it. An unknown `pending` is a no-op
    /// (the ticket already settled).
    pub fn exporterDialed(self: *Node, pending: PendingId, exporter_peer: PeerId) !void {
        try self.exporterReady(pending, exporter_peer, false);
    }

    /// Complete a pending dial with a Host session that was already live and
    /// application-owned. Unlike `exporterDialed`, failed withdrawals may not
    /// retire this selected session.
    pub fn exporterSelected(self: *Node, pending: PendingId, exporter_peer: PeerId) !void {
        try self.exporterReady(pending, exporter_peer, true);
    }

    /// The session opened for a redeem has carried application-visible work.
    /// It is no longer disposable even if every pending withdrawal fails.
    pub fn exporterApplicationOwned(self: *Node, exporter_peer: PeerId) void {
        if (self.peers.getPtr(exporter_peer)) |slot| slot.provisional_exporter = false;
    }

    fn exporterReady(self: *Node, pending: PendingId, exporter_peer: PeerId, selected: bool) !void {
        const pending_ptr = self.pending_dials.getPtr(pending) orelse return;
        pending_ptr.effect_in_flight = false;
        if (pending_ptr.cancel_requested) return;
        const pending_view = pending_ptr.*;
        const waiter_count = pending_view.waiters.items.len;
        // A dial that lost its final inline recipient while the external
        // effect was already running is still provisional: accept the physical
        // completion, then retire it without caching an ownerless session.
        const redeem_only = !pending_view.application_owned and !selected;
        // A successful waiter consumes one flush action now and one terminal
        // consequence later; a locally failed waiter consumes one failure now.
        // Reserve the larger bound for the whole batch, plus a possible
        // redeem-only retirement, before removing the pending dial. Reserve
        // both maps for the same reason: after this preflight, every waiter is
        // guaranteed either a tracked withdrawal or an explicit failure.
        // Each waiter already holds its terminal seat. Add one immediate flush
        // per successful withdraw and the possible redeem-only retirement.
        const batch_actions = std.math.add(usize, waiter_count, @intFromBool(redeem_only)) catch
            return error.OutOfMemory;
        try self.exporters.ensureUnusedCapacity(self.allocator, 1);
        try self.pending_withdraws.ensureUnusedCapacity(
            self.allocator,
            std.math.cast(u32, waiter_count) orelse return error.OutOfMemory,
        );
        try self.reserveActions(batch_actions);
        var entry = (self.pending_dials.fetchRemove(pending) orelse return).value;
        self.releasePendingDialWaiterReservations(entry.waiters.items.len);
        defer {
            for (entry.waiters.items) |waiter| self.allocator.free(waiter.give);
            entry.waiters.deinit(self.allocator);
        }
        std.debug.assert(self.pending_dial_by_identity.remove(entry.identity));
        // Parsed dial paths are no longer needed; the cache keys on identity.
        // The shell releases every path's owned transport, designator, and hints.
        self.freePendingDialShell(&entry);
        // The cache adopts the identity bytes; an already-cached identity (a
        // duplicate dial the embedder raced) keeps the first row.
        const cached = self.exporters.getOrPutAssumeCapacity(entry.identity);
        if (cached.found_existing) {
            self.allocator.free(entry.identity);
        } else {
            cached.value_ptr.* = exporter_peer;
        }
        const slot = self.peers.getPtr(exporter_peer);
        if (slot) |live| live.provisional_exporter = redeem_only;
        for (entry.waiters.items) |waiter| {
            self.beginWithdraw(exporter_peer, waiter.dest, waiter.give) catch |err| switch (err) {
                // Map and action capacity were secured above. The remaining
                // allocation is the peer's outbound message clone; failure
                // there belongs to this answer, not to the rest of the batch.
                error.OutOfMemory => self.actions.pushReserved(.{ .fail = .{
                    .dest = .fromRedeem(waiter.dest),
                    .reason = .{ .static = "handoff redeem failed: local allocation failure" },
                } }),
            };
        }
        if (slot) |live| {
            if (redeem_only and live.pending_withdraw_count == 0)
                self.actions.pushReserved(.{ .retire_exporter = exporter_peer });
        }
    }

    /// Claim a queued redeem-only exporter retirement at execution time. The
    /// action may have become stale while an earlier failure consequence ran:
    /// application activity can adopt the session, or another give can begin a
    /// withdrawal on it. Only the still-provisional, idle session is retired;
    /// claiming it also evicts the locator cache before the Host closes it.
    pub fn claimExporterRetirement(self: *Node, exporter_peer: PeerId) bool {
        const slot = self.peers.getPtr(exporter_peer) orelse return false;
        if (!slot.provisional_exporter or slot.pending_withdraw_count != 0) return false;
        slot.provisional_exporter = false;
        self.evictExporterCache(exporter_peer);
        return true;
    }

    /// Report a dial's failure. A failed path advances the same logical ticket
    /// to the next already-parsed alternative and emits another `dial` action.
    /// Only exhaustion breaks every waiter with `reason`; an unknown `pending`
    /// is a no-op.
    pub fn dialFailed(self: *Node, pending: PendingId, reason: []const u8) !DialFailure {
        const pending_view = self.pending_dials.getPtr(pending) orelse return .stale;
        pending_view.effect_in_flight = false;
        if (pending_view.cancel_requested) return .stale;
        const waiter_count = pending_view.waiters.items.len;

        if (pending_view.path_index + 1 < pending_view.paths.len) {
            try self.reserveActions(1);
            pending_view.path_index += 1;
            self.actions.pushReserved(.{ .dial = .{ .pending = pending } });
            return .retry;
        }

        var buf: [256]u8 = undefined;
        const message = std.fmt.bufPrint(&buf, "handoff redeem failed: {s}", .{reason}) catch "handoff redeem failed";
        // Preserve the useful transport diagnostic when memory permits. If it
        // does not, static failures still settle the entire batch after the
        // action reservation; allocator pressure must not erase answers.
        const owned_reasons: ?[][]u8 = stage: {
            if (waiter_count == 0) break :stage null;
            const reasons = self.allocator.alloc([]u8, waiter_count) catch break :stage null;
            var initialized: usize = 0;
            while (initialized < reasons.len) : (initialized += 1) {
                reasons[initialized] = self.allocator.dupe(u8, message) catch {
                    for (reasons[0..initialized]) |owned| self.allocator.free(owned);
                    self.allocator.free(reasons);
                    break :stage null;
                };
            }
            break :stage reasons;
        };
        defer if (owned_reasons) |reasons| self.allocator.free(reasons);

        var entry = (self.pending_dials.fetchRemove(pending) orelse return .stale).value;
        self.releasePendingDialWaiterReservations(entry.waiters.items.len);
        defer {
            self.freePendingDialBytes(&entry);
            for (entry.waiters.items) |waiter| self.allocator.free(waiter.give);
            entry.waiters.deinit(self.allocator);
        }
        std.debug.assert(self.pending_dial_by_identity.remove(entry.identity));
        for (entry.waiters.items, 0..) |waiter, index| {
            const failure_reason: FailureReason = if (owned_reasons) |reasons|
                .{ .owned = reasons[index] }
            else
                .{ .static = "handoff redeem failed: exporter dial failed" };
            self.actions.pushReserved(.{ .fail = .{
                .dest = .fromRedeem(waiter.dest),
                .reason = failure_reason,
            } });
        }
        return .exhausted;
    }

    /// How a redeem's awaited withdraw-resolution settled, fed through
    /// `claimResolve`. Named for the redeem half it classifies —
    /// `engine.bootstrap.WithdrawOutcome` is the exporter responder's verdict,
    /// a different question in the same layer.
    pub const RedeemOutcome = union(enum) {
        /// Fulfilled with a far object capability (the ordinary outcome).
        far: u64,
        /// Broken by the exporter; the reason is borrowed for the call.
        broken: []const u8,
        /// Fulfilled with something that is not a capability.
        not_capability,
    };

    /// Offer a resolve the embedder polled on `peer_id` to the node. Returns
    /// true when the resolve settles a pending withdraw — the node consumes it
    /// (enrolling the capability under a route and queueing the `settle`, or
    /// queueing the `fail`), and the embedder must not surface it to the
    /// application. False means the resolve is the application's, untouched.
    pub fn claimResolve(self: *Node, peer_id: PeerId, answer: u64, outcome: RedeemOutcome) !bool {
        // Read the row but retire it only after the outcome is queued, so an
        // allocation failure leaves the withdraw pending (the claim can be
        // retried) rather than silently dropping the recipient's answer.
        const key: WithdrawKey = .{ .peer_id = peer_id, .answer = answer };
        const pending = self.pending_withdraws.get(key) orelse return false;
        const slot = self.peers.getPtr(peer_id) orelse unreachable;
        std.debug.assert(slot.pending_withdraw_count != 0);
        switch (outcome) {
            .far => |far_id| {
                // Reserve both tables before the enroll clones, so the enroll
                // (row install + route bump) and the settle queue are one
                // all-or-nothing step: an OOM can only fire before anything
                // commits, and the retriable withdraw never strands a route.
                try self.redeemed.ensureUnusedCapacity(self.allocator, 1);
                try self.reserveActions(1);
                const redeemed = try self.enrollRedeemed(peer_id, .{ .far = model.FarRef.object(far_id) });
                self.actions.pushReserved(.{ .settle = .{
                    .dest = pending.dest,
                    .route_id = redeemed.routed.id,
                } });
                // The application now owns a capability homed on this session.
                slot.provisional_exporter = false;
            },
            .broken => |reason| {
                var buf: [256]u8 = undefined;
                const message = std.fmt.bufPrint(&buf, "handoff redeem failed: {s}", .{reason}) catch "handoff redeem failed";
                const retire: ?PeerId = if (slot.provisional_exporter and slot.pending_withdraw_count == 1) peer_id else null;
                try self.queueWithdrawFailure(pending, message, retire);
            },
            .not_capability => {
                const retire: ?PeerId = if (slot.provisional_exporter and slot.pending_withdraw_count == 1) peer_id else null;
                try self.queueWithdrawFailure(pending, "withdraw-gift did not resolve to a capability", retire);
            },
        }
        slot.pending_withdraw_count -= 1;
        std.debug.assert(self.pending_withdraws.remove(key));
        return true;
    }

    /// Record the verbatim exporter locator to embed in gives whose exporter
    /// is `peer_id` — an exporter reachable only by a dial hint (an iroh
    /// endpoint's direct addresses), where the session's own signed location
    /// record is not dialable. `location` is borrowed (the node copies it);
    /// empty clears the override back to the session record.
    pub fn setExporterLocation(self: *Node, peer_id: PeerId, location: ?model.PeerLocator) !void {
        const loc = location orelse {
            if (self.exporter_locations.fetchRemove(peer_id)) |prev| self.allocator.free(prev.value);
            return;
        };
        // Canonical Syrup locator-record bytes — the give embeds these, so a URI
        // (or any other non-record form) can never reach the wire from here.
        const owned = try engine.encodePeerLocatorRecord(self.allocator, loc);
        errdefer self.allocator.free(owned);
        if (!self.exporter_locations.contains(peer_id))
            try self.exporter_locations.ensureUnusedCapacity(self.allocator, 1);
        if (self.exporter_locations.fetchPutAssumeCapacity(peer_id, owned)) |prev|
            self.allocator.free(prev.value);
    }

    /// The recorded give-location override for `peer_id`, or empty (use the
    /// exporter session's own signed record).
    fn exporterLocation(self: *const Node, peer_id: PeerId) []const u8 {
        return self.exporter_locations.get(peer_id) orelse "";
    }

    /// When `far_id` is a foreign **promise** route whose home is not
    /// `recipient_peer`, mint a third-party import-promise on the recipient
    /// session, ensure a home-session `op:listen`, and return the near promise
    /// the vat should resolve with (ADR-0009 introducing-session proxy).
    /// Null means this fulfill is not a promise-proxy case (same-home, object
    /// foreign → gift path, or unknown route). Fails `error.session_not_open`
    /// when the home peer exists but cannot yet receive an `op:listen`.
    /// Multi-introduce of the same home wire shares **one** home listen; on
    /// fire the Host owns the lifted settlement and each recipient store
    /// materializes its own lowered tree through the shared Passable staging
    /// transaction.
    pub fn proxyForeignPromiseFulfill(self: *Node, recipient_peer: PeerId, route_id: model.CapabilityRouteId) !?model.Reference {
        const home = self.homeOf(route_id) orelse return null;
        if (home == recipient_peer) return null;
        const enrolled = self.foreignRoute(route_id) orelse return null;
        const wire_far = switch (enrolled.reference) {
            .far => |f| f,
            else => return null,
        };
        if (wire_far.kind != .promise) return null;

        // The same prepare/commit package used for recursive Passable values
        // keeps the historical top-level fulfillment seam transactional too.
        // One seat is the future recipient settlement drive; the other is the
        // possible first home-listener flush. Existing proxies simply leave
        // the second seat unused.
        try self.reserveActions(2);
        var projections = [_]InlinePromiseProjection{.{
            .route_id = route_id,
            .home = home,
            .original = .{ .routed = .{ .id = route_id, .kind = .promise } },
            .source = wire_far,
        }};
        var shell: InlinePassableBatch = undefined;
        shell.recipient_peer = recipient_peer;
        shell.promises = &projections;
        var prepared = try self.prepareInlinePromises(&shell);
        defer prepared.deinit(self);
        prepared.commit(self);
        return projections[0].projected.?;
    }

    /// Whether `(home_peer, listener_export)` is an armed proxy home-listener.
    /// Host peeks this before materializing a deliver's resolution so ordinary
    /// listen fires pay no clone on the miss path.
    pub fn isProxyHomeListener(self: *const Node, home_peer: PeerId, listener_export: u64) bool {
        return self.proxy_by_listener.contains(.{ .home = home_peer, .listener_export = listener_export });
    }

    /// Peek → materialize → consume a proxy home-listener fire. Miss path never
    /// allocates. Hit path takes ownership of the materialized resolution and
    /// never returns false after `toOwned`.
    pub fn claimProjectedProxyListenerFire(
        self: *Node,
        allocator: std.mem.Allocator,
        home_peer: PeerId,
        listener_export: u64,
        view_res: model.view.Resolution,
    ) !bool {
        if (!self.isProxyHomeListener(home_peer, listener_export)) return false;
        const owned = try view_res.toOwned(allocator);
        std.debug.assert(self.consumeProjectedProxyListenerFire(
            home_peer,
            listener_export,
            owned,
        ));
        return true;
    }

    /// Settle every live recipient of a consumed proxy fire with the break
    /// escrowed when that recipient was admitted. No allocation is permitted
    /// here: after the home fire is consumed there is no event to retry.
    fn breakRecipients(self: *Node, row: *PromiseProxy) void {
        for (row.recipients.items) |*recipient| self.breakRecipient(recipient);
    }

    fn breakRelayedOwned(self: *Node, peer_id: PeerId, slot: RelayedSlot, reason: []u8) void {
        const recip = self.peer(peer_id) orelse {
            self.allocator.free(reason);
            self.releaseProxyActionReservation();
            return;
        };
        // `applyRelayedResolution` consumes the resolution on every outcome,
        // including an error after the store commits. Freeing it here would
        // double-free that stored settlement.
        recip.applyRelayedResolutionGuaranteed(
            model.ImportPosition.from(slot.import_pos),
            slot.row_id,
            .{ .@"break" = .{ .message = reason } },
        ) catch |err| recip.emitFailure(err);
        self.queueProxyFlush(peer_id);
    }

    fn breakRecipient(self: *Node, recipient: *ProxyRecipient) void {
        self.breakRelayedOwned(
            recipient.peer,
            .{ .import_pos = recipient.import_pos, .row_id = recipient.row_id },
            recipient.takeFailure(),
        );
    }

    /// Move one resolution into a recipient store. If validation or storage
    /// refuses it before commit, use the already-reserved terminal break;
    /// after commit, only release the now-unneeded escrow.
    fn settleRecipient(self: *Node, recipient: *ProxyRecipient, resolution: model.Resolution) void {
        const recip = self.peer(recipient.peer) orelse {
            model.freeResolution(self.allocator, resolution);
            recipient.releaseFailure(self.allocator);
            self.releaseProxyActionReservation();
            return;
        };
        recip.applyRelayedResolutionGuaranteed(
            model.ImportPosition.from(recipient.import_pos),
            recipient.row_id,
            resolution,
        ) catch |err| recip.recordFailure(err);
        if (recip.session_state.importedPromiseResolution(.from(recipient.import_pos)) != null)
            recipient.releaseFailure(self.allocator)
        else
            return self.breakRecipient(recipient);
        self.queueProxyFlush(recipient.peer);
    }

    /// One recipient of a consumed proxy-listener fire. The handle exposes
    /// only the recipient session identity and one ownership-taking settlement
    /// operation; Host identity projection remains above Node, while the Node
    /// keeps the escrowed terminal break and staging transaction private.
    pub const RelayRecipient = struct {
        node: *Node,
        recipient: *ProxyRecipient,

        pub fn peerId(self: *const RelayRecipient) PeerId {
            return self.recipient.peer;
        }

        /// Materialize `resolution` into the recipient's allocator, then
        /// settle it directly or transfer it into the same bounded inline
        /// Passable transaction ordinary outbound messages use. Returns true
        /// only when the lowered capability receipts may commit. On false the
        /// recipient has already received its reserved terminal break.
        pub fn adopt(self: *RelayRecipient, resolution: model.Resolution) bool {
            const recipient_peer = self.node.peer(self.recipient.peer) orelse {
                self.node.breakRecipient(self.recipient);
                return false;
            };
            const owned = model.materializeResolutionForStore(recipient_peer.allocator, resolution) catch {
                self.node.breakRecipient(self.recipient);
                return false;
            };
            var message: model.Message = .{
                .resolve = .{
                    // This is a staging carrier, never a wire answer. The terminal
                    // destination below consumes only its resolution.
                    .answer = .from(0),
                    .resolution = owned,
                },
            };
            var destination: InlinePassableDestination = .{ .relayed = self.recipient.* };
            self.recipient.failure_reason = null;
            const staged = self.node.stageInlinePassable(
                self.recipient.peer,
                &message,
                &destination,
            ) catch {
                self.recipient.* = destination.relayed;
                model.freeMessage(recipient_peer.allocator, message);
                self.node.breakRecipient(self.recipient);
                return false;
            };
            if (staged) return true;

            self.recipient.* = destination.relayed;
            self.node.settleRecipient(self.recipient, message.resolve.resolution);
            return true;
        }
    };

    /// Consume one proxy-listener fire after the Host has lifted its value.
    /// `project` is invoked independently for each live recipient and must
    /// finish through `RelayRecipient.adopt`; a callback that cannot project
    /// leaves the escrow intact and is broken here. This is intentionally a
    /// Host-core callback seam, not a public embedding API.
    pub fn projectProxyListenerFire(
        self: *Node,
        home_peer: PeerId,
        listener_export: u64,
        context: anytype,
        comptime project: anytype,
    ) bool {
        const home_key = self.proxy_by_listener.get(.{
            .home = home_peer,
            .listener_export = listener_export,
        }) orelse return false;
        const row = self.promise_proxies.getPtr(home_key) orelse return false;
        for (row.recipients.items) |*recipient| {
            var relay: RelayRecipient = .{ .node = self, .recipient = recipient };
            project(context, &relay);
            if (recipient.failure_reason != null) self.breakRecipient(recipient);
        }
        self.removePromiseProxy(home_key);
        return true;
    }

    /// Consume a proxy fire whose owning Host could not lift/project. Every
    /// recipient already owns a terminal seat, so failure is correlated and
    /// allocation-free rather than escaping as a host-wide step error.
    pub fn breakProxyListenerFire(self: *Node, home_peer: PeerId, listener_export: u64) bool {
        const home_key = self.proxy_by_listener.get(.{
            .home = home_peer,
            .listener_export = listener_export,
        }) orelse return false;
        const row = self.promise_proxies.getPtr(home_key) orelse return false;
        self.breakRecipients(row);
        self.removePromiseProxy(home_key);
        return true;
    }

    /// Consume a complete resolution that is already expressed in Node
    /// identity: ordinary data plus enrolled foreign routes, never raw
    /// positions borrowed from some other session. This is the low-level peer
    /// face of the Host projection above. Every recipient materializes and
    /// stages independently; `resolution` remains one owner until all
    /// projections have adopted or broken, then is freed exactly once.
    pub fn consumeProjectedProxyListenerFire(
        self: *Node,
        home_peer: PeerId,
        listener_export: u64,
        resolution: model.Resolution,
    ) bool {
        if (!self.isProxyHomeListener(home_peer, listener_export)) return false;
        defer model.freeResolution(self.allocator, resolution);
        const Projection = struct {
            resolution: model.Resolution,

            fn recipient(context: *@This(), relay: *RelayRecipient) void {
                _ = relay.adopt(context.resolution);
            }
        };
        var projection: Projection = .{ .resolution = resolution };
        return self.projectProxyListenerFire(
            home_peer,
            listener_export,
            &projection,
            Projection.recipient,
        );
    }

    fn removePromiseProxy(self: *Node, key: ProxyHomeKey) void {
        if (self.promise_proxies.fetchRemove(key)) |kv| {
            var proxy = kv.value;
            self.deinitPromiseProxy(key, &proxy);
        }
    }

    fn deinitPromiseProxy(self: *Node, key: ProxyHomeKey, proxy: *PromiseProxy) void {
        if (self.peer(key.home)) |home_peer| {
            const listener = model.ExportPosition.from(proxy.listener_export);
            if (home_peer.session_state.captp_version == .next) {
                if (home_peer.session_state.shorteningIncarnationForImport(.from(proxy.current_wire_pos))) |source|
                    home_peer.session_state.detachPromiseSettlingNodeConsumer(source, listener);
            }
            home_peer.session_state.retireNodeSettlingResolver(listener);
        }
        const listener_key: ProxyListenerKey = .{
            .home = key.home,
            .listener_export = proxy.listener_export,
        };
        std.debug.assert(self.proxy_by_listener.remove(listener_key));
        std.debug.assert(self.proxy_by_source.remove(.{
            .home = key.home,
            .wire_pos = proxy.current_wire_pos,
        }));
        self.deinitProxyStorage(proxy);
    }

    fn deinitProxyStorage(self: *Node, proxy: *PromiseProxy) void {
        for (proxy.recipients.items) |*recipient| {
            if (recipient.failure_reason != null) self.releaseProxyActionReservation();
        }
        proxy.deinit(self.allocator);
    }

    fn sweepPromiseProxiesForPeer(self: *Node, peer_id: PeerId) void {
        var it = self.promise_proxies.iterator();
        while (it.next()) |entry| {
            var remove = entry.key_ptr.home == peer_id;
            if (!remove) {
                var i: usize = 0;
                while (i < entry.value_ptr.recipients.items.len) {
                    if (entry.value_ptr.recipients.items[i].peer == peer_id) {
                        if (entry.value_ptr.recipients.items[i].failure_reason != null)
                            self.releaseProxyActionReservation();
                        entry.value_ptr.recipients.items[i].releaseFailure(self.allocator);
                        entry.value_ptr.recipients.items[i] = entry.value_ptr.recipients.items[entry.value_ptr.recipients.items.len - 1];
                        entry.value_ptr.recipients.items.len -= 1;
                    } else {
                        i += 1;
                    }
                }
                remove = entry.value_ptr.recipients.items.len == 0;
            }
            if (!remove) continue;

            const key = entry.key_ptr.*;
            var proxy = entry.value_ptr.*;
            self.promise_proxies.removeByPtr(entry.key_ptr);
            self.deinitPromiseProxy(key, &proxy);
        }
    }

    /// Gifter intercept: the application answer `answer` on `peer_id`
    /// fulfilled to the far capability `far_id`. When that capability's
    /// recorded home is another connection, the node claims the reply and
    /// queues a `need_gift_id` action — entropy is a host effect, requested
    /// only now that the reply is actually becoming a gift — and returns true
    /// (the embedder must not also send a plain resolve; it draws 32 bytes and
    /// feeds `provideGiftId`). False means the reply is ordinary and the
    /// embedder resolves it itself. Foreign **promise** routes are not gifted
    /// here — Host rewrites those through `proxyForeignPromiseFulfill`.
    pub fn interceptFulfilledRoute(self: *Node, peer_id: PeerId, answer: u64, route_id: model.CapabilityRouteId) !bool {
        return self.interceptFulfilledRouteNamed(peer_id, .fromWire(.from(answer)), route_id);
    }

    pub fn interceptFulfilledRouteNamed(self: *Node, peer_id: PeerId, answer: model.AnswerName, route_id: model.CapabilityRouteId) !bool {
        const home = self.homeOf(route_id) orelse return false;
        if (home == peer_id) return false;
        if (self.foreignRoute(route_id)) |enrolled| {
            if (enrolled.reference == .far and enrolled.reference.far.kind == .promise) return false;
        }
        try self.requestGiftId(peer_id, route_id, .{ .answer = answer }, null);
        return true;
    }

    const PreparedInlineDeposit = struct {
        peer: *engine.Peer,
        deposit: engine.handoff_gifter.PreparedDepositGift,
    };

    const InlineExporterPreparation = struct {
        peer: *engine.Peer,
        count: usize = 0,
        batch: ?engine.Peer.PendingBatch = null,
    };

    const PreparedPromiseHome = struct {
        key: ProxyHomeKey,
        listener_export: model.ExportPosition,
        current_wire_pos: u64,
        next: bool,
        message: model.Message,
        reservation: engine.Peer.PendingReservation,
        proxy: PromiseProxy,
        committed: bool = false,

        fn abandon(self: *PreparedPromiseHome, node: *Node) void {
            if (self.committed) return;
            if (node.peer(self.key.home)) |home| {
                home.cancelPendingReservation(self.reservation);
                if (self.next) {
                    home.session_state.abandonPromiseSettlingListener(.from(self.current_wire_pos));
                } else {
                    std.debug.assert(home.session_state.removeOutboundResolver(self.listener_export));
                }
                home.session_state.releaseUnsharedExport(self.listener_export);
            }
            self.proxy.deinit(node.allocator);
            self.* = undefined;
        }

        fn commit(self: *PreparedPromiseHome, node: *Node) void {
            const home = node.peer(self.key.home) orelse unreachable;
            home.session_state.recordSend(self.message) catch unreachable;
            home.pushPendingAssume(self.reservation, .{ .message = self.message });
            const listener_key: ProxyListenerKey = .{
                .home = self.key.home,
                .listener_export = self.listener_export.int(),
            };
            node.proxy_by_listener.putAssumeCapacity(listener_key, self.key);
            node.promise_proxies.putAssumeCapacity(self.key, self.proxy);
            node.proxy_by_source.putAssumeCapacity(.{
                .home = self.key.home,
                .wire_pos = self.current_wire_pos,
            }, self.key);
            node.actions.pushReserved(.{ .flush = self.key.home });
            self.committed = true;
        }
    };

    const InlinePromiseGroup = struct {
        count: usize = 0,
        prepared_home: ?PreparedPromiseHome = null,
    };

    const PreparedPromiseRecipient = struct {
        home_key: ProxyHomeKey,
        peer: PeerId,
        export_position: model.ExportPosition,
        import_position: model.ImportPosition,
        row_id: u64,
        failure_reason: []u8,
        committed: bool = false,

        fn abandon(self: *PreparedPromiseRecipient, node: *Node) void {
            if (self.committed) return;
            if (node.peer(self.peer)) |recipient| {
                recipient.session_state.abandonUnsharedThirdPartyImport(self.import_position);
                recipient.session_state.releaseUnsharedExport(self.export_position);
            }
            node.allocator.free(self.failure_reason);
            self.* = undefined;
        }

        fn commit(self: *PreparedPromiseRecipient, node: *Node) void {
            const proxy = node.promise_proxies.getPtr(self.home_key) orelse unreachable;
            proxy.recipients.appendAssumeCapacity(.{
                .peer = self.peer,
                .import_pos = self.import_position.int(),
                .row_id = self.row_id,
                .failure_reason = self.failure_reason,
            });
            self.committed = true;
        }
    };

    const PreparedInlinePromises = struct {
        groups: std.AutoHashMapUnmanaged(ProxyHomeKey, InlinePromiseGroup) = .empty,
        recipients: std.ArrayListUnmanaged(PreparedPromiseRecipient) = .empty,
        committed: bool = false,

        fn deinit(self: *PreparedInlinePromises, node: *Node) void {
            if (!self.committed) {
                for (self.recipients.items) |*recipient| recipient.abandon(node);
                var groups = self.groups.valueIterator();
                while (groups.next()) |group| if (group.prepared_home) |*home|
                    home.abandon(node);
            }
            self.recipients.deinit(node.allocator);
            self.groups.deinit(node.allocator);
            self.* = undefined;
        }

        fn commit(self: *PreparedInlinePromises, node: *Node) void {
            var groups = self.groups.valueIterator();
            while (groups.next()) |group| if (group.prepared_home) |*home|
                home.commit(node);
            for (self.recipients.items) |*recipient| recipient.commit(node);
            node.proxy_action_reservations += self.recipients.items.len;
            self.committed = true;
        }
    };

    fn preparePromiseHome(
        self: *Node,
        key: ProxyHomeKey,
        wire_far: model.FarRef,
        recipient_count: usize,
    ) !PreparedPromiseHome {
        const home = self.peer(key.home) orelse return error.PeerGone;
        if (!home.sessionIsOpen()) return error.session_not_open;
        const next = home.session_state.captp_version == .next;
        const settling_target = if (next)
            home.session_state.shortenedPromiseTarget(wire_far.import_position)
        else
            wire_far.import_position;
        const listener = try home.session_state.allocateExport();
        errdefer home.session_state.releaseUnsharedExport(listener);
        if (next) {
            if (!(try home.session_state.claimPromiseSettlingListener(settling_target, listener, null)))
                return error.UnexpectedMessage;
        } else {
            try home.session_state.installNodeSettlingResolver(listener);
        }
        errdefer if (next) {
            home.session_state.abandonPromiseSettlingListener(settling_target);
        } else {
            std.debug.assert(home.session_state.removeOutboundResolver(listener));
        };
        const message: model.Message = .{ .listen = .{
            .target = .{ .far = model.FarRef.promise(settling_target.int()) },
            .listener = session_mod.slot.toReference(home.session_state.exportSlot(listener).?).?,
            .mode = .settling_only,
        } };
        try home.session_state.admits(model.view.Body.fromOwned(&message));
        try session_mod.validate.validateSend(&home.session_state, message);
        const reservation = try home.reservePending(.{ .message = message });
        errdefer home.cancelPendingReservation(reservation);
        var proxy: PromiseProxy = .{
            .listener_export = listener.int(),
            .current_wire_pos = settling_target.int(),
        };
        errdefer proxy.deinit(self.allocator);
        try proxy.recipients.ensureUnusedCapacity(self.allocator, recipient_count);
        return .{
            .key = key,
            .listener_export = listener,
            .current_wire_pos = settling_target.int(),
            .next = next,
            .message = message,
            .reservation = reservation,
            .proxy = proxy,
        };
    }

    fn preparePromiseRecipient(
        self: *Node,
        recipient: *engine.Peer,
        recipient_peer: PeerId,
        home_key: ProxyHomeKey,
        host_bytes: []const u8,
    ) !PreparedPromiseRecipient {
        const export_position = try recipient.session_state.allocatePromiseExport();
        errdefer recipient.session_state.releaseUnsharedExport(export_position);
        const import_position = model.ImportPosition.from(export_position.int());
        try recipient.session_state.installThirdPartyImport(import_position, host_bytes);
        errdefer recipient.session_state.abandonUnsharedThirdPartyImport(import_position);
        const failure_reason = try self.allocator.dupe(u8, proxy_failure_reason);
        return .{
            .home_key = home_key,
            .peer = recipient_peer,
            .export_position = export_position,
            .import_position = import_position,
            .row_id = recipient.session_state.importedPromiseRowId(import_position).?,
            .failure_reason = failure_reason,
        };
    }

    fn prepareInlinePromises(
        self: *Node,
        batch: *InlinePassableBatch,
    ) !PreparedInlinePromises {
        var prepared: PreparedInlinePromises = .{};
        errdefer prepared.deinit(self);
        if (batch.promises.len == 0) return prepared;

        try prepared.groups.ensureUnusedCapacity(self.allocator, @intCast(batch.promises.len));
        for (batch.promises) |promise| {
            const foreign = self.foreignRoute(promise.route_id) orelse return error.RouteNotLowerable;
            if (foreign.peer_id != promise.home or foreign.reference != .far or
                !std.meta.eql(foreign.reference.far, promise.source))
                return error.RouteNotLowerable;
            const home = self.peer(promise.home) orelse return error.PeerGone;
            const current_wire_pos = if (home.session_state.captp_version == .next)
                home.session_state.shortenedPromiseTarget(promise.source.import_position).int()
            else
                promise.source.import_position.int();
            const source_key: ProxyHomeKey = .{ .home = promise.home, .wire_pos = current_wire_pos };
            const home_key = self.proxy_by_source.get(source_key) orelse source_key;
            const entry = prepared.groups.getOrPutAssumeCapacity(home_key);
            if (!entry.found_existing) entry.value_ptr.* = .{};
            entry.value_ptr.count = std.math.add(
                usize,
                entry.value_ptr.count,
                1,
            ) catch return error.ProxyRecipientCapExceeded;
        }

        var new_homes: usize = 0;
        var groups = prepared.groups.iterator();
        while (groups.next()) |entry| {
            if (self.promise_proxies.getPtr(entry.key_ptr.*)) |proxy| {
                const total_recipients = std.math.add(
                    usize,
                    proxy.recipients.items.len,
                    entry.value_ptr.count,
                ) catch return error.ProxyRecipientCapExceeded;
                if (total_recipients > max_proxy_recipients)
                    return error.ProxyRecipientCapExceeded;
                try proxy.recipients.ensureUnusedCapacity(self.allocator, entry.value_ptr.count);
            } else {
                if (entry.value_ptr.count > max_proxy_recipients)
                    return error.ProxyRecipientCapExceeded;
                new_homes += 1;
            }
        }
        try self.proxy_by_listener.ensureUnusedCapacity(self.allocator, @intCast(new_homes));
        try self.promise_proxies.ensureUnusedCapacity(self.allocator, @intCast(new_homes));
        try self.proxy_by_source.ensureUnusedCapacity(self.allocator, @intCast(new_homes));

        groups = prepared.groups.iterator();
        while (groups.next()) |entry| {
            if (self.promise_proxies.contains(entry.key_ptr.*)) continue;
            entry.value_ptr.prepared_home = try self.preparePromiseHome(
                entry.key_ptr.*,
                model.FarRef.promise(entry.key_ptr.*.wire_pos),
                entry.value_ptr.count,
            );
        }

        try prepared.recipients.ensureTotalCapacityPrecise(self.allocator, batch.promises.len);
        const recipient = self.peer(batch.recipient_peer) orelse return error.PeerGone;
        for (batch.promises) |*promise| {
            const home = self.peer(promise.home) orelse return error.PeerGone;
            const current_wire_pos = if (home.session_state.captp_version == .next)
                home.session_state.shortenedPromiseTarget(promise.source.import_position).int()
            else
                promise.source.import_position.int();
            const source_key: ProxyHomeKey = .{ .home = promise.home, .wire_pos = current_wire_pos };
            const home_key = self.proxy_by_source.get(source_key) orelse source_key;
            const host_bytes = home.session_state.partnerDesignator() orelse
                return error.MissingPartnerDesignator;
            const projected = try self.preparePromiseRecipient(
                recipient,
                batch.recipient_peer,
                home_key,
                host_bytes,
            );
            prepared.recipients.appendAssumeCapacity(projected);
            promise.projected = .{ .near = model.NearRef.promise(projected.export_position.int()) };
        }
        return prepared;
    }

    fn replaceInlineProjectionArguments(
        self: *Node,
        recipient_peer: PeerId,
        args: []const model.Argument,
        gifts: []InlineGift,
        promises: []InlinePromiseProjection,
        gift_index: *usize,
        promise_index: *usize,
    ) engine.node_services.OutboundStagingError!void {
        for (@constCast(args)) |*arg|
            try self.replaceInlineProjectionArgument(
                recipient_peer,
                arg,
                gifts,
                promises,
                gift_index,
                promise_index,
            );
    }

    fn replaceInlineProjectionArgument(
        self: *Node,
        recipient_peer: PeerId,
        arg: *model.Argument,
        gifts: []InlineGift,
        promises: []InlinePromiseProjection,
        gift_index: *usize,
        promise_index: *usize,
    ) engine.node_services.OutboundStagingError!void {
        switch (arg.*) {
            .reference => |reference| if (try self.inlineProjectionRoute(recipient_peer, reference)) |projection| {
                switch (projection.kind) {
                    .object => {
                        const gift = &gifts[gift_index.*];
                        if (gift.route_id != projection.route_id or gift.home != projection.home or
                            !std.meta.eql(gift.original, reference))
                            return error.RouteNotLowerable;
                        const handoff = gift.handoff orelse return error.RouteNotLowerable;
                        arg.* = .{ .handoff = handoff };
                        gift.handoff = null;
                        gift.inserted_handoff = handoff;
                        gift_index.* += 1;
                    },
                    .promise => {
                        const promise = &promises[promise_index.*];
                        if (promise.route_id != projection.route_id or promise.home != projection.home or
                            !std.meta.eql(promise.original, reference))
                            return error.RouteNotLowerable;
                        arg.* = .{ .reference = promise.projected orelse return error.RouteNotLowerable };
                        promise.inserted_at = arg;
                        promise_index.* += 1;
                    },
                }
            },
            .list, .set => |items| try self.replaceInlineProjectionArguments(
                recipient_peer,
                items,
                gifts,
                promises,
                gift_index,
                promise_index,
            ),
            .tagged => |tagged| try self.replaceInlineProjectionArguments(
                recipient_peer,
                tagged.value,
                gifts,
                promises,
                gift_index,
                promise_index,
            ),
            .@"struct" => |entries| for (@constCast(entries)) |*entry|
                try self.replaceInlineProjectionArgument(
                    recipient_peer,
                    &entry.value,
                    gifts,
                    promises,
                    gift_index,
                    promise_index,
                ),
            else => {},
        }
    }

    fn replaceInlineProjections(self: *Node, batch: *InlinePassableBatch) !void {
        var gift_index: usize = 0;
        var promise_index: usize = 0;
        switch (batch.message) {
            .deliver => |deliver| try self.replaceInlineProjectionArguments(
                batch.recipient_peer,
                deliver.args,
                batch.gifts,
                batch.promises,
                &gift_index,
                &promise_index,
            ),
            .resolve => |*resolve| switch (resolve.resolution) {
                .fulfill => |*arg| try self.replaceInlineProjectionArgument(
                    batch.recipient_peer,
                    arg,
                    batch.gifts,
                    batch.promises,
                    &gift_index,
                    &promise_index,
                ),
                .@"break" => {},
            },
            else => unreachable,
        }
        if (gift_index != batch.gifts.len or promise_index != batch.promises.len)
            return error.RouteNotLowerable;
    }

    fn restoreInlineProjectionArguments(
        args: []const model.Argument,
        gifts: []InlineGift,
        promises: []InlinePromiseProjection,
        gift_index: *usize,
        promise_index: *usize,
    ) void {
        for (@constCast(args)) |*arg|
            restoreInlineProjectionArgument(arg, gifts, promises, gift_index, promise_index);
    }

    fn restoreInlineProjectionArgument(
        arg: *model.Argument,
        gifts: []InlineGift,
        promises: []InlinePromiseProjection,
        gift_index: *usize,
        promise_index: *usize,
    ) void {
        switch (arg.*) {
            .handoff => |handoff| if (gift_index.* < gifts.len and
                gifts[gift_index.*].inserted_handoff == handoff)
            {
                const gift = &gifts[gift_index.*];
                gift.handoff = handoff;
                gift.inserted_handoff = null;
                arg.* = .{ .reference = gift.original };
                gift_index.* += 1;
            },
            .reference => if (promise_index.* < promises.len and
                promises[promise_index.*].inserted_at == arg)
            {
                const promise = &promises[promise_index.*];
                arg.* = .{ .reference = promise.original };
                promise.inserted_at = null;
                promise_index.* += 1;
            },
            .list, .set => |items| restoreInlineProjectionArguments(
                items,
                gifts,
                promises,
                gift_index,
                promise_index,
            ),
            .tagged => |tagged| restoreInlineProjectionArguments(
                tagged.value,
                gifts,
                promises,
                gift_index,
                promise_index,
            ),
            .@"struct" => |entries| for (@constCast(entries)) |*entry|
                restoreInlineProjectionArgument(
                    &entry.value,
                    gifts,
                    promises,
                    gift_index,
                    promise_index,
                ),
            else => {},
        }
    }

    fn restoreInlineProjections(batch: *InlinePassableBatch) void {
        var gift_index: usize = 0;
        var promise_index: usize = 0;
        switch (batch.message) {
            .deliver => |deliver| restoreInlineProjectionArguments(
                deliver.args,
                batch.gifts,
                batch.promises,
                &gift_index,
                &promise_index,
            ),
            .resolve => |*resolve| switch (resolve.resolution) {
                .fulfill => |*arg| restoreInlineProjectionArgument(
                    arg,
                    batch.gifts,
                    batch.promises,
                    &gift_index,
                    &promise_index,
                ),
                .@"break" => {},
            },
            else => {},
        }
    }

    fn cancelInlineGiftTickets(self: *Node, batch_id: InlinePassableBatchId) void {
        while (true) {
            var found: ?u64 = null;
            var it = self.pending_gifts.iterator();
            while (it.next()) |entry| switch (entry.value_ptr.dest) {
                .inline_gift => |staged| if (staged.batch == batch_id) {
                    found = entry.key_ptr.*;
                    break;
                },
                else => {},
            };
            const ticket = found orelse break;
            var pending = (self.pending_gifts.fetchRemove(ticket) orelse unreachable).value;
            pending.releaseFailure(self.allocator);
        }
    }

    fn spendInlinePassableTerminalReservations(self: *Node, batch: *InlinePassableBatch) void {
        std.debug.assert(self.inline_passable_action_reservations >= batch.terminal_action_reservations);
        self.inline_passable_action_reservations -= batch.terminal_action_reservations;
        batch.terminal_action_reservations = 0;
    }

    fn queueInlineGiftLeaseReleases(self: *Node, gifts: []const InlineGift) void {
        for (gifts) |gift| if (gift.capability_lease) |capability_raw|
            self.actions.pushReserved(.{ .release_capability = capability_raw });
    }

    fn queueInlinePromiseLeaseReleases(
        self: *Node,
        promises: []const InlinePromiseProjection,
    ) void {
        for (promises) |promise| if (promise.capability_lease) |capability_raw|
            self.actions.pushReserved(.{ .release_capability = capability_raw });
    }

    fn unclaimInlineProjectionLeases(self: *Node, batch: *InlinePassableBatch) void {
        for (batch.gifts) |*gift| if (gift.capability_lease) |capability_raw| {
            self.unclaimOutboundStagingLease(gift.route_id, capability_raw);
            gift.capability_lease = null;
        };
        for (batch.promises) |*promise| if (promise.capability_lease) |capability_raw| {
            self.unclaimOutboundStagingLease(promise.route_id, capability_raw);
            promise.capability_lease = null;
        };
    }

    fn failInlinePassableBatch(self: *Node, batch_id: InlinePassableBatchId, err: anyerror) void {
        var batch = (self.pending_inline_passables.fetchRemove(batch_id) orelse return).value;
        self.cancelInlineGiftTickets(batch_id);
        self.spendInlinePassableTerminalReservations(&batch);
        switch (batch.destination) {
            .outbound => if (self.peer(batch.recipient_peer) != null) {
                self.actions.pushReserved(.{ .fail_session = .{
                    .peer_id = batch.recipient_peer,
                    .reason = @errorName(err),
                } });
            },
            .relayed => |*recipient| self.breakRecipient(recipient),
        }
        self.queueInlineGiftLeaseReleases(batch.gifts);
        self.queueInlinePromiseLeaseReleases(batch.promises);
        batch.deinit(self);
    }

    fn finishInlinePassableBatch(self: *Node, batch_id: InlinePassableBatchId) !void {
        const batch = self.pending_inline_passables.getPtr(batch_id) orelse return;
        if (batch.ready != batch.gifts.len) return;
        const recipient = self.peer(batch.recipient_peer) orelse return error.RouteNotLowerable;

        var deposits: std.ArrayListUnmanaged(PreparedInlineDeposit) = .empty;
        defer deposits.deinit(self.allocator);
        errdefer for (deposits.items) |*prepared| prepared.deposit.abandon(prepared.peer);
        try deposits.ensureTotalCapacityPrecise(self.allocator, batch.gifts.len);

        // One inline message may carry several gifts homed on the same
        // exporter. Reserve that exporter's complete queue transaction once;
        // independent one-row reservations would not enforce the cumulative
        // waterline while none of the prepared deposits is appended yet.
        var exporters: std.AutoHashMapUnmanaged(PeerId, InlineExporterPreparation) = .empty;
        defer exporters.deinit(self.allocator);
        try exporters.ensureUnusedCapacity(self.allocator, @intCast(batch.gifts.len));
        for (batch.gifts) |gift| {
            const exporter = self.peer(gift.home) orelse return error.RouteNotLowerable;
            const entry = exporters.getOrPutAssumeCapacity(gift.home);
            if (!entry.found_existing) entry.value_ptr.* = .{ .peer = exporter };
            entry.value_ptr.count += 1;
        }
        var exporter_it = exporters.valueIterator();
        while (exporter_it.next()) |entry|
            entry.batch = try entry.peer.beginPendingBatch(entry.count);

        for (batch.gifts) |gift| {
            const exporter = exporters.getPtr(gift.home) orelse unreachable;
            const pending_batch = if (exporter.batch) |*pending| pending else unreachable;
            deposits.appendAssumeCapacity(.{
                .peer = exporter.peer,
                .deposit = try engine.handoff_gifter.prepareDepositGiftInBatch(
                    exporter.peer,
                    pending_batch,
                    &gift.gift_id,
                    gift.gifted,
                ),
            });
        }

        var promises = try self.prepareInlinePromises(batch);
        defer promises.deinit(self);

        var projections_rewritten = true;
        errdefer if (projections_rewritten) restoreInlineProjections(batch);
        try self.replaceInlineProjections(batch);
        switch (batch.destination) {
            .outbound => {
                // Validate the rewritten recipient message while the batch
                // still owns it. Ordinary `Peer.send` consumes on every
                // outcome, so every deterministic refusal we can know here
                // must happen before that ownership edge.
                try recipient.session_state.admits(model.view.Body.fromOwned(&batch.message));
                try session_mod.validate.validateSend(&recipient.session_state, batch.message);
                recipient.cancelInlinePassableStaging(batch.staging_reservation.?);
                batch.staging_reservation = null;
                const send_result = recipient.send(batch.message);
                batch.message_owned = false;
                projections_rewritten = false;
                try send_result;

                promises.commit(self);
                for (deposits.items) |*prepared| prepared.deposit.commit(prepared.peer);
                deposits.clearRetainingCapacity();
            },
            .relayed => |*proxy_recipient| {
                const resolve = switch (batch.message) {
                    .resolve => |*value| value,
                    else => unreachable,
                };
                try recipient.session_state.validateStoredResolution(resolve.resolution);
                const imported = recipient.session_state.findImportedPromise(
                    .from(proxy_recipient.import_pos),
                ) orelse return error.InvalidReference;
                if (imported.cell.row_id != proxy_recipient.row_id)
                    return error.InvalidReference;
                if (imported.cell.resolution != null)
                    return error.UnexpectedMessage;

                // The row is live and the complete rewritten value is
                // admissible. Commit every gift/proxy consequence before the
                // recipient store can publish the resolution; one recipient
                // therefore observes all of its projection or only its
                // reserved terminal break.
                promises.commit(self);
                for (deposits.items) |*prepared| prepared.deposit.commit(prepared.peer);
                deposits.clearRetainingCapacity();
                recipient.cancelInlinePassableStaging(batch.staging_reservation.?);
                batch.staging_reservation = null;
                const resolution = resolve.resolution;
                batch.message_owned = false;
                projections_rewritten = false;
                self.settleRecipient(proxy_recipient, resolution);
            },
        }

        var finished = (self.pending_inline_passables.fetchRemove(batch_id) orelse unreachable).value;
        self.spendInlinePassableTerminalReservations(&finished);
        for (finished.gifts) |gift| self.actions.pushReserved(.{ .flush = gift.home });
        if (finished.destination == .outbound)
            self.actions.pushReserved(.{ .flush = finished.recipient_peer });
        self.queueInlineGiftLeaseReleases(finished.gifts);
        self.queueInlinePromiseLeaseReleases(finished.promises);
        finished.deinit(self);
    }

    /// Park a pending gift and ask the embedder for its id. Entropy is a host
    /// effect, so the node cannot draw the id itself; it queues a
    /// `need_gift_id` action and finishes in `provideGiftId`.
    ///
    /// One ticket per recipient, never one per capability: a give is signed
    /// for a single recipient's session key, so two recipients of the same
    /// relayed promise need two ids and two deposits.
    ///
    /// The ticket table and the action queue are reserved before either
    /// commits, so an out-of-memory fires before anything does and never
    /// orphans a ticket whose action the embedder never sees.
    fn requestGiftId(
        self: *Node,
        recipient_peer: PeerId,
        route_id: model.CapabilityRouteId,
        dest: PendingGift.Dest,
        failure_reason: ?[]u8,
    ) !void {
        try self.pending_gifts.ensureUnusedCapacity(self.allocator, 1);
        try self.reserveActions(1);
        const ticket = self.next_pending;
        self.pending_gifts.putAssumeCapacity(ticket, .{
            .recipient_peer = recipient_peer,
            .route_id = route_id,
            .dest = dest,
            .failure_reason = failure_reason,
        });
        self.next_pending += 1;
        self.actions.pushReserved(.{ .need_gift_id = .{ .ticket = ticket } });
    }

    /// Settle a pending gift that cannot be originated, at whichever slot it
    /// was bound for.
    fn failPendingGiftReserved(self: *Node, pending_in: PendingGift, reason: []const u8) void {
        var pending = pending_in;
        switch (pending.dest) {
            .answer => |answer| self.actions.pushReserved(.{ .fail = .{
                .dest = .{ .served_answer = .{
                    .recipient_peer = pending.recipient_peer,
                    .answer = answer,
                } },
                .reason = .{ .static = reason },
            } }),
            .relayed => |slot| self.breakRelayedOwned(pending.recipient_peer, slot, pending.takeFailure()),
            .inline_gift => |staged| self.failInlinePassableBatch(staged.batch, error.GiftIdUnavailable),
        }
    }

    /// Answer a `need_gift_id` action with the host-drawn `gift_id`: the node
    /// originates the claimed handoff (deposit on the exporter, signed give
    /// resolving the claimed answer, using any `setExporterLocation` override
    /// recorded for the exporter) and queues the two flushes, exporter first as
    /// a scheduling preference. The independent sessions may deliver either
    /// half first; the exporter parks an early withdraw until its deposit. A
    /// failed origination breaks the claimed answer instead. An unknown `ticket`
    /// is a no-op. `gift_id` is borrowed.
    pub fn provideGiftId(self: *Node, ticket: u64, gift_id: []const u8) !void {
        if (!self.pending_gifts.contains(ticket)) return;
        // Reserve the largest consequence before consuming the ticket. From
        // that commit point onward the handoff either queues both flushes or
        // settles its destination broken without another allocation.
        try self.reserveActions(2);
        var pending = (self.pending_gifts.fetchRemove(ticket) orelse unreachable).value;
        if (pending.dest == .inline_gift) {
            const staged = pending.dest.inline_gift;
            const batch = self.pending_inline_passables.getPtr(staged.batch) orelse return;
            if (staged.gift_index >= batch.gifts.len or
                gift_id.len != model.HANDOFF_GIFT_ID_BYTES)
            {
                self.failInlinePassableBatch(staged.batch, error.GiftIdUnavailable);
                return;
            }
            const gift = &batch.gifts[staged.gift_index];
            const gift_route = self.route(.{ .routed = .{ .id = pending.route_id } }) orelse {
                self.failInlinePassableBatch(staged.batch, error.RouteNotLowerable);
                return;
            };
            if (gift_route.peer_id != gift.home or !std.meta.eql(gift_route.reference, gift.gifted)) {
                self.failInlinePassableBatch(staged.batch, error.RouteNotLowerable);
                return;
            }
            const recipient = self.peer(pending.recipient_peer) orelse {
                self.failInlinePassableBatch(staged.batch, error.UnknownConnection);
                return;
            };
            const exporter = self.peer(gift.home) orelse {
                self.failInlinePassableBatch(staged.batch, error.UnknownConnection);
                return;
            };
            const recipient_key = recipient.session_state.partnerSessionKey() orelse {
                self.failInlinePassableBatch(staged.batch, error.NoRecipientKey);
                return;
            };
            const exporter_key = exporter.session_state.partnerSessionKey() orelse {
                self.failInlinePassableBatch(staged.batch, error.NoExporterKey);
                return;
            };
            const claimed = exporter.session_state.partnerLocatorRaw() orelse {
                self.failInlinePassableBatch(staged.batch, error.NoExporterLocator);
                return;
            };
            const exporter_location = self.exporterLocation(gift.home);
            const give = self.mintGive(
                gift.home,
                gift_id,
                recipient_key,
                exporter_key,
                if (exporter_location.len != 0) exporter_location else claimed,
                recipient.session_state.partnerKnownPancake(),
            ) catch |err| {
                self.failInlinePassableBatch(staged.batch, err);
                return;
            };
            defer self.allocator.free(give);
            gift.handoff = engine.handoff_gifter.decodeHandoffGive(batch.allocator, give) catch |err| {
                self.failInlinePassableBatch(staged.batch, err);
                return;
            };
            @memcpy(&gift.gift_id, gift_id);
            batch.ready += 1;
            pending.releaseFailure(self.allocator);
            self.finishInlinePassableBatch(staged.batch) catch |err|
                self.failInlinePassableBatch(staged.batch, err);
            return;
        }
        // Resolve the exporter connection and the real reference to deposit there.
        // The claimed far is a foreign-import route (ADR-0069) that carries the real
        // `far(position)` to deposit; depositing the route itself would name an
        // export the exporter never made.
        const r = self.route(.{ .routed = .{ .id = pending.route_id } }) orelse {
            self.failPendingGiftReserved(pending, "handoff origination failed: home connection is gone");
            return;
        };
        const home = r.peer_id;
        const gifted = r.reference;
        self.originateGive(
            pending.recipient_peer,
            home,
            gifted,
            gift_id,
            pending.dest,
            self.exporterLocation(home),
        ) catch {
            // The ticket and source listener are spent. A failure therefore
            // settles now, including OOM, rather than leaving the recipient to
            // wait on an operation no retry can reconstruct.
            self.failPendingGiftReserved(pending, "handoff origination failed: resource unavailable");
            return;
        };
        if (pending.failure_reason != null) self.releaseProxyActionReservation();
        pending.releaseFailure(self.allocator);
        self.actions.pushReserved(.{ .flush = home });
        self.actions.pushReserved(.{ .flush = pending.recipient_peer });
    }

    /// Report that the embedder could not answer a `need_gift_id` action.
    /// The claimed answer or relayed slot must still settle: consuming an
    /// entropy request without this terminal path would leave authority parked
    /// in `pending_gifts` forever. An unknown ticket is a no-op.
    pub fn giftIdFailed(self: *Node, ticket: u64) !void {
        const pending_view = self.pending_gifts.get(ticket) orelse return;
        // Callers normally report failure after popping the request, which
        // leaves its reserved queue slot available. Reserve explicitly so the
        // verb is still correct if a direct Node embedder reports early.
        if (pending_view.dest == .answer or pending_view.dest == .inline_gift) try self.reserveActions(1);
        const pending = (self.pending_gifts.fetchRemove(ticket) orelse unreachable).value;
        self.failPendingGiftReserved(pending, "handoff origination failed: gift-id entropy unavailable");
    }

    /// Gifter half of a three-party handoff (ADR-0009), the mirror of
    /// `beginWithdraw`: queue a `deposit-gift` of `gifted` on the exporter
    /// connection, build a `desc:handoff-give` signed by the node identity and
    /// addressed to the recipient connection's partner, and queue it as the
    /// fulfillment of `answer` on the recipient connection. This is the one
    /// definition of the origination the bindings and native driver share,
    /// replacing the per-binding deposit/build/resolve glue.
    ///
    /// `gift_id` keys both the deposit and the give (draw it at the embedder's I/O
    /// boundary — the sans-io node never generates entropy). `exporter_location`,
    /// when non-empty, is the verbatim exporter locator embedded in the give (an
    /// iroh exporter reachable only by a Direct dial hint); empty uses the
    /// exporter session's own signed location record. `gifted` is borrowed (the
    /// deposit deep-copies it).
    ///
    /// The embedder flushes both connections, exporter first as a scheduling
    /// preference, not a wire-order guarantee. Both sessions must be open keyed
    /// sessions (the recipient key addresses the give; the exporter key names the
    /// gifter-to-exporter session the give is signed under).
    fn originateGive(
        self: *Node,
        recipient_peer: PeerId,
        exporter_peer: PeerId,
        gifted: model.Reference,
        gift_id: []const u8,
        dest: PendingGift.Dest,
        exporter_location: []const u8,
    ) !void {
        const rp = self.peerAt(recipient_peer) orelse return error.UnknownConnection;
        const ep = self.peerAt(exporter_peer) orelse return error.UnknownConnection;

        const recipient_key = rp.session_state.partnerSessionKey() orelse return error.NoRecipientKey;
        const exporter_key = ep.session_state.partnerSessionKey() orelse return error.NoExporterKey;
        const claimed = ep.session_state.partnerLocatorRaw() orelse return error.NoExporterLocator;
        const exporter_loc = if (exporter_location.len != 0)
            exporter_location
        else
            claimed;

        const give = try self.mintGive(
            exporter_peer,
            gift_id,
            recipient_key,
            exporter_key,
            exporter_loc,
            rp.session_state.partnerKnownPancake(),
        );
        defer self.allocator.free(give);

        // The transaction owns exporter preparation and both local queue
        // commits. A prepared session mutation never escapes for a caller to
        // stale; the two transports remain free to deliver either queue first.
        const destination: engine.handoff_gifter.GiveDestination = switch (dest) {
            .answer => |answer| .{ .answer = answer },
            .relayed => |slot| .{ .relayed = .{
                .import_position = model.ImportPosition.from(slot.import_pos),
                .row_id = slot.row_id,
            } },
            .inline_gift => unreachable,
        };
        try engine.handoff_gifter.queueOriginatedGive(
            ep,
            rp,
            gift_id,
            gifted,
            give,
            destination,
        );
    }

    /// Mint the signed give before preparing either peer's queue transaction.
    /// Signing and encoding are fallible; completing them first keeps the
    /// later two-peer preparation free of stale session reservations.
    ///
    /// Two destinations need it. `originateGive` resolves a claimed *answer*
    /// with the give, which is the reply-interception path. The relayed
    /// settlement path needs the same bytes for a different slot: an
    /// introduced promise that fulfils with a capability owes the recipient a
    /// handoff, not a break, and a signed give is legal in any Passable
    /// position (the draft CapTP specification's "Sending the
    /// `desc:handoff-give`"). Splitting mint from delivery is what lets the
    /// second caller exist without a second copy of the signing.
    ///
    /// The caller owns the returned bytes.
    /// Mint one signed give for its recipient. Body lives in
    /// `handoff_gifter.mintGive`; this resolves the gifter–exporter session
    /// secret the signature needs (ADR-0097).
    fn mintGive(
        self: *Node,
        exporter_peer: PeerId,
        gift_id: []const u8,
        recipient_key: []const u8,
        exporter_key: []const u8,
        exporter_loc: []const u8,
        recipient_known_pancake: bool,
    ) ![]u8 {
        const secret = self.sessionSecret(exporter_peer) orelse return error.RouteNotLowerable;
        return engine.handoff_gifter.mintGive(
            self.allocator,
            secret,
            gift_id,
            recipient_key,
            exporter_key,
            exporter_loc,
            recipient_known_pancake,
        );
    }
};
