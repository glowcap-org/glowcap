//! A connection-bound vat driver: the application surface for native Zig.
//!
//! `actors.Vat` is a sync, no-I/O turn loop. `net_adapter` is where I/O lives.
//! A networked Zig app normally has to open a socket, bind a vat to the peer, pump
//! the connection, and dispatch each surfaced event into the vat. `ConnectedVat`
//! is that composition. It owns no protocol the engine lacks, and it hides no
//! allocation or I/O. Every read and write is one explicit `step`. A host that
//! wants to answer until the partner leaves can call `serve`. Either way, the
//! caller owns the allocator, the buffers, and the peer's lifetime. This layer is
//! above both `actors` and `net_adapter`, so it is the one place that may touch
//! `std.Io` and the actor turn loop at the same time. It is not part of the
//! no-I/O core.
//!
//! The driver reaches a transport two ways. `connectTcp` and `acceptTcp` are
//! the tcp-named conveniences that pick tcp explicitly. `connectVia` and
//! `acceptVia` take a `net_adapter.NetlayerRegistry` and dispatch on the
//! locator's transport symbol at runtime. A transport the driver never names can
//! dial and host through the same code once it is registered. There is no
//! `TcpVat`, and `ConnectedVat` itself is transport-neutral: a caller that already
//! holds a `net_adapter.Connection` over any stream uses `ConnectedVat.over`
//! directly.
//!
//! This file owns the blocking, one-connection-per-thread surface and the
//! vocabulary every driver embedding shares. `ConnectedVat` and its
//! constructors are the caller-pumped half; `Connection`, `connect`, and
//! `listen` are the one-call client and host over the same path, matching the
//! bindings' surface. The shared verbs — `publishNamed`, `spawnAt`,
//! `sendBootstrapFetch`, and the `drawSessionSecret` entropy boundary — live
//! here once. The completion-loop fan-out drivers, `LoopHost` and
//! `LoopDialer`, live in `loop.zig` and are re-exported here, so every driver
//! surface is reached through this one root.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");
const actors = @import("actors");
const net_adapter = @import("net_adapter");

pub const crossed_hellos = @import("crossed_hellos.zig");
pub const gc = @import("gc.zig");

const loop = @import("loop.zig");
/// The completion-loop hosting fan-out (see `loop.zig`), re-exported so callers
/// keep reaching it as `driver.LoopHost`.
pub const LoopHost = loop.LoopHost;
/// The completion-loop client fan-out (see `loop.zig`), re-exported so callers
/// keep reaching it as `driver.LoopDialer`.
pub const LoopDialer = loop.LoopDialer;

const crypto = foundation.crypto;

pub const Error = error{
    /// A `fetch` ran to a clean connection close before the capability resolved.
    ConnectionClosed,
    /// A `fetch` settled broken: the partner answered the bootstrap fetch with a
    /// break (an unpublished name, a refused handoff). The break reason is
    /// turn-borrowed and not retained here; a caller that needs it uses
    /// `ConnectedVat.fetchSettled`, which returns the reason in caller-owned
    /// memory.
    FetchBroken,
    /// A `fetch` fulfilled with something other than a far capability, so there
    /// is no reference to return.
    FetchNotACapability,
    /// The OS entropy source could not fill the session seed for the handshake.
    HandshakeEntropyFailed,
    /// A shared driver verb (`publishNamed`, `spawnAt`, `sendBootstrapFetch`)
    /// was given a vat with no bound peer; only a peer-bound vat can export or
    /// fetch over the wire.
    NotConnected,
    /// A locator named a transport no registered netlayer hosts.
    UnknownTransport,
};

/// Draw a fresh random session secret from `io` at the I/O boundary, never in the
/// no-I/O core. The raw seed is wiped off the stack after `fromSeed` consumes it,
/// so the ephemeral secret does not linger. The `ConnectedVat` handshake halves
/// and the loop drivers' identity keys (`LoopHost`, `LoopDialer`) use this one
/// entropy boundary.
pub fn drawSessionSecret(io: std.Io) Error!crypto.SecretKey {
    var seed: [crypto.SEED_BYTES]u8 = undefined;
    defer std.crypto.secureZero(u8, &seed);
    io.randomSecure(&seed) catch return Error.HandshakeEntropyFailed;
    return crypto.SecretKey.fromSeed(seed);
}

/// A capability to a local actor this vat hosts. Pass it to a partner as a
/// `send` argument, and use it locally too: `ref` is the vat-local reference,
/// so the application can near-call or `send` to the actor it just published
/// or spawned without redoing vat bookkeeping. `nearRef()` returns the
/// explicit wire reference the export position marshals to, so the Zig
/// surface keeps that conversion visible rather than implicit.
pub const Capability = struct {
    /// The export position the session allocated for this actor.
    position: u64,
    /// The vat-local reference to the same actor, for local sends and calls.
    ref: actors.Ref,

    /// The explicit wire reference this capability marshals to: a near object
    /// at `position`.
    pub fn nearRef(self: Capability) model.Reference {
        return .{ .near = model.NearRef.object(self.position) };
    }

    /// The capability as a ready-to-send argument, so handing a partner a
    /// callback reads `.args = &.{ cap.arg() }`. This is `nearRef` wrapped in
    /// the `.reference` argument arm.
    pub fn arg(self: Capability) model.Argument {
        return .{ .reference = self.nearRef() };
    }
};

/// How a `call` (or `fetchSettled`) settled. Both arms are materialized into
/// the caller-supplied allocator — typically an arena the caller resets — so
/// nothing in the result borrows the turn that settled it. A caller that used
/// a plain allocator instead of an arena frees the result with `deinit`.
pub const Settled = union(enum) {
    fulfilled: model.Argument,
    broken: []const u8,

    /// Free what `call` / `fetchSettled` materialized into `allocator`: the
    /// fulfilled argument's deep clone, or the broken reason's dupe. A caller
    /// that settled into an arena it resets never needs this.
    pub fn deinit(self: Settled, allocator: std.mem.Allocator) void {
        switch (self) {
            .fulfilled => |argument| model.freeArgument(allocator, argument),
            .broken => |reason| allocator.free(reason),
        }
    }
};

