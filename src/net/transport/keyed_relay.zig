//! The keyed-relay transport: RFC 6455 WebSocket client legs over TCP sockets,
//! so a native peer dials — and is dialed through — a relay's rendezvous
//! (ADR-0088).
//!
//! A `keyed-relay` locator names a peer by its Ed25519 key designator alone.
//! There is no dialable address in the locator: the peer holds an inbound
//! WebSocket at a relay under that designator, and a dialer opens the relay's
//! rendezvous leg it is configured for. The relay mapping is the dialing
//! host's deployment configuration (`Resident.relay_url`), never locator
//! bytes, so the same give redeems against whatever relay the redeeming host
//! trusts. The relay carries bytes and parses nothing; the keyed CapTP
//! handshake carries the claimed designator end to end with the same
//! unauthenticated posture as `keyed-tcp` (the channel is cleartext `ws://`;
//! see `docs/boundaries.md`).
//!
//! Both halves live here. `dial` opens `relay_url` with `?rendezvous=<key>`
//! and yields a `Connection` over the socket. `listen` registers the host's
//! own key at `register_url` (`?id=<key>`) and parks: `waitAcceptable` answers
//! the relay's pings in place, and `accept` hands over the registered socket
//! the moment a dialer's bytes are bridged onto it. The next wait registers
//! the replacement, so an accept loop keeps the peer cold-dialable — the
//! rendezvous shape of a TCP accept loop.
//!
//! The WebSocket layer is a client-side RFC 6455 subset: the HTTP/1.1 upgrade
//! with `Sec-WebSocket-Accept` verification, masked outbound binary frames,
//! and inbound binary/continuation streaming with ping/pong and close
//! handling. Text frames, extensions (non-zero RSV bits), masked server
//! frames, and oversized control frames are refused — every inbound byte is
//! attacker-influenced until the CapTP session validates it, so the codec
//! fails closed. Inbound payload lengths are streamed, never allocated from.
//!
//! Costs, named: masking is a per-byte transform RFC 6455 requires of clients,
//! paid as one copy into the socket writer's buffer (there is no in-place
//! spelling — the caller's bytes are borrowed). Inbound payload pays one copy
//! from the socket reader's buffer into the CapTP reader's. Each connection
//! pins one `RelayStream` (the ADR-0043 stable-address pin) carrying the
//! socket reader/writer stores; an application-tier cost, not the loop tier's.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");
const connection = @import("../connection.zig");
const netlayer = @import("../netlayer.zig");
const stream_shim = @import("../stream_shim.zig");
const tcp = @import("tcp.zig");

const crypto = foundation.crypto;
const Io = std.Io;
const Stream = Io.net.Stream;

const Netlayer = netlayer.Netlayer;
const NetLayerListener = netlayer.Listener;
const Buffers = netlayer.Buffers;
const Connection = connection.Connection;

/// The transport symbol carried in a `model.PeerLocator`. A key designator
/// with no address: reachability is the dialing host's configured relay.
pub const transport_name = model.transport.keyed_relay;

/// The relay's rendezvous-leg query key (`?rendezvous=<designator>`), the
/// ADR-0088 contract the reference relay dispatches on.
pub const rendezvous_query = "rendezvous";
/// The relay's registration query key (`?id=<designator>`).
pub const register_query = "id";

// --- The WebSocket frame codec (client side) -------------------------------
//
// Pure over `std.Io.Reader` / byte buffers so the hostile-input tests drive it
// without a socket. The connection state machine below composes these.

/// RFC 6455 opcodes this client speaks. Text frames are refused outright:
/// pancake bytes are binary, and a text frame from a relay is a fault.
pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xa,
    _,
};

/// One parsed frame header. `len` is the payload length; the payload itself is
/// streamed by the caller, never materialized from this length.
pub const FrameHeader = struct {
    opcode: Opcode,
    fin: bool,
    len: u64,
};

pub const FrameError = error{
    /// A reserved bit was set (no extension is negotiated), the server sent a
    /// masked frame (RFC 6455 forbids it), the opcode is unknown or text, or a
    /// control frame exceeds its 125-byte payload cap or arrives fragmented.
    ProtocolViolation,
    /// The stream ended mid-header.
    Truncated,
    /// The underlying read faulted.
    ReadFailed,
};

