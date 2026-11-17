//! A feed that cannot be retained closes the wire it fed. Each sweep refuses
//! runtime allocations at every index its workload reaches, in turn: one
//! refusal, the way a process under a brief shortage does, or every
//! allocation from that index on until memory comes back. After the refusal
//! each wire is open and in sync or closed with a memory cause, no step
//! latches a terminal failure, every byte the runtime took returned, and the
//! single-wire workloads end with the sibling session answering a call.
//!
//! A step fails only where the workload says so, and only with
//! `OutOfMemory`. The feed's own allocations, the park and the retained
//! tail, never fail a step. A wait that owns the wire hears the exact cause.
//!
//! No allocation index in these workloads makes the core's close tail fail.
//! The tail's classification and the retry deadline's rules are therefore
//! checked by calling their seams, and the drain's failure for a reason
//! other than memory is raised through a completion sink that refuses to
//! reserve.

const std = @import("std");
const glowcap = @import("glowcap");

const driver = glowcap.driver;
const HostRuntime = driver.HostRuntime;
const FailingOnce = @import("../../support/failing_once.zig").FailingOnce;
const pressure_rig = @import("pressure_rig.zig");
const Rig = pressure_rig.Rig;
const Sibling = @import("sibling.zig").Sibling;
const stream_framing = glowcap.foundation.stream_framing;

const disabled = std.math.maxInt(usize);

/// What a sweep saw across every index it refused.
const Tally = struct {
    indexes: usize = 0,
    /// Wires that closed with `OutOfMemory` as their cause.
    closed_for_memory: usize = 0,
    /// Wires the core condemned for a frame it could not retain.
    closed_condemned: usize = 0,
    /// Wires that closed with no cause, after the core's own abort.
    closed_clean: usize = 0,
    /// Runs where the rig's wire stayed open and answered in order.
    stayed_open: usize = 0,
    /// Steps that failed under the refusal, where the scenario allows one.
    step_errors: usize = 0,
    /// Steps that returned with core work retained behind the retry deadline.
    retained_steps: usize = 0,
    /// Failed steps after which a wire held input the sweep had not counted.
    stale_hold: usize = 0,

    /// Count a closed wire by its cause: its own `OutOfMemory`, the core's
    /// `SessionCondemned` for a frame it could not retain, or none when the
    /// core condemned the session, sent its abort, and the close action ran
    /// clean. No workload ends a stream or breaks a transport, so any other
    /// cause is a defect.
    fn noteClose(self: *Tally, cause: ?anyerror) !void {
        const got = cause orelse {
            self.closed_clean += 1;
            return;
        };
        if (got == error.OutOfMemory) {
            self.closed_for_memory += 1;
        } else if (got == error.SessionCondemned) {
            self.closed_condemned += 1;
        } else return error.ClosedForAnotherCause;
    }
};

const Shortage = enum { brief, lasting };

const Workload = enum {
    /// The first half of one request, attended: the core can retain only
    /// the tail, which is the one allocation the feed owns.
    half_request,
    /// One whole request on a wire the embedder has not attended: the
    /// resident parks it.
    parked_request,
    /// Both requests, attended: feed, serve, answer and drain all allocate.
    requests,
    /// One request parked on each of two wires whose outbound sits at the
    /// waterline, so the sweep replays both once their windows open.
    held_pair,
    /// A request on each of two attended wires at once, so one wire's
    /// refusal can leave work queued for the other's close to meet.
    request_pair,

    fn attended(workload: Workload) bool {
        return workload != .parked_request and workload != .held_pair;
    }

    fn fetches(workload: Workload) usize {
        return if (workload == .requests) 2 else 1;
    }

    /// Whether a step may fail while memory is short.
    fn stepMayFail(workload: Workload, shortage: Shortage) bool {
        return workload == .requests or workload == .held_pair or workload == .request_pair or shortage == .lasting;
    }
};

