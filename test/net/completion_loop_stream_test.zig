//! Bytes streaming through the completion loop under scarcity, on scripted
//! backends: a pool of one read buffer serves starved connections without
//! dropping, a frame split across two recv completions applies exactly once
//! via the spill, an in-flight send's bytes stay frozen while replies queue
//! behind it, and an incomplete big-frame prefix under the peer cap is not
//! aborted.

const std = @import("std");
const builtin = @import("builtin");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const tcp = glowcap.net.tcp;
const Loop = glowcap.net.TcpLoop;
const completion = glowcap.net.completion;
const fetch_pump = @import("../support/fetch_pump.zig");
const handshake = @import("../support/handshake.zig");
const no_dial = @import("../support/no_dial_locator.zig");

const frame_cap = fixtures.frame_cap;
const fixtures = @import("../support/completion_loop_fixtures.zig");
const startSession = fixtures.startSession;
const makeServerPeer = fixtures.makeServerPeer;
const pumpStream = fixtures.pumpStream;
const drainOutboundStreamBytes = fixtures.drainOutboundStreamBytes;
const FakeBackend = fixtures.FakeBackend;
const FakeEvent = fixtures.FakeEvent;

/// A scripted backend for the shared-pool contract (ADR-0019): every accepted
/// connection replays the same inbound `chunks` script, each chunk handed out
/// as a borrowed completion view from a pool of `read_buffers` buffers. A recv
/// armed while the pool is empty completes `recv_no_buffer`, exactly the
/// platform backends' starvation shape, and sends complete synchronously.
const ScriptBackend = struct {
    pub const Fd = i32;

    pub fn applyKeepalive(_: *ScriptBackend, _: Fd, _: completion.Keepalive) !void {
        return error.OperationUnsupported;
    }

    pub fn wireFraming(_: *ScriptBackend, _: Fd) model.transport.WireFraming {
        return .byte_stream;
    }

    /// The per-connection inbound script (the same bytes for every
    /// connection), set by the test before `Loop.init`.
    var chunks: []const []const u8 = &.{};
    /// How many scripted connections to accept.
    var accept_count: usize = 1;

    const first_fd: Fd = 10;

    accepts: usize = 0,
    chunk_idx: [4]usize = @splat(0),
    pool_free: usize = 0,
    handed: usize = 0,
    recycles: usize = 0,
    starved: usize = 0,
    sends_ok: usize = 0,
    ready: [64]completion.Completion = undefined,
    ready_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, queue_entries: u16, read_buffers: u16, read_buffer_bytes: u32) !ScriptBackend {
        _ = allocator;
        _ = queue_entries;
        _ = read_buffer_bytes;
        return .{ .pool_free = read_buffers };
    }

    pub fn deinit(self: *ScriptBackend) void {
        self.* = .{ .pool_free = 0 };
    }

    pub const ListenTarget = u16;

    pub fn loopListenTarget(port: u16) ListenTarget {
        return port;
    }

    /// A scripted listener binds at `openListener`; nothing pends here; a
    /// wrapped adapter's pending setup reports through the adapter itself.
    pub fn listenerPending(_: *@This(), _: Fd) bool {
        return false;
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

    fn push(self: *ScriptBackend, c: completion.Completion) void {
        self.ready[self.ready_len] = c;
        self.ready_len += 1;
    }

    pub fn submitAccept(self: *ScriptBackend, user_data: u64, listen_fd: Fd) !void {
        _ = listen_fd;
        if (self.accepts >= accept_count) return;
        self.push(.{ .user_data = user_data, .result = first_fd + @as(Fd, @intCast(self.accepts)) });
        self.accepts += 1;
    }

    pub fn submitRecv(self: *ScriptBackend, user_data: u64, fd: Fd) !void {
        const conn: usize = @intCast(fd - first_fd);
        if (self.chunk_idx[conn] < chunks.len) {
            if (self.pool_free == 0) {
                // Data is pending but every pool buffer is lent out: the
                // platform shape is an immediate starved completion.
                self.starved += 1;
                self.push(.{ .user_data = user_data, .result = -1, .recv_no_buffer = true });
                return;
            }
            self.pool_free -= 1;
            self.handed += 1;
            const chunk = chunks[self.chunk_idx[conn]];
            self.chunk_idx[conn] += 1;
            self.push(.{ .user_data = user_data, .result = @intCast(chunk.len), .borrowed = .recv(chunk, 0) });
        } else {
            self.push(.{ .user_data = user_data, .result = 0 }); // clean EOF
        }
    }

    pub fn verifiedChannelKey(self: *ScriptBackend, fd: Fd) ?[32]u8 {
        _ = self;
        _ = fd;
        return null;
    }

    pub fn recycleBorrowed(self: *ScriptBackend, comp: completion.Completion) void {
        _ = comp;
        self.recycles += 1;
        self.pool_free += 1;
    }

    pub fn submitSend(self: *ScriptBackend, user_data: u64, fd: Fd, bytes: []const u8) !void {
        _ = fd;
        self.sends_ok += 1;
        self.push(.{ .user_data = user_data, .result = @intCast(bytes.len) });
    }

    pub fn submitCancel(self: *ScriptBackend, cancel_user_data: u64, target_user_data: u64, fd: Fd) !void {
        _ = .{ target_user_data, fd };
        self.push(.{ .user_data = cancel_user_data, .result = 0 });
    }

    pub fn submitClose(self: *ScriptBackend, user_data: u64, fd: Fd) !void {
        _ = fd;
        self.push(.{ .user_data = user_data, .result = 0 });
    }

    /// No submission queue here, so a peek is a zero-timeout poll.
    pub fn peek(self: *ScriptBackend, out: []completion.Completion) !usize {
        return self.poll(out, 0);
    }

    pub fn poll(self: *ScriptBackend, out: []completion.Completion, timeout_ms: i32) !usize {
        _ = timeout_ms;
        // The loop stalled with no completion to deliver: a loop bug, a
        // starved connection that was never resumed would die here, loudly.
        if (self.ready_len == 0) return error.FakeBackendStalled;
        const n = @min(out.len, self.ready_len);
        @memcpy(out[0..n], self.ready[0..n]);
        std.mem.copyForwards(completion.Completion, self.ready[0 .. self.ready_len - n], self.ready[n..self.ready_len]);
        self.ready_len -= n;
        return n;
    }
};

