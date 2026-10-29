//! Owning Zig Session handle and one-call dial constructors.
//!
//! This is the application-facing client half of the blocking HostRuntime
//! facade. Session owns one claimed Host wire and, for one-call construction,
//! one lease on the heap-stable runtime beneath it. Promise values borrow that
//! Session authority. All blocking waits keep their listener stack alive until
//! the Host settles or breaks it.

const std = @import("std");

const model = @import("model");
const engine = @import("engine");
const actors = @import("actors");
const net = @import("net");
const driver_core = @import("driver_core");

const host_runtime = @import("../host_runtime.zig");

const driver = @import("../mod.zig");
const Settled = driver.Settled;
const Capability = driver.Capability;
const Value = driver.Value;
const Reply = driver.Reply;
const Error = driver.Error;
const connect_mod = @import("connect.zig");

/// An allocation-free eventual result scoped to the owning Session. Its core
/// vow row is pending work from creation until settlement, including when the
/// caller ignores the value. Use `Session.tell` for fire-and-forget delivery.
/// `settle` reads a reply that arrived while another verb pumped the session,
/// with its capabilities still held, so `release` a promise you will not
/// settle. `on` takes a listener only while the reply is pending, matching
/// `actors.Vow`'s one-shot listener contract.
pub const Promise = struct {
    owner: *Session,
    home: *driver_core.HostSession,
    id: u64,

    pub fn send(self: Promise, verb: ?[]const u8, args: []const Value) !Promise {
        return self.owner.sendToPromise(self, verb, args);
    }

    /// Fire-and-forget eventual-send to this promise's answer. No result vow
    /// or answer position is allocated.
    pub fn tell(self: Promise, verb: ?[]const u8, args: []const Value) !void {
        return self.owner.tellToPromise(self, verb, args);
    }

    pub fn settle(self: Promise, arena: std.mem.Allocator) !Reply {
        return self.owner.settlePromise(self, arena);
    }

    pub fn on(self: Promise, listener: actors.Listener) !void {
        return self.owner.observePromise(self, listener);
    }

    /// This promise as a capability to pass in a send or tell (ADR-0068). On
    /// its own session it travels as the answer reference, and on another
    /// session as a local promise the Host settles when this one does. The
    /// capability carries its own retain, so `Session.release` it once the
    /// send has it.
    pub fn capability(self: Promise) !Capability {
        return self.owner.promiseCapability(self);
    }

    /// Release an unobserved promise handle and its remote answer. Copies of
    /// this value are invalid after release. Repeated release is harmless.
    pub fn release(self: Promise) !void {
        return self.owner.releasePromise(self);
    }
};

/// Options for `connect` and `listen` (see `driver.HostRuntime.Options`, the owning
/// face these views ride).
pub const SessionOptions = host_runtime.HostRuntime.Options;
const SharedRuntime = @import("shared_runtime.zig").SharedRuntime;

