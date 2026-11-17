//! The callers of a retained drain, entered the way an application enters
//! them: a blocking settle that must drain a queued completion, a session
//! release a callback deferred to the outermost turn, a close that drains as
//! it progresses, and a blocking verb parking on a source wait. Each meets a
//! shortage of memory in the drain and neither fails the runtime nor loses
//! the queued work.

const std = @import("std");
const glowcap = @import("glowcap");

const driver = glowcap.driver;
const HostRuntime = driver.HostRuntime;
const support = @import("retry_support.zig");
const Sink = support.Sink;
const buildRig = support.buildRig;
const breakPendingFetch = support.breakPendingFetch;
const expectArmed = support.expectArmed;
const queueCompletion = support.queueCompletion;
const retry_ms = support.retry_ms;

test "a blocking settle over queued work answers OutOfMemory while memory is short, then the reply" {
    const rig = try buildRig();
    defer rig.destroy();
    const runtime = &rig.runtime;
    const view = try driver.Session.adopt(runtime, rig.session);
    defer view.deinit();
    var sink = Sink{ .runtime = runtime, .mode = .oom };
    sink.install();
    const id = try runtime.core.fetch(rig.session, "treasure");
    // The far vows break with the session still live: the settle queues one
    // completion, and the reply is the application's to read once drained.
    try runtime.core.breakFarVows(rig.session, "transport gone");
    try std.testing.expect(runtime.core.hasRunnableWork());
    const promise: driver.Promise = .{ .owner = view, .home = rig.session, .id = id };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // The settle needs the queued completion drained, and the drain is
    // retained. The caller is told so, and nothing fails the runtime.
    try std.testing.expectError(error.OutOfMemory, promise.settle(arena.allocator()));
    try std.testing.expectEqual(@as(usize, 1), sink.reserves);
    const due = try expectArmed(runtime);
    // Not yet due, the settle runs nothing.
    try std.testing.expectError(error.OutOfMemory, promise.settle(arena.allocator()));
    try std.testing.expectEqual(@as(usize, 1), sink.reserves);
    try std.testing.expectEqual(due, try expectArmed(runtime));

    sink.mode = .ok;
    rig.clock.advanceMs(retry_ms);
    const reply = try promise.settle(arena.allocator());
    try std.testing.expect(reply == .broken);
    try std.testing.expectEqual(@as(?i64, null), runtime.core.memory_retry_due_ms);
}

fn deferRelease(sink: *Sink) void {
    sink.on_take = null;
    sink.mode = .oom;
    const request: *HostRuntime.DeferredSessionRelease = @ptrCast(@alignCast(sink.probe_ctx.?));
    sink.runtime.deferSessionRelease(request) catch |err| std.debug.panic("defer refused: {s}", .{@errorName(err)});
}

fn releaseDone(_: *anyopaque) bool {
    return false;
}

test "a session release deferred to the outermost turn leaves a retained drain retained" {
    const rig = try buildRig();
    defer rig.destroy();
    const runtime = &rig.runtime;
    try runtime.claimSessionHandle(rig.session);
    var token: u8 = 0;
    var request: HostRuntime.DeferredSessionRelease = .{ .session = rig.session, .ctx = &token, .complete = releaseDone };
    var sink = Sink{ .runtime = runtime, .on_take = deferRelease, .probe_ctx = &request };
    sink.install();
    // Two completions: the first take defers the release and the memory
    // shortage begins, so the turn's own drain retains the second.
    _ = try runtime.core.fetch(rig.session, "treasure");
    try breakPendingFetch(rig);
    _ = try rig.step();
    try std.testing.expectEqual(@as(usize, 1), sink.takes);
    // The deferred release ran its close and its drain at the turn's end. The
    // shortage is retained there too: the runtime is not failed.
    try std.testing.expect(runtime.terminal_failure == null);
    _ = try expectArmed(runtime);
}

test "a close that drains while memory is short retains the drain and finishes once memory returns" {
    const rig = try buildRig();
    defer rig.destroy();
    const runtime = &rig.runtime;
    var sink = Sink{ .runtime = runtime, .mode = .oom };
    sink.install();
    try queueCompletion(rig);
    runtime.beginClose(.cancel);
    _ = try rig.stepQuiet();
    try std.testing.expect(runtime.terminal_failure == null);
    _ = try expectArmed(runtime);
    try std.testing.expectEqual(@as(usize, 0), sink.takes);

    sink.mode = .ok;
    rig.clock.advanceMs(retry_ms);
    _ = try rig.stepQuiet();
    try std.testing.expectEqual(@as(usize, 1), sink.takes);
    try std.testing.expectEqual(@as(?i64, null), runtime.core.memory_retry_due_ms);
}

const Pressure = @import("pressure_rig.zig");

fn queueOnOpen(ctx: ?*anyopaque, session: *glowcap.driver.core.HostSession) void {
    const runtime: *HostRuntime = @ptrCast(@alignCast(ctx.?));
    _ = runtime.core.fetch(session, "treasure") catch |err| std.debug.panic("fetch: {s}", .{@errorName(err)});
    runtime.core.breakFarVows(session, "transport gone") catch |err| std.debug.panic("break: {s}", .{@errorName(err)});
}

test "an open that completes at the sweep answers the work its observer queued in that step" {
    const rig = try Pressure.Rig.build(std.testing.allocator, .{
        .fetches = 0,
        .opens_on_read = true,
        .clock_step_ns = std.time.ns_per_us,
    });
    defer rig.destroy();
    const runtime = &rig.runtime;
    var sink = Sink{ .runtime = runtime };
    sink.install();
    rig.observed.on_opened = queueOnOpen;
    rig.observed.hook_ctx = runtime;

    rig.resident.offer(&rig.burst);
    _ = try rig.step();
    try std.testing.expect(rig.observed.did_open);
    try std.testing.expectEqual(@as(usize, 1), sink.takes);
    try std.testing.expect(!runtime.core.hasRunnableWork());
}

