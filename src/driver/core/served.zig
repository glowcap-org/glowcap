//! The sans-io session serve core (`Served`): an `actors.Port` over a borrowed
//! `engine.Peer`, the serve loop, and the byte-fed drive. Socket-free — the
//! `driver_core` layer's I/O ban keeps it that way. `BlockingSession` (in the
//! `driver` layer) composes one of these with a `net.Connection` for the
//! blocking socket path (ADR-0072).

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");
const actors = @import("actors");

const gc = @import("gc.zig");
const vocab = @import("vocab.zig");
const Error = vocab.Error;
const Exported = vocab.Exported;

/// A hook run before the vat serves each drained event. Return true to claim
/// the event and skip the vat's serve dispatch; a hook error propagates out of
/// the driver surface that drove the serve loop.
pub const BeforeServeHook = *const fn (ctx: ?*anyopaque, served: *Served, event: *engine.Event) anyerror!bool;

/// A drive polled an event and then could not serve it. The event is
/// already owned by (and deinitialized with) the drive, so retrying the drive
/// cannot replay it. The Host must condemn the session rather than treating
/// this as retryable allocator pressure. OOM after this boundary — local-turn
/// driving or outbound encoding — remains the ordinary retryable `OutOfMemory`.
pub const DriveError = error{EventServeOutOfMemory};

/// A loop driver's per-session setup callback: publish the objects this
/// fresh CapTP session serves (e.g. `try served.publish(vat, "name", App, .{})`). One
/// declaration shared by every loop host, so an application's publish function
/// is portable across transports.
pub const Publish = *const fn (ctx: ?*anyopaque, served: *Served, vat: *actors.Vat) anyerror!void;

/// Adapter options for a CapTP session's serve core. Stateless GC is driver
/// policy, not CapTP semantics added below the engine. Crossed-hellos is
/// host-tier serve policy: it runs in the host's `before_serve` hook, not
/// here, and its `CrossedHellos` table is sans-io and lockless by contract —
/// one thread drives one host (ADR-0072).
pub const ServeOptions = struct {
    /// Emit `op:gc-exports` / `op:gc-answers` after each inbound deliver/resolve
    /// the vat does not retain imports from.
    gc_stateless: bool = false,
    hook_ctx: ?*anyopaque = null,
    before_serve: ?BeforeServeHook = null,
};

