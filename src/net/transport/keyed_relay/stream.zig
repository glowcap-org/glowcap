//! One clear-WebSocket relay leg: connection acquisition, upgrade,
//! framing, nonblocking I/O, and exact connection-local failure retention.

const std = @import("std");
const blocking_frame = @import("blocking_frame.zig");
const close_machine = @import("close.zig");
const protocol = @import("../../websocket.zig").client_protocol;
const byte_stream = @import("carrier/byte_stream.zig");
const carrier_runtime = @import("carrier/runtime.zig");
const ws_source = @import("ws_source.zig");

const foundation = @import("foundation");
const engine = @import("engine");
const connection = @import("../../connection.zig");
const multiplexed_resident = @import("../../multiplexed_resident.zig");
const netlayer = @import("../../netlayer.zig");
const stream_shim = @import("../../stream_shim.zig");

const Io = std.Io;
const Buffers = netlayer.Buffers;
const Connection = connection.Connection;
const FrameError = blocking_frame.FrameError;
const FrameHeader = protocol.FrameHeader;
const OutgoingOpcode = protocol.OutgoingOpcode;
const max_control_payload = protocol.max_control_payload;
const max_header_len = protocol.max_header_len;
const writeFrameHeader = protocol.writeFrameHeader;
const parseHeaderBytes = protocol.parseHeaderBytes;
const admitFrame = protocol.admitFrame;
const readHeaderBytes = blocking_frame.readHeaderBytes;

pub const readFrameHeader = blocking_frame.readFrameHeader;
pub const CloseProgress = connection.CloseProgress;

// --- The pinned connection stream ------------------------------------------

/// How many bytes the socket-facing reader and writer each buffer. Sized for
/// the upgrade response and frame headers with room for payload batching. The
/// CapTP-facing steady state is the caller's `Buffers`, not this.
const inner_buf_bytes = 2048;
const staged_control_bytes = max_header_len + max_control_payload;
const max_staged_application_bytes = inner_buf_bytes - max_header_len - staged_control_bytes;

comptime {
    std.debug.assert(max_staged_application_bytes > 0);
}

const WsSource = ws_source.Source(RelayStream);
const ShimT = stream_shim.Shim(WsSource);

