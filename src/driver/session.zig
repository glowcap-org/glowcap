//! The owning, one-call driver surface: `Session` and `Server`, views over the
//! owning host face (`driver.PollHost`, ADR-0090).
//!
//! `connect`, `connectUriOwned`, and `listen` hand back owning bundles so a
//! native Zig app connects (or accepts) in one call. Underneath, every session
//! is backed by a `driver_core.Host` — the same multi-session core every
//! binding drives — so a three-party introduction settles as a live capability
//! inside the caller's wait instead of an unredeemable `.give`. `connect`
//! builds a single-session host; every `Server.accept` shares its server's
//! host, which is what lets a give minted for one partner be withdrawn by
//! another. The borrowing `BlockingSession` surface remains the explicit
//! single-connection tier whose caller owns the peer and buffers — and the
//! one tier where `Settled.give` still surfaces, because "no router" is that
//! caller's choice.

const std = @import("std");

const model = @import("model");
const engine = @import("engine");
const actors = @import("actors");
const net = @import("net");
const driver_core = @import("driver_core");

const host_mod = @import("host.zig");

const driver = @import("mod.zig");
const Settled = driver.Settled;
const Capability = driver.Capability;
const Identity = driver.Identity;
const Budget = driver.Budget;
const Error = driver.Error;

/// Options for `connect` and `listen` (see `driver.PollHost.Options`, the owning
/// face these views ride).
pub const SessionOptions = host_mod.PollHost.Options;

