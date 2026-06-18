//! The completion `Loop`, proven end to end on its platform backend, and the
//! outbound-backpressure contract, proven on a scripted fake backend.
//!
//! One single-threaded `net.Loop` (the portable `completion.Loop` over the
//! platform backend) accepts several concurrent connections and serves the
//! bootstrap-fetch scenario on each — the same handshake-to-open plus
//! `fetch`/auto-`resolve` round-trip the blocking `tcp_test` proves, now driven by
//! kernel completions instead of a blocking pump. Several clients dial at once, so
//! the multiplexing (many connections, one loop, one thread) is exercised, not
//! just the single-connection path. The loop logic under test is OS-neutral; only
//! the backend beneath it is io_uring or kqueue.
//!
//! The backpressure test exploits the same genericity the platform backends do:
//! a fake backend scripts a slow reader (writes complete only when the loop has
//! nothing else to do) and journals every submit, so the exact park/resume order
//! ADR-0042 promises is asserted deterministically, with no sockets and no
//! timing, on every platform.

const std = @import("std");
const builtin = @import("builtin");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const tcp = pancake.net.tcp;
const Loop = pancake.net.Loop;
const completion = pancake.net.completion;
const fetch_pump = @import("../support/fetch_pump.zig");
const handshake = @import("../support/handshake.zig");

const frame_cap = 4096;
const client_count = 8;

fn startSession(designator: []const u8) model.Message {
    return handshake.startSession(tcp.transport_name, designator);
}

/// Build the server-side peer for one accepted connection: handshake verification
/// off (the loopback stub uses zero signatures), publish the shared `thermostat`
/// bootstrap cap, and queue the opening `op:start-session`.
fn makeServerPeer(ctx: ?*anyopaque, allocator: std.mem.Allocator) anyerror!engine.Peer {
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
fn fetchOnce(io: std.Io, port: u16, allocator: std.mem.Allocator) anyerror!void {
    var peer = engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = false });
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    var designator_buf: [64]u8 = undefined;
    const designator = try std.fmt.bufPrint(&designator_buf, "127.0.0.1:{d}", .{port});
    const locator: model.PeerLocator = .{
        .transport = tcp.transport_name,
        .designator = designator,
        .hints = model.Hints.emptyMap(),
    };
    var conn = try tcp.connect(io, &peer, locator, read_buf, write_buf);
    defer conn.deinit();

    try fetch_pump.handshakeToOpen(&peer, &conn, startSession("client"));

    const reference = try fetch_pump.settleFetch(allocator, &peer, &conn, "thermostat");
    model.freeReference(allocator, reference);
}

fn runLoop(loop: *Loop, until_closed: usize) void {
    loop.run(.{ .after_closed = until_closed }) catch {};
}

test "completion loop: concurrent clients each fetch the shared bootstrap cap" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    var loop = try Loop.init(allocator, makeServerPeer, null, .{
        .frame_cap = frame_cap,
        .max_conns = 64,
        .listen = 0,
    });
    defer loop.deinit();
    const port = loop.port.?;

    // The completion loop runs on its own thread; the clients drive a std.Io
    // backend on this thread, dialing concurrently.
    const loop_thread = try std.Thread.spawn(.{}, runLoop, .{ &loop, @as(usize, client_count) });

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var futures: [client_count]std.Io.Future(anyerror!void) = undefined;
    for (&futures) |*f| {
        f.* = try io.concurrent(fetchOnce, .{ io, port, allocator });
    }
    var first_err: ?anyerror = null;
    for (&futures) |*f| {
        f.await(io) catch |err| {
            if (first_err == null) first_err = err;
        };
    }

    loop_thread.join();
    if (first_err) |err| return err;
}

const actors = pancake.actors;

/// The object hosted on the loop: answers `greet(name)` with a greeting built in
/// the turn arena. This is an ordinary `actors` behavior — the same kind the
/// blocking driver runs — now running on the completion loop.
const Greeter = struct {
    pub fn handle(self: *Greeter, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        if (!std.mem.eql(u8, msg.verb, "greet")) return error.NoSuchMethod;
        return .{ .string = try std.fmt.allocPrint(turn.arena, "hi from the loop", .{}) };
    }
};

