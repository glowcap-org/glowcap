//! `LoopBridge`: the translator that feeds the byte-fed multi-connection
//! host (`driver_core.Host`) from the TCP completion loop (`net.Loop`).
//!
//! Every decision it relays already has one owner. The host's `drainWork`
//! decides which connections to flush and when one is condemned; the loop's
//! `flushOutbound` decides how bytes reach a socket; `Served.drivePostBatch`
//! decides how much a batch may amplify. The bridge adds no policy of its
//! own — it owns only the verbs that let those owners reach each other: the
//! loop's per-connection hooks adopt each accepted peer into the host
//! (`Host.openAcceptedOver`) and serve each polled event through the host
//! (`Host.serveEvent`), and the host's action queue drains into the loop —
//! a `flush` action for connection B, queued while connection A was being
//! served, becomes `Loop.armOutbound(B)`, which is what puts a three-party
//! deposit on the exporter's wire (ADR-0076).
//!
//! Ownership: the caller owns the host and the loop; the bridge borrows
//! both. Teardown order is loop first (its teardown releases every adopted
//! connection through `freeConnCtx`), then the bridge, then the host.
//!
//! Dialing is refused fail-closed: a bridge-fed host answers every `dial`
//! action with `dialFailed`, so a give can be *minted* here (the deposit
//! rides an already-accepted exporter connection) but not *redeemed* here.
//! The loop-side dial executor is not implemented; it lands with a
//! loop-recipient consumer.

const std = @import("std");

const engine = @import("engine");
const net = @import("net");
const driver_core = @import("driver_core");

