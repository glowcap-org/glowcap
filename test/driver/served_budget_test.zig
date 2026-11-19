//! Served's per-ingress turn limits. Exercise batch slicing and an exhausted
//! feed retry by reading the latest settled counter after each slice.
const std = @import("std");
const glowcap = @import("glowcap");

const engine = glowcap.ocapn.engine;
const actors = glowcap.actors;
const driver = glowcap.driver;
const capture = @import("../support/capture.zig");
const support_actors = @import("../support/actors.zig");

const Counter = support_actors.Counter;

fn queueHits(vat: *actors.Vat, counter: actors.Ref, queued: usize, hits: *i64) !void {
    for (0..queued) |_| {
        const vow = try vat.send(counter, .{ .verb = "hit" });
        try vat.on(vow, .{ .ctx = hits, .func = capture.captureInt });
    }
}

fn checkBatch(served: *driver.Served, vat: *actors.Vat, queued: usize, budget: usize) !usize {
    if (queued > budget)
        try std.testing.expectError(error.LocalTurnLimitExceeded, served.drivePostBatch(vat, budget))
    else
        try served.drivePostBatch(vat, budget);
    return queued -| budget;
}

test "post-batch turn budgets leave the same residual across slices" {
    const allocator = std.testing.allocator;
    var pair = try engine.pairing.paired(allocator);
    defer pair.deinit();
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();
    var served = driver.Served.over(allocator, &pair.p1);
    defer served.deinit(&vat);

    for (0..5) |queued| {
        for (0..5) |first| {
            for (0..5) |second| {
                const counter = try vat.spawn(Counter, .{});
                var hits: i64 = 0;
                try queueHits(&vat, counter, queued, &hits);
                const after_first = try checkBatch(&served, &vat, queued, first);
                try std.testing.expectEqual(@as(i64, @intCast(queued - after_first)), hits);
                const after_second = try checkBatch(&served, &vat, after_first, second);
                try std.testing.expectEqual(@as(i64, @intCast(queued - after_second)), hits);
                try served.drivePostBatch(&vat, std.math.maxInt(usize));
                try std.testing.expectEqual(@as(i64, @intCast(queued)), hits);
            }
        }
    }
}

test "retrying an exhausted fed turn budget consumes no more turns" {
    const allocator = std.testing.allocator;
    var pair = try engine.pairing.paired(allocator);
    defer pair.deinit();
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();
    var served = driver.Served.over(allocator, &pair.p1);
    defer served.deinit(&vat);

    for (0..3) |limit| {
        served.local_turn_budget = limit;
        served.budgeted_local_turns = null;
        const counter = try vat.spawn(Counter, .{});
        const queued = limit + 2;
        var hits: i64 = 0;
        try queueHits(&vat, counter, queued, &hits);
        for (0..limit -| 1) |_| try std.testing.expectEqual(.more_pending, try served.driveFedBudgeted(&vat));
        for (0..3) |_| {
            try std.testing.expectError(error.LocalTurnLimitExceeded, served.driveFedBudgeted(&vat));
            try std.testing.expectEqual(@as(i64, @intCast(limit)), hits);
        }
        try served.drivePostBatch(&vat, queued - limit);
        try std.testing.expectEqual(@as(i64, @intCast(queued)), hits);
    }
}