/// The per-connection context the loop hosts: a vat bound to the connection's
/// peer, with a `Greeter` published as the `thermostat` bootstrap cap. This is
/// what `net` cannot build itself (it owns no actor layer) and the loop
/// carries through an opaque pointer.
const LoopVat = struct {
    vat: actors.Vat,

    fn make(ctx: ?*anyopaque, peer: *engine.Peer) anyerror!?*anyopaque {
        const allocator: *const std.mem.Allocator = @ptrCast(@alignCast(ctx.?));
        const self = try allocator.create(LoopVat);
        errdefer allocator.destroy(self);
        self.vat = actors.Vat.initOver(allocator.*, peer);
        // Spawn the actor and publish it at the bootstrap swissnum the client
        // fetches — exactly `driver.ConnectedVat.publish`, now on the loop.
        const greeter = try self.vat.spawn(Greeter, .{});
        const position = try peer.registerBootstrapCap("thermostat");
        try self.vat.bindExport(greeter, position);
        return self;
    }

    fn serve(conn_ctx: ?*anyopaque, peer: *engine.Peer, event: *engine.Event) anyerror!void {
        _ = peer;
        const self: *LoopVat = @ptrCast(@alignCast(conn_ctx.?));
        _ = try self.vat.serve(event);
    }

    fn free(ctx: ?*anyopaque, conn_ctx: ?*anyopaque) void {
        const allocator: *const std.mem.Allocator = @ptrCast(@alignCast(ctx.?));
        const self: *LoopVat = @ptrCast(@alignCast(conn_ctx.?));
        self.vat.deinit();
        allocator.destroy(self);
    }
};

/// A peer for a loop connection that hosts a vat: negotiating, the actor is
/// published by `LoopVat.make` (not here), and the opening start-session is
/// queued. `registerBootstrapCap` is left to the vat so the export position and
/// the actor are bound together.
fn makeVatHostPeer(ctx: ?*anyopaque, allocator: std.mem.Allocator) anyerror!engine.Peer {
    _ = ctx;
    var peer = engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = false });
    errdefer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;
    try peer.sendCopying(startSession("server"));
    return peer;
}

/// One client: handshake, fetch the loop-hosted `thermostat`, then *call*
/// `greet` on it and assert the reply comes back — over the completion loop.
fn fetchThenCall(io: std.Io, port: u16, allocator: std.mem.Allocator) anyerror!void {
    var peer = engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = false });
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    var designator_buf: [64]u8 = undefined;
    const designator = try std.fmt.bufPrint(&designator_buf, "127.0.0.1:{d}", .{port});
    const locator: model.PeerLocator = .{
        .transport = tcp.transport_name,
        .designator = designator,
        .hints = model.Hints.emptyMap(),
    };
    var conn = try tcp.connect(io, &peer, locator, read_buf, write_buf);
    defer conn.deinit();

    var vat = actors.Vat.initOver(allocator, &peer);
    defer vat.deinit();

    try fetch_pump.handshakeToOpen(&peer, &conn, startSession("client"));

    const reference = try fetch_pump.settleFetch(allocator, &peer, &conn, "thermostat");
    const cap = reference.far;
    model.freeReference(allocator, reference);

    // Call the loop-hosted object and pump until the reply settles.
    const State = struct {
        done: bool = false,
        ok: bool = false,
        fn onReply(c: ?*anyopaque, resolution: actors.Resolution) void {
            const s: *@This() = @ptrCast(@alignCast(c.?));
            s.done = true;
            s.ok = switch (resolution) {
                .fulfilled => |arg| arg == .string and std.mem.eql(u8, arg.string, "hi from the loop"),
                .broken => false,
            };
        }
    };
    var state = State{};
    const promise = try vat.send(.{ .far = cap }, .{ .verb = "greet", .args = &.{.{ .string = "x" }} });
    try vat.on(promise, .{ .ctx = &state, .func = State.onReply });

    var spins: usize = 0;
    while (!state.done and spins < 10_000) : (spins += 1) {
        const progress = try conn.pump();
        while (peer.pollEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();
            _ = try vat.serve(&event);
        }
        if (progress == .closed) break;
    }
    try std.testing.expect(state.done);
    try std.testing.expect(state.ok);
}

