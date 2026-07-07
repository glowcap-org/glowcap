//! The completion-loop fan-out drivers: many connections on one thread.
//!
//! This file owns the scalable counterparts to the blocking, caller-pumped
//! surface in `mod.zig`. `LoopHost` hosts the actor surface on
//! `net.Loop`: it accepts partners, signs every connection's keyed
//! `op:start-session` with one server identity key, and gives each accepted
//! connection its own `actors.Vat`. `LoopDialer` is the outbound counterpart:
//! it dials TCP partners, signs the dialer half of the handshake with a
//! dialer-owned key, and hands each opened connection's application surface to
//! the caller as a `LoopDialer.Client`. Both run application callbacks from
//! the loop's per-event hooks, and both are re-exported from the driver root,
//! so callers reach them as `driver.LoopHost` and `driver.LoopDialer`. Neither
//! adds CapTP semantics the engine lacks, and the shared verbs they ride —
//! `publishNamed`, `spawnAt`, `sendBootstrapFetch`, `drawSessionSecret` — are
//! the driver root's, defined once in `mod.zig`.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");
const actors = @import("actors");
const net = @import("net");

const mod = @import("mod.zig");
const gc = @import("gc.zig");

const crypto = foundation.crypto;

const Capability = mod.Capability;
const drawSessionSecret = mod.drawSessionSecret;
const publishNamed = mod.publishNamed;
const spawnAt = mod.spawnAt;
const sendBootstrapFetch = mod.sendBootstrapFetch;

/// Build one negotiating peer for a loop connection: apply the frame cap, then
/// sign and queue the keyed `op:start-session` for a `tcp` locator naming
/// `designator`. `LoopHost` and `LoopDialer` differ only in the designator
/// they sign (the host's bound port versus the dialer's placeholder), so both
/// `makePeer` hooks call this one definition.
fn makeKeyedPeer(
    allocator: std.mem.Allocator,
    frame_cap: usize,
    verify_partner: bool,
    designator: []const u8,
    secret: crypto.SecretKey,
) !engine.Peer {
    var peer = engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = verify_partner, .limits = .{ .max_frame_bytes = frame_cap } });
    errdefer peer.deinit();
    try peer.sendKeyedStartSession(.v1_0, .{
        .transport = "tcp",
        .designator = designator,
        .hints = model.Hints.emptyFalse(),
    }, secret);
    return peer;
}

/// The serve-hook tail both loop drivers share: run the event through the
/// connection's vat, then emit stateless `op:gc-*` for what this deliver /
/// resolve introduced but the vat did not retain. The loop's own drive flushes
/// the gc frames in the same step that drained the event.
fn serveThroughVat(vat: *actors.Vat, gc_stateless: bool, peer: *engine.Peer, event: *engine.Event) !void {
    _ = try vat.serve(event);
    if (gc_stateless) gc.emitStatelessAfter(peer, event);
}

/// One teardown for both loop drivers' per-connection contexts: deinit the
/// context and free it on the owner's allocator. `Owner` carries `allocator`
/// and an inner `Conn` type with a `deinit`.
fn freeConnCtxFor(comptime Owner: type) net.completion.FreeConnCtx {
    return struct {
        fn free(ctx: ?*anyopaque, conn_ctx: ?*anyopaque) void {
            const self: *Owner = @ptrCast(@alignCast(ctx.?));
            const conn: *Owner.Conn = @ptrCast(@alignCast(conn_ctx.?));
            conn.deinit();
            self.allocator.destroy(conn);
        }
    }.free;
}

