//! Core work a memory refusal left queued is retained, not failed. One
//! deadline on the core gates every drain: not yet due answers retained
//! without running anything, due renews it and runs one attempt, and a drain
//! that completes clears it. Runtime turns and consumed handles treat retained
//! work as queued, a terminal failure retires the deadline, and the core
//! reports no runnable work while it waits.
//!
//! The refusal is a completion sink that cannot reserve a slot, a refusal the
//! stepped face meets before it consumes any action. A wire closing under a
//! pending fetch produces the completion. Time is a `SteppedClock` the test
//! advances, so no test sleeps or sweeps allocation indices.

const std = @import("std");
const glowcap = @import("glowcap");

const driver = glowcap.driver;
const driver_core = driver.core;
const HostRuntime = driver.HostRuntime;
const pressure_rig = @import("pressure_rig.zig");
const test_host = @import("../../support/core_host.zig");
const Rig = pressure_rig.Rig;

const support = @import("retry_support.zig");
const Sink = support.Sink;
const FlushOom = support.FlushOom;
const FlushIdle = support.FlushIdle;
const FlushFail = support.FlushFail;
const buildRig = support.buildRig;
const breakPendingFetch = support.breakPendingFetch;
const expectArmed = support.expectArmed;
const queueCompletion = support.queueCompletion;
const retry_ms = support.retry_ms;

test "a refused completion slot retains the drain: no retry before due, one attempt when due, then recovery" {
    const rig = try buildRig();
    defer rig.destroy();
    const runtime = &rig.runtime;
    var sink = Sink{ .runtime = runtime, .mode = .oom };
    sink.install();
    try breakPendingFetch(rig);

    // The turn that meets the refusal returns normally and leaves the work.
    _ = try rig.step();
    try std.testing.expectEqual(@as(usize, 1), sink.reserves);
    const first_due = try expectArmed(runtime);
    try std.testing.expect(runtime.core.actions.peek() != null);
    // The core reports nothing runnable while the work waits, so a progress
    // loop parks instead of spinning on it.
    try std.testing.expect(!runtime.core.hasRunnableWork());
    const wait = runtime.stepWaitMs();
    try std.testing.expect(wait >= 0 and wait <= retry_ms);

    // Before the deadline no step touches the sink, so none allocates.
    for (0..4) |_| _ = try rig.step();
    try std.testing.expectEqual(@as(usize, 1), sink.reserves);
    try std.testing.expectEqual(first_due, try expectArmed(runtime));

    // Due: exactly one attempt, refused again, and the deadline renews. A
    // persistent shortage is not terminal.
    rig.clock.advanceMs(retry_ms);
    _ = try rig.step();
    try std.testing.expectEqual(@as(usize, 2), sink.reserves);
    try std.testing.expect(try expectArmed(runtime) > first_due);
    try std.testing.expectEqual(@as(usize, 0), sink.takes);

    // Memory returns: the next due attempt delivers the completion once and
    // the core is idle again.
    sink.mode = .ok;
    rig.clock.advanceMs(retry_ms);
    _ = try rig.step();
    try std.testing.expectEqual(@as(usize, 1), sink.takes);
    try std.testing.expectEqual(@as(?i64, null), runtime.core.memory_retry_due_ms);
    for (0..3) |_| {
        rig.clock.advanceMs(retry_ms);
        _ = try rig.step();
    }
    try std.testing.expectEqual(@as(usize, 1), sink.takes);
    try std.testing.expect(!runtime.core.hasRunnableWork());
}

test "the public drain answers retained work with OutOfMemory and runs nothing before due" {
    const rig = try buildRig();
    defer rig.destroy();
    const runtime = &rig.runtime;
    var sink = Sink{ .runtime = runtime, .mode = .oom };
    sink.install();
    try breakPendingFetch(rig);
    _ = try rig.step();
    try std.testing.expectEqual(@as(usize, 1), sink.reserves);

    try std.testing.expectError(error.OutOfMemory, runtime.drainActions());
    try std.testing.expectEqual(@as(usize, 1), sink.reserves);
    try std.testing.expect(runtime.terminal_failure == null);

    sink.mode = .ok;
    rig.clock.advanceMs(retry_ms);
    try runtime.drainActions();
    try std.testing.expectEqual(@as(usize, 1), sink.takes);
    try std.testing.expectEqual(@as(?i64, null), runtime.core.memory_retry_due_ms);
}

