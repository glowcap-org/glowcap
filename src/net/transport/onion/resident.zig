//! The `onion` netlayer resident: dial and accept over the ADR-0043 contract.
//!
//! Neither half is a new kind of socket. A dial is a stream to the local Tor's
//! SOCKS endpoint with a handshake in front of it, and an accept is a stream Tor
//! opened to a local endpoint pancake bound. What reaches CapTP is the ordinary
//! Syrup frame stream either way, so nothing above `net` learns a new shape.
//!
//! The designator is an address, not a key. A version 3 service id encodes an
//! Ed25519 public key and Tor does prove the far end holds it, but what it proves
//! belongs to the rendezvous service rather than to the CapTP peer: the peer is
//! whoever holds the local endpoint that service forwards to. ADR-0108 argues
//! this at length; the consequence here is that the resident declares the default
//! `address` scheme and asserts no channel key.
//!
//! Hosting needs a control endpoint. A resident configured without one can dial
//! and cannot host, which is the right posture for a client that only reaches
//! out, and `listen` refuses rather than silently succeeding.

const std = @import("std");

const engine = @import("engine");
const model = @import("model");

const connection = @import("../../connection.zig");
const frame_stream = @import("../../frame_stream.zig");
const netlayer = @import("../../netlayer.zig");
const poll = @import("../../poll.zig");
const wake_channel = @import("../../wake_channel.zig");

const control = @import("control.zig");
const endpoint_mod = @import("endpoint.zig");
const session_mod = @import("session.zig");
const socks5 = @import("socks5.zig");

const Connection = connection.Connection;
const Endpoint = endpoint_mod.Endpoint;
const ControlSession = session_mod.ControlSession;
const Netlayer = netlayer.Netlayer;
const NetLayerListener = netlayer.Listener;
const Buffers = netlayer.Buffers;

const IpAddress = std.Io.net.IpAddress;
const Server = std.Io.net.Server;
const Stream = std.Io.net.Stream;

/// The transport symbol. `onion` is what the OCapN draft standardizes and what
/// the pinned Goblins netlayer reports as its own name, so a pancake locator
/// addresses and is addressed by a Goblins onion peer.
const known_transport = model.transport.Known.onion;
pub const transport_name = known_transport.metadata().symbol;

/// The unframed byte-stream seam shared by native connections and the C
/// provider. The caller owns the buffers; an empty buffer keeps the provider's
/// host-side buffering as the only extra layer.
pub const RawStream = struct {
    reader: Stream.Reader,
    writer: Stream.Writer,
    io: std.Io,

    pub fn init(io: std.Io, stream: Stream, read_buf: []u8, write_buf: []u8) RawStream {
        return .{
            .reader = stream.reader(io, read_buf),
            .writer = stream.writer(io, write_buf),
            .io = io,
        };
    }

    pub fn read(self: *RawStream, out: []u8) std.Io.Reader.Error!usize {
        var slices = [_][]u8{out};
        return self.reader.interface.readVec(&slices);
    }

    pub fn writeAll(self: *RawStream, bytes: []const u8) std.Io.Writer.Error!void {
        try self.writer.interface.writeAll(bytes);
        try self.writer.interface.flush();
    }

    pub fn close(self: *RawStream) void {
        self.reader.stream.close(self.io);
    }

    pub fn shutdown(self: *RawStream) void {
        self.reader.stream.shutdown(self.io, .both) catch {};
    }

    pub fn readinessFd(self: *const RawStream) std.Io.net.Socket.Handle {
        return self.reader.stream.socket.handle;
    }
};

/// The longest forward-target text this resident formats: a Unix socket path at
/// the platform maximum, or an `addr:port` well under it.
const forward_text_max = 108;

