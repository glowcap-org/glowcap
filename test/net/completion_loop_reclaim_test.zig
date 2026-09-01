//! How the completion loop takes a connection back, on scripted backends: a
//! dead peer's read error reclaims the slot and fires `on_close` (ADR-0081),
//! and a park past `park_kill_ms` reclaims with its own close reason.

const std = @import("std");
const builtin = @import("builtin");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const tcp = pancake.net.tcp;
const Loop = pancake.net.TcpLoop;
const completion = pancake.net.completion;
const fetch_pump = @import("../support/fetch_pump.zig");
const handshake = @import("../support/handshake.zig");
const no_dial = @import("../support/no_dial_locator.zig");

const frame_cap = fixtures.frame_cap;
const fixtures = @import("../support/completion_loop_fixtures.zig");
const startSession = fixtures.startSession;
const makeServerPeer = fixtures.makeServerPeer;
const drainOutboundBytes = fixtures.drainOutboundBytes;
const drainOutboundStreamBytes = fixtures.drainOutboundStreamBytes;
const FakeBackend = fixtures.FakeBackend;
const FakeEvent = fixtures.FakeEvent;

/// A peer that vanishes without a clean close: its armed recv finally surfaces
/// a read error (an RST, or a keepalive probe giving up on a dead remote host).
/// One connection accepts, its opening send lands, then the next recv errors.
const DeadPeerBackend = struct {
    pub const Fd = i32;

    pub fn applyKeepalive(_: *DeadPeerBackend, _: Fd, _: completion.Keepalive) !void {
        return error.OperationUnsupported;
    }

    pub fn wireFraming(_: *DeadPeerBackend, _: Fd) model.transport.WireFraming {
        return .byte_stream;
    }

    const ok_fd: Fd = 200;
    // -ECONNRESET on Linux: the shape a vanished-then-surfaced peer produces.
    const read_error: i64 = -104;

    accepts: usize = 0,
    pool_free: usize = 0,
    ready: [16]completion.Completion = undefined,
    ready_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, queue_entries: u16, read_buffers: u16, read_buffer_bytes: u32) !DeadPeerBackend {
        _ = allocator;
        _ = queue_entries;
        _ = read_buffer_bytes;
        return .{ .pool_free = read_buffers };
    }
    pub fn deinit(self: *DeadPeerBackend) void {
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
    fn push(self: *DeadPeerBackend, c: completion.Completion) void {
        self.ready[self.ready_len] = c;
        self.ready_len += 1;
    }
    pub fn submitAccept(self: *DeadPeerBackend, user_data: u64, listen_fd: Fd) !void {
        _ = listen_fd;
        if (self.accepts >= 1) return; // one connection; later re-arms pend
        self.accepts += 1;
        self.push(.{ .user_data = user_data, .result = ok_fd });
    }
    pub fn submitSend(self: *DeadPeerBackend, user_data: u64, fd: Fd, bytes: []const u8) !void {
        _ = fd;
        self.push(.{ .user_data = user_data, .result = @intCast(bytes.len) });
    }
    pub fn submitRecv(self: *DeadPeerBackend, user_data: u64, fd: Fd) !void {
        _ = fd;
        // The vanish surfaces: a read error, not a clean EOF (result 0).
        self.push(.{
            .user_data = user_data,
            .result = read_error,
            .failure = error.ConnectionResetByPeer,
        });
    }
    pub fn submitCancel(self: *DeadPeerBackend, cancel_user_data: u64, target_user_data: u64, fd: Fd) !void {
        _ = .{ target_user_data, fd };
        self.push(.{ .user_data = cancel_user_data, .result = 0 });
    }
    pub fn verifiedChannelKey(self: *DeadPeerBackend, fd: Fd) ?[32]u8 {
        _ = self;
        _ = fd;
        return null;
    }

    pub fn recycleBorrowed(self: *DeadPeerBackend, comp: completion.Completion) void {
        _ = comp;
        self.pool_free += 1;
    }
    pub fn submitClose(self: *DeadPeerBackend, user_data: u64, fd: Fd) !void {
        _ = fd;
        self.push(.{ .user_data = user_data, .result = 0 });
    }
    pub fn poll(self: *DeadPeerBackend, out: []completion.Completion, timeout_ms: i32) !usize {
        _ = timeout_ms;
        if (self.ready_len == 0) return error.FakeBackendStalled;
        const n = @min(out.len, self.ready_len);
        @memcpy(out[0..n], self.ready[0..n]);
        std.mem.copyForwards(completion.Completion, self.ready[0 .. self.ready_len - n], self.ready[n..self.ready_len]);
        self.ready_len -= n;
        return n;
    }
};

