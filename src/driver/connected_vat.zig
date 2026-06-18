//! The borrowing, caller-pumped driver surface: `ConnectedVat` and the
//! transport constructors that bind one.
//!
//! `ConnectedVat` composes an `actors.Vat` and a `net.Connection` over one
//! borrowed `engine.Peer` — the blocking, one-connection-per-thread embedding
//! (ADR-0053): each side serves cooperative request/response and drains the
//! replies it asked for. The constructors bind one over a transport: `connectTcp`
//! and `acceptTcp` name tcp explicitly; `connectVia`, `acceptVia`, and
//! `connectUri` dispatch on the locator's transport symbol by resolving it
//! against a `[]const net.netlayer.Netlayer`. The owning, one-call `Connection`/`Server` surface
//! that wraps this lives in `connection.zig`; the shared vocabulary (`Error`,
//! `Identity`, `Capability`, `Settled`) and verbs (`publishNamed`, `spawnAt`,
//! `sendBootstrapFetch`, `drawSessionSecret`) both surfaces ride live once in the
//! driver root (`mod.zig`).

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");
const actors = @import("actors");
const net = @import("net");

const crossed_hellos = @import("crossed_hellos.zig");
const gc = @import("gc.zig");

const driver = @import("mod.zig");
const Error = driver.Error;
const Identity = driver.Identity;
const Capability = driver.Capability;
const Settled = driver.Settled;
const ServeOptions = driver.ServeOptions;
const drawSessionSecret = driver.drawSessionSecret;
const publishNamed = driver.publishNamed;
const spawnAt = driver.spawnAt;
const sendBootstrapFetch = driver.sendBootstrapFetch;

const crypto = foundation.crypto;

