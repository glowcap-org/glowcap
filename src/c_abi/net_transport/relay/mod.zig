//! The native relay multiplexed provider archive.
//!
//! The archive owns one multiplexed runtime and advertises two profiles through
//! it: clear `keyed-relay` and Host-sealed `noise-relay`. The runtime moves
//! opaque WebSocket bytes only. CapTP framing and Noise_XK remain Host policy,
//! selected by the profile metadata consumed by the driver.

const std = @import("std");

const crypto = @import("foundation").crypto;
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
    keyed: net.keyed_relay.Resident,
    noise: net.keyed_relay.Resident,
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

    fn release(self: *Payload) void {
        if (self.references.fetchSub(1, .acq_rel) != 1) return;
        self.runtime.deinit();
        self.noise.deinit();
        self.keyed.deinit();
        self.threaded.deinit();
        self.allocator.destroy(self);
    }
};

const ConnState = struct {
    runtime: *MultiplexedRuntime,
    id: u64,
    raw: net.keyed_relay.RawConnection,
    io_mutex: net.sync.SpinLock = .{},
    events: std.atomic.Value(u32) = .init(0),
    closed: std.atomic.Value(bool) = .init(false),
    raw_closed: bool = false,
};

const ListenerState = struct {
    runtime: *MultiplexedRuntime,
    raw: net.keyed_relay.RawListener,
    locator: model.PeerLocator,
    route_id: u64,
    io_mutex: net.sync.SpinLock = .{},
    stopped: std.atomic.Value(bool) = .init(false),
    closed: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
    events: std.atomic.Value(u32) = .init(0),
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
    cancelled: bool = false,

    const State = enum { running, succeeded, failed };

    fn run(job: *DialState) std.Io.Cancelable!void {
        const runtime = job.runtime;
        const raw = runtime.resident(job.profile).dialRaw(job.locator) catch |err| {
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
        if (runtime.stopping.load(.acquire) or job.cancelled) {
            if (job.cancelled) removeJobLocked(runtime, job);
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
};

const PollSubject = union(enum) {
    wake,
    listener: *ListenerState,
    connection: *ConnState,
};

/// The relay rendezvous route is keyed by durable designator, not channel
/// profile, so one runtime owns one logical listener route at a time.
const ListenerSlot = union(enum) {
    empty,
    starting,
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

    fn deinit(self: *MultiplexedRuntime) void {
        self.stopping.store(true, .release);
        self.control_wake.nudge();
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }

        self.tasks.shutdown();
        self.tasks.join();

        self.mutex.lock();
        switch (self.listener) {
            .empty, .starting => {},
            .active => |listener| destroyListenerLocked(self, listener),
        }
        self.listener = .empty;
        for (self.connections.items) |conn| {
            closeConnectionLocked(conn);
            self.allocator.destroy(conn);
        }
        for (self.jobs.items) |job| destroyDialLocked(self, job);
        self.jobs.clearRetainingCapacity();
        self.mutex.unlock();

        self.jobs.deinit(self.allocator);
        self.connections.deinit(self.allocator);
        self.by_id.deinit();
        self.pollfds.deinit(self.allocator);
        self.subjects.deinit(self.allocator);
        self.ready_wake.deinit();
        self.control_wake.deinit();
    }

    fn resident(self: *MultiplexedRuntime, profile: Profile) *net.keyed_relay.Resident {
        return switch (profile) {
            .keyed => &self.payload.keyed,
            .noise => &self.payload.noise,
        };
    }

    fn signalControl(self: *MultiplexedRuntime) void {
        self.control_wake.nudge();
    }

    fn signalReady(self: *MultiplexedRuntime) void {
        self.ready_wake.nudge();
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
        if (job.cancelled) {
            removeJobLocked(self, job);
            return;
        }
        job.state = .failed;
        job.error_code = code;
        self.signalReady();
    }

    fn startConnect(self: *MultiplexedRuntime, request_id: u64, locator: model.PeerLocator) !void {
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
        self.tasks.start(DialState.run, .{job}) catch |err| {
            _ = self.jobs.pop();
            return switch (err) {
                error.Closing => error.ConnectionLost,
                error.ConcurrencyUnavailable => error.OutOfMemory,
            };
        };
    }

    fn finishConnect(self: *MultiplexedRuntime, request_id: u64) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const job = self.findJobLocked(request_id) orelse return error.ConnectionLost;
        switch (job.state) {
            .running => return error.ConnectionLost,
            .failed => {
                const code = job.error_code;
                removeJobLocked(self, job);
                return switch (code) {
                    PANCAKE_ERR_INVALID_ARGUMENT => error.InvalidAddress,
                    PANCAKE_ERR_TIMEOUT => error.TimedOut,
                    PANCAKE_ERR_INTERNAL => error.OutOfMemory,
                    else => error.ConnectionLost,
                };
            },
            .succeeded => {
                const conn = job.conn orelse return error.ConnectionLost;
                const id = conn.id;
                removeJobLocked(self, job);
                return id;
            },
        }
    }

    fn cancelConnect(self: *MultiplexedRuntime, request_id: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const job = self.findJobLocked(request_id) orelse return;
        job.cancelled = true;
        if (job.state != .running) {
            if (job.conn) |conn| conn.closed.store(true, .release);
            removeJobLocked(self, job);
        }
        self.signalControl();
    }

    fn startListen(
        self: *MultiplexedRuntime,
        route_id: u64,
        transport: []const u8,
        requested_designator: []const u8,
    ) !*anyopaque {
        const profile = profileForTransport(transport) orelse return error.InvalidAddress;
        const identity = crypto.PeerKey.fromDesignator(requested_designator) orelse
            return error.InvalidAddress;

        self.mutex.lock();
        switch (self.listener) {
            .empty => self.listener = .starting,
            .starting, .active => {
                self.mutex.unlock();
                return error.BindFailed;
            },
        }
        self.mutex.unlock();
        defer {
            self.mutex.lock();
            switch (self.listener) {
                .starting => self.listener = .empty,
                .empty, .active => {},
            }
            self.mutex.unlock();
        }

        var raw = self.resident(profile).listenRaw(self.allocator, .{
            .designator = requested_designator,
            .identity = identity,
        }) catch |err| return err;
        var owns_raw = true;
        defer if (owns_raw) raw.close();
        if (!(raw.waitReady(-1) catch return error.BindFailed)) return error.BindFailed;
        const locator = try raw.localLocator(self.allocator);
        var owns_locator = true;
        defer if (owns_locator) model.freePeerLocator(self.allocator, locator);
        const listener = try self.allocator.create(ListenerState);
        var owns_listener = true;
        defer if (owns_listener) destroyListenerLocked(self, listener);
        listener.* = .{
            .runtime = self,
            .raw = raw,
            .locator = locator,
            .route_id = route_id,
        };
        owns_locator = false;
        raw = undefined;
        owns_raw = false;

        self.mutex.lock();
        defer self.mutex.unlock();
        const reserved = switch (self.listener) {
            .starting => true,
            .empty, .active => false,
        };
        if (self.stopping.load(.acquire) or !reserved) return error.BindFailed;
        self.listener = .{ .active = listener };
        owns_listener = false;
        self.signalControl();
        return listener;
    }

    fn stopListen(self: *MultiplexedRuntime, listener: *ListenerState) void {
        if (listener.stopped.swap(true, .acq_rel)) return;
        self.signalControl();
    }
};

fn destroyDialLocked(runtime: *MultiplexedRuntime, job: *DialState) void {
    model.freePeerLocator(runtime.allocator, job.locator);
    runtime.allocator.destroy(job);
}

fn removeJobLocked(runtime: *MultiplexedRuntime, job: *DialState) void {
    for (runtime.jobs.items, 0..) |candidate, i| {
        if (candidate == job) {
            const removed = runtime.jobs.swapRemove(i);
            std.debug.assert(removed == job);
            destroyDialLocked(runtime, job);
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

fn closeListenerLocked(listener: *ListenerState) void {
    listener.io_mutex.lock();
    defer listener.io_mutex.unlock();
    if (listener.closed.swap(true, .acq_rel)) return;
    listener.raw.close();
}

fn destroyListenerLocked(runtime: *MultiplexedRuntime, listener: *ListenerState) void {
    closeListenerLocked(listener);
    model.freePeerLocator(runtime.allocator, listener.locator);
    runtime.allocator.destroy(listener);
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
        if (!rebuildPollSet(runtime)) {
            failRuntime(runtime);
            return;
        }
        const ready = net.poll.wait(runtime.pollfds.items, -1) catch return;
        if (runtime.stopping.load(.acquire)) return;
        if (ready == 0) continue;

        for (runtime.pollfds.items, runtime.subjects.items) |pollfd, subject| {
            const revents = pollfd.revents;
            if (revents == 0) continue;
            switch (subject) {
                .wake => runtime.control_wake.drain(),
                .listener => |listener| reactorListener(runtime, listener, revents),
                .connection => |conn| reactorConnection(runtime, conn, revents),
            }
        }
        reapClosedConnections(runtime);
        reapStoppedListener(runtime);
    }
}

fn rebuildPollSet(runtime: *MultiplexedRuntime) bool {
    runtime.mutex.lock();
    defer runtime.mutex.unlock();
    runtime.pollfds.clearRetainingCapacity();
    runtime.subjects.clearRetainingCapacity();
    const listener_count: usize = switch (runtime.listener) {
        .active => |listener| @intFromBool(!listener.stopped.load(.acquire)),
        .empty, .starting => 0,
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
        .empty, .starting => {},
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

fn reactorListener(runtime: *MultiplexedRuntime, listener: *ListenerState, revents: c_short) void {
    if (listener.stopped.load(.acquire)) return;
    const bad = revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL) != 0;
    listener.io_mutex.lock();
    defer listener.io_mutex.unlock();
    if (listener.closed.load(.acquire)) return;
    if (bad or !(listener.raw.waitAcceptable(0) catch false)) {
        if (bad) listener.failed.store(true, .release);
        if (!bad) return;
    }
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
            destroyListenerLocked(runtime, listener);
            runtime.listener = .empty;
        },
        .empty, .starting => {},
    }
}

fn failRuntime(runtime: *MultiplexedRuntime) void {
    runtime.mutex.lock();
    defer runtime.mutex.unlock();
    switch (runtime.listener) {
        .active => |listener| {
            listener.failed.store(true, .release);
            _ = listener.events.fetchOr(EV_ACCEPT, .acq_rel);
        },
        .empty, .starting => {},
    }
    for (runtime.jobs.items) |job| {
        if (job.state == .running) {
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

fn providerRetain(ctx: ?*anyopaque) callconv(.c) i32 {
    const payload: *Payload = @ptrCast(@alignCast(ctx orelse return PANCAKE_ERR_NULL_POINTER));
    return if (payload.retain()) PANCAKE_OK else PANCAKE_ERR_CLOSED;
}

fn providerRelease(ctx: ?*anyopaque) callconv(.c) void {
    const payload: *Payload = @ptrCast(@alignCast(ctx orelse return));
    payload.release();
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
        .start_listen = multiplexedStartListen,
        .listener_locator = multiplexedListenerLocatorShim,
        .listener_advertise = multiplexedListenerAdvertiseShim,
        .finish_accept = multiplexedFinishAccept,
        .stop_listen = multiplexedStopListen,
        .try_read = multiplexedTryRead,
        .try_write = multiplexedTryWrite,
        .conn_close = multiplexedConnClose,
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
) callconv(.c) usize {
    const runtime = runtimeFrom(ctx);
    const output = out orelse return 0;
    if (cap == 0) return 0;
    runtime.ready_wake.drain();
    runtime.mutex.lock();
    defer runtime.mutex.unlock();
    var total: usize = 0;

    switch (runtime.listener) {
        .active => |listener| {
            const events = listener.events.fetchAnd(0, .acq_rel);
            if (events != 0 and total < cap) {
                output[total] = .{ .subject = listener.route_id, .events = events & EV_ACCEPT };
                total += 1;
            }
        },
        .empty, .starting => {},
    }
    for (runtime.jobs.items) |job| {
        if (total == cap) break;
        if (job.state == .running or job.announced) continue;
        job.announced = true;
        output[total] = .{ .subject = job.request_id, .events = EV_CONNECT };
        total += 1;
    }
    for (runtime.connections.items) |conn| {
        if (total == cap) break;
        const events = conn.events.fetchAnd(0, .acq_rel);
        if (events == 0) continue;
        output[total] = .{ .subject = conn.id, .events = events };
        total += 1;
    }
    if (hasReadyLocked(runtime)) runtime.signalReady();
    if (total != 0) runtime.signalControl();
    return total;
}

fn hasReadyLocked(runtime: *MultiplexedRuntime) bool {
    switch (runtime.listener) {
        .active => |listener| if (listener.events.load(.acquire) != 0) return true,
        .empty, .starting => {},
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
) callconv(.c) i32 {
    const runtime = runtimeFrom(ctx);
    const view = locator_view orelse return PANCAKE_ERR_NULL_POINTER;
    var hint_stack: [c.locator_adapter.inline_hint_capacity]model.HintEntry = undefined;
    var borrowed = c.locator_adapter.BorrowedLocator.init(runtime.allocator, view, &hint_stack) catch |err|
        return c.locatorAdapterErrorCode(err);
    defer borrowed.deinit(runtime.allocator);
    runtime.startConnect(request_id, borrowed.value) catch |err| return dialErrorCode(err);
    runtime.signalControl();
    return PANCAKE_OK;
}

fn multiplexedFinishConnect(ctx: ?*anyopaque, request_id: u64, out_conn: ?*u64) callconv(.c) i32 {
    const runtime = runtimeFrom(ctx);
    const slot = out_conn orelse return PANCAKE_ERR_NULL_POINTER;
    const id = runtime.finishConnect(request_id) catch |err| return dialErrorCode(err);
    slot.* = id;
    return PANCAKE_OK;
}

fn multiplexedCancelConnect(ctx: ?*anyopaque, request_id: u64) callconv(.c) void {
    runtimeFrom(ctx).cancelConnect(request_id);
}

fn multiplexedStartListen(
    ctx: ?*anyopaque,
    route_id: u64,
    transport: ?[*]const u8,
    transport_len: usize,
    requested_designator: ?[*]const u8,
    requested_designator_len: usize,
    out_listener: ?*?*anyopaque,
) callconv(.c) i32 {
    const runtime = runtimeFrom(ctx);
    const slot = out_listener orelse return PANCAKE_ERR_NULL_POINTER;
    const transport_bytes = c.sliceFromC(transport, transport_len) catch return PANCAKE_ERR_NULL_POINTER;
    const requested = c.sliceFromC(requested_designator, requested_designator_len) catch
        return PANCAKE_ERR_NULL_POINTER;
    const listener = runtime.startListen(route_id, transport_bytes, requested) catch |err| return switch (err) {
        error.InvalidAddress => PANCAKE_ERR_INVALID_ARGUMENT,
        error.OutOfMemory => PANCAKE_ERR_INTERNAL,
        else => PANCAKE_ERR_IO,
    };
    slot.* = listener;
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

fn multiplexedFinishAccept(listener_raw: ?*anyopaque, out_conn: ?*u64) callconv(.c) i32 {
    const listener = listenerFrom(listener_raw);
    const slot = out_conn orelse return PANCAKE_ERR_NULL_POINTER;
    if (listener.stopped.load(.acquire)) return PANCAKE_ERR_CLOSED;
    if (listener.failed.load(.acquire)) return PANCAKE_ERR_IO;
    listener.io_mutex.lock();
    defer listener.io_mutex.unlock();
    const acceptable = listener.raw.waitAcceptable(0) catch return PANCAKE_ERR_IO;
    if (!acceptable) return PANCAKE_ERR_WOULD_BLOCK;
    var raw = listener.raw.accept(listener.runtime.allocator) catch return PANCAKE_ERR_IO;
    var owned_raw = true;
    defer if (owned_raw) raw.close();
    const conn = listener.runtime.allocator.create(ConnState) catch return PANCAKE_ERR_INTERNAL;
    conn.* = .{ .runtime = listener.runtime, .id = 0, .raw = raw };
    owned_raw = false;
    listener.runtime.mutex.lock();
    defer listener.runtime.mutex.unlock();
    const id = listener.runtime.addConnectionLocked(conn) catch |err| {
        conn.raw.close();
        listener.runtime.allocator.destroy(conn);
        return if (err == error.OutOfMemory) PANCAKE_ERR_INTERNAL else PANCAKE_ERR_CLOSED;
    };
    slot.* = id;
    listener.runtime.signalControl();
    return PANCAKE_OK;
}

fn multiplexedStopListen(listener_raw: ?*anyopaque) callconv(.c) void {
    const listener = listenerFrom(listener_raw);
    listener.runtime.stopListen(listener);
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
    return state.raw.tryRead(dest[0..cap]);
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
    if (state.raw.hasPendingWrite()) runtime.signalControl();
    return wrote;
}

fn multiplexedConnClose(ctx: ?*anyopaque, conn_id: u64) callconv(.c) void {
    const runtime = runtimeFrom(ctx);
    runtime.mutex.lock();
    const state = runtime.findConnectionLocked(conn_id) orelse {
        runtime.mutex.unlock();
        return;
    };
    if (state.closed.swap(true, .acq_rel)) {
        runtime.mutex.unlock();
        return;
    }
    _ = state.events.fetchAnd(0, .acq_rel);
    runtime.mutex.unlock();
    runtime.signalControl();
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
    const relay_url = c.sliceFromC(cfg.relay_url, cfg.relay_url_len) catch return PANCAKE_ERR_INVALID_ARGUMENT;
    const register_url = c.sliceFromC(cfg.register_url, cfg.register_url_len) catch return PANCAKE_ERR_INVALID_ARGUMENT;
    if (relay_url.len == 0) return PANCAKE_ERR_INVALID_ARGUMENT;

    const payload = allocator.create(Payload) catch return PANCAKE_ERR_INTERNAL;
    payload.threaded = std.Io.Threaded.init(allocator, .{});
    payload.allocator = allocator;
    payload.references = .init(1);
    payload.keyed = (if (register_url.len == 0)
        net.keyed_relay.Resident.initProfile(allocator, payload.io(), relay_url, .keyed)
    else
        net.keyed_relay.Resident.initProviderProfile(allocator, payload.io(), relay_url, register_url, .keyed)) catch |err| {
        payload.threaded.deinit();
        allocator.destroy(payload);
        return if (err == error.InvalidRelayUrl) PANCAKE_ERR_INVALID_ARGUMENT else PANCAKE_ERR_INTERNAL;
    };
    payload.noise = (if (register_url.len == 0)
        net.keyed_relay.Resident.initProfile(allocator, payload.io(), relay_url, .noise)
    else
        net.keyed_relay.Resident.initProviderProfile(allocator, payload.io(), relay_url, register_url, .noise)) catch |err| {
        payload.keyed.deinit();
        payload.threaded.deinit();
        allocator.destroy(payload);
        return if (err == error.InvalidRelayUrl) PANCAKE_ERR_INVALID_ARGUMENT else PANCAKE_ERR_INTERNAL;
    };
    payload.runtime.init(payload) catch |err| {
        payload.noise.deinit();
        payload.keyed.deinit();
        payload.threaded.deinit();
        allocator.destroy(payload);
        return if (err == error.ConcurrencyUnavailable) PANCAKE_ERR_INTERNAL else PANCAKE_ERR_INTERNAL;
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

pub export fn pancake_relay_runtime_release(runtime: ?*PancakeRelayRuntime) void {
    const payload = payloadFromOpaque(runtime) orelse return;
    payload.release();
}
