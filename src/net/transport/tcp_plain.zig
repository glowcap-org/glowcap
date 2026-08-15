//! The plain TCP profile: where the blocking path turns a `std.Io` into a TCP socket.
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
const connection = @import("../connection.zig");
const frame_stream = @import("../frame_stream.zig");
const netlayer = @import("../netlayer.zig");
const addressing = @import("tcp_addressing.zig");
const profile_listener = @import("tcp_listener.zig");
const runtime = @import("tcp_runtime.zig");

const Netlayer = netlayer.Netlayer;
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
/// `keepalive` null (the default via `{}`) leaves NODELAY-only — same as before.
/// When set, see `socket.Keepalive` (NAT hold-open / dead-remote-host reclaim).
pub const StreamOptions = runtime.StreamOptions;
pub const OperationOptions = struct {
    stream: StreamOptions = .{},

    pub fn borrowed(self: *const OperationOptions) netlayer.OperationOptions {
        return netlayer.OperationOptions.borrow(OperationOptions, self);
    }
};
pub const RawConnection = runtime.Connection;

pub fn connectRaw(
    io: std.Io,
    address: IpAddress,
    read_buf: []u8,
    write_buf: []u8,
    options: StreamOptions,
) (IpAddress.ConnectError || runtime.ConfigurationError)!RawConnection {
    return runtime.Connection.connect(io, address, read_buf, write_buf, options);
}

/// One accepted/dialed TCP stream, pinned so its reader/writer interfaces hold a
/// stable address for the `Connection`'s life (the connection borrows
/// `*std.Io.Reader` / `*std.Io.Writer` into this wrapper). Allocated from the
/// peer's allocator at connect/accept and freed by the connection's transport
/// handle on `deinit` — one small per-connection allocation on the blocking
/// path, the price of keeping `Connection` transport-neutral.
const TcpStream = struct {
    raw: runtime.Connection,
    allocator: std.mem.Allocator,

    fn close(ctx: *anyopaque) void {
        const self: *TcpStream = @ptrCast(@alignCast(ctx));
        self.raw.close();
        self.allocator.destroy(self);
    }

    fn socketHandle(ctx: *anyopaque) ?Socket.Handle {
        const self: *TcpStream = @ptrCast(@alignCast(ctx));
        return self.raw.readinessFd();
    }
};

pub fn connectionOverRaw(
    peer: *engine.Peer,
    raw: runtime.Connection,
) std.mem.Allocator.Error!Connection {
    const ts = try peer.allocator.create(TcpStream);
    errdefer peer.allocator.destroy(ts);
    ts.* = .{ .raw = raw, .allocator = peer.allocator };
    return Connection.init(raw.io, peer, &ts.raw.reader.interface, &ts.raw.writer.interface, .{
        .ctx = ts,
        .close_fn = TcpStream.close,
        .socket_handle_fn = TcpStream.socketHandle,
    });
}

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
) (std.mem.Allocator.Error || runtime.ConfigurationError)!Connection {
    return connectionOverRaw(peer, try runtime.Connection.over(io, stream, read_buf, write_buf, options));
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
/// designator into caller storage `buf`. The transport owns this spelling, so a
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
/// wire form (`.emptyFalse()`, the spelling Goblins signs a tcp locator with), so
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

/// Profile adapter over the canonical raw TCP listener. It adds only the
/// engine/frame projections; socket ownership and concurrency stay in
/// `tcp_runtime.Listener`.
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
    stream_options: StreamOptions = .{},

    /// This resident as a `Netlayer`. `self` must outlive every connection the
    /// netlayer mints.
    pub fn netlayer(self: *Resident) Netlayer {
        return .{ .ctx = self, .vtable = &resident_vtable };
    }
};

const resident_ctx = netlayer.ResidentContext(Resident);

const resident_vtable: Netlayer.VTable = .{
    .profile = known_transport.metadata(),
    .dial = .{ .blocking = residentDial },
    .listen = residentListen,
    .io = resident_ctx.io,
};

fn residentDial(
    ctx: *anyopaque,
    peer: *engine.Peer,
    loc: model.PeerLocator,
    bufs: Buffers,
    options: netlayer.OperationOptions,
) netlayer.DialError!Connection {
    const self = resident_ctx.of(ctx);
    const override = try options.decode(OperationOptions);
    const stream_options = if (override) |value| value.stream else self.stream_options;
    const address = addressing.resolveProfile(known_transport.metadata(), loc.designator, &.{}) catch return error.InvalidAddress;
    return connectAddress(self.io, peer, address, bufs.read, bufs.write, stream_options) catch |err| classifyConnect(err);
}