/// A hook run before the vat serves each drained event. Return true to claim
/// the event and skip the vat's serve dispatch; a hook error propagates out of
/// `step` / `flush` / `stepReadable`.
pub const BeforeServeHook = *const fn (ctx: ?*anyopaque, cv: *ConnectedVat, event: *engine.Event) anyerror!bool;

/// Adapter options for a live connection. Crossed-hellos and stateless GC are
/// driver policy, not CapTP semantics added below the engine.
pub const ServeOptions = struct {
    crossed_hellos: ?*crossed_hellos.Registry = null,
    /// Emit `op:gc-exports` / `op:gc-answers` after each inbound deliver/resolve
    /// the vat does not retain imports from.
    gc_stateless: bool = false,
    hook_ctx: ?*anyopaque = null,
    before_serve: ?BeforeServeHook = null,
};

/// A vat bound to a live connection. Composes an `actors.Vat` and a
/// `net_adapter.Connection` over one borrowed `engine.Peer`. The peer is owned by
/// the caller (stable address); this borrows it, exactly as `actors.Vat.initOver`
/// does.
///
/// This is the blocking, transport-neutral embedding, and it runs on one fiber
/// by contract (ADR-0053): it serves cooperative request/response, where each
/// side drains the replies it asked for. A partner that streams without
/// draining belongs on the completion loop (`LoopHost` / `LoopDialer`),
/// which bounds outbound bytes and parks reads instead of blocking a write.
pub const ConnectedVat = struct {
    vat: actors.Vat,
    conn: net_adapter.Connection,
    peer: *engine.Peer,
    serve_options: ServeOptions = .{},
    /// The partner's most recent `op:abort`, retained so a close can name the
    /// partner's actual diagnostic instead of a generic "connection closed".
    /// Bounded and inline: the message is copied into a fixed buffer, so
    /// retaining it allocates nothing and borrows nothing from the event.
    last_abort: ?AbortInfo = null,

    /// Bounded retention of an inbound `op:abort`: the typed kind plus the
    /// first `message_buf.len` bytes of the partner's diagnostic.
    pub const AbortInfo = struct {
        kind: model.AbortKind,
        message_buf: [128]u8,
        message_len: usize,
    };

    /// The partner's retained abort diagnostic, or null when no `op:abort`
    /// arrived. The slice points into this `ConnectedVat`'s own buffer, so it
    /// stays valid as long as the connected vat does.
    pub fn abortReason(self: *const ConnectedVat) ?[]const u8 {
        if (self.last_abort) |*info| return info.message_buf[0..info.message_len];
        return null;
    }

    /// Bind a vat to an existing connection over `peer`. Transport-neutral: the
    /// connection may ride any stream.
    pub fn over(allocator: std.mem.Allocator, peer: *engine.Peer, conn: net_adapter.Connection) ConnectedVat {
        return .{
            .vat = actors.Vat.initOver(allocator, peer),
            .conn = conn,
            .peer = peer,
        };
    }

    /// Tear down the vat and close the connection. Does not free the borrowed peer.
    pub fn deinit(self: *ConnectedVat) void {
        self.vat.deinit();
        self.conn.deinit();
    }

    /// One pump cycle: drive the connection one step (one read and/or one flush),
    /// then dispatch every event the peer surfaced into the vat. A deliver runs
    /// its published actor and resolves the answer. A resolve fires a far
    /// promise's listener. Returns the connection's `Progress` so the caller's loop can act
    /// on `.closed`. Allocation and I/O are visible here: the pump reads and writes
    /// the socket, and the vat dispatch allocates only what a surfaced event costs.
    ///
    /// When the pump reports `.closed`, every far promise still awaiting a
    /// partner's resolution is broken. Those resolutions ride the wire that just
    /// went away, so an awaiting `on` listener settles broken here rather than
    /// hanging on a reply that can never arrive. The break carries the partner's
    /// retained abort diagnostic when one arrived, so the reason names what the
    /// partner actually said.
    pub fn step(self: *ConnectedVat) !net_adapter.Progress {
        try self.drainEvents();
        const progress = try self.conn.pump();
        try self.drainEvents();
        if (progress == .closed) self.vat.breakFarPromises(self.closeReason("connection closed"));
        return progress;
    }

    /// Serve the connection until the partner leaves. This is the hosting half of
    /// the surface: accept, publish, serve. Runs `step` until the pump reports
    /// `.closed`. A partner that drops the socket without a clean shutdown
    /// (`error.ConnectionLost`, `error.TruncatedFrame`) has still left, so serve
    /// breaks the far promises that were waiting on that wire and returns
    /// normally, exactly as it does for a graceful close. Every other error
    /// propagates. A caller that needs work between reads keeps the explicit
    /// `step` loop.
    pub fn serve(self: *ConnectedVat) !void {
        while (true) {
            const progress = self.step() catch |err| switch (err) {
                error.ConnectionLost, error.TruncatedFrame => {
                    self.vat.breakFarPromises(self.closeReason("connection lost"));
                    return;
                },
                else => return err,
            };
            if (progress == .closed) return;
        }
    }

    /// Dispatch any queued events and flush the resulting outbound, without
    /// reading. A host coordinating across connections enqueues a send on this
    /// vat's peer (the gifter sending a `fetch` over the exporter's connection)
    /// and calls this to put it on the wire instead of blocking on a read.
    pub fn flush(self: *ConnectedVat) !void {
        try self.drainEvents();
        try self.conn.flush();
        try self.drainEvents();
    }

    /// Poll-guarded `step`: flush outbound, then wait up to `timeout_ms` for the
    /// socket to become readable. Returns the pump `Progress` once data is ready
    /// (or already buffered), or null on timeout. A poll failure on the fd means
    /// the transport is gone, so it surfaces as `error.ConnectionLost` — the
    /// same classification `serve` and `settle` give a lost partner — rather
    /// than masquerading as a timeout. A host serving several
    /// connections on one thread per connection can then re-check shared cross-connection
    /// work between reads rather than blocking a read that may never arrive. The
    /// blocking `step` stays the honest primitive; this is the multiplexing sugar.
    pub fn stepReadable(self: *ConnectedVat, timeout_ms: i32) !?net_adapter.Progress {
        try self.flush();
        if (!self.conn.hasBufferedInbound()) {
            // Poll only when the transport exposes a pollable fd. A transport
            // without one (a userspace stream that multiplexes in its own loop)
            // falls through to a blocking step.
            if (self.conn.socketHandle()) |handle| {
                var fds = [_]std.posix.pollfd{.{ .fd = handle, .events = std.posix.POLL.IN, .revents = 0 }};
                const ready = std.posix.poll(&fds, timeout_ms) catch return error.ConnectionLost;
                if (ready == 0) return null;
            }
        }
        return try self.step();
    }

    fn drainEvents(self: *ConnectedVat) !void {
        while (self.peer.pollEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();

            // Retain the partner's abort diagnostic (bounded, copied) before
            // anything else sees the event, so a later close can break the far
            // promises with the partner's own words.
            if (event.kind() == .abort) self.retainAbort(&event);

            if (event.kind() == .start_session) {
                if (self.serve_options.crossed_hellos) |registry| {
                    try crossed_hellos.maybeAbortInbound(registry, self.peer, &self.conn, &event);
                }
            }

            const skip_serve = if (self.serve_options.before_serve) |hook|
                try hook(self.serve_options.hook_ctx, self, &event)
            else
                false;
            // An event the vat does not claim (no published actor, no awaited
            // promise) is dropped here by design; the discarded bool is that
            // claim verdict.
            if (!skip_serve) _ = try self.vat.serve(&event);

            if (self.serve_options.gc_stateless) gc.emitStatelessAfter(self.peer, &event);
        }
        // Run any queued local turns so a local-target `send` settles through
        // the same pump that settles far sends. Without this, a local deliver
        // queued on the vat would wait forever: nothing else in the driver
        // calls `drive`, and the promise would never fire its listener.
        try self.vat.drive();
    }

    /// Copy an inbound `op:abort`'s kind and bounded message into `last_abort`.
    /// A message longer than the buffer is truncated; a malformed abort view is
    /// ignored, leaving any earlier retention in place.
    fn retainAbort(self: *ConnectedVat, event: *const engine.Event) void {
        const body = event.view() catch return;
        const abort = switch (body) {
            .abort => |abort| abort,
            else => return,
        };
        var info = AbortInfo{ .kind = abort.kind, .message_buf = undefined, .message_len = 0 };
        info.message_len = @min(abort.message.len, info.message_buf.len);
        @memcpy(info.message_buf[0..info.message_len], abort.message[0..info.message_len]);
        self.last_abort = info;
    }

    /// What a wire close breaks the far promises with: the partner's retained
    /// abort diagnostic when one arrived, else `fallback`.
    fn closeReason(self: *const ConnectedVat, fallback: []const u8) []const u8 {
        return self.abortReason() orelse fallback;
    }

    /// Run one half of the keyed handshake with a fresh session secret: draw
    /// the secret, sign `locator`, send `op:start-session`, then pump until the
    /// session opens. Both halves run this same exchange; only the locator each
    /// side signs differs.
    pub fn startKeyedSession(self: *ConnectedVat, locator: model.PeerLocator) !void {
        const secret = try drawSessionSecret(self.conn.io);
        try self.startKeyedSessionWithSecret(locator, secret);
    }

    /// One keyed `op:start-session` half with a caller-supplied `locator` and
    /// `secret`. It signs, sends, and pumps until the session opens. Both
    /// handshake halves run this same exchange, so this is the parameterized
    /// primitive. `startKeyedSession` and `openKeyedSession` wrap it with a
    /// drawn secret and a default locator. Call it directly when the identity or
    /// the address matters. A three-party handoff recipient signs its
    /// `desc:handoff-receive` with the same key the gifter named as the recipient,
    /// and a dialer that also listens signs its real dialable locator rather than
    /// the placeholder.
    pub fn startKeyedSessionWithSecret(self: *ConnectedVat, locator: model.PeerLocator, secret: crypto.SecretKey) !void {
        try self.peer.sendKeyedStartSession(.v1_0, locator, secret);
        while (!self.peer.sessionIsOpen()) {
            const progress = try self.conn.pump();
            if (progress == .closed) return Error.ConnectionClosed;
        }
    }

    /// Complete the keyed `op:start-session` handshake from the bound (negotiating)
    /// peer over tcp, then pump until the session opens. The dialer half uses the
    /// same exchange as `startKeyedSession` with a fresh random session key.
    /// A driver-dialed client does not itself listen, so it signs a placeholder
    /// `tcp` locator and the session identity is the key, not the address. A
    /// signature-verifying partner (a Goblins vat)
    /// checks the signature over these bytes, not that the address is reachable.
    /// The peer must have been built with `engine.Peer.initNegotiating`.
    /// `connectTcp` calls this for you; the transport-neutral dialer is
    /// `connectVia`.
    pub fn openKeyedSession(self: *ConnectedVat) !void {
        try self.startKeyedSession(.{
            .transport = "tcp",
            .designator = "127.0.0.1:0",
            .hints = model.Hints.emptyFalse(),
        });
    }

    /// Spawn a local actor at a fresh export position and return a capability to
    /// it. Pass the capability's `arg()` as a `send` argument to hand a partner
    /// a callback. The export is live the moment this returns: the partner can
    /// invoke the capability whether or not you have sent it the reference. An
    /// actor that must stay unreachable until granted is spawned with
    /// `Vat.spawn`, which mints no export. The spawn-and-publish sequence lives
    /// once in `spawnAt`, which the loop client shares.
    pub fn spawn(self: *ConnectedVat, comptime Behavior: type, initial: Behavior) !Capability {
        return spawnAt(&self.vat, Behavior, initial);
    }

    /// Publish an actor so a partner can `fetch` it by `name` (a swiss-number).
    /// Name first, matching every binding's `publish`. The
    /// register-spawn-publish dance lives once in `publishNamed`, which the
    /// loop host shares.
    pub fn publish(self: *ConnectedVat, name: []const u8, comptime Behavior: type, initial: Behavior) !Capability {
        return publishNamed(&self.vat, name, Behavior, initial);
    }

    /// Eventual-send `msg` to `target` (`<-`), returning a promise to observe
    /// with `on`. A far send goes on the wire; the next `step`s flush it and
    /// dispatch the reply.
    pub fn send(self: *ConnectedVat, target: actors.Ref, msg: actors.Message) !actors.Promise {
        return self.vat.send(target, msg);
    }

    /// Fire-and-forget eventual-send (`<-np`): enqueue a deliver with no answer,
    /// so a notification costs one deliver and no reply. The next `step` flushes
    /// it. Returns nothing — there is no promise to observe.
    pub fn tell(self: *ConnectedVat, target: actors.Ref, msg: actors.Message) !void {
        return self.vat.tell(target, msg);
    }

    /// Register a one-shot listener on `promise`.
    pub fn on(self: *ConnectedVat, promise: actors.Promise, listener: actors.Listener) !void {
        return self.vat.on(promise, listener);
    }

    /// Eventual-send `msg` to `target` and drive the connection with `step`
    /// until the reply settles, returning the settled outcome. This is
    /// explicit, blocking, caller-owned I/O, the same contract as `fetch`.
    /// Both `Settled` arms are materialized into `arena` — pass an arena (or
    /// any allocator) the caller owns and frees, so the result borrows nothing
    /// from the turn that settled it. Returns `ConnectionClosed` if the
    /// partner leaves before the reply settles.
    pub fn call(self: *ConnectedVat, target: actors.Ref, msg: actors.Message, arena: std.mem.Allocator) !Settled {
        const promise = try self.vat.send(target, msg);
        return self.settleOwned(promise, arena);
    }

    /// Fetch a partner's published capability by `name`, returning a far `Ref` you
    /// can `send` to. This is a `call` on the bootstrap object, using explicit,
    /// blocking, caller-owned I/O; `sendBootstrapFetch` is the shared deliver
    /// shape it drives to settlement. A fetch the partner answers with a break (an
    /// unpublished name) returns `Error.FetchBroken`; a fetch that fulfills with
    /// anything other than a far capability returns `Error.FetchNotACapability`.
    /// This path allocates nothing and retains no break reason; `fetchSettled`
    /// is the reason-bearing form.
    pub fn fetch(self: *ConnectedVat, name: []const u8) !actors.Ref {
        var state = FetchState{};
        const promise = try sendBootstrapFetch(&self.vat, name);
        try self.settle(promise, .{ .ctx = &state, .func = onFetch });
        return switch (state.outcome orelse return Error.ConnectionClosed) {
            .capability => |far_ref| .{ .far = far_ref },
            .broken => Error.FetchBroken,
            .not_a_capability => Error.FetchNotACapability,
        };
    }

    /// The reason-bearing fetch: the same bootstrap fetch as `fetch`, returning
    /// the partner's settlement whole as a `Settled` materialized into `arena`.
    /// A break's reason (say, "unknown swissnum") is readable here instead of
    /// flattened to `Error.FetchBroken`; a fulfilled fetch carries the
    /// capability as a `.reference` argument.
    pub fn fetchSettled(self: *ConnectedVat, name: []const u8, arena: std.mem.Allocator) !Settled {
        const promise = try sendBootstrapFetch(&self.vat, name);
        return self.settleOwned(promise, arena);
    }

    /// Drive `promise` to settlement and materialize the outcome into `arena`:
    /// the shared owned tail of `call` and `fetchSettled`.
    fn settleOwned(self: *ConnectedVat, promise: actors.Promise, arena: std.mem.Allocator) !Settled {
        var capture = CaptureState{ .arena = arena };
        try self.settle(promise, .{ .ctx = &capture, .func = CaptureState.fire });
        if (capture.failed) return error.OutOfMemory;
        return capture.settled orelse Error.ConnectionClosed;
    }

    /// Drive the connection with `step` until `promise` settles into
    /// `listener`: the shared blocking tail of `call` and `fetch`.
    fn settle(self: *ConnectedVat, promise: actors.Promise, listener: actors.Listener) !void {
        var settle_state = SettleState{ .inner = listener };
        try self.vat.on(promise, .{ .ctx = &settle_state, .func = SettleState.fire });
        // Flush before blocking on a read: a far deliver goes on the wire one
        // syscall earlier, and a local-target promise settles in the flush's
        // drive without touching the socket at all — a read would otherwise
        // block forever on a reply the partner was never asked for.
        self.flush() catch |err| switch (err) {
            error.ConnectionLost, error.TruncatedFrame => {
                self.vat.breakFarPromises(self.closeReason("connection lost"));
                return Error.ConnectionClosed;
            },
            else => {
                self.vat.breakFarPromises("connection failed");
                return err;
            },
        };
        if (settle_state.done) return;
        while (!settle_state.done) {
            // A transport fault is the partner leaving, exactly as in serve():
            // break the far promises (which fires this call's listener broken
            // and removes it, so the stack-bound listener can't dangle on the
            // vat) and report the close, rather than propagating the raw fault.
            const progress = self.step() catch |err| switch (err) {
                error.ConnectionLost, error.TruncatedFrame => {
                    self.vat.breakFarPromises(self.closeReason("connection lost"));
                    return Error.ConnectionClosed;
                },
                // Any other step failure (protocol abort, OOM) also ends this
                // call, so the stack-bound listener must come off the vat the
                // same way — a later turn firing it would write into a dead
                // frame. The promises break now, while `settle_state` is still
                // alive.
                else => {
                    self.vat.breakFarPromises("connection failed");
                    return err;
                },
            };
            // A partner may answer and close in the same step: a settled
            // promise is a settled call, so the real resolution wins over the
            // close that followed it.
            if (settle_state.done) return;
            // `step` already broke the far promises on a clean close (firing
            // this call's listener); just report it.
            if (progress == .closed) return Error.ConnectionClosed;
        }
    }
};

