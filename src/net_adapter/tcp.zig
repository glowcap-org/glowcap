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

const model = @import("model");
const engine = @import("engine");
const connection = @import("connection.zig");
const frame_stream = @import("frame_stream.zig");
const netlayer = @import("netlayer.zig");

const Netlayer = netlayer.Netlayer;
const NetLayerListener = netlayer.Listener;
const Buffers = netlayer.Buffers;

const net = std.Io.net;

pub const Connection = connection.Connection;
pub const TransportHandle = connection.TransportHandle;
pub const FrameStream = frame_stream.FrameStream;

/// One accepted/dialed TCP stream, pinned so its reader/writer interfaces hold a
/// stable address for the `Connection`'s life (the connection borrows
/// `*std.Io.Reader` / `*std.Io.Writer` into this wrapper). Allocated from the
/// peer's allocator at connect/accept and freed by the connection's transport
/// handle on `deinit` — one small per-connection allocation on the blocking
/// path, the price of keeping `Connection` transport-neutral.
const TcpStream = struct {
    reader: net.Stream.Reader,
    writer: net.Stream.Writer,
    io: std.Io,
    allocator: std.mem.Allocator,

    fn close(ctx: *anyopaque) void {
        const self: *TcpStream = @ptrCast(@alignCast(ctx));
        self.reader.stream.close(self.io);
        self.allocator.destroy(self);
    }

    fn socketHandle(ctx: *anyopaque) ?net.Socket.Handle {
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
    stream: net.Stream,
    read_buf: []u8,
    write_buf: []u8,
) std.mem.Allocator.Error!Connection {
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
pub const transport_name = "tcp";

pub const Error = error{
    /// A host string (or a locator's `host:port` designator) was not a parseable
    /// address this transport can dial.
    InvalidAddress,
};

/// Open a TCP stream to `address` and weld it to `peer`. `io` is named once,
/// here, and captured by the connection's stream reader/writer. The caller owns
/// `read_buf` / `write_buf`; `read_buf` sizes the steady per-connection memory,
/// not the largest admissible frame (a larger frame spills, bounded by
/// `max_frame_bytes`).
pub fn connectAddress(
    io: std.Io,
    peer: *engine.Peer,
    address: net.IpAddress,
    read_buf: []u8,
    write_buf: []u8,
) (net.IpAddress.ConnectError || std.mem.Allocator.Error)!Connection {
    const stream = try net.IpAddress.connect(&address, io, .{ .mode = .stream });
    errdefer stream.close(io);
    return connectionOver(io, peer, stream, read_buf, write_buf);
}

/// As `connectAddress`, resolving `locator`'s `host:port` designator (the
/// `acceptable-location` a peer advertises for reconnect). The locator's
/// `transport` is expected to be `transport_name`; this is the adapter-level
/// mapping from designator to address.
pub fn connect(
    io: std.Io,
    peer: *engine.Peer,
    locator: model.PeerLocator,
    read_buf: []u8,
    write_buf: []u8,
) !Connection {
    const address = try parseDesignator(locator.designator);
    return connectAddress(io, peer, address, read_buf, write_buf);
}

/// As `connectAddress`, but yielding a peer-less `FrameStream` (the host-
/// driven frame boundary the C ABI sits on, where the host owns the peer).
pub fn connectFrameStream(
    io: std.Io,
    allocator: std.mem.Allocator,
    address: net.IpAddress,
    codec_id: model.CodecId,
    max_frame_bytes: usize,
    read_buf: []u8,
    write_buf: []u8,
) net.IpAddress.ConnectError!FrameStream {
    const stream = try net.IpAddress.connect(&address, io, .{ .mode = .stream });
    return FrameStream.initStream(io, allocator, stream, codec_id, max_frame_bytes, read_buf, write_buf);
}

/// A bound, listening TCP socket. Accepts inbound connections and welds each to
/// a caller-supplied peer. The listener owns its socket; each accepted
/// `Connection` owns its own stream.
pub const Listener = struct {
    server: net.Server,
    io: std.Io,

    /// Bind + listen on `address`. Pass port 0 to let the OS choose; the chosen
    /// port is then readable via `localAddress`.
    pub fn bind(io: std.Io, address: net.IpAddress) net.IpAddress.ListenError!Listener {
        return .{
            .server = try net.IpAddress.listen(&address, io, .{ .reuse_address = true }),
            .io = io,
        };
    }

    /// The address the listener is bound to, including the OS-resolved port when
    /// bound to port 0.
    pub fn localAddress(self: *const Listener) net.IpAddress {
        return self.server.socket.address;
    }

    /// Block until a client connects, welding the accepted stream to `peer`.
    pub fn accept(
        self: *Listener,
        peer: *engine.Peer,
        read_buf: []u8,
        write_buf: []u8,
    ) (net.Server.AcceptError || std.mem.Allocator.Error)!Connection {
        const stream = try self.server.accept(self.io);
        errdefer stream.close(self.io);
        return connectionOver(self.io, peer, stream, read_buf, write_buf);
    }

    /// As `accept`, but yielding a peer-less `FrameStream`.
    pub fn acceptFrameStream(
        self: *Listener,
        allocator: std.mem.Allocator,
        codec_id: model.CodecId,
        max_frame_bytes: usize,
        read_buf: []u8,
        write_buf: []u8,
    ) net.Server.AcceptError!FrameStream {
        const stream = try self.server.accept(self.io);
        return FrameStream.initStream(self.io, allocator, stream, codec_id, max_frame_bytes, read_buf, write_buf);
    }

    pub fn deinit(self: *Listener) void {
        self.server.deinit(self.io);
    }
};

// --- The tcp netlayer resident -------------------------------------------
//
// `tcp` is the first resident of the netlayer contract: the same `connect` /
// `bind` / `accept` above, presented behind the runtime vtable the driver
// dispatches against. The driver no longer names `tcp`; it resolves a transport
// symbol to a registered resident, and this is the one a host registers for it.

/// The tcp netlayer's state: the host `std.Io` it dials and binds with. The
/// caller owns a `Resident` at a stable address (the netlayer vtable's `ctx`
/// points at it) for as long as the registry holds the netlayer.
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
    locator: model.PeerLocator,
    bufs: Buffers,
) netlayer.DialError!Connection {
    const self: *Resident = @ptrCast(@alignCast(ctx));
    const address = parseDesignator(locator.designator) catch return error.InvalidAddress;
    return connectAddress(self.io, peer, address, bufs.read, bufs.write) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
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

fn listenerAccept(ctx: *anyopaque, peer: *engine.Peer, bufs: Buffers) netlayer.AcceptError!Connection {
    const box: *ListenerBox = @ptrCast(@alignCast(ctx));
    return box.listener.accept(peer, bufs.read, bufs.write) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ConnectionLost,
    };
}

fn listenerLocalDesignator(ctx: *anyopaque, out: []u8) []const u8 {
    const box: *ListenerBox = @ptrCast(@alignCast(ctx));
    return std.fmt.bufPrint(out, "{f}", .{box.listener.localAddress()}) catch out[0..0];
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
pub fn parseHostPort(host: []const u8, port: u16) Error!net.IpAddress {
    return net.IpAddress.parse(host, port) catch return Error.InvalidAddress;
}

/// Parse a `host:port` designator (IPv4 / IPv6 literal) into an address. IPv6
/// hosts must be bracketed, e.g. `[::1]:9000`, so the port colon is unambiguous.
/// Splits the designator, then defers to `parseHostPort` so there is one
/// address parser.
pub fn parseDesignator(designator: []const u8) Error!net.IpAddress {
    const colon = std.mem.lastIndexOfScalar(u8, designator, ':') orelse return Error.InvalidAddress;
    var host = designator[0..colon];
    const port = std.fmt.parseInt(u16, designator[colon + 1 ..], 10) catch return Error.InvalidAddress;
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') {
        host = host[1 .. host.len - 1];
    }
    return parseHostPort(host, port);
}
