//! The host's descriptor wait under kernel memory pressure
//! (`host_runtime/descriptor_wait.zig`). A normal runtime waits through the
//! real `poll(2)` over real registered descriptors, and the syscall owner
//! answers one scripted errno where the kernel would, so the runtime's own
//! rows, readiness, and clock decide everything else. A refused poll is paced
//! work: the wait rests and returns for another round, a ready resident or a
//! wake never waits out the rest, and any other errno latches terminal with
//! its exact cause. `Script.calls` counts the raw descriptor polls the syscall
//! owner saw, never the ready-set queries a stepped wait still makes.
//!
//! The runtime's `Io` is the threaded one with a virtual clock, a sleep that
//! only records and advances that clock (optionally returning early), and
//! cancel-protection tracking. No test sleeps or asserts a wall-time bound, so
//! a loaded runner cannot turn one red. Residents are non-parking with
//! `busy_poll_ns` zero, so every wait reaches the descriptor poll.

const std = @import("std");
const glowcap = @import("glowcap");
const step_harness = @import("../host_runtime_step/harness.zig");
const growth_probe = @import("growth_probe.zig");

const driver = glowcap.driver;
const net = glowcap.net;
const poll = net.poll;

const fixtures = @import("residents.zig");
const AcceptOwnershipResident = fixtures.AcceptOwnershipResident;
const HostRuntime = driver.HostRuntime;

const retry_ms: i64 = HostRuntime.testing.memory_retry_ms;
const max_residents = 40;

/// The runtime's `Io`: threaded for everything but time. The awake clock is
/// virtual and moves only when a test advances it, a sleep consumes, or a
/// scripted jump lands on a numbered read. A sleep may return early. Tests run
/// serially, so one set of statics is the whole state.
const Fake = struct {
    var now_ms: i64 = 0;
    var reads: usize = 0;
    var jump_at_read: usize = 0;
    var jump_ms: i64 = 0;
    var early_ms: ?i64 = null;
    var sleeps: [8]i64 = undefined;
    var sleep_count: usize = 0;
    var protection: std.Io.CancelProtection = .unblocked;
    var unprotected_sleeps: usize = 0;
    var real: *const std.Io.VTable = undefined;
    var table: std.Io.VTable = undefined;

    fn install(threaded: *std.Io.Threaded) std.Io {
        const base = threaded.io();
        real = base.vtable;
        table = base.vtable.*;
        table.now = now;
        table.sleep = sleep;
        table.swapCancelProtection = swap;
        now_ms = 1_000_000;
        reads = 0;
        jump_at_read = 0;
        jump_ms = 0;
        early_ms = null;
        sleep_count = 0;
        protection = .unblocked;
        unprotected_sleeps = 0;
        return .{ .userdata = base.userdata, .vtable = &table };
    }

    fn now(userdata: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
        if (clock != .awake) return real.now(userdata, clock);
        reads += 1;
        if (reads == jump_at_read) now_ms += jump_ms;
        return .{ .nanoseconds = @as(i96, now_ms) * std.time.ns_per_ms };
    }

    fn sleep(_: ?*anyopaque, timeout: std.Io.Timeout) std.Io.Cancelable!void {
        if (protection != .blocked) unprotected_sleeps += 1;
        const asked: i64 = @intCast(@divTrunc(timeout.duration.raw.nanoseconds, std.time.ns_per_ms));
        sleeps[sleep_count] = asked;
        sleep_count += 1;
        now_ms += if (early_ms) |early| @min(early, asked) else asked;
    }

    fn swap(_: ?*anyopaque, new: std.Io.CancelProtection) std.Io.CancelProtection {
        const prior = protection;
        protection = new;
        return prior;
    }

    fn slept() []const i64 {
        return sleeps[0..sleep_count];
    }
};