/// The `net.Loop` → `driver_core.Host` bridge. Construct with `init`, bind
/// the loop with `attach` (the loop needs the bridge's hooks at its own init,
/// so the two point at each other in two steps), and pass `makePeer` /
/// `makeConnCtx` / `serve` / `freeConnCtx` as the loop's hooks with the
/// bridge as `make_ctx`.
pub const LoopBridge = struct {
    allocator: std.mem.Allocator,
    /// Borrowed; the caller keeps it alive past the loop's teardown.
    host: *driver_core.Host,
    /// Borrowed; bound by `attach` before the loop runs.
    loop: *net.Loop,
    /// The entropy boundary for gift-id draws — the driver tier owns entropy,
    /// exactly as `drawSessionSecret` does for session secrets.
    io: std.Io,
    /// The listener's transport and dialable designator, signed into every
    /// accepted connection's keyed hello (what a partner can actually dial,
    /// and what a give made here names as the exporter location). Copied into
    /// retained buffers at `attach`, because the loop's bound port is only
    /// known after `Loop.init`.
    transport_buf: [16]u8 = undefined,
    transport_len: usize = 0,
    designator_buf: [64]u8 = undefined,
    designator_len: usize = 0,
    /// ConnId → loop slot, the map `drainActions` routes `flush` and `close`
    /// actions through. Bounded by live connections: a row is added at
    /// adoption and removed first thing in `freeConnCtx`, so a teardown drain
    /// can never arm a dead slot.
    slots: std.AutoHashMapUnmanaged(engine.ConnId, usize) = .{},
    /// Per-connection publish callback, run at adoption — before any inbound
    /// frame is served on the connection, so a partner's first fetch cannot
    /// race the registration (`driver_core.Publish`, the same seam the iroh
    /// loop host takes).
    publish: ?driver_core.Publish = null,
    publish_ctx: ?*anyopaque = null,
    on_open: ?OnOpen = null,
    on_open_ctx: ?*anyopaque = null,
    on_action: ?OnAction = null,
    on_action_ctx: ?*anyopaque = null,

    /// Fires once per connection, from the loop thread, the first time the
    /// connection's session is open — after the event that opened it was
    /// served, with the host's callback latch released, so top-level host
    /// verbs (`fetch`, `vowOn`, `send`) are legal here. End with nothing: the
    /// bridge drains the actions those verbs queued when the callback
    /// returns. An error closes that one connection.
    pub const OnOpen = *const fn (ctx: ?*anyopaque, bridge: *LoopBridge, conn: *LoopBridge.Conn) anyerror!void;

    /// Hears a `settled`/`failed` completion the drain popped for a vow with
    /// no in-process listener, borrowed for the call (the bridge frees the
    /// payload when it returns). Null drops such completions: an in-process
    /// consumer observes its vows with `Host.vowOn` instead.
    pub const OnAction = *const fn (ctx: ?*anyopaque, bridge: *LoopBridge, action: driver_core.HostAction) void;

    /// One adopted connection's bridge shell: what the loop's serve hook gets
    /// as its per-connection context. Bounded by live connections; freed in
    /// `freeConnCtx`.
    pub const Conn = struct {
        bridge: *LoopBridge,
        conn: *driver_core.HostConnection,
        slot: usize,
        opened: bool = false,
    };

    pub const Options = struct {
        publish: ?driver_core.Publish = null,
        publish_ctx: ?*anyopaque = null,
        on_open: ?OnOpen = null,
        on_open_ctx: ?*anyopaque = null,
        on_action: ?OnAction = null,
        on_action_ctx: ?*anyopaque = null,
    };

    pub fn init(allocator: std.mem.Allocator, host: *driver_core.Host, io: std.Io, options: Options) LoopBridge {
        return .{
            .allocator = allocator,
            .host = host,
            .loop = undefined,
            .io = io,
            .publish = options.publish,
            .publish_ctx = options.publish_ctx,
            .on_open = options.on_open,
            .on_open_ctx = options.on_open_ctx,
            .on_action = options.on_action,
            .on_action_ctx = options.on_action_ctx,
        };
    }

    /// Bind the loop and record the listener's dialable address. Call after
    /// `Loop.init` (the kernel-chosen port is known then) and before the loop
    /// serves its first connection.
    pub fn attach(self: *LoopBridge, loop: *net.Loop, transport: []const u8, designator: []const u8) !void {
        if (transport.len > self.transport_buf.len or designator.len > self.designator_buf.len)
            return error.DesignatorTooLong;
        self.loop = loop;
        @memcpy(self.transport_buf[0..transport.len], transport);
        self.transport_len = transport.len;
        @memcpy(self.designator_buf[0..designator.len], designator);
        self.designator_len = designator.len;
    }

    /// Free the bridge's own state. The loop's `deinit` already released
    /// every adopted connection through `freeConnCtx`; run this after the
    /// loop's teardown and before the host's.
    pub fn deinit(self: *LoopBridge) void {
        self.slots.deinit(self.allocator);
    }

    fn transportName(self: *const LoopBridge) []const u8 {
        return self.transport_buf[0..self.transport_len];
    }

    fn selfDesignator(self: *const LoopBridge) []const u8 {
        return self.designator_buf[0..self.designator_len];
    }

    // ── The loop hooks ───────────────────────────────────────────────────────

    /// `completion.MakePeer`: a bare negotiating peer. Every posture — frame
    /// cap, verify, codec, local-turn budget — lands at adoption, from the
    /// host's own options, so the loop and the host cannot disagree on it.
    pub fn makePeer(ctx: ?*anyopaque, allocator: std.mem.Allocator) anyerror!engine.Peer {
        _ = ctx;
        return engine.Peer.initNegotiating(allocator);
    }

    /// `completion.MakeConnCtx`: adopt the accepted peer into the host
    /// (keyed responder hello, node routing, enrollment), run the publish
    /// callback while no inbound frame can have been served yet, and drain
    /// the actions the adoption queued — which flushes the hello through
    /// `armOutbound`.
    pub fn makeConnCtx(ctx: ?*anyopaque, peer: *engine.Peer, slot: usize) anyerror!?*anyopaque {
        const self: *LoopBridge = @ptrCast(@alignCast(ctx.?));
        const host_conn = try self.host.openAcceptedOver(peer, self.transportName(), self.selfDesignator());
        errdefer self.host.releaseConn(host_conn) catch {};
        if (self.publish) |publish| try publish(self.publish_ctx, &host_conn.served);
        const shell = try self.allocator.create(Conn);
        errdefer self.allocator.destroy(shell);
        shell.* = .{ .bridge = self, .conn = host_conn, .slot = slot };
        try self.slots.put(self.allocator, host_conn.conn_id, slot);
        errdefer std.debug.assert(self.slots.remove(host_conn.conn_id));
        try self.drainActions();
        return shell;
    }

    /// `completion.Serve`: serve the polled event through the host (crossed
    /// hellos, auto-redeem, give origination, the budgeted drive all run in
    /// there), fire `on_open` on the session-open edge, and drain what the
    /// serve queued. An error closes that one connection, after a best-effort
    /// drain so sibling flushes the failed dispatch queued still leave.
    pub fn serve(conn_ctx: ?*anyopaque, peer: *engine.Peer, event: *engine.Event) anyerror!void {
        _ = peer;
        const shell: *Conn = @ptrCast(@alignCast(conn_ctx.?));
        const self = shell.bridge;
        self.host.serveEvent(shell.conn, event) catch |err| {
            self.drainActions() catch {};
            return err;
        };
        if (!shell.opened and shell.conn.sessionOpen()) {
            shell.opened = true;
            if (self.on_open) |on_open| try on_open(self.on_open_ctx, self, shell);
        }
        try self.drainActions();
    }

    /// `completion.FreeConnCtx`: release the adopted connection and free the
    /// shell. The map row goes first, so the drain below — the release's node
    /// sweep fails sibling withdraws closed and may queue sibling flushes —
    /// can arm sibling slots but never the dead one (and `armOutbound`
    /// no-ops on non-open slots anyway). The peer itself stays the loop's:
    /// its teardown deinits it after this returns.
    pub fn freeConnCtx(ctx: ?*anyopaque, conn_ctx: ?*anyopaque) void {
        const self: *LoopBridge = @ptrCast(@alignCast(ctx.?));
        const shell: *Conn = @ptrCast(@alignCast(conn_ctx orelse return));
        std.debug.assert(self.slots.remove(shell.conn.conn_id));
        self.host.releaseConn(shell.conn) catch {};
        self.drainActions() catch {};
        self.allocator.destroy(shell);
    }

    // ── The action drain ─────────────────────────────────────────────────────

    /// Drain the host's action queue into the loop. Every bridge entry point
    /// ends with this, and every action on the queue was put there by a host
    /// verb the bridge itself (or an embedder callback it ran) invoked, so no
    /// self-wake is ever needed. Public because an embedder callback that ran
    /// its own top-level host verbs outside a bridge entry (a test harness, a
    /// custom serve wrapper) must drain what those verbs queued.
    ///
    /// The arms: `flush` for connection B becomes `armOutbound(B)` — the
    /// cross-connection outbound arm, how a deposit reaches an exporter
    /// connection the loop was not serving; `close` flushes the condemned
    /// connection's typed abort and closes its slot; `need_gift_id` draws 32
    /// bytes at this tier's entropy boundary; `dial` is refused fail-closed
    /// (`dialFailed`, see the module header); `settled`/`failed` hand to
    /// `on_action` when set and are dropped otherwise. The arm set lives once
    /// in `driver_core.drainActions`; this tier only supplies the per-arm I/O.
    pub fn drainActions(self: *LoopBridge) !void {
        const Exec = struct {
            bridge: *LoopBridge,

            pub fn flush(e: @This(), conn_id: engine.ConnId) !void {
                if (e.bridge.slots.get(conn_id)) |slot| e.bridge.loop.armOutbound(slot);
            }

            pub fn close(e: @This(), conn_id: engine.ConnId) !void {
                if (e.bridge.slots.get(conn_id)) |slot| e.bridge.loop.closeSlot(slot);
            }

            pub fn dial(e: @This(), d: driver_core.HostAction.Dial) !void {
                try e.bridge.host.dialFailed(d.ticket, "the loop bridge does not dial");
            }

            pub fn complete(e: @This(), action: driver_core.HostAction) !void {
                defer e.bridge.host.freeAction(action);
                if (e.bridge.on_action) |on_action| on_action(e.bridge.on_action_ctx, e.bridge, action);
            }
        };
        try driver_core.drainActions(self.host, self.io, Exec{ .bridge = self });
    }
};
