//! The imported-promise rows: promise shortening rewrites through chains,
//! refuses cycles and bounds each walk by `max_resolution_chain`, and spends
//! only the retains its stable edges own.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const session = glowcap.ocapn.session;

test "promise shortening rewrites through chains and refuses a cycle" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerImport(.from(5));
    try s.registerImport(.from(6));
    try s.registerImport(.from(7));

    // Each callback's introduced retain (the `registerImport` above stands in
    // for it) becomes the stable edge's own once the source is still held.
    const first = (try s.nominateShorteningResolver(.from(5))).?;
    try s.validateShorteningCompletion(first.resolver_export, model.FarRef.promise(6));
    s.completeShortening(first.resolver_export, model.FarRef.promise(6), true);

    const second = (try s.nominateShorteningResolver(.from(6))).?;
    try s.validateShorteningCompletion(second.resolver_export, model.FarRef.promise(7));
    s.completeShortening(second.resolver_export, model.FarRef.promise(7), true);

    // An edge-owned retain is the session's, not a caller's to spend.
    try std.testing.expectEqual(@as(u64, 0), s.importReleasable(.from(6)));
    try std.testing.expectError(error.GcUnderflow, s.recordSend(.{ .gc_export = .{ .positions = &.{6}, .deltas = &.{1} } }));

    var message: model.Message = .{ .deliver = .{
        .target = .{ .far = model.FarRef.promise(5) },
        .args = &.{},
    } };
    s.rewriteShortenedMessage(&message, .none);
    try std.testing.expectEqual(model.FarRef.promise(7), message.deliver.target.far);

    const cycle = (try s.nominateShorteningResolver(.from(7))).?;
    try std.testing.expectError(
        session.Error.UnexpectedMessage,
        s.validateShorteningCompletion(cycle.resolver_export, model.FarRef.promise(5)),
    );

    var release: model.GcExport = .{
        .positions = try allocator.dupe(u64, &.{5}),
        .deltas = try allocator.dupe(u64, &.{1}),
    };
    defer allocator.free(release.positions);
    defer allocator.free(release.deltas);
    // The caller's release of 5 carries the closure behind it: the two
    // edge-owned retains, recorded as the session's own the way `Peer.send`
    // records them.
    const closure_len = try s.expandShorteningGcExportReleases(allocator, &release);
    try std.testing.expectEqual(@as(usize, 2), closure_len);
    try std.testing.expectEqualSlices(u64, &.{ 5, 6, 7 }, release.positions);
    try std.testing.expectEqualSlices(u64, &.{ 1, 1, 1 }, release.deltas);
    try s.recordSend(.{ .gc_export = .{ .positions = release.positions[0..1], .deltas = release.deltas[0..1] } });
    s.recordSessionImportRelease(.{ .positions = release.positions[1..], .deltas = release.deltas[1..] });
    try std.testing.expect(!s.holdsImport(.from(5)));
    try std.testing.expect(!s.holdsImport(.from(6)));
    try std.testing.expect(!s.holdsImport(.from(7)));
}

test "an edge completed after its source was released owns no retain and adds nothing to a closure" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerImport(.from(5));
    try s.registerImport(.from(6));

    // The edge 5 -> 6 lands after 5 was already released: the engine gives
    // the callback's retain on 6 back in the same transaction, so the edge
    // must not own one.
    const first = (try s.nominateShorteningResolver(.from(5))).?;
    try s.validateShorteningCompletion(first.resolver_export, model.FarRef.promise(6));
    s.completeShortening(first.resolver_export, model.FarRef.promise(6), false);
    try std.testing.expectEqual(@as(u64, 1), s.importReleasable(.from(6)));

    // The caller's release of 5 carries no closure, and 6 stays exactly as
    // its own holder left it.
    var release: model.GcExport = .{
        .positions = try allocator.dupe(u64, &.{5}),
        .deltas = try allocator.dupe(u64, &.{1}),
    };
    defer allocator.free(release.positions);
    defer allocator.free(release.deltas);
    var no_allocation = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectEqual(@as(usize, 0), try s.expandShorteningGcExportReleases(no_allocation.allocator(), &release));
    try s.recordSend(.{ .gc_export = release });
    try std.testing.expect(!s.holdsImport(.from(5)));
    try std.testing.expectEqual(@as(u64, 1), s.importRefcount(.from(6)));
}

