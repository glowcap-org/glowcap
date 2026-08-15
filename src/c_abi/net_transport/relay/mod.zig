//! The native relay multiplexed provider archive.
//!
//! The archive owns one multiplexed runtime and advertises two profiles through
//! it: clear `keyed-relay` and Host-sealed `noise-relay`. The runtime moves
//! opaque WebSocket bytes only. CapTP framing and Noise_XK remain Host policy,
//! selected by the profile metadata consumed by the driver.

const std = @import("std");

const foundation = @import("foundation");
const crypto = foundation.crypto;
const model = @import("model");
const net = @import("net");
const c = @import("c_abi_shared");

pub const PancakeRelayRuntime = opaque {};
const PancakeContext = c.PancakeContext;

const PANCAKE_OK = c.PANCAKE_OK;
const PANCAKE_ERR_NULL_POINTER = c.PANCAKE_ERR_NULL_POINTER;
const PANCAKE_ERR_INVALID_ARGUMENT = c.PANCAKE_ERR_INVALID_ARGUMENT;
const PANCAKE_ERR_INTERNAL = c.PANCAKE_ERR_INTERNAL;
const PANCAKE_ERR_WOULD_BLOCK = c.PANCAKE_ERR_WOULD_BLOCK;
const PANCAKE_ERR_CLOSED = c.PANCAKE_ERR_CLOSED;
const PANCAKE_ERR_IO = c.PANCAKE_ERR_IO;
const PANCAKE_ERR_TIMEOUT = c.PANCAKE_ERR_TIMEOUT;

const multiplexed = c.multiplexed_transport;

const EV_READABLE = multiplexed.PANCAKE_MULTIPLEXED_EV_READABLE;
const EV_WRITABLE = multiplexed.PANCAKE_MULTIPLEXED_EV_WRITABLE;
const EV_CLOSED = multiplexed.PANCAKE_MULTIPLEXED_EV_CLOSED;
const EV_ACCEPT = multiplexed.PANCAKE_MULTIPLEXED_EV_ACCEPT;
const EV_CONNECT = multiplexed.PANCAKE_MULTIPLEXED_EV_CONNECT;
const EV_LISTEN = multiplexed.PANCAKE_MULTIPLEXED_EV_LISTEN;
const WOULD_BLOCK: isize = multiplexed.PANCAKE_MULTIPLEXED_WOULD_BLOCK;

pub const symbols = @import("symbols.zig");

/// Deployment configuration shared by both relay profiles. The resident
/// copies the URL text it needs; this ABI borrows the fields for construction.
pub const PancakeRelayConfig = extern struct {
    relay_url: ?[*]const u8 = null,
    relay_url_len: usize = 0,
    register_url: ?[*]const u8 = null,
    register_url_len: usize = 0,
};

const Profile = enum(u1) { keyed, noise };
const profile_count = @typeInfo(Profile).@"enum".fields.len;

fn profileMetadata(profile: Profile) model.transport.Metadata {
    return switch (profile) {
        .keyed => model.transport.Known.keyed_relay.metadata(),
        .noise => model.transport.Known.noise_relay.metadata(),
    };
}

fn profileForTransport(transport: []const u8) ?Profile {
    if (std.mem.eql(u8, transport, model.transport.keyed_relay)) return .keyed;
    if (std.mem.eql(u8, transport, model.transport.noise_relay)) return .noise;
    return null;
}

