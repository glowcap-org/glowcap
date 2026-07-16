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
const posix = std.posix;
const Io = std.Io;
const Connection = net.Connection;
const Netlayer = net.netlayer.Netlayer;
const Listener = net.netlayer.Listener;
const Buffers = net.netlayer.Buffers;

/// The transport symbol this resident registers under and signs into
/// `op:start-session`.
pub const transport_name = model.transport.iroh;

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

extern fn pancake_iroh_sidecar_endpoint_new(secret_seed32: ?*const [32]u8, reachability: u32, connect_timeout_ms: u64) ?*CEndpoint;
extern fn pancake_iroh_sidecar_endpoint_node_id(ep: *const CEndpoint, out: [*]u8, out_cap: usize) isize;
extern fn pancake_iroh_sidecar_endpoint_direct_addrs(ep: *const CEndpoint, out: [*]u8, out_cap: usize) isize;
extern fn pancake_iroh_sidecar_connect(ep: *CEndpoint, node_id: [*]const u8, node_id_len: usize, addr_hints: [*]const u8, addr_hints_len: usize, out_code: *i32) ?*CConn;
extern fn pancake_iroh_sidecar_accept(ep: *CEndpoint) ?*CConn;
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
extern fn pancake_iroh_sidecar_endpoint_set_nonblocking_accept(ep: *CEndpoint) i32;
extern fn pancake_iroh_sidecar_endpoint_try_accept(ep: *CEndpoint) ?*CConn;
extern fn pancake_iroh_sidecar_conn_set_nonblocking(ep: *CEndpoint, conn: *CConn) i32;
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