const Rig = struct {
    threaded: std.Io.Threaded,
    residents: [max_residents]AcceptOwnershipResident,
    made: usize,
    names: [max_residents][24]u8,
    runtime: HostRuntime,
    allocator: std.mem.Allocator,
    finished: bool = false,

    fn begin(self: *Rig, allocator: std.mem.Allocator, stepped: bool) !void {
        self.threaded = std.Io.Threaded.init(std.testing.allocator, .{});
        errdefer self.threaded.deinit();
        self.finished = false;
        self.made = 0;
        self.allocator = allocator;
        var options = if (stepped) step_harness.steppedQuiet() else fixtures.opts;
        options.busy_poll_ns = 0;
        self.runtime = try HostRuntime.init(allocator, Fake.install(&self.threaded), .{}, .ephemeral, options);
    }

    /// Consume the runtime through `deinitOutcome`, as an owner that reports
    /// the terminal cause does. `deinit` then leaves the runtime alone.
    fn finish(self: *Rig) ?driver.OperationFailure {
        self.finished = true;
        return self.runtime.deinitOutcome();
    }

    fn deinit(self: *Rig) void {
        if (!self.finished) self.runtime.deinit();
        for (self.residents[0..self.made]) |*resident| resident.deinit();
        self.threaded.deinit();
    }

    fn admit(self: *Rig, count: usize) !void {
        var registrations: [max_residents]HostRuntime.ProviderRegistration = undefined;
        var indices: [max_residents]usize = undefined;
        const first = self.made;
        for (0..count) |k| {
            self.residents[first + k] = try AcceptOwnershipResident.init();
            self.made += 1;
            registrations[k] = .{
                .profile = .{
                    .symbol = std.mem.print(&self.names[first + k], "x-pressure-{d}", .{first + k}) catch unreachable,
                    .designator_scheme = .address,
                },
                .resident = self.residents[first + k].multiplexedResident(),
            };
        }
        try self.runtime.addProviders(registrations[0..count], indices[0..count]);
    }

    /// One operational wait, with the clock reads the runtime made before it
    /// reached the descriptor wait counted off, so a scripted jump can name
    /// the Nth read inside it.
    fn waitOnce(self: *Rig, timeout_ms: i32) !?usize {
        return HostRuntime.testing.waitAnySource(&self.runtime, timeout_ms, true);
    }

    /// Clock reads the runtime makes before the descriptor wait reads its
    /// own, found by one unrefused positive wait (whose first read is the
    /// wait's entry).
    fn readsBefore(self: *Rig) !usize {
        Fake.reads = 0;
        _ = try self.waitOnce(1);
        Fake.sleep_count = 0;
        return Fake.reads - 1;
    }

    /// Land a jump of `ms` on the `nth` clock read inside the next wait
    /// (1 is the descriptor wait's entry). `before` is `readsBefore`, taken
    /// ahead of any injection so it consumes none.
    fn jumpAt(before: usize, nth: usize, ms: i64) void {
        Fake.reads = 0;
        Fake.jump_at_read = before + nth;
        Fake.jump_ms = ms;
    }
};

fn refuse(count: comptime_int) [count]std.posix.E {
    return @splat(.NOMEM);
}

test "descriptor pressure: a refused poll rests one interval and the next poll clears it" {
    for ([_]bool{ false, true }) |stepped| {
        var rig: Rig = undefined;
        try rig.begin(std.testing.allocator, stepped);
        defer rig.deinit();
        try rig.admit(1);

        var script: poll.testing.Script = .{ .errnos = &refuse(1) };
        {
            const guard = poll.testing.inject(&script);
            defer guard.deinit();
            const armed = Fake.now_ms;
            // Paced: nothing is ready, nothing failed, and the wait gave the
            // caller back its turn at the interval, not its whole bound.
            try std.testing.expectEqual(@as(?usize, null), try rig.waitOnce(5_000));
            try std.testing.expectEqualSlices(i64, &.{retry_ms}, Fake.slept());
            try std.testing.expectEqual(@as(usize, 0), Fake.unprotected_sleeps);
            try std.testing.expectEqual(std.Io.CancelProtection.unblocked, Fake.protection);
            try std.testing.expectEqual(armed + retry_ms, rig.runtime.descriptor_refusal_due_ms.?);
            try std.testing.expect(rig.runtime.terminal_failure == null);

            // The next poll reaches the kernel, finds the rows quiet, and
            // clears the pacing.
            try std.testing.expectEqual(@as(?usize, null), try rig.waitOnce(30));
            try std.testing.expectEqual(@as(?i64, null), rig.runtime.descriptor_refusal_due_ms);
        }
        try std.testing.expectEqual(@as(usize, 2), script.calls);
        try std.testing.expectEqual(@as(usize, 1), Fake.sleep_count);
    }
}

