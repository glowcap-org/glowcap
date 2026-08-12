//! The relay transport's blocking resident: RFC 6455 WebSocket client legs
//! over TCP sockets, so a native peer dials — and is dialed through — a relay's
//! rendezvous (ADR-0088). The resident owns both byte-channel profiles:
//! clear `keyed-relay` and Host-sealed `noise-relay`.
//!
//! A `keyed-relay` locator names a peer by its Ed25519 key designator and may
//! carry a provider-owned `rendezvous-relay` hint. Without that hint, a dialer
//! uses its deployment relay; with it, the provider asks the named relay for
//! the same designator. The relay carries bytes and parses nothing; the keyed
//! CapTP handshake carries the claimed designator end to end with the same
//! unauthenticated posture as `keyed-tcp` (the channel is cleartext `ws://`;
//! see `docs/boundaries.md`).
//!
//! Both halves live here. `dial` opens `relay_url` with `?rendezvous=<key>`
//! and yields a `Connection` over the socket. `listen` registers the host's
//! own key at `register_url` (`?id=<key>`) and parks a registration task. That
//! task answers relay pings away from the caller's reactor and wakes
//! `waitAcceptable` only when dialer bytes arrive; `accept` hands over that
//! registered socket and immediately starts its replacement. This is the
//! rendezvous shape of a TCP accept loop without network I/O hidden in a
//! readiness query.
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
//! spelling — the caller's bytes are borrowed). The blocking resident copies
//! inbound payload from its socket reader into the CapTP reader. The completion
//! path instead lends ordinary payload directly from the wrapped backend's
//! shared buffer; only split headers, control frames, upgrade residue, and a
//! coalesced next-frame tail copy into a bounded per-connection spill, whose
//! burst capacity is released after drain. Each blocking connection pins one
//! `RelayStream` (the ADR-0043 stable-address pin) carrying the socket
//! reader/writer stores; that is an application-tier cost, not the loop tier's.
//!
//! The native scale path is the sibling `completion.zig` adapter, which wraps
//! the host platform completion backend and keeps TCP plus outbound relay dials
//! in one `completion.Loop`. Registration accept remains resident-owned; when
//! the profile is `noise-relay`, `driver_core.Host` seals that byte pipe.

const std = @import("std");
const protocol = @import("protocol.zig");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");
const connection = @import("../../connection.zig");
const multiplexed_resident = @import("../../multiplexed_resident.zig");
const netlayer = @import("../../netlayer.zig");
const clock = @import("../../clock.zig");
const operation_owner = @import("../../operation_owner.zig");
const poll = @import("../../poll.zig");
const socket = @import("../../socket.zig");
const stream_shim = @import("../../stream_shim.zig");
const wake_channel = @import("../../wake_channel.zig");
const tcp = @import("../tcp.zig");

const crypto = foundation.crypto;
const Io = std.Io;
const Stream = Io.net.Stream;

const Netlayer = netlayer.Netlayer;
const NetLayerListener = netlayer.Listener;
const Buffers = netlayer.Buffers;
const Connection = connection.Connection;
const DialError = netlayer.DialError;
const ListenError = netlayer.ListenError;
const ListenConfig = netlayer.ListenConfig;

/// The relay package's default clear profile. A resident or listener carries
/// its selected profile when ownership-sensitive code needs the distinction.
pub const transport_name = model.transport.keyed_relay;
const rendezvous_query = protocol.rendezvous_query;
const register_query = protocol.register_query;

const Opcode = protocol.Opcode;
const OutgoingOpcode = protocol.OutgoingOpcode;
const FrameHeader = protocol.FrameHeader;
pub const FrameError = protocol.ParseError || error{ Truncated, ReadFailed };
const max_control_payload = protocol.max_control_payload;
const max_header_len = protocol.max_header_len;
const writeFrameHeader = protocol.writeFrameHeader;
const acceptKey = protocol.acceptKey;
const RelayUrl = protocol.RelayUrl;
const headerLenOf = protocol.headerLenOf;
const parseHeaderBytes = protocol.parseHeaderBytes;
const admitFrame = protocol.admitFrame;
pub const rendezvous_relay_hint = protocol.rendezvous_relay_hint;
pub const max_rendezvous_relay_hint_bytes = protocol.max_rendezvous_relay_hint_bytes;

const UpgradeError = error{
    UpgradeRefused,
    ConnectionLost,
    UpgradeTimedOut,
};

/// A relay that accepts the TCP leg but never completes HTTP upgrade must not
/// pin a resident worker forever. The short poll slice also gives structured
/// cancellation a bounded observation point without putting a raw blocking
/// read in the destructor path.
const upgrade_timeout_ms: i64 = 10_000;
const upgrade_poll_slice_ms: i32 = 50;
const listener_poll_slice_ms: i32 = 50;
const registration_retry_delay_ms: i64 = 100;

