//! The socket binding of the sans-io serve core: `ConnectedVat` composes a
//! `driver_core.Served` with a `net.Connection`, the blocking,
//! one-connection-per-thread embedding (ADR-0053). It folds I/O over the core —
//! `step`/`serve`/`stepReadable` read and write the socket and drive the serve
//! loop, and `call`/`fetch` block until a reply settles. A partner that streams
//! without draining belongs on a loop that bounds outbound bytes and parks
//! reads — `net.Loop` at the byte tier, or iroh's `LoopHost` over the sidecar.
//!
//! The constructors bind a `ConnectedVat` over a transport: `connectTcp` and
//! `acceptTcp` name tcp explicitly; `connectVia`, `acceptVia`, and `connectUri`
//! dispatch on the locator's transport symbol against a
//! `[]const net.netlayer.Netlayer`. The owning, one-call `Connection`/`Server`
//! surface lives in `connection.zig`. The serve core and the shared vocabulary
//! (`Error`, `Identity`, `Capability`, `Settled`) live in `driver_core`; the
//! driver root re-exports them and adds the one I/O-boundary verb,
//! `drawSessionSecret`.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");
const actors = @import("actors");
const net = @import("net");

const driver = @import("mod.zig");
const Error = driver.Error;
const Identity = driver.Identity;
const Capability = driver.Capability;
const Settled = driver.Settled;
const drawSessionSecret = driver.drawSessionSecret;
const Served = driver.Served;

const crypto = foundation.crypto;

