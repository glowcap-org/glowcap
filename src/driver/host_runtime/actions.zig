//! Core action execution and transport-ready outbound drains.

const std = @import("std");

const engine = @import("engine");
const net = @import("net");
const driver_core = @import("driver_core");

const lifecycle = @import("lifecycle.zig");
const runtime = @import("../host_runtime.zig");

const HostRuntime = runtime.HostRuntime;
const Internal = runtime.Internal;
const ExternalEffectMode = lifecycle.ExternalEffectMode;
const Wire = HostRuntime.Wire;

/// Write what the core queued for `wire`: the retained frame first,
/// then the core's queue, each through `try_write` until the window refuses. A
/// partial frame is retained with its offset. The window announces writable
/// readiness and the drain resumes exactly there, so bytes are never resent or
/// reordered.
/// The core owns whether the prefix is present, so this I/O tier never
/// interprets transport names or channel state.
pub fn writeOutbound(self: *HostRuntime, wire: *Wire) !void {
    const rl = &wire.link;
    const resident = self.residents.items[rl.index].resident;
    // One batch per drain: the resident sends what this drain staged at once.
    defer resident.flushWrites(rl.conn);
    if (rl.pending != null) {
        if (!try pushPendingResident(resident, rl)) return;
    }
    while (try wire.session.takeTransportOutbound()) |outbound| {
        // The whole fixed prefix buffer moves as one array, a few word
        // stores, where copying `prefix_len` bytes would call memcpy.
        rl.pending = .{
            .frame = outbound.payload,
            .prefix = outbound.prefix,
            .prefix_len = outbound.prefix_len,
            .offset = 0,
        };
        if (!try pushPendingResident(resident, rl)) return;
    }
}

/// Push a retained frame as far as the resident window allows.
fn pushPendingResident(resident: net.MultiplexedResident, rl: *Wire.Link) !bool {
    const pending = &rl.pending.?;
    const body = pending.frame.bytes();
    const total = pending.prefix_len + body.len;
    while (pending.offset < total) {
        const span = if (pending.offset < pending.prefix_len)
            pending.prefix[pending.offset..pending.prefix_len]
        else
            body[pending.offset - pending.prefix_len ..];
        const wrote = resident.tryWrite(rl.conn, span);
        if (wrote == net.multiplexed_resident.would_block) return false;
        if (wrote < 0) return error.ConnectionLost;
        // Zero is a full non-blocking window, not progress. Retain the frame
        // and wait for the same writable event as the explicit sentinel.
        if (wrote == 0) return false;
        if (@as(usize, @intCast(wrote)) > span.len) return error.ConnectionLost;
        pending.offset += @intCast(wrote);
    }
    pending.frame.deinit();
    rl.pending = null;
    return true;
}

/// What one gated drain left behind: everything it could run ran, or work a
/// memory refusal left queued waits for the retry deadline.
pub const Drain = enum { complete, retained };

/// Whether an attempt sends held answer releases before the core's actions.
/// The stepped face flushes on every attempt, because it parks outside the
/// runtime and no later message of ours would carry them. The blocking face
/// flushes only when the retry is due or at its own park (`.park`), where the
/// next verb's message may still carry them. A `.park` attempt that sent
/// nothing drains nothing.
pub const FlushIntent = enum { turn, park };

/// Drain every immediately runnable core action: writes, redeem dials, entropy
/// draws, closes, and unobserved completions. Outbound pressure returns to the
/// owning step so transport readiness, rather than this stack frame, retries
/// the parked work. Work a memory refusal left retained answers
/// `error.OutOfMemory` here, for the caller whose result needs it drained
/// (`replyVowId`). A completion-sink callback calling this gets
/// `error.ReenteredHost`. Runtime turns and consumed handles call `attempt` and treat
/// retained work as queued, not failed.
pub fn drainActions(self: *HostRuntime) !void {
    try self.refuseReentry();
    switch (try attempt(self, .operational, .turn)) {
        .complete => {},
        .retained => return error.OutOfMemory,
    }
}

