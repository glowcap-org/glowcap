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
/// Bounded providers may call `ready` before this returns; providers that
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
    try Internal.admitApplicationOperation(self);
    const provider = Internal.providerFor(self, transport) orelse return Error.UnknownTransport;
    switch (provider.source) {
        .stream => |nl| if (!nl.supportsListen()) return Error.UnknownTransport,
        .resident => |index| if (self.residents.items[index].resident.acceptor() == null)
            return Error.UnknownTransport,
    }
    try observer.reserve(observer.ctx, tag);
    var observation_owned = true;
    errdefer if (observation_owned) observer.release(observer.ctx, tag);
    try Internal.reserveListenerProfile(self, provider.transport);
    var profile_owned = true;
    errdefer if (profile_owned) Internal.releaseListenerProfile(self, provider.transport);
    const observation = ListenerObservation{ .observer = observer, .tag = tag };

    switch (provider.source) {
        .stream => |nl| {
            const config = net.netlayer.ListenConfig{
                .designator = requested_designator,
                .identity = self.core.node.publicKey(),
                .options = options,
            };
            const result = switch (nl.listen(self.allocator, config)) {
                .admitted => |result| result,
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
                        .designator_scheme = nl.designatorScheme(),
                        .source = .{ .stream = .{ .handle = listener } },
                    });
                    return;
                },
                .pending => {},
            }
            var attempt = result.pending;
            const fd = attempt.readinessFd();
            if (fd < 0 or Internal.descriptorInUse(self, fd)) {
                Internal.releaseListenerProfile(self, provider.transport);
                profile_owned = false;
                observation_owned = false;
                Internal.reportListenAttemptFailure(self, observer, tag, &attempt, if (fd < 0)
                    error.ReadinessUnavailable
                else
                    error.ReadinessDescriptorConflict);
                return;
            }
            const row = self.allocator.create(PendingListener) catch |err| {
                Internal.releaseListenerProfile(self, provider.transport);
                profile_owned = false;
                observation_owned = false;
                Internal.reportListenAttemptFailure(self, observer, tag, &attempt, err);
                return;
            };
            self.pending_listeners.ensureUnusedCapacity(self.allocator, 1) catch |err| {
                self.allocator.destroy(row);
                Internal.releaseListenerProfile(self, provider.transport);
                profile_owned = false;
                observation_owned = false;
                Internal.reportListenAttemptFailure(self, observer, tag, &attempt, err);
                return;
            };
            switch (self.drive) {
                .blocking => {},
                .stepped => |*stepped| stepped.ready_set.add(fd) catch |err| {
                    self.allocator.destroy(row);
                    Internal.releaseListenerProfile(self, provider.transport);
                    profile_owned = false;
                    observation_owned = false;
                    Internal.reportListenAttemptFailure(self, observer, tag, &attempt, err);
                    return;
                },
            }
            row.* = .{
                .stage = .{ .stream = attempt.take() },
                .transport = provider.transport,
                .designator_scheme = nl.designatorScheme(),
                .deadline_ms = listenerSetupDeadline(self),
                .observation = observation,
            };
            self.pending_listeners.appendAssumeCapacity(row);
            profile_owned = false;
            observation_owned = false;
        },
        .resident => |index| {
            const runtime = &self.residents.items[index];
            const acceptor = runtime.resident.acceptor().?;
            const route_id = Internal.mintRuntimeId(&runtime.next_listener_route) catch |err| {
                Internal.releaseListenerProfile(self, provider.transport);
                profile_owned = false;
                observation_owned = false;
                Internal.reportObservedFailure(self, observer, tag, err);
                return;
            };
            const host_designator = self.core.node.publicKey().toDesignator();
            const effective_designator: []const u8 = if (requested_designator.len == 0 and
                provider.designator_scheme == .key)
                &host_designator
            else
                requested_designator;
            var result = switch (acceptor.listen(
                route_id,
                provider.transport,
                effective_designator,
                options,
            )) {
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
                        .source = .{ .resident = .{ .runtime = index, .listener = listener } },
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
                        .stage = .{ .resident = .{
                            .attempt = pending.*,
                            .resident = index,
                        } },
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
        },
    }
}

/// Explicitly blocking native convenience over `startListener`. Product
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
        .ms => |v| net.clock.nowMs(self.io) + v,
    };
}

/// Cancel one admitted listener setup. Active listeners are owned by the
/// caller and close through `closeListener`; this method names only the
/// pending construction state.
pub fn cancelListener(self: *HostRuntime, tag: u64) ListenerStopOutcome {
    for (self.pending_listeners.items, 0..) |row, i| {
        if (row.observation.tag != tag) continue;
        std.debug.assert(self.pending_listeners.swapRemove(i) == row);
        var failure: ?OperationFailure = null;
        switch (row.stage) {
            .stream => |*attempt| {
                Internal.removeReadyFd(self, attempt.readinessFd());
                if (attempt.deinit()) |cleanup|
                    failure = OperationFailure.fromChain(cleanup);
            },
            .resident => |*pending| {
                if (pending.attempt.deinit()) |cleanup|
                    failure = OperationFailure.fromChain(cleanup);
            },
        }
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
    const listener: TransportListener = switch (row.stage) {
        .stream => |*attempt| blk: {
            Internal.removeReadyFd(self, attempt.readinessFd());
            const stream = switch (attempt.finish(self.allocator)) {
                .ready => |listener| listener,
                .failed => |failure| {
                    Internal.releaseListenerProfile(self, transport);
                    self.allocator.destroy(row);
                    Internal.reportObservedFailureChain(self, observation.observer, observation.tag, failure);
                    return;
                },
            };
            break :blk .{
                .transport = transport,
                .designator_scheme = designator_scheme,
                .source = .{ .stream = .{ .handle = stream } },
            };
        },
        .resident => |*pending| blk: {
            const resident_listener = switch (pending.attempt.finish()) {
                .ready => |listener| listener,
                .failed => |failure| {
                    Internal.releaseListenerProfile(self, transport);
                    self.allocator.destroy(row);
                    Internal.reportObservedFailureChain(self, observation.observer, observation.tag, failure);
                    return;
                },
            };
            break :blk .{
                .transport = transport,
                .designator_scheme = designator_scheme,
                .source = .{ .resident = .{
                    .runtime = pending.resident,
                    .listener = resident_listener,
                } },
            };
        },
    };
    self.allocator.destroy(row);
    observation.observer.ready(observation.observer.ctx, observation.tag, listener);
}

pub fn failPendingListener(self: *HostRuntime, row: *PendingListener, err: anyerror) void {
    removePendingListener(self, row);
    var failure = net.netlayer.ListenFailure.init(err);
    switch (row.stage) {
        .stream => |*attempt| {
            Internal.removeReadyFd(self, attempt.readinessFd());
            if (attempt.deinit()) |cleanup| failure.noteChain(cleanup);
        },
        .resident => |*pending| if (pending.attempt.deinit()) |cleanup| failure.noteChain(cleanup),
    }
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
    for (self.pending_listeners.items) |row| switch (row.stage) {
        .resident => |pending| if (pending.resident == resident and pending.attempt.id() == route)
            return row,
        .stream => {},
    };
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
    const now = net.clock.nowMs(self.io);
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
