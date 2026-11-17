//! Retained redeem reports. A redeem open owns its verdict until the core
//! commits it: the opened session (`exporterDialed`) or the exact failure
//! (`dialFailed`). One non-draining pass inside the common operational attempt
//! is the only reporter, so a producer only enqueues. A memory refusal keeps
//! the same row and waits for the Host's retry deadline, and a closing carrier
//! waits for its own completion, never for the memory clock.
//!
//! Every scenario drives a real redeem through the scripted resident and a raw
//! partner session on a stepped clock. A `FailingOnce` allocator lands one
//! refusal at every allocation a window reaches, so each report origin and
//! each pre-row allocation meets a real refusal rather than a stub.

const std = @import("std");
const glowcap = @import("glowcap");

const net = glowcap.net;
const fx = @import("open_fixture.zig");
const refuseDial = fx.refuseDial;
const rig_mod = @import("redeem_rig.zig");
const Rig = rig_mod.Rig;
const sweep_bound = rig_mod.sweep_bound;

test "a refusal before the row owns the dial commits no route failure and retries once" {
    var pre_row: usize = 0;
    var k: usize = 0;
    while (k < sweep_bound) : (k += 1) {
        var rig: Rig = undefined;
        try rig.init(.{ .ms = 10_000 });
        defer rig.deinit();
        rig.f.resident.hold_connect = true;
        try rig.f.enliven();
        rig.arm(k);
        try rig.step();
        const induced = rig.failing.induced;
        if (induced and rig.f.resident.dial_starts == 0) pre_row += 1;
        try rig.settleFor(4);
        // The route stayed undecided through the refusal: no failure reached
        // the core, and the provider was asked exactly once.
        try std.testing.expectEqual(@as(usize, 1), rig.f.resident.dial_starts);
        try std.testing.expectEqual(@as(usize, 0), rig.f.sink.takes);
        try std.testing.expectEqual(@as(usize, 1), rig.rows());
        try std.testing.expect(rig.stage() == .resident_dial);
        try std.testing.expect(rig.f.runtime.terminal_failure == null);
        if (!induced) break;
    }
    try std.testing.expect(pre_row > 0);
    try std.testing.expect(k < sweep_bound);
}

test "an opened report refused for memory keeps its open exporter and reports once when memory returns" {
    var refused: usize = 0;
    var k: usize = 0;
    while (k < sweep_bound) : (k += 1) {
        var rig: Rig = undefined;
        try rig.init(.{ .ms = 10_000 });
        defer rig.deinit();
        try rig.connect();
        rig.holdDeadline();
        try rig.deliverHello();
        try rig.step();
        // The open waits behind the held deadline as a ready report that still
        // owns its session and wire.
        try std.testing.expectEqual(@as(usize, 1), rig.rows());
        try std.testing.expect(rig.stage() == .opened_report);
        try std.testing.expect(rig.f.runtime.pending_opens.items[0].stage.opened_report.wait == .ready);

        rig.arm(k);
        rig.becomeDue();
        try rig.step();
        const induced = rig.failing.induced;
        var retained = false;
        if (rig.memoryRefused()) {
            try rig.expectGated();
            retained = true;
            refused += 1;
            // The refusal precedes the core's commit: the same open wire stays
            // alive, the Host retry deadline is armed, and nothing redialed.
            try std.testing.expect(rig.stage() == .opened_report);
            try std.testing.expectEqual(@as(usize, 1), rig.f.runtime.wires.count());
            var wires = rig.f.runtime.wires.valueIterator();
            try std.testing.expect(!wires.next().?.*.closed);
            try std.testing.expect(rig.f.runtime.core.memory_retry_due_ms != null);
            try std.testing.expectEqual(@as(usize, 1), rig.f.resident.dial_starts);
        }
        try rig.settle();
        try std.testing.expectEqual(@as(usize, 1), rig.f.resident.dial_starts);
        // A retained report commits the open session once memory returns. A
        // refusal after the core's commit is a completion failure instead.
        if (retained) {
            try std.testing.expectEqual(@as(usize, 1), rig.f.runtime.wires.count());
            try std.testing.expectEqual(@as(usize, 0), rig.f.sink.takes);
            // The core committed the open: its pending dial is gone and it
            // owns the one session, not merely the runtime row removed.
            try std.testing.expectEqual(@as(usize, 0), rig.rows());
            try std.testing.expectEqual(@as(usize, 0), rig.f.runtime.core.node.pendingDialCount());
            try std.testing.expectEqual(@as(usize, 1), rig.f.runtime.core.sessions.count());
        }
        try std.testing.expect(rig.f.runtime.terminal_failure == null);
        if (!induced) break;
    }
    try std.testing.expect(refused > 0);
    try std.testing.expect(k < sweep_bound);
}

const FailedOrigin = enum { connect_failure, connect_budget, wired_handshake, provider_refusal };

