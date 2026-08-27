//! Host and session close over fed bytes: failure diagnostics keep their
//! first cause, the close barrier commits once, cancel and expiry race to a
//! decided winner, finish waits for every kind of admitted work, and
//! transport packages publish nothing before a conflict.

const std = @import("std");
const pancake = @import("pancake");
const test_host = @import("../../support/core_host.zig");

const model = pancake.ocapn.model;
const actors = pancake.actors;
const driver = pancake.driver;

const Host = driver.core.Host;
const HostSession = driver.core.HostSession;
const engine = pancake.ocapn.engine;
const crypto = pancake.foundation.crypto;
const stream_framing = pancake.foundation.stream_framing;

const harness = @import("harness.zig");
const SessionOpenFailingAllocator = harness.SessionOpenFailingAllocator;
const TaggedRow = harness.TaggedRow;
const frame_cap = harness.frame_cap;
const Widget = harness.Widget;
const FairCounter = harness.FairCounter;
const Vendor = harness.Vendor;
const Introducer = harness.Introducer;
const host_pair = harness.host_pair;
const handshake_support = harness.handshake_support;
const Pair = harness.Pair;
const shuttle = harness.shuttle;
const shuttleAll = harness.shuttleAll;
const tcpLocator = harness.tcpLocator;
const publishAndOpenAccepted = harness.publishAndOpenAccepted;
const publishAndOpenAcceptedOver = harness.publishAndOpenAcceptedOver;
const tcpSturdyref = harness.tcpSturdyref;
const onionLocator = harness.onionLocator;
const onionSturdyref = harness.onionSturdyref;
const ParkedDial = harness.ParkedDial;
const drainActions = harness.drainActions;
const pumpToQuiescence = harness.pumpToQuiescence;
const CapturedRef = harness.CapturedRef;
const CapturedString = harness.CapturedString;
const openPair = harness.openPair;
const retireClosingSession = harness.retireClosingSession;
const retireClosedSession = harness.retireClosedSession;
const Tagged = harness.Tagged;
const keyedDesignator = harness.keyedDesignator;
const TraceLog = harness.TraceLog;

test "operation failure preserves its first cause and later chain" {
    var failure = driver.OperationFailure.fromError(error.Primary);
    var cleanup = pancake.foundation.FailureChain.init(error.FirstCleanup);
    cleanup.note(error.LaterCleanup);
    failure.noteChain(cleanup);
    failure.note(error.LastCleanup);

    try std.testing.expectEqual(error.Primary, failure.cause);
    try std.testing.expectEqual(error.FirstCleanup, failure.secondary_cause.?);
    try std.testing.expectEqual(@as(u16, 3), failure.secondary_count);
}

test "peer failure diagnostics retain first and secondary cleanup failures" {
    var peer = engine.Peer.init(std.testing.allocator);
    defer peer.deinit();

    peer.recordFailure(error.IngressCancelFailed);
    peer.recordSecondaryFailure(error.VerbTailFailed);
    peer.recordSecondaryFailure(error.LaterCleanupFailed);

    const info = peer.lastAbort().?;
    try std.testing.expectEqualStrings("IngressCancelFailed", info.error_name);
    try std.testing.expectEqual(error.VerbTailFailed, info.secondary_error.?);
    try std.testing.expectEqual(@as(u8, 2), info.secondary_error_count);

    for (0..300) |_| peer.recordSecondaryFailure(error.ExcessCleanupFailure);
    const saturated = peer.lastAbort().?;
    try std.testing.expectEqual(error.VerbTailFailed, saturated.secondary_error.?);
    try std.testing.expectEqual(std.math.maxInt(u8), saturated.secondary_error_count);
}

test "abort delivery failure without a recorded origin becomes primary" {
    var peer = engine.Peer.init(std.testing.allocator);
    defer peer.deinit();

    peer.recordAbortDeliveryFailure(error.AbortWriteFailed);
    const info = peer.lastAbort().?;
    try std.testing.expectEqualStrings("AbortWriteFailed", info.error_name);
    try std.testing.expect(info.abort_delivery_error == null);
}

test "Host action failure detail remains diagnostic when retaining it cannot allocate" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const retained = driver.core.testing.retainFailureMessage(failing.allocator(), "specific partner refusal");
    try std.testing.expect(!retained.owned);
    try std.testing.expectEqualStrings("failure detail unavailable: allocation failed", retained.bytes);
}

