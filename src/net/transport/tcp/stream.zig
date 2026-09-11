//! The blocking TCP byte path: where a raw socket becomes an engine
//! `Connection` or a peer-less `FrameStream`, in both directions.
//!
//! It stays thin on purpose. A locator or address becomes a `std.Io.net.Stream`,
//! which the caller's `std.Io` already hands back as a reader and writer. From
//! there the stream goes to one of two places: a `Connection`, where it's wired to
//! a borrowed `*engine.Peer` that validates and applies as it reads, or a
//! peer-less `FrameStream`, where the host owns the peer (this is what the C ABI
//! endpoints use). Nothing here picks a runtime. The host brings its own `std.Io`
//! (Threaded, Uring, Kqueue, fibers), and `runtime.zig` is the single spot where
//! `Io` turns into syscalls.
//!
//! The typed `Listener` here is the plain `tcp` profile's, the one tests, apps,
//! and the C archive bind by address. The three netlayer residents live in
//! `profile.zig` and share every primitive below.

const std = @import("std");

const model = @import("model");
const engine = @import("engine");
const connection = @import("../../connection.zig");
const frame_stream = @import("../../frame_stream.zig");
const netlayer = @import("../../netlayer.zig");
const addressing = @import("addressing.zig");
const profile_listener = @import("listener.zig");
const runtime = @import("runtime.zig");

const NetLayerListener = netlayer.Listener;
const Buffers = netlayer.Buffers;

const IpAddress = std.Io.net.IpAddress;
const Socket = std.Io.net.Socket;
const Stream = std.Io.net.Stream;

const Connection = connection.Connection;
const FrameStream = frame_stream.FrameStream;

/// Opt-in TCP keepalive (idle/interval/count required). Re-exported so callers
/// configure the blocking path through the socket library, not `completion/`.
pub const Keepalive = runtime.Keepalive;

/// Socket tune applied once when the blocking path turns an `Io` into a stream.
/// `keepalive` null (the default via `{}`) leaves NODELAY-only.
/// When set, see `socket.Keepalive` (NAT hold-open / dead-remote-host reclaim).
pub const StreamOptions = runtime.StreamOptions;
pub const OperationOptions = struct {
    stream: StreamOptions = .{},
};
pub const RawConnection = runtime.Connection;
/// What a raw connect can refuse, in std's own names; `classifyConnect`
/// projects it onto the netlayer's dial vocabulary.
pub const ConnectRawError = IpAddress.ConnectError || runtime.ConfigurationError;

pub fn connectRaw(
    io: std.Io,
    address: IpAddress,
    read_buf: []u8,
    write_buf: []u8,
    options: StreamOptions,
) ConnectRawError!RawConnection {
    return runtime.Connection.connect(io, address, read_buf, write_buf, options);
}

/// One accepted or dialed TCP stream, pinned for the `Connection`'s life. The
/// shared raw-connection shell; its cost is argued at
/// `netlayer_support.PinnedRawStream`.
const TcpStream = netlayer.PinnedRawStream(runtime.Connection);

pub fn connectionOverRaw(
    peer: *engine.Peer,
    raw: runtime.Connection,
) std.mem.Allocator.Error!Connection {
    return TcpStream.adopt(peer, raw);
}

/// The transport symbol carried in a `model.PeerLocator`. `tcp` is what the
/// OCapN conformance TCP netlayer (and Goblins' `^tcp-netlayer`) matches on, so
/// the two peers can address each other; the bytes are cleartext.
const known_transport = model.transport.Known.tcp;
pub const transport_name = known_transport.metadata().symbol;

/// Open a TCP stream to `address` and weld it to `peer`. `io` is named once,
/// here, and captured by the connection's stream reader/writer. The caller owns
/// `read_buf` / `write_buf`; `read_buf` sizes the steady per-connection memory,
/// not the largest admissible frame (a larger frame spills, bounded by
/// `max_frame_bytes`).
/// Post-admission TCP connect: `address` must already be a host:port admitted
/// by `DialResolver.resolve` (or `model.uri.tcpConnectHostPort`). Do not call
/// this to skip OCapN admission.
pub fn connectAddress(
    io: std.Io,
    peer: *engine.Peer,
    address: IpAddress,
    read_buf: []u8,
    write_buf: []u8,
    options: StreamOptions,
) (IpAddress.ConnectError || std.mem.Allocator.Error || runtime.ConfigurationError)!Connection {
    var raw = try runtime.Connection.connect(io, address, read_buf, write_buf, options);
    errdefer raw.close();
    return connectionOverRaw(peer, raw);
}

