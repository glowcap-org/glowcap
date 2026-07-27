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
const fetch_pump = @import("../support/fetch_pump.zig");
const handshake = @import("../support/handshake.zig");
const no_dial = @import("../support/no_dial_locator.zig");

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
    // `run` returns on the close count alone and leaves any other slot's armed
    // recv in flight, which `deinit` refuses to free. Drain here, on the
    // loop-owner thread, exactly as `closeAndDrain` documents for an early
    // `run` return.
    loop.closeAndDrain() catch |err| {
        // The run's error is the cause; the drain's is usually its consequence.
        if (out_err.* == null) out_err.* = err;
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
    /// Set once the loop asks `poll` to wait a bounded time rather than block.
    /// A deadline the loop enforces only after the poll cannot fire on a quiet
    /// connection, because that connection is the one producing no
    /// completions, so the wait itself has to carry it.
    var saw_bounded_poll: bool = false;
    /// When set, the next released send reports this many bytes instead of the
    /// whole buffer, so a test can drive `onSend`'s partial-write branch.
    var partial_send_bytes: usize = 0;

    const Held = struct { user_data: u64, len: usize };

    chunk_idx: usize = 0,
    accepted: bool = false,
    pending_recv: ?u64 = null,
    submitted_bytes: usize = 0,
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
        // Totalled, so a test can assert that bytes the loop queued actually
        // reached a submit rather than being dropped with the connection.
        self.submitted_bytes += bytes.len;
        self.held[self.held_len] = .{ .user_data = user_data, .len = bytes.len };
        self.held_len += 1;
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
                self.push(.{ .user_data = user_data, .result = @intCast(chunk.len), .recv_bytes = chunk });
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

test "close-slot: terminal drain ignores a late completion from the already-armed recv" {
    const allocator = std.testing.allocator;

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
    });
    defer loop.deinit();

    // Reach the quiet steady state: the handshake is open and one recv is
    // armed with no completion behind it.
    try std.testing.expectError(error.ScriptParked, loop.run(.{ .after_closed = 1 }));
    const conn = &loop.conns[0];
    try std.testing.expect(conn.state == .open);
    try std.testing.expect(conn.read == .armed);

    // A bridge-style close projects its final abort while that recv remains
    // armed. Hold the abort send, then let a valid deliver complete the old
    // recv. The terminal lifecycle must recycle/drop it, not apply it and
    // queue a reply behind the abort.
    try conn.peer.sendCopying(.{ .abort = .{
        .kind = .graceful_shutdown,
        .message = "done",
    } });
    CrossArmBackend.hold_sends = true;
    loop.closeSlot(0);
    try std.testing.expect(conn.state == .draining);
    try std.testing.expect(conn.write_in_flight);
    try std.testing.expectEqual(@as(usize, 0), conn.back.items.len);

    CrossArmBackend.chunks = &.{ client_ss.items, fetch_bytes.items };
    try std.testing.expectError(error.ScriptParked, loop.run(.{ .after_closed = 1 }));
    try std.testing.expect(conn.state == .draining);
    try std.testing.expect(conn.read == .idle);
    try std.testing.expectEqual(@as(usize, 0), conn.back.items.len);
    try std.testing.expect(conn.peer.pollEvent() == null);

    // Once the already-frozen abort drains, close follows immediately; the
    // late frame never caused a read re-arm or an extra outbound submit.
    CrossArmBackend.hold_sends = false;
    try loop.run(.{ .after_closed = 1 });
    try std.testing.expectEqual(@as(usize, 1), loop.closed_count);
}

test "close-slot: the terminal drain is bounded out of the box" {
    // No production path sets `park_kill_ms` — not the Host bridge, not
    // `net.TcpLoop`, not the iroh loop — so a drain bound that had to be
    // opted into would be a bound nothing ever applied. The default is the
    // whole guarantee: a partner that never reads an abort cannot pin a slot,
    // its fd, its peer, and its queues for the loop's lifetime.
    const defaults: completion.Options = .{ .frame_cap = frame_cap, .max_conns = 1, .listen = 0 };
    try std.testing.expect(defaults.drain_kill_ms != null);
}

