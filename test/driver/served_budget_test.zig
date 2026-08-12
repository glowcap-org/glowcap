//! `Served.drivePostBatch`: the loop drivers' amplification cap, pinned
//! sans-io. A high-fan-out loop drives each connection's queued local turns
//! within a caller-supplied budget and closes the connection on
//! `error.LocalTurnLimitExceeded`; this holds the verdict mapping and the
//! resume contract (a refused batch leaves the residual queue intact, so a
//! later budget drains it) without a socket or a loop. The authority is a
//! `driver_core` invariant; the live loop consumer is `iroh.Backend` + Bridge
//! (`zig build iroh-loop`).
const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const actors = pancake.actors;
const driver = pancake.driver;
const capture = @import("../support/capture.zig");

const Counter = struct {
    hits: i64 = 0,
    pub fn handle(self: *Counter, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "hit")) return error.NoSuchMethod;
        self.hits += 1;
        return .{ .integer = self.hits };
    }
};

test "drivePostBatch refuses a batch past its budget and the residual drains under a later one" {
    const allocator = std.testing.allocator;
    var pair = try engine.pairing.paired(allocator);
    defer pair.deinit();
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();
    var served = driver.Served.over(allocator, &pair.p1);
    defer served.deinit(&vat);

    const counter = try vat.spawn(Counter, .{});

    // Queue more local turns than the budget admits. The budget is the
    // caller's number — an operator knob, never the partner's.
    const budget: usize = 4;
    const queued: usize = budget + 3;
    var i: usize = 0;
    while (i < queued) : (i += 1) {
        _ = try vat.send(counter, .{ .verb = "hit", .args = &.{} });
    }

    // The over-budget batch is the runaway verdict, not a partial success.
    try std.testing.expectError(error.LocalTurnLimitExceeded, served.drivePostBatch(&vat, budget));

    // The refusal left the residual queue intact: a later post-batch with
    // room drains it to quiescence, and every queued turn ran exactly once —
    // read back through an ordinary near-call.
    try served.drivePostBatch(&vat, queued);
    const hits = try vat.near(counter, .{ .verb = "hit", .args = &.{} });
    try std.testing.expectEqual(@as(i64, @intCast(queued + 1)), hits.integer);
}

test "drivePostBatch within budget drains and settles the local send's listener" {
    const allocator = std.testing.allocator;
    var pair = try engine.pairing.paired(allocator);
    defer pair.deinit();
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();
    var served = driver.Served.over(allocator, &pair.p1);
    defer served.deinit(&vat);

    const counter = try vat.spawn(Counter, .{});
    const vow = try vat.send(counter, .{ .verb = "hit", .args = &.{} });

    var result: i64 = 0;
    try vat.on(vow, .{ .ctx = &result, .func = capture.captureInt });
    try served.drivePostBatch(&vat, actors.Vat.max_batch_local_turns);
    try std.testing.expectEqual(@as(i64, 1), result);
}

test "driveFedBudgeted with zero local-turn budget consumes no turn" {
    const allocator = std.testing.allocator;
    var pair = try engine.pairing.paired(allocator);
    defer pair.deinit();
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();
    var served = driver.Served.over(allocator, &pair.p1);
    defer served.deinit(&vat);
    served.local_turn_budget = 0;

    const counter = try vat.spawn(Counter, .{});
    _ = try vat.send(counter, .{ .verb = "hit", .args = &.{} });

    try std.testing.expectError(error.LocalTurnLimitExceeded, served.driveFedBudgeted(&vat));
    // The zero-budget probe must leave the queued turn untouched. A later
    // explicit unbounded drive proves the failure did not consume it.
    served.local_turn_budget = null;
    try served.drivePostBatch(&vat, 1);
    const hits = try vat.near(counter, .{ .verb = "hit", .args = &.{} });
    try std.testing.expectEqual(@as(i64, 2), hits.integer);
}

test "driveFedBudgeted retry cannot exceed an exhausted local-turn epoch" {
    const allocator = std.testing.allocator;
    var pair = try engine.pairing.paired(allocator);
    defer pair.deinit();
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();
    var served = driver.Served.over(allocator, &pair.p1);
    defer served.deinit(&vat);
    served.local_turn_budget = 1;
    served.budgeted_local_turns = 1;

    const counter = try vat.spawn(Counter, .{});
    _ = try vat.send(counter, .{ .verb = "hit", .args = &.{} });

    try std.testing.expectError(error.LocalTurnLimitExceeded, served.driveFedBudgeted(&vat));
    // The carried epoch is already exhausted, so retrying the drive may encode
    // prior work but must not execute the queued turn.
    try std.testing.expectError(error.LocalTurnLimitExceeded, served.driveFedBudgeted(&vat));
    served.local_turn_budget = null;
    served.budgeted_local_turns = null;
    try served.drivePostBatch(&vat, 1);
    const hits = try vat.near(counter, .{ .verb = "hit", .args = &.{} });
    try std.testing.expectEqual(@as(i64, 2), hits.integer);
}