/// Records the loop's `on_close` firing, so the test can prove the callback ran
/// under `run` (not only at `closeAndDrain`) and carried `opened == true`.
const CloseWatch = struct {
    var fired: usize = 0;
    var opened: bool = false;
    var failure_name: ?[]const u8 = null;
};
fn watchClose(ctx: ?*anyopaque, slot: usize, conn_ctx: ?*anyopaque, report: completion.CloseReport) void {
    _ = ctx;
    _ = slot;
    _ = conn_ctx;
    CloseWatch.fired += 1;
    CloseWatch.opened = report.opened;
    CloseWatch.failure_name = if (report.failure) |failure| failure.error_name else null;
}

test "completion loop: a dead peer's read error reclaims the slot and fires on_close under run (ADR-0081)" {
    const allocator = std.testing.allocator;

    CloseWatch.fired = 0;
    CloseWatch.opened = false;
    CloseWatch.failure_name = null;

    var loop = try completion.Loop(DeadPeerBackend, no_dial.Unsupported).init(allocator, makeServerPeer, null, .{
        .max_conns = 4,
        .listen = 0,
        .on_close = watchClose,
    });
    defer loop.deinit();

    // The remote vanished: its armed recv completes with a read error while the
    // loop is running. The loop must reclaim the slot and fire on_close *now*,
    // not defer liveness to closeAndDrain (ADR-0081, contract 3).
    try loop.run(.{ .after_closed = 1 });

    try std.testing.expectEqual(@as(usize, 1), loop.closed_count);
    try std.testing.expectEqual(@as(usize, 1), CloseWatch.fired);
    // The connection had accepted (transport-opened) before the read error, so
    // the close reports opened == true — a surfaced vanish, not a refused dial.
    try std.testing.expect(CloseWatch.opened);
    try std.testing.expectEqualStrings("ConnectionResetByPeer", CloseWatch.failure_name.?);
}

/// Park-kill (ADR-0082): a connection that stays `.parked` past `park_kill_ms`
/// is reclaimed and `on_close` reports `CloseReason.park_kill`.
const ParkKillWatch = struct {
    var fired: usize = 0;
    var reason: completion.CloseReason = .ordinary;
};

fn watchParkKill(ctx: ?*anyopaque, slot: usize, conn_ctx: ?*anyopaque, report: completion.CloseReport) void {
    _ = ctx;
    _ = slot;
    _ = conn_ctx;
    ParkKillWatch.fired += 1;
    ParkKillWatch.reason = report.reason;
}

test "completion loop: park past park_kill_ms reclaims with CloseReason.park_kill" {
    const allocator = std.testing.allocator;

    // No client script: this test never feeds one (`chunks` is empty below).
    // What has to exceed the mark is the *server's* hello, the write that
    // parks the connection, and that is asserted on `server_ss` a few lines
    // down.
    const high_water: usize = 16;

    var server_twin = try makeServerPeer(null, allocator);
    defer server_twin.deinit();
    var server_ss: std.ArrayList(u8) = .empty;
    defer server_ss.deinit(allocator);
    try drainOutboundBytes(&server_twin, allocator, &server_ss);
    try std.testing.expect(server_ss.items.len > high_water);

    FakeBackend.chunks = &.{};
    defer FakeBackend.chunks = &.{};

    ParkKillWatch.fired = 0;
    ParkKillWatch.reason = .ordinary;

    var loop = try completion.Loop(FakeBackend, no_dial.Unsupported).init(allocator, makeServerPeer, null, .{
        .max_conns = 4,
        .listen = 0,
        .outbound_high_water_bytes = high_water,
        .park_kill_ms = 0, // reclaim as soon as reap runs after park
        .on_close = watchParkKill,
    });
    defer loop.deinit();

    try loop.run(.{ .after_closed = 1 });

    try std.testing.expectEqual(@as(usize, 1), loop.closed_count);
    try std.testing.expectEqual(@as(usize, 1), ParkKillWatch.fired);
    try std.testing.expectEqual(completion.CloseReason.park_kill, ParkKillWatch.reason);
}