test "Host admission frame cap defaults to the canonical session limit" {
    // Single-source lock: a default-constructed Host admits the same frame size
    // the driver C ABI publishes as PANCAKE_DEFAULT_FRAME_CAP, so a native Zig
    // embedder and a C embedder agree on the default admission cap. If someone
    // re-hardcodes this default to a bare literal, this fails instead of
    // silently shrinking a Zig host's admissible frame below the advertised C
    // default.
    try std.testing.expectEqual(
        (engine.SessionLimits{}).max_frame_bytes,
        (Host.Options{}).frameCap(),
    );
}

test "core host close seals admission and an idle finish closes immediately" {
    var host = test_host.init(std.testing.allocator, @as([32]u8, @splat(0x21)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    host.beginClose(.{ .finish = .unbounded }, 0);
    try std.testing.expectEqual(Host.LifecyclePhase.finishing, host.lifecyclePhase());
    try host.progressClose(0);
    try std.testing.expectEqual(Host.LifecyclePhase.closed, host.lifecyclePhase());
    try std.testing.expectError(error.HostClosing, host.openAcceptedAdvertised("tcp"));
    host.beginClose(.cancel, 0);
    try std.testing.expectEqual(Host.LifecyclePhase.closed, host.lifecyclePhase());
}

test "core host close initiation cannot fail after committing its barrier" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var host = test_host.init(failing.allocator(), @as([32]u8, @splat(0x34)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    const session = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:7081", &.{});
    while (try host.nextAction()) |_| {}
    while (try session.takeOutbound()) |frame_value| {
        var frame = frame_value;
        frame.deinit();
    }
    try session.served.port.peer.sendCopying(.{ .abort = .{
        .kind = .graceful_shutdown,
        .message = "queued before finish",
    } });
    driver.core.testing.markDirty(&host, session.peer_handle);

    failing.fail_index = failing.alloc_index;
    host.beginClose(.{ .finish = .unbounded }, 0);
    try std.testing.expectEqual(Host.LifecyclePhase.finishing, host.lifecyclePhase());

    try host.progressClose(1);
    try std.testing.expectEqual(Host.LifecyclePhase.finishing, host.lifecyclePhase());

    failing.fail_index = std.math.maxInt(usize);
    const allocations_before_retry = failing.alloc_index;
    try host.progressClose(2);
    try std.testing.expect(failing.alloc_index > allocations_before_retry);
    host.beginClose(.cancel, 3);
    var saw_close = false;
    while (try host.nextAction()) |action| switch (action) {
        .flush => while (try session.takeOutbound()) |frame_value| {
            var frame = frame_value;
            frame.deinit();
        },
        .close => saw_close = true,
        else => {},
    };
    try host.progressClose(4);
    try std.testing.expectEqual(Host.LifecyclePhase.closed, host.lifecyclePhase());
    try std.testing.expect(saw_close);
    try host.releaseSession(session);
}

test "core session close retains terminal drive under post-transition OOM" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var host = test_host.init(failing.allocator(), @as([32]u8, @splat(0x35)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    try host.ensureAdvertisedLocator("tcp");
    const session = try host.openDialedLocator(tcpLocator("127.0.0.1:7080"));
    while (try host.nextAction()) |_| {}
    while (try session.takeOutbound()) |frame_value| {
        var frame = frame_value;
        frame.deinit();
    }

    failing.fail_index = failing.alloc_index;
    try host.beginSessionClose(session, .cancel, 0);
    try std.testing.expect(session.lifecyclePhase() != .active);

    try host.progressSessionCloses(1);
    try std.testing.expect(!host.sessionCloseActionDelivered(session));

    failing.fail_index = std.math.maxInt(usize);
    try host.progressSessionCloses(2);
    var saw_close = false;
    while (try host.nextAction()) |action| switch (action) {
        .flush => while (try session.takeOutbound()) |frame_value| {
            var frame = frame_value;
            frame.deinit();
        },
        .close => saw_close = true,
        else => {},
    };
    try std.testing.expect(saw_close);
    try std.testing.expectEqual(driver.core.CloseOutcome.closed, host.sessionCloseOutcome(session, true));
    try host.releaseSession(session);
}

test "core close policy validates representation-neutral inputs" {
    const close = driver.core;
    try std.testing.expectEqual(close.PendingWork.cancel, try (close.PendingWorkInput{
        .pending = .cancel,
        .grace = .unspecified,
    }).resolve());
    try std.testing.expectError(error.CancelGraceSpecified, (close.PendingWorkInput{
        .pending = .cancel,
        .grace = .{ .finite_ms = 0 },
    }).resolve());
    try std.testing.expectError(error.FinishGraceRequired, (close.PendingWorkInput{
        .pending = .finish,
        .grace = .unspecified,
    }).resolve());
    try std.testing.expectEqual(close.PendingWork{ .finish = .unbounded }, try (close.PendingWorkInput{
        .pending = .finish,
        .grace = .unbounded,
    }).resolve());
    try std.testing.expectEqual(close.PendingWork{ .finish = .{ .ms = close.max_finite_close_grace_ms } }, try (close.PendingWorkInput{
        .pending = .finish,
        .grace = .{ .finite_ms = close.max_finite_close_grace_ms },
    }).resolve());
}

test "core close wait selects and safely clamps the nearest deadline" {
    var host = test_host.init(std.testing.allocator, @as([32]u8, @splat(0x35)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    try std.testing.expectEqual(@as(i64, -1), host.closeWaitMs(0));

    try host.ensureAdvertisedLocator("tcp");
    const session = try host.openDialedLocator(tcpLocator("127.0.0.1:7084"));
    try host.beginSessionClose(session, .{ .finish = .{ .ms = 50 } }, 100);
    host.beginClose(.{ .finish = .{ .ms = 100 } }, 100);

    try std.testing.expectEqual(@as(i64, 50), host.closeWaitMs(100));
    try std.testing.expectEqual(@as(i64, 10), host.closeWaitMs(140));
    try std.testing.expectEqual(@as(i64, 0), host.closeWaitMs(150));
    try std.testing.expectEqual(@as(i64, 0), host.closeWaitMs(std.math.maxInt(i64)));
}

test "core close wait advances when the nearest session deadline retires" {
    var host = test_host.init(std.testing.allocator, @as([32]u8, @splat(0x36)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    try host.ensureAdvertisedLocator("tcp");
    const first = try host.openDialedLocator(tcpLocator("127.0.0.1:7087"));
    const second = try host.openDialedLocator(tcpLocator("127.0.0.1:7088"));
    try host.beginSessionClose(first, .{ .finish = .{ .ms = 50 } }, 100);
    try host.beginSessionClose(second, .{ .finish = .{ .ms = 100 } }, 100);
    try std.testing.expectEqual(@as(i64, 50), host.closeWaitMs(100));

    try driver.core.testing.condemn(&host, first, .normal_shutdown, "test retirement");
    try std.testing.expectEqual(@as(i64, 100), host.closeWaitMs(100));
}

test "core host cancel invalidates a queued redeem dial before external delivery" {
    var host = test_host.init(std.testing.allocator, @as([32]u8, @splat(0x22)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    const vow_id = try host.enlivenSelectOrDial(tcpSturdyref("127.0.0.1:7086", "widget"));
    host.beginClose(.cancel, 0);

    const failed = (try host.nextAction()) orelse return error.MissingFailure;
    try std.testing.expect(failed == .failed);
    try std.testing.expectEqual(vow_id, failed.failed.vow_id);
    try std.testing.expectEqual(driver.core.VowFailure.closed, failed.failed.failure);
    try std.testing.expect((try host.nextAction()) == null);
    try std.testing.expectEqual(Host.LifecyclePhase.closed, host.lifecyclePhase());
}

test "core abnormal termination settles every parked enliven closed" {
    var host = test_host.init(std.testing.allocator, @as([32]u8, @splat(0x23)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    const vow_id = try host.enlivenSelectOrDial(tcpSturdyref("127.0.0.1:7089", "widget"));
    driver.core.testing.startAbnormalTermination(&host);

    var saw_failure = false;
    while (try host.nextAction()) |action| switch (action) {
        .failed => |failed| if (failed.vow_id == vow_id) {
            try std.testing.expectEqual(driver.core.VowFailure.closed, failed.failure);
            saw_failure = true;
        },
        else => {},
    };
    try std.testing.expect(saw_failure);
    try std.testing.expectEqual(Host.LifecyclePhase.closed, host.lifecyclePhase());
}

test "core host finish counts pending gift entropy and cancel retires it without an effect" {
    var host = test_host.init(std.testing.allocator, @as([32]u8, @splat(0x23)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    const recipient = try host.node.registerPeer(.{});
    const exporter = try host.node.registerPeer(.{});
    try host.node.peer(exporter).?.session_state.registerImport(.from(4));
    const gift = try host.node.enrollForeign(exporter, .{ .far = model.FarRef.object(4) });
    try host.node.peer(recipient).?.session_state.installInboundAnswer(.from(9));
    try std.testing.expect(try host.node.interceptFulfilledRoute(recipient, 9, gift.routed.id));

    host.beginClose(.{ .finish = .unbounded }, 0);
    try std.testing.expectEqual(Host.LifecyclePhase.finishing, host.lifecyclePhase());
    try std.testing.expectEqual(@as(usize, 1), host.node.pendingGiftEffects());

    host.beginClose(.cancel, 0);
    try std.testing.expectEqual(@as(usize, 0), host.node.pendingGiftEffects());
    try std.testing.expect((try host.nextAction()) == null);
    try std.testing.expect((try host.nextAction()) == null);
    try std.testing.expectEqual(Host.LifecyclePhase.closed, host.lifecyclePhase());
}

test "core host failures classify at the sans-I/O authority" {
    const HostFailure = driver.core.HostFailure;
    try std.testing.expectEqual(HostFailure.Kind.internal, HostFailure.classify(error.OutOfMemory));
    try std.testing.expectEqual(HostFailure.Kind.not_found, HostFailure.classify(error.CapabilityRouteUnavailable));
    try std.testing.expectEqual(HostFailure.Kind.invalid_argument, HostFailure.classify(error.ForeignArgument));
    try std.testing.expectEqual(HostFailure.Kind.would_block, HostFailure.classify(error.OutboundBackpressure));
    try std.testing.expectEqual(HostFailure.Kind.would_block, HostFailure.classify(error.SessionOperationLimitReached));
    try std.testing.expectEqual(HostFailure.Kind.closed, HostFailure.classify(error.SessionClosing));
    try std.testing.expectEqual(HostFailure.Kind.session, HostFailure.classify(error.SendRejected));
    try std.testing.expectEqual(HostFailure.Kind.session, HostFailure.classify(error.OutboundAnswerSpaceExhausted));
    try std.testing.expectEqual(HostFailure.Kind.codec, HostFailure.classify(error.MalformedView));
    try std.testing.expectEqual(HostFailure.Kind.frame_too_large, HostFailure.classify(error.FrameTooLarge));
}

test "driver and Host failure tables agree on every name both classify" {
    // `driver.OperationFailure` extends the sans-I/O `HostFailure` vocabulary
    // with I/O, timeout, and would-block arms it alone can mint. The names
    // both tables list explicitly must land in corresponding categories, or an
    // embedder sees one error change meaning across the two fronts. The two
    // `else` arms differ on purpose (driver: transport I/O; Host: abort
    // projection), so only the shared explicit names are held here.
    const HostFailure = driver.core.HostFailure;
    const OperationFailure = driver.OperationFailure;
    const shared = [_]anyerror{
        error.HostClosing,
        error.SessionClosing,
        error.SessionCondemned,
        error.UnknownTransport,
        error.TransportSemanticsConflict,
        error.TransportAlreadyRegistered,
        error.InvalidTransportName,
        error.ReenteredHost,
        error.MissingAdvertisedLocator,
        error.InvalidArgument,
        error.OutOfMemory,
        error.OutboundAnswerSpaceExhausted,
    };
    for (shared) |cause| {
        const expected: OperationFailure.Kind = switch (HostFailure.classify(cause)) {
            .invalid_argument => .invalid_argument,
            .closed => .closed,
            .internal => .internal,
            .would_block => .would_block,
            .session => .session,
            .not_found, .codec, .frame_too_large => unreachable,
        };
        try std.testing.expectEqual(expected, OperationFailure.classify(cause));
    }
}

test "hosted Host-wide publication consumes its context on preflight failure" {
    const Hosted = struct {
        fn handle(_: *anyopaque, _: *actors.Turn, _: actors.Message) anyerror!model.Argument {
            unreachable;
        }

        fn free(ctx: *anyopaque) void {
            const freed: *bool = @ptrCast(@alignCast(ctx));
            freed.* = true;
        }
    };

    var host = test_host.init(std.testing.allocator, @as([32]u8, @splat(0x22)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    host.beginClose(.cancel, 0);

    var giftable_freed = false;
    try std.testing.expectError(error.HostClosing, host.publishHostedGiftable("closed", .{
        .ctx = &giftable_freed,
        .handle = Hosted.handle,
        .free = Hosted.free,
    }));
    try std.testing.expect(giftable_freed);

    var durable_freed = false;
    try std.testing.expectError(error.HostClosing, host.publishHostedDurable(
        @as([engine.durable_swiss_entropy_len]u8, @splat(0x23)),
        .{
            .ctx = &durable_freed,
            .handle = Hosted.handle,
            .free = Hosted.free,
        },
    ));
    try std.testing.expect(durable_freed);
}

test "core host expiry wins over a cancel arriving at the deadline" {
    var host = test_host.init(std.testing.allocator, @as([32]u8, @splat(0x32)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    try host.ensureAdvertisedLocator("tcp");
    const session = try host.openDialedLocator(tcpLocator("127.0.0.1:7083"));
    host.beginClose(.{ .finish = .{ .ms = 10 } }, 100);
    host.beginClose(.cancel, 110);
    while (try host.nextAction()) |action| switch (action) {
        .flush => while (try session.takeOutbound()) |frame_value| {
            var frame = frame_value;
            frame.deinit();
        },
        else => {},
    };
    try std.testing.expectEqual(Host.LifecyclePhase.closed, host.lifecyclePhase());
    try std.testing.expectEqual(driver.core.CloseOutcome.timed_out, host.closeOutcome(true));
    host.beginClose(.{ .finish = .unbounded }, 111);
    try std.testing.expectEqual(driver.core.CloseOutcome.timed_out, host.closeOutcome(true));
    try host.releaseSession(session);
}

test "core session expiry wins over a cancel arriving at the deadline" {
    var host = test_host.init(std.testing.allocator, @as([32]u8, @splat(0x33)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    try host.ensureAdvertisedLocator("tcp");
    const session = try host.openDialedLocator(tcpLocator("127.0.0.1:7082"));
    while (try host.nextAction()) |action| switch (action) {
        .flush => while (try session.takeOutbound()) |frame_value| {
            var frame = frame_value;
            frame.deinit();
        },
        else => {},
    };
    try host.beginSessionClose(session, .{ .finish = .{ .ms = 10 } }, 100);
    try host.beginSessionClose(session, .cancel, 110);
    try std.testing.expectEqual(driver.core.CloseOutcome.pending, host.sessionCloseOutcome(session, false));
    var saw_flush = false;
    var saw_close = false;
    while (try host.nextAction()) |action| switch (action) {
        .flush => {
            saw_flush = true;
            while (try session.takeOutbound()) |frame_value| {
                var frame = frame_value;
                frame.deinit();
            }
        },
        .close => {
            try std.testing.expect(saw_flush);
            saw_close = true;
        },
        else => {},
    };
    try std.testing.expect(saw_close);
    try std.testing.expectEqual(driver.core.CloseOutcome.timed_out, host.sessionCloseOutcome(session, true));
    try host.releaseSession(session);
}

test "close policy stamps the partner-visible abort kind" {
    // The wire artifact of the two close policies: cancel condemns a live
    // session with `normal_shutdown`, a finish that reaches quiescence with
    // `graceful_shutdown`. Nothing else pins the label split, so a swap would
    // otherwise ship silently.
    const allocator = std.testing.allocator;
    const codec = pancake.ocapn.codec;
    const cases = [_]struct {
        policy: driver.core.PendingWork,
        kind: model.AbortKind,
        seed: u8,
        designator: []const u8,
    }{
        .{ .policy = .cancel, .kind = .normal_shutdown, .seed = 0x8c, .designator = "127.0.0.1:7113" },
        .{ .policy = .{ .finish = .unbounded }, .kind = .graceful_shutdown, .seed = 0x9c, .designator = "127.0.0.1:7114" },
    };
    for (cases) |case| {
        var client = test_host.init(allocator, @as([32]u8, @splat(case.seed)), Host.Options.withFrameCap(frame_cap));
        defer client.deinit();
        var server = test_host.init(allocator, @as([32]u8, @splat(case.seed + 1)), Host.Options.withFrameCap(frame_cap));
        defer server.deinit();
        var dials: std.ArrayList(ParkedDial) = .empty;
        defer dials.deinit(allocator);
        const pair = try openPair(allocator, &client, &server, case.designator, &dials);

        client.beginClose(case.policy, 0);
        var kind: ?model.AbortKind = null;
        while (try client.nextAction()) |action| switch (action) {
            .flush => |peer_handle| {
                try std.testing.expectEqual(pair.a.peer_handle, peer_handle);
                while (try pair.a.takeOutbound()) |frame_value| {
                    var frame = frame_value;
                    defer frame.deinit();
                    const body = try codec.syrup.decodeBodyForProfile(.v1_0, frame.view());
                    if (body == .abort) kind = body.abort.kind;
                }
            },
            .close => |peer_handle| {
                try std.testing.expectEqual(pair.a.peer_handle, peer_handle);
                try client.releaseSession(pair.a);
            },
            else => {},
        };
        try std.testing.expectEqual(case.kind, kind orelse return error.MissingAbort);
    }
}