/// Reader adapter for the pure frame-header parser. The resident is the only
/// tier allowed to wait for bytes; completion code calls `parseHeaderBytes`
/// directly on buffers its backend delivered.
pub fn readFrameHeader(r: *Io.Reader) FrameError!FrameHeader {
    var header: [10]u8 = undefined;
    header[0] = try takeHeaderByte(r);
    header[1] = try takeHeaderByte(r);
    const need = headerLenOf(header[0..2]).?;
    try readHeaderBytes(r, header[2..need]);
    return (try parseHeaderBytes(header[0..need])).?.frame;
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

/// Wait for and verify the bounded RFC 6455 upgrade response. Bytes after the
/// terminating blank line remain in the reader for the WebSocket frame path.
fn readUpgradeResponse(
    rs: *RelayStream,
    expected_accept: *const [28]u8,
    deadline_ms: i64,
) UpgradeError!void {
    var total: usize = 0;
    var line: [protocol.max_upgrade_response_bytes]u8 = undefined;
    var line_len: usize = 0;
    var first_line = true;
    var response = protocol.UpgradeResponseValidator{};
    while (true) {
        if (total >= protocol.max_upgrade_response_bytes) return error.UpgradeRefused;
        while (rs.reader.interface.bufferedLen() == 0) {
            std.Io.checkCancel(rs.io) catch return error.ConnectionLost;
            const remaining = deadline_ms - clock.nowMs(rs.io);
            if (remaining <= 0) return error.UpgradeTimedOut;
            var fds = [_]std.posix.pollfd{.{
                .fd = rs.reader.stream.socket.handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const timeout: i32 = @intCast(@min(remaining, @as(i64, upgrade_poll_slice_ms)));
            const ready = poll.wait(&fds, timeout) catch return error.ConnectionLost;
            if (ready == 0) continue;
            if (fds[0].revents & std.posix.POLL.NVAL != 0)
                return error.ConnectionLost;
            if (fds[0].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP) != 0 and
                fds[0].revents & std.posix.POLL.IN == 0)
                return error.ConnectionLost;
            break;
        }
        const b = rs.reader.interface.takeByte() catch return error.ConnectionLost;
        total += 1;
        if (b != '\n') {
            line[line_len] = b;
            line_len += 1;
            continue;
        }
        if (line_len == 0 or line[line_len - 1] != '\r') return error.UpgradeRefused;
        const complete = line[0 .. line_len - 1];
        if (first_line) {
            if (!protocol.validUpgradeStatus(complete)) return error.UpgradeRefused;
            first_line = false;
        } else if (complete.len == 0) {
            if (!response.valid()) return error.UpgradeRefused;
            return;
        } else {
            response.observe(complete, expected_accept);
        }
        line_len = 0;
    }
}

// --- The pinned connection stream ------------------------------------------

/// How many bytes the socket-facing reader and writer each buffer. Sized for
/// the upgrade response and frame headers with room for payload batching; the
/// CapTP-facing steady state is the caller's `Buffers`, not this.
const inner_buf_bytes = 2048;
const staged_control_bytes = max_header_len + max_control_payload;
const max_staged_application_bytes = inner_buf_bytes - max_header_len - staged_control_bytes;

comptime {
    std.debug.assert(max_staged_application_bytes > 0);
}

const upgrade_request_fmt = protocol.upgrade_request_fmt;

const WsSource = struct {
    rs: *RelayStream,

    pub fn readSome(self: WsSource, dest: []u8) Io.Reader.Error!usize {
        return self.rs.readSome(dest);
    }
    pub fn writeAll(self: WsSource, bytes: []const u8) Io.Writer.Error!void {
        // RFC 6455 section 5.5.1 forbids data frames after either half has
        // started the close handshake. Control replies still use writeFrame
        // directly, so this gate applies only to application bytes.
        if (self.rs.read_closed or self.rs.close_sent) return error.WriteFailed;
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
    /// Whether a non-final binary message is waiting for continuation frames.
    fragmented: bool,
    /// The receive half reached a close frame or a clean frame-boundary EOF.
    read_closed: bool,
    close_sent: bool,
    /// Mask keys per outbound frame. Seeded once from the host entropy; RFC
    /// 6455 wants masks an intermediary cannot predict, not a secret.
    mask_rng: std.Random.DefaultCsprng,
    read_store: [inner_buf_bytes]u8,
    write_store: [inner_buf_bytes]u8,

    /// Pin a stream over a connected socket. The WebSocket upgrade has not run
    /// yet; `handshake` drives it. On error the caller still owns `stream`.
    fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        stream: Stream,
        mask_seed: [std.Random.DefaultCsprng.secret_seed_length]u8,
    ) std.mem.Allocator.Error!*RelayStream {
        const rs = try allocator.create(RelayStream);
        rs.io = io;
        rs.allocator = allocator;
        rs.remaining = 0;
        rs.fragmented = false;
        rs.read_closed = false;
        rs.close_sent = false;
        rs.mask_rng = std.Random.DefaultCsprng.init(mask_seed);
        rs.reader = stream.reader(io, &rs.read_store);
        rs.writer = stream.writer(io, &rs.write_store);
        return rs;
    }

    /// Re-pin a listener-owned registration stream under the accepted peer.
    /// The concrete std.Io interfaces contain pointers into their enclosing
    /// RelayStream, so allocator transfer is reconstruction, not a struct move.
    /// Upgrade and control writes are normally flushed before this boundary;
    /// reconstruct both buffers anyway so correctness does not depend on that
    /// scheduling invariant.
    fn moveToAllocator(rs: *RelayStream, allocator: std.mem.Allocator) std.mem.Allocator.Error!*RelayStream {
        if (rs.allocator.ptr == allocator.ptr and rs.allocator.vtable == allocator.vtable) return rs;

        const moved = try allocator.create(RelayStream);
        moved.io = rs.io;
        moved.allocator = allocator;
        moved.remaining = rs.remaining;
        moved.fragmented = rs.fragmented;
        moved.read_closed = rs.read_closed;
        moved.close_sent = rs.close_sent;
        moved.mask_rng = rs.mask_rng;

        const stream = rs.reader.stream;
        const buffered = rs.reader.interface.buffered();
        const pending_write = rs.writer.interface.buffer[0..rs.writer.interface.end];
        moved.reader = stream.reader(rs.io, &moved.read_store);
        @memcpy(moved.read_store[0..buffered.len], buffered);
        moved.reader.interface.end = buffered.len;
        moved.reader.err = rs.reader.err;
        moved.writer = stream.writer(rs.io, &moved.write_store);
        @memcpy(moved.write_store[0..pending_write.len], pending_write);
        moved.writer.interface.end = pending_write.len;
        moved.writer.err = rs.writer.err;
        moved.writer.write_file_err = rs.writer.write_file_err;

        rs.allocator.destroy(rs);
        return moved;
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
        // consumed. Lend only those already-buffered payload bytes to the
        // Connection reader: HostRuntime can observe them before polling the
        // socket, and accept never enters a source read that could park.
        const buffered = probeParked(rs) catch return error.ConnectionLost;
        if (buffered == .closed) return error.ConnectionLost;
        if (buffered == .data_pending) rs.primeConnectionReader();
        return Connection.init(rs.io, peer, &rs.ws_reader.interface, &rs.ws_writer.interface, .{
            .ctx = rs,
            .close_fn = close,
            .socket_handle_fn = socketHandle,
        });
    }

    /// Copy only payload bytes the inner socket reader already owns. This is
    /// the readiness-to-accept handoff, so it deliberately bypasses the shim's
    /// generic fill operation: even a future change to `readSome` cannot turn
    /// an acceptable listener into a blocking accept.
    fn primeConnectionReader(rs: *RelayStream) void {
        const source = rs.reader.interface.buffered();
        const n: usize = @intCast(@min(
            @as(u64, @min(source.len, rs.ws_reader.interface.buffer.len)),
            rs.remaining,
        ));
        if (n == 0) return;
        @memcpy(rs.ws_reader.interface.buffer[0..n], source[0..n]);
        rs.ws_reader.interface.end = n;
        rs.reader.interface.toss(n);
        rs.remaining -= n;
    }

    fn close(ctx: *anyopaque) void {
        const rs: *RelayStream = @ptrCast(@alignCast(ctx));
        rs.destroy();
    }

    fn destroy(rs: *RelayStream) void {
        // Destruction is abortive by contract. A close frame is a graceful
        // protocol operation and belongs to an active, bounded I/O owner; a
        // destructor cannot perform network I/O without making every unwind
        // path capable of parking its caller.
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
            if (rs.read_closed) return if (written > 0) written else error.EndOfStream;
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

    /// Read application bytes without parking the caller. Socket readiness is
    /// only a hint for WebSocket: it may announce a ping, a partial header, or
    /// EOF rather than application data. This loop consumes exactly the bytes
    /// currently available, stages one bounded control reply, and reports
    /// `WouldBlock` once another kernel edge is required.
    fn tryReadSome(rs: *RelayStream, dest: []u8) (Io.Reader.Error || error{WouldBlock})!usize {
        if (rs.writer.interface.end != 0) return error.WouldBlock;
        var written: usize = 0;
        while (written < dest.len) {
            if (rs.read_closed) return if (written > 0) written else error.EndOfStream;
            if (rs.remaining > 0) {
                const r = &rs.reader.interface;
                if (r.bufferedLen() == 0) {
                    if (!rs.socketReadable()) return if (written > 0) written else error.WouldBlock;
                    r.fillMore() catch |err| switch (err) {
                        error.EndOfStream => return error.ReadFailed,
                        error.ReadFailed => return error.ReadFailed,
                    };
                }
                const available = r.buffered();
                const n: usize = @intCast(@min(
                    @as(u64, @min(dest.len - written, available.len)),
                    rs.remaining,
                ));
                @memcpy(dest[written..][0..n], available[0..n]);
                r.toss(n);
                rs.remaining -= n;
                written += n;
                if (rs.remaining > 0 or written == dest.len) return written;
            }

            const r = &rs.reader.interface;
            const buffered = r.buffered();
            const parsed = (parseHeaderBytes(buffered) catch return error.ReadFailed) orelse {
                if (written > 0) return written;
                if (!rs.socketReadable()) return error.WouldBlock;
                r.fillMore() catch |err| switch (err) {
                    error.EndOfStream => {
                        if (buffered.len != 0) return error.ReadFailed;
                        rs.read_closed = true;
                        return error.EndOfStream;
                    },
                    error.ReadFailed => return error.ReadFailed,
                };
                continue;
            };
            const body_len = protocol.controlPayloadLen(parsed.frame);
            if (buffered.len < parsed.header_len + body_len) {
                if (written > 0) return written;
                if (!rs.socketReadable()) return error.WouldBlock;
                r.fillMore() catch return error.ReadFailed;
                continue;
            }
            r.toss(parsed.header_len);
            const body = r.buffered()[0..body_len];
            const step = rs.applyFrame(parsed.frame, body, .staged) catch return error.ReadFailed;
            r.toss(body_len);
            switch (step) {
                .data => {},
                .closed => return if (written > 0) written else error.EndOfStream,
                .handled => if (rs.writer.interface.end != 0)
                    return if (written > 0) written else error.WouldBlock,
            }
        }
        return written;
    }

    fn socketReadable(rs: *RelayStream) bool {
        var fds = [_]std.posix.pollfd{.{
            .fd = rs.reader.stream.socket.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const count = poll.wait(&fds, 0) catch return false;
        return count != 0 and fds[0].revents &
            (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR) != 0;
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
                        rs.read_closed = true;
                        return false;
                    },
                    error.ReadFailed => return FrameError.ReadFailed,
                };
            }
            const header = try readFrameHeader(r);
            var payload: [max_control_payload]u8 = undefined;
            const body = try readControlPayload(r, header, &payload);
            switch (try rs.applyFrame(header, body, .blocking)) {
                .data => return true,
                .closed => return false,
                .handled => {},
            }
        }
    }

    /// What one consumed frame means to the caller's loop.
    const FrameStep = enum { data, handled, closed };

    /// Read the bounded control payload for the blocking frame loop. Data
    /// payload remains in the reader and streams through `readSome`.
    fn readControlPayload(
        r: *Io.Reader,
        header: FrameHeader,
        storage: *[max_control_payload]u8,
    ) FrameError![]const u8 {
        return switch (header.opcode) {
            .close, .ping, .pong => blk: {
                const bytes = storage[0..protocol.controlPayloadLen(header)];
                try readHeaderBytes(r, bytes);
                break :blk bytes;
            },
            .binary, .continuation => &.{},
            else => unreachable,
        };
    }

    /// Apply one frame whose bounded control body is already available: a data frame hands its
    /// payload count to `remaining`, a ping is answered in place, a pong is
    /// drained, a close marks the stream. Both frame loops — the blocking
    /// `nextDataFrame` and the parked `probeParked` — dispatch through this
    /// one arm set, so an opcode fix cannot land in one loop and miss the
    /// other. The reads block only when the caller allows it: the parked
    /// path passes a borrow from bytes it already proved buffered.
    const ControlWrite = enum { blocking, staged };

    fn applyFrame(
        rs: *RelayStream,
        header: FrameHeader,
        body: []const u8,
        control_write: ControlWrite,
    ) FrameError!FrameStep {
        switch (try admitFrame(&rs.fragmented, header, body)) {
            .data => {
                if (header.len > 0) {
                    rs.remaining = header.len;
                    return .data;
                }
                // Empty data frame: nothing to hand over, keep scanning.
                return .handled;
            },
            .ping => {
                rs.writeFrame(.pong, body) catch return FrameError.ReadFailed;
                if (control_write == .blocking)
                    rs.writer.interface.flush() catch return FrameError.ReadFailed;
                return .handled;
            },
            .pong => return .handled,
            .close => {
                if (!rs.close_sent) {
                    rs.writeFrame(.close, body) catch return FrameError.ReadFailed;
                    if (control_write == .blocking)
                        rs.writer.interface.flush() catch return FrameError.ReadFailed;
                }
                rs.read_closed = true;
                return .closed;
            },
        }
    }

    /// One masked client frame: header, then the payload XOR-copied into the
    /// socket writer's buffer — the single copy masking requires.
    fn writeFrame(rs: *RelayStream, opcode: OutgoingOpcode, bytes: []const u8) Io.Writer.Error!void {
        const w = &rs.writer.interface;
        var mask: [4]u8 = undefined;
        rs.mask_rng.random().bytes(&mask);
        var header: [max_header_len]u8 = undefined;
        try w.writeAll(writeFrameHeader(&header, opcode, bytes.len, mask) catch return error.WriteFailed);
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
        if (opcode == .close) rs.close_sent = true;
    }

    fn tryWriteSome(rs: *RelayStream, bytes: []const u8) isize {
        if (bytes.len == 0) return 0;
        const flushed = rs.tryFlushPending();
        if (flushed < 0) return flushed;
        if (rs.writer.interface.end != 0) return multiplexed_resident.would_block;
        const consumed = @min(bytes.len, max_staged_application_bytes);
        rs.writeFrame(.binary, bytes[0..consumed]) catch return -1;
        _ = rs.tryFlushPending();
        return @intCast(consumed);
    }

    fn tryFlushPending(rs: *RelayStream) isize {
        const w = &rs.writer.interface;
        if (w.end == 0) return 0;
        const n = socket.sendNonblocking(
            rs.reader.stream.socket.handle,
            w.buffer[0..w.end],
        ) catch |err| return switch (err) {
            error.WouldBlock => multiplexed_resident.would_block,
            error.SendFailed => -1,
        };
        if (n == 0) return 0;
        const remaining = w.end - n;
        std.mem.copyForwards(u8, w.buffer[0..remaining], w.buffer[n..w.end]);
        w.end = remaining;
        return @intCast(n);
    }
};

// --- The client upgrade ----------------------------------------------------

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
        upgrade_request_fmt,
        .{ path, relay.queryJoin(), query_key, designator, relay.authority_host, relay.port, &key_b64 },
    ) catch return UpgradeError.ConnectionLost;
    w.flush() catch return UpgradeError.ConnectionLost;

    var expected: [28]u8 = undefined;
    acceptKey(&expected, &key_b64);
    const deadline_ms = clock.nowMs(rs.io) + upgrade_timeout_ms;
    try readUpgradeResponse(rs, &expected, deadline_ms);
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
    var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
    io.randomSecure(&seed) catch return error.ConnectionLost;
    const stream = Io.net.IpAddress.connect(&address, io, .{ .mode = .stream }) catch |err|
        return tcp.classifyConnect(err);
    var stream_owned = true;
    errdefer if (stream_owned) stream.close(io);
    const rs = RelayStream.create(allocator, io, stream, seed) catch
        return error.OutOfMemory;
    stream_owned = false;
    errdefer rs.destroy();
    upgrade(rs, relay, query_key, designator) catch |err| switch (err) {
        error.UpgradeRefused => return error.ConnectionRefused,
        error.ConnectionLost => return error.ConnectionLost,
        error.UpgradeTimedOut => return error.TimedOut,
    };
    return rs;
}