/// Captures a settling resolution into a caller-owned allocator: the listener
/// behind `ConnectedVat.call` and `fetchSettled`. Lives on the caller's stack
/// for that bounded drive. The listener contract cannot carry an error, so an
/// allocation failure is recorded and surfaced after the drive returns.
const CaptureState = struct {
    arena: std.mem.Allocator,
    settled: ?Settled = null,
    failed: bool = false,

    fn fire(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *CaptureState = @ptrCast(@alignCast(ctx.?));
        switch (resolution) {
            .fulfilled => |arg| {
                const owned_arg = model.cloneArgument(self.arena, arg) catch {
                    self.failed = true;
                    return;
                };
                self.settled = .{ .fulfilled = owned_arg };
            },
            .broken => |reason| {
                const owned_reason = self.arena.dupe(u8, reason) catch {
                    self.failed = true;
                    return;
                };
                self.settled = .{ .broken = owned_reason };
            },
        }
    }
};

/// Wraps a `ConnectedVat.call` caller's listener so the drive loop can see when
/// it settles. Lives on `call`'s stack and is valid only for that bounded call.
const SettleState = struct {
    inner: actors.Listener,
    done: bool = false,

    fn fire(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *SettleState = @ptrCast(@alignCast(ctx.?));
        self.done = true;
        self.inner.func(self.inner.ctx, resolution);
    }
};

