//! The carrier-close deadline's abort on a wire whose close the resident
//! still holds. A detached wire has no caller left, so its abort delivers a
//! fresh physical close failure to the resident's own sink once and reports
//! nothing to the runtime. A wire the application still waits on receives that
//! failure after the timeout. A resident that declares no abort keeps the
//! detached wire until release. The resident here is the scripted
//! `ExternalAdoptionResident`: its abort answers as a completion resident's
//! does with a claimable provider failure, and the real resident's own
//! behavior is read in `test/net/external_close_claim_test.zig`.

const std = @import("std");
const glowcap = @import("glowcap");
const Rig = @import("../host_runtime_step/pressure_rig.zig").Rig;

const driver = glowcap.driver;

/// Past the runtime's carrier-close deadline.
const past_deadline_ms = 5_001;

fn build(spec: struct { abortable: bool, claims: bool }) !*Rig {
    return Rig.build(std.testing.allocator, .{
        .fetches = 0,
        .clock_step_ns = 1,
        .close_pends = true,
        .abortable = spec.abortable,
        .abort_claims_failure = spec.claims,
    });
}

test "an expired detached wire hands a fresh provider close failure to its sink once" {
    const rig = try build(.{ .abortable = true, .claims = true });
    defer rig.destroy();

    try rig.runtime.releaseWire(rig.session);
    // The close is waiting on the resident and the wire is detached, retained.
    try std.testing.expect(rig.resident.close_calls != 0);
    try std.testing.expect(rig.runtime.retiring_wires != null);
    try std.testing.expectEqual(@as(usize, 0), rig.resident.abort_calls);
    try std.testing.expectEqual(@as(usize, 0), rig.resident.sink_failures);

    rig.clock.advanceMs(past_deadline_ms);
    _ = try rig.stepQuiet();
    _ = try rig.stepQuiet();

    try std.testing.expectEqual(@as(usize, 1), rig.resident.abort_calls);
    try std.testing.expectEqual(@as(?glowcap.net.multiplexed_resident.CloseMode, .no_wait), rig.resident.abort_mode);
    try std.testing.expectEqual(@as(usize, 1), rig.resident.sink_failures);
    try std.testing.expect(rig.runtime.retiring_wires == null);
    // Nothing reaches a runtime recipient, and no stale cause is replayed.
    try std.testing.expectEqual(@as(usize, 0), rig.observed.close_events);
    try std.testing.expect(rig.runtime.terminalFailure() == null);
}

test "an expired wire the application still waits on receives the failure after the timeout" {
    const rig = try build(.{ .abortable = true, .claims = true });
    defer rig.destroy();

    try rig.runtime.beginSessionClose(rig.session, .cancel);
    var rounds: usize = 0;
    while (rig.resident.close_calls == 0 and rounds < 100) : (rounds += 1) _ = try rig.step();
    try std.testing.expect(rig.resident.close_calls != 0);
    try std.testing.expectEqual(@as(usize, 0), rig.observed.close_events);

    rig.clock.advanceMs(past_deadline_ms);
    _ = try rig.stepQuiet();

    try std.testing.expectEqual(@as(usize, 1), rig.resident.abort_calls);
    try std.testing.expectEqual(@as(?glowcap.net.multiplexed_resident.CloseMode, .awaited), rig.resident.abort_mode);
    try std.testing.expectEqual(@as(usize, 0), rig.resident.sink_failures);
    try std.testing.expectEqual(@as(usize, 1), rig.observed.close_events);
    const failure = rig.observed.close_detail.?;
    try std.testing.expectEqualStrings("CloseTimedOut", failure.chain.primaryName());
    try std.testing.expectEqualStrings("ResidentCloseFailed", failure.chain.secondaryName().?);
    try rig.runtime.releaseWire(rig.session);
}

test "a resident that declares no abort keeps the expired detached wire until release" {
    const rig = try build(.{ .abortable = false, .claims = false });
    defer rig.destroy();

    try rig.runtime.releaseWire(rig.session);
    rig.clock.advanceMs(past_deadline_ms);
    _ = try rig.stepQuiet();

    try std.testing.expectEqual(@as(usize, 0), rig.resident.abort_calls);
    try std.testing.expect(rig.runtime.retiring_wires != null);
    try std.testing.expectEqual(@as(usize, 0), rig.observed.close_events);
    // The release joins the physical close.
    rig.resident.close_completes = true;
}