test "a flush that refuses memory still drains the actions, and its debt survives a later error or a clean drain" {
    const rig = try buildRig();
    defer rig.destroy();
    const runtime = &rig.runtime;
    const attemptWith = HostRuntime.testing.attemptWith;
    var sink = Sink{ .runtime = runtime };
    sink.install();
    try queueCompletion(rig);

    // An error other than memory with no new refusal leaves no deadline.
    sink.mode = .refused;
    FlushIdle.calls = 0;
    try std.testing.expectError(error.SinkRefused, attemptWith(runtime, .operational, .turn, FlushIdle));
    try std.testing.expectEqual(@as(usize, 1), FlushIdle.calls);
    try std.testing.expectEqual(@as(?i64, null), runtime.core.memory_retry_due_ms);

    // The same error after a refused flush arms the remembered debt first.
    FlushOom.calls = 0;
    try std.testing.expectError(error.SinkRefused, attemptWith(runtime, .operational, .turn, FlushOom));
    try std.testing.expectEqual(@as(usize, 1), FlushOom.calls);
    _ = try expectArmed(runtime);
    try std.testing.expectEqual(@as(usize, 0), sink.takes);

    // Due, a clean drain after a refused flush delivers the completion and
    // still answers retained, so the held releases are tried again.
    sink.mode = .ok;
    rig.clock.advanceMs(retry_ms);
    try std.testing.expectEqual(
        HostRuntime.testing.Drain.retained,
        try attemptWith(runtime, .operational, .turn, FlushOom),
    );
    try std.testing.expectEqual(@as(usize, 1), sink.takes);
    _ = try expectArmed(runtime);

    // A clean flush and drain complete and clear.
    rig.clock.advanceMs(retry_ms);
    try std.testing.expectEqual(
        HostRuntime.testing.Drain.complete,
        try attemptWith(runtime, .operational, .turn, FlushIdle),
    );
    try std.testing.expectEqual(@as(?i64, null), runtime.core.memory_retry_due_ms);
}

test "an ungated drain returns a flush refusal at once, and a gated one keeps its cause when the flush fails otherwise" {
    const attemptWith = HostRuntime.testing.attemptWith;
    // Cleanup-only with no terminal failure, and an operational drain after
    // one: neither remembers a memory refusal for later. Each returns it
    // before any action runs and leaves the core's deadline alone.
    for (0..2) |which| {
        const rig = try buildRig();
        defer rig.destroy();
        const runtime = &rig.runtime;
        var sink = Sink{ .runtime = runtime };
        sink.install();
        try queueCompletion(rig);
        const mode: HostRuntime.testing.Mode = if (which == 0) .cleanup_only else .operational;
        if (which == 1) runtime.noteTerminalFailure(error.ProviderInternal);
        FlushOom.calls = 0;
        try std.testing.expectError(error.OutOfMemory, attemptWith(runtime, mode, .turn, FlushOom));
        try std.testing.expectEqual(@as(usize, 1), FlushOom.calls);
        try std.testing.expectEqual(@as(usize, 0), sink.reserves);
        try std.testing.expectEqual(@as(?i64, null), runtime.core.memory_retry_due_ms);
        try std.testing.expect((runtime.terminal_failure != null) == (which == 1));
    }

    // A flush error that is not memory stops a gated drain with its own cause
    // and arms nothing.
    const rig = try buildRig();
    defer rig.destroy();
    const runtime = &rig.runtime;
    var sink = Sink{ .runtime = runtime };
    sink.install();
    try queueCompletion(rig);
    FlushFail.calls = 0;
    try std.testing.expectError(error.ProviderInternal, attemptWith(runtime, .operational, .turn, FlushFail));
    try std.testing.expectEqual(@as(usize, 1), FlushFail.calls);
    try std.testing.expectEqual(@as(usize, 0), sink.reserves);
    try std.testing.expectEqual(@as(?i64, null), runtime.core.memory_retry_due_ms);
}

