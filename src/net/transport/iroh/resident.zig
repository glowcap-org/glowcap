//! The blocking iroh resident: a netlayer over the sidecar's QUIC streams that
//! dials, listens, and hands each accepted stream to a peer as a framed
//! `net.Connection`.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");
const net = @import("net");
const sidecar = @import("sidecar.zig");
const locators = @import("locators.zig");

const crypto = foundation.crypto;
const Io = std.Io;
const Connection = net.Connection;
const Netlayer = net.netlayer.Netlayer;
const Listener = net.netlayer.Listener;
const Buffers = net.netlayer.Buffers;

const CEndpoint = sidecar.CEndpoint;
const CConn = sidecar.CConn;
const CEndpointConfig = sidecar.CEndpointConfig;
const ReadyEvent = sidecar.ReadyEvent;
const Reachability = locators.Reachability;
const known_transport = locators.known_transport;
const transport_name = locators.transport_name;
const node_id_len = locators.node_id_len;
const resolveConnectTarget = locators.resolveConnectTarget;
const validateListenerLocator = locators.validateListenerLocator;
const connRemoteKey = sidecar.connRemoteKey;
const would_block = sidecar.would_block;
const ev_readable = sidecar.ev_readable;
const ev_writable = sidecar.ev_writable;
const ev_closed = sidecar.ev_closed;
const ev_accept = sidecar.ev_accept;
const ev_connect = sidecar.ev_connect;

// ── The stream over one QUIC connection ──────────────────────────────────────

/// The sidecar connection as a `stream_shim` byte source. The sidecar write
/// is synchronous: it copies or sends the bytes before returning, so the caller
/// may free them as soon as the call returns, unlike the completion loop's
/// queued writes, which borrow until retire. QUIC sends written bytes eagerly,
/// so `flush` only surfaces a connection that died under the writes.
const ConnSource = struct {
    conn: *CConn,

    pub fn readSome(self: ConnSource, dest: []u8) Io.Reader.Error!usize {
        const n = sidecar.pancake_iroh_sidecar_conn_read(self.conn, dest.ptr, dest.len);
        if (n == 0) return error.EndOfStream;
        if (n < 0) return error.ReadFailed;
        return @intCast(n);
    }

    pub fn writeAll(self: ConnSource, bytes: []const u8) Io.Writer.Error!void {
        if (sidecar.pancake_iroh_sidecar_conn_write(self.conn, bytes.ptr, bytes.len) < 0) return error.WriteFailed;
    }

    pub fn flush(self: ConnSource) Io.Writer.Error!void {
        if (sidecar.pancake_iroh_sidecar_conn_flush(self.conn) != 0) return error.WriteFailed;
    }
};

/// One dialed/accepted QUIC stream, pinned so its reader/writer interfaces hold
/// a stable address for the `Connection`'s life. It is the shared
/// `net.netlayer.PinnedStream` over the sidecar's `ConnSource`; closing it
/// finishes the QUIC stream (the partner reads a clean end of stream) and frees
/// the sidecar connection handle. Read and write ride the one `*CConn`, so both
/// Shim sources name it.
const IrohContext = struct {
    conn: *CConn,

    pub fn closeStream(self: IrohContext) void {
        sidecar.pancake_iroh_sidecar_conn_free(self.conn);
    }
};

const IrohStream = net.netlayer.PinnedStream(ConnSource, IrohContext);

fn irohStreamCreate(allocator: std.mem.Allocator, conn: *CConn, bufs: Buffers) std.mem.Allocator.Error!*IrohStream {
    return IrohStream.create(allocator, .{ .conn = conn }, .{ .conn = conn }, bufs, .{ .conn = conn });
}

/// Adopt one sidecar connection into the netlayer stream. Ownership transfers
/// on entry, including every failure path. The authenticated identity becomes
/// durable only after the last fallible stream allocation, so a refused
/// connection cannot leave a phantom channel proof on `peer`.
pub fn adoptOwnedConn(io: Io, peer: *engine.Peer, conn: *CConn, bufs: Buffers) (error{ConnectionLost} || std.mem.Allocator.Error)!Connection {
    errdefer sidecar.pancake_iroh_sidecar_conn_free(conn);
    const remote_key = connRemoteKey(conn) orelse return error.ConnectionLost;
    const stream = try irohStreamCreate(peer.allocator, conn, bufs);
    peer.bindVerifiedChannelKey(remote_key);
    return stream.intoConnection(io, peer);
}