test "descriptor pressure: a zero wait never rests and keeps the due a later wait rests to" {
    var rig: Rig = undefined;
    try rig.begin(std.testing.allocator, true);
    defer rig.deinit();
    try rig.admit(1);

    var script: poll.testing.Script = .{ .errnos = &refuse(3) };
    const guard = poll.testing.inject(&script);
    defer guard.deinit();
    try std.testing.expectEqual(@as(?usize, null), try rig.waitOnce(0));
    const due = rig.runtime.descriptor_refusal_due_ms.?;
    // A second zero step skips the descriptor poll while the retry is pending.
    Fake.now_ms += 100;
    try std.testing.expectEqual(@as(?usize, null), try rig.waitOnce(0));
    try std.testing.expectEqual(due, rig.runtime.descriptor_refusal_due_ms.?);
    try std.testing.expectEqual(@as(usize, 0), Fake.sleep_count);

    // A positive wait rests only to that due, which the zero steps ate into.
    try std.testing.expectEqual(@as(?usize, null), try rig.waitOnce(5_000));
    try std.testing.expectEqualSlices(i64, &.{retry_ms - 100}, Fake.slept());
    try std.testing.expectEqual(due, Fake.now_ms);
}

test "descriptor pressure: a ready resident is selected in rotation without resting" {
    var rig: Rig = undefined;
    try rig.begin(std.testing.allocator, true);
    defer rig.deinit();
    try rig.admit(2);
    for (rig.residents[0..rig.made]) |*resident| _ = try resident.wake.nudge();

    var script: poll.testing.Script = .{ .errnos = &refuse(2) };
    const guard = poll.testing.inject(&script);
    defer guard.deinit();
    const first = try rig.waitOnce(5_000);
    const second = try rig.waitOnce(5_000);
    // Both are ready and neither wait rested. The cursor moved between them,
    // so the second wait started at the other resident.
    try std.testing.expect(first != null and second != null);
    try std.testing.expect(first.? != second.?);
    try std.testing.expectEqual(@as(usize, 0), Fake.sleep_count);
    try std.testing.expect(rig.runtime.descriptor_refusal_due_ms != null);
}

test "descriptor pressure: a quiet resident behind many foreign watches still rests, and a ready one past them is selected" {
    var rig: Rig = undefined;
    try rig.begin(std.testing.allocator, true);
    defer rig.deinit();
    try rig.admit(2);

    // Forty foreign descriptors, all readable, outnumber the small buffer.
    var foreign: [40]net.wake_channel.WakeChannel = undefined;
    var opened: usize = 0;
    defer for (foreign[0..opened]) |channel| channel.deinit();
    for (&foreign) |*channel| {
        channel.* = try net.wake_channel.WakeChannel.open();
        opened += 1;
        try rig.runtime.watchFd(channel.read);
        _ = try channel.nudge();
    }

    var script: poll.testing.Script = .{ .errnos = &refuse(2) };
    const guard = poll.testing.inject(&script);
    defer guard.deinit();
    // External readiness belongs to the embedder: it selects nothing here.
    try std.testing.expectEqual(@as(?usize, null), try rig.waitOnce(5_000));
    try std.testing.expectEqualSlices(i64, &.{retry_ms}, Fake.slept());

    // The second resident became ready behind forty-two other members.
    _ = try rig.residents[1].wake.nudge();
    try std.testing.expect((try rig.waitOnce(5_000)) != null);
    try std.testing.expectEqual(@as(usize, 1), Fake.sleep_count);
}

test "descriptor pressure: the timed resident is selected only when the caller's deadline ran the wait" {
    var rig: Rig = undefined;
    try rig.begin(std.testing.allocator, false);
    defer rig.deinit();
    try rig.admit(1);
    rig.residents[0].timed_work_ms = 60;

    var script: poll.testing.Script = .{ .errnos = &refuse(8) };
    const guard = poll.testing.inject(&script);
    defer guard.deinit();

    // The resident's work is due inside the interval: the rest is that bound,
    // and the wait ended on it.
    try std.testing.expectEqual(@as(?usize, 0), try rig.waitOnce(5_000));
    try std.testing.expectEqualSlices(i64, &.{60}, Fake.slept());

    // A sleep that returns early leaves the deadline unreached, so the timed
    // resident is not selected and the caller goes round again.
    Fake.sleep_count = 0;
    Fake.early_ms = 20;
    const entered = Fake.now_ms;
    try std.testing.expectEqual(@as(?usize, null), try rig.waitOnce(5_000));
    try std.testing.expectEqual(entered + 20, Fake.now_ms);
    // The next round keeps the one deadline of its own entry, and the armed
    // due is still the first refusal's.
    Fake.early_ms = null;
    Fake.sleep_count = 0;
    try std.testing.expectEqual(@as(?usize, 0), try rig.waitOnce(5_000));
    try std.testing.expectEqualSlices(i64, &.{60}, Fake.slept());

    // Work due after the interval: the refusal's due ends the rest, and that
    // alone never selects the resident.
    rig.residents[0].timed_work_ms = 5_000;
    Fake.sleep_count = 0;
    const left = rig.runtime.descriptor_refusal_due_ms.? - Fake.now_ms;
    try std.testing.expectEqual(@as(?usize, null), try rig.waitOnce(10_000));
    try std.testing.expectEqualSlices(i64, &.{left}, Fake.slept());
}

