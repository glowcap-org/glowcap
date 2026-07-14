//! `Bridge`: the translator that feeds the byte-fed multi-session CapTP host
//! (`driver_core.Host`) from a completion loop (`completion.Loop` over any
//! Backend — the platform TCP `net.TcpLoop`, or an iroh-bound loop).
//!
//! Every decision it relays already has one owner. The host's `drainWork`
//! decides which CapTP sessions to flush and when one is condemned; the loop's
//! `flushOutbound` decides how bytes reach a socket; `Served.drivePostBatch`
//! decides how much a batch may amplify. The bridge adds no policy of its
//! own — it owns only the verbs that let those owners reach each other: the
//! loop's per-slot hooks adopt each accepted or dialed peer into the
//! host (`Host.openAcceptedOver` / `Host.openDialedOver`) and serve each
//! polled event through the host (`Host.serveEvent`), and the host's action
//! queue drains into the loop — a `flush` action for session B, queued
//! while session A was being served, becomes `Loop.armOutbound(B)`, which
//! is what puts a three-party deposit on the exporter's wire; a `dial`
//! action becomes `Loop.dialLocator` with OCapN locator parts (transport,
//! designator, hint), then, once the session opens, `Host.exporterDialed`
//! (ADR-0076). The Loop's Locator resolves those parts; the Backend connects —
//! netlayers own networking; the bridge stays above that boundary.
//!
//! Ownership: the caller owns the host and the loop; the bridge borrows
//! both. Construct with `init` (passing the loop's storage address), then
//! `Loop.init` into that storage, then `attach` for the listener designator.
//! Teardown order is loop first (its teardown releases every adopted
//! connection through `freeConnCtx`), then the bridge, then the host.
//!
//! An iroh-backed loop and a TCP loop share this bridge for
//! accept/serve/flush/redeem: dial dispatch is Locator-owned, not branched here.

const std = @import("std");

const engine = @import("engine");
const driver_core = @import("driver_core");

/// Which dial produced a `PendingDial`: an application dial (`dialOutbound`)
/// carries no ticket, a redeem dial from the host's action queue carries the
/// node's pending ticket. One sum, the same shape the file's `Leg` established
/// over a bool-plus-optional-ticket — "app dial with a ticket" and "redeem with
/// none" are unconstructible. `makeConnCtx` maps it straight onto the adopted
/// session's `Leg`.
const DialKind = union(enum) {
    app_dial,
    redeem: engine.Node.PendingId,
};

/// In-flight outbound connect: correlates a loop slot to its adoption
/// payload until `makeConnCtx` adopts the peer or `onClose` reports refusal.
const PendingDial = struct {
    kind: DialKind,
    transport: []u8,
    designator: []u8,

    fn deinit(self: PendingDial, allocator: std.mem.Allocator) void {
        allocator.free(self.transport);
        allocator.free(self.designator);
    }
};