/// The width of the caller storage `locatorFromAddress` formats a `host:port` designator
/// into. A bracketed IPv6 literal with a port is the widest designator, and it
/// runs to 47 bytes (`[` + 39 hex-and-colon characters + `]` + `:` + a
/// five-digit port), so a 64-byte array holds any designator with room to
/// spare. The buffer being a fixed array of this width is what makes the format
/// in `locator` infallible.
pub const designator_buf_len = profile_listener.designator_buf_len;

/// Build a `tcp` locator for a typed `address`, formatting its `host:port`
/// designator into caller storage `buf`. The transport owns this form, so a
/// caller holding a typed address dials without writing the `model.PeerLocator`
/// literal or the designator format by hand. `buf` is a fixed
/// `designator_buf_len`-byte array because that width holds any designator, so
/// the format cannot run out of room and the `bufPrint` cannot fail. `buf` need
/// only outlive the dial that copies what the session retains. The owning
/// `driver.connect` takes the returned locator directly.
pub fn locatorFromAddress(buf: *[designator_buf_len]u8, address: IpAddress) model.PeerLocator {
    const designator = std.fmt.bufPrint(buf, "{f}", .{address}) catch unreachable;
    return .{ .transport = transport_name, .designator = designator, .hints = model.Hints.emptyFalse() };
}

/// Build a `tcp` locator from a `host:port` `designator` string the caller
/// already holds, the value `argv` hands a client, or a `Server`'s
/// `localDesignator`. This is the buffer-free primary: the designator is the
/// address, so a literal address needs no `IpAddress` parse and no caller format
/// buffer (the netlayer `dial` parses the designator). It owns the empty-hints
/// wire form (`.emptyFalse()`, the form Goblins signs a tcp locator with), so
/// a caller never types `.hints` and the signed `op:start-session` bytes are
/// unchanged. `designator` is borrowed: it must outlive the dial that copies what
/// the session retains.
pub fn locator(designator: []const u8) model.PeerLocator {
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
    const address = try addressing.resolveProfile(known_transport.metadata(), loc.designator, &.{});
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
) (IpAddress.ConnectError || runtime.ConfigurationError)!FrameStream {
    const stream = try runtime.connectStream(io, address, options);
    return FrameStream.initStream(io, allocator, stream, codec_id, max_frame_bytes, read_buf, write_buf);
}

/// Project the std connect fault onto the DialError retry axis (ADR-0081): a
/// refused partner, a missing route, and a timeout are distinct retryable arms;
/// OutOfMemory is transient local pressure; everything else stays ConnectionLost.
pub fn classifyConnect(err: (ConnectRawError || std.mem.Allocator.Error)) netlayer.DialError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ConnectionRefused => error.ConnectionRefused,
        error.HostUnreachable, error.NetworkUnreachable, error.NetworkDown => error.NetworkUnreachable,
        error.Timeout => error.TimedOut,
        error.InvalidKeepalive,
        error.UnsupportedPlatform,
        error.KeepaliveRollbackFailed,
        error.AlreadyConnected,
        error.FileDescriptorNotASocket,
        error.InvalidProtocolOption,
        error.NoDevice,
        error.OperationUnsupported,
        error.PermissionDenied,
        error.SocketNotBound,
        error.SystemResources,
        error.TimeoutTooBig,
        error.Unexpected,
        => error.SocketConfigurationFailed,
        else => error.ConnectionLost,
    };
}

pub fn classifyAccept(err: runtime.AcceptError) netlayer.AcceptError {
    return switch (err) {
        error.ConnectionLost => error.ConnectionLost,
        else => error.SocketConfigurationFailed,
    };
}

