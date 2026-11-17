//! A decided session open queues its consequences and never drains beneath
//! its caller. An open decided inside `Exec.dial` or `startDial` leaves them
//! for the loop already running, or for the next step. An open decided by the
//! pump's sweep answers them before the step parks. A shortage of memory at
//! that drain leaves them retained behind the retry deadline instead of
//! failing the sweep.
//!
//! The refusal is a completion sink that cannot reserve a slot, and the open
//! fails through a scripted resident: an immediate refusal, a connect that
//! completes with a failure, or a connect that never answers inside the
//! handshake budget. A `SteppedClock` the test advances supplies time.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const driver = glowcap.driver;
const driver_core = driver.core;
const HostRuntime = driver.HostRuntime;
const fixtures = @import("../host_runtime_multiplexed/residents.zig");
const AcceptOwnershipResident = fixtures.AcceptOwnershipResident;
const ObservedOpen = fixtures.ObservedOpen;
const SteppedClock = @import("../../support/stepped_clock.zig").SteppedClock;
const fx = @import("open_fixture.zig");
const Fixture = fx.Fixture;
const refuseDial = fx.refuseDial;
const retry_ms = fx.retry_ms;
const transport = fx.transport;
const handshake_ms = fx.handshake_ms;

test "an open the provider refuses inside Exec.dial drains once, from the loop already running" {
    var f: Fixture = undefined;
    try f.start(.{ .ms = 10_000 });
    defer f.stop();
    refuseDial(&f.resident);
    f.sink.refuse = true;
    try f.enliven();

    _ = try f.runtime.stepAny(0);
    // The refused dial failed its route and broke the fetch: one completion,
    // met once by the outer drain, never by a drain nested in the dial.
    try std.testing.expectEqual(@as(usize, 1), f.resident.dial_starts);
    try std.testing.expectEqual(@as(usize, 0), f.runtime.pending_opens.items.len);
    try std.testing.expectEqual(@as(usize, 1), f.sink.reserves);
    const outer_depth = f.sink.depth_seen;
    try std.testing.expect(f.runtime.terminal_failure == null);
    try std.testing.expect(f.runtime.core.memory_retry_due_ms != null);

    f.sink.refuse = false;
    f.clock.advanceMs(retry_ms);
    _ = try f.runtime.stepAny(0);
    try std.testing.expectEqual(@as(usize, 1), f.sink.takes);
    try std.testing.expectEqual(@as(?i64, null), f.runtime.core.memory_retry_due_ms);
    try std.testing.expectEqual(outer_depth, f.sink.depth_seen);
}

test "an open that fails when its connect completes is drained by the step that serviced it" {
    var f: Fixture = undefined;
    try f.start(.{ .ms = 10_000 });
    defer f.stop();
    f.resident.hold_connect = true;
    f.resident.connect_ready_at_start = true;
    try f.enliven();

    // The first step stages the dial, services the connect that completes with
    // a failure, and answers the completion it breaks before it parks.
    _ = try f.runtime.stepAny(0);
    try std.testing.expectEqual(@as(usize, 1), f.sink.takes);
    try std.testing.expectEqual(@as(usize, 0), f.runtime.pending_opens.items.len);
    try std.testing.expect(f.runtime.terminal_failure == null);
    try std.testing.expectEqual(@as(?i64, null), f.runtime.core.memory_retry_due_ms);
}

test "an open the sweep fails at its deadline answers its consequences before the step parks" {
    var f: Fixture = undefined;
    try f.start(.{ .ms = handshake_ms });
    defer f.stop();
    f.resident.hold_connect = true;
    try f.enliven();
    _ = try f.runtime.stepAny(0);
    try std.testing.expectEqual(@as(usize, 1), f.runtime.pending_opens.items.len);
    try std.testing.expectEqual(@as(usize, 0), f.sink.takes);

    f.clock.advanceMs(handshake_ms + 1);
    _ = try f.runtime.stepAny(0);
    try std.testing.expectEqual(@as(usize, 0), f.runtime.pending_opens.items.len);
    try std.testing.expectEqual(@as(usize, 1), f.resident.cancel_connect_calls);
    // The same step delivered the broken fetch: the sweep drained it itself.
    try std.testing.expectEqual(@as(usize, 1), f.sink.takes);
}

