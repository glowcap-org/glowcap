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
//! host (`Host.openAcceptedAdvertisedOver` / `Host.openDialedOver`) and serve each
//! polled event through the host (`Host.serveEvent`), and the host's action
//! queue drains into the loop — a `flush` action for session B, queued
//! while session A was being served, becomes `Loop.armOutbound(B)`, which
//! is what puts a three-party deposit on the exporter's wire; a `dial`
//! action becomes `Loop.dialLocator` with the complete OCapN locator, then,
//! once the session opens, `Host.exporterDialed` (ADR-0076). The Loop's
//! transport resolver interprets its hints; the Backend connects —
//! netlayers own networking; the bridge stays above that boundary.
//!
//! Ownership: the caller owns the host and the loop; the bridge borrows
//! both. Construct with `init` (passing the loop's storage address), then
//! `Loop.init` into that storage, then `attach` for the listener designator.
//! Teardown order is loop first (its teardown releases every adopted
//! connection through `freeConnCtx`), then the bridge, then the host.
//!
//! An iroh-backed loop and a TCP loop share this bridge for
//! accept/serve/flush/redeem: dial dispatch is DialResolver-owned, not branched here.
//!
//! A loop whose DialResolver speaks `keyed-relay` owns TCP connect, WebSocket
//! upgrade, frame I/O, and close at the completion layer. Bridge never opens a
//! blocking side wire: every adopted session is a Loop slot under one admission
//! budget and one action-routing map.

const std = @import("std");

const model = @import("model");
const engine = @import("engine");
const driver_core = @import("driver_core");
const settle_mailbox = @import("settle_mailbox.zig");
const foundation = @import("foundation");
const net = @import("net");

/// In-flight outbound connect: correlates a loop slot to its adoption
/// payload until `makeConnCtx` adopts the peer or `onClose` reports refusal.
/// App dials own transport/designator (no Node pending row). Redeem dials
/// store only the ticket — parts stay on the Node row until `exporterDialed`.
const OutboundConnect = union(enum) {
    app_dial: struct { transport: []u8, designator: []u8 },
    redeem: engine.Node.PendingId,

    fn deinit(self: OutboundConnect, allocator: std.mem.Allocator) void {
        switch (self) {
            .app_dial => |a| {
                allocator.free(a.transport);
                allocator.free(a.designator);
            },
            .redeem => {},
        }
    }
};

