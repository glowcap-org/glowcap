//! The TCP transport: where the blocking path turns a `std.Io` into a TCP socket.
//!
//! It stays thin on purpose. A locator or address becomes a `std.Io.net.Stream`,
//! which the caller's `std.Io` already hands back as a reader and writer. From
//! there the stream goes to one of two places: a `Connection`, where it's wired to
//! a borrowed `*engine.Peer` that validates and applies as it reads, or a
//! peer-less `FrameStream`, where the host owns the peer (this is what the C ABI
//! endpoints use). Nothing here picks a runtime. The host brings its own `std.Io`
//! (Threaded, Uring, Kqueue, fibers), and this is the single spot where `Io`
//! turns into syscalls.
//!
//! The transport is named `tcp` — the symbol the OCapN conformance TCP netlayer
//! (Goblins' `^tcp-netlayer`) matches on, so a pancake locator addresses and is
//! addressed by a Goblins `tcp` peer. It is still cleartext, no TLS: the OCapN
//! spec standardizes only `onion`, and `tcp` is the conformance/testing
//! transport both sides speak. Real confidential transports (TLS, QUIC/iroh)
//! layer on top of the same two boundaries.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");
const connection = @import("../connection.zig");
const frame_stream = @import("../frame_stream.zig");
const netlayer = @import("../netlayer.zig");

const crypto = foundation.crypto;

const Netlayer = netlayer.Netlayer;
const NetLayerListener = netlayer.Listener;
const Buffers = netlayer.Buffers;

const IpAddress = std.Io.net.IpAddress;
const Socket = std.Io.net.Socket;
const Stream = std.Io.net.Stream;
const Server = std.Io.net.Server;

const Connection = connection.Connection;
const FrameStream = frame_stream.FrameStream;

const socket = @import("../socket.zig");

/// Opt-in TCP keepalive (idle/interval/count required). Re-exported so callers
/// configure the blocking path through the socket library, not `completion/`.
pub const Keepalive = socket.Keepalive;

/// Socket tune applied once when the blocking path turns an `Io` into a stream.
/// `keepalive` null (the default via `{}`) leaves NODELAY-only — same as before.
/// When set, see `socket.Keepalive` (NAT hold-open / dead-remote-host reclaim).
pub const StreamOptions = struct {
    keepalive: ?Keepalive = null,
};

/// Set `TCP_NODELAY` on a freshly dialed or accepted `stream`, disabling Nagle's
/// algorithm. OCapN is a request/response wire: a peer writes a frame — or, with
/// promise pipelining, a batch of them — and then waits for the reply. Nagle holds
/// a small trailing segment until the prior one is ACKed, and the idle peer only
/// ACKs on its delayed-ACK timer (~40 ms), so every round trip can eat that stall
/// for nothing — and it erases pipelining's whole point, turning a one-round-trip
/// batch back into a timer wait. Best-effort: a stream whose option cannot be set
/// still works, just with Nagle's coalescing. Set once per stream, at the single
/// spot the transport turns an `Io` into a socket.
fn setNoDelay(stream: Stream) void {
    std.posix.setsockopt(
        stream.socket.handle,
        std.posix.IPPROTO.TCP,
        std.posix.TCP.NODELAY,
        &std.mem.toBytes(@as(c_int, 1)),
    ) catch {};
}

/// One place the blocking TCP path tunes a fresh stream: always `TCP_NODELAY`,
/// and optionally keepalive when the caller opted in with explicit timers.
fn configureStream(stream: Stream, keepalive: ?Keepalive) void {
    setNoDelay(stream);
    if (keepalive) |ka| socket.applyKeepalive(stream.socket.handle, ka);
}

/// One accepted/dialed TCP stream, pinned so its reader/writer interfaces hold a
/// stable address for the `Connection`'s life (the connection borrows
/// `*std.Io.Reader` / `*std.Io.Writer` into this wrapper). Allocated from the
/// peer's allocator at connect/accept and freed by the connection's transport
/// handle on `deinit` — one small per-connection allocation on the blocking
/// path, the price of keeping `Connection` transport-neutral.
const TcpStream = struct {
    reader: Stream.Reader,
    writer: Stream.Writer,
    io: std.Io,
    allocator: std.mem.Allocator,

    fn close(ctx: *anyopaque) void {
        const self: *TcpStream = @ptrCast(@alignCast(ctx));
        self.reader.stream.close(self.io);
        self.allocator.destroy(self);
    }

    fn socketHandle(ctx: *anyopaque) ?Socket.Handle {
        const self: *TcpStream = @ptrCast(@alignCast(ctx));
        return self.reader.stream.socket.handle;
    }
};

