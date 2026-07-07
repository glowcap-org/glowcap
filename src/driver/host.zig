//! `Host`: the native multi-connection tier — one identity, one node, many
//! connections (ADR-0066/0067). A `Host` owns an `engine.Node` (the retained
//! identity seed, the shared gift registry, the routing tables, the serve
//! step) and mints owning connections whose peers are node-registered, so
//! everything the node decides — where a token routes, which exporter a give
//! withdraws from, when a served reply becomes a signed give — happens under
//! every connection the host holds. This is the tier every language binding
//! builds inside its `connect`; natively it is explicit: `Host.dial` where a
//! binding dials invisibly, `Host.redeem` where a binding redeems invisibly.
//! The single-connection `connect`/`listen` tier stays below for the client
//! that will never hold two connections at once.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");
const actors = @import("actors");
const net = @import("net");

const connected_vat = @import("connected_vat.zig");
const crossed_hellos = @import("crossed_hellos.zig");
const ConnectedVat = connected_vat.ConnectedVat;
const connection_mod = @import("connection.zig");
const ConnectionOptions = connection_mod.ConnectionOptions;

const driver = @import("mod.zig");
const Settled = driver.Settled;

const crypto = foundation.crypto;

pub const Error = error{
    /// No netlayer in the host's slice hosts the locator's transport.
    UnknownTransport,
    /// The give's exporter closed, refused the session, or broke the withdraw
    /// (a missing deposit, a failed signature, a non-capability fulfillment).
    RedeemFailed,
    /// A token routed to an exporter connection that is gone; the send is
    /// dropped, not mis-sent (the node's fail-closed contract).
    TokenRetired,
};

