//! Provider authority over multiplexed residents (ADR-0112): duplicate
//! authority is refused, a failed batch preserves a
//! shared live readiness descriptor, equal descriptors do not merge distinct
//! residents, two profiles share one resident with independent listener
//! lifecycles, accept close-ownership transfers exactly once, a dial refusal
//! reaches its observer with the exact failure chain, and an always-ready
//! resident cannot starve its sibling.

const std = @import("std");
const glowcap = @import("glowcap");
const test_host = @import("../../support/core_host.zig");

const model = glowcap.ocapn.model;
const driver = glowcap.driver;
const driver_core = driver.core;
const net = glowcap.net;

const fixtures = @import("residents.zig");
const FakeResident = fixtures.FakeResident;
const AcceptOwnershipResident = fixtures.AcceptOwnershipResident;
const IgnoreSessionOpen = fixtures.IgnoreSessionOpen;
const Treasure = fixtures.Treasure;
const Introducer = fixtures.Introducer;
const prepareAcceptOwnershipRuntime = fixtures.prepareAcceptOwnershipRuntime;
const frame_cap = fixtures.frame_cap;
const opts = fixtures.opts;

test "HostRuntime preserves configured and adopted feature vocabulary" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const features = model.FeatureSet.full().forCaptpVersion(.next);

    var configured = opts;
    configured.captp_version = .next;
    configured.features = features;
    var runtime = try driver.HostRuntime.init(allocator, io, .{}, .ephemeral, configured);
    defer runtime.deinit();
    try std.testing.expectEqual(features, runtime.opts.features);
    try std.testing.expectEqual(features, runtime.core.opts.features);

    var core_options = driver_core.Host.Options{};
    core_options.captp_version = .next;
    core_options.features = features;
    var core = test_host.init(allocator, @as([32]u8, @splat(0x51)), core_options);
    defer core.deinit();
    var adopted = try driver.HostRuntime.initWithCore(allocator, io, &core, .{}, .{
        .handshake = opts.handshake,
        .settle = opts.settle,
    });
    defer adopted.deinit();
    try std.testing.expectEqual(features, adopted.opts.features);
}

test "HostRuntime refuses duplicate provider authority" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var runtime = try driver.HostRuntime.init(allocator, io, .{}, .ephemeral, opts);
    defer runtime.deinit();
    var first = try FakeResident.init(allocator);
    defer first.deinit();
    const registration: driver.HostRuntime.ProviderRegistration = .{
        .profile = model.transport.Known.tcp.metadata(),
        .resident = first.multiplexedResident(),
    };
    var indices: [2]usize = undefined;
    try std.testing.expectError(
        error.TransportAlreadyRegistered,
        runtime.addProviders(&.{ registration, registration }, &indices),
    );
    try runtime.addProviders(&.{registration}, indices[0..1]);
    var second = try FakeResident.init(allocator);
    defer second.deinit();
    try std.testing.expectError(error.TransportAlreadyRegistered, runtime.addResident(
        model.transport.Known.tcp.metadata(),
        second.multiplexedResident(),
    ));
}

test "failed provider batch preserves a shared live readiness descriptor" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var resident = try AcceptOwnershipResident.init();
    defer resident.deinit();
    var runtime = try prepareAcceptOwnershipRuntime(std.testing.allocator, io, &resident);
    defer runtime.deinit();

    const multiplexed = resident.multiplexedResident();
    var indices = [_]usize{ 97, 98 };

    try std.testing.expectError(
        error.TransportSemanticsConflict,
        runtime.addProviders(&.{
            .{
                .profile = .{ .symbol = "x-shared-readiness", .designator_scheme = .address },
                .resident = multiplexed,
            },
            .{
                .profile = .{ .symbol = model.transport.tcp, .designator_scheme = .key },
                .resident = multiplexed,
            },
        }, &indices),
    );
    try std.testing.expectEqual(@as(usize, 97), indices[0]);
    try std.testing.expectEqual(@as(usize, 98), indices[1]);
    try std.testing.expectError(error.UnknownTransport, runtime.core.transportProfile("x-shared-readiness"));

    resident.announceAccept();
    _ = try runtime.stepAny(1_000);
    try std.testing.expect(resident.claimed);
}

test "equal readiness descriptors do not merge distinct multiplexed residents" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var resident = try AcceptOwnershipResident.init();
    defer resident.deinit();
    var runtime = try driver.HostRuntime.init(std.testing.allocator, io, .{}, .ephemeral, opts);
    defer runtime.deinit();

    var second_vtable = AcceptOwnershipResident.vtable;
    const first = resident.multiplexedResident();
    const second = net.MultiplexedResident{ .ctx = &resident, .vtable = &second_vtable };
    var indices = [_]usize{ 97, 98 };
    try std.testing.expectError(
        error.ReadinessDescriptorConflict,
        runtime.addProviders(&.{
            .{
                .profile = .{ .symbol = "x-runtime-one", .designator_scheme = .address },
                .resident = first,
            },
            .{
                .profile = .{ .symbol = "x-runtime-two", .designator_scheme = .address },
                .resident = second,
            },
        }, &indices),
    );
    try std.testing.expectEqual(@as(usize, 97), indices[0]);
    try std.testing.expectEqual(@as(usize, 98), indices[1]);
    try std.testing.expectEqual(@as(usize, 0), runtime.residents.items.len);
}

