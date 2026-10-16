//! The V1.0 resolver links and the pipelining substrate: resolver-callback
//! links record, query, and drop with gc-answers, a linked resolver's retain
//! is the session's to release, queued calls and listeners are owned and
//! capped loudly, and a resolver purpose replaces its collision in both
//! directions. The imported-promise store and shortening live in
//! `imported_promise_test.zig`.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const session = glowcap.ocapn.session;
const syrup = glowcap.ocapn.codec.syrup;
const capnp = glowcap.ocapn.codec.capnp;

const harness = @import("session_harness.zig");
const startSessionMessage = harness.startSessionMessage;
const startSessionMessageWithKey = harness.startSessionMessageWithKey;

test "V1.0 outbound resolver export is reclaimed when its answer is gc'd, not leaked to teardown" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerImport(.from(7));

    // An answered deliver we send, so its answer exists to carry a resolver.
    try s.recordSend(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(7) } },
        .args = &.{.{ .bytes = "hi" }},
        .answer = .from(42),
    } });

    // Mint the V1.0 resolver export for that answer: `allocateExport`'s base
    // count-1 plus the wire mention's retain is count 2.
    const resolver = try s.mintOutboundResolver(.from(42));
    try std.testing.expectEqual(@as(u64, 2), s.exports.count(resolver));

    // The partner GCs its one wire mention. The base reference still floats, so
    // the partner's GC alone cannot reclaim the export.
    try s.recordRecv(.{ .gc_export = .{
        .positions = &.{resolver.int()},
        .deltas = &.{1},
    } });
    try std.testing.expect(s.hasExport(resolver));
    try std.testing.expectEqual(@as(u64, 1), s.exports.count(resolver));

    // We GC the answer. Its resolver can never fire again, so the base
    // reference is released and the export is reclaimed here, not left floating
    // until session teardown (the leak this pins).
    try s.recordSend(.{ .gc_answer = .{ .positions = &.{42} } });
    try std.testing.expect(!s.hasExport(resolver));
}

test "v1.0 session records and queries resolver-callback links" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .captp_version = model.CaptpVersion.v1_0,
        .features = model.FeatureSet.full(),
    });
    defer s.deinit();

    try std.testing.expect(s.needsV1_0Translation());

    // Outbound: our answer 42 resolves via our local resolver export 7.
    try s.installOutboundResolver(.from(42), .from(7));
    try std.testing.expectEqual(@as(?model.AnswerPosition, .from(42)), s.answerForResolverExport(.from(7)));
    try std.testing.expectEqual(@as(?model.AnswerPosition, null), s.answerForResolverExport(.from(8)));

    // Inbound: the partner's answer 99 resolves via their resolver import 3.
    try s.installInboundResolver(.fromWire(.from(99)), .from(3));
    try std.testing.expectEqual(@as(?model.ImportPosition, .from(3)), s.resolverForInboundAnswer(.fromWire(.from(99))));
    try std.testing.expectEqual(@as(?model.ImportPosition, null), s.resolverForInboundAnswer(.fromWire(.from(100))));
    // The inverse link is queryable too, keyed by the resolver import.
    try std.testing.expectEqual(@as(?model.AnswerName, .fromWire(.from(99))), s.answerForResolverImport(.from(3)));
}

test "v1.0 inbound resolver links never evict accepted authority" {
    var s = session.Session.initWith(std.testing.allocator, .{
        .captp_version = .v1_0,
        .features = model.FeatureSet.full(),
    });
    defer s.deinit();

    const first_answer = model.AnswerName.fromWire(.from(41));
    try s.installInboundResolver(first_answer, .from(7));

    try std.testing.expectError(
        session.Error.UnexpectedMessage,
        s.installInboundResolver(first_answer, .from(8)),
    );
    try std.testing.expectError(
        session.Error.UnexpectedMessage,
        s.installInboundResolver(.fromWire(.from(42)), .from(7)),
    );

    try std.testing.expectEqual(
        @as(?model.ImportPosition, .from(7)),
        s.resolverForInboundAnswer(first_answer),
    );
    try std.testing.expectEqual(@as(?model.AnswerName, first_answer), s.answerForResolverImport(.from(7)));
    try std.testing.expectEqual(@as(u64, 1), s.importRefcount(.from(7)));
    try std.testing.expect(!s.hasImport(.from(8)));
}

