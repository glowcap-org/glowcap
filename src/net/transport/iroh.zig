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
//! `ConnectedVat` path ADR-0053 settled. For pancake-scale fan-out, `LoopHost`
//! (below) drives the ADR-0057 event-driven superset: the sidecar exposes one
//! readiness fd and non-blocking try-I/O, so one thread multiplexes many iroh
//! connections through the completion-loop shape — the userspace-QUIC analogue
//! of the kernel-fd `net.Loop`, which a userspace QUIC stream cannot register.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");
const actors = @import("actors");
const net = @import("net");
const driver_core = @import("driver_core");
const Served = driver_core.Served;

const crypto = foundation.crypto;
const posix = std.posix;
const Io = std.Io;
const Connection = net.Connection;
const Netlayer = net.netlayer.Netlayer;
const Listener = net.netlayer.Listener;
const Buffers = net.netlayer.Buffers;

/// The transport symbol this resident registers under and signs into
/// `op:start-session`.
pub const transport_name = "iroh";

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
/// hint cannot reach its partner and `dial` refuses such a locator with
/// `error.InvalidAddress` instead of timing out; an endpoint with a discovery
/// posture resolves the partner by id, so the hint is optional there. The name
/// itself is the transport-neutral vocabulary in `net.netlayer` (keyed TCP
/// dials with the same hint), re-exported here so iroh consumers keep this
/// spelling.
pub const hint_direct_addresses = net.netlayer.hint_direct_addresses;

/// An endpoint id is an Ed25519 public key printed as lowercase hex — the one
/// canonical key-designator spelling, owned by
/// `foundation.crypto.PeerKey.toDesignator`: `Resident.nodeId` produces it, and
/// `dial` refuses any other shape with `error.InvalidAddress`.
pub const node_id_len = crypto.PeerKey.designator_len;

// ── The sidecar C ABI (transports/iroh/include/pancake_iroh_sidecar.h) ──────

const CEndpoint = opaque {};
const CConn = opaque {};

extern fn pancake_iroh_sidecar_endpoint_new(secret_seed32: ?*const [32]u8, reachability: u32) ?*CEndpoint;
extern fn pancake_iroh_sidecar_endpoint_node_id(ep: *const CEndpoint, out: [*]u8, out_cap: usize) isize;
extern fn pancake_iroh_sidecar_endpoint_direct_addrs(ep: *const CEndpoint, out: [*]u8, out_cap: usize) isize;
extern fn pancake_iroh_sidecar_connect(ep: *CEndpoint, node_id: [*]const u8, node_id_len: usize, addr_hints: [*]const u8, addr_hints_len: usize) ?*CConn;
extern fn pancake_iroh_sidecar_accept(ep: *CEndpoint) ?*CConn;
extern fn pancake_iroh_sidecar_conn_read(conn: *CConn, buf: [*]u8, len: usize) isize;
extern fn pancake_iroh_sidecar_conn_write(conn: *CConn, buf: [*]const u8, len: usize) isize;
extern fn pancake_iroh_sidecar_conn_flush(conn: *CConn) i32;
extern fn pancake_iroh_sidecar_conn_close(conn: *CConn) void;
extern fn pancake_iroh_sidecar_conn_free(conn: *CConn) void;
extern fn pancake_iroh_sidecar_endpoint_close(ep: *CEndpoint) void;
extern fn pancake_iroh_sidecar_endpoint_free(ep: *CEndpoint) void;

// The event-driven scale superset (ADR-0057): one readiness fd per endpoint, a
// drained ready-queue, and non-blocking frame I/O, so the `LoopHost` below
// serves many connections from one thread.
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

/// The sidecar connection as a `net.stream_shim` byte source. The sidecar write
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

const Shim = net.stream_shim.Shim(ConnSource);
const StreamReader = Shim.Reader;
const StreamWriter = Shim.Writer;

