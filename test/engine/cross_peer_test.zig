const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const codec = pancake.ocapn.codec;
const engine = pancake.ocapn.engine;
const session = pancake.ocapn.session;
const crypto = pancake.foundation.crypto;
const syrup = pancake.ocapn.codec.syrup;
const cross_peer = @import("../support/cross_peer.zig");
const CountingAllocator = @import("../support/alloc_metrics.zig").CountingAllocator;
const peer_fixture = @import("../support/peer_fixture.zig");

fn repeated(comptime n: usize, byte: u8) [n]u8 {
    return [_]u8{byte} ** n;
}

const recipient_key = repeated(32, 0x42);
const gifter_session = repeated(32, 0xcc);
const gifter_side = repeated(32, 0x11);
const receiving_session = repeated(32, 0xdd);
/// The recipient's side name is not free bytes: the exporter derives it from the
/// give's recipient key and refuses a receive that names anything else, so the
/// fixture derives it the same way rather than picking a constant.
const receiving_side = blk: {
    @setEvalBranchQuota(100_000);
    break :blk engine.handoff_recipient.sideName(recipient_key[0..]) catch unreachable;
};
const give_signature = repeated(64, 0xaa);
const receive_signature = repeated(64, 0xbb);
const gift_id_a = repeated(32, 0x01);
const gift_id_b = repeated(32, 0x02);

/// The side name the exporter derives from a give's recipient key. A receive
/// must name exactly this, so a fixture holding its own recipient key derives it
/// the same way instead of inventing bytes.
fn sideOf(key: crypto.PeerKey) [32]u8 {
    return engine.handoff_recipient.sideName(key.asBytes()) catch unreachable;
}

const GifterSessionFixture = struct {
    peer_id: engine.PeerId = .from(0),
    side: [32]u8,
    session_name: [32]u8,
    key: [32]u8,
    gifts: *engine.bootstrap.GiftRegistry,
    resolve_calls: usize = 0,

    fn resolve(ctx: ?*anyopaque, side: [32]u8, session_name: []const u8) ?engine.bootstrap.GifterSession {
        const self: *GifterSessionFixture = @ptrCast(@alignCast(ctx.?));
        self.resolve_calls += 1;
        if (!std.mem.eql(u8, &self.side, &side)) return null;
        if (!std.mem.eql(u8, &self.session_name, session_name)) return null;
        return .{ .peer_id = self.peer_id, .key = self.key, .gifts = self.gifts };
    }

    fn resolver(self: *GifterSessionFixture) engine.bootstrap.GifterSessionResolver {
        return .{ .ctx = self, .resolve = resolve };
    }
};

fn giveWith(gift_id: []const u8) model.HandoffGive {
    return .{
        .recipient_key = recipient_key[0..],
        .exporter = .{ .transport = "memory", .designator = "exporter" },
        .gifter_exporter_session = gifter_session[0..],
        .gifter_side = gifter_side[0..],
        .gift_id = gift_id,
        .signature = give_signature[0..],
    };
}

fn receiveWith(gift_id: []const u8, count: u64, signature: []const u8) model.HandoffReceive {
    return .{
        .receiving_session = receiving_session[0..],
        .receiving_side = receiving_side[0..],
        .handoff_count = count,
        .signed_give = giveWith(gift_id),
        .signature = signature,
    };
}

const RejectingVerifier = struct {
    fn verify(_: ?*anyopaque, _: []const u8, _: []const u8) bool {
        return false;
    }

    fn make() cross_peer.SignatureVerifier {
        return .{ .context = null, .verify_fn = verify };
    }
};

/// A real Ed25519 verifier that routes each handoff certificate to the right key,
/// the production shape ADR-0009 describes. A `desc:handoff-receive` payload is
/// verified with the recipient key; any other (`desc:handoff-give`) with the
/// gifter's session key. It distinguishes them by the leading record label, since
/// a receive record carries its own label before the give it embeds.
const RoutingVerifier = struct {
    gifter_key: crypto.PeerKey,
    recipient_key: crypto.PeerKey,

    fn verify(ctx: ?*anyopaque, payload: []const u8, signature: []const u8) bool {
        const self: *RoutingVerifier = @ptrCast(@alignCast(ctx.?));
        const label_at = std.mem.indexOf(u8, payload, "desc:handoff-") orelse return false;
        const key = if (std.mem.startsWith(u8, payload[label_at..], "desc:handoff-receive"))
            self.recipient_key
        else
            self.gifter_key;
        if (signature.len != crypto.SIGNATURE_BYTES) return false;
        const sig = crypto.Signature.fromBytes(signature[0..crypto.SIGNATURE_BYTES].*);
        crypto.verify(key, payload, sig) catch return false;
        return true;
    }

    fn make(self: *RoutingVerifier) cross_peer.SignatureVerifier {
        return .{ .context = self, .verify_fn = verify };
    }
};

/// A give signed by `gifter_secret` over its canonical bytes, naming `recipient`
/// as its recipient. The returned give borrows the caller-owned key/signature
/// slices, so they must outlive it.
fn signedGive(
    gift_id: []const u8,
    recipient: []const u8,
    gifter_secret: *const crypto.SecretKey,
    out_signed: *[]u8,
    out_sig: *crypto.Signature,
    allocator: std.mem.Allocator,
) !model.HandoffGive {
    var give: model.HandoffGive = .{
        .recipient_key = recipient,
        .exporter = .{ .transport = "memory", .designator = "exporter" },
        .gifter_exporter_session = gifter_session[0..],
        .gifter_side = gifter_side[0..],
        .gift_id = gift_id,
        .signature = "",
    };
    out_signed.* = try syrup.canonicalHandoffGiveSignedBytes(allocator, give);
    out_sig.* = crypto.sign(gifter_secret, out_signed.*);
    give.signature = out_sig.asBytes();
    return give;
}