/// How this resident reaches Tor, and what it asks for when hosting.
///
/// Every field is configured rather than guessed. pancake does not start,
/// supervise, or configure the daemon, so it cannot assume where the daemon
/// listens or how it wants to be authenticated. The meaning of each field is
/// documented once here; the C archive and the bindings mirror this struct and
/// point back at it.
pub const Config = struct {
    /// Tor's SOCKS endpoint, as `/path/to/socket` or `host:port`. Required: a
    /// resident that cannot dial is not a netlayer.
    socks: []const u8,
    /// Tor's control endpoint, in the same two forms. Empty means dial-only, and
    /// `listen` then refuses.
    control_endpoint: []const u8 = &.{},
    /// How the control endpoint expects to be authenticated.
    auth: control.Auth = .none,
    /// The service key to restore, exactly as Tor returned it in
    /// `250-PrivateKey=`. Empty asks for a fresh service.
    service_key: []const u8 = &.{},
    /// The local endpoint Tor forwards the service's virtual port to. Empty binds
    /// a loopback port and reports the one the OS chose.
    forward: []const u8 = &.{},
};

/// The resident's state. The caller owns one at a stable address for as long as
/// the transport slice holds the netlayer, and owns the `Config` text for at
/// least as long, because the endpoints are borrowed rather than copied.
pub const Resident = struct {
    io: std.Io,
    config: Config,

    /// This resident as a `Netlayer`.
    pub fn netlayer(self: *Resident) Netlayer {
        return .{ .ctx = self, .vtable = &resident_vtable };
    }
};

const resident_ctx = netlayer.ResidentContext(Resident);

const resident_vtable: Netlayer.VTable = .{
    .profile = known_transport.metadata(),
    .dial = residentDial,
    .listen = residentListen,
    .io = resident_ctx.io,
};

/// The pinned stream a dialed onion connection runs over.
///
/// It exists for the reason `tcp.TcpStream` does: `std.Io.Reader`'s vtable
/// recovers its concrete reader from `&interface` by field offset, so the reader
/// and writer need an address that outlives the call that made them.
const OnionStream = struct {
    raw: RawStream,
    allocator: std.mem.Allocator,

    fn close(ctx: *anyopaque) void {
        const self: *OnionStream = @ptrCast(@alignCast(ctx));
        self.raw.close();
        self.allocator.destroy(self);
    }

    fn socketHandle(ctx: *anyopaque) ?std.Io.net.Socket.Handle {
        const self: *OnionStream = @ptrCast(@alignCast(ctx));
        return self.raw.readinessFd();
    }
};

fn residentDial(
    ctx: *anyopaque,
    peer: *engine.Peer,
    loc: model.PeerLocator,
    bufs: Buffers,
) netlayer.DialError!Connection {
    const self = resident_ctx.of(ctx);
    if (loc.hints.entries.len != 0 or loc.hints.wire_form != .boolean_false)
        return error.InvalidAddress;
    return dial(self.io, peer, self.config.socks, loc.designator, bufs);
}

/// Dial `service_id` through the SOCKS endpoint `socks_text`.
///
/// Locator hints are ignored rather than refused. The designator already says
/// where to dial, so a hint carries nothing this transport needs, and refusing a
/// hinted locator would turn a partner's harmless extra field into a failed dial.
/// What pancake itself *emits* carries no hints, which is a separate rule and the
/// one the pinned Goblins actually requires (ADR-0108).
pub fn dial(
    io: std.Io,
    peer: *engine.Peer,
    socks_text: []const u8,
    service_id: []const u8,
    bufs: Buffers,
) netlayer.DialError!Connection {
    const stream = try dialRawStream(io, socks_text, service_id);
    var owns_stream = true;
    defer if (owns_stream) stream.close(io);

    const os = try peer.allocator.create(OnionStream);
    var owns_pin = true;
    defer if (owns_pin) peer.allocator.destroy(os);
    os.* = .{ .raw = RawStream.init(io, stream, bufs.read, bufs.write), .allocator = peer.allocator };

    owns_stream = false;
    owns_pin = false;
    return Connection.init(io, peer, &os.raw.reader.interface, &os.raw.writer.interface, .{
        .ctx = os,
        .close_fn = OnionStream.close,
        .socket_handle_fn = OnionStream.socketHandle,
    });
}

