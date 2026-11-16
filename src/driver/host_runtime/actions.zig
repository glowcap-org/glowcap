//! Core action execution and transport-ready outbound drains.

const std = @import("std");

const engine = @import("engine");
const net = @import("net");
const driver_core = @import("driver_core");

const lifecycle = @import("lifecycle.zig");
const runtime = @import("../host_runtime.zig");

const HostRuntime = runtime.HostRuntime;
const Internal = runtime.Internal;
const Error = driver_core.Error;
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

/// Drain every immediately runnable core action: writes, redeem dials, entropy
/// draws, closes, and unobserved completions. Outbound pressure returns to the
/// owning step so transport readiness, rather than this stack frame, retries
/// the parked work.
pub fn drainActions(self: *HostRuntime) !void {
    try drainActionsWith(self, .operational);
}

/// How long the step's wait lets work that failed for lack of memory sit
/// before the next drain tries it. Memory comes back when other work
/// finishes, which takes milliseconds, so this is far shorter than a dial's
/// network interval. The deadline bounds idle wake-ups while the work waits.
/// It does not cap retries: every drain reruns the work.
pub const memory_retry_ms: i64 = 250;

/// Ask the step's wait to wake for another drain once memory may have
/// returned (`clampTimeoutToPendingWork`), so queued work a refused
/// allocation left does not wait for an event that may never come.
pub fn armMemoryRetry(self: *HostRuntime) void {
    self.memory_retry_due_ms = self.nowMs() +| memory_retry_ms;
}

/// Drain every immediately runnable action. Arming the memory retry deadline
/// belongs to this drain and to a close whose tail ran out of memory
/// (`closeTailFailed`), and clearing it belongs to this drain alone. A drain
/// that returns clears the deadline, because it has rerun the pump
/// (`resumeWorkForActionDrain`) or stopped at outbound pressure, whose flush
/// wake brings the rerun. A drain that fails with `OutOfMemory` arms it. A
/// drain that fails any other way while it is set arms it afresh, so a
/// deadline already past never holds the step's wait at zero.
pub fn drainActionsWith(self: *HostRuntime, effect_mode: ExternalEffectMode) !void {
    self.enterDriver();
    defer self.leaveDriver();
    drainLoop(self, effect_mode) catch |err| {
        if (err == error.OutOfMemory or self.memory_retry_due_ms != null) armMemoryRetry(self);
        return err;
    };
    self.memory_retry_due_ms = null;
}

fn drainLoop(self: *HostRuntime, effect_mode: ExternalEffectMode) !void {
    // The stepped face parks outside the runtime, so a held answer release
    // has no later message of ours to ride before that park: every drain
    // here sends it. The blocking face flushes at its own park instead
    // (`waitAnySource`), where the next verb's message may still carry it.
    if (self.drive == .stepped) _ = try self.core.flushHeldReleases();
    // The blocking front has no shared reactor turn to yield to, so finite
    // scheduler slices continue here. Outbound pressure is different: the
    // resident window can move only after this call returns to readiness.
    while (true) switch (try driver_core.drainActions(
        self.core,
        EntropySource{ .io = self.io },
        Exec{ .runtime = self, .effect_mode = effect_mode },
    )) {
        .drained, .outbound_blocked => return,
        .yielded => {},
    };
}

const EntropySource = struct {
    io: std.Io,
    pub fn randomSecure(self: EntropySource, buf: []u8) !void {
        self.io.randomSecure(buf) catch return Error.HandshakeEntropyFailed;
    }
};

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
            .stepped => |*stepped| try stepped.completion_sink.reserve(stepped.completion_sink.ctx),
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
                if (sink.take(sink.ctx, action)) return;
                // A sink declines only while its embedder releases the loop,
                // so nothing asks for this completion again.
                sink.release(sink.ctx);
                self.runtime.core.freeAction(action);
            },
        }
    }
};

/// Stage a redeem dial so the active pump advances its handshake and reports
/// the result through `exporterDialed` / `dialFailed`. Keeps `anyerror` on
/// purpose: its failure path drains actions again, so narrowing it to an
/// inferred set closes a dependency loop through the action drain that the
/// toolchain refuses to resolve.
fn answerDial(self: *HostRuntime, ticket: engine.Node.PendingId, route_index: usize) anyerror!void {
    const pending = self.core.pendingDial(ticket, route_index) orelse return;
    // The pending row owns every locator slice until the ticket settles;
    // stageDial borrows the complete active route for this call.
    Internal.stageDial(self, pending.locator, .inherit, .{ .redeem = .{
        .ticket = ticket,
        .route_index = route_index,
    } }, .pending_dial) catch |err| {
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