// --- The keyed-relay netlayer resident -------------------------------------

/// Which wire protocol runs over the relay pipe. Both profiles use the same
/// key-addressed rendezvous; only `noise-relay` asks the owning Host to run the
/// sealed channel before CapTP bytes move.
pub const ChannelProfile = enum {
    keyed,
    noise,

    fn known(self: ChannelProfile) model.transport.Known {
        return switch (self) {
            .keyed => .keyed_relay,
            .noise => .noise_relay,
        };
    }

    fn transportName(self: ChannelProfile) []const u8 {
        return self.known().metadata().symbol;
    }
};

/// The relay netlayer's state: the selected channel profile, host `std.Io`, the
/// relay's rendezvous URL a dial opens, and — for a host that registers to be
/// cold-dialed — the registration URL and identity key it registers under. The resident owns
/// one configuration block that both parsed URLs view, so a netlayer can safely
/// outlive the caller's argv, environment, or request buffer. A listener copies
/// its registration URL when it is minted; its replacement-registration task
/// therefore depends on the listener, not this resident.
pub const Resident = struct {
    pub const InitError = error{ InvalidRelayUrl, OutOfMemory };

    const Registration = union(enum) {
        dial_only,
        registered: struct {
            url_text: []const u8,
            /// A product may pin the registration identity at construction.
            /// Provider packages leave it null and take the identity from the
            /// Host at listener creation, where that authority already lives.
            public_key: ?crypto.PeerKey,
        },
    };

    allocator: std.mem.Allocator,
    url_storage: []u8,
    /// Exact deployment URL text, borrowed from `url_storage` and copied into
    /// listeners that advertise this resident's rendezvous route.
    relay_url_text: []const u8,
    io: std.Io,
    profile: ChannelProfile,
    /// The deployment relay used when a dial has no `rendezvous-relay` hint.
    /// A valid provider hint may override this per dial.
    relay_url: RelayUrl,
    registration: Registration = .dial_only,

    /// Copy and parse `url` into a dial-only resident.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, url: []const u8) InitError!Resident {
        return initProfile(allocator, io, url, .keyed);
    }

    /// Copy and parse `url` into a dial-only resident for `profile`.
    pub fn initProfile(
        allocator: std.mem.Allocator,
        io: std.Io,
        url: []const u8,
        profile: ChannelProfile,
    ) InitError!Resident {
        const storage = try allocator.dupe(u8, url);
        errdefer allocator.free(storage);
        return .{
            .allocator = allocator,
            .url_storage = storage,
            .relay_url_text = storage,
            .io = io,
            .profile = profile,
            .relay_url = try RelayUrl.parse(storage),
        };
    }

    /// Parse a resident that can both dial through `relay_url` and register a
    /// listener at `register_url`. The caller derives `public_key` from the Host
    /// identity used to sign accepted sessions.
    pub fn initRegistered(
        allocator: std.mem.Allocator,
        io: std.Io,
        relay_url: []const u8,
        register_url: []const u8,
        public_key: crypto.PeerKey,
    ) InitError!Resident {
        return initRegisteredProfile(allocator, io, relay_url, register_url, public_key, .keyed);
    }

    /// Parse a resident that dials and registers the selected relay profile.
    pub fn initRegisteredProfile(
        allocator: std.mem.Allocator,
        io: std.Io,
        relay_url: []const u8,
        register_url: []const u8,
        public_key: crypto.PeerKey,
        profile: ChannelProfile,
    ) InitError!Resident {
        const total = std.math.add(usize, relay_url.len, register_url.len) catch
            return error.OutOfMemory;
        const storage = try allocator.alloc(u8, total);
        errdefer allocator.free(storage);
        @memcpy(storage[0..relay_url.len], relay_url);
        @memcpy(storage[relay_url.len..], register_url);
        const owned_relay = storage[0..relay_url.len];
        const owned_register = storage[relay_url.len..];
        const parsed_register = try RelayUrl.parse(owned_register);
        const parsed_relay = try RelayUrl.parse(owned_relay);
        if (!sameRelayAuthority(parsed_relay, parsed_register))
            return error.InvalidRelayUrl;
        return .{
            .allocator = allocator,
            .url_storage = storage,
            .relay_url_text = owned_relay,
            .io = io,
            .profile = profile,
            .relay_url = parsed_relay,
            .registration = .{ .registered = .{
                .url_text = owned_register,
                .public_key = public_key,
            } },
        };
    }

    /// Parse a resident whose listener identity is supplied by the owning Host
    /// at listen time. This is the provider-package posture: deployment owns
    /// relay URLs, while the Host remains the sole identity authority.
    pub fn initProviderProfile(
        allocator: std.mem.Allocator,
        io: std.Io,
        relay_url: []const u8,
        register_url: []const u8,
        profile: ChannelProfile,
    ) InitError!Resident {
        const total = std.math.add(usize, relay_url.len, register_url.len) catch
            return error.OutOfMemory;
        const storage = try allocator.alloc(u8, total);
        errdefer allocator.free(storage);
        @memcpy(storage[0..relay_url.len], relay_url);
        @memcpy(storage[relay_url.len..], register_url);
        const owned_relay = storage[0..relay_url.len];
        const owned_register = storage[relay_url.len..];
        const parsed_register = try RelayUrl.parse(owned_register);
        const parsed_relay = try RelayUrl.parse(owned_relay);
        if (!sameRelayAuthority(parsed_relay, parsed_register))
            return error.InvalidRelayUrl;
        return .{
            .allocator = allocator,
            .url_storage = storage,
            .relay_url_text = owned_relay,
            .io = io,
            .profile = profile,
            .relay_url = parsed_relay,
            .registration = .{ .registered = .{
                .url_text = owned_register,
                .public_key = null,
            } },
        };
    }

    pub fn deinit(self: *Resident) void {
        self.allocator.free(self.url_storage);
        self.* = undefined;
    }

    /// This resident as a `Netlayer`. `self` must outlive every dial/listen call
    /// through the returned vtable. Minted connections and listeners own the
    /// state their later I/O needs.
    pub fn netlayer(self: *Resident) Netlayer {
        return .{ .ctx = self, .vtable = switch (self.profile) {
            .keyed => &keyed_resident_vtable,
            .noise => &noise_resident_vtable,
        } };
    }

    /// Open the relay leg without attaching it to a protocol peer. Provider
    /// archives use this byte seam; the Host above them owns framing and any
    /// sealed channel selected by the profile.
    pub fn dialRaw(self: *Resident, locator: model.PeerLocator) DialError!RawConnection {
        if (!std.mem.eql(u8, locator.transport, self.profile.transportName()) or
            crypto.PeerKey.fromDesignator(locator.designator) == null)
            return error.InvalidAddress;
        const relay = relayForDial(self, locator) catch return error.InvalidAddress;
        return .{ .stream = try openLeg(
            self.io,
            self.allocator,
            relay,
            rendezvous_query,
            locator.designator,
        ) };
    }

    /// Start one profile listener. The listener copies all runtime state it
    /// needs, so it remains valid until closed even if the resident's package
    /// lease is the only reference keeping this runtime alive.
    pub fn listenRaw(
        self: *Resident,
        allocator: std.mem.Allocator,
        config: ListenConfig,
    ) ListenError!RawListener {
        if (self.relay_url_text.len > max_rendezvous_relay_hint_bytes)
            return error.BindFailed;
        const registered = switch (self.registration) {
            .dial_only => return error.InvalidAddress,
            .registered => |configured| configured,
        };
        const identity = config.identity orelse return error.InvalidAddress;
        if (registered.public_key) |expected| {
            if (!std.mem.eql(u8, &identity.bytes, &expected.bytes))
                return error.InvalidAddress;
        }
        if (config.designator.len != 0) {
            const expected = identity.toDesignator();
            if (!std.mem.eql(u8, config.designator, &expected)) return error.InvalidAddress;
        }
        const register_url_storage = allocator.dupe(u8, registered.url_text) catch
            return error.OutOfMemory;
        errdefer allocator.free(register_url_storage);
        const relay_url_storage = allocator.dupe(u8, self.relay_url_text) catch
            return error.OutOfMemory;
        errdefer allocator.free(relay_url_storage);
        const box = allocator.create(ListenerBox) catch return error.OutOfMemory;
        errdefer allocator.destroy(box);
        const wake = wake_channel.WakeChannel.open() catch return error.BindFailed;
        errdefer wake.deinit();
        box.* = .{
            .io = self.io,
            .register_url_storage = register_url_storage,
            .register_url = RelayUrl.parse(register_url_storage) catch unreachable,
            .relay_url_storage = relay_url_storage,
            .public_key = identity,
            .profile = self.profile,
            .allocator = allocator,
            .ready = null,
            .wake = wake,
            .registrations = undefined,
            .registration = undefined,
            .registration_retry_at_ms = 0,
        };
        box.registration = .{ .box = box };
        box.registrations.init(self.io) catch return error.BindFailed;
        errdefer box.registrations.join();
        box.startRegistration() catch return error.BindFailed;
        return .{ .box = box };
    }
};