/// Dial an onion service and return the established, unframed byte stream.
/// The SOCKS handshake lives here so every host integration uses the same Tor
/// validation and error classification.
pub fn dialRawStream(
    io: std.Io,
    socks_text: []const u8,
    service_id: []const u8,
) netlayer.DialError!Stream {
    const ep = Endpoint.parse(socks_text) catch return error.InvalidAddress;
    socks5.checkServiceId(service_id) catch return error.InvalidAddress;

    const stream = ep.connect(io) catch |err| return classifyConnect(err);
    errdefer stream.close(io);
    session_mod.socksHandshake(io, stream, service_id) catch |err| return classifyHandshake(err);
    return stream;
}

/// Dial `service_id` and yield a peer-less `FrameStream`.
///
/// The form the C archive and every language binding use: the host owns the peer,
/// so this hands back whole frames rather than a welded connection. The handshake
/// is the same one `dial` runs, and it runs before the frame stream exists for the
/// same reason.
pub fn dialFrameStream(
    io: std.Io,
    allocator: std.mem.Allocator,
    socks_text: []const u8,
    service_id: []const u8,
    codec_id: model.CodecId,
    max_frame_bytes: usize,
    read_buf: []u8,
    write_buf: []u8,
) netlayer.DialError!frame_stream.FrameStream {
    const stream = try dialRawStream(io, socks_text, service_id);
    return frame_stream.FrameStream.initStream(
        io,
        allocator,
        stream,
        codec_id,
        max_frame_bytes,
        read_buf,
        write_buf,
    );
}

/// Project a local-socket fault onto the dial retry axis (ADR-0081). Reaching
/// Tor is a local connect, so a refusal here means the daemon is not listening
/// where configuration said, not that the far peer refused.
fn classifyConnect(err: Endpoint.ConnectError) netlayer.DialError {
    return switch (err) {
        error.ConnectionRefused, error.FileNotFound => error.ConnectionRefused,
        error.NetworkDown, error.NetworkUnreachable, error.HostUnreachable => error.NetworkUnreachable,
        error.Timeout => error.TimedOut,
        else => error.ConnectionLost,
    };
}

/// Project a handshake fault. A SOCKS refusal is the interesting one: Tor answers
/// it when it cannot reach the service, which is the far peer being unreachable
/// rather than the local daemon being absent.
fn classifyHandshake(err: session_mod.Error) netlayer.DialError {
    return switch (err) {
        error.InvalidServiceId => error.InvalidAddress,
        error.Refused => error.NetworkUnreachable,
        error.ProtocolViolation, error.ReplyTooLong => error.ConnectionLost,
        else => error.ConnectionLost,
    };
}

fn residentListen(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    config: netlayer.ListenConfig,
) netlayer.ListenError!NetLayerListener {
    const self = resident_ctx.of(ctx);
    // `ListenConfig.designator` is not read. For every other address-scheme
    // transport the caller names where to bind; here Tor mints the service id and
    // pancake learns it from the reply, so a caller-supplied designator would be
    // a value nothing could honour.
    _ = config;
    const listener = try Listener.create(allocator, self.io, self.config);
    return listener.asNetlayer();
}