/// Land one refusal at every allocation the report window reaches, for a redeem
/// that fails at `origin`. Every refusal leaves a resource-free failed report
/// retained, and the failure reaches the core exactly once with no redial.
fn failedOriginSweep(origin: FailedOrigin) !void {
    var refused: usize = 0;
    var k: usize = 0;
    // The provider's refusal has already failed two routes when the report
    // under test is the third.
    const base: usize = if (origin == .provider_refusal) 3 else 1;
    while (k < sweep_bound) : (k += 1) {
        var rig: Rig = undefined;
        try rig.init(.{ .ms = 50 });
        defer rig.deinit();
        var waiters: usize = 1;
        rig.f.resident.hold_connect = true;
        if (origin == .wired_handshake) {
            rig.f.resident.connect_ready_at_start = true;
            rig.f.resident.connect_succeeds = true;
        }
        try rig.giveWaiter(0);
        try rig.step();
        if (origin == .wired_handshake) {
            // The connect completed: the row owns a core session and its wire.
            try std.testing.expect(rig.stage() == .handshake);
            try std.testing.expectEqual(@as(usize, 1), rig.f.runtime.wires.count());
            rig.quietConnects();
        } else {
            try std.testing.expect(rig.stage() == .resident_dial);
        }
        rig.holdDeadline();
        if (origin == .connect_budget or origin == .wired_handshake) {
            rig.f.clock.advanceMs(60);
        } else {
            const request = rig.f.runtime.pending_opens.items[0].stage.resident_dial.attempt.id().?;
            // A provider that refuses every dial after the first route.
            if (origin == .provider_refusal) refuseDial(&rig.f.resident);
            rig.f.resident.held_record = .{ .subject = request, .events = net.multiplexed_resident.ev_connect };
            _ = try rig.f.resident.wake.nudge();
        }
        try rig.step();
        try std.testing.expectEqual(@as(usize, 1), rig.rows());
        try std.testing.expect(rig.stage() == .failed_report);
        try std.testing.expectEqual(@as(usize, 0), rig.f.sink.takes);
        // The verdict retired every resource first: the wire and its session
        // are gone, and the retained failure carries the handshake timeout.
        try std.testing.expectEqual(@as(usize, 0), rig.f.runtime.wires.count());
        if (origin == .connect_budget or origin == .wired_handshake) {
            const failed = rig.f.runtime.pending_opens.items[0].stage.failed_report;
            try std.testing.expectEqual(error.HandshakeTimedOut, failed.failure.chain.cause);
        }
        if (origin == .provider_refusal) {
            // Report the first route unarmed. A step runs two attempts, so the
            // core's next two dials are refused inside Exec.dial and each
            // failure queues as a report. The third refused route is the
            // report under test, with the fourth route still ahead.
            rig.becomeDue();
            try rig.step();
            try std.testing.expectEqual(@as(usize, 1), rig.rows());
            try std.testing.expect(rig.stage() == .failed_report);
            try std.testing.expectEqual(base, rig.f.resident.dial_starts);
            try std.testing.expectEqual(@as(usize, 0), rig.f.sink.takes);
            rig.holdDeadline();
        }
        // Real admissions on the same pending exporter fill the promised
        // seats, so the report's own reserve needs a seat the queue lacks.
        waiters += try rig.fillPromisedSeats(waiters);
        rig.arm(k);
        rig.becomeDue();
        try rig.step();
        const induced = rig.failing.induced;
        if (rig.memoryRefused()) {
            try rig.expectGated();
            refused += 1;
            try std.testing.expect(rig.stage() == .failed_report);
            try std.testing.expect(rig.f.runtime.core.memory_retry_due_ms != null);
            try std.testing.expectEqual(base, rig.f.resident.dial_starts);
            try std.testing.expectEqual(@as(usize, 0), rig.f.runtime.wires.count());
            try std.testing.expectEqual(@as(usize, 0), rig.f.sink.takes);
        }
        // Memory returns: the failure reaches the core once, which advances to
        // the next route. A refused provider fails the last route too, so the
        // plan is exhausted and the open fails; a held connect stays dialing.
        rig.restore();
        var rounds: usize = 0;
        while (rounds < 16 and rig.f.resident.dial_starts <= base) : (rounds += 1) {
            rig.becomeDue();
            try rig.step();
        }
        try std.testing.expectEqual(base + 1, rig.f.resident.dial_starts);
        if (origin == .provider_refusal) {
            try rig.settle();
            try std.testing.expectEqual(@as(usize, 4), rig.f.resident.dial_starts);
            // Every waiter's seat settled with the exhausted plan, once.
            try std.testing.expectEqual(@as(usize, 0), rig.promised());
            try std.testing.expectEqual(@as(usize, 0), rig.f.runtime.core.node.pendingDialCount());
        } else {
            try std.testing.expectEqual(waiters, rig.promised());
            try std.testing.expectEqual(@as(usize, 1), rig.f.runtime.core.node.pendingDialCount());
            try std.testing.expectEqual(@as(usize, 1), rig.rows());
            try std.testing.expect(rig.stage() == .resident_dial);
            try std.testing.expectEqual(@as(usize, 0), rig.f.sink.takes);
        }
        try std.testing.expect(rig.f.runtime.terminal_failure == null);
        if (!induced) break;
    }
    try std.testing.expect(refused > 0);
    try std.testing.expect(k < sweep_bound);
}

test "a failed report refused for memory after an async connect failure is retained and reported once" {
    try failedOriginSweep(.connect_failure);
}

test "a failed report refused for memory after an expired connect budget is retained and reported once" {
    try failedOriginSweep(.connect_budget);
}

test "a failed report refused for memory after a wired handshake timeout is retained and reported once" {
    try failedOriginSweep(.wired_handshake);
}

test "a failed report refused for memory after an immediate provider refusal is retained and reported once" {
    try failedOriginSweep(.provider_refusal);
}