fn sameRelayAuthority(left: RelayUrl, right: RelayUrl) bool {
    return left.port == right.port and std.mem.eql(u8, left.host, right.host);
}

/// Select the relay for one provider dial. A keyed-relay locator's designator
/// remains the target identity; this hint only tells the provider which relay
/// to ask for that identity. The deployment URL remains the default so
/// existing locators retain shared-relay behavior.
fn relayForDial(self: *const Resident, locator: model.PeerLocator) error{InvalidAddress}!RelayUrl {
    model.validatePeerLocator(locator) catch return error.InvalidAddress;
    return (protocol.relayHint(locator.hints) catch return error.InvalidAddress) orelse self.relay_url;
}

/// One raw relay byte stream. It owns the connected WebSocket leg but knows
/// nothing about CapTP frames or sealed-channel policy.
pub const RawConnection = struct {
    stream: *RelayStream,

    pub fn read(self: *RawConnection, dest: []u8) Io.Reader.Error!usize {
        return self.stream.readSome(dest);
    }

    pub fn writeAll(self: *RawConnection, bytes: []const u8) Io.Writer.Error!void {
        try self.stream.writeFrame(.binary, bytes);
        try self.stream.writer.interface.flush();
    }

    /// Multiplexed-provider read: application bytes, clean EOF, fatal failure, or
    /// `multiplexed_resident.would_block`. Control-only readability is consumed
    /// without being mistaken for application progress.
    pub fn tryRead(self: *RawConnection, dest: []u8) isize {
        const count = self.stream.tryReadSome(dest) catch |err| return switch (err) {
            error.WouldBlock => multiplexed_resident.would_block,
            error.EndOfStream => 0,
            error.ReadFailed => -1,
        };
        return @intCast(count);
    }

    /// Multiplexed-provider write. A consumed prefix is masked into the stream's
    /// fixed staging buffer before this returns; no caller borrow escapes.
    pub fn tryWrite(self: *RawConnection, bytes: []const u8) isize {
        return self.stream.tryWriteSome(bytes);
    }

    /// Flush already-owned masked bytes without blocking.
    pub fn flushPending(self: *RawConnection) isize {
        return self.stream.tryFlushPending();
    }

    pub fn hasPendingWrite(self: *const RawConnection) bool {
        return self.stream.writer.interface.end != 0;
    }

    pub fn readinessFd(self: *const RawConnection) i32 {
        return self.stream.reader.stream.socket.handle;
    }

    pub fn close(self: *RawConnection) void {
        self.stream.destroy();
        self.* = undefined;
    }
};