/// Control frames carry at most 125 payload bytes (RFC 6455 §5.5); the
/// parked-listener wait and the reader's ping handling size their stack
/// buffers from this.
pub const max_control_payload = 125;

/// The widest header a client writes: 2 base bytes, 8 extended-length bytes,
/// 4 mask bytes.
pub const max_header_len = 14;

/// Read one frame header off `r`, refusing the shapes a conforming relay never
/// produces. Blocks until the header bytes arrive; a clean EOF before the
/// first byte is `Truncated` (the caller distinguishes a clean close at a
/// frame boundary before calling).
pub fn readFrameHeader(r: *Io.Reader) FrameError!FrameHeader {
    const b0 = takeHeaderByte(r) catch |err| return err;
    const b1 = takeHeaderByte(r) catch |err| return err;
    if (b0 & 0x70 != 0) return FrameError.ProtocolViolation; // RSV1-3
    const opcode: Opcode = @enumFromInt(@as(u4, @truncate(b0 & 0x0f)));
    const fin = b0 & 0x80 != 0;
    const masked = b1 & 0x80 != 0;
    if (masked) return FrameError.ProtocolViolation; // server frames are unmasked
    var len: u64 = b1 & 0x7f;
    if (len == 126) {
        var ext: [2]u8 = undefined;
        readHeaderBytes(r, &ext) catch |err| return err;
        len = std.mem.readInt(u16, &ext, .big);
    } else if (len == 127) {
        var ext: [8]u8 = undefined;
        readHeaderBytes(r, &ext) catch |err| return err;
        len = std.mem.readInt(u64, &ext, .big);
        if (len & (1 << 63) != 0) return FrameError.ProtocolViolation; // MSB must be 0
    }
    switch (opcode) {
        .continuation, .binary => {},
        .close, .ping, .pong => {
            if (len > max_control_payload or !fin) return FrameError.ProtocolViolation;
        },
        .text => return FrameError.ProtocolViolation,
        _ => return FrameError.ProtocolViolation,
    }
    return .{ .opcode = opcode, .fin = fin, .len = len };
}

fn takeHeaderByte(r: *Io.Reader) FrameError!u8 {
    return r.takeByte() catch |err| switch (err) {
        error.EndOfStream => FrameError.Truncated,
        error.ReadFailed => FrameError.ReadFailed,
    };
}

fn readHeaderBytes(r: *Io.Reader, dest: []u8) FrameError!void {
    r.readSliceAll(dest) catch |err| switch (err) {
        error.EndOfStream => return FrameError.Truncated,
        error.ReadFailed => return FrameError.ReadFailed,
    };
}

/// Build a client frame header into `buf` (masked — every client frame is) and
/// return the written prefix.
pub fn writeFrameHeader(buf: *[max_header_len]u8, opcode: Opcode, len: u64, mask: [4]u8) []const u8 {
    buf[0] = 0x80 | @as(u8, @intFromEnum(opcode)); // FIN, no RSV
    var at: usize = 2;
    if (len < 126) {
        buf[1] = 0x80 | @as(u8, @intCast(len));
    } else if (len <= std.math.maxInt(u16)) {
        buf[1] = 0x80 | 126;
        std.mem.writeInt(u16, buf[2..4], @intCast(len), .big);
        at = 4;
    } else {
        buf[1] = 0x80 | 127;
        std.mem.writeInt(u64, buf[2..10], len, .big);
        at = 10;
    }
    @memcpy(buf[at..][0..4], &mask);
    return buf[0 .. at + 4];
}

/// The `Sec-WebSocket-Accept` value for a request key: base64 of the SHA-1
/// over the key joined with the RFC 6455 GUID.
pub fn acceptKey(out: *[28]u8, request_key: []const u8) void {
    const guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(request_key);
    sha.update(guid);
    var digest: [20]u8 = undefined;
    sha.final(&digest);
    _ = std.base64.standard.Encoder.encode(out, &digest);
}

// --- The relay URL ---------------------------------------------------------