/// Profile adapter over the canonical raw TCP listener for the plain `tcp`
/// profile. It adds only the engine/frame projections; socket ownership and
/// concurrency stay in `runtime.Listener`.
pub const Listener = struct {
    profile: profile_listener.Listener,

    pub fn bind(io: std.Io, address: IpAddress) (IpAddress.ListenError || error{WakeChannelFailed})!Listener {
        return .{ .profile = try profile_listener.Listener.bind(known_transport, io, address, null) };
    }

    pub fn localAddress(self: *const Listener) IpAddress {
        return self.profile.localAddress();
    }

    pub fn readinessFd(self: *const Listener) Socket.Handle {
        return self.profile.readinessFd();
    }

    pub fn waitAcceptable(self: *Listener, timeout_ms: i32) runtime.WaitError!bool {
        return self.profile.waitAcceptable(timeout_ms);
    }

    pub fn acceptStream(self: *Listener) netlayer.AcceptError!Stream {
        return self.profile.acceptStream(.{}) catch |err| return classifyAccept(err);
    }

    pub fn acceptRaw(
        self: *Listener,
        read_buf: []u8,
        write_buf: []u8,
        options: StreamOptions,
    ) netlayer.AcceptError!RawConnection {
        return self.profile.acceptRaw(read_buf, write_buf, options) catch |err| return classifyAccept(err);
    }

    pub fn accept(
        self: *Listener,
        peer: *engine.Peer,
        read_buf: []u8,
        write_buf: []u8,
        options: StreamOptions,
    ) (netlayer.AcceptError || std.mem.Allocator.Error)!Connection {
        var raw = self.profile.acceptRaw(read_buf, write_buf, options) catch |err| return classifyAccept(err);
        errdefer raw.close();
        return connectionOverRaw(peer, raw);
    }

    pub fn acceptFrameStream(
        self: *Listener,
        allocator: std.mem.Allocator,
        codec_id: model.CodecId,
        max_frame_bytes: usize,
        read_buf: []u8,
        write_buf: []u8,
        options: StreamOptions,
    ) netlayer.AcceptError!FrameStream {
        const stream = self.profile.acceptStream(options) catch |err| return classifyAccept(err);
        return FrameStream.initStream(self.profile.socket.io, allocator, stream, codec_id, max_frame_bytes, read_buf, write_buf);
    }

    pub fn shutdown(self: *Listener) void {
        self.profile.shutdown();
    }

    pub fn deinit(self: *Listener) void {
        self.profile.deinit();
    }

    /// Borrow this typed listener as a contract `netlayer.Listener`. `close` is
    /// a no-op; the caller still owns this `Listener`.
    pub fn asNetlayer(self: *Listener) NetLayerListener {
        return BorrowedShell.listener(self);
    }
};

/// The contract listener over a caller-owned typed `Listener`: same accept and
/// designator as a resident's owned box, but `close` frees nothing.
const BorrowedShell = netlayer.ListenerShell(struct {
    pub const State = Listener;
    pub const metadata = known_transport.metadata();

    pub fn accept(self: *Listener, peer: *engine.Peer, bufs: Buffers) netlayer.AcceptError!Connection {
        return self.accept(peer, bufs.read, bufs.write, .{});
    }

    pub fn waitAcceptable(self: *Listener, timeout_ms: i32) netlayer.AcceptError!bool {
        return self.waitAcceptable(timeout_ms);
    }

    pub fn localLocator(self: *Listener, allocator: std.mem.Allocator) netlayer.ListenError!model.PeerLocator {
        return self.profile.localLocator(allocator);
    }

    pub fn canonicalizeLocator(
        self: *Listener,
        allocator: std.mem.Allocator,
        proposed: model.PeerLocator,
    ) netlayer.ListenError!model.PeerLocator {
        return self.profile.canonicalizeLocator(allocator, proposed);
    }

    pub fn readinessFd(self: *Listener) i32 {
        return self.readinessFd();
    }

    pub fn close(_: *Listener) ?netlayer.ListenerCloseFailure {
        return null;
    }
});