test "nominateResolverExport installs the answer it hands back, so no caller can order it after the send" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{ .features = model.FeatureSet.full() });
    defer s.deinit();

    const nomination = try s.nominateResolverExport();

    // All three rows are live before the verb returns: the export, the answer,
    // and both directions of the link binding them.
    try std.testing.expectEqual(@as(u64, 1), s.exportRefcount(nomination.resolver_export));
    try std.testing.expect(s.outbound_answers.contains(nomination.answer));
    try std.testing.expectEqual(
        @as(?model.AnswerPosition, nomination.answer),
        s.answerForResolverExport(nomination.resolver_export),
    );
    try std.testing.expectEqual(
        @as(?model.ExportPosition, nomination.resolver_export),
        s.outbound_resolver_link.getByValue(.{ .application_answer = nomination.answer }),
    );

    // A second nomination shares nothing with the first.
    const second = try s.nominateResolverExport();
    try std.testing.expect(second.resolver_export != nomination.resolver_export);
    try std.testing.expect(second.answer != nomination.answer);

    // And abandoning one takes its export, its link, and its answer row away,
    // leaving the other nomination whole.
    s.abandonResolverNomination(nomination);
    try std.testing.expectEqual(@as(u64, 0), s.exportRefcount(nomination.resolver_export));
    try std.testing.expect(!s.outbound_answers.contains(nomination.answer));
    try std.testing.expectEqual(
        @as(?model.AnswerPosition, null),
        s.answerForResolverExport(nomination.resolver_export),
    );
    try std.testing.expectEqual(
        @as(?model.AnswerPosition, second.answer),
        s.answerForResolverExport(second.resolver_export),
    );
    try std.testing.expect(s.outbound_answers.contains(second.answer));
}

test "v1.0 gc-answers drops both directions of the inbound resolver link" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .captp_version = model.CaptpVersion.v1_0,
        .features = model.FeatureSet.full(),
    });
    defer s.deinit();

    // The partner delivers to our export 1, opening inbound answer 99, and we
    // record resolver import 3 as its resolve-me target (both link directions).
    try s.registerExport(.from(1));
    try s.recordRecv(.{ .deliver = .{
        .target = .{ .near = .{ .export_position = .from(1) } },
        .args = &.{},
        .answer = .from(99),
    } });
    try s.installInboundResolver(.fromWire(.from(99)), .from(3));
    try std.testing.expectEqual(@as(?model.ImportPosition, .from(3)), s.resolverForInboundAnswer(.fromWire(.from(99))));
    try std.testing.expectEqual(@as(?model.AnswerName, .fromWire(.from(99))), s.answerForResolverImport(.from(3)));

    // The partner GCs the answer: the forward map and its inverse drop together,
    // so a long-lived session never accumulates orphaned reverse-link rows.
    try s.recordRecv(.{ .gc_answer = .{ .positions = &.{99} } });
    try std.testing.expectEqual(@as(?model.ImportPosition, null), s.resolverForInboundAnswer(.fromWire(.from(99))));
    try std.testing.expectEqual(@as(?model.AnswerName, null), s.answerForResolverImport(.from(3)));
}

test "v1.0 borrowed inbound raw resolve is rejected" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .captp_version = model.CaptpVersion.v1_0,
        .features = model.FeatureSet.full(),
    });
    defer s.deinit();
    try s.registerImport(.from(7));
    try s.recordSend(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(7) } },
        .args = &.{},
        .answer = .from(11),
    } });
    const message = model.Message{ .resolve = .{
        .answer = .from(11),
        .resolution = .{ .fulfill = .{ .void = {} } },
    } };
    try std.testing.expectError(session.Error.UnexpectedMessage, s.recordRecvView(model.view.Body.fromOwned(&message)));
}