/// How long the step's wait lets work that failed for lack of memory sit
/// before the next drain tries it. Memory comes back when other work
/// finishes, which takes milliseconds, so this is far shorter than a dial's
/// network interval. The deadline bounds idle wake-ups while the work waits.
pub const memory_retry_ms: i64 = 250;

/// Record that core work waits on memory: arm the retry deadline unless one
/// is armed or the runtime failed terminally. An armed deadline is never
/// postponed, so a persistent shortage retries at the policy rate. The step's
/// wait wakes for the deadline (`clampTimeoutToPendingWork`), and the core
/// reports no runnable work until then (`Host.hasRunnableWork`).
pub fn noteMemoryDebt(self: *HostRuntime) void {
    if (self.terminal_failure != null) return;
    if (self.core.memory_retry_due_ms == null) self.core.memory_retry_due_ms = self.nowMs() +| memory_retry_ms;
}

/// Drop the retry deadline: the work it gated ran, or the runtime failed
/// terminally and no later drain will clear it.
pub fn clearMemoryDebt(self: *HostRuntime) void {
    self.core.memory_retry_due_ms = null;
}

/// One drain of the held releases and the core's actions, gated by the memory
/// retry deadline. The deadline belongs to this function, to a close whose
/// tail ran out of memory (`closeTailFailed`), and to the terminal setters.
///
/// - Operational: no core deadline runs. Not yet due returns `.retained`
///   before any core work, so the core allocates nothing. A due resident
///   pass (`resident_retry_due_ms`) runs first and may reserve and submit.
///   Due renews the core deadline to one policy interval from now and runs,
///   so each owner gets one attempt per interval.
/// - A memory refusal in the flush is remembered while the core's actions
///   still drain. Any other flush error stops. On every exit a remembered
///   refusal arms the deadline before a later error returns, and a clean
///   drain with one returns `.retained`. A clean drain without one clears
///   the deadline: it ran the pump again (`resumeWorkForActionDrain`) or
///   stopped at outbound pressure, whose flush wake brings the rerun. An
///   error other than memory with no new refusal leaves the deadline as is.
/// - Cleanup-only, and any drain after a terminal failure, is ungated: it
///   reads and writes no deadline and returns every error, a flush refusal
///   included, at once.
pub fn attempt(self: *HostRuntime, effect_mode: ExternalEffectMode, intent: FlushIntent) !Drain {
    return attemptWith(self, effect_mode, intent, CoreFlush);
}

/// The held-release flush `attempt` runs, a comptime parameter so a test can
/// refuse or count it without a real encode failure.
const CoreFlush = struct {
    pub fn flush(core: *driver_core.Host) !bool {
        return core.flushHeldReleases();
    }
};

/// Retry every resident debt once: the due pass of `resident_retry_due_ms`.
/// A group's `retry` runs no runtime verb, so it can neither latch terminal
/// nor change the resident list this pass walks.
fn retryDueResidents(self: *HostRuntime) void {
    for (self.residents.items) |registered| {
        const group = registered.resident.memoryRetry() orelse continue;
        if (group.owes()) group.retry();
    }
}

/// Bring `resident_retry_due_ms` in line with the residents' live debt: arm one
/// policy interval when some resident owes and none is armed, keep an armed
/// deadline, clear it when nothing is owed. After a terminal failure it clears
/// without asking any resident.
pub fn reconcileResidentDebt(self: *HostRuntime) void {
    if (self.terminal_failure != null) {
        self.resident_retry_due_ms = null;
        return;
    }
    var owed = false;
    for (self.residents.items) |registered| {
        const group = registered.resident.memoryRetry() orelse continue;
        if (group.owes()) {
            owed = true;
            break;
        }
    }
    if (!owed) {
        self.resident_retry_due_ms = null;
    } else if (self.resident_retry_due_ms == null) {
        self.resident_retry_due_ms = self.nowMs() +| memory_retry_ms;
    }
}