/// A parsed `ws://host:port/path` relay endpoint. Views borrow the configured
/// URL string, which the caller keeps alive for the resident's life (the same
/// borrow the transport slice already holds on the resident). The host must be
/// an IP literal with an explicit port — the native tier resolves no names —
/// and the scheme must be `ws`: the channel is cleartext, the keyed handshake
/// carries the authentication (`docs/boundaries.md`).
pub const RelayUrl = struct {
    host: []const u8,
    port: u16,
    /// The path including its leading `/` and any fixed query the deployment
    /// carries; empty means `/`. The dial appends its own query pair.
    path: []const u8,

    pub fn parse(url: []const u8) error{InvalidRelayUrl}!RelayUrl {
        const scheme = "ws://";
        if (!std.mem.startsWith(u8, url, scheme)) return error.InvalidRelayUrl;
        const rest = url[scheme.len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        const split = model.uri.splitHostPort(rest[0..slash]) catch return error.InvalidRelayUrl;
        _ = tcp.parseHostPort(split.host, split.port) catch return error.InvalidRelayUrl;
        return .{ .host = split.host, .port = split.port, .path = rest[slash..] };
    }

    /// `?` when the configured path carries no query yet, `&` when it does.
    fn queryJoin(self: RelayUrl) u8 {
        return if (std.mem.indexOfScalar(u8, self.path, '?') == null) '?' else '&';
    }
};

// --- The pinned connection stream ------------------------------------------

/// How many bytes the socket-facing reader and writer each buffer. Sized for
/// the upgrade response and frame headers with room for payload batching; the
/// CapTP-facing steady state is the caller's `Buffers`, not this.
const inner_buf_bytes = 2048;

/// The cap on the relay's HTTP upgrade response. A response still growing past
/// this is refused — the relay is not fully trusted, so the handshake reader
/// is bounded like any inbound parser.
const max_upgrade_response_bytes = 4096;

const WsSource = struct {
    rs: *RelayStream,

    pub fn readSome(self: WsSource, dest: []u8) Io.Reader.Error!usize {
        return self.rs.readSome(dest);
    }
    pub fn writeAll(self: WsSource, bytes: []const u8) Io.Writer.Error!void {
        return self.rs.writeFrame(.binary, bytes);
    }
    pub fn flush(self: WsSource) Io.Writer.Error!void {
        self.rs.writer.interface.flush() catch return error.WriteFailed;
    }
};

const ShimT = stream_shim.Shim(WsSource);

/// One dialed or registered relay socket, pinned so the reader/writer
/// interfaces hold a stable address for the `Connection`'s life (ADR-0043).
/// Carries the WebSocket decode state across reads — including across the
/// parked-listener wait, whose control-frame handling consumes headers before
/// `accept` hands the stream over. Freed through the connection's transport
/// handle, or by the listener that still owns it.
const RelayStream = struct {
    reader: Stream.Reader,
    writer: Stream.Writer,
    ws_reader: ShimT.Reader,
    ws_writer: ShimT.Writer,
    io: std.Io,
    allocator: std.mem.Allocator,
    /// Payload bytes remaining in the data frame being streamed.
    remaining: u64,
    /// A close frame arrived; subsequent reads are a clean end of stream.
    saw_close: bool,
    /// The upgrade completed; before it, teardown skips the close frame (the
    /// stream is still an HTTP conversation).
    upgraded: bool,
    /// Mask keys per outbound frame. Seeded once from the host entropy; RFC
    /// 6455 wants masks an intermediary cannot predict, not a secret.
    mask_rng: std.Random.DefaultPrng,
    read_store: [inner_buf_bytes]u8,
    write_store: [inner_buf_bytes]u8,

    /// Pin a stream over a connected socket. The WebSocket upgrade has not run
    /// yet; `handshake` drives it. On error the caller still owns `stream`.
    fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        stream: Stream,
        mask_seed: u64,
    ) std.mem.Allocator.Error!*RelayStream {
        const rs = try allocator.create(RelayStream);
        rs.io = io;
        rs.allocator = allocator;
        rs.remaining = 0;
        rs.saw_close = false;
        rs.upgraded = false;
        rs.mask_rng = std.Random.DefaultPrng.init(mask_seed);
        rs.reader = stream.reader(io, &rs.read_store);
        rs.writer = stream.writer(io, &rs.write_store);
        return rs;
    }

    /// Wire the CapTP-facing reader/writer over the caller's buffers and weld
    /// to `peer`. Runs once, after the upgrade (and for a registered socket,
    /// after the parked wait).
    fn intoConnection(rs: *RelayStream, peer: *engine.Peer, bufs: Buffers) error{ConnectionLost}!Connection {
        rs.ws_reader = ShimT.Reader.init(.{ .rs = rs }, bufs.read);
        rs.ws_writer = ShimT.Writer.init(.{ .rs = rs }, bufs.write);
        // The peer may send its hello while this leg is still reading the HTTP
        // upgrade response. A socket fill can then leave the first WebSocket
        // frame in the inner reader, beyond the bytes readUpgradeResponse
        // consumed. Pull immediately available payload into the Connection
        // reader: PollHost can observe that buffer before polling the socket,
        // whereas bytes already removed from the kernel produce no readiness
        // event of their own.
        const buffered = probeParked(rs) catch return error.ConnectionLost;
        if (buffered == .closed) return error.ConnectionLost;
        if (buffered == .data_pending and rs.reader.interface.bufferedLen() > 0)
            rs.ws_reader.interface.fillMore() catch return error.ConnectionLost;
        return Connection.init(rs.io, peer, &rs.ws_reader.interface, &rs.ws_writer.interface, .{
            .ctx = rs,
            .close_fn = close,
            .socket_handle_fn = socketHandle,
        });
    }

    fn close(ctx: *anyopaque) void {
        const rs: *RelayStream = @ptrCast(@alignCast(ctx));
        rs.destroy();
    }

    fn destroy(rs: *RelayStream) void {
        // Best-effort close frame so the relay's far leg tears down promptly;
        // the socket close is the authoritative end either way.
        if (rs.upgraded and !rs.saw_close) {
            rs.writeFrame(.close, &.{}) catch {};
            rs.writer.interface.flush() catch {};
        }
        rs.reader.stream.close(rs.io);
        rs.allocator.destroy(rs);
    }

    fn socketHandle(ctx: *anyopaque) ?Io.net.Socket.Handle {
        const rs: *RelayStream = @ptrCast(@alignCast(ctx));
        return rs.reader.stream.socket.handle;
    }

    /// The byte-source read: streams data-frame payload, answers pings, and
    /// surfaces a close frame or a frame-boundary EOF as a clean end. Mid-frame
    /// truncation and every protocol violation are `ReadFailed` — fail closed.
    fn readSome(rs: *RelayStream, dest: []u8) Io.Reader.Error!usize {
        var written: usize = 0;
        while (written < dest.len) {
            if (rs.saw_close) return if (written > 0) written else error.EndOfStream;
            if (rs.remaining > 0) {
                const r = &rs.reader.interface;
                if (r.bufferedLen() == 0) {
                    // A stream read may span several WebSocket data messages,
                    // but it must not block for the next message after already
                    // producing bytes. The caller will poll before asking
                    // again when no lower-buffered message is ready.
                    if (written > 0) return written;
                    r.fillMore() catch |err| switch (err) {
                        error.EndOfStream => return error.ReadFailed, // mid-frame truncation
                        error.ReadFailed => return error.ReadFailed,
                    };
                }
                const avail = r.buffered();
                const n: usize = @intCast(@min(@as(u64, @min(dest.len - written, avail.len)), rs.remaining));
                @memcpy(dest[written..][0..n], avail[0..n]);
                r.toss(n);
                rs.remaining -= n;
                written += n;
                if (rs.remaining > 0 or written == dest.len) return written;
                // A byte stream has no WebSocket message boundary. Consume any
                // fully buffered control frames and continue through a buffered
                // data frame. `probeParked` never reads the socket, so this
                // remains non-blocking after making progress.
                switch (probeParked(rs) catch return error.ReadFailed) {
                    .data_pending => continue,
                    .closed => return written,
                    .idle => return written,
                }
            }
            if (written > 0) {
                switch (probeParked(rs) catch return error.ReadFailed) {
                    .data_pending => continue,
                    .closed => return written,
                    .idle => return written,
                }
            }
            const arrived = rs.nextDataFrame() catch return error.ReadFailed;
            if (!arrived) return if (written > 0) written else error.EndOfStream;
        }
        return written;
    }

    /// Advance the frame state machine to the next data frame, blocking:
    /// handle control frames in place, set `remaining` on a data header, and
    /// report whether one arrived (`false` is a clean end: a close frame, or
    /// EOF on a frame boundary). The parked listener never calls this — its
    /// non-blocking sibling is `probeParked`.
    fn nextDataFrame(rs: *RelayStream) FrameError!bool {
        const r = &rs.reader.interface;
        while (true) {
            if (r.bufferedLen() == 0) {
                // A clean EOF between frames is a graceful close (a relay that
                // drops the socket without a close frame).
                r.fillMore() catch |err| switch (err) {
                    error.EndOfStream => {
                        rs.saw_close = true;
                        return false;
                    },
                    error.ReadFailed => return FrameError.ReadFailed,
                };
            }
            const header = try readFrameHeader(r);
            switch (try rs.consumeFrame(header)) {
                .data => return true,
                .closed => return false,
                .handled => {},
            }
        }
    }

    /// What one consumed frame means to the caller's loop.
    const FrameStep = enum { data, handled, closed };

    /// Consume one frame body given its header: a data frame hands its
    /// payload count to `remaining`, a ping is answered in place, a pong is
    /// drained, a close marks the stream. Both frame loops — the blocking
    /// `nextDataFrame` and the parked `probeParked` — dispatch through this
    /// one arm set, so an opcode fix cannot land in one loop and miss the
    /// other. The reads block only when the caller allows it: the parked
    /// path proves the whole frame is buffered before calling.
    fn consumeFrame(rs: *RelayStream, header: FrameHeader) FrameError!FrameStep {
        const r = &rs.reader.interface;
        switch (header.opcode) {
            .binary, .continuation => {
                if (header.len > 0) {
                    rs.remaining = header.len;
                    return .data;
                }
                // Empty data frame: nothing to hand over, keep scanning.
                return .handled;
            },
            .ping => {
                var payload: [max_control_payload]u8 = undefined;
                const body = payload[0..@intCast(header.len)];
                readHeaderBytes(r, body) catch |err| return err;
                rs.writeFrame(.pong, body) catch return FrameError.ReadFailed;
                rs.writer.interface.flush() catch return FrameError.ReadFailed;
                return .handled;
            },
            .pong => {
                var payload: [max_control_payload]u8 = undefined;
                readHeaderBytes(r, payload[0..@intCast(header.len)]) catch |err| return err;
                return .handled;
            },
            .close => {
                rs.saw_close = true;
                return .closed;
            },
            else => unreachable, // readFrameHeader refused it
        }
    }

    /// One masked client frame: header, then the payload XOR-copied into the
    /// socket writer's buffer — the single copy masking requires.
    fn writeFrame(rs: *RelayStream, opcode: Opcode, bytes: []const u8) Io.Writer.Error!void {
        const w = &rs.writer.interface;
        var mask: [4]u8 = undefined;
        rs.mask_rng.random().bytes(&mask);
        var header: [max_header_len]u8 = undefined;
        try w.writeAll(writeFrameHeader(&header, opcode, bytes.len, mask));
        var i: usize = 0;
        while (i < bytes.len) {
            const chunk = try w.writableSliceGreedy(1);
            const n = @min(chunk.len, bytes.len - i);
            for (chunk[0..n], bytes[i..][0..n]) |*out, in| {
                out.* = in ^ mask[i % 4];
                i += 1;
            }
            w.advance(n);
        }
    }
};

