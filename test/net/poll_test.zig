//! The raw `poll(2)` owner (`net.poll`): which errno is kernel pressure, which
//! is a malformed wait, and how an interrupted wait keeps its deadline. The
//! kernel answers every call that is not scripted, so the rows, descriptors,
//! and readiness here are real, and a scripted errno stands for exactly what
//! the kernel would have returned at that call.

const std = @import("std");
const glowcap = @import("glowcap");

const net = glowcap.net;
const poll = net.poll;
const posix = std.posix;

fn quietRow(channel: net.wake_channel.WakeChannel) posix.pollfd {
    return .{ .fd = channel.read, .events = posix.POLL.IN, .revents = 0 };
}

test "poll owner: unclassified errnos return Unexpected to the caller" {
    const channel = try net.wake_channel.WakeChannel.open();
    defer channel.deinit();
    var rows = [_]posix.pollfd{quietRow(channel)};
    // PERM is no poll errno at all. AGAIN is the pressure signal on Darwin and
    // an unknown errno on Linux. The scripted guard is the raw poll counted.
    const others = [_]posix.E{ .PERM, .IO, if (@import("builtin").target.os.tag.isDarwin()) .BUSY else .AGAIN };
    var script: poll.testing.Script = .{ .errnos = &others };
    const guard = poll.testing.inject(&script);
    defer guard.deinit();
    for (others) |_| try std.testing.expectError(error.Unexpected, poll.wait(&rows, 0));
    try std.testing.expectEqual(others.len, script.calls);
}

test "poll owner: kernel allocation refusal is temporary pressure, and EINVAL is a malformed wait" {
    const channel = try net.wake_channel.WakeChannel.open();
    defer channel.deinit();
    var rows = [_]posix.pollfd{quietRow(channel)};

    var script: poll.testing.Script = .{ .errnos = &.{.NOMEM} };
    {
        const guard = poll.testing.inject(&script);
        defer guard.deinit();
        try std.testing.expectError(error.SystemResources, poll.wait(&rows, 0));
    }
    // Darwin reports the same refusal as EAGAIN. Linux never does, and its
    // reading of that errno is not asserted here.
    if (@import("builtin").target.os.tag.isDarwin()) {
        script = .{ .errnos = &.{.AGAIN} };
        const guard = poll.testing.inject(&script);
        defer guard.deinit();
        try std.testing.expectError(error.SystemResources, poll.wait(&rows, 0));
    }
    script = .{ .errnos = &.{.INVAL} };
    {
        const guard = poll.testing.inject(&script);
        defer guard.deinit();
        try std.testing.expectError(error.InvalidWait, poll.wait(&rows, 0));
    }
    // The guard is scoped: the next call reaches the kernel, which finds the
    // channel quiet.
    try std.testing.expectEqual(@as(usize, 0), try poll.wait(&rows, 0));
}

test "poll owner: an interrupted wait resumes for the time that remains, and expiry ends it" {
    const channel = try net.wake_channel.WakeChannel.open();
    defer channel.deinit();
    var rows = [_]posix.pollfd{quietRow(channel)};

    // Each interruption spends 100 ms of the wait's own clock. The third
    // finds the 250 ms spent, so one last nonblocking poll asks for
    // readiness, and the wait ends quiet. No wall time passes.
    var script: poll.testing.Script = .{
        .errnos = &.{ .INTR, .INTR, .INTR },
        .scripted_ms = 100,
    };
    {
        const guard = poll.testing.inject(&script);
        defer guard.deinit();
        try std.testing.expectEqual(@as(usize, 0), try poll.wait(&rows, 250));
    }
    try std.testing.expectEqual(@as(usize, 4), script.calls);
    try std.testing.expectEqualSlices(i32, &.{ 250, 150, 50, 0 }, script.timeouts[0..4]);

    // An interruption of that last poll ends the wait. Further scripted
    // interruptions are never consumed, so nothing retries indefinitely.
    script = .{ .errnos = &.{ .INTR, .INTR, .INTR, .INTR, .INTR }, .scripted_ms = 300 };
    {
        const guard = poll.testing.inject(&script);
        defer guard.deinit();
        try std.testing.expectEqual(@as(usize, 0), try poll.wait(&rows, 250));
    }
    try std.testing.expectEqual(@as(usize, 2), script.calls);
    try std.testing.expectEqualSlices(i32, &.{ 250, 0 }, script.timeouts[0..2]);
}

test "poll owner: a ready row is reported after interruptions and a zero wait never retries" {
    const channel = try net.wake_channel.WakeChannel.open();
    defer channel.deinit();
    var rows = [_]posix.pollfd{quietRow(channel)};
    _ = try channel.nudge();

    // Time spent interrupted still leaves the final nonblocking poll to find
    // the ready row.
    var script: poll.testing.Script = .{ .errnos = &.{.INTR}, .scripted_ms = 500 };
    {
        const guard = poll.testing.inject(&script);
        defer guard.deinit();
        try std.testing.expectEqual(@as(usize, 1), try poll.wait(&rows, 100));
    }
    try std.testing.expectEqualSlices(i32, &.{ 100, 0 }, script.timeouts[0..2]);

    // An interrupted zero wait is quiet and costs one call.
    rows[0].revents = 0;
    script = .{ .errnos = &.{ .INTR, .INTR } };
    {
        const guard = poll.testing.inject(&script);
        defer guard.deinit();
        try std.testing.expectEqual(@as(usize, 0), try poll.wait(&rows, 0));
    }
    try std.testing.expectEqual(@as(usize, 1), script.calls);
}

test "poll owner: every negative timeout waits forever and reaches the kernel as minus one" {
    const channel = try net.wake_channel.WakeChannel.open();
    defer channel.deinit();
    var rows = [_]posix.pollfd{quietRow(channel)};
    // A genuinely ready descriptor, so the kernel answers at once. Passing -7
    // through would be undefined for `poll`, and the kernel's own contract is
    // only that a negative timeout is infinite.
    _ = try channel.nudge();

    for ([_]i32{ -1, -7, std.math.minInt(i32) }) |timeout| {
        rows[0].revents = 0;
        var script: poll.testing.Script = .{ .errnos = &.{} };
        const guard = poll.testing.inject(&script);
        defer guard.deinit();
        try std.testing.expectEqual(@as(usize, 1), try poll.wait(&rows, timeout));
        try std.testing.expectEqual(@as(i32, -1), script.timeouts[0]);
    }

    // An interrupted infinite wait stays infinite.
    var script: poll.testing.Script = .{ .errnos = &.{ .INTR, .INTR }, .scripted_ms = 1_000_000 };
    const guard = poll.testing.inject(&script);
    defer guard.deinit();
    rows[0].revents = 0;
    try std.testing.expectEqual(@as(usize, 1), try poll.wait(&rows, -7));
    try std.testing.expectEqualSlices(i32, &.{ -1, -1, -1 }, script.timeouts[0..3]);
}

test "poll owner: the row count is the kernel's unsigned 32-bit count" {
    // Pure arithmetic on the count: no slice of that length exists.
    try std.testing.expectEqual(@as(posix.nfds_t, 0), try poll.testing.rowCount(0));
    try std.testing.expectEqual(@as(posix.nfds_t, std.math.maxInt(u32)), try poll.testing.rowCount(std.math.maxInt(u32)));
    if (@bitSizeOf(usize) > 32) {
        try std.testing.expectError(error.InvalidWait, poll.testing.rowCount(@as(usize, std.math.maxInt(u32)) + 1));
        try std.testing.expectError(error.InvalidWait, poll.testing.rowCount(std.math.maxInt(usize)));
    }
}
