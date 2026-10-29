//! Actor-layer allocation budgets.
//!
//! Exact contracts, not upper bounds, over the vat's turn and settle paths:
//! a warmed local settle window is bump-only (zero gpa allocations), a
//! common-arity far send pays exactly its wire frame, and a persistent
//! actor's `become` turn pays exactly the one merged box+state block. A
//! regression in *either* direction fails.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const actors = glowcap.actors;
const Turn = actors.Turn;
const Message = actors.Message;
const Delivery = actors.Delivery;
const CountingAllocator = @import("../support/alloc_metrics.zig").CountingAllocator;
const LiveBytesAllocator = @import("../support/alloc_metrics.zig").LiveBytesAllocator;
const promise_capture = @import("../support/capture.zig");

/// Replies with a fresh turn-arena byte string, the documented handler
/// pattern: the reply must be cloned for the settling listener, and where
/// that clone lands is exactly what the budget below pins.
const ArenaReplier = struct {
    pub fn handle(self: *ArenaReplier, turn: *Turn, msg: Delivery) !model.Argument {
        _ = self;
        return .{ .bytes = try std.fmt.allocPrint(turn.arena, "echo-{s}", .{try msg.argBytes(0)}) };
    }
};

const ByteCapture = promise_capture.CapturedBytes;

test "a warmed local settle window costs zero gpa allocations" {
    var counter = CountingAllocator{ .backing = std.testing.allocator };
    var vat = actors.Vat.init(counter.allocator());
    defer vat.deinit();

    const replier = try vat.spawn(ArenaReplier, .{});
    var captured = ByteCapture{};

    // Warm: grow the spare queue chunk, the listener table, the turn arena
    // (handler reply), and the settle arena so
    // the measured window sees only steady-state traffic.
    for (0..8) |_| {
        const promise = try vat.send(replier, .{ .verb = "echo", .args = &.{.{ .bytes = "payload" }} });
        try vat.on(promise, .{ .ctx = &captured, .func = ByteCapture.record });
        try vat.drive();
    }

    // The exact contract: the settle window, `drive` running the queued
    // turn, `settleLocal` cloning the fulfilled bytes for the listener, the
    // listener call, chunk reclamation, and the settlement-arena reset, is
    // bump-only.
    // The queued message is read from the chunk arena, the handler's reply
    // lives in the warmed turn arena, and the settle clone lands in the
    // warmed settle arena, so nothing in the window touches the gpa. The
    // send/on half stays outside the window: its queue append and listener
    // insert are vat bookkeeping, not the settle path.
    const turns = 8;
    var window_allocs: usize = 0;
    for (0..turns) |_| {
        const promise = try vat.send(replier, .{ .verb = "echo", .args = &.{.{ .bytes = "payload" }} });
        try vat.on(promise, .{ .ctx = &captured, .func = ByteCapture.record });
        counter.allocs = 0;
        try vat.drive();
        window_allocs += counter.allocs;
    }
    try std.testing.expectEqual(@as(usize, 0), window_allocs);
    try std.testing.expectEqualStrings("echo-payload", captured.buf[0..captured.len]);
}

test "a warmed local queue batch costs zero gpa allocations" {
    var counter = CountingAllocator{ .backing = std.testing.allocator };
    var vat = actors.Vat.init(counter.allocator());
    defer vat.deinit();
    const replier = try vat.spawn(ArenaReplier, .{});

    // Warm the one Vat-wide spare chunk, its bounded payload arena, and the
    // pending-vow index. No idle ingress retains its own spare.
    for (0..8) |_| {
        try vat.tell(replier, .{ .verb = "echo", .args = &.{.{ .bytes = "payload" }} });
        try vat.drive();
    }

    counter.allocs = 0;
    try vat.tell(replier, .{ .verb = "echo", .args = &.{.{ .bytes = "payload" }} });
    try vat.drive();
    try std.testing.expectEqual(@as(usize, 0), counter.allocs);
}

