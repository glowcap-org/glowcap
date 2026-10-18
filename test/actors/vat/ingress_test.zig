//! Ingress scheduling: driveBudgeted yields after its quantum, rotation is
//! fair with FIFO inside each ingress, admission is atomic, an ingress
//! closes only after its work drains, and chunk reclamation never recycles
//! what an outer turn still borrows.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const actors = glowcap.actors;
const Turn = actors.Turn;
const Message = actors.Message;
const Delivery = actors.Delivery;
const cross_peer = @import("../../support/cross_peer.zig");
const peer_fixture = @import("../../support/peer_fixture.zig");
const poison = @import("../../support/poison.zig");

const harness = @import("harness.zig");
const Counter = harness.Counter;
const Greeter = harness.Greeter;
const getN = harness.getN;
const Forwarder = harness.Forwarder;
const MutateThenRead = harness.MutateThenRead;
const Sink = harness.Sink;
const LabelHolder = harness.LabelHolder;
const PersistentCounter = harness.PersistentCounter;

test "vat id exhaustion refuses before publishing local actor or queued vow" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    vat.actor_ids.next = std.math.maxInt(u64);
    try std.testing.expectError(
        actors.Error.ResourceExhausted,
        vat.spawn(Counter, .{ .n = 0 }),
    );
    try std.testing.expectEqual(@as(usize, 0), vat.actors.count());

    vat.actor_ids.next = 1;
    const counter = try vat.spawn(Counter, .{ .n = 0 });
    vat.vow_ids.next = std.math.maxInt(u64);
    try std.testing.expectError(
        actors.Error.ResourceExhausted,
        vat.send(counter, .{ .verb = "increment" }),
    );
    try std.testing.expectEqual(@as(usize, 0), vat.pending_local_vows.count());
    try std.testing.expectEqual(std.math.maxInt(u64), vat.vow_ids.next);
}

test "driveBudgeted runs at most N queued turns then yields the rest to the next call" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const counter = try vat.spawn(Counter, .{ .n = 0 });
    // Queue five turns; a budget of two must run exactly two, leave three.
    for (0..5) |_| try vat.tell(counter, .{ .verb = "increment" });

    try std.testing.expectEqual(actors.Vat.DriveProgress.more_pending, try vat.driveBudgeted(2));
    try std.testing.expectEqual(@as(i64, 2), (try vat.near(counter, .{ .verb = "get" })).integer);

    try std.testing.expectEqual(actors.Vat.DriveProgress.more_pending, try vat.driveBudgeted(2));
    try std.testing.expectEqual(@as(i64, 4), (try vat.near(counter, .{ .verb = "get" })).integer);

    // The remaining one turn fits the budget, so the queue drains fully.
    try std.testing.expectEqual(actors.Vat.DriveProgress.drained, try vat.driveBudgeted(2));
    try std.testing.expectEqual(@as(i64, 5), (try vat.near(counter, .{ .verb = "get" })).integer);

    // A drained queue reports `.drained` even with budget to spare.
    try std.testing.expectEqual(actors.Vat.DriveProgress.drained, try vat.driveBudgeted(2));
}

const OrderActor = struct {
    order: [16]u8 = undefined,
    len: usize = 0,

    pub fn handle(self: *OrderActor, turn: *Turn, msg: Delivery) !model.Argument {
        _ = turn;
        if (std.mem.eql(u8, msg.verb, "record")) {
            self.order[self.len] = @intCast(try msg.argInt(0));
            self.len += 1;
            return .{ .void = {} };
        }
        if (std.mem.eql(u8, msg.verb, "order")) return .{ .bytes = self.order[0..self.len] };
        return error.NoSuchMethod;
    }
};

test "ingress scheduling rotates fairly and preserves FIFO within each ingress" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();
    const a = try vat.openIngress();
    const b = try vat.openIngress();
    defer vat.closeIngress(a) catch unreachable;
    defer vat.closeIngress(b) catch unreachable;
    const recorder = try vat.spawn(OrderActor, .{});

    for ([_]i64{ 1, 2, 3 }) |value| {
        try vat.tellFromIngress(a, recorder, .{ .verb = "record", .args = &.{.{ .integer = value }} });
    }
    for ([_]i64{ 10, 11, 12 }) |value| {
        try vat.tellFromIngress(b, recorder, .{ .verb = "record", .args = &.{.{ .integer = value }} });
    }

    try std.testing.expectEqual(actors.Vat.DriveProgress.drained, try vat.driveBudgeted(6));
    const order = (try vat.near(recorder, .{ .verb = "order" })).bytes;
    try std.testing.expectEqualSlices(u8, &.{ 1, 10, 2, 11, 3, 12 }, order);
}

