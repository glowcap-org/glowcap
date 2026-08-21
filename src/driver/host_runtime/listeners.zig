//! Active listener publication, locator authority, accepts, and retirement.
//!
//! The Runtime owns profile occupancy and every active transport handle.
//! Observer seats are reserved before publication and consumed exactly once by
//! explicit retirement or a terminal listener failure.

const std = @import("std");

const model = @import("model");
const net = @import("net");
const driver_core = @import("driver_core");

const resident_state = @import("resident.zig");
const host_runtime = @import("../host_runtime.zig");
const OperationFailure = @import("../operation_failure.zig").OperationFailure;

const HostRuntime = host_runtime.HostRuntime;
const Internal = host_runtime.Internal;
const Error = driver_core.Error;
const ResidentListenerKey = resident_state.ListenerKey;
const ListenerStopOutcome = HostRuntime.ListenerStopOutcome;
const PrepareListenerLocatorOutcome = HostRuntime.PrepareListenerLocatorOutcome;
const PreparedListenerLocator = HostRuntime.PreparedListenerLocator;
const SessionAcceptObserver = HostRuntime.SessionAcceptObserver;
const SessionAcceptObservation = @import("lifecycle.zig").SessionAcceptObservation;
const TransportListener = HostRuntime.TransportListener;

pub fn reserveListenerProfile(self: *HostRuntime, transport: []const u8) !void {
    if (self.listener_profiles.contains(transport)) return Error.ListenerProfileInUse;
    try self.listener_profiles.ensureUnusedCapacity(self.allocator, 1);
    self.listener_profiles.putAssumeCapacity(transport, {});
}

pub fn releaseListenerProfile(self: *HostRuntime, transport: []const u8) void {
    std.debug.assert(self.listener_profiles.remove(transport));
}

/// Transfer a stream listener out of Runtime ownership. The raw listener's
/// owner becomes responsible for uniqueness above this Runtime.
pub fn takeStreamListener(self: *HostRuntime, listener: *TransportListener) ?net.netlayer.Listener {
    const transport = listener.transportName();
    const stream = listener.takeStream() orelse return null;
    releaseListenerProfile(self, transport);
    return stream;
}

/// Materialize the complete locator an active listener publishes. The
/// provider owns transport-specific hints; the driver validates the
/// dispatch symbol and takes ownership of the returned model value.
pub fn listenerLocatorOutcome(
    self: *const HostRuntime,
    listener: *const TransportListener,
) net.netlayer.ListenerLocatorOutcome {
    const outcome = switch (listener.source) {
        .stream => |stream| stream.handle.localLocatorOutcome(self.allocator),
        .resident => |resident| resident.listener.localLocatorOutcome(self.allocator),
    };
    const locator = switch (outcome) {
        .locator => |locator| locator,
        .failed => |failure| return .{ .failed = failure },
    };
    if (!std.mem.eql(u8, locator.transport, listener.transportName()) or locator.designator.len == 0) {
        model.freePeerLocator(self.allocator, locator);
        return .{ .failed = .init(error.ProviderContract) };
    }
    return .{ .locator = locator };
}

/// Query or copy opaque provider state that restores this listener's local
/// transport address. Null means the transport has no restoration state;
/// otherwise the result is the complete size and a short output is untouched.
pub fn listenerRestorationStateOutcome(
    self: *const HostRuntime,
    listener: *const TransportListener,
    out: []u8,
) net.netlayer.ListenerRestorationOutcome {
    _ = self;
    return switch (listener.source) {
        .stream => |stream| stream.handle.restorationStateOutcome(out),
        .resident => |resident| resident.listener.restorationStateOutcome(out),
    };
}

/// Validate and canonicalize a replacement locator through the provider
/// that owns this active listener. The caller owns the returned value.
pub fn canonicalizeListenerLocatorOutcome(
    self: *const HostRuntime,
    listener: *const TransportListener,
    locator: model.PeerLocator,
) net.netlayer.ListenerLocatorOutcome {
    Internal.admitApplicationOperation(self) catch |err| return .{ .failed = .init(err) };
    const outcome = switch (listener.source) {
        .stream => |stream| stream.handle.canonicalizeLocatorOutcome(self.allocator, locator),
        .resident => |resident| resident.listener.canonicalizeLocatorOutcome(self.allocator, locator),
    };
    const canonical = switch (outcome) {
        .locator => |canonical| canonical,
        .failed => |failure| return .{ .failed = failure },
    };
    if (!std.mem.eql(u8, canonical.transport, listener.transportName()) or canonical.designator.len == 0) {
        model.freePeerLocator(self.allocator, canonical);
        return .{ .failed = .init(error.ProviderContract) };
    }
    return .{ .locator = canonical };
}

