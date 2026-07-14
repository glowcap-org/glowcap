//! `Node` — the sans-io cross-session handoff router (ADR-0066 / ADR-0079).
//!
//! A `Node` is the **router half** of Goblins' `mycapn`: the tables distinct from
//! a per-partner CapTP session. The multi-session CapTP **endpoint** (identity +
//! many partners + handoff) is `driver_core.Host`, which owns one `Node`. The
//! node owns stable identity (one retained session `seed`, reused for every
//! session it opens, so an exporter verifies a `desc:handoff-receive` against
//! one key), the set of `engine.Peer`s it routes between (keyed by an integer
//! `peer_id`), one shared
//! `engine.bootstrap.GiftRegistry` ([ADR-0056](../../../docs/decisions/adr/ADR-0056-vat-scoped-gift-registry.md))
//! so a deposit on a gifter session meets a withdraw on the recipient session,
//! and the two routing tables that make three-party handoff transparent: the
//! `redeemed` map from a synthetic far token to the exporter session that
//! hosts the real capability, and the `foreign_imports` map from a node-unique
//! token to the session a fetched capability lives on and the real wire
//! reference to address it there (ADR-0069).
//!
//! It is **sans-io**: it owns no sockets and no event loop. The embedder keeps
//! its own transport and async loop, registers each live session's peer with
//! the node, feeds the peer the bytes it reads, drains the bytes the peer
//! produces, and asks the node to route sends. Every route value is an integer
//! `peer_id` or owned bytes, so the router is pure data — which is exactly why it
//! lives here in the sync, no-I/O engine core (not the I/O-bearing driver layer)
//! instead of being reimplemented per binding, and why the sans-io
//! `libpancake_ocapn` archive can project it (ADR-0066). The vat (turn loop,
//! promise resolution, behavior dispatch) stays
//! above the node, in the embedder, because that is the host-scheduler adapter
//! (ADR-0066 records the boundary).
//!
//! The node owns each registered `engine.Peer` (heap-pinned, since a live
//! session borrows the peer's stable address) and frees it when the
//! session is removed or the node is torn down. The node itself must not
//! move once a session is registered: each registered peer points at the
//! node's shared gift registry by address (the C ABI heap-pins the node for
//! exactly this reason). The shared gift registry is
//! the node's; every peer it registers points at it, so a peer freed by the node
//! never frees the shared registry (the engine's `Peer.deinit` only frees a
//! peer's *own* registry).

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("mod.zig");
const session_mod = @import("session");

const ActionFifo = @import("action_fifo.zig").ActionFifo;

const crypto = foundation.crypto;

/// A connection id: the embedder's handle to one registered peer. Stable for the
/// life of the registration; freed ids are not reused within a node's life, so a
/// stale id fails closed rather than aliasing a later connection. A distinct
/// type (the `ImportPosition` pattern): the host tier also traffics in vow ids
/// and gift tokens, which are plain `u64`s, and the compiler refuses the mix-up
/// instead of a review catching it. Cross the ABI or index with `.int()`; mint
/// from an integer with `.from()`.
pub const PeerId = enum(u64) {
    _,

    pub fn from(n: u64) PeerId {
        return @enumFromInt(n);
    }

    pub fn int(self: PeerId) u64 {
        return @intFromEnum(self);
    }
};

/// Where a redeemed token routes: the exporter connection that hosts the real
/// capability, and the real exporter-side reference to swap in when forwarding.
/// The node owns `reference`.
const Route = struct {
    peer_id: PeerId,
    reference: model.Reference,
};

