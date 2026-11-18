//! The blocking face's park over a multiplexed resident (ADR-0060): a record
//! a resident holds without a descriptor wake is serviced before the park, a
//! busy-poll window services a record that lands during the spin, and the
//! window never outlasts the step's own budget, even on a clock that stands
//! still.

const std = @import("std");
const glowcap = @import("glowcap");

const driver = glowcap.driver;
const net = glowcap.net;

const fixtures = @import("residents.zig");
const Rig = @import("../host_runtime_step/pressure_rig.zig").Rig;
const SteppedClock = @import("../../support/stepped_clock.zig").SteppedClock;
const AcceptOwnershipResident = fixtures.AcceptOwnershipResident;
const opts = fixtures.opts;

test "a blocking step services a record a resident holds without a descriptor wake" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var resident = try AcceptOwnershipResident.init();
    defer resident.deinit();

    var runtime = try driver.HostRuntime.init(std.testing.allocator, io, .{}, .ephemeral, opts);
    defer runtime.deinit();
    _ = try runtime.addResident(.{
        .symbol = AcceptOwnershipResident.transport,
        .designator_scheme = .address,
    }, resident.multiplexedResident());

    // The resident's descriptor never fires: the record waits in userland,
    // so the step must service it instead of parking for the whole budget.
    // Staged work reaches the kernel as the step would park, and again as
    // the verb returns, since the caller may not come back soon.
    resident.held_record = .{ .subject = 404, .events = net.multiplexed_resident.ev_writable };
    const started = net.clock.nowMonotonicMs();
    _ = try runtime.stepAny(5_000);
    try std.testing.expect(net.clock.nowMonotonicMs() - started < 1_000);
    try std.testing.expectEqual(@as(?net.multiplexed_resident.ReadyEvent, null), resident.held_record);
    try std.testing.expectEqual(@as(usize, 1), resident.drain_calls);
    try std.testing.expectEqual(@as(usize, 2), resident.before_wait_calls);
}

test "a busy-poll window services a record that lands during the spin without a descriptor wake" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var resident = try AcceptOwnershipResident.init();
    defer resident.deinit();

    var spinning = opts;
    spinning.busy_poll_ns = driver.HostRuntime.max_busy_poll_ns;
    var runtime = try driver.HostRuntime.init(std.testing.allocator, io, .{}, .ephemeral, spinning);
    defer runtime.deinit();
    _ = try runtime.addResident(.{
        .symbol = AcceptOwnershipResident.transport,
        .designator_scheme = .address,
    }, resident.multiplexedResident());

    // Nothing is held as the step begins and the descriptor never fires:
    // only the spin's third reap produces the record, so a step that parked
    // at once would wait out its whole budget.
    resident.reap_record_at = 3;
    const started = net.clock.nowMonotonicMs();
    _ = try runtime.stepAny(5_000);
    try std.testing.expect(net.clock.nowMonotonicMs() - started < 1_000);
    try std.testing.expectEqual(@as(usize, 3), resident.reap_calls);
    try std.testing.expectEqual(@as(usize, 1), resident.drain_calls);
    try std.testing.expectEqual(@as(?net.multiplexed_resident.ReadyEvent, null), resident.held_record);
}

test "a busy-poll window is bounded by the step's own budget" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var resident = try AcceptOwnershipResident.init();
    defer resident.deinit();

    var spinning = opts;
    spinning.busy_poll_ns = driver.HostRuntime.max_busy_poll_ns;
    var runtime = try driver.HostRuntime.init(std.testing.allocator, io, .{}, .ephemeral, spinning);
    defer runtime.deinit();
    _ = try runtime.addResident(.{
        .symbol = AcceptOwnershipResident.transport,
        .designator_scheme = .address,
    }, resident.multiplexedResident());

    const started = net.clock.nowMonotonicMs();
    try std.testing.expectEqual(@as(?net.Progress, null), try runtime.stepAny(20));
    try std.testing.expect(net.clock.nowMonotonicMs() - started < 1_000);
    try std.testing.expect(resident.reap_calls > 0);
}

test "a busy-poll window ends on a clock that never moves" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var resident = try AcceptOwnershipResident.init();
    defer resident.deinit();

    var spinning = opts;
    spinning.busy_poll_ns = driver.HostRuntime.max_busy_poll_ns;
    var runtime = try driver.HostRuntime.init(std.testing.allocator, io, .{}, .ephemeral, spinning);
    defer runtime.deinit();
    _ = try runtime.addResident(.{
        .symbol = AcceptOwnershipResident.transport,
        .designator_scheme = .address,
    }, resident.multiplexedResident());

    // An injected clock that advances only when something sleeps reads the
    // same instant for the whole spin. The window must still end.
    const Frozen = struct {
        fn now(_: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
            return .{ .nanoseconds = 0 };
        }
    };
    var frozen_vtable = io.vtable.*;
    frozen_vtable.now = Frozen.now;
    runtime.io.vtable = &frozen_vtable;
    defer runtime.io.vtable = io.vtable;

    // The step's own budget is shorter than the window, so it bounds the
    // spin at one round per nanosecond of it. The spin is the only reap on
    // this path, so a clock that never moves spends every round.
    const budget_ms = 1;
    try std.testing.expectEqual(@as(?net.Progress, null), try runtime.stepAny(budget_ms));
    try std.testing.expectEqual(@as(usize, budget_ms * std.time.ns_per_ms), resident.reap_calls);
}