// ── The resident ─────────────────────────────────────────────────────────────

/// The iroh netlayer's state: one bound iroh endpoint (and, through it, the
/// sidecar's tokio runtime). The caller owns a `Resident` at a stable address
/// for as long as the registry holds the netlayer, and `deinit`s it after
/// every connection and listener it minted is closed.
pub const Resident = struct {
    io: Io,
    endpoint: *CEndpoint,
    reachability: Reachability,

    pub const InitError = error{EndpointBindFailed};

    /// One endpoint's configuration, the iroh mirror of the completion loop's
    /// opt-in `Keepalive`: `reachability` is mandatory (no default — enabling
    /// relays or discovery is always the host's visible choice), and
    /// `connect_timeout_ms` is the per-endpoint stream-establishment deadline
    /// (0 keeps the sidecar's built-in default). A single config so a future
    /// endpoint knob rides it without growing the constructor's arity.
    ///
    /// `idle_timeout_ms` bounds how long a connection survives without a packet
    /// from the far end. A connection whose peer was killed rather than
    /// closed ends here. 0 keeps the sidecar's default. The C ABI's
    /// `PancakeIrohConfig` is the authority on what to set it to and why.
    pub const Config = struct {
        reachability: Reachability,
        connect_timeout_ms: u64 = 0,
        idle_timeout_ms: u64 = 0,
        /// Worker threads for this endpoint's runtime; 0 takes the sidecar's
        /// default. A per-endpoint cost, so a process holding many endpoints is
        /// the caller that should name it.
        worker_threads: u32 = 0,
    };

    /// Bind an iroh endpoint. `secret_seed` is either null (a fresh random
    /// endpoint key) or 32 bytes of Ed25519 secret key material, borrowed for
    /// the call. `config` carries the mandatory reachability posture and the
    /// optional dial/accept timeout. `io` is captured for the connections this
    /// resident mints.
    pub fn init(io: Io, secret_seed: ?*const [32]u8, config: Config) InitError!Resident {
        const c_config: CEndpointConfig = .{
            .reachability = @backingInt(config.reachability),
            .connect_timeout_ms = config.connect_timeout_ms,
            .idle_timeout_ms = config.idle_timeout_ms,
            .worker_threads = config.worker_threads,
        };
        const endpoint = sidecar.pancake_iroh_sidecar_endpoint_new(secret_seed, &c_config) orelse return error.EndpointBindFailed;
        return .{ .io = io, .endpoint = endpoint, .reachability = config.reachability };
    }

    /// Close the endpoint without freeing it: a blocked `accept` returns
    /// `error.ConnectionLost` and subsequent dials fail. Idempotent; `deinit`
    /// still releases the handle. The shutdown lever for a host whose accept
    /// loop parks on another thread.
    pub fn close(self: *Resident) void {
        sidecar.pancake_iroh_sidecar_endpoint_close(self.endpoint);
    }

    /// Close the endpoint and its runtime. Every connection minted from this
    /// resident must already be closed.
    pub fn deinit(self: *Resident) error{SidecarTeardownFailed}!void {
        if (sidecar.pancake_iroh_sidecar_endpoint_free(self.endpoint) != 0) return error.SidecarTeardownFailed;
    }

    /// This resident as a `Netlayer`. `self` must outlive every connection
    /// the netlayer mints.
    pub fn netlayer(self: *Resident) Netlayer {
        return .{ .ctx = self, .vtable = &resident_vtable };
    }

    /// Dial a partner by its canonical endpoint id (`designator`) and
    /// comma-separated `direct_addrs` hint, opening the session's one QUIC
    /// stream. A hint-less dial on a direct endpoint is the caller's defect,
    /// typed `InvalidAddress` before the network is touched. The dial itself
    /// projects the sidecar's classification onto the `DialError` retry axis:
    /// a malformed id or hint is `InvalidAddress`, a deadline is `TimedOut`, a
    /// connection that could not be established is `NetworkUnreachable`, and a
    /// connection that came up then failed is `ConnectionLost` (ADR-0081). The
    /// returned `*CConn` is owned by the caller, freed with
    /// `sidecar.pancake_iroh_sidecar_conn_free`.
    fn dialRawConn(self: *Resident, designator: []const u8, direct_addrs: []const u8) net.netlayer.DialError!*CConn {
        // Canonical node-id shape is owned by `DialResolver.resolve` before the
        // blocking `residentDial` reaches here. This path owns reachability
        // hint policy.
        // A `direct` endpoint has no way to find a partner it was not handed an
        // address for, so a hint-less dial is a caller defect, refused before
        // the network. A discovery endpoint resolves the partner by id.
        if (direct_addrs.len == 0 and !locators.resolvesById(self.reachability)) return error.InvalidAddress;
        var code: i32 = 0;
        if (sidecar.pancake_iroh_sidecar_connect_blocking(
            self.endpoint,
            designator.ptr,
            designator.len,
            direct_addrs.ptr,
            direct_addrs.len,
            &code,
        )) |conn| return conn;
        // The sidecar header's dial codes: 1 invalid, 2 timeout, 3 unreachable,
        // 4 lost. iroh has no connection-refused — a dead port times out — so
        // that arm never appears here.
        return switch (code) {
            1 => error.InvalidAddress,
            2 => error.TimedOut,
            3 => error.NetworkUnreachable,
            else => error.ConnectionLost,
        };
    }

    /// Write this endpoint's id — the dialable designator — into `out` and
    /// return the written slice (`node_id_len` bytes). The buffer is exactly
    /// id-sized, so a short buffer is unrepresentable; an empty return means
    /// the sidecar faulted.
    pub fn nodeId(self: *const Resident, out: *[node_id_len]u8) []const u8 {
        const n = sidecar.pancake_iroh_sidecar_endpoint_node_id(self.endpoint, out, out.len);
        if (n != @as(isize, @intCast(out.len))) return out[0..0];
        return out[0..@intCast(n)];
    }

    pub const DirectAddrsError = error{SidecarFailed};
    const DirectAddrsOwnedError = DirectAddrsError || error{AddressListTooLarge} || std.mem.Allocator.Error;
    pub const DirectAddrsResult = union(enum) {
        written: []const u8,
        too_small: usize,
    };

    /// Write this endpoint's comma-separated direct socket addresses into
    /// `out` and return the written slice, the `hint_direct_addresses`
    /// value a partner dials with. An endpoint with no direct addresses
    /// yields an empty slice; a short buffer reports the exact required size.
    pub fn directAddrs(self: *const Resident, out: []u8) DirectAddrsError!DirectAddrsResult {
        const n = sidecar.pancake_iroh_sidecar_endpoint_direct_addrs(self.endpoint, out.ptr, out.len);
        if (n < 0) return error.SidecarFailed;
        const required: usize = @intCast(n);
        if (required > out.len) return .{ .too_small = required };
        return .{ .written = out[0..required] };
    }

    /// Return a caller-owned direct-address snapshot, capped by iroh locator policy.
    pub fn directAddrsOwned(self: *const Resident, allocator: std.mem.Allocator) DirectAddrsOwnedError![]u8 {
        var query: [1]u8 = undefined;
        var cap: usize = switch (try self.directAddrs(query[0..0])) {
            .written => return allocator.alloc(u8, 0),
            .too_small => |required| required,
        };
        while (true) {
            if (cap > locators.max_direct_address_bytes) return error.AddressListTooLarge;
            const out = try allocator.alloc(u8, cap);
            switch (self.directAddrs(out) catch |err| {
                allocator.free(out);
                return err;
            }) {
                .too_small => |required| {
                    allocator.free(out);
                    cap = required;
                },
                .written => |written| {
                    if (written.len > locators.max_direct_address_bytes) {
                        allocator.free(out);
                        return error.AddressListTooLarge;
                    }
                    if (written.len == out.len) return out;
                    return allocator.realloc(out, written.len) catch |err| {
                        allocator.free(out);
                        return err;
                    };
                },
            }
        }
    }

    // ── The event-driven loop surface (ADR-0057) ────────────────────────────
    //
    // These let a host that owns the loop — `iroh.Backend` here, or a language
    // binding through the C ABI — drive many connections from one thread
    // without a parked blocking read per connection. A connection handle is
    // the sidecar's opaque `*CConn`, surfaced as `*anyopaque` so callers
    // (the C ABI) hold it without naming the private type; pass it straight
    // back to the `loop*` methods. The `usize` value of that pointer is the
    // key the readiness records carry (`ReadyEvent.conn`).

    /// Switch the endpoint to non-blocking mode: spawn the acceptor and ensure
    /// the readiness channel exists. Idempotent. Returns false if the sidecar
    /// could not arm the acceptor (e.g. the self-pipe failed).
    pub fn enableLoop(self: *Resident) bool {
        return sidecar.pancake_iroh_sidecar_endpoint_set_nonblocking_accept(self.endpoint) == 0;
    }

    /// The endpoint's single read-only OS-level readiness fd, registered once
    /// with the host's poller. Readable whenever the ready queue has records.
    pub fn readinessFd(self: *Resident) i32 {
        return sidecar.pancake_iroh_sidecar_endpoint_readiness_fd(self.endpoint);
    }

    /// Clear the fd's coalesced wake bytes, then drain pending readiness records
    /// into `out`, returning the count (0 when empty, negative on fault). Owning
    /// that order here makes a lost-wakeup ordering error unavailable to callers.
    /// Each record's `conn` is a `*CConn` as an integer, or 0 for an accept.
    pub fn drainReady(self: *Resident, out: []ReadyEvent) isize {
        return sidecar.pancake_iroh_sidecar_endpoint_drain_ready(self.endpoint, out.ptr, out.len);
    }

    /// Claim one accepted connection, already switched to non-blocking, or null
    /// when none is pending (`WOULD_BLOCK`) or the transition failed.
    pub fn loopTryAccept(self: *Resident) ?*anyopaque {
        const conn = sidecar.pancake_iroh_sidecar_endpoint_try_accept(self.endpoint) orelse return null;
        if (sidecar.pancake_iroh_sidecar_conn_set_nonblocking(self.endpoint, conn) != 0) {
            sidecar.pancake_iroh_sidecar_conn_free(conn);
            return null;
        }
        return conn;
    }

    /// Admit one evented dial under a caller-owned request id. Accepted starts
    /// produce exactly one `ev_connect`; rejected starts produce none.
    pub fn loopStartConnectResolved(self: *Resident, request_id: usize, designator: []const u8, direct_addrs: []const u8) (net.netlayer.DialError || error{WouldBlock})!void {
        if (request_id == 0) return error.InvalidAddress;
        if (direct_addrs.len == 0 and !locators.resolvesById(self.reachability)) return error.InvalidAddress;
        return switch (sidecar.pancake_iroh_sidecar_endpoint_start_connect(
            self.endpoint,
            request_id,
            designator.ptr,
            designator.len,
            direct_addrs.ptr,
            direct_addrs.len,
        )) {
            0 => {},
            1 => error.InvalidAddress,
            2 => error.TimedOut,
            3 => error.NetworkUnreachable,
            7 => error.WouldBlock,
            else => error.ConnectionLost,
        };
    }

    /// Consume one terminal evented dial and move the connection onto the
    /// readiness surface. The caller owns the returned handle.
    pub fn loopFinishConnect(self: *Resident, request_id: usize) net.netlayer.DialError!*anyopaque {
        var conn: ?*CConn = null;
        return switch (sidecar.pancake_iroh_sidecar_endpoint_finish_connect(self.endpoint, request_id, &conn)) {
            0 => blk: {
                const ready_conn = conn orelse return error.ConnectionLost;
                if (sidecar.pancake_iroh_sidecar_conn_set_nonblocking(self.endpoint, ready_conn) != 0) {
                    sidecar.pancake_iroh_sidecar_conn_free(ready_conn);
                    return error.ConnectionLost;
                }
                break :blk ready_conn;
            },
            1 => error.InvalidAddress,
            2 => error.TimedOut,
            3 => error.NetworkUnreachable,
            else => error.ConnectionLost,
        };
    }

    /// Request cancellation while leaving the terminal row for an explicit
    /// `loopFinishConnect`. This is the low-level iroh C API's two-phase edge.
    pub fn loopRequestConnectCancel(self: *Resident, request_id: usize) void {
        _ = sidecar.pancake_iroh_sidecar_endpoint_cancel_connect(self.endpoint, request_id);
    }

    /// Cancel and consume one evented dial. Multiplexed-resident adapters use
    /// this complete ownership edge because their cancel contract has no later
    /// finish call. A connect that won the race is closed instead of leaked.
    pub fn loopCancelConnect(self: *Resident, request_id: usize) void {
        self.loopRequestConnectCancel(request_id);
        if (self.loopFinishConnect(request_id)) |conn| self.loopConnClose(conn) else |_| {}
    }

    pub fn loopConnId(self: *const Resident, conn: *const anyopaque) usize {
        _ = self;
        return sidecar.pancake_iroh_sidecar_conn_id(@ptrCast(conn));
    }

    /// Non-blocking read of raw bytes from a loop connection into `buf`:
    /// the byte count, `loop_would_block` when nothing is buffered yet, 0 on a
    /// clean end of stream, or negative on a read fault. The host frames these
    /// bytes itself (the peer's stream-input path), the same shape `tcp` uses.
    pub fn loopTryRead(self: *Resident, conn: *anyopaque, buf: []u8) isize {
        _ = self;
        return sidecar.pancake_iroh_sidecar_conn_try_read(@ptrCast(conn), buf.ptr, buf.len);
    }

    /// Non-blocking write of raw bytes to a loop connection: the count
    /// written, `loop_would_block` when the outbound buffer has no room,
    /// or negative on a fault. The caller treats a short write as ordinary
    /// (advance and resubmit the tail).
    pub fn loopTryWrite(self: *Resident, conn: *anyopaque, buf: []const u8) isize {
        _ = self;
        return sidecar.pancake_iroh_sidecar_conn_try_write(@ptrCast(conn), buf.ptr, buf.len);
    }

    /// Close and free a loop connection handle. After this the handle is dead;
    /// any later readiness record naming it routes to nothing.
    pub fn loopConnClose(self: *Resident, conn: *anyopaque) void {
        _ = self;
        sidecar.pancake_iroh_sidecar_conn_free(@ptrCast(conn));
    }

    /// The key QUIC verified for the far end of a loop connection, or null
    /// when the handle is gone or the sidecar could not read it. This is the
    /// transport proof of ADR-0105 at the loop surface, for a host that drives
    /// the loop itself: the blocking accept and dial paths above assert it to
    /// their peer directly, while a loop host (`iroh.Backend`, or a language
    /// binding through `pancake_iroh_conn_remote_node_id`) owns the connection
    /// and has to ask.
    pub fn loopConnRemoteKey(self: *const Resident, conn: *const anyopaque) ?crypto.PeerKey {
        _ = self;
        return connRemoteKey(@ptrCast(conn));
    }
};

