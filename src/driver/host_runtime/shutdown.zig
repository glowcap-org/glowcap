//! Driver-thread ownership and monotonic Runtime/session shutdown barriers.

const std = @import("std");

const net = @import("net");
const driver_core = @import("driver_core");

const lifecycle = @import("lifecycle.zig");
const runtime = @import("../host_runtime.zig");

const HostRuntime = runtime.HostRuntime;
const Internal = runtime.Internal;
const Error = driver_core.Error;
const OperationFailure = @import("../operation_failure.zig").OperationFailure;
const PendingWork = HostRuntime.PendingWork;
const CloseOutcome = HostRuntime.CloseOutcome;
const ExternalEffectMode = lifecycle.ExternalEffectMode;

pub const SessionCloseStatus = struct {
    phase: driver_core.HostSession.LifecyclePhase,
    outcome: CloseOutcome,
};

/// Enter one native driver operation. Public only for sibling owning faces.
pub fn enterDriver(self: *HostRuntime) void {
    if (comptime std.debug.runtime_safety) self.core.assertOwner();
    self.driver_depth += 1;
}

/// Transfer core ownership only after the outermost call stops dispatching.
pub fn leaveDriver(self: *HostRuntime) void {
    if (self.driver_depth == 0) {
        Internal.retainAndReportUnhandledFailure(self, .fromError(error.ProviderContract));
        return;
    }
    self.driver_depth -= 1;
    if (self.driver_depth != 0 or self.draining_session_releases) return;
    if (drainDeferredSessionReleases(self)) return;
    self.core.releaseDriverOwnership();
}

pub fn detachThread(self: *HostRuntime) error{HostNotQuiescent}!void {
    if (self.driver_depth != 0) return error.HostNotQuiescent;
    self.core.releaseDriverOwnership();
}

/// Transfer callback-time implicit Session release to the outermost turn.
pub fn deferSessionRelease(self: *HostRuntime, request: *HostRuntime.DeferredSessionRelease) !void {
    enterDriver(self);
    defer leaveDriver(self);
    std.debug.assert(withinCallback(self));
    std.debug.assert(!request.queued);
    const wire = self.wires.get(request.session.peer_handle) orelse return Error.SessionNotOwned;
    if (wire.session != request.session or !wire.session_handle_claimed) return Error.SessionNotOwned;
    self.core.beginSessionClose(request.session, .cancel, net.clock.nowMs(self.io)) catch |err|
        self.noteTerminalFailure(err);
    request.next = self.deferred_session_releases;
    request.queued = true;
    self.deferred_session_releases = request;
}

pub fn drainDeferredSessionReleases(self: *HostRuntime) bool {
    if (self.deferred_session_releases == null) return false;
    self.draining_session_releases = true;
    progressSessionCloses(self) catch |err| self.noteTerminalFailure(err);
    self.drainActions() catch |err| self.noteTerminalFailure(err);

    var request = self.deferred_session_releases;
    self.deferred_session_releases = null;
    while (request) |current| {
        const next = current.next;
        const wire = self.wires.get(current.session.peer_handle);
        if (wire == null or wire.?.session != current.session) {
            current.next = null;
            current.queued = false;
            Internal.retainAndReportUnhandledFailure(self, .fromError(error.ProviderContract));
            if (current.complete(current.ctx)) return true;
            request = next;
            continue;
        }
        if (!wire.?.carrierClosed()) {
            current.next = self.deferred_session_releases;
            self.deferred_session_releases = current;
            request = next;
            continue;
        }
        current.next = null;
        current.queued = false;
        Internal.releaseWireOwned(self, current.session) catch |err| {
            self.noteTerminalFailure(err);
            current.next = self.deferred_session_releases;
            self.deferred_session_releases = current;
            request = next;
            continue;
        };
        if (current.complete(current.ctx)) return true;
        request = next;
    }
    self.draining_session_releases = false;
    if (self.deferred_session_releases != null) Internal.nudgeIfWorkRemains(self);
    return false;
}

pub fn refuseReentry(self: *HostRuntime) error{ ReenteredHost, WrongThread }!void {
    if (self.observer_callback_depth != 0) return error.ReenteredHost;
    try self.core.refuseReentry();
}

pub fn withinCallback(self: *const HostRuntime) bool {
    return self.observer_callback_depth != 0 or self.core.withinCallback();
}

pub fn beginClose(self: *HostRuntime, pending: PendingWork) void {
    enterDriver(self);
    defer leaveDriver(self);
    beginCloseOwned(self, pending);
}

fn beginCloseOwned(self: *HostRuntime, pending: PendingWork) void {
    self.retiring = false;
    self.retirement_effects_pending = false;
    self.close_effects_pending = true;
    self.core.beginClose(pending, net.clock.nowMs(self.io));
    self.wakeReadiness() catch |err| self.noteTerminalFailure(err);
}