pub fn attemptWith(
    self: *HostRuntime,
    effect_mode: ExternalEffectMode,
    intent: FlushIntent,
    comptime Flush: type,
) !Drain {
    self.enterDriver();
    defer self.leaveDriver();
    // Declared after `leaveDriver`, so it runs first on every exit.
    defer if (effect_mode == .operational) reconcileResidentDebt(self);
    const gated = effect_mode == .operational and self.terminal_failure == null;
    // Resident debt has its own deadline and runs before the core gate, so a
    // not-due or failed core drain cannot starve it. A callback skips it
    // without renewing, and the next top-level attempt runs it.
    if (gated and !self.withinCallback()) if (self.resident_retry_due_ms) |deadline| {
        const now_ms = self.nowMs();
        if (now_ms >= deadline) {
            self.resident_retry_due_ms = now_ms +| memory_retry_ms;
            retryDueResidents(self);
        }
    };
    var due = false;
    if (gated) if (self.core.memory_retry_due_ms) |deadline| {
        const now_ms = self.nowMs();
        if (now_ms < deadline) return .retained;
        self.core.memory_retry_due_ms = now_ms +| memory_retry_ms;
        due = true;
    };
    var remembered = false;
    var flushed = false;
    if (self.drive == .stepped or intent == .park or due) {
        flushed = Flush.flush(self.core) catch |err| blk: {
            if (!gated or err != error.OutOfMemory) return err;
            remembered = true;
            break :blk false;
        };
        // A ready report keeps a park from returning only when this attempt
        // can run it: terminal cleanup runs no report, so it must not force a drain.
        if (intent == .park and !flushed and !remembered and !due and !(gated and Internal.readyReportWaiting(self))) return .complete;
    }
    // The one reporter of retained redeem verdicts. It is gated like the
    // drain below, and never runs under a callback, where the core refuses
    // re-entry. An actual refusal is debt exactly as a flush refusal is.
    if (gated and !self.withinCallback()) {
        if (Internal.reportRedeems(self)) remembered = true;
    }
    drainLoop(self, effect_mode) catch |err| {
        if (!gated) return err;
        if (err == error.OutOfMemory) {
            noteMemoryDebt(self);
            return .retained;
        }
        if (remembered) noteMemoryDebt(self);
        return err;
    };
    if (!gated) return .complete;
    if (remembered) {
        noteMemoryDebt(self);
        return .retained;
    }
    clearMemoryDebt(self);
    // A report the drain staged, or one a due attempt's renewed deadline
    // suppressed a wake for, is runnable now that the deadline is clear.
    Internal.nudgeReadyReports(self);
    return .complete;
}

fn drainLoop(self: *HostRuntime, effect_mode: ExternalEffectMode) !void {
    // The blocking front has no shared reactor turn to yield to, so finite
    // scheduler slices continue here. Outbound pressure is different: the
    // resident window can move only after this call returns to readiness.
    while (true) switch (try driver_core.drainActions(
        self.core,
        self.io,
        Exec{ .runtime = self, .effect_mode = effect_mode },
    )) {
        .drained, .outbound_blocked => return,
        .yielded => {},
        .unobserved_gift_failure => |err| self.reportUnhandledFailure(.fromError(err)),
    };
}

