//! Retained redeem reports at the runtime's wait owners, on both faces: the
//! park inside `waitAnySource`, the tail after a wait that timed out, and the
//! terminal cleanup wait. Time passes through the resident's before-park hook
//! and the carrier close deadline, so no descriptor reports anything.

const std = @import("std");
const glowcap = @import("glowcap");

const driver = glowcap.driver;
const HostRuntime = driver.HostRuntime;
const Rig = @import("redeem_rig.zig").Rig;

const faces = [_]bool{ false, true };

fn advanceDuringPark(ctx: *anyopaque) void {
    const rig: *Rig = @ptrCast(@alignCast(ctx));
    rig.f.clock.advanceMs(60);
}

test "a handshake budget that expires during the park is reported in that wait's own tail" {
    for (faces) |blocking| {
        var rig: Rig = undefined;
        try rig.initOn(blocking, .{ .ms = 20 });
        defer rig.deinit();
        try rig.connect();
        rig.f.resident.before_wait_hook = advanceDuringPark;
        rig.f.resident.before_wait_ctx = &rig;
        const parks = rig.f.resident.before_wait_calls;
        const reads = rig.f.resident.read_calls;
        // One call: the park clamps to the row's deadline and times out, the
        // clock has moved by then, and the tail decides the row and runs the
        // report pass without another step.
        _ = try rig.f.runtime.stepAny(500);
        try std.testing.expect(rig.f.resident.before_wait_calls > parks);
        try std.testing.expectEqual(reads, rig.f.resident.read_calls);
        try std.testing.expectEqual(@as(usize, 0), rig.rows());
        try std.testing.expectEqual(@as(usize, 0), rig.f.runtime.core.node.pendingDialCount());
    }
}

test "a carrier the resident aborts at its deadline completes inside the park and its report runs there" {
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
        try std.testing.expect(rig.stage() == .opened_report);
        try std.testing.expect(rig.f.runtime.pending_opens.items[0].stage.opened_report.wait == .carrier_closing);
        try std.testing.expectEqual(@as(usize, 0), rig.f.resident.abort_calls);

        // The partner never reads the close. Past the carrier deadline, the
        // park's own prelude aborts it with no descriptor I/O, and the park
        // attempt that follows reports the row.
        rig.f.clock.advanceMs(5_001);
        const reads = rig.f.resident.read_calls;
        _ = try rig.f.runtime.stepAny(20);
        try std.testing.expectEqual(@as(usize, 1), rig.f.resident.abort_calls);
        try std.testing.expectEqual(reads, rig.f.resident.read_calls);
        try std.testing.expectEqual(@as(usize, 0), rig.rows());
        try std.testing.expectEqual(@as(usize, 0), rig.f.runtime.core.node.pendingDialCount());
        try std.testing.expectEqual(@as(usize, 0), rig.f.observed.close_events);
        try std.testing.expectEqual(@as(usize, 0), rig.f.observed.reservations);
    }
}

test "terminal cleanup forces a closing carrier without running its report" {
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

        rig.f.runtime.noteTerminalFailure(error.ProviderContract);
        // The cleanup wait forces the carrier closed instead of parking on a
        // close nothing will complete, and the terminal runtime runs no report.
        try std.testing.expectError(error.LoopTerminal, rig.f.runtime.stepAny(20));
        try std.testing.expectEqual(@as(usize, 1), rig.rows());
        try std.testing.expect(rig.stage() == .opened_report);
        try std.testing.expect(rig.f.runtime.pending_opens.items[0].stage.opened_report.wait == .ready);
        try std.testing.expectEqual(@as(usize, 0), rig.f.sink.takes);
        try std.testing.expectEqual(@as(usize, 1), rig.f.runtime.core.node.pendingDialCount());
        // The row's resources retire once under the runtime's own teardown.
        rig.f.resident.close_pending = false;
        rig.f.runtime.beginClose(.cancel);
        var rounds: usize = 0;
        while (rig.f.runtime.closeOutcome() == .pending and rounds < 64) : (rounds += 1) {
            rig.f.clock.advanceMs(100);
            try std.testing.expectError(error.LoopTerminal, rig.step());
        }
        try std.testing.expectEqual(@as(usize, 0), rig.rows());
        try std.testing.expectEqual(@as(usize, 0), rig.f.runtime.wires.count());
    }
}
