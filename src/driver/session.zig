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

/// An allocation-free eventual result scoped to the owning Session. Its core
/// vow row is pending work from creation until settlement, including when the
/// caller ignores the value; use `Session.tell` for fire-and-forget delivery.
/// Register `on` before stepping the runtime, matching `actors.Vow`'s one-shot
/// listener contract.
pub const Promise = struct {
    owner: *Session,
    home: *driver_core.HostSession,
    id: u64,

    pub fn send(self: Promise, verb: []const u8, args: []const Value) !Promise {
        return self.owner.sendToPromise(self, verb, args);
    }

    pub fn settle(self: Promise, arena: std.mem.Allocator) !Reply {
        return self.owner.settlePromise(self, arena);
    }

    pub fn on(self: Promise, listener: actors.Listener) !void {
        return self.owner.observePromise(self, listener);
    }
};

/// Options for `connect` and `listen` (see `driver.HostRuntime.Options`, the owning
/// face these views ride).
pub const SessionOptions = host_runtime.HostRuntime.Options;

/// Heap-stable ownership shared by a one-call Server and the Sessions it has
/// already yielded. The listener owns one lease and each accepted Session owns
/// one more; closing the listener drops only its lease. The last lease tears
/// down the runtime and every runtime-internal session that was never yielded.
const SharedRuntime = struct {
    runtime: host_runtime.HostRuntime,
    allocator: std.mem.Allocator,
    leases: usize = 1,

    fn retain(self: *SharedRuntime) void {
        // Every lease beyond the listener's owns a distinct heap-allocated
        // Session, so the address space is exhausted before usize can be.
        std.debug.assert(self.leases != std.math.maxInt(usize));
        self.leases += 1;
    }

    fn releaseOutcome(self: *SharedRuntime) ?driver.OperationFailure {
        std.debug.assert(self.leases != 0);
        self.leases -= 1;
        if (self.leases != 0) return null;
        const allocator = self.allocator;
        const failure = self.runtime.deinitOutcome();
        allocator.destroy(self);
        return failure;
    }

    fn releaseImplicit(self: *SharedRuntime) bool {
        std.debug.assert(self.leases != 0);
        self.leases -= 1;
        if (self.leases != 0) return false;
        const allocator = self.allocator;
        if (self.runtime.deinitOutcome()) |failure| self.runtime.reportUnhandledFailure(failure);
        allocator.destroy(self);
        return true;
    }

    /// Deferred Session cleanup runs from HostRuntime's quiescent tail. True
    /// means this was the final lease and the callback destroyed that runtime;
    /// its caller must return without dereferencing the HostRuntime again.
    fn releaseDeferred(self: *SharedRuntime) bool {
        return self.releaseImplicit();
    }
};

