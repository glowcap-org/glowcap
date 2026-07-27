const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const session = pancake.ocapn.session;

const sturdyref = engine.sturdyref;
const fetch = engine.fetch;

test "sturdyref cache stores, reconstructs, and overwrites by swissnum" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();

    try s.cacheSturdyrefEnlivenment("alpha", .{ .import_position = .from(7), .kind = .promise });
    const first = s.sturdyrefCacheLookup("alpha") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 7), first.far.import_position.int());
    try std.testing.expectEqual(model.RefKind.promise, first.far.kind);
    try std.testing.expect(s.sturdyrefCacheLookup("beta") == null);

    // Idempotent on swissnum: last-wins overwrite, no new row.
    try s.cacheSturdyrefEnlivenment("alpha", .{ .import_position = .from(9), .kind = .object });
    const overwritten = s.sturdyrefCacheLookup("alpha") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 9), overwritten.far.import_position.int());
    try std.testing.expectEqual(model.RefKind.object, overwritten.far.kind);
    try std.testing.expectEqual(@as(usize, 1), s.sturdyref_cache.items.len);
}

test "sturdyref cache evicts the oldest entry past the cap" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .limits = .{ .max_sturdyref_cache_entries = 2 },
    });
    defer s.deinit();

    try s.cacheSturdyrefEnlivenment("a", .{ .import_position = .from(1), .kind = .object });
    try s.cacheSturdyrefEnlivenment("b", .{ .import_position = .from(2), .kind = .object });
    try s.cacheSturdyrefEnlivenment("c", .{ .import_position = .from(3), .kind = .object });

    try std.testing.expect(s.sturdyrefCacheLookup("a") == null);
    try std.testing.expectEqual(@as(u64, 2), s.sturdyrefCacheLookup("b").?.far.import_position.int());
    try std.testing.expectEqual(@as(u64, 3), s.sturdyrefCacheLookup("c").?.far.import_position.int());
}

test "sturdyref cache cap of zero disables caching" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .limits = .{ .max_sturdyref_cache_entries = 0 },
    });
    defer s.deinit();

    try s.cacheSturdyrefEnlivenment("a", .{ .import_position = .from(1), .kind = .object });
    try std.testing.expect(s.sturdyrefCacheLookup("a") == null);
    try std.testing.expectEqual(@as(usize, 0), s.sturdyref_cache.items.len);
}

test "in-flight enliven dedup tracks and clears the outstanding answer" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();

    try std.testing.expectEqual(@as(?model.AnswerPosition, null), s.pendingEnlivenAnswer("a"));
    try s.notePendingEnliven("a", .from(5));
    try std.testing.expectEqual(@as(?model.AnswerPosition, .from(5)), s.pendingEnlivenAnswer("a"));
    try std.testing.expectEqualStrings("a", s.pendingEnlivenSwissnum(.from(5)).?);

    // Idempotent: a second note for the same swissnum keeps the first answer.
    try s.notePendingEnliven("a", .from(99));
    try std.testing.expectEqual(@as(?model.AnswerPosition, .from(5)), s.pendingEnlivenAnswer("a"));
    try std.testing.expectEqualStrings("a", s.pendingEnlivenSwissnum(.from(5)).?);

    s.finishPendingEnliven("a");
    try std.testing.expectEqual(@as(?model.AnswerPosition, null), s.pendingEnlivenAnswer("a"));
    try std.testing.expectEqual(@as(?[]const u8, null), s.pendingEnlivenSwissnum(.from(5)));
}

test "checkEnlivenPreconditions rejects non-negotiated and non-open sessions" {
    const allocator = std.testing.allocator;

    var not_negotiated = session.Session.initWith(allocator, .{
        .captp_version = model.CaptpVersion.next,
        .features = model.FeatureSet{},
    });
    defer not_negotiated.deinit();
    try std.testing.expectError(
        sturdyref.Error.SturdyrefsNotNegotiated,
        sturdyref.checkEnlivenPreconditions(&not_negotiated),
    );

    var negotiating = session.Session.initNegotiating(allocator);
    defer negotiating.deinit();
    try std.testing.expectError(
        sturdyref.Error.SessionNotOpen,
        sturdyref.checkEnlivenPreconditions(&negotiating),
    );

    var open = session.Session.init(allocator);
    defer open.deinit();
    try sturdyref.checkEnlivenPreconditions(&open);
}

test "sturdyrefCacheHit reconstructs the far reference with kind preserved" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();

    try std.testing.expect(sturdyref.sturdyrefCacheHit(&s, "alpha") == null);

    try s.cacheSturdyrefEnlivenment("alpha", .{ .import_position = .from(12), .kind = .promise });
    const hit = sturdyref.sturdyrefCacheHit(&s, "alpha") orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(hit == .far);
    try std.testing.expectEqual(@as(u64, 12), hit.far.import_position.int());
    try std.testing.expectEqual(model.RefKind.promise, hit.far.kind);
}

test "prepareEnliven issues a fresh bootstrap-fetch on a cache miss and marks it in-flight" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();

    const start = try sturdyref.prepareEnliven(allocator, &s, "swiss");
    try std.testing.expect(start == .fresh);
    defer model.freeMessage(allocator, start.fresh.message);

    const deliver = start.fresh.message.deliver;
    try std.testing.expect(deliver.target == .far);
    try std.testing.expectEqual(session.BOOTSTRAP_POSITION, deliver.target.far.import_position.int());
    try std.testing.expectEqualStrings("fetch", deliver.args[0].symbol);
    try std.testing.expectEqualStrings("swiss", deliver.args[1].bytes);
    try std.testing.expectEqual(@as(?model.AnswerPosition, start.fresh.answer_position), s.pendingEnlivenAnswer("swiss"));
}