test "a busy-poll window past the runtime's maximum is refused at adoption" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var spinning = opts;
    spinning.busy_poll_ns = driver.HostRuntime.max_busy_poll_ns + 1;
    try std.testing.expectError(
        error.BusyPollWindowTooLong,
        driver.HostRuntime.init(std.testing.allocator, io, .{}, .ephemeral, spinning),
    );
    spinning.busy_poll_ns = driver.HostRuntime.max_busy_poll_ns;
    var runtime = try driver.HostRuntime.init(std.testing.allocator, io, .{}, .ephemeral, spinning);
    runtime.deinit();
}

const spin_step_ns = std.time.ns_per_us;
const spin_window_ns = 20 * std.time.ns_per_us;
const advance_ms = 31;

/// A positive budget spins the window and reaps the resident. Zero does not.
fn expectSpun(timeout_ms: i32, reaps: usize) !void {
    if (timeout_ms > 0) try std.testing.expect(reaps > 0) else try std.testing.expectEqual(@as(usize, 0), reaps);
}

fn expectClockFollows(runtime: *driver.HostRuntime, clock: *const SteppedClock) !void {
    const before = runtime.nowMs();
    clock.advanceMs(advance_ms);
    try std.testing.expect(runtime.nowMs() - before >= advance_ms);
}

fn stepSessionOutsideTurn(timeout_ms: i32) !void {
    // Declared before the rig so it outlives the runtime the rig destroys.
    var quiet = try AcceptOwnershipResident.init();
    defer quiet.deinit();
    const rig = try Rig.build(std.testing.allocator, .{
        .fetches = 0,
        .blocking = true,
        .clock_step_ns = spin_step_ns,
        .busy_poll_ns = spin_window_ns,
    });
    defer rig.destroy();
    _ = try rig.runtime.addResident(.{
        .symbol = AcceptOwnershipResident.transport,
        .designator_scheme = .address,
    }, quiet.multiplexedResident());

    try std.testing.expectEqual(@as(?i64, null), rig.runtime.turn_ms);
    try std.testing.expectEqual(@as(usize, 0), quiet.reap_calls);
    try std.testing.expectEqual(@as(?net.Progress, null), try rig.runtime.stepSession(rig.session, timeout_ms));
    try expectSpun(timeout_ms, quiet.reap_calls);
    // `stepSession` owns no turn: the clock it leaves is the live one.
    try std.testing.expectEqual(@as(?i64, null), rig.runtime.turn_ms);
    try expectClockFollows(&rig.runtime, &rig.clock);
}

test "a session step with a busy-poll window spins and leaves no turn clock behind" {
    try stepSessionOutsideTurn(3);
}

test "a session step with no budget does not spin or leave a turn clock behind" {
    try stepSessionOutsideTurn(0);
}

fn waitInsideTurn(timeout_ms: i32) !void {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var clock = SteppedClock.init(threaded.io(), 0, spin_step_ns);

    var resident = try AcceptOwnershipResident.init();
    defer resident.deinit();

    var spinning = opts;
    spinning.busy_poll_ns = spin_window_ns;
    var runtime = try driver.HostRuntime.init(std.testing.allocator, clock.io(), .{}, .ephemeral, spinning);
    defer runtime.deinit();
    _ = try runtime.addResident(.{
        .symbol = AcceptOwnershipResident.transport,
        .designator_scheme = .address,
    }, resident.multiplexedResident());

    runtime.readTurnClock();
    const seed = runtime.turn_ms.?;
    clock.advanceMs(advance_ms);
    try std.testing.expectEqual(seed, runtime.nowMs());
    try std.testing.expectEqual(@as(?usize, null), try driver.HostRuntime.testing.waitAnySource(&runtime, timeout_ms, true));
    try expectSpun(timeout_ms, resident.reap_calls);
    // The turn the caller opened stays open and moves past the spin.
    try std.testing.expect(runtime.turn_ms.? >= seed + advance_ms);
    try std.testing.expectEqual(runtime.turn_ms.?, runtime.nowMs());
}

test "a wait inside a turn spins and refreshes the open turn clock" {
    try waitInsideTurn(3);
}

test "a wait inside a turn with no budget keeps the turn open on a fresh reading" {
    try waitInsideTurn(0);
}
