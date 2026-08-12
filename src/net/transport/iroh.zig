//! The iroh netlayer resident: an encrypted QUIC transport behind the same
//! contract as tcp and inproc, carried by the Rust sidecar (ADR-0055).
//!
//! The wire is iroh: each `Resident` owns one iroh endpoint (created through
//! the C ABI in `transports/iroh/include/pancake_iroh_sidecar.h`, implemented
//! by the `libpancake_iroh_sidecar.a` staticlib), and every connection is one
//! bidirectional QUIC
//! stream presented as the same `*std.Io.Reader` / `*std.Io.Writer` pair the
//! other residents produce. The transport symbol is `iroh`; the locator
//! designator is the endpoint id — an Ed25519 public key, OCapN's
//! self-authenticating designator — and direct socket addresses ride the
//! locator's hints under `hint_direct_addresses`.
//!
//! This file is deliberately *not* reachable from the default `pancake` module
//! graph: it is not exported by `net/mod.zig`, because its extern
//! declarations resolve only when `libpancake_iroh_sidecar.a` is linked, and
//! `test/api_surface_test.zig` references every exported declaration
//! recursively — exporting it would force the Rust staticlib into every gate.
//! The sidecar posture (ADR-0055) keeps the core archives pure Zig; the
//! `iroh-interop` build step compiles this file as its own module (importing
//! the `net` contract module rather than sibling files, so no source
//! file lands in two modules) and links the staticlib.
//!
//! Two consumer shapes ride this resident. The blocking sidecar calls
//! (`connect`/`accept`/`read_frame`/`write_frame`) each block the calling OS
//! thread (the endpoint runs its own tokio runtime) and serve the cooperative
//! `BlockingSession` path ADR-0053 settled. For pancake-scale fan-out, the
//! ADR-0057 event-driven superset exposes one readiness fd and non-blocking
//! try-I/O through `Backend` below — `completion.Loop(Backend, DialResolver)` plus
//! `driver.Bridge` multiplex many iroh connections the same way `net.TcpLoop`
//! multiplexes kernel sockets (ADR-0076).

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");
const net = @import("net");
const completion = net.completion;
const ScratchPool = completion.ScratchPool;

const crypto = foundation.crypto;
const Io = std.Io;
const Connection = net.Connection;
const Netlayer = net.netlayer.Netlayer;
const Listener = net.netlayer.Listener;
const Buffers = net.netlayer.Buffers;

/// The transport symbol this resident registers under and signs into
/// `op:start-session`.
const known_transport = model.transport.Known.iroh;
pub const transport_profile = known_transport.metadata();
pub const transport_name = transport_profile.symbol;

/// How an endpoint becomes reachable, chosen explicitly when the resident is
/// created — there is no default, so enabling relays or a discovery service is
/// always the host's visible decision, never a hidden implementation detail.
/// The values mirror `PANCAKE_IROH_REACH_*` in the sidecar header.
pub const Reachability = enum(u32) {
    /// Relay-less and lookup-less: a dial needs the partner's direct-address
    /// hints, and a hint-less dial refuses as `error.InvalidAddress`. The
    /// loopback/LAN posture.
    direct = 0,
    /// The number-0 relays plus DNS/pkarr discovery: a peer is dialable by id
    /// alone over the public internet, with hole-punching and NAT traversal.
    discovery = 1,
    /// DNS/pkarr discovery without relays — direct addresses are published and
    /// resolved, but there is no relay fallback.
    discovery_no_relay = 2,
    /// An in-process shared address book: endpoints publish and resolve by id
    /// alone with no relay, DNS, or hints. For tests and same-process
    /// embeddings, never the public internet.
    local_discovery = 3,

    /// Whether a dial may omit the partner's direct-address hints because the
    /// endpoint can resolve the partner by id. Only `direct` cannot.
    fn resolvesById(self: Reachability) bool {
        return self != .direct;
    }
};

/// The locator hint carrying the partner's comma-separated direct socket
/// addresses (the string `pancake_iroh_sidecar_endpoint_direct_addrs` produces).
/// A `direct` endpoint runs no relay or lookup service, so a dial without this
/// hint cannot reach its partner and `DialResolver.resolve` / `dialRawConn` refuse
/// such a locator with `error.InvalidAddress` instead of timing out; an endpoint
/// with a discovery posture resolves the partner by id, so the hint is optional
/// there. The name
/// itself is the transport-neutral vocabulary in `net.netlayer` (keyed TCP
/// dials with the same hint), re-exported here so iroh consumers keep this
/// spelling.
pub const hint_direct_addresses = net.netlayer.hint_direct_addresses;

/// An endpoint id is an Ed25519 public key printed as lowercase hex — the one
/// canonical key-designator spelling, owned by
/// `foundation.crypto.PeerKey.toDesignator`: `Resident.nodeId` produces it, and
/// `DialResolver.resolve` refuses any other shape with `error.InvalidAddress`.
pub const node_id_len = crypto.PeerKey.designator_len;

// ── The sidecar C ABI (transports/iroh/include/pancake_iroh_sidecar.h) ──────

const CEndpoint = opaque {};
const CConn = opaque {};

/// The sidecar's endpoint config, field-for-field with its `#[repr(C)]`
/// counterpart. Passed by pointer so a new endpoint knob is a field here rather
/// than a wider signature every caller has to agree on.
const CEndpointConfig = extern struct {
    reachability: u32,
    connect_timeout_ms: u64,
    idle_timeout_ms: u64,
    worker_threads: u32,
};

extern fn pancake_iroh_sidecar_endpoint_new(secret_seed32: ?*const [32]u8, config: *const CEndpointConfig) ?*CEndpoint;
extern fn pancake_iroh_sidecar_endpoint_node_id(ep: *const CEndpoint, out: [*]u8, out_cap: usize) isize;
extern fn pancake_iroh_sidecar_endpoint_direct_addrs(ep: *const CEndpoint, out: [*]u8, out_cap: usize) isize;
extern fn pancake_iroh_sidecar_connect_blocking(ep: *CEndpoint, node_id: [*]const u8, node_id_len: usize, addr_hints: [*]const u8, addr_hints_len: usize, out_code: *i32) ?*CConn;
extern fn pancake_iroh_sidecar_accept_timeout(ep: *CEndpoint, timeout_ms: i32) ?*CConn;
extern fn pancake_iroh_sidecar_conn_remote_node_id(conn: *const CConn, out_key32: [*]u8) i32;
extern fn pancake_iroh_sidecar_conn_read(conn: *CConn, buf: [*]u8, len: usize) isize;
extern fn pancake_iroh_sidecar_conn_write(conn: *CConn, buf: [*]const u8, len: usize) isize;
extern fn pancake_iroh_sidecar_conn_flush(conn: *CConn) i32;
extern fn pancake_iroh_sidecar_conn_close(conn: *CConn) void;
extern fn pancake_iroh_sidecar_conn_free(conn: *CConn) void;
extern fn pancake_iroh_sidecar_endpoint_close(ep: *CEndpoint) void;
extern fn pancake_iroh_sidecar_endpoint_free(ep: *CEndpoint) void;

