//! The native relay archive's multiplexed runtime adapter.
//!
//! This module owns readiness, cancellation, and teardown while adapting the
//! native blocking relay carrier to the generic C multiplexed-provider table.
//! It moves opaque WebSocket bytes only. The archive facade owns exported C
//! handles; CapTP framing and Noise_XK remain Host policy.

const std = @import("std");

const foundation = @import("foundation");
const crypto = foundation.crypto;
const model = @import("model");
const net = @import("net");
const c = @import("c_abi_shared");
const native_relay = @import("native_relay");
const connection_state = @import("../connection/state.zig");
const contract = @import("../contract.zig");
const dial_lifecycle = @import("../dial/lifecycle.zig");
const dial_state = @import("../dial/state.zig");
const failure_projection = @import("../failure/projection.zig");
const failure_state = @import("../failure/state.zig");
const listener_state = @import("../listener/state.zig");
const multiplexed_projection = @import("../multiplexed/projection.zig");
const reactor_state = @import("../reactor/state.zig");
const reactor = @import("../reactor/mod.zig");
const runtime_lifecycle = @import("lifecycle.zig");

const PANCAKE_OK = c.PANCAKE_OK;
const PANCAKE_ERR_NULL_POINTER = c.PANCAKE_ERR_NULL_POINTER;
const PANCAKE_ERR_CLOSED = c.PANCAKE_ERR_CLOSED;

const multiplexed = c.multiplexed_transport;

const EV_CLOSED = multiplexed.PANCAKE_MULTIPLEXED_EV_CLOSED;
const EV_ACCEPT = multiplexed.PANCAKE_MULTIPLEXED_EV_ACCEPT;
const EV_CONNECT = multiplexed.PANCAKE_MULTIPLEXED_EV_CONNECT;
const EV_LISTEN = multiplexed.PANCAKE_MULTIPLEXED_EV_LISTEN;

const PancakeRelayConfig = contract.PancakeRelayConfig;
const Profile = contract.Profile;
const profile_count = contract.profile_count;
const profileMetadata = contract.metadata;
const profileForTransport = contract.forTransport;

pub const Payload = struct {
    threaded: std.Io.Threaded,
    allocator: std.mem.Allocator,
    references: std.atomic.Value(usize),
    native: native_relay.Provider,
    runtime: MultiplexedRuntime,
    profile_abi: [profile_count]c.PancakeTransportProfile,
    entries: [profile_count]c.PancakeTransportProviderEntry,
    multiplexed_transport: c.PancakeMultiplexedTransport,
    provider: c.PancakeTransportProvider,

    pub fn io(self: *Payload) std.Io {
        return self.threaded.io();
    }

    pub fn initProvider(self: *Payload) void {
        self.profile_abi[@backingInt(Profile.keyed)] =
            c.transport_provider.profileFromMetadata(profileMetadata(.keyed));
        self.profile_abi[@backingInt(Profile.noise)] =
            c.transport_provider.profileFromMetadata(profileMetadata(.noise));
        self.multiplexed_transport = MultiplexedProjection.transport(&self.runtime);
        self.entries[@backingInt(Profile.keyed)] = .{
            .profile = &self.profile_abi[@backingInt(Profile.keyed)],
            .execution_model = c.transport_provider.PANCAKE_TRANSPORT_EXEC_MULTIPLEXED,
            .implementation = &self.multiplexed_transport,
        };
        self.entries[@backingInt(Profile.noise)] = .{
            .profile = &self.profile_abi[@backingInt(Profile.noise)],
            .execution_model = c.transport_provider.PANCAKE_TRANSPORT_EXEC_MULTIPLEXED,
            .implementation = &self.multiplexed_transport,
        };
        self.provider = .{
            .abi_version = c.transport_provider.PANCAKE_TRANSPORT_PROVIDER_ABI_VERSION,
            .struct_size = @sizeOf(c.PancakeTransportProvider),
            .entries = &self.entries,
            .entry_count = self.entries.len,
            .lease_ctx = self,
            .same_configuration = providerSameConfiguration,
            .retain = providerRetain,
            .release = providerRelease,
        };
    }

    fn retain(self: *Payload) bool {
        var current = self.references.load(.acquire);
        while (current != 0) {
            if (self.references.cmpxchgWeak(current, current + 1, .acq_rel, .acquire)) |observed| {
                current = observed;
            } else return true;
        }
        return false;
    }

    pub fn release(self: *Payload) ?foundation.FailureChain {
        return runtime_lifecycle.release(self);
    }

    pub fn transportProvider(self: *const Payload) c.PancakeTransportProvider {
        return self.provider;
    }

    pub fn trustSummary(self: *const Payload) contract.PancakeRelayTrustSummary {
        return runtime_lifecycle.projectTrustSummary(self.native.trustSummary());
    }
};

