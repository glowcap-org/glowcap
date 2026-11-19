//! Retained redeem reports under a terminal latch, on both faces. The terminal
//! runtime runs neither the active sweep nor the report pass: an expired retry
//! wait and an expired wired handshake or a ready report stay exactly as they
//! are, and no route progresses. A finishing Host keeps its cleanup wait: it
//! parks on the terminal signal, bounded by the closing carrier's deadline and
//! then by the caller's timeout, and never spins on a row or report it will
//! not run. One scripted connection backs one wire, so the pairs here are an
//! expired retry wait with a wired handshake and with a ready opened report.

const std = @import("std");
const glowcap = @import("glowcap");

const driver = glowcap.driver;
const HostRuntime = driver.HostRuntime;
const Rig = @import("redeem_rig.zig").Rig;

const faces = [_]bool{ false, true };
const retry_interval_ms = 3_000;
const handshake_budget_ms = 4_000;
const retrying: @FieldType(driver.SessionOptions, "dial_retry") = .{
    .max_attempts = 3,
    .retry_interval_ms = retry_interval_ms,
};

const Sibling = enum { handshake, opened_report };

/// A retry wait that is not yet due beside a staged session on the one
/// scripted connection: a wired handshake, or its ready opened report.
fn stage(rig: *Rig, sibling: Sibling) !void {
    rig.f.resident.hold_connect = true;
    rig.f.resident.connect_ready_at_start = true;
    try rig.f.enliven();
    try rig.step();
    try std.testing.expect(rig.f.runtime.pending_opens.items[0].stage == .retry_wait);
    rig.f.resident.connect_succeeds = true;
    try rig.f.enlivenOther();
    try rig.step();
    rig.holdDeadline();
    if (sibling == .opened_report) {
        try rig.deliverHello();
        try rig.step();
    }
    try std.testing.expectEqual(@as(usize, 2), rig.rows());
    try std.testing.expectEqualStrings(@tagName(sibling), @tagName(rig.f.runtime.pending_opens.items[1].stage));
}

/// The sibling's own budget and the retry wait's due have both passed, and the
/// ready report owns no deadline, so no clock can be what keeps a row alive.
fn expectExpired(rig: *Rig, sibling: Sibling) !void {
    const now = rig.f.runtime.nowMs();
    const wait = rig.f.runtime.pending_opens.items[0].stage;
    try std.testing.expect(wait.retry_wait.due_ms <= now);
    try std.testing.expect(wait.deadlineMs().? <= now);
    const staged = rig.f.runtime.pending_opens.items[1].stage;
    switch (sibling) {
        .handshake => try std.testing.expect(staged.deadlineMs().? <= now),
        .opened_report => try std.testing.expectEqual(@as(?i64, null), staged.deadlineMs()),
    }
}

/// Rows, route and core ownership are exactly as staged.
fn expectUntouched(rig: *Rig, sibling: Sibling) !void {
    try std.testing.expectEqual(@as(usize, 2), rig.rows());
    try std.testing.expect(rig.f.runtime.pending_opens.items[0].stage == .retry_wait);
    try std.testing.expectEqualStrings(@tagName(sibling), @tagName(rig.f.runtime.pending_opens.items[1].stage));
    try std.testing.expectEqual(@as(usize, 2), rig.f.resident.dial_starts);
    try std.testing.expectEqual(@as(usize, 2), rig.f.runtime.core.node.pendingDialCount());
    try std.testing.expectEqual(@as(usize, 1), rig.f.runtime.wires.count());
    if (!rig.f.blocking) try std.testing.expectEqual(@as(usize, 0), rig.f.sink.takes);
}

test "an active terminal latch ends the step with its cause and leaves expired and ready rows alone" {
    for (faces) |blocking| for ([_]Sibling{ .handshake, .opened_report }) |sibling| {
        var rig: Rig = undefined;
        try rig.initRetrying(.{ .blocking = blocking }, .{ .ms = handshake_budget_ms }, retrying);
        defer rig.deinit();
        try stage(&rig, sibling);
        rig.f.clock.advanceMs(handshake_budget_ms + 1);
        try expectExpired(&rig, sibling);
        rig.f.runtime.noteTerminalFailure(error.ProviderContract);
        // Nothing owes a wake: no clock binds a terminal runtime.
        try std.testing.expectEqual(@as(i32, -1), rig.f.runtime.stepWaitMs());
        const parks = rig.f.resident.before_wait_calls;
        for (0..3) |_| {
            try std.testing.expectError(error.LoopTerminal, rig.f.runtime.stepAny(20));
            try expectUntouched(&rig, sibling);
        }
        try std.testing.expectEqual(parks, rig.f.resident.before_wait_calls);
    };
}