/// One dialed or registered relay socket, pinned so the reader/writer
/// interfaces hold a stable address for the `Connection`'s life (ADR-0043).
/// Carries the WebSocket decode state across reads, including across the
/// parked-listener wait, whose control-frame handling consumes headers before
/// `accept` hands the stream over. Freed through the connection's transport
/// handle, or by the listener that still owns it.
pub const RelayStream = struct {
    source: byte_stream.Stream,
    ws_reader: ShimT.Reader,
    ws_writer: ShimT.Writer,
    carrier: carrier_runtime.Lease,
    allocator: std.mem.Allocator,
    /// Payload bytes remaining in the data frame being streamed.
    remaining: u64,
    /// Whether a non-final binary message is waiting for continuation frames.
    fragmented: bool,
    /// The receive half reached a close frame or a clean frame-boundary EOF.
    read_closed: bool,
    close_sent: bool,
    failure: ?foundation.FailureChain,
    /// Mask keys per outbound frame. Seeded once from the host entropy. RFC
    /// 6455 wants masks an intermediary cannot predict, not a secret.
    mask_rng: std.Random.DefaultCsprng,

    /// Pin a stream over a connected socket. The WebSocket upgrade has not run
    /// yet. `upgrade` drives it. On error the caller still owns the carrier
    /// lease and `stream`. On success this value adopts both.
    pub fn create(
        allocator: std.mem.Allocator,
        carrier: carrier_runtime.Lease,
        source: byte_stream.Stream,
        mask_seed: [std.Random.DefaultCsprng.secret_seed_length]u8,
    ) std.mem.Allocator.Error!*RelayStream {
        const rs = try allocator.create(RelayStream);
        rs.carrier = carrier;
        rs.allocator = allocator;
        rs.remaining = 0;
        rs.fragmented = false;
        rs.read_closed = false;
        rs.close_sent = false;
        rs.failure = null;
        rs.mask_rng = std.Random.DefaultCsprng.init(mask_seed);
        rs.source = source;
        return rs;
    }

    /// Re-pin a listener-owned registration stream under the accepted peer.
    /// The concrete std.Io interfaces contain pointers into their enclosing
    /// RelayStream, so allocator transfer is reconstruction, not a struct move.
    /// Upgrade and control writes are normally flushed before this boundary.
    /// Reconstruct both buffers anyway so correctness does not depend on that
    /// scheduling invariant.
    pub fn moveToAllocator(rs: *RelayStream, allocator: std.mem.Allocator) std.mem.Allocator.Error!*RelayStream {
        if (rs.allocator.ptr == allocator.ptr and rs.allocator.vtable == allocator.vtable) return rs;

        const moved = try allocator.create(RelayStream);
        moved.carrier = rs.carrier;
        moved.allocator = allocator;
        moved.remaining = rs.remaining;
        moved.fragmented = rs.fragmented;
        moved.read_closed = rs.read_closed;
        moved.close_sent = rs.close_sent;
        moved.failure = rs.failure;
        moved.mask_rng = rs.mask_rng;

        // The byte stream is independently pinned under the carrier runtime's
        // allocator. Only WebSocket ownership moves across this admission
        // boundary; lower transport and TLS retry borrows stay stable.
        moved.source = rs.source;

        rs.allocator.destroy(rs);
        return moved;
    }

    /// Wire the CapTP-facing reader/writer over the caller's buffers and weld
    /// to `peer`. Runs once, after the upgrade (and for a registered socket,
    /// after the parked wait).
    pub fn intoConnection(rs: *RelayStream, peer: *engine.Peer, bufs: Buffers) error{ConnectionLost}!Connection {
        rs.ws_reader = ShimT.Reader.init(.{ .rs = rs }, bufs.read);
        rs.ws_writer = ShimT.Writer.init(.{ .rs = rs }, bufs.write);
        // The peer may send its hello while this leg is still reading the HTTP
        // upgrade response. A socket fill can then leave the first WebSocket
        // frame in the inner reader, beyond the bytes readUpgradeResponse
        // consumed. Lend only those already-buffered payload bytes to the
        // Connection reader: HostRuntime can observe them before polling the
        // socket, and accept never enters a source read that could park. A
        // buffered ping is answered with one flushed pong, the one write this
        // probe makes.
        const buffered = probeParked(rs) catch |err| {
            rs.noteFailure(err);
            return error.ConnectionLost;
        };
        if (buffered == .closed) return error.ConnectionLost;
        if (buffered == .data_pending) rs.primeConnectionReader();
        return Connection.init(rs.carrier.io(), peer, &rs.ws_reader.interface, &rs.ws_writer.interface, .{
            .ctx = rs,
            .close_fn = close,
            .try_close_fn = tryCloseErased,
            .socket_handle_fn = socketHandle,
            .take_failure_fn = takeFailureErased,
        });
    }

    /// Copy only payload bytes the inner socket reader already owns. This is
    /// the readiness-to-accept handoff, so it bypasses the shim's
    /// generic fill operation: even a future change to `readSome` cannot turn
    /// an acceptable listener into a blocking accept.
    fn primeConnectionReader(rs: *RelayStream) void {
        const source = rs.source.reader.buffered();
        const n: usize = @intCast(@min(
            @as(u64, @min(source.len, rs.ws_reader.interface.buffer.len)),
            rs.remaining,
        ));
        if (n == 0) return;
        @memcpy(rs.ws_reader.interface.buffer[0..n], source[0..n]);
        rs.ws_reader.interface.end = n;
        rs.source.reader.toss(n);
        rs.remaining -= n;
    }

    fn close(ctx: *anyopaque) void {
        const rs: *RelayStream = @ptrCast(@alignCast(ctx));
        _ = rs.destroy();
    }

    fn tryCloseErased(ctx: *anyopaque) connection.CloseProgress {
        const rs: *RelayStream = @ptrCast(@alignCast(ctx));
        return rs.tryClose();
    }

    pub fn destroy(rs: *RelayStream) ?foundation.FailureChain {
        // Destruction is abortive by contract. A close frame is a graceful
        // protocol operation and belongs to an active, bounded I/O owner; a
        // destructor cannot perform network I/O without making every unwind
        // path capable of parking its caller.
        const allocator = rs.allocator;
        var carrier = rs.carrier;
        if (rs.source.deinitOutcome()) |failure| {
            if (rs.failure) |*primary| primary.noteChain(failure) else rs.failure = failure;
        }
        if (carrier.releaseOutcome()) |failure| {
            if (rs.failure) |*primary| primary.noteChain(failure) else rs.failure = failure;
        }
        const failure = rs.failure;
        allocator.destroy(rs);
        return failure;
    }

    fn socketHandle(ctx: *anyopaque) ?Io.net.Socket.Handle {
        const rs: *RelayStream = @ptrCast(@alignCast(ctx));
        return rs.source.socketHandle();
    }

    pub fn noteFailure(rs: *RelayStream, cause: anyerror) void {
        if (rs.failure) |*failure| failure.note(cause) else rs.failure = .init(cause);
    }

    pub fn noteSourceFailure(rs: *RelayStream, fallback: anyerror) void {
        if (rs.source.takeFailure()) |failure| {
            if (rs.failure) |*primary| primary.noteChain(failure) else rs.failure = failure;
        } else {
            rs.noteFailure(fallback);
        }
    }

    pub fn takeFailure(rs: *RelayStream) ?foundation.FailureChain {
        const failure = rs.failure;
        rs.failure = null;
        return failure;
    }

    fn takeFailureErased(ctx: *anyopaque) ?foundation.FailureChain {
        const rs: *RelayStream = @ptrCast(@alignCast(ctx));
        return rs.takeFailure();
    }

    fn readFailed(rs: *RelayStream, cause: anyerror) error{ReadFailed} {
        if (cause != error.ReadFailed or rs.failure == null) rs.noteFailure(cause);
        return error.ReadFailed;
    }

    /// The byte-source read: streams data-frame payload, answers pings, and
    /// surfaces a close frame or a frame-boundary EOF as a clean end. Mid-frame
    /// truncation and every protocol violation are `ReadFailed`, fail closed.
    pub fn readSome(rs: *RelayStream, dest: []u8) Io.Reader.Error!usize {
        var written: usize = 0;
        while (written < dest.len) {
            if (rs.read_closed) return if (written > 0) written else error.EndOfStream;
            if (rs.remaining > 0) {
                const r = rs.source.reader;
                if (r.bufferedLen() == 0) {
                    // A stream read may span several WebSocket data messages,
                    // but it must not block for the next message after already
                    // producing bytes. The caller will poll before asking
                    // again when no lower-buffered message is ready.
                    if (written > 0) return written;
                    r.fillMore() catch |err| switch (err) {
                        error.EndOfStream => return rs.readFailed(error.Truncated),
                        error.ReadFailed => {
                            rs.noteSourceFailure(err);
                            return error.ReadFailed;
                        },
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
                // cannot park on a read after making progress; a buffered ping
                // still answers with one flushed pong on this blocking API.
                switch (probeParked(rs) catch |err| return rs.readFailed(err)) {
                    .data_pending => continue,
                    .closed => return written,
                    .idle => return written,
                }
            }
            if (written > 0) {
                switch (probeParked(rs) catch |err| return rs.readFailed(err)) {
                    .data_pending => continue,
                    .closed => return written,
                    .idle => return written,
                }
            }
            const arrived = rs.nextDataFrame() catch |err| return rs.readFailed(err);
            if (!arrived) return if (written > 0) written else error.EndOfStream;
        }
        return written;
    }

    /// Read application bytes without parking the caller. Socket readiness is
    /// only a hint for WebSocket: it may announce a ping, a partial header, or
    /// EOF rather than application data. This loop consumes exactly the bytes
    /// currently available, stages one bounded control reply, and reports
    /// `WouldBlock` once another kernel edge is required.
    pub fn tryReadSome(rs: *RelayStream, dest: []u8) (Io.Reader.Error || error{WouldBlock})!usize {
        if (rs.source.hasPendingWrite()) return error.WouldBlock;
        var written: usize = 0;
        while (written < dest.len) {
            if (rs.read_closed) return if (written > 0) written else error.EndOfStream;
            if (rs.remaining > 0) {
                const r = rs.source.reader;
                if (r.bufferedLen() == 0) {
                    switch (rs.source.tryFill() catch {
                        rs.noteSourceFailure(error.ReadFailed);
                        return error.ReadFailed;
                    }) {
                        .progress => {},
                        .would_block => return if (written > 0) written else error.WouldBlock,
                        .closed => return rs.readFailed(error.Truncated),
                    }
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

            const r = rs.source.reader;
            const buffered = r.buffered();
            const parsed = (parseHeaderBytes(buffered) catch |err| return rs.readFailed(err)) orelse {
                if (written > 0) return written;
                switch (rs.source.tryFill() catch {
                    rs.noteSourceFailure(error.ReadFailed);
                    return error.ReadFailed;
                }) {
                    .closed => {
                        if (buffered.len != 0) return rs.readFailed(error.Truncated);
                        rs.read_closed = true;
                        return error.EndOfStream;
                    },
                    .would_block => return error.WouldBlock,
                    .progress => {},
                }
                continue;
            };
            const body_len = protocol.controlPayloadLen(parsed.frame);
            if (buffered.len < parsed.header_len + body_len) {
                if (written > 0) return written;
                switch (rs.source.tryFill() catch {
                    rs.noteSourceFailure(error.ReadFailed);
                    return error.ReadFailed;
                }) {
                    .closed => return rs.readFailed(error.Truncated),
                    .would_block => return error.WouldBlock,
                    .progress => {},
                }
                continue;
            }
            r.toss(parsed.header_len);
            const body = r.buffered()[0..body_len];
            const step = rs.applyFrame(parsed.frame, body, .staged) catch |err| return rs.readFailed(err);
            r.toss(body_len);
            switch (step) {
                .data => {},
                .closed => return if (written > 0) written else error.EndOfStream,
                .handled => if (rs.source.writer.end != 0)
                    return if (written > 0) written else error.WouldBlock,
            }
        }
        return written;
    }

    /// Advance the frame state machine to the next data frame, blocking:
    /// handle control frames in place, set `remaining` on a data header, and
    /// report whether one arrived (`false` is a clean end: a close frame, or
    /// EOF on a frame boundary). The parked listener never calls this, its
    /// non-blocking sibling is `probeParked`.
    pub fn nextDataFrame(rs: *RelayStream) FrameError!bool {
        const r = rs.source.reader;
        while (true) {
            if (r.bufferedLen() == 0) {
                // A clean EOF between frames is a graceful close (a relay that
                // drops the socket without a close frame).
                r.fillMore() catch |err| switch (err) {
                    error.EndOfStream => {
                        rs.read_closed = true;
                        return false;
                    },
                    error.ReadFailed => {
                        rs.noteSourceFailure(error.ReadFailed);
                        return FrameError.ReadFailed;
                    },
                };
            }
            const header = readFrameHeader(r) catch |err| {
                rs.noteFrameFailure(err);
                return err;
            };
            var payload: [max_control_payload]u8 = undefined;
            const body = readControlPayload(r, header, &payload) catch |err| {
                rs.noteFrameFailure(err);
                return err;
            };
            const step = rs.applyFrame(header, body, .blocking) catch |err| {
                rs.noteFrameFailure(err);
                return err;
            };
            switch (step) {
                .data => return true,
                .closed => return false,
                .handled => {},
            }
        }
    }

    pub fn noteFrameFailure(rs: *RelayStream, cause: FrameError) void {
        if (cause == error.ReadFailed and rs.failure == null)
            rs.noteSourceFailure(cause);
    }

    /// What one consumed frame means to the caller's loop.
    pub const FrameStep = enum { data, handled, closed };

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
    /// drained, a close marks the stream. Both frame loops, the blocking
    /// `nextDataFrame` and the parked `probeParked`, dispatch through this
    /// one arm set, so an opcode fix cannot land in one loop and miss the
    /// other. The reads block only when the caller allows it: the parked
    /// path passes a borrow from bytes it already proved buffered.
    pub const ControlWrite = enum { blocking, staged };

    pub fn applyFrame(
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
                if (control_write == .blocking) rs.source.writer.flush() catch |err| {
                    rs.noteSourceFailure(err);
                    return FrameError.ReadFailed;
                };
                return .handled;
            },
            .pong => return .handled,
            .close => {
                if (!rs.close_sent) {
                    rs.writeFrame(.close, body) catch return FrameError.ReadFailed;
                    if (control_write == .blocking) rs.source.writer.flush() catch |err| {
                        rs.noteSourceFailure(err);
                        return FrameError.ReadFailed;
                    };
                }
                rs.read_closed = true;
                return .closed;
            },
        }
    }

    /// One masked client frame: header, then the payload XOR-copied into the
    /// socket writer's buffer, the single copy masking requires.
    pub fn writeFrame(rs: *RelayStream, opcode: OutgoingOpcode, bytes: []const u8) Io.Writer.Error!void {
        const w = rs.source.writer;
        var mask: [4]u8 = undefined;
        rs.mask_rng.random().bytes(&mask);
        var header: [max_header_len]u8 = undefined;
        const encoded = writeFrameHeader(&header, opcode, bytes.len, mask) catch |err| {
            rs.noteFailure(err);
            return error.WriteFailed;
        };
        w.writeAll(encoded) catch |err| {
            rs.noteSourceFailure(err);
            return error.WriteFailed;
        };
        var i: usize = 0;
        while (i < bytes.len) {
            const chunk = w.writableSliceGreedy(1) catch |err| {
                rs.noteSourceFailure(err);
                return error.WriteFailed;
            };
            const n = @min(chunk.len, bytes.len - i);
            for (chunk[0..n], bytes[i..][0..n]) |*out, in| {
                out.* = in ^ mask[i % 4];
                i += 1;
            }
            w.advance(n);
        }
        if (opcode == .close) rs.close_sent = true;
    }

    pub fn tryWriteSome(rs: *RelayStream, bytes: []const u8) isize {
        if (bytes.len == 0) return 0;
        const flushed = rs.tryFlushPending();
        if (flushed < 0) return flushed;
        if (rs.source.writer.end != 0) return multiplexed_resident.would_block;
        const consumed = @min(bytes.len, max_staged_application_bytes);
        rs.writeFrame(.binary, bytes[0..consumed]) catch return -1;
        const flushed_after_write = rs.tryFlushPending();
        if (flushed_after_write < 0) return flushed_after_write;
        return @intCast(consumed);
    }

    pub fn tryFlushPending(rs: *RelayStream) isize {
        const result = rs.source.tryFlush();
        if (result < 0 and result != multiplexed_resident.would_block)
            rs.noteSourceFailure(error.WriteFailed);
        return result;
    }

    pub fn flush(rs: *RelayStream) Io.Writer.Error!void {
        rs.source.writer.flush() catch |err| {
            rs.noteSourceFailure(err);
            return error.WriteFailed;
        };
    }

    pub fn hasPendingWrite(rs: *const RelayStream) bool {
        return rs.source.hasPendingWrite();
    }

    /// Whether a nonblocking read can advance without another socket edge.
    pub fn hasBufferedReadWork(rs: *const RelayStream) bool {
        return rs.read_closed or rs.source.reader.bufferedLen() != 0;
    }

    /// Advance the explicit close transaction without parking the provider
    /// reactor. Application writes reserve enough buffer for this one control
    /// frame, so staging the close cannot flush or allocate.
    pub fn tryClose(rs: *RelayStream) CloseProgress {
        if (!rs.close_sent) rs.writeFrame(.close, &.{}) catch return .failed;
        const flushed = rs.tryFlushPending();
        if (flushed == multiplexed_resident.would_block) return .wait_write;
        if (flushed < 0) return .failed;
        if (rs.hasPendingWrite()) return .wait_write;

        if (!rs.read_closed) switch (close_machine.drainAfterLocalClose(rs)) {
            .closed => {},
            .wait_read => return .wait_read,
            .wait_write => return .wait_write,
            .failed => return .failed,
        };
        return switch (rs.source.tryShutdown() catch |err| {
            rs.noteSourceFailure(err);
            return .failed;
        }) {
            .complete => .complete,
            .wait_read => .wait_read,
            .wait_write => .wait_write,
        };
    }

    pub fn readinessFd(rs: *const RelayStream) Io.net.Socket.Handle {
        return rs.source.socketHandle();
    }
};

const ParkVerdict = enum { idle, data_pending, closed };

/// Advance the parked stream past the control frames the buffer completely
/// holds, answering pings, without ever issuing a blocking read. A partial
/// header (or a control frame whose payload has not fully arrived) stays
/// buffered as `idle`. The socket poll fires again when the rest lands. A data
/// frame header hands its payload count to the connection-facing reader.
fn probeParked(rs: *RelayStream) FrameError!ParkVerdict {
    if (rs.read_closed) return .closed;
    if (rs.remaining > 0) return .data_pending;
    const r = rs.source.reader;
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
        const step = rs.applyFrame(parsed.frame, body, .blocking) catch |err| {
            rs.noteFrameFailure(err);
            return err;
        };
        r.toss(body_len);
        switch (step) {
            .data => return .data_pending,
            .closed => return .closed,
            .handled => {},
        }
    }
}
