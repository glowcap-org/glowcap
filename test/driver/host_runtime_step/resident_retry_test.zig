//! Debt a resident's allocator refused has its own paced retry on the
//! runtime (`resident_retry_due_ms`), separate from the core's deadline.
//! Resident-only debt gates no core work, a due resident pass runs before the
//! core gate on every exit, both clocks keep their own interval, and a latched
//! resident failure ends its debt and reaches the runtime through readiness.
//!
//! The resident is `AcceptOwnershipResident` with its `memory_retry` group
//! scripted by the test. Time is the rig's `SteppedClock`.

const std = @import("std");
const glowcap = @import("glowcap");

const driver = glowcap.driver;
const HostRuntime = driver.HostRuntime;
const net = glowcap.net;
const fixtures = @import("../host_runtime_multiplexed/residents.zig");
const Debt = fixtures.AcceptOwnershipResident;
const pressure_rig = @import("pressure_rig.zig");
const Rig = pressure_rig.Rig;
const SteppedClock = @import("../../support/stepped_clock.zig").SteppedClock;

const support = @import("retry_support.zig");
const Sink = support.Sink;
const FlushIdle = support.FlushIdle;
const FlushFail = support.FlushFail;
const buildRig = support.buildRig;
const breakPendingFetch = support.breakPendingFetch;
const queueCompletion = support.queueCompletion;
const retry_ms = support.retry_ms;

fn join(rig: *Rig, debt: *Debt) !void {
    _ = try rig.runtime.addResident(.{ .symbol = Debt.transport, .designator_scheme = .address }, debt.multiplexedResident());
}

fn joinAlternate(rig: *Rig, debt: *Debt) !void {
    _ = try rig.runtime.addResident(.{ .symbol = Debt.alternate_transport, .designator_scheme = .address }, debt.multiplexedResident());
}

fn armed(runtime: *HostRuntime) !i64 {
    return runtime.resident_retry_due_ms orelse error.ResidentDeadlineNotArmed;
}

test "resident-only debt gates no core work, and its retry runs once per interval" {
    var debt = try Debt.init();
    defer debt.deinit();
    const rig = try Rig.build(std.testing.allocator, .{ .fetches = 1, .clock_step_ns = std.time.ns_per_us });
    defer rig.destroy();
    const runtime = &rig.runtime;
    try join(rig, &debt);
    debt.owes_debt = true;
    debt.retry_pays = false;

    // The sibling's frame drains while the resident owes, and the core holds
    // no deadline of its own.
    rig.offerNext();
    _ = try rig.step();
    const first_due = try armed(runtime);
    try std.testing.expectEqual(@as(?i64, null), runtime.core.memory_retry_due_ms);
    try rig.expectAnswersInOrder();
    var sink = Sink{ .runtime = runtime };
    sink.install();
    try queueCompletion(rig);
    try std.testing.expect(runtime.core.hasRunnableWork());
    _ = try rig.step();
    try std.testing.expectEqual(@as(usize, 1), sink.takes);

    // Early steps never retry. The due step retries once and renews.
    try std.testing.expectEqual(@as(usize, 0), debt.retry_calls);
    for (0..3) |_| _ = try rig.step();
    try std.testing.expectEqual(@as(usize, 0), debt.retry_calls);
    try std.testing.expectEqual(first_due, try armed(runtime));
    rig.clock.advanceMs(retry_ms);
    _ = try rig.step();
    _ = try rig.step();
    try std.testing.expectEqual(@as(usize, 1), debt.retry_calls);
    const second_due = try armed(runtime);
    try std.testing.expect(second_due > first_due);
    rig.clock.advanceMs(retry_ms);
    _ = try rig.step();
    try std.testing.expectEqual(@as(usize, 2), debt.retry_calls);

    // Paid, the deadline clears at the same attempt's exit.
    debt.retry_pays = true;
    rig.clock.advanceMs(retry_ms);
    _ = try rig.step();
    try std.testing.expectEqual(@as(usize, 3), debt.retry_calls);
    try std.testing.expectEqual(@as(?i64, null), runtime.resident_retry_due_ms);
    try std.testing.expectEqual(@as(?i64, null), runtime.core.memory_retry_due_ms);
}