// The event-driven scale superset (ADR-0057): one readiness fd per endpoint, a
// drained ready-queue, and non-blocking frame I/O — the `Backend` below adapts
// them to `completion.Loop`.
extern fn pancake_iroh_sidecar_endpoint_readiness_fd(ep: *const CEndpoint) i32;
extern fn pancake_iroh_sidecar_endpoint_drain_ready(ep: *const CEndpoint, out: [*]ReadyEvent, out_cap: usize) isize;
extern fn pancake_iroh_sidecar_endpoint_start_connect(ep: *CEndpoint, request_id: usize, node_id: [*]const u8, node_id_len: usize, addr_hints: [*]const u8, addr_hints_len: usize) i32;
extern fn pancake_iroh_sidecar_endpoint_finish_connect(ep: *CEndpoint, request_id: usize, out_conn: *?*CConn) i32;
extern fn pancake_iroh_sidecar_endpoint_cancel_connect(ep: *CEndpoint, request_id: usize) i32;
extern fn pancake_iroh_sidecar_endpoint_set_nonblocking_accept(ep: *CEndpoint) i32;
extern fn pancake_iroh_sidecar_endpoint_try_accept(ep: *CEndpoint) ?*CConn;
extern fn pancake_iroh_sidecar_conn_set_nonblocking(ep: *CEndpoint, conn: *CConn) i32;
extern fn pancake_iroh_sidecar_conn_id(conn: *const CConn) usize;
extern fn pancake_iroh_sidecar_conn_try_read(conn: *CConn, buf: [*]u8, len: usize) isize;
extern fn pancake_iroh_sidecar_conn_try_write(conn: *CConn, buf: [*]const u8, len: usize) isize;

/// `conn_try_read` / `conn_try_write` return this when the operation cannot make
/// progress without blocking. Distinct from 0 (clean end of stream) and -1
/// (error). Mirrors `PANCAKE_IROH_WOULD_BLOCK` in the sidecar header.
const would_block: isize = -2;

/// Readiness event bits packed into `ReadyEvent.events`, mirroring the sidecar
/// header's `PANCAKE_IROH_EV_*`. A drained record may carry several at once.
const ev_readable: u32 = 1;
const ev_writable: u32 = 2;
const ev_closed: u32 = 4;
const ev_accept: u32 = 8;
const ev_connect: u32 = 16;

/// One drained readiness record: the subject that became ready (the stable
/// `loopConnId` identity for connection records, a caller request id for
/// `ev_connect`, 0 for `ev_accept`) and the `ev_*` bitset. This is the
/// `extern struct` counterpart of the sidecar's `PancakeIrohReadyEvent` and
/// the header's `pancake_iroh_sidecar_ready_event`; the three layouts are
/// kept in lockstep.
pub const ReadyEvent = extern struct {
    subject: usize,
    events: u32,
};

// ── The stream over one QUIC connection ──────────────────────────────────────

/// The sidecar connection as a `stream_shim` byte source. The sidecar write
/// is synchronous: it copies or sends the bytes before returning, so the caller
/// may free them as soon as the call returns, unlike the completion loop's
/// queued writes, which borrow until retire. QUIC sends written bytes eagerly,
/// so `flush` only surfaces a connection that died under the writes.
const ConnSource = struct {
    conn: *CConn,

    pub fn readSome(self: ConnSource, dest: []u8) Io.Reader.Error!usize {
        const n = pancake_iroh_sidecar_conn_read(self.conn, dest.ptr, dest.len);
        if (n == 0) return error.EndOfStream;
        if (n < 0) return error.ReadFailed;
        return @intCast(n);
    }

    pub fn writeAll(self: ConnSource, bytes: []const u8) Io.Writer.Error!void {
        if (pancake_iroh_sidecar_conn_write(self.conn, bytes.ptr, bytes.len) < 0) return error.WriteFailed;
    }

    pub fn flush(self: ConnSource) Io.Writer.Error!void {
        if (pancake_iroh_sidecar_conn_flush(self.conn) != 0) return error.WriteFailed;
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
        pancake_iroh_sidecar_conn_free(self.conn);
    }
};

const IrohStream = net.netlayer.PinnedStream(ConnSource, IrohContext);