/// Pin an already-open `stream` on the peer's allocator and weld it to `peer` as
/// a `Connection`. The pinned `TcpStream` keeps the reader/writer interfaces
/// stable and is freed through the connection's transport handle; on error the
/// caller still owns `stream`. The entry for a
/// caller that already holds an accepted/dialed `std.Io.net.Stream` (the
/// conformance harness, which accepts the socket itself); `connectAddress` and
/// `Listener.accept` are the dial/listen forms over it.
pub fn connectionOver(
    io: std.Io,
    peer: *engine.Peer,
    stream: Stream,
    read_buf: []u8,
    write_buf: []u8,
    options: StreamOptions,
) std.mem.Allocator.Error!Connection {
    configureStream(stream, options.keepalive);
    const ts = try peer.allocator.create(TcpStream);
    errdefer peer.allocator.destroy(ts);
    ts.* = .{
        .reader = stream.reader(io, read_buf),
        .writer = stream.writer(io, write_buf),
        .io = io,
        .allocator = peer.allocator,
    };
    return Connection.init(io, peer, &ts.reader.interface, &ts.writer.interface, .{
        .ctx = ts,
        .close_fn = TcpStream.close,
        .socket_handle_fn = TcpStream.socketHandle,
    });
}

/// The transport symbol carried in a `model.PeerLocator`. `tcp` is what the
/// OCapN conformance TCP netlayer (and Goblins' `^tcp-netlayer`) matches on, so
/// the two peers can address each other; the bytes are cleartext.
pub const transport_name = model.transport.tcp;

pub const Error = error{
    /// A host string (or a locator's `host:port` designator) was not a parseable
    /// address this transport can dial.
    InvalidAddress,
    /// The transport symbol is not in the TCP family this module speaks
    /// (`tcp` / `keyed-tcp`). The completion loop's connect path is TCP-only;
    /// other netlayers resolve and dial elsewhere.
    UnknownTransport,
};

/// Open a TCP stream to `address` and weld it to `peer`. `io` is named once,
/// here, and captured by the connection's stream reader/writer. The caller owns
/// `read_buf` / `write_buf`; `read_buf` sizes the steady per-connection memory,
/// not the largest admissible frame (a larger frame spills, bounded by
/// `max_frame_bytes`).
/// Post-admission TCP connect: `address` must already be a `DialResolver.resolve`
/// (or equivalent hostport parse) result. Production dials go through
/// `DialResolver.resolve` → here; do not call this to skip OCapN admission.
pub fn connectAddress(
    io: std.Io,
    peer: *engine.Peer,
    address: IpAddress,
    read_buf: []u8,
    write_buf: []u8,
    options: StreamOptions,
) (IpAddress.ConnectError || std.mem.Allocator.Error)!Connection {
    const stream = try IpAddress.connect(&address, io, .{ .mode = .stream });
    errdefer stream.close(io);
    return connectionOver(io, peer, stream, read_buf, write_buf, options);
}

/// The width of the caller storage `locator` formats a `host:port` designator
/// into. A bracketed IPv6 literal with a port is the widest designator, and it
/// runs to 47 bytes (`[` + 39 hex-and-colon characters + `]` + `:` + a
/// five-digit port), so a 64-byte array holds any designator with room to
/// spare. The buffer being a fixed array of this width is what makes the format
/// in `locator` infallible.
pub const designator_buf_len = 64;

/// Build a `tcp` locator for a literal `address`, formatting its `host:port`
/// designator into caller storage `buf`. The transport owns this spelling, so a
/// caller holding a typed address dials without writing the `model.PeerLocator`
/// literal or the designator format by hand. `buf` is a fixed
/// `designator_buf_len`-byte array because that width holds any designator, so
/// the format cannot run out of room and the `bufPrint` cannot fail. `buf` need
/// only outlive the dial that copies what the session retains. The owning
/// `driver.connect` takes the returned locator directly.
pub fn locator(buf: *[designator_buf_len]u8, address: IpAddress) model.PeerLocator {
    const designator = std.fmt.bufPrint(buf, "{f}", .{address}) catch unreachable;
    return .{ .transport = transport_name, .designator = designator, .hints = model.Hints.emptyFalse() };
}

