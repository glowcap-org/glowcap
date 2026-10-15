//! The blocking face's park over a multiplexed resident (ADR-0213,
//! ADR-0215): a record a resident holds without a descriptor wake is
//! serviced before the park, a busy-poll window services a record that lands
//! during the spin, and the window never outlasts the step's own budget.

const std = @import("std");
const glowcap = @import("glowcap");

const driver = glowcap.driver;
const net = glowcap.net;

const fixtures = @import("residents.zig");
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
