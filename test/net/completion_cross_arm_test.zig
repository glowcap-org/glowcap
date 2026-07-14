//! The completion loop's cross-connection outbound arm (`Loop.armOutbound`):
//! a hook serving connection A that enqueued sends on connection B's peer
//! arms B's write without waiting for B's own traffic. Proven twice: end to
//! end on the platform backend (a quiet partner receives a frame only
//! cross-arming could have put on its wire), and on a scripted backend that
//! pins the queue accounting — cross-armed bytes count into the connection's
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
const fetch_pump = @import("../support/fetch_pump.zig");
const handshake = @import("../support/handshake.zig");
const no_dial = @import("no_dial_locator.zig");

const frame_cap = 4096;

fn startSession(designator: []const u8) model.Message {
    return handshake.startSession(tcp.transport_name, designator);
}

fn makeServerPeer(ctx: ?*anyopaque, allocator: std.mem.Allocator) anyerror!engine.Peer {
    _ = ctx;
    var peer = engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = false });
    errdefer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;
    _ = try peer.registerBootstrapCap("thermostat");
    try peer.sendCopying(startSession("server"));
    return peer;
}

// ── End to end: a quiet partner hears a cross-armed frame ────────────────────

/// One accepted connection's registry row: the peer and slot `make_conn_ctx`
/// recorded, in accept order.
const Entry = struct {
    shared: *Shared,
    peer: *engine.Peer,
    slot: usize,
    index: usize,
};

const Shared = struct {
    allocator: std.mem.Allocator,
    loop: *Loop,
    entries: [2]Entry = undefined,
    count: usize = 0,
    triggered: bool = false,

    fn make(ctx: ?*anyopaque, peer: *engine.Peer, slot: usize) anyerror!?*anyopaque {
        const shared: *Shared = @ptrCast(@alignCast(ctx.?));
        const index = shared.count;
        shared.count += 1;
        shared.entries[index] = .{ .shared = shared, .peer = peer, .slot = slot, .index = index };
        return &shared.entries[index];
    }

    /// The hook under test: the *sender* connection's first deliver makes the
    /// loop enqueue a bootstrap fetch on the *quiet* connection's peer and arm
    /// its outbound — mid-dispatch, from another connection's event.
    fn serve(conn_ctx: ?*anyopaque, peer: *engine.Peer, event: *engine.Event) anyerror!void {
        _ = peer;
        const entry: *Entry = @ptrCast(@alignCast(conn_ctx.?));
        const shared = entry.shared;
        if (entry.index != 1 or event.kind() != .deliver or shared.triggered) return;
        shared.triggered = true;
        const quiet = &shared.entries[0];
        const prepared = try engine.fetch.prepareFetchSwissnum(
            shared.allocator,
            &quiet.peer.session_state,
            "beacon",
        );
        try quiet.peer.send(prepared.message);
        shared.loop.armOutbound(quiet.slot);
    }
};

fn runLoopCapturing(loop: *Loop, until_closed: usize, out_err: *?anyerror) void {
    loop.run(.{ .after_closed = until_closed }) catch |err| {
        out_err.* = err;
    };
}

/// The sender: an ordinary fetch client whose one deliver (the fetch) is the
/// hook's trigger.
fn senderOnce(io: std.Io, port: u16, allocator: std.mem.Allocator) anyerror!void {
    var peer = engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = false });
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const designator_addr = try tcp.parseHostPort("127.0.0.1", port);
    const designator = tcp.locator(&designator_buf, designator_addr).designator;
    const locator: model.PeerLocator = .{
        .transport = tcp.transport_name,
        .designator = designator,
        .hints = model.Hints.emptyMap(),
    };
    var conn = try tcp.connect(io, &peer, locator, read_buf, write_buf, .{});
    defer conn.deinit();

    try fetch_pump.handshakeToOpen(&peer, &conn, startSession("sender"));
    const reference = try fetch_pump.settleFetch(allocator, &peer, &conn, "thermostat");
    model.freeReference(allocator, reference);
}