const Trial = struct {
    rig: *Rig,
    sibling: *Sibling,
    tally: *Tally,
    workload: Workload,
    shortage: Shortage,
    /// Memory has come back, so no step may fail.
    recovered: bool = false,

    fn step(self: *Trial) !void {
        // Each step is the retry the wait allows: the deadline, if armed, is due.
        if (self.rig.runtime.core.memory_retry_due_ms != null) self.rig.clock.advanceMs(HostRuntime.testing.memory_retry_ms);
        _ = try self.sibling.resident.wake.nudge();
        _ = try self.rig.resident.wake.nudge();
        const failed = if (self.rig.runtime.stepAny(0)) |_| false else |err| blk: {
            if (self.recovered or !self.workload.stepMayFail(self.shortage)) return err;
            try std.testing.expectEqual(error.OutOfMemory, err);
            self.tally.step_errors += 1;
            break :blk true;
        };
        // No step latches: a failure with a caller returns, and one that
        // belongs to a connection closes it.
        try std.testing.expect(self.rig.runtime.terminal_failure == null);
        const retained = self.rig.runtime.core.memory_retry_due_ms != null;
        if (retained and !failed) self.tally.retained_steps += 1;
        if (failed or retained) {
            // A failed or retained drain leaves the retry the wait wakes for.
            try std.testing.expect(self.rig.runtime.core.memory_retry_due_ms != null);
            try self.expectHoldsCounted();
        }
        if (self.rig.runtime.core.memory_retry_due_ms != null) {
            // The step's wait wakes for the retry and never past it.
            const wait = self.rig.runtime.stepWaitMs();
            try std.testing.expect(wait >= 0 and wait <= HostRuntime.testing.memory_retry_ms);
        }
    }

    /// After a failed step a live wire that holds input is counted in
    /// `held_input_possible`. The sweep asked every wire, or it stopped on
    /// one that held input, which leaves the flag set.
    fn expectHoldsCounted(self: *Trial) !void {
        var wires = self.rig.runtime.wires.valueIterator();
        while (wires.next()) |entry| {
            const link = &entry.*.link;
            const held = !entry.*.closed and
                (link.read_deferred or link.parked.items.len != 0 or entry.*.session.inboundResumable());
            if (held and !self.rig.runtime.held_input_possible) {
                self.tally.stale_hold += 1;
                return error.HeldInputNotCounted;
            }
        }
    }

    fn steps(self: *Trial, count: usize) !void {
        for (0..count) |_| try self.step();
    }

    /// The rig's wire, or null once the runtime no longer holds one.
    fn wire(self: *Trial) ?*driver.HostRuntime.Wire {
        return self.rig.runtime.wires.get(self.rig.session.peer_handle);
    }
};

/// Run `workload` with the `k`th runtime allocation from now refused, and
/// return whether that allocation was reached.
fn trial(workload: Workload, shortage: Shortage, k: usize, tally: *Tally) !bool {
    const allocator = std.testing.allocator;
    var failing = FailingOnce.init(allocator, disabled);
    failing.lasting = shortage == .lasting;
    const rig = try Rig.build(allocator, .{
        .fetches = workload.fetches(),
        .attended = workload.attended(),
        .runtime_allocator = failing.allocator(),
        .clock_step_ns = std.time.ns_per_us,
    });
    const sibling = try Sibling.attach(rig, workload != .held_pair);
    errdefer {
        rig.destroy();
        sibling.destroy();
    }
    var run = Trial{ .rig = rig, .sibling = sibling, .tally = tally, .workload = workload, .shortage = shortage };
    try prepare(&run);

    failing.fail_index = failing.alloc_index + k;
    try drive(&run);
    const reached = failing.induced;
    failing.fail_index = disabled;
    run.recovered = true;
    if (reached) try settle(&run);

    rig.destroy();
    sibling.destroy();
    try std.testing.expect(failing.balanced());
    return reached;
}

/// What the workload needs in place before the refusal is armed.
fn prepare(run: *Trial) !void {
    if (run.workload == .request_pair) return run.sibling.ask();
    if (run.workload != .held_pair) return;
    const rig = run.rig;
    const sibling = run.sibling;
    try rig.parkAndPressure(1);
    try sibling.ask();
    _ = try sibling.step();
    try std.testing.expect(sibling.holdsParked());
    try sibling.pressure();
    // Attending replays nothing while the outbound sits at the waterline.
    try rig.runtime.attendSession(rig.session);
    try rig.runtime.attendSession(sibling.session);
    try std.testing.expect(rig.runtime.wires.get(rig.session.peer_handle).?.link.parked.items.len != 0);
    try std.testing.expect(sibling.holdsParked());
}

