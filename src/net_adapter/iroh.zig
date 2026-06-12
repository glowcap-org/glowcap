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
//! graph: it is not exported by `net_adapter/mod.zig`, because its extern
//! declarations resolve only when `libpancake_iroh_sidecar.a` is linked, and
//! `test/api_surface_test.zig` references every exported declaration
//! recursively — exporting it would force the Rust staticlib into every gate.
//! The sidecar posture (ADR-0055) keeps `libpancake` pure Zig; the
//! `iroh-interop` build step compiles this file as its own module (importing
//! the `net_adapter` contract module rather than sibling files, so no source
//! file lands in two modules) and links the staticlib.
//!
//! Every sidecar call blocks the calling OS thread (the endpoint runs its own
//! tokio runtime), so this resident serves the cooperative blocking
//! `ConnectedVat` path — the consumer shape ADR-0053 settled — not the
//! completion loop, which multiplexes kernel fds that a userspace QUIC stream
//! does not have.

const std = @import("std");

const model = @import("model");
const engine = @import("engine");
const net_adapter = @import("net_adapter");

const Io = std.Io;
const Connection = net_adapter.Connection;
const Netlayer = net_adapter.Netlayer;
const Listener = net_adapter.Listener;
const Buffers = net_adapter.Buffers;

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
    pub fn resolvesById(self: Reachability) bool {
        return self != .direct;
    }
};

/// The locator hint carrying the partner's comma-separated direct socket
/// addresses (the string `pancake_iroh_sidecar_endpoint_direct_addrs` produces).
/// A `direct` endpoint runs no relay or lookup service, so a dial without this
/// hint cannot reach its partner and `dial` refuses such a locator with
/// `error.InvalidAddress` instead of timing out; an endpoint with a discovery
/// posture resolves the partner by id, so the hint is optional there.
pub const hint_direct_addresses = "direct-addresses";

/// An endpoint id is an Ed25519 public key printed as lowercase hex. This is
/// the one canonical designator spelling: `Resident.nodeId` produces it, and
/// `dial` refuses any other shape with `error.InvalidAddress`.
pub const node_id_len = 64;

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

// ── The stream over one QUIC connection ──────────────────────────────────────

const reader_vtable = Io.Reader.VTable{ .stream = StreamReader.streamImpl, .readVec = StreamReader.readVec };
const writer_vtable = Io.Writer.VTable{ .drain = StreamWriter.drain };

const max_iovecs = 8;

const StreamReader = struct {
    interface: Io.Reader,
    conn: *CConn,

    fn streamImpl(io_r: *Io.Reader, io_w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const dest = limit.slice(try io_w.writableSliceGreedy(1));
        var data: [1][]u8 = .{dest};
        const n = try readVec(io_r, &data);
        io_w.advance(n);
        return n;
    }

    fn readVec(io_r: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
        const self: *StreamReader = @alignCast(@fieldParentPtr("interface", io_r));
        var iovecs: [max_iovecs][]u8 = undefined;
        const dest_n, const data_size = try io_r.writableVector(&iovecs, data);
        const dest = iovecs[0..dest_n];
        std.debug.assert(dest[0].len > 0);
        // A short read into the first writable slice is allowed by the vtable
        // contract; the stream hands over whatever has arrived.
        const n = pancake_iroh_sidecar_conn_read(self.conn, dest[0].ptr, dest[0].len);
        if (n == 0) return error.EndOfStream;
        if (n < 0) return error.ReadFailed;
        const got: usize = @intCast(n);
        if (got > data_size) {
            io_r.end += got - data_size;
            return data_size;
        }
        return got;
    }
};

const StreamWriter = struct {
    interface: Io.Writer,
    conn: *CConn,

    fn drain(io_w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *StreamWriter = @alignCast(@fieldParentPtr("interface", io_w));
        var total: usize = 0;
        const buffered = io_w.buffered();
        if (buffered.len > 0) {
            try self.writeAll(buffered);
            total += buffered.len;
        }
        const slices = data[0 .. data.len - 1];
        for (slices) |slice| {
            if (slice.len == 0) continue;
            try self.writeAll(slice);
            total += slice.len;
        }
        const pattern = data[data.len - 1];
        if (pattern.len > 0) {
            var i: usize = 0;
            while (i < splat) : (i += 1) try self.writeAll(pattern);
            total += pattern.len * splat;
        }
        // QUIC sends written bytes eagerly; this only surfaces a connection
        // that died under the writes.
        if (pancake_iroh_sidecar_conn_flush(self.conn) != 0) return error.WriteFailed;
        return io_w.consume(total);
    }

    /// The sidecar write is synchronous: it copies or sends `bytes` before
    /// returning, so the caller may free them as soon as the call returns —
    /// unlike the completion loop's queued writes, which borrow until retire.
    fn writeAll(self: *StreamWriter, bytes: []const u8) Io.Writer.Error!void {
        if (pancake_iroh_sidecar_conn_write(self.conn, bytes.ptr, bytes.len) < 0) return error.WriteFailed;
    }
};

