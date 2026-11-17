//! Retained redeem reports on both runtime faces. Each scenario runs once on
//! the stepped face and once on the blocking face through the same rig, so a
//! wake or clamp that only one face honors shows as a failure of the other.

const std = @import("std");
const glowcap = @import("glowcap");

const driver = glowcap.driver;
const HostRuntime = driver.HostRuntime;
const fx = @import("open_fixture.zig");
const refuseDial = fx.refuseDial;
const retry_ms = fx.retry_ms;
const Rig = @import("redeem_rig.zig").Rig;

const faces = [_]bool{ false, true };

test "a carrier that never completes holds its report without throttling a sibling" {
    for (faces) |blocking| {
        var rig: Rig = undefined;
        try rig.initOn(blocking, .{ .ms = 50 });
        defer rig.deinit();
        try rig.readyOpened();

        // The partner's end of stream closes the wire, and the resident keeps
        // the close pending with no abort to cut it short.
        rig.f.resident.close_pending = true;
        try rig.endOfStream();
        try rig.step();
        rig.becomeDue();
        try rig.step();
        try std.testing.expect(rig.stage() == .opened_report);
        try std.testing.expect(rig.f.runtime.pending_opens.items[0].stage.opened_report.wait == .carrier_closing);
        // A carrier wait is not memory debt: the successful attempt cleared it.
        try std.testing.expectEqual(@as(?i64, null), rig.f.runtime.core.memory_retry_due_ms);

        // A sibling redeem decides inside its own budget while the carrier is
        // still closing, and its report commits without waiting for physical
        // close.
        rig.quietConnects();
        try rig.f.enlivenOther();
        try rig.step();
        try std.testing.expectEqual(@as(usize, 2), rig.rows());
        try std.testing.expectEqual(@as(usize, 2), rig.f.runtime.core.node.pendingDialCount());
        rig.f.clock.advanceMs(60);
        var rounds: usize = 0;
        while (rig.f.runtime.core.node.pendingDialCount() != 1 and rounds < 4) : (rounds += 1) try rig.step();
        try std.testing.expectEqual(@as(usize, 1), rig.f.runtime.core.node.pendingDialCount());
        try std.testing.expectEqual(@as(usize, 1), rig.rows());
        try std.testing.expect(rig.f.runtime.pending_opens.items[0].stage.opened_report.wait == .carrier_closing);

        // The wait spans several retry epochs with the resident never done.
        for (0..3) |_| {
            rig.becomeDue();
            try rig.step();
            try std.testing.expect(rig.f.runtime.pending_opens.items[0].stage.opened_report.wait == .carrier_closing);
            try std.testing.expectEqual(@as(?i64, null), rig.f.runtime.core.memory_retry_due_ms);
        }

        // Completion alone, with no new I/O besides the close record, runs
        // the report: the closed open fails its redeem exactly once.
        rig.f.resident.close_pending = false;
        try rig.closeEvent();
        try rig.step();
        rounds = 0;
        while (rig.rows() != 0 and rounds < 4) : (rounds += 1) try rig.step();
        try std.testing.expectEqual(@as(usize, 0), rig.rows());
        try std.testing.expectEqual(@as(usize, 0), rig.f.runtime.core.node.pendingDialCount());
        try std.testing.expectEqual(@as(usize, 0), rig.f.runtime.wires.count());
    }
}

test "a decision with no I/O reaches its report in the same step, and a held deadline is not a stale handshake budget" {
    for (faces) |blocking| {
        // No I/O: the handshake budget passes and nothing else happens.
        {
            var rig: Rig = undefined;
            try rig.initOn(blocking, .{ .ms = 50 });
            defer rig.deinit();
            try rig.connect();
            const reads = rig.f.resident.read_calls;
            rig.f.clock.advanceMs(60);
            try rig.step();
            try std.testing.expectEqual(reads, rig.f.resident.read_calls);
            try std.testing.expectEqual(@as(usize, 0), rig.rows());
            try std.testing.expectEqual(@as(usize, 0), rig.f.runtime.core.node.pendingDialCount());
            try std.testing.expect(rig.f.runtime.terminal_failure == null);
        }
        // Under a held memory deadline the decided row waits for that
        // deadline and no longer for its handshake budget.
        {
            var rig: Rig = undefined;
            try rig.initOn(blocking, .{ .ms = 50 });
            defer rig.deinit();
            try rig.connect();
            rig.holdDeadline();
            rig.f.clock.advanceMs(60);
            try rig.step();
            try std.testing.expect(rig.stage() == .failed_report);
            const wait = rig.f.runtime.stepWaitMs();
            try std.testing.expect(wait > 0 and wait <= retry_ms);
            rig.becomeDue();
            try rig.step();
            try std.testing.expectEqual(@as(usize, 0), rig.rows());
        }
    }
}

