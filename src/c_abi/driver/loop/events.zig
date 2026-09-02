//! Own the C loop event queue, observer callbacks, and borrowed event projection.

const std = @import("std");
const engine = @import("engine");
const driver = @import("driver");
const driver_core = @import("driver_core");
const root = @import("../loop.zig");
const listener_state = @import("../listener_state.zig");
const driver_error = @import("../error.zig");
const failure_output = @import("../failure_output.zig");
const shared = @import("c_abi_shared");
const ch = @import("c_abi_host");
const c = @import("../mod.zig");

const Internal = root.Internal;
const Instance = Internal.Instance;
const FailureProjection = c.FailureProjection;
const GLOWCAP_OK = shared.GLOWCAP_OK;
const GLOWCAP_ERR_NULL_POINTER = shared.GLOWCAP_ERR_NULL_POINTER;
const GLOWCAP_ERR_INVALID_ARGUMENT = shared.GLOWCAP_ERR_INVALID_ARGUMENT;
const GLOWCAP_ERR_WOULD_BLOCK = shared.GLOWCAP_ERR_WOULD_BLOCK;
const instanceFrom = Internal.instanceFrom;

/// One queued loop event, in owned form; projection to C happens at pop.
pub const OwnedEvent = union(enum) {
    opened: struct { operation_id: u64, session: SessionEventRef },
    open_failed: struct { operation_id: u64, failure: FailureProjection },
    listener_ready: u64,
    listener_failed: struct { listener: u64, failure: FailureProjection },
    accepted: struct { listener: u64, session: SessionEventRef },
    session_closed: struct {
        session: SessionEventRef,
        failure: ?FailureProjection,
    },
    completion: driver_core.HostAction,
};

/// Stable identity beside a borrowed session pointer. Release removes the
/// wire map row before freeing the session, so stale queued events can compare
/// pointer values without dereferencing freed memory.
pub const SessionEventRef = struct {
    peer_handle: engine.PeerHandle,
    hs: *driver_core.HostSession,

    fn init(hs: *driver_core.HostSession) SessionEventRef {
        return .{ .peer_handle = hs.peer_handle, .hs = hs };
    }

    fn isLive(self: SessionEventRef, inst: *const Instance) bool {
        return inst.runtime.sessionEventIsLive(self.peer_handle, self.hs);
    }
};

// ── Event queue ──────────────────────────────────────────────────────────────

pub fn compactEventsIfDrained(inst: *Instance) void {
    if (inst.events_head < inst.events.items.len) return;
    inst.events.clearRetainingCapacity();
    inst.events_head = 0;
}

pub fn reserveEvent(inst: *Instance) !void {
    compactEventsIfDrained(inst);
    const promised = std.math.add(usize, inst.events.items.len, inst.event_reservations) catch
        return error.OutOfMemory;
    const required = std.math.add(usize, promised, 1) catch return error.OutOfMemory;
    try inst.events.ensureTotalCapacity(inst.allocator, required);
    inst.event_reservations += 1;
}

pub fn releaseEventReservation(inst: *Instance) void {
    std.debug.assert(inst.event_reservations != 0);
    inst.event_reservations -= 1;
}

pub fn reserveOpenEventForObserver(ctx: *anyopaque, _: u64) anyerror!void {
    const inst: *Instance = @ptrCast(@alignCast(ctx));
    try reserveEvent(inst);
}

pub fn releaseOpenEventForObserver(ctx: *anyopaque, _: u64) void {
    const inst: *Instance = @ptrCast(@alignCast(ctx));
    releaseEventReservation(inst);
}

pub fn abandonListenerEvent(ctx: *anyopaque, tag: u64) void {
    const inst: *Instance = @ptrCast(@alignCast(ctx));
    listener_state.abandon(inst, tag);
}

pub fn retireListener(ctx: *anyopaque, tag: u64) void {
    const inst: *Instance = @ptrCast(@alignCast(ctx));
    listener_state.retire(inst, tag);
}

pub fn enqueueReservedEvent(inst: *Instance, event: OwnedEvent) void {
    releaseEventReservation(inst);
    inst.events.appendAssumeCapacity(event);
}