/// An owning connection, the one object a native Zig application holds — a
/// view onto a session of a `driver.PollHost`. `connect` builds a single-session
/// host underneath and hands back its one view (`deinit` tears the whole
/// bundle down); `Server.accept` views borrow the server's shared host
/// (`deinit` releases that one session and leaves the siblings serving).
/// Heap-pinned: the pointer is stable for the connection's life.
///
/// Because a host is underneath, a reply that introduces a capability on a
/// third machine settles as a live reference inside the wait: the redeem dial
/// runs in the pump, under the handshake budget. `Settled.give` never
/// surfaces here.
pub const Session = struct {
    host: *host_mod.PollHost,
    hs: *driver_core.HostSession,
    /// What this view owns, and therefore what its `deinit` reclaims.
    owner: Owner,
    allocator: std.mem.Allocator,

    /// A session view is one of three things, and a two-state flag could name
    /// only two of them. The third — a view onto a host the caller owns — was
    /// the one that had no spelling, so callers wrote a struct literal for it
    /// and `deinit` treated it as an accepted view: it decremented a counter
    /// no constructor had incremented, then freed a pointer that was usually
    /// on the stack. Naming the third state is what makes that unrepresentable
    /// rather than merely documented.
    pub const Owner = enum {
        /// `PollHost.view`: borrowed. The caller owns the host and released
        /// the session, so `deinit` reclaims nothing and is safe on a value
        /// that was never heap-allocated.
        borrowed,
        /// `Server.accept`: one session of the server's shared host.
        accepted,
        /// `driver.connect`: the whole private bundle, host included.
        private_host,
    };

    /// A borrowed view onto a session a caller-owned `PollHost` already holds.
    ///
    /// By value, and owning nothing: releasing the session stays the caller's
    /// job through `PollHost.releaseWire`, and tearing down the host stays its
    /// own `deinit`. This exists so that shape has a constructor at all.
    /// Without one, every caller wrote the struct literal, and a literal is
    /// where the owner gets guessed.
    pub fn view(host: *host_mod.PollHost, hs: *driver_core.HostSession) Session {
        return .{ .host = host, .hs = hs, .owner = .borrowed, .allocator = host.allocator };
    }

    /// Reclaim what this view owns. A borrowed view owns nothing, so this is
    /// a no-op there; the host it points at is the caller's to tear down.
    pub fn deinit(self: *Session) void {
        switch (self.owner) {
            .borrowed => return,
            .private_host => {
                self.host.deinit();
                self.allocator.destroy(self.host);
            },
            .accepted => {
                self.host.releaseWire(self.hs);
                self.host.accepted_views -= 1;
            },
        }
        self.allocator.destroy(self);
    }

    /// Begin the bootstrap fetch for `name`, returning its vow without
    /// blocking (see `driver_core.Served.beginFetch`).
    pub fn beginFetch(self: *Session, name: []const u8) !actors.Vow {
        const vow = try self.hs.served.sendBootstrapFetch(&self.host.core.vat, name);
        try self.host.core.flushSession(self.hs);
        return vow;
    }

    /// Chain fetch-then-send without blocking (see `Served.beginSendNamed`).
    pub fn beginSendNamed(self: *Session, pending: *driver.PendingSend, name: []const u8, msg: actors.Message, terminal: actors.Listener) !void {
        try self.hs.served.beginSendNamed(&self.host.core.vat, pending, name, msg, terminal);
        try self.host.core.flushSession(self.hs);
    }

    /// Chain fetch-then-tell without blocking (see `Served.beginTellNamed`).
    pub fn beginTellNamed(self: *Session, pending: *driver.PendingSend, name: []const u8, msg: actors.Message, terminal: actors.Listener) !void {
        try self.hs.served.beginTellNamed(&self.host.core.vat, pending, name, msg, terminal);
        try self.host.core.flushSession(self.hs);
    }

    /// Break every far vow still awaiting a partner answer (cancel / timeout /
    /// teardown). Stable `message` bytes are what listeners observe.
    pub fn breakFarVows(self: *Session, message: []const u8) void {
        self.hs.served.port.breakFarVows(message);
    }

    /// The partner identity this session's handshake proved: its session public
    /// key, the location designator it signed, and the verbatim location record
    /// those came from (see `driver_core.PartnerIdentity`).
    ///
    /// This is how an application asks who it is talking to without taking the
    /// partner's word for it. A success means the signature was checked, so a
    /// server can require that a locator a caller *claims* names the key that
    /// caller actually proved, and refuse the mismatch. The returned views
    /// borrow session-owned bytes and stay valid until this session is
    /// released.
    ///
    /// `HostError.HandshakeIncomplete` means the partner's half has not arrived
    /// with a key yet; `HostError.PartnerUnverified` means this session does not
    /// verify its partner, so there is no proved identity to report.
    pub fn partnerIdentity(self: *Session) !driver_core.PartnerIdentity {
        return self.host.core.partnerIdentity(self.hs);
    }

    /// Enroll a capability this session holds under a node-unique token, so it
    /// can be handed to a third party, and return that token.
    ///
    /// `fetch` below enrolls its own result. A capability that arrived any
    /// other way — returned from a call, lifted from a delivered argument —
    /// has no token until this gives it one, and the node cannot route a
    /// capability it was never told the home of, so replying with an
    /// unenrolled one would name a position that means nothing on the
    /// recipient's session.
    ///
    /// Takes and returns a whole `model.FarRef` rather than a position, because
    /// the enrolled row records whether the position names a settled capability
    /// or a promise the partner has not settled, and a far reference encodes the
    /// same either way, so the import row cannot tell them apart. Reading the
    /// kind off the reference the caller already holds is what makes a
    /// position naming one kind and a kind argument naming the other
    /// unconstructible on this tier. What comes back is the enrolled row's own
    /// reference, so the token is ready to hand on as it stands.
    ///
    /// Idempotent per import, so one object never wears two identities. A
    /// position this session does not hold is refused
    /// `HostError.ForeignArgument`, and a position already enrolled under the
    /// other kind is refused `HostError.EnrolledKindConflict`.
    pub fn enroll(self: *Session, reference: model.FarRef) !model.FarRef {
        const token = try self.host.core.enrollCapability(
            self.hs,
            reference.import_position.int(),
            reference.kind,
        );
        return .{ .import_position = .from(token), .kind = reference.kind };
    }

    /// Fetch a partner's published capability by `name`, returning a far
    /// `Ref`. The fulfilled capability is enrolled under a node-unique token
    /// before it is dispatched (ADR-0069), so handing it back to the partner —
    /// or re-gifting it — routes to the right exporter. An unpublished name
    /// returns `Error.FetchBroken`; any other fulfill returns
    /// `Error.FetchNotACapability`.
    pub fn fetch(self: *Session, name: []const u8) !actors.Ref {
        var capture = driver.FetchCapture{};
        const id = try self.host.core.fetch(self.hs, name);
        try self.awaitVowId(id, .{ .ctx = &capture, .func = driver.FetchCapture.record });
        return switch (capture.outcome orelse return Error.ConnectionClosed) {
            .capability => |far_ref| .{ .far = far_ref },
            .broken => Error.FetchBroken,
            .not_a_capability => Error.FetchNotACapability,
        };
    }

    /// The reason-bearing fetch: the partner's settlement whole, materialized
    /// into `arena`.
    pub fn fetchSettled(self: *Session, name: []const u8, arena: std.mem.Allocator) !Settled {
        var capture = driver.SettleCapture{ .arena = arena };
        const id = try self.host.core.fetch(self.hs, name);
        try self.awaitVowId(id, .{ .ctx = &capture, .func = driver.SettleCapture.fire });
        return capture.finish();
    }

    /// Eventual-send `msg` to `target` and block until the reply settles,
    /// materializing both `Settled` arms into caller-owned `arena`. Returns
    /// `ConnectionClosed` if the partner leaves before the reply settles.
    pub fn call(self: *Session, target: actors.Ref, msg: actors.Message, arena: std.mem.Allocator) !Settled {
        const vow = try self.send(target, msg);
        return self.settleVow(vow, arena);
    }

    /// Fetch by `name`, returning the enrolled token as a `model.Reference` —
    /// the routable spelling `callReference` / `sendReference` take, which
    /// rides its exporter session even when that is not this one.
    pub fn fetchReference(self: *Session, name: []const u8) !model.Reference {
        var capture = driver.FetchCapture{};
        const id = try self.host.core.fetch(self.hs, name);
        try self.awaitVowId(id, .{ .ctx = &capture, .func = driver.FetchCapture.record });
        return switch (capture.outcome orelse return Error.ConnectionClosed) {
            .capability => |far_ref| .{ .far = far_ref },
            .broken => Error.FetchBroken,
            .not_a_capability => Error.FetchNotACapability,
        };
    }

    /// Eventual-send to a reference-keyed target and block until the reply
    /// settles. The node routes the token to its exporter session, so a
    /// redeemed or re-gifted capability is called the same way a directly
    /// fetched one is; an argument foreign to the routed session is refused
    /// whole (`ForeignArgument`).
    pub fn callReference(self: *Session, target: model.Reference, verb: []const u8, args: []const model.Argument, arena: std.mem.Allocator) !Settled {
        if (self.refForTarget(target) == null) return Error.UncallableTarget;
        const routed = try self.host.core.routeSend(self.hs, target, args);
        const vow = try routed.session.served.send(&self.host.core.vat, routed.target, .{ .verb = verb, .args = args });
        return self.settleVowOn(routed.session, vow, arena);
    }

    /// Eventual-send `msg` to `target`, returning the reply's vow without
    /// blocking; settle it with `settleVow` or observe it with `on`.
    pub fn send(self: *Session, target: actors.Ref, msg: actors.Message) !actors.Vow {
        const vow = try self.hs.served.send(&self.host.core.vat, target, msg);
        // A far send owes the wire its encode now. A near send queued a local
        // turn instead — driving it here would settle the vow before the
        // caller could register a listener, so the drive waits for the next
        // flush or settle (the borrowing tier's contract exactly).
        if (target == .far) try self.host.core.flushSession(self.hs);
        return vow;
    }

    /// `send` to a reference-keyed target (see `callReference` for routing).
    pub fn sendReference(self: *Session, target: model.Reference, verb: []const u8, args: []const model.Argument) !actors.Vow {
        if (self.refForTarget(target) == null) return Error.UncallableTarget;
        const routed = try self.host.core.routeSend(self.hs, target, args);
        const vow = try routed.session.served.send(&self.host.core.vat, routed.target, .{ .verb = verb, .args = args });
        if (routed.target == .far) try self.host.core.flushSession(routed.session);
        return vow;
    }

    /// Listen on the promise `target` names, returning a vow for its
    /// settlement (see `Served.listenTo`). A promise this partner handed us
    /// settles through a notification it delivers, so this is how a received
    /// promise is waited on; `listenSettled` is the blocking form. A far
    /// target routes through the node the way `callReference` routes, so a
    /// node token is listened on its exporter session. A give that arrives in
    /// the settlement is redeemed on the way through, exactly as one arriving
    /// in a call's reply is. No `refForTarget` guard here: that guard admits
    /// only far *objects*, and a listen's usual target is a far promise.
    pub fn listenTo(self: *Session, target: model.Reference) !actors.Vow {
        return (try self.listenToRouted(target)).vow;
    }

    /// Listen on the promise `target` names and block until it settles,
    /// materializing the outcome into `arena`.
    pub fn listenSettled(self: *Session, target: model.Reference, arena: std.mem.Allocator) !Settled {
        const routed = try self.listenToRouted(target);
        // Drive the session the listen actually rides, which for a routed
        // token is the exporter's, not this view's.
        return self.settleVowOn(routed.session, routed.vow, arena);
    }

    fn listenToRouted(self: *Session, target: model.Reference) !struct { session: *driver_core.HostSession, vow: actors.Vow } {
        if (target == .far) {
            const routed = try self.host.core.routeSend(self.hs, target, &.{});
            const vow = try routed.session.served.listenTo(.{ .far = routed.target.far });
            // The `op:listen` owes the wire its encode now, like a far send's.
            try self.host.core.flushSession(routed.session);
            return .{ .session = routed.session, .vow = vow };
        }
        // Every non-far shape is refused `InvalidReference` by the engine verb.
        const vow = try self.hs.served.listenTo(target);
        return .{ .session = self.hs, .vow = vow };
    }

    /// Promise pipelining against a far `vow` (see `Served.sendToAnswer`).
    pub fn sendToAnswer(self: *Session, vow: actors.Vow, msg: actors.Message) !actors.Vow {
        const next = try self.hs.served.sendToAnswer(&self.host.core.vat, vow, msg);
        try self.host.core.flushSession(self.hs);
        return next;
    }

    /// Block until `vow` settles, materializing the outcome into `arena`.
    pub fn settleVow(self: *Session, vow: actors.Vow, arena: std.mem.Allocator) !Settled {
        return self.settleVowOn(self.hs, vow, arena);
    }

    fn settleVowOn(self: *Session, hs: *driver_core.HostSession, vow: actors.Vow, arena: std.mem.Allocator) !Settled {
        var capture = driver.SettleCapture{ .arena = arena };
        try self.awaitVow(hs, vow, .{ .ctx = &capture, .func = driver.SettleCapture.fire });
        return capture.finish();
    }

    /// Register `listener` on host vow `id` behind a settle flag and block
    /// until it fires — the host-vow twin of `BlockingSession.awaitVow`. The
    /// flag lives on this frame for the whole wait, so the listener's ctx
    /// outlives every fire. No pre-pump flush: `core.fetch` and the vow verbs
    /// pump their own send before returning the id.
    fn awaitVowId(self: *Session, id: u64, listener: actors.Listener) !void {
        var flag = driver.SettleFlag{ .inner = listener };
        try self.host.core.vowOn(id, .{ .ctx = &flag, .func = driver.SettleFlag.fire });
        try self.pumpWait(self.hs, &flag.done);
    }

    /// Register `listener` on a vat `vow` behind a settle flag, drive, and
    /// block until it fires. Listener first, then the drive: a near target's
    /// vow settles inside this flush's own local turn, firing the capture
    /// before the pump parks.
    fn awaitVow(self: *Session, hs: *driver_core.HostSession, vow: actors.Vow, listener: actors.Listener) !void {
        var flag = driver.SettleFlag{ .inner = listener };
        try hs.served.port.on(&hs.host.vat, vow, .{ .ctx = &flag, .func = driver.SettleFlag.fire });
        try self.host.core.flushSession(hs);
        try self.pumpWait(hs, &flag.done);
    }

    /// The one blocking wait every stack-capture verb runs. On any pump
    /// failure the session's far vows break *before* the error unwinds, so a
    /// listener whose ctx is this frame's stack fires while the frame is
    /// alive — a later break firing it into a dead frame is the memory bug,
    /// not the timeout (the same contract `BlockingSession`'s waits hold).
    fn pumpWait(self: *Session, hs: *driver_core.HostSession, flag: *const bool) !void {
        self.host.pumpUntilFlag(hs, flag, self.host.opts.settle) catch |err| {
            hs.served.port.breakFarVows(hs.served.closeReason("wait failed"));
            return err;
        };
    }

    /// Fire-and-forget eventual-send (see `Served.tell`).
    pub fn tell(self: *Session, target: actors.Ref, msg: actors.Message) !void {
        try self.hs.served.tell(&self.host.core.vat, target, msg);
        try self.host.core.flushSession(self.hs);
    }

    /// Observe `vow` with a caller listener (see `Vat.on`). The listener fires
    /// during a later pump on this session.
    pub fn on(self: *Session, vow: actors.Vow, listener: actors.Listener) !void {
        return self.hs.served.port.on(&self.host.core.vat, vow, listener);
    }

    /// Spawn a local actor and return a capability to it (see `Served.spawn`).
    pub fn spawn(self: *Session, comptime Behavior: type, initial: Behavior) !Capability {
        return self.hs.served.spawn(&self.host.core.vat, Behavior, initial);
    }

    /// Publish an actor a partner can `fetch` by `name` (see `Served.publish`).
    pub fn publish(self: *Session, name: []const u8, comptime Behavior: type, initial: Behavior) !Capability {
        return self.hs.served.publish(&self.host.core.vat, name, Behavior, initial);
    }

    /// One blocking pump cycle across the host: drain actions, wait for any
    /// live session's readable progress, feed it. Returns this session's
    /// `Progress` so a caller's loop can act on `.closed`.
    pub fn step(self: *Session) !net.Progress {
        return (try self.host.stepSession(self.hs, -1)) orelse .idle;
    }

    /// Poll-guarded `step`: wait up to `timeout_ms` for readable progress, or
    /// null on timeout. The multiplexing convenience over `step`.
    pub fn stepReadable(self: *Session, timeout_ms: i32) !?net.Progress {
        return self.host.stepSession(self.hs, timeout_ms);
    }

    /// Serve this session until the partner leaves: run `step` until it
    /// reports `.closed`. Far vows break with the close reason inside the
    /// pump's release, exactly as on the borrowing tier.
    pub fn serve(self: *Session) !void {
        while (true) {
            const progress = (try self.host.stepSession(self.hs, -1)) orelse continue;
            if (progress == .closed) return;
        }
    }

    /// The raw engine peer under this session — the explicit-ownership escape
    /// for a consumer that outgrows the surface (the same contract
    /// `BlockingSession.peer` carries on the borrowing tier).
    pub fn peer(self: *Session) *engine.Peer {
        return self.hs.served.port.peer;
    }

    /// The partner's retained abort, or null (see `Served.partnerAbort`).
    pub fn partnerAbort(self: *const Session) ?driver.Served.PartnerAbortView {
        return self.hs.served.partnerAbort();
    }

    /// The partner's retained abort diagnostic, or null.
    pub fn abortReason(self: *const Session) ?[]const u8 {
        return self.hs.served.abortReason();
    }

    /// The eventual-send target gate the reference verbs share: only a near or
    /// far *object* reference is a target. A promise-kind near/far, a bare
    /// answer-promise, a sturdy, and a broken reference are refused
    /// `UncallableTarget` — pipelining rides the answer vow (`sendToAnswer`),
    /// never a promise-kind target — and a near object that names no live
    /// export resolves to nothing rather than being coerced into a vat actor
    /// id, which is a different number space.
    fn refForTarget(self: *Session, target: model.Reference) ?actors.Ref {
        return switch (target) {
            .far => |far_ref| if (far_ref.kind == .object) actors.Ref{ .far = far_ref } else null,
            .near => |near_ref| if (near_ref.kind == .object) self.hs.served.refForExport(near_ref.export_position.int()) else null,
            .promise, .sturdy, .broken => null,
        };
    }
};