/// Publish the caller's listener observation after all fallible
/// caller-owned state has been reserved. From here every admitted accept
/// retains the exact callback that owns its outcome.
pub fn activateListener(
    self: *HostRuntime,
    listener: *TransportListener,
    tag: u64,
    observer: SessionAcceptObserver,
) !void {
    const observation = SessionAcceptObservation{ .observer = observer, .tag = tag };
    // One publication right lives with the active listener. Accepted
    // sessions reserve independently; this seat is consumed only by the
    // listener's terminal failure and released by an explicit close.
    try observer.reserve(observer.ctx, tag);
    errdefer observer.release(observer.ctx, tag);
    switch (listener.source) {
        .stream => |*stream| {
            std.debug.assert(stream.observation == null);
            if (stream.handle.readinessFd()) |fd| try self.watchFd(fd);
            stream.observation = observation;
        },
        .resident => |index| {
            const key = ResidentListenerKey{
                .resident = index.runtime,
                .route = index.listener.route_id,
            };
            if (self.resident_listeners.contains(key)) return error.ListenerAlreadyActive;
            try self.resident_listeners.ensureUnusedCapacity(self.allocator, 1);
            self.resident_listeners.putAssumeCapacity(key, .{
                .listener = index.listener,
                .transport = listener.transport,
                .observation = observation,
            });
        },
    }
}

/// Prepare the exact complete locator this listener will publish. The
/// result is not authoritative until `activateOwnedListener` consumes it.
pub fn prepareListenerLocatorOutcome(
    self: *HostRuntime,
    listener: *const TransportListener,
) PrepareListenerLocatorOutcome {
    const local = switch (self.listenerLocatorOutcome(listener)) {
        .locator => |locator| locator,
        .failed => |failure| return .{ .failed = failure },
    };
    defer model.freePeerLocator(self.allocator, local);
    const prepared = self.core.prepareAdvertisedLocator(self.allocator, local) catch |err|
        return .{ .failed = .init(err) };
    return .{ .ready = .{ .value = prepared } };
}

/// Transfer one prepared listener and locator into Runtime ownership.
/// Runtime close stops every owned listener and removes its Host route
/// before advancing terminal Host close.
pub fn activateOwnedListener(
    self: *HostRuntime,
    listener: *TransportListener,
    prepared: *PreparedListenerLocator,
    tag: u64,
    observer: SessionAcceptObserver,
) !void {
    try Internal.admitApplicationOperation(self);
    if (self.active_listeners.contains(tag)) return error.ListenerAlreadyActive;
    if (!std.mem.eql(u8, prepared.value.transport, listener.transportName())) return error.ProviderContract;
    try self.active_listeners.ensureUnusedCapacity(self.allocator, 1);
    try self.core.retainPreparedAdvertisedLocator(prepared.value);
    errdefer self.core.retireAdvertisedLocator(prepared.value.transport);
    try self.activateListener(listener, tag, observer);
    self.active_listeners.putAssumeCapacity(tag, .{
        .transport = listener.*,
        .locator = prepared.value,
    });
    listener.* = undefined;
    prepared.* = undefined;
}

pub fn ownedListenerLocator(self: *const HostRuntime, tag: u64) ?model.PeerLocator {
    return (self.active_listeners.get(tag) orelse return null).locator;
}

pub fn ownedListenerRestorationStateOutcome(
    self: *const HostRuntime,
    tag: u64,
    out: []u8,
) net.netlayer.ListenerRestorationOutcome {
    Internal.admitApplicationOperation(self) catch |err| return .{ .failed = .init(err) };
    const listener = self.active_listeners.get(tag) orelse
        return .{ .failed = .init(error.ListenerNotActive) };
    return self.listenerRestorationStateOutcome(&listener.transport, out);
}

