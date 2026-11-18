//! How the completion resident arms the parking watches (ADR-0060) over the
//! epoll backend. A watch refused before it registered anything declines the
//! park without waiting, keeps the watches already armed, and offers only the
//! refused suffix at the next park. A fault, whether it arrives while arming or
//! from a completed watch, ends the park before any wait. The refusals here are
//! the backend's own allocator refusing, or an errno injected at the
//! `epoll_ctl` result, which names the injection and not a kernel observation.

const std = @import("std");
const builtin = @import("builtin");
const glowcap = @import("glowcap");

const net = glowcap.net;
const white_box = net.epoll_white_box;
const completion = net.completion;

/// Rows enough that the backend's row map outgrows its first allocation.
const growing_rows = 16;
/// A park that waits runs this long. One that declines returns far sooner.
const park_bound_ms = 10_000;
const declined_within_ms = 2_000;

const Backend = white_box.TestBackend;
const Resident = net.completion_resident.Resident(Backend, net.tcp.CompletionPolicy(Backend));
const Park = net.MultiplexedResident.Park;

const Rig = struct {
    failing: std.testing.FailingAllocator,
    resident: Resident,
    wakes: [growing_rows]net.wake_channel.WakeChannel,
    opened: usize,

    /// A resident and `count` wake channels, none offered as a watch yet.
    fn beginBare(self: *Rig, count: usize) !void {
        self.failing = .init(std.testing.allocator, .{});
        self.opened = 0;
        self.resident = try Resident.init(std.testing.allocator, try Backend.init(self.failing.allocator(), 64, 8, 4096), .{
            .send_window_bytes = 16 << 10,
            .spare_send_buffers = 2,
        });
        errdefer self.resident.deinit();
        errdefer for (self.wakes[0..self.opened]) |wake| wake.deinit();
        for (self.wakes[0..count]) |*wake| {
            wake.* = try net.wake_channel.WakeChannel.open();
            self.opened += 1;
        }
    }

    /// `count` wake channels, each offered as a watch.
    fn begin(self: *Rig, count: usize) !void {
        try self.beginBare(count);
        errdefer self.deinit();
        for (self.wakes[0..count]) |wake| try self.resident.resident().watch(wake.read);
    }

    fn deinit(self: *Rig) void {
        self.failing.fail_index = std.math.maxInt(usize);
        self.resident.resident().beforeWait(.park);
        self.resident.deinit();
        for (self.wakes[0..self.opened]) |wake| wake.deinit();
    }

    /// The backend's allocator grants `grants` more requests, then refuses.
    fn refuseGrowthAfter(self: *Rig, grants: usize) void {
        self.failing.fail_index = self.failing.alloc_index + grants;
    }

    fn armed(self: *Rig) usize {
        var count: usize = 0;
        for (self.resident.watches.items) |row| count += @intFromBool(row.armed);
        return count;
    }

    const Timed = struct { outcome: Park, ms: i64 };

    /// One park with a long bound, and how it ended and how long it took.
    fn timedPark(self: *Rig) Timed {
        const ops = self.resident.resident();
        ops.beforeWait(.park);
        const started = net.clock.nowMonotonicMs();
        const outcome = ops.park(park_bound_ms);
        return .{ .outcome = outcome, .ms = net.clock.nowMonotonicMs() - started };
    }

    fn expectDeclined(self: *Rig) !void {
        const declined = self.timedPark();
        try std.testing.expectEqual(Park.unavailable, declined.outcome);
        try std.testing.expect(declined.ms < declined_within_ms);
        try std.testing.expectEqual(@as(?anyerror, null), self.resident.failure);
    }

    /// One watch armed, then a second whose registration the injected errno
    /// refuses at the `epoll_ctl` result.
    fn armOneThenInject(self: *Rig, errno: std.os.linux.E) !void {
        const ops = self.resident.resident();
        try ops.watch(self.wakes[0].read);
        try std.testing.expectEqual(Park.timeout, ops.park(0));
        try std.testing.expectEqual(@as(usize, 1), self.armed());
        try ops.watch(self.wakes[1].read);
        white_box.failNextControl(&self.resident.backend, errno);
    }
};

test "watch arm: a real allocator refusal after a prefix declines the park, keeps the prefix, and the suffix arms later" {
    if (builtin.target.os.tag != .linux) return error.SkipZigTest;
    var rig: Rig = undefined;
    try rig.begin(growing_rows);
    defer rig.deinit();

    // The first registration allocates the backend's row map, and a later one
    // outgrows it: a real refusal with registrations already committed.
    rig.refuseGrowthAfter(1);
    const first = rig.timedPark();
    const prefix = rig.armed();
    try std.testing.expect(prefix >= 1 and prefix < growing_rows);
    try std.testing.expectEqual(prefix, white_box.pendingCount(&rig.resident.backend));
    try std.testing.expectEqual(Park.unavailable, first.outcome);
    try std.testing.expect(first.ms < declined_within_ms);
    try std.testing.expectEqual(@as(?anyerror, null), rig.resident.failure);
    try std.testing.expect(!rig.resident.resident().readyPending());

    // Persistent refusal: the same prefix stays armed, nothing waits, nothing latches.
    try rig.expectDeclined();
    try std.testing.expectEqual(prefix, rig.armed());

    // Recovery arms only the suffix, then a real source wakes the park.
    rig.failing.fail_index = std.math.maxInt(usize);
    _ = try rig.wakes[growing_rows - 1].nudge();
    const ops = rig.resident.resident();
    ops.beforeWait(.park);
    try std.testing.expectEqual(Park.woke, ops.park(park_bound_ms));
    // Every row was submitted once. The nudged one has completed since.
    try std.testing.expectEqual(growing_rows - 1, white_box.pendingCount(&rig.resident.backend));
    try std.testing.expectEqual(growing_rows - 1, rig.armed());
    try std.testing.expectEqual(@as(?anyerror, null), rig.resident.failure);
    try rig.wakes[growing_rows - 1].drain();
}