test "third-party handoff authorizes a withdrawal under real Ed25519 with keys routed per certificate" {
    const allocator = std.testing.allocator;

    // Real keys: the gifter signs the give, the recipient signs the receive.
    const gifter_secret = crypto.SecretKey.fromSeed(repeated(32, 0x51));
    const recipient_secret = crypto.SecretKey.fromSeed(repeated(32, 0x52));
    const gifter_pub = gifter_secret.publicKey();
    const recipient_pub = recipient_secret.publicKey();
    // The receive has to name the side the exporter derives from the give.
    const recipient_side = sideOf(recipient_pub);

    var give_signed: []u8 = undefined;
    var give_sig: crypto.Signature = undefined;
    const give = try signedGive(gift_id_a[0..], recipient_pub.asBytes(), &gifter_secret, &give_signed, &give_sig, allocator);
    defer allocator.free(give_signed);

    // The receive embeds the signed give and is signed by the recipient.
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

    var gifter = engine.Peer.init(allocator);
    defer gifter.deinit();
    var recipient_from_gifter = engine.Peer.init(allocator);
    defer recipient_from_gifter.deinit();
    var recipient_to_exporter = engine.Peer.init(allocator);
    defer recipient_to_exporter.deinit();
    var exporter = engine.Peer.init(allocator);
    defer exporter.deinit();

    // The exporter records the gifter's session key alongside the gift at deposit.
    try cross_peer.deliverGive(&gifter, &recipient_from_gifter, &exporter, give, gifter_pub.asBytes());
    {
        var event = recipient_from_gifter.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(engine.EventKind.handoff, event.kind());
    }

    // The exporter builds its verifier from the key it stored at deposit (the
    // gifter's) and the recipient key carried in the give, no key conjured at
    // verify time. Both certificates verify, so the withdrawal is authorized.
    var verifier_ctx: RoutingVerifier = .{
        .gifter_key = gifter_pub,
        .recipient_key = try crypto.PeerKey.fromSlice(give.recipient_key),
    };
    try cross_peer.withdrawGift(&recipient_to_exporter, &exporter, receive, verifier_ctx.make());
    try std.testing.expect(!exporter.giftRegistry().giftLive(gift_id_a[0..]));
}

test "immediate deposited withdraw verifies the borrowed receive without ownership materialization" {
    const allocator = std.testing.allocator;
    const gifter_secret = crypto.SecretKey.fromSeed(repeated(32, 0x53));
    const recipient_secret = crypto.SecretKey.fromSeed(repeated(32, 0x54));
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

    var counter = CountingAllocator{ .backing = allocator };
    const measured = counter.allocator();
    var exporter = engine.Peer.init(measured);
    defer exporter.deinit();
    try exporter.giftRegistry().depositOwned(
        measured,
        exporter.session_state.limits,
        gift_id_a[0..],
        .{ .far = .{ .import_position = .from(9) } },
    );
    var gifter = GifterSessionFixture{
        .side = gifter_side,
        .session_name = gifter_session,
        .key = gifter_pub.bytes,
        .gifts = exporter.giftRegistry(),
    };
    const handoff = model.Handoff{ .receive = receive };
    const view_handoff = model.view.Handoff.fromOwned(&handoff);

    counter.allocs = 0;
    var prepared = switch (try engine.bootstrap.resolveForWithdraw(
        measured,
        &exporter.session_state,
        exporter.giftRegistry(),
        gifter.resolver(),
        null,
        null,
        .{ .receive = view_handoff.receive, .answer = .from(1) },
    )) {
        .settled => |settled| settled,
        .awaiting_deposit => |admission| {
            var pending_receive = admission.receive;
            pending_receive.deinit(measured);
            return error.TestUnexpectedPending;
        },
    };
    defer prepared.deinit(measured);

    // The two canonical signing-domain byte products are the only allocations.
    // An owned HandoffReceive projection would allocate each nested slice and
    // fail this exact budget before gift preparation begins.
    try std.testing.expectEqual(@as(usize, 2), counter.allocs);
}

test "borrowed handoff signing domains equal owned domains through both codecs" {
    const allocator = std.testing.allocator;
    const gifter_secret = crypto.SecretKey.fromSeed(repeated(32, 0x55));
    const recipient_secret = crypto.SecretKey.fromSeed(repeated(32, 0x56));
    const recipient_pub = recipient_secret.publicKey();
    const recipient_side = sideOf(recipient_pub);

    var hint_entry = [_]model.HintEntry{.{
        .name = "direct-addresses",
        .value = .{ .string = "10.0.0.1:9049" },
    }};
    const hint_cases = [_]model.Hints{
        model.Hints.emptyMap(),
        model.Hints.emptyFalse(),
        .{ .entries = &hint_entry },
    };

    for (hint_cases) |hints| {
        var give: model.HandoffGive = .{
            .recipient_key = recipient_pub.asBytes(),
            .exporter = .{ .transport = "memory", .designator = "exporter", .hints = hints },
            .gifter_exporter_session = gifter_session[0..],
            .gifter_side = gifter_side[0..],
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

        for ([_]model.CodecId{ .syrup, .capnp }) |codec_id| {
            var frame = try codec.dispatch.encodeMessageForProfile(
                codec_id,
                allocator,
                .v1_0,
                .{ .handoff = .{ .receive = receive } },
            );
            defer frame.deinit();
            const decoded = try codec.dispatch.decodeBody(codec_id, frame.view());
            try std.testing.expect(decoded.handoff == .receive);

            const borrowed_give = try codec.signed.giveViewBytes(allocator, decoded.handoff.receive.signed_give);
            defer allocator.free(borrowed_give);
            try std.testing.expectEqualSlices(u8, give_signed, borrowed_give);

            const borrowed_receive = try codec.signed.receiveViewBytes(allocator, decoded.handoff.receive);
            defer allocator.free(borrowed_receive);
            try std.testing.expectEqualSlices(u8, receive_signed, borrowed_receive);
        }
    }
}

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
        gift_id_a[0..],
        redeposited,
    );

    // Withdraw it. `resolveForWithdraw` moves the gifted cap out of the row via
    // `applyWithdraw`, so the resolution fulfills with the deposited reference.
    const handoff = model.Handoff{ .receive = receive };
    const view_handoff = model.view.Handoff.fromOwned(&handoff);
    var prepared = switch (try engine.bootstrap.resolveForWithdraw(allocator, &peer.session_state, peer.giftRegistry(), gifter.resolver(), null, null, .{
        .receive = view_handoff.receive,
        .answer = .from(5),
    })) {
        .settled => |msg| msg,
        .awaiting_deposit => |admission| {
            var pending_receive = admission.receive;
            pending_receive.deinit(allocator);
            return error.TestUnexpectedPending;
        },
    };
    defer prepared.deinit(allocator);
    const resolution_msg = prepared.message.?;

    try std.testing.expectEqual(@as(u64, 5), resolution_msg.resolve.answer.int());
    const fulfilled = switch (resolution_msg.resolve.resolution) {
        .fulfill => |arg| arg,
        .@"break" => return error.TestUnexpectedBreak,
    };
    try std.testing.expectEqual(@as(u64, 10), fulfilled.reference.far.import_position.int());
    try std.testing.expect(peer.giftRegistry().giftLive(gift_id_a[0..]));
    prepared.apply(allocator, peer.giftRegistry());
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
    try peer.giftRegistry().depositOwned(allocator, peer.session_state.limits, gift_id_a[0..], gifted);

    const handoff = model.Handoff{ .receive = receive };
    const view_handoff = model.view.Handoff.fromOwned(&handoff);
    var prepared = switch (try engine.bootstrap.resolveForWithdraw(allocator, &peer.session_state, peer.giftRegistry(), gifter.resolver(), null, null, .{
        .receive = view_handoff.receive,
        .answer = .from(5),
    })) {
        .settled => |msg| msg,
        .awaiting_deposit => |admission| {
            var pending_receive = admission.receive;
            pending_receive.deinit(allocator);
            return error.TestUnexpectedPending;
        },
    };
    defer prepared.deinit(allocator);
    const resolution_msg = prepared.message.?;

    const fulfilled = switch (resolution_msg.resolve.resolution) {
        .fulfill => |arg| arg,
        .@"break" => return error.TestUnexpectedBreak,
    };
    try std.testing.expectEqualStrings("gifted-was-broken", fulfilled.reference.broken.message);
    prepared.apply(allocator, peer.giftRegistry());
    try std.testing.expect(!peer.giftRegistry().giftLive(gift_id_a[0..]));
}

