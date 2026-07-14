//! The sans-io vat serve core (`Served`): an `actors.Vat` over a borrowed
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
const Capability = vocab.Capability;

/// A hook run before the vat serves each drained event. Return true to claim
/// the event and skip the vat's serve dispatch; a hook error propagates out of
/// the driver surface that drove the serve loop.
pub const BeforeServeHook = *const fn (ctx: ?*anyopaque, served: *Served, event: *engine.Event) anyerror!bool;

/// A loop driver's per-session setup callback: publish the objects this
/// fresh CapTP session serves (e.g. `try served.publish("name", App, .{})`). One
/// declaration shared by every loop host, so an application's publish function
/// is portable across transports.
pub const Publish = *const fn (ctx: ?*anyopaque, served: *Served) anyerror!void;

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

/// The sans-io serve core: an `actors.Vat` over one borrowed `engine.Peer`,
/// with the serve loop and the byte-fed drive. The peer is caller-owned (stable
/// address); this borrows it, exactly as `actors.Vat.initOver` does. It reads no
/// socket: a caller feeds inbound frames with `feedBorrowed` and drains outbound
/// with `takeOutbound`, owning its own loop (ADR-0072). `BlockingSession` composes
/// one of these with a `net.Connection` for the blocking socket path.
pub const Served = struct {
    vat: actors.Vat,
    peer: *engine.Peer,
    serve_options: ServeOptions = .{},
    /// Local-turn amplification cap per drive, for fan-out embedders: a
    /// non-null budget makes `drainEvents` drive its post-batch turns through
    /// `drivePostBatch`, so one inbound message that amplifies past the budget
    /// surfaces `error.LocalTurnLimitExceeded` instead of stalling the loop
    /// that serves every other connection. Null (the default) drives
    /// unbounded, the blocking one-connection-per-thread posture.
    local_turn_budget: ?usize = null,
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
    /// with `takeOutbound`; `deinit` frees the vat only. This is the driving mode
    /// the C ABI's `libpancake_driver` and a browser ride.
    pub fn over(allocator: std.mem.Allocator, peer: *engine.Peer) Served {
        return .{ .vat = actors.Vat.initOver(allocator, peer), .peer = peer };
    }

    /// Tear down the vat. Does not free the borrowed peer.
    pub fn deinit(self: *Served) void {
        self.vat.deinit();
    }

    /// The partner's retained abort diagnostic, or null when no `op:abort`
    /// arrived. The slice points into this core's own buffer, so it stays valid
    /// as long as the core does.
    pub fn abortReason(self: *const Served) ?[]const u8 {
        if (self.last_abort) |*info| return info.message_buf[0..info.message_len];
        return null;
    }

    /// Byte-fed inbound: apply one borrowed frame the caller pumped from its own
    /// transport, dispatch every event it surfaces into the vat, run the local
    /// turns it queues, then encode the resulting outbound so `takeOutbound`
    /// drains it. Zero-copy and caller-driven: the frame is borrowed for the call
    /// and nothing here reads a socket.
    pub fn feedBorrowed(self: *Served, frame: foundation.FrameView) !void {
        try self.peer.recvBorrowed(frame);
        return self.driveFed();
    }

    /// Byte-fed drive with no inbound frame: dispatch queued events, run local
    /// turns, and encode outbound. Call it to flush the handshake's first
    /// `op:start-session`, or after enqueuing a host-coordinated send, so
    /// `takeOutbound` has something to drain without a read.
    pub fn driveFed(self: *Served) !void {
        try self.drainEvents();
        try self.peer.stepToIdle();
    }

    /// Drain one encoded outbound frame for the caller to write to its
    /// transport, or null when the outbound queue is empty. Owned: the caller
    /// frees the returned frame.
    pub fn takeOutbound(self: *Served) ?foundation.Frame {
        return self.peer.takeOutbound();
    }

    /// Whether an encoded outbound frame is queued — the cheap emptiness
    /// probe a pump reads before telling its embedder to flush.
    pub fn hasOutbound(self: *const Served) bool {
        return self.peer.hasOutbound();
    }

    /// Serve one already-polled event: retain a partner abort, run the
    /// `before_serve` hook, dispatch into the vat unless the hook claimed it, then
    /// emit stateless GC. This is the one per-event serve spine — a socket `step`,
    /// a completion loop, and a byte-fed feed all serve through it, so they serve
    /// identically. The `before_serve` hook is the injection point for I/O-tier
    /// serve policy (node claim, crossed-hellos); it reaches what it needs through
    /// its `ctx`, keeping this sans-io. The caller owns the event's lifetime.
    pub fn serveEvent(self: *Served, event: *engine.Event) !void {
        // Retain the partner's abort diagnostic (bounded, copied) before anything
        // else sees the event, so a later close can break the far vows with the
        // partner's own words.
        if (event.kind() == .abort) self.retainAbort(event);

        const skip_serve = if (self.serve_options.before_serve) |hook|
            try hook(self.serve_options.hook_ctx, self, event)
        else
            false;
        if (!skip_serve) _ = try self.vat.serve(event);

        if (self.serve_options.gc_stateless) gc.emitStatelessAfter(self.peer, event);
    }

    /// The loop drivers' post-batch policy in one spelling: drive one inbound
    /// batch's queued local turns within `budget` (a high-fan-out loop's
    /// per-connection amplification cap), and treat `.more_pending` as the
    /// runaway error a loop closes that one connection on — a single message
    /// that amplifies past its budget must not stall or grow in memory. The
    /// Both scale paths ride this through `Host` + `Bridge` (TCP `net.TcpLoop`,
    /// iroh `completion.Loop(iroh.Backend, iroh.DialResolver)`). The blocking one-connection-per-
    /// thread path drives unbounded through `drainEvents` instead.
    pub fn drivePostBatch(self: *Served, budget: usize) !void {
        switch (try self.vat.driveBudgeted(budget)) {
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
    pub fn drainEvents(self: *Served) !void {
        while (self.peer.pollEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();
            try self.serveEvent(&event);
        }
        // Run any queued local turns so a local-target `send` settles through the
        // same drive that settles far sends. Nothing else calls `drive`, so a
        // queued local deliver would otherwise never fire its listener. A
        // configured `local_turn_budget` caps the drive (fan-out embedders);
        // null drives unbounded.
        if (self.local_turn_budget) |budget|
            try self.drivePostBatch(budget)
        else
            try self.vat.drive();
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
    pub fn spawn(self: *Served, comptime Behavior: type, initial: Behavior) !Capability {
        return vocab.spawnAt(&self.vat, Behavior, initial);
    }

    /// Publish an actor a partner can `fetch` by `name` (a swiss-number). Name
    /// first, matching every binding's `publish`. This is the
    /// `registerBootstrapCap`, spawn, and publish sequence; every driver
    /// surface publishes through its `Served`, so it is defined once here.
    /// Returns the capability at its allocated export position, carrying the
    /// vat-local `ref` so the publisher can keep talking to its own actor.
    pub fn publish(self: *Served, name: []const u8, comptime Behavior: type, initial: Behavior) !Capability {
        const position = try self.peer.registerBootstrapCap(name);
        const ref = try self.vat.spawn(Behavior, initial);
        try self.vat.bindExport(ref, position);
        return .{ .position = position, .ref = ref };
    }

    /// Spawn an opaque hosted object (C trampoline / language binding) on this
    /// connection's vat. The one Served verb the C ABI uses instead of reaching
    /// through `&conn.served.vat` (ADR-0071).
    pub fn spawnHosted(self: *Served, hosted: actors.HostedActor) !actors.Ref {
        return self.vat.spawnHosted(hosted);
    }

    /// Bind `actor` at `position` on this session's export table.
    pub fn bindExport(self: *Served, actor: actors.Ref, position: u64) !void {
        try self.vat.bindExport(actor, position);
    }

    /// The local actor bound at `position`, or null when nothing is bound
    /// there: the read half of the seating surface above, so a consumer that
    /// seats through `Served` resolves through it too.
    pub fn refForExport(self: *const Served, position: u64) ?actors.Ref {
        return self.vat.refForExport(position);
    }

    /// Enqueue the bootstrap `fetch` for `name` and return the promise of the
    /// partner's answer: import the well-known bootstrap export, then
    /// eventual-send `fetch(name)` to it. This is the one definition of the
    /// bootstrap-fetch deliver shape. `BlockingSession.fetch` drives the returned
    /// promise to settlement; the byte-fed `Host`'s fetch rides the same
    /// deliver with a host vow instead of a blocking wait.
    pub fn sendBootstrapFetch(self: *Served, name: []const u8) !actors.Vow {
        try self.peer.importObject(engine.BOOTSTRAP_POSITION);
        return self.vat.send(
            .{ .far = model.FarRef.object(engine.BOOTSTRAP_POSITION) },
            .{ .verb = "fetch", .args = &.{.{ .bytes = name }} },
        );
    }

    /// Eventual-send `msg` to `target` (`<-`), returning a vow to observe with
    /// `on`. A far send goes on the wire; the next drive flushes it.
    pub fn send(self: *Served, target: actors.Ref, msg: actors.Message) !actors.Vow {
        return self.vat.send(target, msg);
    }

    /// Promise pipelining: eventual-send `msg` to a far `vow` before it resolves
    /// (see `Vat.sendToAnswer`). A `.local` vow has no wire answer to pipeline
    /// against, so it is refused with `NotPipelineable`.
    pub fn sendToAnswer(self: *Served, vow: actors.Vow, msg: actors.Message) !actors.Vow {
        return switch (vow) {
            .far => |answer_pos| self.vat.sendToAnswer(answer_pos, msg),
            .local => Error.NotPipelineable,
        };
    }

    /// Fire-and-forget eventual-send (`<-np`): enqueue a deliver with no answer.
    pub fn tell(self: *Served, target: actors.Ref, msg: actors.Message) !void {
        return self.vat.tell(target, msg);
    }

    /// Register a one-shot listener on `vow`.
    pub fn on(self: *Served, vow: actors.Vow, listener: actors.Listener) !void {
        return self.vat.on(vow, listener);
    }
};