/// The completion-loop → `driver_core.Host` bridge, generic over the loop
/// type so TCP (`net.TcpLoop`) and iroh (`completion.Loop(iroh.Backend, iroh.DialResolver)`) share
/// one translator. Construct with `init` (the loop storage address is known
/// before `Loop.init` fills it), fill the loop, then `attach` the listener
/// designator, and pass `makePeer` / `makeConnCtx` / `serve` / `freeConnCtx` /
/// `onClose` as the loop's hooks with the bridge as `make_ctx`.
pub fn Bridge(comptime LoopT: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        /// Borrowed; the caller keeps it alive past the loop's teardown.
        host: *driver_core.Host,
        /// Borrowed; points at the caller's loop storage from `init` (filled
        /// by a subsequent `Loop.init` into that same storage).
        loop: *LoopT,
        /// The entropy boundary for gift-id draws — the driver tier owns entropy,
        /// exactly as `drawSessionSecret` does for session secrets.
        io: std.Io,
        /// The listener's transport and dialable designator, signed into every
        /// accepted CapTP session's keyed hello (what a partner can actually dial,
        /// and what a give made here names as the exporter location). Copied into
        /// retained buffers at `attach`, because the loop's bound port is only
        /// known after `Loop.init`.
        transport_buf: [16]u8 = undefined,
        transport_len: usize = 0,
        designator_buf: [64]u8 = undefined,
        designator_len: usize = 0,
        /// Bound dial address for a key-designator transport (`keyed-tcp`),
        /// signed into every accepted CapTP session's locator as the
        /// `direct-addresses` hint. Empty for address-designator transports.
        hint_buf: [64]u8 = undefined,
        hint_len: usize = 0,
        /// PeerId → loop slot, the map `drainActions` routes `flush` and `close`
        /// actions through. Bounded by live CapTP sessions: a row is added at
        /// adoption and removed first thing in `freeConnCtx`, so a teardown drain
        /// can never arm a dead slot.
        slots: std.AutoHashMapUnmanaged(engine.PeerId, usize) = .{},
        /// Slot → in-flight outbound dial. Inserted by `Exec.dial` / `dialOutbound`
        /// after `dialLocator`; removed by `makeConnCtx` (connect ok) or
        /// `onClose` (connect refused). Bounded by concurrent outbound connects.
        pending_dials: std.AutoHashMapUnmanaged(usize, PendingDial) = .{},
        /// Per-session publish callback, run at *accepted* adoption — before
        /// any inbound frame is served on the session, so a partner's first
        /// fetch cannot race the registration (`driver_core.Publish`). Dialed
        /// (redeem) legs skip it: they are exporter sessions, not desks.
        publish: ?driver_core.Publish = null,
        publish_ctx: ?*anyopaque = null,
        on_open: ?OnOpen = null,
        on_open_ctx: ?*anyopaque = null,
        on_action: ?OnAction = null,
        on_action_ctx: ?*anyopaque = null,

        /// Fires once per CapTP session, from the loop thread, the first time the
        /// session is open — after the event that opened it was served, with the
        /// host's callback latch released, so top-level host verbs (`fetch`,
        /// `vowOn`, `send`) are legal here. End with nothing: the bridge drains
        /// the actions those verbs queued when the callback returns. An error
        /// closes that one session.
        pub const OnOpen = *const fn (ctx: ?*anyopaque, bridge: *Self, slot: *Slot) anyerror!void;

        /// Hears a `settled`/`failed` completion the drain popped for a vow with
        /// no in-process listener, borrowed for the call (the bridge frees the
        /// payload when it returns). Null drops such completions: an in-process
        /// consumer observes its vows with `Host.vowOn` instead.
        pub const OnAction = *const fn (ctx: ?*anyopaque, bridge: *Self, action: driver_core.HostAction) void;

        /// How this session entered the host — one sum type, not a bool +
        /// optional ticket pair. A redeem leg carries its pending ticket until
        /// `exporterDialed` (or `dialFailed`) clears it to `.redeem_open`.
        pub const Leg = union(enum) {
            accept,
            app_dial,
            /// Redeem dial awaiting `exporterDialed` once the session opens.
            redeem: engine.Node.PendingId,
            /// Redeem dial whose ticket was reported; still distinct from
            /// `app_dial` so `on_open` can tell the two dial shapes apart.
            redeem_open,
        };

        /// One adopted connection's bridge shell: what the loop's serve hook gets
        /// as its per-connection context. Bounded by live connections; freed in
        /// `freeConnCtx`.
        pub const Slot = struct {
            bridge: *Self,
            session: *driver_core.HostSession,
            slot: usize,
            opened: bool = false,
            leg: Leg = .accept,
        };

        pub const Options = struct {
            publish: ?driver_core.Publish = null,
            publish_ctx: ?*anyopaque = null,
            on_open: ?OnOpen = null,
            on_open_ctx: ?*anyopaque = null,
            on_action: ?OnAction = null,
            on_action_ctx: ?*anyopaque = null,
        };

        /// `loop` is the caller's loop storage — typically `undefined` until a
        /// following `Loop.init` writes into it. The pointer is non-optional from
        /// construction so drain/dial never carry a nullable loop.
        pub fn init(allocator: std.mem.Allocator, host: *driver_core.Host, io: std.Io, loop: *LoopT, options: Options) Self {
            return .{
                .allocator = allocator,
                .host = host,
                .loop = loop,
                .io = io,
                .publish = options.publish,
                .publish_ctx = options.publish_ctx,
                .on_open = options.on_open,
                .on_open_ctx = options.on_open_ctx,
                .on_action = options.on_action,
                .on_action_ctx = options.on_action_ctx,
            };
        }

        /// Record the listener's dialable address. Call after `Loop.init` (the
        /// kernel-chosen port is known then) and before the loop serves its first
        /// connection. Refuses a second attach — the bridge points at exactly one
        /// listener identity for its lifetime. Also records the designator on the
        /// host so dialed hellos sign the same dialable address accepted hellos
        /// do. On a key-designator transport, pass the bound address as
        /// `direct_addresses_hint` (TCP has no discovery); address transports
        /// leave it empty.
        pub fn attach(self: *Self, transport: []const u8, designator: []const u8, direct_addresses_hint: []const u8) !void {
            if (self.transport_len != 0) return error.AlreadyAttached;
            if (transport.len > self.transport_buf.len or designator.len > self.designator_buf.len or
                direct_addresses_hint.len > self.hint_buf.len)
                return error.DesignatorTooLong;
            try self.host.setSelfDesignator(designator);
            @memcpy(self.transport_buf[0..transport.len], transport);
            self.transport_len = transport.len;
            @memcpy(self.designator_buf[0..designator.len], designator);
            self.designator_len = designator.len;
            @memcpy(self.hint_buf[0..direct_addresses_hint.len], direct_addresses_hint);
            self.hint_len = direct_addresses_hint.len;
        }

        /// Free the bridge's own state. The loop's `deinit` already released
        /// every adopted connection through `freeConnCtx`; run this after the
        /// loop's teardown and before the host's. Any stranded pending dial
        /// (loop torn down mid-connect) frees its duped strings here.
        pub fn deinit(self: *Self) void {
            var it = self.pending_dials.valueIterator();
            while (it.next()) |pending| pending.deinit(self.allocator);
            self.pending_dials.deinit(self.allocator);
            self.slots.deinit(self.allocator);
        }

        fn transportName(self: *const Self) []const u8 {
            return self.transport_buf[0..self.transport_len];
        }

        fn selfDesignator(self: *const Self) []const u8 {
            return self.designator_buf[0..self.designator_len];
        }

        fn selfHint(self: *const Self) []const u8 {
            return self.hint_buf[0..self.hint_len];
        }

        fn drainBestEffort(self: *Self) void {
            self.drainActions() catch {};
        }

        /// Submit an application outbound dial the bridge will adopt as
        /// `openDialedOver` once the connect completes. Redeem dials use the
        /// action-queue path (`Exec.dial`) instead. Call from the loop-owner
        /// thread (same affinity as `Loop.dialLocator`) — before
        /// `run` or from a hook. The Loop's Locator resolves the OCapN locator parts.
        pub fn dialOutbound(
            self: *Self,
            transport: []const u8,
            designator: []const u8,
            direct_addresses_hint: []const u8,
        ) !void {
            try self.submitPendingDial(self.loop, .app_dial, transport, designator, direct_addresses_hint);
        }

        fn submitPendingDial(
            self: *Self,
            loop: *LoopT,
            kind: DialKind,
            transport: []const u8,
            designator: []const u8,
            hint: []const u8,
        ) !void {
            const transport_owned = try self.allocator.dupe(u8, transport);
            errdefer self.allocator.free(transport_owned);
            const designator_owned = try self.allocator.dupe(u8, designator);
            errdefer self.allocator.free(designator_owned);
            const slot = try loop.dialLocator(transport, designator, hint);
            errdefer loop.closeSlot(slot);
            try self.pending_dials.put(self.allocator, slot, .{
                .kind = kind,
                .transport = transport_owned,
                .designator = designator_owned,
            });
        }

        // ── The loop hooks ───────────────────────────────────────────────────────

        /// `completion.MakePeer`: a bare negotiating peer. Every posture — frame
        /// cap, verify, codec, local-turn budget — lands at adoption, from the
        /// host's own options, so the loop and the host cannot disagree on it.
        pub fn makePeer(ctx: ?*anyopaque, allocator: std.mem.Allocator) anyerror!engine.Peer {
            _ = ctx;
            return engine.Peer.initNegotiating(allocator);
        }

        /// `completion.MakeConnCtx`: adopt the accepted or dialed peer into the
        /// host. Origin is one lookup: a `pending_dials` row means dial
        /// (`openDialedOver`, redeem or application); absence means accept
        /// (`openAcceptedOver` + publish).
        pub fn makeConnCtx(ctx: ?*anyopaque, peer: *engine.Peer, slot: usize) anyerror!?*anyopaque {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            var leg: Leg = .accept;
            const session = if (self.pending_dials.fetchRemove(slot)) |kv| blk: {
                const pending = kv.value;
                defer pending.deinit(self.allocator);
                leg = switch (pending.kind) {
                    .app_dial => .app_dial,
                    .redeem => |t| .{ .redeem = t },
                };
                break :blk self.host.openDialedOver(peer, pending.transport, pending.designator) catch |err| {
                    switch (pending.kind) {
                        .redeem => |t| self.host.dialFailed(t, @errorName(err)) catch {},
                        .app_dial => {},
                    }
                    return err;
                };
            } else try self.host.openAcceptedOver(peer, self.transportName(), self.selfDesignator(), self.selfHint());
            errdefer {
                if (leg == .redeem) self.host.dialFailed(leg.redeem, "ConnectionClosed") catch {};
                self.host.releaseSession(session) catch {};
            }
            // Publish only on accepted desks — never on dialed exporter/app legs.
            if (session.role == .accepted) {
                if (self.publish) |publish| try publish(self.publish_ctx, &session.served);
            }
            const shell = try self.allocator.create(Slot);
            errdefer self.allocator.destroy(shell);
            shell.* = .{
                .bridge = self,
                .session = session,
                .slot = slot,
                .leg = leg,
            };
            try self.slots.put(self.allocator, session.peer_id, slot);
            errdefer std.debug.assert(self.slots.remove(session.peer_id));
            try self.drainActions();
            return shell;
        }

        /// `completion.Serve`: serve the polled event through the host, report a
        /// completed redeem with `exporterDialed` on the session-open edge, fire
        /// `on_open`, and drain what the serve queued.
        pub fn serve(conn_ctx: ?*anyopaque, peer: *engine.Peer, event: *engine.Event) anyerror!void {
            _ = peer;
            const shell: *Slot = @ptrCast(@alignCast(conn_ctx.?));
            const self = shell.bridge;
            self.host.serveEvent(shell.session, event) catch |err| {
                self.drainBestEffort();
                return err;
            };
            if (!shell.opened and shell.session.sessionOpen()) {
                shell.opened = true;
                if (shell.leg == .redeem) {
                    const ticket = shell.leg.redeem;
                    self.host.exporterDialed(ticket, shell.session) catch |err| {
                        self.host.dialFailed(ticket, @errorName(err)) catch {};
                        shell.leg = .app_dial;
                        self.drainBestEffort();
                        return err;
                    };
                    shell.leg = .redeem_open;
                }
                if (self.on_open) |on_open| try on_open(self.on_open_ctx, self, shell);
            }
            try self.drainActions();
        }

        /// `completion.FreeConnCtx`: release the adopted connection and free the
        /// shell. A redeem that never reached session open reports `dialFailed`
        /// first so the node's ticket cannot strand.
        pub fn freeConnCtx(ctx: ?*anyopaque, conn_ctx: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            const shell: *Slot = @ptrCast(@alignCast(conn_ctx orelse return));
            if (shell.leg == .redeem) {
                self.host.dialFailed(shell.leg.redeem, "ConnectionClosed") catch {};
                shell.leg = .app_dial;
            }
            // idempotent: closeAndDrain and a racing deinit may free twice.
            _ = self.slots.remove(shell.session.peer_id);
            self.host.releaseSession(shell.session) catch {};
            // During Loop.closeAndDrain, draining would re-enter dial/arm and
            // prevent the in-flight ops from retiring.
            if (!(self.loop.shutting_down or self.loop.tearing_down)) self.drainBestEffort();
            self.allocator.destroy(shell);
        }

        /// `completion.OnClose`: a refused connect never builds a shell, so the
        /// pending dial row is the only place the ticket lives — report
        /// `dialFailed` and free it. Opened teardowns are handled by `freeConnCtx`.
        pub fn onClose(ctx: ?*anyopaque, slot: usize, conn_ctx: ?*anyopaque, opened: bool) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            if (conn_ctx != null) return;
            if (opened) return;
            const pending = (self.pending_dials.fetchRemove(slot) orelse return).value;
            defer pending.deinit(self.allocator);
            switch (pending.kind) {
                .redeem => |t| {
                    self.host.dialFailed(t, "ConnectionRefused") catch {};
                    self.drainBestEffort();
                },
                .app_dial => {},
            }
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
        /// cross-connection outbound arm; `close` flushes the condemned
        /// connection's typed abort and closes its slot; `need_gift_id` draws 32
        /// bytes at this tier's entropy boundary; `dial` forwards OCapN locator
        /// parts through `Loop.dialLocator` (Locator resolves, Backend connects), and
        /// parks the ticket under the slot until connect completes or refuses;
        /// `settled`/`failed` hand to `on_action` when set and are dropped
        /// otherwise. The arm set lives once in `driver_core.drainActions`; this
        /// tier only supplies the per-arm I/O.
        pub fn drainActions(self: *Self) !void {
            const Exec = struct {
                bridge: *Self,
                loop: *LoopT,

                pub fn flush(e: @This(), peer_id: engine.PeerId) !void {
                    if (e.bridge.slots.get(peer_id)) |slot| e.loop.armOutbound(slot);
                }

                pub fn close(e: @This(), peer_id: engine.PeerId) !void {
                    if (e.bridge.slots.get(peer_id)) |slot| e.loop.closeSlot(slot);
                }

                pub fn dial(e: @This(), d: driver_core.HostAction.Dial) !void {
                    const bridge = e.bridge;
                    bridge.submitPendingDial(e.loop, .{ .redeem = d.ticket }, d.transport, d.designator, d.direct_addresses_hint) catch |err| {
                        try bridge.host.dialFailed(d.ticket, @errorName(err));
                    };
                }

                pub fn complete(e: @This(), action: driver_core.HostAction) !void {
                    defer e.bridge.host.freeAction(action);
                    if (e.bridge.on_action) |on_action| on_action(e.bridge.on_action_ctx, e.bridge, action);
                }
            };
            try driver_core.drainActions(self.host, self.io, Exec{ .bridge = self, .loop = self.loop });
        }
    };
}