/// One drained readiness record: the connection that became ready (its `*CConn`
/// as an integer, or 0 for an `ev_accept` record) and the `ev_*` bitset. This is
/// the `extern struct` counterpart of the sidecar's `PancakeIrohReadyEvent` and
/// the header's `pancake_iroh_sidecar_ready_event`; the three layouts are kept
/// in lockstep.
pub const ReadyEvent = extern struct {
    conn: usize,
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
    pub const Config = struct {
        reachability: Reachability,
        connect_timeout_ms: u64 = 0,
    };

    /// Bind an iroh endpoint. `secret_seed` is either null (a fresh random
    /// endpoint key) or 32 bytes of Ed25519 secret key material, borrowed for
    /// the call. `config` carries the mandatory reachability posture and the
    /// optional dial/accept timeout. `io` is captured for the connections this
    /// resident mints.
    pub fn init(io: Io, secret_seed: ?*const [32]u8, config: Config) InitError!Resident {
        const endpoint = pancake_iroh_sidecar_endpoint_new(secret_seed, @intFromEnum(config.reachability), config.connect_timeout_ms) orelse return error.EndpointBindFailed;
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
        // Canonical node-id shape is owned by `DialResolver.resolve` (blocking
        // `residentDial`, C-ABI `loopConnect`, `Loop.dialLocator`). Callers hand
        // an already-admitted id; this path owns reachability hint policy.
        // A `direct` endpoint has no way to find a partner it was not handed an
        // address for, so a hint-less dial is a caller defect, refused before
        // the network. A discovery endpoint resolves the partner by id.
        if (direct_addrs.len == 0 and !self.reachability.resolvesById()) return error.InvalidAddress;
        var code: i32 = 0;
        if (pancake_iroh_sidecar_connect(
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

    /// The endpoint's single OS-level readiness fd, registered once with the
    /// host's poller. Readable whenever the ready-queue has fresh records.
    pub fn readinessFd(self: *Resident) i32 {
        return pancake_iroh_sidecar_endpoint_readiness_fd(self.endpoint);
    }

    /// Drain pending readiness records into `out`, returning the count (0 when
    /// the queue is empty, negative on a sidecar fault). Each record's `conn`
    /// is a `*CConn` as an integer, or 0 for an accept record.
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

    /// Dial a partner (blocking, like the netlayer dial) and hand back a
    /// non-blocking connection handle for the loop surface, or the typed dial
    /// error. The dial itself blocks the calling thread; only subsequent frame
    /// I/O on the returned handle is non-blocking.
    pub fn loopConnect(self: *Resident, designator: []const u8, direct_addrs: []const u8) net.netlayer.DialError!*anyopaque {
        // Admission for standalone / C-ABI callers that have not already gone
        // through `DialResolver.resolve` (completion workers use `loopConnectResolved`).
        const target = DialResolver.resolve(transport_name, designator, direct_addrs) catch return error.InvalidAddress;
        return self.loopConnectResolved(target.id, target.hints);
    }

    /// Post-admission loop dial: `designator` / `direct_addrs` already passed
    /// `DialResolver.resolve` (the `Loop.dialLocator` path). Sets the connection
    /// non-blocking for the completion surface.
    pub fn loopConnectResolved(self: *Resident, designator: []const u8, direct_addrs: []const u8) net.netlayer.DialError!*anyopaque {
        const conn = try self.dialRawConn(designator, direct_addrs);
        if (pancake_iroh_sidecar_conn_set_nonblocking(self.endpoint, conn) != 0) {
            pancake_iroh_sidecar_conn_free(conn);
            return error.ConnectionLost;
        }
        return conn;
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
    /// written, `loop_would_block` when the outbound buffer is at its bound,
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

const resident_vtable: Netlayer.VTable = .{
    .transport_name = transport_name,
    // The designator is the endpoint's Ed25519 key, so a driver dial pins the
    // partner's session identity to it (`net.netlayer.DesignatorScheme`).
    .designator_scheme = .key,
    .dial = residentDial,
    .listen = residentListen,
};

/// The canonical designator shape `Resident.nodeId` produces: exactly
/// `node_id_len` lowercase hex digits. One spelling, owned by
/// `foundation.crypto.PeerKey.fromDesignator`, checked before the sidecar is
/// asked to parse anything.
fn isCanonicalNodeId(designator: []const u8) bool {
    return crypto.PeerKey.fromDesignator(designator) != null;
}

/// The locator's `hint_direct_addresses` string hint, or null when the hint is
/// missing or carries a non-string value (`net.netlayer.directAddrHint`).
const directAddrHint = net.netlayer.directAddrHint;

fn residentDial(
    ctx: *anyopaque,
    peer: *engine.Peer,
    locator: model.PeerLocator,
    bufs: Buffers,
) net.netlayer.DialError!Connection {
    const self: *Resident = @ptrCast(@alignCast(ctx));
    // Same admission as the completion loop: DialResolver.resolve owns transport +
    // canonical node-id; dialRawConn owns reachability hint policy (needs
    // resident posture).
    const hints = directAddrHint(locator.hints) orelse "";
    const target = DialResolver.resolve(locator.transport, locator.designator, hints) catch return error.InvalidAddress;
    const conn = try self.dialRawConn(target.id, target.hints);
    errdefer pancake_iroh_sidecar_conn_free(conn);
    const stream = try irohStreamCreate(peer.allocator, conn, bufs);
    return stream.intoConnection(self.io, peer);
}

fn residentListen(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    config: net.netlayer.ListenConfig,
) net.netlayer.ListenError!Listener {
    const self: *Resident = @ptrCast(@alignCast(ctx));
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
/// `Locator` and `Backend` share one type without nesting the Locator on the Backend.
const connect_target = struct {
    id: []const u8,
    hints: []const u8,
};
pub const ConnectTarget = connect_target;

/// OCapN locator → iroh `ConnectTarget` for `completion.Loop`.
/// Canonical node-id shape is refused here so `dialLocator` / blocking dial
/// fail before the network (or a connect worker) is touched.
pub const DialResolver = struct {
    pub fn resolve(
        transport: []const u8,
        designator: []const u8,
        direct_addresses_hint: []const u8,
    ) !ConnectTarget {
        if (!std.mem.eql(u8, transport, model.transport.iroh)) return error.UnknownTransport;
        if (!isCanonicalNodeId(designator)) return error.InvalidAddress;
        return .{ .id = designator, .hints = direct_addresses_hint };
    }
};

/// A heap-pinned accept seat over the resident's one endpoint, freed by the
/// contract listener's `close`. Closing the listener does not close the
/// endpoint, the resident owns that.
const ListenerBox = struct {
    resident: *Resident,
    allocator: std.mem.Allocator,
};

const listener_vtable: Listener.VTable = .{
    .transport_name = transport_name,
    // Key scheme, like the netlayer: the responder's signed designator derives
    // from its identity key. `localHint` stays null — an iroh accept signs a
    // hint-less locator (the partner already reached us; discovery or the
    // application's own locator record carries dial addresses).
    .designator_scheme = .key,
    .accept = listenerAccept,
    .localDesignator = listenerLocalDesignator,
    .close = listenerClose,
};

fn listenerAccept(ctx: *anyopaque, peer: *engine.Peer, bufs: Buffers) net.netlayer.AcceptError!Connection {
    const box: *ListenerBox = @ptrCast(@alignCast(ctx));
    const conn = pancake_iroh_sidecar_accept(box.resident.endpoint) orelse return error.ConnectionLost;
    errdefer pancake_iroh_sidecar_conn_free(conn);
    const stream = try irohStreamCreate(peer.allocator, conn, bufs);
    return stream.intoConnection(box.resident.io, peer);
}

fn listenerLocalDesignator(ctx: *anyopaque, out: []u8) []const u8 {
    const box: *ListenerBox = @ptrCast(@alignCast(ctx));
    // The contract surface degrades to empty on a short buffer (as tcp's
    // does); the typed surface is `Resident.nodeId`, whose exactly-sized
    // buffer cannot be short.
    if (out.len < node_id_len) return out[0..0];
    return box.resident.nodeId(out[0..node_id_len]);
}

fn listenerClose(ctx: *anyopaque) void {
    const box: *ListenerBox = @ptrCast(@alignCast(ctx));
    box.allocator.destroy(box);
}

// ── Completion backend: many iroh connections on one `completion.Loop` (ADR-0057) ─

/// The iroh completion `Backend` for `net.completion.Loop`. Adapts the
/// sidecar's one readiness fd + non-blocking try-I/O to the same
/// completion-shaped interface the io_uring and kqueue backends provide, so
/// CapTP fan-out rides `driver.Bridge` + `driver_core.Host` instead of a
/// second, diverging loop (ADR-0076 convergence).
///
/// Construct with `initBound` over a `Resident`'s endpoint, then
/// `completion.Loop(Backend, DialResolver).initWithBackend`. Outbound dials
/// resolve OCapN locator parts through `DialResolver.resolve` into `ConnectTarget`,
/// then `startDial` (worker-offloaded `Resident.loopConnectResolved`).
/// Dial stays on a detached worker because `dialRawConn` blocks; wakeup +
/// `harvestReadiness` keep accept/readiness from starving while workers finish.
pub const Backend = struct {
    pub const Fd = i32;
    pub const ConnectTarget = connect_target;

    /// Sentinel listen handle: not an OS fd; `openListener` returns it after
    /// arming non-blocking accept on the endpoint.
    pub const listen_fd: Fd = 0;

    /// Slot fd while an outbound iroh dial is in flight — not a live synthetic
    /// fd. `onConnect` replaces it with the allocFd result (or teardown ignores it).
    pub const pending_dial_fd: Fd = -1;

    const Pending = struct {
        read_ud: ?u64 = null,
        read_is_recv: bool = false,
        write_ud: ?u64 = null,
        write_bytes: ?[]const u8 = null,
        readable_hint: bool = false,
        writable_hint: bool = false,
    };

    const ConnEntry = struct {
        cconn: *CConn,
        pending: Pending = .{},
    };

    /// A finished worker dial, drained on the loop thread so `allocFd` stays
    /// single-threaded over `conns` / `by_ptr`.
    const ConnectDone = struct {
        user_data: u64,
        cconn: ?*CConn,
    };

    allocator: std.mem.Allocator,
    /// Borrowed; must outlive the backend. Dial workers call `loopConnectResolved` on it.
    resident: *Resident,
    endpoint: *CEndpoint,
    readiness_fd: i32 = -1,
    /// Wake the loop when a dial worker finishes (pipe — portable `std.posix`).
    wakeup_r: i32 = -1,
    wakeup_w: i32 = -1,
    /// Completions that need no further readiness (closes, immediate accepts
    /// from the stash, hint-satisfied recv/send, drained dials), drained before blocking.
    ready: std.ArrayList(completion.Completion) = .empty,
    /// Accepted connections waiting for a `submitAccept` to claim them — edge-
    /// triggered accept can queue several before the loop re-arms.
    accept_stash: std.ArrayList(*CConn) = .empty,
    accept_ud: ?u64 = null,
    /// Synthetic fd → sidecar connection. Fd 0 is the listen sentinel.
    conns: std.AutoHashMap(Fd, ConnEntry),
    /// Sidecar `*CConn` identity → synthetic fd, for readiness records.
    by_ptr: std.AutoHashMap(usize, Fd),
    next_fd: Fd = 1,
    scratch_pool: ScratchPool,
    poll_timeout_ms: i32 = 200,
    /// Protects `connect_done` between dial workers and the loop thread.
    /// Short critical sections only — spin, no Io (workers are OS threads).
    connect_mutex: std.atomic.Mutex = .unlocked,
    connect_done: std.ArrayList(ConnectDone) = .empty,
    connects_in_flight: std.atomic.Value(usize) = .init(0),

    /// Bind a backend to `resident`'s endpoint. The resident must outlive the
    /// loop and be driven by no other consumer for accept/connection I/O.
    pub fn initBound(
        allocator: std.mem.Allocator,
        resident: *Resident,
        queue_entries: u16,
        read_buffers: u16,
        read_buffer_bytes: u32,
    ) !Backend {
        _ = queue_entries;
        var scratch_pool = try ScratchPool.init(allocator, read_buffers, read_buffer_bytes);
        errdefer scratch_pool.deinit();

        const wakeup = try openWakeup();
        errdefer closeWakeup(wakeup.r, wakeup.w);

        return .{
            .allocator = allocator,
            .resident = resident,
            .endpoint = resident.endpoint,
            .wakeup_r = wakeup.r,
            .wakeup_w = wakeup.w,
            .conns = std.AutoHashMap(Fd, ConnEntry).init(allocator),
            .by_ptr = std.AutoHashMap(usize, Fd).init(allocator),
            .scratch_pool = scratch_pool,
        };
    }

    pub fn deinit(self: *Backend) void {
        while (self.connects_in_flight.load(.acquire) != 0) {
            std.Thread.yield() catch {};
        }
        lockConnect(&self.connect_mutex);
        for (self.connect_done.items) |done| {
            if (done.cconn) |cconn| pancake_iroh_sidecar_conn_free(cconn);
        }
        self.connect_done.deinit(self.allocator);
        unlockConnect(&self.connect_mutex);
        closeWakeup(self.wakeup_r, self.wakeup_w);
        self.wakeup_r = -1;
        self.wakeup_w = -1;

        var it = self.conns.iterator();
        while (it.next()) |entry| {
            pancake_iroh_sidecar_conn_free(entry.value_ptr.cconn);
        }
        self.conns.deinit();
        self.by_ptr.deinit();
        for (self.accept_stash.items) |cconn| pancake_iroh_sidecar_conn_free(cconn);
        self.accept_stash.deinit(self.allocator);
        self.ready.deinit(self.allocator);
        self.scratch_pool.deinit();
    }

    pub fn openListener(self: *Backend, port: u16) !Fd {
        _ = port;
        if (pancake_iroh_sidecar_endpoint_set_nonblocking_accept(self.endpoint) != 0)
            return error.ListenFailed;
        const fd = pancake_iroh_sidecar_endpoint_readiness_fd(self.endpoint);
        if (fd < 0) return error.ListenFailed;
        self.readiness_fd = fd;
        return listen_fd;
    }

    /// Start an outbound iroh dial: spawn the connect worker and return the
    /// pending-dial sentinel. The synthetic fd arrives on connect completion.
    pub fn startDial(self: *Backend, user_data: u64, target: connect_target) !Fd {
        try self.submitConnect(user_data, target);
        return pending_dial_fd;
    }

    pub fn boundPort(fd: Fd) !u16 {
        _ = fd;
        return 0;
    }

    pub fn closeFd(self: *Backend, fd: Fd) void {
        if (fd == listen_fd or fd == pending_dial_fd) return;
        const entry = self.conns.fetchRemove(fd) orelse return;
        std.debug.assert(self.by_ptr.remove(@intFromPtr(entry.value.cconn)));
        pancake_iroh_sidecar_conn_free(entry.value.cconn);
    }

    /// Required Backend contract; iroh has no OS recv to unblock.
    pub fn shutdownFd(self: *Backend, fd: Fd) void {
        _ = self;
        _ = fd;
    }

    pub fn recycleRecv(self: *Backend, comp: completion.Completion) void {
        self.scratch_pool.release(@intCast(comp.recv_token));
    }

    fn allocFd(self: *Backend, cconn: *CConn) !Fd {
        const fd = self.next_fd;
        if (fd == std.math.maxInt(Fd)) return error.OutOfFds;
        self.next_fd += 1;
        // Fresh connections are writable; seed the hint so the first hello
        // send is not stranded if a writable edge fired before by_ptr
        // registration (edge-triggered readiness drops unknown conns).
        try self.conns.put(fd, .{ .cconn = cconn, .pending = .{ .writable_hint = true } });
        errdefer std.debug.assert(self.conns.remove(fd));
        try self.by_ptr.put(@intFromPtr(cconn), fd);
        return fd;
    }

    fn takeAccept(self: *Backend) !void {
        const ud = self.accept_ud orelse return;
        if (self.accept_stash.items.len == 0) return;
        const cconn = self.accept_stash.orderedRemove(0);
        const fd = self.allocFd(cconn) catch {
            pancake_iroh_sidecar_conn_free(cconn);
            try self.ready.append(self.allocator, .{ .user_data = ud, .result = -1 });
            self.accept_ud = null;
            return;
        };
        try self.ready.append(self.allocator, .{ .user_data = ud, .result = fd });
        self.accept_ud = null;
    }

    fn stashAccepts(self: *Backend) void {
        while (pancake_iroh_sidecar_endpoint_try_accept(self.endpoint)) |cconn| {
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

    pub fn submitAccept(self: *Backend, user_data: u64, listen: Fd) !void {
        if (listen != listen_fd) return error.InvalidListenFd;
        self.accept_ud = user_data;
        self.stashAccepts();
        try self.takeAccept();
    }

    fn submitConnect(self: *Backend, user_data: u64, target: connect_target) !void {
        const designator = target.id;
        const hints = target.hints;
        // Node-id shape was validated by `DialResolver.resolve` on the dialLocator path.
        const designator_owned = try self.allocator.dupe(u8, designator);
        errdefer self.allocator.free(designator_owned);
        const hints_owned = try self.allocator.dupe(u8, hints);
        errdefer self.allocator.free(hints_owned);

        _ = self.connects_in_flight.fetchAdd(1, .acq_rel);
        errdefer _ = self.connects_in_flight.fetchSub(1, .acq_rel);

        const thread = try std.Thread.spawn(.{}, connectWorker, .{ self, user_data, designator_owned, hints_owned });
        thread.detach();
    }

    fn connectWorker(self: *Backend, user_data: u64, designator: []u8, hints: []u8) void {
        defer {
            self.allocator.free(designator);
            self.allocator.free(hints);
            _ = self.connects_in_flight.fetchSub(1, .acq_rel);
        }
        const cconn: ?*CConn = blk: {
            const opaque_conn = self.resident.loopConnectResolved(designator, hints) catch break :blk null;
            break :blk @ptrCast(opaque_conn);
        };

        lockConnect(&self.connect_mutex);
        const queued = blk: {
            self.connect_done.append(self.allocator, .{ .user_data = user_data, .cconn = cconn }) catch {
                if (cconn) |c| pancake_iroh_sidecar_conn_free(c);
                // Fallback failure marker so the dial fails observably. A second
                // OOM here drops ConnectDone entirely (no further channel) —
                // accepted residual under ADR-0081; the common single-OOM path
                // already queues cconn=null and the dial fails closed.
                self.connect_done.append(self.allocator, .{ .user_data = user_data, .cconn = null }) catch break :blk false;
                break :blk true;
            };
            break :blk true;
        };
        unlockConnect(&self.connect_mutex);
        if (queued) self.wake();
    }

    fn wake(self: *Backend) void {
        if (self.wakeup_w < 0) return;
        const one: [1]u8 = .{1};
        _ = posix.system.write(self.wakeup_w, &one, 1);
    }

    fn drainConnectDone(self: *Backend) !void {
        lockConnect(&self.connect_mutex);
        var batch = self.connect_done;
        self.connect_done = .empty;
        unlockConnect(&self.connect_mutex);
        defer batch.deinit(self.allocator);

        for (batch.items) |done| {
            if (done.cconn) |cconn| {
                const fd = self.allocFd(cconn) catch {
                    pancake_iroh_sidecar_conn_free(cconn);
                    try self.ready.append(self.allocator, .{ .user_data = done.user_data, .result = -1 });
                    continue;
                };
                try self.ready.append(self.allocator, .{ .user_data = done.user_data, .result = fd });
            } else {
                try self.ready.append(self.allocator, .{ .user_data = done.user_data, .result = -1 });
            }
        }
    }

    fn entryPtr(self: *Backend, fd: Fd) !*ConnEntry {
        return self.conns.getPtr(fd) orelse error.InvalidFd;
    }

    fn completeRecv(self: *Backend, fd: Fd, entry: *ConnEntry) !void {
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
                comp.recv_token = idx;
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
        entry.pending.read_is_recv = false;
        try self.ready.append(self.allocator, comp);
        _ = fd;
    }

    fn completeSend(self: *Backend, entry: *ConnEntry) !void {
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
        try self.ready.append(self.allocator, .{ .user_data = ud, .result = result });
    }

    pub fn submitRecv(self: *Backend, user_data: u64, fd: Fd) !void {
        const entry = try self.entryPtr(fd);
        entry.pending.read_ud = user_data;
        entry.pending.read_is_recv = true;
        if (entry.pending.readable_hint) try self.completeRecv(fd, entry);
    }

    pub fn submitSend(self: *Backend, user_data: u64, fd: Fd, bytes: []const u8) !void {
        const entry = try self.entryPtr(fd);
        entry.pending.write_ud = user_data;
        entry.pending.write_bytes = bytes;
        // Always attempt once: a seeded writable_hint or a live edge may
        // already allow the write; would_block parks until the next edge.
        try self.completeSend(entry);
    }

    pub fn submitClose(self: *Backend, user_data: u64, fd: Fd) !void {
        try self.ready.ensureUnusedCapacity(self.allocator, 3);
        if (fd == listen_fd) {
            // Cancel a pending accept so Loop.closeAndDrain cannot hang on an
            // idle acceptor; the listen sentinel is not a real conn entry.
            if (self.accept_ud) |ud| {
                self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = -1 });
                self.accept_ud = null;
            }
            for (self.accept_stash.items) |cconn| pancake_iroh_sidecar_conn_free(cconn);
            self.accept_stash.clearRetainingCapacity();
            self.ready.appendAssumeCapacity(.{ .user_data = user_data, .result = 0 });
            return;
        }
        if (self.conns.getPtr(fd)) |entry| {
            if (entry.pending.read_ud) |ud| self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = -1 });
            if (entry.pending.write_ud) |ud| self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = -1 });
            entry.pending = .{};
            std.debug.assert(self.by_ptr.remove(@intFromPtr(entry.cconn)));
            pancake_iroh_sidecar_conn_free(entry.cconn);
            std.debug.assert(self.conns.remove(fd));
        }
        self.ready.appendAssumeCapacity(.{ .user_data = user_data, .result = 0 });
    }

    fn dispatchReady(self: *Backend, ev: ReadyEvent) !void {
        if (ev.events & ev_accept != 0) {
            self.stashAccepts();
            try self.takeAccept();
            return;
        }
        const fd = self.by_ptr.get(ev.conn) orelse return;
        const entry = self.conns.getPtr(fd) orelse return;
        if (ev.events & (ev_readable | ev_closed) != 0) {
            entry.pending.readable_hint = true;
            if (entry.pending.read_ud != null and entry.pending.read_is_recv)
                try self.completeRecv(fd, entry);
        }
        if (ev.events & ev_writable != 0) {
            entry.pending.writable_hint = true;
            if (entry.pending.write_ud != null) try self.completeSend(entry);
        }
    }

    fn takeReady(self: *Backend, out: []completion.Completion) usize {
        return completion.drainReady(&self.ready, out);
    }

    /// Non-blocking harvest of dial wakeups and sidecar readiness. Must run
    /// even when `ready` already has send/recv completions — otherwise an
    /// accept that arrived during a busy G↔E exchange stays invisible until
    /// the queue drains, and a redeem dialer's CapTP hello is never answered.
    fn harvestReadiness(self: *Backend) !void {
        try self.drainConnectDone();
        if (self.readiness_fd < 0) return;

        var pfds = [_]posix.pollfd{
            .{ .fd = self.readiness_fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = self.wakeup_r, .events = posix.POLL.IN, .revents = 0 },
        };
        _ = posix.poll(&pfds, 0) catch 0;

        if (pfds[1].revents & (posix.POLL.IN | posix.POLL.ERR | posix.POLL.HUP) != 0) {
            var drain_buf: [64]u8 = undefined;
            while (true) {
                const drained = posix.read(self.wakeup_r, &drain_buf) catch break;
                if (drained == 0) break;
            }
            try self.drainConnectDone();
        }

        if (pfds[0].revents & (posix.POLL.IN | posix.POLL.ERR | posix.POLL.HUP) != 0) {
            var readiness_buf: [256]u8 = undefined;
            while (true) {
                const drained = posix.read(self.readiness_fd, &readiness_buf) catch break;
                if (drained == 0) break;
            }
            var events_buf: [256]ReadyEvent = undefined;
            while (true) {
                const n = pancake_iroh_sidecar_endpoint_drain_ready(self.endpoint, &events_buf, events_buf.len);
                if (n < 0) return error.SidecarDrainFailed;
                if (n == 0) break;
                const count: usize = @intCast(n);
                for (events_buf[0..count]) |ev| try self.dispatchReady(ev);
                if (count < events_buf.len) break;
            }
        }
    }

    pub fn poll(self: *Backend, out: []completion.Completion, timeout_ms: i32) !usize {
        try self.harvestReadiness();
        {
            const n = self.takeReady(out);
            if (n > 0) return n;
        }

        if (self.readiness_fd < 0) return error.NotListening;
        var pfds = [_]posix.pollfd{
            .{ .fd = self.readiness_fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = self.wakeup_r, .events = posix.POLL.IN, .revents = 0 },
        };
        const poll_ms: i32 = if (timeout_ms < 0) self.poll_timeout_ms else timeout_ms;
        _ = posix.poll(&pfds, poll_ms) catch 0;

        // Same harvest body as the non-blocking path — no duplicated drain.
        try self.harvestReadiness();
        {
            const n = self.takeReady(out);
            if (n > 0) return n;
        }

        // Timeout with nothing ready: return 0 so the loop can re-check Stop.
        // `completion.Loop.run` treats an empty poll as continue; a zero return
        // is valid.
        return 0;
    }
};

fn openWakeup() !struct { r: i32, w: i32 } {
    // posix.system.pipe2: libc when linked, Linux syscalls otherwise — never
    // names a platform namespace in this file (arch-check).
    var fds: [2]posix.fd_t = undefined;
    switch (posix.errno(posix.system.pipe2(&fds, .{ .CLOEXEC = true, .NONBLOCK = true }))) {
        .SUCCESS => {},
        else => return error.WakeupFailed,
    }
    return .{ .r = fds[0], .w = fds[1] };
}

fn closeWakeup(r: i32, w: i32) void {
    if (r >= 0) _ = posix.system.close(r);
    if (w >= 0 and w != r) _ = posix.system.close(w);
}

fn lockConnect(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) std.atomic.spinLoopHint();
}

fn unlockConnect(m: *std.atomic.Mutex) void {
    m.unlock();
}
