//! The imported-promise store: a third-party import installs atomically and
//! owns its host, listeners, and relayed resolution until an outbound release
//! drops the row, and promise shortening rewrites through chains, refuses a
//! cycle, and spends only the retains its stable edges own.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const session = glowcap.ocapn.session;

test "imported-promise substrate owns host, listeners, and relayed resolution" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();

    // Root import 5 at a third-party host; idempotent for the same host.
    try s.installThirdPartyImport(.from(5), "host-a");
    try std.testing.expect(s.isThirdPartyImport(.from(5)));
    try std.testing.expect(!s.isThirdPartyImport(.from(6)));
    try s.installThirdPartyImport(.from(5), "host-a");

    // Re-rooting at a different host is a loud error.
    try std.testing.expectError(error.HostMismatch, s.installThirdPartyImport(.from(5), "host-b"));

    // A listener (POD far listener cap) and a stored relayed resolution.
    try s.retainImportForSession(.from(9));
    try s.installImportedPromiseListener(.from(5), .{ .listener = .{ .import_position = .from(9) }, .mode = .settling_only });
    try std.testing.expect(try s.recordRelayedResolution(.from(5), s.importedPromiseRowId(.from(5)).?, .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "v") } }));
    const peeked = s.importedPromiseResolution(.from(5)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("v", peeked.fulfill.bytes);

    // A second relayed resolution is refused — a promise resolves once,
    // mirroring the answer-side rule — the refused value is freed (no leak),
    // and the stored value is untouched.
    try std.testing.expectError(error.UnexpectedMessage, s.recordRelayedResolution(
        .from(5),
        s.importedPromiseRowId(.from(5)).?,
        .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "w") } },
    ));
    try std.testing.expectEqualStrings("v", s.importedPromiseResolution(.from(5)).?.fulfill.bytes);

    // Recording on an unknown import frees the resolution and errors.
    try std.testing.expectError(error.InvalidReference, s.recordRelayedResolution(
        .from(99),
        0,
        .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "z") } },
    ));

    // Drain empties the list (entries are POD; only the slice is owned); a
    // second drain is empty.
    const listeners = try s.takeImportedPromiseListeners(.from(5));
    defer allocator.free(listeners);
    try std.testing.expectEqual(@as(usize, 1), listeners.len);
    try std.testing.expectEqual(@as(usize, 0), (try s.takeImportedPromiseListeners(.from(5))).len);
}

test "third-party import installation is atomic across allocation failure" {
    var reached_success = false;
    for (0..16) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        var s = session.Session.init(failing.allocator());
        defer {
            failing.fail_index = std.math.maxInt(usize);
            s.deinit();
        }

        s.installThirdPartyImport(.from(5), "home") catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(@as(u64, 0), s.importRefcount(.from(5)));
            try std.testing.expect(!s.isThirdPartyImport(.from(5)));
            continue;
        };
        reached_success = true;
        try std.testing.expectEqual(@as(u64, 1), s.importRefcount(.from(5)));
        try std.testing.expect(s.isThirdPartyImport(.from(5)));
        break;
    }
    try std.testing.expect(reached_success);
}

test "imported-promise listener cap fails loud" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .limits = .{ .max_listeners_per_target = 1 },
    });
    defer s.deinit();

    try s.installThirdPartyImport(.from(5), "h");
    try s.retainImportForSession(.from(9));
    try s.installImportedPromiseListener(.from(5), .{ .listener = .{ .import_position = .from(9) }, .mode = .settling_only });
    try std.testing.expectError(error.ListenerCapExceeded, s.installImportedPromiseListener(
        .from(5),
        .{ .listener = .{ .import_position = .from(9) }, .mode = .settling_only },
    ));
    // A listener on an unknown (non-third-party) import errors.
    try std.testing.expectError(error.InvalidReference, s.installImportedPromiseListener(
        .from(99),
        .{ .listener = .{ .import_position = .from(9) }, .mode = .settling_only },
    ));
}

test "outbound gc-export releasing a third-party import drops its imported-promise row" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();

    try s.installThirdPartyImport(.from(5), "h");
    try s.retainImportForSession(.from(9));
    try s.installImportedPromiseListener(.from(5), .{ .listener = .{ .import_position = .from(9) }, .mode = .settling_only });
    try std.testing.expect(try s.recordRelayedResolution(.from(5), s.importedPromiseRowId(.from(5)).?, .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "v") } }));
    try std.testing.expect(s.isThirdPartyImport(.from(5)));

    // Outbound op:gc-exports releasing import 5 (count 1 → 0) evicts the row,
    // freeing the host designator, the listener cap, and the stored resolution.
    try s.recordSend(.{ .gc_export = .{ .positions = &.{5}, .deltas = &.{1} } });
    try std.testing.expect(!s.isThirdPartyImport(.from(5)));
    try std.testing.expect(s.importedPromiseResolution(.from(5)) == null);
}

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
    s.rewriteShortenedMessage(&message);
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
    try std.testing.expectEqual(@as(usize, 0), try s.expandShorteningGcExportReleases(allocator, &release));
    try s.recordSend(.{ .gc_export = release });
    try std.testing.expect(!s.holdsImport(.from(5)));
    try std.testing.expectEqual(@as(u64, 1), s.importRefcount(.from(6)));
}