/// A connection-fan-out host that runs the actor surface on the completion loop.
/// This is the scalable counterpart to one-connection-per-thread `ConnectedVat`.
///
/// It wraps `net.Loop`, draws one server identity key, and hosts a vat
/// per accepted connection: each connection gets a fresh `actors.Vat` bound to
/// its peer, the application's `publish` callback sets up that connection's
/// objects (typically with `publishNamed`), and every surfaced event runs
/// through `vat.serve` with the reply flushed by the loop. Objects answer through
/// the same nine-verb surface as `ConnectedVat`, but without a thread per
/// connection. The keyed handshake is the responder half: one server identity
/// key, drawn once, signs every connection's `op:start-session`.
///
/// The listening socket binds loopback (127.0.0.1) only; the completion
/// backends do not thread a bind address through, so partners must reach
/// the host on the same machine.
pub const LoopHost = struct {
    /// The application's per-connection setup: publish the objects this fresh
    /// connection serves on its `vat` (e.g. `try publishNamed(vat, "name", App, .{})`).
    pub const Publish = *const fn (ctx: ?*anyopaque, vat: *actors.Vat) anyerror!void;

    pub const Options = struct {
        frame_cap: usize = 1 << 16,
        max_conns: usize = 1024,
        port: u16 = 0,
        /// Verify each partner's keyed start-session signature (the secure
        /// default a real server keeps). Stub-key test clients turn it off.
        verify_partner: bool = true,
        /// Emit `op:gc-exports` / `op:gc-answers` after each inbound deliver /
        /// resolve the connection's vat does not retain imports from, the same
        /// stateless GC `ConnectedVat` offers. This keeps a long-lived fan-out
        /// server's import tables bounded. Crossed-hellos, the other
        /// `ConnectedVat` serve policy, does not apply: a `LoopHost` only accepts
        /// and never dials, so it has no outbound session to collide with an
        /// inbound one.
        gc_stateless: bool = false,
    };

    /// Per-connection context the loop hosts: the connection's vat plus the
    /// serve-policy flags it needs (carried here so the actor-agnostic loop hook
    /// stays one opaque pointer).
    const Conn = struct {
        vat: actors.Vat,
        gc_stateless: bool,

        fn deinit(self: *Conn) void {
            self.vat.deinit();
        }
    };

    loop: net.Loop,
    secret: crypto.SecretKey,
    frame_cap: usize,
    verify_partner: bool,
    gc_stateless: bool,
    publish_fn: Publish,
    publish_ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    designator_buf: [64]u8 = undefined,
    designator_len: usize = 0,

    /// Bind a listening loop host. `io` draws the one server identity seed (at
    /// the I/O boundary, never in the core). The caller owns the returned host at
    /// a stable address. `run` binds the loop's hooks back to it.
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        publish_fn: Publish,
        publish_ctx: ?*anyopaque,
        options: Options,
    ) !LoopHost {
        const secret = try drawSessionSecret(io);

        const loop = try net.Loop.init(allocator, makePeer, null, .{
            .frame_cap = options.frame_cap,
            .max_conns = options.max_conns,
            .listen = options.port,
            .make_conn_ctx = makeConnCtx,
            .serve = serveEvent,
            .free_conn_ctx = freeConnCtxFor(LoopHost),
        });
        var self = LoopHost{
            .loop = loop,
            .secret = secret,
            .frame_cap = options.frame_cap,
            .verify_partner = options.verify_partner,
            .gc_stateless = options.gc_stateless,
            .publish_fn = publish_fn,
            .publish_ctx = publish_ctx,
            .allocator = allocator,
        };
        // The signed locator names the bound port: a dialable `tcp` locator a
        // partner verifies. Stored as bytes (not a slice) so the move out of init
        // cannot dangle. The loop always listens for a host, so the port is set.
        const d = std.fmt.bufPrint(&self.designator_buf, "127.0.0.1:{d}", .{loop.port.?}) catch unreachable;
        self.designator_len = d.len;
        return self;
    }

    pub fn deinit(self: *LoopHost) void {
        self.loop.deinit();
    }

    /// The kernel-chosen bound port (when `Options.port` was 0). A host always
    /// listens, so the loop's bound port is always set.
    pub fn port(self: *const LoopHost) u16 {
        return self.loop.port.?;
    }

    /// Run the loop: `.forever` for a real server, `.{ .after_closed = n }` to
    /// return once `n` connections have fully closed (the test-shaped stop).
    /// Binds the loop's shared context to this now-stable host so the
    /// per-connection hooks can reach the server key, the publish callback, and
    /// the allocator.
    pub fn run(self: *LoopHost, stop: net.completion.Stop) !void {
        self.loop.make_ctx = @ptrCast(self);
        return self.loop.run(stop);
    }

    fn designator(self: *const LoopHost) []const u8 {
        return self.designator_buf[0..self.designator_len];
    }

    fn makePeer(ctx: ?*anyopaque, allocator: std.mem.Allocator) anyerror!engine.Peer {
        const self: *LoopHost = @ptrCast(@alignCast(ctx.?));
        return makeKeyedPeer(allocator, self.frame_cap, self.verify_partner, self.designator(), self.secret);
    }

    fn makeConnCtx(ctx: ?*anyopaque, peer: *engine.Peer) anyerror!?*anyopaque {
        const self: *LoopHost = @ptrCast(@alignCast(ctx.?));
        const conn = try self.allocator.create(Conn);
        errdefer self.allocator.destroy(conn);
        conn.* = .{ .vat = actors.Vat.initOver(self.allocator, peer), .gc_stateless = self.gc_stateless };
        errdefer conn.vat.deinit();
        try self.publish_fn(self.publish_ctx, &conn.vat);
        return conn;
    }

    fn serveEvent(conn_ctx: ?*anyopaque, peer: *engine.Peer, event: *engine.Event) anyerror!void {
        const conn: *Conn = @ptrCast(@alignCast(conn_ctx.?));
        return serveThroughVat(&conn.vat, conn.gc_stateless, peer, event);
    }
};

