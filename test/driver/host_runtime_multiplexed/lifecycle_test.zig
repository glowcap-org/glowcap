//! `driver.HostRuntime` lifecycle over a multiplexed resident (ADR-0024):
//! close and cancellation own their teardown consequences, external adoption
//! commits its pending-open owner, a staged dial is read when the runtime
//! adopts it, listener setup and profiles admit exactly one owner, and a
//! failed remote-key contract retires its dial.

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
const ExternalAdoptionResident = fixtures.ExternalAdoptionResident;
const ObservedOpen = fixtures.ObservedOpen;
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
        self.failure = failure.chain.cause;
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

test "runtime close cancels a resident open after core reaches closed" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var resident = try AcceptOwnershipResident.init();
    defer resident.deinit();
    resident.hold_connect = true;

    var runtime = try driver.HostRuntime.init(std.testing.allocator, io, .{}, .ephemeral, opts);
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

test "a verb that leaves a resident holding a record raises the stepped readiness descriptor" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var resident = try AcceptOwnershipResident.init();
    defer resident.deinit();
    resident.hold_connect = true;

    var observed = ObservedOpen{};
    var runtime = try driver.HostRuntime.init(std.testing.allocator, io, .{}, .ephemeral, observed.steppedOpts());
    defer runtime.deinit();
    _ = try runtime.addResident(.{
        .symbol = AcceptOwnershipResident.transport,
        .designator_scheme = .address,
    }, resident.multiplexedResident());
    const ready_fd = try runtime.readinessDescriptor();
    try std.testing.expect(!try readableNow(ready_fd));

    // The dial verb runs a resident verb and returns with the record still
    // held, which the embedder's park could never see on its own. The verb's
    // end is also where the embedder may park, so staged work is handed to
    // the kernel there.
    resident.held_record = .{ .subject = 404, .events = net.multiplexed_resident.ev_writable };
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
    try std.testing.expect(try readableNow(ready_fd));
    try std.testing.expectEqual(@as(usize, 1), resident.before_wait_calls);

    // The step it provokes services the record and leaves the descriptor quiet.
    _ = try runtime.stepAny(0);
    try std.testing.expectEqual(@as(?net.multiplexed_resident.ReadyEvent, null), resident.held_record);
    try std.testing.expect(!try readableNow(ready_fd));

    runtime.beginClose(.cancel);
    _ = try runtime.stepAny(0);
    try std.testing.expectEqual(driver.HostRuntime.CloseOutcome.closed, runtime.closeOutcome());
}

/// Whether `fd` reports readable without waiting.
fn readableNow(fd: std.posix.fd_t) !bool {
    var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    return try std.posix.poll(&fds, 0) > 0;
}

test "resident dial cancellation attaches exact teardown consequences to its owner" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    var resident = try AcceptOwnershipResident.init();
    defer resident.deinit();
    resident.hold_connect = true;
    resident.fail_cancel_connect = true;

    var runtime = try driver.HostRuntime.init(std.testing.allocator, threaded.io(), .{}, .ephemeral, opts);
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
    try std.testing.expectEqual(error.Canceled, failure.chain.cause);
    try std.testing.expectEqualStrings("ResidentCancelFailed", failure.chain.secondaryName().?);
    try std.testing.expectEqual(@as(u16, 2), failure.chain.secondary_count);
    try std.testing.expectEqual(@as(usize, 0), observed.reservations);
}