/// Build the shared two-frame conversation script: the client's
/// `op:start-session`, then a fetch of the shared bootstrap cap, both
/// admissible against `makeServerPeer`'s session.
fn buildClientScript(
    allocator: std.mem.Allocator,
    client_ss: *std.ArrayList(u8),
    fetch_bytes: *std.ArrayList(u8),
) !void {
    var client = engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = false });
    defer client.deinit();
    client.session_state.limits.max_frame_bytes = frame_cap;

    try client.sendBorrowed(startSession("client"));
    try drainOutboundStreamBytes(&client, allocator, client_ss);

    var server_twin = try makeServerPeer(null, allocator);
    defer server_twin.deinit();
    _ = try pumpStream(&server_twin, &client, allocator);
    fetch_pump.drainEvents(&client);

    const prepared = try engine.fetch.prepareFetchSwissnum(allocator, &client.session_state, "thermostat");
    try client.send(prepared.message);
    try drainOutboundStreamBytes(&client, allocator, fetch_bytes);
}

test "completion loop: a pool of one serves two starved connections, a starved read resumes on recycle, never drops" {
    const allocator = std.testing.allocator;

    var client_ss: std.ArrayList(u8) = .empty;
    defer client_ss.deinit(allocator);
    var fetch_bytes: std.ArrayList(u8) = .empty;
    defer fetch_bytes.deinit(allocator);
    try buildClientScript(allocator, &client_ss, &fetch_bytes);

    ScriptBackend.chunks = &.{ client_ss.items, fetch_bytes.items };
    ScriptBackend.accept_count = 2;
    defer {
        ScriptBackend.chunks = &.{};
        ScriptBackend.accept_count = 1;
    }

    var loop = try completion.Loop(ScriptBackend, no_dial.Unsupported).initWithBackendOptions(allocator, .{
        .read_buffers = 1,
    }, makeServerPeer, null, .{
        .max_conns = 4,
        .listen = 0,
    });
    defer loop.deinit();

    // Two connections contend for the single shared buffer. Both must be
    // served to completion: a starved recv parks and resumes when the buffer
    // recycles; if the loop ever dropped or stranded a starved connection,
    // the backend's stall check would fail the run loudly.
    try loop.run(.{ .after_closed = 2 });

    try std.testing.expectEqual(@as(usize, 2), loop.closed_count);
    // The pool of one really was contended at least once.
    try std.testing.expect(loop.backend.starved >= 1);
    // Both connections consumed their whole script and were answered.
    try std.testing.expectEqual(@as(usize, 2), loop.backend.chunk_idx[0]);
    try std.testing.expectEqual(@as(usize, 2), loop.backend.chunk_idx[1]);
    try std.testing.expect(loop.backend.sends_ok >= 4);
    // Every successful recv's buffer was recycled exactly once.
    try std.testing.expectEqual(@as(usize, 4), loop.backend.handed);
    try std.testing.expectEqual(loop.backend.handed, loop.backend.recycles);
}