test "cross-arm: a hook serving one connection puts a frame on a quiet sibling's wire" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    var shared = Shared{ .allocator = allocator, .loop = undefined };
    var loop = try Loop.init(allocator, makeServerPeer, @ptrCast(&shared), .{
        .frame_cap = frame_cap,
        .max_conns = 8,
        .listen = 0,
        .make_conn_ctx = Shared.make,
        .serve = Shared.serve,
    });
    defer loop.deinit();
    shared.loop = &loop;
    const port = loop.port.?;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var loop_err: ?anyerror = null;
    var loop_future = try io.concurrent(runLoopCapturing, .{ &loop, @as(usize, 2), &loop_err });

    // The quiet partner connects and handshakes first, so it is the registry's
    // first entry. It registers `beacon` so the cross-armed bootstrap fetch is
    // admissible and auto-answered, and after the handshake it sends nothing:
    // the only way a frame reaches it is the sibling hook's armOutbound.
    var quiet_peer = engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = false });
    defer quiet_peer.deinit();
    quiet_peer.session_state.limits.max_frame_bytes = frame_cap;
    _ = try quiet_peer.registerBootstrapCap("beacon");

    const quiet_read = try allocator.alloc(u8, frame_cap);
    defer allocator.free(quiet_read);
    const quiet_write = try allocator.alloc(u8, frame_cap);
    defer allocator.free(quiet_write);

    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const designator_addr = try tcp.parseHostPort("127.0.0.1", port);
    const designator = tcp.locator(&designator_buf, designator_addr).designator;
    var quiet_conn = try tcp.connect(io, &quiet_peer, .{
        .transport = tcp.transport_name,
        .designator = designator,
        .hints = model.Hints.emptyMap(),
    }, quiet_read, quiet_write, .{});

    try fetch_pump.handshakeToOpen(&quiet_peer, &quiet_conn, startSession("quiet"));

    // Only now does the sender dial: the quiet connection is accepted and
    // registered, so the hook's registry lookup is deterministic.
    var sender_future = try io.concurrent(senderOnce, .{ io, port, allocator });

    // The quiet partner blocks reading until the cross-armed fetch arrives.
    var saw_deliver = false;
    var spins: usize = 0;
    while (!saw_deliver and spins < 10_000) : (spins += 1) {
        const progress = try quiet_conn.pump();
        while (quiet_peer.pollEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();
            if (event.kind() == .deliver) saw_deliver = true;
        }
        if (progress == .closed) break;
    }

    const sender_result = sender_future.await(io);
    quiet_conn.deinit();
    loop_future.await(io);

    try sender_result;
    if (loop_err) |err| return err;
    try std.testing.expect(saw_deliver);
}

// ── Scripted: cross-armed bytes ride the ADR-0042 queue accounting ──────────