test "pipelining substrate owns queued calls, listeners, and stored resolution" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();

    // A pending inbound answer (#5), created via an inbound deliver to our
    // export 1 (post-flip `.near`). Export 1 hosts the deliver target; import 1
    // backs the `.far` listener target installed below.
    try s.registerExport(.from(1));
    try s.retainImportForSession(.from(1));
    try s.recordRecv(.{ .deliver = .{
        .target = .{ .near = .{ .export_position = .from(1) } },
        .args = &.{},
        .answer = .from(5),
    } });
    try std.testing.expect(!s.answerResolved(.from(5)));

    // Queue two pipelined calls; the session takes ownership of each.
    try s.enqueuePipelinedCall(.from(5), .{ .abort = .{ .kind = .other, .message = try allocator.dupe(u8, "a") } });
    try s.enqueuePipelinedCall(.from(5), .{ .abort = .{ .kind = .other, .message = try allocator.dupe(u8, "b") } });

    // Queueing against an unknown answer is rejected and frees the message
    // (the testing allocator would flag a leak otherwise).
    try std.testing.expectError(error.InvalidReference, s.enqueuePipelinedCall(
        .from(99),
        .{ .abort = .{ .kind = .other, .message = try allocator.dupe(u8, "z") } },
    ));

    // A listener (POD listener cap) and a stored resolution.
    try s.installListener(.from(5), .{ .listener = .{ .import_position = .from(1) }, .mode = .settling_only });
    try s.storeResolution(.from(5), .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "v") } });
    try std.testing.expect(s.answerResolved(.from(5)));
    const peeked = s.peekResolution(.from(5)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(peeked.* == .fulfill);

    // Drain transfers ownership of the queued calls to the caller; a second
    // drain is empty.
    const drained = try s.takePipelinedCalls(.from(5));
    defer {
        for (drained) |call| call.deinit(allocator);
        allocator.free(drained);
    }
    try std.testing.expectEqual(@as(usize, 2), drained.len);
    const empty = try s.takePipelinedCalls(.from(5));
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    // Draining listeners likewise empties the list (entries are POD; only the
    // slice is owned); a second drain is empty.
    const listeners = try s.takePipelinedListeners(.from(5));
    defer allocator.free(listeners);
    try std.testing.expectEqual(@as(usize, 1), listeners.len);
    try std.testing.expectEqual(@as(usize, 0), (try s.takePipelinedListeners(.from(5))).len);
}

test "pipelining caps fail loud rather than silently dropping" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .limits = .{ .queue_cap = 2, .max_listeners_per_target = 1 },
    });
    defer s.deinit();

    // Export 1 hosts the inbound deliver target (post-flip `.near`); import 1
    // backs the `.far` listener target.
    try s.registerExport(.from(1));
    try s.retainImportForSession(.from(1));
    try s.recordRecv(.{ .deliver = .{
        .target = .{ .near = .{ .export_position = .from(1) } },
        .args = &.{},
        .answer = .from(7),
    } });

    try s.enqueuePipelinedCall(.from(7), .{ .abort = .{ .kind = .other, .message = try allocator.dupe(u8, "1") } });
    try s.enqueuePipelinedCall(.from(7), .{ .abort = .{ .kind = .other, .message = try allocator.dupe(u8, "2") } });
    try std.testing.expectError(error.QueueCapExceeded, s.enqueuePipelinedCall(
        .from(7),
        .{ .abort = .{ .kind = .other, .message = try allocator.dupe(u8, "3") } },
    ));

    try s.installListener(.from(7), .{ .listener = .{ .import_position = .from(1) }, .mode = .settling_only });
    try std.testing.expectError(error.ListenerCapExceeded, s.installListener(
        .from(7),
        .{ .listener = .{ .import_position = .from(1) }, .mode = .settling_only },
    ));
}