test "completion loop: a frame split across two recv completions applies exactly once via the spill" {
    const allocator = std.testing.allocator;

    var client_ss: std.ArrayList(u8) = .empty;
    defer client_ss.deinit(allocator);
    var fetch_bytes: std.ArrayList(u8) = .empty;
    defer fetch_bytes.deinit(allocator);
    try buildClientScript(allocator, &client_ss, &fetch_bytes);

    // Split the start-session frame mid-frame: the first completion carries an
    // incomplete prefix (which must absorb into the bounded spill, because the
    // pool buffer is recycled before the rest arrives), the second carries the
    // remainder plus the whole fetch frame.
    const split = client_ss.items.len / 2;
    try std.testing.expect(split > 0 and split < client_ss.items.len);
    const rest_and_fetch = try std.mem.concat(allocator, u8, &.{
        client_ss.items[split..],
        fetch_bytes.items,
    });
    defer allocator.free(rest_and_fetch);

    ScriptBackend.chunks = &.{ client_ss.items[0..split], rest_and_fetch };
    defer ScriptBackend.chunks = &.{};

    var loop = try completion.Loop(ScriptBackend, no_dial.Unsupported).init(allocator, makeServerPeer, null, .{
        .max_conns = 4,
        .listen = 0,
    });
    defer loop.deinit();

    try loop.run(.{ .after_closed = 1 });

    try std.testing.expectEqual(@as(usize, 1), loop.closed_count);
    // The whole script was consumed and the conversation completed: the split
    // start-session applied exactly once (a duplicate or dropped apply would
    // have failed the session before the fetch, leaving the script unread),
    // and the fetch drew its reply alongside the server's start-session.
    try std.testing.expectEqual(@as(usize, 2), loop.backend.chunk_idx[0]);
    try std.testing.expect(loop.backend.sends_ok >= 2);
    // Both borrowed views were recycled exactly once.
    try std.testing.expectEqual(@as(usize, 2), loop.backend.handed);
    try std.testing.expectEqual(loop.backend.handed, loop.backend.recycles);
}

