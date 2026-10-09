//! The withdraw's settlement: it fulfills with the deposited capability, a
//! re-deposit replaces the first, the exact local target projects on the
//! receiving Port, and a queue failure preserves the gift while rolling the
//! fresh projection back.

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

test "withdraw fulfills with the deposited capability, and a re-deposit replaces the first" {
    const allocator = std.testing.allocator;

    // Real keys: the gifter signs the give, the recipient signs the receive.
    const gifter_secret = crypto.SecretKey.fromSeed(repeated(32, 0x71));
    const recipient_secret = crypto.SecretKey.fromSeed(repeated(32, 0x72));
    const gifter_pub = gifter_secret.publicKey();
    const recipient_pub = recipient_secret.publicKey();
    // The receive has to name the side the exporter derives from the give.
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

    var peer = engine.Peer.init(allocator);
    defer peer.deinit();
    var gifter = GifterSessionFixture{
        .side = gifter_side,
        .session_name = gifter_session,
        .key = gifter_pub.bytes,
        .gifts = peer.giftRegistry(),
    };

    // Deposit the capability the exporter will hand back, keyed under the
    // gifter's session pubkey, on the peer's own gift registry.
    const deposited = model.Reference{ .far = .{ .import_position = .from(9) } };
    try peer.giftRegistry().depositOwned(
        allocator,
        peer.session_state.limits,
        null,
        gift_id_a[0..],
        deposited,
    );

    // A second deposit of the same gift id replaces the first (the registry's
    // re-deposit contract): the withdraw below must yield this reference, not
    // the import-9 one.
    const redeposited = model.Reference{ .far = .{ .import_position = .from(10) } };
    try peer.giftRegistry().depositOwned(
        allocator,
        peer.session_state.limits,
        null,
        gift_id_a[0..],
        redeposited,
    );

    // Withdraw it. `resolveForWithdraw` moves the gifted cap out of the row via
    // `applyWithdraw`, so the resolution fulfills with the deposited reference.
    const handoff = model.Handoff{ .receive = receive };
    const view_handoff = model.view.Handoff.fromOwned(&handoff);
    var prepared = switch (try engine.bootstrap.resolveForWithdraw(allocator, &peer.session_state, peer.giftRegistry(), gifter.resolver(), null, null, .{
        .receive = view_handoff.receive,
        .answer = .fromWire(.from(5)),
    })) {
        .settled => |msg| msg,
        .awaiting_deposit => |admission| {
            var pending_receive = admission.receive;
            pending_receive.deinit(allocator);
            return error.TestUnexpectedPending;
        },
    };
    defer prepared.deinit(allocator);
    try std.testing.expectEqual(model.AnswerName.fromWire(.from(5)), prepared.answer);
    const fulfilled = switch (prepared.resolution.?) {
        .fulfill => |arg| arg,
        .@"break" => return error.TestUnexpectedBreak,
    };
    try std.testing.expectEqual(@as(u64, 10), fulfilled.reference.far.import_position.int());
    try std.testing.expect(peer.giftRegistry().giftLive(gift_id_a[0..]));
    prepared.apply(allocator, null, peer.giftRegistry());
    try std.testing.expect(!peer.giftRegistry().giftLive(gift_id_a[0..]));
}

test "withdraw of a verbatim gifted cap reclaims the moved reference through the settled helper" {
    const allocator = std.testing.allocator;

    const gifter_secret = crypto.SecretKey.fromSeed(repeated(32, 0x73));
    const recipient_secret = crypto.SecretKey.fromSeed(repeated(32, 0x74));
    const gifter_pub = gifter_secret.publicKey();
    const recipient_pub = recipient_secret.publicKey();
    // The receive has to name the side the exporter derives from the give.
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

    var peer = engine.Peer.init(allocator);
    defer peer.deinit();
    var gifter = GifterSessionFixture{
        .side = gifter_side,
        .session_name = gifter_session,
        .key = gifter_pub.bytes,
        .gifts = peer.giftRegistry(),
    };

    // A verbatim gifted cap (a broken reference) is cloned into the prepared
    // outbound message before the original gift row is committed and freed.
    // The testing allocator is the verdict on both owners.
    const gifted = model.Reference{ .broken = .{ .message = try allocator.dupe(u8, "gifted-was-broken") } };
    try peer.giftRegistry().depositOwned(allocator, peer.session_state.limits, null, gift_id_a[0..], gifted);

    const handoff = model.Handoff{ .receive = receive };
    const view_handoff = model.view.Handoff.fromOwned(&handoff);
    var prepared = switch (try engine.bootstrap.resolveForWithdraw(allocator, &peer.session_state, peer.giftRegistry(), gifter.resolver(), null, null, .{
        .receive = view_handoff.receive,
        .answer = .fromWire(.from(5)),
    })) {
        .settled => |msg| msg,
        .awaiting_deposit => |admission| {
            var pending_receive = admission.receive;
            pending_receive.deinit(allocator);
            return error.TestUnexpectedPending;
        },
    };
    defer prepared.deinit(allocator);
    const fulfilled = switch (prepared.resolution.?) {
        .fulfill => |arg| arg,
        .@"break" => return error.TestUnexpectedBreak,
    };
    try std.testing.expectEqualStrings("gifted-was-broken", fulfilled.reference.broken.message);
    prepared.apply(allocator, null, peer.giftRegistry());
    try std.testing.expect(!peer.giftRegistry().giftLive(gift_id_a[0..]));
}