/// One identity, one node, many connections. `netlayers` is borrowed and must
/// outlive the host; every connection the host mints shares `opts`. Free with
/// `deinit`, after every `HostConnection` the host handed out is closed.
///
/// One thread drives all of a host's connections. The node tables, the
/// connection map, and the redeem bookkeeping are unsynchronized, so two
/// threads serving different `HostConnection`s of the same host would race
/// them. The multiplexing primitive for a single thread is
/// `HostConnection.stepReadable`, round-robined across the connections. The
/// embedded crossed-hellos `Registry` locks its own state for the moment an
/// accepted connection compares an inbound start-session against an outbound
/// dial, not to license cross-thread serving.
pub const Host = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    node: engine.Node,
    netlayers: []const net.netlayer.Netlayer,
    opts: ConnectionOptions,
    connections: std.AutoHashMapUnmanaged(engine.ConnId, *HostConnection) = .{},
    /// Synthetic answer positions for `redeem`'s serve-step bookkeeping, drawn
    /// from a range no wire answer uses.
    next_redeem_answer: u64 = REDEEM_ANSWER_BASE,
    /// Set by the before-serve hook when the node claims a resolve, so a
    /// blocking drive knows fresh serve-step actions may be queued.
    claim_fired: bool = false,
    /// Crossed-hellos tiebreak state (ADR-0030): `dial` registers the outbound
    /// before it dials, accepted connections compare inbound start-sessions
    /// against it, and a dialed connection that lost the tiebreak aborts on
    /// its next pump. One registry per host, the identity the tiebreak keys on.
    hellos: crossed_hellos.Registry = .{},
    /// The host's own dialable designator, recorded by the first `listen` and
    /// signed into every dial's start-session — what a partner's crossed-hellos
    /// registry looks this host up by, and what its gives can name. Empty for
    /// a host that never listens (an ordinary client, unreachable by dial).
    self_designator: [64]u8 = undefined,
    self_designator_len: usize = 0,

    /// Synthetic answers `redeem` keys its serve-step bookkeeping on, drawn
    /// from a range no wire answer reaches so a redeem's internal answer can
    /// never collide with a partner-named one.
    pub const REDEEM_ANSWER_BASE: u64 = 1 << 62;

    /// Create a host with a fresh identity drawn at this I/O boundary; the
    /// node reuses it for every connection, so an exporter verifies a
    /// handoff signature against the one key the gifter named.
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        netlayers: []const net.netlayer.Netlayer,
        opts: ConnectionOptions,
    ) !Host {
        var seed: [crypto.SEED_BYTES]u8 = undefined;
        defer std.crypto.secureZero(u8, &seed);
        try io.randomSecure(&seed);
        return initSeeded(allocator, io, netlayers, seed, opts);
    }

    /// The retained-identity constructor: `seed` is the host's stable session
    /// identity (a listener that must present the same key across restarts).
    pub fn initSeeded(
        allocator: std.mem.Allocator,
        io: std.Io,
        netlayers: []const net.netlayer.Netlayer,
        seed: [crypto.SEED_BYTES]u8,
        opts: ConnectionOptions,
    ) Host {
        return .{
            .allocator = allocator,
            .io = io,
            .node = engine.Node.init(allocator, seed),
            .netlayers = netlayers,
            .opts = opts,
        };
    }

    /// Close every connection the host still holds, then free the node (and
    /// with it every registered peer) and the connection table.
    pub fn deinit(self: *Host) void {
        var it = self.connections.valueIterator();
        while (it.next()) |hc| {
            hc.*.cv.deinit();
            if (hc.*.dialed_designator.len != 0) self.allocator.free(hc.*.dialed_designator);
            self.allocator.free(hc.*.read_buf);
            self.allocator.free(hc.*.write_buf);
            self.allocator.destroy(hc.*);
        }
        self.connections.deinit(self.allocator);
        self.hellos.deinit(self.io, self.allocator);
        self.node.deinit();
    }

    /// Dial `locator`, register the connection on the node, and complete the
    /// keyed handshake under the host identity. The returned connection is
    /// closed with `HostConnection.deinit`, which also retires it from the
    /// node (failing anything still pending on it closed).
    pub fn dial(self: *Host, locator: model.PeerLocator) !*HostConnection {
        const nl = net.netlayer.resolve(self.netlayers, locator.transport) orelse return Error.UnknownTransport;
        return self.dialOn(nl, locator);
    }

    /// `dial` for a caller holding a published `ocapn://` URI string.
    pub fn dialUri(self: *Host, uri_str: []const u8) !*HostConnection {
        const locator = try model.uri.parsePeer(self.allocator, uri_str);
        defer model.freePeerLocator(self.allocator, locator);
        return self.dial(locator);
    }

    fn dialOn(self: *Host, nl: net.netlayer.Netlayer, locator: model.PeerLocator) !*HostConnection {
        try self.connections.ensureUnusedCapacity(self.allocator, 1);
        // Register the outbound before any bytes move: a crossed inbound
        // start-session from the same partner must find this dial (ADR-0030).
        const our_pid = foundation.crypto.derivePublicIdentifier(self.node.secretKey().publicKey());
        try self.hellos.registerOutbound(self.io, self.allocator, locator.designator, our_pid);
        errdefer self.hellos.unregister(self.io, self.allocator, locator.designator);
        const partner_designator = try self.allocator.dupe(u8, locator.designator);
        errdefer self.allocator.free(partner_designator);
        const conn_id = try self.node.registerConn();
        errdefer self.node.removeConn(conn_id);
        const peer = self.node.peer(conn_id).?;
        peer.session_state.limits.max_frame_bytes = self.opts.frame_cap;

        const hc = try self.allocator.create(HostConnection);
        errdefer self.allocator.destroy(hc);
        hc.* = .{ .host = self, .conn_id = conn_id, .cv = undefined, .read_buf = &.{}, .write_buf = &.{}, .dialed_designator = partner_designator };
        hc.read_buf = try self.allocator.alloc(u8, self.opts.frame_cap);
        errdefer self.allocator.free(hc.read_buf);
        hc.write_buf = try self.allocator.alloc(u8, self.opts.frame_cap);
        errdefer self.allocator.free(hc.write_buf);

        const conn = try nl.dial(peer, locator, .{ .read = hc.read_buf, .write = hc.write_buf });
        hc.cv = ConnectedVat.over(self.allocator, peer, conn);
        errdefer hc.cv.deinit();
        try hc.cv.startKeyedSessionWithSecret(.{
            .transport = locator.transport,
            .designator = self.selfDesignator(),
            .hints = model.Hints.emptyFalse(),
        }, self.node.secretKey());
        self.enroll(hc, .dialed);
        return hc;
    }

    /// Wire a connection into the host: the before-serve hook offers every
    /// inbound resolve to the node before the vat sees it (a claimed resolve
    /// is serve-step bookkeeping, never the application's), and the resolve
    /// interceptor turns a served reply that fulfills with a foreign-homed
    /// capability into a signed give (the gifter half, ADR-0067). Only an
    /// *accepted* connection consults the crossed-hellos registry: a partner's
    /// start-session arriving on a connection this host dialed is the ordinary
    /// handshake response, never a crossed inbound — comparing it against the
    /// host's own outbound entry would abort every dial to a listed partner.
    fn enroll(self: *Host, hc: *HostConnection, role: enum { dialed, accepted }) void {
        hc.cv.serve_options = .{
            .hook_ctx = hc,
            .before_serve = claimBeforeServe,
            .crossed_hellos = if (role == .accepted) &self.hellos else null,
        };
        hc.cv.vat.setResolveInterceptor(.{ .ctx = hc, .func = originateInterceptor });
        self.connections.putAssumeCapacity(hc.conn_id, hc);
    }

    /// Redeem a `.give` outcome: dial its exporter (or join the live exporter
    /// connection the node already holds), withdraw under the host identity,
    /// and hand back the capability, routable through any of this host's
    /// connections. The serve step owns every decision; this executes its
    /// actions with blocking I/O.
    pub fn redeem(self: *Host, from: *HostConnection, give: actors.Give) !actors.Ref {
        const answer = self.next_redeem_answer;
        self.next_redeem_answer += 1;
        try self.node.acceptGive(from.conn_id, answer, give.give_bytes, give.exporter_locator_uri);
        var dialed: ?*HostConnection = null;
        return self.driveRedeem(answer, &dialed) catch |err| {
            // A refused or broken withdraw retires the connection this redeem
            // dialed; an exporter another redeem already holds stays open.
            if (dialed) |hc| hc.deinit();
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => Error.RedeemFailed,
            };
        };
    }

    /// Execute serve-step actions until the redeem keyed on `answer` settles
    /// or fails. Dial actions open fresh host connections; a flush action
    /// pumps its connection until the before-serve hook claims a resolve
    /// (which queues the settle or fail this loop pops next).
    fn driveRedeem(self: *Host, answer: u64, dialed_out: *?*HostConnection) !actors.Ref {
        var pump: ?*HostConnection = null;
        while (true) {
            while (self.node.nextAction()) |action| {
                switch (action) {
                    .dial => |d| {
                        const dialed = self.dialGiveExporter(d.locator) catch |err| {
                            self.node.dialFailed(d.pending, @errorName(err)) catch {};
                            continue;
                        };
                        dialed_out.* = dialed;
                        try self.node.exporterDialed(d.pending, dialed.conn_id);
                    },
                    .flush => |conn_id| {
                        const hc = self.connections.get(conn_id) orelse continue;
                        try hc.cv.flush();
                        pump = hc;
                    },
                    .settle => |s_action| {
                        if (s_action.answer == answer) return .{ .far = model.FarRef.object(s_action.token) };
                    },
                    .fail => |f| {
                        if (f.answer == answer) return Error.RedeemFailed;
                    },
                    .need_gift_id => |n| {
                        var gift_id: [32]u8 = undefined;
                        try self.io.randomSecure(&gift_id);
                        try self.node.provideGiftId(n.ticket, &gift_id);
                    },
                }
            }
            // No action pending: the serve step is waiting on the wire. Pump
            // the last-flushed connection until the hook claims a resolve. An
            // exporter that leaves mid-withdraw is retired closed, and the
            // node's sweep queues the fail action the outer loop pops.
            const hc = pump orelse return Error.RedeemFailed;
            self.claim_fired = false;
            while (!self.claim_fired) {
                const progress = hc.cv.step() catch {
                    pump = null;
                    if (dialed_out.* == hc) dialed_out.* = null;
                    hc.deinit();
                    break;
                };
                if (progress == .closed) {
                    pump = null;
                    if (dialed_out.* == hc) dialed_out.* = null;
                    hc.deinit();
                    break;
                }
            }
        }
    }

    fn dialGiveExporter(self: *Host, locator_uri: []const u8) !*HostConnection {
        const locator = try model.uri.parsePeer(self.allocator, locator_uri);
        defer model.freePeerLocator(self.allocator, locator);
        return self.dial(locator);
    }

    /// Bind `netlayer` per `config` and return the accepting half: each
    /// `HostServer.accept` mints a node-registered connection whose responder
    /// handshake signs with the host identity and the listener's own dialable
    /// designator — the locator record a give made on this host names as the
    /// exporter location.
    pub fn listen(self: *Host, netlayer: net.netlayer.Netlayer, config: net.netlayer.ListenConfig) !HostServer {
        const listener = try netlayer.listen(self.allocator, config);
        if (self.self_designator_len == 0) {
            const bound = listener.localDesignator(&self.self_designator);
            self.self_designator_len = bound.len;
        }
        return .{ .host = self, .listener = listener };
    }

    /// The designator this host's dials sign: the first listener's bound
    /// address, or the shared unreachable-client placeholder for a host that
    /// never listens (a partner verifies the signature over it, not
    /// reachability), the same placeholder every never-listening dialer signs.
    fn selfDesignator(self: *const Host) []const u8 {
        if (self.self_designator_len == 0) return driver.unreachable_client_designator;
        return self.self_designator[0..self.self_designator_len];
    }

    /// The before-serve hook installed on every host connection: offer each
    /// inbound resolve to the node. Claimed means it settled a pending
    /// withdraw — serve-step bookkeeping the application must never see — so
    /// the vat is skipped and the claim signal wakes any blocking drive.
    fn claimBeforeServe(ctx: ?*anyopaque, cv: *ConnectedVat, event: *engine.Event) anyerror!bool {
        _ = cv;
        const hc: *HostConnection = @ptrCast(@alignCast(ctx.?));
        const body = event.view() catch return false;
        if (body != .resolve) return false;
        const outcome: engine.Node.WithdrawOutcome = switch (body.resolve.resolution) {
            .fulfill => |arg| switch (arg) {
                .reference => |reference| switch (reference) {
                    .far => |far| .{ .far = far.import_position.int() },
                    else => .not_capability,
                },
                else => .not_capability,
            },
            .@"break" => |b| .{ .broken = b.message },
        };
        const claimed = try hc.host.node.claimResolve(hc.conn_id, body.resolve.answer.int(), outcome);
        if (claimed) hc.host.claim_fired = true;
        return claimed;
    }

    /// The served-reply interceptor installed on every host connection's vat:
    /// a reply that fulfills with a far capability whose recorded home is
    /// another connection is claimed by the node, which asks for gift-id
    /// entropy and originates the give (deposit on the home connection, signed
    /// give resolving this answer). The exporter leg flushes here; the give
    /// itself rides this connection's own pump, which runs right after the
    /// serve that fired this interceptor.
    fn originateInterceptor(ctx: ?*anyopaque, answer: model.AnswerId, fulfilled: model.Argument) anyerror!bool {
        const hc: *HostConnection = @ptrCast(@alignCast(ctx.?));
        if (fulfilled != .reference or fulfilled.reference != .far) return false;
        const far_id = fulfilled.reference.far.import_position.int();
        const claimed = try hc.host.node.interceptFulfilledRef(hc.conn_id, answer.int(), far_id);
        if (!claimed) return false;
        try hc.host.driveOrigination(hc.conn_id);
        return true;
    }

    /// Execute the origination actions a claimed reply queued: draw the
    /// gift-id at this I/O boundary, and flush the give's legs — every
    /// connection except `serving`, whose own pump (already in flight above
    /// this call) writes its outbound the moment the serve returns.
    fn driveOrigination(self: *Host, serving: engine.ConnId) !void {
        while (self.node.nextAction()) |action| {
            switch (action) {
                .need_gift_id => |n| {
                    var gift_id: [32]u8 = undefined;
                    try self.io.randomSecure(&gift_id);
                    try self.node.provideGiftId(n.ticket, &gift_id);
                },
                .flush => |conn_id| {
                    if (conn_id == serving) continue;
                    const hc = self.connections.get(conn_id) orelse continue;
                    try hc.cv.flush();
                },
                .fail => |f| {
                    // The origination failed closed; the node broke the
                    // answer, and there is nothing further to execute.
                    _ = f;
                },
                .dial, .settle => {},
            }
        }
    }

    /// Route `target` for a send leaving `from`: an ordinary reference rides
    /// `from` unchanged; a redeemed token resolves to its exporter connection
    /// with the real reference swapped in. Fails closed when the token's
    /// exporter is gone.
    pub fn route(self: *Host, from: *HostConnection, target: actors.Ref) !struct { conn: *HostConnection, target: actors.Ref } {
        const far = switch (target) {
            .far => |f| f,
            .local => return .{ .conn = from, .target = target },
        };
        const routed = self.node.routeReference(from.conn_id, .{ .far = far }) orelse return Error.TokenRetired;
        const conn = self.connections.get(routed.conn_id) orelse return Error.TokenRetired;
        return .{ .conn = conn, .target = .{ .far = routed.target.far } };
    }
};

