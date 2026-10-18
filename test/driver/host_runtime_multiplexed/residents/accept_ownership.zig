//! The accept-capable multiplexed resident whose bookkeeping the lifecycle
//! and provider scenarios interrogate: it counts the runtime's calls, holds a
//! record outside a service, and hands ownership of an accepted session to
//! the runtime. `residents.zig` re-exports it beside the TCP-backed fake.

const std = @import("std");
const glowcap = @import("glowcap");
const residents = @import("../residents.zig");

const model = glowcap.ocapn.model;
const driver = glowcap.driver;
const driver_core = driver.core;
const net = glowcap.net;

const opts = residents.opts;

pub const AcceptOwnershipResident = struct {
    wake: net.wake_channel.WakeChannel,
    accept_ready: bool = false,
    claimed: bool = false,
    close_calls: usize = 0,
    drain_calls: usize = 0,
    /// A record reaped outside a service, which no descriptor reports.
    held_record: ?net.multiplexed_resident.ReadyEvent = null,
    /// How often the runtime said it was about to park.
    before_wait_calls: usize = 0,
    reap_calls: usize = 0,
    /// A record that appears on this reap, as a reply landing inside a
    /// spinning runtime's window would.
    reap_record_at: ?usize = null,
    listen_calls: usize = 0,
    listeners: [2]Listener = undefined,
    listener_count: usize = 0,
    accept_route: ?usize = null,
    dialed: [2]bool = @splat(false),
    hold_connect: bool = false,
    pending_connect: ?usize = null,
    pending_listener: ?usize = null,
    fail_drain: bool = false,
    fail_listener_finish: bool = false,
    cancel_connect_calls: usize = 0,
    cancel_listen_calls: usize = 0,
    fail_cancel_connect: bool = false,
    /// When set, draining leaves the readiness descriptor readable, so the
    /// resident reports ready on every wait.
    keep_ready: bool = false,
    /// When set, every dial start refuses with exactly this failure.
    dial_failure: ?net.netlayer.DialFailure = null,

    pub const transport = "x-accept-ownership";
    pub const alternate_transport = "x-accept-ownership-alt";
    const conn_id: usize = 41;

    const Listener = struct {
        resident: *AcceptOwnershipResident,
        transport: []const u8,
        route: usize,
        active: bool = true,
    };

    pub fn init() !AcceptOwnershipResident {
        return .{ .wake = try net.wake_channel.WakeChannel.open() };
    }

    pub fn deinit(self: *AcceptOwnershipResident) void {
        self.wake.deinit();
    }

    pub fn announceAccept(self: *AcceptOwnershipResident) void {
        for (self.listeners[0..self.listener_count]) |listener| {
            if (listener.active) return self.announceAcceptFor(listener.transport);
        }
        unreachable;
    }

    pub fn announceAcceptFor(self: *AcceptOwnershipResident, selected: []const u8) void {
        std.debug.assert(!self.accept_ready and !self.claimed);
        for (self.listeners[0..self.listener_count]) |listener| {
            if (listener.active and std.mem.eql(u8, listener.transport, selected)) {
                self.accept_route = listener.route;
                break;
            }
        }
        std.debug.assert(self.accept_route != null);
        self.accept_ready = true;
        _ = self.wake.nudge() catch unreachable;
    }

    pub fn multiplexedResident(self: *AcceptOwnershipResident) net.MultiplexedResident {
        return .{ .ctx = self, .vtable = &vtable };
    }

    pub const vtable = net.MultiplexedResident.VTable{
        .readiness_fd = readinessFd,
        .ready_pending = readyPending,
        .before_wait = beforeWait,
        .reap = reap,
        .drain_ready = drainReady,
        .dial = .{
            .start_connect = startConnect,
            .finish_connect = finishConnect,
            .cancel_connect = cancelConnect,
        },
        .listen = .{
            .listen = listen,
            .completion = .{
                .finish = finishListen,
                .cancel = cancelListen,
            },
            .local_locator = net.MultiplexedResident.adaptListenerLocator(localLocator),
            .canonicalize_locator = net.MultiplexedResident.adaptListenerCanonicalize(canonicalizeLocator),
            .finish_accept = net.MultiplexedResident.adaptFinishAccept(finishAccept),
            .stop_listen = stopListen,
        },
        .try_read = tryRead,
        .try_write = tryWrite,
        .conn_close = connClose,
        .conn_remote_key = connRemoteKey,
    };

    fn of(ctx: *anyopaque) *AcceptOwnershipResident {
        return @ptrCast(@alignCast(ctx));
    }

    fn readinessFd(ctx: *anyopaque) i32 {
        return of(ctx).wake.read;
    }

    fn readyPending(ctx: *anyopaque) bool {
        return of(ctx).held_record != null;
    }

    fn beforeWait(ctx: *anyopaque, _: net.multiplexed_resident.AfterTurn) void {
        of(ctx).before_wait_calls += 1;
    }

    fn reap(ctx: *anyopaque) void {
        const self = of(ctx);
        self.reap_calls += 1;
        if (self.reap_record_at) |at| if (self.reap_calls == at) {
            self.held_record = .{ .subject = 404, .events = net.multiplexed_resident.ev_writable };
        };
    }

    fn drainReady(ctx: *anyopaque, out: []net.multiplexed_resident.ReadyEvent) net.multiplexed_resident.ContractError!usize {
        const self = of(ctx);
        self.drain_calls += 1;
        if (!self.keep_ready) self.wake.drain() catch unreachable;
        if (self.fail_drain) return error.ProviderContract;
        if (out.len == 0) return 0;
        if (self.held_record) |record| {
            self.held_record = null;
            out[0] = record;
            return 1;
        }
        if (self.pending_listener != null) {
            out[0] = .{ .subject = self.pending_listener.?, .events = net.multiplexed_resident.ev_listen };
            return 1;
        }
        if (!self.accept_ready) return 0;
        self.accept_ready = false;
        out[0] = .{
            .subject = self.accept_route orelse return 0,
            .events = net.multiplexed_resident.ev_accept,
        };
        return 1;
    }

    fn transportIndex(selected: []const u8) ?usize {
        if (std.mem.eql(u8, selected, transport)) return 0;
        if (std.mem.eql(u8, selected, alternate_transport)) return 1;
        return null;
    }

    fn canonicalTransport(selected: []const u8) ?[]const u8 {
        return switch (transportIndex(selected) orelse return null) {
            0 => transport,
            1 => alternate_transport,
            else => unreachable,
        };
    }

    fn startConnect(ctx: *anyopaque, request_id: usize, locator: model.PeerLocator, _: net.netlayer.OperationOptions, _: net.netlayer.DialOrigin) net.MultiplexedDialRawStartOutcome {
        const index = transportIndex(locator.transport) orelse
            return .{ .failed = .init(error.InvalidAddress) };
        const self = of(ctx);
        if (self.dial_failure) |failure| return .{ .failed = failure };
        self.dialed[index] = true;
        if (self.hold_connect) {
            self.pending_connect = request_id;
            return .admitted;
        }
        return .{ .failed = .init(error.InvalidAddress) };
    }

    fn finishConnect(_: *anyopaque, _: usize) net.MultiplexedDialRawFinishOutcome {
        return .{ .failed = .init(error.ConnectionLost) };
    }

    fn cancelConnect(ctx: *anyopaque, request_id: usize) ?glowcap.foundation.FailureChain {
        const self = of(ctx);
        self.cancel_connect_calls += 1;
        if (self.pending_connect == request_id) self.pending_connect = null;
        if (self.fail_cancel_connect) {
            var failure = glowcap.foundation.FailureChain.initNamed(error.ConnectionLost, "ResidentCancelFailed");
            failure.noteChain(.initNamed(error.OutOfMemory, "ResidentCancelCleanupFailed"));
            return failure;
        }
        return null;
    }

    fn listen(
        ctx: *anyopaque,
        route_id: usize,
        selected: []const u8,
        _: net.netlayer.ListenConfig,
    ) net.MultiplexedResident.RawListenStartOutcome {
        const self = of(ctx);
        const transport_name = canonicalTransport(selected) orelse
            return .{ .failed = .init(error.InvalidAddress) };
        self.listen_calls += 1;
        if (self.fail_drain or self.fail_listener_finish) {
            self.pending_listener = route_id;
            _ = self.wake.nudge() catch unreachable;
            return .{ .admitted = .pending };
        }
        if (self.listener_count == self.listeners.len)
            return .{ .failed = .init(error.BindFailed) };
        const listener = &self.listeners[self.listener_count];
        self.listener_count += 1;
        listener.* = .{
            .resident = self,
            .transport = transport_name,
            .route = route_id,
        };
        return .{ .admitted = .{ .ready = listener } };
    }

    fn finishListen(ctx: *anyopaque, route_id: usize) net.MultiplexedResident.RawListenFinishOutcome {
        const self = of(ctx);
        if (self.pending_listener == route_id) self.pending_listener = null;
        return .{ .failed = .init(error.BindFailed) };
    }

    fn cancelListen(ctx: *anyopaque, route_id: usize) ?glowcap.foundation.FailureChain {
        const self = of(ctx);
        self.cancel_listen_calls += 1;
        if (self.pending_listener != route_id) return null;
        self.pending_listener = null;
        return null;
    }

    fn localLocator(
        _: *anyopaque,
        listener_ctx: *anyopaque,
        selected: []const u8,
        allocator: std.mem.Allocator,
    ) net.netlayer.ListenError!model.PeerLocator {
        const listener: *Listener = @ptrCast(@alignCast(listener_ctx));
        const canonical = canonicalTransport(selected) orelse return error.InvalidAddress;
        if (!listener.active or !std.mem.eql(u8, canonical, listener.transport)) return error.InvalidAddress;
        return model.clonePeerLocator(allocator, .{
            .transport = canonical,
            .designator = "resident.test:1",
            .hints = model.Hints.emptyFalse(),
        });
    }

    fn canonicalizeLocator(
        _: *anyopaque,
        listener_ctx: *anyopaque,
        selected: []const u8,
        allocator: std.mem.Allocator,
        locator: model.PeerLocator,
    ) net.netlayer.ListenError!model.PeerLocator {
        const listener: *Listener = @ptrCast(@alignCast(listener_ctx));
        const canonical = canonicalTransport(selected) orelse return error.InvalidAddress;
        if (!listener.active or !std.mem.eql(u8, canonical, listener.transport) or
            !std.mem.eql(u8, locator.transport, canonical) or
            !std.mem.eql(u8, locator.designator, "resident.test:1")) return error.InvalidAddress;
        return model.clonePeerLocator(allocator, locator);
    }

    fn finishAccept(_: *anyopaque, listener_ctx: *anyopaque) net.netlayer.AcceptError!?usize {
        const listener: *Listener = @ptrCast(@alignCast(listener_ctx));
        const self = listener.resident;
        if (!listener.active or self.accept_route != listener.route) return null;
        if (self.claimed) return null;
        self.claimed = true;
        return conn_id;
    }

    fn stopListen(_: *anyopaque, listener_ctx: *anyopaque) net.multiplexed_resident.TeardownOutcome {
        const listener: *Listener = @ptrCast(@alignCast(listener_ctx));
        listener.active = false;
        if (listener.resident.accept_route == listener.route) listener.resident.accept_route = null;
        return .complete;
    }

    fn tryRead(_: *anyopaque, _: usize, _: []u8) isize {
        return net.multiplexed_resident.would_block;
    }

    fn tryWrite(_: *anyopaque, _: usize, bytes: []const u8) isize {
        return @intCast(bytes.len);
    }

    fn connClose(ctx: *anyopaque, conn: usize) net.multiplexed_resident.TeardownOutcome {
        const self = of(ctx);
        std.debug.assert(conn == conn_id);
        self.close_calls += 1;
        return .complete;
    }

    fn connRemoteKey(_: *anyopaque, _: usize) net.multiplexed_resident.ContractError!?glowcap.foundation.crypto.PeerKey {
        return null;
    }
};