/// `loopTryRead` / `loopTryWrite` return this when the operation cannot make
/// progress without blocking, the resident-surface spelling of the sidecar's
/// `WOULD_BLOCK`, distinct from 0 (clean end of stream) and negative (fault).
pub const loop_would_block: isize = would_block;

/// Readiness event bits a `ReadyEvent.events` carries, re-exported for hosts
/// that drive `drainReady` (the C ABI). Mirrors the sidecar header's
/// `PANCAKE_IROH_EV_*`.
pub const loop_ev_readable: u32 = ev_readable;
pub const loop_ev_writable: u32 = ev_writable;
pub const loop_ev_closed: u32 = ev_closed;
pub const loop_ev_accept: u32 = ev_accept;
pub const loop_ev_connect: u32 = ev_connect;

const resident_ctx = net.netlayer.ResidentContext(Resident);

const resident_vtable: Netlayer.VTable = .{
    .profile = known_transport.metadata(),
    .dial = .{ .blocking = net.netlayer.adaptBlockingDial(residentDial) },
    .listen = residentListen,
    .io = resident_ctx.io,
};

fn residentDial(
    ctx: *anyopaque,
    peer: *engine.Peer,
    candidate: model.PeerLocator,
    bufs: Buffers,
    options: net.netlayer.OperationOptions,
) net.netlayer.DialError!Connection {
    try options.requireInherited();
    const self = resident_ctx.of(ctx);
    // Same admission as the completion loop: DialResolver.resolve owns transport +
    // canonical node-id; dialRawConn owns reachability hint policy (needs
    // resident posture).
    const target = resolveConnectTarget(candidate) catch return error.InvalidAddress;
    const conn = try self.dialRawConn(target.id, target.hints);
    // The dial half of the same proof the accept half makes (ADR-0105): QUIC
    // authenticated the endpoint this connection reached, so read it back off
    // the connection rather than assuming the dial got what it asked for.
    return adoptOwnedConn(self.io, peer, conn, bufs);
}