test "descriptor pressure: time spent before or during the refusal is charged to the one deadline" {
    var rig: Rig = undefined;
    try rig.begin(std.testing.allocator, false);
    defer rig.deinit();
    try rig.admit(1);
    rig.residents[0].timed_work_ms = 60;
    const before = try rig.readsBefore();

    var script: poll.testing.Script = .{ .errnos = &refuse(8) };
    const guard = poll.testing.inject(&script);
    defer guard.deinit();

    // The poll was interrupted and ran 100 ms before the kernel refused it.
    // The bound named 60, so no whole budget starts over and nothing rests.
    Rig.jumpAt(before, 2, 100);
    try std.testing.expectEqual(@as(?usize, 0), try rig.waitOnce(5_000));
    try std.testing.expectEqual(@as(usize, 0), Fake.sleep_count);

    // A cold query that takes longer than the bound spends it too.
    Fake.jump_at_read = 0;
    Fake.now_ms += retry_ms + 10;
    Rig.jumpAt(before, 3, 100);
    try std.testing.expectEqual(@as(?usize, 0), try rig.waitOnce(5_000));
    try std.testing.expectEqual(@as(usize, 0), Fake.sleep_count);
}

test "descriptor pressure: a due that passes during the query is not renewed" {
    var rig: Rig = undefined;
    try rig.begin(std.testing.allocator, true);
    defer rig.deinit();
    try rig.admit(1);
    const before = try rig.readsBefore();

    var script: poll.testing.Script = .{ .errnos = &refuse(2) };
    const guard = poll.testing.inject(&script);
    defer guard.deinit();
    // The query crosses the due between its two clock reads. The caller goes
    // round with nothing rested and the due as armed, so the next refused
    // raw descriptor poll, and only that, arms the following one.
    Rig.jumpAt(before, 3, retry_ms + 50);
    const armed = Fake.now_ms + retry_ms;
    try std.testing.expectEqual(@as(?usize, null), try rig.waitOnce(5_000));
    try std.testing.expectEqual(@as(usize, 0), Fake.sleep_count);
    try std.testing.expectEqual(armed, rig.runtime.descriptor_refusal_due_ms.?);

    Fake.jump_at_read = 0;
    try std.testing.expectEqual(@as(?usize, null), try rig.waitOnce(5_000));
    try std.testing.expectEqual(armed + 50 + retry_ms, rig.runtime.descriptor_refusal_due_ms.?);
    try std.testing.expectEqualSlices(i64, &.{retry_ms}, Fake.slept());
}

test "descriptor pressure: repeated zero steps before the retry skip the descriptor poll" {
    for ([_]bool{ false, true }) |stepped| {
        var rig: Rig = undefined;
        try rig.begin(std.testing.allocator, stepped);
        defer rig.deinit();
        try rig.admit(1);

        var script: poll.testing.Script = .{ .errnos = &refuse(8) };
        const guard = poll.testing.inject(&script);
        defer guard.deinit();
        _ = try rig.runtime.stepAny(0);
        try std.testing.expectEqual(@as(usize, 1), script.calls);
        const due = rig.runtime.descriptor_refusal_due_ms.?;
        // The clock moves inside the interval between steps. None of them
        // makes a raw descriptor poll, postpones the due, or clears it.
        for (0..5) |_| {
            Fake.now_ms += 40;
            _ = try rig.runtime.stepAny(0);
        }
        try std.testing.expectEqual(@as(usize, 1), script.calls);
        try std.testing.expectEqual(due, rig.runtime.descriptor_refusal_due_ms.?);
        try std.testing.expectEqual(@as(usize, 0), Fake.sleep_count);
        try std.testing.expect(rig.runtime.terminal_failure == null);
    }
}