const Payload = struct {
    threaded: std.Io.Threaded,
    allocator: std.mem.Allocator,
    references: std.atomic.Value(usize),
    keyed: net.relay.Resident,
    noise: net.relay.Resident,
    runtime: MultiplexedRuntime,
    profile_abi: [profile_count]c.PancakeTransportProfile,
    entries: [profile_count]c.PancakeTransportProviderEntry,
    multiplexed_transport: c.PancakeMultiplexedTransport,
    provider: c.PancakeTransportProvider,

    fn io(self: *Payload) std.Io {
        return self.threaded.io();
    }

    fn initProvider(self: *Payload) void {
        self.profile_abi[@intFromEnum(Profile.keyed)] =
            c.transport_provider.profileFromMetadata(profileMetadata(.keyed));
        self.profile_abi[@intFromEnum(Profile.noise)] =
            c.transport_provider.profileFromMetadata(profileMetadata(.noise));
        self.multiplexed_transport = multiplexedTransport(&self.runtime);
        self.entries[@intFromEnum(Profile.keyed)] = .{
            .profile = &self.profile_abi[@intFromEnum(Profile.keyed)],
            .execution_model = c.transport_provider.PANCAKE_TRANSPORT_EXEC_MULTIPLEXED,
            .implementation = &self.multiplexed_transport,
        };
        self.entries[@intFromEnum(Profile.noise)] = .{
            .profile = &self.profile_abi[@intFromEnum(Profile.noise)],
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

    fn release(self: *Payload) ?foundation.FailureChain {
        if (self.references.fetchSub(1, .acq_rel) != 1) return null;
        const failure = self.runtime.deinit();
        self.noise.deinit();
        self.keyed.deinit();
        self.threaded.deinit();
        self.allocator.destroy(self);
        return failure;
    }
};

const ConnState = struct {
    runtime: *MultiplexedRuntime,
    id: u64,
    raw: net.relay.RawConnection,
    io_mutex: net.sync.SpinLock = .{},
    events: std.atomic.Value(u32) = .init(0),
    closed: std.atomic.Value(bool) = .init(false),
    raw_closed: bool = false,
    failure: c.PancakeProviderFailure = std.mem.zeroes(c.PancakeProviderFailure),
};

const ListenerState = struct {
    runtime: *MultiplexedRuntime,
    raw: net.relay.RawListener,
    locator: model.PeerLocator,
    route_id: u64,
    io_mutex: net.sync.SpinLock = .{},
    stopped: std.atomic.Value(bool) = .init(false),
    closed: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
    events: std.atomic.Value(u32) = .init(0),
};

const ListenerSetup = struct {
    runtime: *MultiplexedRuntime,
    raw: net.relay.RawListener,
    route_id: u64,
    state: State = .running,
    error_code: i32 = PANCAKE_ERR_IO,
    listener: ?*ListenerState = null,
    announced: bool = false,

    const State = enum { running, succeeded, failed, cancelled };
};

const DialState = struct {
    runtime: *MultiplexedRuntime,
    request_id: u64,
    profile: Profile,
    locator: model.PeerLocator,
    state: State = .running,
    error_code: i32 = PANCAKE_ERR_IO,
    conn: ?*ConnState = null,
    announced: bool = false,
    stop_requested: std.atomic.Value(bool) = .init(false),
    operation: net.CancelableOperation = undefined,

    const State = enum { running, succeeded, failed };

    fn run(job: *DialState) std.Io.Cancelable!void {
        const runtime = job.runtime;
        const raw = runtime.resident(job.profile).dialRawCancelable(job.locator, &job.stop_requested) catch |err| {
            runtime.completeDial(job, dialErrorCode(err));
            return;
        };
        var owned_raw = true;
        defer if (owned_raw) {
            var discarded = raw;
            discarded.close();
        };

        runtime.mutex.lock();
        defer runtime.mutex.unlock();
        if (runtime.stopping.load(.acquire) or job.stop_requested.load(.acquire)) {
            return;
        }

        const conn = runtime.allocator.create(ConnState) catch {
            job.state = .failed;
            job.error_code = PANCAKE_ERR_INTERNAL;
            runtime.signalReady();
            return;
        };
        conn.* = .{ .runtime = runtime, .id = 0, .raw = raw };
        owned_raw = false;
        if (runtime.addConnectionLocked(conn)) |_| {
            job.conn = conn;
            job.state = .succeeded;
            job.error_code = PANCAKE_OK;
            job.runtime.signalControl();
            job.runtime.signalReady();
            return;
        } else |err| {
            conn.raw.close();
            runtime.allocator.destroy(conn);
            job.state = .failed;
            job.error_code = if (err == error.OutOfMemory) PANCAKE_ERR_INTERNAL else PANCAKE_ERR_CLOSED;
            runtime.signalReady();
        }
    }

    fn retire(raw: *anyopaque) void {
        const job: *DialState = @ptrCast(@alignCast(raw));
        const runtime = job.runtime;
        runtime.mutex.lock();
        detachJobLocked(runtime, job);
        runtime.mutex.unlock();
        destroyDial(runtime, job);
    }
};

const PollSubject = union(enum) {
    wake,
    listener_setup: *ListenerSetup,
    listener: *ListenerState,
    connection: *ConnState,
};

/// The relay rendezvous route is keyed by durable designator, not channel
/// profile, so one runtime owns one logical listener route at a time.
const ListenerSlot = union(enum) {
    empty,
    starting: *ListenerSetup,
    active: *ListenerState,
};

const MultiplexedRuntime = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    payload: *Payload,
    control_wake: net.wake_channel.WakeChannel,
    ready_wake: net.wake_channel.WakeChannel,
    tasks: net.OperationOwner,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    terminal_failure_mutex: net.sync.SpinLock = .{},
    terminal_failure: ?foundation.FailureChain = null,
    terminal_failure_present: std.atomic.Value(bool) = .init(false),
    mutex: net.sync.SpinLock = .{},
    listener: ListenerSlot = .empty,
    next_connection: u64 = 1,
    jobs: std.ArrayList(*DialState) = .empty,
    connections: std.ArrayList(*ConnState) = .empty,
    by_id: std.AutoHashMap(u64, *ConnState),
    pollfds: std.ArrayList(std.posix.pollfd) = .empty,
    subjects: std.ArrayList(PollSubject) = .empty,

    fn init(self: *MultiplexedRuntime, payload: *Payload) !void {
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
        self.thread = std.Thread.spawn(.{}, reactorMain, .{self}) catch
            return error.ConcurrencyUnavailable;
    }

    fn deinit(self: *MultiplexedRuntime) ?foundation.FailureChain {
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
            .starting => |setup| if (destroyListenerSetup(self, setup)) |failure|
                self.noteListenerFailure(failure),
            .active => |listener| if (destroyListenerLocked(self, listener)) |failure|
                self.noteListenerFailure(failure),
        }
        self.listener = .empty;
        for (self.connections.items) |conn| {
            closeConnectionLocked(conn);
            self.allocator.destroy(conn);
        }
        for (self.jobs.items) |job| destroyDial(self, job);
        self.jobs.clearRetainingCapacity();
        self.mutex.unlock();

        self.jobs.deinit(self.allocator);
        self.connections.deinit(self.allocator);
        self.by_id.deinit();
        self.pollfds.deinit(self.allocator);
        self.subjects.deinit(self.allocator);
        self.ready_wake.deinit();
        self.control_wake.deinit();
        return self.recordedFailure();
    }

    fn resident(self: *MultiplexedRuntime, profile: Profile) *net.relay.Resident {
        return switch (profile) {
            .keyed => &self.payload.keyed,
            .noise => &self.payload.noise,
        };
    }

    fn signalControl(self: *MultiplexedRuntime) void {
        _ = self.control_wake.nudge() catch {
            self.noteFailure(error.WakeNudgeFailed);
        };
    }

    fn noteListenerFailure(self: *MultiplexedRuntime, later: net.netlayer.ListenerCloseFailure) void {
        self.terminal_failure_mutex.lock();
        if (self.terminal_failure) |*failure|
            failure.noteChain(later)
        else
            self.terminal_failure = later;
        self.terminal_failure_mutex.unlock();
        self.terminal_failure_present.store(true, .release);
        self.signalControl();
    }

    fn noteFailure(self: *MultiplexedRuntime, cause: anyerror) void {
        self.terminal_failure_mutex.lock();
        if (self.terminal_failure) |*failure|
            failure.note(cause)
        else
            self.terminal_failure = foundation.FailureChain.init(cause);
        self.terminal_failure_mutex.unlock();
        self.terminal_failure_present.store(true, .release);
    }

    fn recordedFailure(self: *MultiplexedRuntime) ?foundation.FailureChain {
        self.terminal_failure_mutex.lock();
        defer self.terminal_failure_mutex.unlock();
        return self.terminal_failure;
    }

    fn signalReady(self: *MultiplexedRuntime) void {
        _ = self.ready_wake.nudge() catch {
            self.noteFailure(error.WakeNudgeFailed);
        };
    }

    fn addConnectionLocked(self: *MultiplexedRuntime, conn: *ConnState) !u64 {
        if (self.stopping.load(.acquire)) return error.Closing;
        if (self.next_connection == std.math.maxInt(u64)) return error.Closing;
        const id = self.next_connection;
        self.next_connection += 1;
        conn.id = id;
        try self.connections.append(self.allocator, conn);
        errdefer _ = self.connections.pop();
        try self.by_id.put(id, conn);
        return id;
    }

    fn findConnectionLocked(self: *MultiplexedRuntime, id: u64) ?*ConnState {
        return self.by_id.get(id);
    }

    fn findJobLocked(self: *MultiplexedRuntime, request_id: u64) ?*DialState {
        for (self.jobs.items) |job| if (job.request_id == request_id) return job;
        return null;
    }

    fn completeDial(self: *MultiplexedRuntime, job: *DialState, code: i32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.stopping.load(.acquire)) return;
        if (job.stop_requested.load(.acquire)) {
            return;
        }
        job.state = .failed;
        job.error_code = code;
        self.signalReady();
    }

    fn startDial(self: *MultiplexedRuntime, request_id: u64, locator: model.PeerLocator) !void {
        const profile = profileForTransport(locator.transport) orelse return error.InvalidAddress;
        const owned_locator = try model.clonePeerLocator(self.allocator, locator);
        errdefer model.freePeerLocator(self.allocator, owned_locator);
        const job = try self.allocator.create(DialState);
        errdefer self.allocator.destroy(job);
        job.* = .{
            .runtime = self,
            .request_id = @intCast(request_id),
            .profile = profile,
            .locator = owned_locator,
        };

        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.stopping.load(.acquire) or self.findJobLocked(job.request_id) != null)
            return error.ConnectionLost;
        try self.jobs.append(self.allocator, job);
        errdefer _ = self.jobs.pop();
        self.tasks.startCancelable(
            &job.operation,
            DialState.run,
            .{job},
            job,
            DialState.retire,
        ) catch |err| {
            return switch (err) {
                error.Closing => error.ConnectionLost,
                error.ConcurrencyUnavailable => error.OutOfMemory,
            };
        };
    }

    fn finishDial(self: *MultiplexedRuntime, request_id: u64) !u64 {
        self.mutex.lock();
        const job = self.findJobLocked(request_id) orelse {
            self.mutex.unlock();
            return error.ConnectionLost;
        };
        switch (job.state) {
            .running => {
                job.stop_requested.store(true, .release);
                detachJobLocked(self, job);
                self.mutex.unlock();
                self.tasks.cancel(&job.operation);
                self.signalControl();
                return error.ConnectionLost;
            },
            .failed => {
                const code = job.error_code;
                detachJobLocked(self, job);
                self.mutex.unlock();
                self.tasks.reap(&job.operation);
                return switch (code) {
                    PANCAKE_ERR_INVALID_ARGUMENT => error.InvalidAddress,
                    PANCAKE_ERR_TIMEOUT => error.TimedOut,
                    PANCAKE_ERR_INTERNAL => error.OutOfMemory,
                    else => error.ConnectionLost,
                };
            },
            .succeeded => {
                const conn = job.conn orelse {
                    detachJobLocked(self, job);
                    self.mutex.unlock();
                    self.tasks.reap(&job.operation);
                    return error.ConnectionLost;
                };
                const id = conn.id;
                detachJobLocked(self, job);
                self.mutex.unlock();
                self.tasks.reap(&job.operation);
                return id;
            },
        }
    }

    fn cancelDial(self: *MultiplexedRuntime, request_id: u64) void {
        self.mutex.lock();
        const job = self.findJobLocked(request_id) orelse {
            self.mutex.unlock();
            return;
        };
        job.stop_requested.store(true, .release);
        if (job.state != .running) {
            if (job.conn) |conn| conn.closed.store(true, .release);
        }
        detachJobLocked(self, job);
        self.mutex.unlock();
        self.tasks.cancel(&job.operation);
        self.signalControl();
    }

    fn listen(
        self: *MultiplexedRuntime,
        route_id: u64,
        transport: []const u8,
        requested_designator: []const u8,
    ) !net.multiplexed_resident.RawListenResult {
        const profile = profileForTransport(transport) orelse return error.InvalidAddress;
        const identity = crypto.PeerKey.fromDesignator(requested_designator) orelse
            return error.InvalidAddress;
        const raw = try self.resident(profile).listenRaw(self.allocator, .{
            .designator = requested_designator,
            .identity = identity,
        });
        const setup = self.allocator.create(ListenerSetup) catch {
            var failure = net.netlayer.ListenFailure.init(error.OutOfMemory);
            if (raw.close()) |cleanup| failure.noteChain(cleanup);
            self.noteListenerFailure(failure);
            return error.OutOfMemory;
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
            if (destroyListenerSetup(self, setup)) |cleanup| failure.noteChain(cleanup);
            self.noteListenerFailure(failure);
            return error.BindFailed;
        }
        self.listener = .{ .starting = setup };
        self.mutex.unlock();
        self.signalControl();
        return .pending;
    }

    fn finishListen(self: *MultiplexedRuntime, route_id: u64) !*ListenerState {
        self.mutex.lock();
        const setup = switch (self.listener) {
            .starting => |value| value,
            .empty, .active => {
                self.mutex.unlock();
                return error.BindFailed;
            },
        };
        if (setup.route_id != route_id) {
            self.mutex.unlock();
            return error.BindFailed;
        }
        if (setup.state == .running) {
            setup.state = .cancelled;
            self.mutex.unlock();
            self.signalControl();
            return error.BindFailed;
        }
        if (setup.state != .succeeded) {
            const code = setup.error_code;
            const cause: anyerror = switch (code) {
                PANCAKE_ERR_INVALID_ARGUMENT => error.InvalidAddress,
                PANCAKE_ERR_INTERNAL => error.OutOfMemory,
                else => error.BindFailed,
            };
            self.listener = .empty;
            self.mutex.unlock();
            var failure = net.netlayer.ListenFailure.init(cause);
            if (destroyListenerSetup(self, setup)) |cleanup| failure.noteChain(cleanup);
            self.noteListenerFailure(failure);
            return cause;
        }
        const listener = setup.listener orelse {
            self.listener = .empty;
            self.mutex.unlock();
            var failure = net.netlayer.ListenFailure.init(error.BindFailed);
            if (destroyListenerSetup(self, setup)) |cleanup| failure.noteChain(cleanup);
            self.noteListenerFailure(failure);
            return error.BindFailed;
        };
        setup.listener = null;
        self.listener = .{ .active = listener };
        self.mutex.unlock();
        self.allocator.destroy(setup);
        self.signalControl();
        return listener;
    }

    fn cancelListen(self: *MultiplexedRuntime, route_id: u64) void {
        self.mutex.lock();
        switch (self.listener) {
            .starting => |setup| {
                if (setup.route_id == route_id) setup.state = .cancelled;
            },
            .empty, .active => {},
        }
        self.mutex.unlock();
        self.signalControl();
    }

    fn stopListen(self: *MultiplexedRuntime, listener: *ListenerState) void {
        if (listener.stopped.swap(true, .acq_rel)) return;
        self.signalControl();
    }
};