/// Build a `tcp` locator from a `host:port` `designator` string the caller
/// already holds, the value `argv` hands a client, or a `Server`'s
/// `localDesignator`. This is the buffer-free primary: the designator is the
/// address, so a literal address needs no `IpAddress` parse and no caller format
/// buffer (the netlayer `dial` parses the designator). It owns the empty-hints
/// wire form (`.emptyFalse()`, the spelling Goblins signs a tcp locator with), so
/// a caller never types `.hints` and the signed `op:start-session` bytes are
/// unchanged. `designator` is borrowed: it must outlive the dial that copies what
/// the session retains.
pub fn at(designator: []const u8) model.PeerLocator {
    return .{ .transport = transport_name, .designator = designator, .hints = model.Hints.emptyFalse() };
}

/// As `connectAddress`, resolving `locator`'s `host:port` designator (the
/// `acceptable-location` a peer advertises for reconnect). The locator's
/// `transport` is expected to be `transport_name`; this is the adapter-level
/// mapping from designator to address.
pub fn connect(
    io: std.Io,
    peer: *engine.Peer,
    loc: model.PeerLocator,
    read_buf: []u8,
    write_buf: []u8,
    options: StreamOptions,
) !Connection {
    const address = try DialResolver.resolve(loc.transport, loc.designator, &.{});
    return connectAddress(io, peer, address, read_buf, write_buf, options);
}

/// As `connectAddress`, but yielding a peer-less `FrameStream` (the host-
/// driven frame boundary the C ABI sits on, where the host owns the peer).
pub fn connectFrameStream(
    io: std.Io,
    allocator: std.mem.Allocator,
    address: IpAddress,
    codec_id: model.CodecId,
    max_frame_bytes: usize,
    read_buf: []u8,
    write_buf: []u8,
    options: StreamOptions,
) IpAddress.ConnectError!FrameStream {
    const stream = try IpAddress.connect(&address, io, .{ .mode = .stream });
    configureStream(stream, options.keepalive);
    return FrameStream.initStream(io, allocator, stream, codec_id, max_frame_bytes, read_buf, write_buf);
}

/// A bound, listening TCP socket. Accepts inbound connections and welds each to
/// a caller-supplied peer. The listener owns its socket; each accepted
/// `Connection` owns its own stream.
pub const Listener = struct {
    server: Server,
    io: std.Io,

    /// Bind + listen on `address`. Pass port 0 to let the OS choose; the chosen
    /// port is then readable via `localAddress`.
    pub fn bind(io: std.Io, address: IpAddress) IpAddress.ListenError!Listener {
        return .{
            .server = try IpAddress.listen(&address, io, .{ .reuse_address = true }),
            .io = io,
        };
    }

    /// The address the listener is bound to, including the OS-resolved port when
    /// bound to port 0.
    pub fn localAddress(self: *const Listener) IpAddress {
        return self.server.socket.address;
    }

    /// Block until a client connects, welding the accepted stream to `peer`.
    pub fn accept(
        self: *Listener,
        peer: *engine.Peer,
        read_buf: []u8,
        write_buf: []u8,
        options: StreamOptions,
    ) (Server.AcceptError || std.mem.Allocator.Error)!Connection {
        const stream = try self.server.accept(self.io);
        errdefer stream.close(self.io);
        return connectionOver(self.io, peer, stream, read_buf, write_buf, options);
    }

    /// As `accept`, but yielding a peer-less `FrameStream`.
    pub fn acceptFrameStream(
        self: *Listener,
        allocator: std.mem.Allocator,
        codec_id: model.CodecId,
        max_frame_bytes: usize,
        read_buf: []u8,
        write_buf: []u8,
        options: StreamOptions,
    ) Server.AcceptError!FrameStream {
        const stream = try self.server.accept(self.io);
        configureStream(stream, options.keepalive);
        return FrameStream.initStream(self.io, allocator, stream, codec_id, max_frame_bytes, read_buf, write_buf);
    }

    pub fn deinit(self: *Listener) void {
        self.server.deinit(self.io);
    }

    /// Borrow this typed listener as a contract `netlayer.Listener`. `close` is
    /// a no-op — the caller still owns this `Listener`. `driver.acceptTcp`
    /// uses this so the tcp-named accept shares `acceptVia`'s hello path.
    pub fn asNetlayer(self: *Listener) NetLayerListener {
        return .{ .ctx = self, .vtable = &borrowed_listener_vtable };
    }
};