/// The accepting half a `Host.listen` binds: each accepted partner becomes a
/// node-registered `HostConnection` with the same hooks a dialed one carries,
/// so redeem claiming and give origination work on served connections too.
pub const HostServer = struct {
    host: *Host,
    listener: net.netlayer.Listener,

    /// The bound dialable designator (kernel-chosen port resolved), written
    /// into `out`: what a partner dials, and what this host's gives name.
    pub fn localDesignator(self: *const HostServer, out: []u8) []const u8 {
        return self.listener.localDesignator(out);
    }

    /// Accept one partner into a node-registered connection; the responder
    /// keyed handshake (host identity, the listener's real designator)
    /// completes before this returns.
    pub fn accept(self: *HostServer) !*HostConnection {
        const host = self.host;
        try host.connections.ensureUnusedCapacity(host.allocator, 1);
        const conn_id = try host.node.registerConn();
        errdefer host.node.removeConn(conn_id);
        const peer = host.node.peer(conn_id).?;
        peer.session_state.limits.max_frame_bytes = host.opts.frame_cap;

        const hc = try host.allocator.create(HostConnection);
        errdefer host.allocator.destroy(hc);
        hc.* = .{ .host = host, .conn_id = conn_id, .cv = undefined, .read_buf = &.{}, .write_buf = &.{} };
        hc.read_buf = try host.allocator.alloc(u8, host.opts.frame_cap);
        errdefer host.allocator.free(hc.read_buf);
        hc.write_buf = try host.allocator.alloc(u8, host.opts.frame_cap);
        errdefer host.allocator.free(hc.write_buf);

        const conn = try self.listener.accept(peer, .{ .read = hc.read_buf, .write = hc.write_buf });
        hc.cv = ConnectedVat.over(host.allocator, peer, conn);
        errdefer hc.cv.deinit();
        var designator_buf: [64]u8 = undefined;
        try hc.cv.startKeyedSessionWithSecret(.{
            .transport = self.listener.transportName(),
            .designator = self.listener.localDesignator(&designator_buf),
            .hints = model.Hints.emptyFalse(),
        }, host.node.secretKey());
        host.enroll(hc, .accepted);
        return hc;
    }

    /// Stop listening. Accepted connections live on; each is torn down by its
    /// own `HostConnection.deinit`.
    pub fn close(self: *HostServer) void {
        self.listener.close();
    }
};

