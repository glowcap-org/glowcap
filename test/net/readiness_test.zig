const std = @import("std");

const net = @import("pancake").net;

const WakeChannel = net.wake_channel.WakeChannel;

test "draining the set wake preserves genuine member readiness" {
    var set = try net.readiness.ReadySet.init();
    defer set.deinit();
    const member = try WakeChannel.open();
    defer member.deinit();
    try set.add(member.read);

    member.nudge();
    set.postWake();
    set.drainWake();

    var fds = [_]std.posix.pollfd{
        .{ .fd = set.descriptor(), .events = std.posix.POLL.IN, .revents = 0 },
    };
    try std.testing.expectEqual(@as(usize, 1), try std.posix.poll(&fds, 0));

    member.drain();
    set.drainWake();
    fds[0].revents = 0;
    try std.testing.expectEqual(@as(usize, 0), try std.posix.poll(&fds, 0));
}
