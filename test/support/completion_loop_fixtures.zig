//! Shared fixtures the completion-loop suites drive: the negotiated server
//! peer and hello every scenario opens with, the outbound-byte drains that
//! walk a peer's queue into a flat buffer, and the journaling `FakeBackend`
//! whose held sends and synchronous recv chunks make park/resume order a
//! deterministic assertion instead of a timing race (ADR-0042).

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const tcp = glowcap.net.tcp;
const completion = glowcap.net.completion;
const handshake = @import("handshake.zig");

pub const frame_cap = 4096;

pub fn startSession(designator: []const u8) model.Message {
    return handshake.startSession(tcp.transport_name, designator);
}

/// Build the server-side peer for one accepted connection: handshake verification
/// off (the loopback stub uses zero signatures), publish the shared `thermostat`
/// bootstrap cap, and queue the opening `op:start-session`.
pub fn makeServerPeer(ctx: ?*anyopaque, allocator: std.mem.Allocator) anyerror!engine.Peer {
    _ = ctx;
    var peer = engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = false });
    errdefer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;
    _ = try peer.registerBootstrapCap("thermostat");
    try peer.sendCopying(startSession("server"));
    return peer;
}

/// One blocking client: connect, handshake to open, fetch `thermostat`, assert it
/// settles fulfilled, then close (the `defer`) so the server observes EOF.
pub fn drainOutboundBytes(peer: *engine.Peer, allocator: std.mem.Allocator, sink: *std.ArrayList(u8)) !void {
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_value| {
        var frame = frame_value;
        defer frame.deinit();
        try sink.appendSlice(allocator, frame.bytes());
    }
}

/// Encode `peer`'s queued sends at the byte-stream boundary, where every bare
/// codec frame is carried inside one outer Syrup byte string.
pub fn drainOutboundStreamBytes(peer: *engine.Peer, allocator: std.mem.Allocator, sink: *std.ArrayList(u8)) !void {
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_value| {
        var frame = frame_value;
        defer frame.deinit();
        _ = try glowcap.net.appendFrameBytes(sink, allocator, frame.bytes());
    }
}

/// A scripted backend hosting two connections where the first is a bad
/// partner: every send submission on its fd fails. The second connection's
/// inbound script (`chunks`) is a full bootstrap-fetch conversation. The loop
/// must close the failing connection and keep serving the healthy one.
/// The backend-visible actions the fake journals. Their order *is* the
/// backpressure contract: a `recv_armed` may not appear while pending outbound
/// sits past the high-water mark.
pub const FakeEvent = enum { send_submitted, send_released, recv_armed };