/// A bound onion service: the control session that keeps it alive, and the local
/// server Tor forwards it to.
pub const Listener = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    server: Server,
    ctrl: ControlSession,
    service_id: [socks5.service_id_len]u8,
    /// The key Tor returned for a freshly minted service, so a caller can store
    /// it and restore the same address later. Empty for a restored service.
    service_key_store: [256]u8,
    service_key_len: usize,
    /// The Unix socket path this listener bound, when it bound one, so `close`
    /// can remove it. Tor does not clean up a forward target it only connected
    /// to.
    unix_path: ?[]const u8,
    forward_text: [forward_text_max]u8,
    /// Private cancellation edge for the blocking accept path. `shutdown(2)`
    /// does not reliably cancel an accept on a listening socket, so shutdown
    /// wakes this descriptor and deinit joins the serialized accept lease
    /// before releasing either fd or listener storage.
    wake: wake_channel.WakeChannel,
    operation_gate: std.Io.Mutex = .init,
    stopping: std.atomic.Value(bool) = .init(false),

    /// Create the service and bind its forward target.
    ///
    /// The order matters and is the order the pinned Goblins uses: bind locally
    /// first, then tell Tor to forward to it. The reverse races, because Tor may
    /// publish the descriptor and receive a circuit before anything is listening,
    /// and that first partner is refused for no reason it can see.
    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        config: Config,
    ) netlayer.ListenError!*Listener {
        if (config.control_endpoint.len == 0) return error.InvalidAddress;
        const control_ep = Endpoint.parse(config.control_endpoint) catch return error.InvalidAddress;

        const self = try allocator.create(Listener);
        errdefer allocator.destroy(self);
        self.allocator = allocator;
        self.io = io;
        self.service_key_len = 0;
        self.unix_path = null;
        self.operation_gate = .init;
        self.stopping = .init(false);
        self.wake = wake_channel.WakeChannel.open() catch return error.BindFailed;
        errdefer self.wake.deinit();

        // Bind the local end first.
        const forward_ep: Endpoint = if (config.forward.len == 0)
            .{ .address = IpAddress.parse("127.0.0.1", 0) catch unreachable }
        else
            Endpoint.parse(config.forward) catch return error.InvalidAddress;

        self.server = forward_ep.listen(io) catch return error.BindFailed;
        errdefer {
            self.server.deinit(io);
            if (self.unix_path) |path| std.Io.Dir.deleteFileAbsolute(io, path) catch {};
        }

        // Then name it to Tor. An empty configured forward means the OS chose the
        // port, so the text has to be read back off the bound socket rather than
        // from configuration.
        const forward_text = try self.formatForward(config.forward, forward_ep);
        if (forward_ep.isUnix()) self.unix_path = forward_text;

        self.ctrl.open(io, control_ep, config.auth) catch return error.BindFailed;
        errdefer self.ctrl.close();

        const service = self.ctrl.addOnion(
            forward_ep,
            forward_text,
            config.service_key,
        ) catch return error.BindFailed;

        self.service_id = service.id;
        if (service.key.len > 0) {
            if (service.key.len > self.service_key_store.len) return error.BindFailed;
            @memcpy(self.service_key_store[0..service.key.len], service.key);
            self.service_key_len = service.key.len;
        }
        return self;
    }

    fn formatForward(
        self: *Listener,
        configured: []const u8,
        ep: Endpoint,
    ) netlayer.ListenError![]const u8 {
        if (configured.len > 0) {
            if (configured.len > self.forward_text.len) return error.InvalidAddress;
            @memcpy(self.forward_text[0..configured.len], configured);
            return self.forward_text[0..configured.len];
        }
        std.debug.assert(ep == .address);
        const bound = self.server.socket.address;
        const written = std.fmt.bufPrint(&self.forward_text, "{f}", .{bound}) catch
            return error.InvalidAddress;
        return written;
    }

    /// The service id, which is this listener's dialable designator.
    pub fn designator(self: *const Listener) []const u8 {
        return &self.service_id;
    }

    /// The key that restores this exact service, or an empty slice when the
    /// service was restored rather than minted. A caller that wants a durable
    /// onion address stores this.
    pub fn serviceKey(self: *const Listener) []const u8 {
        return self.service_key_store[0..self.service_key_len];
    }

    /// The descriptor Tor's circuits arrive on, for an embedder that polls rather
    /// than blocks.
    ///
    /// This is what keeps an event-driven consumer off the blocking path entirely:
    /// park on this with `poll`, `epoll`, or a JavaScript socket wrapper, and only
    /// call `accept` once it is readable. An onion service's forward target is an
    /// ordinary local socket, which is why this transport can offer a real
    /// descriptor where the iroh sidecar had to synthesize a readiness fd.
    pub fn readinessFd(self: *const Listener) std.Io.net.Socket.Handle {
        return self.server.socket.handle;
    }

    pub fn asNetlayer(self: *Listener) NetLayerListener {
        return .{ .ctx = self, .vtable = &listener_vtable };
    }

    fn accept(self: *Listener, peer: *engine.Peer, bufs: Buffers) netlayer.AcceptError!Connection {
        // What arrives is a local connection from Tor, carrying no client
        // identity: Tor tells a hidden service nothing about who dialed it. The
        // partner's claimed location is therefore unverified, which ADR-0108
        // records as a finding rather than a secret.
        self.operation_gate.lockUncancelable(self.io);
        defer self.operation_gate.unlock(self.io);
        const stream = try self.acceptStreamLocked();
        var owns_stream = true;
        defer if (owns_stream) stream.close(self.io);

        const os = try peer.allocator.create(OnionStream);
        errdefer peer.allocator.destroy(os);
        os.* = .{ .raw = RawStream.init(self.io, stream, bufs.read, bufs.write), .allocator = peer.allocator };
        owns_stream = false;
        return Connection.init(self.io, peer, &os.raw.reader.interface, &os.raw.writer.interface, .{
            .ctx = os,
            .close_fn = OnionStream.close,
            .socket_handle_fn = OnionStream.socketHandle,
        });
    }

    /// As `accept`, but yielding a peer-less `FrameStream` for a host that owns
    /// its own peer. No handshake runs on this side: Tor connected to the local
    /// endpoint, so the stream is already transparent.
    pub fn acceptFrameStream(
        self: *Listener,
        allocator: std.mem.Allocator,
        codec_id: model.CodecId,
        max_frame_bytes: usize,
        read_buf: []u8,
        write_buf: []u8,
    ) netlayer.AcceptError!frame_stream.FrameStream {
        self.operation_gate.lockUncancelable(self.io);
        defer self.operation_gate.unlock(self.io);
        const stream = try self.acceptStreamLocked();
        return frame_stream.FrameStream.initStream(
            self.io,
            allocator,
            stream,
            codec_id,
            max_frame_bytes,
            read_buf,
            write_buf,
        );
    }

    /// Accept under `operation_gate`. The caller retains the gate through
    /// complete wrapper construction so concurrent deinit cannot free listener
    /// state between the kernel accept and the last read of `self.io`.
    fn acceptStreamLocked(self: *Listener) netlayer.AcceptError!Stream {
        if (self.stopping.load(.acquire)) return error.ConnectionLost;

        var fds = [_]std.posix.pollfd{
            .{ .fd = self.server.socket.handle, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = self.wake.read, .events = std.posix.POLL.IN, .revents = 0 },
        };
        const ready = poll.wait(&fds, -1) catch return error.ConnectionLost;
        if (ready == 0 or self.stopping.load(.acquire) or
            fds[1].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR) != 0)
        {
            self.wake.drain();
            return error.ConnectionLost;
        }
        return self.server.accept(self.io) catch error.ConnectionLost;
    }

    /// Accept an unframed stream for host integrations that own CapTP framing.
    pub fn acceptRawStream(self: *Listener) netlayer.AcceptError!Stream {
        self.operation_gate.lockUncancelable(self.io);
        defer self.operation_gate.unlock(self.io);
        return self.acceptStreamLocked();
    }

    /// Wait until `accept` would make progress, up to `timeout_ms`. The poll
    /// guard that lets a blocking host leave its accept loop without closing the
    /// listen descriptor from another thread.
    pub fn waitAcceptable(self: *Listener, timeout_ms: i32) netlayer.AcceptError!bool {
        self.operation_gate.lockUncancelable(self.io);
        defer self.operation_gate.unlock(self.io);
        if (self.stopping.load(.acquire)) return error.ConnectionLost;
        var fds = [_]std.posix.pollfd{
            .{ .fd = self.server.socket.handle, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = self.wake.read, .events = std.posix.POLL.IN, .revents = 0 },
        };
        const ready = poll.wait(&fds, timeout_ms) catch return error.ConnectionLost;
        if (self.stopping.load(.acquire) or
            fds[1].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR) != 0)
            return error.ConnectionLost;
        return ready != 0 and
            fds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR) != 0;
    }

    /// Wake a blocked accept without releasing listener storage. This is the
    /// cancellation half used by foreign runtimes whose blocking accept runs on
    /// another OS thread; `deinit` follows after that call returns.
    pub fn shutdown(self: *Listener) void {
        self.stopping.store(true, .release);
        self.wake.nudge();
    }

    /// Drop the undetached service's control session and release the local end.
    /// Tor withdraws an undetached onion service when that session closes, so
    /// release performs no control I/O and cannot park an embedder's reactor.
    pub fn deinit(self: *Listener) void {
        self.shutdown();
        self.operation_gate.lockUncancelable(self.io);
        self.operation_gate.unlock(self.io);
        self.ctrl.close();
        self.server.deinit(self.io);
        self.wake.deinit();
        // Tor only connected to this socket; the process that bound it owns the
        // inode, and leaving it behind makes the next bind fail with the path
        // already in use.
        // `Endpoint.parse` only accepts an absolute path for a socket, which is
        // what lets this take the absolute form and name no directory.
        if (self.unix_path) |path| std.Io.Dir.deleteFileAbsolute(self.io, path) catch {};
        self.allocator.destroy(self);
    }
};