const Projection = struct {
    position: model.ExportPosition,
    seen_scope: ?engine.PeerHandle = null,
    seen_target: ?u64 = null,
    fail: bool = false,

    fn resolveName(_: ?*anyopaque, _: engine.PeerHandle, _: engine.bootstrap.FetchContext) !engine.bootstrap.FetchOutcome {
        return .missing;
    }

    fn capture(_: ?*anyopaque, _: engine.PeerHandle, _: model.ExportPosition) ?u64 {
        return null;
    }

    fn project(ctx: ?*anyopaque, scope: engine.PeerHandle, target: u64) !engine.bootstrap.gifts.ProjectedLocalTarget {
        const self: *Projection = @ptrCast(@alignCast(ctx.?));
        self.seen_scope = scope;
        self.seen_target = target;
        if (self.fail) return error.ProjectionUnavailable;
        return .{ .export_position = self.position, .created = false };
    }

    fn releaseTarget(_: ?*anyopaque, _: u64) void {}

    fn rollback(_: ?*anyopaque, _: engine.PeerHandle, _: u64, _: engine.bootstrap.gifts.ProjectedLocalTarget) void {}
};

// The exporter half of a three-party handoff across two sessions: the gift row
// retains one opaque local target and asks the withdrawing Port to project it.
// No mutable bootstrap name participates after deposit.
test "a withdraw projects the exact deposited local target on the receiving Port" {
    const allocator = std.testing.allocator;

    const gifter_secret = crypto.SecretKey.fromSeed(repeated(32, 0x73));
    const recipient_secret = crypto.SecretKey.fromSeed(repeated(32, 0x74));
    const gifter_pub = gifter_secret.publicKey();
    const recipient_pub = recipient_secret.publicKey();
    // The receive has to name the side the exporter derives from the give.
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

    var exporter = engine.Peer.init(allocator);
    defer exporter.deinit();
    var gifter = GifterSessionFixture{
        .side = gifter_side,
        .session_name = gifter_session,
        .key = gifter_pub.bytes,
        .gifts = exporter.giftRegistry(),
    };

    _ = try exporter.session_state.allocateExport();
    const projected_here = try exporter.session_state.allocateExport();
    var projection = Projection{ .position = projected_here };
    const local_projection: engine.bootstrap.gifts.LocalObjectProjection = .{
        .ctx = &projection,
        .resolve_fetch = Projection.resolveName,
        .capture = Projection.capture,
        .project = Projection.project,
        .rollback = Projection.rollback,
        .release_target = Projection.releaseTarget,
    };

    const exact_target: u64 = 0xfeed;
    try exporter.giftRegistry().depositLocalTarget(
        allocator,
        exporter.session_state.limits,
        null,
        gift_id_a[0..],
        exact_target,
    );

    const handoff = model.Handoff{ .receive = receive };
    const view_handoff = model.view.Handoff.fromOwned(&handoff);
    const receiving_scope: engine.PeerHandle = .from(91);

    // Projection failure is recoverable: it breaks this withdrawal attempt but
    // consumes neither the gift nor its replay count, so the same signed
    // receive can retry when the target becomes projectable again.
    projection.fail = true;
    var refused = switch (try engine.bootstrap.resolveForWithdraw(allocator, &exporter.session_state, exporter.giftRegistry(), gifter.resolver(), local_projection, receiving_scope, .{
        .receive = view_handoff.receive,
        .answer = .fromWire(.from(7)),
    })) {
        .settled => |msg| msg,
        .awaiting_deposit => |admission| {
            var pending_receive = admission.receive;
            pending_receive.deinit(allocator);
            return error.TestUnexpectedPending;
        },
    };
    defer refused.deinit(allocator);
    try std.testing.expect(refused.resolution.? == .@"break");
    try std.testing.expectEqualStrings("gift target cannot be projected", refused.resolution.?.@"break".message);
    try std.testing.expect(exporter.giftRegistry().giftLive(gift_id_a[0..]));

    projection.fail = false;
    var prepared = switch (try engine.bootstrap.resolveForWithdraw(allocator, &exporter.session_state, exporter.giftRegistry(), gifter.resolver(), local_projection, receiving_scope, .{
        .receive = view_handoff.receive,
        .answer = .fromWire(.from(7)),
    })) {
        .settled => |msg| msg,
        .awaiting_deposit => |admission| {
            var pending_receive = admission.receive;
            pending_receive.deinit(allocator);
            return error.TestUnexpectedPending;
        },
    };
    defer prepared.deinit(allocator);
    const fulfilled = switch (prepared.resolution.?) {
        .fulfill => |arg| arg,
        .@"break" => return error.TestUnexpectedBreak,
    };
    try std.testing.expectEqual(projected_here, fulfilled.reference.near.export_position);
    try std.testing.expectEqual(receiving_scope, projection.seen_scope.?);
    try std.testing.expectEqual(exact_target, projection.seen_target.?);
    try std.testing.expect(exporter.giftRegistry().giftLive(gift_id_a[0..]));
    prepared.apply(allocator, local_projection, exporter.giftRegistry());
    try std.testing.expect(!exporter.giftRegistry().giftLive(gift_id_a[0..]));
}