// --- The tcp netlayer resident -------------------------------------------
//
// `tcp` is the first resident of the netlayer contract: the same `connect` /
// `bind` / `accept` above, presented behind the runtime vtable the driver
// dispatches against. A host registers this resident for the `tcp` transport
// symbol; the driver resolves the locator's transport to a registered resident.

/// The tcp netlayer's state: the host `std.Io` it dials and binds with. The
/// caller owns a `Resident` at a stable address (the netlayer vtable's `ctx`
/// points at it) for as long as the transport slice holds the netlayer.
pub const Resident = struct {
    io: std.Io,

    /// This resident as a `Netlayer`. `self` must outlive every connection the
    /// netlayer mints.
    pub fn netlayer(self: *Resident) Netlayer {
        return .{ .ctx = self, .vtable = &resident_vtable };
    }
};

const resident_vtable: Netlayer.VTable = .{
    .transport_name = transport_name,
    .dial = residentDial,
    .listen = residentListen,
};

fn residentDial(
    ctx: *anyopaque,
    peer: *engine.Peer,
    loc: model.PeerLocator,
    bufs: Buffers,
) netlayer.DialError!Connection {
    const self: *Resident = @ptrCast(@alignCast(ctx));
    const address = DialResolver.resolve(loc.transport, loc.designator, &.{}) catch return error.InvalidAddress;
    return connectAddress(self.io, peer, address, bufs.read, bufs.write, .{}) catch |err| classifyConnect(err);
}

/// Project the std connect fault onto the DialError retry axis (ADR-0081): a
/// refused partner, a missing route, and a timeout are distinct retryable arms;
/// OutOfMemory is transient local pressure; everything else stays ConnectionLost.
pub fn classifyConnect(err: (IpAddress.ConnectError || std.mem.Allocator.Error)) netlayer.DialError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ConnectionRefused => error.ConnectionRefused,
        error.HostUnreachable, error.NetworkUnreachable, error.NetworkDown => error.NetworkUnreachable,
        error.Timeout => error.TimedOut,
        else => error.ConnectionLost,
    };
}

fn residentListen(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    config: netlayer.ListenConfig,
) netlayer.ListenError!NetLayerListener {
    const self: *Resident = @ptrCast(@alignCast(ctx));
    const address = parseDesignator(config.designator) catch return error.InvalidAddress;
    const box = allocator.create(ListenerBox) catch return error.OutOfMemory;
    errdefer allocator.destroy(box);
    box.* = .{
        .listener = Listener.bind(self.io, address) catch return error.BindFailed,
        .allocator = allocator,
    };
    return .{ .ctx = box, .vtable = &listener_vtable };
}

/// A heap-pinned `Listener` behind a contract `NetLayerListener`, freed by
/// the contract listener's `close`.
const ListenerBox = struct {
    listener: Listener,
    allocator: std.mem.Allocator,
};

const listener_vtable: NetLayerListener.VTable = .{
    .transport_name = transport_name,
    .accept = listenerAccept,
    .localDesignator = listenerLocalDesignator,
    .close = listenerClose,
};

/// Vtable for `Listener.asNetlayer`: same accept/designator as the owned box,
/// but `close` is a no-op so a caller-owned typed listener is not destroyed.
const borrowed_listener_vtable: NetLayerListener.VTable = .{
    .transport_name = transport_name,
    .accept = borrowedListenerAccept,
    .localDesignator = borrowedListenerLocalDesignator,
    .close = borrowedListenerClose,
};

