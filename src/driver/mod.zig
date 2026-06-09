//! A connection-bound vat driver: the application surface for native Zig.
//!
//! The `actors.Vat` is a sync, no-I/O turn loop; `net_adapter` is the one place
//! I/O lives. Wiring them together — open a socket, bind a vat to the peer, pump
//! the connection, dispatch each surfaced event into the vat — is the same loop
//! every networked Zig app would otherwise hand-write. [`ConnectedVat`] is that
//! composition, and nothing more: it owns no protocol the engine lacks and hides
//! no allocation or I/O. Every read and write is one explicit [`step`]; the
//! caller still owns the loop, the allocator, the buffers, and the peer's
//! lifetime. This layer is *above* both `actors` and `net_adapter`, so it is the
//! one place that may touch `std.Io` and the actor turn loop at once — it is not
//! part of the no-I/O core.
//!
//! The transport is named once, at the constructor ([`connectTcp`]). The driver
//! type itself is transport-neutral: a caller that already holds a
//! `net_adapter.Connection` over any stream (TLS, an in-memory pipe, a future
//! QUIC binding) uses [`ConnectedVat.over`] directly. There is no `TcpVat`.

const std = @import("std");

const foundation = @import("../foundation/mod.zig");
const model = @import("../model/mod.zig");
const engine = @import("../engine/mod.zig");
const actors = @import("../actors/mod.zig");
const net_adapter = @import("../net_adapter/mod.zig");

pub const crossed_hellos = @import("crossed_hellos.zig");
pub const gc = @import("gc.zig");

const crypto = foundation.crypto;

/// The well-known bootstrap export every OCapN peer answers `fetch` on.
const BOOTSTRAP_POSITION: u64 = 0;

/// App-allocated export positions start clear of the bootstrap object (0) and a
/// band of low well-known slots, so a [`ConnectedVat.spawn`] never collides with
/// the bootstrap export or a fixed slot a power-user binds through `peer`.
const FIRST_SPAWN_POSITION: u64 = 32;

pub const Error = error{
    /// A `fetch` ran to a clean connection close before the capability resolved.
    ConnectionClosed,
    /// A `fetch` resolved to something other than a capability, or broke.
    FetchFailed,
    /// The OS entropy source could not fill the session seed for the handshake.
    HandshakeEntropyFailed,
};

/// A capability to a local actor this vat hosts — the handle you pass a partner
/// as a `send` argument. `nearRef()` is the explicit wire reference it marshals
/// to; the Zig surface keeps that conversion visible rather than implicit.
pub const Capability = struct {
    position: u64,

    pub fn nearRef(self: Capability) model.Reference {
        return .{ .near = model.NearRef.object(self.position) };
    }
};

/// A vat bound to a live connection. Composes an `actors.Vat` and a
/// `net_adapter.Connection` over one borrowed `engine.Peer`. The peer is owned by
/// the caller (stable address); this borrows it, exactly as `actors.Vat.initOver`
/// does.
/// Adapter options for a live connection. Crossed-hellos and stateless GC are
/// policy the driver owns — not CapTP semantics the engine lacks.
pub const BeforeServeHook = *const fn (ctx: ?*anyopaque, cv: *ConnectedVat, event: *engine.Event) anyerror!bool;

pub const ServeOptions = struct {
    crossed_hellos: ?*crossed_hellos.Registry = null,
    /// Emit `op:gc-exports` / `op:gc-answers` after each inbound deliver/resolve
    /// the vat does not retain imports from.
    gc_stateless: bool = false,
    hook_ctx: ?*anyopaque = null,
    before_serve: ?BeforeServeHook = null,
};