test "outbound gc-export cannot spend the retain a linked resolver keeps" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .captp_version = .v1_0,
        .features = model.FeatureSet.full(),
    });
    defer s.deinit();
    try s.registerExport(.from(1));
    const answer = model.AnswerName.fromWire(.from(99));
    try s.recordRecv(.{ .deliver = .{
        .target = .{ .near = model.NearRef.object(1) },
        .args = &.{},
        .answer = answer.wire,
    } });
    try s.installInboundResolver(answer, .from(3));

    // The link's own retain is not a caller's to release: the settlement still
    // has to address this row.
    try std.testing.expectError(error.GcUnderflow, s.recordSend(.{ .gc_export = .{ .positions = &.{3}, .deltas = &.{1} } }));
    // A caller's own retain on the same import is, and only that one.
    try s.registerImport(.from(3));
    try std.testing.expectError(error.GcUnderflow, s.recordSend(.{ .gc_export = .{ .positions = &.{3}, .deltas = &.{2} } }));
    try s.recordSend(.{ .gc_export = .{ .positions = &.{3}, .deltas = &.{1} } });
    try std.testing.expect(s.resolverForInboundAnswer(answer) != null);
    try std.testing.expect(s.hasImport(.from(3)));
}

test "next session needs no v1.0 resolver translation" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .captp_version = model.CaptpVersion.next,
    });
    defer s.deinit();
    try std.testing.expect(!s.needsV1_0Translation());
}

test "gc-answers retires a resolver until its wire mention is released" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .captp_version = model.CaptpVersion.v1_0,
        .features = model.FeatureSet.full(),
    });
    defer s.deinit();
    try s.registerImport(.from(7));

    // Send a question (answer 5) and commit its resolver export, as the runtime
    // does when augmenting the outbound deliver.
    try s.recordSend(.{
        .deliver = .{
            .target = .{ .far = .{ .import_position = .from(7) } },
            .args = &.{.{ .bytes = "hello" }},
            .answer = .from(5),
        },
    });
    const resolver = try s.mintMentionedResolverExport(.from(5), .object);
    try std.testing.expectEqual(@as(?model.AnswerPosition, .from(5)), s.answerForResolverExport(resolver));
    try std.testing.expectEqual(@as(u64, 2), s.exportRefcount(resolver));

    // We allocated the question, so we are the side that GCs it: sending
    // `op:gc-answers` for our own answer-pos releases the outbound answer. The
    // resolver remains addressable for one callback already in flight, and its
    // local baseline remains until the partner releases the wire mention.
    try s.recordSend(.{ .gc_answer = .{ .positions = &.{5} } });
    try std.testing.expectEqual(@as(?model.AnswerPosition, null), s.answerForResolverExport(resolver));
    try std.testing.expectEqual(session.RetiredResolverState.pending, s.retiredResolverState(resolver).?);
    try std.testing.expectEqual(@as(u64, 2), s.exportRefcount(resolver));

    try s.recordRecv(.{ .gc_export = .{
        .positions = &.{resolver.int()},
        .deltas = &.{1},
    } });
    try std.testing.expectEqual(@as(u64, 0), s.exportRefcount(resolver));
    try std.testing.expect(s.retiredResolverState(resolver) == null);
}

fn sendRequiredShortening(s: *session.Session, position: model.ImportPosition) !void {
    const nomination = (try s.nominateShorteningResolver(position)).?;
    try s.recordSend(.{ .listen = .{
        .target = .{ .far = model.FarRef.promise(position.int()) },
        .listener = session.slot.toReference(s.exportSlot(nomination.resolver_export).?).?,
        .mode = .shortening_only,
    } });
}