test "two profiles share one multiplexed resident with independent listener lifecycles" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var resident = try AcceptOwnershipResident.init();
    defer resident.deinit();
    var runtime = try driver.HostRuntime.init(std.testing.allocator, io, .{}, .ephemeral, opts);
    defer runtime.deinit();

    const multiplexed = resident.multiplexedResident();
    var indices = [_]usize{ 0, 0 };
    try runtime.addProviders(&.{
        .{
            .profile = .{ .symbol = AcceptOwnershipResident.transport, .designator_scheme = .address },
            .resident = multiplexed,
        },
        .{
            .profile = .{ .symbol = AcceptOwnershipResident.alternate_transport, .designator_scheme = .address },
            .resident = multiplexed,
        },
    }, &indices);
    try std.testing.expectEqual(indices[0], indices[1]);
    try std.testing.expectEqual(@as(usize, 1), runtime.residents.items.len);

    inline for (.{ AcceptOwnershipResident.transport, AcceptOwnershipResident.alternate_transport }) |transport| {
        try runtime.core.setAdvertisedLocator(.{
            .transport = transport,
            .designator = "resident.test:1",
            .hints = model.Hints.emptyFalse(),
        });
        try std.testing.expectError(error.InvalidAddress, runtime.connectLocator(.{
            .transport = transport,
            .designator = "remote.test:1",
            .hints = model.Hints.emptyFalse(),
        }, .inherit));
    }
    try std.testing.expectEqual([2]bool{ true, true }, resident.dialed);
    try std.testing.expectEqual(@as(usize, 0), resident.cancel_connect_calls);

    var listener = try runtime.bindListener(AcceptOwnershipResident.alternate_transport, "", .inherit);
    var listener_open = true;
    defer if (listener_open) std.testing.expect(runtime.closeListener(&listener) == null) catch unreachable;
    var second_listener = try runtime.bindListener(AcceptOwnershipResident.transport, "", .inherit);
    var second_listener_open = true;
    defer if (second_listener_open) std.testing.expect(runtime.closeListener(&second_listener) == null) catch unreachable;
    try std.testing.expectEqual(@as(usize, 2), resident.listen_calls);

    const locator = switch (runtime.listenerLocatorOutcome(&listener)) {
        .locator => |value| value,
        .failed => |failure| return failure.cause,
    };
    defer model.freePeerLocator(std.testing.allocator, locator);
    try std.testing.expectEqualStrings(AcceptOwnershipResident.alternate_transport, locator.transport);
    try runtime.activateListener(&listener, 73, .{
        .ctx = &resident,
        .opened = IgnoreSessionOpen.opened,
        .failed = IgnoreSessionOpen.failed,
    });
    try runtime.activateListener(&second_listener, 74, .{
        .ctx = &resident,
        .opened = IgnoreSessionOpen.opened,
        .failed = IgnoreSessionOpen.failed,
    });

    resident.announceAcceptFor(AcceptOwnershipResident.alternate_transport);
    _ = try runtime.stepAny(1_000);
    try std.testing.expectEqual(@as(usize, 1), resident.drain_calls);
    try std.testing.expectEqual(@as(usize, 1), runtime.pending_opens.items.len);
    try std.testing.expectEqualStrings(
        AcceptOwnershipResident.alternate_transport,
        runtime.pending_opens.items[0].session.transport,
    );

    try std.testing.expect(runtime.closeListener(&listener) == null);
    listener_open = false;
    try std.testing.expectEqual(@as(usize, 0), runtime.pending_opens.items.len);
    try std.testing.expectEqual(@as(usize, 1), resident.close_calls);

    resident.claimed = false;
    resident.announceAcceptFor(AcceptOwnershipResident.transport);
    _ = try runtime.stepAny(1_000);
    try std.testing.expectEqual(@as(usize, 1), runtime.pending_opens.items.len);
    try std.testing.expectEqualStrings(
        AcceptOwnershipResident.transport,
        runtime.pending_opens.items[0].session.transport,
    );
    try std.testing.expect(runtime.closeListener(&second_listener) == null);
    second_listener_open = false;
    try std.testing.expectEqual(@as(usize, 0), runtime.pending_opens.items.len);
    try std.testing.expectEqual(@as(usize, 2), resident.close_calls);
}