const Projection = struct {
    position: model.ExportPosition,
    seen_scope: ?engine.PeerId = null,
    seen_target: ?u64 = null,
    fail: bool = false,

    fn resolveName(_: ?*anyopaque, _: engine.PeerId, _: []const u8) !?model.ExportPosition {
        return null;
    }

    fn capture(_: ?*anyopaque, _: engine.PeerId, _: model.ExportPosition) ?u64 {
        return null;
    }

    fn project(ctx: ?*anyopaque, scope: engine.PeerId, target: u64) !engine.bootstrap.ProjectedLocalTarget {
        const self: *Projection = @ptrCast(@alignCast(ctx.?));
        self.seen_scope = scope;
        self.seen_target = target;
        if (self.fail) return error.ProjectionUnavailable;
        return .{ .export_position = self.position, .created = false };
    }

    fn rollback(_: ?*anyopaque, _: engine.PeerId, _: u64, _: engine.bootstrap.ProjectedLocalTarget) void {}
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
    const local_projection: engine.bootstrap.LocalObjectProjection = .{
        .ctx = &projection,
        .resolve_name = Projection.resolveName,
        .capture = Projection.capture,
        .project = Projection.project,
        .rollback = Projection.rollback,
    };

    const exact_target: u64 = 0xfeed;
    try exporter.giftRegistry().depositLocalTarget(
        allocator,
        exporter.session_state.limits,
        gift_id_a[0..],
        exact_target,
    );

    const handoff = model.Handoff{ .receive = receive };
    const view_handoff = model.view.Handoff.fromOwned(&handoff);
    const receiving_scope: engine.PeerId = .from(91);

    // Projection failure is recoverable: it breaks this withdrawal attempt but
    // consumes neither the gift nor its replay count, so the same signed
    // receive can retry when the target becomes projectable again.
    projection.fail = true;
    var refused = switch (try engine.bootstrap.resolveForWithdraw(allocator, &exporter.session_state, exporter.giftRegistry(), gifter.resolver(), local_projection, receiving_scope, .{
        .receive = view_handoff.receive,
        .answer = .from(7),
    })) {
        .settled => |msg| msg,
        .awaiting_deposit => |admission| {
            var pending_receive = admission.receive;
            pending_receive.deinit(allocator);
            return error.TestUnexpectedPending;
        },
    };
    defer refused.deinit(allocator);
    const refused_msg = refused.message.?;
    try std.testing.expect(refused_msg.resolve.resolution == .@"break");
    try std.testing.expectEqualStrings("gift target cannot be projected", refused_msg.resolve.resolution.@"break".message);
    try std.testing.expect(exporter.giftRegistry().giftLive(gift_id_a[0..]));

    projection.fail = false;
    var prepared = switch (try engine.bootstrap.resolveForWithdraw(allocator, &exporter.session_state, exporter.giftRegistry(), gifter.resolver(), local_projection, receiving_scope, .{
        .receive = view_handoff.receive,
        .answer = .from(7),
    })) {
        .settled => |msg| msg,
        .awaiting_deposit => |admission| {
            var pending_receive = admission.receive;
            pending_receive.deinit(allocator);
            return error.TestUnexpectedPending;
        },
    };
    defer prepared.deinit(allocator);
    const resolution_msg = prepared.message.?;

    const fulfilled = switch (resolution_msg.resolve.resolution) {
        .fulfill => |arg| arg,
        .@"break" => return error.TestUnexpectedBreak,
    };
    try std.testing.expectEqual(projected_here, fulfilled.reference.near.export_position);
    try std.testing.expectEqual(receiving_scope, projection.seen_scope.?);
    try std.testing.expectEqual(exact_target, projection.seen_target.?);
    try std.testing.expect(exporter.giftRegistry().giftLive(gift_id_a[0..]));
    prepared.apply(allocator, exporter.giftRegistry());
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

        fn resolveName(_: ?*anyopaque, _: engine.PeerId, _: []const u8) !?model.ExportPosition {
            return null;
        }
        fn capture(_: ?*anyopaque, _: engine.PeerId, _: model.ExportPosition) ?u64 {
            return null;
        }
        fn project(ctx: ?*anyopaque, _: engine.PeerId, _: u64) !engine.bootstrap.ProjectedLocalTarget {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            return .{ .export_position = self.position, .created = true };
        }
        fn rollback(ctx: ?*anyopaque, _: engine.PeerId, _: u64, projected: engine.bootstrap.ProjectedLocalTarget) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (projected.created) self.rollbacks += 1;
        }
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
        const seam: engine.bootstrap.LocalObjectProjection = .{
            .ctx = &projection,
            .resolve_name = TrackingProjection.resolveName,
            .capture = TrackingProjection.capture,
            .project = TrackingProjection.project,
            .rollback = TrackingProjection.rollback,
        };
        peer.giftRegistry().depositLocalTarget(
            fail_allocator,
            peer.session_state.limits,
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
            .{ .receive = view_handoff.receive, .answer = .from(7) },
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
                    .{ .receive = view_handoff.receive, .answer = .from(7) },
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

test "a withdraw that arrives before its deposit parks and settles once the gift lands" {
    const allocator = std.testing.allocator;

    const gifter_secret = crypto.SecretKey.fromSeed(repeated(32, 0x61));
    const recipient_secret = crypto.SecretKey.fromSeed(repeated(32, 0x62));
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

    // next carries a wire `op:resolve`, so the settled answer is observable
    // as one outbound frame without the V1.0 resolver-callback choreography.
    var exporter = peer_fixture.openPeer(allocator);
    defer exporter.deinit();
    var resolver_fixture: GifterSessionFixture = .{
        .side = gifter_side,
        .session_name = gifter_session,
        .key = gifter_pub.bytes,
        .gifts = exporter.giftRegistry(),
    };
    var node = engine.Node.init(allocator, repeated(32, 0x63));
    defer node.deinit();
    node.setGifterSessionResolver(resolver_fixture.resolver());
    _ = try node.registerPeerOver(&exporter);
    try exporter.session_state.transitionToOpen();

    // The withdraw arrives on the wire before any deposit: `deposit-gift` and
    // `withdraw-gift` travel on different sessions, so this order is legal.
    var handoff_arg = model.Handoff{ .receive = receive };
    // Verification materializes exactly the receive that can outlive this
    // frame. The caller either admits that owned value to its bounded pending
    // table or frees it without retaining attacker input.
    const handoff_view = model.view.Handoff.fromOwned(&handoff_arg);
    switch (try engine.bootstrap.resolveForWithdraw(
        allocator,
        &exporter.session_state,
        exporter.giftRegistry(),
        exporter.gifterSessionResolver(),
        null,
        null,
        .{ .receive = handoff_view.receive, .answer = .from(1) },
    )) {
        .awaiting_deposit => |admission| {
            var pending_receive = admission.receive;
            pending_receive.deinit(allocator);
        },
        .settled => return error.TestUnexpectedSettlement,
    }
    const frame = try syrup.encodeMessage(allocator, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(0) },
        .args = &.{ .{ .symbol = "withdraw-gift" }, .{ .handoff = &handoff_arg } },
        .answer = .from(1),
    } });
    try exporter.feedOwned(frame);
    while ((try exporter.step()) != .idle) {}
    while (exporter.pollEvent()) |event_value| {
        var event = event_value;
        event.deinit();
    }

    // Not refused, parked: no answer left the peer and the entry is held. The
    // gift is not in the registry yet; the deposit lands below. The parked row
    // owns the verified receive and its accepted replay count, not a gift.
    try std.testing.expect(exporter.takeOutbound() == null);
    try std.testing.expectEqual(@as(usize, 1), exporter.pendingWithdrawCount());
    try std.testing.expect(!exporter.giftRegistry().giftLive(gift_id_a[0..]));

    // A second valid certificate can arrive before the same gift. Its newer
    // count advances replay authority immediately while both verified waits
    // remain parked. Settling the older wait below must never move that
    // monotonic counter backward.
    var later_receive = receive;
    later_receive.handoff_count = 2;
    later_receive.signature = "";
    const later_signed = try syrup.canonicalHandoffReceiveSignedBytes(allocator, later_receive);
    defer allocator.free(later_signed);
    const later_sig = crypto.sign(&recipient_secret, later_signed);
    later_receive.signature = later_sig.asBytes();
    var later_handoff = model.Handoff{ .receive = later_receive };
    const later_frame = try syrup.encodeMessage(allocator, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(0) },
        .args = &.{ .{ .symbol = "withdraw-gift" }, .{ .handoff = &later_handoff } },
        .answer = .from(2),
    } });
    try exporter.feedOwned(later_frame);
    while ((try exporter.step()) != .idle) {}
    while (exporter.pollEvent()) |event_value| {
        var event = event_value;
        event.deinit();
    }
    try std.testing.expect(exporter.takeOutbound() == null);
    try std.testing.expectEqual(@as(usize, 2), exporter.pendingWithdrawCount());

    // The deposit lands on the vat's registry (in production, via the gifter's
    // session to this same vat). The settlement below sends this reference on
    // *this* session, so the fixture holds the import it names: a fulfill may
    // only name a far this session holds, and the withdraw responder is not
    // exempt from that.
    try exporter.session_state.registerImport(.from(9));
    const deposited = model.Reference{ .far = .{ .import_position = .from(9) } };
    try exporter.giftRegistry().depositOwned(
        allocator,
        exporter.session_state.limits,
        gift_id_a[0..],
        deposited,
    );
    // This fixture writes the registry directly and drives the Peer without a
    // Host, so explicitly provide the exact wake a production Host forwards
    // from the Node after an inbound bootstrap deposit commits.
    exporter.noteHandoffChange(engine.node_services.HandoffDependency.init(
        exporter.node_services.?.peer_id,
        gift_id_a[0..],
    ));

    // The next steps settle the parked withdraw: signature-verified, applied,
    // and answered with the deposited capability.
    while ((try exporter.step()) != .idle) {}
    var settled = exporter.takeOutbound() orelse return error.TestNoSettlement;
    defer settled.deinit();
    // One deposit satisfies one wait. The newer accepted wait remains parked
    // for a later re-deposit of the same gifter/id pair.
    try std.testing.expectEqual(@as(usize, 1), exporter.pendingWithdrawCount());
    try std.testing.expect(!exporter.giftRegistry().giftLive(gift_id_a[0..]));

    // The older wait settled after count 2 had already been accepted. Reusing
    // count 2 is still a replay; a plain assignment in commitWithdraw used to
    // roll the counter back to 1 and admit this certificate again.
    const later_view = model.view.Handoff.fromOwned(&later_handoff);
    var replay = switch (try engine.bootstrap.resolveForWithdraw(
        allocator,
        &exporter.session_state,
        exporter.giftRegistry(),
        exporter.gifterSessionResolver(),
        null,
        null,
        .{ .receive = later_view.receive, .answer = .from(3) },
    )) {
        .settled => |prepared| prepared,
        .awaiting_deposit => |admission| {
            var pending_receive = admission.receive;
            pending_receive.deinit(allocator);
            return error.TestReplayWasParked;
        },
    };
    defer replay.deinit(allocator);
    try std.testing.expect(replay.message.?.resolve.resolution == .@"break");
}