/// What a bootstrap fetch settled to. `onFetch` runs during the settling step
/// with a turn-borrowed resolution, so it records only the shape (and the POD
/// far ref) — never a borrow of the resolution's bytes. The break reason is
/// deliberately not copied; carrying it would be a hidden allocation, and a
/// caller that needs it uses `ConnectedVat.fetchSettled`.
const FetchOutcome = union(enum) {
    capability: model.FarRef,
    broken,
    not_a_capability,
};

const FetchState = struct {
    outcome: ?FetchOutcome = null,
};

fn onFetch(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const state: *FetchState = @ptrCast(@alignCast(ctx.?));
    state.outcome = switch (resolution) {
        .fulfilled => |arg| switch (arg) {
            .reference => |reference| switch (reference) {
                .far => |far_ref| .{ .capability = far_ref },
                else => .not_a_capability,
            },
            else => .not_a_capability,
        },
        .broken => .broken,
    };
}

/// Open a TCP connection to `address`, bind a vat to a fresh-wired peer, and
/// return the connected vat. The transport is named here, at the constructor; the
/// returned type is the transport-neutral `ConnectedVat`. The caller owns
/// `read_buf` / `write_buf` and the `peer`, including keeping them coherent:
/// the buffers size the steady state, not the largest admissible frame. An
/// inbound frame larger than `read_buf` assembles once in the connection's
/// bounded spill, capped by the peer's `SessionLimits.max_frame_bytes`
/// (ADR-0041), and an outbound frame larger than `write_buf` streams straight
/// through, so smaller buffers are a supported size choice, not an error. The
/// one-call `connect` derives buffers and the session limit from a single
/// `frame_cap` so they cannot drift apart.
pub fn connectTcp(
    io: std.Io,
    allocator: std.mem.Allocator,
    peer: *engine.Peer,
    address: std.Io.net.IpAddress,
    read_buf: []u8,
    write_buf: []u8,
) !ConnectedVat {
    const conn = try net_adapter.tcp.connectAddress(io, peer, address, read_buf, write_buf);
    var vat = ConnectedVat.over(allocator, peer, conn);
    errdefer vat.deinit();
    // Establish the OCapN session before returning, so the caller's first
    // `fetch`/`send` rides an open session. The peer must be negotiating.
    try vat.openKeyedSession();
    return vat;
}