pub const IgnoreSessionOpen = struct {
    pub fn opened(_: *anyopaque, _: u64, _: *driver_core.HostSession) !void {}
    pub fn failed(_: *anyopaque, _: u64, _: driver.OperationFailure) void {}
};

pub fn prepareAcceptOwnershipRuntime(
    allocator: std.mem.Allocator,
    io: std.Io,
    resident: *AcceptOwnershipResident,
) !driver.HostRuntime {
    var runtime = try driver.HostRuntime.init(allocator, io, .{}, .ephemeral, opts);
    errdefer runtime.deinit();
    _ = try runtime.addResident(
        .{ .symbol = AcceptOwnershipResident.transport, .designator_scheme = .address },
        resident.multiplexedResident(),
    );
    var listener = try runtime.bindListener(AcceptOwnershipResident.transport, "", .inherit);
    errdefer if (runtime.closeListener(&listener)) |failure|
        runtime.noteTerminalOperationFailure(failure);
    try runtime.core.setAdvertisedLocator(.{
        .transport = AcceptOwnershipResident.transport,
        .designator = "resident.test:1",
        .hints = model.Hints.emptyFalse(),
    });
    try runtime.activateListener(&listener, 7, .{
        .ctx = resident,
        .opened = IgnoreSessionOpen.opened,
        .failed = IgnoreSessionOpen.failed,
    });
    _ = try runtime.stepAny(0); // Warm readiness scratch before injection.
    return runtime;
}