test "each owner retries once per its own interval and the wait is the nearer deadline" {
    var debt = try Debt.init();
    defer debt.deinit();
    const rig = try buildRig();
    defer rig.destroy();
    const runtime = &rig.runtime;
    try join(rig, &debt);
    var sink = Sink{ .runtime = runtime, .mode = .oom };
    sink.install();
    try breakPendingFetch(rig);

    // Core debt arms at 0 and its first attempt is refused.
    _ = try rig.step();
    try std.testing.expectEqual(@as(usize, 1), sink.reserves);
    const core_due = runtime.core.memory_retry_due_ms.?;
    // The resident's debt arrives 100 ms later, in its own epoch.
    rig.clock.advanceMs(100);
    debt.owes_debt = true;
    debt.retry_pays = false;
    _ = try rig.step();
    const resident_due = try armed(runtime);
    try std.testing.expect(resident_due > core_due);
    try std.testing.expectEqual(core_due, runtime.core.memory_retry_due_ms.?);
    const wait = runtime.stepWaitMs();
    try std.testing.expect(wait > 0 and wait <= retry_ms - 100);

    // The core's due attempt retries the core and leaves the resident alone.
    rig.clock.advanceMs(retry_ms - 100);
    _ = try rig.step();
    try std.testing.expectEqual(@as(usize, 2), sink.reserves);
    try std.testing.expectEqual(@as(usize, 0), debt.retry_calls);
    // The resident's due attempt retries it while the core, renewed, waits.
    rig.clock.advanceMs(100);
    _ = try rig.step();
    try std.testing.expectEqual(@as(usize, 2), sink.reserves);
    try std.testing.expectEqual(@as(usize, 1), debt.retry_calls);
    const next_wait = runtime.stepWaitMs();
    try std.testing.expect(next_wait > 0 and next_wait <= retry_ms - 100);
}

test "a core drain refused for memory cannot skip a due resident batch" {
    var debt = try Debt.init();
    defer debt.deinit();
    const rig = try buildRig();
    defer rig.destroy();
    const runtime = &rig.runtime;
    try join(rig, &debt);
    var sink = Sink{ .runtime = runtime, .mode = .oom };
    sink.install();
    try breakPendingFetch(rig);
    debt.owes_debt = true;
    debt.retry_pays = false;
    _ = try rig.step();
    try std.testing.expectEqual(@as(usize, 1), sink.reserves);
    try std.testing.expectEqual(@as(usize, 0), debt.retry_calls);

    // Both are due at once: the core drain is refused again, and the
    // resident batch ran first in the same attempt.
    rig.clock.advanceMs(retry_ms);
    _ = try rig.step();
    try std.testing.expectEqual(@as(usize, 2), sink.reserves);
    try std.testing.expectEqual(@as(usize, 1), debt.retry_calls);
}

test "a joining debt does not postpone an armed epoch in either domain" {
    var first = try Debt.init();
    defer first.deinit();
    var second = try Debt.init();
    defer second.deinit();
    const rig = try buildRig();
    defer rig.destroy();
    const runtime = &rig.runtime;
    try join(rig, &first);
    try joinAlternate(rig, &second);
    first.owes_debt = true;
    first.retry_pays = false;
    _ = try rig.step();
    const due = try armed(runtime);
    rig.clock.advanceMs(100);
    second.owes_debt = true;
    second.retry_pays = false;
    _ = try rig.step();
    try std.testing.expectEqual(due, try armed(runtime));

    // The core's armed deadline is never postponed either.
    HostRuntime.testing.closeTailFailed(runtime, error.OutOfMemory);
    const core_due = runtime.core.memory_retry_due_ms.?;
    rig.clock.advanceMs(50);
    HostRuntime.testing.closeTailFailed(runtime, error.OutOfMemory);
    try std.testing.expectEqual(core_due, runtime.core.memory_retry_due_ms.?);
}

