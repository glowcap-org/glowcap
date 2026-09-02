//! `driver.HostRuntime` lifecycle over a multiplexed resident (ADR-0112):
//! close and cancellation own their teardown consequences, external adoption
//! commits its pending-open owner, listener setup and profiles admit
//! exactly one owner, and a failed remote-key contract retires its dial.

const std = @import("std");
const glowcap = @import("glowcap");
const netlayer_test = @import("../../support/netlayer.zig");

const model = glowcap.ocapn.model;
const driver = glowcap.driver;
const driver_core = driver.core;
const net = glowcap.net;
const tcp = net.tcp;
const linux = std.os.linux;

const fixtures = @import("residents.zig");
const FakeResident = fixtures.FakeResident;
const AcceptOwnershipResident = fixtures.AcceptOwnershipResident;
const IgnoreSessionOpen = fixtures.IgnoreSessionOpen;
const Treasure = fixtures.Treasure;
const Introducer = fixtures.Introducer;
const prepareAcceptOwnershipRuntime = fixtures.prepareAcceptOwnershipRuntime;
const frame_cap = fixtures.frame_cap;
const opts = fixtures.opts;

const ListenerCapture = struct {
    reservations: usize = 0,
    abandonments: usize = 0,
    listener: ?driver.HostRuntime.TransportListener = null,
    failure: ?anyerror = null,
    failure_detail: ?driver.OperationFailure = null,

    fn of(ctx: *anyopaque) *ListenerCapture {
        return @ptrCast(@alignCast(ctx));
    }

    fn reserve(ctx: *anyopaque, _: u64) anyerror!void {
        of(ctx).reservations += 1;
    }

    fn release(ctx: *anyopaque, _: u64) void {
        const self = of(ctx);
        std.debug.assert(self.reservations != 0);
        self.reservations -= 1;
    }

    fn ready(ctx: *anyopaque, tag: u64, listener: driver.HostRuntime.TransportListener) void {
        const self = of(ctx);
        release(ctx, tag);
        self.listener = listener;
    }

    fn failed(ctx: *anyopaque, tag: u64, failure: driver.OperationFailure) void {
        const self = of(ctx);
        release(ctx, tag);
        self.failure = failure.cause;
        self.failure_detail = failure;
    }

    fn abandoned(ctx: *anyopaque, tag: u64) void {
        const self = of(ctx);
        release(ctx, tag);
        self.abandonments += 1;
    }

    fn observer(self: *ListenerCapture) driver.HostRuntime.ListenerObserver {
        return .{
            .ctx = self,
            .reserve = reserve,
            .release = release,
            .abandoned = abandoned,
            .ready = ready,
            .failed = failed,
        };
    }
};