/// An application-facing session, the object a native Zig application holds:
/// an owning handle for one session of a `driver.HostRuntime`. `connect` and
/// `Server.accept` retain their heap-stable runtime; `adopt` transfers one
/// caller-owned runtime wire into the same Session contract while borrowing
/// the runtime itself. In every case `deinit` cancels and releases this
/// session. A borrowed runtime must outlive its adopted Sessions.
/// Heap-pinned: the pointer is stable for the session handle's life.
///
/// Because the core Host routes every session, a reply that introduces a
/// capability on a third machine settles as a live reference inside the wait:
/// the redeem dial runs in the runtime pump, under the handshake budget.
/// `Settled.give` never surfaces here.
pub const Session = struct {
    runtime: *host_runtime.HostRuntime,
    hs: *driver_core.HostSession,
    runtime_lease: RuntimeLease,
    allocator: std.mem.Allocator,
    deferred_release: host_runtime.HostRuntime.DeferredSessionRelease,
    active_calls: usize = 0,
    native_release_complete: bool = false,

    const RuntimeLease = union(enum) {
        /// `Session.adopt`: the Session owns its wire, while its caller keeps
        /// the surrounding runtime alive.
        borrowed,
        /// `connect` / `Server.accept`: the Session retains the runtime
        /// allocation independently of the listener or any sibling Session.
        retained: *SharedRuntime,
    };

    /// Transfer one wire from a caller-owned HostRuntime into an owning
    /// Session. The runtime remains borrowed and must outlive the returned
    /// handle; the caller must not also call `releaseWire` for `hs`.
    pub fn adopt(runtime: *host_runtime.HostRuntime, hs: *driver_core.HostSession) Error!*Session {
        if (hs.host != runtime.core) return Error.SessionNotOwned;
        const session = try runtime.allocator.create(Session);
        errdefer runtime.allocator.destroy(session);
        try runtime.claimSessionHandle(hs);
        session.* = .{
            .runtime = runtime,
            .hs = hs,
            .runtime_lease = .borrowed,
            .allocator = runtime.allocator,
            .deferred_release = .{
                .session = hs,
                .ctx = session,
                .complete = completeDeferredRelease,
            },
        };
        return session;
    }

    fn enterCall(self: *Session) void {
        std.debug.assert(!self.native_release_complete);
        self.active_calls += 1;
        self.runtime.enterDriver();
    }

    fn leaveCall(self: *Session) void {
        self.runtime.leaveDriver();
        std.debug.assert(self.active_calls != 0);
        self.active_calls -= 1;
        if (self.active_calls == 0 and self.native_release_complete) _ = self.completeRelease();
    }

    /// Implicit cleanup always cancels, then releases the wire and its runtime
    /// lease. Use `close(.{ .finish = budget })` first when pending operations
    /// should receive a grace period.
    pub fn deinit(self: *Session) void {
        if (self.runtime.withinCallback()) {
            self.runtime.deferSessionRelease(&self.deferred_release) catch |err| {
                // The wrapper cannot be consumed while its callback owns the
                // Host latch. Retain the refusal at the surviving Runtime and
                // leave this allocation pinned rather than terminating the
                // embedding process or freeing live native authority.
                self.runtime.noteTerminalFailure(err);
            };
            return;
        }
        self.enterCall();
        defer self.leaveCall();
        // `deinit` cannot return, but the Runtime can: retain the concrete
        // close refusal in its sticky terminal channel before consuming this
        // wrapper's release authority.
        self.runtime.closeSession(self.hs, .cancel) catch |err|
            self.runtime.noteTerminalFailure(err);
        // A listener fired by cancel may have transferred release to the
        // callback-safe queue. Its drain owns the wire and wrapper from here.
        if (self.deferred_release.queued) return;
        self.runtime.releaseWire(self.hs) catch |err| {
            // Implicit destruction has no return recipient. A pre-commit
            // release refusal leaves the native wire live, so retain the
            // failure and pin this wrapper rather than pretending teardown
            // committed or turning a library error into process death.
            self.runtime.noteTerminalFailure(err);
            return;
        };
        self.native_release_complete = true;
    }

    fn completeDeferredRelease(ctx: *anyopaque) bool {
        const self: *Session = @ptrCast(@alignCast(ctx));
        if (self.active_calls != 0) {
            self.native_release_complete = true;
            return false;
        }
        return self.completeRelease();
    }

    fn completeRelease(self: *Session) bool {
        const allocator = self.allocator;
        const lease = self.runtime_lease;
        allocator.destroy(self);
        return switch (lease) {
            .borrowed => false,
            .retained => |shared| shared.releaseDeferred(),
        };
    }

    /// Close this session under one monotonic pending-work policy. Repeated
    /// calls observe the same barrier; cancel may escalate an in-progress
    /// finish. Memory remains owned until `deinit`.
    pub fn close(self: *Session, pending: driver.PendingWork) !void {
        self.enterCall();
        defer self.leaveCall();
        return self.runtime.closeSession(self.hs, pending);
    }

    pub fn closeOutcome(self: *const Session) driver.CloseOutcome {
        self.runtime.enterDriver();
        defer self.runtime.leaveDriver();
        return self.runtime.sessionCloseOutcome(self.hs);
    }

    /// Begin the bootstrap fetch for `name`, returning its Promise without
    /// blocking (see `driver_core.Served.beginFetch`).
    pub fn beginFetch(self: *Session, name: []const u8) !Promise {
        self.enterCall();
        defer self.leaveCall();
        const id = try self.runtime.core.queueFetch(self.hs, name);
        return .{ .owner = self, .home = self.hs, .id = id };
    }

    /// Chain fetch-then-send without blocking (see `Served.beginSendNamed`).
    /// Args are owning-tier `Value`s; the pending machinery owns its own clone
    /// of the lowered message, so the caller's slices are borrowed for this
    /// call only.
    pub fn beginSendNamed(self: *Session, pending: *driver.PendingSend, name: []const u8, verb: []const u8, args: []const Value, terminal: actors.Listener) !void {
        self.enterCall();
        defer self.leaveCall();
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        try self.runtime.core.beginSendNamedValues(self.hs, pending, name, verb, args, scratch.allocator(), terminal);
    }

    /// Chain fetch-then-tell without blocking (see `Served.beginTellNamed`).
    pub fn beginTellNamed(self: *Session, pending: *driver.PendingSend, name: []const u8, verb: []const u8, args: []const Value, terminal: actors.Listener) !void {
        self.enterCall();
        defer self.leaveCall();
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        try self.runtime.core.beginTellNamedValues(self.hs, pending, name, verb, args, scratch.allocator(), terminal);
    }

    /// Break every far vow still awaiting a partner answer (cancel / timeout /
    /// teardown). Stable `message` bytes are what listeners observe.
    pub fn breakFarVows(self: *Session, message: []const u8) void {
        self.enterCall();
        defer self.leaveCall();
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
        self.enterCall();
        defer self.leaveCall();
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
        self.enterCall();
        defer self.leaveCall();
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
        self.enterCall();
        defer self.leaveCall();
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
        self.enterCall();
        defer self.leaveCall();
        const promise = try self.queueSend(target, verb, args);
        return self.replyVowId(promise.home, promise.id, arena);
    }

    /// Eventual-send to `target`, returning its Promise without blocking.
    /// Args are borrowed
    /// for this call: the actor layer owns its clone before this returns.
    pub fn send(self: *Session, target: Capability, verb: []const u8, args: []const Value) !Promise {
        self.enterCall();
        defer self.leaveCall();
        return self.queueSend(target, verb, args);
    }

    /// Lower one owning-tier delivery and commit it through the Host's routing,
    /// vow, and pending-work authority without driving local settlement.
    fn queueSend(self: *Session, target: Capability, verb: []const u8, args: []const Value) !Promise {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const id = try self.runtime.core.queueSendValues(self.hs, target, verb, args, scratch.allocator());
        return .{ .owner = self, .home = try self.runtime.core.vowSession(id), .id = id };
    }

    /// Listen on the promise `target` names, returning a Promise for its
    /// settlement (see `Served.listenTo`). A promise this partner handed us
    /// settles through a notification it delivers, so this is how a received
    /// promise capability is waited on; `listenSettled` is the blocking form.
    /// A remote target routes through the node, so a re-gifted promise is
    /// listened on its exporter session. A give that arrives in the
    /// settlement is redeemed on the way through, exactly as one arriving in
    /// a call's reply is. No object-kind gate here: a listen's usual target
    /// is a promise capability.
    pub fn listenTo(self: *Session, target: Capability) !Promise {
        self.enterCall();
        defer self.leaveCall();
        return self.queueListenTo(target);
    }

    /// Listen on the promise `target` names and block until it settles,
    /// lifting the outcome into `arena`.
    pub fn listenSettled(self: *Session, target: Capability, arena: std.mem.Allocator) !Reply {
        self.enterCall();
        defer self.leaveCall();
        const promise = try self.queueListenTo(target);
        return self.replyVowId(promise.home, promise.id, arena);
    }

    fn queueListenTo(self: *Session, target: Capability) !Promise {
        const id = try self.runtime.core.queueListenToCapability(self.hs, target);
        return .{ .owner = self, .home = try self.runtime.core.vowSession(id), .id = id };
    }

    fn sendToPromise(self: *Session, promise: Promise, verb: []const u8, args: []const Value) !Promise {
        self.enterCall();
        defer self.leaveCall();
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const id = try self.runtime.core.queueVowSendValues(promise.id, verb, args, scratch.allocator());
        return .{ .owner = self, .home = promise.home, .id = id };
    }

    fn settlePromise(self: *Session, promise: Promise, arena: std.mem.Allocator) !Reply {
        self.enterCall();
        defer self.leaveCall();
        return self.replyVowId(promise.home, promise.id, arena);
    }

    /// The blocking settle every `Reply`-returning verb shares.
    fn replyVowId(self: *Session, hs: *driver_core.HostSession, id: u64, arena: std.mem.Allocator) !Reply {
        var capture = driver.SettleCapture{ .arena = arena };
        try self.awaitVowIdOn(hs, id, .{ .ctx = &capture, .func = driver.SettleCapture.fire });
        return self.replyFromSettled(hs, arena, try capture.finish());
    }

    /// Lift an already-captured wire settlement on this session into a
    /// `Reply` (the REPL's cooperative queue captures first and renders
    /// later; ordinary blocking verbs never need this).
    pub fn liftSettled(self: *Session, settled: Settled, arena: std.mem.Allocator) !Reply {
        self.enterCall();
        defer self.leaveCall();
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

    /// Register `listener` on host vow `id` behind a settle flag and block
    /// until it fires — the host-vow twin of `BlockingSession.awaitVow`. The
    /// flag lives on this frame for the whole wait, so the listener's ctx
    /// outlives every fire. No pre-pump flush: `core.fetch` and the vow verbs
    /// pump their own send before returning the id.
    fn awaitVowId(self: *Session, id: u64, listener: actors.Listener) !void {
        return self.awaitVowIdOn(self.hs, id, listener);
    }

    fn awaitVowIdOn(self: *Session, hs: *driver_core.HostSession, id: u64, listener: actors.Listener) !void {
        var flag = driver.SettleFlag{ .inner = listener };
        try self.runtime.core.vowOn(id, .{ .ctx = &flag, .func = driver.SettleFlag.fire });
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
        self.enterCall();
        defer self.leaveCall();
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        try self.runtime.core.tellValues(self.hs, target, verb, args, scratch.allocator());
    }

    fn observePromise(self: *Session, promise: Promise, listener: actors.Listener) !void {
        self.enterCall();
        defer self.leaveCall();
        return self.runtime.core.vowOn(promise.id, listener);
    }

    /// Spawn a local actor and return its opaque capability. `Behavior` is
    /// Value-shaped (see `driver_core.Hosting`): its handler receives lifted
    /// `Value` args and answers with a `Value`, so hosting code speaks opaque
    /// capabilities end to end.
    pub fn spawn(self: *Session, comptime Behavior: type, initial: Behavior) !Capability {
        self.enterCall();
        defer self.leaveCall();
        return self.runtime.core.spawn(self.hs, driver_core.Hosting(Behavior), .{ .inner = initial });
    }

    /// Publish an actor a partner can `fetch` by `name`. `Behavior` is
    /// Value-shaped like `spawn`'s.
    pub fn publish(self: *Session, name: []const u8, comptime Behavior: type, initial: Behavior) !Capability {
        self.enterCall();
        defer self.leaveCall();
        return self.runtime.core.publish(self.hs, name, driver_core.Hosting(Behavior), .{ .inner = initial });
    }

    /// Return the Host capability published under `name` on this session, or
    /// null when no session-local or Host-wide publication has that name.
    pub fn publishedCapability(self: *Session, name: []const u8) !?Capability {
        self.enterCall();
        defer self.leaveCall();
        return self.runtime.core.publishedCapability(self.hs, name);
    }

    /// Enliven a complete sturdyref by Host-level select-or-dial (ADR-0098
    /// step 4): the host resolves the sturdyref's peer to the live dialed
    /// session it names, or dials it, so the caller never picks the session —
    /// the peer named in the sturdyref does. The settled capability arrives
    /// lifted, like every owning-tier reference.
    pub fn enliven(self: *Session, sturdy: model.SturdyRef) !Capability {
        self.enterCall();
        defer self.leaveCall();
        return self.runtime.enliven(sturdy);
    }

    /// `enliven` from an `ocapn://…/s/…` sturdyref URI string.
    pub fn enlivenUri(self: *Session, uri_str: []const u8) !Capability {
        self.enterCall();
        defer self.leaveCall();
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
        self.enterCall();
        defer self.leaveCall();
        try self.runtime.core.releaseCapability(cap, 1);
    }

    /// One blocking pump cycle across the host: drain actions, wait for any
    /// live session's readable progress, feed it. Returns this session's
    /// `Progress` so a caller's loop can act on `.closed`.
    pub fn step(self: *Session) !net.Progress {
        self.enterCall();
        defer self.leaveCall();
        return (try self.runtime.stepSession(self.hs, -1)) orelse .idle;
    }

    /// Poll-guarded `step`: wait up to `timeout_ms` for readable progress, or
    /// null on timeout. The multiplexing convenience over `step`.
    pub fn stepReadable(self: *Session, timeout_ms: i32) !?net.Progress {
        self.enterCall();
        defer self.leaveCall();
        return self.runtime.stepSession(self.hs, timeout_ms);
    }

    /// Serve this session until the partner leaves: run `step` until it
    /// reports `.closed`. Far vows break with the close reason inside the
    /// pump's release, exactly as on the borrowing tier.
    pub fn serve(self: *Session) !void {
        self.enterCall();
        defer self.leaveCall();
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

    const shared = try allocator.create(SharedRuntime);
    errdefer allocator.destroy(shared);
    shared.* = .{
        .runtime = try host_runtime.HostRuntime.init(allocator, io, netlayers, identity, opts),
        .allocator = allocator,
    };
    errdefer shared.runtime.deinit();

    const hs = try shared.runtime.connectLocator(locator, .inherit);

    const session = try allocator.create(Session);
    errdefer allocator.destroy(session);
    try shared.runtime.claimSessionHandle(hs);
    session.* = .{
        .runtime = &shared.runtime,
        .hs = hs,
        .runtime_lease = .{ .retained = shared },
        .allocator = allocator,
        .deferred_release = .{
            .session = hs,
            .ctx = session,
            .complete = Session.completeDeferredRelease,
        },
    };
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
/// `*Session` handle freed by `Session.deinit`. Closing the Server stops new
/// accepts while those yielded Sessions retain the shared Host runtime.
pub const Server = struct {
    runtime: *host_runtime.HostRuntime,
    shared: *SharedRuntime,
    listener: net.netlayer.Listener,
    allocator: std.mem.Allocator,
    closed: bool = false,
    close_failure: ?driver.OperationFailure = null,

    fn ensureOpen(self: *const Server) error{ServerClosed}!void {
        if (self.closed) return error.ServerClosed;
    }

    /// Write the bound dialable designator (with the kernel-chosen port when
    /// `listen` bound port 0) into `out` and return the written slice.
    ///
    /// An error rather than an empty slice: this is the public surface a
    /// caller signs from, and an empty designator published as a locator is a
    /// locator nobody can dial.
    pub fn localDesignator(self: *const Server, out: []u8) driver.Error![]const u8 {
        const designator = (try self.advertisedLocator()).designator;
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
        try self.ensureOpen();
        self.runtime.enterDriver();
        defer self.runtime.leaveDriver();
        if (!std.mem.eql(u8, locator.transport, self.listener.transportName()))
            return error.TransportMismatch;
        try self.runtime.core.setAdvertisedLocator(locator);
    }

    /// Borrow the currently advertised locator. The view remains valid until
    /// `setAdvertisedLocator`, removal through the lower host tier, or close.
    pub fn advertisedLocator(self: *const Server) driver.Error!model.PeerLocator {
        try self.ensureOpen();
        self.runtime.enterDriver();
        defer self.runtime.leaveDriver();
        return self.runtime.core.advertisedLocator(self.listener.transportName()).?;
    }

    /// Query or copy opaque transport-owned state that restores this
    /// listener's local address. Null means this transport has no restoration
    /// state. The complete size is returned and a short output is untouched.
    pub fn restorationState(
        self: *const Server,
        out: []u8,
    ) (driver.Error || net.netlayer.RestorationStateError)!?usize {
        try self.ensureOpen();
        self.runtime.enterDriver();
        defer self.runtime.leaveDriver();
        return try self.listener.restorationState(out);
    }

    /// Accept one partner into its own `*Session` view of the shared host.
    /// The responder keyed handshake completes inside, under the handshake
    /// budget. Freed by `Session.deinit` (which leaves the siblings serving).
    /// Publish one Host-Vat actor under `name`. Any accepted Port can discover
    /// it lazily; exact gifts retain that actor independently of later name
    /// changes.
    pub fn publishGiftable(self: *Server, name: []const u8, comptime Behavior: type, initial: Behavior) !void {
        try self.ensureOpen();
        return self.runtime.publishGiftable(name, Behavior, initial);
    }

    /// Remove the Host-wide alias `name` (see `HostRuntime.unpublish`): a later
    /// fetch misses on every accepted session, while issued capabilities and
    /// deposited gifts keep the exact actor. A minted durable name is refused
    /// here; it leaves through `removeDurable` (ADR-0098).
    pub fn unpublish(
        self: *Server,
        name: []const u8,
    ) error{ ServerClosed, HostClosing, ReenteredHost, WrongThread, UnknownPublication, ReservedDurableNamespace }!void {
        try self.ensureOpen();
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
        try self.ensureOpen();
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
    pub fn removeDurable(
        self: *Server,
        swiss: []const u8,
    ) error{ ServerClosed, HostClosing, ReenteredHost, WrongThread, UnknownPublication, NotDurableName }!void {
        try self.ensureOpen();
        self.runtime.enterDriver();
        defer self.runtime.leaveDriver();
        return self.runtime.core.removeDurable(swiss);
    }

    pub fn accept(self: *Server) !*Session {
        try self.ensureOpen();
        const hs = try self.runtime.acceptWire(self.listener, self.listener.transportName());
        // `acceptWire` returned this Runtime's fresh, unclaimed session. A
        // release refusal before publication is an ownership invariant defect.
        errdefer self.runtime.releaseWire(hs) catch unreachable;
        const session = try self.allocator.create(Session);
        errdefer self.allocator.destroy(session);
        try self.runtime.claimSessionHandle(hs);
        self.shared.retain();
        session.* = .{
            .runtime = self.runtime,
            .hs = hs,
            .runtime_lease = .{ .retained = self.shared },
            .allocator = self.allocator,
            .deferred_release = .{
                .session = hs,
                .ctx = session,
                .complete = Session.completeDeferredRelease,
            },
        };
        return session;
    }

    /// Wait until `accept` would make progress, up to `timeout_ms`. The
    /// stop-friendly twin of blocking accept: poll, check a latch, then
    /// `accept`.
    pub fn waitAcceptable(self: *Server, timeout_ms: i32) !bool {
        try self.ensureOpen();
        return self.listener.waitAcceptable(timeout_ms);
    }

    /// Stop accepting and release the Server's runtime lease. Sessions already
    /// yielded by `accept` retain the runtime and remain usable until their own
    /// close/deinit barrier. No pending-work policy belongs here: listener
    /// close is admission-only.
    pub fn close(self: *Server) ?driver.OperationFailure {
        if (self.closed) return self.close_failure;
        self.closed = true;
        if (self.listener.close()) |failure| {
            self.close_failure = .fromChain(failure);
            self.runtime.noteTerminalOperationFailure(self.close_failure.?);
        }
        if (self.shared.releaseOutcome()) |failure| self.close_failure = failure;
        return self.close_failure;
    }

    /// Stop admission if needed, then release the owning Server handle.
    pub fn deinit(self: *Server) void {
        const allocator = self.allocator;
        if (!self.closed) {
            self.closed = true;
            if (self.listener.close()) |failure|
                self.runtime.noteTerminalOperationFailure(.fromChain(failure));
            _ = self.shared.releaseImplicit();
        }
        allocator.destroy(self);
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
) !*Server {
    // A transport with no pollable fd cannot back a multiplexed blocking wait;
    // refuse it by its own name rather than as an entropy failure.
    const io = netlayer.io() orelse return Error.TransportNotPollable;
    const shared = try allocator.create(SharedRuntime);
    errdefer allocator.destroy(shared);
    // The server's own transport is its immutable dial table: an accepted
    // session that receives a give naming a third peer redeems it there.
    try host_runtime.HostRuntime.initWithOwnNetlayer(
        &shared.runtime,
        allocator,
        io,
        netlayer,
        acceptToIdentity(identity),
        opts,
    );
    shared.allocator = allocator;
    shared.leases = 1;
    errdefer shared.runtime.deinit();

    var listen_config = config;
    listen_config.identity = switch (identity) {
        .ephemeral => null,
        .keyed => |secret| secret.publicKey(),
    };
    if (netlayer.designatorScheme() == .key and listen_config.identity == null)
        return Error.EphemeralIdentityOnKeyedTransport;
    var transport_listener = try shared.runtime.bindListener(
        netlayer.transportName(),
        listen_config.designator,
        listen_config.options,
    );
    var owns_transport_listener = true;
    errdefer if (owns_transport_listener) {
        if (shared.runtime.closeListener(&transport_listener)) |failure|
            shared.runtime.noteTerminalOperationFailure(failure);
    };
    var listener = shared.runtime.takeStreamListener(&transport_listener) orelse return Error.TransportNotPollable;
    owns_transport_listener = false;
    errdefer if (listener.close()) |failure|
        shared.runtime.noteTerminalOperationFailure(.fromChain(failure));

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
    try shared.runtime.core.setAdvertisedLocator(bound_locator);

    const server = try allocator.create(Server);
    server.* = .{
        .runtime = &shared.runtime,
        .shared = shared,
        .listener = listener,
        .allocator = allocator,
    };
    return server;
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