/// One raw registered relay listener. Registration and replacement work is
/// background-owned; these methods only observe its wake descriptor or claim a
/// stream that is already acceptable.
pub const RawListener = struct {
    box: *ListenerBox,

    pub fn waitReady(self: RawListener, timeout_ms: i32) netlayer.AcceptError!bool {
        return listenerWait(self.box, timeout_ms, .registered);
    }

    pub fn waitAcceptable(self: RawListener, timeout_ms: i32) netlayer.AcceptError!bool {
        return listenerWait(self.box, timeout_ms, .acceptable);
    }

    pub fn readinessFd(self: RawListener) i32 {
        return self.box.wake.read;
    }

    pub fn localLocator(
        self: RawListener,
        allocator: std.mem.Allocator,
    ) netlayer.ListenError!model.PeerLocator {
        return listenerLocalLocator(self.box, allocator);
    }

    pub fn canonicalizeLocator(
        self: RawListener,
        allocator: std.mem.Allocator,
        locator: model.PeerLocator,
    ) netlayer.ListenError!model.PeerLocator {
        return listenerCanonicalizeLocator(self.box, allocator, locator);
    }

    pub fn accept(self: RawListener, allocator: std.mem.Allocator) netlayer.AcceptError!RawConnection {
        const box = self.box;
        box.operation_gate.lockUncancelable(box.io);
        defer box.operation_gate.unlock(box.io);
        _ = try listenerWaitLocked(box, -1, .acceptable);
        var stream = box.ready orelse return error.ConnectionLost;
        box.ready = null;
        box.registration_ready = false;
        errdefer stream.destroy();
        box.startRegistration() catch |err| switch (err) {
            error.Closing => return error.ConnectionLost,
            error.ConcurrencyUnavailable => box.scheduleRegistrationRetry(),
        };
        stream = try stream.moveToAllocator(allocator);
        return .{ .stream = stream };
    }

    pub fn close(self: RawListener) void {
        listenerClose(self.box);
    }
};

