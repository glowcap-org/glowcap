//! Shared fixtures the completion-loop suites drive: the negotiated server
//! peer and hello every scenario opens with, the outbound-byte drains that
//! walk a peer's queue into a flat buffer, and the journaling `FakeBackend`
//! whose held sends and synchronous recv chunks make park/resume order a
//! deterministic assertion instead of a timing race (ADR-0017).

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const tcp = glowcap.net.tcp;
const completion = glowcap.net.completion;
const handshake = @import("handshake.zig");

pub const frame_cap = 4096;

/// The completion a fake backend's scripted recv pushes: the next of `chunks`
/// as a borrowed buffer, `recv_no_buffer` while the pool is dry, and a clean
/// EOF once the script ends. `self` carries the script's `chunk_idx` and the
/// pool's `pool_free` and `handed`.
pub fn scriptedRecv(self: anytype, user_data: u64, chunks: []const []const u8) completion.Completion {
    if (self.chunk_idx >= chunks.len) return .{ .user_data = user_data, .result = 0 }; // clean EOF
    if (self.pool_free == 0) return .{ .user_data = user_data, .result = -1, .recv_no_buffer = true };
    self.pool_free -= 1;
    self.handed += 1;
    const chunk = chunks[self.chunk_idx];
    self.chunk_idx += 1;
    return .{ .user_data = user_data, .result = @intCast(chunk.len), .borrowed = .recv(chunk, 0) };
}

pub fn startSession(designator: []const u8) model.Message {
    return handshake.startSession(tcp.transport_name, designator);
}

