//! Direct evidence for the completion loop's internal deadline owner.

const std = @import("std");
const deadlines = @import("completion_deadlines");

const Conn = struct {
    state: enum { free, open, draining, closing } = .free,
    read: enum { idle, armed, parked, starved } = .idle,
    waiting_since_ms: i64 = 0,
    waiting_is_drain: bool = false,
    over_mark: bool = false,
    front: std.ArrayList(u8) = .empty,
    front_off: usize = 0,
    back: std.ArrayList(u8) = .empty,
};

const Harness = struct {
    conns: []Conn,
    outbound_high_water_bytes: usize = 16,
    park_kill_ms: ?u64 = 60_000,
    drain_kill_ms: ?u64 = 5_000,
    waiting_count: usize = 0,
    earliest_due_ms: ?i64 = null,
    over_mark_count: usize = 0,
    fan_in_throttle: bool = true,
    fan_in_dirty: bool = false,
};

const CloseReason = enum { ordinary, park_kill, drain_kill };

const State = struct {
    pub fn pendingOut(c: *const Conn) usize {
        return c.front.items.len - c.front_off + c.back.items.len;
    }
};

const Clock = struct {
    pub fn nowMonotonicMs() i64 {
        return 1_000_000;
    }
};

const Deadlines = deadlines.Machine(Harness, CloseReason, State, Clock);

test "completion deadline arithmetic saturates without firing early" {
    try std.testing.expectEqual(@as(i64, 1_025), deadlines.dueAt(25, 1_000));
    try std.testing.expectEqual(
        std.math.maxInt(i64),
        deadlines.dueAt(std.math.maxInt(i64) - 5, 5),
    );
    try std.testing.expectEqual(
        std.math.maxInt(i64),
        deadlines.dueAt(1, std.math.maxInt(u64)),
    );
}

test "completion caller deadline expires before narrowing" {
    try std.testing.expectEqual(
        std.math.maxInt(i32),
        try deadlines.remainingCallerTimeout(std.math.maxInt(i32), 0),
    );
    try std.testing.expectEqual(
        @as(i32, 1),
        try deadlines.remainingCallerTimeout(std.math.maxInt(i32), std.math.maxInt(i32) - 1),
    );
    try std.testing.expectError(
        error.Timeout,
        deadlines.remainingCallerTimeout(std.math.maxInt(i32), std.math.maxInt(i32)),
    );
    try std.testing.expectError(
        error.Timeout,
        deadlines.remainingCallerTimeout(std.math.maxInt(i32), std.math.maxInt(i64)),
    );
}

test "fan-in victim starts waiting only when its own queue crosses the mark" {
    var conns = [_]Conn{.{ .state = .open, .read = .parked }};
    var harness: Harness = .{ .conns = &conns };

    Deadlines.refreshWaiting(&harness, &conns[0]);
    try std.testing.expectEqual(@as(i64, 0), conns[0].waiting_since_ms);
    try std.testing.expect(Deadlines.pendingDeadline(&harness, &conns[0]) == null);

    try conns[0].back.appendSlice(std.testing.allocator, &@as([64]u8, @splat(0)));
    defer conns[0].back.deinit(std.testing.allocator);
    Deadlines.refreshWaiting(&harness, &conns[0]);
    try std.testing.expect(conns[0].waiting_since_ms != 0);
    try std.testing.expectEqual(@as(usize, 1), harness.waiting_count);
    const deadline = Deadlines.pendingDeadline(&harness, &conns[0]) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("park_kill", @tagName(deadline.reason));

    conns[0].back.clearRetainingCapacity();
    Deadlines.refreshWaiting(&harness, &conns[0]);
    try std.testing.expectEqual(@as(i64, 0), conns[0].waiting_since_ms);
    try std.testing.expectEqual(@as(usize, 0), harness.waiting_count);
}

test "draining restarts a parked sink's wait clock" {
    var conns = [_]Conn{.{ .state = .open, .read = .parked }};
    var harness: Harness = .{ .conns = &conns };
    try conns[0].back.appendSlice(std.testing.allocator, &@as([64]u8, @splat(0)));
    defer conns[0].back.deinit(std.testing.allocator);

    Deadlines.refreshWaiting(&harness, &conns[0]);
    conns[0].waiting_since_ms -= 600_000;
    const parked_at = conns[0].waiting_since_ms;
    conns[0].state = .draining;
    Deadlines.refreshWaiting(&harness, &conns[0]);

    try std.testing.expect(conns[0].waiting_since_ms > parked_at);
    const deadline = Deadlines.pendingDeadline(&harness, &conns[0]) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("drain_kill", @tagName(deadline.reason));
}