test "watch arm: an injected epoll ENOSPC or ENOMEM declines the park and only the refused watch is offered again" {
    if (builtin.target.os.tag != .linux) return error.SkipZigTest;
    inline for (.{ std.os.linux.E.NOSPC, std.os.linux.E.NOMEM }) |errno| {
        var rig: Rig = undefined;
        try rig.beginBare(2);
        defer rig.deinit();
        try rig.armOneThenInject(errno);
        try rig.expectDeclined();
        try std.testing.expectEqual(@as(usize, 1), rig.armed());
        try std.testing.expectEqual(@as(usize, 1), white_box.pendingCount(&rig.resident.backend));

        // The refusal committed nothing, so the retry is a first registration,
        // and the prefix is not submitted again.
        _ = try rig.wakes[1].nudge();
        const ops = rig.resident.resident();
        ops.beforeWait(.park);
        try std.testing.expectEqual(Park.woke, ops.park(park_bound_ms));
        try std.testing.expectEqual(@as(?anyerror, null), rig.resident.failure);
        try rig.wakes[1].drain();
    }
}

test "watch arm: another injected errno while arming latches and no park waits after it" {
    if (builtin.target.os.tag != .linux) return error.SkipZigTest;
    var rig: Rig = undefined;
    try rig.beginBare(2);
    defer rig.deinit();
    try rig.armOneThenInject(.INVAL);
    const first = rig.timedPark();
    try std.testing.expectEqual(Park.woke, first.outcome);
    try std.testing.expectEqual(@as(?anyerror, error.EpollControlFailed), rig.resident.failure);
    try std.testing.expect(rig.resident.resident().readyPending());
    // The fault is sticky: the next park reports it without arming or waiting.
    const second = rig.timedPark();
    try std.testing.expectEqual(Park.woke, second.outcome);
    try std.testing.expect(first.ms + second.ms < declined_within_ms);
    try std.testing.expectEqual(@as(usize, 1), rig.armed());
}

test "watch arm: a failed completion for a watch stays a fault and the next park does not wait" {
    if (builtin.target.os.tag != .linux) return error.SkipZigTest;
    var rig: Rig = undefined;
    try rig.beginBare(1);
    defer rig.deinit();
    const ops = rig.resident.resident();
    try ops.watch(rig.wakes[0].read);
    try std.testing.expectEqual(Park.timeout, ops.park(0));
    try std.testing.expectEqual(@as(usize, 1), rig.armed());

    // A projection, not a kernel failure: the completion a backend would
    // report for a failed poll is a negative result for the watch's own
    // user_data, and this hands that value to the resident's dispatch
    // directly. The epoll backend is not asked to fail, and its row stays.
    Resident.Completions.dispatch(&rig.resident, .{
        .user_data = net.completion_resident.userData(.watch, 0),
        .result = -1,
    });
    try std.testing.expectEqual(@as(usize, 0), rig.armed());
    try std.testing.expectEqual(@as(?anyerror, error.WatchFailed), rig.resident.failure);
    const woke = rig.timedPark();
    try std.testing.expectEqual(Park.woke, woke.outcome);
    try std.testing.expect(woke.ms < declined_within_ms);
}

test "watch arm: the same raw errno is a watch refusal for a poll and an ordinary failure for any other registration" {
    if (builtin.target.os.tag != .linux) return error.SkipZigTest;
    var backend = try Backend.init(std.testing.allocator, 4, 2, 64);
    defer backend.deinit();
    const wake = try net.wake_channel.WakeChannel.open();
    defer wake.deinit();

    const cases = .{
        .{ std.os.linux.E.NOSPC, error.EpollWatchLimit },
        .{ std.os.linux.E.NOMEM, error.OutOfMemory },
        .{ std.os.linux.E.INVAL, error.EpollControlFailed },
    };
    inline for (cases) |case| {
        white_box.failNextControl(&backend, case[0]);
        try std.testing.expectError(case[1], backend.submitPoll(1, wake.read, .readable));
        try std.testing.expectEqual(@as(usize, 0), white_box.pendingCount(&backend));
        // Every other registration keeps its one failure for the same errno.
        white_box.failNextControl(&backend, case[0]);
        try std.testing.expectError(error.EpollControlFailed, backend.submitRecv(2, wake.read));
        try std.testing.expectEqual(@as(usize, 0), white_box.pendingCount(&backend));
    }
    // Neither refusal left a registration behind: the watch registers and completes.
    try backend.submitPoll(3, wake.read, .readable);
    _ = try wake.nudge();
    var out: [1]completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&out, 1_000));
    try std.testing.expectEqual(@as(u64, 3), out[0].user_data);
}