test "cross-arm: a partial write that drains under the mark clears the deadline" {
    const allocator = std.testing.allocator;

    // The reaper trusts the stamp rather than re-reading the queue, so every
    // path that moves the queue owes it a refresh. `onSend`'s partial-write
    // branch resubmits the remainder and returns; if it skips the refresh, a
    // partner that is demonstrably draining our bytes still looks stalled and
    // can be reclaimed.
    var client = engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = false });
    defer client.deinit();
    client.session_state.limits.max_frame_bytes = frame_cap;
    var client_ss: std.ArrayList(u8) = .empty;
    defer client_ss.deinit(allocator);
    try client.sendCopying(startSession("client"));
    try drainOutboundBytes(&client, allocator, &client_ss);

    CrossArmBackend.chunks = &.{client_ss.items};
    CrossArmBackend.hold_sends = true;
    CrossArmBackend.eof_when_exhausted = false;
    CrossArmBackend.partial_send_bytes = 0;
    defer {
        CrossArmBackend.chunks = &.{};
        CrossArmBackend.hold_sends = false;
        CrossArmBackend.eof_when_exhausted = false;
        CrossArmBackend.partial_send_bytes = 0;
    }

    // A high-water mark below the server hello, so the connection parks as a
    // sink the moment it is served, and a finite park budget so the park is
    // stamped at all.
    var loop = try completion.Loop(CrossArmBackend, no_dial.Unsupported).init(allocator, makeServerPeer, null, .{
        .frame_cap = frame_cap,
        .max_conns = 4,
        .listen = 0,
        .outbound_high_water = 16,
        .park_kill_ms = 60_000,
    });
    defer loop.deinit();

    try std.testing.expectError(error.ScriptParked, loop.run(.{ .after_closed = 1 }));
    const conn = &loop.conns[0];
    try std.testing.expect(conn.read == .parked);
    try std.testing.expect(conn.waiting_since_ms != 0);
    try std.testing.expectEqual(@as(usize, 1), loop.waiting_count);

    // The partner takes all but four bytes. Pending falls under the mark, so
    // this connection is no longer the slow reader the deadline is about.
    CrossArmBackend.partial_send_bytes = conn.front.items.len - 4;
    CrossArmBackend.hold_sends = false;
    try std.testing.expectError(error.ScriptParked, loop.run(.{ .after_closed = 1 }));
    try std.testing.expectEqual(@as(i64, 0), conn.waiting_since_ms);
    try std.testing.expectEqual(@as(usize, 0), loop.waiting_count);
    // And the read is armed again, which is the part that matters: dropping
    // the deadline without re-arming would leave this connection with no
    // wakeup at all if the resubmitted remainder never completed.
    try std.testing.expect(conn.read == .armed);

    // Let the resubmitted remainder and the connection retire, so `deinit`
    // sees no op in flight.
    CrossArmBackend.hold_sends = false;
    CrossArmBackend.eof_when_exhausted = true;
    try loop.run(.{ .after_closed = 1 });
    try std.testing.expectEqual(@as(usize, 1), loop.closed_count);
}

test "close-slot: the deadline count tracks only connections actually waiting" {
    const allocator = std.testing.allocator;

    var client = engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = false });
    defer client.deinit();
    client.session_state.limits.max_frame_bytes = frame_cap;
    var client_ss: std.ArrayList(u8) = .empty;
    defer client_ss.deinit(allocator);
    try client.sendCopying(startSession("client"));
    try drainOutboundBytes(&client, allocator, &client_ss);

    CrossArmBackend.chunks = &.{client_ss.items};
    CrossArmBackend.hold_sends = false;
    CrossArmBackend.eof_when_exhausted = false;
    defer {
        CrossArmBackend.chunks = &.{};
        CrossArmBackend.hold_sends = false;
        CrossArmBackend.eof_when_exhausted = false;
    }

    const LoopType = completion.Loop(CrossArmBackend, no_dial.Unsupported);
    var loop = try completion.Loop(CrossArmBackend, no_dial.Unsupported).init(allocator, makeServerPeer, null, .{
        .frame_cap = frame_cap,
        .max_conns = 4,
        .listen = 0,
    });
    defer loop.deinit();

    // An open, handshaken connection with nobody waiting. The count is what
    // keeps both `O(max_conns)` deadline sweeps off the poll path: guarded on
    // the options alone they would run every poll, because `drain_kill_ms` is
    // finite by default. This pins the count itself; the guard reading it is
    // one line, and the cost it avoids is `max_conns` cold reads per poll at
    // the 500k destination.
    try std.testing.expectError(error.ScriptParked, loop.run(.{ .after_closed = 1 }));
    try std.testing.expect(loop.conns[0].state == .open);
    // The count is the assertion. `nextDeadlineMs` returns null on a zero
    // count as its first statement, so asking it as well restates the line
    // above and cannot fail independently of it.
    try std.testing.expectEqual(@as(usize, 0), loop.waiting_count);

    // The count tracks the terminal wait, and gives it back at close. The
    // abort is what makes the close wait at all: with nothing to flush,
    // `closeSlot` closes outright and never enters `.draining`.
    try loop.conns[0].peer.sendCopying(.{ .abort = .{
        .kind = .graceful_shutdown,
        .message = "done",
    } });
    CrossArmBackend.hold_sends = true;
    loop.closeSlot(0);
    try std.testing.expect(loop.conns[0].state == .draining);
    try std.testing.expectEqual(@as(usize, 1), loop.waiting_count);
    try std.testing.expect(LoopType.white_box.nextDeadlineMs(&loop) != null);

    CrossArmBackend.hold_sends = false;
    CrossArmBackend.eof_when_exhausted = true;
    try loop.run(.{ .after_closed = 1 });
    try std.testing.expectEqual(@as(usize, 1), loop.closed_count);
    try std.testing.expectEqual(@as(usize, 0), loop.waiting_count);
}