test "withdraw queue failure preserves the gift and rolls back a fresh projection" {
    const allocator = std.testing.allocator;
    const gifter_secret = crypto.SecretKey.fromSeed(repeated(32, 0x75));
    const recipient_secret = crypto.SecretKey.fromSeed(repeated(32, 0x76));
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
    const handoff = model.Handoff{ .receive = receive };
    const view_handoff = model.view.Handoff.fromOwned(&handoff);

    const TrackingProjection = struct {
        position: model.ExportPosition,
        rollbacks: usize = 0,

        fn resolveName(_: ?*anyopaque, _: engine.PeerHandle, _: engine.bootstrap.FetchContext) !engine.bootstrap.FetchOutcome {
            return .missing;
        }
        fn capture(_: ?*anyopaque, _: engine.PeerHandle, _: model.ExportPosition) ?u64 {
            return null;
        }
        fn project(ctx: ?*anyopaque, _: engine.PeerHandle, _: u64) !engine.bootstrap.gifts.ProjectedLocalTarget {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            return .{ .export_position = self.position, .created = true };
        }
        fn rollback(ctx: ?*anyopaque, _: engine.PeerHandle, _: u64, projected: engine.bootstrap.gifts.ProjectedLocalTarget) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (projected.created) self.rollbacks += 1;
        }
        fn releaseTarget(_: ?*anyopaque, _: u64) void {}
    };

    var saw_send_oom = false;
    var fail_index: usize = 0;
    while (fail_index < 96 and !saw_send_oom) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        const fail_allocator = failing.allocator();
        var peer = engine.Peer.init(fail_allocator);
        defer peer.deinit();
        peer.session_state.installInboundAnswer(.from(7)) catch continue;
        const projected = peer.session_state.allocateExport() catch continue;
        var projection = TrackingProjection{ .position = projected };
        const seam: engine.bootstrap.gifts.LocalObjectProjection = .{
            .ctx = &projection,
            .resolve_fetch = TrackingProjection.resolveName,
            .capture = TrackingProjection.capture,
            .project = TrackingProjection.project,
            .rollback = TrackingProjection.rollback,
            .release_target = TrackingProjection.releaseTarget,
        };
        peer.giftRegistry().depositLocalTarget(
            fail_allocator,
            peer.session_state.limits,
            null,
            gift_id_a[0..],
            0xfeed,
        ) catch continue;
        var gifter = GifterSessionFixture{
            .side = gifter_side,
            .session_name = gifter_session,
            .key = gifter_pub.bytes,
            .gifts = peer.giftRegistry(),
        };
        const outcome = engine.bootstrap.resolveForWithdraw(
            fail_allocator,
            &peer.session_state,
            peer.giftRegistry(),
            gifter.resolver(),
            seam,
            .from(91),
            .{ .receive = view_handoff.receive, .answer = .fromWire(.from(7)) },
        ) catch continue;
        const prepared = switch (outcome) {
            .settled => |settled| settled,
            .awaiting_deposit => |admission| {
                var pending_receive = admission.receive;
                pending_receive.deinit(fail_allocator);
                return error.TestUnexpectedPending;
            },
        };
        peer.sendWithdrawSettled(prepared) catch |err| switch (err) {
            error.OutOfMemory => {
                saw_send_oom = true;
                try std.testing.expect(peer.giftRegistry().giftLive(gift_id_a[0..]));
                try std.testing.expectEqual(@as(usize, 1), projection.rollbacks);
                failing.fail_index = std.math.maxInt(usize);

                const retry = switch (try engine.bootstrap.resolveForWithdraw(
                    fail_allocator,
                    &peer.session_state,
                    peer.giftRegistry(),
                    gifter.resolver(),
                    seam,
                    .from(91),
                    .{ .receive = view_handoff.receive, .answer = .fromWire(.from(7)) },
                )) {
                    .settled => |settled| settled,
                    .awaiting_deposit => |admission| {
                        var pending_receive = admission.receive;
                        pending_receive.deinit(fail_allocator);
                        return error.TestUnexpectedPending;
                    },
                };
                try peer.sendWithdrawSettled(retry);
                try std.testing.expect(!peer.giftRegistry().giftLive(gift_id_a[0..]));
            },
            else => return err,
        };
    }
    try std.testing.expect(saw_send_oom);
}