test "a shortage of memory at the sweep's drain retains the consequences and does not fail the step" {
    var f: Fixture = undefined;
    try f.start(.{ .ms = handshake_ms });
    defer f.stop();
    f.resident.hold_connect = true;
    try f.enliven();
    _ = try f.runtime.stepAny(0);

    f.sink.refuse = true;
    f.clock.advanceMs(handshake_ms + 1);
    _ = try f.runtime.stepAny(0);
    try std.testing.expectEqual(@as(usize, 0), f.runtime.pending_opens.items.len);
    try std.testing.expect(f.runtime.terminal_failure == null);
    try std.testing.expect(f.runtime.core.memory_retry_due_ms != null);
    try std.testing.expectEqual(@as(usize, 0), f.sink.takes);

    f.sink.refuse = false;
    f.clock.advanceMs(retry_ms);
    _ = try f.runtime.stepAny(0);
    try std.testing.expectEqual(@as(usize, 1), f.sink.takes);
    try std.testing.expectEqual(@as(?i64, null), f.runtime.core.memory_retry_due_ms);
}

test "startDial reports an immediate refusal and leaves its cleanup queued for the next step" {
    var f: Fixture = undefined;
    try f.start(.{ .ms = 10_000 });
    defer f.stop();
    refuseDial(&f.resident);

    try f.startDial();
    try std.testing.expectEqual(@as(?anyerror, error.ProviderIo), f.observed.failure);
    try std.testing.expectEqual(@as(usize, 0), f.observed.reservations);
    try std.testing.expectEqual(@as(usize, 0), f.runtime.pending_opens.items.len);
    // The refusal drained nothing beneath its caller: the cleanup waits.
    try std.testing.expect(f.runtime.core.hasRunnableWork());

    _ = try f.runtime.stepAny(0);
    try std.testing.expect(!f.runtime.core.hasRunnableWork());
    try std.testing.expect(f.runtime.terminal_failure == null);
}

const retry_interval_ms = 30;
const retrying: @FieldType(driver.SessionOptions, "dial_retry") = .{
    .max_attempts = 3,
    .retry_interval_ms = retry_interval_ms,
};

/// A redeem open whose first connect fails with a fault worth retrying, so its
/// row waits for the retry interval.
fn enlivenIntoRetryWait(f: *Fixture) !void {
    f.resident.hold_connect = true;
    f.resident.connect_ready_at_start = true;
    try f.enliven();
    _ = try f.runtime.stepAny(0);
    try std.testing.expectEqual(@as(usize, 1), f.runtime.pending_opens.items.len);
    try std.testing.expect(f.runtime.pending_opens.items[0].stage == .retry_wait);
    try std.testing.expectEqual(@as(usize, 0), f.sink.takes);
}

test "an open whose retry interval outlives its handshake budget fails at the sweep and answers in that step" {
    var f: Fixture = undefined;
    try f.startRetrying(.{ .ms = 50 }, retrying);
    defer f.stop();
    try enlivenIntoRetryWait(&f);

    // Past the budget and past the interval together: the budget decides.
    f.clock.advanceMs(51);
    _ = try f.runtime.stepAny(0);
    try std.testing.expectEqual(@as(usize, 0), f.runtime.pending_opens.items.len);
    try std.testing.expectEqual(@as(usize, 1), f.resident.dial_starts);
    try std.testing.expectEqual(@as(usize, 1), f.sink.takes);
}

test "a retry the provider then refuses fails its open and answers in the step that re-issued it" {
    var f: Fixture = undefined;
    try f.startRetrying(.{ .ms = 10_000 }, retrying);
    defer f.stop();
    try enlivenIntoRetryWait(&f);

    f.resident.dial_failure = .init(error.ConnectionRefused);
    f.clock.advanceMs(retry_interval_ms + 1);
    _ = try f.runtime.stepAny(0);
    try std.testing.expectEqual(@as(usize, 2), f.resident.dial_starts);
    try std.testing.expectEqual(@as(usize, 0), f.runtime.pending_opens.items.len);
    try std.testing.expectEqual(@as(usize, 1), f.sink.takes);
    try std.testing.expect(f.runtime.terminal_failure == null);
}