/// Accept one TCP partner on `listener`, bind a vat to a fresh-wired peer, and
/// return the connected vat. This is the server-side counterpart of `connectTcp`.
/// The caller binds a `net_adapter.tcp.Listener` once and accepts each partner into
/// its own caller-owned `peer`, `read_buf`, and `write_buf`, so one listener can
/// host one connected vat per partner. Buffer sizing follows the same contract
/// as `connectTcp`: the buffers size the steady state, and a frame that
/// outgrows them rides the bounded spill (inbound) or streams through
/// (outbound), capped by the peer's `SessionLimits.max_frame_bytes`. The
/// one-call owner over this path is `listen` / `Server.accept`, which derives
/// buffers and the session limit from one `frame_cap`.
/// The keyed `op:start-session` handshake
/// completes (responder half, fresh random session key) before this returns, so
/// the caller's first serve loop rides an open session. The signed locator names
/// the listener's bound address, which is the address a partner can actually dial.
/// A host that must reuse the session identity (a three-party handoff recipient) builds
/// the vat with `ConnectedVat.over` and calls
/// `ConnectedVat.startKeyedSessionWithSecret` itself.
pub fn acceptTcp(
    allocator: std.mem.Allocator,
    peer: *engine.Peer,
    listener: *net_adapter.tcp.Listener,
    read_buf: []u8,
    write_buf: []u8,
) !ConnectedVat {
    const conn = try listener.accept(peer, read_buf, write_buf);
    var vat = ConnectedVat.over(allocator, peer, conn);
    errdefer vat.deinit();
    // "255.255.255.255:65535" is 21 bytes; a bracketed IPv6 designator with a
    // port is at most 54. The locator is copied into the outbound start-session
    // before this call returns, so a stack buffer is safe.
    var designator_buf: [64]u8 = undefined;
    const designator = std.fmt.bufPrint(&designator_buf, "{f}", .{listener.localAddress()}) catch
        unreachable;
    try vat.startKeyedSession(.{
        .transport = "tcp",
        .designator = designator,
        .hints = model.Hints.emptyFalse(),
    });
    return vat;
}