fn residentListen(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    config: net.netlayer.ListenConfig,
) net.netlayer.ListenStartOutcome {
    return .{ .admitted = residentListenFallible(ctx, allocator, config) catch |err|
        return .{ .failed = .init(err) } };
}

fn residentListenFallible(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    config: net.netlayer.ListenConfig,
) net.netlayer.ListenError!net.netlayer.ListenResult {
    try config.options.requireInherited();
    const self = resident_ctx.of(ctx);
    // The endpoint bound at `Resident.init` is the listener; iroh has no
    // per-listen address. The node default is the empty designator; a caller
    // may also name this endpoint's own id.
    if (config.designator.len != 0) {
        var id_buf: [node_id_len]u8 = undefined;
        const id = self.nodeId(&id_buf);
        if (!std.mem.eql(u8, config.designator, id)) return error.InvalidAddress;
    }
    const box = allocator.create(ListenerBox) catch return error.OutOfMemory;
    box.* = .{ .resident = self, .allocator = allocator };
    return .{ .ready = .{ .ctx = box, .vtable = &listener_vtable } };
}
/// A heap-pinned accept seat over the resident's one endpoint, freed by the
/// contract listener's `close`. Closing the listener does not close the
/// endpoint, the resident owns that. `stashed` holds a conn claimed by
/// `waitAcceptable` via try_accept so the next `accept` does not block.
const ListenerBox = struct {
    resident: *Resident,
    allocator: std.mem.Allocator,
    stashed: ?*CConn = null,
    /// The sidecar's blocking accept has no per-call cancel handle. Serialize
    /// it and poll in short bounded slices so close can join without freeing
    /// this box under an active call.
    operation_gate: std.Io.Mutex = .init,
    stopping: std.atomic.Value(bool) = .init(false),
};

