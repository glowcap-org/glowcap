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
//! connection is removed or the node is torn down. The shared gift registry is
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
    pub fn enrollRedeemed(self: *Node, exporter_conn: ConnId, reference: model.Reference) !model.Reference {
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
    pub fn foreignHome(self: *Node, reference: model.Reference) ?ConnId {
        const id = switch (reference) {
            .far => |far| far.import_position.int(),
            else => return null,
        };
        if (id >= REDEEMED_TOKEN_BASE) return null;
        return self.foreign_homes.get(id);
    }

    /// Whether `reference` names a capability foreign to `default_conn` when used
    /// as a `send`/`tell` argument: a redeemed-handoff token (a synthetic id in
    /// the reserved range, which the node routes to a different exporter
    /// connection) or a far the node recorded as fetched on another connection.
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
    pub fn sendWithdraw(self: *Node, exporter_conn: ConnId, give_bytes: []const u8, answer: u64) !void {
        const conn = self.connAt(exporter_conn) orelse return error.UnknownConnection;
        try conn.peer.sendWithdrawGift(self.secretKey(), give_bytes, model.AnswerId.from(answer));
    }

    // ── Gifter origination (the gifter half) ─────────────────────────────────

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
    pub fn originateGive(
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
        const gifter_side = try engine.handoff_gifter.sideName(secret.publicKey().asBytes());
        const exporter_side = try engine.handoff_gifter.sideName(exporter_key);
        const session = engine.handoff_gifter.sessionName(gifter_side, exporter_side);

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
