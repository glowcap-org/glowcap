//! The owning host face (ADR-0090): a blocking, poll-multiplexed embedding of
//! the sans-io `driver_core.Host`, the native sibling of the byte-fed pump
//! every binding runs on its own event loop.
//!
//! `driver.PollHost` owns the composition — the core host, one transport wire per
//! live session, and the pump — and `session.zig`'s owning `Session`/`Server`
//! are views over it. Every blocking wait runs one loop: drain the core's
//! action queue (write flushes, answer redeem dials, draw gift-id entropy),
//! wait for any live wire to become readable under the caller's `Budget`, feed
//! those outer-framed bytes through `Host.feedBytes`, and repeat until the wait's capture
//! fires. Because the wait spans every live wire, a sibling session's inbound
//! (a deposit arriving while this session waits on a withdraw) is served
//! inside the same wait, which is what makes same-host gifter and exporter
//! roles work on one fiber with no thread.
//!
//! The wires are `net.Connection`s used through their byte-stream face only —
//! raw reads off `conn.r` into the core's outer framer, and
//! `takeOutbound` frames wrapped onto `conn.w`; the parse-into-peer
//! half (`pump`, the spill) stays the borrowing tier's vocabulary. Multiplexed
//! blocking waits need readiness, so a transport with no pollable fd is
//! refused at open (`Error.TransportNotPollable`); the completion loop is the
//! tier that serves those.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");
const actors = @import("actors");
const net = @import("net");
const driver_core = @import("driver_core");
const settle_mailbox = @import("settle_mailbox.zig");

const Budget = driver_core.Budget;
const Error = driver_core.Error;
const Identity = driver_core.Identity;