const accept_cancel_poll_ms: i32 = 50;

const listener_vtable: Listener.VTable = .{
    .transport_name = transport_name,
    // Key scheme, like the netlayer: the responder's signed designator derives
    // from its identity key, and the complete locator publishes any direct
    // addresses the endpoint knows.
    .designator_scheme = known_transport.metadata().designator_scheme,
    .sealed_channel = known_transport.metadata().sealed_channel,
    .accept = net.netlayer.adaptAccept(listenerAccept),
    .wait_acceptable = net.netlayer.adaptAcceptReadiness(listenerWaitAcceptable),
    .local_locator = net.netlayer.adaptListenerLocator(listenerLocalLocator),
    .canonicalize_locator = net.netlayer.adaptListenerCanonicalize(listenerCanonicalizeLocator),
    .close = listenerClose,
};

fn listenerWaitAcceptable(ctx: *anyopaque, timeout_ms: i32) net.netlayer.AcceptError!bool {
    const box: *ListenerBox = @ptrCast(@alignCast(ctx));
    box.operation_gate.lockUncancelable(box.resident.io);
    defer box.operation_gate.unlock(box.resident.io);
    return waitForConnection(box, timeout_ms);
}

fn listenerAccept(ctx: *anyopaque, peer: *engine.Peer, bufs: Buffers) net.netlayer.AcceptError!Connection {
    const box: *ListenerBox = @ptrCast(@alignCast(ctx));
    box.operation_gate.lockUncancelable(box.resident.io);
    defer box.operation_gate.unlock(box.resident.io);
    if (box.stashed == null and !try waitForConnection(box, -1)) return error.ConnectionLost;
    const conn = box.stashed orelse return error.ConnectionLost;
    box.stashed = null;
    // The transport proof (ADR-0105): QUIC verified the remote endpoint key
    // during the TLS handshake, and this resident is the code that realized
    // the connection, so it is the one that may say so. Bound before any byte
    // is fed, so the pre-open chokepoint sees the evidence when the partner's
    // claim arrives. A connection whose proof cannot be read is refused rather
    // than admitted unbound.
    return adoptOwnedConn(box.resident.io, peer, conn, bufs);
}