test "a completed chunk frees live bytes while another ingress remains runnable" {
    var live = LiveBytesAllocator{ .backing = std.testing.allocator };
    var vat = actors.Vat.init(live.allocator());
    defer vat.deinit();
    const replier = try vat.spawn(ArenaReplier, .{});

    // Pre-warm the single Vat-wide spare. In the measured episode the first
    // completed chunk occupies that spare and a later completed chunk must be
    // returned to the allocator, even though ingress b still has work.
    try vat.tell(replier, .{ .verb = "echo", .args = &.{.{ .bytes = "payload" }} });
    try vat.drive();
    const a = try vat.openIngress();
    const b = try vat.openIngress();
    const c = try vat.openIngress();
    defer vat.closeIngress(a) catch unreachable;
    defer vat.closeIngress(b) catch unreachable;
    defer vat.closeIngress(c) catch unreachable;

    try vat.tellFromIngress(a, replier, .{ .verb = "echo", .args = &.{.{ .bytes = "payload" }} });
    try vat.tellFromIngress(b, replier, .{ .verb = "echo", .args = &.{.{ .bytes = "payload" }} });
    try vat.tellFromIngress(b, replier, .{ .verb = "echo", .args = &.{.{ .bytes = "payload" }} });
    try vat.tellFromIngress(c, replier, .{ .verb = "echo", .args = &.{.{ .bytes = "payload" }} });
    const before = live.liveBytes();

    try std.testing.expectEqual(actors.Vat.DriveProgress.more_pending, try vat.driveBudgeted(3));
    try std.testing.expect(vat.ingresses.get(a).?.first == null);
    try std.testing.expect(vat.ingresses.get(c).?.first == null);
    try std.testing.expectEqual(@as(usize, 1), vat.ingresses.get(b).?.pending_turns);
    try std.testing.expect(live.liveBytes() < before);
    try vat.drive();
}

test "a common-arity far send allocates its frame and nothing else" {
    var counter = CountingAllocator{ .backing = std.testing.allocator };
    var pair = try engine.pairing.paired(counter.allocator());
    defer pair.deinit();
    try pair.p1.importObject(5);

    var vat = actors.Vat.init(counter.allocator());
    defer vat.deinit();
    var port = actors.Port.init(counter.allocator(), &pair.p1);
    defer port.deinit(&vat);
    const remote: actors.Ref = .{ .far = model.FarRef.object(5) };

    // Seven args, the widest arity the stack buffer carries with a verb.
    const args = [7]model.Argument{
        .{ .bytes = "payload" }, .{ .integer = 1 }, .{ .integer = 2 },
        .{ .integer = 3 },       .{ .integer = 4 }, .{ .integer = 5 },
        .{ .integer = 6 },
    };

    // Warm one send/encode cycle so the pending-send queue's steady backing
    // (retained at drain-reset because it sits under the engine's 4096-byte
    // burst-release bound) and the encode buffers exist before measurement.
    try port.tell(&vat, remote, .{ .verb = "poke", .args = &args });
    while (true) {
        _ = try pair.p1.step();
        var frame = pair.p1.takeOutbound() orelse break;
        frame.deinit();
    }

    // The exact contract: a ≤7-arg far send costs only its wire frame,
    // encoded at admission from the caller's borrowed arguments
    // (ADR-0064). The tree with no reference lists nothing, so the inventory
    // allocates nothing, and the verb-splice scratch spine rides
    // `farDeliverTo`'s stack buffer. Each send is measured alone and the
    // queue drained between them, because the engine's steady-queue bound
    // keeps only one queued row's slot warm, queue growth on back-to-back
    // sends is engine footprint policy, not vat scratch.
    const sends = 4;
    var send_allocs: usize = 0;
    for (0..sends) |_| {
        counter.allocs = 0;
        try port.tell(&vat, remote, .{ .verb = "poke", .args = &args });
        send_allocs += counter.allocs;
        while (true) {
            _ = try pair.p1.step();
            var frame = pair.p1.takeOutbound() orelse break;
            frame.deinit();
        }
    }
    try std.testing.expectEqual(@as(usize, 1 * sends), send_allocs);
}

/// A persistent counter: every `increment` turn stages a `become`, whose whole
/// cost the budget below pins to the one merged box+state block.
const PersistentCounter = struct {
    pub const snapshot_persistent = true;
    n: i64,

    pub fn handle(self: *const PersistentCounter, turn: *Turn, msg: Delivery) !model.Argument {
        if (msg.is("get")) return .{ .integer = self.n };
        if (msg.is("increment")) {
            try turn.become(PersistentCounter, .{ .n = self.n + 1 });
            return .{ .void = {} };
        }
        return error.NoSuchMethod;
    }
};

test "a persistent become turn costs exactly one gpa allocation, the merged block" {
    var counter = CountingAllocator{ .backing = std.testing.allocator };
    var vat = actors.Vat.init(counter.allocator());
    defer vat.deinit();

    const actor = try vat.spawn(PersistentCounter, .{ .n = 0 });
    // Warm the turn arena so the measured turn's `beginTurn` reset retains.
    _ = try vat.near(actor, .{ .verb = "increment" });

    // The exact contract: one near-call turn that becomes allocates once,
    // `makeBox`'s single `Boxed` block carrying the `StateBox` header and the
    // next state side by side. Installing the become frees the old block; status-allow: replacement state identity
    // frees are not allocations, so the box/state merge shows up here as
    // exactly 1 where the split box + state pair cost 2.
    counter.allocs = 0;
    _ = try vat.near(actor, .{ .verb = "increment" });
    try std.testing.expectEqual(@as(usize, 1), counter.allocs);
    try std.testing.expectEqual(@as(i64, 2), (try vat.near(actor, .{ .verb = "get" })).integer);
}
