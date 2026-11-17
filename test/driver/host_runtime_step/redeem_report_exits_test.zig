//! Retained redeem reports at their exits: runtime close from every report
//! stage, a handle that outlives its stage, a terminal latch over retry
//! waits, and a wire that closes synchronously under a held report.

const std = @import("std");
const glowcap = @import("glowcap");

const driver = glowcap.driver;
const HostRuntime = driver.HostRuntime;
const fx = @import("open_fixture.zig");
const refuseDial = fx.refuseDial;
const rig_mod = @import("redeem_rig.zig");
const Rig = rig_mod.Rig;
const sweep_bound = rig_mod.sweep_bound;

const faces = [_]bool{ false, true };

fn expectClosedEmpty(rig: *Rig) !void {
    // `close` waits on the stepped clock, so advance it between steps.
    rig.f.runtime.beginClose(.cancel);
    var rounds: usize = 0;
    while (rig.f.runtime.closeOutcome() == .pending and rounds < 64) : (rounds += 1) {
        rig.f.clock.advanceMs(100);
        try rig.step();
    }
    try std.testing.expectEqual(@as(usize, 0), rig.rows());
    try std.testing.expectEqual(@as(usize, 0), rig.f.runtime.wires.count());
    try std.testing.expect(rig.f.runtime.closeOutcome() == .closed);
    // Every resource retired once: no core session, no seat, no wire still
    // waiting for its physical close, and nothing published.
    try std.testing.expectEqual(@as(usize, 0), rig.f.runtime.core.sessions.count());
    try std.testing.expectEqual(@as(usize, 0), rig.f.observed.reservations);
    try std.testing.expectEqual(@as(usize, 0), rig.f.observed.close_events);
    try std.testing.expect(rig.f.runtime.retiring_wires == null);
}

test "closing the runtime cancels a held resident dial" {
    for (faces) |blocking| {
        var rig: Rig = undefined;
        try rig.initOn(blocking, .{ .ms = 10_000 });
        defer rig.deinit();
        rig.f.resident.hold_connect = true;
        try rig.f.enliven();
        try rig.step();
        try std.testing.expect(rig.stage() == .resident_dial);
        try expectClosedEmpty(&rig);
    }
}

test "closing the runtime cancels a handshake" {
    for (faces) |blocking| {
        var rig: Rig = undefined;
        try rig.initOn(blocking, .{ .ms = 10_000 });
        defer rig.deinit();
        try rig.connect();
        try std.testing.expect(rig.stage() == .handshake);
        try expectClosedEmpty(&rig);
    }
}

test "closing the runtime cancels a ready opened report" {
    for (faces) |blocking| {
        var rig: Rig = undefined;
        try rig.initOn(blocking, .{ .ms = 10_000 });
        defer rig.deinit();
        try rig.readyOpened();
        try std.testing.expect(rig.stage() == .opened_report);
        try expectClosedEmpty(&rig);
    }
}

test "closing the runtime cancels a ready failed report" {
    for (faces) |blocking| {
        var rig: Rig = undefined;
        try rig.initOn(blocking, .{ .ms = 50 });
        defer rig.deinit();
        refuseDial(&rig.f.resident);
        try rig.f.enliven();
        _ = try HostRuntime.testing.attempt(&rig.f.runtime, .operational, .turn);
        try std.testing.expect(rig.stage() == .failed_report);
        try expectClosedEmpty(&rig);
    }
}

test "closing the runtime cancels an opened report refused for memory" {
    var retained = false;
    var k: usize = 0;
    while (k < sweep_bound and !retained) : (k += 1) {
        var rig: Rig = undefined;
        try rig.init(.{ .ms = 10_000 });
        defer rig.deinit();
        try rig.readyOpened();
        rig.arm(k);
        rig.becomeDue();
        try rig.step();
        rig.restore();
        if (rig.memoryRefused()) {
            retained = true;
            try std.testing.expect(rig.stage() == .opened_report);
            try expectClosedEmpty(&rig);
        }
        if (!rig.failing.induced) break;
    }
    try std.testing.expect(retained);
}

