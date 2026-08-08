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
//!
//! **Rendezvous side dial.** `keyed-relay` has no `completion.Loop` Backend
//! today: its byte path is a blocking `net.keyed_relay` resident over a
//! WebSocket (ADR-0088). When the embedder `attachRendezvous`s that netlayer,
//! `connectOutbound` answers a `keyed-relay` dial by blocking-dialing the
//! resident, adopting a side wire on this Host, and pumping the handshake on
//! the loop-owner thread — the same seam PollHost's `answerDial` uses, named
//! here so an iroh (or TCP) loop can still redeem browser peers. Call
//! `pumpRendezvous` from the embedder's wake so live side wires keep moving
//! after the handshake. Without `attachRendezvous`, a `keyed-relay` dial
//! fails loud (`NoRendezvousConfigured`).

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
        transport_buf: [16]u8 = undefined,
        transport_len: usize = 0,
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
        /// The off-turn settle mailbox this bridge applies on wake (ADR-0102
        /// stage 4); borrowed, armed by `attachSettleMailbox`.
        mailbox: ?*settle_mailbox.SettleMailbox = null,
        /// Optional `keyed-relay` netlayer for rendezvous redeem/app dials the
        /// Loop's Locator cannot resolve. Borrowed; the resident behind it must
        /// outlive every side wire. Set once via `attachRendezvous`.
        rendezvous_nl: ?net.netlayer.Netlayer = null,
        /// PeerId → side wire for sessions opened through `rendezvous_nl`.
        /// Orthogonal to `slots` (those name Loop connections).
        rendezvous_wires: std.AutoHashMapUnmanaged(engine.PeerId, *RendezvousWire) = .{},
        /// Handshake budget for a rendezvous dial, milliseconds.
        rendezvous_handshake_ms: i64 = 10_000,
        /// Depth while host actions are being translated into loop/side-wire
        /// effects. Rendezvous redeem dials intentionally nest
        /// drain → dial → handshake → drain. A side-wire close during this
        /// window is collected when the outermost drain returns, matching loop
        /// slots whose `freeConnCtx` runs after `closeSlot`.
        draining_actions: usize = 0,
        /// Rendezvous shells borrowed by bridge code or embedder callbacks.
        /// A close may mark the side wire dead while one of these borrows is
        /// live, but collection cannot release the Host session or free the
        /// shell until the borrow ends.
        rendezvous_borrows: usize = 0,

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

        pub const Origin = union(enum) {
            loop: usize,
            rendezvous,
        };

        /// One adopted connection's bridge shell: what the loop's serve hook
        /// gets as its per-connection context, and what `on_open` observes for
        /// both loop slots and rendezvous side wires.
        /// Bounded by live connections; loop shells are freed in `freeConnCtx`,
        /// rendezvous shells with their `RendezvousWire`.
        pub const Slot = struct {
            bridge: *Self,
            session: *driver_core.HostSession,
            origin: Origin,
            opened: bool = false,
            leg: Leg = .accept,

            fn isRendezvous(self: *const Slot) bool {
                return self.origin == .rendezvous;
            }
        };

        /// One Host session whose bytes ride a blocking `keyed-relay`
        /// Connection rather than a Loop slot — the rendezvous side-dial shell.
        pub const RendezvousWire = struct {
            shell: Slot,
            conn: net.Connection,
            read_buf: []u8,
            write_buf: []u8,
            closed: bool = false,
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
        /// bridge's four per-connection hooks spliced in. Callers set only the
        /// sizing and metrics fields (`frame_cap`, `max_conns`, `listen`,
        /// `on_park`, …) and pass `makePeer` / `@ptrCast(bridge)` alongside to
        /// `Loop.init` / `initWithBackend`; a hand-wired hook set that skips
        /// one callback is an adoption leak, so the splice is the API.
        pub fn hookOptions(base: net.completion.Options) net.completion.Options {
            var options = base;
            options.make_conn_ctx = makeConnCtx;
            options.serve = serve;
            options.free_conn_ctx = freeConnCtx;
            options.on_close = onClose;
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
        pub fn attach(self: *Self, transport: []const u8, designator: []const u8, direct_addresses_hint: []const u8) !void {
            if (self.transport_len != 0) return error.AlreadyAttached;
            if (transport.len > self.transport_buf.len)
                return error.TransportTooLong;
            var hint_entries: [1]model.HintEntry = undefined;
            try self.host.setAdvertisedLocator(.{
                .transport = transport,
                .designator = designator,
                .hints = model.Hints.forDirectAddresses(direct_addresses_hint, &hint_entries),
            });
            @memcpy(self.transport_buf[0..transport.len], transport);
            self.transport_len = transport.len;
        }

        /// Borrow a `keyed-relay` netlayer for rendezvous dials (ADR-0088). The
        /// resident behind `nl` must outlive this bridge and every side wire.
        /// Call once, before any `keyed-relay` redeem or app dial. Without this,
        /// a `keyed-relay` dial fails with `NoRendezvousConfigured`.
        pub fn attachRendezvous(self: *Self, nl: net.netlayer.Netlayer) error{AlreadyAttached}!void {
            if (self.rendezvous_nl != null) return error.AlreadyAttached;
            self.rendezvous_nl = nl;
        }

        /// Free the bridge's own state. The loop's `deinit` already released
        /// every adopted connection through `freeConnCtx`; run this after the
        /// loop's teardown and before the host's. Any stranded app-dial connect
        /// (loop torn down mid-connect) frees its duped strings here. Rendezvous
        /// side wires are released here — the Loop never adopted them.
        pub fn deinit(self: *Self) void {
            var it = self.pending_connects.valueIterator();
            while (it.next()) |pending| pending.deinit(self.allocator);
            self.pending_connects.deinit(self.allocator);
            self.slots.deinit(self.allocator);
            var rw_it = self.rendezvous_wires.valueIterator();
            while (rw_it.next()) |wire_ptr| self.destroyRendezvousWire(wire_ptr.*);
            self.rendezvous_wires.deinit(self.allocator);
        }

        fn transportName(self: *const Self) []const u8 {
            return self.transport_buf[0..self.transport_len];
        }

        fn drainBestEffort(self: *Self) void {
            self.drainActions() catch {};
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
            mb.drainWake();
            mb.apply(self.host);
            self.drainBestEffort();
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
            // Pack owned strings first so errdefers stop at the block boundary;
            // connectOutbound owns the OutboundConnect on every exit path.
            const connect: OutboundConnect = blk: {
                const transport_owned = try self.allocator.dupe(u8, transport);
                errdefer self.allocator.free(transport_owned);
                const designator_owned = try self.allocator.dupe(u8, designator);
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
                transport,
                designator,
                direct_addresses_hint,
            );
        }

        /// Close the loop connection — or rendezvous side wire — serving
        /// `peer_id`, if one is still adopted. The slot row leaves in
        /// `freeConnCtx` before the session's release, so a stale or already-torn
        /// id no-ops — the same spine `drainActions`' close arm rides. Call from
        /// the loop-owner thread only (`Loop.closeSlot` affinity).
        pub fn closeConn(self: *Self, peer_id: engine.PeerId) void {
            if (self.slots.get(peer_id)) |slot| {
                self.loop.closeSlot(slot);
                return;
            }
            if (self.rendezvous_wires.get(peer_id)) |wire| {
                self.closeRendezvousWire(wire);
                self.collectClosedRendezvous();
            }
        }

        /// Shared dial spine for app and redeem. Loop-resolved transports go
        /// through `dialLocator`; `keyed-relay` goes through the attached
        /// rendezvous netlayer (blocking dial + side wire) when configured.
        /// Takes ownership of `connect` (map on success, deinit on refuse /
        /// rendezvous completion).
        fn connectOutbound(
            self: *Self,
            loop: *LoopT,
            connect: OutboundConnect,
            transport: []const u8,
            designator: []const u8,
            hint: []const u8,
        ) !void {
            if (std.mem.eql(u8, transport, model.transport.keyed_relay)) {
                try self.dialRendezvous(connect, transport, designator, hint);
                return;
            }
            errdefer connect.deinit(self.allocator);
            const slot = try loop.dialLocator(transport, designator, hint);
            errdefer loop.closeSlot(slot);
            try self.pending_connects.put(self.allocator, slot, connect);
        }

        /// Blocking `keyed-relay` dial: open the Host session, dial the
        /// attached rendezvous netlayer, pump the handshake on this thread,
        /// then report `exporterDialed` for redeem (or free app-dial ownership).
        /// `anyerror` breaks the inferred-error recursion nested drain → dial
        /// → handshake → drain (same seat as `PollHost.answerDial`).
        fn dialRendezvous(
            self: *Self,
            connect: OutboundConnect,
            transport: []const u8,
            designator: []const u8,
            hint: []const u8,
        ) anyerror!void {
            errdefer connect.deinit(self.allocator);
            const nl = self.rendezvous_nl orelse return error.NoRendezvousConfigured;

            var entry_buf: [1]model.HintEntry = undefined;
            const locator: model.PeerLocator = .{
                .transport = transport,
                .designator = designator,
                .hints = model.Hints.forDirectAddresses(hint, &entry_buf),
            };
            try self.host.ensureAdvertisedLocator(transport);
            const session = try self.host.openDialedLocator(locator);
            var session_adopted = false;
            errdefer if (!session_adopted) self.host.releaseSession(session) catch {};

            const frame_cap = self.host.opts.limits.max_frame_bytes;
            const read_buf = try self.allocator.alloc(u8, frame_cap);
            errdefer if (!session_adopted) self.allocator.free(read_buf);
            const write_buf = try self.allocator.alloc(u8, frame_cap);
            errdefer if (!session_adopted) self.allocator.free(write_buf);

            var conn = try nl.dial(session.served.port.peer, locator, .{ .read = read_buf, .write = write_buf });
            errdefer if (!session_adopted) conn.deinit();
            if (conn.socketHandle() == null) return error.TransportNotPollable;

            try self.rendezvous_wires.ensureUnusedCapacity(self.allocator, 1);
            const wire = try self.allocator.create(RendezvousWire);
            errdefer if (!session_adopted) self.allocator.destroy(wire);
            const leg: Leg = switch (connect) {
                .redeem => |ticket| .{ .redeem = ticket },
                .app_dial => .app_dial,
            };
            wire.* = .{
                .shell = .{
                    .bridge = self,
                    .session = session,
                    .origin = .rendezvous,
                    .leg = leg,
                },
                .conn = conn,
                .read_buf = read_buf,
                .write_buf = write_buf,
            };
            self.rendezvous_wires.putAssumeCapacity(session.peer_id, wire);
            session_adopted = true;
            errdefer {
                std.debug.assert(self.rendezvous_wires.remove(session.peer_id));
                self.destroyRendezvousWire(wire);
            }

            try self.pumpRendezvousHandshake(session);
            connect.deinit(self.allocator);
        }

        fn destroyRendezvousWire(self: *Self, wire: *RendezvousWire) void {
            wire.closed = true;
            wire.conn.deinit();
            self.host.releaseSession(wire.shell.session) catch {};
            self.allocator.free(wire.read_buf);
            self.allocator.free(wire.write_buf);
            self.allocator.destroy(wire);
        }

        /// Mark the side wire closed without releasing the transport. A
        /// `Host.feedBytes` callback may close the same wire while its reader is
        /// still on the stack; `collectClosedRendezvous` owns the eventual
        /// transport teardown once borrows and callbacks have unwound.
        fn closeRendezvousWire(self: *Self, wire: *RendezvousWire) void {
            _ = self;
            if (wire.closed) return;
            wire.closed = true;
            wire.shell.session.served.port.breakFarVows(wire.shell.session.served.closeReason("connection lost"));
        }

        fn beginRendezvousBorrow(self: *Self) void {
            self.rendezvous_borrows += 1;
        }

        fn endRendezvousBorrow(self: *Self) void {
            std.debug.assert(self.rendezvous_borrows > 0);
            self.rendezvous_borrows -= 1;
        }

        fn collectClosedRendezvous(self: *Self) void {
            if (self.draining_actions != 0 or self.rendezvous_borrows != 0 or self.host.in_callback) return;
            while (true) {
                var closed: [8]engine.PeerId = undefined;
                var closed_n: usize = 0;
                var it = self.rendezvous_wires.iterator();
                while (it.next()) |entry| {
                    const wire = entry.value_ptr.*;
                    if (!wire.closed) continue;
                    closed[closed_n] = entry.key_ptr.*;
                    closed_n += 1;
                    if (closed_n == closed.len) break;
                }
                for (closed[0..closed_n]) |peer_id| {
                    if (self.rendezvous_wires.fetchRemove(peer_id)) |kv| {
                        self.destroyRendezvousWire(kv.value);
                    }
                }
                if (closed_n < closed.len) break;
            }
        }

        const RendezvousSnapshot = struct {
            ids: []engine.PeerId,
            heap: ?[]engine.PeerId = null,

            fn deinit(self: RendezvousSnapshot, allocator: std.mem.Allocator) void {
                if (self.heap) |heap| allocator.free(heap);
            }
        };

        fn snapshotRendezvousWires(
            self: *Self,
            stack: []engine.PeerId,
            skip: ?*driver_core.HostSession,
            comptime feed_tails_only: bool,
        ) !RendezvousSnapshot {
            const total = self.rendezvous_wires.count();
            const backing = if (total <= stack.len)
                stack
            else
                try self.allocator.alloc(engine.PeerId, total);
            const heap = if (backing.ptr == stack.ptr) null else backing;
            var n: usize = 0;
            var it = self.rendezvous_wires.iterator();
            while (it.next()) |entry| {
                const wire = entry.value_ptr.*;
                if (wire.closed) continue;
                if (skip) |session| if (wire.shell.session == session) continue;
                if (feed_tails_only and !wire.shell.session.feed_tail.isActive()) continue;
                backing[n] = entry.key_ptr.*;
                n += 1;
            }
            return .{ .ids = backing[0..n], .heap = heap };
        }

        fn writeRendezvousOutbound(self: *Self, wire: *RendezvousWire) !void {
            _ = self;
            if (wire.closed) return;
            while (try wire.shell.session.takeOutbound()) |frame| {
                var owned = frame;
                defer owned.deinit();
                _ = try net.writeFrameBytes(wire.conn.w, owned.bytes());
            }
            try wire.conn.w.flush();
        }

        fn readRendezvousFeed(self: *Self, wire: *RendezvousWire) !void {
            const r = wire.conn.r;
            if (r.bufferedLen() == 0) {
                r.fillMore() catch |err| switch (err) {
                    error.EndOfStream => return error.ConnectionLost,
                    error.ReadFailed => return error.ConnectionLost,
                };
            }
            const chunk = r.buffered();
            self.beginRendezvousBorrow();
            defer self.endRendezvousBorrow();
            self.host.feedBytes(wire.shell.session, chunk) catch |err| {
                r.toss(chunk.len);
                self.drainBestEffort();
                self.writeRendezvousOutbound(wire) catch {};
                self.closeRendezvousWire(wire);
                return net.classifyApplyError(err);
            };
            r.toss(chunk.len);
        }

        /// Resume paused frames already held by `Host.feedBytes`. The core
        /// pauses behind the frame that opens a session so the embedder can run
        /// post-open setup first; after that, no socket readiness will report
        /// those bytes because they already left the kernel.
        fn resumeRendezvousFeedTails(self: *Self, skip: ?*driver_core.HostSession) void {
            while (true) {
                var stack: [64]engine.PeerId = undefined;
                const ids = self.snapshotRendezvousWires(&stack, skip, true) catch {
                    self.drainBestEffort();
                    return;
                };
                defer ids.deinit(self.allocator);
                if (ids.ids.len == 0) break;

                var failed: [8]engine.PeerId = undefined;
                var failed_n: usize = 0;
                var hit_batch_limit = false;
                for (ids.ids) |peer_id| {
                    const wire = self.rendezvous_wires.get(peer_id) orelse continue;
                    if (wire.closed) continue;
                    if (wire.shell.session == skip) continue;
                    if (!wire.shell.session.feed_tail.isActive()) continue;
                    self.beginRendezvousBorrow();
                    self.host.feedBytes(wire.shell.session, &.{}) catch {
                        self.endRendezvousBorrow();
                        failed[failed_n] = peer_id;
                        failed_n += 1;
                        if (failed_n == failed.len) hit_batch_limit = true;
                        break;
                    };
                    self.endRendezvousBorrow();
                }
                if (failed_n != 0) {
                    self.drainBestEffort();
                    for (failed[0..failed_n]) |peer_id| {
                        if (self.rendezvous_wires.get(peer_id)) |wire| {
                            self.writeRendezvousOutbound(wire) catch {};
                            self.closeRendezvousWire(wire);
                        }
                    }
                    self.collectClosedRendezvous();
                }
                if (!hit_batch_limit and failed_n == 0) break;
            }
        }

        fn fireOpen(self: *Self, shell: *Slot) anyerror!void {
            if (shell.opened) return;
            if (!shell.session.sessionOpen()) return;
            if (shell.isRendezvous()) self.beginRendezvousBorrow();
            defer if (shell.isRendezvous()) self.endRendezvousBorrow();
            shell.opened = true;
            if (shell.leg == .redeem) {
                const ticket = shell.leg.redeem;
                self.host.exporterDialed(ticket, shell.session) catch |err| {
                    self.host.dialFailed(ticket, @errorName(err)) catch {};
                    shell.leg = .redeem_done;
                    self.drainBestEffort();
                    return err;
                };
                shell.leg = .redeem_open;
            }
            if (self.on_open) |on_open| try on_open(self.on_open_ctx, self, shell);
        }

        /// Pump one rendezvous wire's handshake until the CapTP session opens,
        /// under `rendezvous_handshake_ms`. Loop sessions are frozen for this
        /// window (same nested-dial freeze PollHost accepts).
        fn pumpRendezvousHandshake(self: *Self, session: *driver_core.HostSession) anyerror!void {
            const deadline = net.clock.nowMs(self.io) + self.rendezvous_handshake_ms;
            while (!session.sessionOpen()) {
                self.resumeRendezvousFeedTails(session);
                try self.drainActions();
                const wire = self.rendezvous_wires.get(session.peer_id) orelse return error.ConnectionLost;
                if (wire.closed) return error.ConnectionLost;
                self.writeRendezvousOutbound(wire) catch return error.ConnectionLost;

                const remaining = deadline - net.clock.nowMs(self.io);
                if (remaining <= 0) return error.HandshakeTimedOut;
                const timeout: i32 = std.math.cast(i32, remaining) orelse std.math.maxInt(i32);

                var fds = [_]std.posix.pollfd{.{
                    .fd = wire.conn.socketHandle().?,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                }};
                if (wire.conn.hasBufferedRaw()) {
                    self.readRendezvousFeed(wire) catch return error.ConnectionLost;
                    continue;
                }
                const ready = std.posix.poll(&fds, timeout) catch return error.ConnectionLost;
                if (ready == 0) return error.HandshakeTimedOut;
                self.readRendezvousFeed(wire) catch return error.ConnectionLost;
            }
            // Drain anything queued by the open edge (exporterDialed follows).
            try self.drainActions();
            if (self.rendezvous_wires.get(session.peer_id)) |wire| {
                self.writeRendezvousOutbound(wire) catch {};
                try self.fireOpen(&wire.shell);
            }
            self.resumeRendezvousFeedTails(null);
            try self.drainActions();
        }

        /// Non-blocking progress on every live rendezvous side wire. Call from
        /// the embedder's wake (rooms-peer `maintain`) so redeem sessions keep
        /// moving after the handshake while the Loop serves its own slots.
        pub fn pumpRendezvous(self: *Self) void {
            while (true) {
                self.resumeRendezvousFeedTails(null);
                self.drainBestEffort();
                var stack: [64]engine.PeerId = undefined;
                const ids = self.snapshotRendezvousWires(&stack, null, false) catch {
                    self.drainBestEffort();
                    return;
                };
                defer ids.deinit(self.allocator);
                if (ids.ids.len == 0) {
                    self.collectClosedRendezvous();
                    self.drainBestEffort();
                    break;
                }
                var doomed: [8]engine.PeerId = undefined;
                var doomed_n: usize = 0;
                var hit_batch_limit = false;
                for (ids.ids) |peer_id| {
                    const wire = self.rendezvous_wires.get(peer_id) orelse continue;
                    if (wire.closed) {
                        doomed[doomed_n] = peer_id;
                        doomed_n += 1;
                        if (doomed_n == doomed.len) {
                            hit_batch_limit = true;
                            break;
                        }
                        continue;
                    }
                    self.writeRendezvousOutbound(wire) catch {
                        doomed[doomed_n] = peer_id;
                        doomed_n += 1;
                        if (doomed_n == doomed.len) {
                            hit_batch_limit = true;
                            break;
                        }
                        continue;
                    };
                    // Drain readable / buffered without blocking the Loop wake.
                    while (true) {
                        var fds = [_]std.posix.pollfd{.{
                            .fd = wire.conn.socketHandle() orelse break,
                            .events = std.posix.POLL.IN,
                            .revents = 0,
                        }};
                        const buffered = wire.conn.hasBufferedRaw();
                        if (!buffered) {
                            const ready = std.posix.poll(&fds, 0) catch break;
                            if (ready == 0) break;
                        }
                        self.readRendezvousFeed(wire) catch {
                            doomed[doomed_n] = peer_id;
                            doomed_n += 1;
                            if (doomed_n == doomed.len) hit_batch_limit = true;
                            break;
                        };
                        if (wire.closed) break;
                    }
                    if (hit_batch_limit) break;
                }
                for (doomed[0..doomed_n]) |peer_id| {
                    if (self.rendezvous_wires.get(peer_id)) |wire| {
                        self.closeRendezvousWire(wire);
                    }
                }
                self.collectClosedRendezvous();
                if (!hit_batch_limit) {
                    self.drainBestEffort();
                    break;
                }
                self.drainBestEffort();
            }
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
            const session = if (self.pending_connects.fetchRemove(slot)) |kv| blk: {
                const pending = kv.value;
                defer pending.deinit(self.allocator);
                // One switch: pieces, Leg, and redeem refuse share one arm.
                break :blk switch (pending) {
                    .app_dial => |a| open: {
                        leg = .app_dial;
                        break :open try self.host.openDialedOver(peer, a.transport, a.designator);
                    },
                    .redeem => |t| open: {
                        leg = .{ .redeem = t };
                        const view = self.host.pendingDial(t) orelse {
                            self.host.dialFailed(t, "pending dial missing") catch {};
                            return error.MissingPendingDial;
                        };
                        break :open self.host.openDialedOver(peer, view.transport, view.designator) catch |err| {
                            self.host.dialFailed(t, @errorName(err)) catch {};
                            return err;
                        };
                    },
                };
            } else try self.host.openAcceptedAdvertisedOver(peer, self.transportName());
            errdefer {
                if (leg == .redeem) self.host.dialFailed(leg.redeem, "ConnectionClosed") catch {};
                self.host.releaseSession(session) catch {};
            }
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
                .origin = .{ .loop = slot },
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
                self.host.dialFailed(shell.leg.redeem, "ConnectionClosed") catch {};
                shell.leg = .redeem_done;
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
        pub fn onClose(ctx: ?*anyopaque, slot: usize, conn_ctx: ?*anyopaque, opened: bool, reason: net.completion.CloseReason) void {
            _ = reason;
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            if (conn_ctx != null) return;
            if (opened) return;
            const pending = (self.pending_connects.fetchRemove(slot) orelse return).value;
            defer pending.deinit(self.allocator);
            switch (pending) {
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
                    if (e.bridge.slots.get(peer_id)) |slot| {
                        e.loop.armOutbound(slot);
                        return;
                    }
                    if (e.bridge.rendezvous_wires.get(peer_id)) |wire| {
                        if (wire.closed) return;
                        e.bridge.writeRendezvousOutbound(wire) catch e.bridge.closeConn(peer_id);
                    }
                }

                pub fn close(e: @This(), peer_id: engine.PeerId) !void {
                    if (e.bridge.rendezvous_wires.get(peer_id)) |wire| {
                        e.bridge.writeRendezvousOutbound(wire) catch {};
                        e.bridge.closeRendezvousWire(wire);
                        return;
                    }
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
                        view.transport,
                        view.designator,
                        view.direct_addresses_hint,
                    ) catch |err| {
                        // Stack detail is copied inside `node.dialFailed` before return.
                        // Include a short designator prefix so InvalidAddress digs
                        // can see exporter shape without a second logging path.
                        const prefix_len = @min(view.designator.len, 16);
                        var detail: [192]u8 = undefined;
                        const reason = std.fmt.bufPrint(&detail, "{s} transport={s} designatorLen={d} designatorPrefix={s} hintLen={d}", .{
                            @errorName(err),
                            view.transport,
                            view.designator.len,
                            view.designator[0..prefix_len],
                            view.direct_addresses_hint.len,
                        }) catch @errorName(err);
                        try bridge.host.dialFailed(d.ticket, reason);
                    };
                }

                pub fn complete(e: @This(), action: driver_core.HostAction) !void {
                    defer e.bridge.host.freeAction(action);
                    if (e.bridge.on_action) |on_action| on_action(e.bridge.on_action_ctx, e.bridge, action);
                }
            };
            self.draining_actions += 1;
            driver_core.drainActions(self.host, self.io, Exec{ .bridge = self, .loop = self.loop }) catch |err| {
                self.draining_actions -= 1;
                if (self.draining_actions == 0) self.collectClosedRendezvous();
                return err;
            };
            self.draining_actions -= 1;
            if (self.draining_actions == 0) self.collectClosedRendezvous();
        }
    };
}