const ConnState = connection_state.State;

const ListenerState = listener_state.State(MultiplexedRuntime);
const ListenerSetup = listener_state.Setup(MultiplexedRuntime, ListenerState);

const DialState = dial_state.State(MultiplexedRuntime, Profile, ConnState);

const PollSubject = reactor_state.PollSubject(ListenerSetup, ListenerState, ConnState);

/// The relay rendezvous route is keyed by durable designator, not channel
/// profile, so one runtime owns one logical listener route at a time.
const ListenerSlot = reactor_state.ListenerSlot(ListenerSetup, ListenerState);

const Reactor = reactor.Machine(
    MultiplexedRuntime,
    DialState,
    ListenerSetup,
    ListenerState,
    ConnState,
    EV_ACCEPT,
    EV_CLOSED,
    EV_LISTEN,
);

const DialLifecycle = dial_lifecycle.Machine(
    MultiplexedRuntime,
    DialState,
    Reactor,
    profileForTransport,
);

const MultiplexedRuntime = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    payload: *Payload,
    control_wake: net.wake_channel.WakeChannel,
    ready_wake: net.wake_channel.WakeChannel,
    tasks: net.OperationOwner,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    failures: failure_state.State = .{},
    mutex: net.sync.SpinLock = .{},
    listener: ListenerSlot = .empty,
    next_connection: u64 = 1,
    jobs: std.ArrayList(*DialState) = .empty,
    connections: std.ArrayList(*ConnState) = .empty,
    by_id: std.AutoHashMap(u64, *ConnState),
    pollfds: std.ArrayList(std.posix.pollfd) = .empty,
    subjects: std.ArrayList(PollSubject) = .empty,

    pub fn init(self: *MultiplexedRuntime, payload: *Payload) !void {
        const control_wake = net.wake_channel.WakeChannel.open() catch
            return error.ConcurrencyUnavailable;
        errdefer control_wake.deinit();
        const ready_wake = net.wake_channel.WakeChannel.open() catch
            return error.ConcurrencyUnavailable;
        errdefer ready_wake.deinit();
        self.* = .{
            .allocator = payload.allocator,
            .io = payload.io(),
            .payload = payload,
            .control_wake = control_wake,
            .ready_wake = ready_wake,
            .tasks = undefined,
            .by_id = std.AutoHashMap(u64, *ConnState).init(payload.allocator),
        };
        errdefer self.by_id.deinit();
        self.tasks.init(self.io) catch return error.ConcurrencyUnavailable;
        errdefer self.tasks.join();
        self.thread = std.Thread.spawn(.{}, Reactor.main, .{self}) catch
            return error.ConcurrencyUnavailable;
    }

    pub fn deinit(self: *MultiplexedRuntime) ?foundation.FailureChain {
        self.retireConnections();
        self.stopping.store(true, .release);
        self.signalControl();
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }

        self.tasks.shutdown();
        self.tasks.join();

        self.mutex.lock();
        switch (self.listener) {
            .empty => {},
            .starting => |setup| {
                var failure = setup.failure;
                if (Reactor.destroyListenerSetup(self, setup)) |cleanup| {
                    if (failure) |*first| first.noteChain(cleanup) else failure = cleanup;
                }
                if (failure) |reported| self.noteCleanupFailure(reported);
            },
            .active => |listener| if (Reactor.destroyListener(self, listener)) |failure|
                self.noteCleanupFailure(failure),
        }
        self.listener = .empty;
        for (self.connections.items) |conn| {
            conn.closeAndRetain();
            if (conn.claimFailure()) |failure| self.noteCleanupFailure(failure);
            self.allocator.destroy(conn);
        }
        for (self.jobs.items) |job| Reactor.destroyDial(self, job);
        self.jobs.clearRetainingCapacity();
        self.mutex.unlock();

        self.jobs.deinit(self.allocator);
        self.connections.deinit(self.allocator);
        self.by_id.deinit();
        self.pollfds.deinit(self.allocator);
        self.subjects.deinit(self.allocator);
        self.ready_wake.deinit();
        self.control_wake.deinit();
        return self.failures.releaseOutcome();
    }

    /// Transfer every admitted connection to the reactor and wait for their
    /// close transactions together. Each connection owns its own deadline, so
    /// one stalled peer cannot serialize or strand the others. A terminal
    /// reactor failure already owns every connection's exact consequence and
    /// ends this wait; the abortive cleanup below remains the final fallback.
    fn retireConnections(self: *MultiplexedRuntime) void {
        self.mutex.lock();
        for (self.connections.items) |conn| {
            if (!conn.release_requested.swap(true, .acq_rel))
                _ = conn.events.fetchAnd(0, .acq_rel);
        }
        self.mutex.unlock();
        self.signalControl();

        while (!self.hasTerminalFailure()) {
            self.mutex.lock();
            var joined = true;
            for (self.connections.items) |conn| {
                if (!conn.release_complete.load(.acquire)) {
                    joined = false;
                    break;
                }
            }
            self.mutex.unlock();
            if (joined) return;
            std.Io.sleep(self.io, .fromMilliseconds(1), .real) catch |err| {
                self.noteFailure(err);
                return;
            };
        }
    }

    pub fn resident(self: *MultiplexedRuntime, profile: Profile) *net.relay.Resident {
        return self.payload.native.resident(profile);
    }

    pub fn signalControl(self: *MultiplexedRuntime) void {
        _ = self.control_wake.nudge() catch {
            self.noteFailure(error.WakeNudgeFailed);
        };
    }

    pub fn noteFailure(self: *MultiplexedRuntime, cause: anyerror) void {
        self.failures.noteTerminal(.init(cause));
    }

    pub fn noteCleanupFailure(self: *MultiplexedRuntime, later: foundation.FailureChain) void {
        self.failures.noteCleanup(later);
    }

    pub fn recordedFailure(self: *MultiplexedRuntime) ?foundation.FailureChain {
        return self.failures.terminalFailure();
    }

    pub fn hasTerminalFailure(self: *const MultiplexedRuntime) bool {
        return self.failures.hasTerminal();
    }

    pub fn signalReady(self: *MultiplexedRuntime) void {
        _ = self.ready_wake.nudge() catch {
            self.noteFailure(error.WakeNudgeFailed);
        };
    }

    pub fn addConnectionLocked(self: *MultiplexedRuntime, conn: *ConnState) !u64 {
        if (self.stopping.load(.acquire)) return error.Closing;
        if (self.next_connection == std.math.maxInt(u64)) return error.Closing;
        const id = self.next_connection;
        self.next_connection += 1;
        conn.id = id;
        try self.connections.append(self.allocator, conn);
        errdefer _ = self.connections.pop();
        try self.by_id.put(id, conn);
        if (conn.events.load(.acquire) != 0) self.signalReady();
        return id;
    }

    pub fn findConnectionLocked(self: *MultiplexedRuntime, id: u64) ?*ConnState {
        return self.by_id.get(id);
    }

    fn findJobLocked(self: *MultiplexedRuntime, request_id: u64) ?*DialState {
        return DialLifecycle.findLocked(self, request_id);
    }

    pub fn completeDial(self: *MultiplexedRuntime, job: *DialState, failure: net.netlayer.DialFailure) void {
        DialLifecycle.complete(self, job, failure);
    }

    pub fn startDial(self: *MultiplexedRuntime, request_id: u64, locator: model.PeerLocator) !void {
        return DialLifecycle.start(self, request_id, locator);
    }

    pub fn retireDialJob(self: *MultiplexedRuntime, job: *DialState) void {
        DialLifecycle.retire(self, job);
    }

    pub fn finishDial(self: *MultiplexedRuntime, request_id: u64) net.MultiplexedDialRawFinishOutcome {
        return DialLifecycle.finish(self, request_id);
    }

    pub fn cancelDial(self: *MultiplexedRuntime, request_id: u64) ?foundation.FailureChain {
        return DialLifecycle.cancel(self, request_id);
    }

    pub fn listen(
        self: *MultiplexedRuntime,
        route_id: u64,
        transport: []const u8,
        requested_designator: []const u8,
    ) net.multiplexed_resident.MultiplexedResident.RawListenStartOutcome {
        const profile = profileForTransport(transport) orelse
            return .{ .failed = .init(error.InvalidAddress) };
        const identity = crypto.PeerKey.fromDesignator(requested_designator) orelse
            return .{ .failed = .init(error.InvalidAddress) };
        const raw = self.resident(profile).listenRaw(self.allocator, .{
            .designator = requested_designator,
            .identity = identity,
        }) catch |err| return .{ .failed = .init(err) };
        const setup = self.allocator.create(ListenerSetup) catch {
            var failure = net.netlayer.ListenFailure.init(error.OutOfMemory);
            if (raw.close()) |cleanup| failure.noteChain(cleanup);
            return .{ .failed = failure };
        };
        setup.* = .{
            .runtime = self,
            .raw = raw,
            .route_id = route_id,
        };

        self.mutex.lock();
        if (self.stopping.load(.acquire) or self.listener != .empty) {
            self.mutex.unlock();
            var failure = net.netlayer.ListenFailure.init(error.BindFailed);
            if (Reactor.destroyListenerSetup(self, setup)) |cleanup| failure.noteChain(cleanup);
            return .{ .failed = failure };
        }
        self.listener = .{ .starting = setup };
        self.mutex.unlock();
        self.signalControl();
        return .{ .admitted = .pending };
    }

    pub fn finishListen(
        self: *MultiplexedRuntime,
        route_id: u64,
    ) net.multiplexed_resident.MultiplexedResident.RawListenFinishOutcome {
        self.mutex.lock();
        const setup = switch (self.listener) {
            .starting => |value| value,
            .empty, .active => {
                self.mutex.unlock();
                return .{ .failed = .init(error.BindFailed) };
            },
        };
        if (setup.route_id != route_id) {
            self.mutex.unlock();
            return .{ .failed = .init(error.BindFailed) };
        }
        if (setup.state == .running) {
            setup.state = .cancelled;
            self.mutex.unlock();
            self.signalControl();
            return .{ .failed = .init(error.BindFailed) };
        }
        if (setup.state != .succeeded) {
            var failure = setup.failure orelse net.netlayer.ListenFailure.init(error.BindFailed);
            self.listener = .empty;
            self.mutex.unlock();
            if (Reactor.destroyListenerSetup(self, setup)) |cleanup| failure.noteChain(cleanup);
            return .{ .failed = failure };
        }
        const listener = setup.listener orelse {
            self.listener = .empty;
            self.mutex.unlock();
            var failure = net.netlayer.ListenFailure.init(error.BindFailed);
            if (Reactor.destroyListenerSetup(self, setup)) |cleanup| failure.noteChain(cleanup);
            return .{ .failed = failure };
        };
        setup.listener = null;
        self.listener = .{ .active = listener };
        self.mutex.unlock();
        self.allocator.destroy(setup);
        self.signalControl();
        return .{ .listener = listener };
    }

    pub fn cancelListen(self: *MultiplexedRuntime, route_id: u64) ?foundation.FailureChain {
        self.mutex.lock();
        switch (self.listener) {
            .starting => |setup| {
                if (setup.route_id != route_id) {
                    self.mutex.unlock();
                    return null;
                }
                if (setup.state == .retired) {
                    const failure = setup.failure;
                    self.listener = .empty;
                    self.mutex.unlock();
                    self.allocator.destroy(setup);
                    return failure;
                }
                setup.state = .cancelled;
            },
            .active => |listener| {
                if (listener.route_id != route_id or !listener.retired.load(.acquire)) {
                    self.mutex.unlock();
                    return null;
                }
                const failure = listener.claimFailure();
                self.listener = .empty;
                self.mutex.unlock();
                model.freePeerLocator(self.allocator, listener.locator);
                self.allocator.destroy(listener);
                return failure;
            },
            .empty => {},
        }
        self.mutex.unlock();
        self.signalControl();
        return null;
    }

    pub fn stopListen(self: *MultiplexedRuntime, listener: *ListenerState) net.multiplexed_resident.TeardownOutcome {
        self.mutex.lock();
        switch (self.listener) {
            .active => |active| if (active == listener) {
                if (listener.retired.load(.acquire)) {
                    const failure = listener.claimFailure();
                    self.listener = .empty;
                    self.mutex.unlock();
                    model.freePeerLocator(self.allocator, listener.locator);
                    self.allocator.destroy(listener);
                    return if (failure) |reported| .{ .failed = reported } else .complete;
                }
                _ = listener.stopped.swap(true, .acq_rel);
                self.mutex.unlock();
                self.signalControl();
                return .pending;
            },
            .empty, .starting => {},
        }
        self.mutex.unlock();
        self.signalControl();
        return .complete;
    }
};