/// The full wire length of the frame header starting `buffered`, or null when
/// fewer than the base two bytes are present. The parked probe uses this to
/// avoid blocking mid-header.
fn headerLenOf(buffered: []const u8) ?usize {
    if (buffered.len < 2) return null;
    const len7 = buffered[1] & 0x7f;
    return switch (len7) {
        126 => 4,
        127 => 10,
        else => 2,
    };
}

// --- The client upgrade ----------------------------------------------------

const UpgradeError = error{
    /// The relay answered, but not with a valid 101 upgrade whose
    /// `Sec-WebSocket-Accept` proves it hashed our key.
    UpgradeRefused,
    /// The socket faulted or closed during the upgrade.
    ConnectionLost,
};

/// Drive the RFC 6455 client upgrade on a fresh `RelayStream`: the GET with
/// `query_key=<designator>` appended to the relay path, then a bounded read of
/// the response, verified by status and accept-key.
fn upgrade(
    rs: *RelayStream,
    relay: RelayUrl,
    query_key: []const u8,
    designator: []const u8,
) UpgradeError!void {
    var key_bytes: [16]u8 = undefined;
    rs.mask_rng.random().bytes(&key_bytes);
    var key_b64: [24]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&key_b64, &key_bytes);

    const w = &rs.writer.interface;
    const path = if (relay.path.len != 0) relay.path else "/";
    w.print(
        "GET {s}{c}{s}={s} HTTP/1.1\r\n" ++
            "Host: {s}:{d}\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: {s}\r\n" ++
            "Sec-WebSocket-Version: 13\r\n\r\n",
        .{ path, relay.queryJoin(), query_key, designator, relay.host, relay.port, &key_b64 },
    ) catch return UpgradeError.ConnectionLost;
    w.flush() catch return UpgradeError.ConnectionLost;

    var expected: [28]u8 = undefined;
    acceptKey(&expected, &key_b64);
    try readUpgradeResponse(&rs.reader.interface, &expected);
    rs.upgraded = true;
}