test "completion loop: a hosted actor answers a call over the loop (objects on the scalable path)" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    // make_ctx carries the allocator the per-connection vat builders use; its
    // address must outlive the loop, so it lives in this test frame.
    var ctx_alloc = allocator;

    var loop = try Loop.init(allocator, makeVatHostPeer, @ptrCast(&ctx_alloc), .{
        .frame_cap = frame_cap,
        .max_conns = 16,
        .listen = 0,
        .make_conn_ctx = LoopVat.make,
        .serve = LoopVat.serve,
        .free_conn_ctx = LoopVat.free,
    });
    defer loop.deinit();
    const port = loop.port.?;

    const clients = 6;
    var loop_err: ?anyerror = null;
    const loop_thread = try std.Thread.spawn(.{}, runLoopCapturing, .{ &loop, @as(usize, clients), &loop_err });

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var futures: [clients]std.Io.Future(anyerror!void) = undefined;
    for (&futures) |*f| f.* = try io.concurrent(fetchThenCall, .{ io, port, allocator });
    var first_err: ?anyerror = null;
    for (&futures) |*f| f.await(io) catch |err| {
        if (first_err == null) first_err = err;
    };

    loop_thread.join();
    if (loop_err) |err| return err;
    if (first_err) |err| return err;
}

fn runLoopCapturing(loop: *Loop, until_closed: usize, out_err: *?anyerror) void {
    loop.run(.{ .after_closed = until_closed }) catch |err| {
        out_err.* = err;
    };
}

test "completion loop: churns hundreds of connection lifecycles through a small slot pool" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    // Heavy reuse on purpose: more lifecycles than slots, in waves, so each
    // slot is torn down and re-accepted many times. This is the real stress of
    // the deferred-teardown + slot-reuse machinery the unit path only grazes —
    // if teardown ever stranded a slot (the io_uring/kqueue close-while-recv-armed
    // bug class), the pool would fill, later accepts would be refused, and the
    // clients in a later wave would fail to fetch.
    const per_wave = 40;
    const waves = 12;
    const total = per_wave * waves; // 480 connection lifecycles
    const max_conns = 56; // < concurrent-peak's headroom, so slots recycle across waves

    var loop = try Loop.init(allocator, makeServerPeer, null, .{
        .frame_cap = frame_cap,
        .max_conns = max_conns,
        .listen = 0,
        // A deliberately tiny ring: one dispatch batch arms far more
        // operations than eight SQ entries hold, so this churn also pins the
        // io_uring backend's submission-queue self-healing — without the
        // mid-batch flush in `getSqe`, a full queue would close healthy
        // connections (or kill the accept re-arm, and with it the loop) long
        // before the waves complete. kqueue ignores the hint.
        .queue_entries = 8,
    });
    defer loop.deinit();
    const port = loop.port.?;

    var loop_err: ?anyerror = null;
    const loop_thread = try std.Thread.spawn(.{}, runLoopCapturing, .{ &loop, @as(usize, total), &loop_err });

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var served: usize = 0;
    var first_err: ?anyerror = null;
    var wave: usize = 0;
    while (wave < waves) : (wave += 1) {
        var futures: [per_wave]std.Io.Future(anyerror!void) = undefined;
        for (&futures) |*f| f.* = try io.concurrent(fetchOnce, .{ io, port, allocator });
        for (&futures) |*f| {
            if (f.await(io)) |_| {
                served += 1;
            } else |err| {
                if (first_err == null) first_err = err;
            }
        }
    }

    loop_thread.join();
    if (loop_err) |err| return err;
    if (first_err) |err| return err;
    // Every lifecycle completed: no slot was stranded, no client was refused.
    try std.testing.expectEqual(@as(usize, total), served);
}

/// One abrupt client: connect a real socket and drop it immediately, without
/// handshaking. The server accepts, arms a recv, and has its opening
/// `op:start-session` send pending — so the close lands while ops are in flight.
/// This is the exact teardown path the io_uring/kqueue close-while-recv-armed
/// bugs lived in; under churn it must drain both ops and reclaim the slot, never
/// strand or crash.
fn slamOnce(io: std.Io, port: u16, allocator: std.mem.Allocator) anyerror!void {
    var peer = engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = false });
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    var designator_buf: [64]u8 = undefined;
    const designator = try std.fmt.bufPrint(&designator_buf, "127.0.0.1:{d}", .{port});
    const locator: model.PeerLocator = .{
        .transport = tcp.transport_name,
        .designator = designator,
        .hints = model.Hints.emptyMap(),
    };
    var conn = tcp.connect(io, &peer, locator, read_buf, write_buf) catch return;
    // Drop without handshaking: the defer closes the socket while the server
    // still has a recv armed and its start-session send pending.
    conn.deinit();
}