test "the resident deadline reconciles on every attempt exit and at the flush tail" {
    const attemptWith = HostRuntime.testing.attemptWith;
    for (0..6) |which| {
        var debt = try Debt.init();
        defer debt.deinit();
        const rig = try buildRig();
        defer rig.destroy();
        const runtime = &rig.runtime;
        try join(rig, &debt);
        var sink = Sink{ .runtime = runtime };
        sink.install();
        debt.owes_debt = true;
        debt.retry_pays = false;
        runtime.resident_retry_due_ms = null;
        switch (which) {
            // The core's not-due return.
            0 => {
                HostRuntime.testing.closeTailFailed(runtime, error.OutOfMemory);
                try std.testing.expectEqual(HostRuntime.testing.Drain.retained, try attemptWith(runtime, .operational, .turn, FlushIdle));
            },
            // A flush error other than memory.
            1 => try std.testing.expectError(error.ProviderInternal, attemptWith(runtime, .operational, .turn, FlushFail)),
            // The park shortcut.
            2 => try std.testing.expectEqual(HostRuntime.testing.Drain.complete, try attemptWith(runtime, .operational, .park, FlushIdle)),
            // A drain refused for memory.
            3 => {
                sink.mode = .oom;
                try queueCompletion(rig);
                try std.testing.expectEqual(HostRuntime.testing.Drain.retained, try attemptWith(runtime, .operational, .turn, FlushIdle));
            },
            // A clean drain.
            4 => try std.testing.expectEqual(HostRuntime.testing.Drain.complete, try attemptWith(runtime, .operational, .turn, FlushIdle)),
            // The flush tail alone.
            else => HostRuntime.testing.flushResidents(runtime, .park),
        }
        _ = try armed(runtime);
        try std.testing.expectEqual(@as(usize, 0), debt.retry_calls);
    }
}

test "terminal failure clears the resident deadline and later cleanup, operational and flush paths ask no resident" {
    var debt = try Debt.init();
    defer debt.deinit();
    const rig = try buildRig();
    defer rig.destroy();
    const runtime = &rig.runtime;
    try join(rig, &debt);
    debt.owes_debt = true;
    debt.retry_pays = false;
    _ = try rig.step();
    _ = try armed(runtime);
    rig.clock.advanceMs(retry_ms);

    // The latch itself queries nobody and clears the deadline, though it is due.
    const asked = debt.owes_calls;
    runtime.noteTerminalFailure(error.ProviderInternal);
    try std.testing.expectEqual(asked, debt.owes_calls);
    try std.testing.expectEqual(@as(?i64, null), runtime.resident_retry_due_ms);

    // Supported cleanup after terminal: the cleanup-only attempt, then an
    // operational attempt (ungated after terminal) and a flush tail.
    _ = try HostRuntime.testing.attempt(runtime, .cleanup_only, .park);
    _ = try HostRuntime.testing.attempt(runtime, .operational, .park);
    HostRuntime.testing.flushResidents(runtime, .park);
    try std.testing.expectEqual(asked, debt.owes_calls);
    try std.testing.expectEqual(@as(usize, 0), debt.retry_calls);
    try std.testing.expectEqual(@as(?i64, null), runtime.resident_retry_due_ms);
}

fn reenter(sink: *Sink) void {
    sink.reentry = if (sink.runtime.stepAny(0)) |_| null else |err| err;
}

test "a callback's reentry is refused before any resident pass, and the outer attempt's retry ran once before it" {
    var debt = try Debt.init();
    defer debt.deinit();
    const rig = try buildRig();
    defer rig.destroy();
    const runtime = &rig.runtime;
    try join(rig, &debt);
    debt.owes_debt = true;
    debt.retry_pays = false;
    _ = try rig.step();
    const due = try armed(runtime);
    var sink = Sink{ .runtime = runtime, .on_take = reenter };
    sink.install();
    try queueCompletion(rig);
    rig.clock.advanceMs(retry_ms);

    // The outer attempt runs the due pass and renews, then drains the
    // completion. The callback's nested public step is refused at the entry,
    // so it never reaches the pass: one retry, one renewal.
    _ = try rig.step();
    try std.testing.expectEqual(@as(usize, 1), sink.takes);
    try std.testing.expectEqual(@as(?anyerror, error.ReenteredHost), sink.reentry);
    try std.testing.expectEqual(@as(usize, 1), debt.retry_calls);
    const renewed = try armed(runtime);
    // One interval past the deadline that was due, not a second renewal.
    try std.testing.expect(renewed >= due + retry_ms and renewed <= due + retry_ms + 2);
}