const ImmediateClosedExternalResident = struct {
    wake: net.wake_channel.WakeChannel,
    close_calls: usize = 0,
    close_ready: bool = false,

    const transport = "external-close";
    const conn_id: usize = 9;

    fn multiplexedResident(self: *ImmediateClosedExternalResident) net.MultiplexedResident {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable = net.MultiplexedResident.VTable{
        .readiness_fd = readinessFd,
        .drain_ready = drainReady,
        .external_claim = .{ .claim_external = claimExternal },
        .try_read = tryRead,
        .try_write = tryWrite,
        .conn_close = connClose,
        .conn_remote_key = connRemoteKey,
    };

    fn of(ctx: *anyopaque) *ImmediateClosedExternalResident {
        return @ptrCast(@alignCast(ctx));
    }

    fn readinessFd(ctx: *anyopaque) i32 {
        return of(ctx).wake.read;
    }

    fn drainReady(ctx: *anyopaque, out: []net.multiplexed_resident.ReadyEvent) net.multiplexed_resident.ContractError!usize {
        const self = of(ctx);
        self.wake.drain() catch return error.ProviderContract;
        if (!self.close_ready or out.len == 0) return 0;
        out[0] = .{ .subject = conn_id, .events = net.multiplexed_resident.ev_closed };
        return 1;
    }

    fn claimExternal(_: *anyopaque, subject: usize) net.MultiplexedExternalClaimRawOutcome {
        if (subject != conn_id) return .{ .failed = .init(error.InvalidAddress) };
        return .{ .claimed = conn_id };
    }

    fn tryRead(_: *anyopaque, _: usize, _: []u8) isize {
        return 0;
    }

    fn tryWrite(_: *anyopaque, _: usize, bytes: []const u8) isize {
        return @intCast(bytes.len);
    }

    fn connClose(ctx: *anyopaque, conn: usize) net.multiplexed_resident.TeardownOutcome {
        std.debug.assert(conn == conn_id);
        const self = of(ctx);
        self.close_calls += 1;
        if (!self.close_ready) return .pending;
        var failure = glowcap.foundation.FailureChain.init(error.ResidentCloseFailed);
        failure.note(error.ResidentCloseCleanupFailed);
        return .{ .failed = failure };
    }

    fn connRemoteKey(_: *anyopaque, conn: usize) net.multiplexed_resident.ContractError!?glowcap.foundation.crypto.PeerKey {
        std.debug.assert(conn == conn_id);
        return glowcap.foundation.crypto.SecretKey.fromSeed(@as([32]u8, @splat(0x5d))).publicKey();
    }
};

const ObservedOpen = struct {
    reservations: usize = 0,
    did_open: bool = false,
    failure: ?anyerror = null,
    failure_detail: ?driver.OperationFailure = null,
    close_events: usize = 0,

    fn of(ctx: *anyopaque) *ObservedOpen {
        return @ptrCast(@alignCast(ctx));
    }

    fn reserve(ctx: *anyopaque, _: u64) anyerror!void {
        of(ctx).reservations += 1;
    }

    fn release(ctx: *anyopaque, _: u64) void {
        const self = of(ctx);
        std.debug.assert(self.reservations != 0);
        self.reservations -= 1;
    }

    fn reserveClose(ctx: *anyopaque) anyerror!void {
        of(ctx).reservations += 1;
    }

    fn releaseClose(ctx: *anyopaque) void {
        const self = of(ctx);
        std.debug.assert(self.reservations != 0);
        self.reservations -= 1;
    }

    fn opened(ctx: *anyopaque, _: u64, _: *driver_core.HostSession) !void {
        const self = of(ctx);
        release(ctx, 0);
        self.did_open = true;
    }

    fn failed(ctx: *anyopaque, _: u64, failure: driver.OperationFailure) void {
        const self = of(ctx);
        release(ctx, 0);
        self.failure = failure.cause;
        self.failure_detail = failure;
    }

    fn closed(ctx: *anyopaque, _: *driver_core.HostSession, _: ?driver.OperationFailure) void {
        const self = of(ctx);
        releaseClose(ctx);
        self.close_events += 1;
    }
};

test "runtime close cancels a resident open after core reaches closed" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var resident = try AcceptOwnershipResident.init();
    defer resident.deinit();
    resident.hold_connect = true;

    var runtime = try driver.HostRuntime.init(std.testing.allocator, io, &.{}, .ephemeral, opts);
    defer runtime.deinit();
    _ = try runtime.addResident(.{
        .symbol = AcceptOwnershipResident.transport,
        .designator_scheme = .address,
    }, resident.multiplexedResident());

    var observed = ObservedOpen{};
    try runtime.startDial(.{
        .transport = AcceptOwnershipResident.transport,
        .designator = "remote.test:1",
        .hints = model.Hints.emptyFalse(),
    }, .inherit, 91, .{
        .ctx = &observed,
        .reserve = ObservedOpen.reserve,
        .release = ObservedOpen.release,
        .opened = ObservedOpen.opened,
        .failed = ObservedOpen.failed,
    });
    try std.testing.expectEqual(@as(usize, 1), runtime.pending_opens.items.len);
    try std.testing.expect(resident.pending_connect != null);

    runtime.beginClose(.cancel);
    try std.testing.expectEqual(driver.HostRuntime.CloseOutcome.pending, runtime.closeOutcome());
    _ = try runtime.stepAny(0);

    try std.testing.expectEqual(driver.HostRuntime.CloseOutcome.closed, runtime.closeOutcome());
    try std.testing.expectEqual(@as(usize, 0), runtime.pending_opens.items.len);
    try std.testing.expectEqual(@as(?usize, null), resident.pending_connect);
    try std.testing.expectEqual(@as(usize, 1), resident.cancel_connect_calls);
    try std.testing.expectEqual(@as(?anyerror, error.Canceled), observed.failure);
    try std.testing.expectEqual(@as(usize, 0), observed.reservations);
}