/// One registered connection: the peer plus who frees it. `registerPeer` mints
/// a node-owned peer (`owned = true`, freed on removal and at `deinit`);
/// `registerPeerOver` adopts a peer the embedder pins and frees itself
/// (`owned = false`, only unregistered here), which is how a peer-owning driver
/// like the completion loop joins the node without surrendering its inline peer.
const PeerSlot = struct {
    peer: *engine.Peer,
    owned: bool,
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

    /// The session's virtual inbound-answer floor, re-exported beside the token
    /// base so an embedder minting its own synthetic id range can assert, at
    /// comptime, that the reserved ranges stay disjoint without reaching into
    /// the session layer.
    pub const VIRTUAL_INBOUND_ANSWER_BASE: u64 = session_mod.VIRTUAL_INBOUND_ANSWER_BASE;

    allocator: std.mem.Allocator,
    /// The retained 32-byte node identity, reused for every CapTP session this
    /// node opens so an exporter verifies a `desc:handoff-receive` (and a gifter's
    /// `desc:handoff-give` signature) against the one key it saw.
    seed: [crypto.SEED_BYTES]u8,
    /// One deposited-gift / handoff-count authority shared across every peer this
    /// node registers, so an exporter's deposit (on the gifter session) and
    /// withdraw (on the recipient session) resolve against the same table.
    gifts: engine.bootstrap.GiftRegistry = .{},
    /// Registered CapTP sessions, indexed by `peer_id`: the node-owned, heap-pinned
    /// peer for each live session, whose stable address the embedder's
    /// `net.Connection` borrows. A removed slot holds null, so null is the entire
    /// liveness marker; a `peer_id` is never reused, so an index stays stable
    /// for the node's life.
    peers: std.ArrayListUnmanaged(?PeerSlot) = .empty,
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
    /// walking an outbound message to lower tokens (`Peer.lowering`): a node that
    /// never fetches a foreign capability leaves it false, so every send skips the
    /// walk for one bool load. The peer holds a `*const bool` into this field, so
    /// the node must not move once a session is registered — already required
    /// for the shared gift registry.
    foreign_active: bool = false,
    /// The next synthetic token a redeemed capability is enrolled under.
    next_token: u64 = REDEEMED_TOKEN_BASE,
    /// The serve step's exporter cache: a give's exporter locator (`ocapn://…`
    /// bytes, node-owned keys) to the live CapTP session already dialed for it, so
    /// a second redeem to one exporter reuses the session.
    exporters: std.StringHashMapUnmanaged(PeerId) = .empty,
    /// Dials in flight, keyed by the `PendingId` the `dial` action carried.
    pending_dials: std.AutoHashMapUnmanaged(PendingId, PendingDial) = .empty,
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
    /// The most recently popped action; its byte views stay valid until the
    /// next `nextAction`, which frees them.
    last_action: ?Action = null,
    /// The next pending-dial ticket.
    next_pending: PendingId = 0,

    /// A node bound to a caller-supplied identity `seed`, with empty tables. The
    /// seed is the node's stable session identity; draw it at the embedder's I/O
    /// boundary (the sans-io core never generates entropy) and pass it here.
    pub fn init(allocator: std.mem.Allocator, seed: [crypto.SEED_BYTES]u8) Node {
        return .{ .allocator = allocator, .seed = seed };
    }

    /// Tear down the node: free every registered peer, the routing tables (and
    /// the references the redeemed table owns), and the shared gift registry. A
    /// registered peer points at this node's shared registry, so freeing the peer
    /// never touches the registry; the node frees the registry last, after every
    /// peer is gone.
    pub fn deinit(self: *Node) void {
        for (self.peers.items) |slot| {
            if (slot) |s| {
                if (s.owned) {
                    s.peer.deinit();
                    self.allocator.destroy(s.peer);
                }
            }
        }
        self.peers.deinit(self.allocator);

        var route_it = self.redeemed.valueIterator();
        while (route_it.next()) |entry| model.freeReference(self.allocator, entry.reference);
        self.redeemed.deinit(self.allocator);

        var foreign_it = self.foreign_imports.valueIterator();
        while (foreign_it.next()) |entry| model.freeReference(self.allocator, entry.reference);
        self.foreign_imports.deinit(self.allocator);

        self.gifts.deinit(self.allocator);

        var exporter_keys = self.exporters.keyIterator();
        while (exporter_keys.next()) |key| self.allocator.free(key.*);
        self.exporters.deinit(self.allocator);

        var dial_it = self.pending_dials.valueIterator();
        while (dial_it.next()) |pending| {
            self.allocator.free(pending.locator);
            for (pending.waiters.items) |waiter| self.allocator.free(waiter.give);
            pending.waiters.deinit(self.allocator);
        }
        self.pending_dials.deinit(self.allocator);
        self.pending_withdraws.deinit(self.allocator);
        self.pending_gifts.deinit(self.allocator);

        var location_it = self.exporter_locations.valueIterator();
        while (location_it.next()) |location| self.allocator.free(location.*);
        self.exporter_locations.deinit(self.allocator);

        if (self.last_action) |last| self.freeAction(last);
        for (self.actions.unpopped()) |action| self.freeAction(action);
        self.actions.deinit(self.allocator);
    }

    /// Register a fresh negotiating peer bound to this node's shared gift
    /// registry and return its `peer_id`. The embedder builds its live
    /// `net.Connection` over `node.peer(peer_id)` and pumps it; the peer's
    /// address is stable for the registration's life. The peer is negotiating, so
    /// the embedder completes the keyed `op:start-session` handshake (it owns the
    /// socket and the entropy) signing with `node.seed` for an identity the
    /// exporter will recognize across CapTP sessions. `options` are the same
    /// knobs `Peer.initNegotiatingWith` takes — applied at construction so the
    /// host never pokes session tables after the fact.
    pub fn registerPeer(self: *Node, options: engine.Peer.NegotiatingOptions) !PeerId {
        const new_peer = try self.allocator.create(engine.Peer);
        errdefer self.allocator.destroy(new_peer);
        new_peer.* = engine.Peer.initNegotiatingWith(self.allocator, options);
        new_peer.shared_gift_registry = &self.gifts;

        const id: PeerId = .from(self.peers.items.len);
        new_peer.lowering = self.lowering(id);
        try self.peers.append(self.allocator, .{ .peer = new_peer, .owned = true });
        return id;
    }

    /// Register a connection over a peer the embedder already owns and pins at a
    /// stable address, joining it to the node's routing and shared gift registry
    /// without the node taking ownership. `removePeer` and `deinit` unregister
    /// the slot but never free `peer`; the embedder frees it. This is how a
    /// peer-owning driver — the completion loop, whose fixed-slot `peers` hold
    /// each peer inline — puts its connections under one node so a redeemed token
    /// routes to them and a served reply can originate a gift. `peer` must
    /// outlive its registration.
    pub fn registerPeerOver(self: *Node, adopted: *engine.Peer) !PeerId {
        adopted.shared_gift_registry = &self.gifts;
        const id: PeerId = .from(self.peers.items.len);
        adopted.lowering = self.lowering(id);
        try self.peers.append(self.allocator, .{ .peer = adopted, .owned = false });
        return id;
    }

    /// Remove a registered CapTP session: free its peer and mark the slot dead. A
    /// later route to a redeemed token whose exporter was this session fails
    /// closed (the peer is gone), rather than forwarding onto a dead socket. The
    /// `peer_id` is never reused.
    ///
    /// The exporter cache, pending withdraws, and pending gifts naming this
    /// session are swept below. The `redeemed` routes are deliberately *not*:
    /// a route's `peer_id` going dead is exactly what `routeReference` reads to
    /// fail the token closed (its `peerAt` returns null). Removing the row would
    /// instead make the synthetic token fall through `route`'s "not a token I
    /// hold" branch and get sent to a partner as an ordinary far — a meaningless
    /// high id. The dead rows are reclaimed at `deinit`.
    pub fn removePeer(self: *Node, peer_id: PeerId) void {
        if (peer_id.int() >= self.peers.items.len) return;
        const slot = self.peers.items[peer_id.int()] orelse return;
        // Only a node-owned peer is freed here; an adopted (`registerPeerOver`)
        // peer is the embedder's to free, so the node only unregisters the slot.
        if (slot.owned) {
            slot.peer.deinit();
            self.allocator.destroy(slot.peer);
        }
        self.peers.items[peer_id.int()] = null;
        if (self.exporter_locations.fetchRemove(peer_id)) |prev| self.allocator.free(prev.value);

        // Evict the exporter-cache rows naming this CapTP session, so a later
        // give for the same exporter dials a fresh session instead of
        // failing against the dead one forever.
        var evicted = true;
        while (evicted) {
            evicted = false;
            var exporter_it = self.exporters.iterator();
            while (exporter_it.next()) |entry| {
                if (entry.value_ptr.* == peer_id) {
                    const key = entry.key_ptr.*;
                    self.exporters.removeByPtr(entry.key_ptr);
                    self.allocator.free(key);
                    evicted = true;
                    break; // removal invalidates the iterator; rescan
                }
            }
        }

        // Break every withdraw still pending on this session: its resolve
        // can never arrive, so the recipient's answer fails closed instead of
        // hanging. Best-effort — an allocation failure during teardown queues
        // nothing, and the recipient's own disconnect handling breaks the vow.
        var swept = true;
        while (swept) {
            swept = false;
            var withdraw_it = self.pending_withdraws.iterator();
            while (withdraw_it.next()) |entry| {
                if (entry.key_ptr.peer_id == peer_id) {
                    const pending = entry.value_ptr.*;
                    self.pending_withdraws.removeByPtr(entry.key_ptr);
                    self.queueFail(pending.recipient_peer, pending.answer, "handoff redeem failed: exporter connection closed") catch {};
                    swept = true;
                    break;
                }
            }
        }

        // A claimed gifter origination whose recipient died settles nowhere;
        // retire its ticket so a late provideGiftId is a clean no-op.
        var retired = true;
        while (retired) {
            retired = false;
            var gift_it = self.pending_gifts.iterator();
            while (gift_it.next()) |entry| {
                if (entry.value_ptr.recipient_peer == peer_id) {
                    self.pending_gifts.removeByPtr(entry.key_ptr);
                    retired = true;
                    break;
                }
            }
        }

        // Reclaim the foreign-import enrollments homed on this CapTP session
        // (ADR-0069): once the home is gone the token can never re-gift, so a
        // long-running broker does not accumulate stale routing rows.
        var reclaimed = true;
        while (reclaimed) {
            reclaimed = false;
            var foreign_it = self.foreign_imports.iterator();
            while (foreign_it.next()) |entry| {
                if (entry.value_ptr.peer_id == peer_id) {
                    model.freeReference(self.allocator, entry.value_ptr.reference);
                    self.foreign_imports.removeByPtr(entry.key_ptr);
                    reclaimed = true;
                    break;
                }
            }
        }
    }

    /// The node-owned peer for `peer_id`, or null when the id names no live
    /// connection. The embedder pumps I/O through this peer; the node routes
    /// across them.
    pub fn peer(self: *Node, peer_id: PeerId) ?*engine.Peer {
        return self.peerAt(peer_id);
    }

    fn peerAt(self: *Node, peer_id: PeerId) ?*engine.Peer {
        if (peer_id.int() >= self.peers.items.len) return null;
        const slot = self.peers.items[peer_id.int()] orelse return null;
        return slot.peer;
    }

    // ── Redeemed-token routing (the recipient half) ──────────────────────────

    /// Enroll a redeemed capability under a fresh synthetic token and return the
    /// far reference the application receives, indistinguishable from any other
    /// far capability a partner handed back. A later `routeReference` of that
    /// reference forwards to `exporter_peer` with `reference` (the real
    /// exporter-side ref) swapped in. The node adopts a clone of `reference`; the
    /// caller keeps its own. The caller reserves one slot in `redeemed` first, so
    /// the only fallible step here is the clone — which commits nothing on
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
        const id = switch (reference) {
            .far => |far| far.import_position.int(),
            else => return null,
        };
        if (id < REDEEMED_TOKEN_BASE) return null;
        if (self.redeemed.get(id)) |r| return r;
        // A foreign-import token (ADR-0069) routes to its home connection,
        // addressed with the real wire import — the same swap a redeemed token
        // gets, so a send to a fetched capability reaches its exporter.
        return self.foreign_imports.get(id);
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
        try self.foreign_imports.ensureUnusedCapacity(self.allocator, 1);
        const token = self.next_token;
        self.foreign_imports.putAssumeCapacity(token, .{ .peer_id = home, .reference = wire });
        self.next_token += 1;
        self.foreign_active = true;
        return .{ .far = model.FarRef.object(token) };
    }

    /// The connection a fetched capability's `far_id` lives on, or null when the
    /// node holds no enrollment for it (a redeemed token, an ordinary wire import
    /// the node never fetched, or an id the node never minted). This is the home
    /// the gifter-side interceptor originates a handoff toward. A fetched
    /// capability's identity is always a token, so only the token enrollment is
    /// consulted (ADR-0069).
    fn homeOf(self: *Node, far_id: u64) ?PeerId {
        if (self.foreign_imports.get(far_id)) |r| return r.peer_id;
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
        const id = switch (reference) {
            .far => |far| far.import_position.int(),
            else => return false,
        };
        if (id < REDEEMED_TOKEN_BASE) return false;
        // A foreign-import token is foreign only away from its home. A redeemed
        // token has no wire home and is foreign everywhere; an unknown high id
        // fails closed.
        if (self.foreign_imports.get(id)) |r| return r.peer_id != default_peer;
        return true;
    }

    /// Lower `reference` to the wire reference it names on `peer_id`, for the one
    /// place every outbound message is emitted (`Peer.send`, ADR-0069). This is
    /// the single chokepoint that keeps a node-local token off the wire in *every*
    /// position — target, argument, forwarded target, resolution — instead of one
    /// path at a time. The peer reaches it through the `engine.Lowering` hook this
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
        const id = switch (reference) {
            .far => |far| far.import_position.int(),
            else => return reference,
        };
        if (id < REDEEMED_TOKEN_BASE) return reference;
        const r = self.route(reference) orelse return error.TokenNotLiftable;
        if (r.peer_id != peer_id) return error.TokenNotLiftable;
        return r.reference;
    }

    /// The lowering hook for the peer registered as `peer_id`, installed on it at
    /// registration so `Peer.send` swaps tokens to wire references (ADR-0069). It
    /// carries a `*const bool` into `foreign_active` as its gate, so the peer skips
    /// the walk entirely until this node fetches its first foreign capability.
    fn lowering(self: *Node, peer_id: PeerId) engine.Lowering {
        return .{
            .ctx = self,
            .peer_id = peer_id,
            .active = &self.foreign_active,
            .lower_fn = lowerThunk,
        };
    }

    fn lowerThunk(ctx: *anyopaque, peer_id: PeerId, reference: model.Reference) engine.LoweringError!model.Reference {
        const self: *Node = @ptrCast(@alignCast(ctx));
        return self.lowerForConn(peer_id, reference);
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
        if (target == .far and target.far.import_position.int() >= REDEEMED_TOKEN_BASE) {
            return self.routeToken(target.far.import_position.int());
        }
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

    // ── Recipient withdraw (the redeem half) ─────────────────────────────────

    /// The node's session secret, derived from its retained `seed`. Every
    /// connection the embedder opens for this node signs its keyed
    /// `op:start-session` with this key, so an exporter sees one identity across
    /// the introducer and the direct connection and verifies a
    /// `desc:handoff-receive` against it.
    pub fn secretKey(self: *const Node) crypto.SecretKey {
        return crypto.SecretKey.fromSeed(self.seed);
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

    /// One in-flight exporter dial, possibly carrying several redeems for the
    /// same exporter (a second give for one locator joins the waiters instead
    /// of dialing twice). The node owns `locator`.
    const PendingDial = struct {
        locator: []u8,
        waiters: std.ArrayListUnmanaged(Waiter) = .empty,
    };

    /// One withdraw awaiting its resolution on an exporter connection, keyed
    /// by `(exporter conn, withdraw answer)`.
    const PendingWithdraw = struct {
        recipient_peer: PeerId,
        answer: u64,
    };

    /// One claimed gifter origination awaiting its host-drawn gift id, keyed
    /// by the ticket the `need_gift_id` action carried.
    const PendingGift = struct {
        recipient_peer: PeerId,
        answer: u64,
        far_id: u64,
    };

    const WithdrawKey = struct {
        peer_id: PeerId,
        answer: u64,
    };

    /// What the embedder must do next. Byte views are node-owned and valid
    /// until the next `nextAction` call (or node teardown); copy what outlives
    /// that.
    pub const Action = union(enum) {
        /// Dial the exporter at `locator` (an `ocapn://…` URI) with the node's
        /// retained identity, register the CapTP session, open the keyed session,
        /// then feed `exporterDialed(pending, peer_id)` — or
        /// `dialFailed(pending, reason)` if any step refuses.
        dial: struct { pending: PendingId, locator: []const u8 },
        /// Pump this CapTP session's outbound queue to the wire.
        flush: PeerId,
        /// Settle the application answer `answer` on `peer_id`: the redeemed
        /// capability is enrolled and `token` is the ordinary far id the
        /// application receives.
        settle: struct { peer_id: PeerId, answer: u64, token: u64 },
        /// Break the application answer `answer` on `peer_id` with `reason`.
        fail: struct { peer_id: PeerId, answer: u64, reason: []const u8 },
        /// Draw 32 bytes of gift-id entropy and feed them back through
        /// `provideGiftId(ticket, bytes)`. Entropy is a host effect like
        /// dialing: the sans-io node never generates it, and requesting it
        /// only when a reply actually becomes a gift keeps the ordinary reply
        /// path free of speculative draws.
        need_gift_id: struct { ticket: u64 },
    };

    fn freeAction(self: *Node, action: Action) void {
        switch (action) {
            .dial => |d| self.allocator.free(d.locator),
            .fail => |f| self.allocator.free(f.reason),
            .flush, .settle, .need_gift_id => {},
        }
    }

    fn queueAction(self: *Node, action: Action) !void {
        try self.actions.push(self.allocator, action);
    }

    /// Queue a fail action carrying an owned copy of `reason`.
    fn queueFail(self: *Node, peer_id: PeerId, answer: u64, reason: []const u8) !void {
        const owned = try self.allocator.dupe(u8, reason);
        errdefer self.allocator.free(owned);
        try self.queueAction(.{ .fail = .{ .peer_id = peer_id, .answer = answer, .reason = owned } });
    }

    /// Pop the next queued action. The previous action's byte views are freed
    /// here, so a popped action is valid until the next call. Null when no
    /// action is pending.
    pub fn nextAction(self: *Node) ?Action {
        if (self.last_action) |last| {
            self.freeAction(last);
            self.last_action = null;
        }
        const action = self.actions.pop() orelse return null;
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
        if (self.exporters.get(exporter_locator)) |exporter_peer| {
            return self.beginWithdraw(exporter_peer, recipient_peer, answer, give);
        }

        const owned_give = try self.allocator.dupe(u8, give);
        errdefer self.allocator.free(owned_give);
        const waiter: Waiter = .{ .recipient_peer = recipient_peer, .answer = answer, .give = owned_give };

        // A dial already in flight for this exporter adopts the redeem instead
        // of opening a second connection.
        var it = self.pending_dials.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.locator, exporter_locator)) {
                try entry.value_ptr.waiters.append(self.allocator, waiter);
                return;
            }
        }

        // Every fallible step happens before any ownership transfer, so an
        // allocation failure can never leave the pending table owning bytes an
        // armed errdefer also frees (the memory rule: exactly one free on
        // every path).
        try self.pending_dials.ensureUnusedCapacity(self.allocator, 1);
        try self.actions.reserve(self.allocator, 1);
        const locator_owned = try self.allocator.dupe(u8, exporter_locator);
        errdefer self.allocator.free(locator_owned);
        // The action carries its own copy so the embedder's view survives the
        // pending entry being consumed by `exporterDialed` mid-drain.
        const action_locator = try self.allocator.dupe(u8, exporter_locator);
        errdefer self.allocator.free(action_locator);
        var pending: PendingDial = .{ .locator = locator_owned };
        errdefer pending.waiters.deinit(self.allocator);
        try pending.waiters.append(self.allocator, waiter);

        const pending_id = self.next_pending;
        self.pending_dials.putAssumeCapacity(pending_id, pending);
        self.next_pending += 1;
        self.actions.pushReserved(.{ .dial = .{ .pending = pending_id, .locator = action_locator } });
    }

    /// Send one withdraw on a live exporter connection and record it pending.
    /// `give` is borrowed. The `desc:handoff-receive` is signed by the node's
    /// retained identity (`secretKey`), so the exporter verifies it against the
    /// one key it saw across the introducer and the direct connection. The
    /// tracking row and the flush action are reserved before the withdraw is
    /// queued: once the withdraw is on the wire, failing to track it would let
    /// its resolve surface to the application as an answer it never asked.
    fn beginWithdraw(self: *Node, exporter_peer: PeerId, recipient_peer: PeerId, answer: u64, give: []const u8) !void {
        const conn = self.peerAt(exporter_peer) orelse
            return self.queueFail(recipient_peer, answer, "handoff redeem failed: exporter connection is gone");
        try self.pending_withdraws.ensureUnusedCapacity(self.allocator, 1);
        try self.actions.reserve(self.allocator, 1);
        const withdraw_answer = conn.allocateAnswer();
        conn.sendWithdrawGift(self.secretKey(), give, model.AnswerPosition.from(withdraw_answer)) catch |err| switch (err) {
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
        self.actions.pushReserved(.{ .flush = exporter_peer });
    }

    /// Report a dial's success: the exporter at `pending`'s locator is
    /// registered as `exporter_peer` with an open keyed session. The node
    /// caches the exporter and withdraws every waiting give on it. An unknown
    /// `pending` is a no-op (the ticket already settled).
    pub fn exporterDialed(self: *Node, pending: PendingId, exporter_peer: PeerId) !void {
        var entry = (self.pending_dials.fetchRemove(pending) orelse return).value;
        defer {
            for (entry.waiters.items) |waiter| self.allocator.free(waiter.give);
            entry.waiters.deinit(self.allocator);
        }
        // The cache adopts the locator bytes; an already-cached locator (a
        // duplicate dial the embedder raced) keeps the first row.
        const cached = self.exporters.getOrPut(self.allocator, entry.locator) catch |err| {
            self.allocator.free(entry.locator);
            return err;
        };
        if (cached.found_existing) {
            self.allocator.free(entry.locator);
        } else {
            cached.value_ptr.* = exporter_peer;
        }
        // Each `beginWithdraw` self-reserves its own node-table rows, so the
        // node tables never fail a waiter mid-batch. The one fallible step it
        // cannot reserve away is the peer-side `sendWithdrawGift` allocation: a
        // mid-batch OOM there returns the error with the head waiters' withdraws
        // already on the wire and the tail waiters dropped (their answers hang,
        // to be broken by the recipient's own disconnect handling). The defer
        // frees every waiter's give on every path, so this is best-effort, not
        // leaky — the same posture `removePeer` documents.
        for (entry.waiters.items) |waiter| {
            try self.beginWithdraw(exporter_peer, waiter.recipient_peer, waiter.answer, waiter.give);
        }
    }

    /// Report a dial's failure: every redeem waiting on `pending` breaks with
    /// `reason`. An unknown `pending` is a no-op.
    pub fn dialFailed(self: *Node, pending: PendingId, reason: []const u8) !void {
        var entry = (self.pending_dials.fetchRemove(pending) orelse return).value;
        defer {
            self.allocator.free(entry.locator);
            for (entry.waiters.items) |waiter| self.allocator.free(waiter.give);
            entry.waiters.deinit(self.allocator);
        }
        var buf: [256]u8 = undefined;
        const message = std.fmt.bufPrint(&buf, "handoff redeem failed: {s}", .{reason}) catch "handoff redeem failed";
        for (entry.waiters.items) |waiter| {
            try self.queueFail(waiter.recipient_peer, waiter.answer, message);
        }
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
        switch (outcome) {
            .far => |far_id| {
                // Reserve both tables before the enroll clones, so the enroll
                // (row install + token bump) and the settle queue are one
                // all-or-nothing step: an OOM can only fire before anything
                // commits, and the retriable withdraw never strands a token.
                try self.redeemed.ensureUnusedCapacity(self.allocator, 1);
                try self.actions.reserve(self.allocator, 1);
                const token = try self.enrollRedeemed(peer_id, .{ .far = model.FarRef.object(far_id) });
                self.actions.pushReserved(.{ .settle = .{
                    .peer_id = pending.recipient_peer,
                    .answer = pending.answer,
                    .token = token.far.import_position.int(),
                } });
            },
            .broken => |reason| {
                var buf: [256]u8 = undefined;
                const message = std.fmt.bufPrint(&buf, "handoff redeem failed: {s}", .{reason}) catch "handoff redeem failed";
                try self.queueFail(pending.recipient_peer, pending.answer, message);
            },
            .not_capability => {
                try self.queueFail(pending.recipient_peer, pending.answer, "withdraw-gift did not resolve to a capability");
            },
        }
        std.debug.assert(self.pending_withdraws.remove(key));
        return true;
    }

    /// Record the verbatim exporter locator to embed in gives whose exporter
    /// is `peer_id` — an exporter reachable only by a dial hint (an iroh
    /// endpoint's direct addresses), where the session's own signed location
    /// record is not dialable. `location` is borrowed (the node copies it);
    /// empty clears the override back to the session record.
    pub fn setExporterLocation(self: *Node, peer_id: PeerId, location: ?model.PeerLocator) !void {
        if (self.exporter_locations.fetchRemove(peer_id)) |prev| self.allocator.free(prev.value);
        const loc = location orelse return;
        // Canonical Syrup locator-record bytes — the give embeds these, so a URI
        // (or any other non-record spelling) can never reach the wire from here.
        const owned = try engine.encodePeerLocatorRecord(self.allocator, loc);
        errdefer self.allocator.free(owned);
        try self.exporter_locations.put(self.allocator, peer_id, owned);
    }

    /// The recorded give-location override for `peer_id`, or empty (use the
    /// exporter session's own signed record).
    fn exporterLocation(self: *const Node, peer_id: PeerId) []const u8 {
        return self.exporter_locations.get(peer_id) orelse "";
    }

    /// Gifter intercept: the application answer `answer` on `peer_id`
    /// fulfilled to the far capability `far_id`. When that capability's
    /// recorded home is another connection, the node claims the reply and
    /// queues a `need_gift_id` action — entropy is a host effect, requested
    /// only now that the reply is actually becoming a gift — and returns true
    /// (the embedder must not also send a plain resolve; it draws 32 bytes and
    /// feeds `provideGiftId`). False means the reply is ordinary and the
    /// embedder resolves it itself.
    pub fn interceptFulfilledRef(self: *Node, peer_id: PeerId, answer: u64, far_id: u64) !bool {
        const home = self.homeOf(far_id) orelse return false;
        if (home == peer_id) return false;
        // Reserve the ticket table and the action queue before either commits,
        // so the row install and the `need_gift_id` queue are one all-or-nothing
        // step: an OOM fires before anything commits and never orphans a ticket
        // whose action the embedder never sees.
        try self.pending_gifts.ensureUnusedCapacity(self.allocator, 1);
        try self.actions.reserve(self.allocator, 1);
        const ticket = self.next_pending;
        self.pending_gifts.putAssumeCapacity(ticket, .{
            .recipient_peer = peer_id,
            .answer = answer,
            .far_id = far_id,
        });
        self.next_pending += 1;
        self.actions.pushReserved(.{ .need_gift_id = .{ .ticket = ticket } });
        return true;
    }

    /// Answer a `need_gift_id` action with the host-drawn `gift_id`: the node
    /// originates the claimed handoff (deposit on the exporter, signed give
    /// resolving the claimed answer, using any `setExporterLocation` override
    /// recorded for the exporter) and queues the two flushes — exporter first,
    /// so the deposit is on the wire before the recipient dials in to
    /// withdraw. A failed origination breaks the claimed answer instead. An
    /// unknown `ticket` is a no-op. `gift_id` is borrowed.
    pub fn provideGiftId(self: *Node, ticket: u64, gift_id: []const u8) !void {
        const pending = (self.pending_gifts.fetchRemove(ticket) orelse return).value;
        // Resolve the exporter connection and the real reference to deposit there.
        // The claimed far is a foreign-import token (ADR-0069) that carries the real
        // `far(position)` to deposit; depositing the token itself would name an
        // export the exporter never made.
        const r = self.foreign_imports.get(pending.far_id) orelse
            return self.queueFail(pending.recipient_peer, pending.answer, "handoff origination failed: home connection is gone");
        const home = r.peer_id;
        const gifted = r.reference;
        self.originateGive(
            pending.recipient_peer,
            home,
            gifted,
            gift_id,
            pending.answer,
            self.exporterLocation(home),
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                var buf: [128]u8 = undefined;
                const reason = std.fmt.bufPrint(&buf, "handoff origination failed: {s}", .{@errorName(err)}) catch "handoff origination failed";
                return self.queueFail(pending.recipient_peer, pending.answer, reason);
            },
        };
        try self.queueAction(.{ .flush = home });
        try self.queueAction(.{ .flush = pending.recipient_peer });
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
    /// The embedder flushes both connections, exporter first: the deposit must be
    /// on the wire before the recipient dials in to withdraw. Both sessions must
    /// be open keyed sessions (the recipient key addresses the give; the exporter
    /// key names the gifter↔exporter session the give is signed under).
    fn originateGive(
        self: *Node,
        recipient_peer: PeerId,
        exporter_peer: PeerId,
        gifted: model.Reference,
        gift_id: []const u8,
        answer: u64,
        exporter_location: []const u8,
    ) !void {
        const rp = self.peerAt(recipient_peer) orelse return error.UnknownConnection;
        const ep = self.peerAt(exporter_peer) orelse return error.UnknownConnection;

        const recipient_key = rp.session_state.partnerSessionKey() orelse return error.NoRecipientKey;
        const exporter_key = ep.session_state.partnerSessionKey() orelse return error.NoExporterKey;
        const exporter_loc = if (exporter_location.len != 0)
            exporter_location
        else
            ep.session_state.partnerLocatorRaw() orelse return error.NoExporterLocator;

        // Deposit on the exporter first (fire-and-forget): the exporter records
        // the gift so a `withdraw-gift` the recipient sends later resolves.
        try ep.sendDepositGift(gift_id, gifted);

        const secret = self.secretKey();
        const gifter_side = try engine.handoff_recipient.sideName(secret.publicKey().asBytes());
        const exporter_side = try engine.handoff_recipient.sideName(exporter_key);
        const session = engine.handoff_recipient.sessionName(gifter_side, exporter_side);

        const give = try engine.handoff_gifter.buildSignedGive(
            self.allocator,
            secret,
            recipient_key,
            exporter_loc,
            &session,
            &gifter_side,
            gift_id,
        );
        defer self.allocator.free(give);

        try rp.sendResolveHandoffGive(model.AnswerPosition.from(answer), give);
    }
};