/// One dialed/accepted QUIC stream, pinned so its reader/writer interfaces hold
/// a stable address for the `Connection`'s life (the connection borrows
/// `*std.Io.Reader` / `*std.Io.Writer` into this wrapper, recovered from
/// `&interface` by field offset). Allocated from the peer's allocator at
/// connect/accept and freed by the connection's transport handle on `deinit` —
/// the same one named per-connection allocation as tcp's `TcpStream`
/// (ADR-0043). Closing it finishes the QUIC stream (the partner reads a clean
/// end of stream) and frees the sidecar connection handle.
///
/// Public so the host-driven C ABI (`src/c_abi/iroh.zig`) can frame whole
/// frames over `reader.interface` / `writer.interface` with the peer-less
/// `net_adapter` frame readers — the iroh counterpart of `tcp.FrameStream`.
/// The `Connection` path (peer reads as it streams) and the `FrameStream` path
/// (host owns the peer) thus share one stream wrapper.
pub const IrohStream = struct {
    reader: StreamReader,
    writer: StreamWriter,
    conn: *CConn,
    allocator: std.mem.Allocator,

    fn create(allocator: std.mem.Allocator, conn: *CConn, bufs: Buffers) std.mem.Allocator.Error!*IrohStream {
        const self = try allocator.create(IrohStream);
        self.* = .{
            .reader = .{
                .interface = .{ .vtable = &reader_vtable, .buffer = bufs.read, .seek = 0, .end = 0 },
                .conn = conn,
            },
            .writer = .{
                .interface = .{ .vtable = &writer_vtable, .buffer = bufs.write },
                .conn = conn,
            },
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

    /// Free the sidecar connection and destroy this wrapper — the typed
    /// counterpart of the `Connection`'s `close` hook, for the host-driven C
    /// ABI frame path that holds the stream directly rather than behind a
    /// `Connection`.
    pub fn deinit(self: *IrohStream) void {
        close(self);
    }

    /// The borrowed reader interface the peer-less frame readers fold over.
    pub fn readerInterface(self: *IrohStream) *Io.Reader {
        return &self.reader.interface;
    }

    /// The borrowed writer interface the peer-less frame writer drains to.
    pub fn writerInterface(self: *IrohStream) *Io.Writer {
        return &self.writer.interface;
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
    /// is mandatory — there is no default. `io` is captured for the connections
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
    fn dialRawConn(self: *Resident, designator: []const u8, direct_addrs: []const u8) net_adapter.DialError!*CConn {
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

    /// Dial a partner and hand back the pinned `IrohStream` so a host that owns
    /// its own peer can frame whole frames over it (the C ABI's frame path).
    /// `read_buf` / `write_buf` are caller-owned and back the stream's
    /// reader/writer; the returned stream is freed with `IrohStream.deinit`.
    pub fn dialStream(
        self: *Resident,
        allocator: std.mem.Allocator,
        designator: []const u8,
        direct_addrs: []const u8,
        read_buf: []u8,
        write_buf: []u8,
    ) net_adapter.DialError!*IrohStream {
        const conn = try self.dialRawConn(designator, direct_addrs);
        errdefer pancake_iroh_sidecar_conn_free(conn);
        return IrohStream.create(allocator, conn, .{ .read = read_buf, .write = write_buf }) catch return error.OutOfMemory;
    }

    /// Block until a partner dials this endpoint and hand back the pinned
    /// `IrohStream` for the host-driven frame path. `ConnectionLost` covers a
    /// closed endpoint (the shutdown lever) as well as a network fault.
    pub fn acceptStream(
        self: *Resident,
        allocator: std.mem.Allocator,
        read_buf: []u8,
        write_buf: []u8,
    ) net_adapter.AcceptError!*IrohStream {
        const conn = pancake_iroh_sidecar_accept(self.endpoint) orelse return error.ConnectionLost;
        errdefer pancake_iroh_sidecar_conn_free(conn);
        return IrohStream.create(allocator, conn, .{ .read = read_buf, .write = write_buf }) catch return error.OutOfMemory;
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
    /// `out` and return the written slice — the `hint_direct_addresses`
    /// value a partner dials with. An endpoint with no direct addresses
    /// yields an empty slice; a buffer that cannot hold the list is the
    /// typed error, never silently empty.
    pub fn directAddrs(self: *const Resident, out: []u8) DirectAddrsError![]const u8 {
        const n = pancake_iroh_sidecar_endpoint_direct_addrs(self.endpoint, out.ptr, out.len);
        if (n < 0) return error.OutputBufferTooSmall;
        return out[0..@intCast(n)];
    }
};

const resident_vtable: Netlayer.VTable = .{
    .transport_name = transport_name,
    .dial = residentDial,
    .listen = residentListen,
};

/// The canonical designator shape `Resident.nodeId` produces: exactly
/// `node_id_len` lowercase hex digits. One spelling, checked before the
/// sidecar is asked to parse anything.
fn isCanonicalNodeId(designator: []const u8) bool {
    if (designator.len != node_id_len) return false;
    for (designator) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

/// The locator's `hint_direct_addresses` string hint, or null when the hint is
/// missing or carries a non-string value.
fn directAddrHint(hints: model.Hints) ?[]const u8 {
    for (hints.entries) |entry| {
        if (!std.mem.eql(u8, entry.name, hint_direct_addresses)) continue;
        switch (entry.value) {
            .string => |s| return s,
            else => return null,
        }
    }
    return null;
}

fn residentDial(
    ctx: *anyopaque,
    peer: *engine.Peer,
    locator: model.PeerLocator,
    bufs: Buffers,
) net_adapter.DialError!Connection {
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
    config: net_adapter.ListenConfig,
) net_adapter.ListenError!Listener {
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
/// endpoint — the resident owns that.
const ListenerBox = struct {
    resident: *Resident,
    allocator: std.mem.Allocator,
};

const listener_vtable: Listener.VTable = .{
    .transport_name = transport_name,
    .accept = listenerAccept,
    .localDesignator = listenerLocalDesignator,
    .close = listenerClose,
};

fn listenerAccept(ctx: *anyopaque, peer: *engine.Peer, bufs: Buffers) net_adapter.AcceptError!Connection {
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