test "a staged resident dial is read at adoption, with no readable record" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    var resident = try AcceptOwnershipResident.init();
    defer resident.deinit();
    resident.hold_connect = true;
    resident.connect_succeeds = true;
    // The far peer ended the connection before the runtime claimed it. The
    // resident reported that readiness while no wire existed to take it.
    resident.read_result = 0;

    var runtime = try driver.HostRuntime.init(std.testing.allocator, threaded.io(), .{}, .ephemeral, opts);
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
    }, .inherit, 93, .{
        .ctx = &observed,
        .reserve = ObservedOpen.reserve,
        .release = ObservedOpen.release,
        .opened = ObservedOpen.opened,
        .failed = ObservedOpen.failed,
    });
    try std.testing.expectEqual(@as(usize, 0), resident.read_calls);

    // The connect record is the only one this step drains.
    resident.held_record = .{
        .subject = resident.pending_connect.?,
        .events = net.multiplexed_resident.ev_connect,
    };
    _ = try resident.wake.nudge();
    _ = try runtime.stepAny(0);
    try std.testing.expectEqual(@as(usize, 1), resident.read_calls);
    try std.testing.expect(!observed.did_open);
    try std.testing.expectEqual(error.ConnectionClosed, observed.failure.?);
    try std.testing.expectEqual(@as(usize, 1), resident.close_calls);
}

test "external adoption commits its pending-open owner before immediate EOF" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();

    var resident = ExternalAdoptionResident{
        .wake = try net.wake_channel.WakeChannel.open(),
    };
    defer resident.wake.deinit();

    var observed = ObservedOpen{};
    var runtime = try driver.HostRuntime.init(allocator, threaded.io(), .{}, .ephemeral, observed.steppedOpts());
    defer runtime.deinit();
    _ = try runtime.addResident(.{
        .symbol = ExternalAdoptionResident.transport,
        .designator_scheme = .key,
    }, resident.multiplexedResident());

    try runtime.startAdoptExternal(
        ExternalAdoptionResident.transport,
        ExternalAdoptionResident.conn_id,
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
    try std.testing.expectEqualStrings("ResidentCloseCleanupFailed", observed.failure_detail.?.chain.secondaryName().?);
    try std.testing.expectEqual(@as(u16, 1), observed.failure_detail.?.chain.secondary_count);
    try std.testing.expectEqual(@as(usize, 0), observed.close_events);
    try std.testing.expectEqual(@as(usize, 2), resident.close_calls);
}

test "message resident adoption sizes reads from the transport packet cap" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();

    var resident = ExternalAdoptionResident{
        .wake = try net.wake_channel.WakeChannel.open(),
    };
    defer resident.wake.deinit();

    var runtime = try driver.HostRuntime.init(allocator, threaded.io(), .{}, .ephemeral, opts);
    defer runtime.deinit();
    const packet_cap = frame_cap + 2048;
    _ = try runtime.addResident(.{
        .symbol = ExternalAdoptionResident.transport,
        .designator_scheme = .key,
        .wire_framing = .message,
        .max_packet_bytes = packet_cap,
    }, resident.multiplexedResident());

    var observed = ObservedOpen{};
    try runtime.startAdoptExternal(
        ExternalAdoptionResident.transport,
        ExternalAdoptionResident.conn_id,
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

    // A message-framed wire can deliver a whole packet, so the shared resident
    // read scratch grows to the packet cap when it adopts one.
    try std.testing.expectEqual(packet_cap, runtime.resident_read_scratch.len);
}

test "bindListener cancels pending provider setup when readiness fails" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();

    var resident = try AcceptOwnershipResident.init();
    defer resident.deinit();
    resident.fail_drain = true;

    var runtime = try driver.HostRuntime.init(allocator, threaded.io(), .{}, .ephemeral, opts);
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

    var runtime = try driver.HostRuntime.init(allocator, threaded.io(), .{}, .ephemeral, opts);
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

    var runtime = try driver.HostRuntime.init(allocator, threaded.io(), .{}, .ephemeral, opts);
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
    var runtime = try driver.HostRuntime.init(allocator, io, .{}, .ephemeral, opts);
    defer runtime.deinit();
    _ = try runtime.addResident(
        model.transport.Known.tcp.metadata(),
        resident.multiplexedResident(),
    );

    try std.testing.expectError(error.ProviderContract, runtime.connectLocator(locator, .inherit));
    try std.testing.expectEqual(@as(usize, 0), runtime.pending_opens.items.len);
    try std.testing.expectEqual(@as(usize, 0), resident.conns.count());
}