/// Dial the peer `locator` names into one owned session: build a private
/// single-session host under `identity`, dial through whichever netlayer in
/// `netlayers` hosts the locator's transport, and pump the keyed handshake
/// under `opts.handshake`. The returned `*Session` is freed by
/// `Session.deinit`; `netlayers` (and the residents behind it) must outlive
/// it — and "outlive" means the whole session, not just the dial: the host
/// resolves later dials against this same slice, which is how a redeem
/// reaches an exporter, so a caller that builds the slice on a frame it then
/// returns from hands the host a dangling transport. A netlayer whose
/// transport reports no pollable fd is refused
/// `Error.TransportNotPollable`: the face multiplexes its blocking waits with
/// poll. A caller that wants to own the peer and buffers directly uses the
/// borrowing `connectVia` / `connectUri`; a caller that wants many sessions
/// under one identity builds a `driver.PollHost` and a `Server` explicitly.
pub fn connect(
    allocator: std.mem.Allocator,
    netlayers: []const net.netlayer.Netlayer,
    locator: model.PeerLocator,
    identity: Identity,
    opts: SessionOptions,
) !*Session {
    const nl = net.netlayer.resolve(netlayers, locator.transport) orelse return Error.UnknownTransport;
    const io = nl.io() orelse return Error.TransportNotPollable;

    const host = try allocator.create(host_mod.PollHost);
    errdefer allocator.destroy(host);
    host.* = try host_mod.PollHost.init(allocator, io, netlayers, identity, opts);
    errdefer host.deinit();

    const hs = try host.connectLocator(locator);

    const session = try allocator.create(Session);
    session.* = .{ .host = host, .hs = hs, .owner = .private_host, .allocator = allocator };
    return session;
}