fn destroyDial(runtime: *MultiplexedRuntime, job: *DialState) void {
    model.freePeerLocator(runtime.allocator, job.locator);
    runtime.allocator.destroy(job);
}

fn detachJobLocked(runtime: *MultiplexedRuntime, job: *DialState) void {
    for (runtime.jobs.items, 0..) |candidate, i| {
        if (candidate == job) {
            const removed = runtime.jobs.swapRemove(i);
            std.debug.assert(removed == job);
            return;
        }
    }
}

fn closeConnectionLocked(conn: *ConnState) void {
    conn.io_mutex.lock();
    defer conn.io_mutex.unlock();
    if (conn.raw_closed) return;
    conn.raw.close();
    conn.raw_closed = true;
}

fn closeListenerLocked(listener: *ListenerState) ?net.netlayer.ListenerCloseFailure {
    listener.io_mutex.lock();
    defer listener.io_mutex.unlock();
    if (listener.closed.swap(true, .acq_rel)) return null;
    return listener.raw.close();
}

fn destroyListenerLocked(runtime: *MultiplexedRuntime, listener: *ListenerState) ?net.netlayer.ListenerCloseFailure {
    const failure = closeListenerLocked(listener);
    model.freePeerLocator(runtime.allocator, listener.locator);
    runtime.allocator.destroy(listener);
    return failure;
}