pub fn reentrancyCode(inst: *Instance, operation: []const u8) ?i32 {
    if (inst.stepping) {
        shared.setLastError("driver: {s} refused during driver execution", .{operation});
        return GLOWCAP_ERR_INVALID_ARGUMENT;
    }
    inst.runtime.refuseReentry() catch |err| {
        shared.setLastError("driver: {s} refused during driver execution: {s}", .{ operation, @errorName(err) });
        return driver_error.fromError(err);
    };
    return null;
}

pub fn operationErrorCode(inst: *const Instance, err: anyerror) i32 {
    return failure_output.operationCode(&inst.runtime, err);
}

pub fn freeEventPayload(inst: *Instance, event: OwnedEvent) void {
    switch (event) {
        .completion => |action| inst.runtime.freeAction(action),
        else => {},
    }
}

pub fn popEvent(inst: *Instance) ?OwnedEvent {
    if (inst.events_head >= inst.events.items.len) return null;
    const event = inst.events.items[inst.events_head];
    inst.events_head += 1;
    return event;
}

fn eventNamesLiveSession(inst: *const Instance, event: OwnedEvent) bool {
    return switch (event) {
        .opened => |opened| opened.session.isLive(inst),
        .accepted => |accepted| accepted.session.isLive(inst),
        .session_closed => |closed| closed.session.isLive(inst),
        .open_failed, .listener_ready, .listener_failed, .completion => true,
    };
}

// ── Host observer seams ──────────────────────────────────────────────────

/// The completion sink installed on the poll face: settled/failed actions
/// with no in-process claimer queue as COMPLETION events. The shared drain
/// reserves the queue slot while the completion remains parked, so taking it
/// here is allocation-free and infallible.
pub fn sinkTake(ctx: *anyopaque, action: driver_core.HostAction) bool {
    const inst: *Instance = @ptrCast(@alignCast(ctx));
    enqueueReservedEvent(inst, .{ .completion = action });
    return true;
}

pub fn reserveSinkEvent(ctx: *anyopaque) anyerror!void {
    const inst: *Instance = @ptrCast(@alignCast(ctx));
    try reserveEvent(inst);
}

pub fn releaseSinkEvent(ctx: *anyopaque) void {
    const inst: *Instance = @ptrCast(@alignCast(ctx));
    releaseEventReservation(inst);
}

/// The close observer: a wire the pump closes queues a SESSION_CLOSED event.
/// Clean EOF carries GLOWCAP_OK and no message; a fault carries the stable
/// driver classification plus its concrete Zig error name. Wire adoption
/// reserved this event before the session could become visible.
pub fn observeClose(
    ctx: *anyopaque,
    hs: *driver_core.HostSession,
    failure: ?driver.OperationFailure,
) void {
    const inst: *Instance = @ptrCast(@alignCast(ctx));
    enqueueReservedEvent(inst, .{ .session_closed = .{
        .session = .init(hs),
        .failure = if (failure) |f| .init(f) else null,
    } });
}

/// An open finished its handshake inside a step; queue OPENED under its
/// operation id. Admission reserved the queue slot, so this callback cannot
/// allocate after the session commits.
pub fn openSucceeded(ctx: *anyopaque, tag: u64, session: *driver_core.HostSession) !void {
    const inst: *Instance = @ptrCast(@alignCast(ctx));
    try inst.runtime.claimSessionHandle(session);
    // The embedder has not seen this session; hold its inbound until
    // `glowcap_driver_session_serve` says the post-open setup is done, so a
    // partner's pipelined first frames cannot outrun a publish.
    inst.runtime.markSessionUnattended(session);
    enqueueReservedEvent(inst, .{ .opened = .{ .operation_id = tag, .session = .init(session) } });
}

/// An open failed after the host unwound its in-flight session. Queue
/// OPEN_FAILED with the error's static name. Admission reserved the queue slot,
/// so failure publication cannot allocate after the operation commits.
pub fn openFailedEvent(ctx: *anyopaque, tag: u64, failure: driver.OperationFailure) void {
    const inst: *Instance = @ptrCast(@alignCast(ctx));
    enqueueReservedEvent(inst, .{
        .open_failed = .{
            .operation_id = tag,
            .failure = .init(failure),
        },
    });
}