test "descriptor pressure: at the due one poll runs, and a second refusal arms the next due" {
    var rig: Rig = undefined;
    try rig.begin(std.testing.allocator, true);
    defer rig.deinit();
    try rig.admit(1);

    var script: poll.testing.Script = .{ .errnos = &refuse(8) };
    const guard = poll.testing.inject(&script);
    defer guard.deinit();
    _ = try rig.runtime.stepAny(0);
    const first = rig.runtime.descriptor_refusal_due_ms.?;
    Fake.now_ms = first - 1;
    _ = try rig.runtime.stepAny(0);
    try std.testing.expectEqual(@as(usize, 1), script.calls);

    Fake.now_ms = first;
    _ = try rig.runtime.stepAny(0);
    try std.testing.expectEqual(@as(usize, 2), script.calls);
    try std.testing.expectEqual(first + retry_ms, rig.runtime.descriptor_refusal_due_ms.?);
    // Refused again, so the new due holds the poll off again.
    _ = try rig.runtime.stepAny(0);
    try std.testing.expectEqual(@as(usize, 2), script.calls);
}

test "descriptor pressure: at the due a successful poll clears the pacing for good" {
    var rig: Rig = undefined;
    try rig.begin(std.testing.allocator, true);
    defer rig.deinit();
    try rig.admit(1);

    var script: poll.testing.Script = .{ .errnos = &refuse(1) };
    const guard = poll.testing.inject(&script);
    defer guard.deinit();
    _ = try rig.runtime.stepAny(0);
    try std.testing.expectEqual(@as(usize, 1), script.calls);
    // Inside the due the kernel is not asked, so an early success cannot
    // clear it.
    _ = try rig.runtime.stepAny(0);
    try std.testing.expectEqual(@as(usize, 1), script.calls);
    try std.testing.expect(rig.runtime.descriptor_refusal_due_ms != null);

    Fake.now_ms = rig.runtime.descriptor_refusal_due_ms.?;
    _ = try rig.runtime.stepAny(0);
    try std.testing.expectEqual(@as(usize, 2), script.calls);
    try std.testing.expectEqual(@as(?i64, null), rig.runtime.descriptor_refusal_due_ms);
    // Healthy again: every step polls.
    _ = try rig.runtime.stepAny(0);
    _ = try rig.runtime.stepAny(0);
    try std.testing.expectEqual(@as(usize, 4), script.calls);
}

test "descriptor pressure: the terminal wait holds the poll off inside its due and the primary survives to deinitOutcome" {
    var rig: Rig = undefined;
    try rig.begin(std.testing.allocator, true);
    defer rig.deinit();
    try rig.admit(1);
    rig.runtime.noteTerminalFailure(error.ProviderContract);

    var script: poll.testing.Script = .{ .errnos = &.{ .NOMEM, .INVAL } };
    const guard = poll.testing.inject(&script);
    defer guard.deinit();
    // A rest that ends early leaves the wait inside its due.
    Fake.early_ms = 100;
    try HostRuntime.testing.waitForTerminalSignal(&rig.runtime, 5_000);
    try std.testing.expectEqual(@as(usize, 1), script.calls);
    try HostRuntime.testing.waitForTerminalSignal(&rig.runtime, 5_000);
    try std.testing.expectEqual(@as(usize, 1), script.calls);
    try std.testing.expectEqualSlices(i64, &.{ retry_ms, retry_ms - 100 }, Fake.slept());

    // At the due the poll runs once more, and its hard failure leaves the
    // primary as the retained cause.
    Fake.now_ms = rig.runtime.descriptor_refusal_due_ms.?;
    try std.testing.expectError(error.LoopTerminal, HostRuntime.testing.waitForTerminalSignal(&rig.runtime, 5_000));
    try std.testing.expectEqual(@as(usize, 2), script.calls);
    const outcome = rig.finish().?;
    try std.testing.expectEqual(error.ProviderContract, outcome.chain.cause);
}