fn destroyListenerSetup(runtime: *MultiplexedRuntime, setup: *ListenerSetup) ?net.netlayer.ListenerCloseFailure {
    const failure = if (setup.listener) |listener|
        destroyListenerLocked(runtime, listener)
    else
        setup.raw.close();
    runtime.allocator.destroy(setup);
    return failure;
}

fn dialErrorCode(err: anyerror) i32 {
    return switch (err) {
        error.InvalidAddress => PANCAKE_ERR_INVALID_ARGUMENT,
        error.TimedOut => PANCAKE_ERR_TIMEOUT,
        error.OutOfMemory => PANCAKE_ERR_INTERNAL,
        else => PANCAKE_ERR_IO,
    };
}

fn reactorMain(runtime: *MultiplexedRuntime) void {
    while (!runtime.stopping.load(.acquire)) {
        if (runtime.terminal_failure_present.load(.acquire)) {
            failRuntime(runtime);
            return;
        }
        if (!rebuildPollSet(runtime)) {
            failRuntime(runtime);
            return;
        }
        // The wake is the fast path; the bounded poll is the recovery path
        // that lets a latched notification fault terminalize and join instead
        // of making descriptor failure an unbounded shutdown hang.
        const ready = net.poll.wait(runtime.pollfds.items, 100) catch {
            failRuntime(runtime);
            return;
        };
        if (runtime.stopping.load(.acquire)) return;
        if (ready == 0) continue;

        for (runtime.pollfds.items, runtime.subjects.items) |pollfd, subject| {
            const revents = pollfd.revents;
            if (revents == 0) continue;
            switch (subject) {
                .wake => runtime.control_wake.drain() catch {
                    runtime.noteFailure(error.WakeDrainFailed);
                    failRuntime(runtime);
                    return;
                },
                .listener_setup => |setup| reactorListenerSetup(runtime, setup, revents),
                .listener => |listener| reactorListener(runtime, listener, revents),
                .connection => |conn| reactorConnection(runtime, conn, revents),
            }
        }
        reapClosedConnections(runtime);
        reapStoppedListener(runtime);
        reapCancelledListenerSetup(runtime);
    }
}

fn rebuildPollSet(runtime: *MultiplexedRuntime) bool {
    runtime.mutex.lock();
    defer runtime.mutex.unlock();
    runtime.pollfds.clearRetainingCapacity();
    runtime.subjects.clearRetainingCapacity();
    const listener_count: usize = switch (runtime.listener) {
        .active => |listener| @intFromBool(!listener.stopped.load(.acquire)),
        .starting => |setup| @intFromBool(setup.state == .running),
        .empty => 0,
    };
    const wanted = @as(usize, 1) + listener_count + runtime.connections.items.len;
    runtime.pollfds.ensureTotalCapacity(runtime.allocator, wanted) catch return false;
    runtime.subjects.ensureTotalCapacity(runtime.allocator, wanted) catch return false;
    runtime.pollfds.appendAssumeCapacity(.{
        .fd = runtime.control_wake.read,
        .events = std.posix.POLL.IN,
        .revents = 0,
    });
    runtime.subjects.appendAssumeCapacity(.wake);
    switch (runtime.listener) {
        .starting => |setup| if (setup.state == .running) {
            const fd = setup.raw.readinessFd();
            if (fd >= 0) {
                runtime.pollfds.appendAssumeCapacity(.{
                    .fd = fd,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                });
                runtime.subjects.appendAssumeCapacity(.{ .listener_setup = setup });
            }
        },
        .active => |listener| if (!listener.stopped.load(.acquire)) {
            const fd = listener.raw.readinessFd();
            if (fd >= 0) {
                runtime.pollfds.appendAssumeCapacity(.{
                    .fd = fd,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                });
                runtime.subjects.appendAssumeCapacity(.{ .listener = listener });
            }
        },
        .empty => {},
    }
    for (runtime.connections.items) |conn| {
        if (conn.closed.load(.acquire)) continue;
        conn.io_mutex.lock();
        const pending = !conn.raw_closed and conn.raw.hasPendingWrite();
        const fd = if (conn.raw_closed) -1 else conn.raw.readinessFd();
        conn.io_mutex.unlock();
        if (fd < 0) continue;
        runtime.pollfds.appendAssumeCapacity(.{
            .fd = fd,
            .events = std.posix.POLL.IN | if (pending) @as(c_short, std.posix.POLL.OUT) else 0,
            .revents = 0,
        });
        runtime.subjects.appendAssumeCapacity(.{ .connection = conn });
    }
    return true;
}

fn failListenerSetup(runtime: *MultiplexedRuntime, setup: *ListenerSetup, code: i32) void {
    runtime.mutex.lock();
    const current = switch (runtime.listener) {
        .starting => |value| value == setup and setup.state == .running,
        .empty, .active => false,
    };
    if (current) {
        setup.state = .failed;
        setup.error_code = code;
    }
    runtime.mutex.unlock();
    if (current) runtime.signalReady();
}

fn reactorListenerSetup(runtime: *MultiplexedRuntime, setup: *ListenerSetup, revents: c_short) void {
    if (revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL) != 0) {
        failListenerSetup(runtime, setup, PANCAKE_ERR_IO);
        return;
    }
    const established = setup.raw.waitEstablished(0) catch {
        failListenerSetup(runtime, setup, PANCAKE_ERR_IO);
        return;
    };
    if (!established) return;
    const locator = setup.raw.localLocator(runtime.allocator) catch |err| {
        failListenerSetup(runtime, setup, if (err == error.OutOfMemory) PANCAKE_ERR_INTERNAL else PANCAKE_ERR_IO);
        return;
    };
    const listener = runtime.allocator.create(ListenerState) catch {
        model.freePeerLocator(runtime.allocator, locator);
        failListenerSetup(runtime, setup, PANCAKE_ERR_INTERNAL);
        return;
    };

    runtime.mutex.lock();
    const current = switch (runtime.listener) {
        .starting => |value| value == setup and setup.state == .running,
        .empty, .active => false,
    };
    if (current) {
        listener.* = .{
            .runtime = runtime,
            .raw = setup.raw,
            .locator = locator,
            .route_id = setup.route_id,
        };
        setup.listener = listener;
        setup.state = .succeeded;
    }
    runtime.mutex.unlock();
    if (!current) {
        runtime.allocator.destroy(listener);
        model.freePeerLocator(runtime.allocator, locator);
        return;
    }
    runtime.signalReady();
}

