//! Retained redeem reports against a carrier that closes: after a real memory
//! refusal, while a handshake is still open, and under a distinct sibling. The
//! open session keeps its one close-observer seat until its report retires, a
//! synchronous close publishes no application close, and a delayed physical
//! close is waited for by its own completion, never by the memory clock.

const std = @import("std");
const glowcap = @import("glowcap");

const Rig = @import("redeem_rig.zig").Rig;
const sweep_bound = @import("redeem_rig.zig").sweep_bound;

/// A close failure with one named cause and one named consequence.
fn namedFailure() glowcap.foundation.FailureChain {
    var chain = glowcap.foundation.FailureChain.initNamed(error.ConnectionLost, "ResidentCloseFailed");
    chain.noteChain(.initNamed(error.OutOfMemory, "ResidentCloseCleanupFailed"));
    return chain;
}

/// The exact failure `namedFailure` made, cause and consequence intact.
fn expectNamedFailure(failure: glowcap.driver.OperationFailure) !void {
    try std.testing.expectEqual(error.ConnectionLost, failure.chain.cause);
    try std.testing.expectEqualStrings("ResidentCloseFailed", failure.chain.primaryName());
    try std.testing.expectEqual(@as(?anyerror, error.OutOfMemory), failure.chain.secondary_cause);
    try std.testing.expectEqualStrings("ResidentCloseCleanupFailed", failure.chain.secondaryName().?);
    try std.testing.expectEqual(@as(u16, 1), failure.chain.secondary_count);
}

/// Open the rig's redeem, then land one refusal on its opened report. Returns
/// whether the refusal landed on the report (`memory_refused`), leaving the
/// allocator restored.
fn refuseOpenedReport(rig: *Rig, k: usize) !bool {
    try rig.readyOpened();
    rig.arm(k);
    rig.becomeDue();
    try rig.step();
    rig.restore();
    return rig.memoryRefused();
}

test "a report refused for memory is reclassified to its closing carrier on the next clean attempt" {
    var landed: usize = 0;
    var k: usize = 0;
    while (k < sweep_bound) : (k += 1) {
        var rig: Rig = undefined;
        try rig.init(.{ .ms = 50 });
        defer rig.deinit();
        const refused = try refuseOpenedReport(&rig, k);
        const induced = rig.failing.induced;
        if (refused) {
            landed += 1;
            try rig.expectGated();
            // The partner closes while the report waits on the memory clock;
            // the resident keeps the physical close pending.
            rig.f.resident.close_pending = true;
            try rig.endOfStream();
            try rig.step();
            try std.testing.expect(rig.memoryRefused());
            try std.testing.expectEqual(@as(usize, 1), rig.f.observed.reservations);
            try std.testing.expectEqual(@as(usize, 0), rig.f.sink.takes);
            // The first clean attempt past the deadline moves the same row to
            // its carrier and clears the debt: no redial, no core report.
            rig.becomeDue();
            try rig.step();
            const wait = rig.f.runtime.pending_opens.items[0].stage.opened_report.wait;
            try std.testing.expect(wait == .carrier_closing);
            try std.testing.expectEqual(@as(?i64, null), rig.f.runtime.core.memory_retry_due_ms);
            try std.testing.expectEqual(@as(usize, 1), rig.f.resident.dial_starts);
            try std.testing.expectEqual(@as(usize, 0), rig.f.sink.takes);
            // The partner's end of stream named no failure: the row has no
            // cause yet, so the later completion's own cause is the one kept.
            try std.testing.expect(rig.f.runtime.pending_opens.items[0].stage.opened_report.close_cause == null);

            // A distinct sibling redeem decides inside its own budget while
            // the first carrier is still closing.
            rig.quietConnects();
            try rig.f.enlivenOther();
            try rig.step();
            try std.testing.expectEqual(@as(usize, 2), rig.rows());
            rig.f.clock.advanceMs(60);
            var rounds: usize = 0;
            while (rig.f.runtime.core.node.pendingDialCount() != 1 and rounds < 4) : (rounds += 1) try rig.step();
            try std.testing.expectEqual(@as(usize, 1), rig.f.runtime.core.node.pendingDialCount());
            try std.testing.expect(rig.f.runtime.pending_opens.items[0].stage.opened_report.wait == .carrier_closing);
            try std.testing.expectEqual(@as(usize, 1), rig.f.observed.reservations);

            // The carrier's own completion names a failure. Held behind the
            // deadline, the completed row keeps that exact chain until its
            // report retires, then reports once and returns its one seat.
            rig.holdDeadline();
            rig.f.resident.close_failure = namedFailure();
            rig.f.resident.close_pending = false;
            try rig.closeEvent();
            try rig.step();
            const completed = rig.f.runtime.pending_opens.items[0].stage.opened_report;
            try std.testing.expect(completed.wait == .ready);
            try expectNamedFailure(completed.close_cause.?);
            try std.testing.expectEqual(@as(usize, 0), rig.f.observed.reservations);
            rig.becomeDue();
            try rig.step();
            rounds = 0;
            while (rig.rows() != 0 and rounds < 4) : (rounds += 1) try rig.step();
            try std.testing.expectEqual(@as(usize, 0), rig.rows());
            try std.testing.expectEqual(@as(usize, 0), rig.f.runtime.core.node.pendingDialCount());
            try std.testing.expectEqual(@as(usize, 0), rig.f.runtime.wires.count());
            try std.testing.expectEqual(@as(usize, 0), rig.f.observed.reservations);
            try std.testing.expectEqual(@as(usize, 0), rig.f.observed.close_events);
            // The first row never redialed: the one other start is the sibling's.
            try std.testing.expectEqual(@as(usize, 2), rig.f.resident.dial_starts);
            try std.testing.expect(rig.f.runtime.terminal_failure == null);
        }
        if (!induced) break;
    }
    try std.testing.expect(landed > 0);
    try std.testing.expect(k < sweep_bound);
}