/// A vat bound to a live connection: a `Served` serve core plus an owned
/// `net.Connection`. The blocking, transport-neutral, one-fiber embedding
/// (ADR-0053): it serves cooperative request/response, where each side drains
/// the replies it asked for. The vat verbs delegate to the core; the socket
/// verbs (`step`/`serve`/`flush`/`call`/`fetch`) fold I/O over it.
pub const ConnectedVat = struct {
    served: Served,
    conn: net.Connection,

    /// Bind a vat to an existing connection over `peer`. Transport-neutral: the
    /// connection may ride any stream.
    pub fn over(allocator: std.mem.Allocator, peer: *engine.Peer, conn: net.Connection) ConnectedVat {
        return .{ .served = Served.over(allocator, peer), .conn = conn };
    }

    /// Tear down the serve core and close the connection. Does not free the
    /// borrowed peer.
    pub fn deinit(self: *ConnectedVat) void {
        self.served.deinit();
        self.conn.deinit();
    }

    /// The partner's retained abort diagnostic, or null (see `Served.abortReason`).
    pub fn abortReason(self: *const ConnectedVat) ?[]const u8 {
        return self.served.abortReason();
    }

    /// One pump cycle: dispatch queued events, drive the connection one step (one
    /// read and/or one flush), then dispatch every event the peer surfaced. A
    /// deliver runs its published actor and resolves the answer; a resolve fires
    /// a far vow's listener. Returns the connection's `Progress` so the caller's
    /// loop can act on `.closed`. I/O is visible here: the pump reads and writes
    /// the socket.
    ///
    /// When the pump reports `.closed`, every far vow still awaiting a partner's
    /// resolution is broken — those resolutions ride the wire that just went
    /// away — carrying the partner's retained abort diagnostic when one arrived.
    pub fn step(self: *ConnectedVat) !net.Progress {
        try self.served.drainEvents();
        const progress = try self.conn.pump();
        try self.served.drainEvents();
        if (progress == .closed) self.served.vat.breakFarVows(self.served.closeReason("connection closed"));
        return progress;
    }

    /// Serve the connection until the partner leaves: run `step` until the pump
    /// reports `.closed`. A partner that drops the socket without a clean shutdown
    /// (`error.ConnectionLost`, `error.TruncatedFrame`) has still left, so serve
    /// breaks the waiting far vows and returns normally, as it does for a graceful
    /// close. Every other error propagates.
    pub fn serve(self: *ConnectedVat) !void {
        while (true) {
            const progress = self.step() catch |err| switch (err) {
                error.ConnectionLost, error.TruncatedFrame => {
                    self.served.vat.breakFarVows(self.served.closeReason("connection lost"));
                    return;
                },
                else => return err,
            };
            if (progress == .closed) return;
        }
    }

    /// Dispatch any queued events and flush the resulting outbound, without
    /// reading. `settle` runs it before parking on the socket, so a far
    /// deliver leaves the wire before the blocking read — and a local-target
    /// vow settles inside the flush's own drive without touching the socket
    /// at all.
    pub fn flush(self: *ConnectedVat) !void {
        try self.served.drainEvents();
        try self.conn.flush();
        try self.served.drainEvents();
    }

    /// Poll-guarded `step`: flush outbound, then wait up to `timeout_ms` for the
    /// socket to become readable. Returns the pump `Progress` once data is ready
    /// (or already buffered), or null on timeout. A poll failure on the fd means
    /// the transport is gone, so it surfaces as `error.ConnectionLost`. The
    /// blocking `step` stays the primitive; `stepReadable` is the multiplexing
    /// convenience over it.
    pub fn stepReadable(self: *ConnectedVat, timeout_ms: i32) !?net.Progress {
        try self.flush();
        if (!try self.conn.waitReadable(timeout_ms)) return null;
        return try self.step();
    }

    /// Run one half of the keyed handshake with a fresh session secret: draw the
    /// secret, sign `locator`, send `op:start-session`, then pump until the
    /// session opens. Both halves run this same exchange; only the locator each
    /// side signs differs.
    pub fn startKeyedSession(self: *ConnectedVat, locator: model.PeerLocator) !void {
        const secret = try drawSessionSecret(self.conn.io);
        try self.startKeyedSessionWithSecret(locator, secret);
    }

    /// One keyed `op:start-session` half with a caller-supplied `locator` and
    /// `secret`: sign, send, and pump until the session opens. The parameterized
    /// primitive both handshake halves run. A three-party handoff recipient signs
    /// its `desc:handoff-receive` with the same key the gifter named, and a dialer
    /// that also listens signs its real dialable locator rather than the
    /// placeholder. The peer must have been built with `engine.Peer.initNegotiating`.
    pub fn startKeyedSessionWithSecret(self: *ConnectedVat, locator: model.PeerLocator, secret: crypto.SecretKey) !void {
        try self.served.peer.sendKeyedStartSession(.v1_0, locator, secret);
        while (!self.served.peer.sessionIsOpen()) {
            const progress = try self.conn.pump();
            if (progress == .closed) return Error.ConnectionClosed;
        }
    }

    /// Complete the keyed handshake from the bound (negotiating) peer over tcp,
    /// then pump until the session opens. A driver-dialed client does not itself
    /// listen, so it signs a placeholder `tcp` locator and the session identity is
    /// the key, not the address. `connectTcp` calls this for you; the
    /// transport-neutral dialer is `connectVia`.
    pub fn openKeyedSession(self: *ConnectedVat) !void {
        try self.startKeyedSession(.{
            .transport = "tcp",
            .designator = driver.unreachable_client_designator,
            .hints = model.Hints.emptyFalse(),
        });
    }

    // ── Vat verbs (delegate to the serve core) ───────────────────────────────

    /// Spawn a local actor and return a capability to it (see `Served.spawn`).
    pub fn spawn(self: *ConnectedVat, comptime Behavior: type, initial: Behavior) !Capability {
        return self.served.spawn(Behavior, initial);
    }

    /// Publish an actor a partner can `fetch` by `name` (see `Served.publish`).
    pub fn publish(self: *ConnectedVat, name: []const u8, comptime Behavior: type, initial: Behavior) !Capability {
        return self.served.publish(name, Behavior, initial);
    }

    /// Eventual-send `msg` to `target` (see `Served.send`).
    pub fn send(self: *ConnectedVat, target: actors.Ref, msg: actors.Message) !actors.Vow {
        return self.served.send(target, msg);
    }

    /// Promise pipelining against a far `vow` (see `Served.sendToAnswer`).
    pub fn sendToAnswer(self: *ConnectedVat, vow: actors.Vow, msg: actors.Message) !actors.Vow {
        return self.served.sendToAnswer(vow, msg);
    }

    /// Fire-and-forget eventual-send (see `Served.tell`).
    pub fn tell(self: *ConnectedVat, target: actors.Ref, msg: actors.Message) !void {
        return self.served.tell(target, msg);
    }

    /// Register a one-shot listener on `vow` (see `Served.on`).
    pub fn on(self: *ConnectedVat, vow: actors.Vow, listener: actors.Listener) !void {
        return self.served.on(vow, listener);
    }

    // ── Blocking request/reply (fold I/O over the core) ──────────────────────

    /// Drive the connection until `vow` settles, materializing the outcome into
    /// `arena` — the building block pipelining needs. `call` is this fused onto a
    /// single `send`. Returns `ConnectionClosed` if the partner leaves first.
    pub fn settleVow(self: *ConnectedVat, vow: actors.Vow, arena: std.mem.Allocator) !Settled {
        var capture = driver.SettleCapture{ .arena = arena };
        try self.settle(vow, .{ .ctx = &capture, .func = driver.SettleCapture.fire });
        return capture.finish();
    }

    /// Eventual-send `msg` to `target` and drive with `step` until the reply
    /// settles, materializing both `Settled` arms into caller-owned `arena` (so
    /// the result borrows nothing from the settling turn). Returns
    /// `ConnectionClosed` if the partner leaves before the reply settles.
    pub fn call(self: *ConnectedVat, target: actors.Ref, msg: actors.Message, arena: std.mem.Allocator) !Settled {
        const vow = try self.served.send(target, msg);
        return self.settleVow(vow, arena);
    }

    /// Fetch a partner's published capability by `name`, returning a far `Ref`.
    /// A fulfilled fetch yields a far ref; an unpublished name returns
    /// `Error.FetchBroken`, and any other fulfill returns
    /// `Error.FetchNotACapability`. Allocates nothing and retains no break reason;
    /// `fetchSettled` is the reason-bearing form.
    pub fn fetch(self: *ConnectedVat, name: []const u8) !actors.Ref {
        var state = driver.FetchCapture{};
        const vow = try self.served.sendBootstrapFetch(name);
        try self.settle(vow, .{ .ctx = &state, .func = driver.FetchCapture.record });
        return switch (state.outcome orelse return Error.ConnectionClosed) {
            .capability => |far_ref| .{ .far = far_ref },
            .broken => Error.FetchBroken,
            .not_a_capability => Error.FetchNotACapability,
        };
    }

    /// The reason-bearing fetch: the same bootstrap fetch as `fetch`, returning
    /// the partner's settlement whole as a `Settled` materialized into `arena`.
    pub fn fetchSettled(self: *ConnectedVat, name: []const u8, arena: std.mem.Allocator) !Settled {
        const vow = try self.served.sendBootstrapFetch(name);
        return self.settleVow(vow, arena);
    }

    /// Drive the connection with `step` until `vow` settles into `listener`: the
    /// shared blocking tail of `call` and `fetch`.
    fn settle(self: *ConnectedVat, vow: actors.Vow, listener: actors.Listener) !void {
        var settle_state = driver.SettleFlag{ .inner = listener };
        try self.served.vat.on(vow, .{ .ctx = &settle_state, .func = driver.SettleFlag.fire });
        // Flush before blocking on a read: a far deliver goes on the wire one
        // syscall earlier, and a local-target vow settles in the flush's drive
        // without touching the socket at all — a read would otherwise block
        // forever on a reply the partner was never asked for.
        self.flush() catch |err| switch (err) {
            error.ConnectionLost, error.TruncatedFrame => {
                self.served.vat.breakFarVows(self.served.closeReason("connection lost"));
                return Error.ConnectionClosed;
            },
            else => {
                self.served.vat.breakFarVows("connection failed");
                return err;
            },
        };
        if (settle_state.done) return;
        while (!settle_state.done) {
            // A transport fault is the partner leaving, exactly as in serve():
            // break the far vows (which fires this call's listener broken and
            // removes it, so the stack-bound listener can't dangle on the vat)
            // and report the close, rather than propagating the raw fault.
            const progress = self.step() catch |err| switch (err) {
                error.ConnectionLost, error.TruncatedFrame => {
                    self.served.vat.breakFarVows(self.served.closeReason("connection lost"));
                    return Error.ConnectionClosed;
                },
                // Any other step failure (protocol abort, OOM) also ends this
                // call, so the stack-bound listener must come off the vat the
                // same way — a later turn firing it would write into a dead
                // frame. The vows break now, while `settle_state` is still alive.
                else => {
                    self.served.vat.breakFarVows("connection failed");
                    return err;
                },
            };
            // A partner may answer and close in the same step: a settled vow is
            // a settled call, so the real resolution wins over the close.
            if (settle_state.done) return;
            // `step` already broke the far vows on a clean close (firing this
            // call's listener); just report it.
            if (progress == .closed) return Error.ConnectionClosed;
        }
    }
};

