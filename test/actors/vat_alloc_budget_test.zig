//! Actor-layer allocation budgets.
//!
//! Exact contracts, not upper bounds, over the vat's turn and settle paths:
//! a warmed local settle window is bump-only (zero gpa allocations), a
//! common-arity far send pays exactly the `sendCopying` boundary clone, and a
//! persistent actor's `become` turn pays exactly the one merged box+state
//! block. A regression in *either* direction fails.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const actors = pancake.actors;
const Turn = actors.Turn;
const Message = actors.Message;
const CountingAllocator = @import("../support/alloc_metrics.zig").CountingAllocator;
const promise_capture = @import("../support/capture.zig");

/// Replies with a fresh turn-arena byte string, the documented handler
/// pattern: the reply must be cloned for the settling listener, and where
/// that clone lands is exactly what the budget below pins.
const ArenaReplier = struct {
    pub fn handle(self: *ArenaReplier, turn: *Turn, msg: Message) !model.Argument {
        _ = self;
        return .{ .bytes = try std.fmt.allocPrint(turn.arena, "echo-{s}", .{msg.arg(0).bytes}) };
    }
};

const ByteCapture = promise_capture.CapturedBytes;

test "a warmed local settle window costs zero gpa allocations" {
    var counter = CountingAllocator{ .backing = std.testing.allocator };
    var vat = actors.Vat.init(counter.allocator());
    defer vat.deinit();

    const replier = try vat.spawn(ArenaReplier, .{});
    var captured = ByteCapture{};

    // Warm: grow the send queue, the listener table, the turn arena (handler
    // reply), and the queue arena (queued-message clone + settle clone) so
    // the measured window sees only steady-state traffic.
    for (0..8) |_| {
        const promise = try vat.send(replier, .{ .verb = "echo", .args = &.{.{ .bytes = "payload" }} });
        try vat.on(promise, .{ .ctx = &captured, .func = ByteCapture.record });
        try vat.drive();
    }

    // The exact contract: the settle window — `drive` running the queued
    // turn, `settleLocal` cloning the fulfilled bytes for the listener, the
    // listener call, and the end-of-drive queue/arena resets — is bump-only.
    // The queued message is read from the queue arena, the handler's reply
    // lives in the warmed turn arena, and the settle clone lands in the
    // warmed queue arena, so nothing in the window touches the gpa. The
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

test "a common-arity far send pays exactly the sendCopying clone, no scratch spine" {
    var counter = CountingAllocator{ .backing = std.testing.allocator };
    var pair = try engine.pairing.paired(counter.allocator());
    defer pair.deinit();
    try pair.p1.importObject(5);

    var vat = actors.Vat.initOver(counter.allocator(), &pair.p1);
    defer vat.deinit();
    const remote: actors.Ref = .{ .far = model.FarRef.object(5) };

    // Seven args — the widest arity the stack buffer carries with a verb.
    const args = [7]model.Argument{
        .{ .bytes = "payload" }, .{ .integer = 1 }, .{ .integer = 2 },
        .{ .integer = 3 },       .{ .integer = 4 }, .{ .integer = 5 },
        .{ .integer = 6 },
    };

    // Warm one send/encode cycle so the pending-send queue's steady backing
    // (retained at drain-reset because it sits under the engine's 4096-byte
    // burst-release bound) and the encode buffers exist before measurement.
    try vat.tell(remote, .{ .verb = "poke", .args = &args });
    while (true) {
        _ = try pair.p1.step();
        var frame = pair.p1.takeOutbound() orelse break;
        frame.deinit();
    }

    // The exact contract: a ≤7-arg far send costs only `sendCopying`'s
    // boundary clone of the message — (1) the owned args spine, (2) the verb
    // symbol dupe, (3) the bytes payload dupe; the six integer args are POD
    // and the far target/no-answer carry no heap. The verb-splice scratch
    // spine rides `farDeliverTo`'s stack buffer, so it no longer appears
    // here. Each send is measured alone and the queue drained between them
    // (encoding outside the window), because the engine's steady-queue bound
    // keeps only one queued message's slot warm — queue growth on
    // back-to-back sends is engine footprint policy, not vat scratch.
    const sends = 4;
    var send_allocs: usize = 0;
    for (0..sends) |_| {
        counter.allocs = 0;
        try vat.tell(remote, .{ .verb = "poke", .args = &args });
        send_allocs += counter.allocs;
        while (true) {
            _ = try pair.p1.step();
            var frame = pair.p1.takeOutbound() orelse break;
            frame.deinit();
        }
    }
    try std.testing.expectEqual(@as(usize, 3 * sends), send_allocs);
}

/// A persistent counter: every `increment` turn stages a `become`, whose whole
/// cost the budget below pins to the one merged box+state block.
const PersistentCounter = struct {
    pub const snapshot_persistent = true;
    n: i64,

    pub fn handle(self: *const PersistentCounter, turn: *Turn, msg: Message) !model.Argument {
        if (std.mem.eql(u8, msg.verb, "get")) return .{ .integer = self.n };
        if (std.mem.eql(u8, msg.verb, "increment")) {
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

    // The exact contract: one near-call turn that becomes allocates once —
    // `makeBox`'s single `Boxed` block carrying the `StateBox` header and the
    // next state side by side. Installing the become frees the old block;
    // frees are not allocations, so the box/state merge shows up here as
    // exactly 1 where the split box + state pair cost 2.
    counter.allocs = 0;
    _ = try vat.near(actor, .{ .verb = "increment" });
    try std.testing.expectEqual(@as(usize, 1), counter.allocs);
    try std.testing.expectEqual(@as(i64, 2), (try vat.near(actor, .{ .verb = "get" })).integer);
}
