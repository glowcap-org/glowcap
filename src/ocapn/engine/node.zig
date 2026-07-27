//! `Node` — the sans-io cross-session handoff router (ADR-0066 / ADR-0079).
//!
//! A `Node` is the **router half** of Goblins' `mycapn`: the tables distinct from
//! a per-partner CapTP session. The multi-session CapTP **endpoint** (identity +
//! many partners + handoff) is `driver_core.Host`, which owns one `Node`. The
//! node owns stable identity (one retained session `seed`, reused for every
//! session it opens, so an exporter verifies a `desc:handoff-receive` against
//! one key), the set of `engine.Peer`s it routes between (keyed by an integer
//! `peer_id`), one shared
//! `engine.bootstrap.GiftRegistry` (ADR-0056)
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

/// One recipient for an introducing-session foreign-promise proxy (ADR-0009).
/// `row_id` is stamped at enroll so a GC/re-register between enroll and fire
/// cannot satisfy a stale relay (same contract as `recordRelayedResolution`).
const ProxyRecipient = struct {
    peer: PeerId,
    import_pos: u64,
    row_id: u64,
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
    recipients: std.ArrayListUnmanaged(ProxyRecipient) = .empty,

    fn deinit(self: *PromiseProxy, allocator: std.mem.Allocator) void {
        self.recipients.deinit(allocator);
    }
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

    allocator: std.mem.Allocator,
    /// The node's session identity, expanded once at construction and reused for
    /// every CapTP session this node opens, so an exporter verifies a
    /// `desc:handoff-receive` (and a gifter's `desc:handoff-give` signature)
    /// against the one key it saw. Expanding it is a scalar multiplication and
    /// the connect path asks for it twice per dial, so it is held rather than
    /// derived. `SecretKey.seed` recovers the 32 bytes it was built from; they
    /// are not stored twice.
    secret: crypto.SecretKey,
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
    /// The serve step's exporter cache: canonical peer-identity URI → live
    /// CapTP session already dialed for that exporter (`uri.canonicalPeerIdentityUri`),
    /// so a second redeem reuses the session even when the give's spelling or
    /// hints differ.
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

    /// A node bound to a caller-supplied identity `seed`, with empty tables. The
    /// seed is the node's stable session identity; draw it at the embedder's I/O
    /// boundary (the sans-io core never generates entropy) and pass it here.
    pub fn init(allocator: std.mem.Allocator, seed: [crypto.SEED_BYTES]u8) Node {
        return .{ .allocator = allocator, .secret = crypto.SecretKey.fromSeed(seed) };
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
            self.freePendingDialBytes(pending);
            for (pending.waiters.items) |waiter| self.allocator.free(waiter.give);
            pending.waiters.deinit(self.allocator);
        }
        self.pending_dials.deinit(self.allocator);
        // Keys alias pending identity URIs freed above.
        self.pending_dial_by_identity.deinit(self.allocator);
        self.pending_withdraws.deinit(self.allocator);
        self.pending_gifts.deinit(self.allocator);

        var location_it = self.exporter_locations.valueIterator();
        while (location_it.next()) |location| self.allocator.free(location.*);
        self.exporter_locations.deinit(self.allocator);

        if (self.last_action) |last| self.freeAction(last);
        for (self.actions.unpopped()) |action| self.freeAction(action);
        self.actions.deinit(self.allocator);

        var proxy_it = self.promise_proxies.valueIterator();
        while (proxy_it.next()) |proxy| proxy.deinit(self.allocator);
        self.promise_proxies.deinit(self.allocator);
        self.proxy_by_listener.deinit(self.allocator);
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
        // Guarded < len (a usize), so the id fits the index type; the cast keeps
        // the slice access valid on a 32-bit target (wasm32, ADR-0070).
        const idx: usize = @intCast(peer_id.int());
        const slot = self.peers.items[idx] orelse return;
        // Only a node-owned peer is freed here; an adopted (`registerPeerOver`)
        // peer is the embedder's to free, so the node only unregisters the slot.
        if (slot.owned) {
            slot.peer.deinit();
            self.allocator.destroy(slot.peer);
        }
        self.peers.items[idx] = null;
        if (self.exporter_locations.fetchRemove(peer_id)) |prev| self.allocator.free(prev.value);

        // Evict the exporter-cache rows naming this CapTP session, so a later
        // give for the same exporter dials a fresh session instead of
        // failing against the dead one forever.
        self.removeRowsForPeer(&self.exporters, peer_id, struct {
            fn match(_: []const u8, home: PeerId, dying: PeerId) bool {
                return home == dying;
            }
        }.match, struct {
            fn cleanup(node: *Node, key: []const u8, _: PeerId) void {
                node.allocator.free(key);
            }
        }.cleanup);

        // Break every withdraw still pending on this session: its resolve
        // can never arrive, so the recipient's answer fails closed instead of
        // hanging. Best-effort — an allocation failure during teardown queues
        // nothing, and the recipient's own disconnect handling breaks the vow.
        self.removeRowsForPeer(&self.pending_withdraws, peer_id, struct {
            fn match(key: WithdrawKey, _: PendingWithdraw, dying: PeerId) bool {
                return key.peer_id == dying;
            }
        }.match, struct {
            fn cleanup(node: *Node, _: WithdrawKey, pending: PendingWithdraw) void {
                node.queueFail(pending.recipient_peer, pending.answer, "handoff redeem failed: exporter connection closed") catch {};
            }
        }.cleanup);

        // A claimed gifter origination whose recipient died settles nowhere;
        // retire its ticket so a late provideGiftId is a clean no-op.
        self.removeRowsForPeer(&self.pending_gifts, peer_id, struct {
            fn match(_: u64, gift: PendingGift, dying: PeerId) bool {
                return gift.recipient_peer == dying;
            }
        }.match, struct {
            fn cleanup(_: *Node, _: u64, _: PendingGift) void {}
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

        // Drop promise proxies whose home or recipient peer died
        // recipient peer so a later home fire cannot relay onto a gone session.
        self.sweepPromiseProxiesForPeer(peer_id);
    }

    /// Remove every row of `map` tied to the dying `peer_id` in one O(n) pass:
    /// collect the matching keys, then remove and clean up each. This is the
    /// shape `sweepPromiseProxiesForPeer` uses; restarting the scan after each
    /// removal is O(n·k) and repeats the same flag-and-break spine at every
    /// teardown site. `match` reads a row against the dying peer; `cleanup` runs
    /// on the removed key and value to free its owned bytes or break its pending
    /// vow. A teardown allocation failure drops that key from the sweep — the
    /// row is reclaimed at `deinit` — rather than failing the teardown.
    fn removeRowsForPeer(
        self: *Node,
        map: anytype,
        peer_id: PeerId,
        comptime match: anytype,
        comptime cleanup: anytype,
    ) void {
        const Key = @FieldType(@TypeOf(map.*).KV, "key");
        var doomed: std.ArrayListUnmanaged(Key) = .empty;
        defer doomed.deinit(self.allocator);
        var it = map.iterator();
        while (it.next()) |entry| {
            if (match(entry.key_ptr.*, entry.value_ptr.*, peer_id)) {
                doomed.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }
        for (doomed.items) |key| {
            if (map.fetchRemove(key)) |kv| cleanup(self, kv.key, kv.value);
        }
    }

    /// The reserved token id `reference` names (ADR-0066), or null for any
    /// reference outside the reserved range: an ordinary far import, a near, a
    /// promise, a sturdyref. This is the one definition of "this far id is a node
    /// token" that every routing and lowering entry shares, so the reserved-range
    /// boundary is a single fact rather than four hand-inlined compares.
    fn tokenIdOf(reference: model.Reference) ?u64 {
        const id = switch (reference) {
            .far => |far| far.import_position.int(),
            else => return null,
        };
        return if (id >= REDEEMED_TOKEN_BASE) id else null;
    }

    /// The node-owned peer for `peer_id`, or null when the id names no live
    /// connection. The embedder pumps I/O through this peer; the node routes
    /// across them.
    pub fn peer(self: *Node, peer_id: PeerId) ?*engine.Peer {
        return self.peerAt(peer_id);
    }

    fn peerAt(self: *Node, peer_id: PeerId) ?*engine.Peer {
        if (peer_id.int() >= self.peers.items.len) return null;
        // Guarded < len (a usize): safe to narrow for indexing on wasm32.
        const idx: usize = @intCast(peer_id.int());
        const slot = self.peers.items[idx] orelse return null;
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
        return self.foreign_imports.get(id);
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
        try self.foreign_imports.ensureUnusedCapacity(self.allocator, 1);
        const token = self.next_token;
        self.foreign_imports.putAssumeCapacity(token, .{ .peer_id = home, .reference = wire });
        self.next_token += 1;
        self.foreign_active = true;
        const kind = switch (wire) {
            .far => |far| far.kind,
            else => .object,
        };
        return .{ .far = .{ .import_position = .from(token), .kind = kind } };
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
        const id = tokenIdOf(reference) orelse return false;
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
        if (tokenIdOf(reference) == null) return reference;
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

    // ── Recipient withdraw (the redeem half) ─────────────────────────────────

    /// The node's session secret, derived from its retained `seed`. Every
    /// connection the embedder opens for this node signs its keyed
    /// `op:start-session` with this key, so an exporter sees one identity across
    /// the introducer and the direct connection and verifies a
    /// `desc:handoff-receive` against it.
    pub fn secretKey(self: *const Node) crypto.SecretKey {
        return self.secret;
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
    /// same exporter (a second give for one identity joins the waiters instead
    /// of dialing twice). The node owns every heap string; an empty hint is an
    /// unowned sentinel (len 0, not freed). Unparseable gives never reach a
    /// pending row (`acceptGive` fails them closed). Dial authority is
    /// transport/designator/hint — no verbatim URI copy.
    const PendingDial = struct {
        /// Canonical peer-identity URI (hints stripped); indexes
        /// `pending_dial_by_identity` / feeds `exporters` on dial success.
        identity: []u8,
        /// Parsed once at `acceptGive` — dial / reuse borrow these (no re-parse).
        transport: []const u8,
        designator: []const u8,
        /// Empty when the give had no direct-addresses hint (unowned sentinel).
        direct_addresses_hint: []const u8,
        waiters: std.ArrayListUnmanaged(Waiter) = .empty,
    };

    /// Empty slices are unowned sentinels (no heap); non-empty parts are owned.
    fn freeDialPart(self: *Node, part: []const u8) void {
        if (part.len == 0) return;
        self.allocator.free(part);
    }

    fn freeDialParts(self: *Node, transport: []const u8, designator: []const u8, hint: []const u8) void {
        self.freeDialPart(transport);
        self.freeDialPart(designator);
        self.freeDialPart(hint);
    }

    /// Dial parts (not identity). `exporterDialed` uses this before the exporters
    /// cache adopts identity; `dialFailed`/`deinit` free identity too.
    fn freePendingDialShell(self: *Node, pending: *const PendingDial) void {
        self.freeDialParts(pending.transport, pending.designator, pending.direct_addresses_hint);
    }

    fn freePendingDialBytes(self: *Node, pending: *const PendingDial) void {
        self.freePendingDialShell(pending);
        self.allocator.free(pending.identity);
    }

    /// Borrowed pending-dial row for one ticket (views into the pending row).
    /// Valid until `exporterDialed` / `dialFailed` / teardown.
    pub const PendingDialView = struct {
        transport: []const u8,
        designator: []const u8,
        direct_addresses_hint: []const u8,
    };

    /// Parse identity + dial parts. Join / exporter-cache hits free this and
    /// never open a pending row.
    const StagedDial = struct {
        identity: []u8,
        transport: []const u8,
        designator: []const u8,
        direct_addresses_hint: []const u8,
    };

    fn freeStagedDial(self: *Node, staged: *const StagedDial) void {
        self.allocator.free(staged.identity);
        self.freeDialParts(staged.transport, staged.designator, staged.direct_addresses_hint);
    }

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
        fail: struct { peer_id: PeerId, answer: u64, reason: []const u8 },
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
    /// row exists. `direct_addresses_hint` is empty when the give carried no
    /// hint. Valid until `exporterDialed` / `dialFailed` / teardown.
    pub fn pendingDial(self: *const Node, pending: PendingId) ?PendingDialView {
        const entry = self.pending_dials.get(pending) orelse return null;
        return .{
            .transport = entry.transport,
            .designator = entry.designator,
            .direct_addresses_hint = entry.direct_addresses_hint,
        };
    }

    /// Parse once into identity + dial parts. Never owns a verbatim URI copy —
    /// dial authority is the staged parts. Unparseable locators return
    /// `error.UnparseableExporterLocator` with no heap (refuse path must not
    /// allocate staging bytes that are immediately freed).
    fn stagePendingDial(self: *Node, exporter_locator: []const u8) error{ OutOfMemory, UnparseableExporterLocator }!StagedDial {
        const parsed = model.uri.parsePeer(self.allocator, exporter_locator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.UnparseableExporterLocator,
        };
        // Steal transport/designator from the parse; free hints after copying
        // the direct-addresses value (empty hint stays an unowned sentinel).
        const transport = parsed.transport;
        const designator = parsed.designator;
        const hints = parsed.hints;
        errdefer self.freeDialPart(transport);
        errdefer self.freeDialPart(designator);
        errdefer model.freeHints(self.allocator, hints);
        var hint_src: []const u8 = "";
        for (hints.entries) |entry| {
            if (!std.mem.eql(u8, entry.name, model.transport.hint_direct_addresses)) continue;
            switch (entry.value) {
                .string, .bytes => |bytes| hint_src = bytes,
                else => {},
            }
            break;
        }
        const hint_owned: []const u8 = if (hint_src.len == 0)
            ""
        else
            try self.allocator.dupe(u8, hint_src);
        errdefer self.freeDialPart(hint_owned);
        // writePeer on a just-parsed peer should only fail OOM; fold any other
        // encode refuse into the same unparseable path as parsePeer.
        const identity = model.uri.writePeer(self.allocator, .{
            .transport = transport,
            .designator = designator,
            .hints = model.Hints.emptyFalse(),
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.UnparseableExporterLocator,
        };
        errdefer self.allocator.free(identity);
        model.freeHints(self.allocator, hints);
        return .{
            .identity = identity,
            .transport = transport,
            .designator = designator,
            .direct_addresses_hint = hint_owned,
        };
    }

    fn freeAction(self: *Node, action: Action) void {
        switch (action) {
            .fail => |f| self.allocator.free(f.reason),
            .dial, .flush, .settle, .need_gift_id => {},
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
        // One parse yields identity + dial parts (ADR-0012 join on
        // transport+designator, not raw URI spelling / hints). No verbatim
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
            return self.beginWithdraw(exporter_peer, recipient_peer, answer, give);
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
        try self.actions.reserve(self.allocator, 1);
        var pending: PendingDial = .{
            .identity = staged.identity,
            .transport = staged.transport,
            .designator = staged.designator,
            .direct_addresses_hint = staged.direct_addresses_hint,
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

    /// Report a dial's success: the exporter for `pending` is registered as
    /// `exporter_peer` with an open keyed session. The node caches the exporter
    /// and withdraws every waiting give on it. An unknown `pending` is a no-op
    /// (the ticket already settled).
    pub fn exporterDialed(self: *Node, pending: PendingId, exporter_peer: PeerId) !void {
        var entry = (self.pending_dials.fetchRemove(pending) orelse return).value;
        defer {
            for (entry.waiters.items) |waiter| self.allocator.free(waiter.give);
            entry.waiters.deinit(self.allocator);
        }
        std.debug.assert(self.pending_dial_by_identity.remove(entry.identity));
        // Dial parts are no longer needed; the cache keys on identity.
        // Must use freeDialPart (via the shell) — empty hint is an unowned sentinel.
        self.freePendingDialShell(&entry);
        // The cache adopts the identity bytes; an already-cached identity (a
        // duplicate dial the embedder raced) keeps the first row.
        const cached = self.exporters.getOrPut(self.allocator, entry.identity) catch |err| {
            self.allocator.free(entry.identity);
            return err;
        };
        if (cached.found_existing) {
            self.allocator.free(entry.identity);
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
            self.freePendingDialBytes(&entry);
            for (entry.waiters.items) |waiter| self.allocator.free(waiter.give);
            entry.waiters.deinit(self.allocator);
        }
        std.debug.assert(self.pending_dial_by_identity.remove(entry.identity));
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
        // Reserve before encode so map growth cannot strand a paid encode.
        try self.exporter_locations.ensureUnusedCapacity(self.allocator, 1);
        // Canonical Syrup locator-record bytes — the give embeds these, so a URI
        // (or any other non-record spelling) can never reach the wire from here.
        const owned = try engine.encodePeerLocatorRecord(self.allocator, loc);
        self.exporter_locations.putAssumeCapacity(peer_id, owned);
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
        const enrolled = self.foreign_imports.get(far_id) orelse return null;
        const wire_far = switch (enrolled.reference) {
            .far => |f| f,
            else => return null,
        };
        if (wire_far.kind != .promise) return null;

        const home_key: ProxyHomeKey = .{
            .home = home,
            .wire_pos = wire_far.import_position.int(),
        };
        const armed_here = self.promise_proxies.getPtr(home_key) == null;
        if (armed_here) {
            try self.armHomeProxy(home_key, wire_far);
        }
        errdefer if (armed_here) self.removePromiseProxy(home_key);

        const rp = self.peer(recipient_peer) orelse return error.PeerGone;
        const hp = self.peer(home) orelse return error.PeerGone;
        const host_bytes = hp.session_state.partnerDesignator() orelse return error.MissingPartnerDesignator;
        const export_pos = try rp.session_state.allocatePromiseExport();
        errdefer rp.session_state.releaseUnsharedExport(export_pos);
        try rp.session_state.installThirdPartyImport(.from(export_pos.int()), host_bytes);
        const row_id = rp.session_state.importedPromiseRowId(.from(export_pos.int())).?;

        const proxy = self.promise_proxies.getPtr(home_key).?;
        try proxy.recipients.append(self.allocator, .{
            .peer = recipient_peer,
            .import_pos = export_pos.int(),
            .row_id = row_id,
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

    /// If `listener_export` on `home_peer` is a proxy home-listener, take
    /// ownership of `resolution` as the fire owner, settle every recipient
    /// store (move for N=1; `materializeResolutionForStore` for the rest),
    /// tear the proxy down, and return true. False leaves `resolution` with the caller.
    pub fn consumeProxyListenerFire(
        self: *Node,
        home_peer: PeerId,
        listener_export: u64,
        resolution: model.Resolution,
    ) !bool {
        const home_key = self.proxy_by_listener.get(.{ .home = home_peer, .listener_export = listener_export }) orelse return false;
        const row = self.promise_proxies.getPtr(home_key) orelse return false;
        std.debug.assert(row.recipients.items.len > 0);

        if (row.recipients.items.len == 1) {
            const r = row.recipients.items[0];
            const recip = self.peer(r.peer) orelse {
                model.freeResolution(self.allocator, resolution);
                self.removePromiseProxy(home_key);
                return true;
            };
            try recip.applyRelayedResolution(model.ImportPosition.from(r.import_pos), r.row_id, resolution);
            self.removePromiseProxy(home_key);
            return true;
        }

        // Fire owner: materialize into each live recipient store, then free.
        defer model.freeResolution(self.allocator, resolution);
        for (row.recipients.items) |r| {
            const recip = self.peer(r.peer) orelse continue;
            const owned = try model.materializeResolutionForStore(self.allocator, resolution);
            try recip.applyRelayedResolution(model.ImportPosition.from(r.import_pos), r.row_id, owned);
        }
        self.removePromiseProxy(home_key);
        return true;
    }

    /// Install home `op:listen` and insert an armed `PromiseProxy` row.
    fn armHomeProxy(self: *Node, home_key: ProxyHomeKey, wire_far: model.FarRef) !void {
        const hp = self.peer(home_key.home) orelse return error.PeerGone;
        if (!hp.sessionIsOpen()) return error.session_not_open;
        // Far listen target must already be a held import (enrollment).

        const listener = try hp.session_state.allocateExport();
        hp.send(.{ .listen = .{
            .target = .{ .far = wire_far },
            .listener = .{ .near = model.NearRef.object(listener.int()) },
            .wants_partial = false,
        } }) catch |err| {
            hp.session_state.releaseUnsharedExport(listener);
            return err;
        };

        const listener_key: ProxyListenerKey = .{
            .home = home_key.home,
            .listener_export = listener.int(),
        };
        try self.proxy_by_listener.put(self.allocator, listener_key, home_key);
        errdefer std.debug.assert(self.proxy_by_listener.remove(listener_key));

        try self.promise_proxies.put(self.allocator, home_key, .{
            .listener_export = listener.int(),
        });
    }

    fn removePromiseProxy(self: *Node, key: ProxyHomeKey) void {
        if (self.promise_proxies.fetchRemove(key)) |kv| {
            var proxy = kv.value;
            const listener_key: ProxyListenerKey = .{
                .home = key.home,
                .listener_export = proxy.listener_export,
            };
            std.debug.assert(self.proxy_by_listener.remove(listener_key));
            proxy.deinit(self.allocator);
        }
    }

    fn sweepPromiseProxiesForPeer(self: *Node, peer_id: PeerId) void {
        var remove_keys: std.ArrayListUnmanaged(ProxyHomeKey) = .empty;
        defer remove_keys.deinit(self.allocator);

        var it = self.promise_proxies.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.home == peer_id) {
                remove_keys.append(self.allocator, entry.key_ptr.*) catch continue;
                continue;
            }
            var i: usize = 0;
            while (i < entry.value_ptr.recipients.items.len) {
                if (entry.value_ptr.recipients.items[i].peer == peer_id) {
                    entry.value_ptr.recipients.items[i] = entry.value_ptr.recipients.items[entry.value_ptr.recipients.items.len - 1];
                    entry.value_ptr.recipients.items.len -= 1;
                } else {
                    i += 1;
                }
            }
            if (entry.value_ptr.recipients.items.len == 0) {
                remove_keys.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (remove_keys.items) |key| self.removePromiseProxy(key);
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
        if (self.foreign_imports.get(far_id)) |enrolled| {
            if (enrolled.reference == .far and enrolled.reference.far.kind == .promise) return false;
        }
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
    /// key names the gifter-to-exporter session the give is signed under).
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