test "a provider refusal inside Exec.dial queues its verdict and meets its first permitted pass before parking" {
    for (faces) |blocking| {
        var rig: Rig = undefined;
        try rig.initOn(blocking, .{ .ms = 10_000 });
        defer rig.deinit();
        refuseDial(&rig.f.resident);
        try rig.f.enliven();
        // One turn attempt: the dial drains and the refusal queues a ready
        // verdict. No nested core report ran and no debt was invented.
        _ = try HostRuntime.testing.attempt(&rig.f.runtime, .operational, .turn);
        try std.testing.expectEqual(@as(usize, 1), rig.rows());
        try std.testing.expect(rig.stage() == .failed_report);
        try std.testing.expect(rig.f.runtime.pending_opens.items[0].stage.failed_report.wait == .ready);
        try std.testing.expectEqual(@as(usize, 1), rig.f.runtime.core.node.pendingDialCount());
        try std.testing.expectEqual(@as(?i64, null), rig.f.runtime.core.memory_retry_due_ms);
        try std.testing.expectEqual(@as(usize, 1), rig.f.resident.dial_starts);
        // A permitted ready report is work now: the wait must not park.
        try std.testing.expectEqual(@as(i32, 0), rig.f.runtime.stepWaitMs());
        // The attempt a park runs reports it once.
        _ = try HostRuntime.testing.attempt(&rig.f.runtime, .operational, .park);
        try std.testing.expectEqual(@as(usize, 0), rig.rows());
        try std.testing.expectEqual(@as(usize, 0), rig.f.runtime.core.node.pendingDialCount());
        try std.testing.expectEqual(@as(?i64, null), rig.f.runtime.core.memory_retry_due_ms);
        try std.testing.expectEqual(@as(usize, 1), rig.f.resident.dial_starts);
    }
}

test "a non-memory drain failure after a refused report keeps the report and its debt" {
    // The sibling's report queues a completion whose reservation fails for a
    // reason that is not memory. Refusing the opened report with memory first
    // leaves actual debt that the later error must not erase.
    var kept: usize = 0;
    var k: usize = 0;
    while (k < 64) : (k += 1) {
        var again: Rig = undefined;
        try again.init(.{ .ms = 50 });
        defer again.deinit();
        try again.connect();
        again.quietConnects();
        try again.f.enlivenOther();
        try again.step();
        again.holdDeadline();
        try again.deliverHello();
        try again.step();
        // The sibling's budget passes under the held deadline, so both
        // reports wait: the opened one first, the sibling's failure second.
        again.f.clock.advanceMs(60);
        try again.step();
        try std.testing.expectEqual(@as(usize, 2), again.rows());
        try std.testing.expect(again.f.runtime.pending_opens.items[1].stage == .failed_report);
        again.f.sink.fail_with = error.ProviderContract;
        again.arm(k);
        again.becomeDue();
        const result = again.f.runtime.stepAny(0);
        const induced = again.failing.induced;
        if (again.memoryRefused()) {
            try again.expectGated();
            kept += 1;
            try std.testing.expectError(error.ProviderContract, result);
            try std.testing.expect(again.f.runtime.core.memory_retry_due_ms != null);
            try std.testing.expect(again.stage() == .opened_report);
            try std.testing.expectEqual(@as(usize, 1), again.f.runtime.wires.count());
        }
        again.f.sink.fail_with = null;
        again.restore();
        var rounds: usize = 0;
        while (again.rows() != 0 and rounds < 16) : (rounds += 1) {
            again.becomeDue();
            _ = again.f.runtime.stepAny(0) catch |err| if (err != error.OutOfMemory) return err;
        }
        try std.testing.expectEqual(@as(usize, 0), again.rows());
        if (!induced) break;
    }
    try std.testing.expect(kept > 0);
}