/// Open a TCP connection to `address`, bind a vat to a fresh-wired peer, and
/// return the connected vat. The transport is named here, at the constructor;
/// the returned type is the transport-neutral `ConnectedVat`. The caller owns
/// `read_buf` / `write_buf` and the `peer`: the buffers size the steady state,
/// not the largest admissible frame. An inbound frame larger than `read_buf`
/// assembles once in the connection's bounded spill (ADR-0041); an outbound
/// frame larger than `write_buf` streams straight through. The one-call
/// `connect` derives buffers and the session limit from a single `frame_cap`.
pub fn connectTcp(
    allocator: std.mem.Allocator,
    io: std.Io,
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
/// return the connected vat: the server-side counterpart of `connectTcp`. Buffer
/// sizing follows the same contract. The keyed responder handshake (fresh random
/// session key) completes before this returns, signing the listener's bound
/// address — the address a partner can actually dial. A host that must reuse the
/// session identity (a three-party handoff recipient) builds the vat with
/// `ConnectedVat.over` and calls `startKeyedSessionWithSecret` itself.
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
/// with `identity`. The transport-neutral dialer: the locator's `transport`
/// symbol selects the netlayer that hosts it in `netlayers` at runtime, failing
/// closed with `Error.UnknownTransport` when none does. `identity` is the one
/// signing seam: `.ephemeral` draws a fresh random session key and advertises no
/// dialable designator, and `.keyed` signs with a caller-held key over the
/// dialer's own designator. The caller owns `peer`, `read_buf`, and `write_buf`;
/// `netlayers` must outlive the returned vat. `connectTcp` is the tcp-named
/// convenience over the same machinery.
pub fn connectVia(
    allocator: std.mem.Allocator,
    netlayers: []const net.netlayer.Netlayer,
    peer: *engine.Peer,
    locator: model.PeerLocator,
    identity: Identity,
    read_buf: []u8,
    write_buf: []u8,
) !ConnectedVat {
    const nl = net.netlayer.resolve(netlayers, locator.transport) orelse return Error.UnknownTransport;
    // The dial-side identity pin: on a key-designator transport the dialed
    // designator *is* the partner's key, so pin the peer to it before the
    // handshake pump — the engine then refuses an `op:start-session` signed by
    // any other key (`PartnerKeyMismatch`), fail-closed, before the session
    // opens. This is what makes a keyed-tcp (or iroh) designator trustworthy
    // to re-dial: whoever answers must prove the key the locator named.
    if (nl.designatorScheme() == .key) {
        const expected = crypto.PeerKey.fromDesignator(locator.designator) orelse
            return error.InvalidAddress;
        peer.expectPartnerKey(expected);
    }
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

/// Dial an `ocapn://` URI in one call: parse it into a `model.PeerLocator` and
/// dial through `connectVia` against the caller's `netlayers`. `netlayers` is the
/// caller's because the residents behind it can hold state that must outlive the
/// returned vat. A URI naming a transport no netlayer hosts fails closed with
/// `Error.UnknownTransport`. `identity` is the same signing seam `connectVia`
/// takes. The parsed locator is freed before returning, because `connectVia`
/// copies what the session retains during the handshake.
pub fn connectUri(
    allocator: std.mem.Allocator,
    netlayers: []const net.netlayer.Netlayer,
    peer: *engine.Peer,
    uri_str: []const u8,
    identity: Identity,
    read_buf: []u8,
    write_buf: []u8,
) !ConnectedVat {
    const locator = try model.uri.parsePeer(allocator, uri_str);
    defer model.freePeerLocator(allocator, locator);
    return connectVia(allocator, netlayers, peer, locator, identity, read_buf, write_buf);
}

/// Accept one partner through a contract `net.netlayer.Listener`, bind a vat, and
/// complete the responder handshake signing with `identity`: the
/// transport-neutral hosting counterpart of `connectVia`. `acceptTcp` is the
/// tcp-named convenience. A host is always reachable, so the signed designator
/// names this listener; what that designator *is* follows the listener's
/// scheme. On an `.address` listener it is the bound address, and `identity`
/// chooses only the signing key (`.ephemeral` fresh random, `.keyed` a
/// caller-held key). On a `.key` listener the designator derives from the
/// signing secret itself — its public key's canonical hex, so designator and
/// session key cannot disagree — with the listener's dial hint (keyed-tcp's
/// bound `host:port`) riding as the locator's `direct-addresses` hint; an
/// `.ephemeral` identity is refused there
/// (`Error.EphemeralIdentityOnKeyedTransport`), because a throwaway key cannot
/// produce the durable designator the transport advertises.
pub fn acceptVia(
    allocator: std.mem.Allocator,
    listener: net.netlayer.Listener,
    peer: *engine.Peer,
    identity: driver.AcceptIdentity,
    read_buf: []u8,
    write_buf: []u8,
) !ConnectedVat {
    const conn = try listener.accept(peer, .{ .read = read_buf, .write = write_buf });
    var vat = ConnectedVat.over(allocator, peer, conn);
    errdefer vat.deinit();
    switch (listener.designatorScheme()) {
        .address => {
            var designator_buf: [64]u8 = undefined;
            const self_locator: model.PeerLocator = .{
                .transport = listener.transportName(),
                .designator = listener.localDesignator(&designator_buf),
                .hints = model.Hints.emptyFalse(),
            };
            switch (identity) {
                .ephemeral => try vat.startKeyedSession(self_locator),
                .keyed => |secret| try vat.startKeyedSessionWithSecret(self_locator, secret),
            }
        },
        .key => {
            const secret = switch (identity) {
                .keyed => |secret| secret,
                .ephemeral => return Error.EphemeralIdentityOnKeyedTransport,
            };
            // Derived from the signing secret, not read back from the
            // listener, so designator ≡ session key by construction — the
            // responder half of the invariant the dial-side pin verifies.
            const designator = secret.publicKey().toDesignator();
            var hint_buf: [net.tcp.designator_buf_len]u8 = undefined;
            const hint = listener.localHint(&hint_buf);
            const hint_entries = [_]model.HintEntry{.{
                .name = net.netlayer.hint_direct_addresses,
                .value = .{ .string = hint },
            }};
            const self_locator: model.PeerLocator = .{
                .transport = listener.transportName(),
                .designator = designator[0..],
                // A hint-less key listener (iroh) keeps the `#f` empty-hints
                // spelling its signed locator has always carried.
                .hints = if (hint.len == 0) model.Hints.emptyFalse() else .{ .entries = &hint_entries },
            };
            try vat.startKeyedSessionWithSecret(self_locator, secret);
        },
    }
    return vat;
}