test "the stepped face flushes every attempt and the blocking face flushes when due or at its park" {
    const attemptWith = HostRuntime.testing.attemptWith;
    const closeTailFailed = HostRuntime.testing.closeTailFailed;

    const stepped = try buildRig();
    defer stepped.destroy();
    FlushIdle.calls = 0;
    _ = try attemptWith(&stepped.runtime, .operational, .turn, FlushIdle);
    try std.testing.expectEqual(@as(usize, 1), FlushIdle.calls);

    const blocking = try Rig.build(std.testing.allocator, .{ .fetches = 0, .blocking = true, .clock_step_ns = std.time.ns_per_us });
    defer blocking.destroy();
    const runtime = &blocking.runtime;
    FlushIdle.calls = 0;
    _ = try attemptWith(runtime, .operational, .turn, FlushIdle);
    try std.testing.expectEqual(@as(usize, 0), FlushIdle.calls);
    // At its park the flush runs, and a park that sent nothing drains nothing.
    try std.testing.expectEqual(HostRuntime.testing.Drain.complete, try attemptWith(runtime, .operational, .park, FlushIdle));
    try std.testing.expectEqual(@as(usize, 1), FlushIdle.calls);

    // Armed and not due, neither intent flushes: the attempt is retained
    // without running anything.
    closeTailFailed(runtime, error.OutOfMemory);
    const due = try expectArmed(runtime);
    for ([_]HostRuntime.testing.FlushIntent{ .turn, .park }) |intent| {
        FlushIdle.calls = 0;
        try std.testing.expectEqual(HostRuntime.testing.Drain.retained, try attemptWith(runtime, .operational, intent, FlushIdle));
        try std.testing.expectEqual(@as(usize, 0), FlushIdle.calls);
        try std.testing.expectEqual(due, try expectArmed(runtime));
    }
    // Due, the blocking face flushes, then drains and clears.
    blocking.clock.advanceMs(retry_ms);
    FlushIdle.calls = 0;
    try std.testing.expectEqual(HostRuntime.testing.Drain.complete, try attemptWith(runtime, .operational, .turn, FlushIdle));
    try std.testing.expectEqual(@as(usize, 1), FlushIdle.calls);
    try std.testing.expectEqual(@as(?i64, null), runtime.core.memory_retry_due_ms);
}

fn armDuringDrain(sink: *Sink) void {
    HostRuntime.testing.closeTailFailed(sink.runtime, error.OutOfMemory);
}

test "a close tail's debt raised during a drain that completes is discharged by it" {
    const rig = try buildRig();
    defer rig.destroy();
    const runtime = &rig.runtime;
    var sink = Sink{ .runtime = runtime, .on_reserve = armDuringDrain };
    sink.install();
    try queueCompletion(rig);
    try std.testing.expectEqual(
        HostRuntime.testing.Drain.complete,
        try HostRuntime.testing.attempt(runtime, .operational, .turn),
    );
    try std.testing.expectEqual(@as(usize, 1), sink.takes);
    // The drain's last peek reran the pump the debt names.
    try std.testing.expectEqual(@as(?i64, null), runtime.core.memory_retry_due_ms);
}

fn failTerminally(sink: *Sink) void {
    sink.runtime.noteTerminalFailure(error.ProviderInternal);
}

