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
    /// Runs as the runtime is about to park, so a test can move its clock
    /// during the wait the way elapsed time does.
    before_wait_hook: ?*const fn (*anyopaque) void = null,
    before_wait_ctx: *anyopaque = undefined,
    reap_calls: usize = 0,
    /// A record that appears on this reap, as a reply landing inside a
    /// spinning runtime's window would.
    reap_record_at: ?usize = null,
    listen_calls: usize = 0,
    listeners: [2]Listener = undefined,
    listener_count: usize = 0,
    accept_route: ?usize = null,
    dialed: [2]bool = @splat(false),
    /// Every `startConnect` call, whether it admitted or refused.
    dial_starts: usize = 0,
    hold_connect: bool = false,
    pending_connect: ?usize = null,
    pending_listener: ?usize = null,
    fail_drain: bool = false,
    fail_listener_finish: bool = false,
    /// When set, `connRemoteKey` breaks the provider contract.
    fail_remote_key: bool = false,
    /// When set, a drain reports more records than its buffer holds.
    overreport_drain: bool = false,
    /// When set, closing the accepted connection reports this failure.
    close_failure: ?glowcap.foundation.FailureChain = null,
    /// A record the drain reports after the accept record, in the same batch.
    trailing_record: ?net.multiplexed_resident.ReadyEvent = null,
    cancel_connect_calls: usize = 0,
    cancel_listen_calls: usize = 0,
    fail_cancel_connect: bool = false,
    /// When set, draining leaves the readiness descriptor readable, so the
    /// resident reports ready on every wait.
    keep_ready: bool = false,
    /// When set, every dial start refuses with exactly this failure.
    dial_failure: ?net.netlayer.DialFailure = null,
    /// When set, a held connect finishes with the connection.
    connect_succeeds: bool = false,
    /// When set, a held connect reports its connect record as it starts.
    connect_ready_at_start: bool = false,
    /// What every read of the connection answers. Zero is end of stream.
    read_result: isize = net.multiplexed_resident.would_block,
    /// When set, the first read hands over these bytes instead.
    read_once: ?[]const u8 = null,
    read_calls: usize = 0,
    /// A close that stays pending until the test clears this: a carrier the
    /// resident completes on its own terms, with no abort to cut it short.
    close_pending: bool = false,
    /// A resident that can abort a close the partner never reads: the carrier
    /// close deadline then completes the close with no descriptor I/O.
    abortable: bool = false,
    abort_calls: usize = 0,
    /// Memory-retry debt, as a resident whose allocator refused work would
    /// owe. `retry` pays it when `retry_pays` is set and otherwise keeps it.
    /// `latch_on_retry` fails the resident instead, which then reports
    /// ready and refuses its next drain.
    owes_debt: bool = false,
    retry_pays: bool = true,
    latch_on_retry: bool = false,
    latched: bool = false,
    owes_calls: usize = 0,
    retry_calls: usize = 0,
    /// The reap on which `owes_debt` turns on, as a completion the spin took.
    reap_debt_at: ?usize = null,
    /// The deadline of timed work this resident holds, as a resident owing a
    /// timer would bound the wait. Null leaves the requested wait alone.
    timed_work_ms: ?i32 = null,
    /// A resident that parks in its own queue, recording each wait.
    parking: bool = false,
    park_calls: usize = 0,
    park_timeout_ms: ?i32 = null,

    pub const transport = "x-accept-ownership";
    pub const alternate_transport = "x-accept-ownership-alt";
    pub const conn_id: usize = 41;

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
        return .{ .ctx = self, .vtable = if (self.parking) &parking_vtable else if (self.abortable) &abortable_vtable else &vtable };
    }

    const parking_vtable = parking: {
        var table = vtable;
        table.park = park;
        table.watch = watch;
        break :parking table;
    };

    fn park(ctx: *anyopaque, timeout_ms: i32) net.MultiplexedResident.Park {
        const self = of(ctx);
        self.park_calls += 1;
        self.park_timeout_ms = timeout_ms;
        return .timeout;
    }

    fn watch(_: *anyopaque, _: i32) error{OutOfMemory}!void {}

    fn owesDebt(ctx: *anyopaque) bool {
        const self = of(ctx);
        self.owes_calls += 1;
        return self.owes_debt and !self.latched;
    }

    fn retryDebt(ctx: *anyopaque) void {
        const self = of(ctx);
        self.retry_calls += 1;
        if (self.latch_on_retry) {
            self.latched = true;
            self.owes_debt = false;
        } else if (self.retry_pays) self.owes_debt = false;
    }

    const abortable_vtable = abortable: {
        var table = vtable;
        table.conn_abort = connAbort;
        break :abortable table;
    };

    fn connAbort(ctx: *anyopaque, conn: usize) net.multiplexed_resident.TeardownOutcome {
        const self = of(ctx);
        std.debug.assert(conn == conn_id);
        self.abort_calls += 1;
        return .complete;
    }

    pub const vtable = net.MultiplexedResident.VTable{
        .readiness_fd = readinessFd,
        .ready_pending = readyPending,
        .before_wait = beforeWait,
        .reap = reap,
        .wait_bound_ms = waitBound,
        .drain_ready = drainReady,
        .memory_retry = .{ .owes = owesDebt, .retry = retryDebt },
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

    fn waitBound(ctx: *anyopaque, requested_ms: i32) i32 {
        return of(ctx).timed_work_ms orelse requested_ms;
    }

    fn of(ctx: *anyopaque) *AcceptOwnershipResident {
        return @ptrCast(@alignCast(ctx));
    }

    fn readinessFd(ctx: *anyopaque) i32 {
        return of(ctx).wake.read;
    }

    fn readyPending(ctx: *anyopaque) bool {
        const self = of(ctx);
        return self.held_record != null or self.latched;
    }

    fn beforeWait(ctx: *anyopaque, _: net.multiplexed_resident.AfterTurn) void {
        const self = of(ctx);
        self.before_wait_calls += 1;
        if (self.before_wait_hook) |hook| hook(self.before_wait_ctx);
    }

    fn reap(ctx: *anyopaque) void {
        const self = of(ctx);
        self.reap_calls += 1;
        if (self.reap_debt_at) |at| if (self.reap_calls == at) {
            self.owes_debt = true;
        };
        if (self.reap_record_at) |at| if (self.reap_calls == at) {
            self.held_record = .{ .subject = 404, .events = net.multiplexed_resident.ev_writable };
        };
    }

    fn drainReady(ctx: *anyopaque, out: []net.multiplexed_resident.ReadyEvent) net.multiplexed_resident.ContractError!usize {
        const self = of(ctx);
        self.drain_calls += 1;
        if (!self.keep_ready) self.wake.drain() catch unreachable;
        if (self.fail_drain) return error.ProviderContract;
        if (self.latched) return error.ProviderContract;
        if (self.overreport_drain) return out.len + 1;
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
        if (self.trailing_record) |record| {
            self.trailing_record = null;
            out[1] = record;
            return 2;
        }
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
        self.dial_starts += 1;
        if (self.dial_failure) |failure| return .{ .failed = failure };
        self.dialed[index] = true;
        if (self.hold_connect) {
            self.pending_connect = request_id;
            if (self.connect_ready_at_start) {
                self.held_record = .{ .subject = request_id, .events = net.multiplexed_resident.ev_connect };
                _ = self.wake.nudge() catch unreachable;
            }
            return .admitted;
        }
        return .{ .failed = .init(error.InvalidAddress) };
    }

    fn finishConnect(ctx: *anyopaque, _: usize) net.MultiplexedDialRawFinishOutcome {
        const self = of(ctx);
        if (!self.connect_succeeds) return .{ .failed = .init(error.ConnectionLost) };
        self.pending_connect = null;
        return .{ .connected = conn_id };
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

    fn tryRead(ctx: *anyopaque, _: usize, buf: []u8) isize {
        const self = of(ctx);
        self.read_calls += 1;
        const bytes = self.read_once orelse return self.read_result;
        self.read_once = null;
        const n = @min(buf.len, bytes.len);
        @memcpy(buf[0..n], bytes[0..n]);
        return @intCast(n);
    }

    fn tryWrite(_: *anyopaque, _: usize, bytes: []const u8) isize {
        return @intCast(bytes.len);
    }

    fn connClose(ctx: *anyopaque, conn: usize) net.multiplexed_resident.TeardownOutcome {
        const self = of(ctx);
        std.debug.assert(conn == conn_id);
        self.close_calls += 1;
        if (self.close_pending) return .pending;
        if (self.close_failure) |failure| return .{ .failed = .{ .chain = failure } };
        return .complete;
    }

    fn connRemoteKey(ctx: *anyopaque, _: usize) net.multiplexed_resident.ContractError!?glowcap.foundation.crypto.PeerKey {
        if (of(ctx).fail_remote_key) return error.ProviderContract;
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
