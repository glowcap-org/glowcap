//! Staged listener construction, cancellation, and outcome publication.
//!
//! One pending row owns its provider attempt, profile reservation, and observer
//! seat until exactly one ready, failed, or abandoned outcome consumes them.

const std = @import("std");

const net = @import("net");
const driver_core = @import("driver_core");

const pending_state = @import("pending.zig");
const host_runtime = @import("../host_runtime.zig");
const OperationFailure = @import("../operation_failure.zig").OperationFailure;

const HostRuntime = host_runtime.HostRuntime;
const Internal = host_runtime.Internal;
const Error = driver_core.Error;
const ListenerObserver = HostRuntime.ListenerObserver;
const ListenerStopOutcome = HostRuntime.ListenerStopOutcome;
const TransportListener = HostRuntime.TransportListener;
const ListenerObservation = pending_state.ListenerObservation;
const PendingListener = pending_state.Listener;

/// Begin one listener construction through the generic runtime seam.
/// Bounded providers may call `ready` before this returns. Providers that
/// wait on external progress retain one pending attempt driven by
/// `stepAny`. Once observation is reserved, every provider outcome is
/// reported exactly once through `ready` or `failed`.
pub fn startListener(
    self: *HostRuntime,
    transport: []const u8,
    requested_designator: []const u8,
    options: net.OperationOptions,
    tag: u64,
    observer: ListenerObserver,
) !void {
    self.enterDriver();
    defer self.leaveDriver();
    try Internal.admitApplicationOperation(self);
    const provider = Internal.providerFor(self, transport) orelse return Error.UnknownTransport;
    if (self.residents.items[provider.resident].resident.acceptor() == null)
        return Error.UnknownTransport;
    try observer.reserve(observer.ctx, tag);
    var observation_owned = true;
    errdefer if (observation_owned) observer.release(observer.ctx, tag);
    try Internal.reserveListenerProfile(self, provider.transport);
    var profile_owned = true;
    errdefer if (profile_owned) Internal.releaseListenerProfile(self, provider.transport);
    const observation = ListenerObservation{ .observer = observer, .tag = tag };

    const index = provider.resident;
    const runtime = &self.residents.items[index];
    const acceptor = runtime.resident.acceptor().?;
    const route_id = Internal.mintRuntimeId(&runtime.next_listener_route) catch |err| {
        Internal.releaseListenerProfile(self, provider.transport);
        profile_owned = false;
        observation_owned = false;
        Internal.reportObservedFailure(self, observer, tag, err);
        return;
    };
    var result = switch (acceptor.listen(route_id, provider.transport, .{
        .designator = requested_designator,
        .identity = self.core.node.publicKey(),
        .options = options,
    })) {
        .admitted => |admitted| admitted,
        .failed => |failure| {
            Internal.releaseListenerProfile(self, provider.transport);
            profile_owned = false;
            observation_owned = false;
            Internal.reportObservedFailureChain(self, observer, tag, failure);
            return;
        },
    };
    switch (result) {
        .ready => |listener| {
            profile_owned = false;
            observation_owned = false;
            observer.ready(observer.ctx, tag, .{
                .transport = provider.transport,
                .designator_scheme = provider.designator_scheme,
                .resident = index,
                .listener = listener,
            });
        },
        .pending => |*pending| {
            defer if (pending.deinit()) |failure| Internal.noteTerminalFailureChain(self, failure);
            const row = self.allocator.create(PendingListener) catch |err| {
                Internal.releaseListenerProfile(self, provider.transport);
                profile_owned = false;
                observation_owned = false;
                Internal.reportObservedFailure(self, observer, tag, err);
                return;
            };
            self.pending_listeners.ensureUnusedCapacity(self.allocator, 1) catch |err| {
                self.allocator.destroy(row);
                Internal.releaseListenerProfile(self, provider.transport);
                profile_owned = false;
                observation_owned = false;
                Internal.reportObservedFailure(self, observer, tag, err);
                return;
            };
            row.* = .{
                .attempt = pending.*,
                .resident = index,
                .transport = provider.transport,
                .designator_scheme = provider.designator_scheme,
                .deadline_ms = listenerSetupDeadline(self),
                .observation = observation,
            };
            pending.route_id = null;
            self.pending_listeners.appendAssumeCapacity(row);
            profile_owned = false;
            observation_owned = false;
        },
    }
}

