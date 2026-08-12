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
//! tables that make three-party handoff transparent: the
//! `redeemed` map from a synthetic far token to the exporter session that
//! hosts the real capability, and the `foreign_imports` map from a node-unique
//! token to the session a fetched capability lives on and the real wire
//! reference to address it there (ADR-0069).
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
const session_mod = @import("session");

const ActionFifo = @import("fifo.zig").ActionFifo;

const crypto = foundation.crypto;
pub const PeerId = @import("peer_id.zig").PeerId;
const HandoffDependency = engine.node_services.HandoffDependency;

/// Where a redeemed token routes: the exporter connection that hosts the real
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
/// recipient third-party import rows. On fire the Node owns the settlement
/// briefly, then each recipient store materializes via
/// `materializeResolutionForStore` (N=1 moves). Never N home listens.
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
    /// The reserved far-id range a redeemed three-party-handoff capability is
    /// handed to the application under. A redeemed cap lives on a dialed exporter
    /// connection, not on the connection the give arrived over, so the node hands
    /// the application an ordinary far reference whose id is drawn from this range
    /// — above any wire-allocated import position — and records the route under
    /// that id. A later send to the id is forwarded to the exporter with the real
    /// exporter-side reference swapped in, so transparency lives entirely in the
    /// node and the embedder's reference/send surface is untouched. The range is
    /// disjoint from real session import positions, so a redeemed token can never alias
    /// a partner's import. This is the cross-binding token model ADR-0066
    /// standardizes (retiring the per-binding `Ref.home` field).
    pub const REDEEMED_TOKEN_BASE: u64 = session_mod.REDEEMED_TOKEN_BASE;

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
    /// bookkeeping: a redeemed token's route keeps naming its exporter session
    /// after that session dies, and `routeReference` reads the missing peer to
    /// fail the token closed. Hand the same id to a later session and the stale
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
    /// which would alias that node's sessions one for one, and at the last slot
    /// would run export positions into the range kept for redeemed tokens.
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
    /// How much of `freed_export_bases` is already handed back out. The list is
    /// a queue read from this cursor and compacted in `takeExportBase`, so it
    /// stays proportional to the ranges actually outstanding.
    freed_export_head: usize = 0,
    /// token -> exporter route. A redeemed-handoff capability the application
    /// holds as a far ref `>= REDEEMED_TOKEN_BASE` resolves here.
    redeemed: std.AutoHashMapUnmanaged(u64, Route) = .empty,
    /// A fetched far import enrolled under a node-unique token (ADR-0069), so two
    /// imports at the same wire position on different CapTP sessions never collide.
    /// The `Route` names the home session and the real `far(position)` to
    /// address there — the same shape a redeemed token uses. Sends route through
    /// it, the gifter-side interceptor re-gifts through it, and it is swept in
    /// `removePeer`. Tokens are drawn from the shared `next_token` counter, so a
    /// given token is in `redeemed` or here, never both.
    foreign_imports: std.AutoHashMapUnmanaged(u64, Route) = .empty,
    /// Latches true the first time this node enrolls a foreign import (ADR-0069),
    /// and stays true thereafter. It is the gate each registered peer reads before
    /// walking an outbound message to lower tokens (`Peer.node_services`): a node that
    /// never fetches a foreign capability leaves it false, so every send skips the
    /// walk for one bool load. The peer holds a `*const bool` into this field, so
    /// the node must not move once a session is registered.
    foreign_active: bool = false,
    /// The next synthetic token a redeemed capability is enrolled under.
    next_token: u64 = REDEEMED_TOKEN_BASE,
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
    /// The most recently popped action; its byte views stay valid until the
    /// next `nextAction`, which frees them.
    last_action: ?Action = null,
    /// The next pending-dial ticket.
    next_pending: PendingId = 0,
    /// Introducing-session foreign-promise proxies keyed by home wire import
    /// (ADR-0009). Rows are only inserted once the home `op:listen` is armed.
    promise_proxies: std.AutoHashMapUnmanaged(ProxyHomeKey, PromiseProxy) = .empty,
    /// Home listener export → home-wire key, for O(1) fire dispatch.
    proxy_by_listener: std.AutoHashMapUnmanaged(ProxyListenerKey, ProxyHomeKey) = .empty,
    /// Current shortening target -> stable root key in `promise_proxies`.
    proxy_by_source: std.AutoHashMapUnmanaged(ProxyHomeKey, ProxyHomeKey) = .empty,

    /// How far apart two sessions' export positions start, and where this
    /// node's sessions begin.
    ///
    /// A near reference is one integer, and it means whatever the session
    /// reading it says it means, so the same number names a different object on
    /// every session. An application holds capabilities from several sessions
    /// at once — `sendRedeeming` hands it two in one call — and offering one to
    /// the wrong session is a one-word mistake. Disjoint ranges make that
    /// mistake name a position no session holds, so the held-export check
    /// refuses it, instead of it landing on whatever that session keeps at the
    /// same number and resolving silently to the wrong object.
    ///
    /// The split is 16 bits of node, 20 of session, 24 of export range: about a
    /// million sessions per node, each able to export sixteen million objects,
    /// both past what the connection budget admits. The node bits come from the
    /// node's own identity rather than a shared counter, because a counter
    /// would be process-wide mutable state in a layer whose whole point is not
    /// to have any — and two nodes in one process must still number their
    /// sessions apart, since an application can hold capabilities from both.
    const export_range_bits: u6 = 24;
    const export_node_shift: u6 = 44;
    /// How many node slots there are. Derived from where the node's own token
    /// range begins rather than from the width of a `u64`, so the top slot ends
    /// exactly where the reserved range starts and no export position can be
    /// read as a redeemed token. Sixteen bits, at the shift below.
    const export_node_slots: u64 = REDEEMED_TOKEN_BASE >> export_node_shift;
    const export_range_span: u64 = 1 << export_range_bits;
    comptime {
        // The fields must tile without overlapping, and the slots must tile the
        // reserved space exactly — a partial top slot would let the last node's
        // counter stop somewhere the arithmetic above does not describe. Held
        // here rather than in the prose above, because prose does not fail a
        // build.
        std.debug.assert(export_node_shift > export_range_bits);
        std.debug.assert(export_node_slots >= 1);
        std.debug.assert(REDEEMED_TOKEN_BASE % (@as(u64, 1) << export_node_shift) == 0);
        // Every range a node draws is one span wide and starts on a span
        // boundary, so a slot must hold a whole number of them.
        std.debug.assert((@as(u64, 1) << export_node_shift) % export_range_span == 0);
    }

    /// This node's first range. The node bits come from its own identity, so
    /// two nodes in one process usually land in different slots — usually, not
    /// always: sixteen bits of hash collide by birthday somewhere around three
    /// hundred nodes in one process, and colliding nodes number their sessions
    /// alike again. That is the same defence-in-depth the ranges give a session
    /// pair, not a guarantee, and a process running hundreds of nodes should
    /// read it that way.
    ///
    /// The `| export_range_span` skips slot zero's zeroth range on purpose: a
    /// base of 0 would have the first session mint export position 0, which is
    /// `session.BOOTSTRAP_POSITION`, aliasing the bootstrap export the session
    /// installs at open. Every other slot's first range starts above zero
    /// already; paying one span in every slot keeps the rule uniform.
    fn initialExportBase(seed: [crypto.SEED_BYTES]u8) u64 {
        const node_slot: u64 = std.hash.Wyhash.hash(0, &seed) % export_node_slots;
        return (node_slot << export_node_shift) | export_range_span;
    }

    /// Give `peer`'s session the next range, the one door a session's export
    /// numbers come through.
    ///
    /// It runs at registration for both the owned and the adopted path, so
    /// there is no verb that enrols a session without numbering it. That is the
    /// whole point of it living here: the node is what holds many sessions, so
    /// this makes equal numbering across sessions structurally unlikely, and a
    /// layer above cannot forget to ask.
    fn applyExportRange(self: *Node, target: *engine.Peer) !void {
        const base = try self.takeExportBase();
        target.session_state.setExportBase(base, export_range_span);
    }

    /// One past this node's last range: the top of the slot `base` sits in.
    fn exportBaseEndFor(base: u64) u64 {
        return ((base >> export_node_shift) + 1) << export_node_shift;
    }

    /// Draw the next session's export range: a range a released session gave
    /// back if there is one, otherwise a fresh one from the counter. Called
    /// once per session, at the one place every session passes through: a
    /// second draw would hand one session a range and throw another away.
    ///
    /// Refuses rather than carrying past the node's slot. Reaching that needs
    /// this node to hold every range in its slot at once, which the connection
    /// budget stops first; a node that merely churns connections recycles.
    fn takeExportBase(self: *Node) !u64 {
        const queued = self.freed_export_bases.items;
        if (self.freed_export_head < queued.len) {
            const base = queued[self.freed_export_head];
            self.freed_export_head += 1;
            const live = queued.len - self.freed_export_head;
            if (live == 0) {
                self.freed_export_bases.clearRetainingCapacity();
                self.freed_export_head = 0;
            } else if (self.freed_export_head >= live and self.freed_export_head >= 64) {
                // Slide the queue down once the dead prefix has grown past what
                // is still in it, so steady churn holds capacity near the
                // outstanding count instead of growing a cursor forever.
                std.mem.copyForwards(u64, queued[0..live], queued[self.freed_export_head..]);
                self.freed_export_bases.shrinkRetainingCapacity(live);
                self.freed_export_head = 0;
            }
            return base;
        }
        if (self.next_export_base >= self.export_base_end) return session_mod.Error.ExportRangeExhausted;
        const base = self.next_export_base;
        self.next_export_base += export_range_span;
        return base;
    }

    /// Take a released session's range back for reuse. Best effort: the release
    /// path has nowhere to report to, and a range that fails to make it back
    /// costs one slot out of a million, never correctness.
    fn recycleExportBase(self: *Node, base: u64) void {
        self.freed_export_bases.append(self.allocator, base) catch return;
    }

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
            pending.waiters.deinit(self.allocator);
        }
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
    fn sessionSecret(self: *const Node, peer_id: PeerId) crypto.SecretKey {
        const resolver = self.session_secret_resolver orelse return self.secretKey();
        return resolver.resolve(resolver.ctx, peer_id) orelse self.secretKey();
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
    /// each peer inline — puts its connections under one node so a redeemed token
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
    /// when the Node owns it. A later route to a redeemed token whose exporter
    /// was this session fails closed (the peer is gone), rather than forwarding
    /// onto a dead socket. The `peer_id` is never reused.
    ///
    /// The exporter cache, pending withdraws, and pending gifts naming this
    /// session are swept below. The `redeemed` routes are deliberately *not*:
    /// a route's `peer_id` going dead is exactly what `routeReference` reads to
    /// fail the token closed (its `peerAt` returns null). Removing the row would
    /// instead make the synthetic token fall through `route`'s "not a token I
    /// hold" branch and get sent to a partner as an ordinary far — a meaningless
    /// high id. The dead rows are reclaimed at `deinit`.
    pub fn removePeer(self: *Node, peer_id: PeerId) void {
        const live = self.peers.get(peer_id) orelse return;
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

        // Reclaim the foreign-import enrollments homed on this CapTP session
        // (ADR-0069): once the home is gone the token can never re-gift, so a
        // long-running broker does not accumulate stale routing rows.
        self.removeRowsForPeer(&self.foreign_imports, peer_id, struct {
            fn match(_: u64, route_row: Route, dying: PeerId) bool {
                return route_row.peer_id == dying;
            }
        }.match, struct {
            fn cleanup(node: *Node, _: u64, route_row: Route) void {
                model.freeReference(node.allocator, route_row.reference);
            }
        }.cleanup);

        // Drop promise proxies whose home or recipient peer died so a later
        // home fire cannot relay onto a gone session.
        self.sweepPromiseProxiesForPeer(peer_id);
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
                .peer_id = pending.recipient_peer,
                .answer = pending.answer,
                .reason = .{ .static = exporter_closed_reason },
            } });
            // Removing the iterator's current row only tombstones its slot; it
            // does not reallocate or move the backing. Queue the infallible
            // consequence first, then retire the row and its reserved slot.
            std.debug.assert(self.pending_withdraws.remove(entry.key_ptr.*));
        }
    }

    /// The reserved token id `reference` names (ADR-0066), or null for any
    /// reference outside the reserved range: an ordinary far import, a near, a
    /// promise, a sturdyref. This is the one definition of "this far id is a node
    /// token" that every routing and lowering entry shares, including the host
    /// verbs above the node, so the reserved-range boundary is a single fact
    /// rather than a compare re-typed at each use.
    pub fn tokenIdOf(reference: model.Reference) ?u64 {
        const named = model.ImportName.of(reference) orelse return null;
        return switch (named) {
            .token => |t| t.int(),
            .wire => null,
        };
    }

    /// The token `reference` names, for a caller that wants the typed value
    /// rather than its integer. `tokenIdOf` above stays for the table lookups,
    /// which key on the raw id.
    pub fn tokenOf(reference: model.Reference) ?model.RedeemedToken {
        const named = model.ImportName.of(reference) orelse return null;
        return switch (named) {
            .token => |t| t,
            .wire => null,
        };
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

    // ── Redeemed-token routing (the recipient half) ──────────────────────────

    /// Enroll a redeemed capability under a fresh synthetic token and return the
    /// far reference the application receives, indistinguishable from any other
    /// far capability a partner handed back. A later `routeReference` of that
    /// reference forwards to `exporter_peer` with `reference` (the real
    /// exporter-side ref) swapped in. The node adopts a clone of `reference`; the
    /// caller keeps its own. The caller reserves one slot in `redeemed` first, so
    /// the only fallible step here is the clone, which commits nothing on
    /// failure. Without that, a plain `put` failing after the clone would leave a
    /// half-committed row and a bumped token behind a returned error.
    fn enrollRedeemed(self: *Node, exporter_peer: PeerId, reference: model.Reference) !model.Reference {
        const owned = try model.cloneReference(self.allocator, reference);
        const token = self.next_token;
        self.redeemed.putAssumeCapacity(token, .{ .peer_id = exporter_peer, .reference = owned });
        self.next_token += 1;
        return .{ .far = model.FarRef.object(token) };
    }

    /// The exporter route for `reference`, if it names a redeemed token. Null for
    /// any reference outside the reserved token range, so an ordinary far import
    /// routes on its own connection.
    fn route(self: *Node, reference: model.Reference) ?Route {
        const id = tokenIdOf(reference) orelse return null;
        if (self.redeemed.get(id)) |r| return r;
        // A foreign-import token (ADR-0069) routes to its home connection,
        // addressed with the real wire import — the same swap a redeemed token
        // gets, so a send to a fetched capability reaches its exporter.
        return self.foreignRoute(id);
    }

    /// The still-current foreign-import route for `id`.
    ///
    /// The import row's token is its generation stamp. A missing or different
    /// token means the row was released (and perhaps reused) before a stale
    /// node map row was reclaimed, so every router reader goes through this
    /// check instead of addressing the position under its new meaning.
    fn foreignRoute(self: *Node, id: u64) ?Route {
        const foreign = self.foreign_imports.get(id) orelse return null;
        const home = self.peerAt(foreign.peer_id) orelse return null;
        const position = switch (foreign.reference) {
            .far => |far| far.import_position,
            else => return null,
        };
        if (home.session_state.foreignTokenFor(position) != id) return null;
        return foreign;
    }

    /// The exporter peer a redeemed-handoff (or foreign-import) token routes to,
    /// or null for any reference that names no such route. This is the
    /// deterministic answer to "which connection does this handoff capability
    /// live on," so a redeem's originating send can name that exporter session
    /// from the reply it holds — never by guessing which dial was in flight.
    pub fn exporterPeerFor(self: *Node, reference: model.Reference) ?PeerId {
        const r = self.route(reference) orelse return null;
        return r.peer_id;
    }

    // ── Foreign-import routing (the gifter half) ─────────────────────────────

    /// Enroll a fetched far import under a node-unique token (ADR-0069) and return
    /// the token reference the application holds. `wire` is the real `far(position)`
    /// on `home`. Two imports at the same wire position on different connections
    /// get distinct tokens, so re-gifting one never resolves to the other. The
    /// stored reference is a far (position-only, so it owns no heap); it is freed
    /// through `freeReference` on `removePeer` and `deinit` for uniformity with the
    /// redeemed route.
    pub fn enrollForeign(self: *Node, home: PeerId, wire: model.Reference) !model.Reference {
        const far = switch (wire) {
            .far => |value| value,
            else => return error.NotAFarReference,
        };
        const home_peer = self.peer(home) orelse return error.UnknownPeer;
        const kind = far.kind;
        // Enrolling is idempotent per import: the same capability keeps the
        // token it was first given. Minting a second one would give one object
        // two identities, which is what a caller comparing two fetches of the
        // same name sees, and would leave a routing row behind on every
        // enrollment, so a loop that re-fetches would grow the table without
        // bound. The token is kept on the import row, so it is forgotten when
        // the import is released.
        if (home_peer.session_state.foreignTokenFor(far.import_position)) |existing| {
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
            return .{ .far = .{ .import_position = .from(existing), .kind = enrolled_kind } };
        }
        try self.foreign_imports.ensureUnusedCapacity(self.allocator, 1);
        const token = self.next_token;
        // The session row is the generation check `route` consults. Record it
        // before committing the node route so an allocation failure returns
        // no unusable token and leaves no half-installed map row.
        try home_peer.session_state.noteForeignToken(far.import_position, token);
        self.foreign_imports.putAssumeCapacity(token, .{ .peer_id = home, .reference = wire });
        self.next_token += 1;
        self.foreign_active = true;
        return .{ .far = .{ .import_position = .from(token), .kind = kind } };
    }

    /// The connection a fetched capability's `far_id` lives on, or null when the
    /// node holds no enrollment for it (a redeemed token, an ordinary wire import
    /// the node never fetched, or an id the node never minted). This is the home
    /// the gifter-side interceptor originates a handoff toward. A fetched
    /// capability's identity is always a token, so only the token enrollment is
    /// consulted (ADR-0069).
    fn homeOf(self: *Node, far_id: u64) ?PeerId {
        if (self.foreignRoute(far_id)) |r| return r.peer_id;
        return null;
    }

    /// Whether `reference` names a capability foreign to `default_peer` when used
    /// as a `send`/`tell` argument: a redeemed-handoff token (always foreign — it
    /// has no wire home), or a foreign-import token addressed away from the
    /// connection it was fetched on. On its own home a foreign-import token is
    /// native, so it still marshals as an ordinary import there. An ordinary wire
    /// reference (below the reserved token range) is never foreign — it rides its
    /// own connection. Passing a foreign capability as a send argument is the case
    /// not yet lifted, so a binding fails closed on a true verdict rather than
    /// mis-encoding the reference for this partner. This is the one definition of
    /// that verdict the bindings share, computed from the node's token enrollments
    /// instead of being hand-rolled per binding (ADR-0066/ADR-0069).
    pub fn argIsForeign(self: *Node, default_peer: PeerId, reference: model.Reference) bool {
        const id = tokenIdOf(reference) orelse return false;
        // A foreign-import token is foreign only away from its home. A redeemed
        // token has no wire home and is foreign everywhere; an unknown high id
        // fails closed.
        if (self.foreignRoute(id)) |r| return r.peer_id != default_peer;
        return true;
    }

    /// Lower `reference` to the wire reference it names on `peer_id`, for the one
    /// place every outbound message is emitted (`Peer.send`, ADR-0069). This is
    /// the single chokepoint that keeps a node-local token off the wire in *every*
    /// position — target, argument, forwarded target, resolution — instead of one
    /// path at a time. The peer reaches it through the `engine.NodeServices` link this
    /// node installs at registration; the shared error type is
    /// `engine.LoweringError`.
    ///
    /// The fast path is a single integer compare: an ordinary import or near
    /// reference (below the reserved token range) is returned untouched, which is
    /// every real wire reference. Only a token pays the map lookup. Any token whose
    /// home is this CapTP session — a redeemed capability whose exporter is this
    /// session, or a foreign import fetched on it — lowers to its wire
    /// reference. A token homed on another session has no wire name here and
    /// fails closed with `TokenNotLiftable`. Cross-session *routing* (a redeemed
    /// token's redirect to its exporter, a re-gift) is not this function's job —
    /// the driver and the resolve interceptor own it, because only they choose a
    /// different session. The lowered reference is a far (position-only, POD),
    /// so it is substituted into the message by value with no ownership transfer.
    pub fn lowerForConn(self: *Node, peer_id: PeerId, reference: model.Reference) engine.LoweringError!model.Reference {
        if (tokenIdOf(reference) == null) return reference;
        const r = self.route(reference) orelse return error.TokenNotLiftable;
        if (r.peer_id != peer_id) return error.TokenNotLiftable;
        return r.reference;
    }

    /// The lowering hook for the peer registered as `peer_id`, installed on it at
    /// registration so `Peer.send` swaps tokens to wire references (ADR-0069). It
    /// carries a `*const bool` into `foreign_active` as its gate, so the peer skips
    /// the walk entirely until this node fetches its first foreign capability.
    fn services(self: *Node, peer_id: PeerId) engine.NodeServices {
        return engine.NodeServices.bind(self, peer_id, &self.foreign_active, .{
            .lower = lowerForConn,
            .local_object_projection = localObjectProjection,
            .gifter_session_resolver = gifterSessionResolver,
            .pending_withdraw_added = addHandoffWaiter,
            .pending_withdraw_removed = removeHandoffWaiter,
            .gift_deposited = markHandoffChanged,
            .session_closed = markGifterHandoffsChanged,
            .prepare_v1_emitted_handoff_count = prepareV1HandoffCount,
            .prepare_promise_shortening = prepareProxyPromiseShortening,
            .commit_promise_shortening = commitProxyPromiseShortening,
            .designator_scheme = designatorScheme,
        });
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
    ) !void {
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
    /// reference to address (a redeemed token is rewritten to its exporter-side
    /// reference). The embedder turns this into an `op:deliver` on `peer_id`'s
    /// peer.
    pub const Routed = struct {
        peer_id: PeerId,
        target: model.Reference,
    };

    /// Resolve `target` to the connection and real reference a deliver to it
    /// rides. A redeemed token routes to its exporter connection with the real
    /// exporter-side reference; any other reference rides `default_peer` (the
    /// connection the application is addressing) unchanged. Returns null when a
    /// redeemed token names an exporter connection that is gone.
    pub fn routeReference(self: *Node, default_peer: PeerId, target: model.Reference) ?Routed {
        if (tokenIdOf(target)) |id| return self.routeToken(id);
        return .{ .peer_id = default_peer, .target = target };
    }

    /// Resolve a token — a far id in the reserved range, redeemed or
    /// foreign-import — to its home connection and the real wire reference to
    /// address there, with no default connection to fall back to: a caller
    /// that holds only a token (a `gcRelease` by id) routes here without
    /// inventing one. Null when the token routes nowhere — never minted, or
    /// its enrollment was reclaimed when its home closed (ADR-0069) — so a
    /// retired token fails closed rather than pass the synthetic id onto the
    /// wire.
    pub fn routeToken(self: *Node, token: u64) ?Routed {
        const r = self.route(.{ .far = model.FarRef.object(token) }) orelse return null;
        if (self.peerAt(r.peer_id) == null) return null;
        return .{ .peer_id = r.peer_id, .target = r.reference };
    }

    /// Retire `token` once its real wire import has reached zero.
    ///
    /// The session import row is the lifetime authority: while it exists, a
    /// partial release must leave routing intact. Once it is gone, the partner
    /// may reuse that position, so retaining this route would let the old token
    /// address the new object. Unknown tokens and routes whose home connection
    /// has already gone are no-ops; their existing teardown policy owns those
    /// rows.
    pub fn retireReleasedToken(self: *Node, token: u64) void {
        const kind: enum { redeemed, foreign } = if (self.redeemed.contains(token))
            .redeemed
        else if (self.foreign_imports.contains(token))
            .foreign
        else
            return;
        const route_row = switch (kind) {
            .redeemed => self.redeemed.get(token).?,
            .foreign => self.foreign_imports.get(token).?,
        };
        const home = self.peerAt(route_row.peer_id) orelse return;
        const position = switch (route_row.reference) {
            .far => |far| far.import_position,
            else => return,
        };
        switch (kind) {
            .redeemed => {
                if (home.session_state.hasImport(position)) return;
                const removed = self.redeemed.fetchRemove(token).?;
                model.freeReference(self.allocator, removed.value.reference);
            },
            .foreign => {
                // A reused row may already exist here. Its token, not mere row
                // presence, decides whether this route still belongs to it.
                if (home.session_state.foreignTokenFor(position) == token) return;
                const removed = self.foreign_imports.fetchRemove(token).?;
                model.freeReference(self.allocator, removed.value.reference);
            },
        }
    }

    /// Consume a redeemed-handoff token when the Host lifts it into its own
    /// identity space. This is an ownership transfer: the Host retains the real
    /// import incarnation, and the synthetic Node route must stop being a
    /// second stale-capable handle. Foreign-import tokens are the Node routing
    /// identity for ordinary fetched capabilities and remain on their rows.
    pub fn consumeRedeemedToken(self: *Node, token: u64) bool {
        const removed = self.redeemed.fetchRemove(token) orelse return false;
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
    // with the routable token. The node holds the state (exporter cache,
    // pending dials, pending withdraws) and emits `Action`s; the embedder
    // performs the I/O each action names and feeds the outcome back. No
    // socket, no scheduler, no entropy lives here.

    /// A pending-dial ticket: the embedder's handle for reporting one dial's
    /// outcome (`exporterDialed` / `dialFailed`).
    pub const PendingId = u64;

    /// One redeem waiting on an exporter dial: the application answer to
    /// settle and the verbatim signed give to withdraw. The node owns `give`.
    const Waiter = struct {
        recipient_peer: PeerId,
        answer: u64,
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
        recipient_peer: PeerId,
        answer: u64,
    };

    /// One claimed gifter origination awaiting its host-drawn gift id, keyed
    /// by the ticket the `need_gift_id` action carried.
    /// One recipient's stored slot for a relayed promise: the import position
    /// the recipient knows it by, stamped with the row identity that proves
    /// the row was not torn down and re-registered underneath (ADR-0069).
    const RelayedSlot = struct { import_pos: u64, row_id: u64 };

    const PendingGift = struct {
        recipient_peer: PeerId,
        far_id: u64,
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
            answer: u64,
            relayed: RelayedSlot,
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
        /// Settle the application answer `answer` on `peer_id`: the redeemed
        /// capability is enrolled and `token` is the ordinary far id the
        /// application receives.
        settle: struct { peer_id: PeerId, answer: u64, token: u64 },
        /// Break the application answer `answer` on `peer_id` with `reason`.
        fail: struct {
            peer_id: PeerId,
            answer: u64,
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
        const path = entry.paths[entry.path_index];
        return .{
            .transport = path.transport,
            .designator = path.designator,
            .hints = path.hints,
        };
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
            .dial, .flush, .settle, .retire_exporter, .need_gift_id => {},
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
        const promised = std.math.add(usize, self.pending_withdraws.count(), self.proxy_action_reservations) catch
            return error.OutOfMemory;
        const total = std.math.add(usize, promised, immediate) catch return error.OutOfMemory;
        try self.actions.reserve(self.allocator, total);
    }

    fn reserveProxyAction(self: *Node) !void {
        try self.reserveActions(1);
        self.proxy_action_reservations += 1;
    }

    fn releaseProxyActionReservation(self: *Node) void {
        std.debug.assert(self.proxy_action_reservations > 0);
        self.proxy_action_reservations -= 1;
    }

    /// Spend one proxy's held action seat to drive the recipient Peer. This is
    /// required even for a plain relayed value: listener fires are queued on a
    /// sibling session that the home-session feed would not otherwise touch.
    fn queueProxyFlush(self: *Node, peer_id: PeerId) void {
        self.releaseProxyActionReservation();
        self.actions.pushReserved(.{ .flush = peer_id });
    }

    /// Queue a fail action carrying an owned copy of `reason`.
    fn queueFail(self: *Node, peer_id: PeerId, answer: u64, reason: []const u8) !void {
        const owned = try self.allocator.dupe(u8, reason);
        errdefer self.allocator.free(owned);
        try self.queueAction(.{ .fail = .{ .peer_id = peer_id, .answer = answer, .reason = .{ .owned = owned } } });
    }

    /// Commit one failed withdrawal and, when it was the final use of a
    /// redeem-only exporter, retire that exporter in the same reservation.
    fn queueWithdrawFailure(self: *Node, pending: PendingWithdraw, reason: []const u8, retire: ?PeerId) !void {
        const owned = try self.allocator.dupe(u8, reason);
        errdefer self.allocator.free(owned);
        try self.reserveActions(if (retire != null) 2 else 1);
        self.actions.pushReserved(.{ .fail = .{
            .peer_id = pending.recipient_peer,
            .answer = pending.answer,
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
    pub fn consumePeekedAction(self: *Node) void {
        const action = self.actions.pop(self.allocator) orelse unreachable;
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
        if (exporter_locator.len == 0) {
            return self.queueFail(recipient_peer, answer, "handoff give names no dialable exporter locator");
        }
        // One parse yields identity + dial parts (ADR-0012 join on
        // transport+designator, not raw URI representation / hints). No verbatim
        // URI copy — dial authority is the staged parts alone.
        // Unparseable locator: fail closed — never queue a dial the embedder
        // cannot open (and never allocate a staged row for the refuse path).
        var staged = self.stagePendingDial(exporter_locator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UnparseableExporterLocator => return self.queueFail(
                recipient_peer,
                answer,
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
            try self.beginWithdraw(exporter_peer, recipient_peer, answer, give);
            if (retire_on_failure and slot.?.pending_withdraw_count == 0)
                self.actions.pushReserved(.{ .retire_exporter = exporter_peer });
            return;
        }

        const owned_give = try self.allocator.dupe(u8, give);
        errdefer self.allocator.free(owned_give);
        const waiter: Waiter = .{ .recipient_peer = recipient_peer, .answer = answer, .give = owned_give };

        // A dial already in flight for this exporter adopts the redeem instead
        // of opening a second connection.
        if (self.pending_dial_by_identity.get(staged.identity)) |pending_id| {
            const entry = self.pending_dials.getPtr(pending_id).?;
            try entry.waiters.append(self.allocator, waiter);
            return;
        }

        // Every fallible step happens before any ownership transfer, so an
        // allocation failure can never leave the pending table owning bytes an
        // armed errdefer also frees (the memory rule: exactly one free on
        // every path). The pending row owns identity + dial parts; the dial
        // action carries only the ticket (no verbatim URI dupe).
        try self.pending_dials.ensureUnusedCapacity(self.allocator, 1);
        try self.pending_dial_by_identity.ensureUnusedCapacity(self.allocator, 1);
        try self.reserveActions(1);
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
    fn beginWithdraw(self: *Node, exporter_peer: PeerId, recipient_peer: PeerId, answer: u64, give: []const u8) !void {
        const slot = self.peers.getPtr(exporter_peer) orelse
            return self.queueFail(recipient_peer, answer, "handoff redeem failed: exporter session is gone");
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
        session.sendWithdrawGift(
            self.sessionSecret(recipient_peer),
            give,
            model.AnswerPosition.from(withdraw_answer),
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                var buf: [128]u8 = undefined;
                const reason = std.fmt.bufPrint(&buf, "handoff redeem failed: {s}", .{@errorName(err)}) catch "handoff redeem failed";
                return self.queueFail(recipient_peer, answer, reason);
            },
        };
        self.pending_withdraws.putAssumeCapacity(
            .{ .peer_id = exporter_peer, .answer = withdraw_answer },
            .{ .recipient_peer = recipient_peer, .answer = answer },
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
        const pending_view = self.pending_dials.get(pending) orelse return;
        const waiter_count = pending_view.waiters.items.len;
        const redeem_only = waiter_count != 0 and !pending_view.application_owned and !selected;
        // A successful waiter consumes one flush action now and one terminal
        // consequence later; a locally failed waiter consumes one failure now.
        // Reserve the larger bound for the whole batch, plus a possible
        // redeem-only retirement, before removing the pending dial. Reserve
        // both maps for the same reason: after this preflight, every waiter is
        // guaranteed either a tracked withdrawal or an explicit failure.
        const batch_actions = std.math.add(
            usize,
            std.math.mul(usize, waiter_count, 2) catch return error.OutOfMemory,
            @intFromBool(redeem_only),
        ) catch return error.OutOfMemory;
        try self.exporters.ensureUnusedCapacity(self.allocator, 1);
        try self.pending_withdraws.ensureUnusedCapacity(
            self.allocator,
            std.math.cast(u32, waiter_count) orelse return error.OutOfMemory,
        );
        try self.reserveActions(batch_actions);
        var entry = (self.pending_dials.fetchRemove(pending) orelse return).value;
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
            self.beginWithdraw(exporter_peer, waiter.recipient_peer, waiter.answer, waiter.give) catch |err| switch (err) {
                // Map and action capacity were secured above. The remaining
                // allocation is the peer's outbound message clone; failure
                // there belongs to this answer, not to the rest of the batch.
                error.OutOfMemory => self.actions.pushReserved(.{ .fail = .{
                    .peer_id = waiter.recipient_peer,
                    .answer = waiter.answer,
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
        const waiter_count = pending_view.waiters.items.len;

        if (pending_view.path_index + 1 < pending_view.paths.len) {
            try self.reserveActions(waiter_count + 1);
            pending_view.path_index += 1;
            self.actions.pushReserved(.{ .dial = .{ .pending = pending } });
            return .retry;
        }

        try self.reserveActions(waiter_count);

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
                .peer_id = waiter.recipient_peer,
                .answer = waiter.answer,
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
    /// (enrolling the capability under a token and queueing the `settle`, or
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
                // (row install + token bump) and the settle queue are one
                // all-or-nothing step: an OOM can only fire before anything
                // commits, and the retriable withdraw never strands a token.
                try self.redeemed.ensureUnusedCapacity(self.allocator, 1);
                try self.reserveActions(1);
                const token = try self.enrollRedeemed(peer_id, .{ .far = model.FarRef.object(far_id) });
                self.actions.pushReserved(.{ .settle = .{
                    .peer_id = pending.recipient_peer,
                    .answer = pending.answer,
                    .token = token.far.import_position.int(),
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

    /// When `far_id` is a foreign **promise** token whose home is not
    /// `recipient_peer`, mint a third-party import-promise on the recipient
    /// session, ensure a home-session `op:listen`, and return the near promise
    /// the vat should resolve with (ADR-0009 introducing-session proxy).
    /// Null means this fulfill is not a promise-proxy case (same-home, object
    /// foreign → gift path, or unknown token). Fails `error.session_not_open`
    /// when the home peer exists but cannot yet receive an `op:listen`.
    /// Multi-introduce of the same home wire shares **one** home listen; on
    /// fire the Node owns the settlement and each recipient store materializes
    /// from that owner (`materializeResolutionForStore`; N=1 moves).
    pub fn proxyForeignPromiseFulfill(self: *Node, recipient_peer: PeerId, far_id: u64) !?model.Reference {
        const home = self.homeOf(far_id) orelse return null;
        if (home == recipient_peer) return null;
        const enrolled = self.foreignRoute(far_id) orelse return null;
        const wire_far = switch (enrolled.reference) {
            .far => |f| f,
            else => return null,
        };
        if (wire_far.kind != .promise) return null;

        const hp = self.peer(home) orelse return error.PeerGone;
        const current_wire_pos = if (hp.session_state.captp_version == .next)
            hp.session_state.shortenedPromiseTarget(wire_far.import_position).int()
        else
            wire_far.import_position.int();
        const source_key: ProxyHomeKey = .{ .home = home, .wire_pos = current_wire_pos };
        const home_key = self.proxy_by_source.get(source_key) orelse source_key;
        const armed_here = self.promise_proxies.getPtr(home_key) == null;
        if (armed_here) {
            try self.armHomeProxy(home_key, model.FarRef.promise(current_wire_pos));
        }
        errdefer if (armed_here) self.removePromiseProxy(home_key);

        const rp = self.peer(recipient_peer) orelse return error.PeerGone;
        const host_bytes = hp.session_state.partnerDesignator() orelse return error.MissingPartnerDesignator;
        const export_pos = try rp.session_state.allocatePromiseExport();
        errdefer rp.session_state.releaseUnsharedExport(export_pos);
        try rp.session_state.installThirdPartyImport(.from(export_pos.int()), host_bytes);
        errdefer rp.session_state.abandonUnsharedThirdPartyImport(.from(export_pos.int()));
        const row_id = rp.session_state.importedPromiseRowId(.from(export_pos.int())).?;

        const proxy = self.promise_proxies.getPtr(home_key).?;
        // Refused at introduce time, where the caller can still see it. At fire
        // time the only outcome left is a break, and the peer that would pay
        // for an unbounded list is the home session, which is not the one
        // driving the count.
        if (proxy.recipients.items.len >= max_proxy_recipients) {
            return error.ProxyRecipientCapExceeded;
        }
        const failure_reason = try self.allocator.dupe(u8, proxy_failure_reason);
        errdefer self.allocator.free(failure_reason);
        try proxy.recipients.ensureUnusedCapacity(self.allocator, 1);
        // Hold the sibling-session drive before publishing the recipient. The
        // home fire is one-shot, so settlement may not discover afterward
        // that its listener carriers have no scheduler seat.
        try self.reserveProxyAction();
        proxy.recipients.appendAssumeCapacity(.{
            .peer = recipient_peer,
            .import_pos = export_pos.int(),
            .row_id = row_id,
            .failure_reason = failure_reason,
        });

        return .{ .near = model.NearRef.promise(export_pos.int()) };
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
    pub fn claimProxyListenerFire(
        self: *Node,
        allocator: std.mem.Allocator,
        home_peer: PeerId,
        listener_export: u64,
        view_res: model.view.Resolution,
    ) !bool {
        if (!self.isProxyHomeListener(home_peer, listener_export)) return false;
        const owned = try view_res.toOwned(allocator);
        std.debug.assert(try self.consumeProxyListenerFire(home_peer, listener_export, owned));
        return true;
    }

    /// Whether a home session's resolution names something whose meaning is
    /// local to that session, so it cannot be stored on a recipient as it
    /// stands. This only detects; the caller decides what to do about it.
    ///
    /// The resolution was decoded on the home session, so its references mean
    /// what that session says they mean. Storing them on a recipient session
    /// unchanged hands that partner a number belonging to a different
    /// conversation.
    ///
    /// Renaming it is not enough. Handing a capability to a third party is a
    /// handoff: that party has no session with whoever hosts the object, so it
    /// needs a signed give naming the exporter. Even enrolling the reference
    /// under a node token only moves the failure later — a token whose home is
    /// another connection cannot be lowered onto this one, and the send would
    /// fail at encode with the promise already settled. So a true verdict here
    /// sends the value to `giftableCapability`: a bare far object is
    /// introduced by handoff, and everything else is broken, which is a
    /// settlement the recipient can observe.
    ///
    /// Only the arms whose meaning comes from session state count. A `near` is
    /// an export position, a `far` an import position, a `promise` an answer
    /// position: each names a slot in one conversation. A `sturdy` names a peer
    /// and a swissnum, which mean the same thing everywhere, and is the
    /// ordinary way to hand a durable capability to a third party without a
    /// handoff — it relays like any other value, and the payload encoder
    /// already writes it in fulfill position. A `broken` carries only a reason.
    fn carriesSessionScopedReference(arg: model.Argument) bool {
        return switch (arg) {
            .reference => |reference| switch (reference) {
                .near, .far, .promise => true,
                .sturdy, .broken => false,
            },
            .list, .set => |items| for (items) |item| {
                if (carriesSessionScopedReference(item)) break true;
            } else false,
            .tagged => |tagged| for (tagged.value) |item| {
                if (carriesSessionScopedReference(item)) break true;
            } else false,
            .@"struct" => |entries| for (entries) |entry| {
                if (carriesSessionScopedReference(entry.value)) break true;
            } else false,
            else => false,
        };
    }

    fn resolutionCarriesSessionScopedReference(resolution: model.Resolution) bool {
        return switch (resolution) {
            .fulfill => |arg| carriesSessionScopedReference(arg),
            .@"break" => false,
        };
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
        ) catch {};
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
        ) catch {};
        if (recip.session_state.importedPromiseResolution(.from(recipient.import_pos)) != null)
            recipient.releaseFailure(self.allocator)
        else
            return self.breakRecipient(recipient);
        self.queueProxyFlush(recipient.peer);
    }

    /// The capability a relayed resolution can be introduced by handoff, or
    /// null when it cannot.
    ///
    /// Only a bare far object qualifies, and each rejected shape is rejected
    /// for its own reason. A promise cannot be gifted because a handoff names
    /// a capability the exporter deposits and the recipient withdraws once,
    /// while a promise has a settlement of its own that no gift registry
    /// models. A near names an object this node itself exports, so handing it
    /// on is a re-export on the recipient's session rather than a handoff, and
    /// the node cannot do that: it holds export positions, not the objects
    /// behind them. A value that merely contains references, such as a list or
    /// a struct, would need each one introduced separately and reassembled.
    /// All three still break.
    fn giftableCapability(resolution: model.Resolution) ?model.Reference {
        const arg = switch (resolution) {
            .fulfill => |a| a,
            .@"break" => return null,
        };
        const reference = switch (arg) {
            .reference => |r| r,
            else => return null,
        };
        if (reference != .far or reference.far.kind != .object) return null;
        return reference;
    }

    /// Introduce a relayed capability to every recipient of `row` by handoff.
    ///
    /// The draft CapTP specification requires this: a message carrying a
    /// reference imported from another session must introduce it with a
    /// handoff, and a `desc:handoff-give` is legal wherever a Passable value
    /// is. `wire` is the capability as the *home* session names it, which is
    /// also how the exporter will see it in the deposit.
    ///
    /// Each recipient gets its own ticket, because a give is signed for one
    /// recipient's session key. A recipient whose ticket cannot be parked is
    /// broken rather than left pending; the rest still proceed.
    ///
    /// Infallible, by the contract `breakRecipients` carries and for a sharper
    /// reason: the caller has already consumed the home listener's fire, so an
    /// error returned from here would skip the proxy teardown and leave every
    /// recipient waiting on a promise nothing can settle a second time.
    fn giftRelayedCapability(self: *Node, row: *PromiseProxy, home: PeerId, wire: model.Reference) void {
        const token = self.enrollForeign(home, wire) catch {
            self.breakRecipients(row);
            return;
        };
        const far_id = token.far.import_position.int();
        for (row.recipients.items) |*r| {
            const slot: RelayedSlot = .{ .import_pos = r.import_pos, .row_id = r.row_id };
            const failure_reason = r.takeFailure();
            self.requestGiftId(r.peer, far_id, .{ .relayed = slot }, failure_reason) catch |err| switch (err) {
                error.OutOfMemory => self.breakRelayedOwned(r.peer, slot, failure_reason),
            };
        }
    }

    /// If `listener_export` on `home_peer` is a proxy home-listener, take
    /// ownership of `resolution` as the fire owner, settle every recipient,
    /// tear the proxy down, and return true. False leaves `resolution` with
    /// the caller.
    ///
    /// How a recipient is settled depends on what the home session named. A
    /// value that means the same everywhere is stored directly (moved for
    /// N=1, `materializeResolutionForStore` for the rest). A value naming a
    /// slot in the home conversation cannot be, so it takes the handoff branch
    /// first: a bare far object is introduced with a signed give, and every
    /// other such shape is broken.
    pub fn consumeProxyListenerFire(
        self: *Node,
        home_peer: PeerId,
        listener_export: u64,
        resolution: model.Resolution,
    ) !bool {
        const home_key = self.proxy_by_listener.get(.{ .home = home_peer, .listener_export = listener_export }) orelse return false;
        const row = self.promise_proxies.getPtr(home_key) orelse return false;
        std.debug.assert(row.recipients.items.len > 0);

        // A resolution naming a slot in the home conversation cannot be stored
        // on a recipient as it stands: the numbers mean what the home session
        // says they mean. Where the value is a plain capability, the protocol
        // says what to do instead of breaking — introduce it by handoff. The
        // home session is not at fault in either case, so nothing is refused
        // back at it.
        const owned_resolution = resolution;
        if (resolutionCarriesSessionScopedReference(owned_resolution)) {
            defer model.freeResolution(self.allocator, owned_resolution);
            if (giftableCapability(owned_resolution)) |wire| {
                self.giftRelayedCapability(row, home_key.home, wire);
            } else {
                self.breakRecipients(row);
            }
            self.removePromiseProxy(home_key);
            return true;
        }

        if (row.recipients.items.len == 1) {
            self.settleRecipient(&row.recipients.items[0], owned_resolution);
            self.removePromiseProxy(home_key);
            return true;
        }

        // Fire owner: materialize into each live recipient store, then free.
        defer model.freeResolution(self.allocator, owned_resolution);
        var index: usize = 0;
        while (index < row.recipients.items.len) : (index += 1) {
            const owned = model.materializeResolutionForStore(self.allocator, owned_resolution) catch {
                while (index < row.recipients.items.len) : (index += 1)
                    self.breakRecipient(&row.recipients.items[index]);
                break;
            };
            self.settleRecipient(&row.recipients.items[index], owned);
        }
        self.removePromiseProxy(home_key);
        return true;
    }

    /// Install home `op:listen` and insert an armed `PromiseProxy` row.
    fn armHomeProxy(self: *Node, home_key: ProxyHomeKey, wire_far: model.FarRef) !void {
        const hp = self.peer(home_key.home) orelse return error.PeerGone;
        if (!hp.sessionIsOpen()) return error.session_not_open;
        // Far listen target must already be a held import (enrollment).

        // Reserved before anything commits, so the flush push below cannot fail
        // after the row is armed.
        try self.reserveActions(1);
        try self.proxy_by_listener.ensureUnusedCapacity(self.allocator, 1);
        try self.promise_proxies.ensureUnusedCapacity(self.allocator, 1);
        try self.proxy_by_source.ensureUnusedCapacity(self.allocator, 1);
        const next = hp.session_state.captp_version == .next;
        const settling_target = if (next)
            hp.session_state.shortenedPromiseTarget(wire_far.import_position)
        else
            wire_far.import_position;
        const listener = try hp.session_state.allocateExport();
        errdefer hp.session_state.releaseUnsharedExport(listener);
        if (next) {
            if (!(try hp.session_state.claimPromiseSettlingListener(settling_target, listener, null))) {
                return error.UnexpectedMessage;
            }
        } else {
            try hp.session_state.installNodeSettlingResolver(listener);
        }
        errdefer if (next) {
            hp.session_state.abandonPromiseSettlingListener(settling_target);
        } else {
            std.debug.assert(hp.session_state.removeOutboundResolver(listener));
        };
        hp.send(.{
            .listen = .{
                .target = .{ .far = model.FarRef.promise(settling_target.int()) },
                // Project the mention from the authoritative slot (ADR-0080).
                .listener = session_mod.slot.toReference(hp.session_state.exportSlot(listener).?).?,
                .mode = .settling_only,
            },
        }) catch |err| {
            return err;
        };

        const listener_key: ProxyListenerKey = .{
            .home = home_key.home,
            .listener_export = listener.int(),
        };
        self.proxy_by_listener.putAssumeCapacity(listener_key, home_key);
        self.promise_proxies.putAssumeCapacity(home_key, .{
            .listener_export = listener.int(),
            .current_wire_pos = settling_target.int(),
        });
        self.proxy_by_source.putAssumeCapacity(.{
            .home = home_key.home,
            .wire_pos = settling_target.int(),
        }, home_key);

        // This runs while the *recipient's* session is being fed, so nothing
        // else will encode the home peer's outbound: without the flush the proxy
        // is armed and the partner is never asked.
        self.actions.pushReserved(.{ .flush = home_key.home });
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
    /// embedder resolves it itself. Foreign **promise** tokens are not gifted
    /// here — Host rewrites those through `proxyForeignPromiseFulfill`.
    pub fn interceptFulfilledRef(self: *Node, peer_id: PeerId, answer: u64, far_id: u64) !bool {
        const home = self.homeOf(far_id) orelse return false;
        if (home == peer_id) return false;
        if (self.foreignRoute(far_id)) |enrolled| {
            if (enrolled.reference == .far and enrolled.reference.far.kind == .promise) return false;
        }
        try self.requestGiftId(peer_id, far_id, .{ .answer = answer }, null);
        return true;
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
        far_id: u64,
        dest: PendingGift.Dest,
        failure_reason: ?[]u8,
    ) !void {
        try self.pending_gifts.ensureUnusedCapacity(self.allocator, 1);
        try self.reserveActions(1);
        const ticket = self.next_pending;
        self.pending_gifts.putAssumeCapacity(ticket, .{
            .recipient_peer = recipient_peer,
            .far_id = far_id,
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
                .peer_id = pending.recipient_peer,
                .answer = answer,
                .reason = .{ .static = reason },
            } }),
            .relayed => |slot| self.breakRelayedOwned(pending.recipient_peer, slot, pending.takeFailure()),
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
        // Resolve the exporter connection and the real reference to deposit there.
        // The claimed far is a foreign-import token (ADR-0069) that carries the real
        // `far(position)` to deposit; depositing the token itself would name an
        // export the exporter never made.
        const r = self.foreignRoute(pending.far_id) orelse {
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
        if (pending_view.dest == .answer) try self.reserveActions(1);
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

        const give = try self.mintGive(exporter_peer, gift_id, recipient_key, exporter_key, exporter_loc);
        defer self.allocator.free(give);

        // The transaction owns exporter preparation and both local queue
        // commits. A prepared session mutation never escapes for a caller to
        // stale; the two transports remain free to deliver either queue first.
        const destination: engine.handoff_gifter.GiveDestination = switch (dest) {
            .answer => |answer| .{ .answer = model.AnswerPosition.from(answer) },
            .relayed => |slot| .{ .relayed = .{
                .import_position = model.ImportPosition.from(slot.import_pos),
                .row_id = slot.row_id,
            } },
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
    fn mintGive(
        self: *Node,
        exporter_peer: PeerId,
        gift_id: []const u8,
        recipient_key: []const u8,
        exporter_key: []const u8,
        exporter_loc: []const u8,
    ) ![]u8 {
        // Signed by the gifter's key on the gifter–exporter session, whose
        // names this give carries (ADR-0097): the exporter verifies the
        // signature against the partner key it already proved on that
        // session, so any other key — including this node's durable one —
        // would not verify once sessions stop sharing a key.
        const secret = self.sessionSecret(exporter_peer);
        const gifter_side = try engine.handoff_recipient.sideName(secret.publicKey().asBytes());
        const exporter_side = try engine.handoff_recipient.sideName(exporter_key);
        const session = engine.handoff_recipient.sessionName(gifter_side, exporter_side);

        return engine.handoff_gifter.buildSignedGive(
            self.allocator,
            secret,
            recipient_key,
            exporter_loc,
            &session,
            &gifter_side,
            gift_id,
        );
    }
};