const Exec = struct {
    runtime: *HostRuntime,
    effect_mode: ExternalEffectMode,

    pub fn prepare(self: Exec, action: driver_core.HostAction) !void {
        switch (action) {
            .settled, .failed => {},
            else => return,
        }
        switch (self.runtime.drive) {
            .blocking => {},
            .stepped => |*stepped| {
                const sink = stepped.completion_sink;
                self.runtime.observer_callback_depth += 1;
                defer self.runtime.observer_callback_depth -= 1;
                try sink.reserve(sink.ctx);
            },
        }
    }

    pub fn flush(self: Exec, peer_handle: engine.PeerHandle) !void {
        if (self.effect_mode == .cleanup_only) return;
        const wire = self.runtime.wires.get(peer_handle) orelse return;
        if (wire.closed) return;
        writeOutbound(self.runtime, wire) catch |err| Internal.closeWire(self.runtime, wire, err);
    }

    pub fn close(self: Exec, peer_handle: engine.PeerHandle) !void {
        const wire = self.runtime.wires.get(peer_handle) orelse return;
        if (!wire.closed and self.effect_mode == .operational)
            writeOutbound(self.runtime, wire) catch |err| Internal.closeWire(self.runtime, wire, err);
        if (!wire.closed) Internal.closeWire(self.runtime, wire, null);
    }

    pub fn dial(self: Exec, d: @FieldType(driver_core.HostAction, "dial")) !void {
        if (self.effect_mode == .cleanup_only) {
            try self.runtime.core.dialFailed(d.ticket, d.route_index, .peer_unreachable, "transport provider failed");
            return;
        }
        try answerDial(self.runtime, d.ticket, d.route_index);
    }

    pub fn cancelDial(self: Exec, d: @FieldType(driver_core.HostAction, "cancel_dial")) !void {
        cancelRedeemDial(self.runtime, d.ticket, d.route_index);
        try self.runtime.core.dialCancelled(d.ticket, d.route_index);
    }

    pub fn complete(self: Exec, action: driver_core.HostAction) !void {
        switch (self.runtime.drive) {
            // No embedder takes this completion, so its row keeps it with
            // its retains for `Promise.settle` or the handle's release.
            .blocking => self.runtime.core.holdAction(action),
            .stepped => |*stepped| {
                const sink = stepped.completion_sink;
                // The sink is embedder code: guard it like a close observer,
                // so a verb it calls refuses with `ReenteredHost`.
                self.runtime.observer_callback_depth += 1;
                defer self.runtime.observer_callback_depth -= 1;
                if (sink.take(sink.ctx, action)) return;
                // A sink declines only while its embedder releases the loop,
                // so nothing asks for this completion again.
                sink.release(sink.ctx);
                self.runtime.core.freeAction(action);
            },
        }
    }
};

/// Stage a redeem dial so the active pump advances its handshake. The row it
/// stages keeps its verdict until `redeem_reports.zig` commits it
/// (`exporterDialed` / `dialFailed`). A provider that refuses at once leaves a
/// ready failed report on that row rather than reporting here. A staging error
/// before any row exists reports `dialFailed` here, inside the drain already
/// running this action, and a memory refusal commits nothing. Staging never
/// drains.
fn answerDial(self: *HostRuntime, ticket: engine.Node.PendingId, route_index: usize) !void {
    const pending = self.core.pendingDial(ticket, route_index) orelse return;
    // The pending row owns every locator slice until the ticket settles;
    // stageDial borrows the complete active route for this call.
    Internal.stageDial(self, pending.locator, .inherit, .{ .redeem = .{
        .ticket = ticket,
        .route_index = route_index,
    } }, .pending_dial) catch |err| {
        // A refusal before the row owns the dial commits no verdict: the
        // core action's retry owner re-runs it once memory is due.
        if (err == error.OutOfMemory) return err;
        const failure = self.operationFailure(err);
        try self.core.dialFailed(ticket, route_index, failure.routeFailure(), failure.chain.primaryName());
        return;
    };
}

/// Interrupt the Zig redeem dial named by the core's cancellation action.
fn cancelRedeemDial(self: *HostRuntime, ticket: engine.Node.PendingId, route_index: usize) void {
    for (self.pending_opens.items, 0..) |row, index| switch (row.outcome) {
        .redeem => |pending| if (pending.ticket == ticket and pending.route_index == route_index) {
            std.debug.assert(self.pending_opens.swapRemove(index) == row);
            var discarded = Internal.discardPendingOpen(self, row);
            if (discarded.cleanup) |cleanup| Internal.noteTerminalFailureChain(self, cleanup);
            discarded.admission.release();
            return;
        },
        .operation, .listener_accept => {},
    };
}
