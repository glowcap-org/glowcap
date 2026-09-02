//! Fan-in throttle reclaim: a drained source stays parked while its sink is
//! over high-water, a victim's slow-reader clock starts when it becomes a
//! sink, condemning a parked sink restarts the flush clock, and a condemned
//! sink releases the sources it throttled.

const std = @import("std");
const builtin = @import("builtin");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const tcp = glowcap.net.tcp;
const Loop = glowcap.net.TcpLoop;
const completion = glowcap.net.completion;
const fetch_pump = @import("../../support/fetch_pump.zig");
const handshake = @import("../../support/handshake.zig");
const no_dial = @import("../../support/no_dial_locator.zig");

const frame_cap = fixtures.frame_cap;
const fixtures = @import("../../support/completion_loop_fixtures.zig");
const startSession = fixtures.startSession;
const makeServerPeer = fixtures.makeServerPeer;
const drainOutboundBytes = fixtures.drainOutboundBytes;
const drainOutboundStreamBytes = fixtures.drainOutboundStreamBytes;
const FakeBackend = fixtures.FakeBackend;
const FakeEvent = fixtures.FakeEvent;

/// Two-connection fan-in throttle (ADR-0082): while the sink stays over
/// high-water, a drained source stays parked; when the sink finally drains,
/// the source's read re-arms.
const FanInBackend = struct {
    pub const Fd = i32;

    pub fn applyKeepalive(_: *FanInBackend, _: Fd, _: completion.Keepalive) !void {
        return error.OperationUnsupported;
    }

    pub fn wireFraming(_: *FanInBackend, _: Fd) model.transport.WireFraming {
        return .byte_stream;
    }

    const sink_fd: Fd = 10;
    const source_fd: Fd = 20;

    /// Per-connection inbound scripts (index 0 = sink, 1 = source).
    var scripts: [2][]const []const u8 = .{ &.{}, &.{} };
    /// Hold the sink's write until fan-in hold is observed.
    var hold_sink: bool = true;
    /// Set true when poll sees: both accepted, source write drained, source
    /// never armed a recv while the sink was still held.
    var saw_fan_in_hold: bool = false;
    /// Hand control back to the test at the fan-in hold instead of releasing
    /// the sink, so it can condemn the sink while its victim is still parked.
    var stall_at_hold: bool = false;

    accepts: usize = 0,
    chunk_idx: [2]usize = .{ 0, 0 },
    pool_free: usize = 0,
    handed: usize = 0,
    recycles: usize = 0,
    ready: [16]completion.Completion = undefined,
    ready_len: usize = 0,
    held: [2]?struct { user_data: u64, len: usize } = .{ null, null },
    recv_armed: [2]usize = .{ 0, 0 },
    source_released: bool = false,

    pub fn init(allocator: std.mem.Allocator, queue_entries: u16, read_buffers: u16, read_buffer_bytes: u32) !FanInBackend {
        _ = allocator;
        _ = queue_entries;
        _ = read_buffer_bytes;
        return .{ .pool_free = read_buffers };
    }

    pub fn deinit(self: *FanInBackend) void {
        self.* = .{ .pool_free = 0 };
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

    fn idx(fd: Fd) usize {
        return if (fd == sink_fd) 0 else 1;
    }

    fn push(self: *FanInBackend, c: completion.Completion) void {
        self.ready[self.ready_len] = c;
        self.ready_len += 1;
    }

    pub fn submitAccept(self: *FanInBackend, user_data: u64, listen_fd: Fd) !void {
        _ = listen_fd;
        if (self.accepts >= 2) return;
        self.accepts += 1;
        const fd: Fd = if (self.accepts == 1) sink_fd else source_fd;
        self.push(.{ .user_data = user_data, .result = fd });
    }

    pub fn submitRecv(self: *FanInBackend, user_data: u64, fd: Fd) !void {
        const i = idx(fd);
        self.recv_armed[i] += 1;
        const script = scripts[i];
        if (self.chunk_idx[i] < script.len) {
            if (self.pool_free == 0) {
                self.push(.{ .user_data = user_data, .result = -1, .recv_no_buffer = true });
                return;
            }
            self.pool_free -= 1;
            self.handed += 1;
            const chunk = script[self.chunk_idx[i]];
            self.chunk_idx[i] += 1;
            self.push(.{ .user_data = user_data, .result = @intCast(chunk.len), .borrowed = .recv(chunk, 0) });
        } else {
            self.push(.{ .user_data = user_data, .result = 0 });
        }
    }

    pub fn verifiedChannelKey(self: *FanInBackend, fd: Fd) ?[32]u8 {
        _ = self;
        _ = fd;
        return null;
    }

    pub fn recycleBorrowed(self: *FanInBackend, comp: completion.Completion) void {
        _ = comp;
        self.recycles += 1;
        self.pool_free += 1;
    }

    pub fn submitSend(self: *FanInBackend, user_data: u64, fd: Fd, bytes: []const u8) !void {
        self.held[idx(fd)] = .{ .user_data = user_data, .len = bytes.len };
    }

    pub fn submitCancel(self: *FanInBackend, cancel_user_data: u64, target_user_data: u64, fd: Fd) !void {
        _ = .{ target_user_data, fd };
        self.push(.{ .user_data = cancel_user_data, .result = 0 });
    }

    pub fn submitClose(self: *FanInBackend, user_data: u64, fd: Fd) !void {
        _ = fd;
        self.push(.{ .user_data = user_data, .result = 0 });
    }

    pub fn poll(self: *FanInBackend, out: []completion.Completion, timeout_ms: i32) !usize {
        _ = timeout_ms;
        if (self.ready_len == 0) {
            // Prefer releasing the source write so it drains while the sink
            // stays held — that is the fan-in shape under test.
            if (self.held[1]) |h| {
                self.held[1] = null;
                self.source_released = true;
                self.push(.{ .user_data = h.user_data, .result = @intCast(h.len) });
            } else if (self.held[0]) |h| {
                if (hold_sink) {
                    // After the source's write completed, a fan-in hold means
                    // the source never armed a recv while the sink was stuck.
                    if (self.accepts >= 2 and self.source_released and self.recv_armed[1] == 0) {
                        saw_fan_in_hold = true;
                        if (stall_at_hold) return error.FanInHoldReached;
                        hold_sink = false;
                    } else return 0;
                }
                self.held[0] = null;
                self.push(.{ .user_data = h.user_data, .result = @intCast(h.len) });
            } else return error.FakeBackendStalled;
        }
        const n = @min(out.len, self.ready_len);
        @memcpy(out[0..n], self.ready[0..n]);
        std.mem.copyForwards(completion.Completion, self.ready[0 .. self.ready_len - n], self.ready[n..self.ready_len]);
        self.ready_len -= n;
        return n;
    }
};

test "completion loop: fan_in_throttle parks a drained source while a sink is over high-water" {
    const allocator = std.testing.allocator;

    var client = engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = false });
    defer client.deinit();
    client.session_state.limits.max_frame_bytes = frame_cap;
    var client_ss: std.ArrayList(u8) = .empty;
    defer client_ss.deinit(allocator);
    try client.sendCopying(startSession("client"));
    try drainOutboundStreamBytes(&client, allocator, &client_ss);

    var server_twin = try makeServerPeer(null, allocator);
    defer server_twin.deinit();
    var server_ss: std.ArrayList(u8) = .empty;
    defer server_ss.deinit(allocator);
    try drainOutboundBytes(&server_twin, allocator, &server_ss);

    const high_water: usize = 16;
    try std.testing.expect(server_ss.items.len > high_water);

    FanInBackend.scripts = .{ &.{client_ss.items}, &.{client_ss.items} };
    FanInBackend.hold_sink = true;
    FanInBackend.saw_fan_in_hold = false;
    defer {
        FanInBackend.scripts = .{ &.{}, &.{} };
        FanInBackend.hold_sink = true;
        FanInBackend.saw_fan_in_hold = false;
    }

    var park_hits: usize = 0;
    const ParkCount = struct {
        fn onPark(ctx: ?*anyopaque, slot: usize, conn_ctx: ?*anyopaque, reason: completion.ParkReason) void {
            _ = reason;
            _ = slot;
            _ = conn_ctx;
            const n: *usize = @ptrCast(@alignCast(ctx.?));
            n.* += 1;
        }
    };

    var loop = try completion.Loop(FanInBackend, no_dial.Unsupported).init(allocator, makeServerPeer, &park_hits, .{
        .max_conns = 4,
        .listen = 0,
        .outbound_high_water_bytes = high_water,
        .fan_in_throttle = true,
        // The throttle refuses to be built without one, and generously: this
        // test asserts the park, not the reaping, so the deadline must not
        // fire during it.
        .park_kill_ms = 60_000,
        .on_park = ParkCount.onPark,
    });
    defer loop.deinit();

    try loop.run(.{ .after_closed = 2 });

    try std.testing.expect(FanInBackend.saw_fan_in_hold);
    try std.testing.expect(park_hits >= 2);
    try std.testing.expect(loop.backend.recv_armed[1] >= 1);
    try std.testing.expectEqual(@as(usize, 2), loop.closed_count);
    try std.testing.expectEqual(loop.backend.handed, loop.backend.recycles);
}