test "a wire that closes synchronously under a report refused for memory publishes no close and returns its seat once" {
    var landed: usize = 0;
    var k: usize = 0;
    while (k < sweep_bound) : (k += 1) {
        var rig: Rig = undefined;
        try rig.init(.{ .ms = 50 });
        defer rig.deinit();
        const refused = try refuseOpenedReport(&rig, k);
        const induced = rig.failing.induced;
        if (refused) {
            landed += 1;
            try std.testing.expectEqual(@as(usize, 1), rig.f.observed.reservations);
            try std.testing.expectEqual(@as(usize, 1), rig.f.runtime.core.sessions.count());
            try rig.endOfStream();
            try rig.step();
            // The core still owns the unpublished session through the held
            // report, while the observer's seat is already back.
            try std.testing.expectEqual(@as(usize, 1), rig.rows());
            try std.testing.expectEqual(@as(usize, 1), rig.f.runtime.core.sessions.count());
            try std.testing.expectEqual(@as(usize, 0), rig.f.observed.reservations);
            try std.testing.expectEqual(@as(usize, 0), rig.f.observed.close_events);
            try rig.settle();
            try std.testing.expectEqual(@as(usize, 0), rig.f.runtime.core.sessions.count());
            try std.testing.expectEqual(@as(usize, 0), rig.f.runtime.core.node.pendingDialCount());
            try std.testing.expectEqual(@as(usize, 0), rig.f.observed.reservations);
            try std.testing.expectEqual(@as(usize, 0), rig.f.observed.close_events);
            try std.testing.expectEqual(@as(usize, 1), rig.f.resident.dial_starts);
        }
        if (!induced) break;
    }
    try std.testing.expect(landed > 0);
    try std.testing.expect(k < sweep_bound);
}

test "a wire that closes synchronously during its handshake publishes no close and returns its seat once" {
    var rig: Rig = undefined;
    try rig.init(.{ .ms = 10_000 });
    defer rig.deinit();
    try rig.connect();
    try std.testing.expectEqual(@as(usize, 1), rig.f.runtime.core.sessions.count());
    try std.testing.expectEqual(@as(usize, 1), rig.f.observed.reservations);
    try rig.endOfStream();
    try rig.step();
    try rig.settle();
    try std.testing.expectEqual(@as(usize, 0), rig.rows());
    try std.testing.expectEqual(@as(usize, 0), rig.f.runtime.wires.count());
    try std.testing.expectEqual(@as(usize, 0), rig.f.runtime.core.sessions.count());
    try std.testing.expectEqual(@as(usize, 0), rig.f.runtime.core.node.pendingDialCount());
    try std.testing.expectEqual(@as(usize, 0), rig.f.observed.close_events);
    try std.testing.expectEqual(@as(usize, 0), rig.f.observed.reservations);
    try std.testing.expect(!rig.f.observed.did_open);
}

test "a close failure named by the carrier survives a handshake's retained failed report" {
    var rig: Rig = undefined;
    try rig.init(.{ .ms = 10_000 });
    defer rig.deinit();
    try rig.connect();
    rig.holdDeadline();
    rig.f.resident.close_failure = namedFailure();
    try rig.endOfStream();
    try rig.step();
    // The wire's close completed with the failure and the handshake retired
    // into a retained report that owns the exact chain, nothing else.
    try std.testing.expect(rig.stage() == .failed_report);
    try std.testing.expectEqual(@as(usize, 0), rig.f.runtime.wires.count());
    try std.testing.expectEqual(@as(usize, 0), rig.f.runtime.core.sessions.count());
    try expectNamedFailure(rig.f.runtime.pending_opens.items[0].stage.failed_report.failure);
    rig.becomeDue();
    try rig.step();
    try std.testing.expectEqual(@as(usize, 0), rig.rows());
    try std.testing.expectEqual(@as(usize, 0), rig.f.runtime.core.node.pendingDialCount());
    try std.testing.expectEqual(@as(usize, 0), rig.f.observed.reservations);
    try std.testing.expectEqual(@as(usize, 0), rig.f.observed.close_events);
}
