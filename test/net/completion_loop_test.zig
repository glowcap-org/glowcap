//! The completion `Loop`, proven end to end on its platform backend: one
//! single-threaded `net.TcpLoop` accepts several concurrent connections and
//! serves the bootstrap-fetch scenario on each, the same handshake-to-open
//! plus `fetch`/auto-`resolve` round-trip the blocking `tcp_test` proves, here
//! driven by kernel completions. Several clients dial at once, so the
//! multiplexing (many connections, one loop, one thread) is exercised, not
//! just the single-connection path. Churn and mid-handshake drops recycle the
//! slot pool for real. The loop logic under test is OS-neutral. Only the
//! backend beneath it is selected for the host. The scripted-backend suites live
//! beside this file in `completion_loop_{backpressure,stream,reclaim}_test.zig`.

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

const fixtures = @import("../support/completion_loop_fixtures.zig");
const startSession = fixtures.startSession;
const makeServerPeer = fixtures.makeServerPeer;
const frame_cap = fixtures.frame_cap;
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
    try std.testing.expectEqual(try First.fdFromId(0), First.fdFromComptimeId(0));
    try std.testing.expectError(error.AdapterHandleExhausted, First.fdFromId(First.max_fd_id + 1));
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

    const first_token = First.borrowToken(3);
    const second_token = Second.borrowToken(3);
    try std.testing.expect(First.ownsBorrowToken(first_token));
    try std.testing.expect(!First.ownsBorrowToken(second_token));
    try std.testing.expect(Second.ownsBorrowToken(second_token));
    try std.testing.expect(!Second.ownsBorrowToken(first_token));
    try std.testing.expectEqual(@as(u32, 3), First.borrowTokenPayload(first_token));
    try std.testing.expectEqual(@as(u32, 3), Second.borrowTokenPayload(second_token));
}

test "completion backend: a wake-channel nudge completes an armed recv" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var backend = try glowcap.net.Backend.init(allocator, 8, 2, frame_cap);
    defer backend.deinit();
    const wake = try glowcap.net.wake_channel.WakeChannel.open();
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
    try std.testing.expectEqual(@as(usize, 1), received.borrowed.recvBytes().?.len);
    backend.recycleBorrowed(received);
}

test "completion backend: cancel retires an exact recv without closing its fd" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var backend = try glowcap.net.Backend.init(allocator, 8, 2, frame_cap);
    defer backend.deinit();
    const wake = try glowcap.net.wake_channel.WakeChannel.open();
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
            if (item.borrowed.active()) backend.recycleBorrowed(item);
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
    backend.recycleBorrowed(completions[0]);
}

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
    // close was discarded here, and this test has no assertion of its own, so
    // it went green on a loop that had died.
    if (loop_err) |err| return err;
    if (first_err) |err| return err;
}

const actors = glowcap.actors;

/// The object hosted on the loop: answers `greet(name)` with a greeting built in
/// the turn arena. This is an ordinary `actors` behavior, the same kind the
/// blocking driver runs, hosted on the completion loop.
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
        // fetches, as `driver.Session.publish` does, here on the loop.
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

    // Heavy reuse: more lifecycles than slots, in waves, so each
    // slot is torn down and re-accepted many times. This is the real stress of
    // the deferred-teardown + slot-reuse machinery the unit path only grazes,
    // if teardown ever stranded a slot (the backend close-while-recv-armed
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
        // A tiny ring: one dispatch batch arms far more
        // operations than eight SQ entries hold, so this churn also pins the
        // io_uring backend's submission-queue self-healing, without the
        // mid-batch flush in `getSqe`, a full queue would close healthy
        // connections (or kill the accept re-arm, and with it the loop) long
        // before the waves complete. Readiness backends ignore the hint.
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
/// This is the exact teardown path the completion-backend close-while-recv-armed
/// bugs lived in. Under churn it must drain both ops and reclaim the slot, never
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

test "completion loop: listener sets SO_REUSEADDR without SO_REUSEPORT" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    var loop = try Loop.init(allocator, makeServerPeer, null, .{
        .max_conns = 4,
        .listen = 0,
    });
    defer loop.deinit();

    // SO_REUSEADDR permits a pinned-port restart after prior connections enter
    // TIME_WAIT. SO_REUSEPORT would instead permit two identity-bearing Hosts
    // to own the address concurrently, so prove the completion socket did not
    // opt into it.
    const fd = loop.listen_fd.?;
    const sys = std.posix.system;
    var value: c_int = 0;
    var len: std.posix.socklen_t = @sizeOf(c_int);
    const rc = sys.getsockopt(fd, sys.SOL.SOCKET, sys.SO.REUSEADDR, @ptrCast(&value), &len);
    try std.testing.expect(rc == 0);
    try std.testing.expect(value != 0);
    if (@hasDecl(std.posix.SO, "REUSEPORT")) {
        value = 0;
        len = @sizeOf(c_int);
        const reuse_port_rc = sys.getsockopt(fd, sys.SOL.SOCKET, sys.SO.REUSEPORT, @ptrCast(&value), &len);
        try std.testing.expect(reuse_port_rc == 0);
        try std.testing.expectEqual(@as(c_int, 0), value);
    }
}