/// Read and verify the upgrade response: `HTTP/1.1 101` and a matching
/// `Sec-WebSocket-Accept`, within `max_upgrade_response_bytes`. Anything else
/// refuses. Bytes past the blank line stay buffered for the frame reader.
fn readUpgradeResponse(r: *Io.Reader, expected_accept: *const [28]u8) UpgradeError!void {
    const accept_header = "sec-websocket-accept";
    var total: usize = 0;
    var line: [128]u8 = undefined;
    var line_len: usize = 0;
    var overlong = false;
    var first_line = true;
    var accept_ok = false;
    while (true) {
        if (total >= max_upgrade_response_bytes) return UpgradeError.UpgradeRefused;
        const b = r.takeByte() catch return UpgradeError.ConnectionLost;
        total += 1;
        if (b != '\n') {
            if (line_len < line.len) {
                line[line_len] = b;
                line_len += 1;
            } else {
                overlong = true;
            }
            continue;
        }
        var l = line[0..line_len];
        if (l.len > 0 and l[l.len - 1] == '\r') l = l[0 .. l.len - 1];
        if (first_line) {
            // "HTTP/1.1 101 ..." — the status code is all that matters.
            if (l.len < 12 or !std.mem.eql(u8, l[9..12], "101")) return UpgradeError.UpgradeRefused;
            first_line = false;
        } else if (l.len == 0) {
            if (!accept_ok) return UpgradeError.UpgradeRefused;
            return;
        } else if (!overlong) {
            if (std.mem.indexOfScalar(u8, l, ':')) |colon| {
                const name = l[0..colon];
                if (std.ascii.eqlIgnoreCase(name, accept_header)) {
                    const value = std.mem.trim(u8, l[colon + 1 ..], " \t");
                    accept_ok = std.mem.eql(u8, value, expected_accept[0..]);
                }
            }
        }
        line_len = 0;
        overlong = false;
    }
}