/// Dial an `ocapn://` URI string in one call: parse it through the core
/// grammar, then dial with `connect`, signing with `identity`.
pub fn connectUriOwned(
    allocator: std.mem.Allocator,
    netlayers: []const net.netlayer.Netlayer,
    uri_str: []const u8,
    identity: Identity,
    opts: SessionOptions,
) !*Session {
    const locator = try model.uri.parsePeer(allocator, uri_str);
    defer model.freePeerLocator(allocator, locator);
    return connect(allocator, netlayers, locator, identity, opts);
}

/// The owning hosting half, bound by `listen` — the host twin of `connect`.
/// Every accepted partner shares this server's one host: one identity, one
/// live-session directory, shared routing. That directory is what lets a give
/// minted for one partner resolve its still-open gifter session when another
/// withdraws it. Each `accept` hands back a
/// `*Session` view freed by `Session.deinit`; release every accepted view
/// before `close`, which tears down the listener and the shared host.
pub const Server = struct {
    host: *host_mod.PollHost,
    listener: net.netlayer.Listener,
    allocator: std.mem.Allocator,

    /// Write the bound dialable designator (with the kernel-chosen port when
    /// `listen` bound port 0) into `out` and return the written slice.
    ///
    /// An error rather than an empty slice: this is the public surface a
    /// caller signs from, and an empty designator published as a locator is a
    /// locator nobody can dial.
    pub fn localDesignator(self: *const Server, out: []u8) driver.Error![]const u8 {
        const designator = self.listener.localDesignator(out);
        if (designator.len == 0) return driver.Error.DesignatorUnavailable;
        return designator;
    }

    /// Accept one partner into its own `*Session` view of the shared host.
    /// The responder keyed handshake completes inside, under the handshake
    /// budget. Freed by `Session.deinit` (which leaves the siblings serving).
    /// Publish one Host-Vat actor under `name`. Any accepted Port can discover
    /// it lazily; exact gifts retain that actor independently of later name
    /// changes.
    pub fn publishGiftable(self: *Server, name: []const u8, comptime Behavior: type, initial: Behavior) !void {
        return self.host.publishGiftable(name, Behavior, initial);
    }

    pub fn accept(self: *Server) !*Session {
        var designator_buf: [128]u8 = undefined;
        const designator = try self.localDesignator(&designator_buf);
        // Designator and hint are different locator dimensions: on keyed-tcp
        // the designator is the key and the dialable `host:port` rides the
        // hint, which `localHint` surfaces (empty on address transports,
        // which ignore it).
        var hint_buf: [128]u8 = undefined;
        const hint = self.listener.localHint(&hint_buf);
        const hs = try self.host.acceptWire(self.listener, self.listener.transportName(), designator, hint);
        const session = try self.allocator.create(Session);
        errdefer self.allocator.destroy(session);
        session.* = .{ .host = self.host, .hs = hs, .owner = .accepted, .allocator = self.allocator };
        self.host.accepted_views += 1;
        return session;
    }

    /// Wait until `accept` would make progress, up to `timeout_ms`. The
    /// stop-friendly twin of blocking accept: poll, check a latch, then
    /// `accept`.
    pub fn waitAcceptable(self: *Server, timeout_ms: i32) !bool {
        return self.listener.waitAcceptable(timeout_ms);
    }

    /// Stop listening and tear down the shared host. Every accepted view must
    /// be released first: they hold sessions of the host this frees, so
    /// closing under one is a use-after-free. That is refused with
    /// `Error.SessionsStillOpen` rather than asserted, because an assert
    /// compiles out in ReleaseFast and would turn a caller's ordering mistake
    /// into a silent dangle in exactly the build they ship.
    pub fn close(self: *Server) Error!void {
        if (self.host.accepted_views != 0) return Error.SessionsStillOpen;
        self.listener.close();
        self.host.deinit();
        self.allocator.destroy(self.host);
    }
};