/// Project the std connect fault onto the DialError retry axis (ADR-0081): a
/// refused partner, a missing route, and a timeout are distinct retryable arms;
/// OutOfMemory is transient local pressure; everything else stays ConnectionLost.
pub fn classifyConnect(err: (IpAddress.ConnectError || std.mem.Allocator.Error || runtime.ConfigurationError)) netlayer.DialError {
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

fn residentListen(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    config: netlayer.ListenConfig,
) netlayer.ListenStartOutcome {
    return .{ .admitted = residentListenFallible(ctx, allocator, config) catch |err|
        return .{ .failed = .init(err) } };
}

fn residentListenFallible(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    config: netlayer.ListenConfig,
) netlayer.ListenError!netlayer.ListenResult {
    const self = resident_ctx.of(ctx);
    const address = addressing.parseDesignator(config.designator) catch return error.InvalidAddress;
    const box = allocator.create(ListenerBox) catch return error.OutOfMemory;
    errdefer allocator.destroy(box);
    box.* = .{
        .listener = Listener.bind(self.io, address) catch return error.BindFailed,
        .stream_options = if (try config.options.decode(OperationOptions)) |value|
            value.stream
        else
            self.stream_options,
        .allocator = allocator,
    };
    return .{ .ready = .{ .ctx = box, .vtable = &listener_vtable } };
}

/// A heap-pinned `Listener` behind a contract `NetLayerListener`, freed by
/// the contract listener's `close`.
const ListenerBox = struct {
    listener: Listener,
    stream_options: StreamOptions,
    allocator: std.mem.Allocator,
};

const listener_vtable: NetLayerListener.VTable = .{
    .transport_name = transport_name,
    .designator_scheme = known_transport.metadata().designator_scheme,
    .sealed_channel = known_transport.metadata().sealed_channel,
    .accept = listenerAccept,
    .waitAcceptable = listenerWaitAcceptable,
    .localLocator = listenerLocalLocator,
    .canonicalizeLocator = listenerCanonicalizeLocator,
    .readiness_fd = listenerReadinessFd,
    .close = listenerClose,
};

/// Vtable for `Listener.asNetlayer`: same accept/designator as the owned box,
/// but `close` is a no-op so a caller-owned typed listener is not destroyed.
const borrowed_listener_vtable: NetLayerListener.VTable = .{
    .transport_name = transport_name,
    .designator_scheme = known_transport.metadata().designator_scheme,
    .sealed_channel = known_transport.metadata().sealed_channel,
    .accept = borrowedListenerAccept,
    .waitAcceptable = borrowedListenerWaitAcceptable,
    .localLocator = borrowedListenerLocalLocator,
    .canonicalizeLocator = borrowedListenerCanonicalizeLocator,
    .readiness_fd = borrowedListenerReadinessFd,
    .close = borrowedListenerClose,
};

/// Shared accept arm for owned and borrowed netlayer listener vtables (and
/// `tcp_keyed`'s ListenerBox). Maps typed-listener errors onto the contract.
pub fn acceptOnListener(listener: *Listener, peer: *engine.Peer, bufs: Buffers) netlayer.AcceptError!Connection {
    return listener.accept(peer, bufs.read, bufs.write, .{});
}

fn borrowedListenerAccept(ctx: *anyopaque, peer: *engine.Peer, bufs: Buffers) netlayer.AcceptError!Connection {
    return acceptOnListener(@ptrCast(@alignCast(ctx)), peer, bufs);
}

fn borrowedListenerWaitAcceptable(ctx: *anyopaque, timeout_ms: i32) netlayer.AcceptError!bool {
    return waitAcceptableOnListener(@ptrCast(@alignCast(ctx)), timeout_ms);
}

fn borrowedListenerLocalLocator(ctx: *anyopaque, allocator: std.mem.Allocator) netlayer.ListenError!model.PeerLocator {
    const listener: *Listener = @ptrCast(@alignCast(ctx));
    return listener.profile.localLocator(allocator);
}

fn borrowedListenerCanonicalizeLocator(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    proposed: model.PeerLocator,
) netlayer.ListenError!model.PeerLocator {
    const listener: *Listener = @ptrCast(@alignCast(ctx));
    return listener.profile.canonicalizeLocator(allocator, proposed);
}

fn borrowedListenerClose(_: *anyopaque) ?netlayer.ListenerCloseFailure {
    return null;
}

fn listenerAccept(ctx: *anyopaque, peer: *engine.Peer, bufs: Buffers) netlayer.AcceptError!Connection {
    const box: *ListenerBox = @ptrCast(@alignCast(ctx));
    return box.listener.accept(peer, bufs.read, bufs.write, box.stream_options);
}

fn listenerWaitAcceptable(ctx: *anyopaque, timeout_ms: i32) netlayer.AcceptError!bool {
    const box: *ListenerBox = @ptrCast(@alignCast(ctx));
    return waitAcceptableOnListener(&box.listener, timeout_ms);
}

fn listenerLocalLocator(ctx: *anyopaque, allocator: std.mem.Allocator) netlayer.ListenError!model.PeerLocator {
    const box: *ListenerBox = @ptrCast(@alignCast(ctx));
    return box.listener.profile.localLocator(allocator);
}

fn listenerCanonicalizeLocator(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    proposed: model.PeerLocator,
) netlayer.ListenError!model.PeerLocator {
    const box: *ListenerBox = @ptrCast(@alignCast(ctx));
    return box.listener.profile.canonicalizeLocator(allocator, proposed);
}

/// Shared wait arm for owned and borrowed tcp listener vtables (and keyed-tcp).
pub fn waitAcceptableOnListener(listener: *Listener, timeout_ms: i32) netlayer.AcceptError!bool {
    return listener.waitAcceptable(timeout_ms);
}

fn listenerClose(ctx: *anyopaque) ?netlayer.ListenerCloseFailure {
    const box: *ListenerBox = @ptrCast(@alignCast(ctx));
    box.listener.deinit();
    box.allocator.destroy(box);
    return null;
}

fn listenerReadinessFd(ctx: *anyopaque) i32 {
    const box: *ListenerBox = @ptrCast(@alignCast(ctx));
    return box.listener.readinessFd();
}

fn borrowedListenerReadinessFd(ctx: *anyopaque) i32 {
    const listener: *Listener = @ptrCast(@alignCast(ctx));
    return listener.readinessFd();
}