// --- Dial ------------------------------------------------------------------

/// Open the relay's rendezvous leg for `designator` and pin the stream. Shared
/// by the dial arm and (with `register_query`) the listener's registration.
fn openLeg(
    io: std.Io,
    allocator: std.mem.Allocator,
    relay: RelayUrl,
    query_key: []const u8,
    designator: []const u8,
) netlayer.DialError!*RelayStream {
    const address = tcp.parseHostPort(relay.host, relay.port) catch return error.InvalidAddress;
    var seed: [8]u8 = undefined;
    io.randomSecure(&seed) catch return error.ConnectionLost;
    const stream = Io.net.IpAddress.connect(&address, io, .{ .mode = .stream }) catch |err|
        return tcp.classifyConnect(err);
    var stream_owned = true;
    errdefer if (stream_owned) stream.close(io);
    const rs = RelayStream.create(allocator, io, stream, std.mem.readInt(u64, &seed, .little)) catch
        return error.OutOfMemory;
    stream_owned = false;
    errdefer rs.destroy();
    upgrade(rs, relay, query_key, designator) catch |err| switch (err) {
        error.UpgradeRefused => return error.ConnectionRefused,
        error.ConnectionLost => return error.ConnectionLost,
    };
    return rs;
}

// --- The keyed-relay netlayer resident -------------------------------------