/// A scripted backend that *holds* every submitted send while recv completions
/// keep flowing, the kernel-borrow shape of a real io_uring send. At submit it
/// snapshots the submitted bytes. At release (when the loop has nothing else to
/// do) it checks the borrowed slice still holds exactly those bytes. Before the
/// front/back outbound split, a reply appended while a write was in flight
/// could realloc the queue and free the storage this held slice points into.
const HeldSendBackend = struct {
    pub const Fd = i32;

    pub fn applyKeepalive(_: *HeldSendBackend, _: Fd, _: completion.Keepalive) !void {
        return error.OperationUnsupported;
    }

    pub fn wireFraming(_: *HeldSendBackend, _: Fd) model.transport.WireFraming {
        return .byte_stream;
    }

    /// The inbound wire script, set by the test before `Loop.init`.
    var chunks: []const []const u8 = &.{};

    const Held = struct { user_data: u64, bytes: []const u8, snapshot: []u8 };

    allocator: std.mem.Allocator,
    chunk_idx: usize = 0,
    pool_free: usize = 0,
    handed: usize = 0,
    recycles: usize = 0,
    sends: usize = 0,
    ready: [32]completion.Completion = undefined,
    ready_len: usize = 0,
    held: ?Held = null,
    accepted: bool = false,

    pub fn init(allocator: std.mem.Allocator, queue_entries: u16, read_buffers: u16, read_buffer_bytes: u32) !HeldSendBackend {
        _ = queue_entries;
        _ = read_buffer_bytes;
        return .{ .allocator = allocator, .pool_free = read_buffers };
    }

    pub fn deinit(self: *HeldSendBackend) void {
        if (self.held) |held| self.allocator.free(held.snapshot);
        self.* = .{ .allocator = self.allocator, .pool_free = 0 };
    }

    pub const ListenTarget = u16;

    pub fn loopListenTarget(port: u16) ListenTarget {
        return port;
    }

    /// A scripted listener binds at `openListener`; nothing pends here; a
    /// wrapped adapter's pending setup reports through the adapter itself.
    pub fn listenerPending(_: *@This(), _: Fd) bool {
        return false;
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

    fn push(self: *HeldSendBackend, c: completion.Completion) void {
        self.ready[self.ready_len] = c;
        self.ready_len += 1;
    }

    pub fn submitAccept(self: *HeldSendBackend, user_data: u64, listen_fd: Fd) !void {
        _ = listen_fd;
        // One scripted connection; the loop's re-armed accept pends forever.
        if (self.accepted) return;
        self.accepted = true;
        self.push(.{ .user_data = user_data, .result = 7 });
    }

    pub fn submitRecv(self: *HeldSendBackend, user_data: u64, fd: Fd) !void {
        _ = fd;
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

    pub fn verifiedChannelKey(self: *HeldSendBackend, fd: Fd) ?[32]u8 {
        _ = self;
        _ = fd;
        return null;
    }

    pub fn recycleBorrowed(self: *HeldSendBackend, comp: completion.Completion) void {
        _ = comp;
        self.recycles += 1;
        self.pool_free += 1;
    }

    pub fn submitSend(self: *HeldSendBackend, user_data: u64, fd: Fd, bytes: []const u8) !void {
        _ = fd;
        self.sends += 1;
        // Borrow the slice (as the kernel would) and snapshot what it held at
        // submit time. The loop guarantees one write in flight per connection
        // and this script has one connection, so one held slot suffices.
        const snapshot = try self.allocator.dupe(u8, bytes);
        self.held = .{ .user_data = user_data, .bytes = bytes, .snapshot = snapshot };
    }

    pub fn submitCancel(self: *HeldSendBackend, cancel_user_data: u64, target_user_data: u64, fd: Fd) !void {
        _ = .{ target_user_data, fd };
        self.push(.{ .user_data = cancel_user_data, .result = 0 });
    }

    pub fn submitClose(self: *HeldSendBackend, user_data: u64, fd: Fd) !void {
        _ = fd;
        self.push(.{ .user_data = user_data, .result = 0 });
    }

    /// No submission queue here, so a peek is a zero-timeout poll.
    pub fn peek(self: *HeldSendBackend, out: []completion.Completion) !usize {
        return self.poll(out, 0);
    }

    pub fn poll(self: *HeldSendBackend, out: []completion.Completion, timeout_ms: i32) !usize {
        _ = timeout_ms;
        if (self.ready_len == 0) {
            // The loop is out of other work: the "kernel" finally performs the
            // held write, reading the borrowed slice now. If anything moved or
            // freed that storage since submit, the bytes differ, the exact
            // use-after-free the frozen front buffer forbids.
            const held = self.held orelse return error.FakeBackendStalled;
            self.held = null;
            defer self.allocator.free(held.snapshot);
            if (!std.mem.eql(u8, held.snapshot, held.bytes)) return error.SubmittedBytesMutated;
            self.push(.{ .user_data = held.user_data, .result = @intCast(held.bytes.len) });
        }
        const n = @min(out.len, self.ready_len);
        @memcpy(out[0..n], self.ready[0..n]);
        std.mem.copyForwards(completion.Completion, self.ready[0 .. self.ready_len - n], self.ready[n..self.ready_len]);
        self.ready_len -= n;
        return n;
    }
};

test "completion loop: an in-flight send's bytes stay frozen while replies queue behind it" {
    const allocator = std.testing.allocator;

    // The client's start-session, then several fetches: every fetch reply the
    // server queues lands while its opening start-session send is still held
    // by the backend, and together they outgrow the queue's first allocation,
    // forcing a realloc that would free the held storage.
    var client = engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = false });
    defer client.deinit();
    client.session_state.limits.max_frame_bytes = frame_cap;

    var client_ss: std.ArrayList(u8) = .empty;
    defer client_ss.deinit(allocator);
    try client.sendBorrowed(startSession("client"));
    try drainOutboundStreamBytes(&client, allocator, &client_ss);

    var server_twin = try makeServerPeer(null, allocator);
    defer server_twin.deinit();
    _ = try pumpStream(&server_twin, &client, allocator);
    fetch_pump.drainEvents(&client);

    const fetch_count = 4;
    var fetch_frames: [fetch_count]std.ArrayList(u8) = @splat(.empty);
    defer for (&fetch_frames) |*f| f.deinit(allocator);
    for (&fetch_frames) |*f| {
        const prepared = try engine.fetch.prepareFetchSwissnum(allocator, &client.session_state, "thermostat");
        try client.send(prepared.message);
        try drainOutboundStreamBytes(&client, allocator, f);
    }

    HeldSendBackend.chunks = &.{
        client_ss.items,
        fetch_frames[0].items,
        fetch_frames[1].items,
        fetch_frames[2].items,
        fetch_frames[3].items,
    };
    defer HeldSendBackend.chunks = &.{};

    var loop = try completion.Loop(HeldSendBackend, no_dial.Unsupported).init(allocator, makeServerPeer, null, .{
        .max_conns = 4,
        .listen = 0,
    });
    defer loop.deinit();

    // The backend fails the run with SubmittedBytesMutated if the held send's
    // storage was moved or freed while replies queued behind it.
    try loop.run(.{ .after_closed = 1 });

    try std.testing.expectEqual(@as(usize, 1), loop.closed_count);
    // The whole script was consumed while the first send stayed held.
    try std.testing.expectEqual(@as(usize, 5), loop.backend.chunk_idx);
    try std.testing.expect(loop.backend.sends >= 1);
    // Every successful recv's pool buffer was recycled exactly once.
    try std.testing.expectEqual(loop.backend.handed, loop.backend.recycles);
}