/// Shared accept arm for owned and borrowed netlayer listener vtables (and
/// `tcp_keyed`'s ListenerBox). Maps typed-listener errors onto the contract.
pub fn acceptOnListener(listener: *Listener, peer: *engine.Peer, bufs: Buffers) netlayer.AcceptError!Connection {
    return listener.accept(peer, bufs.read, bufs.write, .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ConnectionLost,
    };
}

/// Shared local-address designator / dial-hint formatter for tcp listener
/// vtables (`localDesignator` on plain tcp; `localHint` on keyed-tcp).
pub fn designatorOnListener(listener: *const Listener, out: []u8) []const u8 {
    return std.fmt.bufPrint(out, "{f}", .{listener.localAddress()}) catch out[0..0];
}

fn borrowedListenerAccept(ctx: *anyopaque, peer: *engine.Peer, bufs: Buffers) netlayer.AcceptError!Connection {
    return acceptOnListener(@ptrCast(@alignCast(ctx)), peer, bufs);
}

fn borrowedListenerLocalDesignator(ctx: *anyopaque, out: []u8) []const u8 {
    return designatorOnListener(@ptrCast(@alignCast(ctx)), out);
}

fn borrowedListenerClose(_: *anyopaque) void {}

fn listenerAccept(ctx: *anyopaque, peer: *engine.Peer, bufs: Buffers) netlayer.AcceptError!Connection {
    const box: *ListenerBox = @ptrCast(@alignCast(ctx));
    return acceptOnListener(&box.listener, peer, bufs);
}

fn listenerLocalDesignator(ctx: *anyopaque, out: []u8) []const u8 {
    const box: *ListenerBox = @ptrCast(@alignCast(ctx));
    return designatorOnListener(&box.listener, out);
}

fn listenerClose(ctx: *anyopaque) void {
    const box: *ListenerBox = @ptrCast(@alignCast(ctx));
    box.listener.deinit();
    box.allocator.destroy(box);
}

/// Resolve a host literal (IPv4 / IPv6, unbracketed) + port into an address.
/// The single address parser: the C ABI endpoints route through it directly, and
/// `parseDesignator` (the locator path) splits onto it. Keeps `std.Io.net`
/// named only here.
pub fn parseHostPort(host: []const u8, port: u16) Error!IpAddress {
    return IpAddress.parse(host, port) catch return Error.InvalidAddress;
}

/// Parse a `host:port` designator (IPv4 / IPv6 literal) into an address. IPv6
/// hosts must be bracketed, e.g. `[::1]:9000`, so the port colon is unambiguous.
/// The split itself is `model.uri.splitHostPort`, the one definition of the
/// designator grammar; this defers to `parseHostPort` for the one address
/// parser.
pub fn parseDesignator(designator: []const u8) Error!IpAddress {
    const split = model.uri.splitHostPort(designator) catch return Error.InvalidAddress;
    return parseHostPort(split.host, split.port);
}

/// Resolve locator dial fields to a TCP connect address. This is the one place
/// the TCP family turns transport + designator + `direct-addresses` hint into
/// an `IpAddress`:
///
/// - `tcp`: the designator is `host:port`.
/// - `keyed-tcp`: the designator must be a canonical Ed25519 key; the socket
///   address rides the hint (TCP has no discovery). Empty hint or a non-key
///   designator is `InvalidAddress` before the network is touched.
///
/// Any other transport refuses with `UnknownTransport` — iroh and inproc do
/// not share this connect path. Platform Backends and Bridge never re-implement
/// the grammar; blocking residents and the completion loop both call
/// `DialResolver.resolve`.
pub const DialResolver = struct {
    pub fn resolve(
        transport: []const u8,
        designator: []const u8,
        direct_addresses_hint: []const u8,
    ) Error!IpAddress {
        const hostport = if (std.mem.eql(u8, transport, transport_name))
            designator
        else if (std.mem.eql(u8, transport, model.transport.keyed_tcp)) blk: {
            if (crypto.PeerKey.fromDesignator(designator) == null) return Error.InvalidAddress;
            if (direct_addresses_hint.len == 0) return Error.InvalidAddress;
            break :blk direct_addresses_hint;
        } else return Error.UnknownTransport;
        if (hostport.len == 0) return Error.InvalidAddress;
        return parseDesignator(hostport);
    }
};