pub fn beginSessionClose(self: *HostRuntime, session: *driver_core.HostSession, pending: PendingWork) !void {
    enterDriver(self);
    defer leaveDriver(self);
    const wire = self.wires.get(session.peer_handle) orelse return Error.SessionNotOwned;
    if (wire.session != session) return Error.SessionNotOwned;
    try self.core.beginSessionClose(session, pending, net.clock.nowMs(self.io));
    self.wakeReadiness() catch |err| self.noteTerminalFailure(err);
}

/// Hold the driver claim across the full session transport barrier.
pub fn closeSession(self: *HostRuntime, session: *driver_core.HostSession, pending: PendingWork) !void {
    try refuseReentry(self);
    enterDriver(self);
    defer leaveDriver(self);
    try beginSessionClose(self, session, pending);
    while (sessionCloseOutcome(self, session) == .pending)
        _ = try Internal.stepAnyToward(self, -1, .{ .session_close = session });
    if (sessionCloseOutcome(self, session) == .timed_out) return Error.CloseTimedOut;
    if (self.wires.get(session.peer_handle)) |wire|
        if (wire.close_failure) |failure| return failure.cause;
}

pub fn sessionCloseOutcome(self: *const HostRuntime, session: *const driver_core.HostSession) CloseOutcome {
    const wire_closed = if (self.wires.get(session.peer_handle)) |wire| wire.carrierClosed() else true;
    return self.core.sessionCloseOutcome(session, wire_closed);
}

pub fn sessionCloseStatus(self: *const HostRuntime, session: *const driver_core.HostSession) Error!SessionCloseStatus {
    const wire = self.wires.get(session.peer_handle) orelse return Error.SessionNotOwned;
    if (wire.session != session) return Error.SessionNotOwned;
    return .{
        .phase = session.lifecyclePhase(),
        .outcome = self.core.sessionCloseOutcome(session, wire.carrierClosed()),
    };
}

pub fn freeAction(self: *HostRuntime, action: driver_core.HostAction) void {
    self.core.freeAction(action);
}

pub fn progressSessionCloses(self: *HostRuntime) !void {
    try self.core.progressSessionCloses(net.clock.nowMs(self.io));
}

pub fn close(self: *HostRuntime, pending: PendingWork) !void {
    try refuseReentry(self);
    beginClose(self, pending);
    while (closeOutcome(self) == .pending) _ = try Internal.stepAnyToward(self, -1, .host_close);
    if (closeOutcome(self) == .timed_out) return Error.CloseTimedOut;
}

/// Retire listeners now. Close the Host only after every claimed Session leaves.
pub fn beginRetirement(self: *HostRuntime) void {
    enterDriver(self);
    defer leaveDriver(self);
    if (self.core.lifecyclePhase() != .active) return;
    self.retiring = true;
    self.retirement_effects_pending = true;
    self.wakeReadiness() catch |err| self.noteTerminalFailure(err);
}

pub fn progressRetirement(self: *HostRuntime) !void {
    if (!self.retiring) return;
    if (self.retirement_effects_pending) {
        self.retirement_effects_pending = false;
        Internal.closeOwnedListeners(self);
        cancelPendingListenerSetups(self);
    }
    if (self.claimed_session_handles == 0) beginCloseOwned(self, .cancel);
}

pub fn listenerOwnershipRetired(self: *const HostRuntime) bool {
    return self.pending_listeners.items.len == 0 and self.active_listeners.count() == 0;
}

pub fn lifecyclePhase(self: *const HostRuntime) driver_core.Host.LifecyclePhase {
    return self.core.lifecyclePhase();
}

pub fn closeOutcome(self: *const HostRuntime) CloseOutcome {
    if (self.retiring) return .pending;
    const complete = self.core.lifecyclePhase() == .closed and
        self.pending_opens.items.len == 0 and self.pending_listeners.items.len == 0 and
        self.open_wire_count == 0;
    return self.core.closeOutcome(complete);
}

/// Advance close without waiting. The outer step owns the readiness park.
pub fn progressClose(self: *HostRuntime, effect_mode: ExternalEffectMode) !void {
    try progressRetirement(self);
    if (self.close_effects_pending) {
        self.close_effects_pending = false;
        Internal.closeOwnedListeners(self);
        cancelPendingListenerSetups(self);
    }
    if (self.core.lifecyclePhase() == .active) return;
    if (self.core.lifecyclePhase() != .closed)
        try self.core.progressClose(net.clock.nowMs(self.io));
    if (self.core.lifecyclePhase() == .terminating or self.core.lifecyclePhase() == .closed)
        cancelPendingRuntimeWork(self);
    try Internal.drainActionsWith(self, effect_mode);
    if (effect_mode == .operational) try Internal.advancePendingOpens(self);
    if (self.core.lifecyclePhase() == .terminating or self.core.lifecyclePhase() == .closed)
        cancelPendingRuntimeWork(self);
    try Internal.drainActionsWith(self, effect_mode);
}

