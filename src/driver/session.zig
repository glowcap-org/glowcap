//! The owning, one-call driver surface: `Session` and `Server`, views over the
//! owning host face (`driver.HostRuntime`, ADR-0090).
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

const host_runtime = @import("host_runtime.zig");

const driver = @import("mod.zig");
const Settled = driver.Settled;
const Capability = driver.Capability;
const Value = driver.Value;
const Reply = driver.Reply;
const Identity = driver.Identity;
const Budget = driver.Budget;
const Error = driver.Error;

/// Options for `connect` and `listen` (see `driver.HostRuntime.Options`, the owning
/// face these views ride).
pub const SessionOptions = host_runtime.HostRuntime.Options;

/// An application-facing session, the object a native Zig application holds:
/// a view onto one session of a `driver.HostRuntime`. `connect` builds a
/// private runtime and core Host underneath and hands back its one view
/// (`deinit` tears the whole bundle down); `Server.accept` views borrow the
/// server's shared runtime (`deinit` releases that one session and leaves the
/// siblings serving).
/// Heap-pinned: the pointer is stable for the session view's life.
///
/// Because the core Host routes every session, a reply that introduces a
/// capability on a third machine settles as a live reference inside the wait:
/// the redeem dial runs in the runtime pump, under the handshake budget.
/// `Settled.give` never surfaces here.
pub const Session = struct {
    runtime: *host_runtime.HostRuntime,
    hs: *driver_core.HostSession,
    /// What this view owns, and therefore what its `deinit` reclaims.
    owner: Owner,
    allocator: std.mem.Allocator,

    /// A session view is one of three things, and a two-state flag could name
    /// only two of them. The third — a view onto a runtime the caller owns — was
    /// the one that had no spelling, so callers wrote a struct literal for it
    /// and `deinit` treated it as an accepted view: it decremented a counter
    /// no constructor had incremented, then freed a pointer that was usually
    /// on the stack. Naming the third state is what makes that unrepresentable
    /// rather than merely documented.
    pub const Owner = enum {
        /// `Session.view`: borrowed. The caller owns the runtime and releases
        /// the session, so `deinit` reclaims nothing and is safe on a value
        /// that was never heap-allocated.
        borrowed,
        /// `Server.accept`: one session of the server's shared runtime.
        accepted,
        /// `driver.connect`: the whole private bundle, runtime included.
        private_runtime,
    };

    /// A borrowed view onto a session a caller-owned `HostRuntime` already holds.
    ///
    /// By value, and owning nothing: releasing the session stays the caller's
    /// job through `HostRuntime.releaseWire`, and tearing down the runtime stays its
    /// own `deinit`. This exists so that shape has a constructor at all.
    /// Without one, every caller wrote the struct literal, and a literal is
    /// where the owner gets guessed.
    pub fn view(runtime: *host_runtime.HostRuntime, hs: *driver_core.HostSession) Error!Session {
        if (hs.host != runtime.core) return Error.SessionNotOwned;
        const wire = runtime.wires.get(hs.peer_id) orelse return Error.SessionNotOwned;
        if (wire.session != hs) return Error.SessionNotOwned;
        return .{ .runtime = runtime, .hs = hs, .owner = .borrowed, .allocator = runtime.allocator };
    }

    /// Reclaim what this view owns. A borrowed view owns nothing, so this is
    /// a no-op there; the runtime it points at is the caller's to tear down.
    pub fn deinit(self: *Session) void {
        switch (self.owner) {
            .borrowed => return,
            .private_runtime => {
                self.runtime.deinit();
                self.allocator.destroy(self.runtime);
            },
            .accepted => {
                self.runtime.releaseWire(self.hs);
                self.runtime.accepted_views -= 1;
            },
        }
        self.allocator.destroy(self);
    }

    /// Begin the bootstrap fetch for `name`, returning its vow without
    /// blocking (see `driver_core.Served.beginFetch`).
    pub fn beginFetch(self: *Session, name: []const u8) !actors.Vow {
        self.runtime.enterDriver();
        defer self.runtime.leaveDriver();
        const vow = try self.hs.served.sendBootstrapFetch(&self.runtime.core.vat, name);
        try self.runtime.core.flushSession(self.hs);
        return vow;
    }

    /// Chain fetch-then-send without blocking (see `Served.beginSendNamed`).
    /// Args are owning-tier `Value`s; the pending machinery owns its own clone
    /// of the lowered message, so the caller's slices are borrowed for this
    /// call only.
    pub fn beginSendNamed(self: *Session, pending: *driver.PendingSend, name: []const u8, verb: []const u8, args: []const Value, terminal: actors.Listener) !void {
        self.runtime.enterDriver();
        defer self.runtime.leaveDriver();
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const lowered = try self.runtime.core.lowerValues(self.hs, scratch.allocator(), args);
        try self.hs.served.beginSendNamed(&self.runtime.core.vat, pending, name, .{ .verb = verb, .args = lowered }, terminal);
        try self.runtime.core.flushSession(self.hs);
    }

    /// Chain fetch-then-tell without blocking (see `Served.beginTellNamed`).
    pub fn beginTellNamed(self: *Session, pending: *driver.PendingSend, name: []const u8, verb: []const u8, args: []const Value, terminal: actors.Listener) !void {
        self.runtime.enterDriver();
        defer self.runtime.leaveDriver();
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const lowered = try self.runtime.core.lowerValues(self.hs, scratch.allocator(), args);
        try self.hs.served.beginTellNamed(&self.runtime.core.vat, pending, name, .{ .verb = verb, .args = lowered }, terminal);
        try self.runtime.core.flushSession(self.hs);
    }

    /// Break every far vow still awaiting a partner answer (cancel / timeout /
    /// teardown). Stable `message` bytes are what listeners observe.
    pub fn breakFarVows(self: *Session, message: []const u8) void {
        self.runtime.enterDriver();
        defer self.runtime.leaveDriver();
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
        self.runtime.enterDriver();
        defer self.runtime.leaveDriver();
        return self.runtime.core.partnerIdentity(self.hs);
    }

    /// Fetch a partner's published capability by `name`, returning its opaque
    /// Host `Capability` (ADR-0096). The fulfilled reference is lifted while
    /// its owning session is known, so handing it back to the partner — or to
    /// a third party — routes to the right exporter without the application
    /// ever holding a wire position. An unpublished name returns
    /// `Error.FetchBroken`; any other fulfill returns
    /// `Error.FetchNotACapability`.
    pub fn fetch(self: *Session, name: []const u8) !Capability {
        self.runtime.enterDriver();
        defer self.runtime.leaveDriver();
        var capture = driver.FetchCapture{};
        const id = try self.runtime.core.fetch(self.hs, name);
        try self.awaitVowId(id, .{ .ctx = &capture, .func = driver.FetchCapture.record });
        return switch (capture.outcome orelse return Error.ConnectionClosed) {
            .capability => |far_ref| self.runtime.core.liftCapability(self.hs, .{ .far = far_ref }),
            .broken => Error.FetchBroken,
            .not_a_capability => Error.FetchNotACapability,
        };
    }

    /// The reason-bearing fetch: the partner's settlement whole, lifted and
    /// materialized into `arena` (reset the arena to reclaim it).
    pub fn fetchSettled(self: *Session, name: []const u8, arena: std.mem.Allocator) !Reply {
        self.runtime.enterDriver();
        defer self.runtime.leaveDriver();
        var capture = driver.SettleCapture{ .arena = arena };
        const id = try self.runtime.core.fetch(self.hs, name);
        try self.awaitVowId(id, .{ .ctx = &capture, .func = driver.SettleCapture.fire });
        return self.replyFromSettled(self.hs, arena, try capture.finish());
    }

    /// Eventual-send to `target` and block until the reply settles,
    /// materializing both `Reply` arms into caller-owned `arena`. The node
    /// routes the capability to its exporter session, so a redeemed or
    /// re-gifted capability is called the same way a directly fetched one is;
    /// an argument foreign to the routed session is refused whole
    /// (`ForeignArgument`). Returns `ConnectionClosed` if the partner leaves
    /// before the reply settles.
    pub fn call(self: *Session, target: Capability, verb: []const u8, args: []const Value, arena: std.mem.Allocator) !Reply {
        self.runtime.enterDriver();
        defer self.runtime.leaveDriver();
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const routed = try self.routedSend(target, verb, args, &scratch);
        return self.replyVowOn(routed.session, routed.vow, arena);
    }

    /// Eventual-send to `target`, returning the reply's vow without blocking;
    /// settle it with `settleVow` or observe it with `on`. Args are borrowed
    /// for this call: the actor layer owns its clone before this returns.
    pub fn send(self: *Session, target: Capability, verb: []const u8, args: []const Value) !actors.Vow {
        self.runtime.enterDriver();
        defer self.runtime.leaveDriver();
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const routed = try self.routedSend(target, verb, args, &scratch);
        return routed.vow;
    }

    /// One lowered, routed delivery, the prologue `call` / `send` / `tell`
    /// share: gate the target on object kind, lower it and the args on this
    /// session, and route to the exporter session. The lowered args live in
    /// `scratch`, which must outlive the served verb that consumes them.
    const RoutedDelivery = struct { session: *driver_core.HostSession, target: actors.Ref, args: []const model.Argument };

    fn routeDelivery(self: *Session, target: Capability, args: []const Value, scratch: *std.heap.ArenaAllocator) !RoutedDelivery {
        const lowered = try self.runtime.core.lowerValues(self.hs, scratch.allocator(), args);
        // A local capability sends as its Vat actor directly: a same-side
        // call needs no wire position, so no export is minted and no binding
        // root is taken (ADR-0101).
        if (self.runtime.core.localActorFor(target)) |local| {
            return .{ .session = self.hs, .target = local, .args = lowered };
        }
        const target_ref = try self.targetForSend(target);
        const routed = try self.runtime.core.routeSend(self.hs, target_ref, lowered);
        return .{ .session = routed.session, .target = routed.target, .args = lowered };
    }

    /// The one lowered, routed eventual-send `call` / `send` share: route,
    /// send, and flush a far send's encode. A near send queues a local turn
    /// instead — driving it here would settle the vow before the caller could
    /// register a listener, so the drive waits for the next flush or settle
    /// (the borrowing tier's contract exactly).
    fn routedSend(self: *Session, target: Capability, verb: []const u8, args: []const Value, scratch: *std.heap.ArenaAllocator) !struct { session: *driver_core.HostSession, vow: actors.Vow } {
        const routed = try self.routeDelivery(target, args, scratch);
        const vow = try routed.session.served.send(&self.runtime.core.vat, routed.target, .{ .verb = verb, .args = routed.args });
        if (routed.target == .far) try self.runtime.core.flushSession(routed.session);
        return .{ .session = routed.session, .vow = vow };
    }

    /// Listen on the promise `target` names, returning a vow for its
    /// settlement (see `Served.listenTo`). A promise this partner handed us
    /// settles through a notification it delivers, so this is how a received
    /// promise capability is waited on; `listenSettled` is the blocking form.
    /// A remote target routes through the node, so a re-gifted promise is
    /// listened on its exporter session. A give that arrives in the
    /// settlement is redeemed on the way through, exactly as one arriving in
    /// a call's reply is. No object-kind gate here: a listen's usual target
    /// is a promise capability.
    pub fn listenTo(self: *Session, target: Capability) !actors.Vow {
        self.runtime.enterDriver();
        defer self.runtime.leaveDriver();
        return (try self.listenToRouted(target)).vow;
    }

    /// Listen on the promise `target` names and block until it settles,
    /// lifting the outcome into `arena`.
    pub fn listenSettled(self: *Session, target: Capability, arena: std.mem.Allocator) !Reply {
        self.runtime.enterDriver();
        defer self.runtime.leaveDriver();
        const routed = try self.listenToRouted(target);
        // Drive the session the listen actually rides, which for a routed
        // capability is the exporter's, not this view's.
        return self.replyVowOn(routed.session, routed.vow, arena);
    }

    fn listenToRouted(self: *Session, target: Capability) !struct { session: *driver_core.HostSession, vow: actors.Vow } {
        const target_ref = try self.runtime.core.lowerCapability(self.hs, target);
        if (target_ref == .far) {
            const routed = try self.runtime.core.routeSend(self.hs, target_ref, &.{});
            const vow = try routed.session.served.listenTo(.{ .far = routed.target.far });
            // The `op:listen` owes the wire its encode now, like a far send's.
            try self.runtime.core.flushSession(routed.session);
            return .{ .session = routed.session, .vow = vow };
        }
        // A near capability is local; the engine verb refuses the non-promise
        // shapes with `InvalidReference`.
        const vow = try self.hs.served.listenTo(target_ref);
        return .{ .session = self.hs, .vow = vow };
    }

    /// Promise pipelining against a far `vow` (see `Served.sendToAnswer`).
    pub fn sendToAnswer(self: *Session, vow: actors.Vow, verb: []const u8, args: []const Value) !actors.Vow {
        self.runtime.enterDriver();
        defer self.runtime.leaveDriver();
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const lowered = try self.runtime.core.lowerValues(self.hs, scratch.allocator(), args);
        const next = try self.hs.served.sendToAnswer(&self.runtime.core.vat, vow, .{ .verb = verb, .args = lowered });
        try self.runtime.core.flushSession(self.hs);
        return next;
    }

    /// Block until `vow` settles, lifting the outcome into `arena`.
    pub fn settleVow(self: *Session, vow: actors.Vow, arena: std.mem.Allocator) !Reply {
        self.runtime.enterDriver();
        defer self.runtime.leaveDriver();
        return self.replyVowOn(self.hs, vow, arena);
    }

    /// The blocking settle every `Reply`-returning verb shares: capture the
    /// wire-shaped settlement into `arena`, then lift it on `hs` — after the
    /// wait, outside any listener fire, the same order the C ABI lifts at its
    /// action drain. The lifted tree's spines live in `arena` and its leaves
    /// alias the capture, which is why a reply has no `deinit`: reset the
    /// arena and both go together.
    fn replyVowOn(self: *Session, hs: *driver_core.HostSession, vow: actors.Vow, arena: std.mem.Allocator) !Reply {
        var capture = driver.SettleCapture{ .arena = arena };
        try self.awaitVow(hs, vow, .{ .ctx = &capture, .func = driver.SettleCapture.fire });
        return self.replyFromSettled(hs, arena, try capture.finish());
    }

    /// Lift an already-captured wire settlement on this session into a
    /// `Reply` (the REPL's cooperative queue captures first and renders
    /// later; ordinary blocking verbs never need this).
    pub fn liftSettled(self: *Session, settled: Settled, arena: std.mem.Allocator) !Reply {
        self.runtime.enterDriver();
        defer self.runtime.leaveDriver();
        return self.replyFromSettled(self.hs, arena, settled);
    }

    fn replyFromSettled(self: *Session, hs: *driver_core.HostSession, arena: std.mem.Allocator, settled: Settled) !Reply {
        return switch (settled) {
            .fulfilled => |arg| .{ .fulfilled = try self.runtime.core.liftValue(hs, arena, arg) },
            .broken => |reason| .{ .broken = reason },
            // The owning tier redeems a give inside the wait it settles under;
            // one that still surfaces is a broken introduction, not a value.
            .give => .{ .broken = "unredeemed handoff give" },
        };
    }

    /// The eventual-send target gate `call` / `send` / `tell` share: only an
    /// object capability is a send target. A promise capability is listened on
    /// (`listenTo`) or pipelined through its answer vow (`sendToAnswer`),
    /// never sent to directly.
    fn targetForSend(self: *Session, target: Capability) !model.Reference {
        const target_ref = try self.runtime.core.lowerCapability(self.hs, target);
        const object = switch (target_ref) {
            .near => |near| near.kind == .object,
            .far => |far| far.kind == .object,
            else => false,
        };
        if (!object) return Error.UncallableTarget;
        return target_ref;
    }

    /// Register `listener` on host vow `id` behind a settle flag and block
    /// until it fires — the host-vow twin of `BlockingSession.awaitVow`. The
    /// flag lives on this frame for the whole wait, so the listener's ctx
    /// outlives every fire. No pre-pump flush: `core.fetch` and the vow verbs
    /// pump their own send before returning the id.
    fn awaitVowId(self: *Session, id: u64, listener: actors.Listener) !void {
        var flag = driver.SettleFlag{ .inner = listener };
        try self.runtime.core.vowOn(id, .{ .ctx = &flag, .func = driver.SettleFlag.fire });
        try self.pumpWait(self.hs, &flag.done);
    }

    /// Register `listener` on a vat `vow` behind a settle flag, drive, and
    /// block until it fires. Listener first, then the drive: a near target's
    /// vow settles inside this flush's own local turn, firing the capture
    /// before the pump parks.
    fn awaitVow(self: *Session, hs: *driver_core.HostSession, vow: actors.Vow, listener: actors.Listener) !void {
        var flag = driver.SettleFlag{ .inner = listener };
        try hs.served.port.on(&hs.host.vat, vow, .{ .ctx = &flag, .func = driver.SettleFlag.fire });
        try self.runtime.core.flushSession(hs);
        try self.pumpWait(hs, &flag.done);
    }

    /// The one blocking wait every stack-capture verb runs. On any pump
    /// failure the session's far vows break *before* the error unwinds, so a
    /// listener whose ctx is this frame's stack fires while the frame is
    /// alive — a later break firing it into a dead frame is the memory bug,
    /// not the timeout (the same contract `BlockingSession`'s waits hold).
    fn pumpWait(self: *Session, hs: *driver_core.HostSession, flag: *const bool) !void {
        self.runtime.pumpUntilFlag(hs, flag, self.runtime.opts.settle) catch |err| {
            hs.served.port.breakFarVows(hs.served.closeReason("wait failed"));
            return err;
        };
    }

    /// Fire-and-forget eventual-send (see `Served.tell`), routed exactly as
    /// `call` routes.
    pub fn tell(self: *Session, target: Capability, verb: []const u8, args: []const Value) !void {
        self.runtime.enterDriver();
        defer self.runtime.leaveDriver();
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const routed = try self.routeDelivery(target, args, &scratch);
        try routed.session.served.tell(&self.runtime.core.vat, routed.target, .{ .verb = verb, .args = routed.args });
        try self.runtime.core.flushSession(routed.session);
    }

    /// Observe `vow` with a caller listener (see `Vat.on`). The listener fires
    /// during a later pump on this session.
    pub fn on(self: *Session, vow: actors.Vow, listener: actors.Listener) !void {
        self.runtime.enterDriver();
        defer self.runtime.leaveDriver();
        return self.hs.served.port.on(&self.runtime.core.vat, vow, listener);
    }

    /// Spawn a local actor and return its opaque capability. `Behavior` is
    /// Value-shaped (see `driver_core.Hosting`): its handler receives lifted
    /// `Value` args and answers with a `Value`, so hosting code speaks opaque
    /// capabilities end to end.
    pub fn spawn(self: *Session, comptime Behavior: type, initial: Behavior) !Capability {
        self.runtime.enterDriver();
        defer self.runtime.leaveDriver();
        const ref = try self.runtime.core.vat.spawn(driver_core.Hosting(Behavior), .{ .inner = initial });
        errdefer self.runtime.core.vat.discardFreshActor(ref);
        // The capability slot adopts the spawn root (ADR-0101); wire
        // positions mint lazily at first marshal, so releasing the last
        // handle of a never-passed spawn reclaims the actor.
        return self.runtime.core.liftLocalActor(ref);
    }

    /// Publish an actor a partner can `fetch` by `name`. `Behavior` is
    /// Value-shaped like `spawn`'s.
    pub fn publish(self: *Session, name: []const u8, comptime Behavior: type, initial: Behavior) !Capability {
        self.runtime.enterDriver();
        defer self.runtime.leaveDriver();
        const exported = try self.hs.served.publish(&self.runtime.core.vat, name, driver_core.Hosting(Behavior), .{ .inner = initial });
        return self.runtime.core.liftCapability(self.hs, exported.nearRef());
    }

    /// Enliven a complete sturdyref by Host-level select-or-dial (ADR-0098
    /// step 4): the host resolves the sturdyref's peer to the live dialed
    /// session it names, or dials it, so the caller never picks the session —
    /// the peer named in the sturdyref does. The settled capability arrives
    /// lifted, like every owning-tier reference.
    pub fn enliven(self: *Session, sturdy: model.SturdyRef) !Capability {
        self.runtime.enterDriver();
        defer self.runtime.leaveDriver();
        return self.runtime.enliven(sturdy);
    }

    /// `enliven` from an `ocapn://…/s/…` sturdyref URI string.
    pub fn enlivenUri(self: *Session, uri_str: []const u8) !Capability {
        self.runtime.enterDriver();
        defer self.runtime.leaveDriver();
        const sturdy = try model.uri.parseSturdyrefForProfile(
            self.allocator,
            self.hs.served.port.peer.session_state.captp_version,
            uri_str,
        );
        defer model.uri.freeSturdyref(self.allocator, sturdy);
        return self.enliven(sturdy);
    }

    /// Release one application retain on `cap`. The final release retires the
    /// opaque identity — a later use fails closed — and, for a remote
    /// capability, queues its exact wire GC release.
    pub fn release(self: *Session, cap: Capability) !void {
        self.runtime.enterDriver();
        defer self.runtime.leaveDriver();
        try self.runtime.core.releaseCapability(cap, 1);
    }

    /// One blocking pump cycle across the host: drain actions, wait for any
    /// live session's readable progress, feed it. Returns this session's
    /// `Progress` so a caller's loop can act on `.closed`.
    pub fn step(self: *Session) !net.Progress {
        return (try self.runtime.stepSession(self.hs, -1)) orelse .idle;
    }

    /// Poll-guarded `step`: wait up to `timeout_ms` for readable progress, or
    /// null on timeout. The multiplexing convenience over `step`.
    pub fn stepReadable(self: *Session, timeout_ms: i32) !?net.Progress {
        return self.runtime.stepSession(self.hs, timeout_ms);
    }

    /// Serve this session until the partner leaves: run `step` until it
    /// reports `.closed`. Far vows break with the close reason inside the
    /// pump's release, exactly as on the borrowing tier.
    pub fn serve(self: *Session) !void {
        while (true) {
            const progress = (try self.runtime.stepSession(self.hs, -1)) orelse continue;
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
        self.runtime.enterDriver();
        defer self.runtime.leaveDriver();
        return self.hs.served.partnerAbort();
    }

    /// The partner's retained abort diagnostic, or null.
    pub fn abortReason(self: *const Session) ?[]const u8 {
        self.runtime.enterDriver();
        defer self.runtime.leaveDriver();
        return self.hs.served.abortReason();
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
/// under one identity builds a `driver.HostRuntime` and a `Server` explicitly.
pub fn connect(
    allocator: std.mem.Allocator,
    netlayers: []const net.netlayer.Netlayer,
    locator: model.PeerLocator,
    identity: Identity,
    opts: SessionOptions,
) !*Session {
    const nl = net.netlayer.resolve(netlayers, locator.transport) orelse return Error.UnknownTransport;
    const io = nl.io() orelse return Error.TransportNotPollable;

    const runtime = try allocator.create(host_runtime.HostRuntime);
    errdefer allocator.destroy(runtime);
    runtime.* = try host_runtime.HostRuntime.init(allocator, io, netlayers, identity, opts);
    errdefer runtime.deinit();

    const hs = try runtime.connectLocator(locator);

    const session = try allocator.create(Session);
    session.* = .{ .runtime = runtime, .hs = hs, .owner = .private_runtime, .allocator = allocator };
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
    runtime: *host_runtime.HostRuntime,
    listener: net.netlayer.Listener,
    allocator: std.mem.Allocator,

    /// Write the bound dialable designator (with the kernel-chosen port when
    /// `listen` bound port 0) into `out` and return the written slice.
    ///
    /// An error rather than an empty slice: this is the public surface a
    /// caller signs from, and an empty designator published as a locator is a
    /// locator nobody can dial.
    pub fn localDesignator(self: *const Server, out: []u8) driver.Error![]const u8 {
        const designator = self.advertisedLocator().designator;
        if (designator.len == 0 or designator.len > out.len) return driver.Error.DesignatorUnavailable;
        @memcpy(out[0..designator.len], designator);
        return out[0..designator.len];
    }

    /// Replace the complete locator this server advertises on subsequent
    /// sessions and in handoffs. `listen` installs a listener-derived default;
    /// deployments use this override when peers should dial an ingress, proxy,
    /// externally mapped address, or another adapter-owned route instead.
    /// Already-open sessions retain the snapshot their hello signed.
    pub fn setAdvertisedLocator(self: *Server, locator: model.PeerLocator) !void {
        self.runtime.enterDriver();
        defer self.runtime.leaveDriver();
        if (!std.mem.eql(u8, locator.transport, self.listener.transportName()))
            return error.TransportMismatch;
        try self.runtime.core.setAdvertisedLocator(locator);
    }

    /// Borrow the currently advertised locator. The view remains valid until
    /// `setAdvertisedLocator`, removal through the lower host tier, or close.
    pub fn advertisedLocator(self: *const Server) model.PeerLocator {
        self.runtime.enterDriver();
        defer self.runtime.leaveDriver();
        return self.runtime.core.advertisedLocator(self.listener.transportName()).?;
    }

    /// Accept one partner into its own `*Session` view of the shared host.
    /// The responder keyed handshake completes inside, under the handshake
    /// budget. Freed by `Session.deinit` (which leaves the siblings serving).
    /// Publish one Host-Vat actor under `name`. Any accepted Port can discover
    /// it lazily; exact gifts retain that actor independently of later name
    /// changes.
    pub fn publishGiftable(self: *Server, name: []const u8, comptime Behavior: type, initial: Behavior) !void {
        return self.runtime.publishGiftable(name, Behavior, initial);
    }

    /// Remove the Host-wide alias `name` (see `HostRuntime.unpublish`): a later
    /// fetch misses on every accepted session, while issued capabilities and
    /// deposited gifts keep the exact actor. A minted durable name is refused
    /// here; it leaves through `removeDurable` (ADR-0098).
    pub fn unpublish(self: *Server, name: []const u8) error{ UnknownPublication, ReservedDurableNamespace }!void {
        return self.runtime.unpublish(name);
    }

    /// Publish `initial` under a freshly minted durable swiss name and return
    /// the complete sturdyref URI (`ocapn://…`), allocated with `allocator`
    /// and owned by the caller (ADR-0098): unpredictable, never reassigned,
    /// removable only through `removeDurable`, structurally disjoint from
    /// every mutable alias. Entropy is drawn here, at the I/O boundary; the
    /// sans-io core only ever sees the bytes. `Behavior` is Value-shaped like
    /// every owning-tier behavior.
    pub fn publishDurable(self: *Server, allocator: std.mem.Allocator, comptime Behavior: type, initial: Behavior) ![]u8 {
        self.runtime.enterDriver();
        defer self.runtime.leaveDriver();
        var entropy: [engine.durable_swiss_entropy_len]u8 = undefined;
        self.runtime.io.randomSecure(&entropy) catch return driver.Error.MintEntropyFailed;
        const swiss = try self.runtime.core.publishDurable(entropy, driver_core.Hosting(Behavior), .{ .inner = initial });
        const advertised = self.runtime.core.acceptableLocator() orelse
            return error.MissingAdvertisedLocator;
        return model.uri.writeSturdyrefForProfile(allocator, self.runtime.opts.captp_version, .{
            .peer = advertised,
            .swissnum = swiss.slice(),
        });
    }

    /// Remove a minted durable publication (see `driver_core.Host.removeDurable`):
    /// the old sturdyref misses from now on, while issued capabilities and
    /// deposited gifts keep the exact actor.
    pub fn removeDurable(self: *Server, swiss: []const u8) error{ UnknownPublication, NotDurableName }!void {
        self.runtime.enterDriver();
        defer self.runtime.leaveDriver();
        return self.runtime.core.removeDurable(swiss);
    }

    pub fn accept(self: *Server) !*Session {
        const hs = try self.runtime.acceptWire(self.listener, self.listener.transportName());
        const session = try self.allocator.create(Session);
        errdefer self.allocator.destroy(session);
        session.* = .{ .runtime = self.runtime, .hs = hs, .owner = .accepted, .allocator = self.allocator };
        self.runtime.accepted_views += 1;
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
        if (self.runtime.accepted_views != 0) return Error.SessionsStillOpen;
        self.listener.close();
        self.runtime.deinit();
        self.allocator.destroy(self.runtime);
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
    const runtime = try allocator.create(host_runtime.HostRuntime);
    errdefer allocator.destroy(runtime);
    // The server's own transport is its immutable dial table: an accepted
    // session that receives a give naming a third peer redeems it there.
    try host_runtime.HostRuntime.initWithOwnNetlayer(
        runtime,
        allocator,
        io,
        netlayer,
        acceptToIdentity(identity),
        opts,
    );
    errdefer runtime.deinit();

    var listen_config = config;
    listen_config.identity = switch (identity) {
        .ephemeral => null,
        .keyed => |secret| secret.publicKey(),
    };
    if (netlayer.designatorScheme() == .key and listen_config.identity == null)
        return Error.EphemeralIdentityOnKeyedTransport;
    var listener = try netlayer.listen(allocator, listen_config);
    errdefer listener.close();

    // A rendezvous listener may own network registration in a cancellable
    // background task. Do not sign or publish its locator until that task has
    // made the locator reachable. Ordinary bound listeners are ready already.
    const ready_timeout: i32 = switch (opts.handshake) {
        .unbounded => -1,
        .ms => |milliseconds| @max(milliseconds, 0),
    };
    if (!try listener.waitReady(ready_timeout)) return Error.HandshakeTimedOut;

    const bound_locator = try listener.localLocator(allocator);
    defer model.freePeerLocator(allocator, bound_locator);
    if (!std.mem.eql(u8, bound_locator.transport, listener.transportName()))
        return error.ProviderContract;
    if (listen_config.identity) |expected| {
        if (listener.designatorScheme() == .key) {
            const expected_designator = expected.toDesignator();
            if (!std.mem.eql(u8, bound_locator.designator, &expected_designator))
                return Error.UnheldIdentity;
        }
    }
    try runtime.core.setAdvertisedLocator(bound_locator);

    return .{ .runtime = runtime, .listener = listener, .allocator = allocator };
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