/// The accept observer's opened arm: an admitted accept finished its handshake;
/// queue the ACCEPTED event under its listener id. The accept step reserved
/// the queue slot before admitting the connection.
pub fn acceptOpened(ctx: *anyopaque, tag: u64, session: *driver_core.HostSession) !void {
    const inst: *Instance = @ptrCast(@alignCast(ctx));
    try inst.runtime.claimSessionHandle(session);
    // Same hold as a dialed open: the accepted partner's coalesced fetch must
    // wait for the embedder's publishes, not race them.
    inst.runtime.markSessionUnattended(session);
    enqueueReservedEvent(inst, .{ .accepted = .{ .listener = tag, .session = .init(session) } });
}

pub fn acceptFailed(ctx: *anyopaque, tag: u64, failure: driver.OperationFailure) void {
    const inst: *Instance = @ptrCast(@alignCast(ctx));
    if (inst.listeners.fetchRemove(@fromBackingInt(@intCast(tag)))) |removed| {
        var state = removed.value;
        _ = state.deinit(inst);
    } else {
        inst.runtime.noteTerminalFailure(error.ProviderContract);
    }
    enqueueReservedEvent(inst, .{
        .listener_failed = .{
            .listener = tag,
            .failure = .init(failure),
        },
    });
}

/// Pop the oldest loop event into `out`, or `GLOWCAP_ERR_WOULD_BLOCK` when
/// none is pending (drain in a loop until that code). Borrowed views in the
/// popped event — an OPEN_FAILED error name, a COMPLETION action's bytes and
/// children — stay valid until the next call. Completion payloads are freed
/// then; error names are static.
pub export fn glowcap_driver_next_event(raw: ?*c.GlowcapDriverLoop, out: ?*c.GlowcapDriverEvent) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(raw) orelse return GLOWCAP_ERR_NULL_POINTER;
    if (reentrancyCode(inst, "next_event")) |code| return code;
    const slot = out orelse return GLOWCAP_ERR_NULL_POINTER;
    if (inst.handed_completion) |action| {
        inst.runtime.freeAction(action);
        inst.handed_completion = null;
    }
    const event = while (popEvent(inst)) |candidate| {
        if (eventNamesLiveSession(inst, candidate)) break candidate;
        freeEventPayload(inst, candidate);
    } else return GLOWCAP_ERR_WOULD_BLOCK;
    slot.* = std.mem.zeroes(c.GlowcapDriverEvent);
    switch (event) {
        .opened => |opened| {
            slot.kind = c.GLOWCAP_DRIVER_EVENT_OPENED;
            slot.operation_id = opened.operation_id;
            slot.session = ch.embedding.sessionHandle(opened.session.hs);
        },
        .open_failed => |failed| {
            slot.kind = c.GLOWCAP_DRIVER_EVENT_OPEN_FAILED;
            slot.operation_id = failed.operation_id;
            failed.failure.project(slot);
        },
        .listener_ready => |listener| {
            slot.kind = c.GLOWCAP_DRIVER_EVENT_LISTENER_READY;
            slot.listener_id = listener;
        },
        .listener_failed => |failed| {
            slot.kind = c.GLOWCAP_DRIVER_EVENT_LISTENER_FAILED;
            slot.listener_id = failed.listener;
            failed.failure.project(slot);
        },
        .accepted => |a| {
            slot.kind = c.GLOWCAP_DRIVER_EVENT_ACCEPTED;
            slot.listener_id = a.listener;
            slot.session = ch.embedding.sessionHandle(a.session.hs);
        },
        .session_closed => |closed| {
            slot.kind = c.GLOWCAP_DRIVER_EVENT_SESSION_CLOSED;
            slot.session = ch.embedding.sessionHandle(closed.session.hs);
            if (closed.failure) |failure| failure.project(slot);
        },
        .completion => |action| {
            slot.kind = c.GLOWCAP_DRIVER_EVENT_COMPLETION;
            const code = ch.embedding.projectCompletion(inst.host_handle, action, &slot.action);
            if (code != GLOWCAP_OK) {
                inst.runtime.freeAction(action);
                return code;
            }
            inst.handed_completion = action;
        },
    }
    return GLOWCAP_OK;
}
