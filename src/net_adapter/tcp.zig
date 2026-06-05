//! TCP transport — the one file that names sockets / `std.Io.net`.
//!
//! Thin by design: a locator (or address) becomes a `std.Io.net.Stream`, which
//! the caller's chosen `std.Io` already exposes as a `Reader` / `Writer`. That
//! stream is handed to one of two seams — a [`Connection`] (the stream welded to
//! a borrowed `*runtime.Peer`, borrowed-validate apply) or a peer-less
//! [`FrameStream`] (the host owns the peer; the C ABI endpoints sit here). No
//! runtime is chosen here — the host passes its `std.Io` (Threaded / Uring /
//! Kqueue / fibers) and this is the only `Io`-to-syscall site.
//!
//! Transport name is `tcp-testing-only`: cleartext, no TLS, honest naming. It
//! exists to prove the one-parser framing design end-to-end over a real socket;
//! production transports (TLS, QUIC/iroh) layer above the same seams.

const std = @import("std");

const model = @import("../model/mod.zig");
const runtime = @import("../runtime/mod.zig");
const connection = @import("connection.zig");
const frame_stream = @import("frame_stream.zig");

const net = std.Io.net;

pub const Connection = connection.Connection;
pub const FrameStream = frame_stream.FrameStream;

/// The honest transport name carried in a `model.PeerLocator` (cleartext TCP).
pub const transport_name = "tcp-testing-only";

pub const Error = error{
    /// A host string (or a locator's `host:port` designator) was not a parseable
    /// address this transport can dial.
    InvalidAddress,
};

/// Open a TCP stream to `address` and weld it to `peer`. `io` is named once,
/// here, and captured by the connection's stream reader/writer. The caller owns
/// `read_buf` / `write_buf` (see [`Connection.initStream`] for sizing).
pub fn connectAddress(
    io: std.Io,
    peer: *runtime.Peer,
    address: net.IpAddress,
    read_buf: []u8,
    write_buf: []u8,
) net.IpAddress.ConnectError!Connection {
    const stream = try net.IpAddress.connect(&address, io, .{ .mode = .stream });
    return Connection.initStream(io, peer, stream, read_buf, write_buf);
}

/// As [`connectAddress`], resolving `locator`'s `host:port` designator (the
/// `acceptable-location` a peer advertises for reconnect). The locator's
/// `transport` is expected to be [`transport_name`]; this is the adapter-level
/// designator → address mapping.
pub fn connect(
    io: std.Io,
    peer: *runtime.Peer,
    locator: model.PeerLocator,
    read_buf: []u8,
    write_buf: []u8,
) !Connection {
    const address = try parseDesignator(locator.designator);
    return connectAddress(io, peer, address, read_buf, write_buf);
}

/// As [`connectAddress`], but yielding a peer-less [`FrameStream`] (the host-
/// driven frame seam the C ABI sits on, where the host owns the peer).
pub fn connectFrameStream(
    io: std.Io,
    address: net.IpAddress,
    codec_id: model.CodecId,
    max_frame_bytes: usize,
    read_buf: []u8,
    write_buf: []u8,
) net.IpAddress.ConnectError!FrameStream {
    const stream = try net.IpAddress.connect(&address, io, .{ .mode = .stream });
    return FrameStream.initStream(io, stream, codec_id, max_frame_bytes, read_buf, write_buf);
}

/// A bound, listening TCP socket. Accepts inbound connections and welds each to
/// a caller-supplied peer. The listener owns its socket; each accepted
/// [`Connection`] owns its own stream.
pub const Listener = struct {
    server: net.Server,
    io: std.Io,

    /// Bind + listen on `address`. Pass port 0 to let the OS choose; the chosen
    /// port is then readable via [`localAddress`].
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
        peer: *runtime.Peer,
        read_buf: []u8,
        write_buf: []u8,
    ) net.Server.AcceptError!Connection {
        const stream = try self.server.accept(self.io);
        return Connection.initStream(self.io, peer, stream, read_buf, write_buf);
    }

    /// As [`accept`], but yielding a peer-less [`FrameStream`].
    pub fn acceptFrameStream(
        self: *Listener,
        codec_id: model.CodecId,
        max_frame_bytes: usize,
        read_buf: []u8,
        write_buf: []u8,
    ) net.Server.AcceptError!FrameStream {
        const stream = try self.server.accept(self.io);
        return FrameStream.initStream(self.io, stream, codec_id, max_frame_bytes, read_buf, write_buf);
    }

    pub fn deinit(self: *Listener) void {
        self.server.deinit(self.io);
    }
};

/// Resolve a host literal (IPv4 / IPv6, unbracketed) + port into an address.
/// The single address parser: the C ABI endpoints route through it directly, and
/// [`parseDesignator`] (the locator path) splits onto it. Keeps `std.Io.net`
/// named only here.
pub fn parseHostPort(host: []const u8, port: u16) Error!net.IpAddress {
    return net.IpAddress.parse(host, port) catch return Error.InvalidAddress;
}

/// Parse a `host:port` designator (IPv4 / IPv6 literal) into an address. IPv6
/// hosts must be bracketed, e.g. `[::1]:9000`, so the port colon is unambiguous.
/// Splits the designator, then defers to [`parseHostPort`] so there is one
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