/// Bind a listener on `netlayer` and return the owning `Server`, whose every
/// accept shares one host identity. `identity` is the responder signing
/// posture (`.ephemeral` fresh random, `.keyed` a caller-held key). A
/// netlayer whose transport reports no pollable fd is refused at accept
/// (`Error.TransportNotPollable`), the same poll boundary `connect` holds.
pub fn listen(
    allocator: std.mem.Allocator,
    netlayer: net.netlayer.Netlayer,
    config: net.netlayer.ListenConfig,
    identity: driver.AcceptIdentity,
    opts: SessionOptions,
) !Server {
    // A transport with no pollable fd cannot back a multiplexed blocking wait;
    // refuse it by its own name rather than as an entropy failure.
    const io = netlayer.io() orelse return Error.TransportNotPollable;
    const host = try allocator.create(host_mod.PollHost);
    errdefer allocator.destroy(host);
    host.* = try host_mod.PollHost.init(allocator, io, &.{}, acceptToIdentity(identity), opts);
    // The server's own transport is its dial table: an accepted session that
    // receives a give naming a third peer redeems it by dialing there, the
    // same contract the connect half and every binding carry.
    host.adoptOwnNetlayer(netlayer);
    errdefer host.deinit();

    var listener = try netlayer.listen(allocator, config);
    errdefer listener.close();

    var designator_buf: [128]u8 = undefined;
    const bound = listener.localDesignator(&designator_buf);
    if (bound.len > 0) host.core.setSelfDesignator(bound) catch {};

    return .{ .host = host, .listener = listener, .allocator = allocator };
}

/// Map the responder signing posture onto the dialer-shaped `Identity` the
/// host face takes: an accepting host's designator is the listener's bound
/// address (set after bind), so the keyed arm carries only the secret here.
fn acceptToIdentity(identity: driver.AcceptIdentity) Identity {
    return switch (identity) {
        .ephemeral => .ephemeral,
        .keyed => |secret| .{ .keyed = .{ .secret = secret, .designator = driver.unreachable_client_designator } },
    };
}
