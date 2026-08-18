//! The V1.0 resolver links and the pipelining substrate: resolver-callback
//! links record, query, and drop with gc-answers, queued calls and listeners
//! are owned and capped loudly, third-party imports install atomically,
//! requeue detects cycles, and shortening rewrites through chains but
//! refuses a cycle.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const session = pancake.ocapn.session;
const syrup = pancake.ocapn.codec.syrup;
const capnp = pancake.ocapn.codec.capnp;

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
    try s.registerImport(.from(1));
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
        for (drained) |message| model.freeMessage(allocator, message);
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
    try s.registerImport(.from(1));
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
    try s.installImportedPromiseListener(.from(5), .{ .listener = .{ .import_position = .from(9) }, .mode = .settling_only });
    try std.testing.expect(try s.recordRelayedResolution(.from(5), s.importedPromiseRowId(.from(5)).?, .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "v") } }));
    try std.testing.expect(s.isThirdPartyImport(.from(5)));

    // Outbound op:gc-exports releasing import 5 (count 1 → 0) evicts the row,
    // freeing the host designator, the listener cap, and the stored resolution.
    try s.recordSend(.{ .gc_export = .{ .positions = &.{5}, .deltas = &.{1} } });
    try std.testing.expect(!s.isThirdPartyImport(.from(5)));
    try std.testing.expect(s.importedPromiseResolution(.from(5)) == null);
}

test "requeue moves a pipelined call to a new target and detects cycles" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();

    // Two pending inbound answers: 1 (resolves to a promise on 2) and 2.
    // Both arrive as inbound delivers to our export 1 (post-flip `.near`).
    try s.registerExport(.from(1));
    inline for (.{ 1, 2 }) |answer| {
        try s.recordRecv(.{ .deliver = .{
            .target = .{ .near = .{ .export_position = .from(1) } },
            .args = &.{},
            .answer = .from(answer),
        } });
    }

    // A call pipelined against answer 1.
    try s.enqueuePipelinedCall(.from(1), .{ .abort = .{ .kind = .other, .message = try allocator.dupe(u8, "call") } });

    // Answer 1 resolved to promise(2): drain 1's calls and requeue onto 2, with
    // 1 on the seen chain. 2 is not seen, so this succeeds and 2 owns the call.
    const drained = try s.takePipelinedCalls(.from(1));
    defer allocator.free(drained);
    for (drained) |call| try s.requeuePipelinedCall(.from(2), &.{.from(1)}, call);

    // A cycle: answer 2 resolves back to promise(1), but 1 is already on the
    // chain, requeue fails loudly and frees the call (no leak).
    const drained2 = try s.takePipelinedCalls(.from(2));
    defer allocator.free(drained2);
    for (drained2) |call| {
        try std.testing.expectError(error.ResolutionCycle, s.requeuePipelinedCall(.from(1), &.{ .from(1), .from(2) }, call));
    }
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

test "Node listener teardown releases an already returned wire mention" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .captp_version = .next,
    });
    defer s.deinit();
    try s.installThirdPartyImport(.from(5), "home");

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

test "promise shortening rewrites through chains and refuses a cycle" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerImport(.from(5));
    try s.registerImport(.from(6));
    try s.registerImport(.from(7));

    const first = (try s.nominateShorteningResolver(.from(5))).?;
    try s.validateShorteningCompletion(first.resolver_export, model.FarRef.promise(6));
    s.completeShortening(first.resolver_export, model.FarRef.promise(6));

    const second = (try s.nominateShorteningResolver(.from(6))).?;
    try s.validateShorteningCompletion(second.resolver_export, model.FarRef.promise(7));
    s.completeShortening(second.resolver_export, model.FarRef.promise(7));

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
    try s.expandShorteningGcExportReleases(allocator, &release);
    try std.testing.expectEqualSlices(u64, &.{ 5, 6, 7 }, release.positions);
    try std.testing.expectEqualSlices(u64, &.{ 1, 1, 1 }, release.deltas);
    try s.recordSend(.{ .gc_export = release });
    try std.testing.expect(!s.holdsImport(.from(5)));
    try std.testing.expect(!s.holdsImport(.from(6)));
    try std.testing.expect(!s.holdsImport(.from(7)));
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