test "resident dial cancellation attaches exact teardown consequences to its owner" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    var resident = try AcceptOwnershipResident.init();
    defer resident.deinit();
    resident.hold_connect = true;
    resident.fail_cancel_connect = true;

    var runtime = try driver.HostRuntime.init(std.testing.allocator, threaded.io(), &.{}, .ephemeral, opts);
    defer runtime.deinit();
    _ = try runtime.addResident(.{
        .symbol = AcceptOwnershipResident.transport,
        .designator_scheme = .address,
    }, resident.multiplexedResident());

    var observed = ObservedOpen{};
    try runtime.startDial(.{
        .transport = AcceptOwnershipResident.transport,
        .designator = "remote.test:1",
        .hints = model.Hints.emptyFalse(),
    }, .inherit, 92, .{
        .ctx = &observed,
        .reserve = ObservedOpen.reserve,
        .release = ObservedOpen.release,
        .opened = ObservedOpen.opened,
        .failed = ObservedOpen.failed,
    });

    runtime.beginClose(.cancel);
    _ = try runtime.stepAny(0);

    const failure = observed.failure_detail.?;
    try std.testing.expectEqual(error.Canceled, failure.cause);
    try std.testing.expectEqualStrings("ResidentCancelFailed", failure.secondaryName().?);
    try std.testing.expectEqual(@as(u16, 2), failure.secondary_count);
    try std.testing.expectEqual(@as(usize, 0), observed.reservations);
}

test "external adoption commits its pending-open owner before immediate EOF" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();

    var resident = ImmediateClosedExternalResident{
        .wake = try net.wake_channel.WakeChannel.open(),
    };
    defer resident.wake.deinit();

    var runtime = try driver.HostRuntime.init(allocator, threaded.io(), &.{}, .ephemeral, opts);
    defer runtime.deinit();
    _ = try runtime.addResident(.{
        .symbol = ImmediateClosedExternalResident.transport,
        .designator_scheme = .key,
    }, resident.multiplexedResident());

    var observed = ObservedOpen{};
    try runtime.setCloseObserver(.{
        .ctx = &observed,
        .reserve = ObservedOpen.reserveClose,
        .release = ObservedOpen.releaseClose,
        .closed = ObservedOpen.closed,
    });
    try runtime.startAdoptExternal(
        ImmediateClosedExternalResident.transport,
        ImmediateClosedExternalResident.conn_id,
        .dialed,
        41,
        .{
            .ctx = &observed,
            .reserve = ObservedOpen.reserve,
            .release = ObservedOpen.release,
            .opened = ObservedOpen.opened,
            .failed = ObservedOpen.failed,
        },
    );

    // The operation outcome and the adopted wire's eventual close each own a
    // publication seat before either transition can commit.
    try std.testing.expectEqual(@as(usize, 2), observed.reservations);
    try std.testing.expectEqual(@as(usize, 0), observed.close_events);
    try std.testing.expect(!observed.did_open);
    try std.testing.expect(observed.failure == null);

    _ = try runtime.stepAny(0);
    try std.testing.expectEqual(@as(usize, 2), observed.reservations);
    try std.testing.expect(observed.failure == null);
    try std.testing.expectEqual(@as(usize, 1), resident.close_calls);

    resident.close_ready = true;
    _ = try resident.wake.nudge();
    _ = try runtime.stepAny(0);
    try std.testing.expectEqual(@as(usize, 0), observed.reservations);
    try std.testing.expectEqual(error.ResidentCloseFailed, observed.failure.?);
    try std.testing.expectEqualStrings("ResidentCloseCleanupFailed", observed.failure_detail.?.secondaryName().?);
    try std.testing.expectEqual(@as(u16, 1), observed.failure_detail.?.secondary_count);
    try std.testing.expectEqual(@as(usize, 0), observed.close_events);
    try std.testing.expectEqual(@as(usize, 2), resident.close_calls);
}

test "message resident adoption sizes reads from the transport packet cap" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();

    var resident = ImmediateClosedExternalResident{
        .wake = try net.wake_channel.WakeChannel.open(),
    };
    defer resident.wake.deinit();

    var runtime = try driver.HostRuntime.init(allocator, threaded.io(), &.{}, .ephemeral, opts);
    defer runtime.deinit();
    const packet_cap = frame_cap + 2048;
    _ = try runtime.addResident(.{
        .symbol = ImmediateClosedExternalResident.transport,
        .designator_scheme = .key,
        .wire_framing = .message,
        .max_packet_bytes = packet_cap,
    }, resident.multiplexedResident());

    var observed = ObservedOpen{};
    try runtime.startAdoptExternal(
        ImmediateClosedExternalResident.transport,
        ImmediateClosedExternalResident.conn_id,
        .dialed,
        41,
        .{
            .ctx = &observed,
            .reserve = ObservedOpen.reserve,
            .release = ObservedOpen.release,
            .opened = ObservedOpen.opened,
            .failed = ObservedOpen.failed,
        },
    );

    const session = runtime.pending_opens.items[0].session;
    const wire = runtime.wires.get(session.peer_handle).?;
    try std.testing.expectEqual(packet_cap, wire.link.resident.read_buf.len);
}