/// A server peer whose admission limit is above the shared read
/// buffer, proving pool sizing does not become a second frame limit.
fn makeBigFramePeer(ctx: ?*anyopaque, allocator: std.mem.Allocator) anyerror!engine.Peer {
    _ = ctx;
    var peer = engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = false });
    errdefer peer.deinit();
    peer.session_state.limits.max_frame_bytes = big_frame_max;
    _ = try peer.registerBootstrapCap("thermostat");
    try peer.sendBorrowed(startSession("server"));
    return peer;
}

const big_frame_max = 1 << 16;
const small_read_buffer_bytes: u32 = 4 * 1024;

/// Build a large but structurally valid `op:deliver` frame in the negotiated
/// codec: the client handshakes against a server twin, then sends a fetch whose
/// swissnum is padded to many kilobytes, so the frame is larger than one pool
/// buffer yet well under the peers' `max_frame_bytes`. Returns the client's status-allow: pending state or quoted runtime label
/// start-session bytes and the big deliver bytes, both owned by the caller.
fn buildBigDeliverScript(
    allocator: std.mem.Allocator,
    client_ss: *std.ArrayList(u8),
    big_deliver: *std.ArrayList(u8),
) !void {
    var client = engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = false });
    defer client.deinit();
    client.session_state.limits.max_frame_bytes = big_frame_max;

    try client.sendBorrowed(startSession("client"));
    try drainOutboundStreamBytes(&client, allocator, client_ss);

    var server_twin = try makeBigFramePeer(null, allocator);
    defer server_twin.deinit();
    _ = try pumpStream(&server_twin, &client, allocator);
    fetch_pump.drainEvents(&client);

    // A fetch is an op:deliver to the bootstrap; padding the swissnum makes the
    // frame arbitrarily large while staying structurally valid.
    const big_swiss = try allocator.alloc(u8, 12 * 1024);
    defer allocator.free(big_swiss);
    @memset(big_swiss, 'x');
    const prepared = try engine.fetch.prepareFetchSwissnum(allocator, &client.session_state, big_swiss);
    try client.send(prepared.message);
    try drainOutboundStreamBytes(&client, allocator, big_deliver);
}

test "completion loop: an incomplete prefix over one read buffer but under the peer cap is not aborted" {
    const allocator = std.testing.allocator;

    var client_ss: std.ArrayList(u8) = .empty;
    defer client_ss.deinit(allocator);
    var big_deliver: std.ArrayList(u8) = .empty;
    defer big_deliver.deinit(allocator);
    try buildBigDeliverScript(allocator, &client_ss, &big_deliver);

    // Feed the big frame only in prefix: the first prefix chunk alone already
    // crosses one 4 KiB pool buffer while the frame stays incomplete. A loop
    // that mistakes pool sizing for admission aborts the connection on this
    // first prefix and never requests the second chunk. Using only the peer's
    // admission limit keeps reading, so the second prefix is handed out and
    // the connection ends only at the scripted EOF.
    try std.testing.expect(big_deliver.items.len > 5500);
    const prefix1 = big_deliver.items[0..5000];
    const prefix2 = big_deliver.items[5000..5500];

    ScriptBackend.chunks = &.{ client_ss.items, prefix1, prefix2 };
    defer ScriptBackend.chunks = &.{};

    var loop = try completion.Loop(ScriptBackend, no_dial.Unsupported).initWithBackendOptions(allocator, .{
        .read_buffer_bytes = small_read_buffer_bytes,
    }, makeBigFramePeer, null, .{
        .max_conns = 4,
        .listen = 0,
    });
    defer loop.deinit();

    try loop.run(.{ .after_closed = 1 });

    try std.testing.expectEqual(@as(usize, 1), loop.closed_count);
    // Both prefix chunks were consumed (3 = client_ss + prefix1 + prefix2): the
    // admissible-but-incomplete frame crossed the pool-buffer boundary.
    try std.testing.expectEqual(@as(usize, 3), loop.backend.chunk_idx[0]);
}
