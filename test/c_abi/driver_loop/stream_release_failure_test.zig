//! A valid cleanup failure from a foreign stream provider's callback belongs
//! to the consuming `glowcap_driver_release` that ran the callback. The
//! release result carries the failure's phase, detail, and chain, in the
//! order the callbacks ran.

const std = @import("std");

const c = @import("c_abi");
const cshared = @import("c_abi_shared");
const cdrv = @import("c_abi_driver");
const glowcap = @import("glowcap");

const harness = @import("harness.zig");
const residents = @import("residents.zig");
const typed_resident = @import("typed_resident.zig");
const Stubs = residents.MalformedImmediateStream;
const expectOk = harness.expectOk;
const providerFailure = harness.providerFailure;
const transport = cshared.transport_provider;

/// What each callback appended, in call order.
const Step = enum { retain, cancel_listen, package_release, contradictory_release };

const Log = struct {
    steps: [8]Step = undefined,
    len: usize = 0,

    fn add(self: *Log, step: Step) void {
        self.steps[self.len] = step;
        self.len += 1;
    }

    fn slice(self: *const Log) []const Step {
        return self.steps[0..self.len];
    }
};

/// A stream package whose one profile holds a pending listen. The listen never
/// becomes ready, so only the consuming release reaches its cancel callback.
const PendingListenPackage = struct {
    wake: glowcap.net.wake_channel.WakeChannel,
    log: *Log,
    cancel_code: i32 = c.GLOWCAP_OK,
    release_code: i32 = c.GLOWCAP_OK,
    /// Reports failure data beside an OK release status.
    release_contradicts: bool = false,
    listens: usize = 0,
    cancels: usize = 0,
    retains: usize = 0,
    releases: usize = 0,
    entry: cdrv.GlowcapTransportProviderEntry = undefined,

    fn of(ctx: ?*anyopaque) *PendingListenPackage {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn listen(
        ctx: ?*anyopaque,
        _: ?[*]const u8,
        _: usize,
        _: ?[*]const u8,
        _: usize,
        _: ?*const cdrv.GlowcapTransportOperationOptions,
        out_result: ?*cdrv.GlowcapListenResult,
        _: ?*cdrv.GlowcapProviderFailure,
    ) callconv(.c) i32 {
        const self = of(ctx);
        self.listens += 1;
        (out_result orelse return c.GLOWCAP_ERR_NULL_POINTER).* = .{
            .state = cdrv.GLOWCAP_LISTEN_PENDING,
            .listener = null,
            .attempt = self,
            .readiness_fd = self.wake.read,
        };
        return c.GLOWCAP_OK;
    }

    fn finishListen(_: ?*anyopaque, _: ?*?*anyopaque, out_failure: ?*cdrv.GlowcapProviderFailure) callconv(.c) i32 {
        return providerFailure(out_failure, c.GLOWCAP_ERR_IO, "UnexpectedFinishListen");
    }

    fn cancelListen(attempt: ?*anyopaque, out_failure: ?*cdrv.GlowcapProviderFailure) callconv(.c) i32 {
        const self = of(attempt);
        self.cancels += 1;
        self.log.add(.cancel_listen);
        if (self.cancel_code == c.GLOWCAP_OK) return c.GLOWCAP_OK;
        const code = providerFailure(out_failure, self.cancel_code, "StreamListenCancelFailed");
        const report = out_failure orelse return code;
        const cleanup = "StreamListenCancelCleanupFailed";
        report.carrier_phase = transport.GLOWCAP_CARRIER_PHASE_SHUTDOWN;
        report.carrier_detail_flags = transport.GLOWCAP_CARRIER_DETAIL_ENGINE_CODE;
        report.carrier_engine_code = -0x2700;
        report.secondary_result = c.GLOWCAP_ERR_INTERNAL;
        report.secondary_name = cleanup.ptr;
        report.secondary_name_len = cleanup.len;
        report.secondary_count = 2;
        return code;
    }

    fn listenerClose(_: ?*anyopaque, _: ?*anyopaque, _: ?*cdrv.GlowcapProviderFailure) callconv(.c) i32 {
        return c.GLOWCAP_OK;
    }

    fn tryIo(_: ?*anyopaque, _: ?*anyopaque, _: ?[*]u8, _: usize) callconv(.c) isize {
        return -1;
    }

    fn tryWrite(_: ?*anyopaque, _: ?*anyopaque, _: ?[*]const u8, _: usize) callconv(.c) isize {
        return -1;
    }

    fn connClose(_: ?*anyopaque, _: ?*anyopaque, _: ?*cdrv.GlowcapProviderFailure) callconv(.c) i32 {
        return c.GLOWCAP_OK;
    }

    fn retain(ctx: ?*anyopaque, _: ?*cdrv.GlowcapProviderFailure) callconv(.c) i32 {
        const self = of(ctx);
        self.retains += 1;
        self.log.add(.retain);
        return c.GLOWCAP_OK;
    }

    fn release(ctx: ?*anyopaque, out_failure: ?*cdrv.GlowcapProviderFailure) callconv(.c) i32 {
        const self = of(ctx);
        self.releases += 1;
        if (self.release_contradicts) {
            self.log.add(.contradictory_release);
            _ = providerFailure(out_failure, c.GLOWCAP_ERR_IO, "ContradictoryPackageRelease");
            return c.GLOWCAP_OK;
        }
        self.log.add(.package_release);
        if (self.release_code == c.GLOWCAP_OK) return c.GLOWCAP_OK;
        return providerFailure(out_failure, self.release_code, "TestPackageReleaseFailed");
    }

    fn table(self: *PendingListenPackage) cdrv.GlowcapStreamTransport {
        return .{
            .abi_version = cdrv.GLOWCAP_STREAM_TRANSPORT_ABI_VERSION,
            .struct_size = @sizeOf(cdrv.GlowcapStreamTransport),
            .ctx = self,
            .start_connect = null,
            .finish_connect = null,
            .cancel_connect = null,
            .listen = listen,
            .finish_listen = finishListen,
            .cancel_listen = cancelListen,
            .listener_wait_acceptable = Stubs.waitAcceptable,
            .listener_readiness_fd = Stubs.readinessFd,
            .listener_locator = Stubs.localLocator,
            .listener_advertise = Stubs.canonicalizeLocator,
            .listener_restoration_state = null,
            .accept = Stubs.accept,
            .listener_close = listenerClose,
            .try_read = tryIo,
            .try_write = tryWrite,
            .conn_close = connClose,
            .conn_take_failure = residents.noStreamConnectionFailure,
        };
    }

    fn provider(
        self: *PendingListenPackage,
        table_ptr: *const cdrv.GlowcapStreamTransport,
        profile: *const cdrv.GlowcapTransportProfile,
    ) cdrv.GlowcapTransportProvider {
        self.entry = .{
            .profile = profile,
            .execution_model = cdrv.GLOWCAP_TRANSPORT_EXEC_STREAM,
            .implementation = table_ptr,
        };
        return .{
            .abi_version = cdrv.GLOWCAP_TRANSPORT_PROVIDER_ABI_VERSION,
            .struct_size = @sizeOf(cdrv.GlowcapTransportProvider),
            .entries = @ptrCast(&self.entry),
            .entry_count = 1,
            .lease_ctx = self,
            .same_configuration = harness.sameStaticProvider,
            .retain = retain,
            .release = release,
        };
    }
};

/// Install the package and leave one pending listen on its provider.
fn installPendingListen(
    loop: ?*cdrv.GlowcapDriverLoop,
    package: *PendingListenPackage,
    table_ptr: *const cdrv.GlowcapStreamTransport,
    profile: *const cdrv.GlowcapTransportProfile,
    name: []const u8,
) !void {
    const provider = package.provider(table_ptr, profile);
    try expectOk(harness.addProvider(loop, &provider));
    var listener: u64 = 0;
    try expectOk(cdrv.glowcap_driver_listen(loop, name.ptr, name.len, "endpoint", "endpoint".len, null, &listener));
    for (0..200) |_| {
        if (package.listens != 0) return;
        try harness.expectStep(cdrv.glowcap_driver_step(loop, 5));
    }
    return error.ListenNeverReachedProvider;
}

fn expectName(name: ?[*]const u8, len: usize, expected: []const u8) !void {
    try std.testing.expectEqualStrings(expected, name.?[0..len]);
}

test "driver release returns a stream cancel failure with its carrier detail and package failure after it" {
    var log: Log = .{};
    var package: PendingListenPackage = .{
        .wake = try glowcap.net.wake_channel.WakeChannel.open(),
        .log = &log,
        .cancel_code = c.GLOWCAP_ERR_IO,
        .release_code = c.GLOWCAP_ERR_INTERNAL,
    };
    defer package.wake.deinit();
    var owned_loop = try harness.newEmptyLoop(0x74);
    defer owned_loop.deinit();
    var table = package.table();
    const profile = harness.providerProfile("stream-release-cancel");
    try installPendingListen(owned_loop.raw, &package, &table, &profile, "stream-release-cancel");
    try std.testing.expectEqual(@as(usize, 0), package.cancels);
    try std.testing.expectEqual(@as(usize, 0), package.releases);

    var failure = cdrv.GlowcapDriverFailure.init();
    try std.testing.expectEqual(-c.GLOWCAP_ERR_IO, owned_loop.release(&failure));

    // Each callback ran once, inside that release, in this order.
    try std.testing.expectEqual(@as(usize, 1), package.cancels);
    try std.testing.expectEqual(@as(usize, 1), package.releases);
    try std.testing.expectEqualSlices(Step, &.{ .retain, .cancel_listen, .package_release }, log.slice());
    // The stream's report is the primary, whole: phase, detail, and name.
    try std.testing.expectEqual(c.GLOWCAP_ERR_IO, failure.primary_result);
    try expectName(failure.primary_name, failure.primary_name_len, "StreamListenCancelFailed");
    try std.testing.expectEqual(transport.GLOWCAP_CARRIER_PHASE_SHUTDOWN, failure.carrier_phase);
    try std.testing.expectEqual(transport.GLOWCAP_CARRIER_DETAIL_ENGINE_CODE, failure.carrier_detail_flags);
    try std.testing.expectEqual(@as(i32, -0x2700), failure.carrier_engine_code);
    // The provider's own secondary leads, then the package failure that ran
    // after the cancel joins the count.
    try std.testing.expectEqual(c.GLOWCAP_ERR_INTERNAL, failure.secondary_result);
    try expectName(failure.secondary_name, failure.secondary_name_len, "StreamListenCancelCleanupFailed");
    try std.testing.expectEqual(@as(u32, 3), failure.secondary_count);
}

test "a refused driver release does not run the stream cleanup" {
    var log: Log = .{};
    var package: PendingListenPackage = .{
        .wake = try glowcap.net.wake_channel.WakeChannel.open(),
        .log = &log,
        .cancel_code = c.GLOWCAP_ERR_IO,
    };
    defer package.wake.deinit();
    var owned_loop = try harness.newEmptyLoop(0x76);
    defer owned_loop.deinit();
    var table = package.table();
    const profile = harness.providerProfile("stream-release-refused");
    try installPendingListen(owned_loop.raw, &package, &table, &profile, "stream-release-refused");

    // A failure slot with a wrong layout refuses before ownership changes.
    var bad = cdrv.GlowcapDriverFailure.init();
    bad.struct_size = 1;
    // A refusal keeps the handle: its code is negative, a consumed failure positive.
    try std.testing.expect(owned_loop.release(&bad) < 0);
    try std.testing.expectEqual(@as(usize, 0), package.cancels);
    try std.testing.expectEqual(@as(usize, 0), package.releases);

    var failure = cdrv.GlowcapDriverFailure.init();
    try std.testing.expectEqual(-c.GLOWCAP_ERR_IO, owned_loop.release(&failure));
    try std.testing.expectEqual(@as(usize, 1), package.cancels);
    try std.testing.expectEqual(@as(usize, 1), package.releases);
}

test "driver release keeps one retained contract failure and joins the stream failure once" {
    var log: Log = .{};
    var stream: PendingListenPackage = .{
        .wake = try glowcap.net.wake_channel.WakeChannel.open(),
        .log = &log,
        .cancel_code = c.GLOWCAP_ERR_IO,
    };
    defer stream.wake.deinit();
    var contradictory: PendingListenPackage = .{
        .wake = try glowcap.net.wake_channel.WakeChannel.open(),
        .log = &log,
        .release_contradicts = true,
    };
    defer contradictory.wake.deinit();
    var owned_loop = try harness.newEmptyLoop(0x77);
    defer owned_loop.deinit();
    var stream_table = stream.table();
    var contradictory_table = contradictory.table();
    const stream_profile = harness.providerProfile("stream-release-joined");
    const contradictory_profile = harness.providerProfile("stream-release-contradiction");
    try installPendingListen(owned_loop.raw, &stream, &stream_table, &stream_profile, "stream-release-joined");
    const second = contradictory.provider(&contradictory_table, &contradictory_profile);
    try expectOk(harness.addProvider(owned_loop.raw, &second));

    // Only installation ran: no cancel or release precedes the public release.
    try std.testing.expectEqualSlices(Step, &.{ .retain, .retain }, log.slice());

    var failure = cdrv.GlowcapDriverFailure.init();
    const status = owned_loop.release(&failure);

    // Each callback ran once inside that release. The completion backend
    // decides whether the pending listen's cancel runs before or after the
    // contradictory package's release (the packages release in reverse
    // install order, and a backend that settles the cancelled poll at
    // submission cancels first). Each legal sequence has its own exact result,
    // and the retained contradiction is joined once in both.
    try std.testing.expectEqual(@as(usize, 1), stream.cancels);
    try std.testing.expectEqual(@as(usize, 1), stream.releases);
    try std.testing.expectEqual(@as(usize, 1), contradictory.releases);
    const retained_first = [_]Step{ .retain, .retain, .contradictory_release, .cancel_listen, .package_release };
    const cancel_first = [_]Step{ .retain, .retain, .cancel_listen, .contradictory_release, .package_release };
    if (std.mem.eql(Step, log.slice(), &retained_first)) {
        // The retained contract failure leads. The stream's phase is not kept
        // because carrier fields belong to the primary alone. The contradictory
        // report is its secondary (one cause), then the stream's primary and
        // its two-cause secondary join once each.
        try std.testing.expectEqual(-c.GLOWCAP_ERR_INVALID_ARGUMENT, status);
        try expectName(failure.primary_name, failure.primary_name_len, "ProviderContract");
        try std.testing.expectEqual(transport.GLOWCAP_CARRIER_PHASE_NONE, failure.carrier_phase);
        try std.testing.expectEqual(c.GLOWCAP_ERR_IO, failure.secondary_result);
        try expectName(failure.secondary_name, failure.secondary_name_len, "ContradictoryPackageRelease");
        try std.testing.expectEqual(@as(u32, 4), failure.secondary_count);
    } else if (std.mem.eql(Step, log.slice(), &cancel_first)) {
        // The stream failure leads whole, with its phase, detail, and own
        // secondary (two causes). The retained contract failure joins after
        // it once, as itself plus its one contradictory-report cause.
        try std.testing.expectEqual(-c.GLOWCAP_ERR_IO, status);
        try expectName(failure.primary_name, failure.primary_name_len, "StreamListenCancelFailed");
        try std.testing.expectEqual(transport.GLOWCAP_CARRIER_PHASE_SHUTDOWN, failure.carrier_phase);
        try std.testing.expectEqual(@as(i32, -0x2700), failure.carrier_engine_code);
        try std.testing.expectEqual(c.GLOWCAP_ERR_INTERNAL, failure.secondary_result);
        try expectName(failure.secondary_name, failure.secondary_name_len, "StreamListenCancelCleanupFailed");
        try std.testing.expectEqual(@as(u32, 4), failure.secondary_count);
    } else {
        return error.UnexpectedCallbackSequence;
    }
}

test "package rollback keeps a valid release failure secondary and its candidate is not released twice" {
    var first: typed_resident.TypedResident = .{
        .wake = try glowcap.net.wake_channel.WakeChannel.open(),
        .opaque_hint = &.{},
    };
    defer first.wake.deinit();
    // A second package with other metadata that names the first one's
    // readiness descriptor. Admission refuses it after the package lease.
    var aliased: typed_resident.TypedResident = .{
        .wake = first.wake,
        .opaque_hint = &.{},
        .release_code = c.GLOWCAP_ERR_IO,
    };
    var owned_loop = try harness.newEmptyLoop(0x78);
    defer owned_loop.deinit();
    var first_table = first.table();
    var aliased_table = aliased.table();
    const first_profile = harness.providerProfile("typed-test");
    const aliased_profile = harness.providerProfile("typed-test-alt");
    const first_provider = typed_resident.typedProvider(&first, &first_table, &first_profile);
    const aliased_provider = typed_resident.typedProvider(&aliased, &aliased_table, &aliased_profile);
    try expectOk(harness.addProvider(owned_loop.raw, &first_provider));

    var registration = cdrv.GlowcapDriverFailure.init();
    const code = cdrv.glowcap_driver_add_provider(owned_loop.raw, &aliased_provider, &registration);
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, code);
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, registration.primary_result);
    try expectName(registration.primary_name, registration.primary_name_len, "ReadinessDescriptorConflict");
    try std.testing.expectEqual(@as(usize, 1), aliased.retains);
    try std.testing.expectEqual(@as(usize, 1), aliased.releases);
    try std.testing.expectEqual(c.GLOWCAP_ERR_IO, registration.secondary_result);
    try expectName(registration.secondary_name, registration.secondary_name_len, "TestPackageReleaseFailed");
    try std.testing.expectEqual(@as(u32, 1), registration.secondary_count);

    // The rejected candidate left no transport behind.
    var present: u8 = 1;
    try expectOk(cdrv.glowcap_driver_has_transport(owned_loop.raw, "typed-test-alt", "typed-test-alt".len, &present));
    try std.testing.expectEqual(@as(u8, 0), present);
    try std.testing.expectEqual(@as(usize, 0), aliased.listener_count);

    // The first installation still serves: its provider opens a listener and
    // publishes the locator it built, and the rollback released nothing of it.
    const listener = try harness.listenReady(owned_loop.raw, "typed-test", "listener-peer");
    const published = try harness.readListenerLocator(owned_loop.raw, listener);
    defer glowcap.ocapn.model.freePeerLocator(std.testing.allocator, published);
    try std.testing.expectEqual(@as(usize, 1), first.listener_count);
    try std.testing.expectEqualStrings("typed-test", published.transport);
    try std.testing.expectEqualStrings("listener-peer", published.designator);
    try std.testing.expectEqualStrings("primary", published.hints.entries[0].value.string);
    try std.testing.expectEqual(@as(usize, 1), first.retains);
    try std.testing.expectEqual(@as(usize, 0), first.releases);

    // Release returns the first package once and does not repeat the
    // candidate's cleanup.
    var release_report = cdrv.GlowcapDriverFailure.init();
    try expectOk(owned_loop.release(&release_report));
    try std.testing.expectEqual(@as(usize, 1), first.releases);
    try std.testing.expectEqual(@as(usize, 1), aliased.releases);
}