/// The keyed-relay netlayer's state: the host `std.Io`, the relay's rendezvous
/// URL a dial opens, and — for a host that registers to be cold-dialed — the
/// registration URL and the identity key it registers under. The URL strings
/// are borrowed for the resident's life. The caller owns a `Resident` at a
/// stable address for as long as the transport slice holds the netlayer.
pub const Resident = struct {
    io: std.Io,
    /// The relay's rendezvous WebSocket endpoint a dial opens
    /// (`ws://host:port/relay` for the reference relay). Deployment
    /// configuration of the dialing host, never locator bytes (ADR-0088).
    relay_url: RelayUrl,
    /// The relay's registration endpoint (`ws://host:port/register`), or null
    /// for a dial-only resident; `listen` refuses without one.
    register_url: ?RelayUrl = null,
    /// The identity key `listen` registers under, or null for a dial-only
    /// resident. Derive it from the accept identity's secret so designator and
    /// signing key cannot disagree, as `keyed-tcp` does.
    public_key: ?crypto.PeerKey = null,

    /// Parse `url` into a dial-only resident. `url` is borrowed.
    pub fn init(io: std.Io, url: []const u8) error{InvalidRelayUrl}!Resident {
        return .{ .io = io, .relay_url = try RelayUrl.parse(url) };
    }

    /// This resident as a `Netlayer`. `self` must outlive every connection the
    /// netlayer mints.
    pub fn netlayer(self: *Resident) Netlayer {
        return .{ .ctx = self, .vtable = &resident_vtable };
    }
};

const resident_ctx = netlayer.ResidentContext(Resident);

const resident_vtable: Netlayer.VTable = .{
    .transport_name = transport_name,
    // The designator is the registered peer's Ed25519 key. A driver dial
    // records that target and checks any selected key route against it. The
    // cleartext relay leg cannot authenticate the claim.
    .designator_scheme = .key,
    .dial = residentDial,
    .listen = residentListen,
    .io = resident_ctx.io,
};

fn residentDial(
    ctx: *anyopaque,
    peer: *engine.Peer,
    loc: model.PeerLocator,
    bufs: Buffers,
) netlayer.DialError!Connection {
    const self = resident_ctx.of(ctx);
    if (crypto.PeerKey.fromDesignator(loc.designator) == null) return error.InvalidAddress;
    const rs = try openLeg(self.io, peer.allocator, self.relay_url, rendezvous_query, loc.designator);
    errdefer rs.destroy();
    return try rs.intoConnection(peer, bufs);
}

fn residentListen(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    config: netlayer.ListenConfig,
) netlayer.ListenError!NetLayerListener {
    _ = config; // No local bind: where to register is resident state.
    const self = resident_ctx.of(ctx);
    const register = self.register_url orelse return error.InvalidAddress;
    const key = self.public_key orelse return error.InvalidAddress;
    const box = allocator.create(ListenerBox) catch return error.OutOfMemory;
    errdefer allocator.destroy(box);
    box.* = .{
        .io = self.io,
        .register_url = register,
        .public_key = key,
        .allocator = allocator,
        .parked = null,
    };
    // Register eagerly so the peer is cold-dialable the moment listen returns;
    // a failure here is a bind failure, loud, not a parked retry.
    box.parked = box.registerOne() catch return error.BindFailed;
    return .{ .ctx = box, .vtable = &listener_vtable };
}

/// The registered half: one parked registration socket, replaced as each
/// accept consumes it — the rendezvous shape of a bound TCP listener. The
/// relay buffers a dialer's bytes onto the held socket, so `waitAcceptable`
/// watches the socket, answers relay pings in place, and reports acceptable
/// only when a data frame's bytes arrive.
const ListenerBox = struct {
    io: std.Io,
    register_url: RelayUrl,
    public_key: crypto.PeerKey,
    allocator: std.mem.Allocator,
    parked: ?*RelayStream,

    fn registerOne(box: *ListenerBox) netlayer.DialError!*RelayStream {
        const hex = box.public_key.toDesignator();
        return openLeg(box.io, box.allocator, box.register_url, register_query, hex[0..]);
    }
};

const listener_vtable: NetLayerListener.VTable = .{
    .transport_name = transport_name,
    .designator_scheme = .key,
    .accept = listenerAccept,
    .waitAcceptable = listenerWaitAcceptable,
    .localDesignator = listenerLocalDesignator,
    .close = listenerClose,
};

