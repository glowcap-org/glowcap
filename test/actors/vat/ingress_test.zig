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
        if (msg.is("record")) {
            self.order[self.len] = @intCast(try msg.argInt(0));
            self.len += 1;
            return .{ .void = {} };
        }
        if (msg.is("order")) return .{ .bytes = self.order[0..self.len] };
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

test "an ingress cannot close while a sibling turn holds staged work" {
    const Stager = struct {
        ingress: actors.IngressId,
        target: actors.Ref,

        pub fn handle(self: *@This(), turn: *Turn, msg: Delivery) !model.Argument {
            try turn.vat.tellFromIngress(self.ingress, self.target, .{ .verb = "increment" });
            try std.testing.expectError(error.IngressBusy, turn.vat.closeIngress(self.ingress));
            try std.testing.expectError(error.IngressBusy, turn.vat.cancelIngress(self.ingress, "cancel"));
            if (msg.is("fail")) return error.Refused;
            return .{ .void = {} };
        }
    };
    for ([_]bool{ false, true }) |fail| {
        var vat = actors.Vat.init(std.testing.allocator);
        defer vat.deinit();
        const ingress = try vat.openIngress();
        const counter = try vat.spawn(Counter, .{ .n = 0 });
        const stager = try vat.spawn(Stager, .{ .ingress = ingress, .target = counter });
        if (fail) {
            try std.testing.expectError(error.Refused, vat.near(stager, .{ .verb = "fail" }));
        } else {
            _ = try vat.near(stager, .{ .verb = "commit" });
            try std.testing.expectError(error.IngressBusy, vat.closeIngress(ingress));
        }
        try vat.drive();
        try std.testing.expectEqual(@as(i64, if (fail) 0 else 1), (try vat.near(counter, .{ .verb = "get" })).integer);
        try vat.closeIngress(ingress);
        try std.testing.expectEqual(@as(usize, 0), vat.pending_local_vows.count());
    }
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
        if (msg.is("fan")) {
            self.refused = false;
            _ = try turn.send(self.sink, .{ .verb = "increment" });
            _ = turn.send(self.sink, .{ .verb = "increment" }) catch |err| {
                if (err != actors.Error.ResourceExhausted) return err;
                self.refused = true;
                return .{ .void = {} };
            };
            return .{ .void = {} };
        }
        if (msg.is("refused")) return .{ .boolean = self.refused };
        return error.NoSuchMethod;
    }
};

test "live and causal sends share ingress capacity" {
    var vat = actors.Vat.init(std.testing.allocator);
    defer vat.deinit();
    const ingress = try vat.openIngress();
    const counter = try vat.spawn(Counter, .{ .n = 0 });
    const fanout = try vat.spawn(CausalFanout, .{ .sink = counter });
    const increment: Message = .{ .verb = "increment" };
    const state = vat.ingresses.get(ingress).?;

    try vat.tellFromIngress(ingress, counter, increment);
    const charge = state.pending_bytes;
    try vat.drive();

    // Each refusal runs with room under both of the other caps.
    const refusals: []const struct { limits: actors.QueueLimits, live: u32 } = &.{
        .{ .limits = .{ .max_pending_turns = 1 }, .live = 1 },
        .{ .limits = .{ .max_pending_bytes = charge * 2 - 1 }, .live = 1 },
        .{ .limits = .{ .max_pending_bytes = charge - 1 }, .live = 1 },
        .{ .limits = .{ .max_chunk_bytes = charge - 1 }, .live = 0 },
    };
    for (refusals) |run| {
        vat.queue_limits = .{};
        const before = try getN(&vat, counter);
        for (0..run.live) |_| try vat.tellFromIngress(ingress, counter, increment);
        vat.queue_limits = run.limits;
        try std.testing.expectError(error.ResourceExhausted, vat.tellFromIngress(ingress, counter, increment));
        try std.testing.expectEqual(run.live, state.pending_turns);
        try std.testing.expectEqual(charge * run.live, state.pending_bytes);
        try vat.drive();
        try std.testing.expectEqual(before + run.live, try getN(&vat, counter));
    }

    // The fanout releases its own charge when it leaves the queue. Its
    // first send takes the remaining capacity and its second is refused.
    for ([_]u32{ 0, 1 }) |live| {
        const total = live + 1;
        for ([_]actors.QueueLimits{
            .{ .max_pending_turns = total },
            .{ .max_pending_bytes = charge * total },
        }) |limits| {
            vat.queue_limits = limits;
            const before = try getN(&vat, counter);
            try vat.tellFromIngress(ingress, fanout, .{ .verb = "fan" });
            for (0..live) |_| try vat.tellFromIngress(ingress, counter, increment);
            try std.testing.expectEqual(actors.Vat.DriveProgress.more_pending, try vat.driveBudgeted(1));
            try std.testing.expect((try vat.near(fanout, .{ .verb = "refused" })).boolean);
            try std.testing.expectEqual(total, state.pending_turns);
            try std.testing.expectEqual(charge * total, state.pending_bytes);
            try std.testing.expectEqual(@as(u32, 0), vat.local_ingress.pending_turns);
            try vat.drive();
            try std.testing.expectEqual(before + total, try getN(&vat, counter));
        }
    }
    try vat.closeIngress(ingress);
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
        if (msg.is("outer")) {
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
        if (msg.is("inner") or msg.is("after")) return .{ .void = {} };
        if (msg.is("observed")) return .{ .bytes = self.observed[0..self.observed_len] };
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