fn reactorListener(runtime: *MultiplexedRuntime, listener: *ListenerState, revents: c_short) void {
    if (listener.stopped.load(.acquire)) return;
    const bad = revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL) != 0;
    listener.io_mutex.lock();
    defer listener.io_mutex.unlock();
    if (listener.closed.load(.acquire)) return;
    const acceptable = listener.raw.waitAcceptable(0) catch {
        // The readiness record is the only path by which the driver can claim
        // this failure. Treating it as "not ready" would strand an active
        // listener forever with no returned error and no later wakeup.
        listener.failed.store(true, .release);
        _ = listener.events.fetchOr(EV_ACCEPT, .acq_rel);
        runtime.signalReady();
        return;
    };
    if (bad) listener.failed.store(true, .release);
    if (!bad and !acceptable) return;
    _ = listener.events.fetchOr(EV_ACCEPT, .acq_rel);
    runtime.signalReady();
}

fn reactorConnection(runtime: *MultiplexedRuntime, conn: *ConnState, revents: c_short) void {
    if (conn.closed.load(.acquire)) return;
    conn.io_mutex.lock();
    defer conn.io_mutex.unlock();
    if (conn.raw_closed) return;
    if (revents & std.posix.POLL.OUT != 0 and conn.raw.hasPendingWrite()) {
        const flushed = conn.raw.flushPending();
        if (flushed == -1) {
            conn.closed.store(true, .release);
            _ = conn.events.fetchOr(EV_CLOSED, .acq_rel);
            runtime.signalReady();
            return;
        }
        if (!conn.raw.hasPendingWrite()) _ = conn.events.fetchOr(EV_WRITABLE, .acq_rel);
    }
    if (revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL) != 0) {
        conn.closed.store(true, .release);
        _ = conn.events.fetchOr(EV_CLOSED, .acq_rel);
    } else if (revents & std.posix.POLL.IN != 0) {
        _ = conn.events.fetchOr(EV_READABLE, .acq_rel);
    }
    runtime.signalReady();
}

fn reapClosedConnections(runtime: *MultiplexedRuntime) void {
    runtime.mutex.lock();
    defer runtime.mutex.unlock();
    var index: usize = 0;
    while (index < runtime.connections.items.len) {
        const conn = runtime.connections.items[index];
        if (!conn.closed.load(.acquire) or conn.events.load(.acquire) != 0) {
            index += 1;
            continue;
        }
        closeConnectionLocked(conn);
        std.debug.assert(runtime.by_id.remove(conn.id));
        const removed = runtime.connections.swapRemove(index);
        std.debug.assert(removed == conn);
        runtime.allocator.destroy(conn);
    }
}

fn reapStoppedListener(runtime: *MultiplexedRuntime) void {
    runtime.mutex.lock();
    defer runtime.mutex.unlock();
    switch (runtime.listener) {
        .active => |listener| if (listener.stopped.load(.acquire)) {
            if (destroyListenerLocked(runtime, listener)) |failure|
                runtime.noteListenerFailure(failure);
            runtime.listener = .empty;
        },
        .empty, .starting => {},
    }
}

fn reapCancelledListenerSetup(runtime: *MultiplexedRuntime) void {
    runtime.mutex.lock();
    const setup: ?*ListenerSetup = switch (runtime.listener) {
        .starting => |value| if (value.state == .cancelled) blk: {
            runtime.listener = .empty;
            break :blk value;
        } else null,
        .empty, .active => null,
    };
    runtime.mutex.unlock();
    if (setup) |value| if (destroyListenerSetup(runtime, value)) |failure|
        runtime.noteListenerFailure(failure);
}

fn failRuntime(runtime: *MultiplexedRuntime) void {
    runtime.mutex.lock();
    defer runtime.mutex.unlock();
    switch (runtime.listener) {
        .starting => |setup| if (setup.state == .running) {
            setup.state = .failed;
            setup.error_code = PANCAKE_ERR_INTERNAL;
        },
        .active => |listener| {
            listener.failed.store(true, .release);
            _ = listener.events.fetchOr(EV_ACCEPT, .acq_rel);
        },
        .empty => {},
    }
    for (runtime.jobs.items) |job| {
        if (job.state == .running) {
            job.stop_requested.store(true, .release);
            job.state = .failed;
            job.error_code = PANCAKE_ERR_INTERNAL;
        }
    }
    for (runtime.connections.items) |conn| {
        conn.closed.store(true, .release);
        _ = conn.events.fetchOr(EV_CLOSED, .acq_rel);
    }
    runtime.signalReady();
}

fn payloadFromOpaque(value: ?*PancakeRelayRuntime) ?*Payload {
    return @ptrCast(@alignCast(value orelse return null));
}

fn runtimeFrom(ctx: ?*anyopaque) *MultiplexedRuntime {
    return @ptrCast(@alignCast(ctx.?));
}

fn listenerFrom(value: ?*anyopaque) *ListenerState {
    return @ptrCast(@alignCast(value.?));
}

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
    return @intFromBool(left.keyed.sameConfiguration(&right.keyed));
}

fn providerRelease(ctx: ?*anyopaque, out_failure: ?*c.PancakeProviderFailure) callconv(.c) i32 {
    const payload: *Payload = @ptrCast(@alignCast(ctx orelse return PANCAKE_OK));
    if (payload.release()) |failure| {
        setReleaseFailure("relay provider release", failure);
        const code = releaseErrorCode(failure.cause);
        c.transport_provider.setProviderFailure(out_failure, code, failure.cause);
        if (failure.secondary_cause) |secondary| {
            const slot = out_failure orelse return code;
            const name = @errorName(secondary);
            slot.secondary_result = releaseErrorCode(secondary);
            slot.secondary_name = name.ptr;
            slot.secondary_name_len = name.len;
            slot.secondary_count = failure.secondary_count;
        }
        return code;
    }
    return PANCAKE_OK;
}

fn setReleaseFailure(prefix: []const u8, failure: foundation.FailureChain) void {
    if (failure.secondary_cause) |secondary| {
        c.setLastError("{s}: {s}; cleanup: {s} ({d} secondary failures)", .{
            prefix,
            @errorName(failure.cause),
            @errorName(secondary),
            failure.secondary_count,
        });
    } else {
        c.setLastError("{s}: {s}", .{ prefix, @errorName(failure.cause) });
    }
}

fn releaseErrorCode(cause: anyerror) i32 {
    return switch (cause) {
        error.OutOfMemory => PANCAKE_ERR_INTERNAL,
        error.Closed, error.Closing => PANCAKE_ERR_CLOSED,
        else => PANCAKE_ERR_IO,
    };
}