/// The sans-io serve core: an `actors.Port` over one borrowed `engine.Peer`,
/// with the serve loop and the byte-fed drive. The peer is caller-owned (stable
/// address); this borrows it. It reads no
/// socket: a caller feeds inbound frames with `feedBorrowed` and drains outbound
/// with `takeOutbound`, owning its own loop (ADR-0072). `BlockingSession` composes
/// one of these with a `net.Connection` for the blocking socket path.
pub const Served = struct {
    port: actors.Port,
    serve_options: ServeOptions = .{},
    /// Local-turn amplification cap per drive, for fan-out embedders: a
    /// non-null budget makes `drainEvents` drive its post-batch turns through
    /// `drivePostBatch`, so one inbound message that amplifies past the budget
    /// surfaces `error.LocalTurnLimitExceeded` instead of stalling the loop
    /// that serves every other connection. Null (the default) drives
    /// unbounded, the blocking one-connection-per-thread posture.
    local_turn_budget: ?usize = null,
    /// Turns consumed in the current resumable local-work epoch. `null` means
    /// no local work is currently being resumed; a finite Host scheduler may
    /// yield between these turns, but it must not confuse that yield with a
    /// fresh batch or reset the per-session amplification cap.
    budgeted_local_turns: ?usize = null,
    /// The partner's most recent `op:abort`, retained so a close can name the
    /// partner's actual diagnostic instead of a generic "connection closed".
    /// Bounded and inline: the message is copied into a fixed buffer, so
    /// retaining it allocates nothing and borrows nothing from the event.
    last_abort: ?PartnerAbort = null,

    /// Bounded retention of the *partner's* inbound `op:abort`: the typed kind
    /// plus the first `message_buf.len` bytes of its diagnostic. Distinct from
    /// `engine.AbortInfo`, which records this node's *local* dispatch failure.
    pub const PartnerAbort = struct {
        kind: model.AbortKind,
        message_buf: [128]u8,
        message_len: usize,
    };

    /// Bind a sans-io serve core over `peer`. The caller owns the loop and
    /// sockets, feeds inbound frames with `feedBorrowed`, and drains outbound
    /// with `takeOutbound`; `deinit` frees only this Port. The caller owns the
    /// Vat passed to the drive methods. This is the driving mode the C ABI's
    /// `libpancake_host` and a browser ride.
    pub fn over(allocator: std.mem.Allocator, peer: *engine.Peer) Served {
        return .{ .port = actors.Port.init(allocator, peer) };
    }

    /// Tear down the Port, releasing its export-binding actor roots into
    /// `vat` (ADR-0101). Does not free the borrowed peer or shared Vat.
    pub fn deinit(self: *Served, vat: *actors.Vat) void {
        self.port.deinit(vat);
    }

    /// Borrowed view of the partner's retained `op:abort` (kind + message).
    /// The message slice points into this core's buffer.
    pub const PartnerAbortView = struct {
        kind: model.AbortKind,
        message: []const u8,
    };

    /// The partner's retained abort, or null when no `op:abort` arrived.
    pub fn partnerAbort(self: *const Served) ?PartnerAbortView {
        if (self.last_abort) |*info| return .{
            .kind = info.kind,
            .message = info.message_buf[0..info.message_len],
        };
        return null;
    }

    /// The partner's retained abort diagnostic, or null when no `op:abort`
    /// arrived. The slice points into this core's own buffer, so it stays valid
    /// as long as the core does.
    pub fn abortReason(self: *const Served) ?[]const u8 {
        if (self.partnerAbort()) |info| return info.message;
        return null;
    }

    /// Byte-fed inbound: apply one borrowed frame the caller pumped from its own
    /// transport, dispatch every event it surfaces into the vat, run the local
    /// turns it queues, then encode the resulting outbound so `takeOutbound`
    /// drains it. Zero-copy and caller-driven: the frame is borrowed for the call
    /// and nothing here reads a socket.
    pub fn feedBorrowed(self: *Served, vat: *actors.Vat, frame: foundation.FrameView) !void {
        try self.port.peer.recvBorrowed(frame);
        return self.driveFed(vat);
    }

    /// Byte-fed drive with no inbound frame: dispatch queued events, run local
    /// turns, and encode outbound. Call it to flush the handshake's first
    /// `op:start-session`, or after enqueuing a host-coordinated send, so
    /// `takeOutbound` has something to drain without a read.
    pub fn driveFed(self: *Served, vat: *actors.Vat) !void {
        try self.drainEvents(vat);
        try self.port.peer.stepToIdle();
    }

    /// One bounded Host continuation. It serves one queued event only when no
    /// local-work epoch is already being resumed, then drives one turn and
    /// encodes the work those operations produced. A `.more_pending` result is
    /// resumable: the Host puts this session at the dirty FIFO's tail, so
    /// siblings receive their own quantum before this session runs again.
    /// `local_turn_budget` is checked against the epoch carried here, never
    /// against the Host scheduler's unrelated quantum.
    pub fn driveFedBudgeted(self: *Served, vat: *actors.Vat) !actors.Vat.DriveProgress {
        if (self.budgeted_local_turns) |used| {
            if (self.local_turn_budget) |limit| {
                if (used >= limit) {
                    // A previous permitted turn may have committed and then
                    // failed while encoding its outbound. Preserve that turn's
                    // charge across the retry: finish encoding, but never run
                    // an extra turn before reporting the exhausted epoch.
                    const pending = try vat.driveIngressBudgeted(self.port.ingress, 0);
                    if (pending == .more_pending) {
                        try self.port.peer.stepToIdle();
                        return error.LocalTurnLimitExceeded;
                    }
                    self.budgeted_local_turns = null;
                }
            }
        }
        if (self.budgeted_local_turns == null) {
            if (self.port.peer.pollEvent()) |event_value| {
                self.budgeted_local_turns = 0;
                var event = event_value;
                defer event.deinit();
                self.serveEvent(vat, &event) catch |err| switch (err) {
                    // `pollEvent` transferred ownership above. There is no
                    // replay-safe queue operation after a serve hook or Port
                    // may have committed part of the event's effects.
                    error.OutOfMemory => return DriveError.EventServeOutOfMemory,
                    else => return err,
                };
            }
        }
        const event_pending = self.port.peer.hasEvent();
        // A zero local-turn budget is a probe, not an implicit one-turn
        // allowance. The Vat reports pending work without consuming it, so a
        // Host can condemn the session before any local turn runs.
        const turn_budget: usize = if (self.local_turn_budget) |limit| if (limit == 0) 0 else 1 else 1;
        const turn_progress = try vat.driveIngressBudgeted(self.port.ingress, turn_budget);
        if (turn_progress == .more_pending) {
            if (turn_budget == 0) {
                try self.port.peer.stepToIdle();
                return error.LocalTurnLimitExceeded;
            }
            const used = (self.budgeted_local_turns orelse 0) + 1;
            self.budgeted_local_turns = used;
            if (self.local_turn_budget) |limit| {
                if (used >= limit) {
                    // Encode the work already committed by the turn before
                    // the caller condemns the session. The caller then adds
                    // the terminal abort through the same outbound path.
                    try self.port.peer.stepToIdle();
                    return error.LocalTurnLimitExceeded;
                }
            }
        } else {
            self.budgeted_local_turns = null;
        }
        try self.port.peer.stepToIdle();
        return if (event_pending or turn_progress == .more_pending) .more_pending else .drained;
    }

    /// Drain one encoded outbound frame for the caller to write to its
    /// transport, or null when the outbound queue is empty. Owned: the caller
    /// frees the returned frame.
    pub fn takeOutbound(self: *Served) ?foundation.Frame {
        return self.port.peer.takeOutbound();
    }

    /// Whether an encoded outbound frame is queued — the cheap emptiness
    /// probe a pump reads before telling its embedder to flush.
    pub fn hasOutbound(self: *const Served) bool {
        return self.port.peer.hasOutbound();
    }

    /// Encoded outbound bytes waiting for the embedder to drain.
    pub fn queuedOutboundBytes(self: *const Served) usize {
        return self.port.peer.queuedOutboundBytes();
    }

    /// Serve one already-polled event: retain a partner abort, run the
    /// `before_serve` hook, dispatch into the vat unless the hook claimed it, then
    /// emit stateless GC. This is the one per-event serve spine — a socket `step`,
    /// a completion loop, and a byte-fed feed all serve through it, so they serve
    /// identically. The `before_serve` hook is the injection point for I/O-tier
    /// serve policy (node claim, crossed-hellos); it reaches what it needs through
    /// its `ctx`, keeping this sans-io. The caller owns the event's lifetime.
    pub fn serveEvent(self: *Served, vat: *actors.Vat, event: *engine.Event) !void {
        // Retain the partner's abort diagnostic (bounded, copied) before anything
        // else sees the event, so a later close can break the far vows with the
        // partner's own words.
        if (event.kind() == .abort) self.retainAbort(event);

        const skip_serve = if (self.serve_options.before_serve) |hook|
            try hook(self.serve_options.hook_ctx, self, event)
        else
            false;
        if (!skip_serve) _ = try self.port.serve(vat, event);

        if (self.serve_options.gc_stateless) gc.emitStatelessAfter(self.port.peer, event);
    }

    /// The loop drivers' post-batch policy in one spelling: drive one inbound
    /// batch's queued local turns within `budget` (a high-fan-out loop's
    /// per-connection amplification cap), and treat `.more_pending` as the
    /// runaway error a loop closes that one connection on — a single message
    /// that amplifies past its budget must not stall or grow in memory. The
    /// Both scale paths ride this through `Host` + `Bridge` (TCP `net.TcpLoop`,
    /// iroh `completion.Loop(iroh.Backend, iroh.DialResolver)`). The blocking one-connection-per-
    /// thread path drives unbounded through `drainEvents` instead.
    pub fn drivePostBatch(self: *Served, vat: *actors.Vat, budget: usize) !void {
        switch (try vat.driveIngressBudgeted(self.port.ingress, budget)) {
            .drained => {},
            .more_pending => return error.LocalTurnLimitExceeded,
        }
    }

    /// The blocking serve loop: serve every event the peer surfaced, then drive
    /// queued local turns to quiescence (or to `local_turn_budget`, when one is
    /// configured). Transport-free — a socket `step` and a byte-fed
    /// `feedBorrowed` both drive it, so they serve identically. A loop driver
    /// may instead call `serveEvent` per event and `drivePostBatch` with its
    /// budget directly, sharing the same per-event spine.
    pub fn drainEvents(self: *Served, vat: *actors.Vat) !void {
        while (self.port.peer.pollEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();
            self.serveEvent(vat, &event) catch |err| switch (err) {
                // `pollEvent` transferred ownership above. There is no
                // replay-safe queue operation after a serve hook or Port may
                // have committed part of the event's effects.
                error.OutOfMemory => return DriveError.EventServeOutOfMemory,
                else => return err,
            };
        }
        // Run any queued local turns so a local-target `send` settles through the
        // same drive that settles far sends. Nothing else calls `drive`, so a
        // queued local deliver would otherwise never fire its listener. A
        // configured `local_turn_budget` caps the drive (fan-out embedders);
        // null drives unbounded.
        try self.drivePostBatch(vat, self.local_turn_budget orelse std.math.maxInt(usize));
    }

    /// Copy an inbound `op:abort`'s kind and bounded message into `last_abort`.
    /// A message longer than the buffer is truncated; a malformed abort view is
    /// ignored, leaving any earlier retention in place.
    fn retainAbort(self: *Served, event: *const engine.Event) void {
        const body = event.view() catch return;
        const abort = switch (body) {
            .abort => |abort| abort,
            else => return,
        };
        var info = PartnerAbort{ .kind = abort.kind, .message_buf = undefined, .message_len = 0 };
        info.message_len = @min(abort.message.len, info.message_buf.len);
        @memcpy(info.message_buf[0..info.message_len], abort.message[0..info.message_len]);
        self.last_abort = info;
    }

    /// What a wire close breaks the far vows with: the partner's retained abort
    /// diagnostic when one arrived, else `fallback`.
    pub fn closeReason(self: *const Served, fallback: []const u8) []const u8 {
        return self.abortReason() orelse fallback;
    }

    /// Spawn a local actor at a fresh export position and return a capability
    /// to it (see `spawnAt`, the same operation in its turn-time form). The
    /// position is reserved here; the partner can address the capability only
    /// once it first marshals onto the wire, or after an explicit grant
    /// through `peer.exportObject` (ADR-0074).
    pub fn spawn(self: *Served, vat: *actors.Vat, comptime Behavior: type, initial: Behavior) !Exported {
        const position = try self.port.peer.exportNextObject();
        errdefer self.port.peer.session_state.releaseUnsharedExport(.from(position));
        const ref = try vat.spawn(Behavior, initial);
        errdefer vat.discardFreshActor(ref);
        try self.port.bindExport(vat, ref, position);
        return .{ .position = position, .ref = ref };
    }

    /// Publish an actor a partner can `fetch` by `name` (a swiss-number). Name
    /// first, matching every binding's `publish`. This is the
    /// `registerBootstrapCap`, spawn, and publish sequence; every driver
    /// surface publishes through its `Served`, so it is defined once here.
    /// Returns the capability at its allocated export position, carrying the
    /// vat-local `ref` so the publisher can keep talking to its own actor.
    pub fn publish(self: *Served, vat: *actors.Vat, name: []const u8, comptime Behavior: type, initial: Behavior) !Exported {
        const prior = self.port.peer.session_state.bootstrapLookup(name);
        const position = try self.port.peer.registerBootstrapCap(name);
        errdefer {
            self.port.peer.session_state.restoreBootstrapMapping(name, prior);
            self.port.peer.session_state.releaseUnsharedExport(.from(position));
        }
        const ref = try vat.spawn(Behavior, initial);
        errdefer vat.discardFreshActor(ref);
        try self.port.bindExport(vat, ref, position);
        // The export binding roots the actor; the spawn root transfers to it
        // (ADR-0101), so a session-published object lives exactly as long as
        // some relationship — this binding, a lift, a gift — holds it.
        vat.releaseActor(switch (ref) {
            .local => |id| id,
            .far => unreachable,
        });
        return .{ .position = position, .ref = ref };
    }

    /// Spawn an opaque hosted object (C trampoline / language binding) in the
    /// caller-supplied Vat. The Port does not own that actor graph.
    pub fn spawnHosted(self: *Served, vat: *actors.Vat, hosted: actors.HostedActor) !actors.Ref {
        _ = self;
        return vat.spawnHosted(hosted);
    }

    /// Unwind a hosted spawn whose following export bind failed.
    pub fn discardFreshActor(self: *Served, vat: *actors.Vat, actor: actors.Ref) void {
        _ = self;
        vat.discardFreshActor(actor);
    }

    /// Bind `actor` at `position` on this session's export table.
    pub fn bindExport(self: *Served, vat: *actors.Vat, actor: actors.Ref, position: u64) !void {
        try self.port.bindExport(vat, actor, position);
    }

    /// The local actor bound at `position`, or null when nothing is bound
    /// there: the read half of the seating surface above, so a consumer that
    /// seats through `Served` resolves through it too.
    pub fn refForExport(self: *const Served, position: u64) ?actors.Ref {
        return self.port.refForExport(position);
    }

    /// Enqueue the bootstrap `fetch` for `name` and return the promise of the
    /// partner's answer: import the well-known bootstrap export, then
    /// eventual-send `fetch(name)` to it. This is the one definition of the
    /// bootstrap-fetch deliver shape. `BlockingSession.fetch` drives the returned
    /// promise to settlement; the byte-fed `Host`'s fetch rides the same
    /// deliver with a host vow instead of a blocking wait.
    pub fn sendBootstrapFetch(self: *Served, vat: *actors.Vat, name: []const u8) !actors.Vow {
        try self.port.peer.importObject(engine.BOOTSTRAP_POSITION);
        errdefer self.port.peer.session_state.releaseImportRetain(.from(engine.BOOTSTRAP_POSITION));
        return self.port.send(
            vat,
            .{ .far = model.FarRef.object(engine.BOOTSTRAP_POSITION) },
            .{ .verb = "fetch", .args = &.{.{ .bytes = name }} },
        );
    }

    /// Ask the partner how `target` settles, returning a vow for that
    /// settlement (CapTP `op:listen`, ADR-0095). In 1.0, `target` may be a far
    /// promise or live far object; a live object answers immediately. In
    /// pancake-next, `target` must be a far promise because shortening and
    /// settling are promise-only. This is how an introducing session's proxy
    /// for a third party's promise (ADR-0009) is waited on: the notification
    /// comes back as a resolve on the vow's answer, so a give arriving in it is
    /// redeemed by the same path a call's reply takes.
    pub fn listenTo(self: *Served, target: model.Reference) !actors.Vow {
        return .{ .far = try engine.listen.listenOnFar(self.port.peer, target) };
    }

    /// Eventual-send `msg` to `target` (`<-`), returning a vow to observe with
    /// `on`. A far send goes on the wire; the next drive flushes it.
    pub fn send(self: *Served, vat: *actors.Vat, target: actors.Ref, msg: actors.Message) !actors.Vow {
        return self.port.send(vat, target, msg);
    }

    /// Promise pipelining: eventual-send `msg` to a far `vow` before it resolves
    /// (see `Vat.sendToAnswer`). A `.local` vow has no wire answer to pipeline
    /// against, so it is refused with `NotPipelineable`.
    pub fn sendToAnswer(self: *Served, vat: *actors.Vat, vow: actors.Vow, msg: actors.Message) !actors.Vow {
        return switch (vow) {
            .far => |answer_pos| self.port.sendToAnswer(vat, answer_pos, msg),
            .local => Error.NotPipelineable,
        };
    }

    /// Fire-and-forget eventual-send (`<-np`): enqueue a deliver with no answer.
    pub fn tell(self: *Served, vat: *actors.Vat, target: actors.Ref, msg: actors.Message) !void {
        return self.port.tell(vat, target, msg);
    }

    /// Register a one-shot listener on `vow`.
    pub fn on(self: *Served, vat: *actors.Vat, vow: actors.Vow, listener: actors.Listener) !void {
        return self.port.on(vat, vow, listener);
    }

    /// A cooperative fetch-then-deliver in flight, the caller-owned context
    /// `beginSendNamed` / `beginTellNamed` chain through. The caller keeps it
    /// alive and address-stable until the terminal listener fires (or the
    /// session tears down), then frees the owned message clone with `deinit`.
    /// `stage` says which leg an outcome came from: a break delivered while
    /// `stage == .fetching` is the fetch's own refusal (an unpublished name),
    /// so a UI can attribute it without parsing reasons.
    pub const PendingSend = struct {
        served: *Served,
        vat: *actors.Vat,
        /// Owns the verb and args clone from begin until `deinit`: the send
        /// happens later, inside the fetch vow's listener, after the caller's
        /// borrowed message may already be gone.
        msg_arena: std.heap.ArenaAllocator,
        verb: []const u8 = "",
        args: []const model.Argument = &.{},
        mode: Mode = .send,
        stage: Stage = .fetching,
        terminal: actors.Listener,

        pub const Mode = enum { send, tell };
        pub const Stage = enum { fetching, delivering };

        pub fn deinit(self: *PendingSend) void {
            self.msg_arena.deinit();
        }

        fn onFetch(ctx: ?*anyopaque, resolution: actors.Resolution) void {
            const self: *PendingSend = @ptrCast(@alignCast(ctx.?));
            const target: actors.Ref = switch (resolution) {
                .fulfilled => |value| switch (value) {
                    .reference => |reference| switch (reference) {
                        .far => |far| .{ .far = far },
                        else => return self.fireBroken("fetch did not resolve to a capability"),
                    },
                    else => return self.fireBroken("fetch did not resolve to a capability"),
                },
                // A fetch break forwards verbatim (a cancel or timeout arrives
                // here too); `stage` still reads `.fetching`, which is how the
                // caller attributes it. A bootstrap fetch never fulfills with
                // an introduction, so `.give` rides the same forward rather
                // than earning an arm it cannot reach.
                .broken, .give => return self.terminal.func(self.terminal.ctx, resolution),
            };
            self.stage = .delivering;
            const msg: actors.Message = .{ .verb = self.verb, .args = self.args };
            switch (self.mode) {
                .send => {
                    // Registering the terminal on the new vow inside this
                    // listener call is the vat's documented re-entrancy: the
                    // fire removed this entry first, and a disconnect's
                    // `breakFarVows` re-checks for registrations made during
                    // the break, so the chained vow can never strand.
                    const vow = self.served.send(self.vat, target, msg) catch |err| return self.fireBroken(@errorName(err));
                    self.served.on(self.vat, vow, self.terminal) catch |err| return self.fireBroken(@errorName(err));
                },
                .tell => {
                    self.served.tell(self.vat, target, msg) catch |err| return self.fireBroken(@errorName(err));
                    self.terminal.func(self.terminal.ctx, .{ .fulfilled = .{ .void = {} } });
                },
            }
        }

        fn fireBroken(self: *PendingSend, reason: []const u8) void {
            self.terminal.func(self.terminal.ctx, .{ .broken = reason });
        }
    };

    /// Begin a cooperative fetch-then-send: fetch the capability published as
    /// `name` and, when it fulfills, eventual-send `msg` to it, the terminal
    /// outcome (or the first break) firing `terminal` exactly once. No I/O is
    /// driven here; the caller pumps its loop until the listener fires. `msg`
    /// is borrowed only for this call — the verb and args are cloned into
    /// `pending`, which the caller keeps address-stable until the fire and
    /// then reclaims with `PendingSend.deinit`. This is the non-blocking
    /// spelling of the fetch-then-call an event-loop UI cannot express with
    /// the blocking `call`, so the chaining lives here once instead of as a
    /// shadow state machine in every embedder.
    pub fn beginSendNamed(self: *Served, vat: *actors.Vat, pending: *PendingSend, name: []const u8, msg: actors.Message, terminal: actors.Listener) !void {
        return self.beginDeliverNamed(vat, pending, name, msg, .send, terminal);
    }

    /// `beginSendNamed`'s fire-and-forget arm: fetch `name`, then `tell` it
    /// `msg`. The terminal fires `.fulfilled = .void` once the tell is queued
    /// (there is no answer to await), or the fetch's break.
    pub fn beginTellNamed(self: *Served, vat: *actors.Vat, pending: *PendingSend, name: []const u8, msg: actors.Message, terminal: actors.Listener) !void {
        return self.beginDeliverNamed(vat, pending, name, msg, .tell, terminal);
    }

    fn beginDeliverNamed(self: *Served, vat: *actors.Vat, pending: *PendingSend, name: []const u8, msg: actors.Message, mode: PendingSend.Mode, terminal: actors.Listener) !void {
        pending.* = .{
            .served = self,
            .vat = vat,
            .msg_arena = std.heap.ArenaAllocator.init(vat.allocator),
            .mode = mode,
            .terminal = terminal,
        };
        errdefer pending.msg_arena.deinit();
        const arena = pending.msg_arena.allocator();
        pending.verb = try arena.dupe(u8, msg.verb);
        pending.args = try model.cloneArgumentSlice(arena, msg.args);
        const vow = try self.sendBootstrapFetch(vat, name);
        try self.port.on(vat, vow, .{ .ctx = pending, .func = PendingSend.onFetch });
    }
};