/// The completion-loop to `driver_core.Host` bridge, generic over the loop
/// type so TCP (`net.TcpLoop`) and iroh (`completion.Loop(iroh.Backend, iroh.DialResolver)`) share
/// one translator. Construct with `init` (the loop storage address is known
/// before `Loop.init` fills it), fill the loop with `hookOptions` as the loop
/// options and `makePeer` / `@ptrCast(&bridge)` as the peer factory, then
/// `attach` the listener designator.
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
        /// The attached listener transport. Its complete advertised locator is
        /// owned by `Host.node`; only the transport is retained here to select
        /// that snapshot when an accepted connection arrives.
        transport: ?[]const u8 = null,
        /// PeerId to loop slot, the map `drainActions` routes `flush` and `close`
        /// actions through. Bounded by live CapTP sessions: a row is added at
        /// adoption and removed first thing in `freeConnCtx`, so a teardown drain
        /// can never arm a dead slot.
        slots: std.AutoHashMapUnmanaged(engine.PeerId, usize) = .{},
        /// Slot to in-flight outbound connect. Inserted by `Exec.dial` /
        /// `dialOutbound` after `dialLocator`; removed by `makeConnCtx`
        /// (connect ok) or `onClose` (connect refused). Bounded by concurrent
        /// outbound connects.
        pending_connects: std.AutoHashMapUnmanaged(usize, OutboundConnect) = .{},
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
        /// A finite Host quantum left work for the next loop turn. The Loop's
        /// pre-poll hook consumes one continuation per reactor turn.
        resume_pending: bool = false,
        /// First failure crossing a void completion-loop callback. The next
        /// adapter turn returns it through `Loop.run` / `runUntil`; teardown
        /// callers can inspect it through `terminalFailure` after draining.
        terminal_failure: ?anyerror = null,
        /// The off-turn settle mailbox this bridge applies on wake (ADR-0102
        /// stage 4); borrowed, armed by `attachSettleMailbox`.
        mailbox: ?*settle_mailbox.SettleMailbox = null,
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
        /// `exporterDialed` clears it to `.redeem_open`, or `dialFailed` clears
        /// it to `.redeem_done`.
        pub const Leg = union(enum) {
            accept,
            app_dial,
            /// Redeem dial awaiting `exporterDialed` once the session opens.
            redeem: engine.Node.PendingId,
            /// Redeem dial whose ticket was reported via `exporterDialed`; still
            /// distinct from `app_dial` so `on_open` can tell the two dial
            /// shapes apart.
            redeem_open,
            /// Redeem dial whose ticket was already reported via `dialFailed`
            /// (open failure or freeConnCtx). Never reuse `.app_dial` for this.
            redeem_done,
        };

        /// One adopted connection's bridge shell: what the loop's serve hook
        /// gets as its per-connection context and what `on_open` observes.
        /// Bounded by live Loop connections and freed in `freeConnCtx`.
        pub const Slot = struct {
            bridge: *Self,
            session: *driver_core.HostSession,
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

        /// The loop options every Bridge embedder wires: `base` with this
        /// bridge's connection, scheduling, and ownership hooks spliced in.
        /// Callers set only the
        /// runtime-policy and metrics fields (`outbound_high_water_bytes`,
        /// `max_conns`, `listen`, `on_park`, …)
        /// and pass `makePeer` / `@ptrCast(bridge)` alongside to
        /// `Loop.init` / `initWithBackend`; a hand-wired hook set that skips
        /// one callback is an adoption leak, so the splice is the API.
        pub fn hookOptions(base: net.completion.Options) net.completion.Options {
            var options = base;
            options.make_conn_ctx = makeConnCtx;
            options.serve = serve;
            options.free_conn_ctx = freeConnCtx;
            options.on_close = onClose;
            options.on_loop_turn = onLoopTurn;
            options.on_driver_exit = onDriverExit;
            return options;
        }

        /// Record the listener's dialable address. Call after `Loop.init` (the
        /// kernel-chosen port is known then) and before the loop serves its first
        /// connection. Refuses a second attach — the bridge points at exactly one
        /// listener identity for its lifetime. Publishes one complete locator
        /// snapshot on the Host so dialed and accepted hellos read the same
        /// value. On a key-designator transport, pass the bound address as
        /// `direct_addresses_hint` (TCP has no discovery); address transports
        /// leave it empty.
        pub fn attach(
            self: *Self,
            profile: model.transport.Metadata,
            designator: []const u8,
            direct_addresses_hint: []const u8,
        ) !void {
            if (self.transport != null) return error.AlreadyAttached;
            const transport = try self.host.defineTransport(profile);
            var hint_entries: [1]model.HintEntry = undefined;
            try self.host.setAdvertisedLocator(.{
                .transport = transport,
                .designator = designator,
                .hints = model.Hints.forDirectAddresses(direct_addresses_hint, &hint_entries),
            });
            self.transport = transport;
        }

        /// Free the bridge's own state. The loop's `deinit` already released
        /// every adopted connection through `freeConnCtx`; run this after the
        /// loop's teardown and before the host's. Any stranded app-dial connect
        /// (loop torn down mid-connect) frees its duped strings here.
        pub fn deinit(self: *Self) void {
            var it = self.pending_connects.valueIterator();
            while (it.next()) |pending| pending.deinit(self.allocator);
            self.pending_connects.deinit(self.allocator);
            self.slots.deinit(self.allocator);
        }

        fn transportName(self: *const Self) []const u8 {
            return self.transport orelse &.{};
        }

        fn recordTerminalFailure(self: *Self, err: anyerror) void {
            if (self.terminal_failure == null) self.terminal_failure = err;
            self.resume_pending = true;
        }

        pub fn terminalFailure(self: *const Self) ?anyerror {
            return self.terminal_failure;
        }

        fn drainOrRecord(self: *Self) void {
            self.drainActions() catch |err| self.recordTerminalFailure(err);
        }

        /// Attach the off-turn settle mailbox (ADR-0102 stage 4): the loop's
        /// wake arms on the mailbox's fd, a worker's `post` re-enters here on
        /// the loop thread, and the drain writes what the settles flushed.
        /// Call on the loop thread, before workers hold the mailbox; the
        /// mailbox is borrowed and must outlive the loop.
        pub fn attachSettleMailbox(self: *Self, mailbox: *settle_mailbox.SettleMailbox) !void {
            self.mailbox = mailbox;
            // A refused arm must not leave the bridge claiming a mailbox it
            // will never apply.
            errdefer self.mailbox = null;
            try self.loop.armWake(mailbox.wakeFd(), self, applySettleWake);
        }

        fn applySettleWake(ctx: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            const mb = self.mailbox orelse return;
            mb.drainWake() catch |err| {
                self.recordTerminalFailure(err);
            };
            mb.apply(self.io, self.host) catch |err| {
                self.recordTerminalFailure(err);
            };
            self.drainOrRecord();
        }

        /// Submit an application outbound dial the bridge will adopt as
        /// `openDialedOver` once the connect completes. Redeem dials use the
        /// action-queue path (`Exec.dial`) instead. Call from the loop-owner
        /// thread (same affinity as `Loop.dialLocator`) — before
        /// `run` or from a hook. The Loop's DialResolver resolves the OCapN locator parts.
        pub fn dialOutbound(
            self: *Self,
            locator: model.PeerLocator,
        ) !void {
            return self.dialApplication(.ordinary, locator);
        }

        /// Submit a bounded control-plane dial through the Loop's reserved
        /// capacity. The loop options must reserve at least one slot; ordinary
        /// application and handoff dials continue through `dialOutbound`.
        pub fn dialOutboundReserved(
            self: *Self,
            locator: model.PeerLocator,
        ) !void {
            return self.dialApplication(.reserved, locator);
        }

        fn dialApplication(
            self: *Self,
            admission: net.completion.DialAdmission,
            locator: model.PeerLocator,
        ) !void {
            // Pack owned strings first so errdefers stop at the block boundary;
            // connectOutbound owns the OutboundConnect on every exit path.
            const connect: OutboundConnect = blk: {
                const transport_owned = try self.allocator.dupe(u8, locator.transport);
                errdefer self.allocator.free(transport_owned);
                const designator_owned = try self.allocator.dupe(u8, locator.designator);
                errdefer self.allocator.free(designator_owned);
                break :blk .{
                    .app_dial = .{
                        .transport = transport_owned,
                        .designator = designator_owned,
                    },
                };
            };
            try self.connectOutbound(
                self.loop,
                connect,
                admission,
                locator,
            );
        }

        /// Close the loop connection serving `peer_id`, if one is still adopted.
        /// The slot row leaves in
        /// `freeConnCtx` before the session's release, so a stale or already-torn
        /// id no-ops — the same spine `drainActions`' close arm rides. Call from
        /// the loop-owner thread only (`Loop.closeSlot` affinity).
        pub fn closeConn(self: *Self, peer_id: engine.PeerId) void {
            if (self.slots.get(peer_id)) |slot| {
                self.loop.closeSlot(slot);
            }
        }

        /// Interrupt a redeem connection that has not yet published a Host
        /// session. An already-adopted leg is closed by the core's ordinary
        /// session `close` action; its `freeConnCtx` sends the same terminal
        /// acknowledgement after the physical slot retires.
        fn cancelDial(self: *Self, ticket: engine.Node.PendingId) void {
            var it = self.pending_connects.iterator();
            while (it.next()) |entry| switch (entry.value_ptr.*) {
                .redeem => |pending| if (pending == ticket) {
                    self.loop.closeSlot(entry.key_ptr.*);
                    return;
                },
                .app_dial => {},
            };
        }

        /// Whether `slot` is an application dial whose connection completed
        /// but whose Host adoption has not committed. An embedder replacing
        /// `on_close` uses this before forwarding to `Bridge.onClose`, because
        /// an adoption failure has `opened == true` but no connection context.
        pub fn pendingAppDial(self: *const Self, slot: usize) bool {
            const pending = self.pending_connects.get(slot) orelse return false;
            return pending == .app_dial;
        }

        /// Shared dial spine for app and redeem. Every transport goes through
        /// `dialLocator`; the Loop's DialResolver and Backend own acquisition. Takes
        /// ownership of `connect` (map on success, deinit on refusal).
        fn connectOutbound(
            self: *Self,
            loop: *LoopT,
            connect: OutboundConnect,
            admission: net.completion.DialAdmission,
            locator: model.PeerLocator,
        ) !void {
            errdefer connect.deinit(self.allocator);
            try self.pending_connects.ensureUnusedCapacity(self.allocator, 1);
            const slot = switch (admission) {
                .ordinary => try loop.dialLocator(locator),
                .reserved => try loop.dialLocatorReserved(locator),
            };
            const gop = self.pending_connects.getOrPutAssumeCapacity(slot);
            std.debug.assert(!gop.found_existing);
            gop.value_ptr.* = connect;
        }

        fn fireOpen(self: *Self, shell: *Slot) anyerror!void {
            if (shell.opened) return;
            if (!shell.session.sessionOpen()) return;
            shell.opened = true;
            if (shell.leg == .redeem) {
                const ticket = shell.leg.redeem;
                self.host.exporterDialed(ticket, shell.session) catch |err| {
                    self.host.dialFailed(ticket, @errorName(err)) catch |report_err|
                        self.recordTerminalFailure(report_err);
                    shell.leg = .redeem_done;
                    self.drainOrRecord();
                    return err;
                };
                shell.leg = .redeem_open;
            }
            if (self.on_open) |on_open| try on_open(self.on_open_ctx, self, shell);
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
        /// host. Origin is one lookup: a `pending_connects` row means dial
        /// (`openDialedOver`, redeem or application); absence means accept
        /// (`openAcceptedAdvertisedOver` + publish).
        pub fn makeConnCtx(ctx: ?*anyopaque, peer: *engine.Peer, slot: usize) anyerror!?*anyopaque {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            var leg: Leg = .accept;
            const pending_connect = self.pending_connects.get(slot);
            const session = if (pending_connect) |pending| blk: {
                // One switch: pieces, Leg, and redeem refuse share one arm.
                break :blk switch (pending) {
                    .app_dial => |a| open: {
                        leg = .app_dial;
                        break :open try self.host.openDialedOver(peer, a.transport, a.designator);
                    },
                    .redeem => |t| open: {
                        leg = .{ .redeem = t };
                        const view = self.host.pendingDial(t) orelse return error.MissingPendingDial;
                        break :open try self.host.openDialedOver(peer, view.transport, view.designator);
                    },
                };
            } else try self.host.openAcceptedAdvertisedOver(peer, self.transportName());
            errdefer self.host.releaseSession(session) catch unreachable;
            // The transport proof (ADR-0105): when the loop's backend verified
            // the remote's durable key (iroh's QUIC handshake), this is the
            // code that realized the connection and so the one that may say
            // so. Every leg, because the proof is the connection's, not the
            // direction's; socket-backed loops carry no lower-layer identity
            // and answer null.
            //
            // After the leg opened rather than before it, and it is safe to
            // wait: no partner byte has been fed yet, since the loop arms this
            // connection's reads only once adoption returns, and everything
            // above it only sent this side's own hello.
            if (self.loop.verifiedChannelKey(slot)) |key| {
                peer.bindVerifiedChannelKey(foundation.crypto.PeerKey.fromBytes(key));
            }
            // Publish only on accepted desks — never on dialed exporter/app legs.
            if (session.role == .accepted) {
                if (self.publish) |publish| try publish(self.publish_ctx, &session.served, &self.host.vat);
            }
            const shell = try self.allocator.create(Slot);
            errdefer self.allocator.destroy(shell);
            shell.* = .{
                .bridge = self,
                .session = session,
                .leg = leg,
            };
            try self.slots.put(self.allocator, session.peer_id, slot);
            errdefer std.debug.assert(self.slots.remove(session.peer_id));
            try self.drainActions();
            // Commit the connect only after every fallible adoption step. If
            // any step above refuses, `onClose` still owns this row and can
            // classify an opened connection with no context as a failed app or
            // redeem dial instead of mistaking it for an accepted connection.
            if (pending_connect != null) {
                const committed = self.pending_connects.fetchRemove(slot) orelse unreachable;
                committed.value.deinit(self.allocator);
            }
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
                self.drainOrRecord();
                return err;
            };
            try self.fireOpen(shell);
            try self.drainActions();
        }

        /// `completion.FreeConnCtx`: release the adopted connection and free the
        /// shell. A redeem that never reached session open reports `dialFailed`
        /// first so the node's ticket cannot strand.
        pub fn freeConnCtx(ctx: ?*anyopaque, conn_ctx: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            const shell: *Slot = @ptrCast(@alignCast(conn_ctx orelse return));
            if (shell.leg == .redeem) {
                const ticket = shell.leg.redeem;
                self.host.dialFailed(ticket, "ConnectionClosed") catch |err|
                    self.recordTerminalFailure(err);
                self.host.dialCancelled(ticket) catch |err|
                    self.recordTerminalFailure(err);
                shell.leg = .redeem_done;
            }
            // Loop teardown calls this exactly once for a published context.
            std.debug.assert(self.slots.remove(shell.session.peer_id));
            // The loop calls this after the serve hook has returned, on the
            // owning thread. A refusal would leave Host authority borrowing a
            // peer the loop is about to free, so it is an invariant violation,
            // never optional cleanup.
            self.host.releaseSession(shell.session) catch unreachable;
            // During Loop.closeAndDrain, draining would re-enter dial/arm and
            // prevent the in-flight ops from retiring.
            if (!(self.loop.shutting_down or self.loop.tearing_down)) self.drainOrRecord();
            self.allocator.destroy(shell);
        }

        /// `completion.OnClose`: a refused connect or Host-adoption failure
        /// never publishes a shell, so the pending dial row is the only place
        /// the ticket lives — report `dialFailed` and free it. Teardowns with a
        /// published context are handled by `freeConnCtx`.
        pub fn onClose(ctx: ?*anyopaque, slot: usize, conn_ctx: ?*anyopaque, report: net.completion.CloseReport) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            if (conn_ctx != null) return;
            const pending = (self.pending_connects.fetchRemove(slot) orelse return).value;
            defer pending.deinit(self.allocator);
            switch (pending) {
                .redeem => |t| {
                    const failure = if (report.failure) |cause| cause.error_name else if (report.opened)
                        "ConnectionClosed"
                    else
                        "ConnectionRefused";
                    self.host.dialFailed(t, failure) catch |err|
                        self.recordTerminalFailure(err);
                    self.host.dialCancelled(t) catch |err|
                        self.recordTerminalFailure(err);
                    self.drainOrRecord();
                },
                .app_dial => {},
            }
        }

        /// Completion-loop driver exit: transfer the unsynchronized Host back
        /// to an unclaimed, quiescent state before the driving thread returns.
        /// The caller may then join that thread and tear the Host down from its
        /// own thread without weakening the one-thread-at-a-time contract.
        fn onDriverExit(ctx: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.host.releaseDriverOwnership();
        }

        /// Completion-loop scheduling hook: run at most one deferred Host
        /// quantum, then force this backend poll non-blocking. Returning to the
        /// loop between continuations lets already-ready network completions
        /// share the owner thread with Host work.
        fn onLoopTurn(ctx: ?*anyopaque) anyerror!bool {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            if (self.terminal_failure) |err| return err;
            if (!self.resume_pending) return false;
            try self.drainActions();
            if (self.terminal_failure) |err| return err;
            return true;
        }

        // ── The action drain ─────────────────────────────────────────────────────

        /// Drain the host's action queue into the loop. Every bridge entry point
        /// ends with this. A finite Host slice parks `resume_pending`; the
        /// Loop's pre-poll adapter hook runs the next slice on a later reactor
        /// turn without a helper thread or private wake descriptor. Public
        /// because an embedder callback that ran its own top-level host verbs
        /// outside a bridge entry (a test harness, a custom serve wrapper) must
        /// drain what those verbs queued.
        ///
        /// The arms: `flush` for connection B becomes `armOutbound(B)` — the
        /// cross-connection outbound arm; `close` flushes the condemned
        /// connection's typed abort and closes its slot; `need_gift_id` draws 32
        /// bytes at this tier's entropy boundary; `dial` forwards OCapN locator
        /// parts through `Loop.dialLocator` (DialResolver resolves, Backend connects), and
        /// parks the ticket under the slot until connect completes or refuses;
        /// `settled`/`failed` hand to `on_action` when set and are dropped
        /// otherwise. The arm set lives once in `driver_core.drainActions`; this
        /// tier only supplies the per-arm I/O.
        pub fn drainActions(self: *Self) !void {
            const Exec = struct {
                bridge: *Self,
                loop: *LoopT,

                pub fn flush(e: @This(), peer_id: engine.PeerId) !void {
                    if (e.bridge.slots.get(peer_id)) |slot| {
                        e.loop.armOutbound(slot);
                    }
                }

                pub fn close(e: @This(), peer_id: engine.PeerId) !void {
                    e.bridge.closeConn(peer_id);
                }

                pub fn dial(e: @This(), d: @FieldType(driver_core.HostAction, "dial")) !void {
                    const bridge = e.bridge;
                    const view = bridge.host.pendingDial(d.ticket) orelse {
                        try bridge.host.dialFailed(d.ticket, "pending dial missing");
                        return;
                    };
                    // Live rows always have non-empty transport/designator
                    // (acceptGive fails unparseable gives closed).
                    bridge.connectOutbound(
                        e.loop,
                        .{ .redeem = d.ticket },
                        .ordinary,
                        view,
                    ) catch |err| {
                        // Stack detail is copied inside `node.dialFailed` before return.
                        // Include a short designator prefix so InvalidAddress digs
                        // can see exporter shape without a second logging path.
                        const prefix_len = @min(view.designator.len, 16);
                        var detail: [192]u8 = undefined;
                        const reason = std.fmt.bufPrint(&detail, "{s} transport={s} designatorLen={d} designatorPrefix={s} hintCount={d}", .{
                            @errorName(err),
                            view.transport,
                            view.designator.len,
                            view.designator[0..prefix_len],
                            view.hints.entries.len,
                        }) catch @errorName(err);
                        try bridge.host.dialFailed(d.ticket, reason);
                    };
                }

                pub fn cancelDial(e: @This(), d: @FieldType(driver_core.HostAction, "cancel_dial")) !void {
                    e.bridge.cancelDial(d.ticket);
                }

                pub fn complete(e: @This(), action: driver_core.HostAction) !void {
                    defer e.bridge.host.freeAction(action);
                    if (e.bridge.on_action) |on_action| on_action(e.bridge.on_action_ctx, e.bridge, action);
                }
            };
            self.resume_pending = false;
            const result = driver_core.drainActions(
                self.host,
                self.io,
                Exec{ .bridge = self, .loop = self.loop },
            ) catch |err| {
                // Preparation failures leave the current Host action parked.
                // A caller may re-enter `run` after pressure subsides, so keep
                // the pre-poll continuation live across that return.
                self.resume_pending = true;
                return err;
            };
            self.resume_pending = result == .yielded;
        }
    };
}