test "every terminal setter retires the deadline, and none re-arms it" {
    const closeTailFailed = HostRuntime.testing.closeTailFailed;
    for (0..3) |which| {
        const rig = try buildRig();
        defer rig.destroy();
        const runtime = &rig.runtime;
        closeTailFailed(runtime, error.OutOfMemory);
        _ = try expectArmed(runtime);
        switch (which) {
            0 => runtime.noteTerminalFailure(error.ProviderInternal),
            1 => HostRuntime.testing.noteTerminalFailureChain(runtime, .init(error.ProviderInternal)),
            else => runtime.noteTerminalOperationFailure(.fromError(error.ProviderInternal)),
        }
        try std.testing.expect(runtime.terminal_failure != null);
        try std.testing.expectEqual(@as(?i64, null), runtime.core.memory_retry_due_ms);
        closeTailFailed(runtime, error.OutOfMemory);
        try std.testing.expectEqual(@as(?i64, null), runtime.core.memory_retry_due_ms);
    }
}

test "a terminal failure during an attempt wins, and later drains are ungated and write no debt" {
    const rig = try buildRig();
    defer rig.destroy();
    const runtime = &rig.runtime;
    var sink = Sink{ .runtime = runtime, .mode = .oom, .on_reserve = failTerminally };
    sink.install();
    try queueCompletion(rig);
    try std.testing.expectEqual(HostRuntime.testing.Drain.retained, try HostRuntime.testing.attempt(runtime, .operational, .turn));
    try std.testing.expect(runtime.terminal_failure != null);
    try std.testing.expectEqual(@as(?i64, null), runtime.core.memory_retry_due_ms);

    // After fail-stop, both modes keep their errors and arm nothing.
    sink.on_reserve = null;
    for ([_]driver.HostRuntime.testing.Mode{ .operational, .cleanup_only }) |mode| {
        const reserves = sink.reserves;
        try std.testing.expectError(error.OutOfMemory, HostRuntime.testing.attempt(runtime, mode, .turn));
        try std.testing.expectEqual(reserves + 1, sink.reserves);
        try std.testing.expectEqual(@as(?i64, null), runtime.core.memory_retry_due_ms);
    }
}

test "a consumed session handle never fails for a drain that only lacked memory" {
    const rig = try buildRig();
    defer rig.destroy();
    const runtime = &rig.runtime;
    var sink = Sink{ .runtime = runtime, .mode = .oom };
    sink.install();
    _ = try runtime.core.fetch(rig.session, "treasure");
    try runtime.releaseWire(rig.session);
    try std.testing.expect(sink.reserves >= 1);
    // The release consumed the handle, so it cannot be retried: the work waits
    // behind the deadline, and the runtime is not failed. Releasing a session
    // leaves the deadline for the work that remains.
    _ = try expectArmed(runtime);

    sink.mode = .ok;
    rig.clock.advanceMs(retry_ms);
    _ = try rig.step();
    try std.testing.expectEqual(@as(usize, 1), sink.takes);
    try std.testing.expectEqual(@as(?i64, null), runtime.core.memory_retry_due_ms);
}

test "the settle mailbox retains its queued drain, and its own failures stay terminal and keep their cause" {
    const BreakCause = glowcap.foundation.break_cause.BreakCause;
    const rig = try buildRig();
    defer rig.destroy();
    const runtime = &rig.runtime;
    const mailbox = try runtime.settleMailbox();
    var sink = Sink{ .runtime = runtime, .mode = .oom };
    sink.install();
    try queueCompletion(rig);

    // Memory the trailing drain lacks is retained: the mailbox's turn is fine.
    try HostRuntime.testing.applySettleMailbox(runtime);
    try std.testing.expectEqual(@as(usize, 1), sink.reserves);
    _ = try expectArmed(runtime);

    // A settle the core refuses fails the apply. The drain still runs after
    // it (a second reservation, due again), its own memory shortage stays
    // retained, and the mailbox's cause is the one latched and returned.
    try mailbox.post(runtime.io, 0xdead, .{ .broken = .{ .detail = "no such resolver", .cause = BreakCause{} } });
    rig.clock.advanceMs(retry_ms);
    const failure = HostRuntime.testing.applySettleMailbox(runtime);
    try std.testing.expectEqual(@as(usize, 2), sink.reserves);
    const cause = runtime.terminal_failure.?.chain.cause;
    try std.testing.expect(cause != error.OutOfMemory);
    try std.testing.expectError(cause, failure);
    try std.testing.expectEqual(@as(?i64, null), runtime.core.memory_retry_due_ms);
}