test "one exact gift wake does not scan unrelated pending withdrawals" {
    const allocator = std.testing.allocator;
    var exporter = peer_fixture.openPeer(allocator);
    defer exporter.deinit();
    var resolver_fixture: GifterSessionFixture = .{
        .side = gifter_side,
        .session_name = gifter_session,
        .key = recipient_key,
        .gifts = exporter.giftRegistry(),
    };
    var node = engine.Node.init(allocator, repeated(32, 0x65));
    defer node.deinit();
    node.setGifterSessionResolver(resolver_fixture.resolver());
    const receiver_id = try node.registerPeerOver(&exporter);
    resolver_fixture.peer_id = receiver_id;

    const pending_count = 256;
    var gift_ids: [pending_count][32]u8 = undefined;
    for (&gift_ids, 0..) |*gift_id, i| {
        gift_id.* = [_]u8{0} ** 32;
        std.mem.writeInt(u64, gift_id[0..8], i, .little);
        var pending: engine.bootstrap.PendingReceive = .{
            .handoff_count = @intCast(i + 1),
            .recipient_key = recipient_key,
            .gifter_exporter_session = gifter_session,
            .gifter_side = gifter_side,
            .gift_id = try allocator.dupe(u8, gift_id),
        };
        exporter.parkPendingWithdraw(pending, .from(@intCast(i + 1)), receiver_id) catch |err| {
            pending.deinit(allocator);
            return err;
        };
    }
    try std.testing.expectEqual(@as(usize, pending_count), exporter.pendingWithdrawCount());

    const target = pending_count / 2;
    try exporter.session_state.installInboundAnswer(.from(target + 1));
    try exporter.session_state.registerImport(.from(9));
    try exporter.giftRegistry().depositOwned(
        allocator,
        exporter.session_state.limits,
        &gift_ids[target],
        .{ .far = model.FarRef.object(9) },
    );
    const calls_before = resolver_fixture.resolve_calls;
    exporter.noteHandoffChange(engine.node_services.HandoffDependency.init(receiver_id, &gift_ids[target]));
    try std.testing.expectEqual(engine.StepOutcome.progress, try exporter.step());

    // The resolver is the observable probe at the head of every row retry.
    // Exact grouping calls it once for the matching row, not 256 times.
    try std.testing.expectEqual(calls_before + 1, resolver_fixture.resolve_calls);
    try std.testing.expectEqual(@as(usize, pending_count - 1), exporter.pendingWithdrawCount());
    var settlement = exporter.takeOutbound() orelse return error.MissingExactSettlement;
    settlement.deinit();
}