fn cancelPendingRuntimeWork(self: *HostRuntime) void {
    while (self.pending_opens.pop()) |row| {
        const outcome = row.outcome;
        var discarded = Internal.discardPendingOpen(self, row);
        switch (outcome) {
            .operation => |observation| {
                var failure = OperationFailure.fromError(error.Canceled);
                if (discarded.cleanup) |cleanup| failure.noteChain(cleanup);
                Internal.reportObservedOperationFailure(self, observation.observer, observation.tag, failure);
            },
            .listener_accept => |observation| {
                if (discarded.cleanup) |cleanup| Internal.noteTerminalFailureChain(self, cleanup);
                observation.observer.abandoned(observation.observer.ctx, observation.tag);
            },
            .redeem => {},
        }
        discarded.admission.release();
    }
    cancelPendingListenerSetups(self);
}

fn cancelPendingListenerSetups(self: *HostRuntime) void {
    while (self.pending_listeners.items.len != 0)
        Internal.failPendingListener(self, self.pending_listeners.items[self.pending_listeners.items.len - 1], error.Canceled);
}

pub fn deinit(self: *HostRuntime) void {
    _ = deinitOutcome(self);
}

pub fn deinitOutcome(self: *HostRuntime) ?OperationFailure {
    deinitImpl(self, true);
    return self.terminal_failure;
}

pub fn deinitAfterFailedAdoption(self: *HostRuntime) void {
    std.debug.assert(!self.owns_core);
    deinitImpl(self, false);
}

fn deinitImpl(self: *HostRuntime, cancel_core: bool) void {
    std.debug.assert(self.driver_depth == 0);
    std.debug.assert(self.deferred_session_releases == null);
    if (cancel_core) beginClose(self, .cancel);
    Internal.closeOwnedListeners(self);
    Internal.detachClosingListeners(self);
    for (self.pending_opens.items) |row| switch (row.stage) {
        .resident_dial => {
            if (row.stage.resident_dial.attempt.deinit()) |failure| Internal.noteTerminalFailureChain(self, failure);
            if (Internal.releaseCoreSession(self, row.session)) |failure| Internal.noteTerminalFailureChain(self, failure);
        },
        .handshake => {},
    };
    var wires = self.wires.valueIterator();
    while (wires.next()) |wire_slot| {
        const wire = wire_slot.*;
        const session = wire.session;
        if (wire.session_handle_claimed) {
            std.debug.assert(self.claimed_session_handles != 0);
            self.claimed_session_handles -= 1;
        }
        Internal.forceWireCarrierClose(self, wire);
        Internal.freeWire(self, wire);
        if (Internal.releaseCoreSession(self, session)) |failure| Internal.noteTerminalFailureChain(self, failure);
    }
    while (self.retiring_wires) |wire| Internal.forceWireCarrierClose(self, wire);
    std.debug.assert(self.open_wire_count == 0);
    std.debug.assert(self.claimed_session_handles == 0);
    self.wires.deinit(self.allocator);
    self.resident_wires.deinit(self.allocator);
    self.allocator.free(self.resident_read_scratch);
    self.pending_resident_dials.deinit(self.allocator);
    for (self.pending_opens.items) |row| {
        switch (row.outcome) {
            .operation => |observation| observation.observer.release(observation.observer.ctx, observation.tag),
            .listener_accept => |observation| observation.observer.release(observation.observer.ctx, observation.tag),
            .redeem => {},
        }
        row.admission.release();
        self.allocator.destroy(row);
    }
    self.pending_opens.deinit(self.allocator);
    std.debug.assert(self.open_admissions == 0);
    for (self.pending_listeners.items) |row| {
        if (row.attempt.deinit()) |failure| Internal.noteTerminalFailureChain(self, failure);
        Internal.releaseListenerProfile(self, row.transport);
        row.observation.observer.abandoned(row.observation.observer.ctx, row.observation.tag);
        self.allocator.destroy(row);
    }
    self.pending_listeners.deinit(self.allocator);
    self.active_listeners.deinit(self.allocator);
    self.listener_profiles.deinit(self.allocator);
    var listeners = self.resident_listeners.valueIterator();
    while (listeners.next()) |listener| if (listener.listener.stopListen()) |failure|
        Internal.noteTerminalFailureChain(self, failure);
    self.resident_listeners.deinit(self.allocator);
    self.residents.deinit(self.allocator);
    self.providers.deinit(self.allocator);
    var package_index = self.provider_packages.items.len;
    while (package_index != 0) {
        package_index -= 1;
        if (self.provider_packages.items[package_index].deinit(self.allocator)) |failure|
            self.noteTerminalOperationFailure(failure);
    }
    self.provider_packages.deinit(self.allocator);
    self.poll_scratch.deinit(self.allocator);
    self.extra_fd_scratch.deinit(self.allocator);
    self.listener_fds.deinit(self.allocator);
    if (self.mailbox) |mailbox| mailbox.deinit();
    self.drive.deinit();
    if (self.owns_core) {
        if (self.core.deinitOutcome()) |failure| self.noteTerminalFailure(failure);
        self.allocator.destroy(self.core);
    }
}
