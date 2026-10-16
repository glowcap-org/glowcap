//! Early-withdraw verification and admission: the claim verifies before
//! waiting and retains one accepted count, a permissive resolver cannot pass
//! malformed signed widths into pending retention, admission OOM leaves no
//! pending row or replay state, and the pending cap refuses loud with the
//! projected resource_exhausted.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const codec = glowcap.ocapn.codec;
const engine = glowcap.ocapn.engine;
const session = glowcap.ocapn.session;
const crypto = glowcap.foundation.crypto;
const syrup = glowcap.ocapn.codec.syrup;
const cross_peer = @import("../../support/cross_peer.zig");
const CountingAllocator = @import("../../support/alloc_metrics.zig").CountingAllocator;
const peer_fixture = @import("../../support/peer_fixture.zig");

const fixtures = @import("fixtures.zig");
const repeated = fixtures.repeated;
const recipient_key = fixtures.recipient_key;
const gifter_session = fixtures.gifter_session;
const gifter_side = fixtures.gifter_side;
const receiving_session = fixtures.receiving_session;
const receiving_side = fixtures.receiving_side;
const give_signature = fixtures.give_signature;
const receive_signature = fixtures.receive_signature;
const gift_id_a = fixtures.gift_id_a;
const gift_id_b = fixtures.gift_id_b;
const sideOf = fixtures.sideOf;
const GifterSessionFixture = fixtures.GifterSessionFixture;
const PermissiveGifterSessionFixture = fixtures.PermissiveGifterSessionFixture;
const giveWith = fixtures.giveWith;
const receiveWith = fixtures.receiveWith;
const RejectingVerifier = fixtures.RejectingVerifier;
const RoutingVerifier = fixtures.RoutingVerifier;
const signedGive = fixtures.signedGive;

test "an early withdraw verifies before waiting and retains only one accepted count" {
    const allocator = std.testing.allocator;
    const gifter_secret = crypto.SecretKey.fromSeed(repeated(32, 0x65));
    const recipient_secret = crypto.SecretKey.fromSeed(repeated(32, 0x66));
    const gifter_pub = gifter_secret.publicKey();
    const recipient_pub = recipient_secret.publicKey();
    const recipient_side = sideOf(recipient_pub);

    var give_signed: []u8 = undefined;
    var give_sig: crypto.Signature = undefined;
    const give = try signedGive(gift_id_a[0..], recipient_pub.asBytes(), &gifter_secret, &give_signed, &give_sig, allocator);
    defer allocator.free(give_signed);

    var receive: model.HandoffReceive = .{
        .receiving_session = receiving_session[0..],
        .receiving_side = &recipient_side,
        .handoff_count = 1,
        .signed_give = give,
        .signature = "",
    };
    const receive_signed = try syrup.canonicalHandoffReceiveSignedBytes(allocator, receive);
    defer allocator.free(receive_signed);
    const receive_sig = crypto.sign(&recipient_secret, receive_signed);

    var exporter = peer_fixture.openPeer(allocator);
    defer exporter.deinit();
    var resolver_fixture: GifterSessionFixture = .{
        .side = gifter_side,
        .session_name = gifter_session,
        .key = gifter_pub.bytes,
        .gifts = exporter.giftRegistry(),
    };
    var node = engine.Node.init(allocator, repeated(32, 0x67));
    defer node.deinit();
    node.setGifterSessionResolver(resolver_fixture.resolver());
    resolver_fixture.peer_handle = try node.registerPeerOver(&exporter);

    // A malformed receive signature breaks immediately. It consumes neither
    // owned pending state nor the replay count, so the corrected certificate
    // below is still the first accepted use of count 1.
    receive.signature = &[_]u8{0};
    var invalid_handoff = model.Handoff{ .receive = receive };
    const invalid_view = model.view.Handoff.fromOwned(&invalid_handoff);
    var invalid = switch (try engine.bootstrap.resolveForWithdraw(
        allocator,
        &exporter.session_state,
        exporter.giftRegistry(),
        exporter.gifterSessionResolver(),
        null,
        null,
        .{ .receive = invalid_view.receive, .answer = .fromWire(.from(1)) },
    )) {
        .settled => |settled| settled,
        .awaiting_deposit => |admission| {
            var pending_receive = admission.receive;
            pending_receive.deinit(allocator);
            return error.TestUnexpectedPending;
        },
    };
    defer invalid.deinit(allocator);
    try std.testing.expect(invalid.resolution.? == .@"break");

    receive.signature = receive_sig.asBytes();
    var valid_handoff = model.Handoff{ .receive = receive };
    const valid_view = model.view.Handoff.fromOwned(&valid_handoff);
    const admission = switch (try engine.bootstrap.resolveForWithdraw(
        allocator,
        &exporter.session_state,
        exporter.giftRegistry(),
        exporter.gifterSessionResolver(),
        null,
        null,
        .{ .receive = valid_view.receive, .answer = .fromWire(.from(2)) },
    )) {
        .awaiting_deposit => |pending| pending,
        .settled => return error.TestUnexpectedSettlement,
    };
    defer {
        var pending = admission.receive;
        pending.deinit(allocator);
    }
    exporter.giftRegistry().acceptValidatedPendingWithdraw(admission.receive.handoff_count);

    // Replaying the same verified certificate is refused before a second owned
    // handoff can be admitted.
    var replay = switch (try engine.bootstrap.resolveForWithdraw(
        allocator,
        &exporter.session_state,
        exporter.giftRegistry(),
        exporter.gifterSessionResolver(),
        null,
        null,
        .{ .receive = valid_view.receive, .answer = .fromWire(.from(3)) },
    )) {
        .settled => |settled| settled,
        .awaiting_deposit => |second| {
            var pending_receive = second.receive;
            pending_receive.deinit(allocator);
            return error.TestUnexpectedPending;
        },
    };
    defer replay.deinit(allocator);
    try std.testing.expect(replay.resolution.? == .@"break");
}