test "parked withdrawal gift ids share the session frame-byte cap" {
    const allocator = std.testing.allocator;
    var limits: engine.SessionLimits = .{};
    limits.max_frame_bytes = 64;
    var peer = engine.Peer.initNegotiatingWith(allocator, .{ .limits = limits });
    defer peer.deinit();

    const first: engine.bootstrap.PendingReceive = .{
        .handoff_count = 1,
        .recipient_key = recipient_key,
        .gifter_exporter_session = gifter_session,
        .gifter_side = gifter_side,
        .gift_id = try allocator.dupe(u8, &([_]u8{0x41} ** 40)),
    };
    try peer.parkPendingWithdraw(first, .from(1), .from(7));

    var second: engine.bootstrap.PendingReceive = .{
        .handoff_count = 2,
        .recipient_key = recipient_key,
        .gifter_exporter_session = gifter_session,
        .gifter_side = gifter_side,
        .gift_id = try allocator.dupe(u8, &([_]u8{0x42} ** 40)),
    };
    try std.testing.expectError(session.Error.PendingWithdrawCapExceeded, peer.parkPendingWithdraw(second, .from(2), .from(7)));
    second.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), peer.pendingWithdrawCount());
}

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
    _ = try node.registerPeerOver(&exporter);

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
        .{ .receive = invalid_view.receive, .answer = .from(1) },
    )) {
        .settled => |settled| settled,
        .awaiting_deposit => |admission| {
            var pending_receive = admission.receive;
            pending_receive.deinit(allocator);
            return error.TestUnexpectedPending;
        },
    };
    defer invalid.deinit(allocator);
    try std.testing.expect(invalid.message.?.resolve.resolution == .@"break");

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
        .{ .receive = valid_view.receive, .answer = .from(2) },
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
        .{ .receive = valid_view.receive, .answer = .from(3) },
    )) {
        .settled => |settled| settled,
        .awaiting_deposit => |second| {
            var pending_receive = second.receive;
            pending_receive.deinit(allocator);
            return error.TestUnexpectedPending;
        },
    };
    defer replay.deinit(allocator);
    try std.testing.expect(replay.message.?.resolve.resolution == .@"break");
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
            resolver_fixture.peer_id = exporter_id;

            var handoff_arg = model.Handoff{ .receive = receive_value };
            const frame = try syrup.encodeMessage(std.testing.allocator, .{ .deliver = .{
                .target = .{ .far = model.FarRef.object(0) },
                .args = &.{ .{ .symbol = "withdraw-gift" }, .{ .handoff = &handoff_arg } },
                .answer = .from(1),
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

    // The park table is attacker-fed (a partner can flood `withdraw-gift`s whose
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
    _ = try node.registerPeerOver(&exporter);
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
        const frame = try syrup.encodeMessage(allocator, .{ .deliver = .{
            .target = .{ .far = model.FarRef.object(0) },
            .args = &.{ .{ .symbol = "withdraw-gift" }, .{ .handoff = &handoff_arg } },
            .answer = .from(@intCast(i + 1)),
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

test "third-party handoff rejects a give signed by a key other than the recorded gifter" {
    const allocator = std.testing.allocator;

    const gifter_secret = crypto.SecretKey.fromSeed(repeated(32, 0x51));
    const forger_secret = crypto.SecretKey.fromSeed(repeated(32, 0x99));
    const recipient_secret = crypto.SecretKey.fromSeed(repeated(32, 0x52));
    const gifter_pub = gifter_secret.publicKey();
    const recipient_pub = recipient_secret.publicKey();
    // The receive has to name the side the exporter derives from the give.
    const recipient_side = sideOf(recipient_pub);

    // The give is signed by the forger, not the gifter the exporter records.
    var give_signed: []u8 = undefined;
    var give_sig: crypto.Signature = undefined;
    const give = try signedGive(gift_id_a[0..], recipient_pub.asBytes(), &forger_secret, &give_signed, &give_sig, allocator);
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

    var gifter = engine.Peer.init(allocator);
    defer gifter.deinit();
    var recipient_from_gifter = engine.Peer.init(allocator);
    defer recipient_from_gifter.deinit();
    var recipient_to_exporter = engine.Peer.init(allocator);
    defer recipient_to_exporter.deinit();
    var exporter = engine.Peer.init(allocator);
    defer exporter.deinit();

    // The exporter records the *legitimate* gifter's key at deposit.
    try cross_peer.deliverGive(&gifter, &recipient_from_gifter, &exporter, give, gifter_pub.asBytes());
    {
        var event = recipient_from_gifter.pollEvent().?;
        defer event.deinit();
    }

    var verifier_ctx: RoutingVerifier = .{
        .gifter_key = gifter_pub,
        .recipient_key = try crypto.PeerKey.fromSlice(give.recipient_key),
    };
    // The give signature was made by the forger, so it fails against the recorded
    // gifter key and the withdrawal is refused.
    try std.testing.expectError(
        cross_peer.Error.SignatureRejected,
        cross_peer.withdrawGift(&recipient_to_exporter, &exporter, receive, verifier_ctx.make()),
    );
    try std.testing.expect(exporter.giftRegistry().giftLive(gift_id_a[0..]));
}

test "third-party handoff routes a give and authorizes a withdrawal across peers" {
    const allocator = std.testing.allocator;
    var gifter = engine.Peer.init(allocator);
    defer gifter.deinit();
    var recipient_from_gifter = engine.Peer.init(allocator);
    defer recipient_from_gifter.deinit();
    var recipient_to_exporter = engine.Peer.init(allocator);
    defer recipient_to_exporter.deinit();
    var exporter = engine.Peer.init(allocator);
    defer exporter.deinit();

    try cross_peer.deliverGive(&gifter, &recipient_from_gifter, &exporter, giveWith(gift_id_a[0..]), null);

    {
        var event = recipient_from_gifter.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(engine.EventKind.handoff, event.kind());
    }
    try std.testing.expect(exporter.giftRegistry().giftLive(gift_id_a[0..]));
    try std.testing.expect(exporter.giftRegistry().giftLive(gift_id_a[0..]));

    try cross_peer.withdrawGift(
        &recipient_to_exporter,
        &exporter,
        receiveWith(gift_id_a[0..], 1, receive_signature[0..]),
        cross_peer.testOnlyAcceptingVerifier(),
    );

    {
        var event = exporter.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(engine.EventKind.handoff, event.kind());
    }
    try std.testing.expect(!exporter.giftRegistry().giftLive(gift_id_a[0..]));
}

test "third-party handoff rejects a replayed handoff count across peers" {
    const allocator = std.testing.allocator;
    var gifter = engine.Peer.init(allocator);
    defer gifter.deinit();
    var recipient_from_gifter = engine.Peer.init(allocator);
    defer recipient_from_gifter.deinit();
    var recipient_to_exporter = engine.Peer.init(allocator);
    defer recipient_to_exporter.deinit();
    var exporter = engine.Peer.init(allocator);
    defer exporter.deinit();

    try cross_peer.deliverGive(&gifter, &recipient_from_gifter, &exporter, giveWith(gift_id_a[0..]), null);
    try cross_peer.deliverGive(&gifter, &recipient_from_gifter, &exporter, giveWith(gift_id_b[0..]), null);

    try cross_peer.withdrawGift(
        &recipient_to_exporter,
        &exporter,
        receiveWith(gift_id_a[0..], 2, receive_signature[0..]),
        cross_peer.testOnlyAcceptingVerifier(),
    );

    try std.testing.expectError(session.Error.HandoffReplay, cross_peer.withdrawGift(
        &recipient_to_exporter,
        &exporter,
        receiveWith(gift_id_b[0..], 1, receive_signature[0..]),
        cross_peer.testOnlyAcceptingVerifier(),
    ));
    try std.testing.expect(exporter.giftRegistry().giftLive(gift_id_b[0..]));
}

test "third-party handoff rejects a withdrawal whose signature fails verification" {
    const allocator = std.testing.allocator;
    var gifter = engine.Peer.init(allocator);
    defer gifter.deinit();
    var recipient_from_gifter = engine.Peer.init(allocator);
    defer recipient_from_gifter.deinit();
    var recipient_to_exporter = engine.Peer.init(allocator);
    defer recipient_to_exporter.deinit();
    var exporter = engine.Peer.init(allocator);
    defer exporter.deinit();

    try cross_peer.deliverGive(&gifter, &recipient_from_gifter, &exporter, giveWith(gift_id_a[0..]), null);

    try std.testing.expectError(cross_peer.Error.SignatureRejected, cross_peer.withdrawGift(
        &recipient_to_exporter,
        &exporter,
        receiveWith(gift_id_a[0..], 1, receive_signature[0..]),
        RejectingVerifier.make(),
    ));
    try std.testing.expect(exporter.giftRegistry().giftLive(gift_id_a[0..]));
}

test "the exporter authorizes a withdrawal against the gifter key it learned from the handshake" {
    const allocator = std.testing.allocator;
    const pairing = engine.pairing;

    const gifter_seed = repeated(32, 0x51);
    const exporter_seed = repeated(32, 0x53);
    const gifter_secret = crypto.SecretKey.fromSeed(gifter_seed);
    const recipient_secret = crypto.SecretKey.fromSeed(repeated(32, 0x52));
    const gifter_pub = gifter_secret.publicKey();
    const recipient_pub = recipient_secret.publicKey();

    // A real keyed handshake for the gifter-to-exporter session, so the exporter
    // learns the gifter's session key from `op:start-session` — not from an
    // argument. gx.p1 is the gifter; gx.p2 is the exporter.
    var gx = try pairing.pairedWithKeys(allocator, gifter_seed, exporter_seed);
    defer gx.deinit();

    // A receive names the session it travels over, and this one is validated
    // against `gx.p2`'s session, whose other end is the gifter. The exporter
    // derives both names from that session's two keys and holds the receive to
    // them, so the fixture names the same pair. What the recipient key still
    // decides is the signature: the receive below is signed with it, and the
    // exporter verifies against the key the give carries.
    const withdrawing_side = sideOf(gifter_pub);
    const exporter_side = sideOf(crypto.SecretKey.fromSeed(exporter_seed).publicKey());
    const receiving_session_name = engine.handoff_recipient.sessionName(withdrawing_side, exporter_side);

    var give_signed: []u8 = undefined;
    var give_sig: crypto.Signature = undefined;
    const give = try signedGive(gift_id_a[0..], recipient_pub.asBytes(), &gifter_secret, &give_signed, &give_sig, allocator);
    defer allocator.free(give_signed);

    var receive: model.HandoffReceive = .{
        .receiving_session = &receiving_session_name,
        .receiving_side = &withdrawing_side,
        .handoff_count = 1,
        .signed_give = give,
        .signature = "",
    };
    const receive_signed = try syrup.canonicalHandoffReceiveSignedBytes(allocator, receive);
    defer allocator.free(receive_signed);
    const receive_sig = crypto.sign(&recipient_secret, receive_signed);
    receive.signature = receive_sig.asBytes();

    var recipient_from_gifter = engine.Peer.init(allocator);
    defer recipient_from_gifter.deinit();
    var recipient_to_exporter = engine.Peer.init(allocator);
    defer recipient_to_exporter.deinit();

    // Deposit with no explicit gifter key: deliverGive falls back to the key the
    // exporter learned from the handshake.
    try cross_peer.deliverGive(&gx.p1, &recipient_from_gifter, &gx.p2, give, null);
    {
        var event = recipient_from_gifter.pollEvent().?;
        defer event.deinit();
    }

    var verifier_ctx: RoutingVerifier = .{
        .gifter_key = gifter_pub,
        .recipient_key = try crypto.PeerKey.fromSlice(give.recipient_key),
    };
    try cross_peer.withdrawGift(&recipient_to_exporter, &gx.p2, receive, verifier_ctx.make());
    try std.testing.expect(!gx.p2.giftRegistry().giftLive(gift_id_a[0..]));
}

test "canonical handoff-give bytes are a stable Ed25519 signing domain an embedder can verify" {
    const allocator = std.testing.allocator;

    // The exact bytes the gifter's `desc:sig-envelope` signature covers. Before
    // this encoder existed, an embedder had no way to reconstruct them, so a
    // handoff signature could not be verified the way an op:start-session
    // location signature can. This proves the domain round-trips under real
    // Ed25519 and that it binds the whole record, not one field.
    const give = giveWith(gift_id_a[0..]);
    const signed = try syrup.canonicalHandoffGiveSignedBytes(allocator, give);
    defer allocator.free(signed);

    const secret = crypto.SecretKey.fromSeed(repeated(32, 0x07));
    const sig = crypto.sign(&secret, signed);
    try crypto.verify(secret.publicKey(), signed, sig);

    // Change one field: the canonical bytes differ, so the prior signature no
    // longer verifies. A signature lifted from another envelope cannot pass.
    const tampered = giveWith(gift_id_b[0..]);
    const tampered_bytes = try syrup.canonicalHandoffGiveSignedBytes(allocator, tampered);
    defer allocator.free(tampered_bytes);
    try std.testing.expect(!std.mem.eql(u8, signed, tampered_bytes));
    try std.testing.expectError(
        crypto.CryptoError.InvalidSignature,
        crypto.verify(secret.publicKey(), tampered_bytes, sig),
    );

    // The receive certificate has its own canonical domain, distinct from the
    // give it embeds, so the two signatures never share a payload.
    const receive = receiveWith(gift_id_a[0..], 1, receive_signature[0..]);
    const receive_signed = try syrup.canonicalHandoffReceiveSignedBytes(allocator, receive);
    defer allocator.free(receive_signed);
    try std.testing.expect(!std.mem.eql(u8, signed, receive_signed));
}

test "a signed handoff give re-encodes across codecs and its gifter signature still verifies (ADR-0009/ADR-0003)" {
    const allocator = std.testing.allocator;
    const dispatch = pancake.ocapn.codec.dispatch;

    // A give signed once, over its Syrup-canonical bytes, the gifter's actual
    // signing domain. `give_sig` must outlive every borrow of `give.signature`.
    const gifter_secret = crypto.SecretKey.fromSeed(repeated(32, 0x07));
    var give_signed: []u8 = undefined;
    var give_sig: crypto.Signature = undefined;
    const give = try signedGive(
        gift_id_a[0..],
        recipient_key[0..],
        &gifter_secret,
        &give_signed,
        &give_sig,
        allocator,
    );
    defer allocator.free(give_signed);
    try crypto.verify(gifter_secret.publicKey(), give_signed, give_sig);

    const profile = model.CaptpVersion.v1_0;
    const message = model.Message{ .handoff = .{ .give = give } };

    // The cross-codec re-encode contract (ADR-0003 / ADR-0009): the signature
    // covers the *decoded* record's Syrup canonicalization, not the carrying
    // codec's bytes. So for every ordered pair of distinct codecs — encode in
    // the source, decode to a typed record, re-encode into the target codec,
    // decode again — re-deriving the signing domain reproduces the exact bytes
    // the gifter signed, and the carried signature still verifies over them.
    const codecs = [_]model.CodecId{ .syrup, .capnp };
    for (codecs) |source| {
        for (codecs) |target| {
            if (source == target) continue;

            var src_frame = try dispatch.encodeMessageForProfile(source, allocator, profile, message);
            defer src_frame.deinit();
            const src_body = try dispatch.decodeBody(source, src_frame.view());
            const src_owned = try src_body.toOwned(allocator);
            defer model.freeMessage(allocator, src_owned);

            // Re-encode the decoded handoff into the OTHER codec: its typed
            // fields and verbatim signature bytes ride along, so the signature
            // still verifies on the far side (ADR-0009 / ADR-0003). Production
            // re-encode rides the ordinary `Peer.send` → codec encode path; this
            // spells the same move out to prove the cross-codec property.
            var tgt_frame = try dispatch.encodeMessageForProfile(
                target,
                allocator,
                profile,
                .{ .handoff = src_owned.handoff },
            );
            defer tgt_frame.deinit();
            const tgt_body = try dispatch.decodeBody(target, tgt_frame.view());
            const tgt_owned = try tgt_body.toOwned(allocator);
            defer model.freeMessage(allocator, tgt_owned);

            const recanonical = try syrup.canonicalHandoffGiveSignedBytes(allocator, tgt_owned.handoff.give);
            defer allocator.free(recanonical);
            try std.testing.expectEqualSlices(u8, give_signed, recanonical);

            const carried = crypto.Signature.fromBytes(
                tgt_owned.handoff.give.signature[0..crypto.SIGNATURE_BYTES].*,
            );
            try crypto.verify(gifter_secret.publicKey(), recanonical, carried);
        }
    }
}

test "a binding-originated give carries typed fields over a Cap'n Proto session, not just Syrup's raw_signed" {
    const allocator = std.testing.allocator;
    var pair = try engine.pairing.pairedWithCodec(allocator, .capnp);
    defer pair.deinit();

    // The exact shape a binding hands `Peer.sendResolveHandoffGive`:
    // `handoff_gifter.buildSignedGive` (what `pancake_build_handoff_give`
    // calls) returns a Syrup-encoded `<desc:sig-envelope …>`. Before this, the
    // send path only ever set that envelope as `raw_signed` and left the typed
    // fields empty, so a Cap'n Proto session (which does not understand
    // `raw_signed`) shipped an empty give.
    const gifter_secret = crypto.SecretKey.fromSeed(repeated(32, 0x51));
    const recipient_pub_key = repeated(32, 0x52);
    try expectCapnpGiveRoundTrip(allocator, &pair, gifter_secret, recipient_pub_key[0..], .{
        .transport = "tcp",
        .designator = "127.0.0.1:9200",
        .hints = model.Hints.emptyMap(),
    });
}

test "a Cap'n Proto session round-trips a handoff give with #f exporter hints" {
    const allocator = std.testing.allocator;
    var pair = try engine.pairing.pairedWithCodec(allocator, .capnp);
    defer pair.deinit();
    const gifter_secret = crypto.SecretKey.fromSeed(repeated(32, 0x61));
    const recipient_pub_key = repeated(32, 0x62);
    try expectCapnpGiveRoundTrip(allocator, &pair, gifter_secret, recipient_pub_key[0..], .{
        .transport = "tcp",
        .designator = "127.0.0.1:9201",
        .hints = model.Hints.emptyFalse(),
    });
}

test "a Cap'n Proto session round-trips a handoff give with direct-addresses hints" {
    const allocator = std.testing.allocator;
    var pair = try engine.pairing.pairedWithCodec(allocator, .capnp);
    defer pair.deinit();
    const gifter_secret = crypto.SecretKey.fromSeed(repeated(32, 0x71));
    const recipient_pub_key = repeated(32, 0x72);
    var entry_buf: [1]model.HintEntry = undefined;
    const hints = model.Hints.forDirectAddresses("127.0.0.1:9202", &entry_buf);
    try expectCapnpGiveRoundTrip(allocator, &pair, gifter_secret, recipient_pub_key[0..], .{
        .transport = "keyed-tcp",
        .designator = "aa" ** 32,
        .hints = hints,
    });
}

fn expectCapnpGiveRoundTrip(
    allocator: std.mem.Allocator,
    pair: *engine.pairing.Pair,
    gifter_secret: crypto.SecretKey,
    recipient_pub_key: []const u8,
    peer: model.PeerLocator,
) !void {
    const exporter_location = try engine.encodePeerLocatorRecord(allocator, peer);
    defer allocator.free(exporter_location);
    const give_bytes = try engine.handoff_gifter.buildSignedGive(
        allocator,
        gifter_secret,
        recipient_pub_key,
        exporter_location,
        gifter_session[0..],
        gifter_side[0..],
        gift_id_a[0..],
    );
    defer allocator.free(give_bytes);

    try pair.p1.exportObject(9);
    try pair.p2.importObject(9);
    try pair.p2.sendCopying(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(9) },
        .args = &.{},
        .answer = model.AnswerPosition.from(5),
    } });
    try cross_peer.pumpOne(&pair.p2, &pair.p1);
    {
        var ask = pair.p1.pollEvent() orelse return error.ExpectedDeliverEvent;
        defer ask.deinit();
    }

    try pair.p1.sendResolveHandoffGive(model.AnswerPosition.from(5), give_bytes);
    try cross_peer.pumpOne(&pair.p1, &pair.p2);

    var event = pair.p2.pollEvent() orelse return error.ExpectedResolveEvent;
    defer event.deinit();
    const view = try event.view();
    const arg = switch (view.resolve.resolution) {
        .fulfill => |a| a,
        .@"break" => return error.ExpectedFulfill,
    };
    const give_view = switch (arg) {
        .handoff => |h| switch (h) {
            .give => |g| g,
            .receive => return error.ExpectedGive,
        },
        else => return error.ExpectedHandoffArgument,
    };

    const owned_give = try give_view.toOwned(allocator);
    defer model.freeHandoffGive(allocator, owned_give);
    try std.testing.expectEqualSlices(u8, recipient_pub_key, owned_give.recipient_key);
    try std.testing.expectEqualStrings(peer.transport, owned_give.exporter.transport);
    try std.testing.expectEqualStrings(peer.designator, owned_give.exporter.designator);
    try std.testing.expectEqual(peer.hints.wire_form, owned_give.exporter.hints.wire_form);
    try std.testing.expectEqual(peer.hints.entries.len, owned_give.exporter.hints.entries.len);

    const uri = try engine.handoff_recipient.exporterLocatorUri(allocator, give_view.exporter);
    defer allocator.free(uri);
    try std.testing.expect(std.mem.startsWith(u8, uri, "ocapn://"));

    const recanonical = try syrup.canonicalHandoffGiveSignedBytes(allocator, owned_give);
    defer allocator.free(recanonical);
    const carried = crypto.Signature.fromBytes(owned_give.signature[0..crypto.SIGNATURE_BYTES].*);
    try crypto.verify(gifter_secret.publicKey(), recanonical, carried);
}

test "handoff side-name helper enforces the 32-byte Ed25519 key contract" {
    const handoff = engine.handoff_recipient;

    // A 32-byte key produces a stable, deterministic side name.
    const key32 = repeated(32, 0x42);
    const side_a = try handoff.sideName(&key32);
    const side_b = try handoff.sideName(&key32);
    try std.testing.expectEqualSlices(u8, &side_a, &side_b);

    // Any other width is rejected fail-closed rather than producing a
    // Goblins-incompatible name or overflowing the rendering buffer.
    const short = repeated(31, 0x42);
    const long = repeated(33, 0x42);
    try std.testing.expectError(error.MalformedKey, handoff.sideName(&short));
    try std.testing.expectError(error.MalformedKey, handoff.sideName(&long));
}