test "a blocking turn over queued work the close-tail policy gated parks inside the retry bound and attempts when due" {
    const rig = try Pressure.Rig.build(std.testing.allocator, .{
        .fetches = 0,
        .blocking = true,
        .clock_step_ns = 0,
    });
    defer rig.destroy();
    const runtime = &rig.runtime;
    // Valid queued core work, gated by the runtime's own close-tail policy
    // (no allocation failure is observed here).
    try queueCompletion(rig);
    HostRuntime.testing.closeTailFailed(runtime, error.OutOfMemory);
    const due = try expectArmed(runtime);
    try std.testing.expect(!runtime.core.hasRunnableWork());

    // Not due: the verb's wait is exactly the time to the deadline, on the
    // frozen fixture clock, and a step leaves the deadline and the work.
    try std.testing.expectEqual(@as(i64, retry_ms), runtime.stepWaitMs());
    for (0..3) |_| _ = try runtime.stepAny(0);
    try std.testing.expectEqual(due, try expectArmed(runtime));
    rig.clock.advanceMs(retry_ms - 1);
    try std.testing.expectEqual(@as(i64, 1), runtime.stepWaitMs());
    _ = try runtime.stepAny(0);
    try std.testing.expectEqual(due, try expectArmed(runtime));
    try std.testing.expect(runtime.terminal_failure == null);

    rig.clock.advanceMs(1);
    _ = try runtime.stepAny(0);
    try std.testing.expectEqual(@as(?i64, null), runtime.core.memory_retry_due_ms);
}

test "a refused parked replay under a not-yet-due host deadline offers its abort to that wire, then closes it" {
    const stream_framing = glowcap.foundation.stream_framing;
    const rig = try Pressure.Rig.build(std.testing.allocator, .{
        .fetches = 0,
        .attended = false,
        .clock_step_ns = 0,
    });
    defer rig.destroy();
    const runtime = &rig.runtime;
    // The partner's undecodable frame parks on the unattended wire.
    var prefix_buf: [stream_framing.prefix_buffer_bytes]u8 = undefined;
    const prefix = stream_framing.renderPrefix(&prefix_buf, 1);
    var bad: [stream_framing.prefix_buffer_bytes + 1]u8 = undefined;
    @memcpy(bad[0..prefix.len], prefix);
    bad[prefix.len] = 0xff;
    const packet = bad[0 .. prefix.len + 1];
    rig.resident.offer(&.{packet});
    _ = try rig.step();
    const wire = runtime.wires.get(rig.session.peer_handle).?;
    try std.testing.expect(wire.link.parked.items.len != 0);
    try std.testing.expectEqual(@as(usize, 0), rig.resident.written.items.len);

    // The host's retry gate is armed and not due (by the close-tail policy),
    // so the replay's drain is retained.
    HostRuntime.testing.closeTailFailed(runtime, error.OutOfMemory);
    const due = try expectArmed(runtime);
    try runtime.attendSession(rig.session);
    _ = try rig.step();
    try std.testing.expectEqual(due, try expectArmed(runtime));
    try std.testing.expect(wire.closed);
    try std.testing.expectEqual(@as(usize, 1), rig.resident.close_calls);

    // What the wire was offered is the core's abort for that frame: the same
    // bytes the partner's own session projects for the same frame.
    try std.testing.expect(rig.resident.written.items.len != 0);
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(std.testing.allocator);
    // tolerant: the partner refuses the frame, and the abort it queues is what the test compares.
    rig.partner.host.feedBytes(rig.partner.session, packet) catch {};
    try rig.partner.takeWire(&expected);
    try std.testing.expectEqualSlices(u8, expected.items, rig.resident.written.items);
}

test "a refused parked replay whose abort write fails closes the wire once with the write failure" {
    const stream_framing = glowcap.foundation.stream_framing;
    const rig = try Pressure.Rig.build(std.testing.allocator, .{
        .fetches = 0,
        .attended = false,
        .clock_step_ns = 0,
    });
    defer rig.destroy();
    const runtime = &rig.runtime;
    var prefix_buf: [stream_framing.prefix_buffer_bytes]u8 = undefined;
    const prefix = stream_framing.renderPrefix(&prefix_buf, 1);
    var bad: [stream_framing.prefix_buffer_bytes + 1]u8 = undefined;
    @memcpy(bad[0..prefix.len], prefix);
    bad[prefix.len] = 0xff;
    rig.resident.offer(&.{bad[0 .. prefix.len + 1]});
    _ = try rig.step();
    const wire = runtime.wires.get(rig.session.peer_handle).?;
    try std.testing.expect(wire.link.parked.items.len != 0);

    HostRuntime.testing.closeTailFailed(runtime, error.OutOfMemory);
    _ = try expectArmed(runtime);
    rig.resident.write_fails = true;
    try runtime.attendSession(rig.session);
    _ = try rig.step();
    try std.testing.expect(wire.closed);
    try std.testing.expect(rig.resident.write_attempts != 0);
    try std.testing.expectEqual(@as(usize, 1), rig.resident.close_calls);
    // The write failure is the wire's cause, as for any write that fails
    // while a wire closes, and the close ran once.
    try std.testing.expectEqual(error.ConnectionLost, wire.close_failure.?.chain.cause);
    try std.testing.expectEqual(@as(?anyerror, error.ConnectionLost), rig.observed.close_failure);
}