/// Explicitly blocking Zig convenience over `startListener`. Product
/// loops and bindings use the staged operation directly.
pub fn bindListener(
    self: *HostRuntime,
    transport: []const u8,
    requested_designator: []const u8,
    options: net.OperationOptions,
) !TransportListener {
    const Capture = struct {
        listener: ?TransportListener = null,
        failure: ?anyerror = null,

        fn ready(ctx: *anyopaque, _: u64, listener: TransportListener) void {
            const capture: *@This() = @ptrCast(@alignCast(ctx));
            capture.listener = listener;
        }

        fn failed(ctx: *anyopaque, _: u64, failure: OperationFailure) void {
            const capture: *@This() = @ptrCast(@alignCast(ctx));
            capture.failure = failure.cause;
        }
    };
    var capture: Capture = .{};
    errdefer if (capture.listener) |*listener| {
        if (self.closeListener(listener)) |failure| self.noteTerminalOperationFailure(failure);
    } else cancelListenerObserver(self, &capture);
    try startListener(self, transport, requested_designator, options, 0, .{
        .ctx = &capture,
        .ready = Capture.ready,
        .failed = Capture.failed,
    });
    while (capture.listener == null and capture.failure == null) _ = try self.stepAny(-1);
    if (capture.failure) |err| return err;
    return capture.listener.?;
}

fn cancelListenerObserver(self: *HostRuntime, observer_ctx: *anyopaque) void {
    for (self.pending_listeners.items) |row| {
        if (row.observation.observer.ctx != observer_ctx) continue;
        failPendingListener(self, row, error.Canceled);
        return;
    }
}

fn listenerSetupDeadline(self: *const HostRuntime) ?i64 {
    return switch (self.opts.listener_setup) {
        .unbounded => null,
        .ms => |v| self.nowMs() + v,
    };
}

/// Cancel one admitted listener setup. Active listeners are owned by the
/// caller and close through `closeListener`. This method names only the
/// pending construction state.
pub fn cancelListener(self: *HostRuntime, tag: u64) ListenerStopOutcome {
    for (self.pending_listeners.items, 0..) |row, i| {
        if (row.observation.tag != tag) continue;
        std.debug.assert(self.pending_listeners.swapRemove(i) == row);
        const failure: ?OperationFailure = if (row.attempt.deinit()) |cleanup| .fromChain(cleanup) else null;
        const observation = row.observation;
        Internal.releaseListenerProfile(self, row.transport);
        self.allocator.destroy(row);
        observation.observer.abandoned(observation.observer.ctx, tag);
        return .{ .found = true, .failure = failure };
    }
    return .{ .found = false };
}

pub fn finishPendingListener(self: *HostRuntime, row: *PendingListener) void {
    removePendingListener(self, row);
    const transport = row.transport;
    const designator_scheme = row.designator_scheme;
    const observation = row.observation;
    const resident_listener = switch (row.attempt.finish()) {
        .ready => |listener| listener,
        .failed => |failure| {
            Internal.releaseListenerProfile(self, transport);
            self.allocator.destroy(row);
            Internal.reportObservedFailureChain(self, observation.observer, observation.tag, failure);
            return;
        },
    };
    const listener: TransportListener = .{
        .transport = transport,
        .designator_scheme = designator_scheme,
        .resident = row.resident,
        .listener = resident_listener,
    };
    self.allocator.destroy(row);
    observation.observer.ready(observation.observer.ctx, observation.tag, listener);
}

pub fn failPendingListener(self: *HostRuntime, row: *PendingListener, err: anyerror) void {
    removePendingListener(self, row);
    var failure = net.netlayer.ListenFailure.init(err);
    if (row.attempt.deinit()) |cleanup| failure.noteChain(cleanup);
    const observation = row.observation;
    Internal.releaseListenerProfile(self, row.transport);
    self.allocator.destroy(row);
    Internal.reportObservedFailureChain(self, observation.observer, observation.tag, failure);
}

pub fn pendingResidentListener(
    self: *HostRuntime,
    resident: usize,
    route: usize,
) ?*PendingListener {
    for (self.pending_listeners.items) |row| {
        if (row.resident == resident and row.attempt.id() == route) return row;
    }
    return null;
}

fn removePendingListener(self: *HostRuntime, row: *PendingListener) void {
    for (self.pending_listeners.items, 0..) |candidate, i| {
        if (candidate != row) continue;
        std.debug.assert(self.pending_listeners.swapRemove(i) == row);
        return;
    }
    unreachable;
}

pub fn advancePendingListeners(self: *HostRuntime) void {
    const now = self.nowMs();
    var i: usize = 0;
    while (i < self.pending_listeners.items.len) {
        const row = self.pending_listeners.items[i];
        if (row.deadline_ms) |deadline| {
            if (now >= deadline) {
                failPendingListener(self, row, error.ListenerSetupTimedOut);
                continue;
            }
        }
        i += 1;
    }
}