fn multiplexedTransport(runtime: *MultiplexedRuntime) c.PancakeMultiplexedTransport {
    return .{
        .abi_version = multiplexed.PANCAKE_MULTIPLEXED_TRANSPORT_ABI_VERSION,
        .struct_size = @sizeOf(c.PancakeMultiplexedTransport),
        .ctx = runtime,
        .readiness_fd = multiplexedReadinessFd,
        .drain_ready = multiplexedDrainReady,
        .start_connect = multiplexedStartConnect,
        .finish_connect = multiplexedFinishConnect,
        .cancel_connect = multiplexedCancelConnect,
        .listen = multiplexedListen,
        .finish_listen = multiplexedFinishListen,
        .cancel_listen = multiplexedCancelListen,
        .listener_locator = multiplexedListenerLocatorShim,
        .listener_advertise = multiplexedListenerAdvertiseShim,
        .finish_accept = multiplexedFinishAccept,
        .stop_listen = multiplexedStopListen,
        .try_read = multiplexedTryRead,
        .try_write = multiplexedTryWrite,
        .conn_close = multiplexedConnClose,
        .conn_take_failure = multiplexedConnTakeFailure,
        .conn_remote_key = multiplexedConnRemoteKey,
    };
}

fn multiplexedReadinessFd(ctx: ?*anyopaque) callconv(.c) i32 {
    return runtimeFrom(ctx).ready_wake.read;
}

fn multiplexedDrainReady(
    ctx: ?*anyopaque,
    out: ?[*]c.PancakeMultiplexedReadyEvent,
    cap: usize,
    out_count: ?*usize,
    out_failure: ?*c.PancakeProviderFailure,
) callconv(.c) i32 {
    const runtime = runtimeFrom(ctx);
    const count_slot = out_count orelse return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer);
    const output = out orelse if (cap == 0) null else return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer);
    runtime.ready_wake.drain() catch {
        runtime.noteFailure(error.WakeDrainFailed);
        failRuntime(runtime);
        return c.transport_provider.failProvider(out_failure, c.PANCAKE_ERR_IO, error.WakeDrainFailed);
    };
    runtime.mutex.lock();
    defer runtime.mutex.unlock();
    var total: usize = 0;

    switch (runtime.listener) {
        .starting => |setup| if (setup.state != .running and setup.state != .cancelled and
            !setup.announced and total < cap)
        {
            setup.announced = true;
            output.?[total] = .{ .subject = setup.route_id, .events = EV_LISTEN };
            total += 1;
        },
        .active => |listener| {
            const events = listener.events.fetchAnd(0, .acq_rel);
            if (events != 0 and total < cap) {
                output.?[total] = .{ .subject = listener.route_id, .events = events & EV_ACCEPT };
                total += 1;
            }
        },
        .empty => {},
    }
    for (runtime.jobs.items) |job| {
        if (total == cap) break;
        if (job.state == .running or job.announced) continue;
        job.announced = true;
        output.?[total] = .{ .subject = job.request_id, .events = EV_CONNECT };
        total += 1;
    }
    for (runtime.connections.items) |conn| {
        if (total == cap) break;
        const events = conn.events.fetchAnd(0, .acq_rel);
        if (events == 0) continue;
        output.?[total] = .{ .subject = conn.id, .events = events };
        total += 1;
    }
    if (hasReadyLocked(runtime)) runtime.signalReady();
    if (total != 0) runtime.signalControl();
    count_slot.* = total;
    return PANCAKE_OK;
}

fn hasReadyLocked(runtime: *MultiplexedRuntime) bool {
    switch (runtime.listener) {
        .starting => |setup| if (setup.state != .running and setup.state != .cancelled and !setup.announced)
            return true,
        .active => |listener| if (listener.events.load(.acquire) != 0) return true,
        .empty => {},
    }
    for (runtime.jobs.items) |job| {
        if (job.state != .running and !job.announced) return true;
    }
    for (runtime.connections.items) |conn| {
        if (conn.events.load(.acquire) != 0) return true;
    }
    return false;
}

fn multiplexedStartConnect(
    ctx: ?*anyopaque,
    request_id: u64,
    locator_view: ?*const c.PancakeLocatorView,
    options: ?*const c.PancakeTransportOperationOptions,
    out_failure: ?*c.PancakeProviderFailure,
) callconv(.c) i32 {
    if (!c.transport_provider.operationOptionsAreInherited(options))
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_INVALID_ARGUMENT, error.InvalidOptions);
    const runtime = runtimeFrom(ctx);
    const view = locator_view orelse return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer);
    var hint_stack: [c.locator_adapter.inline_hint_capacity]model.HintEntry = undefined;
    var borrowed = c.locator_adapter.BorrowedLocator.init(runtime.allocator, view, &hint_stack) catch |err| {
        const code = c.locatorAdapterErrorCode(err);
        return c.transport_provider.failProvider(out_failure, code, err);
    };
    defer borrowed.deinit(runtime.allocator);
    runtime.startDial(request_id, borrowed.value) catch |err| {
        const code = dialErrorCode(err);
        return c.transport_provider.failProvider(out_failure, code, err);
    };
    runtime.signalControl();
    return PANCAKE_OK;
}

fn multiplexedFinishConnect(
    ctx: ?*anyopaque,
    request_id: u64,
    out_conn: ?*u64,
    out_failure: ?*c.PancakeProviderFailure,
) callconv(.c) i32 {
    const runtime = runtimeFrom(ctx);
    const slot = out_conn orelse {
        runtime.cancelDial(request_id);
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer);
    };
    const id = runtime.finishDial(request_id) catch |err| {
        const code = dialErrorCode(err);
        return c.transport_provider.failProvider(out_failure, code, err);
    };
    slot.* = id;
    return PANCAKE_OK;
}

fn multiplexedCancelConnect(ctx: ?*anyopaque, request_id: u64, _: ?*c.PancakeProviderFailure) callconv(.c) i32 {
    runtimeFrom(ctx).cancelDial(request_id);
    return PANCAKE_OK;
}

fn multiplexedListen(
    ctx: ?*anyopaque,
    route_id: u64,
    transport: ?[*]const u8,
    transport_len: usize,
    requested_designator: ?[*]const u8,
    requested_designator_len: usize,
    options: ?*const c.PancakeTransportOperationOptions,
    out_result: ?*c.PancakeListenResult,
) callconv(.c) i32 {
    if (!c.transport_provider.operationOptionsAreInherited(options)) return PANCAKE_ERR_INVALID_ARGUMENT;
    const runtime = runtimeFrom(ctx);
    const result = out_result orelse return PANCAKE_ERR_NULL_POINTER;
    const transport_bytes = c.sliceFromC(transport, transport_len) catch return PANCAKE_ERR_NULL_POINTER;
    const requested = c.sliceFromC(requested_designator, requested_designator_len) catch
        return PANCAKE_ERR_NULL_POINTER;
    const listener = runtime.listen(route_id, transport_bytes, requested) catch |err| return switch (err) {
        error.InvalidAddress => PANCAKE_ERR_INVALID_ARGUMENT,
        error.OutOfMemory => PANCAKE_ERR_INTERNAL,
        else => PANCAKE_ERR_IO,
    };
    result.* = switch (listener) {
        .ready => |value| .{
            .state = c.PANCAKE_LISTEN_READY,
            .listener = value,
            .attempt = null,
            .readiness_fd = -1,
        },
        .pending => .{
            .state = c.PANCAKE_LISTEN_PENDING,
            .listener = null,
            .attempt = null,
            .readiness_fd = -1,
        },
    };
    return PANCAKE_OK;
}