test "descriptor pressure: an invalid wait latches the exact cause and every verb reports it" {
    for ([_]bool{ false, true }) |stepped| {
        var rig: Rig = undefined;
        try rig.begin(std.testing.allocator, stepped);
        defer rig.deinit();
        try rig.admit(1);

        var script: poll.testing.Script = .{ .errnos = &.{.INVAL} };
        {
            const guard = poll.testing.inject(&script);
            defer guard.deinit();
            try std.testing.expectError(error.InvalidWait, rig.waitOnce(30));
        }
        try std.testing.expectEqual(error.InvalidWait, rig.runtime.terminal_failure.?.chain.cause);
        try std.testing.expectEqual(@as(?i64, null), rig.runtime.descriptor_refusal_due_ms);
        // The step surface reports the retained cause, never a fresh one.
        try std.testing.expectError(error.LoopTerminal, rig.runtime.stepAny(0));
    }
}

test "descriptor pressure: a hard ready-set query failure while pacing latches as the first cause" {
    var rig: Rig = undefined;
    try rig.begin(std.testing.allocator, true);
    defer rig.deinit();
    try rig.admit(1);

    var polls: poll.testing.Script = .{ .errnos = &refuse(1) };
    var queries: net.readiness.testing.Script = .{ .errno = .BADF };
    const poll_guard = poll.testing.inject(&polls);
    defer poll_guard.deinit();
    const query_guard = net.readiness.testing.inject(&queries);
    defer query_guard.deinit();

    // The refused descriptor poll sends the stepped step to the ready-set
    // query, whose kernel call fails. That is a hard failure, never pacing.
    try std.testing.expectError(error.LoopTerminal, rig.runtime.stepAny(0));
    try std.testing.expectEqual(@as(usize, 1), polls.calls);
    try std.testing.expect(queries.spent);
    try std.testing.expectEqual(@as(usize, 0), Fake.sleep_count);
    try std.testing.expect(rig.runtime.terminal_failure != null);
    try std.testing.expectEqual(error.ReadinessQueryFailed, rig.runtime.terminal_failure.?.chain.cause);
    // The first transition to terminal ends the operational pacing.
    try std.testing.expectEqual(@as(?i64, null), rig.runtime.descriptor_refusal_due_ms);

    // A later public step reports the retained cause, never a fresh one, and
    // the consuming owner still holds it.
    try std.testing.expectError(error.LoopTerminal, rig.runtime.stepAny(0));
    const outcome = rig.finish().?;
    try std.testing.expectEqual(error.ReadinessQueryFailed, outcome.chain.cause);
}

test "descriptor pressure: an interrupted ready-set query retries and still selects the ready resident" {
    var rig: Rig = undefined;
    try rig.begin(std.testing.allocator, true);
    defer rig.deinit();
    try rig.admit(1);
    _ = try rig.residents[0].wake.nudge();

    var polls: poll.testing.Script = .{ .errnos = &refuse(1) };
    var queries: net.readiness.testing.Script = .{ .errno = .INTR };
    const poll_guard = poll.testing.inject(&polls);
    defer poll_guard.deinit();
    const query_guard = net.readiness.testing.inject(&queries);
    defer query_guard.deinit();

    try std.testing.expectEqual(@as(?usize, 0), try rig.waitOnce(5_000));
    try std.testing.expect(queries.spent);
    try std.testing.expectEqual(@as(usize, 1), queries.kernel_calls);
    try std.testing.expectEqual(@as(usize, 0), Fake.sleep_count);
    try std.testing.expect(rig.runtime.terminal_failure == null);
}

test "descriptor pressure: the terminal wait rests on its own pacing and reports the retained primary" {
    var rig: Rig = undefined;
    try rig.begin(std.testing.allocator, true);
    defer rig.deinit();
    try rig.admit(1);
    // A pending operational refusal ends with the operational phase.
    rig.runtime.descriptor_refusal_due_ms = Fake.now_ms + 10_000;
    rig.runtime.noteTerminalFailure(error.ProviderContract);
    try std.testing.expectEqual(@as(?i64, null), rig.runtime.descriptor_refusal_due_ms);

    var script: poll.testing.Script = .{ .errnos = &refuse(1) };
    {
        const guard = poll.testing.inject(&script);
        defer guard.deinit();
        try HostRuntime.testing.waitForTerminalSignal(&rig.runtime, 5_000);
        try std.testing.expectEqualSlices(i64, &.{retry_ms}, Fake.slept());
        try std.testing.expectEqual(@as(usize, 0), Fake.unprotected_sleeps);
    }
    // Only the wake and mailbox rows were polled: not the resident's.
    try std.testing.expectEqual(@as(usize, 1), rig.runtime.extra_fd_scratch.items.len);
    const due = rig.runtime.descriptor_refusal_due_ms.?;
    // A later terminal report neither erases nor renews the terminal pacing.
    rig.runtime.noteTerminalFailure(error.ConnectionLost);
    try std.testing.expectEqual(due, rig.runtime.descriptor_refusal_due_ms.?);
    try std.testing.expectEqual(error.ProviderContract, rig.runtime.terminal_failure.?.chain.cause);

    // A hard terminal failure surfaces the primary, and keeps its own cause
    // behind it.
    script = .{ .errnos = &.{.INVAL} };
    const guard = poll.testing.inject(&script);
    defer guard.deinit();
    try std.testing.expectError(error.LoopTerminal, HostRuntime.testing.waitForTerminalSignal(&rig.runtime, 5_000));
    try std.testing.expectEqual(error.ProviderContract, rig.runtime.terminal_failure.?.chain.cause);
}