/// Dial a locator through the netlayer contract. This is the transport-neutral
/// dialer.
/// The locator's `transport` symbol selects a registered `net_adapter.Netlayer`
/// at runtime; there is no transport named here, so a transport the core never
/// heard of dials through this same path once its resident is registered. It fails
/// closed with `Error.UnknownTransport` when no resident hosts the symbol. There
/// is no silent fallback that would re-privilege one transport. The caller owns
/// `peer`, `read_buf`, and `write_buf`; the registry (and the residents behind
/// it) must outlive the returned vat. `connectTcp` is the tcp-named convenience
/// over the same machinery.
pub fn connectVia(
    registry: net_adapter.NetlayerRegistry,
    allocator: std.mem.Allocator,
    peer: *engine.Peer,
    locator: model.PeerLocator,
    read_buf: []u8,
    write_buf: []u8,
) !ConnectedVat {
    const nl = registry.resolve(locator.transport) orelse return Error.UnknownTransport;
    const conn = try nl.dial(peer, locator, .{ .read = read_buf, .write = write_buf });
    var vat = ConnectedVat.over(allocator, peer, conn);
    errdefer vat.deinit();
    // A driver-dialed client does not itself listen, so it signs its dialed
    // transport with no dialable designator of its own; the session identity is
    // the random session key, which the partner verifies over these bytes.
    try vat.startKeyedSession(.{
        .transport = locator.transport,
        .designator = "",
        .hints = model.Hints.emptyFalse(),
    });
    return vat;
}

/// Dial like `connectVia`, but sign `op:start-session` with `secret` over the
/// dialer's *own* dialable designator (`self_designator`) instead of a drawn
/// random key and an empty designator. This is the dialer half of key
/// unification: when `secret` is the secret half of the same Ed25519 key the
/// netlayer's endpoint is built on — `crypto.SecretKey.fromSeed(seed)` against an
/// endpoint seeded with `seed` — the session pubkey the partner verifies equals
/// the transport node id it dialed equals `self_designator`. One key is at once
/// the transport identity, the locator designator, and the session signing key.
/// The caller owns `peer`, `read_buf`, and `write_buf`; the registry must outlive
/// the returned vat.
pub fn connectViaWithSecret(
    registry: net_adapter.NetlayerRegistry,
    allocator: std.mem.Allocator,
    peer: *engine.Peer,
    locator: model.PeerLocator,
    self_designator: []const u8,
    secret: crypto.SecretKey,
    read_buf: []u8,
    write_buf: []u8,
) !ConnectedVat {
    const nl = registry.resolve(locator.transport) orelse return Error.UnknownTransport;
    const conn = try nl.dial(peer, locator, .{ .read = read_buf, .write = write_buf });
    var vat = ConnectedVat.over(allocator, peer, conn);
    errdefer vat.deinit();
    try vat.startKeyedSessionWithSecret(.{
        .transport = locator.transport,
        .designator = self_designator,
        .hints = model.Hints.emptyFalse(),
    }, secret);
    return vat;
}

/// Dial an `ocapn://` URI in one call. This parses the URI into a
/// `model.PeerLocator` and dials it through `connectVia` against the caller's
/// `registry`, so the URI a peer published becomes a live connection without
/// the caller parsing it by hand.
///
/// The registry is the caller's because the residents behind it can hold state
/// (the iroh resident does), and that state must outlive the returned vat — a
/// registry built inside this call would dangle the moment it returned. A URI
/// naming a transport no registered resident hosts fails closed with
/// `Error.UnknownTransport`. The caller owns `peer`, `read_buf`, and
/// `write_buf`; the parsed locator is freed before returning, because
/// `connectVia` copies what the session retains during the handshake.
pub fn connectUri(
    registry: net_adapter.NetlayerRegistry,
    allocator: std.mem.Allocator,
    peer: *engine.Peer,
    uri_str: []const u8,
    read_buf: []u8,
    write_buf: []u8,
) !ConnectedVat {
    const locator = try model.uri.parsePeer(allocator, uri_str);
    defer model.freePeerLocator(allocator, locator);
    return connectVia(registry, allocator, peer, locator, read_buf, write_buf);
}

/// Accept one partner through a contract `net_adapter.Listener`, bind a vat,
/// and complete the responder handshake by signing the listener's own transport
/// and dialable designator. This is the transport-neutral hosting counterpart of
/// `connectVia`. The caller binds the listener once (via
/// `net_adapter.Netlayer.listen`) and accepts each partner into its own
/// caller-owned `peer` and buffers. `acceptTcp` is the tcp-named convenience.
pub fn acceptVia(
    listener: net_adapter.Listener,
    allocator: std.mem.Allocator,
    peer: *engine.Peer,
    read_buf: []u8,
    write_buf: []u8,
) !ConnectedVat {
    const conn = try listener.accept(peer, .{ .read = read_buf, .write = write_buf });
    var vat = ConnectedVat.over(allocator, peer, conn);
    errdefer vat.deinit();
    var designator_buf: [64]u8 = undefined;
    const designator = listener.localDesignator(&designator_buf);
    try vat.startKeyedSession(.{
        .transport = listener.transportName(),
        .designator = designator,
        .hints = model.Hints.emptyFalse(),
    });
    return vat;
}

/// Accept like `acceptVia`, but sign the responder handshake with `secret`
/// instead of a drawn random key. The signed designator stays the listener's own
/// dialable designator, so when `secret` is the secret half of the key the
/// netlayer's endpoint is built on — `crypto.SecretKey.fromSeed(seed)` against an
/// endpoint seeded with `seed` — the session pubkey the partner verifies equals
/// the transport node id it dialed equals the signed designator. This is the
/// responder half of key unification; `connectViaWithSecret` is the dialer half.
pub fn acceptViaWithSecret(
    listener: net_adapter.Listener,
    allocator: std.mem.Allocator,
    peer: *engine.Peer,
    secret: crypto.SecretKey,
    read_buf: []u8,
    write_buf: []u8,
) !ConnectedVat {
    const conn = try listener.accept(peer, .{ .read = read_buf, .write = write_buf });
    var vat = ConnectedVat.over(allocator, peer, conn);
    errdefer vat.deinit();
    var designator_buf: [64]u8 = undefined;
    const designator = listener.localDesignator(&designator_buf);
    try vat.startKeyedSessionWithSecret(.{
        .transport = listener.transportName(),
        .designator = designator,
        .hints = model.Hints.emptyFalse(),
    }, secret);
    return vat;
}

