//! Canonical three-party handoff conversation.

const std = @import("std");
const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");
const appendTraceLine = @import("../trace.zig").appendLine;
const support = @import("support.zig");

const DrivenGiftSeams = struct {
    gifter_scope: engine.PeerHandle,
    recipient_scope: engine.PeerHandle,
    source_position: model.ExportPosition,
    gifter_peer: *engine.Peer,
    recipient_peer: *engine.Peer,
    projected_position: ?model.ExportPosition = null,

    const target: u64 = 1;

    fn resolveName(_: ?*anyopaque, _: engine.PeerHandle, request: engine.bootstrap.FetchContext) !engine.bootstrap.FetchOutcome {
        return if (request.session_fallback) |position| .{ .found = position } else .missing;
    }

    fn capture(ctx: ?*anyopaque, scope: engine.PeerHandle, position: model.ExportPosition) ?u64 {
        const self: *DrivenGiftSeams = @ptrCast(@alignCast(ctx.?));
        if (scope != self.gifter_scope or position != self.source_position) return null;
        return target;
    }

    fn project(ctx: ?*anyopaque, scope: engine.PeerHandle, opaque_target: u64) !engine.bootstrap.gifts.ProjectedLocalTarget {
        const self: *DrivenGiftSeams = @ptrCast(@alignCast(ctx.?));
        if (scope != self.recipient_scope or opaque_target != target) return error.InvalidGiftTarget;
        const position: model.ExportPosition = .from(try self.recipient_peer.exportNextObject());
        self.projected_position = position;
        return .{ .export_position = position, .created = true };
    }

    fn releaseTarget(_: ?*anyopaque, _: u64) void {}

    fn rollback(ctx: ?*anyopaque, scope: engine.PeerHandle, opaque_target: u64, projected: engine.bootstrap.gifts.ProjectedLocalTarget) void {
        const self: *DrivenGiftSeams = @ptrCast(@alignCast(ctx.?));
        if (!projected.created or scope != self.recipient_scope or opaque_target != target) return;
        self.recipient_peer.session_state.releaseUnsharedExport(projected.export_position);
        self.projected_position = null;
    }

    fn resolveGifterSession(ctx: ?*anyopaque, gifter_side: [32]u8, session_name: []const u8) ?engine.bootstrap.gifts.GifterSession {
        const self: *DrivenGiftSeams = @ptrCast(@alignCast(ctx.?));
        if (!self.gifter_peer.verify_partner_handshake) return null;
        const key = engine.bootstrap.gifterKeyForSession(&self.gifter_peer.session_state, gifter_side, session_name) orelse return null;
        return .{ .peer_handle = self.gifter_scope, .key = key, .gifts = self.gifter_peer.giftRegistry() };
    }
};

