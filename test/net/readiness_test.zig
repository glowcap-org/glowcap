const std = @import("std");

const net = @import("pancake").net;

const WakeChannel = net.wake_channel.WakeChannel;
const FailureLatch = net.wake_channel.FailureLatch;

fn closeFd(fd: i32) void {
    _ = std.posix.system.close(fd);
}

test "completion claim reports a failed publication wake" {
    var completion = try net.TransportOperationCompletion.init();
    defer completion.deinit();

    closeFd(completion.wake.write);
    completion.wake.write = -1;

    try std.testing.expect(completion.publish());
    try std.testing.expectError(error.WakeNudgeFailed, completion.claim());
}

test "transport completion settles exactly once across every sequential race order" {
    var canceled_first = try net.TransportOperationCompletion.init();
    defer canceled_first.deinit();
    try std.testing.expect(!canceled_first.cancel());
    try std.testing.expect(!canceled_first.cancel());
    try std.testing.expect(!canceled_first.publish());
    try std.testing.expect(!(try canceled_first.claim()));

    var claimed = try net.TransportOperationCompletion.init();
    defer claimed.deinit();
    try std.testing.expect(!(try claimed.claim()));
    try std.testing.expect(claimed.publish());
    try std.testing.expect(try claimed.claim());
    try std.testing.expect(!(try claimed.claim()));
    try std.testing.expect(!claimed.cancel());
    try std.testing.expect(!claimed.publish());

    var canceled_completed = try net.TransportOperationCompletion.init();
    defer canceled_completed.deinit();
    try std.testing.expect(canceled_completed.publish());
    try std.testing.expect(canceled_completed.cancel());
    try std.testing.expect(!canceled_completed.cancel());
    try std.testing.expect(!(try canceled_completed.claim()));
    try std.testing.expect(!canceled_completed.publish());
}

test "transport completion publish-cancel race has one cleanup owner" {
    const Publisher = struct {
        fn run(completion: *net.TransportOperationCompletion, result: *bool) void {
            result.* = completion.publish();
        }
    };

    for (0..128) |_| {
        var completion = try net.TransportOperationCompletion.init();
        defer completion.deinit();
        var published = false;
        const worker = try std.Thread.spawn(.{}, Publisher.run, .{ &completion, &published });
        const canceled = completion.cancel();
        worker.join();

        // Cancel-before/during-publish transfers cleanup to the worker; a
        // cancel that claims a completed result transfers it to the caller.
        // The two ownership verdicts therefore always agree.
        try std.testing.expectEqual(canceled, published);
        try std.testing.expect(!(try completion.claim()));
    }
}

test "ready set reports update and wake faults" {
    var update_set = try net.readiness.ReadySet.init();
    defer update_set.deinit();
    closeFd(update_set.fd);
    update_set.fd = -1;
    try std.testing.expectError(error.ReadinessUpdateFailed, update_set.remove(update_set.wake.read));

    var wake_set = try net.readiness.ReadySet.init();
    defer wake_set.deinit();
    closeFd(wake_set.wake.write);
    wake_set.wake.write = -1;
    try std.testing.expectError(error.WakeNudgeFailed, wake_set.postWake());

    var drain_set = try net.readiness.ReadySet.init();
    defer drain_set.deinit();
    closeFd(drain_set.wake.read);
    drain_set.wake.read = -1;
    try std.testing.expectError(error.WakeDrainFailed, drain_set.drainWake());
}

test "wake channel reports nudge and drain descriptor faults" {
    var channel = try WakeChannel.open();
    defer channel.deinit();

    try std.testing.expectEqual(WakeChannel.NudgeResult.sent, try channel.nudge());
    try channel.drain();

    closeFd(channel.write);
    channel.write = -1;
    try std.testing.expectError(error.WakeNudgeFailed, channel.nudge());

    closeFd(channel.read);
    channel.read = -1;
    try std.testing.expectError(error.WakeDrainFailed, channel.drain());
}

test "wake channel distinguishes a coalesced nudge" {
    var channel = try WakeChannel.open();
    defer channel.deinit();

    while (true) switch (try channel.nudge()) {
        .sent => {},
        .coalesced => break,
    };
    try channel.drain();
    try std.testing.expectEqual(WakeChannel.NudgeResult.sent, try channel.nudge());
}

test "wake failure latch preserves the first fault" {
    var latch: FailureLatch = .{};
    try latch.check();
    latch.record(error.WakeDrainFailed);
    latch.record(error.WakeNudgeFailed);
    try std.testing.expectError(error.WakeDrainFailed, latch.check());

    latch.state.store(std.math.maxInt(u8), .release);
    try std.testing.expectError(error.WakeDrainFailed, latch.check());
}

test "draining the set wake preserves genuine member readiness" {
    var set = try net.readiness.ReadySet.init();
    defer set.deinit();
    const member = try WakeChannel.open();
    defer member.deinit();
    try set.add(member.read);

    _ = try member.nudge();
    try set.postWake();
    try set.drainWake();

    var fds = [_]std.posix.pollfd{
        .{ .fd = set.descriptor(), .events = std.posix.POLL.IN, .revents = 0 },
    };
    try std.testing.expectEqual(@as(usize, 1), try std.posix.poll(&fds, 0));

    try member.drain();
    try set.drainWake();
    fds[0].revents = 0;
    try std.testing.expectEqual(@as(usize, 0), try std.posix.poll(&fds, 0));
}