test "completion loop: survives abrupt mid-handshake drops under churn (close-while-op-armed)" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    const per_wave = 40;
    const waves = 12;
    const total = per_wave * waves; // 480 abrupt lifecycles
    const max_conns = 56;

    var loop = try Loop.init(allocator, makeServerPeer, null, .{
        .frame_cap = frame_cap,
        .max_conns = max_conns,
        .listen = 0,
    });
    defer loop.deinit();
    const port = loop.port.?;

    var loop_err: ?anyerror = null;
    const loop_thread = try std.Thread.spawn(.{}, runLoopCapturing, .{ &loop, @as(usize, total), &loop_err });

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var wave: usize = 0;
    while (wave < waves) : (wave += 1) {
        var futures: [per_wave]std.Io.Future(anyerror!void) = undefined;
        for (&futures) |*f| f.* = try io.concurrent(slamOnce, .{ io, port, allocator });
        for (&futures) |*f| f.await(io) catch {};
    }

    // The loop must process every abrupt close as a completed lifecycle and
    // terminate — if any close stranded its slot, `run(total)` would block
    // forever and join would hang the test rather than return.
    loop_thread.join();
    if (loop_err) |err| return err;
    try std.testing.expectEqual(@as(usize, total), loop.closed_count);
}

/// The backend-visible actions the fake journals. Their order *is* the
/// backpressure contract: a `recv_armed` may not appear while pending outbound
/// sits past the high-water mark.
const FakeEvent = enum { send_submitted, send_released, recv_armed };