/// Drive a complete signed give, early withdraw, deposit, redemption, and
/// direct call across three real keyed sessions. The surrounding session may
/// use either codec; handoff signatures remain in the Syrup signing domain.
pub fn run(allocator: std.mem.Allocator, codec_id: model.CodecId) ![]u8 {
    const crypto = foundation.crypto;
    const gifter_secret = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x11)));
    const recipient_secret = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x22)));
    const exporter_secret = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x33)));

    var gifter_to_recipient = support.keyedNegotiatingPeer(allocator, codec_id);
    defer gifter_to_recipient.deinit();
    var recipient_to_gifter = support.keyedNegotiatingPeer(allocator, codec_id);
    defer recipient_to_gifter.deinit();
    var gifter_to_exporter = support.keyedNegotiatingPeer(allocator, codec_id);
    defer gifter_to_exporter.deinit();
    var recipient_to_exporter = support.keyedNegotiatingPeer(allocator, codec_id);
    defer recipient_to_exporter.deinit();

    var exporter_node = engine.Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x33)));
    defer exporter_node.deinit();
    const exporter_options: engine.Peer.NegotiatingOptions = .{
        .captp_version = .v1_0,
        .codec = codec_id,
        .features = model.FeatureSet.full(),
    };
    const exporter_gifter_id = try exporter_node.registerPeer(exporter_options);
    const exporter_recipient_id = try exporter_node.registerPeer(exporter_options);
    const exporter_to_gifter = exporter_node.peer(exporter_gifter_id).?;
    const exporter_to_recipient = exporter_node.peer(exporter_recipient_id).?;

    var seams = DrivenGiftSeams{
        .gifter_scope = exporter_gifter_id,
        .recipient_scope = exporter_recipient_id,
        .source_position = undefined,
        .gifter_peer = exporter_to_gifter,
        .recipient_peer = exporter_to_recipient,
    };
    exporter_node.setLocalObjectProjection(.{
        .ctx = &seams,
        .resolve_fetch = DrivenGiftSeams.resolveName,
        .capture = DrivenGiftSeams.capture,
        .project = DrivenGiftSeams.project,
        .rollback = DrivenGiftSeams.rollback,
        .release_target = DrivenGiftSeams.releaseTarget,
    });
    exporter_node.setGifterSessionResolver(.{ .ctx = &seams, .resolve = DrivenGiftSeams.resolveGifterSession });

    try support.openKeyedSession(&gifter_to_recipient, gifter_secret, "gifter", &recipient_to_gifter, recipient_secret, "recipient");
    try support.openKeyedSession(&gifter_to_exporter, gifter_secret, "gifter", exporter_to_gifter, exporter_secret, "exporter");
    try support.openKeyedSession(&recipient_to_exporter, recipient_secret, "recipient", exporter_to_recipient, exporter_secret, "exporter");

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "scenario=driven_handoff\n");

    const thermostat_gifter_session = try exporter_to_gifter.registerBootstrapCap("thermostat");
    seams.source_position = .from(thermostat_gifter_session);
    try appendTraceLine(allocator, &out, "exporter=registered:swissnum=thermostat:gifter_session={d}\n", .{thermostat_gifter_session});

    const prepared = try engine.fetch.prepareFetchSwissnum(allocator, &gifter_to_exporter.session_state, "thermostat");
    try gifter_to_exporter.send(prepared.message);
    _ = try gifter_to_exporter.step();
    try out.appendSlice(allocator, "gifter=sent:fetch\n");
    try support.shuttleAndTraceEvents(allocator, &out, &gifter_to_exporter, exporter_to_gifter, "exporter");
    try support.shuttleFrames(exporter_to_gifter, &gifter_to_exporter);
    var fetched: model.Reference = undefined;
    {
        var settle = gifter_to_exporter.pollEvent() orelse return error.MissingFetchResolve;
        defer settle.deinit();
        const owned = try settle.decodeOwned(allocator);
        const match = try engine.fetch.tryMatchFetchOutcome(allocator, prepared.resolver_export, prepared.answer_position, owned);
        switch (match) {
            .settled => |outcome| switch (outcome) {
                .fulfilled => |reference| fetched = reference,
                .broken => |reason| {
                    allocator.free(reason);
                    return error.FetchBroken;
                },
                .malformed => return error.FetchMalformed,
            },
            .unrelated => |message| {
                model.freeMessage(allocator, message);
                return error.FetchUnrelated;
            },
        }
    }
    defer model.freeReference(allocator, fetched);
    switch (fetched) {
        .far => |far| try appendTraceLine(allocator, &out, "gifter=fetched:thermostat:import={d}\n", .{far.import_position.int()}),
        else => return error.UnexpectedFetchShape,
    }

    try recipient_to_gifter.session_state.registerImport(.from(7));
    try gifter_to_recipient.session_state.registerExport(.from(7));
    try recipient_to_gifter.sendCopying(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(7) } },
        .args = &.{.{ .symbol = "introduce" }},
        .answer = .from(42),
    } });
    _ = try recipient_to_gifter.step();
    try out.appendSlice(allocator, "recipient=sent:deliver:answer=42\n");
    try support.shuttleAndTraceEvents(allocator, &out, &recipient_to_gifter, &gifter_to_recipient, "gifter");

    const recipient_key = gifter_to_recipient.session_state.partnerSessionKey() orelse return error.NoRecipientKey;
    const exporter_key = gifter_to_exporter.session_state.partnerSessionKey() orelse return error.NoExporterKey;
    const exporter_location = try engine.encodePeerLocatorRecord(allocator, .{
        .transport = "tcp",
        .designator = "exporter",
        .hints = model.Hints.emptyFalse(),
    });
    defer allocator.free(exporter_location);
    const gifter_side = try engine.handoff_recipient.sideName(gifter_secret.publicKey().asBytes());
    const exporter_side = try engine.handoff_recipient.sideName(exporter_key);
    const gifter_exporter_session = engine.handoff_recipient.sessionName(gifter_side, exporter_side);
    const gift_id = @as([32]u8, @splat(0x6b));
    const give_bytes = try engine.handoff_gifter.buildSignedGive(
        allocator,
        gifter_secret,
        recipient_key,
        exporter_location,
        &gifter_exporter_session,
        &gifter_side,
        &gift_id,
    );
    defer allocator.free(give_bytes);
    try gifter_to_exporter.sendDepositGift(&gift_id, fetched);
    try out.appendSlice(allocator, "gifter=sent:deposit_gift\n");
    try gifter_to_recipient.sendResolveHandoffGive(
        gifter_to_recipient.session_state.answerTargetNamed(.fromWire(.from(42))).?,
        give_bytes,
    );
    try out.appendSlice(allocator, "gifter=sent:resolve_give:answer=42\n");

    try support.shuttleFrames(&gifter_to_recipient, &recipient_to_gifter);
    var redeem_give: ?[]u8 = null;
    defer if (redeem_give) |bytes| allocator.free(bytes);
    {
        var event = recipient_to_gifter.pollEvent() orelse return error.MissingGiveResolve;
        defer event.deinit();
        const view = try event.view();
        try appendTraceLine(allocator, &out, "recipient=event:resolve:answer={d}:fulfill={s}\n", .{
            view.resolve.answer,
            @tagName(view.resolve.resolution.fulfill),
        });
        var projected = try engine.handoff_recipient.projectGiveForRedeem(
            allocator,
            view.resolve.resolution.fulfill.handoff.give,
        );
        defer projected.deinit(allocator);
        redeem_give = try allocator.dupe(u8, projected.bytes() orelse return error.GiveProjectionFailed);
    }

    try recipient_to_exporter.sendWithdrawGift(recipient_secret, redeem_give.?, .from(1));
    _ = try recipient_to_exporter.step();
    try out.appendSlice(allocator, "recipient=sent:withdraw_gift:answer=1\n");
    try support.shuttleAndTraceEvents(allocator, &out, &recipient_to_exporter, exporter_to_recipient, "exporter");
    try appendTraceLine(allocator, &out, "exporter=withdraw_parked={d}:gift_live={}\n", .{
        exporter_to_recipient.pendingWithdrawCount(),
        exporter_to_gifter.giftRegistry().giftLive(&gift_id),
    });

    try support.shuttleAndTraceEvents(allocator, &out, &gifter_to_exporter, exporter_to_gifter, "exporter");
    try appendTraceLine(allocator, &out, "exporter=deposit_recorded:gift_live={}\n", .{exporter_to_gifter.giftRegistry().giftLive(&gift_id)});
    const changed = exporter_node.nextHandoffChange() orelse return error.MissingHandoffWake;
    var waiters = exporter_node.handoffWaiters(changed);
    while (waiters.next()) |receiver| exporter_node.peer(receiver).?.noteHandoffChange(changed);
    exporter_node.consumeHandoffChange(changed);
    try support.shuttleFrames(exporter_to_recipient, &recipient_to_exporter);
    try appendTraceLine(allocator, &out, "exporter=withdraw_settled:parked={d}:gift_live={}\n", .{
        exporter_to_recipient.pendingWithdrawCount(),
        exporter_to_gifter.giftRegistry().giftLive(&gift_id),
    });
    var direct_import: u64 = 0;
    {
        var event = recipient_to_exporter.pollEvent() orelse return error.MissingWithdrawResolve;
        defer event.deinit();
        const owned = try event.decodeOwned(allocator);
        defer model.freeMessage(allocator, owned);
        const reference = owned.resolve.resolution.fulfill.reference;
        direct_import = switch (reference) {
            .far => |far| far.import_position.int(),
            else => return error.UnexpectedWithdrawShape,
        };
        try appendTraceLine(allocator, &out, "recipient=event:resolve:answer={d}:fulfill=import={d}\n", .{
            owned.resolve.answer.int(),
            direct_import,
        });
    }

    try recipient_to_exporter.sendCopying(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(direct_import) } },
        .args = &.{.{ .symbol = "read" }},
        .answer = .from(2),
    } });
    _ = try recipient_to_exporter.step();
    try out.appendSlice(allocator, "recipient=sent:deliver:answer=2:direct\n");
    try support.shuttleFrames(&recipient_to_exporter, exporter_to_recipient);
    {
        var event = exporter_to_recipient.pollEvent() orelse return error.MissingRedeemedDeliver;
        defer event.deinit();
        const view = try event.view();
        if (view != .deliver or view.deliver.target != .near) return error.MalformedRedeemedDeliver;
        if (view.deliver.target.near.export_position != (seams.projected_position orelse return error.GiftWasNotProjected))
            return error.RedeemedWrongTarget;
        try out.appendSlice(allocator, "exporter=event:deliver\n");
    }
    try exporter_to_recipient.sendCopying(.{ .resolve = .{
        .answer = .from(2),
        .resolution = .{ .fulfill = .{ .string = "72F" } },
    } });
    _ = try exporter_to_recipient.step();
    try out.appendSlice(allocator, "exporter=sent:resolve:answer=2\n");
    try support.shuttleAndTraceEvents(allocator, &out, exporter_to_recipient, &recipient_to_exporter, "recipient");
    try out.appendSlice(allocator, "\n");

    return out.toOwnedSlice(allocator);
}
