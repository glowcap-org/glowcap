const std = @import("std");
const pancake = @import("pancake");

const model = pancake.model;
const engine = pancake.engine;
const session = pancake.session;

const sturdyref = engine.sturdyref;
const fetch = engine.fetch;

fn sampleSturdyref(swissnum: []const u8) model.SturdyRef {
    return .{
        .peer = .{ .transport = "memory", .designator = "remote-host" },
        .swissnum = swissnum,
    };
}

test "sturdyref cache stores, reconstructs, and overwrites by swissnum" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();

    try s.cacheSturdyrefEnlivenment("alpha", 7, .promise);
    try std.testing.expectEqual(@as(?u64, 7), s.sturdyrefImportFor("alpha"));
    try std.testing.expectEqual(@as(?model.ImportKind, .promise), s.sturdyrefKindFor("alpha"));
    try std.testing.expectEqual(@as(?u64, null), s.sturdyrefImportFor("beta"));

    // Idempotent on swissnum: last-wins overwrite, no new row.
    try s.cacheSturdyrefEnlivenment("alpha", 9, .object);
    try std.testing.expectEqual(@as(?u64, 9), s.sturdyrefImportFor("alpha"));
    try std.testing.expectEqual(@as(?model.ImportKind, .object), s.sturdyrefKindFor("alpha"));
    try std.testing.expectEqual(@as(usize, 1), s.sturdyref_cache.items.len);
}

test "sturdyref cache evicts the oldest entry past the cap" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    s.limits.max_sturdyref_cache_entries = 2;

    try s.cacheSturdyrefEnlivenment("a", 1, .object);
    try s.cacheSturdyrefEnlivenment("b", 2, .object);
    try s.cacheSturdyrefEnlivenment("c", 3, .object);

    try std.testing.expectEqual(@as(?u64, null), s.sturdyrefImportFor("a"));
    try std.testing.expectEqual(@as(?u64, 2), s.sturdyrefImportFor("b"));
    try std.testing.expectEqual(@as(?u64, 3), s.sturdyrefImportFor("c"));
}

test "sturdyref cache cap of zero disables caching" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    s.limits.max_sturdyref_cache_entries = 0;

    try s.cacheSturdyrefEnlivenment("a", 1, .object);
    try std.testing.expectEqual(@as(?u64, null), s.sturdyrefImportFor("a"));
    try std.testing.expectEqual(@as(usize, 0), s.sturdyref_cache.items.len);
}

test "in-flight enliven dedup tracks and clears the outstanding answer" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();

    try std.testing.expectEqual(@as(?u64, null), s.pendingEnlivenAnswer("a"));
    try s.notePendingEnliven("a", 5);
    try std.testing.expectEqual(@as(?u64, 5), s.pendingEnlivenAnswer("a"));

    // Idempotent: a second note for the same swissnum keeps the first answer.
    try s.notePendingEnliven("a", 99);
    try std.testing.expectEqual(@as(?u64, 5), s.pendingEnlivenAnswer("a"));

    s.finishPendingEnliven("a");
    try std.testing.expectEqual(@as(?u64, null), s.pendingEnlivenAnswer("a"));
}

test "checkEnlivenPreconditions rejects non-negotiated and non-open sessions" {
    const allocator = std.testing.allocator;

    var not_negotiated = session.Session.initWith(allocator, .{
        .wire_profile = model.WireProfile.pre_spec,
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

    try std.testing.expect(sturdyref.sturdyrefCacheHit(&s, sampleSturdyref("alpha")) == null);

    try s.cacheSturdyrefEnlivenment("alpha", 12, .promise);
    const hit = sturdyref.sturdyrefCacheHit(&s, sampleSturdyref("alpha")) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(hit == .far);
    try std.testing.expectEqual(@as(u64, 12), hit.far.import_id);
    try std.testing.expectEqual(model.ImportKind.promise, hit.far.kind);
}

test "prepareEnliven issues a fresh bootstrap-fetch on a cache miss and marks it in-flight" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();

    const start = try sturdyref.prepareEnliven(allocator, &s, sampleSturdyref("swiss"));
    try std.testing.expect(start == .fresh);
    defer model.freeMessage(allocator, start.fresh.message);

    const deliver = start.fresh.message.deliver;
    try std.testing.expect(deliver.target == .far);
    try std.testing.expectEqual(session.BOOTSTRAP_EXPORT_ID, deliver.target.far.import_id);
    try std.testing.expectEqualStrings("fetch", deliver.args[0].symbol);
    try std.testing.expectEqualStrings("swiss", deliver.args[1].bytes);
    try std.testing.expectEqual(@as(?u64, start.fresh.answer_id), s.pendingEnlivenAnswer("swiss"));
}

test "prepareEnliven short-circuits a cached enlivenment without wire traffic" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();

    try s.cacheSturdyrefEnlivenment("swiss", 4, .object);
    const start = try sturdyref.prepareEnliven(allocator, &s, sampleSturdyref("swiss"));
    try std.testing.expect(start == .cached);
    try std.testing.expectEqual(@as(u64, 4), start.cached.far.import_id);
    // No fetch was issued, so nothing is marked in-flight.
    try std.testing.expectEqual(@as(?u64, null), s.pendingEnlivenAnswer("swiss"));
}