/// One dialed/accepted QUIC stream, pinned so its reader/writer interfaces hold
/// a stable address for the `Connection`'s life (the connection borrows
/// `*std.Io.Reader` / `*std.Io.Writer` into this wrapper, recovered from
/// `&interface` by field offset). Allocated from the peer's allocator at
/// connect/accept and freed by the connection's transport handle on `close` —
/// the same one named per-connection allocation as tcp's `TcpStream`
/// (ADR-0043). Closing it finishes the QUIC stream (the partner reads a clean
/// end of stream) and frees the sidecar connection handle.
const IrohStream = struct {
    reader: StreamReader,
    writer: StreamWriter,
    conn: *CConn,
    allocator: std.mem.Allocator,

    fn create(allocator: std.mem.Allocator, conn: *CConn, bufs: Buffers) std.mem.Allocator.Error!*IrohStream {
        const self = try allocator.create(IrohStream);
        self.* = .{
            .reader = StreamReader.init(.{ .conn = conn }, bufs.read),
            .writer = StreamWriter.init(.{ .conn = conn }, bufs.write),
            .conn = conn,
            .allocator = allocator,
        };
        return self;
    }

    fn intoConnection(self: *IrohStream, io: Io, peer: *engine.Peer) Connection {
        return Connection.init(io, peer, &self.reader.interface, &self.writer.interface, .{
            .ctx = self,
            .close_fn = close,
            .socket_handle_fn = socketHandle,
        });
    }

    fn close(ctx: *anyopaque) void {
        const self: *IrohStream = @ptrCast(@alignCast(ctx));
        pancake_iroh_sidecar_conn_free(self.conn);
        self.allocator.destroy(self);
    }

    fn socketHandle(ctx: *anyopaque) ?Io.net.Socket.Handle {
        _ = ctx;
        return null; // No fd: the QUIC stream is userspace, not pollable.
    }
};

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

    /// Bind an iroh endpoint. `secret_seed` is either null (a fresh random
    /// endpoint key) or 32 bytes of Ed25519 secret key material, borrowed for
    /// the call. `reachability` chooses the endpoint's reachability posture and
    /// is mandatory; there is no default. `io` is captured for the connections
    /// this resident mints.
    pub fn init(io: Io, secret_seed: ?*const [32]u8, reachability: Reachability) InitError!Resident {
        const endpoint = pancake_iroh_sidecar_endpoint_new(secret_seed, @intFromEnum(reachability)) orelse return error.EndpointBindFailed;
        return .{ .io = io, .endpoint = endpoint, .reachability = reachability };
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
    /// stream. An address defect is the caller's, typed `InvalidAddress`
    /// before the network is touched; `ConnectionLost` is reserved for the
    /// dial itself. The returned `*CConn` is owned by the caller, freed with
    /// `pancake_iroh_sidecar_conn_free`.
    fn dialRawConn(self: *Resident, designator: []const u8, direct_addrs: []const u8) net.netlayer.DialError!*CConn {
        if (!isCanonicalNodeId(designator)) return error.InvalidAddress;
        // A `direct` endpoint has no way to find a partner it was not handed an
        // address for, so a hint-less dial is a caller defect, refused before
        // the network. A discovery endpoint resolves the partner by id.
        if (direct_addrs.len == 0 and !self.reachability.resolvesById()) return error.InvalidAddress;
        return pancake_iroh_sidecar_connect(
            self.endpoint,
            designator.ptr,
            designator.len,
            direct_addrs.ptr,
            direct_addrs.len,
        ) orelse return error.ConnectionLost;
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
    // These let a host that owns the loop — `LoopHost` here, or a language
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
    // The direct-address hint is optional under a discovery posture and required
    // under `direct`; `dialRawConn` enforces that, refusing a hint-less direct
    // dial as `error.InvalidAddress` before the network instead of timing out.
    const hints = directAddrHint(locator.hints) orelse "";
    const conn = try self.dialRawConn(locator.designator, hints);
    errdefer pancake_iroh_sidecar_conn_free(conn);
    const stream = try IrohStream.create(peer.allocator, conn, bufs);
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
    const stream = try IrohStream.create(peer.allocator, conn, bufs);
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

// ── The completion-loop source: many iroh connections on one thread (ADR-0057) ─

/// Serve many iroh connections from one thread — the loop-scale counterpart
/// of the blocking resident above, over the sidecar's readiness fd instead of
/// kernel sockets.
///
/// Where the blocking resident above parks one OS thread per connection (one
/// `accept`, one `conn_read`, one `conn_write` each), this host registers the
/// endpoint's single readiness fd once and multiplexes every connection through
/// it. On each wake it drains the sidecar's ready-queue and, for each
/// `(conn, events)` record, drives non-blocking frame I/O on that connection's
/// peer and runs the surfaced events through the connection's own `actors.Vat`.
/// N connections cost one loop source plus the sidecar's fixed runtime threads,
/// not N×2 blocking threads, the cost ADR-0057 exists to remove.
///
/// This source lives in the resident module, not `src/driver`, because it calls
/// the sidecar's `extern` symbols directly; keeping it here preserves the
/// pure-Zig core archives (the resident links the Rust staticlib only in the
/// `iroh-*` build steps). The `Netlayer`/`ConnectedVat` contracts above are
/// untouched: a loop-driven host selects this source, a simple consumer keeps
/// the blocking `acceptVia` path.
pub const LoopHost = struct {
    /// The application's per-connection setup (the shared loop-driver
    /// `driver_core.Publish`): publish the objects this fresh connection
    /// serves (e.g. `try served.publish("name", App, .{})`).
    pub const Publish = driver_core.Publish;

    pub const Options = struct {
        frame_cap: usize = 1 << 16,
        max_conns: usize = 1024,
        /// Verify each partner's keyed start-session signature.
        verify_partner: bool = true,
        /// The identity key every accepted session signs its `op:start-session`
        /// with. Under key unification this is the secret half of the seed the
        /// resident's endpoint was bound on, so the signed session key equals
        /// the node id a partner dialed — which a pinning dialer
        /// (`driver.connectVia` over a key-designator transport) requires.
        /// Null draws a fresh random key at `init`; a partner that dials this
        /// host by node id will then refuse the handshake, so a dialable-by-id
        /// host passes its endpoint secret here.
        secret: ?crypto.SecretKey = null,
        /// Emit `op:gc-exports` / `op:gc-answers` after each inbound deliver /
        /// resolve the connection's vat does not retain imports from — the same
        /// stateless GC `ConnectedVat` offers (one chokepoint, `driver_core.gc`),
        /// so a long-lived encrypted fan-out server's import tables stay bounded
        /// too.
        gc_stateless: bool = false,
        /// The outbound backpressure mark (ADR-0042). While a connection's
        /// pending outbound bytes exceed it, the loop stops draining that
        /// connection's inbound from the sidecar, so the sidecar's inbound
        /// buffer fills and QUIC flow control throttles the partner instead of
        /// this loop's memory growing unbounded. `null` resolves to `frame_cap`.
        outbound_high_water: ?usize = null,
        /// Poll timeout in milliseconds: the loop re-checks its stop condition
        /// this often even with no readiness traffic.
        poll_timeout_ms: i32 = 200,
        /// The most local eventual-send turns one inbound batch may drive before
        /// the connection is closed as a runaway (see
        /// `actors.Vat.max_batch_local_turns`, the default). Set by the operator,
        /// never the partner.
        max_batch_local_turns: usize = actors.Vat.max_batch_local_turns,
    };

    /// When `run` returns: `.forever` for a real server, `.{ .after_closed = n }`
    /// to return once `n` connections have fully closed (the test-shaped stop).
    /// The one stop vocabulary every loop shares (`net.completion.Stop`).
    pub const Stop = net.completion.Stop;

    const Conn = struct {
        state: enum { free, open } = .free,
        cconn: ?*CConn = null,
        peer: engine.Peer = undefined,
        served: Served = undefined,
        /// Bounded overflow for a frame split across `try_read` chunks; inactive
        /// (allocation-free) while whole frames arrive within one read.
        spill: net.Spill = .{},
        /// Outbound frame bytes the loop has encoded but the sidecar has not yet
        /// accepted (a `try_write` that returned `WOULD_BLOCK` leaves them here
        /// until the next `ev_writable`).
        outbound: std.ArrayList(u8) = .empty,
        out_off: usize = 0,
        /// True while inbound draining is paused under ADR-0042 backpressure:
        /// the outbound queue crossed the high-water mark, so the loop leaves
        /// the sidecar's inbound buffered (throttling the partner) until the
        /// outbound drains back below it. `flush`'s full-drain resumes reading.
        read_parked: bool = false,
        /// Intrusive free-list link, meaningful only while the slot is free.
        next_free: usize = 0,
    };

    /// Burst outbound capacity above this bound is freed when the queue fully
    /// drains, so one slow-reader episode does not pin its high-water bytes for
    /// the connection's life. Shared with the TCP loop in one home so the
    /// ladder's per-connection footprint budget cannot split between them.
    const steady_outbound_bytes: usize = net.steady_outbound_bytes;

    resident: *Resident,
    secret: crypto.SecretKey,
    node_id_buf: [node_id_len]u8 = undefined,
    frame_cap: usize,
    outbound_high_water: usize,
    verify_partner: bool,
    poll_timeout_ms: i32,
    max_batch_local_turns: usize,
    gc_stateless: bool,
    publish_fn: Publish,
    publish_ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    conns: []Conn,
    /// Maps a live connection's `*CConn` (as an integer, the identity drained
    /// records carry) to its slot. O(1) lookup per readiness record at scale.
    /// A freed conn's address can be reused by a later accept while stale
    /// readiness records for the dead conn still sit in the sidecar queue, so
    /// a record can misroute to the reused slot — harmless by construction:
    /// ready records are hints, not payload carriers, and a spurious
    /// `try_read`/`flush` on a live connection no-ops. A generation stamp
    /// would close the window if records ever start carrying more than
    /// readiness.
    by_ptr: std.AutoHashMap(usize, usize),
    read_scratch: []u8,
    /// The fixed readiness-drain batch, a stack-shaped buffer like `net.Loop`'s
    /// completion batch: a deeper sidecar queue drains across more passes.
    events_buf: [256]ReadyEvent = undefined,
    free_head: usize,
    closed_count: usize = 0,
    /// Set by `requestStop` from another thread to bring `run` down at the next
    /// poll cycle, independent of the `Stop` condition. The safety net a host
    /// runner uses so a partner that never closes cannot hang the loop.
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub const InitError = error{ EndpointBindFailed, HandshakeEntropyFailed } || std.mem.Allocator.Error;

    /// Bind a loop host over `resident`'s endpoint. `resident` must outlive the
    /// host and be driven by no other consumer (this host owns its accept and
    /// connection I/O). The server identity key is `options.secret` (the
    /// endpoint's own key, under key unification); when null, `io` draws a
    /// fresh one at the I/O boundary. The caller owns the returned host at a
    /// stable address.
    pub fn init(
        allocator: std.mem.Allocator,
        io: Io,
        resident: *Resident,
        publish_fn: Publish,
        publish_ctx: ?*anyopaque,
        options: Options,
    ) InitError!LoopHost {
        const secret = options.secret orelse drawn: {
            var seed: [crypto.SEED_BYTES]u8 = undefined;
            defer std.crypto.secureZero(u8, &seed);
            io.randomSecure(&seed) catch return error.HandshakeEntropyFailed;
            break :drawn crypto.SecretKey.fromSeed(seed);
        };

        const conns = try allocator.alloc(Conn, options.max_conns);
        errdefer allocator.free(conns);
        for (conns, 0..) |*c, i| {
            c.* = .{};
            c.next_free = i + 1;
        }
        const read_scratch = try allocator.alloc(u8, @min(options.frame_cap, 64 * 1024));
        errdefer allocator.free(read_scratch);

        var self = LoopHost{
            .resident = resident,
            .secret = secret,
            .frame_cap = options.frame_cap,
            .outbound_high_water = options.outbound_high_water orelse options.frame_cap,
            .verify_partner = options.verify_partner,
            .poll_timeout_ms = options.poll_timeout_ms,
            .max_batch_local_turns = options.max_batch_local_turns,
            .gc_stateless = options.gc_stateless,
            .publish_fn = publish_fn,
            .publish_ctx = publish_ctx,
            .allocator = allocator,
            .conns = conns,
            .by_ptr = std.AutoHashMap(usize, usize).init(allocator),
            .read_scratch = read_scratch,
            .free_head = 0,
        };
        _ = self.resident.nodeId(&self.node_id_buf);
        return self;
    }

    /// Ask `run` to return at the next poll cycle, from another thread. Safe to
    /// call whether or not `run` is still executing.
    pub fn requestStop(self: *LoopHost) void {
        self.stopping.store(true, .release);
    }

    pub fn deinit(self: *LoopHost) void {
        for (self.conns, 0..) |*c, slot| {
            if (c.state == .open) self.closeConn(slot);
        }
        self.by_ptr.deinit();
        self.allocator.free(self.read_scratch);
        self.allocator.free(self.conns);
    }

    /// Run the loop until `stop`. Arms the endpoint's non-blocking acceptor, then
    /// polls the one readiness fd and drains the ready-queue, dispatching each
    /// connection's readiness to non-blocking I/O on its peer.
    pub fn run(self: *LoopHost, stop: Stop) !void {
        if (pancake_iroh_sidecar_endpoint_set_nonblocking_accept(self.resident.endpoint) != 0) {
            return error.ConnectionLost;
        }
        const fd = pancake_iroh_sidecar_endpoint_readiness_fd(self.resident.endpoint);
        if (fd < 0) return error.ConnectionLost;

        while (!self.stopping.load(.acquire) and switch (stop) {
            .forever => true,
            .after_closed => |n| self.closed_count < n,
        }) {
            var pfd = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
            _ = posix.poll(&pfd, self.poll_timeout_ms) catch 0;
            // Drain the self-pipe wakeup bytes so the next poll re-arms only on
            // fresh signals; the ready-queue, drained below, is the truth. A
            // zero-length read is the write end closing under a live loop —
            // stop draining rather than spin on EOF.
            var drain: [256]u8 = undefined;
            while (true) {
                const drained = posix.read(fd, &drain) catch break;
                if (drained == 0) break;
            }
            // Drain the ready-queue until it empties (a short batch means done).
            // A negative count is a sidecar fault: surface it instead of
            // spinning at the poll cadence against a dead queue forever.
            while (true) {
                const n = pancake_iroh_sidecar_endpoint_drain_ready(self.resident.endpoint, &self.events_buf, self.events_buf.len);
                if (n < 0) return error.SidecarDrainFailed;
                if (n == 0) break;
                const count: usize = @intCast(n);
                for (self.events_buf[0..count]) |ev| self.dispatch(ev);
                if (count < self.events_buf.len) break;
            }
        }
    }

    fn dispatch(self: *LoopHost, ev: ReadyEvent) void {
        if (ev.events & ev_accept != 0) {
            self.acceptAll();
            return;
        }
        if (ev.events & (ev_readable | ev_closed) != 0) {
            if (self.by_ptr.get(ev.conn)) |slot| self.serviceReadable(slot);
        }
        if (ev.events & ev_writable != 0) {
            // serviceReadable above may have closed the connection, so re-resolve.
            if (self.by_ptr.get(ev.conn)) |slot| {
                const was_parked = self.conns[slot].read_parked;
                self.flush(slot);
                // If the writable drained a read parked at the mark (ADR-0042),
                // resume draining the sidecar's throttled inbound now.
                if (was_parked and self.conns[slot].state == .open and !self.conns[slot].read_parked) {
                    self.serviceReadable(slot);
                }
            }
        }
    }

    /// Claim every connection the acceptor has queued, bind each to a fresh peer
    /// and vat, and flush the responder's `op:start-session`.
    fn acceptAll(self: *LoopHost) void {
        while (pancake_iroh_sidecar_endpoint_try_accept(self.resident.endpoint)) |cconn| {
            const slot = self.freeSlot() orelse {
                pancake_iroh_sidecar_conn_free(cconn);
                continue;
            };
            if (pancake_iroh_sidecar_conn_set_nonblocking(self.resident.endpoint, cconn) != 0) {
                pancake_iroh_sidecar_conn_free(cconn);
                self.pushFreeSlot(slot);
                continue;
            }
            if (!self.openConn(slot, cconn)) {
                pancake_iroh_sidecar_conn_free(cconn);
                self.pushFreeSlot(slot);
                continue;
            }
            self.by_ptr.put(@intFromPtr(cconn), slot) catch {
                self.closeConn(slot);
                continue;
            };
            // The responder signs and queues its own start-session; flush it now.
            self.driveOut(slot);
        }
    }

    /// Build the per-connection peer and vat at `slot`. Returns false on a setup
    /// failure (the caller frees the sidecar handle and reclaims the slot).
    fn openConn(self: *LoopHost, slot: usize, cconn: *CConn) bool {
        const c = &self.conns[slot];
        const peer = driver_core.makeKeyedPeer(
            self.allocator,
            self.frame_cap,
            self.verify_partner,
            transport_name,
            self.node_id_buf[0..],
            self.secret,
        ) catch return false;
        c.* = .{ .state = .open, .cconn = cconn, .peer = peer };
        c.served = Served.over(self.allocator, &c.peer);
        c.served.serve_options.gc_stateless = self.gc_stateless;
        self.publish_fn(self.publish_ctx, &c.served) catch {
            c.served.deinit();
            c.peer.deinit();
            c.* = .{};
            return false;
        };
        return true;
    }

    /// Drain this connection's buffered inbound bytes through the peer, run the
    /// surfaced events through its vat, then drive and flush the reply.
    fn serviceReadable(self: *LoopHost, slot: usize) void {
        // Read → apply → drive out, repeating only while a read parked at the
        // outbound mark and the drive's flush then drained it back below the
        // mark. Each pass makes progress (drains fully and continues, or blocks
        // / stays parked and stops), so this is a bounded loop, never recursion.
        while (true) {
            const c = &self.conns[slot];
            var parked = false;
            while (true) {
                // Backpressure (ADR-0042): once outbound crosses the mark, stop
                // draining inbound. The sidecar's inbound buffer fills and QUIC
                // flow control throttles the partner instead of this loop's
                // memory growing unbounded.
                if (self.pendingOut(c) > self.outbound_high_water) {
                    c.read_parked = true;
                    parked = true;
                    break;
                }
                const n = pancake_iroh_sidecar_conn_try_read(c.cconn.?, self.read_scratch.ptr, self.read_scratch.len);
                if (n == would_block) break;
                if (n <= 0) {
                    // 0 is clean end of stream, negative a read error: both close.
                    self.closeConn(slot);
                    return;
                }
                switch (self.feed(c, self.read_scratch[0..@intCast(n)])) {
                    .ok => {},
                    .fail => {
                        self.failConn(slot);
                        return;
                    },
                    .close => {
                        self.closeConn(slot);
                        return;
                    },
                }
            }
            self.runEvents(slot);
            if (self.conns[slot].state != .open) return;
            self.driveOut(slot);
            // If the drive's flush drained a parked read back below the mark,
            // loop to resume reading the sidecar's buffered inbound (the drain
            // is edge-triggered, so no fresh readable event will arrive).
            if (!(parked and !self.conns[slot].read_parked and self.conns[slot].state == .open)) return;
        }
    }

    /// Apply every whole frame in `bytes` to the peer, carrying a partial tail in
    /// the spill. This is the same inbound drain the TCP completion loop runs,
    /// shared in `net.drainWholeFrames`, driven here by `try_read` chunks instead
    /// of a shared pool buffer.
    fn feed(self: *LoopHost, c: *Conn, bytes: []const u8) net.DrainVerdict {
        return net.drainWholeFrames(&c.peer, &c.spill, bytes, self.allocator);
    }

    /// Run every surfaced event through the connection's vat, then drain the
    /// vat's queued local eventual-sends before the outbound flush. A vat error
    /// closes only this connection.
    fn runEvents(self: *LoopHost, slot: usize) void {
        const c = &self.conns[slot];
        while (c.peer.pollEvent()) |ev_in| {
            var ev = ev_in;
            defer ev.deinit();
            c.served.serveEvent(&ev) catch {
                self.failConn(slot);
                return;
            };
        }
        // Drain queued local eventual-sends after the whole inbound batch —
        // the one shared post-batch policy (`Served.drivePostBatch`), so a
        // local-target `send` settles on the encrypted fan-out path with the
        // same runaway bound the tcp loop drivers apply.
        c.served.drivePostBatch(self.max_batch_local_turns) catch {
            self.failConn(slot);
            return;
        };
    }

    /// Encode queued sends and flush them to the sidecar's outbound buffer.
    fn driveOut(self: *LoopHost, slot: usize) void {
        const c = &self.conns[slot];
        while ((c.peer.step() catch {
            self.failConn(slot);
            return;
        }) != .idle) {}
        net.queueOutboundBytes(&c.peer, self.allocator, &c.outbound) catch {
            self.closeConn(slot);
            return;
        };
        self.flush(slot);
    }

    /// Push the connection's pending outbound bytes to the sidecar. A
    /// `WOULD_BLOCK` leaves the remainder queued for the next `ev_writable`; a
    /// short write advances the offset and the loop resubmits the tail.
    fn flush(self: *LoopHost, slot: usize) void {
        const c = &self.conns[slot];
        if (c.state != .open) return;
        while (c.out_off < c.outbound.items.len) {
            const remaining = c.outbound.items[c.out_off..];
            const n = pancake_iroh_sidecar_conn_try_write(c.cconn.?, remaining.ptr, remaining.len);
            if (n == would_block) return;
            // would_block is already handled above, so any non-positive result is
            // a fault: closing this one connection is better than advancing the
            // offset by zero and spinning the single loop thread forever.
            if (n <= 0) {
                self.closeConn(slot);
                return;
            }
            c.out_off += @intCast(n);
        }
        // Fully drained. Free burst capacity above the steady bound so a
        // slow-reader episode does not pin its high-water bytes for life
        // (ADR-0041/0042 posture); steady-sized capacity is retained so
        // ordinary reply traffic never reallocates.
        net.reclaimBurst(&c.outbound, self.allocator, steady_outbound_bytes);
        c.out_off = 0;
        // Fully drained means below the mark: lift any read park so the caller
        // (`serviceReadable`'s loop, or the next `ev_writable`) resumes reading.
        c.read_parked = false;
    }

    /// Pending outbound bytes not yet accepted by the sidecar.
    fn pendingOut(self: *LoopHost, c: *const Conn) usize {
        _ = self;
        return c.outbound.items.len - c.out_off;
    }

    /// Best-effort flush of whatever the engine projected for a dispatch failure
    /// (typically an `op:abort`), then close, mirroring the TCP loop's
    /// `failConn`.
    fn failConn(self: *LoopHost, slot: usize) void {
        const c = &self.conns[slot];
        while ((c.peer.step() catch .idle) != .idle) {}
        // Best-effort: an append failure frees the current frame and leaves
        // the rest on the peer, exactly what a closing connection wants.
        net.queueOutboundBytes(&c.peer, self.allocator, &c.outbound) catch {};
        self.flush(slot);
        self.closeConn(slot);
    }

    fn closeConn(self: *LoopHost, slot: usize) void {
        const c = &self.conns[slot];
        if (c.state != .open) return;
        // Settle every outstanding far vow broken — with the partner's retained
        // abort diagnostic when one arrived — before the vat goes away, so a
        // listener awaiting this connection fires instead of dying unfired.
        c.served.vat.breakFarVows(c.served.closeReason("connection closed"));
        if (c.cconn) |cconn| {
            // tolerant: the accept path calls `closeConn` from its `by_ptr.put`
            // OOM catch, before the entry is inserted, so this removal is not
            // guaranteed present.
            _ = self.by_ptr.remove(@intFromPtr(cconn));
            pancake_iroh_sidecar_conn_free(cconn);
        }
        c.served.deinit();
        c.peer.deinit();
        c.spill.deinit(self.allocator);
        c.outbound.deinit(self.allocator);
        c.* = .{};
        self.pushFreeSlot(slot);
        self.closed_count += 1;
    }

    fn freeSlot(self: *LoopHost) ?usize {
        if (self.free_head >= self.conns.len) return null;
        const slot = self.free_head;
        self.free_head = self.conns[slot].next_free;
        return slot;
    }

    fn pushFreeSlot(self: *LoopHost, slot: usize) void {
        self.conns[slot].next_free = self.free_head;
        self.free_head = slot;
    }
};
