//! The completion loop's cross-connection outbound arm (`Loop.armOutbound`):
//! a hook serving connection A that enqueued sends on connection B's peer
//! arms B's write without waiting for B's own traffic. Proven twice: end to
//! end on the platform backend (a quiet partner receives a frame only
//! cross-arming could have put on its wire), and on a scripted backend that
//! pins the queue accounting. Cross-armed bytes count into the connection's
//! pending outbound, so ADR-0017 parks that connection's next read at the
//! high-water mark exactly as it parks reply traffic.

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

const frame_cap = 4096;

const backend_support = @import("cross_arm_backend.zig");
const CrossArmBackend = backend_support.CrossArmBackend;
const startSession = backend_support.startSession;
const makeServerPeer = backend_support.makeServerPeer;
const pumpStream = backend_support.pumpStream;
const drainOutboundStreamBytes = backend_support.drainOutboundStreamBytes;

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
    /// its outbound, mid-dispatch, from another connection's event.
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
    const designator = tcp.locatorFromAddress(&designator_buf, designator_addr).designator;
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
        .max_conns = 8,
        .listen = 0,
        .make_conn_ctx = Shared.make,
        .serve = Shared.serve,
    });
    defer loop.deinit();
    shared.loop = &loop;
    const port = loop.port().?;

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
    const designator = tcp.locatorFromAddress(&designator_buf, designator_addr).designator;
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

// ── Scripted: cross-armed bytes ride the ADR-0017 queue accounting ──────────

test "cross-arm: cross-armed bytes count into pending outbound and park the read at the high-water mark" {
    const allocator = std.testing.allocator;

    // The scripted client's two frames: its start-session, then a fetch of the
    // shared bootstrap cap, both admissible against `makeServerPeer`'s session.
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

    var fetch_bytes: std.ArrayList(u8) = .empty;
    defer fetch_bytes.deinit(allocator);
    const prepared = try engine.fetch.prepareFetchSwissnum(allocator, &client.session_state, "thermostat");
    try client.send(prepared.message);
    try drainOutboundStreamBytes(&client, allocator, &fetch_bytes);

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
        .max_conns = 4,
        .listen = 0,
        .outbound_high_water_bytes = high_water,
    });
    defer loop.deinit();

    // Phase 1: the connection opens, its hello drains, its start-session
    // applies, and its next read arms with nothing scripted behind it, the
    // quiet-partner steady state.
    try std.testing.expectError(error.ScriptParked, loop.run(.{ .after_closed = 1 }));
    const conn = &loop.conns[0];
    try std.testing.expect(conn.state == .open);
    try std.testing.expect(conn.read == .armed);
    try std.testing.expectEqual(@as(usize, 0), conn.front.items.len - conn.front_off + conn.back.items.len);

    // Phase 2: cross-arm from outside the loop's own dispatch, enqueue a
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
    // parks at the high-water mark, ADR-0017 holds for cross-armed bytes.
    CrossArmBackend.hold_sends = true;
    CrossArmBackend.chunks = &.{ client_ss.items, fetch_bytes.items };
    try std.testing.expectError(error.ScriptParked, loop.run(.{ .after_closed = 1 }));
    try std.testing.expect(conn.read == .parked);
    try std.testing.expect(conn.front.items.len - conn.front_off + conn.back.items.len > high_water);

    // Phase 4: the slow reader drains and the script ends. The parked read
    // resumes, meets the clean EOF, and the connection closes whole, every
    // in-flight op retired, so `deinit`'s accounting stays green.
    CrossArmBackend.hold_sends = false;
    CrossArmBackend.eof_when_exhausted = true;
    try loop.run(.{ .after_closed = 1 });
    try std.testing.expectEqual(@as(usize, 1), loop.closed_count);
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
    try client.sendBorrowed(startSession("client"));
    try drainOutboundStreamBytes(&client, allocator, &client_ss);

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
        .max_conns = 4,
        .listen = 0,
        .outbound_high_water_bytes = 16,
        .park_kill_ms = 60_000,
    });
    defer loop.deinit();

    try std.testing.expectError(error.ScriptParked, loop.run(.{ .after_closed = 1 }));
    const conn = &loop.conns[0];
    try std.testing.expect(conn.read == .parked);
    try std.testing.expect(conn.waiting_since_ms != 0);
    try std.testing.expectEqual(@as(usize, 1), loop.waiting_count);

    // The partner takes all but four bytes. Pending falls under the mark, so
    // this connection is not the slow reader the deadline is about.
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

test "cross-arm: a terminal failure with a write in flight swaps its queued tail out" {
    const allocator = std.testing.allocator;

    // `onSend`'s `.draining` arm is the only path that swaps a terminal
    // connection's back buffer into its emptied front. Reaching it needs three
    // things at once, the connection draining, a write still in flight, and
    // bytes queued behind it, and a connection normally has at most two of
    // them, which is why the arm went unexercised. Scripted, the overlap is
    // stated rather than waited for.
    var client = engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = false });
    defer client.deinit();
    client.session_state.limits.max_frame_bytes = frame_cap;
    var client_ss: std.ArrayList(u8) = .empty;
    defer client_ss.deinit(allocator);
    try client.sendBorrowed(startSession("client"));
    try drainOutboundStreamBytes(&client, allocator, &client_ss);

    // Hello, then bytes the session refuses. The refusal projects an abort
    // while the hello's reply is still held, so the abort has nowhere to go but
    // the back buffer.
    const refused = @as([24]u8, @splat(0xff));
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
        .max_conns = 4,
        .listen = 0,
        // Above the reply, so the connection does *not* park and its read
        // re-arms, otherwise the refused frame never arrives and the overlap
        // never forms.
        .outbound_high_water_bytes = 4096,
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
    // submits it, so the abort the partner is owed goes out instead
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
