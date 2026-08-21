//! The scripted backend the cross-arm, wake, and close-slot proofs drive:
//! every completion is the script's choice, and the queue accounting it
//! exposes is what pins ADR-0042's outbound arithmetic without a socket.
//! The completion loop's cross-connection outbound arm (`Loop.armOutbound`):
//! a hook serving connection A that enqueued sends on connection B's peer
//! arms B's write without waiting for B's own traffic. Proven twice: end to
//! end on the platform backend (a quiet partner receives a frame only
//! cross-arming could have put on its wire), and on a scripted backend that
//! pins the queue accounting. Cross-armed bytes count into the connection's
//! pending outbound, so ADR-0042 parks that connection's next read at the
//! high-water mark exactly as it parks reply traffic.

const std = @import("std");
const builtin = @import("builtin");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const tcp = pancake.net.tcp;
const Loop = pancake.net.TcpLoop;
const completion = pancake.net.completion;
const fetch_pump = @import("../../support/fetch_pump.zig");
const handshake = @import("../../support/handshake.zig");
const no_dial = @import("../../support/no_dial_locator.zig");

const frame_cap = 4096;

pub fn startSession(designator: []const u8) model.Message {
    return handshake.startSession(tcp.transport_name, designator);
}

pub fn makeServerPeer(ctx: ?*anyopaque, allocator: std.mem.Allocator) anyerror!engine.Peer {
    _ = ctx;
    var peer = engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = false });
    errdefer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;
    _ = try peer.registerBootstrapCap("thermostat");
    try peer.sendCopying(startSession("server"));
    return peer;
}

// ── End to end: a quiet partner hears a cross-armed frame ────────────────────

