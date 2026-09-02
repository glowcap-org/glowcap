//! Reclaiming a closing slot: the terminal drain ignores a late completion
//! from the already-armed recv, is bounded out of the box, counts deadlines
//! only for connections actually waiting, reclaims a drain the partner never
//! reads, and escalates a second close to a hard close.
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
const drainOutboundBytes = backend_support.drainOutboundBytes;
const drainOutboundStreamBytes = backend_support.drainOutboundStreamBytes;

test "close-slot: terminal drain ignores a late completion from the already-armed recv" {
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
    _ = try client.recvStreamPrefix(server_ss.items);
    fetch_pump.drainEvents(&client);

    var fetch_bytes: std.ArrayList(u8) = .empty;
    defer fetch_bytes.deinit(allocator);
    const prepared = try engine.fetch.prepareFetchSwissnum(allocator, &client.session_state, "thermostat");
    try client.send(prepared.message);
    try drainOutboundStreamBytes(&client, allocator, &fetch_bytes);

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
    const defaults: completion.Options = .{ .max_conns = 1, .listen = 0 };
    try std.testing.expect(defaults.drain_kill_ms != null);
}

test "close-slot: the deadline count tracks only connections actually waiting" {
    const allocator = std.testing.allocator;

    var client = engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = false });
    defer client.deinit();
    client.session_state.limits.max_frame_bytes = frame_cap;
    var client_ss: std.ArrayList(u8) = .empty;
    defer client_ss.deinit(allocator);
    try client.sendCopying(startSession("client"));
    try drainOutboundStreamBytes(&client, allocator, &client_ss);

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
    try drainOutboundStreamBytes(&client, allocator, &client_ss);

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

    var loop = try completion.Loop(CrossArmBackend, no_dial.Unsupported).init(allocator, makeServerPeer, null, .{
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
    try drainOutboundStreamBytes(&client, allocator, &client_ss);

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
