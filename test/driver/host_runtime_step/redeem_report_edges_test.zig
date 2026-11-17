//! Retained redeem reports at their edges: a carrier that closes under a
//! report, a terminal latch over ready reports and expired siblings, and
//! teardown from every report stage. Each scenario drives a real redeem
//! through the shared rig in `redeem_rig.zig`.

const std = @import("std");
const glowcap = @import("glowcap");

const net = glowcap.net;
const HostRuntime = glowcap.driver.HostRuntime;
const fx = @import("open_fixture.zig");
const refuseDial = fx.refuseDial;
const rig_mod = @import("redeem_rig.zig");
const Rig = rig_mod.Rig;
const sweep_bound = rig_mod.sweep_bound;
const AcceptOwnershipResident = @import("../host_runtime_multiplexed/residents.zig").AcceptOwnershipResident;

test "a report whose carrier is closing waits for that carrier and never for the memory clock" {
    var rig: Rig = undefined;
    try rig.init(.{ .ms = 10_000 });
    defer rig.deinit();
    try rig.readyOpened();

    // The partner's end of stream closes the wire, and the resident keeps the
    // close pending on its own terms.
    rig.f.resident.close_pending = true;
    rig.f.resident.read_result = 0;
    rig.f.resident.held_record = .{
        .subject = AcceptOwnershipResident.conn_id,
        .events = net.multiplexed_resident.ev_readable,
    };
    _ = try rig.f.resident.wake.nudge();
    try rig.step();
    // The deadline is still held, so the close lands before any report runs.
    var wires = rig.f.runtime.wires.valueIterator();
    try std.testing.expect(wires.next().?.*.closed);
    try std.testing.expect(rig.stage() == .opened_report);
    try std.testing.expectEqual(@as(usize, 0), rig.f.sink.takes);
    rig.becomeDue();
    try rig.step();
    try std.testing.expect(rig.stage() == .opened_report);
    try std.testing.expect(rig.f.runtime.pending_opens.items[0].stage.opened_report.wait == .carrier_closing);
    // Nothing reached the core, and the wire still owns its open session.
    try std.testing.expectEqual(@as(usize, 0), rig.f.sink.takes);
    try std.testing.expectEqual(@as(usize, 1), rig.f.runtime.wires.count());

    // Time alone never releases a closing carrier's report.
    rig.becomeDue();
    try rig.step();
    try std.testing.expect(rig.f.runtime.pending_opens.items[0].stage.opened_report.wait == .carrier_closing);
    try std.testing.expectEqual(@as(usize, 0), rig.f.sink.takes);

    // The carrier's own completion makes the report ready, and the next
    // permitted attempt reports the failed open exactly once.
    rig.f.resident.close_pending = false;
    try rig.closeEvent();
    try rig.step();
    try rig.settle();
    try std.testing.expectEqual(@as(usize, 1), rig.f.sink.takes);
    try std.testing.expectEqual(@as(usize, 0), rig.f.runtime.wires.count());
    try std.testing.expect(rig.f.runtime.terminal_failure == null);
}

test "a terminal latch ignores a ready report" {
    var rig: Rig = undefined;
    try rig.init(.{ .ms = 10_000 });
    defer rig.deinit();
    try rig.readyOpened();
    rig.becomeDue();
    // A permitted ready report makes the active runtime's wait zero; the
    // terminal latch removes that wake and leaves no timer, so the wait is -1.
    try std.testing.expectEqual(@as(i32, 0), rig.f.runtime.stepWaitMs());
    rig.f.runtime.noteTerminalFailure(error.ProviderContract);
    try std.testing.expectEqual(@as(i32, -1), rig.f.runtime.stepWaitMs());
    try std.testing.expectEqual(@as(usize, 0), rig.f.sink.takes);
}

test "a terminal latch ignores an expired handshake deadline" {
    var rig: Rig = undefined;
    try rig.init(.{ .ms = 50 });
    defer rig.deinit();
    try rig.connect();
    rig.f.clock.advanceMs(60);
    try std.testing.expectEqual(@as(i32, 0), rig.f.runtime.stepWaitMs());
    rig.f.runtime.noteTerminalFailure(error.ProviderContract);
    try std.testing.expectEqual(@as(i32, -1), rig.f.runtime.stepWaitMs());
    try std.testing.expect(rig.stage() == .handshake);
}

test "an active sweep over an expired row stops once the runtime is terminal" {
    var rig: Rig = undefined;
    try rig.init(.{ .ms = 50 });
    defer rig.deinit();
    try rig.connect();
    rig.f.clock.advanceMs(60);
    rig.f.runtime.noteTerminalFailure(error.ProviderContract);
    // The expired handshake is decided only by a live runtime: the sweep
    // leaves it to terminal cleanup, with no verdict and no core report.
    try HostRuntime.testing.advancePendingOpens(&rig.f.runtime);
    try std.testing.expect(rig.stage() == .handshake);
    try std.testing.expectEqual(@as(usize, 0), rig.f.sink.takes);
}

test "teardown from a held dial, a handshake, a ready report and a retained report frees everything" {
    // Each block leaves its rig in one stage and lets the deferred deinit
    // retire the row: the rig's balanced check proves nothing was orphaned.
    {
        var rig: Rig = undefined;
        try rig.init(.{ .ms = 10_000 });
        defer rig.deinit();
        rig.f.resident.hold_connect = true;
        try rig.f.enliven();
        try rig.step();
        try std.testing.expect(rig.stage() == .resident_dial);
    }
    {
        var rig: Rig = undefined;
        try rig.init(.{ .ms = 10_000 });
        defer rig.deinit();
        try rig.connect();
        try std.testing.expect(rig.stage() == .handshake);
    }
    {
        var rig: Rig = undefined;
        try rig.init(.{ .ms = 10_000 });
        defer rig.deinit();
        try rig.readyOpened();
    }
    {
        var rig: Rig = undefined;
        try rig.init(.{ .ms = 50 });
        defer rig.deinit();
        refuseDial(&rig.f.resident);
        try rig.giveWaiter(0);
        try rig.step();
        try std.testing.expect(rig.stage() == .failed_report);
    }
    // A retained opened report: land the refusal on the report's allocation.
    var k: usize = 0;
    var retained = false;
    while (k < sweep_bound and !retained) : (k += 1) {
        var rig: Rig = undefined;
        try rig.init(.{ .ms = 10_000 });
        defer rig.deinit();
        try rig.readyOpened();
        rig.arm(k);
        rig.becomeDue();
        try rig.step();
        if (rig.memoryRefused()) {
            try rig.expectGated();
            retained = true;
            try std.testing.expect(rig.stage() == .opened_report);
        }
        if (!rig.failing.induced) break;
    }
    try std.testing.expect(retained);
}
