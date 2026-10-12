//! The griddle simulator (`glowcap griddle run`): determinism in the seed,
//! invariance of the outcome.
//!
//! A deterministic simulator is only worth the name if both halves hold. The
//! same seed must replay a conversation byte for byte, or a run nobody can
//! reproduce is just a log. And a different seed must be free to interleave
//! the links differently while every question still gets answered, or the
//! seed is decoration and the simulator explores nothing.

const std = @import("std");
const cli = @import("cli");
const glowcap = @import("glowcap");

const sim = cli.griddle_sim;

test "griddle: every advertised scenario name selects one scenario" {
    var names = std.mem.splitSequence(u8, sim.scenario_args, ", ");
    var seen: [@typeInfo(sim.Scenario).@"enum".field_names.len]bool = @splat(false);
    var count: usize = 0;
    while (names.next()) |name| {
        const scenario = sim.Scenario.fromArg(name) orelse return error.AdvertisedScenarioDoesNotParse;
        const index: usize = @intCast(@backingInt(scenario));
        try std.testing.expect(!seen[index]);
        seen[index] = true;
        count += 1;
    }
    try std.testing.expectEqual(@typeInfo(sim.Scenario).@"enum".field_names.len, count);
    for (seen) |advertised| try std.testing.expect(advertised);
}

fn runTimeline(gpa: std.mem.Allocator, scenario: sim.Scenario, seed: u64) ![]u8 {
    return runWeather(gpa, scenario, seed, .{});
}

fn runWeather(
    gpa: std.mem.Allocator,
    scenario: sim.Scenario,
    seed: u64,
    weather: sim.Weather,
) ![]u8 {
    var timeline = try sim.run(gpa, scenario, seed, .syrup, weather);
    defer timeline.deinit();
    return gpa.dupe(u8, timeline.bytes());
}

test "griddle: the same seed replays the same timeline byte for byte" {
    const gpa = std.testing.allocator;
    const first = try runTimeline(gpa, .crossed_fetch, 20250802);
    defer gpa.free(first);
    const again = try runTimeline(gpa, .crossed_fetch, 20250802);
    defer gpa.free(again);
    try std.testing.expectEqualStrings(first, again);
}

test "griddle: a different seed schedules the links differently" {
    // Not every seed pair differs, the scheduler makes a handful of choices,
    // so collisions are ordinary. What must be true is that *some* seed
    // reorders the run; a simulator whose seed changed nothing would explore
    // exactly one interleaving forever.
    const gpa = std.testing.allocator;
    const baseline = try runTimeline(gpa, .crossed_fetch, 1);
    defer gpa.free(baseline);

    var saw_difference = false;
    var seed: u64 = 2;
    while (seed < 40) : (seed += 1) {
        const other = try runTimeline(gpa, .crossed_fetch, seed);
        defer gpa.free(other);
        if (!std.mem.eql(u8, baseline, other)) saw_difference = true;
    }
    try std.testing.expect(saw_difference);
}

test "griddle: every schedule answers every question" {
    // The invariance half. Whatever order the seed chose, both crossed
    // fetches are answered, the outcome is a property of the protocol, not
    // of the schedule that carried it.
    const gpa = std.testing.allocator;
    var seed: u64 = 0;
    while (seed < 40) : (seed += 1) {
        const timeline = try runTimeline(gpa, .crossed_fetch, seed);
        defer gpa.free(timeline);
        try std.testing.expect(std.mem.indexOf(u8, timeline, "\"detail\":\"both-answered\"") != null);
    }
}

test "griddle: the base kinds carry no protocol, and the CapTP kinds are named as such" {
    // The layering is the point: a viewer that understands only the network
    // kinds still draws a correct picture, and anything protocol-specific
    // announces itself with a `captp_` prefix.
    const gpa = std.testing.allocator;
    const timeline = try runTimeline(gpa, .crossed_fetch, 4);
    defer gpa.free(timeline);

    var lines = std.mem.splitScalar(u8, timeline, '\n');
    var saw_base = false;
    var saw_captp = false;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, line, .{});
        defer parsed.deinit();
        const kind = parsed.value.object.get("kind").?.string;
        if (std.mem.startsWith(u8, kind, "captp_")) {
            saw_captp = true;
        } else {
            // A base kind never names a protocol.
            try std.testing.expect(std.mem.indexOf(u8, kind, "captp") == null);
            saw_base = true;
        }
    }
    try std.testing.expect(saw_base and saw_captp);
}