/// A scripted completion backend: each armed recv synchronously delivers the
/// next chunk of `chunks` as a borrowed completion view (a clean EOF past the
/// end), and every submitted send is *held* — the partner is a slow reader —
/// completing only when the loop has nothing else to do (`poll` with an empty
/// ready queue). If the loop parks its read behind a held write, the journal
/// shows the send release strictly before the next `recv_armed`; if parking
/// were broken, the read would arm first and the journal order would flip.
/// The backend also counts pool traffic (`handed` / `recycles`) so tests can
/// assert every successful recv's buffer is recycled exactly once.
pub const FakeBackend = struct {
    pub const Fd = i32;

    pub fn applyKeepalive(_: *FakeBackend, _: Fd, _: completion.Keepalive) !void {
        return error.OperationUnsupported;
    }

    pub fn wireFraming(_: *FakeBackend, _: Fd) model.transport.WireFraming {
        return .byte_stream;
    }

    /// The inbound wire script, set by the test before `Loop.init`.
    pub var chunks: []const []const u8 = &.{};
    /// Test-only pressure injection for listener cancellation. Connection
    /// closes remain unaffected.
    pub var refuse_listener_close_once: bool = false;
    /// Report the canceled accept on the poll after the listener close. This
    /// pins that the Loop drains both operations independent of CQE ordering.
    pub var defer_listener_accept_cancel: bool = false;
    /// Inject one typed listener failure before the ordinary scripted accept.
    pub var first_accept_failure: ?anyerror = null;
    /// Inject one typed send-submission refusal before the slow-reader script.
    pub var first_send_submission_failure: ?anyerror = null;

    chunk_idx: usize = 0,
    pool_free: usize = 0,
    read_buffer_bytes: u32 = 0,
    handed: usize = 0,
    recycles: usize = 0,
    ready: [8]completion.Completion = undefined,
    ready_len: usize = 0,
    held_send: ?struct { user_data: u64, len: usize } = null,
    accepted: bool = false,
    journal: [16]FakeEvent = undefined,
    journal_len: usize = 0,
    listener_close_attempts: usize = 0,
    listener_close_fallbacks: usize = 0,
    pending_accept_ud: ?u64 = null,
    deferred_accept_cancel_ud: ?u64 = null,
    shutdown_fd: ?Fd = null,

    pub fn init(allocator: std.mem.Allocator, queue_entries: u16, read_buffers: u16, read_buffer_bytes: u32) !FakeBackend {
        _ = allocator;
        _ = queue_entries;
        return .{ .pool_free = read_buffers, .read_buffer_bytes = read_buffer_bytes };
    }

    pub fn deinit(self: *FakeBackend) void {
        self.* = .{ .pool_free = 0 };
    }

    pub const ListenTarget = u16;

    pub fn loopListenTarget(port: u16) ListenTarget {
        return port;
    }

    pub fn openListener(self: *@This(), port: u16) !Fd {
        _ = self;
        _ = port;
        return 1;
    }

    pub const ListenerAddress = u16;
    pub fn listenerAddress(_: *@This(), _: Fd) !ListenerAddress {
        return 1;
    }
    pub fn listenerPort(address: ListenerAddress) ?u16 {
        return address;
    }

    pub fn closeFd(self: *@This(), fd: Fd) void {
        if (fd == 1) self.listener_close_fallbacks += 1;
    }

    pub const ConnectTarget = void;

    pub fn startDial(self: *@This(), user_data: u64, target: ConnectTarget) !Fd {
        _ = self;
        _ = user_data;
        _ = target;
        return error.UnsupportedTransport;
    }

    pub fn shutdownFd(self: *@This(), fd: Fd) void {
        self.shutdown_fd = fd;
    }

    fn push(self: *FakeBackend, c: completion.Completion) void {
        self.ready[self.ready_len] = c;
        self.ready_len += 1;
    }

    fn record(self: *FakeBackend, e: FakeEvent) void {
        self.journal[self.journal_len] = e;
        self.journal_len += 1;
    }

    pub fn submitAccept(self: *FakeBackend, user_data: u64, listen_fd: Fd) !void {
        _ = listen_fd;
        if (first_accept_failure) |err| {
            first_accept_failure = null;
            self.push(.{ .user_data = user_data, .result = -1, .failure = err });
            return;
        }
        // One scripted connection; the loop's re-armed accept pends forever.
        if (self.accepted) {
            std.debug.assert(self.pending_accept_ud == null);
            self.pending_accept_ud = user_data;
            return;
        }
        self.accepted = true;
        self.push(.{ .user_data = user_data, .result = 7 });
    }

    pub fn submitRecv(self: *FakeBackend, user_data: u64, fd: Fd) !void {
        _ = fd;
        self.record(.recv_armed);
        if (self.chunk_idx < chunks.len) {
            if (self.pool_free == 0) {
                self.push(.{ .user_data = user_data, .result = -1, .recv_no_buffer = true });
                return;
            }
            self.pool_free -= 1;
            self.handed += 1;
            const chunk = chunks[self.chunk_idx];
            self.chunk_idx += 1;
            self.push(.{ .user_data = user_data, .result = @intCast(chunk.len), .borrowed = .recv(chunk, 0) });
        } else {
            self.push(.{ .user_data = user_data, .result = 0 }); // clean EOF
        }
    }

    pub fn verifiedChannelKey(self: *FakeBackend, fd: Fd) ?[32]u8 {
        _ = self;
        _ = fd;
        return null;
    }

    pub fn recycleBorrowed(self: *FakeBackend, comp: completion.Completion) void {
        _ = comp;
        self.recycles += 1;
        self.pool_free += 1;
    }

    pub fn submitSend(self: *FakeBackend, user_data: u64, fd: Fd, bytes: []const u8) !void {
        _ = fd;
        if (first_send_submission_failure) |err| {
            first_send_submission_failure = null;
            return err;
        }
        self.record(.send_submitted);
        self.held_send = .{ .user_data = user_data, .len = bytes.len };
    }

    pub fn submitCancel(self: *FakeBackend, cancel_user_data: u64, target_user_data: u64, fd: Fd) !void {
        _ = .{ target_user_data, fd };
        // submitRecv completes synchronously into `ready`; only the distinct
        // cancellation operation still needs publication.
        self.push(.{ .user_data = cancel_user_data, .result = 0 });
    }

    pub fn submitClose(self: *FakeBackend, user_data: u64, fd: Fd) !void {
        // The Loop owns the ordering guarantee: shutdown must precede every
        // accepted close submission, including listener cancellation.
        std.debug.assert(self.shutdown_fd != null and self.shutdown_fd.? == fd);
        if (fd == 1) {
            self.listener_close_attempts += 1;
            if (refuse_listener_close_once and self.listener_close_attempts == 1)
                return error.OutOfMemory;
            if (self.pending_accept_ud) |accept_ud| {
                self.pending_accept_ud = null;
                if (defer_listener_accept_cancel) {
                    self.deferred_accept_cancel_ud = accept_ud;
                } else {
                    self.push(.{ .user_data = accept_ud, .result = -1 });
                }
            }
        }
        self.shutdown_fd = null;
        self.push(.{ .user_data = user_data, .result = 0 });
    }

    pub fn poll(self: *FakeBackend, out: []completion.Completion, timeout_ms: i32) !usize {
        _ = timeout_ms;
        if (self.ready_len == 0) {
            if (self.deferred_accept_cancel_ud) |accept_ud| {
                self.deferred_accept_cancel_ud = null;
                self.push(.{ .user_data = accept_ud, .result = -1 });
            }
        }
        if (self.ready_len == 0) {
            // The loop is out of work: the slow reader finally drains the
            // held write. A stall with no held write would be a loop bug.
            const held = self.held_send orelse return error.FakeBackendStalled;
            self.held_send = null;
            self.record(.send_released);
            self.push(.{ .user_data = held.user_data, .result = @intCast(held.len) });
        }
        const n = @min(out.len, self.ready_len);
        @memcpy(out[0..n], self.ready[0..n]);
        std.mem.copyForwards(completion.Completion, self.ready[0 .. self.ready_len - n], self.ready[n..self.ready_len]);
        self.ready_len -= n;
        return n;
    }
};
