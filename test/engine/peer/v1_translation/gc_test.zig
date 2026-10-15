//! V1.0 resolver-link GC: a resolver export survives the partner's release
//! of its wire mention, and a gc-answers wave drops every released link.

const std = @import("std");
const glowcap = @import("glowcap");

const codec = glowcap.ocapn.codec;
const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;

test "a V1.0 resolver export survives the partner's gc of its wire mention" {
    const allocator = std.testing.allocator;
    var p1 = engine.Peer.init(allocator);
    defer p1.deinit();
    try p1.session_state.registerImport(.from(7));

    // Sending a deliver that wants an answer on a v1.0 session mints the
    // resolver export at admission (`outbound/encoded.zig`) and puts its
    // mention on the wire, which must carry the same wire-delta retain
    // `recordSend` would have added: local reference + one wire mention.
    const resolver_export = p1.session_state.next_export_position;
    try p1.sendBorrowed(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(7) } },
        .args = &.{},
        .answer = .from(42),
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    {
        var deliver_frame = p1.takeOutbound().?;
        deliver_frame.deinit();
    }
    try std.testing.expectEqual(@as(u64, 2), p1.session_state.exportRefcount(.from(resolver_export)));

    // The partner releases the one wire mention. The local reference keeps the
    // export row alive, without the encode-time retain this gc would drive the
    // count to zero and remove the row while `outbound_resolver_link` still
    // points at it.
    {
        const positions = [_]u64{resolver_export};
        const deltas = [_]u64{1};
        const gc = try codec.syrup.encodeMessage(allocator, .{ .gc_export = .{
            .positions = &positions,
            .deltas = &deltas,
        } });
        try p1.feedOwned(gc);
    }
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    {
        var gc_event = p1.pollEvent().?;
        gc_event.deinit();
    }
    try std.testing.expect(p1.session_state.hasExport(.from(resolver_export)));
    try std.testing.expectEqual(@as(u64, 1), p1.session_state.exportRefcount(.from(resolver_export)));

    // The partner's resolver callback still settles answer 42: the V1.0
    // translation seam routes a deliver to a known resolver export through
    // the resolver link (`answerForResolverExport`), not through the ADR-0074
    // near-target admission an ordinary export answers to, and the link's
    // whole point is surviving the released wire mention above. The callback
    // can only settle the answer we minted the resolver for, so no broader
    // authority rides on it.
    {
        const callback = try codec.syrup.encodeMessage(allocator, .{ .deliver = .{
            .target = .{ .far = model.FarRef.promise(resolver_export) },
            .args = &.{ .{ .symbol = "fulfill" }, .{ .integer = 17 } },
            .answer = null,
        } });
        try p1.feedOwned(callback);
    }
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    var resolve_event = p1.pollEvent().?;
    defer resolve_event.deinit();
    try std.testing.expectEqual(engine.EventKind.resolve, resolve_event.kind());
}

test "a gc wave over many answered delivers drops every V1.0 resolver link" {
    // The outbound resolver link map is pruned per released answer through its
    // answer side of the `outbound_resolver_link` BiMap, two O(1) keyed
    // removals per position instead of a scan of every outstanding link. This
    // pins the correctness half of that shape: after a full release wave every
    // link, and only the released links, is gone, and both map directions
    // agree. The linear-vs-quadratic win itself is a bench concern.
    const allocator = std.testing.allocator;
    var peer = engine.Peer.init(allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(7));

    // Send a wave of answered delivers; admitting each mints its resolver
    // export in order (`outbound/encoded.zig`).
    const wave = 64;
    const first_resolver = peer.session_state.next_export_position;
    for (0..wave) |i| {
        try peer.sendBorrowed(.{ .deliver = .{
            .target = .{ .far = .{ .import_position = .from(7) } },
            .args = &.{},
            .answer = .from(i),
        } });
        try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
        var frame = peer.takeOutbound().?;
        frame.deinit();
    }
    for (0..wave) |i| {
        try std.testing.expectEqual(
            @as(?model.AnswerPosition, .from(i)),
            peer.session_state.answerForResolverExport(.from(first_resolver + i)),
        );
    }

    // Release every answer but the last in one `op:gc-answers` wave: each
    // released answer's resolver link drops with its row, the survivor keeps
    // both directions of its link.
    var positions: [wave - 1]u64 = undefined;
    for (&positions, 0..) |*position, i| position.* = i;
    try peer.sendBorrowed(.{ .gc_answer = .{ .positions = &positions } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    {
        var frame = peer.takeOutbound().?;
        frame.deinit();
    }
    for (0..wave - 1) |i| {
        try std.testing.expectEqual(
            @as(?model.AnswerPosition, null),
            peer.session_state.answerForResolverExport(.from(first_resolver + i)),
        );
    }
    try std.testing.expectEqual(
        @as(?model.AnswerPosition, .from(wave - 1)),
        peer.session_state.answerForResolverExport(.from(first_resolver + wave - 1)),
    );
}