/// Wait on the sidecar's direct accept path without touching the evented
/// backend's readiness queue. Bounded slices are the cancellation seam: a
/// close flips `stopping`, then joins `operation_gate` within one slice.
fn waitForConnection(box: *ListenerBox, timeout_ms: i32) net.netlayer.AcceptError!bool {
    if (box.stashed != null) return true;
    const started_at = if (timeout_ms > 0) net.clock.nowMs(box.resident.io) else 0;
    while (true) {
        if (box.stopping.load(.acquire)) return error.ConnectionLost;
        const slice_ms: i32 = if (timeout_ms < 0)
            accept_cancel_poll_ms
        else if (timeout_ms == 0)
            0
        else blk: {
            const elapsed = net.clock.nowMs(box.resident.io) - started_at;
            if (elapsed >= timeout_ms) return false;
            break :blk @intCast(@min(@as(i64, accept_cancel_poll_ms), @as(i64, timeout_ms) - elapsed));
        };
        var code: i32 = 0;
        box.stashed = sidecar.pancake_iroh_sidecar_accept_timeout(box.resident.endpoint, slice_ms, &code);
        if (box.stashed != null) return true;
        // Only a completed bounded wait is retryable. Endpoint close and every
        // other sidecar failure are terminal; treating their null handle as a
        // timeout would spin this unbounded listener forever after `close`.
        if (code != 2) return error.ConnectionLost;
        if (timeout_ms == 0) return false;
    }
}