/// One native realization of both relay channel profiles over the same
/// deployment rendezvous. Initialize only after the containing owner reaches
/// its final address: each netlayer context points at an inline resident.
pub const Provider = struct {
    keyed_resident: Resident = undefined,
    noise_resident: Resident = undefined,
    layers: [2]Netlayer = undefined,

    pub fn init(
        self: *Provider,
        allocator: std.mem.Allocator,
        io: std.Io,
        relay_url: []const u8,
    ) Resident.InitError!void {
        self.keyed_resident = try Resident.initProfile(allocator, io, relay_url, .keyed);
        errdefer self.keyed_resident.deinit();
        self.noise_resident = try Resident.initProfile(allocator, io, relay_url, .noise);
        self.layers = .{
            self.keyed_resident.netlayer(),
            self.noise_resident.netlayer(),
        };
    }

    pub fn deinit(self: *Provider) void {
        self.noise_resident.deinit();
        self.keyed_resident.deinit();
        self.* = undefined;
    }

    pub fn netlayers(self: *Provider) []const Netlayer {
        return &self.layers;
    }
};

const resident_ctx = netlayer.ResidentContext(Resident);

const keyed_resident_vtable: Netlayer.VTable = residentVtable(.keyed);
const noise_resident_vtable: Netlayer.VTable = residentVtable(.noise);

fn residentVtable(comptime profile: ChannelProfile) Netlayer.VTable {
    return .{
        .profile = profile.known().metadata(),
        .dial = residentDial,
        .listen = residentListen,
        .io = resident_ctx.io,
    };
}

fn residentDial(
    ctx: *anyopaque,
    peer: *engine.Peer,
    loc: model.PeerLocator,
    bufs: Buffers,
) netlayer.DialError!Connection {
    const self = resident_ctx.of(ctx);
    var raw = try self.dialRaw(loc);
    errdefer raw.close();
    raw.stream = try raw.stream.moveToAllocator(peer.allocator);
    return try raw.stream.intoConnection(peer, bufs);
}

fn residentListen(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    config: netlayer.ListenConfig,
) netlayer.ListenError!NetLayerListener {
    const self = resident_ctx.of(ctx);
    const raw = try self.listenRaw(allocator, config);
    return .{ .ctx = raw.box, .vtable = switch (self.profile) {
        .keyed => &keyed_listener_vtable,
        .noise => &noise_listener_vtable,
    } };
}