/// A scripted completion backend: each armed recv synchronously delivers the
/// next chunk of `chunks` as a borrowed completion view (a clean EOF past the
/// end), and every submitted send is *held* — the partner is a slow reader —
/// completing only when the loop has nothing else to do (`poll` with an empty
/// ready queue). If the loop parks its read behind a held write, the journal
/// shows the send release strictly before the next `recv_armed`; if parking
/// were broken, the read would arm first and the journal order would flip.
/// The backend also counts pool traffic (`handed` / `recycles`) so tests can
/// assert every successful recv's buffer is recycled exactly once.
const FakeBackend = struct {
    pub const Fd = i32;

    /// The inbound wire script, set by the test before `Loop.init`.
    var chunks: []const []const u8 = &.{};

    chunk_idx: usize = 0,
    pool_free: usize = 0,
    handed: usize = 0,
    recycles: usize = 0,
    ready: [8]completion.Completion = undefined,
    ready_len: usize = 0,
    held_send: ?struct { user_data: u64, len: usize } = null,
    accepted: bool = false,
    journal: [16]FakeEvent = undefined,
    journal_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, queue_entries: u16, read_buffers: u16, read_buffer_bytes: u32) !FakeBackend {
        _ = allocator;
        _ = queue_entries;
        _ = read_buffer_bytes;
        return .{ .pool_free = read_buffers };
    }

    pub fn deinit(self: *FakeBackend) void {
        self.* = .{ .pool_free = 0 };
    }

    pub fn openListener(port: u16) !Fd {
        _ = port;
        return 1;
    }

    pub fn boundPort(fd: Fd) !u16 {
        _ = fd;
        return 1;
    }

    pub fn closeFd(fd: Fd) void {
        _ = fd;
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
        // One scripted connection; the loop's re-armed accept pends forever.
        if (self.accepted) return;
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
            self.push(.{ .user_data = user_data, .result = @intCast(chunk.len), .recv_bytes = chunk });
        } else {
            self.push(.{ .user_data = user_data, .result = 0 }); // clean EOF
        }
    }

    pub fn recycleRecv(self: *FakeBackend, comp: completion.Completion) void {
        _ = comp;
        self.recycles += 1;
        self.pool_free += 1;
    }

    pub fn submitSend(self: *FakeBackend, user_data: u64, fd: Fd, bytes: []const u8) !void {
        _ = fd;
        self.record(.send_submitted);
        self.held_send = .{ .user_data = user_data, .len = bytes.len };
    }

    pub fn submitClose(self: *FakeBackend, user_data: u64, fd: Fd) !void {
        _ = fd;
        self.push(.{ .user_data = user_data, .result = 0 });
    }

    pub fn poll(self: *FakeBackend, out: []completion.Completion) !usize {
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

/// Encode `peer`'s queued sends and append their frame bytes to `sink`.
fn drainOutboundBytes(peer: *engine.Peer, allocator: std.mem.Allocator, sink: *std.ArrayList(u8)) !void {
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_value| {
        var frame = frame_value;
        defer frame.deinit();
        try sink.appendSlice(allocator, frame.bytes());
    }
}

/// A scripted backend hosting two connections where the first is a bad
/// partner: every send submission on its fd fails. The second connection's
/// inbound script (`chunks`) is a full bootstrap-fetch conversation. The loop
/// must close the failing connection and keep serving the healthy one.
const OneBadPartnerBackend = struct {
    pub const Fd = i32;

    const refused_fd: Fd = 100;
    const ok_fd: Fd = 200;

    /// The healthy connection's inbound wire script, set before `Loop.init`.
    var chunks: []const []const u8 = &.{};

    accepts: usize = 0,
    chunk_idx: usize = 0,
    sends_ok: usize = 0,
    sends_refused: usize = 0,
    pool_free: usize = 0,
    handed: usize = 0,
    recycles: usize = 0,
    ready: [16]completion.Completion = undefined,
    ready_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, queue_entries: u16, read_buffers: u16, read_buffer_bytes: u32) !OneBadPartnerBackend {
        _ = allocator;
        _ = queue_entries;
        _ = read_buffer_bytes;
        return .{ .pool_free = read_buffers };
    }

    pub fn deinit(self: *OneBadPartnerBackend) void {
        self.* = .{ .pool_free = 0 };
    }

    pub fn openListener(port: u16) !Fd {
        _ = port;
        return 1;
    }

    pub fn boundPort(fd: Fd) !u16 {
        _ = fd;
        return 1;
    }

    pub fn closeFd(fd: Fd) void {
        _ = fd;
    }

    fn push(self: *OneBadPartnerBackend, c: completion.Completion) void {
        self.ready[self.ready_len] = c;
        self.ready_len += 1;
    }

    pub fn submitAccept(self: *OneBadPartnerBackend, user_data: u64, listen_fd: Fd) !void {
        _ = listen_fd;
        // Two scripted connections; the loop's later re-arms pend forever.
        if (self.accepts >= 2) return;
        self.accepts += 1;
        const fd: Fd = if (self.accepts == 1) refused_fd else ok_fd;
        self.push(.{ .user_data = user_data, .result = fd });
    }

    pub fn submitRecv(self: *OneBadPartnerBackend, user_data: u64, fd: Fd) !void {
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
            self.push(.{ .user_data = user_data, .result = @intCast(chunk.len), .recv_bytes = chunk });
        } else {
            self.push(.{ .user_data = user_data, .result = 0 }); // clean EOF
        }
    }

    pub fn recycleRecv(self: *OneBadPartnerBackend, comp: completion.Completion) void {
        _ = comp;
        self.recycles += 1;
        self.pool_free += 1;
    }

    pub fn submitSend(self: *OneBadPartnerBackend, user_data: u64, fd: Fd, bytes: []const u8) !void {
        if (fd == refused_fd) {
            self.sends_refused += 1;
            return error.SendRefused;
        }
        self.sends_ok += 1;
        self.push(.{ .user_data = user_data, .result = @intCast(bytes.len) });
    }

    pub fn submitClose(self: *OneBadPartnerBackend, user_data: u64, fd: Fd) !void {
        _ = fd;
        self.push(.{ .user_data = user_data, .result = 0 });
    }

    pub fn poll(self: *OneBadPartnerBackend, out: []completion.Completion) !usize {
        // The loop stalled with no completion to deliver: a loop bug, fail loud.
        if (self.ready_len == 0) return error.FakeBackendStalled;
        const n = @min(out.len, self.ready_len);
        @memcpy(out[0..n], self.ready[0..n]);
        std.mem.copyForwards(completion.Completion, self.ready[0 .. self.ready_len - n], self.ready[n..self.ready_len]);
        self.ready_len -= n;
        return n;
    }
};