/// Prepare a replacement locator through the owning provider and Host
/// profile. Commit is separate so an adapter can reserve its projection
/// before the authoritative route changes.
pub fn prepareOwnedListenerAdvertisementOutcome(
    self: *HostRuntime,
    tag: u64,
    locator: model.PeerLocator,
) PrepareListenerLocatorOutcome {
    const listener = self.active_listeners.get(tag) orelse
        return .{ .failed = .init(error.ListenerNotActive) };
    const canonical = switch (self.canonicalizeListenerLocatorOutcome(&listener.transport, locator)) {
        .locator => |canonical| canonical,
        .failed => |failure| return .{ .failed = failure },
    };
    defer model.freePeerLocator(self.allocator, canonical);
    const prepared = self.core.prepareAdvertisedLocator(self.allocator, canonical) catch |err|
        return .{ .failed = .init(err) };
    return .{ .ready = .{ .value = prepared } };
}

pub fn commitOwnedListenerAdvertisement(
    self: *HostRuntime,
    tag: u64,
    prepared: *PreparedListenerLocator,
) !void {
    try Internal.admitApplicationOperation(self);
    const listener = self.active_listeners.getPtr(tag) orelse return error.ListenerNotActive;
    if (!std.mem.eql(u8, listener.transport.transportName(), prepared.value.transport))
        return error.ProviderContract;
    try self.core.retainPreparedAdvertisedLocator(prepared.value);
    model.freePeerLocator(self.allocator, listener.locator);
    listener.locator = prepared.value;
    prepared.* = undefined;
}

pub fn selectOwnedListener(self: *HostRuntime, tag: u64) !bool {
    try Internal.admitApplicationOperation(self);
    const listener = self.active_listeners.get(tag) orelse return error.ListenerNotActive;
    return self.core.selectAdvertisedLocator(listener.transport.transportName());
}

/// Stop and remove one Runtime-owned listener. Sessions already yielded
/// through its observer remain owned by their session handles.
pub fn closeActiveListener(self: *HostRuntime, tag: u64, async_completion: bool) ListenerStopOutcome {
    const active = self.active_listeners.getPtr(tag) orelse return .{ .found = false };
    if (!active.closing) {
        active.closing = true;
        self.core.retireAdvertisedLocator(active.transport.transportName());
        if (activeListenerObservation(self, &active.transport)) |observation|
            self.cancelAccepts(observation.tag);
    }
    var failure = active.terminal_failure;
    switch (active.transport.source) {
        .stream => if (closeListener(self, &active.transport)) |reported| {
            if (failure) |*primary|
                primary.noteFailure(reported)
            else
                failure = reported;
        },
        .resident => |resident| switch (resident.listener.stopListenOutcome()) {
            .pending => return .{ .found = true, .pending = true },
            .complete => {},
            .failed => |reported| {
                if (failure) |*primary|
                    primary.noteChain(reported)
                else
                    failure = OperationFailure.fromChain(reported);
            },
        },
    }
    const removed = self.active_listeners.fetchRemove(tag) orelse unreachable;
    var listener = removed.value;
    const observation = activeListenerObservation(self, &listener.transport);
    switch (listener.transport.source) {
        .stream => {},
        .resident => |resident| {
            const key = ResidentListenerKey{
                .resident = resident.runtime,
                .route = resident.listener.route_id,
            };
            std.debug.assert(self.resident_listeners.remove(key));
            releaseListenerProfile(self, listener.transport.transportName());
        },
    }
    model.freePeerLocator(self.allocator, listener.locator);
    if (observation) |value| {
        if (async_completion and failure != null)
            value.observer.failed(value.observer.ctx, value.tag, failure.?)
        else
            value.observer.retired(value.observer.ctx, value.tag);
    } else if (failure) |unclaimed| {
        Internal.retainAndReportUnhandledFailure(self, unclaimed);
    }
    return .{ .found = true, .failure = failure };
}

fn activeListenerObservation(self: *const HostRuntime, listener: *const TransportListener) ?SessionAcceptObservation {
    return switch (listener.source) {
        .stream => |stream| stream.observation,
        .resident => |resident| (self.resident_listeners.get(.{
            .resident = resident.runtime,
            .route = resident.listener.route_id,
        }) orelse return null).observation,
    };
}

pub fn failActiveListener(self: *HostRuntime, tag: u64, primary: OperationFailure) void {
    const active = self.active_listeners.getPtr(tag) orelse return;
    if (active.terminal_failure) |*first| {
        first.noteFailure(primary);
    } else {
        active.terminal_failure = primary;
    }
    const outcome = closeActiveListener(self, tag, true);
    std.debug.assert(outcome.found);
}