/// The owning face over one `driver_core.Host`: the core, the netlayer slice
/// it dials through, and one wire per live session. One thread drives one
/// `PollHost` (the core's own contract); every blocking verb on a view pumps
/// through here.
pub const PollHost = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    core: driver_core.Host,
    /// The transports this host dials through — for the first connect and for
    /// every later redeem dial. Borrowed; must outlive the Host (the residents
    /// behind it hold the live streams), unless it points at `own_netlayer`.
    netlayers: []const net.netlayer.Netlayer,
    /// Inline storage for a host whose dial table is its own single transport:
    /// `listen` builds one here so an accepted session can redeem a give that
    /// names a third peer on the transport it is already bound to, without
    /// asking the caller for a slice that must outlive the server (the exact
    /// lifetime the borrowed field above traps callers on).
    own_netlayer: [1]net.netlayer.Netlayer = undefined,
    opts: Options,
    wires: std.AutoHashMapUnmanaged(engine.PeerId, *Wire) = .{},
    /// Scratch for the multi-wire readiness wait, sized to the live wires; the
    /// wait itself allocates nothing.
    poll_scratch: std.ArrayListUnmanaged(std.posix.pollfd) = .empty,
    conn_scratch: std.ArrayListUnmanaged(*Wire) = .empty,
    borrow_scratch: std.ArrayListUnmanaged(*net.Connection) = .empty,
    /// The off-turn settle mailbox (ADR-0102 stage 4), minted on first
    /// request; its wake fd rides every readiness wait beside the wires.
    mailbox: ?*settle_mailbox.SettleMailbox = null,
    /// Where the next readiness scan starts. `net.waitAnyReadable` reports the
    /// *first* ready wire, so a fixed order lets one always-readable partner
    /// starve every sibling — unbounded on `serve`/`step`, which carry no
    /// budget at all, and a misattributed `WaitTimedOut` on the budgeted
    /// waits (the timeout would name the innocent caller, not the flooder).
    /// Rotating one position per wait bounds a live wire's turn by the
    /// live-wire count instead of by a partner's send rate.
    wait_cursor: usize = 0,
    /// Outstanding accepted views (`Server.accept` mints one, a non-owning
    /// `Session.deinit` retires one). `Server.close` asserts it is zero in
    /// safe builds: a view outliving its server's host is a dangle, and the
    /// wire count cannot stand in — redeem-dialed sessions have no view.
    accepted_views: usize = 0,
    /// One vow whose synchronously settled completion the next action drain
    /// hands back instead of dropping: the select-or-dial enliven's
    /// cache-hit arm settles inside the verb, before any listener can
    /// register. Every other wait on this face registers first, so this is
    /// the only claimer.
    awaited_completion: ?u64 = null,
    claimed_completion: ?driver_core.HostAction = null,

    /// Options for the owning face and its `connect`/`listen` views.
    /// `frame_cap` sizes the owned read/write buffers and the session's
    /// `max_frame_bytes` limit together, so the buffers and the limit cannot
    /// drift apart. `codec` is the wire grammar the negotiating peer encodes
    /// in. There is deliberately no `verify_partner` knob: the application
    /// tier always verifies.
    ///
    /// The two wait budgets are `driver.Budget` and have no default: every
    /// other option has a wrong value that costs memory or speed, but a wait
    /// budget has a wrong value that costs the process, so the question is
    /// asked where it cannot be skipped. A caller that genuinely means
    /// forever — an in-process pair, a harness driving both ends — spells
    /// `.unbounded`.
    pub const Options = struct {
        frame_cap: usize = 1 << 16,
        codec: model.CodecId = model.Preference.baseline.codec,
        /// The CapTP profile this host offers in `op:start-session`, beside
        /// the codec above. The two fields name one offered profile, and a
        /// host normally sets them together, but they are negotiated as
        /// independent axes: `engine.negotiation` settles the version and the
        /// codec separately, so a partner can follow this host on one axis and
        /// not the other (ADR-0003). Both default to
        /// `model.Preference.baseline`, the profile every conforming peer
        /// speaks. A pancake-to-pancake fleet sets `.next` here and `.capnp`
        /// above; a partner that cannot follow settles each axis back to the
        /// baseline on its own session (ADR-0103).
        captp_version: model.CaptpVersion = model.Preference.baseline.captp_version,
        /// Per-read deadline for the keyed handshake, and for each redeem
        /// dial's handshake inside a wait. Breaks with
        /// `Error.HandshakeTimedOut` when a partner connects then goes
        /// silent (ADR-0081).
        handshake: Budget,
        /// Wall-clock deadline for blocking answer-waits after the session
        /// is open (`settle` / `call` / `fetch`).
        settle: Budget,
    };

    /// One session's transport binding: the byte stream, the buffers behind
    /// its reader/writer, and the core shell it feeds. Owned by the host map;
    /// freed by `releaseWire` (or `deinit`).
    pub const Wire = struct {
        conn: net.Connection,
        read_buf: []u8,
        write_buf: []u8,
        session: *driver_core.HostSession,
        /// The transport reported closure (EOF or fault); the wire stays in
        /// the map until `releaseWire` so a view holding it can observe the
        /// close instead of dangling.
        closed: bool = false,
    };

    /// A host bound to `identity`: `.keyed` reuses the caller's seed (one
    /// durable identity across hosts), `.ephemeral` draws a fresh one at the
    /// I/O boundary. `io` is the host `std.Io` entropy and the poll clock ride.
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        netlayers: []const net.netlayer.Netlayer,
        identity: Identity,
        opts: Options,
    ) Error!PollHost {
        const seed: [foundation.crypto.SEED_BYTES]u8 = switch (identity) {
            .keyed => |k| k.secret.seed(),
            .ephemeral => blk: {
                var s: [foundation.crypto.SEED_BYTES]u8 = undefined;
                io.randomSecure(&s) catch return Error.HandshakeEntropyFailed;
                break :blk s;
            },
        };
        // Every session on this host signs with its own key (ADR-0097). The
        // root is drawn here, at the driver's entropy boundary, because the
        // sans-io core draws none; it is fresh per process, so a restarted
        // host cannot recreate a prior session's handoff names.
        var session_root: [foundation.crypto.SEED_BYTES]u8 = undefined;
        io.randomSecure(&session_root) catch return Error.HandshakeEntropyFailed;
        var host = PollHost{
            .allocator = allocator,
            .io = io,
            .core = driver_core.Host.init(allocator, seed, .{
                .codec = opts.codec,
                .captp_version = opts.captp_version,
                .session_seeds = .{ .rooted = session_root },
            }),
            .netlayers = netlayers,
            .opts = opts,
        };
        host.core.setSessionLimits(opts.frame_cap, null);
        if (identity == .keyed) {
            // Both arms are named, and the set is
            // `Host.SetSelfDesignatorError` rather than the whole `HostError`,
            // so a refusal added there becomes a compile error here instead of
            // an `else` arm that would panic on it.
            host.core.setSelfDesignator(identity.keyed.designator) catch |err| switch (err) {
                error.DesignatorTooLong => return Error.DesignatorUnavailable,
            };
        }
        return host;
    }

    /// Point this host's dial table at its own inline copy of `nl`. Call only
    /// after the host sits at its final address: the table borrows the field
    /// beside it.
    pub fn adoptOwnNetlayer(self: *PollHost, nl: net.netlayer.Netlayer) void {
        self.own_netlayer = .{nl};
        self.netlayers = self.own_netlayer[0..1];
    }

    /// Tear down every wire, then the core (which breaks every parked vow).
    pub fn deinit(self: *PollHost) void {
        var it = self.wires.valueIterator();
        while (it.next()) |wire| self.freeWire(wire.*);
        self.wires.deinit(self.allocator);
        self.poll_scratch.deinit(self.allocator);
        self.conn_scratch.deinit(self.allocator);
        self.borrow_scratch.deinit(self.allocator);
        if (self.mailbox) |mb| mb.deinit();
        self.core.deinit();
    }

    /// Dial `locator` into an open session: mint the dialed half (the core
    /// registers crossed hellos and encodes the signed hello), bind the
    /// transport wire, and pump the keyed handshake under the handshake
    /// budget. On any failure the wire, the shell, and the hello registration
    /// unwind together.
    pub fn connectLocator(self: *PollHost, locator: model.PeerLocator) !*driver_core.HostSession {
        try self.core.ensureAdvertisedLocator(locator.transport);
        const session = try self.core.openDialedLocator(locator);
        errdefer {
            self.dropWire(session.peer_id);
            self.core.releaseSession(session) catch {};
        }
        try self.bindWire(session, locator);
        try self.pumpHandshake(session, self.opts.handshake);
        return session;
    }

    /// Bind an accepted transport connection produced by `listener` to a
    /// fresh accepted-half session. The mint happens after `waitAcceptable`
    /// reported readiness but before the accept itself, because the accept
    /// needs the minted peer; the shell's exposure is one accept syscall, not
    /// the listener's park.
    pub fn acceptWire(
        self: *PollHost,
        listener: net.netlayer.Listener,
        transport: []const u8,
    ) !*driver_core.HostSession {
        const session = try self.core.openAcceptedAdvertised(transport);
        errdefer {
            self.dropWire(session.peer_id);
            self.core.releaseSession(session) catch {};
        }
        try self.bindAcceptedWire(session, listener);
        try self.pumpHandshake(session, self.opts.handshake);
        return session;
    }

    /// The accept half of `bindWire`, in its own frame so buffer ownership
    /// transfers atomically: once `adoptConn` succeeds the wire owns the
    /// buffers, and a later handshake failure must unwind through `dropWire`
    /// alone — a still-armed buffer errdefer there was a double free.
    fn bindAcceptedWire(self: *PollHost, session: *driver_core.HostSession, listener: net.netlayer.Listener) !void {
        const bufs = try self.allocBufs();
        errdefer self.freeBufs(bufs);
        const conn = try listener.accept(session.served.port.peer, .{ .read = bufs.read, .write = bufs.write });
        try self.adoptConn(session, conn, bufs);
    }

    const Bufs = struct { read: []u8, write: []u8 };

    fn allocBufs(self: *PollHost) !Bufs {
        const read = try self.allocator.alloc(u8, self.opts.frame_cap);
        errdefer self.allocator.free(read);
        const write = try self.allocator.alloc(u8, self.opts.frame_cap);
        return .{ .read = read, .write = write };
    }

    fn freeBufs(self: *PollHost, bufs: Bufs) void {
        self.allocator.free(bufs.read);
        self.allocator.free(bufs.write);
    }

    /// Resolve and dial `locator`'s transport for `session`, then adopt the
    /// connection as its wire. Refuses a transport with no pollable fd: the
    /// multiplexed wait cannot block on a stream that reports no readiness.
    fn bindWire(self: *PollHost, session: *driver_core.HostSession, locator: model.PeerLocator) !void {
        const nl = net.netlayer.resolve(self.netlayers, locator.transport) orelse return Error.UnknownTransport;
        const bufs = try self.allocBufs();
        errdefer self.freeBufs(bufs);
        const conn = try nl.dial(session.served.port.peer, locator, .{ .read = bufs.read, .write = bufs.write });
        try self.adoptConn(session, conn, bufs);
    }

    fn adoptConn(self: *PollHost, session: *driver_core.HostSession, conn: net.Connection, bufs: Bufs) !void {
        var owned_conn = conn;
        errdefer owned_conn.deinit();
        if (owned_conn.socketHandle() == null) return Error.TransportNotPollable;
        try self.wires.ensureUnusedCapacity(self.allocator, 1);
        const wire = try self.allocator.create(Wire);
        wire.* = .{ .conn = owned_conn, .read_buf = bufs.read, .write_buf = bufs.write, .session = session };
        self.wires.putAssumeCapacity(session.peer_id, wire);
    }

    /// Free one wire's transport and buffers. The caller owns the map row.
    fn freeWire(self: *PollHost, wire: *Wire) void {
        wire.conn.deinit();
        self.allocator.free(wire.read_buf);
        self.allocator.free(wire.write_buf);
        self.allocator.destroy(wire);
    }

    fn dropWire(self: *PollHost, peer_id: engine.PeerId) void {
        if (self.wires.fetchRemove(peer_id)) |kv| self.freeWire(kv.value);
    }

    /// Mark `wire` closed and break its session's far vows so every waiter
    /// hears the closure — without freeing anything. The shell and wire stay
    /// parked until their owner releases them (the view's deinit, or host
    /// teardown), because a view still holds the session pointer; freeing here
    /// is the double-release this split exists to prevent.
    fn closeWire(self: *PollHost, wire: *Wire) void {
        _ = self;
        if (wire.closed) return;
        wire.closed = true;
        wire.session.served.port.breakFarVows(wire.session.served.closeReason("connection lost"));
    }

    /// Spawn `initial` once in the Host Vat and bind `name` as a Host-wide
    /// alias. Fetching the name lazily projects that actor onto the requesting
    /// Port; exact gifts retain the actor target and do not consult this name
    /// again. `Behavior` is Value-shaped (`driver_core.Hosting`), like every
    /// owning-tier behavior.
    pub fn publishGiftable(
        self: *PollHost,
        name: []const u8,
        comptime Behavior: type,
        initial: Behavior,
    ) !void {
        _ = try self.core.publishGiftable(name, driver_core.Hosting(Behavior), .{ .inner = initial });
    }

    /// Remove the host-wide alias `name` (see `driver_core.Host.unpublish`):
    /// a later fetch misses on every session, while issued capabilities and
    /// deposited gifts keep the exact actor.
    pub fn unpublish(self: *PollHost, name: []const u8) error{ UnknownPublication, ReservedDurableNamespace }!void {
        return self.core.unpublish(name);
    }

    /// Adopt a settled/failed completion the enliven wait below is waiting
    /// for; ownership moves to `claimed_completion` and the wait frees it.
    fn claimCompletion(self: *PollHost, action: driver_core.HostAction) bool {
        const wanted = self.awaited_completion orelse return false;
        const vow_id = switch (action) {
            .settled => |settled| settled.vow_id,
            .failed => |failed| failed.vow_id,
            else => return false,
        };
        if (vow_id != wanted or self.claimed_completion != null) return false;
        self.claimed_completion = action;
        return true;
    }

    /// Host-level select-or-dial enlivenment (ADR-0098 step 4): resolve the
    /// sturdyref's peer to the live dialed session it names, or dial it
    /// through this host's netlayers, then enliven — under the same complete
    /// peer check every enliven path shares — and lift the settled
    /// capability. The caller never picks a session; the peer named in the
    /// sturdyref does.
    pub fn enliven(self: *PollHost, sturdy: model.SturdyRef) !driver_core.Capability {
        const hs = self.core.dialedSessionFor(sturdy.peer.transport, sturdy.peer.designator) orelse
            try self.connectLocator(sturdy.peer);
        const vow_id = try self.core.enliven(hs, sturdy);
        var capture = driver_core.FetchCapture{};
        var flag = driver_core.SettleFlag{ .inner = .{ .ctx = &capture, .func = driver_core.FetchCapture.record } };
        self.core.vowOn(vow_id, .{ .ctx = &flag, .func = driver_core.SettleFlag.fire }) catch |err| switch (err) {
            // The enliven settled inside the verb (a session-cache hit): its
            // completion is parked on the action queue with no listener to
            // fire. Claim it from the drain instead of dropping it.
            error.NoSuchVow => {
                self.awaited_completion = vow_id;
                defer self.awaited_completion = null;
                try self.drainActions();
                const action = self.claimed_completion orelse return driver_core.Error.ConnectionClosed;
                self.claimed_completion = null;
                defer self.core.freeAction(action);
                return switch (action) {
                    .settled => |settled| switch (settled.value) {
                        .reference => |reference| self.core.liftCapability(hs, reference),
                        else => driver_core.Error.FetchNotACapability,
                    },
                    .failed => driver_core.Error.FetchBroken,
                    else => unreachable,
                };
            },
            else => return err,
        };
        self.pumpUntilFlag(hs, &flag.done, self.opts.settle) catch |err| {
            hs.served.port.breakFarVows(hs.served.closeReason("wait failed"));
            return err;
        };
        return switch (capture.outcome orelse return driver_core.Error.ConnectionClosed) {
            .capability => |far_ref| self.core.liftCapability(hs, .{ .far = far_ref }),
            .broken => driver_core.Error.FetchBroken,
            .not_a_capability => driver_core.Error.FetchNotACapability,
        };
    }

    /// Release one session and its wire: outbound the core already queued for
    /// it is written best-effort first (a condemned session's abort must reach
    /// the partner), then the core breaks its vows and fail-closes sibling
    /// answers, then the transport closes.
    pub fn releaseWire(self: *PollHost, session: *driver_core.HostSession) void {
        if (self.wires.get(session.peer_id)) |wire| {
            if (!wire.closed) self.writeOutbound(wire) catch {};
        }
        self.dropWire(session.peer_id);
        self.core.releaseSession(session) catch {};
        self.drainActions() catch {};
    }

    /// Write every encoded outbound frame the core queued for `wire`.
    fn writeOutbound(self: *PollHost, wire: *Wire) !void {
        _ = self;
        while (try wire.session.takeOutbound()) |frame| {
            var owned = frame;
            defer owned.deinit();
            _ = try net.writeFrameBytes(wire.conn.w, owned.bytes());
        }
        try wire.conn.w.flush();
    }

    /// Drain the core's action queue to quiescence: writes, redeem dials,
    /// entropy draws, closes, and unobserved completions. The one place every
    /// action is answered; every pump iteration starts here.
    pub fn drainActions(self: *PollHost) !void {
        return driver_core.drainActions(&self.core, EntropySource{ .io = self.io }, Exec{ .host = self });
    }

    /// The entropy boundary the shared drain draws gift ids at, mapping the
    /// OS failure onto this tier's typed reason.
    const EntropySource = struct {
        io: std.Io,
        pub fn randomSecure(self: EntropySource, buf: []u8) !void {
            self.io.randomSecure(buf) catch return Error.HandshakeEntropyFailed;
        }
    };

    /// The arms this embedding supplies to the shared drain skeleton: write a
    /// flush to its wire, answer a redeem dial by dialing and handshaking, and
    /// free an unobserved completion (the Zig face observes vows in-process
    /// through captures, so a queued one has no waiter to route it to).
    const Exec = struct {
        host: *PollHost,

        pub fn flush(self: Exec, peer_id: engine.PeerId) !void {
            const wire = self.host.wires.get(peer_id) orelse return;
            if (wire.closed) return;
            self.host.writeOutbound(wire) catch self.host.closeWire(wire);
        }

        pub fn close(self: Exec, peer_id: engine.PeerId) !void {
            const wire = self.host.wires.get(peer_id) orelse return;
            if (!wire.closed) self.host.writeOutbound(wire) catch {};
            self.host.closeWire(wire);
        }

        pub fn dial(self: Exec, d: @FieldType(driver_core.HostAction, "dial")) !void {
            try self.host.answerDial(d.ticket);
        }

        pub fn complete(self: Exec, action: driver_core.HostAction) !void {
            if (self.host.claimCompletion(action)) return;
            self.host.core.freeAction(action);
        }
    };

    /// Answer a redeem `dial` action: mint the dialed session against the
    /// pending locator, bind its wire, drive its handshake under the handshake
    /// budget, and report the outcome. Failure settles every waiting redeem
    /// broken through `dialFailed` instead of surfacing here — the caller's
    /// wait hears the break, not the dial's plumbing.
    fn answerDial(self: *PollHost, ticket: engine.Node.PendingId) anyerror!void {
        // `anyerror` breaks the inferred-error recursion this call is the seat
        // of: a redeem dial pumps a nested handshake, whose pump drains
        // actions, which may answer another dial. The dial's own failures are
        // caught below and become the waiting redeem's break, so what escapes
        // here is only the reporting verbs' refusal.
        const pending = self.core.pendingDial(ticket) orelse return;
        var transport_buf: [32]u8 = undefined;
        var designator_buf: [256]u8 = undefined;
        var hint_buf: [256]u8 = undefined;
        if (pending.transport.len > transport_buf.len or
            pending.designator.len > designator_buf.len or
            pending.direct_addresses_hint.len > hint_buf.len)
        {
            try self.core.dialFailed(ticket, "exporter locator too long");
            return;
        }
        // The pending view borrows core storage that later core verbs may
        // touch; copy the parts onto the stack for the dial's duration.
        const transport = transport_buf[0..pending.transport.len];
        @memcpy(transport, pending.transport);
        const designator = designator_buf[0..pending.designator.len];
        @memcpy(designator, pending.designator);
        const hint = hint_buf[0..pending.direct_addresses_hint.len];
        @memcpy(hint, pending.direct_addresses_hint);

        const session = self.dialForRedeem(transport, designator, hint) catch |err| {
            try self.core.dialFailed(ticket, @errorName(err));
            return;
        };
        try self.core.exporterDialed(ticket, session);
    }

    fn dialForRedeem(self: *PollHost, transport: []const u8, designator: []const u8, direct_addresses_hint: []const u8) !*driver_core.HostSession {
        // The hint is load-bearing on keyed transports: keyed-tcp dials the
        // bound `host:port` the exporter advertised, and a locator without it
        // fails the dial outright. `forDirectAddresses` keeps the empty-to-#f
        // spelling for address transports, which ignore it.
        var entry_buf: [1]model.HintEntry = undefined;
        const locator: model.PeerLocator = .{
            .transport = transport,
            .designator = designator,
            .hints = model.Hints.forDirectAddresses(direct_addresses_hint, &entry_buf),
        };
        try self.core.ensureAdvertisedLocator(transport);
        const session = try self.core.openDialedLocator(locator);
        errdefer {
            self.dropWire(session.peer_id);
            self.core.releaseSession(session) catch {};
        }
        try self.bindWire(session, locator);
        try self.pumpHandshake(session, self.opts.handshake);
        return session;
    }

    /// Pump until `session`'s keyed handshake opens, under `budget`.
    fn pumpHandshake(self: *PollHost, session: *driver_core.HostSession, budget: Budget) !void {
        var open = session.sessionOpen();
        var probe = SessionOpenProbe{ .session = session, .open = &open };
        self.pumpUntilProbe(&probe, budget) catch |err| switch (err) {
            Error.WaitTimedOut => return Error.HandshakeTimedOut,
            else => |e| return e,
        };
    }

    const SessionOpenProbe = struct {
        session: *driver_core.HostSession,
        open: *bool,
        fn done(self: *SessionOpenProbe) bool {
            self.open.* = self.session.sessionOpen();
            return self.open.*;
        }
        fn resumeSkip(self: *SessionOpenProbe) ?*driver_core.HostSession {
            return self.session;
        }
    };

    /// Resume any session whose `feed_tail` holds paused frames: the core
    /// stops consuming at the frame that opens a session, so frames that
    /// coalesced behind the handshake hello wait in the tail — and no poll
    /// will ever report them, because they already left the kernel. Every
    /// binding's serve loop empty-feeds before parking for exactly this
    /// reason; this is the owning face's spelling of that contract. A refusal
    /// closes that wire like any dispatch refusal.
    ///
    /// `skip` is the session a handshake pump is itself opening: its paused
    /// frames must keep waiting, because the pause exists so the embedder can
    /// finish post-open setup (publish, spawn) before the partner's coalesced
    /// first frames dispatch. Resuming it here would answer a pipelined fetch
    /// before the object it names exists.
    fn resumeFeedTails(self: *PollHost, skip: ?*driver_core.HostSession) !void {
        var it = self.wires.valueIterator();
        while (it.next()) |entry| {
            const wire = entry.*;
            if (wire.closed) continue;
            if (wire.session == skip) continue;
            if (wire.session.feed_tail.isActive()) {
                self.core.feedBytes(wire.session, &.{}) catch {
                    self.drainActions() catch {};
                    self.closeWire(wire);
                    continue;
                };
            }
        }
    }

    /// The blocking pump: drain actions, check `probe.done()`, wait for any
    /// live wire's readable progress under what remains of `budget`, read and
    /// feed, repeat. `Error.WaitTimedOut` on deadline; `Error.ConnectionClosed`
    /// when the probe's own session closes first.
    fn pumpUntilProbe(self: *PollHost, probe: anytype, budget: Budget) !void {
        const deadline_ms: ?i64 = switch (budget) {
            .unbounded => null,
            .ms => |v| net.clock.nowMs(self.io) + v,
        };
        while (true) {
            // Apply posted settles before anything else can consume the
            // iteration. The wake fd rides the poll set too, but a poll
            // reports the first ready row and a busy wire always precedes
            // it, so relying on that alone would starve the mailbox exactly
            // under the sustained traffic it exists for. This is one
            // uncontended lock and a count check, next to nothing beside the
            // poll below.
            try self.applySettleMailbox();
            try self.resumeFeedTails(probe.resumeSkip());
            try self.drainActions();
            if (probe.done()) return;
            if (self.wireClosed(probe)) return Error.ConnectionClosed;

            const timeout: i32 = if (deadline_ms) |d| blk: {
                const remaining = d - net.clock.nowMs(self.io);
                if (remaining <= 0) return Error.WaitTimedOut;
                break :blk std.math.cast(i32, remaining) orelse std.math.maxInt(i32);
            } else -1;

            const idx = try self.waitAnyReadable(timeout) orelse continue;
            const wire = self.conn_scratch.items[idx];
            switch (try self.feedReadable(wire, probeSession(probe))) {
                .fed => {},
                .closed => if (wire.session == probeSession(probe)) return Error.ConnectionClosed,
            }
        }
    }

    const FeedOutcome = union(enum) { fed: usize, closed };

    /// One readable wire's read-feed-react cycle, the one reaction both pump
    /// spellings share so their closure semantics cannot diverge. EOF and
    /// transport faults close the wire here (vows break; the release stays
    /// with the owner). A dispatch refusal already closed the offending wire
    /// inside `readAndFeed`; it propagates only when the misbehaving session
    /// is `own` — a sibling's protocol violation is that session's closure,
    /// not a reason to abort an innocent caller's wait.
    fn feedReadable(self: *PollHost, wire: *Wire, own: *driver_core.HostSession) !FeedOutcome {
        const fed = self.readAndFeed(wire) catch |err| switch (err) {
            error.ConnectionLost, error.EndOfStream, error.TruncatedFrame => {
                self.closeWire(wire);
                return .closed;
            },
            error.OutOfMemory => return error.OutOfMemory,
            else => |e| {
                if (wire.session == own) return e;
                return .closed;
            },
        };
        return .{ .fed = fed };
    }

    fn probeSession(probe: anytype) *driver_core.HostSession {
        return probe.session;
    }

    fn wireClosed(self: *PollHost, probe: anytype) bool {
        const session = probeSession(probe);
        const wire = self.wires.get(session.peer_id) orelse return true;
        return wire.closed;
    }

    /// The off-turn settle mailbox (ADR-0102 stage 4), minted on the owning
    /// thread the first time it is asked for. Hand the returned pointer (and
    /// resolver ids) to worker threads; their `post` calls wake this host's
    /// readiness wait and the settles apply here, on the owning thread. The
    /// mailbox lives until the host's own teardown.
    pub fn settleMailbox(self: *PollHost) !*settle_mailbox.SettleMailbox {
        if (self.mailbox) |mb| return mb;
        const mb = try settle_mailbox.SettleMailbox.init(self.allocator, settle_mailbox.default_slots);
        self.mailbox = mb;
        return mb;
    }

    /// Apply whatever a worker thread posted, on this owning thread. Cheap
    /// and unconditional: the mailbox is empty in the ordinary case, and the
    /// check is one lock acquisition.
    fn applySettleMailbox(self: *PollHost) !void {
        const mb = self.mailbox orelse return;
        mb.drainWake();
        mb.apply(&self.core);
        try self.drainActions();
    }

    /// Fill the scratch lists with the live wires and wait for the first with
    /// readable progress. Null on timeout.
    fn waitAnyReadable(self: *PollHost, timeout_ms: i32) !?usize {
        self.conn_scratch.clearRetainingCapacity();
        var it = self.wires.valueIterator();
        while (it.next()) |wire| {
            if (!wire.*.closed) try self.conn_scratch.append(self.allocator, wire.*);
        }
        const n = self.conn_scratch.items.len;
        if (n == 0) return Error.ConnectionClosed;
        std.mem.rotate(*Wire, self.conn_scratch.items, self.wait_cursor % n);
        self.wait_cursor +%= 1;
        const wake_fd: ?std.posix.fd_t = if (self.mailbox) |mb| mb.wakeFd() else null;
        try self.poll_scratch.resize(self.allocator, n + @intFromBool(wake_fd != null));
        // Borrow the connections for the wait through retained scratch; net
        // polls, we route by index, and the wait itself allocates nothing
        // once the lists have grown to the live-wire count.
        try self.borrow_scratch.resize(self.allocator, n);
        for (self.conn_scratch.items, 0..) |wire, i| self.borrow_scratch.items[i] = &wire.conn;
        const idx = try net.waitAnyReadable(self.borrow_scratch.items, self.poll_scratch.items, timeout_ms, wake_fd) orelse return null;
        if (idx == n) {
            // The mailbox ended the wait. Applying is the loop top's job
            // (`applySettleMailbox`), which runs whether or not the poll
            // happened to select this row; reporting a quiet wait sends us
            // straight there.
            return null;
        }
        return idx;
    }

    /// One raw read off `wire`; the core owns outer framing and its tail.
    fn readAndFeed(self: *PollHost, wire: *Wire) !usize {
        const r = wire.conn.r;
        if (r.bufferedLen() == 0) {
            r.fillMore() catch |err| switch (err) {
                error.EndOfStream => return if (wire.session.feed_tail.isActive()) error.TruncatedFrame else error.EndOfStream,
                error.ReadFailed => return error.ConnectionLost,
            };
        }
        const chunk = r.buffered();
        self.core.feedBytes(wire.session, chunk) catch |err| {
            // The core projected a typed op:abort for a session-authority
            // refusal; write it (the flush action is queued) and surface the
            // pump vocabulary the borrowing tier speaks, so `serve` and the
            // blocking waits see `ProtocolAbort`, not the raw refusal.
            r.toss(chunk.len);
            self.drainActions() catch {};
            self.writeOutbound(wire) catch {};
            self.closeWire(wire);
            return net.classifyApplyError(err);
        };
        r.toss(chunk.len);
        return chunk.len;
    }

    /// Pump until `flag` fires, under `budget` — the settle wait every view
    /// verb blocks through. The capture listener sets `flag` while a feed
    /// dispatches; the pump observes it at the next drain boundary.
    pub fn pumpUntilFlag(self: *PollHost, session: *driver_core.HostSession, flag: *const bool, budget: Budget) !void {
        var probe = FlagProbe{ .session = session, .flag = flag };
        try self.pumpUntilProbe(&probe, budget);
    }

    const FlagProbe = struct {
        session: *driver_core.HostSession,
        flag: *const bool,
        fn done(self: *FlagProbe) bool {
            return self.flag.*;
        }
        fn resumeSkip(self: *FlagProbe) ?*driver_core.HostSession {
            _ = self;
            return null;
        }
    };

    /// One bounded pump step for a view's `stepReadable`/`serve` loops: drain
    /// actions, wait up to `timeout_ms`, feed one readable wire. Reports
    /// progress from `session`'s perspective.
    pub fn stepSession(self: *PollHost, session: *driver_core.HostSession, timeout_ms: i32) !?net.Progress {
        // Every wait on this face applies the mailbox first; `serve` runs
        // this one rather than `pumpUntilProbe`, and a settle must not wait
        // for whichever loop the caller happened to pick.
        try self.applySettleMailbox();
        try self.resumeFeedTails(null);
        try self.drainActions();
        const session_wire = self.wires.get(session.peer_id) orelse return .closed;
        if (session_wire.closed) return .closed;
        const idx = try self.waitAnyReadable(timeout_ms) orelse return null;
        const wire = self.conn_scratch.items[idx];
        const fed_target = wire.session == session;
        switch (try self.feedReadable(wire, session)) {
            .fed => |fed| {
                try self.drainActions();
                return if (fed_target) .{ .received = fed } else .idle;
            },
            .closed => return if (fed_target) .closed else .idle,
        }
    }
};
