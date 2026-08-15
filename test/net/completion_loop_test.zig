//! The completion `Loop`, proven end to end on its platform backend, and the
//! outbound-backpressure contract, proven on a scripted fake backend.
//!
//! One single-threaded `net.TcpLoop` (the portable `completion.Loop` over the
//! platform backend) accepts several concurrent connections and serves the
//! bootstrap-fetch scenario on each, the same handshake-to-open plus
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
const Loop = pancake.net.TcpLoop;
const completion = pancake.net.completion;
const fetch_pump = @import("../support/fetch_pump.zig");
const handshake = @import("../support/handshake.zig");
const no_dial = @import("../support/no_dial_locator.zig");

const frame_cap = 4096;
const client_count = 8;

const DeferredTurnProbe = struct {
    turns: usize = 0,
    done: *std.atomic.Value(bool),

    fn run(ctx: ?*anyopaque) anyerror!bool {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.turns += 1;
        if (self.turns == 3) self.done.store(true, .release);
        return true;
    }
};

const DriverExitProbe = struct {
    exits: usize = 0,

    fn run(ctx: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.exits += 1;
    }
};

test "completion loop interleaves deferred adapter turns with nonblocking polls" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    var done = std.atomic.Value(bool).init(false);
    var probe = DeferredTurnProbe{ .done = &done };
    var loop = try Loop.initWithBackendOptions(
        std.testing.allocator,
        .{ .queue_entries = 8, .read_buffers = 1 },
        makeServerPeer,
        &probe,
        .{
            .max_conns = 1,
            .on_loop_turn = DeferredTurnProbe.run,
        },
    );
    defer loop.deinit();

    // There are no descriptors or completions to wake this dialer-only loop.
    // Each callback result must therefore force the intervening poll to zero
    // timeout, including the turn that sets the driver's stop condition.
    try loop.runUntil(&done, 1_000);
    try std.testing.expectEqual(@as(usize, 3), probe.turns);
}

test "completion loop reports driver exit only for a driver lifetime" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    var probe: DriverExitProbe = .{};
    var loop = try Loop.initWithBackendOptions(
        std.testing.allocator,
        .{ .queue_entries = 8, .read_buffers = 1 },
        makeServerPeer,
        &probe,
        .{
            .max_conns = 1,
            .on_driver_exit = DriverExitProbe.run,
        },
    );
    defer loop.deinit();

    // Setup-time operations may inspect or address an unclaimed loop, but
    // they are not a run and must not transfer adapter ownership on return.
    loop.armOutbound(0);
    loop.closeSlot(0);
    try std.testing.expect(loop.verifiedChannelKey(0) == null);
    try std.testing.expectEqual(@as(usize, 0), probe.exits);

    var done = std.atomic.Value(bool).init(true);
    try loop.runUntil(&done, 0);
    try std.testing.expectEqual(@as(usize, 1), probe.exits);
}

test "completion adapter namespaces compose without handle or token collisions" {
    const Base = struct {
        pub const Fd = i32;
        pub const adapter_depth = 0;
    };
    const First = completion.AdapterNamespace(Base);
    const FirstBackend = struct {
        pub const Fd = i32;
        pub const adapter_depth = First.depth;
    };
    const Second = completion.AdapterNamespace(FirstBackend);

    const first_fd = try First.fdFromId(17);
    const second_fd = try Second.fdFromId(17);
    try std.testing.expect(first_fd < 0 and second_fd < 0);
    try std.testing.expect(First.ownsFd(first_fd));
    try std.testing.expect(!First.ownsFd(second_fd));
    try std.testing.expect(Second.ownsFd(second_fd));
    try std.testing.expect(!Second.ownsFd(first_fd));
    try std.testing.expectEqual(@as(u32, 17), First.fdId(first_fd));
    try std.testing.expectEqual(@as(u32, 17), Second.fdId(second_fd));

    const first_ud = First.userData(29);
    const second_ud = Second.userData(29);
    try std.testing.expect(First.ownsUserData(first_ud));
    try std.testing.expect(!First.ownsUserData(second_ud));
    try std.testing.expect(Second.ownsUserData(second_ud));
    try std.testing.expect(!Second.ownsUserData(first_ud));
    try std.testing.expectEqual(@as(u64, 29), First.userDataPayload(first_ud));
    try std.testing.expectEqual(@as(u64, 29), Second.userDataPayload(second_ud));

    const first_token = First.recvToken(3);
    const second_token = Second.recvToken(3);
    try std.testing.expect(First.ownsRecvToken(first_token));
    try std.testing.expect(!First.ownsRecvToken(second_token));
    try std.testing.expect(Second.ownsRecvToken(second_token));
    try std.testing.expect(!Second.ownsRecvToken(first_token));
    try std.testing.expectEqual(@as(u32, 3), First.recvTokenPayload(first_token));
    try std.testing.expectEqual(@as(u32, 3), Second.recvTokenPayload(second_token));
}