/// Publish `Behavior` on `vat` (which must be peer-bound) so a partner can
/// `fetch` it by `name` (name first, matching every binding's `publish`). This
/// is the `registerBootstrapCap`, spawn, and publish sequence, factored so the
/// connection-per-thread `ConnectedVat` and the loop host share one
/// definition. Returns the capability at its allocated export position,
/// carrying the vat-local `ref` so the publisher can keep talking to its own
/// actor.
pub fn publishNamed(vat: *actors.Vat, name: []const u8, comptime Behavior: type, initial: Behavior) !Capability {
    const peer = vat.peer orelse return Error.NotConnected;
    const position = try peer.registerBootstrapCap(name);
    const ref = try vat.spawn(Behavior, initial);
    try vat.bindExport(ref, position);
    return .{ .position = position, .ref = ref };
}

/// Spawn `initial` on `vat` (which must be peer-bound) at a fresh export
/// position and return a capability to it. The position comes from the session's
/// one export allocator — the counter that also mints resolver and bootstrap
/// exports — so a spawned actor can never alias a position the session hands out
/// for anything else. The export is live the moment this returns: the partner
/// can invoke the capability whether or not the caller has sent it the
/// reference. An actor that must stay unreachable until granted is spawned with
/// `Vat.spawn`, which mints no export. `ConnectedVat.spawn` and
/// `LoopDialer.Client.spawn` share this one definition, the same way
/// `publishNamed` is shared.
pub fn spawnAt(vat: *actors.Vat, comptime Behavior: type, initial: Behavior) !Capability {
    const peer = vat.peer orelse return Error.NotConnected;
    const position = try peer.exportNextObject();
    const ref = try vat.spawn(Behavior, initial);
    try vat.bindExport(ref, position);
    return .{ .position = position, .ref = ref };
}

/// Enqueue the bootstrap `fetch` for `name` on `vat` (which must be peer-bound)
/// and return the promise of the partner's answer: import the well-known
/// bootstrap export, then eventual-send `fetch(name)` to it. This is the one
/// definition of the bootstrap-fetch deliver shape. `ConnectedVat.fetch`
/// drives the returned promise to settlement; `LoopDialer.Client.fetch` hands
/// it to the completion loop.
pub fn sendBootstrapFetch(vat: *actors.Vat, name: []const u8) !actors.Promise {
    const peer = vat.peer orelse return Error.NotConnected;
    try peer.importObject(engine.BOOTSTRAP_POSITION);
    return vat.send(
        .{ .far = model.FarRef.object(engine.BOOTSTRAP_POSITION) },
        .{ .verb = "fetch", .args = &.{.{ .bytes = name }} },
    );
}

/// Options for `connect` and `listen`. The one knob is `frame_cap`: the owned
/// read/write buffers and the session's `max_frame_bytes` limit all derive
/// from it, so the buffers and the limit cannot drift apart.
pub const ConnectionOptions = struct {
    frame_cap: usize = 1 << 16,
};

/// An owning connection — the one object a native Zig application holds. It
/// owns the peer and both read/write buffers, so a caller connects (or
/// accepts) with one call instead of stitching a negotiating peer, two
/// buffers, and `connectTcp` together by hand. Heap-pinned because the
/// connected vat borrows the peer: the pointer `connect` and `Server.accept`
/// return is stable for the connection's life, and `Connection.close` frees
/// the whole bundle. The explicit `connectTcp` / `acceptTcp` path remains
/// available when the caller wants to own the peer and buffers and see every
/// allocation at the call site. This type is the native-Zig spelling of the
/// `Connection` every binding exposes.
pub const Connection = struct {
    cv: ConnectedVat,
    peer: engine.Peer,
    read_buf: []u8,
    write_buf: []u8,
    allocator: std.mem.Allocator,

    /// Tear down the connection and free the peer and buffers this owns.
    pub fn close(self: *Connection) void {
        self.cv.deinit();
        self.freeShell();
    }

    /// Fetch a partner's published capability by `name` (see `ConnectedVat.fetch`).
    pub fn fetch(self: *Connection, name: []const u8) !actors.Ref {
        return self.cv.fetch(name);
    }
    /// The reason-bearing fetch (see `ConnectedVat.fetchSettled`).
    pub fn fetchSettled(self: *Connection, name: []const u8, arena: std.mem.Allocator) !Settled {
        return self.cv.fetchSettled(name, arena);
    }
    /// Send `msg` to `target`, drive until the reply settles, and return the
    /// outcome materialized into `arena` (see `ConnectedVat.call`).
    pub fn call(self: *Connection, target: actors.Ref, msg: actors.Message, arena: std.mem.Allocator) !Settled {
        return self.cv.call(target, msg, arena);
    }
    /// Eventual-send `msg` to `target`, returning a promise (see `ConnectedVat.send`).
    pub fn send(self: *Connection, target: actors.Ref, msg: actors.Message) !actors.Promise {
        return self.cv.send(target, msg);
    }
    /// Fire-and-forget eventual-send (see `ConnectedVat.tell`).
    pub fn tell(self: *Connection, target: actors.Ref, msg: actors.Message) !void {
        return self.cv.tell(target, msg);
    }
    /// Register a one-shot listener on `promise` (see `ConnectedVat.on`).
    pub fn on(self: *Connection, promise: actors.Promise, listener: actors.Listener) !void {
        return self.cv.on(promise, listener);
    }
    /// Spawn a local actor and return a capability to it (see `ConnectedVat.spawn`).
    pub fn spawn(self: *Connection, comptime Behavior: type, initial: Behavior) !Capability {
        return self.cv.spawn(Behavior, initial);
    }
    /// Publish an actor fetchable by `name` (see `ConnectedVat.publish`).
    pub fn publish(self: *Connection, name: []const u8, comptime Behavior: type, initial: Behavior) !Capability {
        return self.cv.publish(name, Behavior, initial);
    }
    /// One pump cycle (see `ConnectedVat.step`).
    pub fn step(self: *Connection) !net_adapter.Progress {
        return self.cv.step();
    }
    /// Serve until the partner leaves (see `ConnectedVat.serve`).
    pub fn serve(self: *Connection) !void {
        return self.cv.serve();
    }
    /// The partner's retained abort diagnostic, if an `op:abort` arrived (see
    /// `ConnectedVat.abortReason`).
    pub fn abortReason(self: *const Connection) ?[]const u8 {
        return self.cv.abortReason();
    }

    /// Free everything `createShell` allocated, in reverse. `close` runs this
    /// after the connected vat is down; a constructor runs it when the
    /// handshake fails after the shell exists.
    fn freeShell(self: *Connection) void {
        self.allocator.free(self.write_buf);
        self.allocator.free(self.read_buf);
        self.peer.deinit();
        self.allocator.destroy(self);
    }
};