test "completion loop: a condemned sink releases the fan-in sources it throttled" {
    const allocator = std.testing.allocator;

    var client = engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = false });
    defer client.deinit();
    client.session_state.limits.max_frame_bytes = frame_cap;
    var client_ss: std.ArrayList(u8) = .empty;
    defer client_ss.deinit(allocator);
    try client.sendCopying(startSession("client"));
    try drainOutboundStreamBytes(&client, allocator, &client_ss);

    var server_twin = try makeServerPeer(null, allocator);
    defer server_twin.deinit();
    var server_ss: std.ArrayList(u8) = .empty;
    defer server_ss.deinit(allocator);
    try drainOutboundBytes(&server_twin, allocator, &server_ss);

    const high_water: usize = 16;
    try std.testing.expect(server_ss.items.len > high_water);

    FanInBackend.scripts = .{ &.{client_ss.items}, &.{client_ss.items} };
    FanInBackend.hold_sink = true;
    FanInBackend.saw_fan_in_hold = false;
    FanInBackend.stall_at_hold = true;
    defer {
        FanInBackend.scripts = .{ &.{}, &.{} };
        FanInBackend.hold_sink = true;
        FanInBackend.saw_fan_in_hold = false;
        FanInBackend.stall_at_hold = false;
    }

    var loop = try completion.Loop(FanInBackend, no_dial.Unsupported).init(allocator, makeServerPeer, null, .{
        .max_conns = 4,
        .listen = 0,
        .outbound_high_water_bytes = high_water,
        .fan_in_throttle = true,
        // Required beside the throttle; long enough not to fire here.
        .park_kill_ms = 60_000,
    });
    defer loop.deinit();

    // Stop at the fan-in hold: the sink is over high-water with its write
    // still in the kernel's hands, and the source is parked as its victim.
    // The error is only returned from the branch that sets `saw_fan_in_hold`,
    // so asserting the flag as well restates the line above it.
    try std.testing.expectError(error.FanInHoldReached, loop.run(.{ .after_closed = 2 }));
    try std.testing.expect(loop.conns[1].read == .parked);
    try std.testing.expectEqual(@as(usize, 0), loop.backend.recv_armed[1]);

    // Condemn the sink. Its victim is exempt from the park reaper, and every
    // terminal path returns before `onSend`'s fan-in tail, so the source's
    // only way back is the sink's departure releasing it.
    loop.closeSlot(0);
    try std.testing.expect(loop.conns[0].state == .draining);

    FanInBackend.stall_at_hold = false;
    FanInBackend.hold_sink = false;
    try loop.run(.{ .after_closed = 2 });

    try std.testing.expect(loop.backend.recv_armed[1] >= 1);
    try std.testing.expectEqual(@as(usize, 2), loop.closed_count);
}
