//! The socket binding of the sans-io serve core: `BlockingSession` composes a
//! `driver_core.Served` with a `net.Connection`, the blocking,
//! one-connection-per-thread embedding (ADR-0053). It folds I/O over the core —
//! `step`/`serve`/`stepReadable` read and write the socket and drive the serve
//! loop, and `call`/`fetch` block until a reply settles. A partner that streams
//! without draining belongs on a loop that bounds outbound bytes and parks
//! reads — `net.TcpLoop` at the byte tier, or `completion.Loop(iroh.Backend, iroh.DialResolver)`
//! over the sidecar.
//!
//! The constructors bind a `BlockingSession` over a transport: `connectTcp` and
//! `acceptTcp` name tcp explicitly; `connectVia`, `acceptVia`, and `connectUri`
//! dispatch on the locator's transport symbol against a
//! `[]const net.netlayer.Netlayer`. The owning, one-call `Session`/`Server`
//! surface lives in `session.zig`. The serve core and the shared vocabulary
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

/// A vat bound to a live `net.Connection`: a `Served` serve core plus an owned
/// framed byte stream. The blocking, transport-neutral, one-fiber embedding
/// (ADR-0053): it serves cooperative request/response, where each side drains
/// the replies it asked for. The vat verbs delegate to the core; the socket
/// verbs (`step`/`serve`/`flush`/`call`/`fetch`) fold I/O over it.
pub const BlockingSession = struct {
    served: Served,
    conn: net.Connection,

    /// An opt-in per-read deadline for the keyed handshake pump, in
    /// milliseconds; 0 (the default) leaves the handshake unbounded, the prior
    /// behavior. When set, `startKeyedSession*` bounds each handshake read on
    /// `conn.waitReadable` and breaks with `Error.HandshakeTimedOut` if a
    /// partner finishes connect and then goes silent — the slowloris a
    /// one-connection-per-thread accept must not park on (ADR-0081). The value
    /// is the caller's policy. It binds fd-backed transports (tcp, keyed-tcp); a
    /// userspace-multiplexed transport (iroh) has no pollable fd to bound here.
    handshake_timeout_ms: i32 = 0,

    /// An opt-in wall-clock deadline for blocking answer-waits (`settle` /
    /// `call` / `fetch`), in milliseconds; 0 (the default) leaves them
    /// unbounded. When set, a partner that opens then never settles breaks
    /// with `Error.WaitTimedOut` instead of parking the fiber forever
    /// (ADR-0076). Same fd-backed binding as `handshake_timeout_ms`.
    settle_timeout_ms: i32 = 0,

    /// Bind a vat to an existing `net.Connection` over `peer`. Transport-neutral:
    /// the stream may ride any netlayer.
    pub fn over(allocator: std.mem.Allocator, peer: *engine.Peer, conn: net.Connection) BlockingSession {
        return .{ .served = Served.over(allocator, peer), .conn = conn };
    }

    /// Tear down the serve core and close the connection. Does not free the
    /// borrowed peer.
    pub fn deinit(self: *BlockingSession) void {
        self.served.deinit();
        self.conn.deinit();
    }

    /// The partner's retained abort, or null (see `Served.partnerAbort`).
    pub fn partnerAbort(self: *const BlockingSession) ?Served.PartnerAbortView {
        return self.served.partnerAbort();
    }

    /// The partner's retained abort diagnostic, or null (see `Served.abortReason`).
    pub fn abortReason(self: *const BlockingSession) ?[]const u8 {
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
    pub fn step(self: *BlockingSession) !net.Progress {
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
    pub fn serve(self: *BlockingSession) !void {
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
    pub fn flush(self: *BlockingSession) !void {
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
    pub fn stepReadable(self: *BlockingSession, timeout_ms: i32) !?net.Progress {
        try self.flush();
        if (!try self.conn.waitReadable(timeout_ms)) return null;
        return try self.step();
    }

    /// Run one half of the keyed handshake with a fresh session secret: draw the
    /// secret, sign `locator`, send `op:start-session`, then pump until the
    /// session opens. Both halves run this same exchange; only the locator each
    /// side signs differs.
    pub fn startKeyedSession(self: *BlockingSession, locator: model.PeerLocator) !void {
        const secret = try drawSessionSecret(self.conn.io);
        try self.startKeyedSessionWithSecret(locator, secret);
    }

    /// One keyed `op:start-session` half with a caller-supplied `locator` and
    /// `secret`: sign, send, and pump until the session opens. The parameterized
    /// primitive both handshake halves run. A three-party handoff recipient signs
    /// its `desc:handoff-receive` with the same key the gifter named, and a dialer
    /// that also listens signs its real dialable locator rather than the
    /// placeholder. The peer must have been built with `engine.Peer.initNegotiating`.
    pub fn startKeyedSessionWithSecret(self: *BlockingSession, locator: model.PeerLocator, secret: crypto.SecretKey) !void {
        try self.served.peer.sendKeyedStartSession(.v1_0, locator, secret);
        if (self.handshake_timeout_ms != 0) {
            const progress = self.conn.runUntil(sessionOpenPred, self.handshake_timeout_ms) catch |err| switch (err) {
                error.Timeout => return Error.HandshakeTimedOut,
                else => |e| return e,
            };
            if (progress == .closed) return Error.ConnectionClosed;
            return;
        }
        while (!self.served.peer.sessionIsOpen()) {
            const progress = try self.conn.pump();
            if (progress == .closed) return Error.ConnectionClosed;
        }
    }

    // ── Vat verbs (delegate to the serve core) ───────────────────────────────

    /// Spawn a local actor and return a capability to it (see `Served.spawn`).
    pub fn spawn(self: *BlockingSession, comptime Behavior: type, initial: Behavior) !Capability {
        return self.served.spawn(Behavior, initial);
    }

    /// Publish an actor a partner can `fetch` by `name` (see `Served.publish`).
    pub fn publish(self: *BlockingSession, name: []const u8, comptime Behavior: type, initial: Behavior) !Capability {
        return self.served.publish(name, Behavior, initial);
    }

    /// Eventual-send `msg` to `target` (see `Served.send`).
    pub fn send(self: *BlockingSession, target: actors.Ref, msg: actors.Message) !actors.Vow {
        return self.served.send(target, msg);
    }

    /// Promise pipelining against a far `vow` (see `Served.sendToAnswer`).
    pub fn sendToAnswer(self: *BlockingSession, vow: actors.Vow, msg: actors.Message) !actors.Vow {
        return self.served.sendToAnswer(vow, msg);
    }

    /// Fire-and-forget eventual-send (see `Served.tell`).
    pub fn tell(self: *BlockingSession, target: actors.Ref, msg: actors.Message) !void {
        return self.served.tell(target, msg);
    }

    /// Register a one-shot listener on `vow` (see `Served.on`).
    pub fn on(self: *BlockingSession, vow: actors.Vow, listener: actors.Listener) !void {
        return self.served.on(vow, listener);
    }

    // ── Blocking request/reply (fold I/O over the core) ──────────────────────

    /// Drive the connection until `vow` settles, materializing the outcome into
    /// `arena` — the building block pipelining needs. `call` is this fused onto a
    /// single `send`. Returns `ConnectionClosed` if the partner leaves first.
    pub fn settleVow(self: *BlockingSession, vow: actors.Vow, arena: std.mem.Allocator) !Settled {
        var capture = driver.SettleCapture{ .arena = arena };
        try self.settle(vow, .{ .ctx = &capture, .func = driver.SettleCapture.fire });
        return capture.finish();
    }

    /// Eventual-send `msg` to `target` and drive with `step` until the reply
    /// settles, materializing both `Settled` arms into caller-owned `arena` (so
    /// the result borrows nothing from the settling turn). Returns
    /// `ConnectionClosed` if the partner leaves before the reply settles.
    pub fn call(self: *BlockingSession, target: actors.Ref, msg: actors.Message, arena: std.mem.Allocator) !Settled {
        const vow = try self.served.send(target, msg);
        return self.settleVow(vow, arena);
    }

    /// Start a bootstrap fetch without driving the socket. The caller registers
    /// a listener (`on`) and pumps (`step` / `stepReadable`) until the vow
    /// settles — the non-blocking twin of `fetch` / `fetchSettled` for a
    /// multiplexed event loop (CapTP lab TUI).
    pub fn beginFetch(self: *BlockingSession, name: []const u8) !actors.Vow {
        return self.served.sendBootstrapFetch(name);
    }

    /// Break every far vow still awaiting a partner answer (cancel / timeout /
    /// teardown). Stable `message` bytes are what listeners observe as the
    /// broken reason; pass a string literal.
    pub fn breakFarVows(self: *BlockingSession, message: []const u8) void {
        self.served.vat.breakFarVows(message);
    }

    /// Fetch a partner's published capability by `name`, returning a far `Ref`.
    /// A fulfilled fetch yields a far ref; an unpublished name returns
    /// `Error.FetchBroken`, and any other fulfill returns
    /// `Error.FetchNotACapability`. Allocates nothing and retains no break reason;
    /// `fetchSettled` is the reason-bearing form.
    pub fn fetch(self: *BlockingSession, name: []const u8) !actors.Ref {
        var state = driver.FetchCapture{};
        const vow = try self.beginFetch(name);
        try self.settle(vow, .{ .ctx = &state, .func = driver.FetchCapture.record });
        return switch (state.outcome orelse return Error.ConnectionClosed) {
            .capability => |far_ref| .{ .far = far_ref },
            .broken => Error.FetchBroken,
            .not_a_capability => Error.FetchNotACapability,
        };
    }

    /// The reason-bearing fetch: the same bootstrap fetch as `fetch`, returning
    /// the partner's settlement whole as a `Settled` materialized into `arena`.
    pub fn fetchSettled(self: *BlockingSession, name: []const u8, arena: std.mem.Allocator) !Settled {
        const vow = try self.served.sendBootstrapFetch(name);
        return self.settleVow(vow, arena);
    }

    /// Drive the connection with `step` until `vow` settles into `listener`: the
    /// shared blocking tail of `call` and `fetch`.
    /// Map a fault on a blocking wait to the error to return, breaking the far
    /// vows first — the one place the flush-catch and step-catch in `settle`
    /// share. A clean transport loss (`ConnectionLost` / `TruncatedFrame`) is
    /// the partner leaving: break with the close reason and report the typed
    /// `ConnectionClosed`. Any other fault (protocol abort, OOM) breaks with a
    /// generic reason and propagates the raw error. `serve` deliberately does
    /// NOT ride this: it returns void and does not break on the non-transport
    /// arm — its caller's `deinit` breaks the vows — so its divergence stays
    /// explicit inline.
    fn faultToClosed(self: *BlockingSession, err: anyerror) anyerror {
        switch (err) {
            error.ConnectionLost, error.TruncatedFrame => {
                self.served.vat.breakFarVows(self.served.closeReason("connection lost"));
                return Error.ConnectionClosed;
            },
            else => {
                self.served.vat.breakFarVows("connection failed");
                return err;
            },
        }
    }

    fn settle(self: *BlockingSession, vow: actors.Vow, listener: actors.Listener) !void {
        var settle_state = driver.SettleFlag{ .inner = listener };
        try self.served.vat.on(vow, .{ .ctx = &settle_state, .func = driver.SettleFlag.fire });
        // Flush before blocking on a read: a far deliver goes on the wire one
        // syscall earlier, and a local-target vow settles in the flush's drive
        // without touching the socket at all — a read would otherwise block
        // forever on a reply the partner was never asked for.
        self.flush() catch |err| return self.faultToClosed(err);
        if (settle_state.done) return;

        const deadline_ms = self.settle_timeout_ms;
        const start_ms: i64 = if (deadline_ms != 0) milliTimestamp() else 0;

        while (!settle_state.done) {
            if (deadline_ms != 0) {
                const elapsed = milliTimestamp() - start_ms;
                if (elapsed >= deadline_ms) {
                    // Take the stack-bound listener off the vat before returning.
                    self.served.vat.breakFarVows("wait timed out");
                    return Error.WaitTimedOut;
                }
                const remaining_i64 = deadline_ms - elapsed;
                const remaining: i32 = if (remaining_i64 > std.math.maxInt(i32))
                    std.math.maxInt(i32)
                else
                    @intCast(remaining_i64);
                const progress = self.stepReadable(remaining) catch |err| return self.faultToClosed(err);
                if (progress == null) {
                    self.served.vat.breakFarVows("wait timed out");
                    return Error.WaitTimedOut;
                }
                if (settle_state.done) return;
                if (progress.? == .closed) return Error.ConnectionClosed;
                continue;
            }
            // A transport fault is the partner leaving, exactly as in serve():
            // break the far vows (which fires this call's listener broken and
            // removes it, so the stack-bound listener can't dangle on the vat)
            // and report the close, rather than propagating the raw fault.
            // A transport fault or any other step failure ends this call the
            // same way (see `faultToClosed`): the stack-bound listener must come
            // off the vat now — a later turn firing it would write into a dead
            // frame — so the vows break while `settle_state` is still alive.
            const progress = self.step() catch |err| return self.faultToClosed(err);
            // A partner may answer and close in the same step: a settled vow is
            // a settled call, so the real resolution wins over the close.
            if (settle_state.done) return;
            // `step` already broke the far vows on a clean close (firing this
            // call's listener); just report it.
            if (progress == .closed) return Error.ConnectionClosed;
        }
    }
};

/// The handshake pump's completion predicate: the session has opened. A
/// file-scope function so `conn.runUntil` can take it by pointer.
fn sessionOpenPred(peer: *engine.Peer) bool {
    return peer.sessionIsOpen();
}

/// Wall-clock milliseconds since the Unix epoch for settle deadlines.
fn milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    switch (std.posix.errno(std.posix.system.clock_gettime(std.posix.CLOCK.REALTIME, &ts))) {
        .SUCCESS => {},
        else => return 0,
    }
    return @as(i64, @intCast(ts.sec)) * std.time.ms_per_s +
        @divFloor(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

/// Open a TCP connection to `address`, bind a vat to a fresh-wired peer, and
/// return the connected vat. The transport is named here, at the constructor;
/// the returned type is the transport-neutral `BlockingSession`. The caller owns
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
) !BlockingSession {
    // Same spine as `connectVia`: netlayer dial + Identity.ephemeral hello.
    // The Resident only needs to outlive the dial call; the connection owns
    // the stream afterward.
    var resident = net.tcp.Resident{ .io = io };
    const netlayers = [_]net.netlayer.Netlayer{resident.netlayer()};
    var designator_buf: [net.tcp.designator_buf_len]u8 = undefined;
    return connectVia(
        allocator,
        &netlayers,
        peer,
        net.tcp.locator(&designator_buf, address),
        .ephemeral,
        read_buf,
        write_buf,
        0,
    );
}

/// Accept one TCP partner on `listener`, bind a vat to a fresh-wired peer, and
/// return the connected vat: the server-side counterpart of `connectTcp`. Buffer
/// sizing follows the same contract. The keyed responder handshake (fresh random
/// session key) completes before this returns, signing the listener's bound
/// address — the address a partner can actually dial. A host that must reuse the
/// session identity (a three-party handoff recipient) builds the vat with
/// `BlockingSession.over` and calls `startKeyedSessionWithSecret` itself.
pub fn acceptTcp(
    allocator: std.mem.Allocator,
    peer: *engine.Peer,
    listener: *net.tcp.Listener,
    read_buf: []u8,
    write_buf: []u8,
) !BlockingSession {
    // Same spine as `acceptVia`: contract listener + AcceptIdentity.ephemeral.
    // The typed tcp.Listener is borrowed for the call; the caller still owns it.
    return acceptVia(allocator, listener.asNetlayer(), peer, .ephemeral, read_buf, write_buf, 0);
}

/// Dial a locator through the netlayer contract, signing the keyed handshake
/// with `identity`. The transport-neutral dialer: the locator's `transport`
/// symbol selects the netlayer that hosts it in `netlayers` at runtime, failing
/// closed with `Error.UnknownTransport` when none does. `identity` is the one
/// signing seam: `.ephemeral` draws a fresh random session key and signs the
/// unreachable-client placeholder as its own designator, and `.keyed` signs
/// with a caller-held key over the dialer's own designator. The caller owns
/// `peer`, `read_buf`, and `write_buf`; `netlayers` must outlive the returned
/// vat. `connectTcp` is the tcp-named convenience over this same path.
/// `handshake_timeout_ms` bounds each handshake read (0 leaves it unbounded);
/// see `BlockingSession.handshake_timeout_ms` (ADR-0081).
pub fn connectVia(
    allocator: std.mem.Allocator,
    netlayers: []const net.netlayer.Netlayer,
    peer: *engine.Peer,
    locator: model.PeerLocator,
    identity: Identity,
    read_buf: []u8,
    write_buf: []u8,
    handshake_timeout_ms: i32,
) !BlockingSession {
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
    var vat = BlockingSession.over(allocator, peer, conn);
    vat.handshake_timeout_ms = handshake_timeout_ms;
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
) !BlockingSession {
    const locator = try model.uri.parsePeer(allocator, uri_str);
    defer model.freePeerLocator(allocator, locator);
    return connectVia(allocator, netlayers, peer, locator, identity, read_buf, write_buf, 0);
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
/// produce the durable designator the transport advertises. The accept side is
/// the slowloris target — a dialer that completes connect and then never speaks
/// would park a one-connection-per-thread accepter for the connection's life —
/// so `handshake_timeout_ms` bounds each handshake read (0 leaves it unbounded);
/// `Server.accept` threads it from `SessionOptions.handshake_timeout_ms`
/// (ADR-0081).
pub fn acceptVia(
    allocator: std.mem.Allocator,
    listener: net.netlayer.Listener,
    peer: *engine.Peer,
    identity: driver.AcceptIdentity,
    read_buf: []u8,
    write_buf: []u8,
    handshake_timeout_ms: i32,
) !BlockingSession {
    const conn = try listener.accept(peer, .{ .read = read_buf, .write = write_buf });
    var vat = BlockingSession.over(allocator, peer, conn);
    vat.handshake_timeout_ms = handshake_timeout_ms;
    errdefer vat.deinit();

    // Signing designator/hint come from the one accept resolver (ADR-0078),
    // same table the bindings call through `pancake_host_plan_accept`.
    var local_buf: [net.tcp.designator_buf_len]u8 = undefined;
    var key_designator: [crypto.PeerKey.designator_len]u8 = undefined;
    const transport = listener.transportName();
    const server_designator: []const u8, const accepted_local_addr: []const u8 = switch (listener.designatorScheme()) {
        .address => .{ "", listener.localDesignator(&local_buf) },
        .key => blk: {
            const secret = switch (identity) {
                .keyed => |secret| secret,
                .ephemeral => return Error.EphemeralIdentityOnKeyedTransport,
            };
            // Derived from the signing secret, not read back from the
            // listener, so designator ≡ session key by construction — the
            // responder half of the invariant the dial-side pin verifies.
            key_designator = secret.publicKey().toDesignator();
            break :blk .{ key_designator[0..], listener.localHint(&local_buf) };
        },
    };
    const plan = driver.core.planAccept(transport, server_designator, accepted_local_addr);
    var entry_buf: [1]model.HintEntry = undefined;
    const self_locator: model.PeerLocator = .{
        .transport = transport,
        .designator = plan.designator,
        .hints = model.Hints.forDirectAddresses(plan.direct_addresses_hint, &entry_buf),
    };
    switch (identity) {
        .ephemeral => try vat.startKeyedSession(self_locator),
        .keyed => |secret| try vat.startKeyedSessionWithSecret(self_locator, secret),
    }
    return vat;
}