test "a sweep decides every expired row exactly once while a longer-lived row stays" {
    for (faces) |blocking| {
        var rig: Rig = undefined;
        try rig.initOn(blocking, .{ .ms = 50 });
        defer rig.deinit();
        const Counter = struct {
            reserved: usize = 0,
            failures: usize = 0,
            fn of(ctx: *anyopaque) *@This() {
                return @ptrCast(@alignCast(ctx));
            }
            pub fn reserve(ctx: *anyopaque, _: u64) anyerror!void {
                of(ctx).reserved += 1;
            }
            fn release(ctx: *anyopaque, _: u64) void {
                of(ctx).reserved -= 1;
            }
            fn opened(_: *anyopaque, _: u64, _: *driver.core.HostSession) !void {}
            fn failed(ctx: *anyopaque, _: u64, _: driver.OperationFailure) void {
                const self = of(ctx);
                self.reserved -= 1;
                self.failures += 1;
            }
        };
        var counter: Counter = .{};
        rig.f.resident.hold_connect = true;
        // Three dials start first. The redeem starts 40 ms later, so it is
        // still inside its budget when the dials' 50 ms has passed.
        const designators = [_][]const u8{ "d1.test:1", "d2.test:1", "d3.test:1" };
        for (designators, 0..) |designator, tag| {
            var peer = fx.Fixture.locator();
            peer.designator = designator;
            try rig.f.runtime.startDial(peer, .inherit, tag, .{
                .ctx = &counter,
                .reserve = Counter.reserve,
                .release = Counter.release,
                .opened = Counter.opened,
                .failed = Counter.failed,
            });
        }
        rig.f.clock.advanceMs(40);
        try rig.f.enliven();
        try rig.step();
        try std.testing.expectEqual(@as(usize, 4), rig.rows());
        rig.f.clock.advanceMs(20);
        try rig.step();
        // Each expired dial answered once, and the redeem is the row left.
        try std.testing.expectEqual(@as(usize, 3), counter.failures);
        try std.testing.expectEqual(@as(usize, 0), counter.reserved);
        try std.testing.expectEqual(@as(usize, 1), rig.rows());
        try std.testing.expect(rig.stage() == .resident_dial);
    }
}

test "a progress loop over a report held behind the retry deadline drains to idle instead of spinning" {
    // The C driver step returns WOULD_BLOCK once `stepAny` reports no
    // progress, and the Loam host asks `hasRunnableWork`. Both must see an
    // idle runtime while a ready report waits on the memory deadline.
    var rig: Rig = undefined;
    try rig.init(.{ .ms = 10_000 });
    defer rig.deinit();
    try rig.readyOpened();
    var rounds: usize = 0;
    while (rounds < 8 and (try rig.f.runtime.stepAny(0)) != null) : (rounds += 1) {}
    try std.testing.expect(rounds < 8);
    try std.testing.expectEqual(@as(usize, 1), rig.rows());
    try std.testing.expect(!rig.f.runtime.core.hasRunnableWork());
    const wait = rig.f.runtime.stepWaitMs();
    try std.testing.expect(wait > 0 and wait <= retry_ms);
    // Once the deadline falls due the same loop reports it and goes idle.
    rig.becomeDue();
    rounds = 0;
    while (rounds < 8 and (try rig.f.runtime.stepAny(0)) != null) : (rounds += 1) {}
    try std.testing.expect(rounds < 8);
    try std.testing.expectEqual(@as(usize, 0), rig.rows());
    try std.testing.expect(!rig.f.runtime.core.hasRunnableWork());
}