test "completion backend: a wake-channel nudge completes an armed recv" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var backend = try pancake.net.Backend.init(allocator, 8, 2, frame_cap);
    defer backend.deinit();
    const wake = try pancake.net.wake_channel.WakeChannel.open();
    defer wake.deinit();
    const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
    for ([_]i32{ wake.read, wake.write }) |fd| {
        const flags = std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0));
        try std.testing.expect(flags >= 0);
        try std.testing.expect(flags & nonblock != 0);
    }

    const wake_user_data = 0xa11ce;
    try backend.submitRecv(wake_user_data, wake.read);
    _ = try wake.nudge();

    var completions: [1]completion.Completion = undefined;
    const count = try backend.poll(&completions, 1_000);
    try std.testing.expectEqual(@as(usize, 1), count);
    const received = completions[0];
    try std.testing.expectEqual(@as(u64, wake_user_data), received.user_data);
    try std.testing.expect(received.result > 0);
    try std.testing.expect(!received.recv_no_buffer);
    try std.testing.expectEqual(@as(usize, 1), received.recv_bytes.?.len);
    backend.recycleRecv(received);
}

test "completion backend: cancel retires an exact recv without closing its fd" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var backend = try pancake.net.Backend.init(allocator, 8, 2, frame_cap);
    defer backend.deinit();
    const wake = try pancake.net.wake_channel.WakeChannel.open();
    defer wake.deinit();

    const recv_ud = 0xc001;
    const cancel_ud = 0xc002;
    try backend.submitRecv(recv_ud, wake.read);
    try backend.submitCancel(cancel_ud, recv_ud, wake.read);

    var saw_recv = false;
    var saw_cancel = false;
    var completions: [2]completion.Completion = undefined;
    while (!saw_recv or !saw_cancel) {
        const count = try backend.poll(&completions, 1_000);
        try std.testing.expect(count != 0);
        for (completions[0..count]) |item| {
            if (item.recv_bytes != null) backend.recycleRecv(item);
            if (item.user_data == recv_ud) {
                saw_recv = true;
            } else if (item.user_data == cancel_ud) {
                saw_cancel = true;
            } else {
                return error.UnexpectedCompletion;
            }
        }
    }

    // Cancellation retires only the operation. The caller-owned descriptor is
    // still usable for a fresh recv.
    const rearm_ud = 0xc003;
    try backend.submitRecv(rearm_ud, wake.read);
    _ = try wake.nudge();
    const count = try backend.poll(&completions, 1_000);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(u64, rearm_ud), completions[0].user_data);
    try std.testing.expect(completions[0].result > 0);
    backend.recycleRecv(completions[0]);
}

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

    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const designator_addr = try tcp.parseHostPort("127.0.0.1", port);
    const designator = tcp.locatorFromAddress(&designator_buf, designator_addr).designator;
    const locator: model.PeerLocator = .{
        .transport = tcp.transport_name,
        .designator = designator,
        .hints = model.Hints.emptyMap(),
    };
    var conn = try tcp.connect(io, &peer, locator, read_buf, write_buf, .{});
    defer conn.deinit();

    try fetch_pump.handshakeToOpen(&peer, &conn, startSession("client"));

    const reference = try fetch_pump.settleFetch(allocator, &peer, &conn, "thermostat");
    model.freeReference(allocator, reference);
}

test "completion loop: concurrent clients each fetch the shared bootstrap cap" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    var loop = try Loop.init(allocator, makeServerPeer, null, .{
        .max_conns = 64,
        .listen = 0,
    });
    defer loop.deinit();
    const port = loop.port().?;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // The completion loop and the clients share the Threaded Io backend.
    var loop_err: ?anyerror = null;
    var loop_future = try io.concurrent(runLoopCapturing, .{ &loop, @as(usize, client_count), &loop_err });

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

    loop_future.await(io);
    // A loop-global failure raised in the same batch that dispatched the last
    // close was discarded here, and this test has no assertion of its own — so
    // it went green on a loop that had died.
    if (loop_err) |err| return err;
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
    port: actors.Port,

    fn make(ctx: ?*anyopaque, peer: *engine.Peer, slot: usize) anyerror!?*anyopaque {
        _ = slot;
        const allocator: *const std.mem.Allocator = @ptrCast(@alignCast(ctx.?));
        const self = try allocator.create(LoopVat);
        errdefer allocator.destroy(self);
        self.vat = actors.Vat.init(allocator.*);
        self.port = actors.Port.init(allocator.*, peer);
        // Spawn the actor and publish it at the bootstrap swissnum the client
        // fetches, exactly `driver.BlockingSession.publish`, now on the loop.
        const greeter = try self.vat.spawn(Greeter, .{});
        const position = try peer.registerBootstrapCap("thermostat");
        try self.port.bindExport(&self.vat, greeter, position);
        return self;
    }

    fn serve(conn_ctx: ?*anyopaque, peer: *engine.Peer, event: *engine.Event) anyerror!void {
        _ = peer;
        const self: *LoopVat = @ptrCast(@alignCast(conn_ctx.?));
        _ = try self.port.serve(&self.vat, event);
    }

    fn free(ctx: ?*anyopaque, conn_ctx: ?*anyopaque) void {
        const allocator: *const std.mem.Allocator = @ptrCast(@alignCast(ctx.?));
        const self: *LoopVat = @ptrCast(@alignCast(conn_ctx.?));
        self.port.deinit(&self.vat);
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
/// `greet` on it and assert the reply comes back, over the completion loop.
fn fetchThenCall(io: std.Io, port: u16, allocator: std.mem.Allocator) anyerror!void {
    var peer = engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = false });
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const designator_addr = try tcp.parseHostPort("127.0.0.1", port);
    const designator = tcp.locatorFromAddress(&designator_buf, designator_addr).designator;
    const locator: model.PeerLocator = .{
        .transport = tcp.transport_name,
        .designator = designator,
        .hints = model.Hints.emptyMap(),
    };
    var conn = try tcp.connect(io, &peer, locator, read_buf, write_buf, .{});
    defer conn.deinit();

    var vat = actors.Vat.init(allocator);
    defer vat.deinit();
    var session_port = actors.Port.init(allocator, &peer);
    defer session_port.deinit(&vat);

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
                .broken, .give => false,
            };
        }
    };
    var state = State{};
    const promise = try session_port.send(&vat, .{ .far = cap }, .{ .verb = "greet", .args = &.{.{ .string = "x" }} });
    try session_port.on(&vat, promise, .{ .ctx = &state, .func = State.onReply });

    var spins: usize = 0;
    while (!state.done and spins < 10_000) : (spins += 1) {
        const progress = try conn.pump();
        while (peer.pollEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();
            _ = try session_port.serve(&vat, &event);
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
        .max_conns = 16,
        .listen = 0,
        .make_conn_ctx = LoopVat.make,
        .serve = LoopVat.serve,
        .free_conn_ctx = LoopVat.free,
    });
    defer loop.deinit();
    const port = loop.port().?;

    const clients = 6;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var loop_err: ?anyerror = null;
    var loop_future = try io.concurrent(runLoopCapturing, .{ &loop, @as(usize, clients), &loop_err });

    var futures: [clients]std.Io.Future(anyerror!void) = undefined;
    for (&futures) |*f| f.* = try io.concurrent(fetchThenCall, .{ io, port, allocator });
    var first_err: ?anyerror = null;
    for (&futures) |*f| f.await(io) catch |err| {
        if (first_err == null) first_err = err;
    };

    loop_future.await(io);
    if (loop_err) |err| return err;
    if (first_err) |err| return err;
}