test "close-slot: a terminal drain the partner never reads is reclaimed, not pinned" {
    const allocator = std.testing.allocator;

    var client = engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = false });
    defer client.deinit();
    client.session_state.limits.max_frame_bytes = frame_cap;
    var client_ss: std.ArrayList(u8) = .empty;
    defer client_ss.deinit(allocator);
    try client.sendCopying(startSession("client"));
    try drainOutboundBytes(&client, allocator, &client_ss);

    CrossArmBackend.chunks = &.{client_ss.items};
    CrossArmBackend.hold_sends = false;
    CrossArmBackend.eof_when_exhausted = false;
    CrossArmBackend.saw_bounded_poll = false;
    defer {
        CrossArmBackend.chunks = &.{};
        CrossArmBackend.hold_sends = false;
        CrossArmBackend.eof_when_exhausted = false;
        CrossArmBackend.saw_bounded_poll = false;
    }

    const LoopType = completion.Loop(CrossArmBackend, no_dial.Unsupported);
    var loop = try completion.Loop(CrossArmBackend, no_dial.Unsupported).init(allocator, makeServerPeer, null, .{
        .frame_cap = frame_cap,
        .max_conns = 4,
        .listen = 0,
        // Reclaim as soon as a reap runs after the wait begins. Deliberately
        // leaves `park_kill_ms` at its `null` default: the drain bound must
        // hold on its own, because no production path sets the park option.
        .drain_kill_ms = 0,
    });
    defer loop.deinit();

    try std.testing.expectError(error.ScriptParked, loop.run(.{ .after_closed = 1 }));
    const conn = &loop.conns[0];
    try std.testing.expect(conn.state == .open);

    // Condemn the connection with its abort held at the backend: the partner
    // is not reading, so the send completion never arrives. Without the
    // drain deadline the slot stays `.draining` for the loop's lifetime.
    try conn.peer.sendCopying(.{ .abort = .{
        .kind = .graceful_shutdown,
        .message = "done",
    } });
    CrossArmBackend.hold_sends = true;
    loop.closeSlot(0);
    try std.testing.expect(conn.state == .draining);
    try std.testing.expect(conn.write_in_flight);

    // The wait itself must carry the deadline. A loop that blocks forever
    // here reaps only when some unrelated connection produces a completion,
    // which on a quiet loop never happens.
    try std.testing.expect(LoopType.white_box.nextDeadlineMs(&loop) != null);

    // The reap runs after a poll batch, so give the loop one completion to
    // process. It lands on the drained read seat and is dropped; the reap
    // that follows is what must claim the stuck drain.
    CrossArmBackend.chunks = &.{ client_ss.items, client_ss.items };
    try std.testing.expectError(error.ScriptParked, loop.run(.{ .after_closed = 1 }));
    // The loop asked to be woken rather than blocking: without this the
    // deadline can only fire when unrelated traffic happens to arrive.
    try std.testing.expect(CrossArmBackend.saw_bounded_poll);
    try std.testing.expect(conn.state == .closing);
    try std.testing.expectEqual(completion.CloseReason.drain_kill, conn.close_reason);

    // Releasing the kernel's borrow retires the last op and reclaims the slot.
    CrossArmBackend.hold_sends = false;
    try loop.run(.{ .after_closed = 1 });
    try std.testing.expectEqual(@as(usize, 1), loop.closed_count);
}