const listener_vtable: NetLayerListener.VTable = .{
    .transport_name = transport_name,
    .designator_scheme = known_transport.metadata().designator_scheme,
    .sealed_channel = known_transport.metadata().sealed_channel,
    .accept = listenerAccept,
    .waitAcceptable = listenerWaitAcceptable,
    .localLocator = listenerLocalLocator,
    .canonicalizeLocator = listenerCanonicalizeLocator,
    .close = listenerClose,
};

fn listenerOf(ctx: *anyopaque) *Listener {
    return @ptrCast(@alignCast(ctx));
}

fn listenerAccept(ctx: *anyopaque, peer: *engine.Peer, bufs: Buffers) netlayer.AcceptError!Connection {
    return listenerOf(ctx).accept(peer, bufs);
}

fn listenerWaitAcceptable(ctx: *anyopaque, timeout_ms: i32) netlayer.AcceptError!bool {
    return listenerOf(ctx).waitAcceptable(timeout_ms);
}

fn listenerLocalLocator(ctx: *anyopaque, allocator: std.mem.Allocator) netlayer.ListenError!model.PeerLocator {
    const self = listenerOf(ctx);
    // Identity is immutable after construction. Keep locator lookup off the
    // serialized accept lease: a parked accept must not make hello assembly or
    // diagnostics wait for network I/O.
    return model.clonePeerLocator(allocator, .{
        .transport = transport_name,
        .designator = &self.service_id,
        .hints = .emptyFalse(),
    });
}

fn listenerCanonicalizeLocator(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    locator: model.PeerLocator,
) netlayer.ListenError!model.PeerLocator {
    const self = listenerOf(ctx);
    if (locator.hints.entries.len != 0 or locator.hints.wire_form != .boolean_false)
        return error.InvalidAddress;
    return netlayer.canonicalizeFixedLocator(allocator, locator, transport_name, &self.service_id);
}

fn listenerClose(ctx: *anyopaque) void {
    listenerOf(ctx).deinit();
}