test "claimed resident accepts close exactly once across every adoption allocation failure" {
    var saw_claim_failure = false;
    var reached_success = false;

    for (0..64) |fail_offset| {
        var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        failing.fail_index = std.math.maxInt(usize);
        var resident = try AcceptOwnershipResident.init();
        defer resident.deinit();
        var runtime = try prepareAcceptOwnershipRuntime(failing.allocator(), io, &resident);

        failing.fail_index = failing.alloc_index + fail_offset;
        resident.announceAccept();
        const step_result = runtime.stepAny(1_000);
        failing.fail_index = std.math.maxInt(usize);

        if (step_result) |_| {
            reached_success = true;
            try std.testing.expect(resident.claimed);
            try std.testing.expectEqual(@as(usize, 0), resident.close_calls);
            try std.testing.expectEqual(@as(usize, 1), runtime.resident_wires.count());
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            if (resident.claimed) saw_claim_failure = true;
            const wire_owns = runtime.resident_wires.count() == 1;
            try std.testing.expectEqual(
                @as(usize, 1),
                resident.close_calls + @intFromBool(wire_owns),
            );
        }

        runtime.deinit();
        if (resident.claimed) try std.testing.expectEqual(@as(usize, 1), resident.close_calls);
        if (reached_success) break;
    }

    try std.testing.expect(saw_claim_failure);
    try std.testing.expect(reached_success);
}

test "successful resident accept transfers close ownership to the wire" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var resident = try AcceptOwnershipResident.init();
    defer resident.deinit();
    var runtime = try prepareAcceptOwnershipRuntime(std.testing.allocator, io, &resident);

    resident.announceAccept();
    _ = try runtime.stepAny(1_000);
    try std.testing.expect(resident.claimed);
    try std.testing.expectEqual(@as(usize, 0), resident.close_calls);
    try std.testing.expectEqual(@as(usize, 1), runtime.resident_wires.count());

    runtime.deinit();
    try std.testing.expectEqual(@as(usize, 1), resident.close_calls);
}

test "a resident's dial refusal reaches the dial observer with its exact failure chain" {
    const Recorder = struct {
        tag: u64 = 0,
        failure: ?driver.OperationFailure = null,

        fn opened(_: *anyopaque, _: u64, _: *driver_core.HostSession) !void {
            return error.UnexpectedOpen;
        }
        fn failed(ctx: *anyopaque, tag: u64, failure: driver.OperationFailure) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.tag = tag;
            self.failure = failure;
        }
    };

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var resident = try AcceptOwnershipResident.init();
    defer resident.deinit();
    var chain = glowcap.foundation.FailureChain.initNamed(error.ProviderIo, "ExactDialRefusal");
    chain.noteChain(.initNamed(error.ProviderIo, "ExactDialCleanup"));
    resident.dial_failure = .fromChain(error.ConnectionRefused, chain);
    var runtime = try driver.HostRuntime.init(std.testing.allocator, threaded.io(), .{}, .ephemeral, opts);
    defer runtime.deinit();
    _ = try runtime.addResident(
        .{ .symbol = AcceptOwnershipResident.transport, .designator_scheme = .address },
        resident.multiplexedResident(),
    );

    var recorder: Recorder = .{};
    try runtime.startDial(.{
        .transport = AcceptOwnershipResident.transport,
        .designator = "remote.test:1",
        .hints = model.Hints.emptyFalse(),
    }, .inherit, 41, .{ .ctx = &recorder, .opened = Recorder.opened, .failed = Recorder.failed });

    const failure = recorder.failure orelse return error.MissingDialFailure;
    try std.testing.expectEqual(@as(u64, 41), recorder.tag);
    try std.testing.expectEqual(driver.OperationFailure.Kind.io, failure.kind());
    try std.testing.expectEqualStrings("ExactDialRefusal", failure.chain.primaryName());
    try std.testing.expectEqualStrings("ExactDialCleanup", failure.chain.secondaryName().?);
    try std.testing.expectEqual(@as(u16, 1), failure.chain.secondary_count);
}

test "an always-ready resident cannot starve a sibling resident's turn" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var runtime = try driver.HostRuntime.init(std.testing.allocator, threaded.io(), .{}, .ephemeral, opts);
    defer runtime.deinit();

    var residents: [2]AcceptOwnershipResident = undefined;
    residents[0] = try AcceptOwnershipResident.init();
    defer residents[0].deinit();
    residents[1] = try AcceptOwnershipResident.init();
    defer residents[1].deinit();
    for (&residents, [_][]const u8{ "x-ready-one", "x-ready-two" }) |*resident, symbol| {
        resident.keep_ready = true;
        _ = try resident.wake.nudge();
        _ = try runtime.addResident(.{ .symbol = symbol, .designator_scheme = .address }, resident.multiplexedResident());
    }

    // A poll reports its first ready row, so without rotation every step
    // would service the first resident and never the second.
    for (0..8) |_| _ = try runtime.stepAny(0);
    try std.testing.expect(residents[0].drain_calls >= 3);
    try std.testing.expect(residents[1].drain_calls >= 3);
}