test "ingress turn and byte admission refuse atomically" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.initWithOptions(allocator, .{ .queue_limits = .{
        .max_pending_turns = 2,
        .max_pending_bytes = 256,
        .max_chunk_bytes = 256,
    } });
    defer vat.deinit();
    const ingress = try vat.openIngress();
    defer vat.closeIngress(ingress) catch unreachable;
    const counter = try vat.spawn(Counter, .{ .n = 0 });

    try vat.tellFromIngress(ingress, counter, .{ .verb = "increment" });
    try vat.tellFromIngress(ingress, counter, .{ .verb = "increment" });
    try std.testing.expectError(
        actors.Error.ResourceExhausted,
        vat.tellFromIngress(ingress, counter, .{ .verb = "increment" }),
    );
    try std.testing.expectEqual(@as(usize, 2), vat.ingresses.get(ingress).?.pending_turns);
    try vat.drive();
    try std.testing.expectEqual(@as(i64, 2), (try vat.near(counter, .{ .verb = "get" })).integer);

    // Exercise the cumulative byte cap independently of the single-chunk cap:
    // one message fits, while a second identical message would cross only the
    // per-ingress pending-byte total.
    const payload = @as([64]u8, @splat(0xaa));
    vat.queue_limits = .{
        .max_pending_turns = 8,
        .max_pending_bytes = 4096,
        .max_chunk_bytes = 4096,
    };
    try vat.tellFromIngress(ingress, counter, .{ .verb = "increment", .args = &.{.{ .bytes = &payload }} });
    const one_turn_bytes = vat.ingresses.get(ingress).?.pending_bytes;
    vat.queue_limits.max_pending_bytes = one_turn_bytes * 2 - 1;
    try std.testing.expectError(
        actors.Error.ResourceExhausted,
        vat.tellFromIngress(ingress, counter, .{ .verb = "increment", .args = &.{.{ .bytes = &payload }} }),
    );
    try std.testing.expectEqual(@as(usize, 1), vat.ingresses.get(ingress).?.pending_turns);
    try std.testing.expectEqual(one_turn_bytes, vat.ingresses.get(ingress).?.pending_bytes);
    try vat.drive();
    try std.testing.expectEqual(@as(i64, 3), (try vat.near(counter, .{ .verb = "get" })).integer);

    // The orthogonal single-message chunk cap also refuses before mutation.
    vat.queue_limits.max_pending_bytes = 4096;
    vat.queue_limits.max_chunk_bytes = one_turn_bytes - 1;
    try std.testing.expectError(
        actors.Error.ResourceExhausted,
        vat.tellFromIngress(ingress, counter, .{ .verb = "increment", .args = &.{.{ .bytes = &payload }} }),
    );
    try std.testing.expectEqual(@as(usize, 0), vat.ingresses.get(ingress).?.pending_turns);
    try std.testing.expectEqual(@as(usize, 0), vat.ingresses.get(ingress).?.pending_bytes);
    try std.testing.expectEqual(@as(i64, 3), (try vat.near(counter, .{ .verb = "get" })).integer);
}

test "an ingress closes only after its queued work drains" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();
    const ingress = try vat.openIngress();
    const counter = try vat.spawn(Counter, .{ .n = 0 });

    try vat.tellFromIngress(ingress, counter, .{ .verb = "increment" });
    try std.testing.expectError(actors.Error.IngressBusy, vat.closeIngress(ingress));
    try vat.drive();
    try vat.closeIngress(ingress);
    try std.testing.expectError(actors.Error.UnknownIngress, vat.closeIngress(ingress));
    try std.testing.expectError(
        actors.Error.UnknownIngress,
        vat.tellFromIngress(ingress, counter, .{ .verb = "increment" }),
    );
}

test "a fresh ingress has an infallible transaction rollback" {
    var vat = actors.Vat.init(std.testing.allocator);
    defer vat.deinit();

    const ingress = try vat.openIngress();
    vat.discardFreshIngress(ingress);
    try std.testing.expectError(actors.Error.UnknownIngress, vat.closeIngress(ingress));
}

const CloseDuringTurn = struct {
    ingress: actors.IngressId,
    saw_busy: bool = false,

    pub fn handle(self: *CloseDuringTurn, turn: *Turn, msg: Delivery) !model.Argument {
        _ = msg;
        turn.vat.closeIngress(self.ingress) catch |err| {
            if (err != actors.Error.IngressBusy) return err;
            self.saw_busy = true;
            return .{ .void = {} };
        };
        return error.ClosedActiveIngress;
    }
};

test "an ingress cannot close during its synchronous turn" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();
    const ingress = try vat.openIngress();
    const actor = try vat.spawn(CloseDuringTurn, .{ .ingress = ingress });

    _ = try vat.nearFromIngress(ingress, actor, .{ .verb = "close" });
    const state: *CloseDuringTurn = @ptrCast(@alignCast(vat.actors.get(actor.local).?.box.ptr));
    try std.testing.expect(state.saw_busy);
    try vat.closeIngress(ingress);
}