test "completion loop: a per-connection drive failure closes that connection, not the loop" {
    const allocator = std.testing.allocator;

    // Precompute the healthy partner's script: its start-session, then a fetch
    // of the shared bootstrap cap (prepared against the same start-session the
    // loop's server peer sends, so the fetch is admissible).
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

    OneBadPartnerBackend.chunks = &.{ client_ss.items, fetch_bytes.items };
    defer OneBadPartnerBackend.chunks = &.{};

    var loop = try completion.Loop(OneBadPartnerBackend).init(allocator, makeServerPeer, null, .{
        .frame_cap = frame_cap,
        .max_conns = 4,
        .listen = 0,
    });
    defer loop.deinit();

    // The first connection's opening start-session send fails at submit; the
    // loop must close only that connection and fully serve the second one.
    // Before the per-connection isolation fix, the first drive failure
    // propagated out of `run` and tore down every connection.
    try loop.run(.{ .after_closed = 2 });

    try std.testing.expectEqual(@as(usize, 2), loop.closed_count);
    // The bad partner's send was refused at least once.
    try std.testing.expect(loop.backend.sends_refused >= 1);
    // The healthy partner consumed its whole script (handshake and fetch) and
    // received replies: it was served to completion after the failure.
    try std.testing.expectEqual(@as(usize, 2), loop.backend.chunk_idx);
    try std.testing.expect(loop.backend.sends_ok >= 2);
    // Every successful recv's pool buffer was recycled exactly once.
    try std.testing.expectEqual(loop.backend.handed, loop.backend.recycles);
}

test "completion loop: outbound past the high-water mark parks reads until the partner drains" {
    const allocator = std.testing.allocator;

    // Precompute the wire script: the client's start-session, then a fetch of
    // the shared bootstrap cap, whose auto-resolve reply outgrows the mark.
    var client = engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = false });
    defer client.deinit();
    client.session_state.limits.max_frame_bytes = frame_cap;

    var client_ss: std.ArrayList(u8) = .empty;
    defer client_ss.deinit(allocator);
    try client.sendCopying(startSession("client"));
    try drainOutboundBytes(&client, allocator, &client_ss);

    // Open the client's session against the same start-session the loop's
    // server peer sends, so the fetch it prepares is admissible.
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

    // The mark sits far below one frame, so both the handshake reply and the
    // fetch reply must park the read — observable from the very first write.
    const high_water: usize = 16;
    try std.testing.expect(server_ss.items.len > high_water);

    FakeBackend.chunks = &.{ client_ss.items, fetch_bytes.items };
    defer FakeBackend.chunks = &.{};

    var loop = try completion.Loop(FakeBackend).init(allocator, makeServerPeer, null, .{
        .frame_cap = frame_cap,
        .max_conns = 4,
        .listen = 0,
        .outbound_high_water = high_water,
    });
    defer loop.deinit();

    try loop.run(.{ .after_closed = 1 });

    try std.testing.expectEqualSlices(FakeEvent, &[_]FakeEvent{
        .send_submitted, // accept: the server's start-session crosses the mark → read parks
        .send_released, // the partner drains; only now…
        .recv_armed, // …does the first read arm (delivers the client start-session)
        .recv_armed, // nothing pending → the next read arms (delivers the fetch)
        .send_submitted, // the fetch's auto-resolve crosses the mark → read parks again
        .send_released, // the partner drains again
        .recv_armed, // the read resumes; the script is spent → clean EOF → close
    }, loop.backend.journal[0..loop.backend.journal_len]);
    // Every successful recv's pool buffer was recycled exactly once.
    try std.testing.expectEqual(@as(usize, 2), loop.backend.handed);
    try std.testing.expectEqual(loop.backend.handed, loop.backend.recycles);
}