/// A scripted backend with test-controlled phases. Sends are held at submit
/// (the kernel-borrow shape); an idle `poll` releases the oldest held send
/// only while `hold_sends` is false. A recv finds its chunk immediately when
/// one is scripted; with the script exhausted it stays pending (delivered by
/// a later idle poll once the test appends a chunk) or completes as a clean
/// EOF once `eof_when_exhausted` is set. An idle poll with nothing to do
/// returns `error.ScriptParked` — each test phase ends there deliberately.
const CrossArmBackend = struct {
    pub const Fd = i32;

    var chunks: []const []const u8 = &.{};
    var hold_sends: bool = false;
    var eof_when_exhausted: bool = false;

    const Held = struct { user_data: u64, len: usize };

    chunk_idx: usize = 0,
    accepted: bool = false,
    pending_recv: ?u64 = null,
    held: [4]Held = undefined,
    held_len: usize = 0,
    ready: [16]completion.Completion = undefined,
    ready_len: usize = 0,

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

    pub fn boundPort(fd: Fd) !u16 {
        _ = fd;
        return 1;
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
        _ = fd;
        if (self.chunk_idx < chunks.len) {
            const chunk = chunks[self.chunk_idx];
            self.chunk_idx += 1;
            self.push(.{ .user_data = user_data, .result = @intCast(chunk.len), .recv_bytes = chunk });
        } else if (eof_when_exhausted) {
            self.push(.{ .user_data = user_data, .result = 0 });
        } else {
            self.pending_recv = user_data;
        }
    }

    pub fn recycleRecv(self: *CrossArmBackend, comp: completion.Completion) void {
        _ = self;
        _ = comp;
    }

    pub fn submitSend(self: *CrossArmBackend, user_data: u64, fd: Fd, bytes: []const u8) !void {
        _ = fd;
        self.held[self.held_len] = .{ .user_data = user_data, .len = bytes.len };
        self.held_len += 1;
    }

    pub fn submitClose(self: *CrossArmBackend, user_data: u64, fd: Fd) !void {
        _ = fd;
        self.push(.{ .user_data = user_data, .result = 0 });
    }

    pub fn poll(self: *CrossArmBackend, out: []completion.Completion) !usize {
        if (self.ready_len == 0) {
            if (!hold_sends and self.held_len > 0) {
                const held = self.held[0];
                std.mem.copyForwards(Held, self.held[0 .. self.held_len - 1], self.held[1..self.held_len]);
                self.held_len -= 1;
                self.push(.{ .user_data = held.user_data, .result = @intCast(held.len) });
            } else if (self.pending_recv != null and self.chunk_idx < chunks.len) {
                const user_data = self.pending_recv.?;
                self.pending_recv = null;
                const chunk = chunks[self.chunk_idx];
                self.chunk_idx += 1;
                self.push(.{ .user_data = user_data, .result = @intCast(chunk.len), .recv_bytes = chunk });
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
fn drainOutboundBytes(peer: *engine.Peer, allocator: std.mem.Allocator, sink: *std.ArrayList(u8)) !void {
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_value| {
        var frame = frame_value;
        defer frame.deinit();
        try sink.appendSlice(allocator, frame.bytes());
    }
}

test "cross-arm: cross-armed bytes count into pending outbound and park the read at the high-water mark" {
    const allocator = std.testing.allocator;

    // The scripted client's two frames: its start-session, then a fetch of the
    // shared bootstrap cap, both admissible against `makeServerPeer`'s session.
    var client = engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = false });
    defer client.deinit();
    client.session_state.limits.max_frame_bytes = frame_cap;

    var client_ss: std.ArrayList(u8) = .empty;
    defer client_ss.deinit(allocator);
    try client.sendCopying(startSession("client"));
    try drainOutboundBytes(&client, allocator, &client_ss);

    var server_twin = try makeServerPeer(null, allocator);
    defer server_twin.deinit();
    var server_ss: std.ArrayList(u8) = .empty;
    defer server_ss.deinit(allocator);
    try drainOutboundBytes(&server_twin, allocator, &server_ss);
    _ = try client.recvStreamPrefix(server_ss.items);
    fetch_pump.drainEvents(&client);

    var fetch_bytes: std.ArrayList(u8) = .empty;
    defer fetch_bytes.deinit(allocator);
    const prepared = try engine.fetch.prepareFetchSwissnum(allocator, &client.session_state, "thermostat");
    try client.send(prepared.message);
    try drainOutboundBytes(&client, allocator, &fetch_bytes);

    const high_water: usize = 16;

    CrossArmBackend.chunks = &.{client_ss.items};
    CrossArmBackend.hold_sends = false;
    CrossArmBackend.eof_when_exhausted = false;
    defer {
        CrossArmBackend.chunks = &.{};
        CrossArmBackend.hold_sends = false;
        CrossArmBackend.eof_when_exhausted = false;
    }

    var loop = try completion.Loop(CrossArmBackend, no_dial.Unsupported).init(allocator, makeServerPeer, null, .{
        .frame_cap = frame_cap,
        .max_conns = 4,
        .listen = 0,
        .outbound_high_water = high_water,
    });
    defer loop.deinit();

    // Phase 1: the connection opens, its hello drains, its start-session
    // applies, and its next read arms with nothing scripted behind it — the
    // quiet-partner steady state.
    try std.testing.expectError(error.ScriptParked, loop.run(.{ .after_closed = 1 }));
    const conn = &loop.conns[0];
    try std.testing.expect(conn.state == .open);
    try std.testing.expect(conn.read == .armed);
    try std.testing.expectEqual(@as(usize, 0), conn.front.items.len - conn.front_off + conn.back.items.len);

    // Phase 2: cross-arm from outside the loop's own dispatch — enqueue a
    // bootstrap fetch on the quiet connection's peer and arm it. The bytes
    // submit (held by the slow-reader backend) and count as pending outbound.
    const cross = try engine.fetch.prepareFetchSwissnum(allocator, &conn.peer.session_state, "beacon");
    try conn.peer.send(cross.message);
    loop.armOutbound(0);
    try std.testing.expect(conn.write_in_flight);
    const pending_after_arm = conn.front.items.len - conn.front_off + conn.back.items.len;
    try std.testing.expect(pending_after_arm > high_water);

    // Phase 3: the partner sends its next frame while the cross-armed write is
    // still unread. Its reply queues behind the frozen front, and the read
    // parks at the high-water mark — ADR-0042 holds for cross-armed bytes.
    CrossArmBackend.hold_sends = true;
    CrossArmBackend.chunks = &.{ client_ss.items, fetch_bytes.items };
    try std.testing.expectError(error.ScriptParked, loop.run(.{ .after_closed = 1 }));
    try std.testing.expect(conn.read == .parked);
    try std.testing.expect(conn.front.items.len - conn.front_off + conn.back.items.len > high_water);

    // Phase 4: the slow reader drains and the script ends. The parked read
    // resumes, meets the clean EOF, and the connection closes whole — every
    // in-flight op retired, so `deinit`'s accounting stays green.
    CrossArmBackend.hold_sends = false;
    CrossArmBackend.eof_when_exhausted = true;
    try loop.run(.{ .after_closed = 1 });
    try std.testing.expectEqual(@as(usize, 1), loop.closed_count);
}
