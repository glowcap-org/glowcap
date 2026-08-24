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

/// Write every transport-ready stream vector the core queued for `wire`. The
/// core owns whether the prefix is present, so this I/O tier never interprets
/// transport names or channel state.
pub fn writeOutbound(self: *HostRuntime, wire: *Wire) !void {
    switch (wire.link) {
        .stream => |*stream| {
            while (try wire.session.takeStreamOutbound()) |value| {
                var outbound = value;
                defer outbound.payload.deinit();
                try stream.conn.w.writeAll(outbound.prefixBytes());
                try stream.conn.w.writeAll(outbound.payload.bytes());
            }
            try stream.conn.w.flush();
        },
        .resident => try writeResidentOutbound(self, wire),
    }
}

/// The resident spelling of the outbound drain: the retained frame first,
/// then the core's queue, each through `try_write` until the window refuses. A
/// partial frame is retained with its offset — the window announces writable
/// readiness and the drain resumes exactly there, so bytes are never resent or
/// reordered.
fn writeResidentOutbound(self: *HostRuntime, wire: *Wire) !void {
    const rl = &wire.link.resident;
    const resident = self.residents.items[rl.index].resident;
    if (rl.pending != null) {
        if (!try pushPendingResident(resident, rl)) return;
    }
    while (try wire.session.takeTransportOutbound()) |value| {
        var outbound = value;
        var pending = Wire.ResidentLink.PendingOut{
            .frame = outbound.payload,
            .prefix = undefined,
            .prefix_len = outbound.prefix_len,
            .offset = 0,
        };
        @memcpy(pending.prefix[0..pending.prefix_len], outbound.prefixBytes());
        rl.pending = pending;
        if (!try pushPendingResident(resident, rl)) return;
    }
}

/// Push a retained frame as far as the resident window allows.
fn pushPendingResident(resident: net.MultiplexedResident, rl: *Wire.ResidentLink) !bool {
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

pub fn drainActionsWith(self: *HostRuntime, effect_mode: ExternalEffectMode) !void {
    self.enterDriver();
    defer self.leaveDriver();
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
        if (Internal.wouldClaimCompletion(self.runtime, action)) return;
        if (self.runtime.completion_sink) |sink| try sink.reserve(sink.ctx);
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
            try self.runtime.core.dialFailed(d.ticket, d.route_index, "transport provider failed");
            return;
        }
        try answerDial(self.runtime, d.ticket, d.route_index);
    }

    pub fn cancelDial(self: Exec, d: @FieldType(driver_core.HostAction, "cancel_dial")) !void {
        cancelRedeemDial(self.runtime, d.ticket, d.route_index);
        try self.runtime.core.dialCancelled(d.ticket, d.route_index);
    }

    pub fn complete(self: Exec, action: driver_core.HostAction) !void {
        if (Internal.claimCompletion(self.runtime, action)) return;
        if (self.runtime.completion_sink) |sink| {
            if (sink.take(sink.ctx, action)) return;
            sink.release(sink.ctx);
        }
        self.runtime.core.freeAction(action);
    }
};

/// Stage a redeem dial so the active pump advances its handshake and reports
/// the result through `exporterDialed` / `dialFailed`.
fn answerDial(self: *HostRuntime, ticket: engine.Node.PendingId, route_index: usize) anyerror!void {
    const pending = self.core.pendingDial(ticket, route_index) orelse return;
    // The pending row owns every locator slice until the ticket settles;
    // stageDial borrows the complete active route for this call.
    Internal.stageDial(self, pending.locator, .inherit, .{ .redeem = .{
        .ticket = ticket,
        .route_index = route_index,
    } }, .pending_dial) catch |err| {
        try self.core.dialFailed(ticket, route_index, @errorName(err));
        return;
    };
}

/// Interrupt the native redeem dial named by the core's cancellation action.
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