fn multiplexedFinishListen(
    ctx: ?*anyopaque,
    route_id: u64,
    out_listener: ?*?*anyopaque,
) callconv(.c) i32 {
    const runtime = runtimeFrom(ctx);
    const slot = out_listener orelse {
        runtime.cancelListen(route_id);
        return PANCAKE_ERR_NULL_POINTER;
    };
    const listener = runtime.finishListen(route_id) catch |err| return switch (err) {
        error.InvalidAddress => PANCAKE_ERR_INVALID_ARGUMENT,
        error.OutOfMemory => PANCAKE_ERR_INTERNAL,
        else => PANCAKE_ERR_IO,
    };
    slot.* = listener;
    return PANCAKE_OK;
}

fn multiplexedCancelListen(ctx: ?*anyopaque, route_id: u64, _: ?*c.PancakeProviderFailure) callconv(.c) i32 {
    runtimeFrom(ctx).cancelListen(route_id);
    return PANCAKE_OK;
}

fn multiplexedListenerLocatorShim(
    ctx: ?*anyopaque,
    sink_ctx: ?*anyopaque,
    sink: c.PancakeLocatorSinkFn,
) callconv(.c) i32 {
    const listener = listenerFrom(ctx);
    if (listener.stopped.load(.acquire)) return PANCAKE_ERR_CLOSED;
    var hints: [c.locator_adapter.inline_hint_capacity]c.PancakeLocatorHintView = undefined;
    var projection = c.locator_adapter.Projection.init(listener.runtime.allocator, listener.locator, &hints) catch |err|
        return c.locatorAdapterErrorCode(err);
    defer projection.deinit(listener.runtime.allocator);
    return sink(sink_ctx, &projection.view);
}

fn multiplexedListenerAdvertiseShim(
    ctx: ?*anyopaque,
    locator_view: ?*const c.PancakeLocatorView,
    sink_ctx: ?*anyopaque,
    sink: c.PancakeLocatorSinkFn,
) callconv(.c) i32 {
    const listener = listenerFrom(ctx);
    if (listener.stopped.load(.acquire)) return PANCAKE_ERR_CLOSED;
    const view = locator_view orelse return PANCAKE_ERR_NULL_POINTER;
    var hints: [c.locator_adapter.inline_hint_capacity]model.HintEntry = undefined;
    var borrowed = c.locator_adapter.BorrowedLocator.init(listener.runtime.allocator, view, &hints) catch |err|
        return c.locatorAdapterErrorCode(err);
    defer borrowed.deinit(listener.runtime.allocator);
    listener.io_mutex.lock();
    defer listener.io_mutex.unlock();
    const canonical = listener.raw.canonicalizeLocator(listener.runtime.allocator, borrowed.value) catch
        return PANCAKE_ERR_INVALID_ARGUMENT;
    defer model.freePeerLocator(listener.runtime.allocator, canonical);
    var canonical_hints: [c.locator_adapter.inline_hint_capacity]c.PancakeLocatorHintView = undefined;
    var projection = c.locator_adapter.Projection.init(listener.runtime.allocator, canonical, &canonical_hints) catch |err|
        return c.locatorAdapterErrorCode(err);
    defer projection.deinit(listener.runtime.allocator);
    return sink(sink_ctx, &projection.view);
}

fn multiplexedFinishAccept(listener_raw: ?*anyopaque, out_conn: ?*u64, out_failure: ?*c.PancakeProviderFailure) callconv(.c) i32 {
    const listener = listenerFrom(listener_raw);
    const slot = out_conn orelse return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer);
    if (listener.stopped.load(.acquire)) return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_CLOSED, error.Closed);
    if (listener.failed.load(.acquire)) return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_IO, error.ConnectionLost);
    listener.io_mutex.lock();
    defer listener.io_mutex.unlock();
    const acceptable = listener.raw.waitAcceptable(0) catch |err| return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_IO, err);
    if (!acceptable) return PANCAKE_ERR_WOULD_BLOCK;
    var raw = listener.raw.accept(listener.runtime.allocator) catch |err| return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_IO, err);
    var owned_raw = true;
    defer if (owned_raw) raw.close();
    const conn = listener.runtime.allocator.create(ConnState) catch |err|
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_INTERNAL, err);
    conn.* = .{ .runtime = listener.runtime, .id = 0, .raw = raw };
    owned_raw = false;
    listener.runtime.mutex.lock();
    defer listener.runtime.mutex.unlock();
    const id = listener.runtime.addConnectionLocked(conn) catch |err| {
        conn.raw.close();
        listener.runtime.allocator.destroy(conn);
        const code: i32 = if (err == error.OutOfMemory) PANCAKE_ERR_INTERNAL else PANCAKE_ERR_CLOSED;
        return c.transport_provider.failProvider(out_failure, code, err);
    };
    slot.* = id;
    listener.runtime.signalControl();
    return PANCAKE_OK;
}

fn multiplexedStopListen(listener_raw: ?*anyopaque, _: ?*c.PancakeProviderFailure) callconv(.c) i32 {
    const listener = listenerFrom(listener_raw);
    listener.runtime.stopListen(listener);
    return PANCAKE_OK;
}

fn multiplexedTryRead(ctx: ?*anyopaque, conn_id: u64, buf: ?[*]u8, cap: usize) callconv(.c) isize {
    const runtime = runtimeFrom(ctx);
    const dest = buf orelse return -1;
    runtime.mutex.lock();
    const state = runtime.findConnectionLocked(conn_id) orelse {
        runtime.mutex.unlock();
        return -1;
    };
    state.io_mutex.lock();
    runtime.mutex.unlock();
    defer state.io_mutex.unlock();
    if (state.closed.load(.acquire)) return -1;
    if (state.raw_closed or state.closed.load(.acquire)) return -1;
    const got = state.raw.tryRead(dest[0..cap]);
    if (got < 0 and c.transport_provider.providerFailureEmpty(state.failure))
        c.transport_provider.setProviderFailure(&state.failure, PANCAKE_ERR_IO, error.ConnectionLost);
    return got;
}

fn multiplexedTryWrite(ctx: ?*anyopaque, conn_id: u64, bytes: ?[*]const u8, len: usize) callconv(.c) isize {
    const runtime = runtimeFrom(ctx);
    const source = bytes orelse return -1;
    runtime.mutex.lock();
    const state = runtime.findConnectionLocked(conn_id) orelse {
        runtime.mutex.unlock();
        return -1;
    };
    state.io_mutex.lock();
    runtime.mutex.unlock();
    defer state.io_mutex.unlock();
    if (state.closed.load(.acquire)) return -1;
    if (state.raw_closed or state.closed.load(.acquire)) return -1;
    const wrote = state.raw.tryWrite(source[0..len]);
    if (wrote < 0 and c.transport_provider.providerFailureEmpty(state.failure))
        c.transport_provider.setProviderFailure(&state.failure, PANCAKE_ERR_IO, error.ConnectionLost);
    if (state.raw.hasPendingWrite()) runtime.signalControl();
    return wrote;
}

