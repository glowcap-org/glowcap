//! Transactional dial settlement under allocator pressure.

const std = @import("std");
const pancake = @import("pancake");

const engine = pancake.ocapn.engine;
const crypto = pancake.foundation.crypto;

const Node = engine.Node;
const harness = @import("../harness.zig");
const openKeyedSessionWithCounterpart = harness.openKeyedSessionWithCounterpart;
const testGiveBytes = harness.testGiveBytes;

test "dial failure settles every waiter when diagnostics cannot allocate" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x41)));
    defer node.deinit();

    const recipient = try node.registerPeer(.{});
    const locator = "ocapn://127.0.0.1%3A9050.tcp";
    try node.acceptGive(recipient, 11, "give-one", locator);
    try node.acceptGive(recipient, 12, "give-two", locator);
    const dial = node.nextAction().?;

    // The action FIFO already has room for both consequences. Fail the first
    // diagnostic allocation and prove the dial row still settles as a batch.
    failing.fail_index = failing.alloc_index;
    _ = try node.dialFailed(dial.dial.pending, 0, "connection refused");
    const first = node.nextAction().?;
    const second = node.nextAction().?;
    try std.testing.expectEqual(@as(u64, 11), first.fail.dest.answer.answer.int());
    try std.testing.expectEqual(@as(u64, 12), second.fail.dest.answer.answer.int());
    try std.testing.expectEqualStrings("handoff redeem failed: exporter dial failed", first.fail.reason.bytes());
    try std.testing.expectEqualStrings("handoff redeem failed: exporter dial failed", second.fail.reason.bytes());
    try std.testing.expect(node.nextAction() == null);
    try std.testing.expect(node.pendingDial(dial.dial.pending, 0) == null);
}

test "exporter completion settles the whole batch across outbound allocation failure" {
    var fail_offset: usize = 0;
    var exercised_partial_batch = false;
    while (fail_offset < 128 and !exercised_partial_batch) : (fail_offset += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const allocator = failing.allocator();
        var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x42)));
        defer node.deinit();

        const recipient = try node.registerPeer(.{});
        const exporter = try node.registerPeer(.{});
        var counterpart = try openKeyedSessionWithCounterpart(
            allocator,
            &node,
            node.peer(exporter).?,
            @as([crypto.SEED_BYTES]u8, @splat(0x43)),
        );
        defer counterpart.deinit();

        const give_a = try testGiveBytes(allocator);
        defer allocator.free(give_a);
        const give_b = try testGiveBytes(allocator);
        defer allocator.free(give_b);
        const give_c = try testGiveBytes(allocator);
        defer allocator.free(give_c);
        const locator = "ocapn://127.0.0.1%3A9054.tcp";
        try node.acceptGive(recipient, 51, give_a, locator);
        try node.acceptGive(recipient, 52, give_b, locator);
        try node.acceptGive(recipient, 53, give_c, locator);
        const dial = node.nextAction().?;

        failing.fail_index = failing.alloc_index + fail_offset;
        _ = node.exporterDialed(dial.dial.pending, 0, exporter) catch |err| switch (err) {
            error.OutOfMemory => {
                // Preflight failure is transactional: the host can retry the
                // same completion because the pending dial still owns every
                // waiter.
                try std.testing.expect(node.pendingDial(dial.dial.pending, 0) != null);
                continue;
            },
            else => return err,
        };
        failing.fail_index = std.math.maxInt(usize);

        var flush_count: usize = 0;
        var fail_count: usize = 0;
        while (node.nextAction()) |action| switch (action) {
            .flush => flush_count += 1,
            .fail => fail_count += 1,
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 3), flush_count + fail_count);
        if (flush_count == 0 or fail_count == 0) continue;

        exercised_partial_batch = true;
        var answers: [3]u64 = undefined;
        var answer_count: usize = 0;
        var withdraws = node.redeems.withdrawals.rows.keyIterator();
        while (withdraws.next()) |key| {
            answers[answer_count] = key.answer;
            answer_count += 1;
        }
        try std.testing.expectEqual(flush_count, answer_count);

        var retire_count: usize = 0;
        for (answers[0..answer_count]) |answer| {
            try std.testing.expect(try node.claimResolve(exporter, answer, .{ .broken = "missing" }));
            while (node.nextAction()) |action| switch (action) {
                .fail => {},
                .retire_exporter => |peer_handle| {
                    try std.testing.expectEqual(exporter, peer_handle);
                    retire_count += 1;
                },
                else => return error.UnexpectedNodeAction,
            };
        }
        try std.testing.expectEqual(@as(usize, 1), retire_count);
    }
    try std.testing.expect(exercised_partial_batch);
}