fn irohStreamCreate(allocator: std.mem.Allocator, conn: *CConn, bufs: Buffers) std.mem.Allocator.Error!*IrohStream {
    return IrohStream.create(allocator, .{ .conn = conn }, .{ .conn = conn }, bufs, .{ .conn = conn });
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
    /// from the far end, which is what ends one whose peer was killed rather
    /// than closed. 0 keeps the sidecar's default. The C ABI's
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
            .reachability = @intFromEnum(config.reachability),
            .connect_timeout_ms = config.connect_timeout_ms,
            .idle_timeout_ms = config.idle_timeout_ms,
            .worker_threads = config.worker_threads,
        };
        const endpoint = pancake_iroh_sidecar_endpoint_new(secret_seed, &c_config) orelse return error.EndpointBindFailed;
        return .{ .io = io, .endpoint = endpoint, .reachability = config.reachability };
    }

    /// Close the endpoint without freeing it: a blocked `accept` returns
    /// `error.ConnectionLost` and subsequent dials fail. Idempotent; `deinit`
    /// still releases the handle. The shutdown lever for a host whose accept
    /// loop parks on another thread.
    pub fn close(self: *Resident) void {
        pancake_iroh_sidecar_endpoint_close(self.endpoint);
    }

    /// Close the endpoint and its runtime. Every connection minted from this
    /// resident must already be closed.
    pub fn deinit(self: *Resident) void {
        pancake_iroh_sidecar_endpoint_free(self.endpoint);
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
    /// `pancake_iroh_sidecar_conn_free`.
    fn dialRawConn(self: *Resident, designator: []const u8, direct_addrs: []const u8) net.netlayer.DialError!*CConn {
        // Canonical node-id shape is owned by `DialResolver.resolve` before the
        // blocking `residentDial` reaches here. This path owns reachability
        // hint policy.
        // A `direct` endpoint has no way to find a partner it was not handed an
        // address for, so a hint-less dial is a caller defect, refused before
        // the network. A discovery endpoint resolves the partner by id.
        if (direct_addrs.len == 0 and !self.reachability.resolvesById()) return error.InvalidAddress;
        var code: i32 = 0;
        if (pancake_iroh_sidecar_connect_blocking(
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
        const n = pancake_iroh_sidecar_endpoint_node_id(self.endpoint, out, out.len);
        if (n < 0) return out[0..0];
        return out[0..@intCast(n)];
    }

    pub const DirectAddrsError = error{OutputBufferTooSmall};

    /// Write this endpoint's comma-separated direct socket addresses into
    /// `out` and return the written slice, the `hint_direct_addresses`
    /// value a partner dials with. An endpoint with no direct addresses
    /// yields an empty slice; a buffer that cannot hold the list is the
    /// typed error, never silently empty.
    pub fn directAddrs(self: *const Resident, out: []u8) DirectAddrsError![]const u8 {
        const n = pancake_iroh_sidecar_endpoint_direct_addrs(self.endpoint, out.ptr, out.len);
        if (n < 0) return error.OutputBufferTooSmall;
        return out[0..@intCast(n)];
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
        return pancake_iroh_sidecar_endpoint_set_nonblocking_accept(self.endpoint) == 0;
    }

    /// The endpoint's single read-only OS-level readiness fd, registered once
    /// with the host's poller. Readable whenever the ready queue has records.
    pub fn readinessFd(self: *Resident) i32 {
        return pancake_iroh_sidecar_endpoint_readiness_fd(self.endpoint);
    }

    /// Clear the fd's coalesced wake bytes, then drain pending readiness records
    /// into `out`, returning the count (0 when empty, negative on fault). Owning
    /// that order here makes a lost-wakeup ordering error unavailable to callers.
    /// Each record's `conn` is a `*CConn` as an integer, or 0 for an accept.
    pub fn drainReady(self: *Resident, out: []ReadyEvent) isize {
        return pancake_iroh_sidecar_endpoint_drain_ready(self.endpoint, out.ptr, out.len);
    }

    /// Claim one accepted connection, already switched to non-blocking, or null
    /// when none is pending (`WOULD_BLOCK`) or the transition failed.
    pub fn loopTryAccept(self: *Resident) ?*anyopaque {
        const conn = pancake_iroh_sidecar_endpoint_try_accept(self.endpoint) orelse return null;
        if (pancake_iroh_sidecar_conn_set_nonblocking(self.endpoint, conn) != 0) {
            pancake_iroh_sidecar_conn_free(conn);
            return null;
        }
        return conn;
    }

    /// Admit one evented dial under a caller-owned request id. Accepted starts
    /// produce exactly one `ev_connect`; rejected starts produce none.
    pub fn loopStartConnectResolved(self: *Resident, request_id: usize, designator: []const u8, direct_addrs: []const u8) (net.netlayer.DialError || error{WouldBlock})!void {
        if (request_id == 0) return error.InvalidAddress;
        if (direct_addrs.len == 0 and !self.reachability.resolvesById()) return error.InvalidAddress;
        return switch (pancake_iroh_sidecar_endpoint_start_connect(
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
        return switch (pancake_iroh_sidecar_endpoint_finish_connect(self.endpoint, request_id, &conn)) {
            0 => blk: {
                const ready_conn = conn orelse return error.ConnectionLost;
                if (pancake_iroh_sidecar_conn_set_nonblocking(self.endpoint, ready_conn) != 0) {
                    pancake_iroh_sidecar_conn_free(ready_conn);
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

    pub fn loopCancelConnect(self: *Resident, request_id: usize) void {
        _ = pancake_iroh_sidecar_endpoint_cancel_connect(self.endpoint, request_id);
    }

    pub fn loopConnId(self: *const Resident, conn: *const anyopaque) usize {
        _ = self;
        return pancake_iroh_sidecar_conn_id(@ptrCast(conn));
    }

    /// Non-blocking read of raw bytes from a loop connection into `buf`:
    /// the byte count, `loop_would_block` when nothing is buffered yet, 0 on a
    /// clean end of stream, or negative on a read fault. The host frames these
    /// bytes itself (the peer's stream-input path), the same shape `tcp` uses.
    pub fn loopTryRead(self: *Resident, conn: *anyopaque, buf: []u8) isize {
        _ = self;
        return pancake_iroh_sidecar_conn_try_read(@ptrCast(conn), buf.ptr, buf.len);
    }

    /// Non-blocking write of raw bytes to a loop connection: the count
    /// written, `loop_would_block` when the outbound buffer has no room,
    /// or negative on a fault. The caller treats a short write as ordinary
    /// (advance and resubmit the tail).
    pub fn loopTryWrite(self: *Resident, conn: *anyopaque, buf: []const u8) isize {
        _ = self;
        return pancake_iroh_sidecar_conn_try_write(@ptrCast(conn), buf.ptr, buf.len);
    }

    /// Close and free a loop connection handle. After this the handle is dead;
    /// any later readiness record naming it routes to nothing.
    pub fn loopConnClose(self: *Resident, conn: *anyopaque) void {
        _ = self;
        pancake_iroh_sidecar_conn_free(@ptrCast(conn));
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

/// The key QUIC verified for the far end of `conn` during the TLS handshake,
/// or null when the sidecar could not read it. Every path that speaks the
/// transport proof of ADR-0105 — the blocking accept and dial, the completion
/// backend, and the loop surface a language binding drives — reads it here, so
/// one function decides what "the connection proved" means for iroh.
fn connRemoteKey(conn: *const CConn) ?crypto.PeerKey {
    var remote: [crypto.PEER_KEY_BYTES]u8 = undefined;
    if (pancake_iroh_sidecar_conn_remote_node_id(conn, &remote) != 0) return null;
    return crypto.PeerKey.fromBytes(remote);
}

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
    .dial = residentDial,
    .listen = residentListen,
    .io = resident_ctx.io,
};

/// The canonical designator shape `Resident.nodeId` produces: exactly
/// `node_id_len` lowercase hex digits. One spelling, owned by
/// `foundation.crypto.PeerKey.fromDesignator`, checked before the sidecar is
/// asked to parse anything.
fn isCanonicalNodeId(designator: []const u8) bool {
    return crypto.PeerKey.fromDesignator(designator) != null;
}

fn residentDial(
    ctx: *anyopaque,
    peer: *engine.Peer,
    locator: model.PeerLocator,
    bufs: Buffers,
) net.netlayer.DialError!Connection {
    const self = resident_ctx.of(ctx);
    // Same admission as the completion loop: DialResolver.resolve owns transport +
    // canonical node-id; dialRawConn owns reachability hint policy (needs
    // resident posture).
    const target = resolveConnectTarget(locator) catch return error.InvalidAddress;
    const conn = try self.dialRawConn(target.id, target.hints);
    errdefer pancake_iroh_sidecar_conn_free(conn);
    // The dial half of the same proof the accept half makes (ADR-0105): QUIC
    // authenticated the endpoint this connection reached, so read it back off
    // the connection rather than assuming the dial got what it asked for.
    peer.bindVerifiedChannelKey(connRemoteKey(conn) orelse return error.ConnectionLost);
    const stream = try irohStreamCreate(peer.allocator, conn, bufs);
    return stream.intoConnection(self.io, peer);
}

fn residentListen(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    config: net.netlayer.ListenConfig,
) net.netlayer.ListenError!Listener {
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
    return .{ .ctx = box, .vtable = &listener_vtable };
}

/// Iroh dial target: node id + optional direct-address hints. Module-level so
/// `DialResolver` and `Backend` share one type without nesting the DialResolver on the Backend.
const connect_target = struct {
    id: []const u8,
    hints: []const u8,
};
pub const ConnectTarget = connect_target;

pub fn resolveConnectTarget(
    locator: model.PeerLocator,
) !ConnectTarget {
    if (!std.mem.eql(u8, locator.transport, model.transport.iroh)) return error.UnknownTransport;
    if (!isCanonicalNodeId(locator.designator)) return error.InvalidAddress;
    return .{
        .id = locator.designator,
        .hints = net.netlayer.directAddrHint(locator.hints) orelse "",
    };
}

/// OCapN locator mapped to an iroh `ConnectTarget` for `completion.Loop`.
/// Canonical node-id shape is refused here so `dialLocator` / blocking dial
/// fail before the network or sidecar admission is touched.
pub const DialResolver = struct {
    pub fn resolve(
        locator: model.PeerLocator,
    ) !Backend.ConnectTarget {
        return .{ .iroh = try resolveConnectTarget(locator) };
    }
};

/// Dial resolver for an iroh completion adapter whose wrapped backend also
/// owns dialable transports. Iroh locators stay at this layer; every other
/// symbol delegates without translating its target or importing that
/// transport's policy here.
pub fn CompositeDialResolver(comptime Platform: type, comptime Delegate: type) type {
    return struct {
        pub fn resolve(
            locator: model.PeerLocator,
        ) !CompletionBackend(Platform).ConnectTarget {
            if (std.mem.eql(u8, locator.transport, model.transport.iroh)) {
                return .{ .iroh = try resolveConnectTarget(locator) };
            }
            return .{ .platform = try Delegate.resolve(locator) };
        }
    };
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
    .accept = listenerAccept,
    .waitAcceptable = listenerWaitAcceptable,
    .localLocator = listenerLocalLocator,
    .canonicalizeLocator = listenerCanonicalizeLocator,
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
    errdefer pancake_iroh_sidecar_conn_free(conn);
    // The transport proof (ADR-0105): QUIC verified the remote endpoint key
    // during the TLS handshake, and this resident is the code that realized
    // the connection, so it is the one that may say so. Bound before any byte
    // is fed, so the pre-open chokepoint sees the evidence when the partner's
    // claim arrives. A connection whose proof cannot be read is refused rather
    // than admitted unbound.
    peer.bindVerifiedChannelKey(connRemoteKey(conn) orelse return error.ConnectionLost);
    const stream = try irohStreamCreate(peer.allocator, conn, bufs);
    return stream.intoConnection(box.resident.io, peer);
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
        box.stashed = pancake_iroh_sidecar_accept_timeout(box.resident.endpoint, slice_ms);
        if (box.stashed != null) return true;
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
    var query: [1]u8 = undefined;
    const direct_len = pancake_iroh_sidecar_endpoint_direct_addrs(box.resident.endpoint, &query, 0);
    if (direct_len < 0) return error.BindFailed;
    const direct = try allocator.alloc(u8, @intCast(direct_len));
    defer allocator.free(direct);
    if (pancake_iroh_sidecar_endpoint_direct_addrs(box.resident.endpoint, direct.ptr, direct.len) != direct_len)
        return error.BindFailed;
    var designator: [node_id_len]u8 = undefined;
    _ = box.resident.nodeId(&designator);
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
    locator: model.PeerLocator,
) net.netlayer.ListenError!model.PeerLocator {
    const box: *ListenerBox = @ptrCast(@alignCast(ctx));
    var expected: [node_id_len]u8 = undefined;
    _ = box.resident.nodeId(&expected);
    try validateListenerLocator(&expected, locator);
    return model.clonePeerLocator(allocator, locator);
}

/// Admit a replacement publication for one active iroh endpoint. The endpoint
/// identity is immutable; direct-address hints may change as reachability does.
pub fn validateListenerLocator(
    expected_designator: []const u8,
    locator: model.PeerLocator,
) net.netlayer.ListenError!void {
    model.validatePeerLocator(locator) catch return error.InvalidAddress;
    if (!std.mem.eql(u8, locator.transport, transport_name) or
        !std.mem.eql(u8, locator.designator, expected_designator))
        return error.InvalidAddress;
    _ = resolveConnectTarget(locator) catch return error.InvalidAddress;
}

fn listenerClose(ctx: *anyopaque) void {
    const box: *ListenerBox = @ptrCast(@alignCast(ctx));
    box.stopping.store(true, .release);
    box.operation_gate.lockUncancelable(box.resident.io);
    box.operation_gate.unlock(box.resident.io);
    if (box.stashed) |conn| pancake_iroh_sidecar_conn_free(conn);
    box.allocator.destroy(box);
}

// ── Completion backend: many iroh connections on one `completion.Loop` (ADR-0057) ─

/// An iroh completion adapter over `Platform`. The sidecar's one readiness fd
/// and non-blocking try-I/O share the wrapped backend's wait primitive with
/// delegated transports, so one `completion.Loop`, `driver.Bridge`, and Host
/// action consumer can drive all of them (ADR-0076 convergence).
///
/// Construct with `initBound` over a `Resident`'s endpoint, then
/// `completion.Loop(Backend, DialResolver).initWithBackend`. `initBound` builds
/// the ordinary platform backend; `initBoundWithPlatform` accepts a configured
/// adapter such as keyed-relay. Iroh and stopper readiness are ordinary
/// nonblocking recv operations on borrowed descriptors owned by the resident
/// and wake channel respectively.
pub fn CompletionBackend(comptime Platform: type) type {
    return struct {
        const Self = @This();
        const Namespace = completion.AdapterNamespace(Platform);
        pub const Fd = Platform.Fd;
        pub const adapter_depth = Namespace.depth;
        pub const ListenerAddress = void;
        pub const ConnectTarget = union(enum) {
            iroh: connect_target,
            platform: Platform.ConnectTarget,
        };

        /// Sentinel listen handle: not an OS fd; `openListener` returns it after
        /// arming non-blocking accept on the endpoint.
        pub const listen_fd: Fd = Namespace.fdFromId(0) catch unreachable;

        const Signal = enum(u1) { readiness, wake };

        const Pending = struct {
            read_ud: ?u64 = null,
            write_ud: ?u64 = null,
            write_bytes: ?[]const u8 = null,
            readable_hint: bool = false,
            writable_hint: bool = false,
        };

        const ConnEntry = struct {
            cconn: *CConn,
            pending: Pending = .{},
        };

        const max_accept_stash = 128;

        allocator: std.mem.Allocator,
        platform: Platform,
        /// Borrowed; must outlive the backend.
        resident: *Resident,
        endpoint: *CEndpoint,
        readiness_fd: Fd,
        accept_enabled: bool = false,
        readiness_armed: bool = false,
        /// Completions that need no further readiness (closes, immediate accepts
        /// from the stash, hint-satisfied recv/send, drained dials), drained before blocking.
        ready: completion.ReadyQueue = .{},
        /// Queue seats owned by admitted iroh operations that have not completed
        /// yet. Capacity is not a reservation: two pending operations both
        /// calling ensureUnusedCapacity(1) can claim the same last slot. This
        /// count makes admission cumulative and lets completion stay infallible
        /// after sidecar bytes or an event have been consumed.
        ready_reserved: usize = 0,
        /// Accepted connections waiting for a `submitAccept` to claim them — edge-
        /// triggered accept can queue several before the loop re-arms.
        accept_stash: std.ArrayList(*CConn) = .empty,
        accept_ud: ?u64 = null,
        /// Synthetic fd to sidecar connection. Fd 0 is the listen sentinel.
        conns: std.AutoHashMap(Fd, ConnEntry),
        /// Sidecar stable connection identity to synthetic fd, for readiness records.
        by_id: std.AutoHashMap(usize, Fd),
        /// Reserved synthetic fd to connect completion user data. The fd is also the
        /// sidecar request id, making cancellation and retirement addressable.
        pending_dials: std.AutoHashMap(Fd, u64),
        /// Stopper wake polled beside the sidecar readiness fd. Iroh readiness is
        /// owned by the sidecar; loop-owner cancellation is a separate userspace
        /// event and should not ride a timeout-polled side channel. The adapter
        /// drains this channel itself after the platform reports readability, so
        /// coalesced nudges cost one owner turn rather than one completion each.
        wake_channel: net.wake_channel.WakeChannel,
        wake_fd: Fd,
        wake_armed: bool = false,
        next_id: u32 = 1,
        scratch_pool: ScratchPool,

        /// Bind a backend to `resident`'s endpoint. The resident must outlive the
        /// loop and be driven by no other consumer for accept/connection I/O.
        pub fn initBound(
            allocator: std.mem.Allocator,
            resident: *Resident,
            queue_entries: u16,
            read_buffers: u16,
            read_buffer_bytes: u32,
        ) !Self {
            const platform = try Platform.init(allocator, queue_entries, read_buffers, read_buffer_bytes);
            return initBoundWithPlatform(allocator, resident, platform, read_buffers, read_buffer_bytes);
        }

        /// Bind iroh over an already-configured platform adapter. Ownership of
        /// `platform` transfers on entry, including every error path.
        pub fn initBoundWithPlatform(
            allocator: std.mem.Allocator,
            resident: *Resident,
            platform: Platform,
            read_buffers: u16,
            read_buffer_bytes: u32,
        ) !Self {
            var owned_platform = platform;
            errdefer owned_platform.deinit();
            const wake_channel = try net.wake_channel.WakeChannel.open();
            errdefer wake_channel.deinit();
            var scratch_pool = try ScratchPool.init(allocator, read_buffers, read_buffer_bytes);
            errdefer scratch_pool.deinit();
            const readiness_source = pancake_iroh_sidecar_endpoint_readiness_fd(resident.endpoint);
            if (readiness_source < 0) return error.ListenFailed;

            return .{
                .allocator = allocator,
                .platform = owned_platform,
                .resident = resident,
                .endpoint = resident.endpoint,
                .readiness_fd = readiness_source,
                .conns = std.AutoHashMap(Fd, ConnEntry).init(allocator),
                .by_id = std.AutoHashMap(usize, Fd).init(allocator),
                .pending_dials = std.AutoHashMap(Fd, u64).init(allocator),
                .wake_channel = wake_channel,
                .wake_fd = wake_channel.read,
                .scratch_pool = scratch_pool,
            };
        }

        pub fn deinit(self: *Self) void {
            var pending_it = self.pending_dials.keyIterator();
            while (pending_it.next()) |fd| self.cancelDial(Namespace.fdId(fd.*));
            self.pending_dials.deinit();

            var it = self.conns.iterator();
            while (it.next()) |entry| {
                pancake_iroh_sidecar_conn_free(entry.value_ptr.cconn);
            }
            self.conns.deinit();
            self.by_id.deinit();
            for (self.accept_stash.items) |cconn| pancake_iroh_sidecar_conn_free(cconn);
            self.accept_stash.deinit(self.allocator);
            self.platform.deinit();
            self.wake_channel.deinit();
            self.ready.deinit(self.allocator);
            self.scratch_pool.deinit();
        }

        /// Wake a parked `poll` so owner-thread stop or teardown state can be
        /// observed without timeout polling. Carries no authority and records no
        /// transport readiness; the next harvest drains the nudge and then observes
        /// the state the caller already changed.
        pub fn wake(self: *Self) void {
            self.wake_channel.nudge();
        }

        pub fn openListener(self: *Self, port: u16) !Fd {
            _ = port;
            if (pancake_iroh_sidecar_endpoint_set_nonblocking_accept(self.endpoint) != 0)
                return error.ListenFailed;
            self.accept_enabled = true;
            return listen_fd;
        }

        /// Start an outbound dial in the layer that resolved it. Iroh reserves a
        /// synthetic handle immediately; delegated targets retain the wrapped
        /// backend's handle and completion semantics unchanged.
        pub fn startDial(self: *Self, user_data: u64, target: Self.ConnectTarget) !Fd {
            return switch (target) {
                .platform => |platform_target| self.platform.startDial(user_data, platform_target),
                .iroh => |iroh_target| blk: {
                    try self.reserveReady(1);
                    errdefer self.releaseReady(1);
                    const fd = try self.reserveFd();
                    try self.pending_dials.put(fd, user_data);
                    errdefer std.debug.assert(self.pending_dials.remove(fd));
                    try self.resident.loopStartConnectResolved(Namespace.fdId(fd), iroh_target.id, iroh_target.hints);
                    break :blk fd;
                },
            };
        }

        pub fn listenerAddress(_: *Self, fd: Fd) !ListenerAddress {
            if (fd != listen_fd) return error.InvalidListener;
        }

        pub fn listenerPort(_: ListenerAddress) ?u16 {
            return null;
        }

        pub fn closeFd(self: *Self, fd: Fd) void {
            if (!Namespace.ownsFd(fd)) return self.platform.closeFd(fd);
            if (fd == listen_fd) return;
            if (self.pending_dials.fetchRemove(fd) != null) {
                self.cancelDial(Namespace.fdId(fd));
                self.releaseReady(1);
                return;
            }
            const entry = self.conns.fetchRemove(fd) orelse return;
            std.debug.assert(self.by_id.remove(self.resident.loopConnId(entry.value.cconn)));
            pancake_iroh_sidecar_conn_free(entry.value.cconn);
        }

        pub fn shutdownFd(self: *Self, fd: Fd) void {
            if (!Namespace.ownsFd(fd)) self.platform.shutdownFd(fd);
        }

        pub fn recycleRecv(self: *Self, comp: completion.Completion) void {
            if (Namespace.ownsRecvToken(comp.recv_token)) {
                self.scratch_pool.release(@intCast(Namespace.recvTokenPayload(comp.recv_token)));
            } else {
                self.platform.recycleRecv(comp);
            }
        }

        fn reserveFd(self: *Self) !Fd {
            if (self.next_id == 0 or self.next_id > Namespace.max_fd_id) return error.OutOfFds;
            const id = self.next_id;
            self.next_id += 1;
            return Namespace.fdFromId(id);
        }

        fn reserveReady(self: *Self, count: usize) !void {
            const total = std.math.add(usize, self.ready_reserved, count) catch return error.OutOfMemory;
            try self.ready.ensureUnusedCapacity(self.allocator, total);
            self.ready_reserved = total;
        }

        fn ensureTransientReady(self: *Self, count: usize) !void {
            const total = std.math.add(usize, self.ready_reserved, count) catch return error.OutOfMemory;
            try self.ready.ensureUnusedCapacity(self.allocator, total);
        }

        fn releaseReady(self: *Self, count: usize) void {
            std.debug.assert(self.ready_reserved >= count);
            self.ready_reserved -= count;
        }

        fn appendReserved(self: *Self, item: completion.Completion) void {
            self.releaseReady(1);
            self.ready.appendAssumeCapacity(item);
        }

        /// Cancellation publishes a terminal sidecar dial record. Consume it
        /// immediately: the adapter has already turned the cancellation into
        /// the Loop's user completion, so leaving the sidecar record around
        /// would retain one entry per canceled dial until endpoint teardown.
        fn cancelDial(self: *Self, request_id: usize) void {
            self.resident.loopCancelConnect(request_id);
            _ = self.resident.loopFinishConnect(request_id) catch {};
        }

        fn bindFd(self: *Self, fd: Fd, cconn: *CConn) !void {
            // Fresh connections are writable; seed the hint so the first hello
            // send is not stranded if a writable edge fired before by_id
            // registration (edge-triggered readiness drops unknown conns).
            try self.conns.put(fd, .{ .cconn = cconn, .pending = .{ .writable_hint = true } });
            errdefer std.debug.assert(self.conns.remove(fd));
            const conn_id = self.resident.loopConnId(cconn);
            if (conn_id == 0) return error.InvalidConnId;
            try self.by_id.put(conn_id, fd);
        }

        fn allocFd(self: *Self, cconn: *CConn) !Fd {
            const fd = try self.reserveFd();
            try self.bindFd(fd, cconn);
            return fd;
        }

        fn takeAccept(self: *Self) void {
            if (!self.accept_enabled) return;
            const ud = self.accept_ud orelse return;
            if (self.accept_stash.items.len == 0) return;
            const cconn = self.accept_stash.orderedRemove(0);
            const fd = self.allocFd(cconn) catch {
                pancake_iroh_sidecar_conn_free(cconn);
                self.appendReserved(.{ .user_data = ud, .result = -1 });
                self.accept_ud = null;
                return;
            };
            self.appendReserved(.{ .user_data = ud, .result = 0, .accepted_fd = fd });
            self.accept_ud = null;
        }

        fn stashAccepts(self: *Self) void {
            while (pancake_iroh_sidecar_endpoint_try_accept(self.endpoint)) |cconn| {
                if (!self.accept_enabled) {
                    pancake_iroh_sidecar_conn_free(cconn);
                    continue;
                }
                if (self.accept_stash.items.len >= max_accept_stash) {
                    // Overload policy: the Zig-side stash is the admission boundary
                    // for accepted loop connections. Drop excess accepts and keep
                    // the backend live; sidecar producer queues are bounded too.
                    pancake_iroh_sidecar_conn_free(cconn);
                    continue;
                }
                if (pancake_iroh_sidecar_conn_set_nonblocking(self.endpoint, cconn) != 0) {
                    pancake_iroh_sidecar_conn_free(cconn);
                    continue;
                }
                self.accept_stash.append(self.allocator, cconn) catch {
                    pancake_iroh_sidecar_conn_free(cconn);
                    continue;
                };
            }
        }

        /// The QUIC-authenticated remote endpoint key for `fd`'s connection, or
        /// null when the connection is gone or the proof cannot be read. This is
        /// the evidence `completion.Loop.verifiedChannelKey` forwards to the bridge,
        /// which asserts it to the engine before the connection's first byte feeds
        /// (ADR-0105). Socket backends have no such decl and the loop answers null
        /// for them.
        pub fn verifiedChannelKey(self: *Self, fd: Fd) ?[crypto.PEER_KEY_BYTES]u8 {
            if (!Namespace.ownsFd(fd)) return self.platform.verifiedChannelKey(fd);
            const entry = self.conns.getPtr(fd) orelse return null;
            const key = connRemoteKey(entry.cconn) orelse return null;
            return key.bytes;
        }

        pub fn submitAccept(self: *Self, user_data: u64, listen: Fd) !void {
            if (!Namespace.ownsFd(listen)) return self.platform.submitAccept(user_data, listen);
            if (listen != listen_fd) return error.InvalidListenFd;
            if (!self.accept_enabled) return error.ListenerClosed;
            if (self.accept_ud != null) return error.AlreadyAccepting;
            try self.reserveReady(1);
            self.accept_ud = user_data;
            self.stashAccepts();
            self.takeAccept();
        }

        fn entryPtr(self: *Self, fd: Fd) !*ConnEntry {
            return self.conns.getPtr(fd) orelse error.InvalidFd;
        }

        fn completeRecv(self: *Self, fd: Fd, entry: *ConnEntry) void {
            const ud = entry.pending.read_ud orelse return;
            var comp: completion.Completion = .{ .user_data = ud, .result = -1 };
            if (self.scratch_pool.acquire()) |idx| {
                const buf = self.scratch_pool.buffer(idx);
                const n = pancake_iroh_sidecar_conn_try_read(entry.cconn, buf.ptr, buf.len);
                if (n == would_block) {
                    // Edge spent without bytes: keep the pending recv; a later
                    // readable (or a left-over hint) will retry.
                    self.scratch_pool.release(idx);
                    entry.pending.readable_hint = false;
                    return;
                }
                if (n > 0) {
                    comp.result = @intCast(n);
                    comp.recv_bytes = buf[0..@intCast(n)];
                    comp.recv_token = Namespace.recvToken(idx);
                    // More may still be buffered: leave the hint so the next
                    // submitRecv completes without waiting for another edge.
                    entry.pending.readable_hint = true;
                } else {
                    // 0 = clean EOF, negative = fault.
                    comp.result = if (n == 0) 0 else -1;
                    self.scratch_pool.release(idx);
                    entry.pending.readable_hint = false;
                }
            } else {
                comp.recv_no_buffer = true;
                // Keep the hint: the loop re-arms once a buffer recycles.
            }
            entry.pending.read_ud = null;
            self.appendReserved(comp);
            _ = fd;
        }

        fn completeSend(self: *Self, entry: *ConnEntry) void {
            const ud = entry.pending.write_ud orelse return;
            const bytes = entry.pending.write_bytes orelse return;
            const n = pancake_iroh_sidecar_conn_try_write(entry.cconn, bytes.ptr, bytes.len);
            var result: i32 = -1;
            if (n == would_block) {
                entry.pending.writable_hint = false;
                return;
            }
            if (n > 0) {
                result = @intCast(n);
                entry.pending.writable_hint = true;
            } else {
                entry.pending.writable_hint = false;
            }
            entry.pending.write_ud = null;
            entry.pending.write_bytes = null;
            self.appendReserved(.{ .user_data = ud, .result = result });
        }

        pub fn submitRecv(self: *Self, user_data: u64, fd: Fd) !void {
            if (!Namespace.ownsFd(fd)) return self.platform.submitRecv(user_data, fd);
            const entry = try self.entryPtr(fd);
            if (entry.pending.read_ud != null) return error.AlreadyReading;
            try self.reserveReady(1);
            entry.pending.read_ud = user_data;
            if (entry.pending.readable_hint) self.completeRecv(fd, entry);
        }

        pub fn submitSend(self: *Self, user_data: u64, fd: Fd, bytes: []const u8) !void {
            if (!Namespace.ownsFd(fd)) return self.platform.submitSend(user_data, fd, bytes);
            const entry = try self.entryPtr(fd);
            if (entry.pending.write_ud != null) return error.AlreadyWriting;
            try self.reserveReady(1);
            entry.pending.write_ud = user_data;
            entry.pending.write_bytes = bytes;
            // Always attempt once: a seeded writable_hint or a live edge may
            // already allow the write; would_block parks until the next edge.
            self.completeSend(entry);
        }

        pub fn submitCancel(
            self: *Self,
            cancel_user_data: u64,
            target_user_data: u64,
            fd: Fd,
        ) !void {
            if (!Namespace.ownsFd(fd))
                return self.platform.submitCancel(cancel_user_data, target_user_data, fd);
            const entry = try self.entryPtr(fd);
            if (entry.pending.read_ud) |ud| {
                if (ud != target_user_data) return error.InvalidCancelTarget;
                // The recv already owns its reserved publication seat.
                try self.reserveReady(1);
                entry.pending.read_ud = null;
                self.appendReserved(.{ .user_data = target_user_data, .result = -1 });
            } else {
                // A synchronous try-read may already have queued the target
                // completion before the Loop can request cancellation.
                try self.reserveReady(1);
            }
            self.appendReserved(.{ .user_data = cancel_user_data, .result = 0 });
        }

        pub fn submitClose(self: *Self, user_data: u64, fd: Fd) !void {
            if (!Namespace.ownsFd(fd)) return self.platform.submitClose(user_data, fd);
            // Every pending accept, dial, read, or write already owns one seat
            // in ready_reserved from its admission. Closing publishes those
            // cancellation records against their existing seats; reserve only
            // the one additional record introduced by this close operation.
            try self.reserveReady(1);
            if (fd == listen_fd) {
                // Cancel a pending accept so Loop.closeAndDrain cannot hang on an
                // idle acceptor; the listen sentinel is not a real conn entry.
                self.accept_enabled = false;
                if (self.accept_ud) |ud| {
                    self.appendReserved(.{ .user_data = ud, .result = -1 });
                    self.accept_ud = null;
                }
                for (self.accept_stash.items) |cconn| pancake_iroh_sidecar_conn_free(cconn);
                self.accept_stash.clearRetainingCapacity();
                self.stashAccepts();
                self.appendReserved(.{ .user_data = user_data, .result = 0 });
                return;
            }
            if (self.pending_dials.fetchRemove(fd)) |done| {
                self.cancelDial(Namespace.fdId(fd));
                self.appendReserved(.{ .user_data = done.value, .result = -1 });
                self.appendReserved(.{ .user_data = user_data, .result = 0 });
                return;
            }
            if (self.conns.getPtr(fd)) |entry| {
                if (entry.pending.read_ud) |ud| self.appendReserved(.{ .user_data = ud, .result = -1 });
                if (entry.pending.write_ud) |ud| self.appendReserved(.{ .user_data = ud, .result = -1 });
                entry.pending = .{};
                std.debug.assert(self.by_id.remove(self.resident.loopConnId(entry.cconn)));
                pancake_iroh_sidecar_conn_free(entry.cconn);
                std.debug.assert(self.conns.remove(fd));
            }
            self.appendReserved(.{ .user_data = user_data, .result = 0 });
        }

        fn dispatchReady(self: *Self, ev: ReadyEvent) void {
            if (ev.events & ev_accept != 0) {
                self.stashAccepts();
                self.takeAccept();
                return;
            }
            if (ev.events & ev_connect != 0) {
                const request_id = std.math.cast(u32, ev.subject) orelse return;
                const fd = Namespace.fdFromId(request_id) catch return;
                const done = self.pending_dials.fetchRemove(fd) orelse return;
                const opaque_conn = self.resident.loopFinishConnect(ev.subject) catch {
                    self.appendReserved(.{ .user_data = done.value, .result = -1 });
                    return;
                };
                const cconn: *CConn = @ptrCast(opaque_conn);
                self.bindFd(fd, cconn) catch {
                    pancake_iroh_sidecar_conn_free(cconn);
                    self.appendReserved(.{ .user_data = done.value, .result = -1 });
                    return;
                };
                self.appendReserved(.{ .user_data = done.value, .result = 0 });
                return;
            }
            const fd = self.by_id.get(ev.subject) orelse return;
            const entry = self.conns.getPtr(fd) orelse return;
            if (ev.events & (ev_readable | ev_closed) != 0) {
                entry.pending.readable_hint = true;
                if (entry.pending.read_ud != null)
                    self.completeRecv(fd, entry);
            }
            if (ev.events & (ev_writable | ev_closed) != 0) {
                entry.pending.writable_hint = true;
                if (entry.pending.write_ud != null) self.completeSend(entry);
            }
        }

        fn takeReady(self: *Self, out: []completion.Completion) usize {
            return self.ready.drain(out);
        }

        fn signalUserData(signal: Signal) u64 {
            return Namespace.userData(@intFromEnum(signal));
        }

        fn armSignals(self: *Self) !void {
            if (!self.readiness_armed) {
                try self.platform.submitRecv(signalUserData(.readiness), self.readiness_fd);
                self.readiness_armed = true;
            }
            if (!self.wake_armed) {
                try self.platform.submitRecv(signalUserData(.wake), self.wake_fd);
                self.wake_armed = true;
            }
        }

        /// Drain one bounded sidecar batch made observable by one readiness byte.
        /// The sidecar re-nudges its descriptor for remaining records. Limiting
        /// this projection to one batch gives delegated platform completions a
        /// turn even while the iroh queue stays continuously hot.
        fn harvestSidecar(self: *Self) !void {
            var events_buf: [256]ReadyEvent = undefined;
            const n = self.resident.drainReady(&events_buf);
            if (n < 0) return error.SidecarDrainFailed;
            const count: usize = @intCast(n);
            for (events_buf[0..count]) |ev| self.dispatchReady(ev);
        }

        fn dispatchPlatform(self: *Self, comp: completion.Completion) !void {
            if (!Namespace.ownsUserData(comp.user_data)) {
                self.ready.appendAssumeCapacity(comp);
                return;
            }

            if (comp.recv_bytes != null) self.platform.recycleRecv(comp);
            const signal: Signal = @enumFromInt(@as(u1, @truncate(Namespace.userDataPayload(comp.user_data))));
            switch (signal) {
                .readiness => self.readiness_armed = false,
                .wake => self.wake_armed = false,
            }
            // A pool-starved recv still proves descriptor readiness. Both
            // signal sources own stack-buffered drain APIs, so progress must not
            // depend on a general transport buffer becoming available.
            if (!comp.recv_no_buffer and comp.result <= 0)
                return error.SignalReadFailed;
            switch (signal) {
                .readiness => try self.harvestSidecar(),
                .wake => {
                    self.wake_channel.drain();
                },
            }
        }

        pub fn poll(self: *Self, out: []completion.Completion, timeout_ms: i32) !usize {
            try self.armSignals();

            var platform_completions: [256]completion.Completion = undefined;
            // Wrapped-platform completions have no iroh admission reservation,
            // so make room for the whole batch without spending the seats each
            // pending iroh operation already owns.
            try self.ensureTransientReady(platform_completions.len);
            const wait_ms: i32 = if (self.ready.len() > 0) 0 else timeout_ms;
            const count = try self.platform.poll(&platform_completions, wait_ms);
            for (platform_completions[0..count]) |comp| {
                try self.dispatchPlatform(comp);
            }

            const ready_count = self.takeReady(out);
            if (ready_count > 0) return ready_count;
            // A stopper wake carries no transport completion. Returning zero lets
            // `runUntil` observe the state the waking thread changed.
            return 0;
        }
    };
}

/// Iroh over the host platform's native completion backend.
pub const Backend = CompletionBackend(net.Backend);