test "a resident failure ends its debt and reaches the runtime through readiness with no new retry" {
    var debt = try Debt.init();
    defer debt.deinit();
    const rig = try buildRig();
    defer rig.destroy();
    const runtime = &rig.runtime;
    try join(rig, &debt);
    debt.owes_debt = true;
    debt.latch_on_retry = true;
    _ = try rig.step();
    _ = try armed(runtime);
    rig.clock.advanceMs(retry_ms);
    // The retry latches. The same attempt's exit reconcile clears the
    // deadline, and the failure surfaces through the resident's drain.
    try std.testing.expectError(error.ProviderContract, rig.stepQuiet());
    try std.testing.expectEqual(@as(usize, 1), debt.retry_calls);
    try std.testing.expect(debt.latched);
    try std.testing.expectEqual(@as(?i64, null), runtime.resident_retry_due_ms);
    try std.testing.expectEqual(@as(?i64, null), runtime.core.memory_retry_due_ms);
}

test "debt a spin reaps arms a finite park bounded by the caller's budget, and recovers with no event" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var clock = SteppedClock.init(threaded.io(), 0, std.time.ns_per_us);
    var spinning = fixtures.opts;
    spinning.busy_poll_ns = 50 * std.time.ns_per_us;
    const wait = HostRuntime.testing.waitAnySource;

    // A caller's smaller budget is never extended to the interval. The debt
    // appears on the spin's third reap, after the first clamp ran with none.
    {
        var small = try Debt.init();
        defer small.deinit();
        small.parking = true;
        small.reap_debt_at = 3;
        small.retry_pays = true;
        var short = try HostRuntime.init(std.testing.allocator, clock.io(), .{}, .ephemeral, spinning);
        defer short.deinit();
        _ = try short.addResident(.{ .symbol = Debt.transport, .designator_scheme = .address }, small.multiplexedResident());
        _ = try wait(&short, 100, true);
        try std.testing.expect(small.reap_calls >= small.reap_debt_at.?);
        try std.testing.expectEqual(@as(usize, 1), small.park_calls);
        try std.testing.expect(small.park_timeout_ms.? <= 100);
    }

    var debt = try Debt.init();
    defer debt.deinit();
    debt.parking = true;
    debt.reap_debt_at = 3;
    debt.retry_pays = true;
    var runtime = try HostRuntime.init(std.testing.allocator, clock.io(), .{}, .ephemeral, spinning);
    defer runtime.deinit();
    _ = try runtime.addResident(.{ .symbol = Debt.transport, .designator_scheme = .address }, debt.multiplexedResident());

    // The spin ran, so the park that follows is the post-spin clamp's and is
    // bounded by the debt's interval, not the caller's 1000 ms.
    _ = try wait(&runtime, 1000, true);
    try std.testing.expect(debt.reap_calls >= debt.reap_debt_at.?);
    try std.testing.expectEqual(@as(usize, 1), debt.park_calls);
    const parked = debt.park_timeout_ms.?;
    try std.testing.expect(parked >= 0 and parked <= retry_ms);
    _ = try armed(&runtime);

    // Recovery needs no fresh event: the next top-level attempt past the
    // deadline retries.
    clock.advanceMs(retry_ms + 1);
    _ = try runtime.stepAny(0);
    try std.testing.expectEqual(@as(usize, 1), debt.retry_calls);
    try std.testing.expectEqual(@as(?i64, null), runtime.resident_retry_due_ms);
}

test "a borrowed core keeps no deadline a detached runtime armed on it" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var debt = try Debt.init();
    defer debt.deinit();
    debt.owes_debt = true;
    debt.retry_pays = false;
    const test_host = @import("../../support/core_host.zig");
    var core = test_host.init(allocator, @as([32]u8, @splat(0x53)), .{ .thread_policy = .unchecked });
    defer core.deinit();
    var adopted = try HostRuntime.initWithCore(allocator, threaded.io(), &core, .{}, .{
        .handshake = .{ .ms = 10_000 },
        .settle = .{ .ms = 10_000 },
    });
    _ = try adopted.addResident(.{ .symbol = Debt.transport, .designator_scheme = .address }, debt.multiplexedResident());
    HostRuntime.testing.closeTailFailed(&adopted, error.OutOfMemory);
    HostRuntime.testing.flushResidents(&adopted, .park);
    _ = try armed(&adopted);
    try std.testing.expect(core.memory_retry_due_ms != null);
    adopted.deinit();
    // Detach clears the deadline the runtime armed on the owner's core. The
    // resident deadline lives on the runtime and dies with it.
    try std.testing.expectEqual(@as(?i64, null), core.memory_retry_due_ms);
}