const MultiplexedProjection = multiplexed_projection.Projection(
    MultiplexedRuntime,
    ListenerState,
    ConnState,
    Reactor.failRuntime,
);

fn providerRetain(ctx: ?*anyopaque, out_failure: ?*c.PancakeProviderFailure) callconv(.c) i32 {
    const payload: *Payload = @ptrCast(@alignCast(ctx orelse {
        c.transport_provider.setProviderFailure(out_failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer);
        return PANCAKE_ERR_NULL_POINTER;
    }));
    if (payload.retain()) return PANCAKE_OK;
    c.transport_provider.setProviderFailure(out_failure, PANCAKE_ERR_CLOSED, error.Closed);
    return PANCAKE_ERR_CLOSED;
}

fn providerSameConfiguration(ctx: ?*anyopaque, other_ctx: ?*anyopaque) callconv(.c) u8 {
    const left: *Payload = @ptrCast(@alignCast(ctx orelse return 0));
    const right: *Payload = @ptrCast(@alignCast(other_ctx orelse return 0));
    return @intFromBool(left.native.sameConfiguration(&right.native));
}

fn providerRelease(ctx: ?*anyopaque, out_failure: ?*c.PancakeProviderFailure) callconv(.c) i32 {
    const payload: *Payload = @ptrCast(@alignCast(ctx orelse return PANCAKE_OK));
    if (payload.release()) |failure| {
        c.setLastErrorChain("relay provider release", failure);
        const code = failure_projection.release(failure.cause);
        return c.transport_provider.failProviderChain(out_failure, code, failure, failure_projection.release);
    }
    return PANCAKE_OK;
}
pub fn create(
    allocator: std.mem.Allocator,
    config: ?*const PancakeRelayConfig,
    slot: *?*Payload,
) i32 {
    return runtime_lifecycle.create(Payload, allocator, config, slot);
}