test "a permissive resolver cannot pass malformed signed widths into pending retention" {
    const allocator = std.testing.allocator;
    const gifter_secret = crypto.SecretKey.fromSeed(repeated(32, 0x75));
    const recipient_secret = crypto.SecretKey.fromSeed(repeated(32, 0x76));
    const gifter_pub = gifter_secret.publicKey();
    const recipient_pub = recipient_secret.publicKey();
    const recipient_side = sideOf(recipient_pub);

    var peer = engine.Peer.init(allocator);
    defer peer.deinit();
    var permissive: PermissiveGifterSessionFixture = .{
        .key = gifter_pub.bytes,
        .gifts = peer.giftRegistry(),
    };

    // Each case is a correctly signed envelope whose signed gifter-side or
    // gifter-session field has a width `PendingReceive` cannot retain. The
    // signatures are real: the width check is the only thing standing between
    // this envelope and the fixed-width copies. Short and long widths exercise
    // the two distinct copy hazards.
    const wrong = repeated(64, 0x11);
    const Case = struct { session: []const u8, side: []const u8 };
    const cases = [_]Case{
        .{ .session = wrong[0..8], .side = gifter_side[0..] },
        .{ .session = wrong[0..], .side = gifter_side[0..] },
        .{ .session = gifter_session[0..], .side = wrong[0..8] },
        .{ .session = gifter_session[0..], .side = wrong[0..] },
    };

    for (cases, 1..) |case, answer_at| {
        var give: model.HandoffGive = .{
            .recipient_key = recipient_pub.asBytes(),
            .exporter = .{ .transport = "memory", .designator = "exporter" },
            .gifter_exporter_session = case.session,
            .gifter_side = case.side,
            .gift_id = gift_id_a[0..],
            .signature = "",
        };
        const give_signed = try syrup.canonicalHandoffGiveSignedBytes(allocator, give);
        defer allocator.free(give_signed);
        const give_sig = crypto.sign(&gifter_secret, give_signed);
        give.signature = give_sig.asBytes();

        var receive: model.HandoffReceive = .{
            .receiving_session = receiving_session[0..],
            .receiving_side = &recipient_side,
            .handoff_count = 1,
            .signed_give = give,
            .signature = "",
        };
        const receive_signed = try syrup.canonicalHandoffReceiveSignedBytes(allocator, receive);
        defer allocator.free(receive_signed);
        const receive_sig = crypto.sign(&recipient_secret, receive_signed);
        receive.signature = receive_sig.asBytes();

        // The gift is absent, so a healthy envelope would reach
        // pending retention; only the width check can turn this one away.
        const calls_before = permissive.resolve_calls;
        const handoff = model.Handoff{ .receive = receive };
        const view_handoff = model.view.Handoff.fromOwned(&handoff);
        var refused = switch (try engine.bootstrap.resolveForWithdraw(
            allocator,
            &peer.session_state,
            peer.giftRegistry(),
            permissive.resolver(),
            null,
            null,
            .{ .receive = view_handoff.receive, .answer = .fromWire(.from(answer_at)) },
        )) {
            .settled => |settled| settled,
            .awaiting_deposit => |admission| {
                var pending_receive = admission.receive;
                pending_receive.deinit(allocator);
                return error.TestUnexpectedPending;
            },
        };
        defer refused.deinit(allocator);

        // The resolver was consulted, so the break below came from the width
        // boundary behind it, not from a closed gifter session.
        try std.testing.expectEqual(calls_before + 1, permissive.resolve_calls);
        try std.testing.expectEqual(model.AnswerName.fromWire(.from(answer_at)), refused.answer);
        const reason = switch (refused.resolution.?) {
            .@"break" => |broken| broken.message,
            .fulfill => return error.TestUnexpectedFulfill,
        };
        try std.testing.expectEqualStrings("handoff session names a malformed key", reason);

        // A safe break and nothing else: no pending row, no replay
        // advancement, no consumed gift.
        try std.testing.expectEqual(@as(usize, 0), peer.pendingWithdrawCount());
        try std.testing.expectEqual(@as(?u64, null), peer.giftRegistry().acceptedHandoffCount());
        try std.testing.expect(!peer.giftRegistry().giftLive(gift_id_a[0..]));
    }

    // Control: the same envelope shape with healthy widths reaches pending
    // retention through the same permissive resolver, so the refusals above
    // are attributable to the width boundary alone.
    var give_signed: []u8 = undefined;
    var give_sig: crypto.Signature = undefined;
    const give = try signedGive(gift_id_a[0..], recipient_pub.asBytes(), &gifter_secret, &give_signed, &give_sig, allocator);
    defer allocator.free(give_signed);
    var receive: model.HandoffReceive = .{
        .receiving_session = receiving_session[0..],
        .receiving_side = &recipient_side,
        .handoff_count = 1,
        .signed_give = give,
        .signature = "",
    };
    const receive_signed = try syrup.canonicalHandoffReceiveSignedBytes(allocator, receive);
    defer allocator.free(receive_signed);
    const receive_sig = crypto.sign(&recipient_secret, receive_signed);
    receive.signature = receive_sig.asBytes();

    const handoff = model.Handoff{ .receive = receive };
    const view_handoff = model.view.Handoff.fromOwned(&handoff);
    const admission = switch (try engine.bootstrap.resolveForWithdraw(
        allocator,
        &peer.session_state,
        peer.giftRegistry(),
        permissive.resolver(),
        null,
        null,
        .{ .receive = view_handoff.receive, .answer = .fromWire(.from(9)) },
    )) {
        .awaiting_deposit => |pending| pending,
        .settled => return error.TestUnexpectedSettlement,
    };
    var pending_receive = admission.receive;
    defer pending_receive.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 1), pending_receive.handoff_count);
}

