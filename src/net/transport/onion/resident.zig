//! The `onion` netlayer resident: dial and accept over the ADR-0043 contract.
//!
//! Neither half is a new kind of socket. A dial is a stream to the local Tor's
//! SOCKS endpoint with a handshake in front of it, and an accept is a stream Tor
//! opened to a local endpoint glowcap bound. What reaches CapTP is the ordinary
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

const accept_gate = @import("../../accept_gate.zig");
const connection = @import("../../connection.zig");
const frame_stream = @import("../../frame_stream.zig");
const netlayer = @import("../../netlayer.zig");

const endpoint_mod = @import("endpoint.zig");
const resident_config = @import("resident_config.zig");
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
/// the pinned Goblins netlayer reports as its own name, so a glowcap locator
/// addresses and is addressed by a Goblins onion peer.
const known_transport = model.transport.Known.onion;
pub const transport_name = known_transport.metadata().symbol;

/// Build an onion locator without parsing or allocating. The service id is
/// borrowed by the returned locator and must remain alive until the dial path
/// has copied or retained it. Onion locators use the Goblins-compatible empty
/// false hint spelling; direct-address hints have no meaning here.
pub fn locator(service_id: []const u8) model.PeerLocator {
    return .{
        .transport = transport_name,
        .designator = service_id,
        .hints = model.Hints.emptyFalse(),
    };
}

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

    pub fn shutdown(self: *RawStream) std.Io.net.ShutdownError!void {
        try frame_stream.shutdownStream(&self.reader.stream, self.io);
    }

    pub fn readinessFd(self: *const RawStream) std.Io.net.Socket.Handle {
        return self.reader.stream.socket.handle;
    }
};

/// The longest forward-target text this resident formats: a Unix socket path at
/// the platform maximum, or an `addr:port` well under it.
const forward_text_max = 108;

pub const Config = resident_config.Config;

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
    .dial = .{ .blocking = netlayer.adaptBlockingDial(residentDial) },
    .listen = residentListen,
    .io = resident_ctx.io,
};

/// The pinned stream a dialed or accepted onion connection runs over: the
/// shared raw-connection shell, argued at `netlayer_support.PinnedRawStream`.
const OnionStream = netlayer.PinnedRawStream(RawStream);

fn residentDial(
    ctx: *anyopaque,
    peer: *engine.Peer,
    loc: model.PeerLocator,
    bufs: Buffers,
    options: netlayer.OperationOptions,
) netlayer.DialError!Connection {
    try options.requireInherited();
    const self = resident_ctx.of(ctx);
    return dial(self.io, peer, self.config.socks, loc.designator, bufs);
}