test "close-slot: a second close on a draining connection escalates to a hard close" {
    const allocator = std.testing.allocator;

    var client = engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = false });
    defer client.deinit();
    client.session_state.limits.max_frame_bytes = frame_cap;
    var client_ss: std.ArrayList(u8) = .empty;
    defer client_ss.deinit(allocator);
    try client.sendCopying(startSession("client"));
    try drainOutboundBytes(&client, allocator, &client_ss);

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
    });
    defer loop.deinit();

    try std.testing.expectError(error.ScriptParked, loop.run(.{ .after_closed = 1 }));
    const conn = &loop.conns[0];

    try conn.peer.sendCopying(.{ .abort = .{
        .kind = .graceful_shutdown,
        .message = "done",
    } });
    CrossArmBackend.hold_sends = true;
    loop.closeSlot(0);
    try std.testing.expect(conn.state == .draining);

    // No deadline is configured here, so the caller's own second request is
    // the escape hatch: it must close rather than silently do nothing.
    loop.closeSlot(0);
    try std.testing.expect(conn.state == .closing);

    // The shutdown is why that escalation works on a real backend: it
    // completes the armed recv at once instead of waiting on a quiet partner.
    // This scripted backend models that as the read reaching end of stream.
    CrossArmBackend.eof_when_exhausted = true;
    CrossArmBackend.hold_sends = false;
    try loop.run(.{ .after_closed = 1 });
    try std.testing.expectEqual(@as(usize, 1), loop.closed_count);
}

test "cross-arm: a terminal failure with a write in flight swaps its queued tail out" {
    const allocator = std.testing.allocator;

    // `onSend`'s `.draining` arm is the only path that swaps a terminal
    // connection's back buffer into its emptied front. Reaching it needs three
    // things at once — the connection draining, a write still in flight, and
    // bytes queued behind it — and a connection normally has at most two of
    // them, which is why the arm went unexercised. Scripted, the overlap is
    // stated rather than waited for.
    var client = engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = false });
    defer client.deinit();
    client.session_state.limits.max_frame_bytes = frame_cap;
    var client_ss: std.ArrayList(u8) = .empty;
    defer client_ss.deinit(allocator);
    try client.sendCopying(startSession("client"));
    try drainOutboundBytes(&client, allocator, &client_ss);

    // Hello, then bytes the session refuses. The refusal projects an abort
    // while the hello's reply is still held, so the abort has nowhere to go but
    // the back buffer.
    const refused = [_]u8{0xff} ** 24;
    CrossArmBackend.chunks = &.{ client_ss.items, refused[0..] };
    CrossArmBackend.hold_sends = true;
    CrossArmBackend.eof_when_exhausted = false;
    CrossArmBackend.partial_send_bytes = 0;
    defer {
        CrossArmBackend.chunks = &.{};
        CrossArmBackend.hold_sends = false;
        CrossArmBackend.eof_when_exhausted = false;
        CrossArmBackend.partial_send_bytes = 0;
    }

    var loop = try completion.Loop(CrossArmBackend, no_dial.Unsupported).init(allocator, makeServerPeer, null, .{
        .frame_cap = frame_cap,
        .max_conns = 4,
        .listen = 0,
        // Above the reply, so the connection does *not* park and its read
        // re-arms — otherwise the refused frame never arrives and the overlap
        // never forms.
        .outbound_high_water = 4096,
        .park_kill_ms = 60_000,
    });
    defer loop.deinit();

    try std.testing.expectError(error.ScriptParked, loop.run(.{ .after_closed = 1 }));
    const conn = &loop.conns[0];
    // The overlap the arm needs: terminal, mid-write, and holding a tail.
    try std.testing.expect(conn.state == .draining);
    try std.testing.expect(conn.write_in_flight);
    try std.testing.expect(conn.back.items.len > 0);

    const reply_bytes = conn.front.items.len;
    const tail_bytes = conn.back.items.len;

    // Release the held write. The arm empties the front, swaps the tail in, and
    // submits it — so the abort the partner is owed actually goes out instead
    // of being dropped with the connection.
    CrossArmBackend.hold_sends = false;
    CrossArmBackend.eof_when_exhausted = true;
    try loop.run(.{ .after_closed = 1 });
    try std.testing.expectEqual(@as(usize, 1), loop.closed_count);
    try std.testing.expectEqual(@as(usize, 0), loop.live_count);
    // Both the reply and the tail behind it were submitted. Counting the bytes
    // is what holds the swap: reaching the arm proves nothing if the assertions
    // are true whether or not the tail ever goes out.
    try std.testing.expectEqual(reply_bytes + tail_bytes, loop.backend.submitted_bytes);
}