test "early-withdraw admission OOM leaves no pending row or replay state" {
    const allocator = std.testing.allocator;
    const gifter_secret = crypto.SecretKey.fromSeed(repeated(32, 0x6a));
    const recipient_secret = crypto.SecretKey.fromSeed(repeated(32, 0x6b));
    const gifter_pub = gifter_secret.publicKey();
    const recipient_pub = recipient_secret.publicKey();
    const recipient_side = sideOf(recipient_pub);

    var give_signed: []u8 = undefined;
    var give_sig: crypto.Signature = undefined;
    const give = try signedGive(gift_id_a[0..], recipient_pub.asBytes(), &gifter_secret, &give_signed, &give_sig, allocator);
    defer allocator.free(give_signed);
    var receive: model.HandoffReceive = .{
        .receiving_session = receiving_session[0..],
        .receiving_side = &recipient_side,
        .handoff_count = 1,
        .signed_give = give,
        .signature = "",
    };
    const receive_signed = try syrup.canonicalHandoffReceiveSignedBytes(allocator, receive);
    defer allocator.free(receive_signed);
    const receive_sig = crypto.sign(&recipient_secret, receive_signed);
    receive.signature = receive_sig.asBytes();

    const Snapshot = struct {
        step_oom: bool,
        pending_len: usize,
        pending_capacity: usize,
        replay_advanced: bool,
        waiters_before_remove: usize,
        waiters_after_remove: usize,
    };
    const Runner = struct {
        fn run(receive_value: model.HandoffReceive, gifter_key: crypto.PeerKey, fail_offset: usize) !Snapshot {
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
            const fail_allocator = failing.allocator();
            var exporter = peer_fixture.openPeer(fail_allocator);
            defer exporter.deinit();
            var resolver_fixture: GifterSessionFixture = .{
                .side = gifter_side,
                .session_name = gifter_session,
                .key = gifter_key.bytes,
                .gifts = exporter.giftRegistry(),
            };
            var node = engine.Node.init(fail_allocator, repeated(32, 0x6c));
            defer node.deinit();
            node.setGifterSessionResolver(resolver_fixture.resolver());
            const exporter_id = try node.registerPeerOver(&exporter);
            // Exercise the production composition path: this adopted receiver
            // must reserve its Node scheduler dependency before replay commits.
            resolver_fixture.peer_handle = exporter_id;

            var handoff_arg = model.Handoff{ .receive = receive_value };
            const frame = try syrup.encodeMessageForProfile(std.testing.allocator, .next, .{ .deliver = .{
                .target = .{ .far = model.FarRef.object(0) },
                .args = &.{ .{ .symbol = "withdraw-gift" }, .{ .handoff = &handoff_arg } },
                .answer = .from(1),
                .resolve_me_desc = .{ .near = model.NearRef.object(0) },
            } });
            try exporter.feedOwned(frame);

            failing.fail_index = failing.alloc_index + fail_offset;
            const step_result = exporter.step();
            const step_oom = if (step_result) |_| false else |err| switch (err) {
                error.OutOfMemory => true,
                else => return err,
            };
            failing.fail_index = std.math.maxInt(usize);

            var replay_advanced = false;
            exporter.giftRegistry().validateWithdrawEnvelope(receive_value, null) catch |err| switch (err) {
                session.Error.HandoffReplay => replay_advanced = true,
                else => return err,
            };
            const waiters_before_remove = node.handoffWaiterCount(exporter_id);
            // Remove an adopted receiver with its real pending row still live.
            // `detachNodeServices` must unregister that row before severing the
            // borrowed link; a hand-written callback sequence would not prove
            // the receiver teardown path.
            node.removePeer(exporter_id);
            const waiters_after_remove = node.handoffWaiterCount(exporter_id);
            return .{
                .step_oom = step_oom,
                .pending_len = exporter.pendingWithdrawCount(),
                .pending_capacity = exporter.pendingWithdrawCapacity(),
                .replay_advanced = replay_advanced,
                .waiters_before_remove = waiters_before_remove,
                .waiters_after_remove = waiters_after_remove,
            };
        }
    };

    // Exercise every fallible allocation in frame application and admission.
    // Replay is scalar session state now, so the pending-list reservation is
    // the final allocation before replay authority commits and the row is
    // appended. Every propagated OOM must therefore leave both untouched.
    var saw_oom = false;
    var saw_admitted = false;
    for (0..128) |offset| {
        const snapshot = try Runner.run(receive, gifter_pub, offset);
        if (snapshot.step_oom) {
            saw_oom = true;
            try std.testing.expectEqual(@as(usize, 0), snapshot.pending_len);
            try std.testing.expect(!snapshot.replay_advanced);
            try std.testing.expectEqual(@as(usize, 0), snapshot.waiters_before_remove);
        } else if (snapshot.pending_len == 1) {
            saw_admitted = true;
            try std.testing.expect(snapshot.pending_capacity != 0);
            try std.testing.expect(snapshot.replay_advanced);
            try std.testing.expectEqual(@as(usize, 1), snapshot.waiters_before_remove);
        }
        try std.testing.expectEqual(@as(usize, 0), snapshot.waiters_after_remove);
    }
    try std.testing.expect(saw_oom);
    try std.testing.expect(saw_admitted);
}