/// Dial `service_id` through the SOCKS endpoint `socks_text`.
///
/// Locator hints are ignored rather than refused. The designator already says
/// where to dial, so a hint carries nothing this transport needs, and refusing a
/// hinted locator would turn a partner's harmless extra field into a failed
/// dial — including the glowcap-hinted form of an onion address, whose profile
/// hints are read one tier up as partner knowledge (ADR-0118). What glowcap
/// itself *emits on the wire* carries no hints, which is a separate rule and
/// the one the pinned Goblins actually requires (ADR-0108).
pub fn dial(
    io: std.Io,
    peer: *engine.Peer,
    socks_text: []const u8,
    service_id: []const u8,
    bufs: Buffers,
) netlayer.DialError!Connection {
    const stream = try dialRawStream(io, socks_text, service_id);
    errdefer stream.close(io);
    return OnionStream.adopt(peer, RawStream.init(io, stream, bufs.read, bufs.write));
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
) netlayer.ListenStartOutcome {
    config.options.requireInherited() catch |err| return .{ .failed = .init(err) };
    const self = resident_ctx.of(ctx);
    // `ListenConfig.designator` is not read. For every other address-scheme
    // transport the caller names where to bind; here Tor mints the service id and
    // glowcap learns it from the reply, so a caller-supplied designator would be
    // a value nothing could honour.
    return switch (Listener.create(allocator, self.io, self.config)) {
        .ready => |listener| .{ .admitted = .{ .ready = listener.asNetlayer() } },
        .failed => |failure| .{ .failed = failure },
    };
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
    service_key_store: [session_mod.service_key_cap]u8,
    service_key_len: usize,
    /// The Unix socket path this listener bound, when it bound one, so `close`
    /// can remove it. Tor does not clean up a forward target it only connected
    /// to.
    unix_path: ?[]const u8,
    forward_text: [forward_text_max]u8,
    /// The cancellation edge for the blocking accept path: shutdown wakes a
    /// parked accept and deinit joins the serialized accept lease before
    /// releasing either fd or listener storage.
    gate: accept_gate.Gate,

    pub const CreateOutcome = union(enum) {
        ready: *Listener,
        failed: netlayer.ListenFailure,
    };

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
    ) CreateOutcome {
        if (config.control_endpoint.len == 0) return .{ .failed = .init(error.InvalidAddress) };
        const control_ep = Endpoint.parse(config.control_endpoint) catch
            return .{ .failed = .init(error.InvalidAddress) };

        const self = allocator.create(Listener) catch |err| return .{ .failed = .init(err) };
        self.allocator = allocator;
        self.io = io;
        self.service_key_len = 0;
        self.unix_path = null;
        self.gate = accept_gate.Gate.open() catch {
            allocator.destroy(self);
            return .{ .failed = .init(error.BindFailed) };
        };

        // Bind the local end first.
        const forward_ep: Endpoint = if (config.forward.len == 0)
            .{ .address = IpAddress.parse("127.0.0.1", 0) catch unreachable }
        else
            Endpoint.parse(config.forward) catch {
                return failCreate(self, error.InvalidAddress, false, false);
            };

        self.server = forward_ep.listen(io) catch return failCreate(self, error.BindFailed, false, false);

        // Then name it to Tor. An empty configured forward means the OS chose the
        // port, so the text has to be read back off the bound socket rather than
        // from configuration.
        const forward_text = self.formatForward(config.forward, forward_ep) catch |err|
            return failCreate(self, err, true, false);
        if (forward_ep.isUnix()) self.unix_path = forward_text;

        self.ctrl.open(io, control_ep, config.auth) catch
            return failCreate(self, error.BindFailed, true, false);

        const service = self.ctrl.addOnion(
            forward_ep,
            forward_text,
            config.service_key,
        ) catch return failCreate(self, error.BindFailed, true, true);

        self.service_id = service.id;
        if (service.key.len > 0) {
            if (service.key.len > self.service_key_store.len)
                return failCreate(self, error.BindFailed, true, true);
            @memcpy(self.service_key_store[0..service.key.len], service.key);
            self.service_key_len = service.key.len;
        }
        return .{ .ready = self };
    }

    fn failCreate(
        self: *Listener,
        cause: anyerror,
        server_live: bool,
        control_live: bool,
    ) CreateOutcome {
        var failure = netlayer.ListenFailure.init(cause);
        if (control_live) self.ctrl.close();
        if (server_live) {
            self.server.deinit(self.io);
            if (self.unix_path) |path| std.Io.Dir.deleteFileAbsolute(self.io, path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => failure.note(err),
            };
        }
        self.gate.deinit();
        self.allocator.destroy(self);
        return .{ .failed = failure };
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
        return ListenerShell.listener(self);
    }

    fn accept(self: *Listener, peer: *engine.Peer, bufs: Buffers) netlayer.AcceptError!Connection {
        // What arrives is a local connection from Tor, carrying no client
        // identity: Tor tells a hidden service nothing about who dialed it. The
        // partner's claimed location is therefore unverified, which ADR-0108
        // records as a finding rather than a secret.
        self.gate.lock(self.io);
        defer self.gate.unlock(self.io);
        const stream = try self.acceptStreamLocked();
        errdefer stream.close(self.io);
        return OnionStream.adopt(peer, RawStream.init(self.io, stream, bufs.read, bufs.write));
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
        self.gate.lock(self.io);
        defer self.gate.unlock(self.io);
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

    /// Accept under the gate's lease. The caller retains the lease through
    /// complete wrapper construction so concurrent deinit cannot free listener
    /// state between the kernel accept and the last read of `self.io`.
    fn acceptStreamLocked(self: *Listener) netlayer.AcceptError!Stream {
        if (!try self.gate.waitReadable(self.server.socket.handle, -1)) return error.ConnectionLost;
        return self.server.accept(self.io) catch error.ConnectionLost;
    }

    /// Accept an unframed stream for host integrations that own CapTP framing.
    pub fn acceptRawStream(self: *Listener) netlayer.AcceptError!Stream {
        self.gate.lock(self.io);
        defer self.gate.unlock(self.io);
        return self.acceptStreamLocked();
    }

    /// Wait until `accept` would make progress, up to `timeout_ms`. The poll
    /// guard that lets a blocking host leave its accept loop without closing the
    /// listen descriptor from another thread.
    pub fn waitAcceptable(self: *Listener, timeout_ms: i32) netlayer.AcceptError!bool {
        self.gate.lock(self.io);
        defer self.gate.unlock(self.io);
        return self.gate.waitReadable(self.server.socket.handle, timeout_ms);
    }

    /// Wake a blocked accept without releasing listener storage. This is the
    /// cancellation half used by foreign runtimes whose blocking accept runs on
    /// another OS thread; `deinit` follows after that call returns.
    pub fn shutdown(self: *Listener) void {
        self.gate.shutdown();
    }

    /// Drop the undetached service's control session and release the local end.
    /// Tor withdraws an undetached onion service when that session closes, so
    /// release performs no control I/O and cannot park an embedder's reactor.
    pub fn deinit(self: *Listener) ?netlayer.ListenerCloseFailure {
        self.gate.shutdown();
        self.gate.join(self.io);
        var failure: ?netlayer.ListenerCloseFailure = if (self.gate.failure()) |err|
            .init(err)
        else
            null;
        self.ctrl.close();
        self.server.deinit(self.io);
        self.gate.deinit();
        // Tor only connected to this socket; the process that bound it owns the
        // inode, and leaving it behind makes the next bind fail with the path
        // already in use.
        // `Endpoint.parse` only accepts an absolute path for a socket, which is
        // what lets this take the absolute form and name no directory.
        if (self.unix_path) |path| std.Io.Dir.deleteFileAbsolute(self.io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => {
                if (failure) |*first|
                    first.note(err)
                else
                    failure = .init(err);
            },
        };
        self.allocator.destroy(self);
        return failure;
    }
};