test "closing the runtime cancels a retry wait" {
    for (faces) |blocking| {
        var rig: Rig = undefined;
        try rig.initRetrying(.{ .blocking = blocking }, .{ .ms = 10_000 }, retrying);
        defer rig.deinit();
        rig.f.resident.hold_connect = true;
        rig.f.resident.connect_ready_at_start = true;
        try rig.f.enliven();
        try rig.step();
        try std.testing.expect(rig.stage() == .retry_wait);
        try expectClosedEmpty(&rig);
        try std.testing.expectEqual(@as(usize, 0), rig.f.runtime.core.node.pendingDialCount());
    }
}

test "closing the runtime cancels an opened report waiting on its closing carrier and aborts the pending close" {
    for (faces) |blocking| {
        var rig: Rig = undefined;
        try rig.initAbortable(blocking, .{ .ms = 10_000 });
        defer rig.deinit();
        try rig.readyOpened();
        rig.f.resident.close_pending = true;
        try rig.endOfStream();
        try rig.step();
        rig.becomeDue();
        try rig.step();
        try std.testing.expect(rig.f.runtime.pending_opens.items[0].stage.opened_report.wait == .carrier_closing);
        try std.testing.expectEqual(@as(usize, 1), rig.f.runtime.wires.count());
        try expectClosedEmpty(&rig);
        // The partner never read the close: the carrier deadline aborted it
        // once, and nothing is left retiring.
        try std.testing.expectEqual(@as(usize, 1), rig.f.resident.abort_calls);
        try std.testing.expectEqual(@as(usize, 0), rig.f.runtime.core.node.pendingDialCount());
    }
}

test "closing the runtime cancels a failed report refused for memory" {
    var retained = false;
    var k: usize = 0;
    while (k < sweep_bound and !retained) : (k += 1) {
        var rig: Rig = undefined;
        try rig.init(.{ .ms = 50 });
        defer rig.deinit();
        rig.f.resident.hold_connect = true;
        try rig.giveWaiter(0);
        try rig.step();
        rig.holdDeadline();
        rig.f.clock.advanceMs(60);
        try rig.step();
        try std.testing.expect(rig.stage() == .failed_report);
        _ = try rig.fillPromisedSeats(1);
        rig.arm(k);
        rig.becomeDue();
        try rig.step();
        rig.restore();
        if (rig.memoryRefused()) {
            retained = true;
            try std.testing.expect(rig.stage() == .failed_report);
            try expectClosedEmpty(&rig);
            try std.testing.expectEqual(@as(usize, 0), rig.f.runtime.core.node.pendingDialCount());
        }
        if (!rig.failing.induced) break;
    }
    try std.testing.expect(retained);
}

test "a session handle from a retired handshake finds no row" {
    var rig: Rig = undefined;
    try rig.init(.{ .ms = 50 });
    defer rig.deinit();
    try rig.connect();
    const old = rig.f.runtime.pending_opens.items[0].stage.session().?;
    try std.testing.expect(HostRuntime.testing.pendingOpenFor(&rig.f.runtime, old) != null);
    rig.holdDeadline();
    rig.f.clock.advanceMs(60);
    try rig.step();
    // The handshake expired: the row now holds only its verdict.
    try std.testing.expect(rig.stage() == .failed_report);
    try std.testing.expect(HostRuntime.testing.pendingOpenFor(&rig.f.runtime, old) == null);
    rig.becomeDue();
    try rig.step();
    try std.testing.expectEqual(@as(usize, 0), rig.rows());
    try std.testing.expect(HostRuntime.testing.pendingOpenFor(&rig.f.runtime, old) == null);
}