/// The registered half: one background-owned registration socket, replaced as
/// each accept consumes it — the rendezvous shape of a bound TCP listener. The
/// task answers relay control frames and wakes the listener only when dialer
/// data is ready, so the caller's readiness wait performs no network I/O.
const ListenerBox = struct {
    io: std.Io,
    /// Sole owner of every slice in `register_url`.
    register_url_storage: []u8,
    register_url: RelayUrl,
    /// Sole owner of the relay URL published in the listener locator.
    relay_url_storage: []u8,
    public_key: crypto.PeerKey,
    profile: ChannelProfile,
    allocator: std.mem.Allocator,
    /// A registration task moved a stream here after it consumed the first
    /// application frame header. The next accept takes it without blocking.
    ready: ?*RelayStream,
    /// Serializes listener state and the readiness wait. The registration task
    /// communicates only through its fixed job record plus the wake channel.
    wake: wake_channel.WakeChannel,
    /// Registration tasks perform TCP connect, HTTP upgrade, and parked
    /// WebSocket control handling. Close seals, cancels, and joins this owner.
    registrations: operation_owner.OperationOwner,
    registration: RegisterJob,
    registration_active: bool = false,
    /// The relay currently owns a live registration for this listener. This is
    /// deliberately not monotonic: after a replacement leg fails, advertising
    /// the old key would publish a locator that no relay can redeem.
    registration_ready: bool = false,
    /// Distinguishes a first registration failure from a replacement failure.
    /// Once a relay has accepted this key, later transient losses are retried.
    ever_registered: bool = false,
    /// A replacement is retried only at this deadline. The fixed, bounded delay
    /// avoids a reconnect storm while keeping the listener self-healing.
    registration_retry_at_ms: i64 = 0,
    operation_gate: std.Io.Mutex = .init,
    stopping: std.atomic.Value(bool) = .init(false),

    fn registerOne(box: *ListenerBox) netlayer.DialError!*RelayStream {
        const hex = box.public_key.toDesignator();
        return openLeg(box.io, box.allocator, box.register_url, register_query, hex[0..]);
    }

    fn startRegistration(box: *ListenerBox) error{ Closing, ConcurrencyUnavailable }!void {
        std.debug.assert(!box.registration_active);
        box.registration.reset();
        box.registration_ready = false;
        box.registration_retry_at_ms = 0;
        box.registration_active = true;
        box.registrations.start(RegisterJob.run, .{&box.registration}) catch |err| {
            box.registration_active = false;
            return err;
        };
    }

    fn scheduleRegistrationRetry(box: *ListenerBox) void {
        box.registration_ready = false;
        box.registration_retry_at_ms = clock.nowMs(box.io) + registration_retry_delay_ms;
        box.wake.nudge();
    }

    /// Publish a finished registration task into `ready`, or schedule a
    /// replacement after a leg that was already registered is lost. Called
    /// under `operation_gate`; the acquire pairs with the task's release store.
    fn collectRegistration(box: *ListenerBox) netlayer.AcceptError!void {
        if (!box.registration_active or !box.registration.done.load(.acquire)) return;
        box.registration_active = false;
        if (box.registration.err != null) {
            const had_registration = box.ever_registered or
                box.registration_ready or
                box.registration.registered.load(.acquire);
            if (!had_registration) return error.ConnectionLost;
            box.ever_registered = true;
            box.scheduleRegistrationRetry();
            return;
        }
        box.ready = box.registration.result orelse return error.ConnectionLost;
        box.registration.result = null;
        // The relay spent this registration when it paired the socket with a
        // dialer. It is acceptable now, but no longer a cold-dial route.
        box.registration_ready = false;
        box.ever_registered = true;
        box.registration_retry_at_ms = 0;
    }

    /// Fold the task's release-published state into the listener-owned state.
    /// This is shared by waits and designator queries so a completed failed
    /// replacement cannot remain advertised merely because nobody called a
    /// readiness method first.
    fn refreshRegistration(box: *ListenerBox) netlayer.AcceptError!void {
        try box.collectRegistration();
        if (box.registration_active and box.registration.registered.load(.acquire)) {
            box.registration_ready = true;
            box.ever_registered = true;
        }
    }
};

const RegisterJob = struct {
    box: *ListenerBox,
    result: ?*RelayStream = null,
    err: ?netlayer.DialError = null,
    /// The WebSocket registration upgrade completed. The task continues to
    /// own the parked socket until dialer data arrives.
    registered: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),

    fn reset(job: *RegisterJob) void {
        job.result = null;
        job.err = null;
        job.registered.store(false, .monotonic);
        job.done.store(false, .monotonic);
    }

    fn run(job: *RegisterJob) std.Io.Cancelable!void {
        const wake = job.box.wake;
        defer {
            job.done.store(true, .release);
            // The acquire-side collector may reset and resubmit `job` as soon
            // as `done` is visible. This worker must not touch the reusable
            // record after the release store; `wake` is the local copy captured
            // above, and nudging it afterward prevents a lost completion wake.
            wake.nudge();
        }
        const rs = job.box.registerOne() catch |err| {
            job.err = err;
            return;
        };
        job.registered.store(true, .release);
        wake.nudge();
        const has_data = rs.nextDataFrame() catch {
            rs.destroy();
            job.err = error.ConnectionLost;
            return;
        };
        if (!has_data) {
            rs.destroy();
            job.err = error.ConnectionLost;
            return;
        }
        job.result = rs;
    }
};

const keyed_listener_vtable: NetLayerListener.VTable = listenerVtable(.keyed);
const noise_listener_vtable: NetLayerListener.VTable = listenerVtable(.noise);

fn listenerVtable(comptime profile: ChannelProfile) NetLayerListener.VTable {
    return .{
        .transport_name = profile.transportName(),
        .designator_scheme = profile.known().metadata().designator_scheme,
        .sealed_channel = profile.known().metadata().sealed_channel,
        .accept = listenerAccept,
        .waitAcceptable = listenerWaitAcceptable,
        .waitReady = listenerWaitReady,
        .localLocator = listenerLocalLocator,
        .canonicalizeLocator = listenerCanonicalizeLocator,
        .close = listenerClose,
    };
}

fn listenerAccept(ctx: *anyopaque, peer: *engine.Peer, bufs: Buffers) netlayer.AcceptError!Connection {
    var raw = try (RawListener{ .box = @ptrCast(@alignCast(ctx)) }).accept(peer.allocator);
    errdefer raw.close();
    return try raw.stream.intoConnection(peer, bufs);
}

fn listenerWaitAcceptable(ctx: *anyopaque, timeout_ms: i32) netlayer.AcceptError!bool {
    return listenerWait(ctx, timeout_ms, .acceptable);
}

fn listenerWaitReady(ctx: *anyopaque, timeout_ms: i32) netlayer.AcceptError!bool {
    return listenerWait(ctx, timeout_ms, .registered);
}

const ListenerWaitTarget = enum { registered, acceptable };