/// The traffic the refusal lands in.
fn drive(run: *Trial) !void {
    const rig = run.rig;
    switch (run.workload) {
        .half_request => {
            const request = rig.packets.items[0];
            var chunk = [1][]const u8{request[0 .. request.len / 2]};
            rig.resident.offer(&chunk);
            try run.steps(3);
            rig.resident.inbound = &.{};
        },
        .parked_request => {
            var chunk = [1][]const u8{rig.packets.items[0]};
            rig.resident.offer(&chunk);
            try run.steps(3);
            rig.resident.inbound = &.{};
        },
        .requests => {
            var chunk = [1][]const u8{rig.frames.items};
            rig.resident.offer(&chunk);
            try run.steps(6);
            rig.resident.inbound = &.{};
        },
        .request_pair => {
            var chunk = [1][]const u8{rig.packets.items[0]};
            rig.resident.offer(&chunk);
            try run.steps(8);
            rig.resident.inbound = &.{};
        },
        .held_pair => {
            rig.resident.write_open = true;
            run.sibling.resident.write_open = true;
            rig.resident.want_write = true;
            run.sibling.resident.want_write = true;
            try run.steps(6);
        },
    }
}

/// After the refusal and the return of memory: the rig's wire is in sync or
/// closed with its cause, and the sibling serves a call.
fn settle(run: *Trial) !void {
    const rig = run.rig;
    const tally = run.tally;
    tally.indexes += 1;
    // The retry the deadline asks for, taken at the rate the wait allows.
    try run.steps(8);
    // Memory is back and every drain since ran its work, so none waits.
    try std.testing.expect(rig.runtime.core.memory_retry_due_ms == null);
    if (run.workload == .held_pair or run.workload == .request_pair) return settleBoth(run);
    const closed = if (run.wire()) |wire| wire.closed else true;
    if (closed) {
        try std.testing.expectEqual(@as(usize, 1), rig.observed.close_events);
        switch (run.workload) {
            .half_request, .parked_request => {
                try std.testing.expectEqual(@as(?anyerror, error.OutOfMemory), rig.observed.close_failure);
                tally.closed_for_memory += 1;
            },
            .requests => try tally.noteClose(rig.observed.close_failure),
            .held_pair, .request_pair => unreachable,
        }
    } else {
        switch (run.workload) {
            .half_request => {
                const request = rig.packets.items[0];
                var rest = [1][]const u8{request[request.len / 2 ..]};
                rig.resident.offer(&rest);
                try run.steps(4);
            },
            .parked_request => {
                try rig.runtime.attendSession(rig.session);
                try run.steps(4);
            },
            .requests => {},
            .held_pair, .request_pair => unreachable,
        }
        try rig.expectAnswersInOrder();
        tally.stayed_open += 1;
    }
    try run.sibling.ask();
    try std.testing.expect(try run.sibling.answered());
}

/// Both wires replayed under the shortage. Each is closed with its cause or
/// still open, and none is left with a replay that never runs.
fn settleBoth(run: *Trial) !void {
    const rig = run.rig;
    const tally = run.tally;
    var closed: usize = 0;
    for ([_]*driver.core.HostSession{ rig.session, run.sibling.session }) |session| {
        const wire = rig.runtime.wires.get(session.peer_handle).?;
        if (!wire.closed) {
            tally.stayed_open += 1;
            continue;
        }
        closed += 1;
        // A refusal closes a wire for the memory it lacked and for no other cause.
        try tally.noteClose(if (wire.close_failure) |failure| failure.chain.cause else null);
    }
    // The runtime's one close observer saw each closed wire once.
    try std.testing.expectEqual(closed, rig.observed.close_events);
}

/// Sweep every allocation index `workload` reaches.
fn sweep(workload: Workload, shortage: Shortage) !Tally {
    var tally = Tally{};
    var k: usize = 0;
    while (try trial(workload, shortage, k, &tally)) : (k += 1) {
        if (k == 10_000) return error.SweepNeverEnded;
    }
    return tally;
}

test "a feed the core cannot retain closes that wire with the memory cause and no step fails" {
    const tally = try sweep(.half_request, .brief);
    try std.testing.expect(tally.closed_for_memory != 0);
    try std.testing.expectEqual(@as(usize, 0), tally.step_errors);
}

test "a chunk an unattended wire cannot park closes that wire and no step fails" {
    const tally = try sweep(.parked_request, .brief);
    try std.testing.expect(tally.closed_for_memory != 0);
    try std.testing.expectEqual(@as(usize, 0), tally.step_errors);
}