test "a release naming no shortening source allocates nothing on either profile" {
    const allocator = std.testing.allocator;
    for ([_]model.CaptpVersion{ .v1_0, .next }) |profile| {
        var s = session.Session.initWith(allocator, .{ .captp_version = profile });
        defer s.deinit();
        try s.registerImport(.from(5));
        var release: model.GcExport = .{ .positions = &.{5}, .deltas = &.{1} };
        var no_allocation = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
        try std.testing.expectEqual(@as(usize, 0), try s.expandShorteningGcExportReleases(no_allocation.allocator(), &release));
        try s.recordSend(.{ .gc_export = release });
        try std.testing.expect(!s.holdsImport(.from(5)));
    }
}

test "a shortening callback refuses a target path past its walk budget" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    s.limits.max_resolution_chain = 2;
    for ([_]u64{ 5, 6, 7, 8 }) |position| try s.registerImport(.from(position));

    // Built from the tail, so each admitted edge sits above a chain the
    // limit still allows: 7 -> 8, then 6 -> 7.
    const tail = (try s.nominateShorteningResolver(.from(7))).?;
    try s.validateShorteningCompletion(tail.resolver_export, model.FarRef.promise(8));
    s.completeShortening(tail.resolver_export, model.FarRef.promise(8), true);
    const middle = (try s.nominateShorteningResolver(.from(6))).?;
    try s.validateShorteningCompletion(middle.resolver_export, model.FarRef.promise(7));
    s.completeShortening(middle.resolver_export, model.FarRef.promise(7), true);

    // A third edge would make a chain of three hops.
    const head = (try s.nominateShorteningResolver(.from(5))).?;
    try std.testing.expectError(
        session.Error.ShorteningChainTooLong,
        s.validateShorteningCompletion(head.resolver_export, model.FarRef.promise(6)),
    );

    // The admitted chain still rewrites end to end.
    var message: model.Message = .{ .deliver = .{
        .target = .{ .far = model.FarRef.promise(6) },
        .args = &.{},
    } };
    s.rewriteShortenedMessage(&message, .none);
    try std.testing.expectEqual(model.FarRef.promise(8), message.deliver.target.far);
    try std.testing.expectEqual(model.ImportPosition.from(8), s.shortenedPromiseTarget(.from(6)));
}

test "head-first shortening bounds routing while releasing the whole retained chain" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    s.limits.max_resolution_chain = 2;
    for ([_]u64{ 5, 6, 7, 8 }) |position| try s.registerImport(.from(position));

    // Callbacks may extend an admitted path. Each callback
    // here sees a self-root target and spends only its own bounded walk.
    for ([_]u64{ 5, 6, 7 }) |source| {
        const resolver = (try s.nominateShorteningResolver(.from(source))).?;
        const target = model.FarRef.promise(source + 1);
        try s.validateShorteningCompletion(resolver.resolver_export, target);
        s.completeShortening(resolver.resolver_export, target, true);
    }
    // The rewrite may stop at 7: it remains valid promise authority and its
    // edge still owns 8. Releasing 5 must nevertheless drain every edge.
    try std.testing.expectEqual(model.ImportPosition.from(7), s.shortenedPromiseTarget(.from(5)));

    var release: model.GcExport = .{
        .positions = try allocator.dupe(u64, &.{5}),
        .deltas = try allocator.dupe(u64, &.{1}),
    };
    defer allocator.free(release.positions);
    defer allocator.free(release.deltas);
    try std.testing.expectEqual(@as(usize, 3), try s.expandShorteningGcExportReleases(allocator, &release));
    try std.testing.expectEqualSlices(u64, &.{ 5, 6, 7, 8 }, release.positions);
    try std.testing.expectEqualSlices(u64, &.{ 1, 1, 1, 1 }, release.deltas);
    try s.recordSend(.{ .gc_export = .{ .positions = release.positions[0..1], .deltas = release.deltas[0..1] } });
    s.recordSessionImportRelease(.{ .positions = release.positions[1..], .deltas = release.deltas[1..] });
    for ([_]u64{ 5, 6, 7, 8 }) |position| try std.testing.expect(!s.holdsImport(.from(position)));
}