/// A scripted backend with test-controlled phases. Sends are held at submit
/// (the kernel-borrow shape); an idle `poll` releases the oldest held send
/// only while `hold_sends` is false. A recv finds its chunk immediately when
/// one is scripted; with the script exhausted it stays pending (delivered by
/// a later idle poll once the test appends a chunk) or completes as a clean
/// EOF once `eof_when_exhausted` is set. An idle poll with nothing to do
/// returns `error.ScriptParked` — each test phase ends there deliberately.
pub const CrossArmBackend = struct {
    pub const Fd = i32;

    pub fn applyKeepalive(_: *CrossArmBackend, _: Fd, _: completion.Keepalive) !void {
        return error.OperationUnsupported;
    }

    pub fn wireFraming(_: *CrossArmBackend, _: Fd) model.transport.WireFraming {
        return .byte_stream;
    }

    pub var chunks: []const []const u8 = &.{};
    pub var hold_sends: bool = false;
    pub var refuse_cancel: bool = false;
    pub var eof_when_exhausted: bool = false;
    /// Refuse this numbered submission on the caller-owned wake descriptor.
    /// Connection receives use other descriptors and remain unaffected.
    pub var fail_wake_submit_at: ?usize = null;
    /// Set once the loop asks `poll` to wait a bounded time rather than block.
    /// A deadline the loop enforces only after the poll cannot fire on a quiet
    /// connection, because that connection is the one producing no
    /// completions, so the wait itself has to carry it.
    pub var saw_bounded_poll: bool = false;
    /// When set, the next released send reports this many bytes instead of the
    /// whole buffer, so a test can drive `onSend`'s partial-write branch.
    pub var partial_send_bytes: usize = 0;

    const Held = struct { user_data: u64, len: usize };

    chunk_idx: usize = 0,
    accepted: bool = false,
    pending_recv: ?u64 = null,
    submitted_bytes: usize = 0,
    held: [4]Held = undefined,
    held_len: usize = 0,
    ready: [16]completion.Completion = undefined,
    ready_len: usize = 0,
    wake_submit_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, queue_entries: u16, read_buffers: u16, read_buffer_bytes: u32) !CrossArmBackend {
        _ = allocator;
        _ = queue_entries;
        _ = read_buffers;
        _ = read_buffer_bytes;
        return .{};
    }

    pub fn deinit(self: *CrossArmBackend) void {
        self.* = .{};
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
        _ = self;
        _ = fd;
    }

    pub const ConnectTarget = void;

    pub fn startDial(self: *@This(), user_data: u64, target: ConnectTarget) !Fd {
        _ = self;
        _ = user_data;
        _ = target;
        return error.UnsupportedTransport;
    }

    pub fn shutdownFd(self: *@This(), fd: Fd) void {
        _ = self;
        _ = fd;
    }

    fn push(self: *CrossArmBackend, c: completion.Completion) void {
        self.ready[self.ready_len] = c;
        self.ready_len += 1;
    }

    pub fn submitAccept(self: *CrossArmBackend, user_data: u64, listen_fd: Fd) !void {
        _ = listen_fd;
        if (self.accepted) return;
        self.accepted = true;
        self.push(.{ .user_data = user_data, .result = 7 });
    }

    pub fn submitRecv(self: *CrossArmBackend, user_data: u64, fd: Fd) !void {
        if (fd == 99) {
            self.wake_submit_count += 1;
            if (fail_wake_submit_at == self.wake_submit_count) return error.WakeSubmitRefused;
        }
        if (self.chunk_idx < chunks.len) {
            const chunk = chunks[self.chunk_idx];
            self.chunk_idx += 1;
            self.push(.{ .user_data = user_data, .result = @intCast(chunk.len), .borrowed = .recv(chunk, 0) });
        } else if (eof_when_exhausted) {
            self.push(.{ .user_data = user_data, .result = 0 });
        } else {
            self.pending_recv = user_data;
        }
    }

    pub fn verifiedChannelKey(self: *CrossArmBackend, fd: Fd) ?[32]u8 {
        _ = self;
        _ = fd;
        return null;
    }

    pub fn recycleBorrowed(self: *CrossArmBackend, comp: completion.Completion) void {
        _ = self;
        _ = comp;
    }

    pub fn submitSend(self: *CrossArmBackend, user_data: u64, fd: Fd, bytes: []const u8) !void {
        _ = fd;
        // Totalled, so a test can assert that bytes the loop queued actually
        // reached a submit rather than being dropped with the connection.
        self.submitted_bytes += bytes.len;
        self.held[self.held_len] = .{ .user_data = user_data, .len = bytes.len };
        self.held_len += 1;
    }

    pub fn submitCancel(self: *CrossArmBackend, cancel_user_data: u64, target_user_data: u64, fd: Fd) !void {
        _ = fd;
        if (refuse_cancel) return error.SubmissionQueueFull;
        if (self.pending_recv) |ud| {
            if (ud != target_user_data) return error.InvalidCancelTarget;
            self.pending_recv = null;
            self.push(.{ .user_data = target_user_data, .result = -1 });
        }
        self.push(.{ .user_data = cancel_user_data, .result = 0 });
    }

    pub fn submitClose(self: *CrossArmBackend, user_data: u64, fd: Fd) !void {
        _ = fd;
        self.push(.{ .user_data = user_data, .result = 0 });
    }

    pub fn poll(self: *CrossArmBackend, out: []completion.Completion, timeout_ms: i32) !usize {
        if (timeout_ms >= 0) saw_bounded_poll = true;
        if (self.ready_len == 0) {
            if (!hold_sends and self.held_len > 0) {
                const held = self.held[0];
                std.mem.copyForwards(Held, self.held[0 .. self.held_len - 1], self.held[1..self.held_len]);
                self.held_len -= 1;
                var reported = held.len;
                if (partial_send_bytes > 0 and partial_send_bytes < held.len) {
                    reported = partial_send_bytes;
                    partial_send_bytes = 0;
                    // The partner takes some bytes and then goes quiet, which
                    // is the case worth pinning: the loop must not still count
                    // it as a stalled reader.
                    hold_sends = true;
                }
                self.push(.{ .user_data = held.user_data, .result = @intCast(reported) });
            } else if (self.pending_recv != null and self.chunk_idx < chunks.len) {
                const user_data = self.pending_recv.?;
                self.pending_recv = null;
                const chunk = chunks[self.chunk_idx];
                self.chunk_idx += 1;
                self.push(.{ .user_data = user_data, .result = @intCast(chunk.len), .borrowed = .recv(chunk, 0) });
            } else if (self.pending_recv != null and eof_when_exhausted) {
                // An already-armed read reaches end of stream. On a real
                // backend this is what `shutdownFd` buys: the recv completes
                // at once rather than waiting on a quiet partner.
                const user_data = self.pending_recv.?;
                self.pending_recv = null;
                self.push(.{ .user_data = user_data, .result = 0 });
            } else {
                // Nothing to do: the current test phase is over.
                return error.ScriptParked;
            }
        }
        const n = @min(out.len, self.ready_len);
        @memcpy(out[0..n], self.ready[0..n]);
        std.mem.copyForwards(completion.Completion, self.ready[0 .. self.ready_len - n], self.ready[n..self.ready_len]);
        self.ready_len -= n;
        return n;
    }
};

/// Encode `peer`'s queued sends and append their frame bytes to `sink`.
pub fn drainOutboundBytes(peer: *engine.Peer, allocator: std.mem.Allocator, sink: *std.ArrayList(u8)) !void {
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_value| {
        var frame = frame_value;
        defer frame.deinit();
        try sink.appendSlice(allocator, frame.bytes());
    }
}

pub fn drainOutboundStreamBytes(peer: *engine.Peer, allocator: std.mem.Allocator, sink: *std.ArrayList(u8)) !void {
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_value| {
        var frame = frame_value;
        defer frame.deinit();
        _ = try pancake.net.appendFrameBytes(sink, allocator, frame.bytes());
    }
}