test "Node listener teardown releases an already returned wire mention" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .captp_version = .next,
    });
    defer s.deinit();
    try s.installThirdPartyImport(.from(5), "home");

    try sendRequiredShortening(&s, .from(5));
    const listener = try s.allocateExport();
    try std.testing.expect(try s.claimPromiseSettlingListener(.from(5), listener, null));
    try s.recordSend(.{ .listen = .{
        .target = .{ .far = model.FarRef.promise(5) },
        .listener = session.slot.toReference(s.exportSlot(listener).?).?,
        .mode = .settling_only,
    } });
    try std.testing.expectEqual(@as(u64, 2), s.exportRefcount(listener));

    try s.recordRecv(.{ .gc_export = .{
        .positions = &.{listener.int()},
        .deltas = &.{1},
    } });
    try std.testing.expectEqual(@as(u64, 1), s.exportRefcount(listener));

    const source = s.shorteningIncarnationForImport(.from(5)).?;
    s.detachPromiseSettlingNodeConsumer(source, listener);
    try std.testing.expect(s.exportSlot(listener) == null);
    try std.testing.expect(s.retiredResolverState(listener) == null);
    try std.testing.expect(!s.promiseSettlingListenerClaimed(source));
}

test "settling convergence releases an already returned source listener" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .captp_version = .next,
    });
    defer s.deinit();
    try s.installThirdPartyImport(.from(5), "home");
    try s.installThirdPartyImport(.from(6), "home");

    try sendRequiredShortening(&s, .from(5));
    try sendRequiredShortening(&s, .from(6));
    const source_nomination = try s.nominateResolverExport();
    try std.testing.expect(try s.claimPromiseSettlingListener(
        .from(5),
        source_nomination.resolver_export,
        source_nomination.answer,
    ));
    try s.recordSend(.{ .listen = .{
        .target = .{ .far = model.FarRef.promise(5) },
        .listener = session.slot.toReference(s.exportSlot(source_nomination.resolver_export).?).?,
        .mode = .settling_only,
    } });

    const target_nomination = try s.nominateResolverExport();
    try std.testing.expect(try s.claimPromiseSettlingListener(
        .from(6),
        target_nomination.resolver_export,
        target_nomination.answer,
    ));
    try s.recordSend(.{ .listen = .{
        .target = .{ .far = model.FarRef.promise(6) },
        .listener = session.slot.toReference(s.exportSlot(target_nomination.resolver_export).?).?,
        .mode = .settling_only,
    } });

    try s.recordRecv(.{ .gc_export = .{
        .positions = &.{source_nomination.resolver_export.int()},
        .deltas = &.{1},
    } });
    try std.testing.expectEqual(@as(u64, 1), s.exportRefcount(source_nomination.resolver_export));

    const source = s.shorteningIncarnationForImport(.from(5)).?;
    var move = try s.preparePromiseSettlingMove(source, .from(6));
    defer move.deinit(allocator);
    s.commitPromiseSettlingMove(&move);

    try std.testing.expect(s.exportSlot(source_nomination.resolver_export) == null);
    try std.testing.expect(s.retiredResolverState(source_nomination.resolver_export) == null);
    try std.testing.expectEqual(
        target_nomination.resolver_export,
        s.outbound_resolver_link.getByValue(.{ .application_answer = target_nomination.answer }).?,
    );
}

test "V1.0 accepts inbound untag but requires explicit peer support outbound" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{ .captp_version = .v1_0 });
    defer s.deinit();
    try s.registerImport(.from(1));
    try s.registerExport(.from(2));

    const outbound = model.Message{ .untag = .{
        .receiver = .{ .far = model.FarRef.object(1) },
        .tag = "cm",
        .answer = .from(7),
    } };
    s.features.untag = false;
    try std.testing.expectError(session.Error.FeatureNotNegotiated, s.recordSend(outbound));
    try std.testing.expect(s.outboundAnswer(.from(7)) == null);

    const inbound = model.Message{ .untag = .{
        .receiver = .{ .near = model.NearRef.object(2) },
        .tag = "cm",
        .answer = .from(8),
    } };
    try s.recordRecv(inbound);
    try std.testing.expect(s.inboundAnswer(.from(8)) != null);

    s.features.untag = true;
    try s.recordSend(outbound);
    try std.testing.expect(s.outboundAnswer(.from(7)) != null);
}