/// Stop a listener operation by its Runtime tag, whether setup is still
/// pending or the listener is active. The observer receives cancellation
/// for a pending setup; an active listener is removed synchronously.
pub fn stopOwnedListener(self: *HostRuntime, tag: u64) ListenerStopOutcome {
    const active = closeActiveListener(self, tag, false);
    if (active.found) return active;
    return self.cancelListener(tag);
}

pub fn closeOwnedListeners(self: *HostRuntime) void {
    while (true) {
        var tag: ?u64 = null;
        var it = self.active_listeners.iterator();
        while (it.next()) |entry| if (!entry.value_ptr.closing) {
            tag = entry.key_ptr.*;
            break;
        };
        const selected = tag orelse return;
        const outcome = closeActiveListener(self, selected, false);
        std.debug.assert(outcome.found);
        if (outcome.failure) |failure| self.noteTerminalOperationFailure(failure);
    }
}

/// Final destruction has no event recipient to drive a readiness-backed
/// listener stop. The provider package remains the asynchronous cleanup
/// authority and joins it during release; detach only Runtime/C metadata
/// here after the stop request has been committed.
pub fn detachClosingListeners(self: *HostRuntime) void {
    while (self.active_listeners.count() != 0) {
        var it = self.active_listeners.keyIterator();
        const tag = (it.next() orelse unreachable).*;
        const removed = self.active_listeners.fetchRemove(tag) orelse unreachable;
        var listener = removed.value;
        std.debug.assert(listener.closing);
        const observation = activeListenerObservation(self, &listener.transport);
        switch (listener.transport.source) {
            .stream => unreachable,
            .resident => |resident| {
                std.debug.assert(self.resident_listeners.remove(.{
                    .resident = resident.runtime,
                    .route = resident.listener.route_id,
                }));
                releaseListenerProfile(self, listener.transport.transportName());
            },
        }
        model.freePeerLocator(self.allocator, listener.locator);
        if (observation) |value| value.observer.retired(value.observer.ctx, value.tag);
    }
}

/// Stage every stream accept currently ready. Multiplexed accepts are drained
/// by `serviceResident` and therefore require no caller-side branch.
pub fn acceptReady(self: *HostRuntime, listener: *TransportListener) !usize {
    const stream = switch (listener.source) {
        .stream => |value| value,
        .resident => return 0,
    };
    const observation = stream.observation orelse return error.ListenerNotActive;
    if (!Internal.pendingOpenSlotAvailable(self)) return 0;
    const acceptable = switch (stream.handle.waitAcceptableOutcome(0)) {
        .ready => |ready| ready,
        .failed => |failure| {
            failActiveListener(self, observation.tag, OperationFailure.fromAcceptFailure(failure));
            return 0;
        },
    };
    if (!acceptable) return 0;
    try self.startAcceptWire(stream.handle, listener.transport, observation.tag, observation.observer);
    return 1;
}

pub fn closeListener(self: *HostRuntime, listener: *TransportListener) ?OperationFailure {
    const transport = listener.transportName();
    const had_terminal_failure = self.terminal_failure != null;
    var failure: ?OperationFailure = null;
    switch (listener.source) {
        .stream => |stream| {
            if (stream.observation) |observation| self.cancelAccepts(observation.tag);
            if (stream.handle.readinessFd()) |fd| self.unwatchFd(fd);
            if (!had_terminal_failure and self.terminal_failure != null)
                failure = self.terminal_failure;
            if (stream.handle.close()) |close_failure| {
                if (failure) |*first| {
                    first.noteChain(close_failure);
                    Internal.noteTerminalFailureChain(self, close_failure);
                } else {
                    failure = OperationFailure.fromChain(close_failure);
                }
            }
        },
        .resident => |resident| {
            const key = ResidentListenerKey{
                .resident = resident.runtime,
                .route = resident.listener.route_id,
            };
            if (self.resident_listeners.fetchRemove(key)) |removed| {
                std.debug.assert(std.mem.eql(u8, removed.value.transport, listener.transport));
                self.cancelAccepts(removed.value.observation.tag);
            }
            if (resident.listener.stopListen()) |cleanup| {
                if (failure) |*first|
                    first.noteChain(cleanup)
                else
                    failure = OperationFailure.fromChain(cleanup);
            }
        },
    }
    releaseListenerProfile(self, transport);
    return failure;
}