pub const ConnectedVat = struct {
    vat: actors.Vat,
    conn: net_adapter.Connection,
    peer: *engine.Peer,
    next_spawn: u64 = FIRST_SPAWN_POSITION,
    serve_options: ServeOptions = .{},

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
    /// then dispatch every event the peer surfaced into the vat — a deliver runs
    /// its published actor and resolves the answer, a resolve fires a far vow's
    /// listener. Returns the connection's `Progress` so the caller's loop can act
    /// on `.closed`. Allocation and I/O are visible here: the pump reads/writes the
    /// socket; the vat dispatch allocates only what a surfaced event costs.
    ///
    /// When the pump reports `.closed`, every far vow still awaiting a partner's
    /// resolution is broken. Those resolutions ride the wire that just went away,
    /// so an awaiting [`on`] listener settles broken here rather than hanging on a
    /// reply that can never arrive.
    pub fn step(self: *ConnectedVat) !net_adapter.Progress {
        try self.drainEvents();
        const progress = try self.conn.pump();
        try self.drainEvents();
        if (progress == .closed) self.vat.breakFarVows("connection closed");
        return progress;
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

    /// Poll-guarded [`step`]: flush outbound, then wait up to `timeout_ms` for the
    /// socket to become readable. Returns the pump `Progress` once data is ready
    /// (or already buffered), or null on timeout — so a host serving several
    /// connections on one thread per connection can re-check shared cross-connection
    /// work between reads rather than blocking a read that may never arrive. The
    /// blocking [`step`] stays the honest primitive; this is the multiplexing sugar.
    pub fn stepReadable(self: *ConnectedVat, timeout_ms: i32) !?net_adapter.Progress {
        try self.drainEvents();
        try self.conn.flush();
        try self.drainEvents();
        if (!self.conn.hasBufferedInbound()) {
            var fds = [_]std.posix.pollfd{.{ .fd = self.conn.socketHandle(), .events = std.posix.POLL.IN, .revents = 0 }};
            const ready = std.posix.poll(&fds, timeout_ms) catch return null;
            if (ready == 0) return null;
        }
        const progress = try self.conn.pump();
        try self.drainEvents();
        if (progress == .closed) self.vat.breakFarVows("connection closed");
        return progress;
    }

    fn drainEvents(self: *ConnectedVat) !void {
        while (self.peer.pollEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();

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

            if (self.serve_options.gc_stateless) {
                if (event.kind() == .deliver) gc.emitExportsForDeliver(self.peer, &event);
                if (event.kind() == .resolve) gc.emitAnswerForResolve(self.peer, &event);
            }
        }
    }

    /// Responder half of a keyed handshake: draw entropy, sign `locator`, send
    /// `op:start-session`, then pump until the session opens.
    pub fn respondKeyedSession(self: *ConnectedVat, locator: model.PeerLocator) !void {
        var seed: [crypto.SEED_BYTES]u8 = undefined;
        if (std.os.linux.getrandom(&seed, seed.len, 0) != seed.len) return Error.HandshakeEntropyFailed;
        const secret = crypto.SecretKey.fromSeed(seed) catch return Error.HandshakeEntropyFailed;
        try self.respondKeyedSessionWithSecret(locator, secret);
    }

    /// Responder half of a keyed handshake using a caller-supplied `secret`,
    /// rather than a fresh random one. A host that must reuse this session's
    /// identity later — a three-party handoff recipient signs its
    /// `desc:handoff-receive` with the same key the gifter named as the recipient
    /// — keeps the secret and passes it here so the published session key matches.
    pub fn respondKeyedSessionWithSecret(self: *ConnectedVat, locator: model.PeerLocator, secret: crypto.SecretKey) !void {
        try self.peer.sendKeyedStartSession(.v1_0, locator, secret);
        while (!self.peer.sessionIsOpen()) {
            const progress = try self.conn.pump();
            if (progress == .closed) return Error.ConnectionClosed;
        }
    }

    /// Complete the keyed `op:start-session` handshake from the bound (negotiating)
    /// peer, then pump until the session is open. Signs a `tcp` locator with a
    /// per-connection random session seed; entropy is drawn here, at the I/O
    /// boundary, never in the no-I/O core. The peer must have been built with
    /// [`engine.Peer.initNegotiating`]. [`connectTcp`] calls this for you.
    pub fn openKeyedSession(self: *ConnectedVat) !void {
        var seed: [crypto.SEED_BYTES]u8 = undefined;
        // A successful getrandom returns the byte count; any error returns a
        // wrapped `-errno`, which will not equal the requested length.
        if (std.os.linux.getrandom(&seed, seed.len, 0) != seed.len) return Error.HandshakeEntropyFailed;
        const secret = crypto.SecretKey.fromSeed(seed) catch return Error.HandshakeEntropyFailed;
        // The signed locator is what a partner verifies. A driver-dialed client
        // does not itself listen, so it signs a placeholder `tcp` locator; the
        // session identity is the random key, not the address. A partner that
        // verifies signatures (a Goblins vat) checks the signature over these
        // bytes, not that the address is reachable.
        const locator: model.PeerLocator = .{
            .transport = "tcp",
            .designator = "127.0.0.1:0",
            .hints = model.Hints.emptyFalse(),
        };
        try self.peer.sendKeyedStartSession(.v1_0, locator, secret);
        while (!self.peer.sessionIsOpen()) {
            const progress = try self.conn.pump();
            if (progress == .closed) return Error.ConnectionClosed;
        }
    }

    /// Spawn a local actor at a fresh export position and return a capability to
    /// it. Pass the capability's `nearRef()` as a `send` argument to hand a
    /// partner a callback.
    pub fn spawn(self: *ConnectedVat, comptime Behavior: type, initial: Behavior) !Capability {
        const position = self.next_spawn;
        self.next_spawn += 1;
        const ref = try self.vat.spawn(Behavior, initial);
        try self.vat.publish(ref, position);
        return .{ .position = position };
    }

    /// Publish an actor so a partner can [`fetch`] it by `name` (a swiss-number).
    pub fn publish(self: *ConnectedVat, comptime Behavior: type, initial: Behavior, name: []const u8) !Capability {
        const position = try self.peer.registerBootstrapCap(name);
        const ref = try self.vat.spawn(Behavior, initial);
        try self.vat.publish(ref, position);
        return .{ .position = position };
    }

    /// Eventual-send `msg` to `target` (`<-`), returning a promise to observe
    /// with [`on`]. A far send goes on the wire; the next [`step`]s flush it and
    /// dispatch the reply.
    pub fn send(self: *ConnectedVat, target: actors.Ref, msg: actors.Message) !actors.Promise {
        return self.vat.send(target, msg);
    }

    /// Fire-and-forget eventual-send (`<-np`): enqueue a deliver with no answer,
    /// so a notification costs one deliver and no reply. The next [`step`] flushes
    /// it. Returns nothing — there is no promise to observe.
    pub fn tell(self: *ConnectedVat, target: actors.Ref, msg: actors.Message) !void {
        return self.vat.sendOnly(target, msg);
    }

    /// Register a one-shot listener on `promise`.
    pub fn on(self: *ConnectedVat, promise: actors.Promise, listener: actors.Listener) !void {
        return self.vat.on(promise, listener);
    }

    /// Fetch a partner's published capability by `name`, returning a far `Ref` you
    /// can [`send`] to. Drives the connection (via [`step`]) until the
    /// bootstrap-fetch resolves — explicit, blocking, caller-owned I/O.
    pub fn fetch(self: *ConnectedVat, name: []const u8) !actors.Ref {
        try self.peer.importObject(BOOTSTRAP_POSITION);
        var state = FetchState{};
        const promise = try self.vat.send(
            .{ .far = model.FarRef.object(BOOTSTRAP_POSITION) },
            .{ .verb = "fetch", .args = &.{.{ .bytes = name }} },
        );
        try self.vat.on(promise, .{ .ctx = &state, .func = onFetch });
        while (!state.done) {
            const progress = try self.step();
            if (progress == .closed) return Error.ConnectionClosed;
        }
        if (state.failed) return Error.FetchFailed;
        return .{ .far = state.ref };
    }
};

const FetchState = struct {
    done: bool = false,
    failed: bool = false,
    ref: model.FarRef = undefined,
};

fn onFetch(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const state: *FetchState = @ptrCast(@alignCast(ctx.?));
    state.done = true;
    switch (resolution) {
        .fulfilled => |arg| switch (arg) {
            .reference => |reference| switch (reference) {
                .far => |far_ref| state.ref = far_ref,
                else => state.failed = true,
            },
            else => state.failed = true,
        },
        .broken => state.failed = true,
    }
}

/// Open a TCP connection to `address`, bind a vat to a fresh-wired peer, and
/// return the connected vat. The transport is named here, at the constructor; the
/// returned type is the transport-neutral [`ConnectedVat`]. The caller owns
/// `read_buf` / `write_buf` and the `peer`.
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