fn multiplexedConnTakeFailure(ctx: ?*anyopaque, conn_id: u64, out_failure: ?*c.PancakeProviderFailure) callconv(.c) void {
    const slot = out_failure orelse return;
    slot.* = std.mem.zeroes(c.PancakeProviderFailure);
    const runtime = runtimeFrom(ctx);
    runtime.mutex.lock();
    const state = runtime.findConnectionLocked(conn_id) orelse {
        runtime.mutex.unlock();
        return;
    };
    state.io_mutex.lock();
    runtime.mutex.unlock();
    defer state.io_mutex.unlock();
    slot.* = state.failure;
    state.failure = std.mem.zeroes(c.PancakeProviderFailure);
}

fn multiplexedConnClose(ctx: ?*anyopaque, conn_id: u64, _: ?*c.PancakeProviderFailure) callconv(.c) i32 {
    const runtime = runtimeFrom(ctx);
    runtime.mutex.lock();
    const state = runtime.findConnectionLocked(conn_id) orelse {
        runtime.mutex.unlock();
        return PANCAKE_OK;
    };
    if (state.closed.swap(true, .acq_rel)) {
        runtime.mutex.unlock();
        return PANCAKE_OK;
    }
    _ = state.events.fetchAnd(0, .acq_rel);
    runtime.mutex.unlock();
    runtime.signalControl();
    return PANCAKE_OK;
}

fn multiplexedConnRemoteKey(_: ?*anyopaque, _: u64, _: ?[*]u8) callconv(.c) i32 {
    // A relay authenticates neither endpoint. Noise, when selected, is a Host
    // channel and its verified key belongs to the Host session, not this ABI.
    return 0;
}

pub export fn pancake_relay_last_error(out_buf: ?[*]u8, cap: usize) usize {
    return c.lastErrorRead(out_buf, cap);
}

pub export fn pancake_relay_clear_last_error() void {
    c.lastErrorClear();
}

pub export fn pancake_relay_runtime_new(
    config: ?*const PancakeRelayConfig,
    out_runtime: ?*?*PancakeRelayRuntime,
) i32 {
    const slot = out_runtime orelse return PANCAKE_ERR_NULL_POINTER;
    return netlayerNewIn(c.library_allocator, config, slot);
}

pub export fn pancake_relay_runtime_new_in(
    context: ?*PancakeContext,
    config: ?*const PancakeRelayConfig,
    out_runtime: ?*?*PancakeRelayRuntime,
) i32 {
    const c_ctx = c.ctxFromOpaque(context) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_runtime orelse return PANCAKE_ERR_NULL_POINTER;
    return netlayerNewIn(c_ctx.allocator(), config, slot);
}

fn netlayerNewIn(
    allocator: std.mem.Allocator,
    config: ?*const PancakeRelayConfig,
    slot: *?*PancakeRelayRuntime,
) i32 {
    slot.* = null;
    const cfg = config orelse return PANCAKE_ERR_NULL_POINTER;
    const relay_url = c.sliceFromC(cfg.relay_url, cfg.relay_url_len) catch |err| {
        c.setLastError("relay runtime_new: invalid relay_url view: {s}", .{@errorName(err)});
        return c.marshalErrorToCode(err);
    };
    const register_url = c.sliceFromC(cfg.register_url, cfg.register_url_len) catch |err| {
        c.setLastError("relay runtime_new: invalid register_url view: {s}", .{@errorName(err)});
        return c.marshalErrorToCode(err);
    };
    if (relay_url.len == 0) {
        c.setLastError("relay runtime_new: relay_url must not be empty", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    }

    const payload = allocator.create(Payload) catch |err|
        return c.failInternal("relay runtime_new", err);
    payload.threaded = std.Io.Threaded.init(allocator, .{});
    payload.allocator = allocator;
    payload.references = .init(1);
    payload.keyed = (if (register_url.len == 0)
        net.relay.Resident.initProfile(allocator, payload.io(), relay_url, .keyed)
    else
        net.relay.Resident.initProviderProfile(allocator, payload.io(), relay_url, register_url, .keyed)) catch |err| {
        payload.threaded.deinit();
        allocator.destroy(payload);
        if (err == error.InvalidRelayUrl) {
            c.setLastError("relay runtime_new: invalid relay URL", .{});
            return PANCAKE_ERR_INVALID_ARGUMENT;
        }
        return c.failInternal("relay runtime_new keyed profile", err);
    };
    payload.noise = (if (register_url.len == 0)
        net.relay.Resident.initProfile(allocator, payload.io(), relay_url, .noise)
    else
        net.relay.Resident.initProviderProfile(allocator, payload.io(), relay_url, register_url, .noise)) catch |err| {
        payload.keyed.deinit();
        payload.threaded.deinit();
        allocator.destroy(payload);
        if (err == error.InvalidRelayUrl) {
            c.setLastError("relay runtime_new: invalid relay URL", .{});
            return PANCAKE_ERR_INVALID_ARGUMENT;
        }
        return c.failInternal("relay runtime_new noise profile", err);
    };
    payload.runtime.init(payload) catch |err| {
        payload.noise.deinit();
        payload.keyed.deinit();
        payload.threaded.deinit();
        allocator.destroy(payload);
        return c.failInternal("relay runtime_new scheduler", err);
    };
    payload.initProvider();
    slot.* = @ptrCast(payload);
    return PANCAKE_OK;
}

pub export fn pancake_relay_transport_provider(
    runtime: ?*PancakeRelayRuntime,
    out_provider: ?*c.PancakeTransportProvider,
) i32 {
    const payload = payloadFromOpaque(runtime) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_provider orelse return PANCAKE_ERR_NULL_POINTER;
    slot.* = payload.provider;
    return PANCAKE_OK;
}

pub export fn pancake_relay_runtime_release(runtime: ?*PancakeRelayRuntime) i32 {
    c.lastErrorClear();
    const payload = payloadFromOpaque(runtime) orelse return PANCAKE_OK;
    if (payload.release()) |failure| {
        setReleaseFailure("relay runtime release", failure);
        return releaseErrorCode(failure.cause);
    }
    return PANCAKE_OK;
}

pub export fn pancake_relay_runtime_release_with_diagnostic(
    runtime: ?*PancakeRelayRuntime,
    out_error: ?[*]u8,
    error_cap: usize,
    out_error_len: ?*usize,
) i32 {
    const len = out_error_len orelse {
        c.lastErrorClear();
        return PANCAKE_ERR_NULL_POINTER;
    };
    return c.captureCallError(
        pancake_relay_runtime_release(runtime),
        out_error,
        error_cap,
        len,
    );
}
