//! `Node` — the sans-io cross-connection handoff router (ADR-0066).
//!
//! A `Node` is pancake's analogue of Goblins' `mycapn`: the thing distinct from
//! a per-partner connection. It owns the node's stable identity (one retained
//! session `seed`, reused for every connection it opens, so an exporter verifies
//! a `desc:handoff-receive` against one key), the set of `engine.Peer`s it
//! routes between (keyed by an integer `conn_id`), one shared
//! `engine.bootstrap.GiftRegistry` ([ADR-0056](../../../docs/decisions/adr/ADR-0056-vat-scoped-gift-registry.md))
//! so a deposit on a gifter session meets a withdraw on the recipient session,
//! and the two routing tables that make three-party handoff transparent: the
//! `redeemed` map from a synthetic far token to the exporter connection that
//! hosts the real capability, and the `foreign_homes` map from a fetched import
//! to the connection it lives on.
//!
//! It is **sans-io**: it owns no sockets and no event loop. The embedder keeps
//! its own transport and async loop, registers each live connection's peer with
//! the node, feeds the peer the bytes it reads, drains the bytes the peer
//! produces, and asks the node to route sends. Every route value is an integer
//! `conn_id` or owned bytes, so the router is pure data — which is exactly why it
//! lives here in the sync, no-I/O engine core (not the I/O-bearing driver layer)
//! instead of being reimplemented per binding, and why the sans-io
//! `libpancake_ocapn` archive can project it (ADR-0066). The vat (turn loop,
//! promise resolution, behavior dispatch) stays
//! above the node, in the embedder, because that is the host-scheduler adapter
//! (ADR-0066 records the boundary).
//!
//! The node owns each registered `engine.Peer` (heap-pinned, since a live
//! connection borrows the peer's stable address) and frees it when the
//! connection is removed or the node is torn down. The node itself must not
//! move once a connection is registered: each registered peer points at the
//! node's shared gift registry by address (the C ABI heap-pins the node for
//! exactly this reason). The shared gift registry is
//! the node's; every peer it registers points at it, so a peer freed by the node
//! never frees the shared registry (the engine's `Peer.deinit` only frees a
//! peer's *own* registry).

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("mod.zig");

const crypto = foundation.crypto;

/// A connection id: the embedder's handle to one registered peer. Stable for the
/// life of the registration; freed ids are not reused within a node's life, so a
/// stale id fails closed rather than aliasing a later connection.
pub const ConnId = u64;

/// Where a redeemed token routes: the exporter connection that hosts the real
/// capability, and the real exporter-side reference to swap in when forwarding.
/// The node owns `reference`.
const Route = struct {
    conn_id: ConnId,
    reference: model.Reference,
};