test "a refusal under serve, answer and drain leaves every wire in sync or closed" {
    const tally = try sweep(.requests, .brief);
    try std.testing.expect(tally.closed_for_memory != 0);
    try std.testing.expect(tally.stayed_open != 0);
}

test "a lasting shortage across serve, answer, drain and close latches nothing" {
    const tally = try sweep(.requests, .lasting);
    try std.testing.expect(tally.closed_for_memory != 0);
    try std.testing.expect(tally.step_errors + tally.retained_steps != 0);
}

test "a lasting shortage under two wires' requests closes wires only for memory and counts held input" {
    const tally = try sweep(.request_pair, .lasting);
    try std.testing.expect(tally.closed_for_memory != 0);
    try std.testing.expectEqual(@as(usize, 0), tally.stale_hold);
}

test "two held wires under a lasting shortage close for memory or stay held and counted" {
    const tally = try sweep(.held_pair, .lasting);
    try std.testing.expect(tally.closed_for_memory != 0);
    try std.testing.expect(tally.step_errors + tally.retained_steps != 0);
    try std.testing.expectEqual(@as(usize, 0), tally.stale_hold);
}

test "a close tail that runs out of memory arms the retry, and backpressure arms nothing" {
    const rig = try Rig.build(std.testing.allocator, .{ .fetches = 0, .clock_step_ns = std.time.ns_per_us });
    defer rig.destroy();
    const runtime = &rig.runtime;
    const closeTailFailed = HostRuntime.testing.closeTailFailed;

    closeTailFailed(runtime, error.OutboundBackpressure);
    try std.testing.expect(runtime.core.memory_retry_due_ms == null);
    try std.testing.expectEqual(@as(i32, -1), runtime.stepWaitMs());
    try std.testing.expect(runtime.terminal_failure == null);

    closeTailFailed(runtime, error.OutOfMemory);
    try std.testing.expect(runtime.core.memory_retry_due_ms != null);
    const wait = runtime.stepWaitMs();
    try std.testing.expect(wait >= 0 and wait <= HostRuntime.testing.memory_retry_ms);
    try std.testing.expect(runtime.terminal_failure == null);

    // Before the deadline the drain is retained, so it answers memory without
    // running anything, and the deadline stays.
    try std.testing.expectError(error.OutOfMemory, runtime.drainActions());
    try std.testing.expect(runtime.core.memory_retry_due_ms != null);
    // The retry is a drain that returns once due, which clears the deadline.
    rig.clock.advanceMs(HostRuntime.testing.memory_retry_ms);
    try runtime.drainActions();
    try std.testing.expect(runtime.core.memory_retry_due_ms == null);

    closeTailFailed(runtime, error.ProviderInternal);
    try std.testing.expect(runtime.terminal_failure != null);
}

test "a deadline that has passed binds the wait until a terminal failure retires it" {
    const rig = try Rig.build(std.testing.allocator, .{ .fetches = 0 });
    defer rig.destroy();
    const runtime = &rig.runtime;
    runtime.core.memory_retry_due_ms = runtime.nowMs() - 1;
    try std.testing.expectEqual(@as(i32, 0), runtime.stepWaitMs());
    // After fail-stop a step may run no drain to clear it, so a wait of zero
    // would spin.
    runtime.noteTerminalFailure(error.ProviderInternal);
    try std.testing.expect(runtime.stepWaitMs() != 0);
}

/// One read-and-feed of a half request, or of a whole one on an unattended
/// wire, with the `k`th runtime allocation refused. The caller that owns the
/// wire (`owned`) hears the failure, and a caller that does not sees the wire
/// closed. Count the runs where the cause reached the owner.
fn feedTrial(attended: bool, owned: bool, k: usize, heard: *usize) !bool {
    const allocator = std.testing.allocator;
    var failing = FailingOnce.init(allocator, disabled);
    const rig = try Rig.build(allocator, .{ .fetches = 1, .attended = attended, .runtime_allocator = failing.allocator() });
    const request = rig.packets.items[0];
    var chunk = [1][]const u8{if (attended) request[0 .. request.len / 2] else request};
    rig.resident.offer(&chunk);
    const wire = rig.runtime.wires.get(rig.session.peer_handle).?;
    failing.fail_index = failing.alloc_index + k;
    const outcome = HostRuntime.testing.feedReadable(&rig.runtime, wire, if (owned) rig.session else null);
    const reached = failing.induced;
    failing.fail_index = disabled;
    rig.resident.inbound = &.{};
    if (outcome) |_| {
        if (reached) try std.testing.expect(wire.closed or !owned);
    } else |err| {
        try std.testing.expect(owned);
        try std.testing.expectEqual(error.OutOfMemory, err);
        try std.testing.expect(wire.closed);
        try std.testing.expectEqual(@as(?anyerror, error.OutOfMemory), rig.observed.close_failure);
        heard.* += 1;
    }
    if (reached and !owned) try std.testing.expectEqual(@as(?anyerror, error.OutOfMemory), rig.observed.close_failure);
    rig.destroy();
    try std.testing.expect(failing.balanced());
    return reached;
}