test "package rollback with a contradictory release returns the live refusal and retains one contract failure" {
    var first: typed_resident.TypedResident = .{
        .wake = try glowcap.net.wake_channel.WakeChannel.open(),
        .opaque_hint = &.{},
    };
    defer first.wake.deinit();
    var aliased: typed_resident.TypedResident = .{
        .wake = first.wake,
        .opaque_hint = &.{},
        .release_reports_failure = true,
    };
    var owned_loop = try harness.newEmptyLoop(0x79);
    defer owned_loop.deinit();
    var first_table = first.table();
    var aliased_table = aliased.table();
    const first_profile = harness.providerProfile("rollback-malformed-first");
    const aliased_profile = harness.providerProfile("rollback-malformed-aliased");
    const first_provider = typed_resident.typedProvider(&first, &first_table, &first_profile);
    const aliased_provider = typed_resident.typedProvider(&aliased, &aliased_table, &aliased_profile);
    try expectOk(harness.addProvider(owned_loop.raw, &first_provider));

    var registration = cdrv.GlowcapDriverFailure.init();
    const code = cdrv.glowcap_driver_add_provider(owned_loop.raw, &aliased_provider, &registration);
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, code);
    try expectName(registration.primary_name, registration.primary_name_len, "ReadinessDescriptorConflict");
    try std.testing.expectEqual(@as(usize, 1), aliased.releases);
    // The malformed release is the live refusal's secondary.
    try expectName(registration.secondary_name, registration.secondary_name_len, "ProviderContract");

    // The contradiction is retained once on the runtime. Release returns it.
    var failure = cdrv.GlowcapDriverFailure.init();
    try std.testing.expect(owned_loop.release(&failure) > 0);
    try expectName(failure.primary_name, failure.primary_name_len, "ProviderContract");
    try expectName(failure.secondary_name, failure.secondary_name_len, "ContradictoryReleaseFailure");
    try std.testing.expectEqual(@as(u32, 1), failure.secondary_count);
    try std.testing.expectEqual(@as(usize, 1), aliased.releases);
}