test "one report pass commits every decided row, including the row that moves under its cursor" {
    for (faces) |blocking| {
        var rig: Rig = undefined;
        try rig.initOn(blocking, .{ .ms = 50 });
        defer rig.deinit();
        try rig.connect();
        rig.quietConnects();
        try rig.f.enlivenOther();
        try rig.step();
        try std.testing.expectEqual(@as(usize, 2), rig.rows());
        // Both handshakes expire under a held deadline, so both rows wait as
        // failed reports for the same pass.
        rig.holdDeadline();
        rig.f.clock.advanceMs(60);
        try rig.step();
        try std.testing.expectEqual(@as(usize, 2), rig.rows());
        try std.testing.expect(rig.f.runtime.pending_opens.items[0].stage == .failed_report);
        try std.testing.expect(rig.f.runtime.pending_opens.items[1].stage == .failed_report);
        try std.testing.expectEqual(@as(usize, 2), rig.f.runtime.core.node.pendingDialCount());
        // Reporting the first row swaps the second into its slot. A single
        // pass still reaches it.
        rig.becomeDue();
        _ = try HostRuntime.testing.attempt(&rig.f.runtime, .operational, .turn);
        try std.testing.expectEqual(@as(usize, 0), rig.rows());
        try std.testing.expectEqual(@as(usize, 0), rig.f.runtime.core.node.pendingDialCount());
    }
}

const Decisions = struct {
    reserved: usize = 0,
    tags: [8]u64 = undefined,
    len: usize = 0,

    fn of(ctx: *anyopaque) *Decisions {
        return @ptrCast(@alignCast(ctx));
    }
    fn reserve(ctx: *anyopaque, _: u64) anyerror!void {
        of(ctx).reserved += 1;
    }
    fn release(ctx: *anyopaque, _: u64) void {
        of(ctx).reserved -= 1;
    }
    fn opened(_: *anyopaque, _: u64, _: *driver.core.HostSession) !void {}
    fn failed(ctx: *anyopaque, tag: u64, _: driver.OperationFailure) void {
        const self = of(ctx);
        self.reserved -= 1;
        self.tags[self.len] = tag;
        self.len += 1;
    }
};

test "a decided row's nested report removes an earlier row, and the sweep still decides the rows that moved below its cursor" {
    // The sweep decides A at index 1. The attempt that answers A runs the
    // report pass, which commits the ready failed report B at index 0 and
    // swap-removes it, moving the last row below the cursor. A sweep that
    // went on from index 2 would skip that row for this whole call.
    for (faces) |blocking| {
        var rig: Rig = undefined;
        try rig.initOn(blocking, .{ .ms = 50 });
        defer rig.deinit();
        refuseDial(&rig.f.resident);
        try rig.f.enliven();
        _ = try HostRuntime.testing.attempt(&rig.f.runtime, .operational, .turn);
        try std.testing.expect(rig.stage() == .failed_report);
        try std.testing.expectEqual(@as(usize, 1), rig.f.runtime.core.node.pendingDialCount());
        rig.f.resident.dial_failure = null;
        rig.f.resident.hold_connect = true;

        var decisions: Decisions = .{};
        const designators = [_][]const u8{ "a.test:1", "m.test:1", "l.test:1" };
        for (designators, 0..) |designator, tag| {
            var peer = fx.Fixture.locator();
            peer.designator = designator;
            try rig.f.runtime.startDial(peer, .inherit, tag, .{
                .ctx = &decisions,
                .reserve = Decisions.reserve,
                .release = Decisions.release,
                .opened = Decisions.opened,
                .failed = Decisions.failed,
            });
        }
        try std.testing.expectEqual(@as(usize, 4), rig.rows());
        try std.testing.expect(rig.f.runtime.pending_opens.items[0].stage == .failed_report);
        const starts = rig.f.resident.dial_starts;
        rig.f.clock.advanceMs(60);

        try HostRuntime.testing.advancePendingOpens(&rig.f.runtime);
        // One call decided A, then M, then L, and B's report committed.
        try std.testing.expectEqual(@as(usize, 3), decisions.len);
        try std.testing.expectEqualSlices(u64, &.{ 0, 1, 2 }, decisions.tags[0..decisions.len]);
        try std.testing.expectEqual(@as(usize, 0), decisions.reserved);
        try std.testing.expectEqual(@as(usize, 0), rig.rows());
        try std.testing.expectEqual(@as(usize, 0), rig.f.runtime.core.node.pendingDialCount());
        // No fresh I/O: every decision came from the rows' own deadlines.
        try std.testing.expectEqual(starts, rig.f.resident.dial_starts);
    }
}