fn realMs(rig: *Rig) i64 {
    return std.Io.Clock.awake.now(rig.f.threaded.io()).toMilliseconds();
}

test "a finishing Host parks on the terminal signal and runs no expired row or ready report" {
    for (faces) |blocking| for ([_]Sibling{ .handshake, .opened_report }) |sibling| {
        var rig: Rig = undefined;
        try rig.initRetrying(.{ .blocking = blocking }, .{ .ms = handshake_budget_ms }, retrying);
        defer rig.deinit();
        try stage(&rig, sibling);
        // The partner closes while the resident keeps the physical close
        // pending: the staged session's carrier is closing.
        rig.f.resident.close_pending = true;
        try rig.endOfStream();
        try rig.step();
        if (sibling == .opened_report) {
            rig.becomeDue();
            try rig.step();
            try std.testing.expect(rig.f.runtime.pending_opens.items[1].stage.opened_report.wait == .carrier_closing);
        }
        rig.f.clock.advanceMs(handshake_budget_ms + 1);
        try expectExpired(&rig, sibling);
        rig.f.runtime.noteTerminalFailure(error.ProviderContract);
        // An actual finishing close, not a latch alone: the Host stays
        // finishing while the staged session and the dials remain.
        rig.f.runtime.beginClose(.{ .finish = .unbounded });
        try std.testing.expect(rig.f.runtime.core.lifecyclePhase() == .finishing);
        const deadline = rig.f.runtime.nearest_carrier_close_ms.?;
        const bound = deadline - rig.f.runtime.nowMs();
        try std.testing.expect(bound > 0);
        // Before the carrier is forced, the one wait is its own close
        // deadline: no expired row or ready report shortens it to zero.
        try std.testing.expectEqual(@as(i32, @intCast(bound)), rig.f.runtime.stepWaitMs());

        // The cleanup wait is `waitForTerminalSignal`, which never reaches the
        // resident's `beforeWait`. It forces the carrier, then parks for the
        // caller's timeout on the signal sources that stay legal, so the real
        // time it takes is the proof that it parked and did not spin.
        const parks = rig.f.resident.before_wait_calls;
        for (0..3) |_| {
            const started = realMs(&rig);
            try std.testing.expectError(error.LoopTerminal, rig.f.runtime.stepAny(20));
            const parked = realMs(&rig) - started;
            try std.testing.expect(parked >= 15);
            try std.testing.expect(rig.f.runtime.core.lifecyclePhase() == .finishing);
            // The signal is drained: no deadline or report wake recurs.
            try std.testing.expectEqual(@as(?i64, null), rig.f.runtime.nearest_carrier_close_ms);
            try std.testing.expectEqual(@as(i32, -1), rig.f.runtime.stepWaitMs());
            try expectUntouched(&rig, sibling);
        }
        try std.testing.expectEqual(parks, rig.f.resident.before_wait_calls);

        // Cancel once: every row retires, and the deferred deinit finds the
        // runtime empty.
        rig.f.resident.close_pending = false;
        rig.f.runtime.beginClose(.cancel);
        var rounds: usize = 0;
        while (rig.f.runtime.closeOutcome() == .pending and rounds < 64) : (rounds += 1) {
            rig.f.clock.advanceMs(100);
            try std.testing.expectError(error.LoopTerminal, rig.step());
        }
        try std.testing.expectEqual(@as(usize, 0), rig.rows());
        try std.testing.expectEqual(@as(usize, 0), rig.f.runtime.wires.count());
        try std.testing.expectEqual(@as(usize, 0), rig.f.runtime.core.sessions.count());
    };
}

test "a terminal park with a ready report drains nothing a park without one would not" {
    for (faces) |blocking| {
        var rig: Rig = undefined;
        try rig.initOn(blocking, .{ .ms = 10_000 });
        defer rig.deinit();
        try rig.readyOpened();
        // A queued dial the core owes, which a cleanup drain would fail.
        rig.quietConnects();
        try rig.f.enlivenOther();
        try std.testing.expectEqual(@as(usize, 2), rig.f.runtime.core.node.pendingDialCount());
        rig.f.runtime.noteTerminalFailure(error.ProviderContract);
        _ = try HostRuntime.testing.attempt(&rig.f.runtime, .cleanup_only, .park);
        // The ready report cannot run, so it forces no drain: the queued dial
        // is still queued, and the report is still the row's.
        try std.testing.expectEqual(@as(usize, 2), rig.f.runtime.core.node.pendingDialCount());
        try std.testing.expectEqual(@as(usize, 1), rig.rows());
        try std.testing.expect(rig.stage() == .opened_report);
        try std.testing.expect(rig.f.runtime.core.hasRunnableWork());
    }
}