const retry_interval_ms = 30;
const retrying: @FieldType(driver.SessionOptions, "dial_retry") = .{
    .max_attempts = 3,
    .retry_interval_ms = retry_interval_ms,
};

test "a wire that closes synchronously under a held report reports once" {
    var rig: Rig = undefined;
    try rig.init(.{ .ms = 10_000 });
    defer rig.deinit();
    try rig.readyOpened();
    // The open's close-observer seat is held while its report waits.
    try std.testing.expectEqual(@as(usize, 1), rig.f.observed.reservations);
    try rig.endOfStream();
    try rig.step();
    // The wire closed with no pending completion before the session ever
    // surfaced: the seat is released once, and no close event fires.
    try std.testing.expectEqual(@as(usize, 0), rig.f.observed.reservations);
    try std.testing.expectEqual(@as(usize, 0), rig.f.observed.close_events);
    rig.becomeDue();
    try rig.step();
    try rig.settle();
    try std.testing.expectEqual(@as(usize, 0), rig.rows());
    try std.testing.expectEqual(@as(usize, 0), rig.f.runtime.core.node.pendingDialCount());
    try std.testing.expectEqual(@as(usize, 0), rig.f.observed.reservations);
    try std.testing.expectEqual(@as(usize, 0), rig.f.observed.close_events);
}

/// Open the rig's redeem with its report ready behind a held deadline, then
/// begin a cancelling close. The core marks the pending exporter cancelled at
/// once, so the report the next attempt runs is stale and not adopted.
fn staleOpenedReport(rig: *Rig) !void {
    try rig.readyOpened();
    try std.testing.expectEqual(@as(usize, 1), rig.f.observed.reservations);
    rig.becomeDue();
    rig.f.runtime.beginClose(.cancel);
}

test "a stale opened report retires its session once when the carrier closes synchronously" {
    var rig: Rig = undefined;
    try rig.init(.{ .ms = 10_000 });
    defer rig.deinit();
    try staleOpenedReport(&rig);
    _ = try HostRuntime.testing.attempt(&rig.f.runtime, .operational, .turn);
    // The session was never published: no application close, and the one
    // close-observer seat went back exactly once.
    try std.testing.expectEqual(@as(usize, 0), rig.rows());
    try std.testing.expectEqual(@as(usize, 0), rig.f.runtime.wires.count());
    try std.testing.expectEqual(@as(usize, 0), rig.f.observed.close_events);
    try std.testing.expectEqual(@as(usize, 0), rig.f.observed.reservations);
    try std.testing.expect(!rig.f.observed.did_open);
    try std.testing.expectEqual(@as(usize, 0), rig.f.runtime.core.sessions.count());
}

test "a stale opened report retires its session once when the carrier closes later" {
    var rig: Rig = undefined;
    try rig.init(.{ .ms = 10_000 });
    defer rig.deinit();
    rig.f.resident.close_pending = true;
    try staleOpenedReport(&rig);
    _ = try HostRuntime.testing.attempt(&rig.f.runtime, .operational, .turn);
    // The wire detached with its close still pending: the seat is already
    // back, nothing was published, and the resident still owns the close.
    try std.testing.expectEqual(@as(usize, 0), rig.rows());
    try std.testing.expectEqual(@as(usize, 0), rig.f.runtime.wires.count());
    try std.testing.expectEqual(@as(usize, 0), rig.f.observed.reservations);
    try std.testing.expectEqual(@as(usize, 0), rig.f.observed.close_events);
    try std.testing.expect(rig.f.runtime.retiring_wires != null);
    rig.f.resident.close_pending = false;
    try rig.closeEvent();
    try rig.step();
    try std.testing.expect(rig.f.runtime.retiring_wires == null);
    try std.testing.expectEqual(@as(usize, 0), rig.f.observed.reservations);
    try std.testing.expectEqual(@as(usize, 0), rig.f.observed.close_events);
    try std.testing.expectEqual(@as(usize, 0), rig.f.runtime.core.sessions.count());
}