/// One registered connection: the node-owned peer plus liveness. The peer is
/// heap-pinned so the embedder's live connection can borrow its stable address.
const Conn = struct {
    peer: *engine.Peer,
    live: bool,
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
    /// disjoint from real session import ids, so a redeemed token can never alias
    /// a partner's import. This is the cross-binding token model ADR-0066
    /// standardizes (retiring the per-binding `Ref.home` field).
    pub const REDEEMED_TOKEN_BASE: u64 = 1 << 60;

    allocator: std.mem.Allocator,
    /// The retained 32-byte node identity, reused for every connection this node
    /// opens so an exporter verifies a `desc:handoff-receive` (and a gifter's
    /// `desc:handoff-give` signature) against the one key it saw.
    seed: [crypto.SEED_BYTES]u8,
    /// One deposited-gift / handoff-count authority shared across every peer this
    /// node registers, so an exporter's deposit (on the gifter connection) and
    /// withdraw (on the recipient connection) resolve against the same table.
    gifts: engine.bootstrap.GiftRegistry = .{},
    /// Registered connections, indexed by `conn_id`. A removed slot holds null so
    /// ids stay stable and are never reused.
    conns: std.ArrayListUnmanaged(?Conn) = .empty,
    /// token -> exporter route. A redeemed-handoff capability the application
    /// holds as a far ref `>= REDEEMED_TOKEN_BASE` resolves here.
    redeemed: std.AutoHashMapUnmanaged(u64, Route) = .empty,
    /// A fetched far import's home connection, by import id: when a published
    /// actor returns a far cap whose home is another connection, the resolve
    /// interceptor reads the home here and originates the gifter half of a
    /// three-party handoff instead of encoding a cross-connection reference
    /// (ADR-0009). Redeemed tokens (synthetic high ids) are never wire imports,
    /// so they are never recorded here.
    foreign_homes: std.AutoHashMapUnmanaged(u64, ConnId) = .empty,
    /// The next synthetic token a redeemed capability is enrolled under.
    next_token: u64 = REDEEMED_TOKEN_BASE,
    /// The serve step's exporter cache: a give's exporter locator (`ocapn://…`
    /// bytes, node-owned keys) to the live connection already dialed for it, so
    /// a second redeem to one exporter reuses the connection.
    exporters: std.StringHashMapUnmanaged(ConnId) = .empty,
    /// Dials in flight, keyed by the `PendingId` the `dial` action carried.
    pending_dials: std.AutoHashMapUnmanaged(PendingId, PendingDial) = .empty,
    /// Withdraws awaiting resolution, keyed by (exporter conn, withdraw answer).
    pending_withdraws: std.AutoHashMapUnmanaged(WithdrawKey, PendingWithdraw) = .empty,
    /// Claimed gifter originations awaiting their host-drawn gift id, keyed by
    /// the `need_gift_id` ticket.
    pending_gifts: std.AutoHashMapUnmanaged(u64, PendingGift) = .empty,
    /// Per-connection give-location overrides (`setExporterLocation`),
    /// node-owned bytes.
    exporter_locations: std.AutoHashMapUnmanaged(ConnId, []u8) = .empty,
    /// The serve step's action queue (`nextAction` drains it).
    actions: std.ArrayListUnmanaged(Action) = .empty,
    action_head: usize = 0,
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
        for (self.conns.items) |slot| {
            if (slot) |conn| {
                conn.peer.deinit();
                self.allocator.destroy(conn.peer);
            }
        }
        self.conns.deinit(self.allocator);

        var route_it = self.redeemed.valueIterator();
        while (route_it.next()) |entry| model.freeReference(self.allocator, entry.reference);
        self.redeemed.deinit(self.allocator);

        self.foreign_homes.deinit(self.allocator);
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
        for (self.actions.items[self.action_head..]) |action| self.freeAction(action);
        self.actions.deinit(self.allocator);
    }

    /// Register a fresh negotiating peer bound to this node's shared gift
    /// registry and return its `conn_id`. The embedder builds its live
    /// `net.Connection` over `node.peer(conn_id)` and pumps it; the peer's
    /// address is stable for the registration's life. The peer is negotiating, so
    /// the embedder completes the keyed `op:start-session` handshake (it owns the
    /// socket and the entropy) signing with `node.seed` for an identity the
    /// exporter will recognize across connections.
    pub fn registerConn(self: *Node) !ConnId {
        const new_peer = try self.allocator.create(engine.Peer);
        errdefer self.allocator.destroy(new_peer);
        new_peer.* = engine.Peer.initNegotiating(self.allocator);
        new_peer.shared_gift_registry = &self.gifts;

        const id: ConnId = self.conns.items.len;
        try self.conns.append(self.allocator, .{ .peer = new_peer, .live = true });
        return id;
    }

    /// Remove a registered connection: free its peer and mark the slot dead. A
    /// later route to a redeemed token whose exporter was this connection fails
    /// closed (the peer is gone), rather than forwarding onto a dead socket. The
    /// `conn_id` is never reused.
    pub fn removeConn(self: *Node, conn_id: ConnId) void {
        const conn = self.connAt(conn_id) orelse return;
        conn.peer.deinit();
        self.allocator.destroy(conn.peer);
        self.conns.items[conn_id] = null;
        if (self.exporter_locations.fetchRemove(conn_id)) |prev| self.allocator.free(prev.value);

        // Evict the exporter-cache rows naming this connection, so a later
        // give for the same exporter dials a fresh connection instead of
        // failing against the dead one forever.
        var evicted = true;
        while (evicted) {
            evicted = false;
            var exporter_it = self.exporters.iterator();
            while (exporter_it.next()) |entry| {
                if (entry.value_ptr.* == conn_id) {
                    const key = entry.key_ptr.*;
                    self.exporters.removeByPtr(entry.key_ptr);
                    self.allocator.free(key);
                    evicted = true;
                    break; // removal invalidates the iterator; rescan
                }
            }
        }

        // Break every withdraw still pending on this connection: its resolve
        // can never arrive, so the recipient's answer fails closed instead of
        // hanging. Best-effort — an allocation failure during teardown queues
        // nothing, and the recipient's own disconnect handling breaks the vow.
        var swept = true;
        while (swept) {
            swept = false;
            var withdraw_it = self.pending_withdraws.iterator();
            while (withdraw_it.next()) |entry| {
                if (entry.key_ptr.conn_id == conn_id) {
                    const pending = entry.value_ptr.*;
                    self.pending_withdraws.removeByPtr(entry.key_ptr);
                    self.queueFail(pending.recipient_conn, pending.answer, "handoff redeem failed: exporter connection closed") catch {};
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
                if (entry.value_ptr.recipient_conn == conn_id) {
                    self.pending_gifts.removeByPtr(entry.key_ptr);
                    retired = true;
                    break;
                }
            }
        }
    }

    /// The node-owned peer for `conn_id`, or null when the id names no live
    /// connection. The embedder pumps I/O through this peer; the node routes
    /// across them.
    pub fn peer(self: *Node, conn_id: ConnId) ?*engine.Peer {
        const conn = self.connAt(conn_id) orelse return null;
        return conn.peer;
    }

    fn connAt(self: *Node, conn_id: ConnId) ?Conn {
        if (conn_id >= self.conns.items.len) return null;
        return self.conns.items[conn_id];
    }

    // ── Redeemed-token routing (the recipient half) ──────────────────────────

    /// Enroll a redeemed capability under a fresh synthetic token and return the
    /// far reference the application receives, indistinguishable from any other
    /// far capability a partner handed back. A later `routeReference` of that
    /// reference forwards to `exporter_conn` with `reference` (the real
    /// exporter-side ref) swapped in. The node adopts a clone of `reference`; the
    /// caller keeps its own.
    fn enrollRedeemed(self: *Node, exporter_conn: ConnId, reference: model.Reference) !model.Reference {
        const owned = try model.cloneReference(self.allocator, reference);
        errdefer model.freeReference(self.allocator, owned);
        const token = self.next_token;
        try self.redeemed.put(self.allocator, token, .{ .conn_id = exporter_conn, .reference = owned });
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
        return self.redeemed.get(id);
    }

    // ── Foreign-home routing (the gifter half) ───────────────────────────────

    /// Record that the far capability `reference` lives on `home`: a `fetch`
    /// stamps every far import it returns, so a later foreign-home return can be
    /// recognized and re-gifted (ADR-0009 gifter half). A redeemed token (a
    /// synthetic high id) is never a wire import, so it is skipped.
    pub fn recordForeignHome(self: *Node, reference: model.Reference, home: ConnId) !void {
        const id = switch (reference) {
            .far => |far| far.import_position.int(),
            else => return,
        };
        if (id >= REDEEMED_TOKEN_BASE) return;
        try self.foreign_homes.put(self.allocator, id, home);
    }

    /// The connection a fetched far `reference` lives on, if any.
    fn foreignHome(self: *Node, reference: model.Reference) ?ConnId {
        const id = switch (reference) {
            .far => |far| far.import_position.int(),
            else => return null,
        };
        if (id >= REDEEMED_TOKEN_BASE) return null;
        return self.foreign_homes.get(id);
    }

    /// Whether `reference` names a capability foreign to `default_conn` when used
    /// as a `send`/`tell` argument: a redeemed-handoff token (always foreign —
    /// route rewriting applies to send *targets* only, so a token in argument
    /// position would reach the wire as its synthetic id, meaningless to any
    /// partner) or a far the node recorded as fetched on another connection.
    /// The gifter half re-gifts such a capability when it is *returned*
    /// (ADR-0009); passing one as a send argument is the symmetric case not yet
    /// lifted, so a binding fails closed on a true verdict rather than
    /// mis-encoding the reference for this partner. This is the one definition of
    /// that verdict the bindings share, computed from the node's redeemed-token
    /// and foreign-home state instead of being hand-rolled per binding (ADR-0066).
    pub fn argIsForeign(self: *Node, default_conn: ConnId, reference: model.Reference) bool {
        const id = switch (reference) {
            .far => |far| far.import_position.int(),
            else => return false,
        };
        if (id >= REDEEMED_TOKEN_BASE) return true;
        const home = self.foreign_homes.get(id) orelse return false;
        return home != default_conn;
    }

    // ── Routed send ──────────────────────────────────────────────────────────

    /// Where a routed deliver lands: which connection carries it, and the real
    /// reference to address (a redeemed token is rewritten to its exporter-side
    /// reference). The embedder turns this into an `op:deliver` on `conn_id`'s
    /// peer.
    pub const Routed = struct {
        conn_id: ConnId,
        target: model.Reference,
    };

    /// Resolve `target` to the connection and real reference a deliver to it
    /// rides. A redeemed token routes to its exporter connection with the real
    /// exporter-side reference; any other reference rides `default_conn` (the
    /// connection the application is addressing) unchanged. Returns null when a
    /// redeemed token names an exporter connection that is gone.
    pub fn routeReference(self: *Node, default_conn: ConnId, target: model.Reference) ?Routed {
        if (self.route(target)) |r| {
            if (self.connAt(r.conn_id) == null) return null;
            return .{ .conn_id = r.conn_id, .target = r.reference };
        }
        return .{ .conn_id = default_conn, .target = target };
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

    /// Recipient half of a three-party handoff, issued on the dialed exporter
    /// connection: sign a `desc:handoff-receive` over `give_bytes` keyed by the
    /// node's retained identity, mint the monotonic handoff-count from the shared
    /// registry (ADR-0056), and queue `withdraw-gift` to the exporter's bootstrap
    /// under `answer`. This is the one definition of the recipient withdraw the
    /// bindings and the native driver share, replacing the per-caller hand-rolled
    /// receive. The embedder pumps `exporter_conn` to flush it and awaits the
    /// resolution; on a fulfilled reference it calls `enrollRedeemed` so the cap
    /// becomes routable. The exporter session must be open, its partner key
    /// drives the receive's session name.
    fn sendWithdraw(self: *Node, exporter_conn: ConnId, give_bytes: []const u8, answer: u64) !void {
        const conn = self.connAt(exporter_conn) orelse return error.UnknownConnection;
        try conn.peer.sendWithdrawGift(self.secretKey(), give_bytes, model.AnswerId.from(answer));
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
        recipient_conn: ConnId,
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
        recipient_conn: ConnId,
        answer: u64,
    };

    /// One claimed gifter origination awaiting its host-drawn gift id, keyed
    /// by the ticket the `need_gift_id` action carried.
    const PendingGift = struct {
        recipient_conn: ConnId,
        answer: u64,
        far_id: u64,
    };

    const WithdrawKey = struct {
        conn_id: ConnId,
        answer: u64,
    };

    /// What the embedder must do next. Byte views are node-owned and valid
    /// until the next `nextAction` call (or node teardown); copy what outlives
    /// that.
    pub const Action = union(enum) {
        /// Dial the exporter at `locator` (an `ocapn://…` URI) with the node's
        /// retained identity, register the connection, open the keyed session,
        /// then feed `exporterDialed(pending, conn_id)` — or
        /// `dialFailed(pending, reason)` if any step refuses.
        dial: struct { pending: PendingId, locator: []const u8 },
        /// Pump this connection's outbound queue to the wire.
        flush: ConnId,
        /// Settle the application answer `answer` on `conn_id`: the redeemed
        /// capability is enrolled and `token` is the ordinary far id the
        /// application receives.
        settle: struct { conn_id: ConnId, answer: u64, token: u64 },
        /// Break the application answer `answer` on `conn_id` with `reason`.
        fail: struct { conn_id: ConnId, answer: u64, reason: []const u8 },
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
        try self.actions.append(self.allocator, action);
    }

    /// Queue a fail action carrying an owned copy of `reason`.
    fn queueFail(self: *Node, conn_id: ConnId, answer: u64, reason: []const u8) !void {
        const owned = try self.allocator.dupe(u8, reason);
        errdefer self.allocator.free(owned);
        try self.queueAction(.{ .fail = .{ .conn_id = conn_id, .answer = answer, .reason = owned } });
    }

    /// Pop the next queued action. The previous action's byte views are freed
    /// here, so a popped action is valid until the next call. Null when no
    /// action is pending.
    pub fn nextAction(self: *Node) ?Action {
        if (self.last_action) |last| {
            self.freeAction(last);
            self.last_action = null;
        }
        if (self.action_head >= self.actions.items.len) {
            self.actions.clearRetainingCapacity();
            self.action_head = 0;
            return null;
        }
        // Compact a long-dead prefix so an embedder that queues new work
        // before ever draining to empty cannot grow the list without bound.
        if (self.action_head >= 32) {
            const remaining = self.actions.items.len - self.action_head;
            std.mem.copyForwards(Action, self.actions.items[0..remaining], self.actions.items[self.action_head..]);
            self.actions.items.len = remaining;
            self.action_head = 0;
        }
        const action = self.actions.items[self.action_head];
        self.action_head += 1;
        self.last_action = action;
        return action;
    }

    /// Recipient intercept: the application answer `answer` on
    /// `recipient_conn` resolved to a handoff give instead of a value. The
    /// embedder must not surface that resolve; it feeds it here and executes
    /// the actions. `give` is the verbatim signed envelope and
    /// `exporter_locator` the give's dialable `ocapn://…` URI (both borrowed;
    /// the node copies what it keeps). A live exporter connection for that
    /// locator withdraws immediately; a dial already in flight is joined; an
    /// unknown exporter becomes a `dial` action. An empty locator fails the
    /// answer closed.
    pub fn acceptGive(
        self: *Node,
        recipient_conn: ConnId,
        answer: u64,
        give: []const u8,
        exporter_locator: []const u8,
    ) !void {
        if (exporter_locator.len == 0) {
            return self.queueFail(recipient_conn, answer, "handoff give names no dialable exporter locator");
        }
        if (self.exporters.get(exporter_locator)) |exporter_conn| {
            return self.beginWithdraw(exporter_conn, recipient_conn, answer, give);
        }

        const owned_give = try self.allocator.dupe(u8, give);
        errdefer self.allocator.free(owned_give);
        const waiter: Waiter = .{ .recipient_conn = recipient_conn, .answer = answer, .give = owned_give };

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
        try self.actions.ensureUnusedCapacity(self.allocator, 1);
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
        self.actions.appendAssumeCapacity(.{ .dial = .{ .pending = pending_id, .locator = action_locator } });
    }

    /// Send one withdraw on a live exporter connection and record it pending.
    /// `give` is borrowed. The tracking row and the flush action are reserved
    /// before the withdraw is queued: once the withdraw is on the wire,
    /// failing to track it would let its resolve surface to the application
    /// as an answer it never asked.
    fn beginWithdraw(self: *Node, exporter_conn: ConnId, recipient_conn: ConnId, answer: u64, give: []const u8) !void {
        const conn = self.connAt(exporter_conn) orelse
            return self.queueFail(recipient_conn, answer, "handoff redeem failed: exporter connection is gone");
        try self.pending_withdraws.ensureUnusedCapacity(self.allocator, 1);
        try self.actions.ensureUnusedCapacity(self.allocator, 1);
        const withdraw_answer = conn.peer.allocateAnswer();
        self.sendWithdraw(exporter_conn, give, withdraw_answer) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                var buf: [128]u8 = undefined;
                const reason = std.fmt.bufPrint(&buf, "handoff redeem failed: {s}", .{@errorName(err)}) catch "handoff redeem failed";
                return self.queueFail(recipient_conn, answer, reason);
            },
        };
        self.pending_withdraws.putAssumeCapacity(
            .{ .conn_id = exporter_conn, .answer = withdraw_answer },
            .{ .recipient_conn = recipient_conn, .answer = answer },
        );
        self.actions.appendAssumeCapacity(.{ .flush = exporter_conn });
    }

    /// Report a dial's success: the exporter at `pending`'s locator is
    /// registered as `exporter_conn` with an open keyed session. The node
    /// caches the exporter and withdraws every waiting give on it. An unknown
    /// `pending` is a no-op (the ticket already settled).
    pub fn exporterDialed(self: *Node, pending: PendingId, exporter_conn: ConnId) !void {
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
            cached.value_ptr.* = exporter_conn;
        }
        // Reserve for the whole batch so an allocation failure cannot orphan
        // the tail waiters after the head's withdraws are already queued.
        try self.pending_withdraws.ensureUnusedCapacity(self.allocator, @intCast(entry.waiters.items.len));
        try self.actions.ensureUnusedCapacity(self.allocator, entry.waiters.items.len);
        for (entry.waiters.items) |waiter| {
            try self.beginWithdraw(exporter_conn, waiter.recipient_conn, waiter.answer, waiter.give);
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
            try self.queueFail(waiter.recipient_conn, waiter.answer, message);
        }
    }

    /// How a withdraw's resolution settled, fed through `claimResolve`.
    pub const WithdrawOutcome = union(enum) {
        /// Fulfilled with a far object capability (the ordinary outcome).
        far: u64,
        /// Broken by the exporter; the reason is borrowed for the call.
        broken: []const u8,
        /// Fulfilled with something that is not a capability.
        not_capability,
    };

    /// Offer a resolve the embedder polled on `conn_id` to the node. Returns
    /// true when the resolve settles a pending withdraw — the node consumes it
    /// (enrolling the capability under a token and queueing the `settle`, or
    /// queueing the `fail`), and the embedder must not surface it to the
    /// application. False means the resolve is the application's, untouched.
    pub fn claimResolve(self: *Node, conn_id: ConnId, answer: u64, outcome: WithdrawOutcome) !bool {
        // Read the row but retire it only after the outcome is queued, so an
        // allocation failure leaves the withdraw pending (the claim can be
        // retried) rather than silently dropping the recipient's answer.
        const key: WithdrawKey = .{ .conn_id = conn_id, .answer = answer };
        const pending = self.pending_withdraws.get(key) orelse return false;
        switch (outcome) {
            .far => |far_id| {
                const token = try self.enrollRedeemed(conn_id, .{ .far = model.FarRef.object(far_id) });
                try self.queueAction(.{ .settle = .{
                    .conn_id = pending.recipient_conn,
                    .answer = pending.answer,
                    .token = token.far.import_position.int(),
                } });
            },
            .broken => |reason| {
                var buf: [256]u8 = undefined;
                const message = std.fmt.bufPrint(&buf, "handoff redeem failed: {s}", .{reason}) catch "handoff redeem failed";
                try self.queueFail(pending.recipient_conn, pending.answer, message);
            },
            .not_capability => {
                try self.queueFail(pending.recipient_conn, pending.answer, "withdraw-gift did not resolve to a capability");
            },
        }
        _ = self.pending_withdraws.remove(key);
        return true;
    }

    /// Record the verbatim exporter locator to embed in gives whose exporter
    /// is `conn_id` — an exporter reachable only by a dial hint (an iroh
    /// endpoint's direct addresses), where the session's own signed location
    /// record is not dialable. `location` is borrowed (the node copies it);
    /// empty clears the override back to the session record.
    pub fn setExporterLocation(self: *Node, conn_id: ConnId, location: []const u8) !void {
        if (self.exporter_locations.fetchRemove(conn_id)) |prev| self.allocator.free(prev.value);
        if (location.len == 0) return;
        const owned = try self.allocator.dupe(u8, location);
        errdefer self.allocator.free(owned);
        try self.exporter_locations.put(self.allocator, conn_id, owned);
    }

    /// The recorded give-location override for `conn_id`, or empty (use the
    /// exporter session's own signed record).
    fn exporterLocation(self: *const Node, conn_id: ConnId) []const u8 {
        return self.exporter_locations.get(conn_id) orelse "";
    }

    /// Gifter intercept: the application answer `answer` on `conn_id`
    /// fulfilled to the far capability `far_id`. When that capability's
    /// recorded home is another connection, the node claims the reply and
    /// queues a `need_gift_id` action — entropy is a host effect, requested
    /// only now that the reply is actually becoming a gift — and returns true
    /// (the embedder must not also send a plain resolve; it draws 32 bytes and
    /// feeds `provideGiftId`). False means the reply is ordinary and the
    /// embedder resolves it itself.
    pub fn interceptFulfilledRef(self: *Node, conn_id: ConnId, answer: u64, far_id: u64) !bool {
        const reference: model.Reference = .{ .far = model.FarRef.object(far_id) };
        const home = self.foreignHome(reference) orelse return false;
        if (home == conn_id) return false;
        const ticket = self.next_pending;
        try self.pending_gifts.put(self.allocator, ticket, .{
            .recipient_conn = conn_id,
            .answer = answer,
            .far_id = far_id,
        });
        self.next_pending += 1;
        try self.queueAction(.{ .need_gift_id = .{ .ticket = ticket } });
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
        const reference: model.Reference = .{ .far = model.FarRef.object(pending.far_id) };
        const home = self.foreignHome(reference) orelse
            return self.queueFail(pending.recipient_conn, pending.answer, "handoff origination failed: home connection is gone");
        self.originateGive(
            pending.recipient_conn,
            home,
            reference,
            gift_id,
            pending.answer,
            self.exporterLocation(home),
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                var buf: [128]u8 = undefined;
                const reason = std.fmt.bufPrint(&buf, "handoff origination failed: {s}", .{@errorName(err)}) catch "handoff origination failed";
                return self.queueFail(pending.recipient_conn, pending.answer, reason);
            },
        };
        try self.queueAction(.{ .flush = home });
        try self.queueAction(.{ .flush = pending.recipient_conn });
    }

    /// Gifter half of a three-party handoff (ADR-0009), the mirror of
    /// `sendWithdraw`: queue a `deposit-gift` of `gifted` on the exporter
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
        recipient_conn: ConnId,
        exporter_conn: ConnId,
        gifted: model.Reference,
        gift_id: []const u8,
        answer: u64,
        exporter_location: []const u8,
    ) !void {
        const recipient = self.connAt(recipient_conn) orelse return error.UnknownConnection;
        const exporter = self.connAt(exporter_conn) orelse return error.UnknownConnection;
        const rp = recipient.peer;
        const ep = exporter.peer;

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

        try rp.sendResolveHandoffGive(model.AnswerId.from(answer), give);
    }
};