const CausalFanout = struct {
    sink: actors.Ref,
    refused: bool = false,

    pub fn handle(self: *CausalFanout, turn: *Turn, msg: Delivery) !model.Argument {
        if (std.mem.eql(u8, msg.verb, "fan")) {
            _ = try turn.send(self.sink, .{ .verb = "increment" });
            _ = turn.send(self.sink, .{ .verb = "increment" }) catch |err| {
                if (err != actors.Error.ResourceExhausted) return err;
                self.refused = true;
                return .{ .void = {} };
            };
            return .{ .void = {} };
        }
        if (std.mem.eql(u8, msg.verb, "refused")) return .{ .boolean = self.refused };
        return error.NoSuchMethod;
    }
};

test "causal sends stay charged to the turn ingress" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.initWithOptions(allocator, .{ .queue_limits = .{ .max_pending_turns = 1 } });
    defer vat.deinit();
    const ingress = try vat.openIngress();
    defer vat.closeIngress(ingress) catch unreachable;
    const counter = try vat.spawn(Counter, .{ .n = 0 });
    const fanout = try vat.spawn(CausalFanout, .{ .sink = counter });

    try vat.tellFromIngress(ingress, fanout, .{ .verb = "fan" });
    try std.testing.expectEqual(actors.Vat.DriveProgress.more_pending, try vat.driveBudgeted(1));
    try std.testing.expect((try vat.near(fanout, .{ .verb = "refused" })).boolean);
    try std.testing.expectEqual(@as(usize, 1), vat.ingresses.get(ingress).?.pending_turns);
    try std.testing.expectEqual(@as(usize, 0), vat.local_ingress.pending_turns);
    try vat.drive();
    try std.testing.expectEqual(@as(i64, 1), (try vat.near(counter, .{ .verb = "get" })).integer);
}

test "a completed ingress chunk is reclaimed while another ingress remains runnable" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.initWithOptions(allocator, .{ .queue_limits = .{
        .max_pending_turns = 8,
        .max_pending_bytes = 4096,
        .max_chunk_bytes = 240,
    } });
    defer vat.deinit();
    const a = try vat.openIngress();
    const b = try vat.openIngress();
    defer vat.closeIngress(a) catch unreachable;
    defer vat.closeIngress(b) catch unreachable;
    const counter = try vat.spawn(Counter, .{ .n = 0 });
    const payload = @as([96]u8, @splat(0x5a));

    try vat.tellFromIngress(a, counter, .{ .verb = "increment", .args = &.{.{ .bytes = &payload }} });
    try vat.tellFromIngress(b, counter, .{ .verb = "increment", .args = &.{.{ .bytes = &payload }} });
    try vat.tellFromIngress(b, counter, .{ .verb = "increment", .args = &.{.{ .bytes = &payload }} });
    try std.testing.expectEqual(actors.Vat.DriveProgress.more_pending, try vat.driveBudgeted(2));
    try std.testing.expect(vat.ingresses.get(a).?.first == null);
    try std.testing.expectEqual(@as(usize, 1), vat.ingresses.get(b).?.pending_turns);
    try std.testing.expect(vat.spare_chunk != null);
    try vat.drive();
}

const ReentrantChunkBorrow = struct {
    observed: [16]u8 = undefined,
    observed_len: usize = 0,

    pub fn handle(self: *ReentrantChunkBorrow, turn: *Turn, msg: Delivery) !model.Argument {
        if (std.mem.eql(u8, msg.verb, "outer")) {
            // Drain the next row in this same chunk. Once it exhausts the chunk,
            // enqueue again to force an incorrect early spare to be reused and
            // overwrite the outer message before we read it.
            try turn.vat.drive();
            _ = try turn.send(turn.me(), .{ .verb = "after", .args = &.{.{ .bytes = "OVERWRITE" }} });
            const original = try msg.argBytes(0);
            @memcpy(self.observed[0..original.len], original);
            self.observed_len = original.len;
            return .{ .void = {} };
        }
        if (std.mem.eql(u8, msg.verb, "inner") or std.mem.eql(u8, msg.verb, "after")) return .{ .void = {} };
        if (std.mem.eql(u8, msg.verb, "observed")) return .{ .bytes = self.observed[0..self.observed_len] };
        return error.NoSuchMethod;
    }
};

test "a nested drive cannot recycle a chunk still borrowed by its outer turn" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();
    const actor = try vat.spawn(ReentrantChunkBorrow, .{});

    try vat.tell(actor, .{ .verb = "outer", .args = &.{.{ .bytes = "ORIGINAL" }} });
    try vat.tell(actor, .{ .verb = "inner" });
    try vat.drive();

    const observed = (try vat.near(actor, .{ .verb = "observed" })).bytes;
    try std.testing.expectEqualStrings("ORIGINAL", observed);
}