test "a second early withdraw past max_pending_withdraws refuses loud and projects resource_exhausted" {
    const allocator = std.testing.allocator;

    const gifter_secret = crypto.SecretKey.fromSeed(repeated(32, 0x61));
    const recipient_secret = crypto.SecretKey.fromSeed(repeated(32, 0x62));
    const gifter_pub = gifter_secret.publicKey();
    const recipient_pub = recipient_secret.publicKey();
    const recipient_side = sideOf(recipient_pub);

    // The park table is peer-supplied (a partner can flood `withdraw-gift`s whose
    // deposits never arrive), so the cap must refuse, not silently drop.
    var exporter = peer_fixture.openPeer(allocator);
    defer exporter.deinit();
    var resolver_fixture: GifterSessionFixture = .{
        .side = gifter_side,
        .session_name = gifter_session,
        .key = gifter_pub.bytes,
        .gifts = exporter.giftRegistry(),
    };
    var node = engine.Node.init(allocator, repeated(32, 0x64));
    defer node.deinit();
    node.setGifterSessionResolver(resolver_fixture.resolver());
    resolver_fixture.peer_handle = try node.registerPeerOver(&exporter);
    exporter.session_state.limits.max_pending_withdraws = 1;
    try exporter.session_state.transitionToOpen();

    // Two fully verified withdraws for gifts with no deposit. The first waits;
    // the second has a fresh handoff count but cannot cross the pending bound.
    for ([_][]const u8{ gift_id_a[0..], gift_id_b[0..] }, 0..) |gift_id, i| {
        var give_signed: []u8 = undefined;
        var give_sig: crypto.Signature = undefined;
        const give = try signedGive(gift_id, recipient_pub.asBytes(), &gifter_secret, &give_signed, &give_sig, allocator);
        defer allocator.free(give_signed);
        var receive: model.HandoffReceive = .{
            .receiving_session = receiving_session[0..],
            .receiving_side = &recipient_side,
            .handoff_count = @intCast(i + 1),
            .signed_give = give,
            .signature = "",
        };
        const receive_signed = try syrup.canonicalHandoffReceiveSignedBytes(allocator, receive);
        defer allocator.free(receive_signed);
        const receive_sig = crypto.sign(&recipient_secret, receive_signed);
        receive.signature = receive_sig.asBytes();

        var handoff_arg = model.Handoff{ .receive = receive };
        const frame = try syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
            .target = .{ .far = model.FarRef.object(0) },
            .args = &.{ .{ .symbol = "withdraw-gift" }, .{ .handoff = &handoff_arg } },
            .answer = .from(@intCast(i + 1)),
            .resolve_me_desc = .{ .near = model.NearRef.object(0) },
        } });
        try exporter.feedOwned(frame);
        if (i == 0) {
            while ((try exporter.step()) != .idle) {}
            try std.testing.expectEqual(@as(usize, 1), exporter.pendingWithdrawCount());
        }
    }

    // The second early withdraw trips the cap: the dispatch fails loud with the
    // typed refusal and the projected abort closes the session as
    // resource_exhausted. Session closure retires the first parked receive too:
    // neither replay nor scheduler authority outlives the closed Peer shell.
    try std.testing.expectError(session.Error.PendingWithdrawCapExceeded, exporter.step());
    try std.testing.expectEqual(@as(usize, 0), exporter.pendingWithdrawCount());
    const classified = engine.abort_projection.classify(session.Error.PendingWithdrawCapExceeded);
    try std.testing.expectEqual(model.AbortKind.resource_exhausted, classified.abort.?.kind);
    try std.testing.expectEqual(session.State.closed, exporter.session_state.state);
    // The projected op:abort frame itself is queued for the wire.
    var abort_frame = exporter.takeOutbound() orelse return error.TestNoAbortFrame;
    abort_frame.deinit();
    while (exporter.pollEvent()) |event_value| {
        var event = event_value;
        event.deinit();
    }
}