fn listenerAccept(ctx: *anyopaque, peer: *engine.Peer, bufs: Buffers) netlayer.AcceptError!Connection {
    const box: *ListenerBox = @ptrCast(@alignCast(ctx));
    const rs = box.parked orelse return error.ConnectionLost; // accept follows a true waitAcceptable
    box.parked = null;
    errdefer rs.destroy();
    // The next waitAcceptable registers the replacement, so an accept loop
    // keeps the peer cold-dialable without this call blocking on the relay.
    return try rs.intoConnection(peer, bufs);
}

/// Wait until a dialer's bytes are bridged onto the parked registration.
/// Answers relay pings in place (a parked registration outlives ping
/// intervals) and replaces a torn-down socket on the next wait, so the wait is
/// also the listener's self-healing loop.
fn listenerWaitAcceptable(ctx: *anyopaque, timeout_ms: i32) netlayer.AcceptError!bool {
    const box: *ListenerBox = @ptrCast(@alignCast(ctx));
    const rs = box.parked orelse blk: {
        const fresh = box.registerOne() catch return error.ConnectionLost;
        box.parked = fresh;
        break :blk fresh;
    };
    // Bytes over-read past the upgrade response may already hold a frame.
    switch (probeParked(rs) catch return dropParked(box)) {
        .data_pending => return true,
        .closed => return dropParked(box),
        .idle => {},
    }
    var fds = [_]std.posix.pollfd{.{
        .fd = rs.reader.stream.socket.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = std.posix.poll(&fds, timeout_ms) catch return error.ConnectionLost;
    if (ready == 0) return false;
    // Readable: one fill cannot block, then decide from what is buffered.
    rs.reader.interface.fillMore() catch return dropParked(box);
    return switch (probeParked(rs) catch return dropParked(box)) {
        .data_pending => true,
        .closed => dropParked(box),
        .idle => false,
    };
}

const ParkVerdict = enum { idle, data_pending, closed };

/// Advance the parked stream past the control frames the buffer completely
/// holds — answering pings — without ever issuing a blocking read. A partial
/// header (or a control frame whose payload has not fully arrived) stays
/// buffered as `idle`; the socket poll fires again when the rest lands. A data
/// frame header hands its payload count to the connection-facing reader.
fn probeParked(rs: *RelayStream) FrameError!ParkVerdict {
    if (rs.saw_close) return .closed;
    if (rs.remaining > 0) return .data_pending;
    const r = &rs.reader.interface;
    while (true) {
        const buffered = r.buffered();
        const need = headerLenOf(buffered) orelse return .idle;
        if (buffered.len < need) return .idle;
        const raw_opcode: Opcode = @enumFromInt(@as(u4, @truncate(buffered[0] & 0x0f)));
        switch (raw_opcode) {
            .close, .ping, .pong => {
                const payload_len: usize = buffered[1] & 0x7f;
                if (payload_len <= max_control_payload and buffered.len < need + payload_len)
                    return .idle;
            },
            else => {},
        }
        // Header and any control payload are proven buffered above, so the
        // shared arm set cannot block here.
        const header = try readFrameHeader(r);
        switch (try rs.consumeFrame(header)) {
            .data => return .data_pending,
            .closed => return .closed,
            .handled => {},
        }
    }
}

/// A parked registration died (relay closed or faulted): drop it and report
/// not-acceptable; the next wait registers afresh.
fn dropParked(box: *ListenerBox) netlayer.AcceptError!bool {
    if (box.parked) |rs| rs.destroy();
    box.parked = null;
    return false;
}

/// The dialable designator is the registered identity key's canonical hex;
/// there is no address hint — reachability is the dialer's configured relay.
fn listenerLocalDesignator(ctx: *anyopaque, out: []u8) []const u8 {
    const box: *ListenerBox = @ptrCast(@alignCast(ctx));
    const hex = box.public_key.toDesignator();
    return netlayer.writeDesignator(out, hex[0..]);
}

fn listenerClose(ctx: *anyopaque) void {
    const box: *ListenerBox = @ptrCast(@alignCast(ctx));
    if (box.parked) |rs| rs.destroy();
    box.allocator.destroy(box);
}