/// An owning connection minted by `Host.dial`: the same verbs as the
/// single-connection `Connection`, with sends and calls routed through the
/// host's node so a redeemed capability is addressable from here like any
/// other. The peer is node-owned; `deinit` retires the connection from the
/// node (failing anything still pending on it closed) and frees the rest.
pub const HostConnection = struct {
    host: *Host,
    conn_id: engine.ConnId,
    cv: ConnectedVat,
    read_buf: []u8,
    write_buf: []u8,
    /// The partner designator this connection dialed, or empty for an accepted
    /// connection: the key the crossed-hellos tiebreak looks an outbound up by.
    dialed_designator: []const u8 = &.{},

    /// Whether this dialed connection lost the crossed-hellos tiebreak (the
    /// partner's higher-keyed dial to us wins): send the typed abort and tear
    /// this one down; the surviving session is the accepted one.
    pub fn lostCrossedHellos(self: *HostConnection) bool {
        if (self.dialed_designator.len == 0) return false;
        return self.host.hellos.shouldAbortOutbound(self.cv.conn.io, self.dialed_designator);
    }

    /// Send the crossed-hellos abort for a lost tiebreak (see
    /// `lostCrossedHellos`), leaving the teardown to `deinit`.
    pub fn abortCrossedHellos(self: *HostConnection) !void {
        try crossed_hellos.maybeAbortOutbound(&self.host.hellos, self.dialed_designator, self.cv.peer, &self.cv.conn);
    }

    /// Tear down: deregister from the host, retire the node connection (its
    /// peer frees with it; stranded withdraws fail closed), free the buffers.
    pub fn deinit(self: *HostConnection) void {
        const host = self.host;
        if (self.dialed_designator.len != 0) {
            host.hellos.unregister(host.io, host.allocator, self.dialed_designator);
            host.allocator.free(self.dialed_designator);
        }
        _ = host.connections.remove(self.conn_id);
        self.cv.deinit();
        host.node.removeConn(self.conn_id);
        // `removeConn` queues fail-closed actions for the withdraws pending on
        // this connection, and those actions break *sibling* connections'
        // answers. They stay on the shared node queue for the driving loop
        // (`driveRedeem`) to consume, or for `Node.deinit` to free. Teardown
        // must never pop them: a pop-and-discard here would eat a settle a
        // redeem still in flight needs, or strand a sibling's fail.
        host.allocator.free(self.read_buf);
        host.allocator.free(self.write_buf);
        host.allocator.destroy(self);
    }

    /// Fetch a partner capability by name, recording its home so a later
    /// foreign return can be recognized and re-gifted (the gifter half). The
    /// home record is load-bearing, not best-effort: without it the resolve
    /// interceptor cannot recognize this capability when a served reply returns
    /// it, so the reply would encode the far's import position onto the wrong
    /// connection. If the routing table cannot record the home, the fetch fails
    /// loud with that allocator error rather than hand back a capability that
    /// would later mis-route.
    pub fn fetch(self: *HostConnection, name: []const u8) !actors.Ref {
        const ref = try self.cv.fetch(name);
        if (ref == .far) {
            try self.host.node.recordForeignHome(.{ .far = ref.far }, self.conn_id);
        }
        return ref;
    }

    /// `call` with node routing: a redeemed token's call rides its exporter
    /// connection transparently (see `Host.route`).
    pub fn call(self: *HostConnection, target: actors.Ref, msg: actors.Message, arena: std.mem.Allocator) !Settled {
        const routed = try self.host.route(self, target);
        return routed.conn.cv.call(routed.target, msg, arena);
    }

    /// `send` with node routing; the returned promise lives on the routed
    /// connection's vat (a redeemed token routes to its exporter connection, an
    /// ordinary reference stays on this one). Settle it with `settlePromise`,
    /// re-passing the same `target` so the settle drives the connection the
    /// send left on.
    pub fn send(self: *HostConnection, target: actors.Ref, msg: actors.Message) !actors.Promise {
        const routed = try self.host.route(self, target);
        return routed.conn.cv.send(routed.target, msg);
    }

    /// Drive the routed connection until `promise` — returned by `send` to
    /// `target` — settles, materializing the outcome into `arena`. Routing
    /// keys on the target reference, not the promise, so the caller re-passes
    /// the `target` it sent to: this re-routes to the same connection the send
    /// left on and settles there. An ordinary reference settles on this
    /// connection; a redeemed token settles on its exporter connection.
    pub fn settlePromise(self: *HostConnection, target: actors.Ref, promise: actors.Promise, arena: std.mem.Allocator) !Settled {
        const routed = try self.host.route(self, target);
        return routed.conn.cv.settlePromise(promise, arena);
    }

    /// Fire-and-forget with node routing.
    pub fn tell(self: *HostConnection, target: actors.Ref, msg: actors.Message) !void {
        const routed = try self.host.route(self, target);
        return routed.conn.cv.tell(routed.target, msg);
    }

    /// Redeem a `.give` outcome this connection's `call`/`fetchSettled`
    /// surfaced: `Host.redeem` with this connection as the arrival leg.
    pub fn redeem(self: *HostConnection, give: actors.Give) !actors.Ref {
        return self.host.redeem(self, give);
    }

    /// Publish an actor fetchable by `name` on this connection's session (see
    /// `ConnectedVat.publish`). A host serving an object to several partners
    /// publishes it on each accepted connection under the same name; the
    /// node's shared registry is what lets a gift deposited on one connection
    /// be withdrawn on another (ADR-0056).
    pub fn publish(self: *HostConnection, name: []const u8, comptime Behavior: type, initial: Behavior) !driver.Capability {
        return self.cv.publish(name, Behavior, initial);
    }

    /// Serve until the partner leaves (see `ConnectedVat.serve`); the host's
    /// hooks ride along, so claims and originations fire here too.
    pub fn serve(self: *HostConnection) !void {
        return self.cv.serve();
    }

    /// One bounded pump: wait up to `timeout_ms` for readable bytes, apply
    /// them, and return, or null on timeout (see `ConnectedVat.stepReadable`).
    /// The round-robin primitive for a single thread serving several
    /// connections of one host.
    pub fn stepReadable(self: *HostConnection, timeout_ms: i32) !?net.Progress {
        return self.cv.stepReadable(timeout_ms);
    }
};