test "prepareEnliven collapses a concurrent enliven onto the in-flight answer" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();

    const first = try sturdyref.prepareEnliven(allocator, &s, sampleSturdyref("swiss"));
    try std.testing.expect(first == .fresh);
    defer model.freeMessage(allocator, first.fresh.message);

    const second = try sturdyref.prepareEnliven(allocator, &s, sampleSturdyref("swiss"));
    try std.testing.expect(second == .in_flight);
    try std.testing.expectEqual(first.fresh.answer_id, second.in_flight);
}

test "recordEnlivenment caches a fulfilled far reference and clears the in-flight marker" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();

    try s.notePendingEnliven("swiss", 9);
    const reference = try sturdyref.recordEnlivenment(allocator, &s, "swiss", .{
        .fulfilled = .{ .far = .{ .import_id = 6, .kind = .promise } },
    });
    model.freeReference(allocator, reference);

    try std.testing.expectEqual(@as(?u64, null), s.pendingEnlivenAnswer("swiss"));
    try std.testing.expectEqual(@as(?u64, 6), s.sturdyrefImportFor("swiss"));
    try std.testing.expectEqual(@as(?model.ImportKind, .promise), s.sturdyrefKindFor("swiss"));
}

test "recordEnlivenment fails loud on a broken settlement and clears the marker" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();

    try s.notePendingEnliven("swiss", 9);
    try std.testing.expectError(sturdyref.Error.EnlivenmentBroke, sturdyref.recordEnlivenment(
        allocator,
        &s,
        "swiss",
        .{ .broken = try allocator.dupe(u8, "unknown swissnum") },
    ));
    // The marker is cleared even on failure, and nothing is cached.
    try std.testing.expectEqual(@as(?u64, null), s.pendingEnlivenAnswer("swiss"));
    try std.testing.expectEqual(@as(?u64, null), s.sturdyrefImportFor("swiss"));
}

test "enliven round-trips over the wire, then a repeat enliven hits the cache" {
    const allocator = std.testing.allocator;
    var p1 = engine.Peer.init(allocator);
    defer p1.deinit();
    var p2 = engine.Peer.init(allocator);
    defer p2.deinit();

    // p1 addresses p2's bootstrap (import 0) — always reachable on an open
    // session, no explicit import needed; p2 holds it as export 0.
    try p2.session_state.registerExport(session.BOOTSTRAP_EXPORT_ID);
    // Register the cap the enliven looks up so the runtime's auto-serve fulfills
    // the inbound bootstrap-fetch. p2 exports it; p1 imports it at the same id.
    const cap_export = try p2.registerBootstrapCap("swiss");

    const ref = sampleSturdyref("swiss");
    const start = try sturdyref.prepareEnliven(allocator, &p1.session_state, ref);
    try std.testing.expect(start == .fresh);
    const answer_id = start.fresh.answer_id;
    const resolver_export = start.fresh.resolver_export;
    try p1.send(start.fresh.message);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    try p2.feedInbound(p1.takeOutbound().?);
    // This step dispatches the inbound fetch: it surfaces the deliver event AND
    // enqueues the synthesized resolve onto p2's pending_send.
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    {
        var fetch_event = p2.pollEvent().?;
        fetch_event.deinit();
    }

    // A subsequent step encodes the auto-served resolve onto the outbound queue.
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    try p1.feedInbound(p2.takeOutbound().?);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());

    var resolve_event = p1.pollEvent().?;
    defer resolve_event.deinit();
    const msg = try resolve_event.decodeOwned(allocator);
    const match = try fetch.tryMatchFetchOutcome(allocator, resolver_export, answer_id, msg);
    try std.testing.expect(match == .settled);

    // The auto-serve fulfills with the cap p2 registered for "swiss" (its
    // export); the codec's perspective flip lands it on p1 as a far import of
    // that export, which `recordEnlivenment` caches.
    const enlivened = try sturdyref.recordEnlivenment(allocator, &p1.session_state, ref.swissnum, match.settled);
    model.freeReference(allocator, enlivened);
    try std.testing.expectEqual(cap_export, enlivened.far.import_id);
    try std.testing.expectEqual(@as(?u64, null), p1.session_state.pendingEnlivenAnswer("swiss"));

    // A repeat enliven now short-circuits to the cached reference, no wire traffic.
    const cached = try sturdyref.prepareEnliven(allocator, &p1.session_state, ref);
    try std.testing.expect(cached == .cached);
    try std.testing.expectEqual(cap_export, cached.cached.far.import_id);
    try std.testing.expectEqual(model.ImportKind.object, cached.cached.far.kind);

    // Pass Invariant Equality (ADR-0012): the repeat enliven returns a target
    // equal to the first, and equal to the far-ref a handoff arrival of the same
    // import would land — same-session equality on (import_id, kind).
    try std.testing.expect(model.referencesEqual(enlivened, cached.cached));
    try std.testing.expect(model.referencesEqual(cached.cached, .{ .far = .{ .import_id = cap_export, .kind = .object } }));
}