/// The one deadline/poll loop for the listener's two distinct readiness
/// questions. Registration means the locator is publishable; acceptable means
/// a dialer has delivered application bytes and `accept` will not park. The
/// background task owns connect, upgrade, and control-frame I/O; this function
/// owns only the wake descriptor, so zero and finite timeouts are hard bounds.
fn listenerWait(ctx: *anyopaque, timeout_ms: i32, target: ListenerWaitTarget) netlayer.AcceptError!bool {
    const box: *ListenerBox = @ptrCast(@alignCast(ctx));
    box.operation_gate.lockUncancelable(box.io);
    defer box.operation_gate.unlock(box.io);
    return listenerWaitLocked(box, timeout_ms, target);
}

fn listenerWaitLocked(
    box: *ListenerBox,
    timeout_ms: i32,
    target: ListenerWaitTarget,
) netlayer.AcceptError!bool {
    const started_at = if (timeout_ms > 0) clock.nowMs(box.io) else 0;
    while (true) {
        if (box.stopping.load(.acquire)) return error.ConnectionLost;

        // Collect before observing readiness. A completed failed job may have
        // set its registered flag earlier; that flag is not current readiness.
        try box.refreshRegistration();

        if (target == .acceptable and box.ready != null) return true;

        if (target == .registered and box.registration_ready) return true;

        // A dialer spent the registration that produced this acceptable leg.
        // `ready` is the listener's sole handoff slot, and only `accept` may
        // consume it and start the replacement. Starting one here would both
        // advertise a route too early and let its result overwrite the live
        // socket waiting in that slot.
        if (target == .registered and box.ready != null) return false;

        if (!box.registration_active and timeout_ms != 0) {
            const now = clock.nowMs(box.io);
            if (box.registration_retry_at_ms == 0 or now >= box.registration_retry_at_ms) {
                box.startRegistration() catch |err| switch (err) {
                    error.Closing => return error.ConnectionLost,
                    error.ConcurrencyUnavailable => {
                        if (!box.ever_registered) return error.ConnectionLost;
                        box.scheduleRegistrationRetry();
                    },
                };
                continue;
            }
        }

        if (timeout_ms == 0) return false;

        const remaining: i32 = if (timeout_ms <= 0)
            listener_poll_slice_ms
        else blk: {
            const elapsed = clock.nowMs(box.io) - started_at;
            if (elapsed >= timeout_ms) return false;
            break :blk @intCast(@as(i64, timeout_ms) - elapsed);
        };
        const poll_timeout: i32 = if (box.registration_retry_at_ms > 0) blk: {
            const retry_remaining = box.registration_retry_at_ms - clock.nowMs(box.io);
            if (retry_remaining <= 0) continue;
            break :blk @min(remaining, @as(i32, @intCast(@min(
                retry_remaining,
                @as(i64, listener_poll_slice_ms),
            ))));
        } else @min(remaining, listener_poll_slice_ms);

        std.Io.checkCancel(box.io) catch return error.ConnectionLost;
        var fds = [_]std.posix.pollfd{.{
            .fd = box.wake.read,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        if ((poll.wait(&fds, poll_timeout) catch return error.ConnectionLost) == 0 and
            timeout_ms > 0 and clock.nowMs(box.io) - started_at >= timeout_ms)
            return false;
        box.wake.drain();
    }
}

const ParkVerdict = enum { idle, data_pending, closed };

/// Advance the parked stream past the control frames the buffer completely
/// holds — answering pings — without ever issuing a blocking read. A partial
/// header (or a control frame whose payload has not fully arrived) stays
/// buffered as `idle`; the socket poll fires again when the rest lands. A data
/// frame header hands its payload count to the connection-facing reader.
fn probeParked(rs: *RelayStream) FrameError!ParkVerdict {
    if (rs.read_closed) return .closed;
    if (rs.remaining > 0) return .data_pending;
    const r = &rs.reader.interface;
    while (true) {
        const buffered = r.buffered();
        const parsed = (try parseHeaderBytes(buffered)) orelse return .idle;
        switch (parsed.frame.opcode) {
            .close, .ping, .pong => if (buffered.len < parsed.header_len + protocol.controlPayloadLen(parsed.frame))
                return .idle,
            .binary, .continuation => {},
            else => unreachable, // parseHeaderBytes refused it
        }
        // Header and any control payload are proven buffered above. Toss the
        // already-parsed header rather than interpreting the wire a second time.
        r.toss(parsed.header_len);
        const body_len = protocol.controlPayloadLen(parsed.frame);
        const body = r.buffered()[0..body_len];
        const step = try rs.applyFrame(parsed.frame, body, .blocking);
        r.toss(body_len);
        switch (step) {
            .data => return .data_pending,
            .closed => return .closed,
            .handled => {},
        }
    }
}

/// The dialable designator is the registered identity key's canonical hex.
/// Publish the provider's relay endpoint as routing advice so a recipient can
/// cold-dial this listener even when its deployment default is another relay.
fn listenerLocalLocator(ctx: *anyopaque, allocator: std.mem.Allocator) netlayer.ListenError!model.PeerLocator {
    const box: *ListenerBox = @ptrCast(@alignCast(ctx));
    box.operation_gate.lockUncancelable(box.io);
    defer box.operation_gate.unlock(box.io);
    box.refreshRegistration() catch return error.BindFailed;
    if (box.stopping.load(.acquire) or !box.registration_ready) return error.BindFailed;
    const hex = box.public_key.toDesignator();
    const hints = [_]model.HintEntry{.{
        .name = rendezvous_relay_hint,
        .value = .{ .string = box.relay_url_storage },
    }};
    return model.clonePeerLocator(allocator, .{
        .transport = box.profile.transportName(),
        .designator = &hex,
        .hints = .{ .entries = &hints },
    });
}

fn listenerCanonicalizeLocator(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    locator: model.PeerLocator,
) netlayer.ListenError!model.PeerLocator {
    const box: *ListenerBox = @ptrCast(@alignCast(ctx));
    const designator = box.public_key.toDesignator();
    return netlayer.canonicalizeFixedLocator(
        allocator,
        locator,
        box.profile.transportName(),
        &designator,
    );
}

fn listenerClose(ctx: *anyopaque) void {
    const box: *ListenerBox = @ptrCast(@alignCast(ctx));
    box.stopping.store(true, .release);
    box.wake.nudge();
    box.registrations.shutdown();
    box.operation_gate.lockUncancelable(box.io);
    box.operation_gate.unlock(box.io);
    box.registrations.join();
    if (box.ready) |rs| rs.destroy();
    if (box.registration.result) |rs| rs.destroy();
    box.wake.deinit();
    box.allocator.free(box.register_url_storage);
    box.allocator.free(box.relay_url_storage);
    box.allocator.destroy(box);
}