test "resolver purpose replacement evicts a colliding resolver in both directions" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();

    const first = try s.allocateExport();
    const second = try s.allocateExport();
    const source_five: session.PromiseIncarnation = .{ .position = .from(5), .row_id = 1 };
    const source_six: session.PromiseIncarnation = .{ .position = .from(6), .row_id = 2 };
    try s.outbound_resolver_link.put(allocator, first, .{ .shortening_pending = source_five });
    try s.outbound_resolver_link.put(allocator, second, .{ .shortening_pending = source_six });

    s.outbound_resolver_link.replaceValueForKey(first, .{ .shortening_pending = source_six });

    try std.testing.expectEqual(
        session.ResolverPurpose{ .shortening_pending = source_six },
        s.outbound_resolver_link.getByKey(first).?,
    );
    try std.testing.expectEqual(
        @as(?model.ExportPosition, first),
        s.outbound_resolver_link.getByValue(.{ .shortening_pending = source_six }),
    );
    try std.testing.expect(s.outbound_resolver_link.getByKey(second) == null);
    try std.testing.expect(s.outbound_resolver_link.getByValue(.{ .shortening_pending = source_five }) == null);
}

test "resolver purpose identity preserves authority and excludes lifetime bookkeeping" {
    // The purpose side of the outbound link is keyed on these words, so two
    // purposes that differ in authority must differ in some word, or the
    // table answers one purpose's lookup with the other's export.
    const one: session.PromiseIncarnation = .{ .position = .from(1), .row_id = 1 };
    const one_reincarnated: session.PromiseIncarnation = .{ .position = .from(1), .row_id = 2 };
    const two: session.PromiseIncarnation = .{ .position = .from(2), .row_id = 1 };
    const distinct = [_]session.ResolverPurpose{
        .{ .application_answer = .from(1) },
        .{ .application_answer = .from(2) },
        .{ .local_promise_answer = .{ .name = .{ .wire = .from(1) } } },
        .{ .local_promise_answer = .{ .name = .{ .virtual = .from(1) } } },
        .{ .node_settling = .{ .resolver_export = .from(1) } },
        .{ .node_settling = .{ .resolver_export = .from(2) } },
        .{ .node_settling = .{ .resolver_export = .from(1), .settling_source = one } },
        .{ .node_settling = .{ .resolver_export = .from(1), .settling_source = one_reincarnated } },
        .{ .node_settling = .{ .resolver_export = .from(1), .settling_source = two } },
        .{ .retired = .{ .resolver_export = .from(1), .state = .pending } },
        .{ .retired = .{ .resolver_export = .from(1), .state = .complete } },
        .{ .retired = .{ .resolver_export = .from(2), .state = .pending } },
        .{ .retired = .{ .resolver_export = .from(1), .settling_source = one, .state = .pending } },
        .{ .retired = .{ .resolver_export = .from(1), .settling_source = one_reincarnated, .state = .pending } },
        .{ .retired = .{ .resolver_export = .from(1), .settling_source = one, .state = .complete } },
        .{ .shortening_pending = one },
        .{ .shortening_pending = one_reincarnated },
        .{ .shortening_pending = two },
        .{ .shortening_complete = one },
        .{ .shortening_complete = one_reincarnated },
    };
    const identity_hash = glowcap.foundation.identity_hash;
    const pristine: session.ResolverPurpose = .{ .local_promise_answer = .{ .name = .{ .virtual = .from(1) } } };
    var tracing = pristine;
    tracing.local_promise_answer.gc_mark = true;
    tracing.local_promise_answer.gc_next = .from(123);
    tracing.local_promise_answer.staging_owners = 2;
    try std.testing.expect(identity_hash.eql(pristine, tracing));
    try std.testing.expectEqualSlices(u64, &identity_hash.words(pristine), &identity_hash.words(tracing));
    for (distinct, 0..) |left, i| {
        try std.testing.expect(identity_hash.eql(left, left));
        for (distinct[i + 1 ..]) |right| {
            try std.testing.expect(!identity_hash.eql(left, right));
            try std.testing.expect(!std.mem.eql(u64, &identity_hash.words(left), &identity_hash.words(right)));
        }
    }
}