test "bindListener cancels pending provider setup when readiness fails" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();

    var resident = try AcceptOwnershipResident.init();
    defer resident.deinit();
    resident.fail_drain = true;

    var runtime = try driver.HostRuntime.init(allocator, threaded.io(), &.{}, .ephemeral, opts);
    defer runtime.deinit();
    _ = try runtime.addResident(.{
        .symbol = AcceptOwnershipResident.transport,
        .designator_scheme = .address,
    }, resident.multiplexedResident());

    try std.testing.expectError(
        error.ProviderContract,
        runtime.bindListener(AcceptOwnershipResident.transport, "", .inherit),
    );
    try std.testing.expectEqual(@as(usize, 0), runtime.pending_listeners.items.len);
    try std.testing.expectEqual(@as(?usize, null), resident.pending_listener);
    try std.testing.expectEqual(@as(usize, 1), resident.cancel_listen_calls);
}

test "one runtime profile admits only one pending or active listener" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();

    var resident = try AcceptOwnershipResident.init();
    defer resident.deinit();
    resident.fail_drain = true;

    var runtime = try driver.HostRuntime.init(allocator, threaded.io(), &.{}, .ephemeral, opts);
    defer runtime.deinit();
    _ = try runtime.addResident(.{
        .symbol = AcceptOwnershipResident.transport,
        .designator_scheme = .address,
    }, resident.multiplexedResident());

    var first = ListenerCapture{};
    try runtime.startListener(AcceptOwnershipResident.transport, "", .inherit, 1, first.observer());
    try std.testing.expectEqual(@as(usize, 1), first.reservations);

    var duplicate = ListenerCapture{};
    try std.testing.expectError(
        error.ListenerProfileInUse,
        runtime.startListener(AcceptOwnershipResident.transport, "", .inherit, 2, duplicate.observer()),
    );
    try std.testing.expectEqual(@as(usize, 0), duplicate.reservations);
    const canceled = runtime.cancelListener(1);
    try std.testing.expect(canceled.found);
    try std.testing.expect(canceled.failure == null);
    try std.testing.expectEqual(@as(usize, 0), first.reservations);
    try std.testing.expectEqual(@as(usize, 1), first.abandonments);
    try std.testing.expect(first.failure == null);

    resident.fail_drain = false;
    var active = try runtime.bindListener(AcceptOwnershipResident.transport, "", .inherit);
    try std.testing.expectError(
        error.ListenerProfileInUse,
        runtime.bindListener(AcceptOwnershipResident.transport, "", .inherit),
    );
    try std.testing.expect(runtime.closeListener(&active) == null);

    var reopened = try runtime.bindListener(AcceptOwnershipResident.transport, "", .inherit);
    try std.testing.expect(runtime.closeListener(&reopened) == null);
}

test "failed multiplexed finish consumes listener setup without cancellation" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();

    var resident = try AcceptOwnershipResident.init();
    defer resident.deinit();
    resident.fail_listener_finish = true;

    var runtime = try driver.HostRuntime.init(allocator, threaded.io(), &.{}, .ephemeral, opts);
    defer runtime.deinit();
    _ = try runtime.addResident(.{
        .symbol = AcceptOwnershipResident.transport,
        .designator_scheme = .address,
    }, resident.multiplexedResident());

    try std.testing.expectError(
        error.BindFailed,
        runtime.bindListener(AcceptOwnershipResident.transport, "", .inherit),
    );
    try std.testing.expectEqual(@as(?usize, null), resident.pending_listener);
    try std.testing.expectEqual(@as(usize, 0), resident.cancel_listen_calls);

    resident.fail_listener_finish = false;
    var listener = try runtime.bindListener(AcceptOwnershipResident.transport, "", .inherit);
    try std.testing.expect(runtime.closeListener(&listener) == null);
}

test "remote-key contract failure retires the claimed dial and pending row" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tcp_resident = tcp.Resident{ .io = io };
    var listener = try netlayer_test.listenBlocking(
        tcp_resident.netlayer(),
        allocator,
        .{ .designator = "127.0.0.1:0" },
    );
    defer netlayer_test.close(listener);
    const locator = try listener.localLocator(allocator);
    defer model.freePeerLocator(allocator, locator);

    var resident = try FakeResident.init(allocator);
    defer resident.deinit();
    resident.fail_remote_key = true;
    var runtime = try driver.HostRuntime.init(allocator, io, &.{}, .ephemeral, opts);
    defer runtime.deinit();
    _ = try runtime.addResident(
        model.transport.Known.tcp.metadata(),
        resident.multiplexedResident(),
    );

    try std.testing.expectError(error.ProviderContract, runtime.connectLocator(locator, .inherit));
    try std.testing.expectEqual(@as(usize, 0), runtime.pending_opens.items.len);
    try std.testing.expectEqual(@as(usize, 0), resident.conns.count());
}