/// A completion-loop client fan-out driver: the outbound counterpart to
/// `LoopHost`. It owns one `net.Loop`, creates one negotiating peer and
/// actor vat per dialed TCP connection, signs the dialer half of
/// `op:start-session` with a dialer-owned key, and runs application callbacks from
/// the loop's per-event hook. The core protocol layers do not change.
pub const LoopDialer = struct {
    /// The loop slot a dialed connection occupies. Slots are recycled: a
    /// `Slot` is only valid until its connection closes, after which the same
    /// value may name a different connection. `Options.on_close` is where a
    /// connection's end is observed.
    pub const Slot = usize;

    pub const OnOpen = *const fn (ctx: ?*anyopaque, client: *Client) anyerror!void;

    /// Fired once per dialed connection when it fully closes. `client` is the
    /// connection's application surface, or null when the connection failed
    /// before it opened (no vat was ever built for it); `opened` is false for
    /// a dial that never completed its connect, a refused dial is observable
    /// nowhere else, because `dialTcp` returns before the connect resolves.
    pub const OnClose = *const fn (ctx: ?*anyopaque, client: ?*Client, opened: bool) void;

    pub const Options = struct {
        frame_cap: usize = 1 << 16,
        max_conns: usize = 1024,
        /// Verify each responder's keyed start-session signature. Tests that use
        /// stubbed zero signatures can turn this off; real peers keep it on.
        verify_partner: bool = true,
        /// Called once per connection when the keyed session reaches open. The
        /// callback can enqueue fetches, sends, or listeners through `Client`;
        /// the loop flushes that outbound work before the next poll.
        on_open: ?OnOpen = null,
        on_open_ctx: ?*anyopaque = null,
        /// Called once per dialed connection when it fully closes (see
        /// `OnClose`). This is the dialer's failure surface: a refused dial
        /// reports here with `opened == false`.
        on_close: ?OnClose = null,
        on_close_ctx: ?*anyopaque = null,
        gc_stateless: bool = false,
    };

    /// Per-dialed-connection application surface. Methods enqueue work on the
    /// connection's vat; the completion loop drives the wire and fires listeners.
    pub const Client = struct {
        vat: actors.Vat,

        /// Enqueue the bootstrap fetch for `name` (the shared
        /// `sendBootstrapFetch` shape) and fire `listener` when the loop drains
        /// the partner's answer.
        pub fn fetch(self: *Client, name: []const u8, listener: actors.Listener) !void {
            const promise = try sendBootstrapFetch(&self.vat, name);
            try self.vat.on(promise, listener);
        }

        pub fn send(self: *Client, target: actors.Ref, msg: actors.Message) !actors.Promise {
            return self.vat.send(target, msg);
        }

        pub fn on(self: *Client, promise: actors.Promise, listener: actors.Listener) !void {
            return self.vat.on(promise, listener);
        }
    };

    const Conn = struct {
        client: Client,
        /// True once `on_open` has fired for this connection, the callback is
        /// at-most-once even if another `start_session` event arrives.
        on_open_fired: bool = false,
        on_open: ?OnOpen,
        on_open_ctx: ?*anyopaque,
        gc_stateless: bool,

        fn deinit(self: *Conn) void {
            self.client.vat.deinit();
        }
    };

    loop: net.Loop,
    secret: crypto.SecretKey,
    frame_cap: usize,
    verify_partner: bool,
    on_open: ?OnOpen,
    on_open_ctx: ?*anyopaque,
    on_close: ?OnClose,
    on_close_ctx: ?*anyopaque,
    gc_stateless: bool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) !LoopDialer {
        const secret = try drawSessionSecret(io);
        // No `.listen`: a dialer-only loop must not open a socket that accepts
        // strangers under the dialer's identity.
        const loop = try net.Loop.init(allocator, makePeer, null, .{
            .frame_cap = options.frame_cap,
            .max_conns = options.max_conns,
            .make_conn_ctx = makeConnCtx,
            .serve = serveEvent,
            .free_conn_ctx = freeConnCtxFor(LoopDialer),
            .on_close = onConnClose,
        });
        return .{
            .loop = loop,
            .secret = secret,
            .frame_cap = options.frame_cap,
            .verify_partner = options.verify_partner,
            .on_open = options.on_open,
            .on_open_ctx = options.on_open_ctx,
            .on_close = options.on_close,
            .on_close_ctx = options.on_close_ctx,
            .gc_stateless = options.gc_stateless,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LoopDialer) void {
        self.loop.deinit();
    }

    pub fn dialTcp(self: *LoopDialer, address: std.Io.net.IpAddress) !Slot {
        self.loop.make_ctx = @ptrCast(self);
        return self.loop.dialTcp(address);
    }

    /// Run the loop: `.forever` for a long-lived dialer, `.{ .after_closed = n }`
    /// to return once `n` dialed connections have fully closed.
    pub fn run(self: *LoopDialer, stop: net.completion.Stop) !void {
        self.loop.make_ctx = @ptrCast(self);
        return self.loop.run(stop);
    }

    fn makePeer(ctx: ?*anyopaque, allocator: std.mem.Allocator) anyerror!engine.Peer {
        const self: *LoopDialer = @ptrCast(@alignCast(ctx.?));
        // A loop-dialed client does not itself listen, so it signs the
        // placeholder designator; the session identity is the key, not the
        // address, exactly as in `ConnectedVat.openKeyedSession`.
        return makeKeyedPeer(allocator, self.frame_cap, self.verify_partner, mod.unreachable_client_designator, self.secret);
    }

    fn makeConnCtx(ctx: ?*anyopaque, peer: *engine.Peer) anyerror!?*anyopaque {
        const self: *LoopDialer = @ptrCast(@alignCast(ctx.?));
        const conn = try self.allocator.create(Conn);
        errdefer self.allocator.destroy(conn);
        conn.* = .{
            .client = .{
                .vat = actors.Vat.initOver(self.allocator, peer),
            },
            .on_open = self.on_open,
            .on_open_ctx = self.on_open_ctx,
            .gc_stateless = self.gc_stateless,
        };
        return conn;
    }

    fn serveEvent(conn_ctx: ?*anyopaque, peer: *engine.Peer, event: *engine.Event) anyerror!void {
        const conn: *Conn = @ptrCast(@alignCast(conn_ctx.?));
        if (!conn.on_open_fired and event.kind() == .start_session and peer.sessionIsOpen()) {
            conn.on_open_fired = true;
            if (conn.on_open) |open| try open(conn.on_open_ctx, &conn.client);
        }
        return serveThroughVat(&conn.client.vat, conn.gc_stateless, peer, event);
    }

    /// The loop's teardown hook: translate the opaque per-connection context
    /// into the dialer's `Client` surface (null when the connection failed
    /// before it opened, so no context was ever built) and relay to the
    /// application's `on_close`.
    fn onConnClose(ctx: ?*anyopaque, conn_ctx: ?*anyopaque, opened: bool) void {
        const self: *LoopDialer = @ptrCast(@alignCast(ctx.?));
        const on_close = self.on_close orelse return;
        const client: ?*Client = if (conn_ctx) |cc| &@as(*Conn, @ptrCast(@alignCast(cc))).client else null;
        on_close(self.on_close_ctx, client, opened);
    }
};