test "prepareEnliven short-circuits a cached enlivenment without wire traffic" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();

    try s.cacheSturdyrefEnlivenment("swiss", .{ .import_position = .from(4), .kind = .object });
    const start = try sturdyref.prepareEnliven(allocator, &s, "swiss");
    try std.testing.expect(start == .cached);
    try std.testing.expectEqual(@as(u64, 4), start.cached.far.import_position.int());
    // No fetch was issued, so nothing is marked in-flight.
    try std.testing.expectEqual(@as(?model.AnswerPosition, null), s.pendingEnlivenAnswer("swiss"));
}

test "prepareEnliven collapses a concurrent enliven onto the in-flight answer" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();

    const first = try sturdyref.prepareEnliven(allocator, &s, "swiss");
    try std.testing.expect(first == .fresh);
    defer model.freeMessage(allocator, first.fresh.message);

    const second = try sturdyref.prepareEnliven(allocator, &s, "swiss");
    try std.testing.expect(second == .in_flight);
    try std.testing.expectEqual(first.fresh.answer_position, second.in_flight);
}

test "recordEnlivenment caches a fulfilled far reference and clears the in-flight marker" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();

    try s.notePendingEnliven("swiss", .from(9));
    const reference = try sturdyref.recordEnlivenment(allocator, &s, "swiss", .{
        .fulfilled = .{ .far = .{ .import_position = .from(6), .kind = .promise } },
    });
    model.freeReference(allocator, reference);

    try std.testing.expectEqual(@as(?model.AnswerPosition, null), s.pendingEnlivenAnswer("swiss"));
    const cached = s.sturdyrefCacheLookup("swiss") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 6), cached.far.import_position.int());
    try std.testing.expectEqual(model.RefKind.promise, cached.far.kind);
}

test "recordEnlivenment fails loud on a broken settlement and clears the marker" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();

    try s.notePendingEnliven("swiss", .from(9));
    try std.testing.expectError(sturdyref.Error.EnlivenmentBroke, sturdyref.recordEnlivenment(
        allocator,
        &s,
        "swiss",
        .{ .broken = try allocator.dupe(u8, "unknown swissnum") },
    ));
    // The marker is cleared even on failure, and nothing is cached.
    try std.testing.expectEqual(@as(?model.AnswerPosition, null), s.pendingEnlivenAnswer("swiss"));
    try std.testing.expect(s.sturdyrefCacheLookup("swiss") == null);
}

test "enliven round-trips over the wire, then a repeat enliven hits the cache" {
    const allocator = std.testing.allocator;
    var p1 = engine.Peer.init(allocator);
    defer p1.deinit();
    var p2 = engine.Peer.init(allocator);
    defer p2.deinit();

    // p1 addresses p2's bootstrap (import 0), always reachable on an open
    // session, no explicit import needed; p2 holds it as export 0.
    try p2.session_state.registerExport(.from(session.BOOTSTRAP_POSITION));
    // Register the cap the enliven looks up so the runtime's auto-serve fulfills
    // the inbound bootstrap-fetch. p2 exports it; p1 imports it at the same id.
    const cap_export = try p2.registerBootstrapCap("swiss");

    const ref = "swiss";
    const start = try sturdyref.prepareEnliven(allocator, &p1.session_state, ref);
    try std.testing.expect(start == .fresh);
    const answer_position = start.fresh.answer_position;
    const resolver_export = start.fresh.resolver_export;
    try p1.send(start.fresh.message);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    try p2.feedOwned(p1.takeOutbound().?);
    // This step dispatches the inbound fetch: it surfaces the deliver event AND
    // enqueues the synthesized resolve onto p2's pending_send.
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    {
        var fetch_event = p2.pollEvent().?;
        fetch_event.deinit();
    }

    // A subsequent step encodes the auto-served resolve onto the outbound queue.
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    try p1.feedOwned(p2.takeOutbound().?);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());

    var resolve_event = p1.pollEvent().?;
    defer resolve_event.deinit();
    const msg = try resolve_event.decodeOwned(allocator);
    const match = try fetch.tryMatchFetchOutcome(allocator, resolver_export, answer_position, msg);
    try std.testing.expect(match == .settled);

    // The auto-serve fulfills with the cap p2 registered for "swiss" (its
    // export); the codec's perspective flip lands it on p1 as a far import of
    // that export, which `recordEnlivenment` caches.
    const enlivened = try sturdyref.recordEnlivenment(allocator, &p1.session_state, ref, match.settled);
    model.freeReference(allocator, enlivened);
    try std.testing.expectEqual(cap_export, enlivened.far.import_position.int());
    try std.testing.expectEqual(@as(?model.AnswerPosition, null), p1.session_state.pendingEnlivenAnswer("swiss"));

    // A repeat enliven now short-circuits to the cached reference, no wire traffic.
    const cached = try sturdyref.prepareEnliven(allocator, &p1.session_state, ref);
    try std.testing.expect(cached == .cached);
    try std.testing.expectEqual(cap_export, cached.cached.far.import_position.int());
    try std.testing.expectEqual(model.RefKind.object, cached.cached.far.kind);

    // The repeat enliven reuses the same session-local import row. This does not
    // exercise a handoff or prove target identity across two network paths.
    try std.testing.expect(model.referencesStructurallyEqual(enlivened, cached.cached));
    try std.testing.expect(model.referencesStructurallyEqual(cached.cached, .{ .far = .{ .import_position = .from(cap_export), .kind = .object } }));
}