test "a wait that owns the wire hears the exact cause of its refused feed and no other wait does" {
    for ([_]bool{ true, false }) |attended| {
        for ([_]bool{ true, false }) |owned| {
            var heard: usize = 0;
            var k: usize = 0;
            while (try feedTrial(attended, owned, k, &heard)) : (k += 1) {
                if (k == 10_000) return error.SweepNeverEnded;
            }
            try std.testing.expectEqual(owned, heard != 0);
        }
    }
}

fn refuseReserve(_: *anyopaque) anyerror!void {
    return error.SinkRefused;
}

test "a due attempt renews the deadline before it runs, and a failure that is not memory leaves it renewed" {
    const rig = try Rig.build(std.testing.allocator, .{ .fetches = 0, .attended = false, .clock_step_ns = 0 });
    const sibling = try Sibling.attach(rig, false);
    defer {
        rig.destroy();
        sibling.destroy();
    }
    const runtime = &rig.runtime;
    // The sibling wire holds a parked request the sweep has not replayed.
    try sibling.ask();
    _ = try sibling.step();
    try std.testing.expect(sibling.holdsParked());
    // The rig's wire parks a malformed frame behind a closed write window,
    // so the replay that refuses it waits for the window.
    var prefix_buf: [stream_framing.prefix_buffer_bytes]u8 = undefined;
    const prefix = stream_framing.renderPrefix(&prefix_buf, 1);
    var bad: [stream_framing.prefix_buffer_bytes + 1]u8 = undefined;
    @memcpy(bad[0..prefix.len], prefix);
    bad[prefix.len] = 0xff;
    var chunk = [1][]const u8{bad[0 .. prefix.len + 1]};
    rig.resident.offer(&chunk);
    _ = try rig.step();
    rig.resident.inbound = &.{};
    const wire = runtime.wires.get(rig.session.peer_handle).?;
    try std.testing.expect(wire.link.parked.items.len != 0);
    rig.resident.write_open = false;
    var fetches: usize = 0;
    while (!rig.session.outboundPressured()) : (fetches += 1) {
        if (fetches == 1000) return error.NeverPressured;
        _ = try runtime.core.fetch(rig.session, "treasure");
        _ = try rig.step();
    }
    try runtime.attendSession(rig.session);
    try std.testing.expect(wire.link.parked.items.len != 0);

    // The replay closes the wire, which breaks its pending vows, and the
    // drain that settles them cannot reserve a completion slot.
    runtime.drive.stepped.completion_sink.reserve = refuseReserve;
    rig.resident.write_open = true;
    rig.resident.want_write = true;
    // The first step opens the window and flushes the queue, so the replay
    // that follows it finds the session no longer at its waterline.
    _ = try rig.step();
    try std.testing.expectError(error.SinkRefused, rig.step());
    try std.testing.expect(wire.closed);
    try std.testing.expect(runtime.terminal_failure == null);
    // No deadline was set, and a failure that is not memory sets none.
    try std.testing.expect(runtime.core.memory_retry_due_ms == null);
    try std.testing.expect(runtime.held_input_possible);

    // With one set and past due, the attempt renews it to one interval from
    // now before it runs, and the failure that is not memory leaves it so.
    const now = runtime.nowMs();
    runtime.core.memory_retry_due_ms = now - 1;
    try std.testing.expectError(error.SinkRefused, runtime.drainActions());
    try std.testing.expectEqual(@as(?i64, now + HostRuntime.testing.memory_retry_ms), runtime.core.memory_retry_due_ms);
    const wait = runtime.stepWaitMs();
    try std.testing.expect(wait >= 0 and wait <= HostRuntime.testing.memory_retry_ms);
}