/// An application-facing session, the object a Zig application holds:
/// an owning handle for one session of a `driver.HostRuntime`. `connect` and
/// `Server.accept` retain their heap-stable runtime. `adopt` transfers one
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
    zig_release_complete: bool = false,
    /// Turn scratch for lowering one verb's argument spine into the core, which
    /// dupes anything session-lived onto its own allocator before the verb
    /// returns. Reset at each verb's entry rather than freed at its exit, so a
    /// steady stream of calls pays no allocation after the first. A Session is
    /// a per-partner application handle, not the 500k-tier `Peer`, so the
    /// arena header here is not a footprint-budget withdrawal.
    verb_scratch: std.heap.ArenaAllocator,

    /// Backing the verb scratch keeps across resets.
    const steady_verb_scratch_bytes = 4096;

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
    /// handle. The caller must not also call `releaseWire` for `hs`.
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
            .verb_scratch = std.heap.ArenaAllocator.init(runtime.allocator),
            .deferred_release = .{
                .session = hs,
                .ctx = session,
                .complete = completeDeferredRelease,
            },
        };
        return session;
    }

    /// Transfer one freshly accepted or dialed wire and one SharedRuntime lease
    /// into a Session. This handle keeps the runtime alive independently of the
    /// constructor or server that created it.
    pub fn adoptRetained(
        runtime: *host_runtime.HostRuntime,
        hs: *driver_core.HostSession,
        shared: *SharedRuntime,
        allocator: std.mem.Allocator,
    ) Error!*Session {
        const session = try allocator.create(Session);
        errdefer allocator.destroy(session);
        try runtime.claimSessionHandle(hs);
        shared.retain();
        session.* = .{
            .runtime = runtime,
            .hs = hs,
            .runtime_lease = .{ .retained = shared },
            .allocator = allocator,
            .verb_scratch = std.heap.ArenaAllocator.init(allocator),
            .deferred_release = .{
                .session = hs,
                .ctx = session,
                .complete = completeDeferredRelease,
            },
        };
        return session;
    }

    fn enterCall(self: *Session) void {
        std.debug.assert(!self.zig_release_complete);
        self.active_calls += 1;
        self.runtime.enterDriver();
    }

    fn leaveCall(self: *Session) void {
        self.runtime.leaveDriver();
        std.debug.assert(self.active_calls != 0);
        self.active_calls -= 1;
        if (self.active_calls == 0 and self.zig_release_complete) _ = self.completeRelease();
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
                // embedding process or freeing live Zig authority.
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
            // release refusal leaves the Zig wire live, so retain the
            // failure and pin this wrapper rather than pretending teardown
            // committed or turning a library error into process death.
            self.runtime.noteTerminalFailure(err);
            return;
        };
        self.zig_release_complete = true;
    }

    fn completeDeferredRelease(ctx: *anyopaque) bool {
        const self: *Session = @ptrCast(@alignCast(ctx));
        if (self.active_calls != 0) {
            self.zig_release_complete = true;
            return false;
        }
        return self.completeRelease();
    }

    fn completeRelease(self: *Session) bool {
        const allocator = self.allocator;
        const lease = self.runtime_lease;
        self.verb_scratch.deinit();
        allocator.destroy(self);
        return switch (lease) {
            .borrowed => false,
            .retained => |shared| shared.releaseDeferred(),
        };
    }

    /// The verb scratch, reset for a fresh verb. Inside a Host callback the
    /// reset is skipped: an outer verb's spine may still be live in it, and
    /// the next verb entered outside any callback resets for both.
    fn scratch(self: *Session) std.mem.Allocator {
        if (!self.runtime.withinCallback())
            _ = self.verb_scratch.reset(.{ .retain_with_limit = steady_verb_scratch_bytes });
        return self.verb_scratch.allocator();
    }

    /// Close this session under one monotonic pending-work policy. Repeated
    /// calls observe the same barrier. Cancel may escalate an in-progress
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

    /// The close outcome with the session's phase and, once the wire has
    /// ended, why it ended (see `HostRuntime.SessionCloseStatus`).
    pub fn closeStatus(self: *const Session) !driver.HostRuntime.SessionCloseStatus {
        self.runtime.enterDriver();
        defer self.runtime.leaveDriver();
        return self.runtime.sessionCloseStatus(self.hs);
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
    /// Args are owning-tier `Value`s. The pending machinery owns its own clone
    /// of the lowered message, so the caller's slices are borrowed for this
    /// call only.
    pub fn beginSendNamed(self: *Session, pending: *driver.PendingSend, name: []const u8, verb: ?[]const u8, args: []const Value, terminal: actors.Listener) !void {
        self.enterCall();
        defer self.leaveCall();
        try self.runtime.core.beginSendNamedValues(self.hs, pending, name, verb, args, self.scratch(), terminal);
    }

    /// Chain fetch-then-tell without blocking (see `Served.beginTellNamed`).
    pub fn beginTellNamed(self: *Session, pending: *driver.PendingSend, name: []const u8, verb: ?[]const u8, args: []const Value, terminal: actors.Listener) !void {
        self.enterCall();
        defer self.leaveCall();
        try self.runtime.core.beginTellNamedValues(self.hs, pending, name, verb, args, self.scratch(), terminal);
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
    /// with a key yet. `HostError.PartnerUnverified` means this session does not status-allow: pending state or quoted runtime label
    /// verify its partner, so there is no proved identity to report.
    pub fn partnerIdentity(self: *Session) !driver_core.PartnerIdentity {
        self.enterCall();
        defer self.leaveCall();
        return self.runtime.core.partnerIdentity(self.hs);
    }

    /// Fetch a partner's published capability by `name`, returning its opaque
    /// Host `Capability` (ADR-0026). The fulfilled reference is lifted while
    /// its owning session is known, so handing it back to the partner, or to
    /// a third party, routes to the right exporter without the application
    /// ever holding a wire position. An unpublished name returns
    /// `Error.FetchBroken`. Any other fulfill returns
    /// `Error.FetchNotACapability`.
    pub fn fetch(self: *Session, name: []const u8) !Capability {
        self.enterCall();
        defer self.leaveCall();
        var capture = driver.FetchCapture{};
        const id = try self.runtime.core.fetch(self.hs, name);
        try self.awaitVowId(id, .{ .ctx = &capture, .func = driver.FetchCapture.record });
        return switch (capture.outcome orelse return Error.ConnectionClosed) {
            .capability => |captured| self.runtime.core.liftCapability(self.hs, captured.reference()),
            .broken => Error.FetchBroken,
            .not_a_capability => Error.FetchNotACapability,
        };
    }

    /// The reason-bearing fetch: the partner's settlement whole, lifted and
    /// materialized into `arena` (reset the arena to reclaim it).
    pub fn fetchSettled(self: *Session, name: []const u8, arena: std.mem.Allocator) !Reply {
        self.enterCall();
        defer self.leaveCall();
        return self.replyVowId(self.hs, try self.runtime.core.fetch(self.hs, name), arena);
    }

    /// Eventual-send to `target` and block until the reply settles,
    /// materializing both `Reply` arms into caller-owned `arena`. The node
    /// routes the capability to its exporter session, so a redeemed or
    /// re-gifted capability is called the same way a directly fetched one is.
    /// An argument foreign to the routed session is refused whole
    /// (`ForeignArgument`). A partner that leaves before the reply settles
    /// breaks it with the wire's close reason.
    pub fn call(self: *Session, target: Capability, verb: ?[]const u8, args: []const Value, arena: std.mem.Allocator) !Reply {
        self.enterCall();
        defer self.leaveCall();
        const promise = try self.queueSend(target, verb, args);
        return self.replyVowId(promise.home, promise.id, arena);
    }

    /// Eventual-send to `target`, returning its Promise without blocking.
    /// Args are borrowed
    /// for this call: the actor layer owns its clone before this returns.
    pub fn send(self: *Session, target: Capability, verb: ?[]const u8, args: []const Value) !Promise {
        self.enterCall();
        defer self.leaveCall();
        return self.queueSend(target, verb, args);
    }

    /// Lower one owning-tier delivery and commit it through the Host's routing,
    /// vow, and pending-work authority without driving local settlement.
    fn queueSend(self: *Session, target: Capability, verb: ?[]const u8, args: []const Value) !Promise {
        const id = try self.runtime.core.queueSendValues(self.hs, target, verb, args, self.scratch());
        return .{ .owner = self, .home = try self.runtime.core.vowSession(id), .id = id };
    }

    /// Listen on the promise `target` names, returning a Promise for its
    /// settlement (see `Served.listenTo`). A promise this partner handed us
    /// settles through a notification it delivers, so this is how a received
    /// promise capability is waited on. `listenSettled` is the blocking form.
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

    fn sendToPromise(self: *Session, promise: Promise, verb: ?[]const u8, args: []const Value) !Promise {
        self.enterCall();
        defer self.leaveCall();
        const id = try self.runtime.core.queueVowSendValues(promise.id, verb, args, self.scratch());
        return .{ .owner = self, .home = promise.home, .id = id };
    }

    fn tellToPromise(self: *Session, promise: Promise, verb: ?[]const u8, args: []const Value) !void {
        self.enterCall();
        defer self.leaveCall();
        try self.runtime.core.vowTellValues(promise.id, verb, args, self.scratch());
    }

    fn releasePromise(self: *Session, promise: Promise) !void {
        self.enterCall();
        defer self.leaveCall();
        try self.runtime.core.vowRelease(promise.id);
    }

    fn promiseCapability(self: *Session, promise: Promise) !Capability {
        self.enterCall();
        defer self.leaveCall();
        return self.runtime.core.vowCapability(promise.id);
    }

    fn settlePromise(self: *Session, promise: Promise, arena: std.mem.Allocator) !Reply {
        self.enterCall();
        defer self.leaveCall();
        return self.replyVowId(promise.home, promise.id, arena);
    }

    /// The blocking settle every `Reply`-returning verb shares. A reply that
    /// arrived while another verb pumped is held on the vow row and read
    /// from there.
    fn replyVowId(self: *Session, hs: *driver_core.HostSession, id: u64, arena: std.mem.Allocator) !Reply {
        switch (try self.runtime.core.vowTakeHeld(id, arena)) {
            .taken => |held| return held,
            .pending => {},
            // The drain that carried the reply stopped at outbound pressure,
            // so the row holds it after this one.
            .queued => {
                try self.runtime.drainActions();
                switch (try self.runtime.core.vowTakeHeld(id, arena)) {
                    .taken => |held| return held,
                    .pending, .queued => return error.AlreadySettled,
                }
            },
        }
        var capture = driver.SettleCapture{ .arena = arena };
        try self.awaitVowIdOn(hs, id, .{ .ctx = &capture, .func = driver.SettleCapture.fire });
        return self.replyFromSettled(hs, arena, try capture.finish());
    }

    /// Lift an already-captured wire settlement on this session into a
    /// `Reply` (the REPL's cooperative queue captures first and renders
    /// later. Ordinary blocking verbs never need this).
    pub fn liftSettled(self: *Session, settled: Settled, arena: std.mem.Allocator) !Reply {
        self.enterCall();
        defer self.leaveCall();
        return self.replyFromSettled(self.hs, arena, settled);
    }

    fn replyFromSettled(self: *Session, hs: *driver_core.HostSession, arena: std.mem.Allocator, settled: Settled) !Reply {
        return switch (settled) {
            .fulfilled => |arg| .{ .fulfilled = try self.runtime.core.liftValue(hs, arena, arg) },
            .broken => |reason| .{ .broken = reason },
            // `Session` redeems a give inside the wait it settles under;
            // one that still surfaces is a broken introduction, not a value.
            .give => .{ .broken = "unredeemed handoff give" },
        };
    }

    /// Register `listener` on host vow `id` behind a settle flag and block
    /// until it fires. The flag lives on this frame for the wait, so the
    /// listener's ctx outlives every fire. No pre-pump flush: `core.fetch` and the vow verbs
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
    /// alive. A later break firing it into a dead frame is the memory bug,
    /// not the timeout.
    fn pumpWait(self: *Session, hs: *driver_core.HostSession, flag: *const bool) !void {
        self.attendAndPump(hs, flag) catch |err| {
            hs.served.port.breakFarVows(hs.served.closeReason("wait failed"));
            return err;
        };
    }

    fn attendAndPump(self: *Session, hs: *driver_core.HostSession, flag: *const bool) !void {
        try self.runtime.attendSession(self.hs);
        if (hs != self.hs) try self.runtime.attendSession(hs);
        try self.runtime.pumpUntilFlag(hs, flag, self.runtime.opts.settle);
    }

    /// Fire-and-forget eventual-send (see `Served.tell`), routed exactly as
    /// `call` routes.
    pub fn tell(self: *Session, target: Capability, verb: ?[]const u8, args: []const Value) !void {
        self.enterCall();
        defer self.leaveCall();
        try self.runtime.core.tellValues(self.hs, target, verb, args, self.scratch());
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
        return self.runtime.core.sessionPublish(self.hs, name, driver_core.Hosting(Behavior), .{ .inner = initial });
    }

    /// Return the Host capability published under `name` on this session, or
    /// null when no session-local or Host-wide publication has that name.
    pub fn publishedCapability(self: *Session, name: []const u8) !?Capability {
        self.enterCall();
        defer self.leaveCall();
        return self.runtime.core.publishedCapability(self.hs, name);
    }

    /// Enliven a complete sturdyref by Host-level select-or-dial (ADR-0007
    /// step 4): the host resolves the sturdyref's peer to the live dialed
    /// session it names, or dials it, so the caller never picks the session.
    /// The peer named in the sturdyref does. The settled capability arrives
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
        const sturdy = try model.uri.parseSturdyref(self.allocator, uri_str);
        defer model.uri.freeSturdyref(self.allocator, sturdy);
        return self.enliven(sturdy);
    }

    /// Release one application retain on `cap`. The final release retires the
    /// opaque identity (a later use fails closed) and, for a remote
    /// capability, queues its exact wire GC release.
    pub fn release(self: *Session, cap: Capability) !void {
        self.enterCall();
        defer self.leaveCall();
        try self.runtime.core.releaseCapability(cap, 1);
    }

    /// Finish this Session's root setup and enable inbound delivery by sibling
    /// or aggregate runtime pumps. Parked resident input may invoke behavior
    /// synchronously here. Step, serve and blocking reply waits attend implicitly.
    pub fn attend(self: *Session) !void {
        try self.runtime.refuseReentry();
        self.enterCall();
        defer self.leaveCall();
        try self.runtime.attendSession(self.hs);
    }

    /// One blocking pump cycle across the host: drain actions, wait for any
    /// live session's readable progress, feed it. Returns this session's
    /// `Progress` so a caller's loop can act on `.closed`.
    pub fn step(self: *Session) !net.Progress {
        self.enterCall();
        defer self.leaveCall();
        try self.runtime.attendSession(self.hs);
        return (try self.runtime.stepSession(self.hs, -1)) orelse .idle;
    }

    /// Poll-guarded `step`: wait up to `timeout_ms` for readable progress, or
    /// null on timeout. The multiplexing convenience over `step`.
    pub fn stepReadable(self: *Session, timeout_ms: i32) !?net.Progress {
        self.enterCall();
        defer self.leaveCall();
        try self.runtime.attendSession(self.hs);
        return self.runtime.stepSession(self.hs, timeout_ms);
    }

    /// Serve this session until the partner leaves: run `step` until it
    /// reports `.closed`. Far vows break with the close reason inside the
    /// pump's release.
    pub fn serve(self: *Session) !void {
        self.enterCall();
        defer self.leaveCall();
        try self.runtime.attendSession(self.hs);
        while (true) {
            const progress = (try self.runtime.stepSession(self.hs, -1)) orelse continue;
            if (progress == .closed) return;
        }
    }

    /// The raw engine peer under this session, the explicit-ownership escape
    /// for a consumer that outgrows the surface.
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

pub const connect = connect_mod.connect;
pub const connectUri = connect_mod.connectUri;