test "next sender subscriptions enforce disjoint modes for each promise incarnation" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{ .captp_version = .next });
    defer s.deinit();
    try s.installThirdPartyImport(.from(7), "remote");
    try s.registerExport(.from(9));
    var listen = model.Message{ .listen = .{
        .target = .{ .far = model.FarRef.promise(7) },
        .listener = .{ .near = model.NearRef.object(9) },
        .mode = .settling_only,
    } };
    const before = s.exportRefcount(.from(9));
    try std.testing.expectError(error.UnexpectedMessage, s.recordSend(listen));
    try std.testing.expectEqual(before, s.exportRefcount(.from(9)));
    listen.listen.mode = .shortening_only;
    try s.recordSend(listen);
    try std.testing.expectError(error.UnexpectedMessage, s.recordSend(listen));
    listen.listen.mode = .shortening_or_settling;
    try std.testing.expectError(error.UnexpectedMessage, s.recordSend(listen));
    listen.listen.mode = .settling_only;
    try s.recordSend(listen);
    try std.testing.expectError(error.UnexpectedMessage, s.recordSend(listen));
    // Co-eviction ends the promise incarnation, permitting a fresh mode-3
    // subscription when the same position is introduced again.
    try s.recordSend(.{ .gc_export = .{ .positions = &.{7}, .deltas = &.{1} } });
    try s.installThirdPartyImport(.from(7), "remote");
    listen.listen.mode = .shortening_or_settling;
    try s.recordSend(listen);
    try std.testing.expectError(error.UnexpectedMessage, s.recordSend(listen));

    try s.recordSend(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &.{},
        .answer = .from(42),
        .listen_mode = .shortening_only,
    } });
    listen.listen.target = .{ .promise = .{ .answer_position = .from(42) } };
    listen.listen.mode = .shortening_only;
    try std.testing.expectError(error.UnexpectedMessage, s.recordSend(listen));
    listen.listen.mode = .settling_only;
    try s.recordSend(listen);
    try std.testing.expectError(error.UnexpectedMessage, s.recordSend(listen));
    try s.recordSend(.{ .gc_answer = .{ .positions = &.{42} } });
    try std.testing.expectError(error.InvalidReference, s.recordSend(listen));
    try s.recordSend(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &.{},
        .answer = .from(42),
    } });
    try std.testing.expectError(error.UnexpectedMessage, s.recordSend(listen));
}

test "withdrawing an unsent next listener returns only its subscription claim" {
    var s = session.Session.initWith(std.testing.allocator, .{ .captp_version = .next });
    defer s.deinit();
    try s.installThirdPartyImport(.from(7), "remote");
    try s.registerExport(.from(9));
    var listen = model.Message{ .listen = .{
        .target = .{ .far = model.FarRef.promise(7) },
        .listener = .{ .near = model.NearRef.object(9) },
        .mode = .shortening_only,
    } };
    try s.recordSend(listen);
    listen.listen.mode = .settling_only;
    const before = s.exportRefcount(.from(9));
    try s.recordSend(listen);
    s.retractPreparedListen(listen);
    try std.testing.expectEqual(before, s.exportRefcount(.from(9)));
    var duplicate = listen;
    duplicate.listen.mode = .shortening_only;
    try std.testing.expectError(error.UnexpectedMessage, s.recordSend(duplicate));
    // The prior shortening subscription stays claimed, while the unsent
    // settling subscription can be attempted again after turn rollback.
    try s.recordSend(listen);
    try std.testing.expectError(error.UnexpectedMessage, s.recordSend(listen));
    s.retractPreparedListen(listen);
    try s.recordSend(listen);
}