fn runLoopCapturing(loop: *Loop, until_closed: usize, out_err: *?anyerror) void {
    loop.run(.{ .after_closed = until_closed }) catch |err| {
        out_err.* = err;
    };
    // `run` returns on the close count alone and leaves any other slot's armed
    // recv in flight, which `deinit` refuses to free. Drain here, on the
    // loop-owner thread, exactly as `closeAndDrain` documents for an early
    // `run` return.
    loop.closeAndDrain() catch |err| {
        // The run's error is the interesting one; the drain's is usually its
        // consequence. Overwriting hid the cause behind the symptom.
        if (out_err.* == null) out_err.* = err;
    };
}

test "completion loop: churns hundreds of connection lifecycles through a small slot pool" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    // Heavy reuse on purpose: more lifecycles than slots, in waves, so each
    // slot is torn down and re-accepted many times. This is the real stress of
    // the deferred-teardown + slot-reuse machinery the unit path only grazes,
    // if teardown ever stranded a slot (the io_uring/kqueue close-while-recv-armed
    // bug class), the pool would fill, later accepts would be refused, and the
    // clients in a later wave would fail to fetch.
    const per_wave = 40;
    const waves = 12;
    const total = per_wave * waves; // 480 connection lifecycles
    const max_conns = 56; // < concurrent-peak's headroom, so slots recycle across waves

    var loop = try Loop.initWithBackendOptions(allocator, .{
        .queue_entries = 8,
    }, makeServerPeer, null, .{
        .max_conns = max_conns,
        .listen = 0,
        // A deliberately tiny ring: one dispatch batch arms far more
        // operations than eight SQ entries hold, so this churn also pins the
        // io_uring backend's submission-queue self-healing, without the
        // mid-batch flush in `getSqe`, a full queue would close healthy
        // connections (or kill the accept re-arm, and with it the loop) long
        // before the waves complete. kqueue ignores the hint.
    });
    defer loop.deinit();
    const port = loop.port().?;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var loop_err: ?anyerror = null;
    var loop_future = try io.concurrent(runLoopCapturing, .{ &loop, @as(usize, total), &loop_err });

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

    loop_future.await(io);
    if (loop_err) |err| return err;
    if (first_err) |err| return err;
    // Every lifecycle completed: no slot was stranded, no client was refused.
    try std.testing.expectEqual(@as(usize, total), served);
}