/// Allocate the owned bundle a `Connection` carries — the heap-pinned struct,
/// a negotiating peer whose `max_frame_bytes` is `frame_cap`, and both
/// buffers sized to match — without binding it to a transport yet. `connect`
/// and `Server.accept` fill `cv` and return the stable pointer.
fn createShell(allocator: std.mem.Allocator, frame_cap: usize) !*Connection {
    const self = try allocator.create(Connection);
    errdefer allocator.destroy(self);
    self.allocator = allocator;
    self.peer = engine.Peer.initNegotiatingWith(allocator, .{ .limits = .{ .max_frame_bytes = frame_cap } });
    errdefer self.peer.deinit();
    self.read_buf = try allocator.alloc(u8, frame_cap);
    errdefer allocator.free(self.read_buf);
    self.write_buf = try allocator.alloc(u8, frame_cap);
    return self;
}

/// Connect to `address`, own the peer and buffers, and complete the keyed
/// handshake — the one-call native-Zig client, matching every binding's
/// `connect`. The returned `*Connection` is freed by `Connection.close`. A
/// caller that wants to own the peer and buffers directly uses `connectTcp`
/// instead.
pub fn connect(io: std.Io, allocator: std.mem.Allocator, address: std.Io.net.IpAddress, opts: ConnectionOptions) !*Connection {
    const self = try createShell(allocator, opts.frame_cap);
    errdefer self.freeShell();
    self.cv = try connectTcp(io, allocator, &self.peer, address, self.read_buf, self.write_buf);
    return self;
}

/// Dial a locator through the netlayer contract, owning the peer and buffers —
/// the transport-neutral sibling of `connect`, over `connectVia`. The locator's
/// `transport` symbol selects a registered resident at runtime, so a transport
/// the core never named (iroh) dials here once its resident is registered. The
/// `registry` (and the residents behind it, which can hold state) must outlive
/// the returned `*Connection`; the connection owns only its peer and buffers,
/// freed by `Connection.close`.
pub fn connectViaOwned(
    registry: net_adapter.NetlayerRegistry,
    allocator: std.mem.Allocator,
    locator: model.PeerLocator,
    opts: ConnectionOptions,
) !*Connection {
    const self = try createShell(allocator, opts.frame_cap);
    errdefer self.freeShell();
    self.cv = try connectVia(registry, allocator, &self.peer, locator, self.read_buf, self.write_buf);
    return self;
}

/// Dial an `ocapn://` URI in one call, owning the peer and buffers — the
/// transport-neutral sibling of `connect`, over `connectUri`. Parses the URI,
/// resolves its transport against `registry`, and completes the keyed handshake,
/// so a URI a peer published becomes an owning `*Connection` without the caller
/// parsing it by hand. The `registry` must outlive the returned `*Connection`.
pub fn connectUriOwned(
    registry: net_adapter.NetlayerRegistry,
    allocator: std.mem.Allocator,
    uri_str: []const u8,
    opts: ConnectionOptions,
) !*Connection {
    const locator = try model.uri.parsePeer(allocator, uri_str);
    defer model.freePeerLocator(allocator, locator);
    return connectViaOwned(registry, allocator, locator, opts);
}

/// The owning hosting half, bound by `listen`. Each `accept` gives the
/// partner its own `*Connection` with the same owned peer and buffers
/// `connect` gives a client, so the two halves reach parity: one call, owned
/// buffers, one `frame_cap` from which the buffers and the session limit both
/// derive. `net_adapter` already names its per-transport `Listener` types, so
/// the driver's owner is a `Server` — the same word the bindings use for it.
pub const Server = struct {
    listener: net_adapter.tcp.Listener,
    allocator: std.mem.Allocator,
    frame_cap: usize,

    /// The bound address (with the kernel-chosen port when `listen` bound
    /// port 0): the address a partner dials.
    pub fn localAddress(self: *const Server) std.Io.net.IpAddress {
        return self.listener.localAddress();
    }

    /// Accept one partner into its own owned `*Connection`. The responder
    /// keyed handshake completes inside (this is `acceptTcp` underneath), so
    /// the returned connection rides an open session. Freed by
    /// `Connection.close`.
    pub fn accept(self: *Server) !*Connection {
        const conn = try createShell(self.allocator, self.frame_cap);
        errdefer conn.freeShell();
        conn.cv = try acceptTcp(self.allocator, &conn.peer, &self.listener, conn.read_buf, conn.write_buf);
        return conn;
    }

    /// Stop listening. Connections already accepted live on; each one is torn
    /// down by its own `Connection.close`.
    pub fn close(self: *Server) void {
        self.listener.deinit();
    }
};

/// Bind a TCP listener at `address` and return the owning `Server` — the
/// one-call native-Zig host, matching every binding's `listen`. Accept each
/// partner with `Server.accept`; a caller that wants to own the peer and
/// buffers directly binds a `net_adapter.tcp.Listener` and uses `acceptTcp`
/// instead.
pub fn listen(io: std.Io, allocator: std.mem.Allocator, address: std.Io.net.IpAddress, opts: ConnectionOptions) !Server {
    return .{
        .listener = try net_adapter.tcp.Listener.bind(io, address),
        .allocator = allocator,
        .frame_cap = opts.frame_cap,
    };
}