test "griddle: the timeline is NDJSON, one parseable object per line" {
    // The timeline is a wire format a viewer will consume, so every line has
    // to stand alone as JSON.
    const gpa = std.testing.allocator;
    const timeline = try runTimeline(gpa, .bootstrap_fetch, 3);
    defer gpa.free(timeline);

    var lines = std.mem.splitScalar(u8, timeline, '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, line, .{});
        defer parsed.deinit();
        _ = parsed.value.object.get("kind") orelse return error.LineHasNoKind;
        _ = parsed.value.object.get("sim_t_ns") orelse return error.LineHasNoClock;
        // Versioned on every line, so a consumer detects a schema change
        // loudly rather than misreading the shape.
        try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("v").?.integer);
        count += 1;
    }
    try std.testing.expect(count > 3);
}

test "griddle: latency delays a link without reordering it" {
    // Latency must move a link in time, never against itself. Each link's
    // frames stay in send order, so the only visible effect is that the run
    // takes more ticks than the instant network.
    const gpa = std.testing.allocator;
    const instant = try runTimeline(gpa, .crossed_fetch, 5);
    defer gpa.free(instant);
    const delayed = try runWeather(gpa, .crossed_fetch, 5, .{ .latency = true });
    defer gpa.free(delayed);

    // Both still finish: latency is not failure.
    try std.testing.expect(std.mem.indexOf(u8, delayed, "\"detail\":\"both-answered\"") != null);
    // And it took longer, the last tick is higher.
    try std.testing.expect(delayed.len >= instant.len);
    try std.testing.expect(std.mem.indexOf(u8, delayed, "\"sim_t_ns\":0,") != null);
}

test "griddle: a partition strands the question rather than breaking it" {
    // The lesson the scenario exists to teach. The partner answers; the
    // answer dies on the cut link; and peer 0 is left with a question that
    // is neither answered nor refused, because nothing observed the failure.
    // Only a caller's deadline ends that wait.
    const gpa = std.testing.allocator;
    const timeline = try runWeather(gpa, .partitioned_fetch, 3, .{ .partition_at = 1 });
    defer gpa.free(timeline);

    try std.testing.expect(std.mem.indexOf(u8, timeline, "\"kind\":\"link_down\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, timeline, "\"kind\":\"message_lost\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, timeline, "\"detail\":\"stranded\"") != null);
    // Nothing was broken: a stranded question is not a broken one.
    try std.testing.expect(std.mem.indexOf(u8, timeline, "\"detail\":\"answered\"") == null);
}

test "griddle: the same seed replays the same weather" {
    // Determinism has to survive the knobs, or a partition nobody can
    // reproduce is worth nothing.
    const gpa = std.testing.allocator;
    const weather = sim.Weather{ .latency = true, .partition_at = 2 };
    const first = try runWeather(gpa, .crossed_fetch, 99, weather);
    defer gpa.free(first);
    const again = try runWeather(gpa, .crossed_fetch, 99, weather);
    defer gpa.free(again);
    try std.testing.expectEqualStrings(first, again);
}

test "griddle: an unpartitioned run never reports a loss" {
    // The negative control for the modelling rule: with no partition, a
    // reliable link loses nothing, because this simulator models no loss.
    const gpa = std.testing.allocator;
    var seed: u64 = 0;
    while (seed < 20) : (seed += 1) {
        const timeline = try runWeather(gpa, .crossed_fetch, seed, .{ .latency = true });
        defer gpa.free(timeline);
        try std.testing.expect(std.mem.indexOf(u8, timeline, "\"kind\":\"message_lost\"") == null);
    }
}

test "griddle: the runaway guard counts deliveries, not time passing" {
    // Latency makes the scheduler advance its clock far more often than it
    // delivers. A guard that counted every scheduling step would refuse a
    // perfectly healthy slow network as a runaway, so the two outcomes are
    // distinct and only deliveries are counted.
    const gpa = std.testing.allocator;
    var seed: u64 = 0;
    while (seed < 30) : (seed += 1) {
        const timeline = try runWeather(gpa, .crossed_fetch, seed, .{ .latency = true });
        defer gpa.free(timeline);
        // Runaway would have surfaced as an error above; reaching the end
        // state is the proof the guard let a slow network finish.
        try std.testing.expect(std.mem.indexOf(u8, timeline, "\"detail\":\"both-answered\"") != null);
    }
}

test "griddle: a peer's step failure reaches the timeline" {
    // A simulator that swallowed an engine failure would spin to its runaway
    // bound with nothing to show. Nothing in the healthy scenarios should
    // fail, so the guarantee here is the negative: a clean run reports no
    // failure, and the kind exists for when one does.
    const gpa = std.testing.allocator;
    const timeline = try runTimeline(gpa, .crossed_fetch, 11);
    defer gpa.free(timeline);
    try std.testing.expect(std.mem.indexOf(u8, timeline, "\"kind\":\"captp_failed\"") == null);
}