/// Build the server-side peer for one accepted connection: handshake verification
/// off (the loopback stub uses zero signatures), publish the shared `thermostat`
/// bootstrap cap, and queue the opening `op:start-session`.
pub fn makeServerPeer(ctx: ?*anyopaque, allocator: std.mem.Allocator) anyerror!engine.Peer {
    _ = ctx;
    var peer = handshake.stubPeer(allocator);
    errdefer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;
    _ = try peer.registerBootstrapCap("thermostat");
    try peer.sendBorrowed(startSession("server"));
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

/// Carry `from`'s queued sends to `to` the way a byte stream does: each
/// frame inside its envelope, applied through the loop's own stream door.
pub fn pumpStream(from: *engine.Peer, to: *engine.Peer, allocator: std.mem.Allocator) !usize {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    try drainOutboundStreamBytes(from, allocator, &bytes);
    var spill: glowcap.net.Spill = .{};
    defer spill.deinit(allocator);
    if (glowcap.net.drainWholeFrames(to, &spill, bytes.items, allocator) != .ok) return error.StreamRefused;
    if (spill.isActive()) return error.PartialFrameLeftInStream;
    return bytes.items.len;
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

/// The completion-backend surface every scripted backend repeats byte for byte:
/// an `i32` handle space, a listener that binds at `openListener` and pends
/// nothing, a dial that is unsupported, a null channel key, and no-op
/// shutdown and close. A backend forwards the declarations it keeps
/// (`pub const Fd = shared.Fd;`) and writes only its script. A Zig struct
/// cannot inherit declarations, so the forwarding line is the mixin.
///
/// The queue declarations expect the backend to hold `ready: [N]Completion`
/// and `ready_len: usize`. `recycleBorrowed` also expects `recycles` and
/// `pool_free` counters.
pub fn ScriptedContract(comptime Self: type) type {
    return struct {
        const Contract = @This();

        pub const Fd = i32;

        pub fn applyKeepalive(_: *Self, _: Fd, _: completion.Keepalive) !void {
            return error.OperationUnsupported;
        }

        pub fn wireFraming(_: *Self, _: Fd) model.transport.WireFraming {
            return .byte_stream;
        }

        pub const ListenTarget = u16;

        pub fn loopListenTarget(port: u16) ListenTarget {
            return port;
        }

        /// A scripted listener binds at `openListener`. Nothing pends here. A
        /// wrapped adapter's pending setup reports through the adapter itself.
        pub fn listenerPending(_: *Self, _: Fd) bool {
            return false;
        }

        pub fn openListener(self: *Self, port: u16) !Fd {
            _ = self;
            _ = port;
            return 1;
        }

        pub const ListenerAddress = u16;
        pub fn listenerAddress(_: *Self, _: Fd) !ListenerAddress {
            return 1;
        }
        pub fn listenerPort(address: ListenerAddress) ?u16 {
            return address;
        }

        pub fn closeFd(self: *Self, fd: Fd) void {
            _ = self;
            _ = fd;
        }

        pub const ConnectTarget = void;

        pub fn startDial(self: *Self, user_data: u64, target: ConnectTarget) !Fd {
            _ = self;
            _ = user_data;
            _ = target;
            return error.UnsupportedTransport;
        }

        pub fn shutdownFd(self: *Self, fd: Fd) void {
            _ = self;
            _ = fd;
        }

        pub fn verifiedChannelKey(self: *Self, fd: Fd) ?[32]u8 {
            _ = self;
            _ = fd;
            return null;
        }

        pub fn recycleBorrowed(self: *Self, comp: completion.Completion) void {
            _ = comp;
            self.recycles += 1;
            self.pool_free += 1;
        }

        pub fn push(self: *Self, c: completion.Completion) void {
            self.ready[self.ready_len] = c;
            self.ready_len += 1;
        }

        pub fn submitCancel(self: *Self, cancel_user_data: u64, target_user_data: u64, fd: Fd) !void {
            _ = .{ target_user_data, fd };
            Contract.push(self, .{ .user_data = cancel_user_data, .result = 0 });
        }

        pub fn submitClose(self: *Self, user_data: u64, fd: Fd) !void {
            _ = fd;
            Contract.push(self, .{ .user_data = user_data, .result = 0 });
        }

        /// No submission queue here, so a peek is a zero-timeout poll.
        pub fn peek(self: *Self, out: []completion.Completion) !usize {
            return self.poll(out, 0);
        }
    };
}

/// A scripted completion backend: each armed recv synchronously delivers the
/// next chunk of `chunks` as a borrowed completion view (a clean EOF past the
/// end), and every submitted send is *held*, the partner is a slow reader,
/// completing only when the loop has nothing else to do (`poll` with an empty
/// ready queue). If the loop parks its read behind a held write, the journal
/// shows the send release strictly before the next `recv_armed`. If parking
/// were broken, the read would arm first and the journal order would flip.
/// The backend also counts pool traffic (`handed` / `recycles`) so tests can
/// assert every successful recv's buffer is recycled exactly once.
pub const FakeBackend = struct {
    const shared = ScriptedContract(@This());
    pub const Fd = shared.Fd;
    pub const applyKeepalive = shared.applyKeepalive;
    pub const wireFraming = shared.wireFraming;
    pub const ListenTarget = shared.ListenTarget;
    pub const loopListenTarget = shared.loopListenTarget;
    pub const listenerPending = shared.listenerPending;
    pub const openListener = shared.openListener;
    pub const ListenerAddress = shared.ListenerAddress;
    pub const listenerAddress = shared.listenerAddress;
    pub const listenerPort = shared.listenerPort;
    pub const ConnectTarget = shared.ConnectTarget;
    pub const startDial = shared.startDial;
    pub const verifiedChannelKey = shared.verifiedChannelKey;
    pub const recycleBorrowed = shared.recycleBorrowed;
    const push = shared.push;
    pub const peek = shared.peek;

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

    pub fn closeFd(self: *@This(), fd: Fd) void {
        if (fd == 1) self.listener_close_fallbacks += 1;
    }

    pub fn shutdownFd(self: *@This(), fd: Fd) void {
        self.shutdown_fd = fd;
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
        self.push(scriptedRecv(self, user_data, chunks));
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
        @memmove(self.ready[0 .. self.ready_len - n], self.ready[n..self.ready_len]);
        self.ready_len -= n;
        return n;
    }
};

/// Run the loop on its own task until `until_closed` sessions closed, then
/// drain it there, keeping the first error for the test to read.
pub fn runLoopCapturing(loop: *glowcap.net.TcpLoop, until_closed: usize, out_err: *?anyerror) void {
    loop.run(.{ .after_closed = until_closed }) catch |err| {
        out_err.* = err;
    };
    // `run` returns on the close count alone and leaves any other slot's armed
    // recv in flight, which `deinit` refuses to free. Drain here, on the
    // loop-owner thread, exactly as `closeAndDrain` documents for an early
    // `run` return.
    loop.closeAndDrain() catch |err| {
        // The run's error is the cause; the drain's is usually its consequence.
        if (out_err.* == null) out_err.* = err;
    };
}