test "descriptor pressure: a refused snapshot reserve at admission leaves the registration unpublished" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var probe: growth_probe.Probe = .{ .backing = std.testing.allocator };
    var rig: Rig = undefined;
    rig.threaded = undefined;
    // The rig owns its Io, so build the runtime here over the probe.
    rig.made = 0;
    rig.allocator = probe.allocator();
    var options = step_harness.steppedQuiet();
    options.busy_poll_ns = 0;
    rig.runtime = try HostRuntime.init(probe.allocator(), threaded.io(), .{}, .ephemeral, options);
    defer {
        rig.runtime.deinit();
        for (rig.residents[0..rig.made]) |*resident| resident.deinit();
    }
    const small = net.readiness.testing.small_query_rows;
    const fits = small - HostRuntime.testing.wait_signal_rows;
    var registrations: [max_residents]HostRuntime.ProviderRegistration = undefined;
    var indices: [max_residents]usize = undefined;
    var names: [max_residents][24]u8 = undefined;
    // Residents up to the small buffer allocate no snapshot rows.
    for (0..fits + 1) |k| {
        rig.residents[k] = try AcceptOwnershipResident.init();
        rig.made += 1;
        registrations[k] = .{
            .profile = .{ .symbol = std.mem.print(&names[k], "x-snapshot-{d}", .{k}) catch unreachable, .designator_scheme = .address },
            .resident = rig.residents[k].multiplexedResident(),
        };
    }
    try rig.runtime.addProviders(registrations[0..fits], indices[0..fits]);
    switch (rig.runtime.drive) {
        .blocking => unreachable,
        .stepped => |*stepped| try std.testing.expectEqual(@as(usize, 0), stepped.ready_query.spill.capacity),
    }

    // The next resident crosses it, and its snapshot reserve is refused.
    const need = small + 1;
    const Row = std.meta.Child(@TypeOf(rig.runtime.drive.stepped.ready_query.spill.items));
    probe.target_len = std.ArrayList(Row).growCapacity(need) * @sizeOf(Row);
    const before = rig.runtime.residents.items.len;
    try std.testing.expectError(error.OutOfMemory, rig.runtime.addProviders(registrations[fits..][0..1], indices[fits..][0..1]));
    try std.testing.expect(probe.hits >= 1);
    try std.testing.expectEqual(before, rig.runtime.residents.items.len);
    try std.testing.expect(!rig.runtime.hasTransport(registrations[fits].profile.symbol));
    // Nothing reached the kernel set, so the retry registers the same
    // descriptor and the snapshot then covers it.
    probe.target_len = growth_probe.none;
    try rig.runtime.addProviders(registrations[fits..][0..1], indices[fits..][0..1]);
    switch (rig.runtime.drive) {
        .blocking => unreachable,
        .stepped => |*stepped| try std.testing.expect(stepped.ready_query.spill.capacity >= need),
    }
    // A watched descriptor past the boundary reserves before it publishes.
    const extra = try net.wake_channel.WakeChannel.open();
    defer extra.deinit();
    probe.target_len = std.ArrayList(Row).growCapacity(need + 1 + 8) * @sizeOf(Row);
    const grown = switch (rig.runtime.drive) {
        .blocking => unreachable,
        .stepped => |*stepped| stepped.ready_query.spill.capacity,
    };
    if (grown < need + 1) {
        try std.testing.expectError(error.OutOfMemory, rig.runtime.watchFd(extra.read));
        try std.testing.expectEqual(@as(usize, 0), rig.runtime.listener_fds.items.len);
    }
}