/// The contract listener over a `Listener`, which owns its own storage and
/// frees it in `deinit`. The forward socket supplies accept readiness to both
/// the blocking wait and the shared runtime's aggregate poll.
const ListenerShell = netlayer.ListenerShell(struct {
    pub const State = Listener;
    pub const metadata = known_transport.metadata();

    pub fn accept(self: *Listener, peer: *engine.Peer, bufs: Buffers) netlayer.AcceptError!Connection {
        return self.accept(peer, bufs);
    }

    pub fn waitAcceptable(self: *Listener, timeout_ms: i32) netlayer.AcceptError!bool {
        return self.waitAcceptable(timeout_ms);
    }

    pub fn readinessFd(self: *Listener) i32 {
        return @intCast(self.readinessFd());
    }

    pub fn localLocator(self: *Listener, allocator: std.mem.Allocator) netlayer.ListenError!model.PeerLocator {
        // Identity is immutable after construction. Keep locator lookup off the
        // serialized accept lease: a parked accept must not make hello assembly or
        // diagnostics wait for network I/O.
        return model.clonePeerLocator(allocator, .{
            .transport = transport_name,
            .designator = &self.service_id,
            .hints = .emptyFalse(),
        });
    }

    pub fn canonicalizeLocator(
        self: *Listener,
        allocator: std.mem.Allocator,
        candidate: model.PeerLocator,
    ) netlayer.ListenError!model.PeerLocator {
        if (candidate.hints.entries.len != 0 or candidate.hints.wire_form != .boolean_false)
            return error.InvalidAddress;
        return netlayer.canonicalizeFixedLocator(allocator, candidate, transport_name, &self.service_id);
    }

    pub fn restorationState(self: *Listener, out: []u8) netlayer.RestorationStateError!usize {
        return netlayer.writeListenerRestorationState(out, self.serviceKey());
    }

    pub fn close(self: *Listener) ?netlayer.ListenerCloseFailure {
        return self.deinit();
    }
});
