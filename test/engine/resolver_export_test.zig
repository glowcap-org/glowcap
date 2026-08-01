//! The resolver-export probe, on both negotiated profiles.
//!
//! A resolver export is one of our exports bound to an outbound answer it
//! settles, and a deliver to it carrying `['fulfill|'break, payload]` is the
//! partner settling that answer (ADR-0095). The link was reached only on V1.0
//! sessions once, because a V1.0 resolver callback was the only thing that
//! minted one; an `op:listen` listener export is settled by that same shape on
//! any profile, so the probe now runs on every session. These tests pin what
//! that widening does, what it must not do (an over-broad probe would swallow
//! ordinary calls), and that the pre-ratified profile's own answer settlement
//! is untouched by it.

const std = @import("std");
const pancake = @import("pancake");

const engine = pancake.ocapn.engine;
const model = pancake.ocapn.model;
const session = pancake.ocapn.session;

/// Both negotiated profiles carry the listen notification, so the probe is
/// exercised on each.
const profiles = [_]model.CaptpVersion{ .v1_0, .next };

/// A paired session on `version` over Syrup.
fn syrupPair(allocator: std.mem.Allocator, version: model.CaptpVersion) !engine.pairing.Pair {
    return engine.pairing.pairedNegotiated(allocator, .{
        .captp_version = version,
        .codec = .syrup,
        .features = model.FeatureSet.full(),
    });
}

/// Grant `position` as a live export on `holder` and as the matching import on
/// `partner`, the two names one wire position wears.
fn grantExport(holder: *engine.Peer, partner: *engine.Peer, position: u64) !void {
    try holder.session_state.registerExport(.from(position));
    try partner.session_state.registerImport(.from(position));
}

/// One `['fulfill|'break, payload]` deliver from `partner` to `holder`'s export
/// at `position`, shuttled across and dispatched.
fn fireAt(partner: *engine.Peer, holder: *engine.Peer, position: u64, args: []const model.Argument) !void {
    try partner.sendCopying(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(position) },
        .args = args,
        .answer = null,
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try partner.step());
    try holder.feedOwned(partner.takeOutbound().?);
}

test "a deliver to a resolver export re-tags as a resolve on every profile" {
    const allocator = std.testing.allocator;
    for (profiles) |version| {
        var pair = try syrupPair(allocator, version);
        defer pair.deinit();

        const resolver: u64 = 41;
        const answer = model.AnswerPosition.from(7);
        try grantExport(&pair.p1, &pair.p2, resolver);
        try pair.p1.session_state.installOutboundResolver(answer, .from(resolver));
        try pair.p1.session_state.installOutboundAnswer(answer);

        try fireAt(&pair.p2, &pair.p1, resolver, &.{ .{ .symbol = "fulfill" }, .{ .bytes = "relayed" } });
        try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p1.step());

        var event = pair.p1.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(engine.EventKind.resolve, event.kind());
        const view = try event.view();
        try std.testing.expectEqual(answer, view.resolve.answer);
        try std.testing.expectEqualStrings("relayed", view.resolve.resolution.fulfill.bytes);
    }
}

test "a deliver to an ordinary export is still a deliver" {
    const allocator = std.testing.allocator;
    for (profiles) |version| {
        var pair = try syrupPair(allocator, version);
        defer pair.deinit();

        // Two exports, one bound to an answer and one not. Only the bound one
        // may re-tag: an ordinary call must not be read as somebody's
        // settlement, which is the whole risk of widening the probe.
        const resolver: u64 = 41;
        const plain: u64 = 42;
        try grantExport(&pair.p1, &pair.p2, resolver);
        try grantExport(&pair.p1, &pair.p2, plain);
        try pair.p1.session_state.installOutboundResolver(.from(7), .from(resolver));
        try pair.p1.session_state.installOutboundAnswer(.from(7));

        try fireAt(&pair.p2, &pair.p1, plain, &.{ .{ .symbol = "fulfill" }, .{ .bytes = "relayed" } });
        try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p1.step());

        var event = pair.p1.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(engine.EventKind.deliver, event.kind());
        const view = try event.view();
        try std.testing.expectEqual(@as(u64, plain), view.deliver.target.near.export_position.int());
    }
}

test "a second fire on the same answer is refused" {
    const allocator = std.testing.allocator;
    for (profiles) |version| {
        var pair = try syrupPair(allocator, version);
        defer pair.deinit();

        const resolver: u64 = 41;
        const answer = model.AnswerPosition.from(7);
        try grantExport(&pair.p1, &pair.p2, resolver);
        try pair.p1.session_state.installOutboundResolver(answer, .from(resolver));
        try pair.p1.session_state.installOutboundAnswer(answer);

        const args = [_]model.Argument{ .{ .symbol = "fulfill" }, .{ .bytes = "once" } };
        try fireAt(&pair.p2, &pair.p1, resolver, &args);
        try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p1.step());
        {
            var event = pair.p1.pollEvent().?;
            event.deinit();
        }

        // An answer settles once. The second notification is a partner
        // protocol violation, refused exactly as a second `op:resolve` on the
        // same answer is.
        try fireAt(&pair.p2, &pair.p1, resolver, &args);
        try std.testing.expectError(error.UnexpectedMessage, pair.p1.step());
    }
}

test "the pre-ratified profile still settles an answered deliver by op:resolve, minting no resolver" {
    const allocator = std.testing.allocator;
    var pair = try syrupPair(allocator, .next);
    defer pair.deinit();

    // An ordinary answered call. On V1.0 the encoder would augment this with a
    // synthesized resolver export and settle it through a callback deliver;
    // here it must not, and the widened probe must not make it look as though
    // it did.
    const before = pair.p1.session_state.next_export_position;
    try pair.p1.session_state.registerImport(.from(session.BOOTSTRAP_POSITION));
    try pair.p1.sendCopying(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(session.BOOTSTRAP_POSITION) } },
        .args = &.{.{ .bytes = "ping" }},
        .answer = .from(42),
        .resolve_me_desc = null,
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p1.step());

    // No resolver export was minted, so the resolver-export link is empty and
    // the probe has nothing on this session to match.
    try std.testing.expectEqual(before, pair.p1.session_state.next_export_position);
    try std.testing.expectEqual(
        @as(?model.AnswerPosition, null),
        pair.p1.session_state.answerForResolverExport(.from(before)),
    );

    try pair.p2.feedOwned(pair.p1.takeOutbound().?);
    try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p2.step());
    {
        var event = pair.p2.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(engine.EventKind.deliver, event.kind());
    }
    // The partner learned no resolver import either: there was nothing on the
    // deliver to advertise one.
    try std.testing.expectEqual(
        @as(?model.ImportPosition, null),
        pair.p2.session_state.resolverForInboundAnswer(.from(42)),
    );

    try pair.p2.sendCopying(.{ .resolve = .{
        .answer = .from(42),
        .resolution = .{ .fulfill = .{ .bytes = "pong" } },
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p2.step());
    try pair.p1.feedOwned(pair.p2.takeOutbound().?);
    try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p1.step());

    var event = pair.p1.pollEvent().?;
    defer event.deinit();
    try std.testing.expectEqual(engine.EventKind.resolve, event.kind());
    // A wire `op:resolve`, not a re-tagged deliver: the answer came off the
    // frame itself, so no off-wire override was needed to read it.
    try std.testing.expect(event.answer_override == .none);
    const view = try event.view();
    try std.testing.expectEqual(@as(u64, 42), view.resolve.answer.int());
    try std.testing.expectEqualStrings("pong", view.resolve.resolution.fulfill.bytes);
}