// Direct teardown: `deinit` from the live state, not after a cancelling close.
// Each scenario asserts what the row owns immediately before `deinit`, then
// that the allocator balances (checked by `Rig.deinit`) and the close
// observer's seat is back, with nothing published.

test "deinit from a retry wait retires its session" {
    for (faces) |blocking| {
        var rig: Rig = undefined;
        try rig.initRetrying(.{ .blocking = blocking }, .{ .ms = 10_000 }, retrying);
        defer rig.deinit();
        rig.f.resident.hold_connect = true;
        rig.f.resident.connect_ready_at_start = true;
        try rig.f.enliven();
        try rig.step();
        try std.testing.expect(rig.stage() == .retry_wait);
        try std.testing.expectEqual(@as(usize, 1), rig.f.runtime.core.sessions.count());
        try std.testing.expectEqual(@as(usize, 0), rig.f.runtime.wires.count());
        try std.testing.expectEqual(@as(usize, 1), rig.f.runtime.core.node.pendingDialCount());
        rig.deinit();
        try std.testing.expectEqual(@as(usize, 0), rig.f.observed.reservations);
        try std.testing.expectEqual(@as(usize, 0), rig.f.observed.close_events);
    }
}

test "deinit from a report waiting on a pending physical close retires the session and returns its seat" {
    for (faces) |blocking| {
        var rig: Rig = undefined;
        try rig.initOn(blocking, .{ .ms = 10_000 });
        defer rig.deinit();
        try rig.readyOpened();
        rig.f.resident.close_pending = true;
        try rig.endOfStream();
        try rig.step();
        rig.becomeDue();
        try rig.step();
        try std.testing.expect(rig.f.runtime.pending_opens.items[0].stage.opened_report.wait == .carrier_closing);
        // The physical close is still pending and the row still holds the
        // core session and, on the stepped face, the one seat (the blocking
        // face publishes no closes and holds none).
        try std.testing.expectEqual(@as(usize, 1), rig.f.runtime.wires.count());
        try std.testing.expectEqual(@as(usize, 1), rig.f.runtime.core.sessions.count());
        try std.testing.expectEqual(@as(usize, if (blocking) 0 else 1), rig.f.observed.reservations);
        rig.deinit();
        try std.testing.expectEqual(@as(usize, 0), rig.f.observed.reservations);
        try std.testing.expectEqual(@as(usize, 0), rig.f.observed.close_events);
    }
}

test "deinit from a failed report refused for memory frees the retained verdict" {
    var retained = false;
    var k: usize = 0;
    while (k < sweep_bound and !retained) : (k += 1) {
        var rig: Rig = undefined;
        try rig.init(.{ .ms = 50 });
        defer rig.deinit();
        rig.f.resident.hold_connect = true;
        try rig.giveWaiter(0);
        try rig.step();
        rig.holdDeadline();
        rig.f.clock.advanceMs(60);
        try rig.step();
        _ = try rig.fillPromisedSeats(1);
        rig.arm(k);
        rig.becomeDue();
        try rig.step();
        rig.restore();
        if (rig.memoryRefused()) {
            retained = true;
            try std.testing.expect(rig.stage() == .failed_report);
            try std.testing.expectEqual(@as(usize, 0), rig.f.runtime.wires.count());
            try std.testing.expectEqual(@as(usize, 0), rig.f.runtime.core.sessions.count());
            try std.testing.expect(rig.f.runtime.core.memory_retry_due_ms != null);
            const starts = rig.f.resident.dial_starts;
            rig.deinit();
            // Nothing redialed, and no seat or close is left behind.
            try std.testing.expectEqual(starts, rig.f.resident.dial_starts);
            try std.testing.expectEqual(@as(usize, 0), rig.f.observed.reservations);
        }
        if (!rig.failing.induced) break;
    }
    try std.testing.expect(retained);
}