test "a drain failure that is not memory is the mailbox's terminal failure" {
    const rig = try buildRig();
    defer rig.destroy();
    const runtime = &rig.runtime;
    _ = try runtime.settleMailbox();
    var sink = Sink{ .runtime = runtime, .mode = .refused };
    sink.install();
    try queueCompletion(rig);
    try std.testing.expectError(error.SinkRefused, HostRuntime.testing.applySettleMailbox(runtime));
    try std.testing.expectEqual(error.SinkRefused, runtime.terminal_failure.?.chain.cause);
}

test "a sink callback cannot re-enter the runtime" {
    for ([_]Sink.Callback{ .reserve, .take, .release }) |callback| {
        const rig = try buildRig();
        defer rig.destroy();
        const runtime = &rig.runtime;
        var sink = Sink{ .runtime = runtime, .probe_in = callback };
        sink.install();
        try queueCompletion(rig);
        _ = try runtime.drainActions();
        try std.testing.expectEqual(@as(?anyerror, error.ReenteredHost), sink.reentry);
        try std.testing.expect(runtime.terminal_failure == null);
        // The guard is released: a later step runs.
        _ = try rig.step();
    }
}

test "a sink callback cannot re-enter the public drain and consume the outer action" {
    for ([_]Sink.Callback{ .reserve, .take, .release }) |callback| {
        const rig = try buildRig();
        defer rig.destroy();
        const runtime = &rig.runtime;
        var sink = Sink{ .runtime = runtime, .probe_in = callback, .probe_drain = true };
        sink.install();
        try queueCompletion(rig);
        try runtime.drainActions();
        try std.testing.expectEqual(@as(?anyerror, error.ReenteredHost), sink.reentry);
        // The outer drain delivered its one completion once.
        try std.testing.expectEqual(@as(usize, 1), sink.takes);
        try std.testing.expect(runtime.terminal_failure == null);
        // The guard is released: a later drain and a later step both run.
        try std.testing.expectEqual(@as(usize, 0), runtime.observer_callback_depth);
        try runtime.drainActions();
        _ = try rig.step();
        try std.testing.expectEqual(@as(usize, 1), sink.takes);
    }
}

test "a retained attempt leaves the runtime quiescent and the deadline on the core" {
    const rig = try buildRig();
    defer rig.destroy();
    const runtime = &rig.runtime;
    var sink = Sink{ .runtime = runtime, .mode = .oom };
    sink.install();
    try queueCompletion(rig);
    try std.testing.expectEqual(HostRuntime.testing.Drain.retained, try HostRuntime.testing.attempt(runtime, .operational, .turn));
    try std.testing.expectEqual(@as(usize, 0), runtime.driver_depth);
    try std.testing.expectEqual(@as(usize, 0), runtime.observer_callback_depth);
    try runtime.detachThread();
    _ = try expectArmed(runtime);
}

test "a runtime over a borrowed core retires its deadline at teardown" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var core = test_host.init(allocator, @as([32]u8, @splat(0x52)), .{ .thread_policy = .unchecked });
    defer core.deinit();
    var adopted = try driver.HostRuntime.initWithCore(allocator, threaded.io(), &core, .{}, .{
        .handshake = .{ .ms = 10_000 },
        .settle = .{ .ms = 10_000 },
    });
    HostRuntime.testing.closeTailFailed(&adopted, error.OutOfMemory);
    try std.testing.expect(core.memory_retry_due_ms != null);
    try std.testing.expect(!core.hasRunnableWork());
    adopted.deinit();
    try std.testing.expectEqual(@as(?i64, null), core.memory_retry_due_ms);
}