/// One abrupt client: connect a real socket and drop it immediately, without
/// handshaking. The server accepts, arms a recv, and has its opening
/// `op:start-session` send pending, so the close lands while ops are in flight.
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

    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const designator_addr = try tcp.parseHostPort("127.0.0.1", port);
    const designator = tcp.locatorFromAddress(&designator_buf, designator_addr).designator;
    const locator: model.PeerLocator = .{
        .transport = tcp.transport_name,
        .designator = designator,
        .hints = model.Hints.emptyMap(),
    };
    var conn = tcp.connect(io, &peer, locator, read_buf, write_buf, .{}) catch return;
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
        .max_conns = max_conns,
        .listen = 0,
    });
    defer loop.deinit();
    const port = loop.port().?;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var loop_err: ?anyerror = null;
    var loop_future = try io.concurrent(runLoopCapturing, .{ &loop, @as(usize, total), &loop_err });

    var wave: usize = 0;
    while (wave < waves) : (wave += 1) {
        var futures: [per_wave]std.Io.Future(anyerror!void) = undefined;
        for (&futures) |*f| f.* = try io.concurrent(slamOnce, .{ io, port, allocator });
        for (&futures) |*f| f.await(io) catch {};
    }

    // The loop must process every abrupt close as a completed lifecycle and
    // terminate, if any close stranded its slot, `run(total)` would block
    // forever and join would hang the test rather than return.
    loop_future.await(io);
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

    pub fn applyKeepalive(_: *FakeBackend, _: Fd, _: completion.Keepalive) !void {
        return error.OperationUnsupported;
    }

    /// The inbound wire script, set by the test before `Loop.init`.
    var chunks: []const []const u8 = &.{};
    /// Test-only pressure injection for listener cancellation. Connection
    /// closes remain unaffected.
    var refuse_listener_close_once: bool = false;
    /// Report the canceled accept on the poll after the listener close. This
    /// pins that the Loop drains both operations independent of CQE ordering.
    var defer_listener_accept_cancel: bool = false;
    /// Inject one typed listener failure before the ordinary scripted accept.
    var first_accept_failure: ?anyerror = null;
    /// Inject one typed send-submission refusal before the slow-reader script.
    var first_send_submission_failure: ?anyerror = null;

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
            self.push(.{ .user_data = user_data, .result = @intCast(chunk.len), .recv_bytes = chunk });
        } else {
            self.push(.{ .user_data = user_data, .result = 0 }); // clean EOF
        }
    }

    pub fn verifiedChannelKey(self: *FakeBackend, fd: Fd) ?[32]u8 {
        _ = self;
        _ = fd;
        return null;
    }

    pub fn recycleRecv(self: *FakeBackend, comp: completion.Completion) void {
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

test "completion loop: accept completion preserves its typed failure" {
    FakeBackend.chunks = &.{};
    FakeBackend.first_accept_failure = error.TestAcceptFailure;
    defer FakeBackend.first_accept_failure = null;

    var loop = try completion.Loop(FakeBackend, no_dial.Unsupported).init(
        std.testing.allocator,
        makeServerPeer,
        null,
        .{ .max_conns = 1, .listen = 0 },
    );
    defer loop.deinit();

    try std.testing.expectError(error.TestAcceptFailure, loop.run(.{ .after_closed = 1 }));
    // The accept was re-armed before the failure reached the owner, so a caller
    // that deliberately resumes the loop does not lose listener readiness.
    try std.testing.expect(loop.accept_armed);
}

fn failMakePeer(_: ?*anyopaque, _: std.mem.Allocator) !engine.Peer {
    return error.TestPeerCreateFailure;
}

test "completion loop surfaces accepted-peer construction failure" {
    FakeBackend.chunks = &.{};

    var loop = try completion.Loop(FakeBackend, no_dial.Unsupported).init(
        std.testing.allocator,
        failMakePeer,
        null,
        .{ .max_conns = 1, .listen = 0 },
    );
    defer loop.deinit();

    try std.testing.expectError(error.TestPeerCreateFailure, loop.run(.{ .after_closed = 1 }));
}

const KeepaliveFailureWatch = struct {
    var report: ?completion.CloseReport = null;

    fn onClose(_: ?*anyopaque, _: usize, _: ?*anyopaque, close_report: completion.CloseReport) void {
        report = close_report;
    }
};

test "completion loop reports backend keepalive refusal before serving connection" {
    FakeBackend.chunks = &.{};
    KeepaliveFailureWatch.report = null;

    var loop = try completion.Loop(FakeBackend, no_dial.Unsupported).init(std.testing.allocator, makeServerPeer, null, .{
        .max_conns = 1,
        .listen = 0,
        .keepalive = .{ .idle_sec = 30, .interval_sec = 10, .count = 3 },
        .on_close = KeepaliveFailureWatch.onClose,
    });
    defer loop.deinit();

    try loop.run(.{ .after_closed = 1 });

    const report = KeepaliveFailureWatch.report orelse return error.MissingCloseReport;
    try std.testing.expect(report.opened);
    try std.testing.expectEqual(completion.CloseReason.ordinary, report.reason);
    try std.testing.expectEqualStrings("OperationUnsupported", report.failure.?.error_name);
}

test "completion loop reports a send submission failure through close" {
    FakeBackend.chunks = &.{};
    FakeBackend.first_send_submission_failure = error.TestSendSubmissionFailure;
    defer FakeBackend.first_send_submission_failure = null;
    KeepaliveFailureWatch.report = null;

    var loop = try completion.Loop(FakeBackend, no_dial.Unsupported).init(std.testing.allocator, makeServerPeer, null, .{
        .max_conns = 1,
        .listen = 0,
        .on_close = KeepaliveFailureWatch.onClose,
    });
    defer loop.deinit();

    try loop.run(.{ .after_closed = 1 });

    const report = KeepaliveFailureWatch.report orelse return error.MissingCloseReport;
    try std.testing.expectEqualStrings("TestSendSubmissionFailure", report.failure.?.error_name);
}

test "completion loop: listener close retries instead of abandoning an armed accept" {
    const allocator = std.testing.allocator;
    FakeBackend.chunks = &.{};
    FakeBackend.refuse_listener_close_once = true;
    defer FakeBackend.refuse_listener_close_once = false;

    var loop = try completion.Loop(FakeBackend, no_dial.Unsupported).init(allocator, makeServerPeer, null, .{
        .max_conns = 1,
        .listen = 0,
    });
    defer loop.deinit();

    // `runUntil` arms the accept even when the stop flag is already set. The
    // first close submit then fails under injected backend pressure. The drain
    // reports that exact refusal while retaining the listener, and a retry
    // completes without falling back to an unsafe descriptor-only close.
    var done = std.atomic.Value(bool).init(true);
    try loop.runUntil(&done, 0);
    try std.testing.expectError(error.OutOfMemory, loop.closeAndDrain());
    try loop.closeAndDrain();

    try std.testing.expectEqual(@as(usize, 2), loop.backend.listener_close_attempts);
    try std.testing.expectEqual(@as(usize, 0), loop.backend.listener_close_fallbacks);
}

test "completion loop: listener shutdown drains a canceled accept after close completion" {
    const allocator = std.testing.allocator;
    FakeBackend.chunks = &.{};
    FakeBackend.defer_listener_accept_cancel = true;
    defer FakeBackend.defer_listener_accept_cancel = false;

    var loop = try completion.Loop(FakeBackend, no_dial.Unsupported).init(allocator, makeServerPeer, null, .{
        .max_conns = 1,
        .listen = 0,
    });
    defer loop.deinit();

    // The scripted connection closes on its first recv, after onAccept has
    // armed a second accept. Listener close completes first; the backend does
    // not surface the canceled accept until the following poll.
    try loop.run(.{ .after_closed = 1 });
    try std.testing.expect(loop.accept_armed);
    try loop.closeAndDrain();

    try std.testing.expect(!loop.accept_armed);
    try std.testing.expect(loop.backend.deferred_accept_cancel_ud == null);
}

/// Encode `peer`'s queued sends and append their bare frame bytes to `sink`.
/// This is the intrinsic message-framed path used to prepare a peer directly.
fn drainOutboundBytes(peer: *engine.Peer, allocator: std.mem.Allocator, sink: *std.ArrayList(u8)) !void {
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_value| {
        var frame = frame_value;
        defer frame.deinit();
        try sink.appendSlice(allocator, frame.bytes());
    }
}

/// Encode `peer`'s queued sends at the byte-stream boundary, where every bare
/// codec frame is carried inside one outer Syrup byte string.
fn drainOutboundStreamBytes(peer: *engine.Peer, allocator: std.mem.Allocator, sink: *std.ArrayList(u8)) !void {
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_value| {
        var frame = frame_value;
        defer frame.deinit();
        _ = try pancake.net.appendFrameBytes(sink, allocator, frame.bytes());
    }
}

/// A scripted backend hosting two connections where the first is a bad
/// partner: every send submission on its fd fails. The second connection's
/// inbound script (`chunks`) is a full bootstrap-fetch conversation. The loop
/// must close the failing connection and keep serving the healthy one.
const OneBadPartnerBackend = struct {
    pub const Fd = i32;

    pub fn applyKeepalive(_: *OneBadPartnerBackend, _: Fd, _: completion.Keepalive) !void {
        return error.OperationUnsupported;
    }

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

    pub fn verifiedChannelKey(self: *OneBadPartnerBackend, fd: Fd) ?[32]u8 {
        _ = self;
        _ = fd;
        return null;
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

    pub fn submitCancel(self: *OneBadPartnerBackend, cancel_user_data: u64, target_user_data: u64, fd: Fd) !void {
        _ = .{ target_user_data, fd };
        self.push(.{ .user_data = cancel_user_data, .result = 0 });
    }

    pub fn submitClose(self: *OneBadPartnerBackend, user_data: u64, fd: Fd) !void {
        _ = fd;
        self.push(.{ .user_data = user_data, .result = 0 });
    }

    pub fn poll(self: *OneBadPartnerBackend, out: []completion.Completion, timeout_ms: i32) !usize {
        _ = timeout_ms;
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
    try drainOutboundStreamBytes(&client, allocator, &client_ss);

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
    try drainOutboundStreamBytes(&client, allocator, &fetch_bytes);

    OneBadPartnerBackend.chunks = &.{ client_ss.items, fetch_bytes.items };
    defer OneBadPartnerBackend.chunks = &.{};

    var loop = try completion.Loop(OneBadPartnerBackend, no_dial.Unsupported).init(allocator, makeServerPeer, null, .{
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
    try drainOutboundStreamBytes(&client, allocator, &client_ss);

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
    try drainOutboundStreamBytes(&client, allocator, &fetch_bytes);

    // The mark sits far below one frame, so both the handshake reply and the
    // fetch reply must park the read, observable from the very first write.
    const high_water: usize = 16;
    try std.testing.expect(server_ss.items.len > high_water);

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

    FakeBackend.chunks = &.{ client_ss.items, fetch_bytes.items };
    defer FakeBackend.chunks = &.{};

    var loop = try completion.Loop(FakeBackend, no_dial.Unsupported).init(allocator, makeServerPeer, &park_hits, .{
        .max_conns = 4,
        .listen = 0,
        .outbound_high_water_bytes = high_water,
        .on_park = ParkCount.onPark,
    });
    defer loop.deinit();

    try loop.run(.{ .after_closed = 1 });

    try std.testing.expect(park_hits >= 1);
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

test "completion loop: outbound high-water has an independent default and explicit override" {
    const defaults: completion.Options = .{};
    try std.testing.expectEqual(completion.default_outbound_high_water_bytes, defaults.outbound_high_water_bytes);

    const overridden: completion.Options = .{ .outbound_high_water_bytes = 333 };
    try std.testing.expectEqual(@as(usize, 333), overridden.outbound_high_water_bytes);
}

test "completion loop: exact read-buffer bytes reach the constructed backend" {
    var loop = try completion.Loop(FakeBackend, no_dial.Unsupported).initWithBackendOptions(
        std.testing.allocator,
        .{ .read_buffers = 1, .read_buffer_bytes = 12_345 },
        makeServerPeer,
        null,
        .{ .max_conns = 1 },
    );
    defer loop.deinit();
    try std.testing.expectEqual(@as(u32, 12_345), loop.backend.read_buffer_bytes);
}

test "completion loop: an empty shared read buffer is refused" {
    try std.testing.expectError(
        error.InvalidReadBufferBytes,
        completion.Loop(FakeBackend, no_dial.Unsupported).initWithBackendOptions(
            std.testing.allocator,
            .{ .read_buffer_bytes = 0 },
            makeServerPeer,
            null,
            .{},
        ),
    );
}

test "completion scratch pool refuses zero-sized buffers at its ownership boundary" {
    try std.testing.expectError(
        error.InvalidReadBufferBytes,
        completion.ScratchPool.init(std.testing.allocator, 1, 0),
    );
}

/// A scripted backend for the shared-pool contract (ADR-0054): every accepted
/// connection replays the same inbound `chunks` script, each chunk handed out
/// as a borrowed completion view from a pool of `read_buffers` buffers. A recv
/// armed while the pool is empty completes `recv_no_buffer` — exactly the
/// platform backends' starvation shape — and sends complete synchronously.
const ScriptBackend = struct {
    pub const Fd = i32;

    pub fn applyKeepalive(_: *ScriptBackend, _: Fd, _: completion.Keepalive) !void {
        return error.OperationUnsupported;
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
            self.push(.{ .user_data = user_data, .result = @intCast(chunk.len), .recv_bytes = chunk });
        } else {
            self.push(.{ .user_data = user_data, .result = 0 }); // clean EOF
        }
    }

    pub fn verifiedChannelKey(self: *ScriptBackend, fd: Fd) ?[32]u8 {
        _ = self;
        _ = fd;
        return null;
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

    pub fn submitCancel(self: *ScriptBackend, cancel_user_data: u64, target_user_data: u64, fd: Fd) !void {
        _ = .{ target_user_data, fd };
        self.push(.{ .user_data = cancel_user_data, .result = 0 });
    }

    pub fn submitClose(self: *ScriptBackend, user_data: u64, fd: Fd) !void {
        _ = fd;
        self.push(.{ .user_data = user_data, .result = 0 });
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

    try client.sendCopying(startSession("client"));
    try drainOutboundStreamBytes(&client, allocator, client_ss);

    var server_twin = try makeServerPeer(null, allocator);
    defer server_twin.deinit();
    var server_ss: std.ArrayList(u8) = .empty;
    defer server_ss.deinit(allocator);
    try drainOutboundBytes(&server_twin, allocator, &server_ss);
    _ = try client.recvStreamPrefix(server_ss.items);
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
/// snapshots the submitted bytes; at release (when the loop has nothing else to
/// do) it checks the borrowed slice still holds exactly those bytes. Before the
/// front/back outbound split, a reply appended while a write was in flight
/// could realloc the queue and free the storage this held slice points into.
const HeldSendBackend = struct {
    pub const Fd = i32;

    pub fn applyKeepalive(_: *HeldSendBackend, _: Fd, _: completion.Keepalive) !void {
        return error.OperationUnsupported;
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
            self.push(.{ .user_data = user_data, .result = @intCast(chunk.len), .recv_bytes = chunk });
        } else {
            self.push(.{ .user_data = user_data, .result = 0 }); // clean EOF
        }
    }

    pub fn verifiedChannelKey(self: *HeldSendBackend, fd: Fd) ?[32]u8 {
        _ = self;
        _ = fd;
        return null;
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

    pub fn submitCancel(self: *HeldSendBackend, cancel_user_data: u64, target_user_data: u64, fd: Fd) !void {
        _ = .{ target_user_data, fd };
        self.push(.{ .user_data = cancel_user_data, .result = 0 });
    }

    pub fn submitClose(self: *HeldSendBackend, user_data: u64, fd: Fd) !void {
        _ = fd;
        self.push(.{ .user_data = user_data, .result = 0 });
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
    // forcing the realloc that used to free the held storage.
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
    _ = try client.recvStreamPrefix(server_ss.items);
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

test "completion loop: the listener sets SO_REUSEADDR, parity with the blocking tcp.Listener" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    var loop = try Loop.init(allocator, makeServerPeer, null, .{
        .max_conns = 4,
        .listen = 0,
    });
    defer loop.deinit();

    // The blocking `tcp.Listener` binds with `reuse_address = true`; the
    // completion backends must match, or a loop restarted on a pinned port
    // (`-Dport=N`) fails to bind for the TIME_WAIT window. Read the option back
    // off the bound listener fd to prove the backend set it.
    const fd = loop.listen_fd.?;
    const sys = std.posix.system;
    var value: c_int = 0;
    var len: std.posix.socklen_t = @sizeOf(c_int);
    const rc = sys.getsockopt(fd, sys.SOL.SOCKET, sys.SO.REUSEADDR, @ptrCast(&value), &len);
    try std.testing.expect(rc == 0);
    try std.testing.expect(value != 0);
}

/// A server peer whose admission limit is deliberately above the shared read
/// buffer, proving pool sizing does not become a second frame limit.
fn makeBigFramePeer(ctx: ?*anyopaque, allocator: std.mem.Allocator) anyerror!engine.Peer {
    _ = ctx;
    var peer = engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = false });
    errdefer peer.deinit();
    peer.session_state.limits.max_frame_bytes = big_frame_max;
    _ = try peer.registerBootstrapCap("thermostat");
    try peer.sendCopying(startSession("server"));
    return peer;
}

const big_frame_max = 1 << 16;
const small_read_buffer_bytes: u32 = 4 * 1024;

/// Build a large but structurally valid `op:deliver` frame in the negotiated
/// codec: the client handshakes against a server twin, then sends a fetch whose
/// swissnum is padded to many kilobytes, so the frame is larger than one pool
/// buffer yet well under the peers' `max_frame_bytes`. Returns the client's
/// start-session bytes and the big deliver bytes, both owned by the caller.
fn buildBigDeliverScript(
    allocator: std.mem.Allocator,
    client_ss: *std.ArrayList(u8),
    big_deliver: *std.ArrayList(u8),
) !void {
    var client = engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = false });
    defer client.deinit();
    client.session_state.limits.max_frame_bytes = big_frame_max;

    try client.sendCopying(startSession("client"));
    try drainOutboundStreamBytes(&client, allocator, client_ss);

    var server_twin = try makeBigFramePeer(null, allocator);
    defer server_twin.deinit();
    var server_ss: std.ArrayList(u8) = .empty;
    defer server_ss.deinit(allocator);
    try drainOutboundBytes(&server_twin, allocator, &server_ss);
    _ = try client.recvStreamPrefix(server_ss.items);
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

/// A peer that vanishes without a clean close: its armed recv finally surfaces
/// a read error (an RST, or a keepalive probe giving up on a dead remote host).
/// One connection accepts, its opening send lands, then the next recv errors.
const DeadPeerBackend = struct {
    pub const Fd = i32;

    pub fn applyKeepalive(_: *DeadPeerBackend, _: Fd, _: completion.Keepalive) !void {
        return error.OperationUnsupported;
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

    pub fn recycleRecv(self: *DeadPeerBackend, comp: completion.Completion) void {
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
    // What has to exceed the mark is the *server's* hello, which is what parks
    // the connection, and that is asserted on `server_ss` a few lines down.
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

/// Two-connection fan-in throttle (ADR-0082): while the sink stays over
/// high-water, a drained source stays parked; when the sink finally drains,
/// the source's read re-arms.
const FanInBackend = struct {
    pub const Fd = i32;

    pub fn applyKeepalive(_: *FanInBackend, _: Fd, _: completion.Keepalive) !void {
        return error.OperationUnsupported;
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
            self.push(.{ .user_data = user_data, .result = @intCast(chunk.len), .recv_bytes = chunk });
        } else {
            self.push(.{ .user_data = user_data, .result = 0 });
        }
    }

    pub fn verifiedChannelKey(self: *FanInBackend, fd: Fd) ?[32]u8 {
        _ = self;
        _ = fd;
        return null;
    }

    pub fn recycleRecv(self: *FanInBackend, comp: completion.Completion) void {
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

test "completion loop: a fan-in victim starts its slow-reader clock when it becomes a sink" {
    const allocator = std.testing.allocator;

    // A parked connection under the high-water mark is somebody else's victim
    // and the reaper must leave it alone. If its own queue later grows past
    // the mark it becomes the slow reader the deadline is about — and its
    // grace starts then, not when it first parked. Stamping at park time
    // would hand a long-throttled victim an already-expired deadline and
    // reclaim it the instant it crossed the mark.
    var peer = engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = false });
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const LoopType = completion.Loop(FanInBackend, no_dial.Unsupported);
    var loop = try completion.Loop(FanInBackend, no_dial.Unsupported).init(allocator, makeServerPeer, null, .{
        .max_conns = 2,
        .listen = 0,
        .outbound_high_water_bytes = 16,
        .fan_in_throttle = true,
        .park_kill_ms = 60_000,
    });
    defer loop.deinit();

    const c = &loop.conns[0];
    // Field by field, not `c.* = .{ … }`. A whole-struct assignment also
    // rewrites `next_link`, which slot zero is holding for the free list it is
    // currently the head of — the list would become a self-loop, and the slot
    // would be both free and open at once. `adoptSlot` exists in the loop for
    // this exact reason; a test that models a state the loop's own transitions
    // cannot reach teaches the next reader to build one.
    // Off the free list first. The slot is its head at `init`, and a live slot
    // still on it is one connection handed to two adopters — the state
    // `freeSlot` now asserts against. `adoptSlot`'s callers pop before they
    // adopt; a hand-built slot has to do the same.
    loop.ordinary_free_head = c.next_link;
    c.state = .open;
    c.opened = true;
    c.fd = 10;
    c.peer = peer;
    // Hand-built slots bypass the close path, so release what the loop's
    // counters are tracking before leaving; `deinit` asserts they reach zero.
    defer {
        loop.parked_head = c.next_link;
        c.read = .idle;
        c.state = .free;
        LoopType.white_box.refreshWaiting(&loop, c);
    }

    // Parked as a victim: no stamp, no deadline, and nothing for the loop to
    // wake up for.
    c.read = .parked;
    // A parked seat is on the parked list; the loop's own `markParked` links
    // them together. Leaving it unlisted is a connection the fan-in release can
    // never find, which is the one thing this hand-built slot must not model.
    c.next_link = @intCast(loop.parked_head);
    c.prev_link = @intCast(loop.conns.len);
    loop.parked_head = 0;
    LoopType.white_box.refreshWaiting(&loop, c);
    try std.testing.expectEqual(@as(i64, 0), c.waiting_since_ms);
    try std.testing.expect(LoopType.white_box.pendingDeadline(&loop, c) == null);
    try std.testing.expectEqual(@as(usize, 0), loop.waiting_count);

    // Its queue crosses the mark. Now it is a sink, and its clock starts.
    try c.back.appendSlice(allocator, &[_]u8{0} ** 64);
    defer c.back.clearAndFree(allocator);
    LoopType.white_box.refreshWaiting(&loop, c);
    try std.testing.expect(c.waiting_since_ms != 0);
    try std.testing.expectEqual(@as(usize, 1), loop.waiting_count);
    const deadline = LoopType.white_box.pendingDeadline(&loop, c) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(completion.CloseReason.park_kill, deadline.reason);
    // Age the stamp, then re-ask. Without this the assertion below cannot
    // fail: the line above has already shown there was no stamp at park time,
    // so nothing could have been inherited and the deadline is always fresh.
    // Aged, it fails unless the stamp really was taken when the connection
    // became a sink rather than when it parked.
    c.waiting_since_ms -= 50_000;
    const aged = LoopType.white_box.pendingDeadline(&loop, c) orelse return error.TestUnexpectedResult;
    try std.testing.expect(aged.due - pancake.net.clock.nowMonotonicMs() < 11_000);
    c.waiting_since_ms += 50_000;
    // And unaged, nearly the whole budget remains.
    try std.testing.expect(deadline.due - pancake.net.clock.nowMonotonicMs() > 59_000);

    // Draining back below the mark makes it a victim again, and gives the
    // deadline back.
    c.back.clearRetainingCapacity();
    LoopType.white_box.refreshWaiting(&loop, c);
    try std.testing.expectEqual(@as(i64, 0), c.waiting_since_ms);
    try std.testing.expectEqual(@as(usize, 0), loop.waiting_count);
}

test "completion loop: condemning a parked sink restarts the clock for the flush" {
    const allocator = std.testing.allocator;

    // A sink that has been parked a long time carries an old stamp. When the
    // connection is condemned, that stamp starts answering to `drain_kill_ms`
    // instead of `park_kill_ms` — and if it is not restarted, the terminal
    // flush is measured against time the connection spent doing something
    // else, and is cut short or skipped entirely.
    var peer = engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = false });
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const LoopType = completion.Loop(FanInBackend, no_dial.Unsupported);
    var loop = try completion.Loop(FanInBackend, no_dial.Unsupported).init(allocator, makeServerPeer, null, .{
        .max_conns = 2,
        .listen = 0,
        .outbound_high_water_bytes = 16,
        .park_kill_ms = 600_000,
        .drain_kill_ms = 5_000,
    });
    defer loop.deinit();

    const c = &loop.conns[0];
    // Field by field, not `c.* = .{ … }`. A whole-struct assignment also
    // rewrites `next_link`, which slot zero is holding for the free list it is
    // currently the head of — the list would become a self-loop, and the slot
    // would be both free and open at once. `adoptSlot` exists in the loop for
    // this exact reason; a test that models a state the loop's own transitions
    // cannot reach teaches the next reader to build one.
    // Off the free list first. The slot is its head at `init`, and a live slot
    // still on it is one connection handed to two adopters — the state
    // `freeSlot` now asserts against. `adoptSlot`'s callers pop before they
    // adopt; a hand-built slot has to do the same.
    loop.ordinary_free_head = c.next_link;
    c.state = .open;
    c.opened = true;
    c.fd = 10;
    c.peer = peer;
    // Hand-built slots bypass the close path, so release what the loop's
    // counters are tracking before leaving; `deinit` asserts they reach zero.
    defer {
        loop.parked_head = c.next_link;
        c.read = .idle;
        c.state = .free;
        LoopType.white_box.refreshWaiting(&loop, c);
    }
    try c.back.appendSlice(allocator, &[_]u8{0} ** 64);
    defer c.back.clearAndFree(allocator);

    // Parked as a sink, then aged: pretend it has been waiting ten minutes.
    c.read = .parked;
    // A parked seat is on the parked list; the loop's own `markParked` links
    // them together. Leaving it unlisted is a connection the fan-in release can
    // never find, which is the one thing this hand-built slot must not model.
    c.next_link = @intCast(loop.parked_head);
    c.prev_link = @intCast(loop.conns.len);
    loop.parked_head = 0;
    LoopType.white_box.refreshWaiting(&loop, c);
    try std.testing.expect(c.waiting_since_ms != 0);
    c.waiting_since_ms -= 600_000;
    const parked_at = c.waiting_since_ms;

    // Condemned. The wait now means something else, so the clock restarts and
    // the flush gets its whole budget.
    c.state = .draining;
    LoopType.white_box.refreshWaiting(&loop, c);
    try std.testing.expect(c.waiting_since_ms > parked_at);
    const deadline = LoopType.white_box.pendingDeadline(&loop, c) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(completion.CloseReason.drain_kill, deadline.reason);
    try std.testing.expect(deadline.due - pancake.net.clock.nowMonotonicMs() > 4_000);
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