/// A scripted backend for the shared-pool contract (ADR-0054): every accepted
/// connection replays the same inbound `chunks` script, each chunk handed out
/// as a borrowed completion view from a pool of `read_buffers` buffers. A recv
/// armed while the pool is empty completes `recv_no_buffer` — exactly the
/// platform backends' starvation shape — and sends complete synchronously.
const ScriptBackend = struct {
    pub const Fd = i32;

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

    pub fn openListener(port: u16) !Fd {
        _ = port;
        return 1;
    }

    pub fn boundPort(fd: Fd) !u16 {
        _ = fd;
        return 1;
    }

    pub fn closeFd(fd: Fd) void {
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
            self.push(.{ .user_data = user_data, .result = @intCast(chunk.len), .recv_bytes = chunk });
        } else {
            self.push(.{ .user_data = user_data, .result = 0 }); // clean EOF
        }
    }

    pub fn recycleRecv(self: *ScriptBackend, comp: completion.Completion) void {
        _ = comp;
        self.recycles += 1;
        self.pool_free += 1;
    }

    pub fn submitSend(self: *ScriptBackend, user_data: u64, fd: Fd, bytes: []const u8) !void {
        _ = fd;
        self.sends_ok += 1;
        self.push(.{ .user_data = user_data, .result = @intCast(bytes.len) });
    }

    pub fn submitClose(self: *ScriptBackend, user_data: u64, fd: Fd) !void {
        _ = fd;
        self.push(.{ .user_data = user_data, .result = 0 });
    }

    pub fn poll(self: *ScriptBackend, out: []completion.Completion) !usize {
        // The loop stalled with no completion to deliver: a loop bug — a
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

    try client.sendCopying(startSession("client"));
    try drainOutboundBytes(&client, allocator, client_ss);

    var server_twin = try makeServerPeer(null, allocator);
    defer server_twin.deinit();
    var server_ss: std.ArrayList(u8) = .empty;
    defer server_ss.deinit(allocator);
    try drainOutboundBytes(&server_twin, allocator, &server_ss);
    _ = try client.recvStreamPrefix(server_ss.items);
    fetch_pump.drainEvents(&client);

    const prepared = try engine.fetch.prepareFetchSwissnum(allocator, &client.session_state, "thermostat");
    try client.send(prepared.message);
    try drainOutboundBytes(&client, allocator, fetch_bytes);
}

test "completion loop: a pool of one serves two starved connections — a starved read resumes on recycle, never drops" {
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

    var loop = try completion.Loop(ScriptBackend).init(allocator, makeServerPeer, null, .{
        .frame_cap = frame_cap,
        .max_conns = 4,
        .listen = 0,
        .read_buffers = 1,
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

    var loop = try completion.Loop(ScriptBackend).init(allocator, makeServerPeer, null, .{
        .frame_cap = frame_cap,
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
/// keep flowing — the kernel-borrow shape of a real io_uring send. At submit it
/// snapshots the submitted bytes; at release (when the loop has nothing else to
/// do) it checks the borrowed slice still holds exactly those bytes. Before the
/// front/back outbound split, a reply appended while a write was in flight
/// could realloc the queue and free the storage this held slice points into.
const HeldSendBackend = struct {
    pub const Fd = i32;

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

    pub fn openListener(port: u16) !Fd {
        _ = port;
        return 1;
    }

    pub fn boundPort(fd: Fd) !u16 {
        _ = fd;
        return 1;
    }

    pub fn closeFd(fd: Fd) void {
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
            self.push(.{ .user_data = user_data, .result = @intCast(chunk.len), .recv_bytes = chunk });
        } else {
            self.push(.{ .user_data = user_data, .result = 0 }); // clean EOF
        }
    }

    pub fn recycleRecv(self: *HeldSendBackend, comp: completion.Completion) void {
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

    pub fn submitClose(self: *HeldSendBackend, user_data: u64, fd: Fd) !void {
        _ = fd;
        self.push(.{ .user_data = user_data, .result = 0 });
    }

    pub fn poll(self: *HeldSendBackend, out: []completion.Completion) !usize {
        if (self.ready_len == 0) {
            // The loop is out of other work: the "kernel" finally performs the
            // held write, reading the borrowed slice now. If anything moved or
            // freed that storage since submit, the bytes differ — the exact
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
    // forcing the realloc that used to free the held storage.
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

    const fetch_count = 4;
    var fetch_frames: [fetch_count]std.ArrayList(u8) = @splat(.empty);
    defer for (&fetch_frames) |*f| f.deinit(allocator);
    for (&fetch_frames) |*f| {
        const prepared = try engine.fetch.prepareFetchSwissnum(allocator, &client.session_state, "thermostat");
        try client.send(prepared.message);
        try drainOutboundBytes(&client, allocator, f);
    }

    HeldSendBackend.chunks = &.{
        client_ss.items,
        fetch_frames[0].items,
        fetch_frames[1].items,
        fetch_frames[2].items,
        fetch_frames[3].items,
    };
    defer HeldSendBackend.chunks = &.{};

    var loop = try completion.Loop(HeldSendBackend).init(allocator, makeServerPeer, null, .{
        .frame_cap = frame_cap,
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