test "an open whose connection closes before it opens fails at the sweep and answers in that step" {
    var f: Fixture = undefined;
    try f.start(.{ .ms = 10_000 });
    defer f.stop();
    f.resident.hold_connect = true;
    f.resident.connect_ready_at_start = true;
    f.resident.connect_succeeds = true;
    // The connection reads end of stream before any hello.
    f.resident.read_result = 0;
    try f.enliven();

    _ = try f.runtime.stepAny(0);
    try std.testing.expectEqual(@as(usize, 1), f.sink.takes);
    try std.testing.expectEqual(@as(usize, 0), f.runtime.pending_opens.items.len);
    try std.testing.expect(f.runtime.terminal_failure == null);
}

/// A dial's observer that, when its open fails, starts the next dial from
/// inside that notification, so the list holds a replacement row.
const Starter = struct {
    fixture: *Fixture,
    failures: usize = 0,
    next: ObservedOpen = .{},

    fn of(ctx: *anyopaque) *Starter {
        return @ptrCast(@alignCast(ctx));
    }

    fn failed(ctx: *anyopaque, _: u64, _: driver.OperationFailure) void {
        const self = of(ctx);
        self.failures += 1;
        const f = self.fixture;
        // The replacement dial is admitted and held, and the provider refuses
        // everything after it again.
        f.resident.dial_failure = null;
        f.runtime.startDial(Fixture.locator(), .inherit, 9, .{
            .ctx = &self.next,
            .reserve = ObservedOpen.reserve,
            .release = ObservedOpen.release,
            .opened = ObservedOpen.opened,
            .failed = ObservedOpen.failed,
        }) catch |err| std.debug.panic("replacement dial refused: {s}", .{@errorName(err)});
        f.resident.dial_failure = .init(error.ConnectionRefused);
    }

    fn noop(_: *anyopaque, _: u64) anyerror!void {}
    fn noopRelease(_: *anyopaque, _: u64) void {}
    fn opened(_: *anyopaque, _: u64, _: *driver_core.HostSession) !void {}
};

test "a failed retry whose observer starts a dial leaves the swapped-in row served in the same sweep" {
    var f: Fixture = undefined;
    try f.startRetrying(.{ .ms = 10_000 }, retrying);
    defer f.stop();
    var starter = Starter{ .fixture = &f };
    f.resident.hold_connect = true;
    f.resident.connect_ready_at_start = true;
    // Two rows wait for their retry: the application dial first, then the
    // redeem dial staged a step later (the resident holds one connect record).
    try f.runtime.startDial(Fixture.locator(), .inherit, 5, .{
        .ctx = &starter,
        .reserve = Starter.noop,
        .release = Starter.noopRelease,
        .opened = Starter.opened,
        .failed = Starter.failed,
    });
    _ = try f.runtime.stepAny(0);
    try f.enlivenOther();
    _ = try f.runtime.stepAny(0);
    try std.testing.expectEqual(@as(usize, 2), f.runtime.pending_opens.items.len);
    try std.testing.expect(f.runtime.pending_opens.items[0].stage == .retry_wait);
    try std.testing.expect(f.runtime.pending_opens.items[1].stage == .retry_wait);
    const starts = f.resident.dial_starts;

    f.resident.dial_failure = .init(error.ConnectionRefused);
    f.clock.advanceMs(retry_interval_ms + 1);
    try HostRuntime.testing.advancePendingOpens(&f.runtime);
    // Re-issue of the first row (refused), the replacement its observer
    // started, and the re-issue of the row swapped into the cursor: three
    // starts in one sweep. The list length never changed, and the removed
    // row's failure did not hide the swapped-in row.
    try std.testing.expectEqual(@as(usize, 1), starter.failures);
    try std.testing.expectEqual(starts + 3, f.resident.dial_starts);
    // The replacement stays held, and the swapped-in row's refusal broke its
    // fetch, which this step answered once.
    try std.testing.expectEqual(@as(usize, 1), f.runtime.pending_opens.items.len);
    try std.testing.expectEqual(@as(usize, 1), f.sink.takes);
    try std.testing.expect(f.runtime.terminal_failure == null);
}