/// A vat bound to a live connection. Composes an `actors.Vat` and a
/// `net.Connection` over one borrowed `engine.Peer`. The peer is owned by
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
    conn: net.Connection,
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
    pub fn over(allocator: std.mem.Allocator, peer: *engine.Peer, conn: net.Connection) ConnectedVat {
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
    pub fn step(self: *ConnectedVat) !net.Progress {
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
    /// blocking `step` stays the primitive; `stepReadable` is the multiplexing convenience over it.
    pub fn stepReadable(self: *ConnectedVat, timeout_ms: i32) !?net.Progress {
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

    /// Promise pipelining: eventual-send `msg` to a far `promise` a prior
    /// `send`/`sendToAnswer` returned, before it resolves — an `op:deliver`
    /// against `<desc:answer>` (see `Vat.sendToAnswer`). Returns a promise for
    /// this call's own result, itself pipelineable. The next `step` flushes it.
    /// A `.local` promise has no wire answer to pipeline against, so it is
    /// refused with `UncallableTarget`.
    pub fn sendToAnswer(self: *ConnectedVat, promise: actors.Promise, msg: actors.Message) !actors.Promise {
        return switch (promise) {
            .far => |answer_pos| self.vat.sendToAnswer(answer_pos, msg),
            .local => Error.UncallableTarget,
        };
    }

    /// Drive the connection until `promise` (from a prior `send`/`sendToAnswer`)
    /// settles, materializing the outcome into `arena` — the building block
    /// pipelining needs: issue the dependent sends, then settle the one whose
    /// result you want. `call` is this fused onto a single `send`. Returns
    /// `ConnectionClosed` if the partner leaves first.
    pub fn settlePromise(self: *ConnectedVat, promise: actors.Promise, arena: std.mem.Allocator) !Settled {
        return self.settleOwned(promise, arena);
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
    const conn = try net.tcp.connectAddress(io, peer, address, read_buf, write_buf);
    var vat = ConnectedVat.over(allocator, peer, conn);
    errdefer vat.deinit();
    // Establish the OCapN session before returning, so the caller's first
    // `fetch`/`send` rides an open session. The peer must be negotiating.
    try vat.openKeyedSession();
    return vat;
}

/// Accept one TCP partner on `listener`, bind a vat to a fresh-wired peer, and
/// return the connected vat. This is the server-side counterpart of `connectTcp`.
/// The caller binds a `net.tcp.Listener` once and accepts each partner into
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
    listener: *net.tcp.Listener,
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

/// Dial a locator through the netlayer contract, signing the keyed handshake
/// with `identity`. This is the transport-neutral dialer.
/// The locator's `transport` symbol selects the netlayer that hosts it in
/// `netlayers` at runtime; there is no transport named here, so a transport the
/// core never heard of dials through this same path once its netlayer is in the
/// slice. It fails closed with `Error.UnknownTransport` when no netlayer hosts
/// the symbol. There is no silent fallback that would re-privilege one transport.
///
/// `identity` is the one identity seam: `.ephemeral` draws a fresh random
/// session key and advertises no dialable designator (the ordinary client), and
/// `.keyed` signs with a caller-held key over the dialer's own designator — key
/// unification, when the key is the secret half of the netlayer endpoint's key.
/// The caller owns `peer`, `read_buf`, and `write_buf`; `netlayers` (and the
/// residents behind it) must outlive the returned vat. `connectTcp` is the
/// tcp-named convenience over the same machinery.
pub fn connectVia(
    netlayers: []const net.netlayer.Netlayer,
    allocator: std.mem.Allocator,
    peer: *engine.Peer,
    locator: model.PeerLocator,
    identity: Identity,
    read_buf: []u8,
    write_buf: []u8,
) !ConnectedVat {
    const nl = net.netlayer.resolve(netlayers, locator.transport) orelse return Error.UnknownTransport;
    const conn = try nl.dial(peer, locator, .{ .read = read_buf, .write = write_buf });
    var vat = ConnectedVat.over(allocator, peer, conn);
    errdefer vat.deinit();
    const self_locator: model.PeerLocator = .{
        .transport = locator.transport,
        .designator = identity.dialedDesignator(),
        .hints = model.Hints.emptyFalse(),
    };
    switch (identity) {
        .ephemeral => try vat.startKeyedSession(self_locator),
        .keyed => |k| try vat.startKeyedSessionWithSecret(self_locator, k.secret),
    }
    return vat;
}

/// Dial an `ocapn://` URI in one call. This parses the URI into a
/// `model.PeerLocator` and dials it through `connectVia` against the caller's
/// `netlayers`, so the URI a peer published becomes a live connection without
/// the caller parsing it by hand.
///
/// `netlayers` is the caller's because the residents behind it can hold state
/// (the iroh resident does), and that state must outlive the returned vat — a
/// slice built inside this call would dangle the moment it returned. A URI
/// naming a transport no netlayer hosts fails closed with
/// `Error.UnknownTransport`. `identity` is the same signing seam `connectVia`
/// takes: `.ephemeral` for an ordinary client, `.keyed` to dial under a
/// caller-held key. The caller owns `peer`, `read_buf`, and `write_buf`; the
/// parsed locator is freed before returning, because `connectVia` copies what
/// the session retains during the handshake.
pub fn connectUri(
    netlayers: []const net.netlayer.Netlayer,
    allocator: std.mem.Allocator,
    peer: *engine.Peer,
    uri_str: []const u8,
    identity: Identity,
    read_buf: []u8,
    write_buf: []u8,
) !ConnectedVat {
    const locator = try model.uri.parsePeer(allocator, uri_str);
    defer model.freePeerLocator(allocator, locator);
    return connectVia(netlayers, allocator, peer, locator, identity, read_buf, write_buf);
}

/// Accept one partner through a contract `net.netlayer.Listener`, bind a vat,
/// and complete the responder handshake signing with `identity`. This is the
/// transport-neutral hosting counterpart of `connectVia`. The caller binds the
/// listener once (via `net.netlayer.Netlayer.listen`) and accepts each partner
/// into its own caller-owned `peer` and buffers. `acceptTcp` is the tcp-named
/// convenience.
///
/// A host is always reachable, so the signed designator is the listener's own
/// bound designator regardless of `identity`. `identity` chooses only the
/// signing key: `.ephemeral` draws a fresh random session key, and `.keyed`
/// signs with a caller-held key — the responder half of key unification, when
/// the key is the secret half of the netlayer endpoint's key and the bound
/// designator already equals that key's node id. The keyed arm's `designator`
/// field is unused here: a host names itself by where it listens.
pub fn acceptVia(
    listener: net.netlayer.Listener,
    allocator: std.mem.Allocator,
    peer: *engine.Peer,
    identity: Identity,
    read_buf: []u8,
    write_buf: []u8,
) !ConnectedVat {
    const conn = try listener.accept(peer, .{ .read = read_buf, .write = write_buf });
    var vat = ConnectedVat.over(allocator, peer, conn);
    errdefer vat.deinit();
    var designator_buf: [64]u8 = undefined;
    const self_locator: model.PeerLocator = .{
        .transport = listener.transportName(),
        .designator = listener.localDesignator(&designator_buf),
        .hints = model.Hints.emptyFalse(),
    };
    switch (identity) {
        .ephemeral => try vat.startKeyedSession(self_locator),
        .keyed => |k| try vat.startKeyedSessionWithSecret(self_locator, k.secret),
    }
    return vat;
}