/// This endpoint's direct addresses, the `hint_direct_addresses` value a partner
/// dials with, published in the hello the way `keyed-tcp` publishes its bound
/// address.
///
/// A key designator says who this peer is, not where it is, so a locator without
/// addresses is only usable by someone who can resolve the node id. For a
/// **third party** handed this locator in a handoff that means a relay round
/// trip, and for an endpoint with no relay of its own it means not at all.
/// Publishing what we know costs nothing: a dialer given addresses uses them,
/// and one given none falls back to discovery.
///
/// An empty direct-address set is ordinary for a discovery-capable endpoint:
/// the locator remains complete and dials by endpoint id.
fn listenerLocalLocator(ctx: *anyopaque, allocator: std.mem.Allocator) net.netlayer.ListenError!model.PeerLocator {
    const box: *ListenerBox = @ptrCast(@alignCast(ctx));
    const direct = box.resident.directAddrsOwned(allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SidecarFailed, error.AddressListTooLarge => return error.BindFailed,
    };
    defer allocator.free(direct);
    var designator: [node_id_len]u8 = undefined;
    if (box.resident.nodeId(&designator).len != designator.len) return error.BindFailed;
    var hint_storage: [1]model.HintEntry = undefined;
    return model.clonePeerLocator(allocator, .{
        .transport = transport_name,
        .designator = &designator,
        .hints = model.Hints.forDirectAddresses(direct, &hint_storage),
    });
}

fn listenerCanonicalizeLocator(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    candidate: model.PeerLocator,
) net.netlayer.ListenError!model.PeerLocator {
    const box: *ListenerBox = @ptrCast(@alignCast(ctx));
    var expected: [node_id_len]u8 = undefined;
    if (box.resident.nodeId(&expected).len != expected.len) return error.BindFailed;
    try validateListenerLocator(&expected, candidate);
    return model.clonePeerLocator(allocator, candidate);
}

fn listenerClose(ctx: *anyopaque) ?net.netlayer.ListenerCloseFailure {
    const box: *ListenerBox = @ptrCast(@alignCast(ctx));
    box.stopping.store(true, .release);
    box.operation_gate.lockUncancelable(box.resident.io);
    box.operation_gate.unlock(box.resident.io);
    if (box.stashed) |conn| sidecar.pancake_iroh_sidecar_conn_free(conn);
    box.allocator.destroy(box);
    return null;
}
