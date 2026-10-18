//! V1.0 resolver translation: resolver-only virtual answers, runtime
//! resolve-me-desc synthesis, next's refusal of wire op:resolve, and
//! callback projection.

const std = @import("std");
const glowcap = @import("glowcap");

const codec = glowcap.ocapn.codec;
const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const session = glowcap.ocapn.session;
const driver = glowcap.driver;
const peer_fixture = @import("../../../support/peer_fixture.zig");

test "raw-open fixture peer is already open on v1.0, not next" {
    const allocator = std.testing.allocator;
    var peer = engine.testing.initRawOpenPeer(allocator);
    defer peer.deinit();

    try std.testing.expect(peer.sessionIsOpen());
    try std.testing.expectEqual(model.CaptpVersion.v1_0, peer.session_state.captp_version);
}

test "raw-open fixture records v1.0 resolver callback imports" {
    const allocator = std.testing.allocator;
    var peer = engine.testing.initRawOpenPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    const wire = "<10'op:deliver<11'desc:export7+>[5:hello]11+<19'desc:import-promise99+>>";
    try peer.recvBorrowed(.{ .bytes = wire, .shape = .byte });

    try std.testing.expectEqual(
        @as(?model.ImportPosition, .from(99)),
        peer.session_state.resolverForInboundAnswer(.fromWire(.from(11))),
    );

    try peer.sendBorrowed(.{ .resolve = .{
        .answer = .from(11),
        .resolution = .{ .fulfill = .{ .integer = 7 } },
    } });
    try std.testing.expectEqual(.progress, try peer.step());
    var out = peer.takeOutbound().?;
    defer out.deinit();
    try std.testing.expect(std.mem.indexOf(u8, out.storage, "op:deliver") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.storage, "fulfill") != null);
}

test "V1 resolver authority outlives stateless argument GC" {
    const allocator = std.testing.allocator;
    var peer = engine.testing.initRawOpenPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    // The same export position appears once as an application argument and
    // once as the answer-owned resolver. Their retains have different owners.
    try peer.recvBorrowed(.{
        .bytes = "<10'op:deliver<11'desc:export7+>[<18'desc:import-object99+>]11+<19'desc:import-promise99+>>",
        .shape = .byte,
    });
    var event = peer.pollEvent().?;
    defer event.deinit();
    try std.testing.expectEqual(@as(u64, 2), peer.session_state.imports.count(.from(99)));
    try std.testing.expectEqual(@as(usize, 1), event.introduced_far_imports.?.len);
    try std.testing.expectEqual(@as(model.ImportPosition, .from(99)), event.introduced_far_imports.?[0]);

    try driver.core.testing.emitStatelessAfter(&peer, &event);
    try std.testing.expectEqual(@as(u64, 1), peer.session_state.imports.count(.from(99)));
    try std.testing.expectEqual(
        @as(?model.ImportPosition, .from(99)),
        peer.session_state.resolverForInboundAnswer(.fromWire(.from(11))),
    );
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }

    try peer.sendBorrowed(.{ .resolve = .{
        .answer = .from(11),
        .resolution = .{ .fulfill = .{ .integer = 7 } },
    } });
    try std.testing.expectEqual(.progress, try peer.step());
    try std.testing.expectEqual(@as(u64, 0), peer.session_state.imports.count(.from(99)));
    try std.testing.expect(peer.session_state.resolverForInboundAnswer(.fromWire(.from(11))) == null);
    var callback = peer.takeOutbound().?;
    callback.deinit();
    var release = peer.takeOutbound().?;
    release.deinit();
}

test "a bootstrap resolver callback emits no wire-delta release" {
    const allocator = std.testing.allocator;
    var peer = engine.testing.initRawOpenPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));
    const bootstrap_count = peer.session_state.imports.count(.from(0));

    try peer.recvBorrowed(.{
        .bytes = "<10'op:deliver<11'desc:export7+>[]11+<19'desc:import-promise0+>>",
        .shape = .byte,
    });
    var event = peer.pollEvent().?;
    event.deinit();
    try std.testing.expectEqual(bootstrap_count, peer.session_state.imports.count(.from(0)));

    try peer.sendBorrowed(.{ .resolve = .{
        .answer = .from(11),
        .resolution = .{ .fulfill = .{ .integer = 7 } },
    } });
    try std.testing.expectEqual(.progress, try peer.step());
    var callback = peer.takeOutbound().?;
    callback.deinit();
    try std.testing.expect(peer.takeOutbound() == null);
    try std.testing.expectEqual(bootstrap_count, peer.session_state.imports.count(.from(0)));
}

test "V1.0 resolver-only delivery retains a virtual answer without inventing a wire position" {
    const allocator = std.testing.allocator;
    var peer = engine.testing.initRawOpenPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    const wire = "<10'op:deliver<11'desc:export7+>[]f<19'desc:import-promise99+>>";
    try peer.recvBorrowed(.{ .bytes = wire, .shape = .byte });
    var event = peer.pollEvent().?;
    defer event.deinit();

    const body = event.view();
    try std.testing.expect(body.deliver.answer == null);
    const answer = event.deliverAnswerName().?;
    try std.testing.expect(answer == .virtual);
    try std.testing.expectEqual(
        @as(?model.ImportPosition, .from(99)),
        peer.session_state.resolverForInboundAnswer(answer),
    );

    try peer.sendAnswerResolutionCopying(answer, .{ .fulfill = .{ .integer = 7 } });
    try std.testing.expectEqual(.progress, try peer.step());
    var out = peer.takeOutbound().?;
    defer out.deinit();
    try std.testing.expect(std.mem.indexOf(u8, out.storage, "op:deliver") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.storage, "fulfill") != null);
}

test "V1.0 resolver-only bootstrap fetch answers through its prepared virtual answer" {
    const allocator = std.testing.allocator;
    var peer = engine.testing.initRawOpenPeer(allocator);
    defer peer.deinit();
    _ = try peer.registerBootstrapCap("known");

    try peer.recvBorrowed(.{
        .bytes = "<10'op:deliver<11'desc:export0+>[5'fetch5:known]f<19'desc:import-promise99+>>",
        .shape = .byte,
    });
    var event = peer.pollEvent().?;
    defer event.deinit();
    try std.testing.expectEqual(engine.EventKind.deliver, event.kind());

    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    var callback = peer.takeOutbound() orelse return error.MissingBootstrapCallback;
    defer callback.deinit();
    const body = try codec.syrup.decodeBodyForProfile(.v1_0, callback.view());
    try std.testing.expectEqual(@as(u64, 99), body.deliver.target.near.export_position.int());
    try std.testing.expectEqualStrings("fulfill", (try body.deliver.args.at(0)).symbol);
    try std.testing.expect((try body.deliver.args.at(1)) == .reference);
    var release = peer.takeOutbound() orelse return error.MissingResolverRelease;
    defer release.deinit();
    try std.testing.expect((try codec.syrup.decodeBodyForProfile(.v1_0, release.view())) == .gc_export);
}

test "malformed V1.0 deliver cannot install its advertised resolver" {
    const allocator = std.testing.allocator;
    var peer = engine.testing.initRawOpenPeer(allocator);
    defer peer.deinit();

    // Export 404 was never granted to the partner. The resolver descriptor is
    // otherwise valid, but no authority from this refused deliver may survive.
    const wire = "<10'op:deliver<11'desc:export404+>[]f<19'desc:import-promise99+>>";
    try std.testing.expectError(
        session.Error.InvalidReference,
        peer.recvBorrowed(.{ .bytes = wire, .shape = .byte }),
    );

    try std.testing.expect(!peer.session_state.hasImport(.from(99)));
    try std.testing.expectEqual(
        @as(?model.AnswerName, null),
        peer.session_state.answerForResolverImport(.from(99)),
    );
}

test "next refuses the V1.0 inline resolver field" {
    var peer = peer_fixture.openPeer(std.testing.allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    try std.testing.expectError(
        error.MalformedFrame,
        peer.recvBorrowed(.{
            .bytes = "<10'op:deliver<11'desc:export7+>[]11+<19'desc:import-promise99+>>",
            .shape = .byte,
        }),
    );
    try std.testing.expect(!peer.session_state.hasInboundAnswer(.from(11)));
    try std.testing.expect(!peer.session_state.hasImport(.from(99)));
}

test "raw-open v1.0 fixture rejects raw inbound op:resolve" {
    const allocator = std.testing.allocator;
    var peer = engine.testing.initRawOpenPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(7));
    try peer.sendBorrowed(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(7) } },
        .args = &.{},
        .answer = .from(11),
    } });

    const wire = "<10'op:resolve11+<15'resolve:fulfill7+>>";
    try std.testing.expectError(session.Error.UnexpectedMessage, peer.recvBorrowed(.{ .bytes = wire, .shape = .byte }));
}

test "a rejected next answer reuse preserves the original resolver" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(7));

    const resolver = peer.session_state.exports.nextPosition();
    try peer.sendBorrowed(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &.{},
        .answer = .from(42),
    } });
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }

    try std.testing.expectError(session.Error.UnexpectedMessage, peer.sendBorrowed(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &.{},
        .answer = .from(42),
    } }));
    try std.testing.expectEqual(
        @as(?model.AnswerPosition, .from(42)),
        peer.session_state.answerForResolverExport(resolver),
    );

    var callback = try codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(resolver.int()) },
        .args = &.{ .{ .symbol = "fulfill" }, .{ .integer = 17 } },
    } });
    defer callback.deinit();
    try peer.recvBorrowed(callback.view());
    var event = peer.pollEvent().?;
    defer event.deinit();
    try std.testing.expectEqual(engine.EventKind.resolve, event.kind());
    const resolved = event.view();
    try std.testing.expectEqual(@as(u64, 42), resolved.resolve.answer.int());
}

test "V1_0 runtime translation synthesizes resolve-me-desc for answered deliver" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.init(allocator);
    defer peer.deinit();
    peer.session_state.captp_version = model.CaptpVersion.v1_0;
    try peer.session_state.registerImport(.from(7));

    try peer.sendBorrowed(.{
        .deliver = .{
            .target = .{ .far = .{ .import_position = .from(7) } },
            .args = &.{.{ .bytes = "hello" }},
            .answer = .from(42),
        },
    });

    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());

    var outbound = peer.takeOutbound().?;
    defer outbound.deinit();

    // The synthesized resolver export is 1, not 0: export 0 is reserved for the
    // bootstrap object from session construction, so a locally-allocated export
    // never aliases it (even on this un-opened raw peer).
    try std.testing.expectEqualSlices(
        u8,
        "<10'op:deliver<11'desc:export7+>[5:hello]42+<18'desc:import-object1+>>",
        outbound.bytes(),
    );
    try std.testing.expect(peer.session_state.hasExport(.from(1)));
    try std.testing.expectEqual(@as(?model.AnswerPosition, .from(42)), peer.session_state.answerForResolverExport(.from(1)));
}

test "V1_0 resolve for an answer whose deliver carried no resolver emits nothing" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.init(allocator);
    defer peer.deinit();
    peer.session_state.captp_version = model.CaptpVersion.v1_0;
    try peer.session_state.registerExport(.from(7));

    // Inbound V1.0 deliver naming answer 11 with `f` where a resolve-me-desc
    // would ride: the partner asked for no callback.
    try peer.recvBorrowed(.{ .bytes = "<10'op:deliver<11'desc:export7+>[]11+f>", .shape = .byte });
    var event = peer.pollEvent().?;
    event.deinit();

    // The application answers anyway. V1.0 has no `op:resolve` wire shape,
    // and no resolver was advertised, so there is nobody to notify: the
    // resolve settles the answer locally and puts nothing on the wire. The
    // drop is the contract (the guard in `outbound.emitOutboundMessage`),
    // pinned here so it stays a decision rather than an accident.
    try peer.sendBorrowed(.{ .resolve = .{
        .answer = .from(11),
        .resolution = .{ .fulfill = .{ .integer = 1 } },
    } });
    _ = try peer.step();
    try std.testing.expect(peer.takeOutbound() == null);
    try std.testing.expect(peer.pollEvent() == null);
}

test "V1_0 resolver-callback resolving to a container registers the introduced import" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.init(allocator);
    defer peer.deinit();
    peer.session_state.captp_version = model.CaptpVersion.v1_0;
    try peer.session_state.registerImport(.from(7));

    // An answered deliver installs outbound answer 42 and our resolver export 1
    // (export 0 is the reserved bootstrap id).
    try peer.sendBorrowed(.{
        .deliver = .{
            .target = .{ .far = .{ .import_position = .from(7) } },
            .args = &.{.{ .bytes = "hi" }},
            .answer = .from(42),
        },
    });
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    {
        var outbound = peer.takeOutbound().?;
        outbound.deinit();
    }
    try std.testing.expectEqual(@as(?model.AnswerPosition, .from(42)), peer.session_state.answerForResolverExport(.from(1)));

    // The partner resolves answer 42 by delivering to our resolver export 1 a
    // `fulfill` whose payload is a *list containing a capability*, a far ref the
    // resolution introduces. On the wire the target is <desc:export 1> and the
    // payload <desc:import-object 9> sits inside a list; decode flips them to
    // .near{1} (our resolver) and .far{9} (the introduced import). Encoded via
    // the codec so the wire shape is exact.
    const callback = model.Message{
        .deliver = .{
            .target = .{ .far = .{ .import_position = .from(1) } },
            .args = &.{
                .{ .symbol = "fulfill" },
                .{ .list = &.{.{ .reference = .{ .near = model.NearRef.object(9) } }} },
            },
        },
    };
    const frame = try codec.syrup.encodeMessage(allocator, callback);
    try peer.feedOwned(frame); // takes ownership of frame
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    {
        var event = peer.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(engine.EventKind.resolve, event.kind());
    }

    // The capability nested in the container resolution was registered as an
    // import. Before the fix, borrowedArgument collapsed the container to void
    // and the introduced-import walk never saw the far ref, so the import was
    // silently dropped and a later message naming it would have failed.
    try std.testing.expect(peer.session_state.hasImport(.from(9)));
}

test "next refuses wire op:resolve" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(99));
    try peer.sendBorrowed(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(99) } },
        .args = &.{},
        .answer = .from(42),
    } });

    try std.testing.expectError(
        codec.syrup.Error.UnsupportedMessage,
        peer.recvBorrowed(.{ .bytes = "<10'op:resolve42+<15'resolve:fulfill<4'void>>>", .shape = .byte }),
    );
    try std.testing.expectEqual(session.AnswerStatus.pending, peer.session_state.outboundAnswer(.from(42)).?.status);
    try std.testing.expect(peer.pollEvent() == null);
}

test "a V1.0 break carrying a tagged record resolves to the tag name" {
    // Goblins marshals a thrown exception or a severed-session condition as a
    // tagged record, not a `desc:error`; the resolver-callback translation
    // keeps the tag as the break message instead of dropping to the generic
    // fallback.
    const tagged_args = [_]model.Argument{
        .{ .symbol = "break" },
        .{ .tagged = .{ .tag = "captp-session-severed", .value = &.{} } },
    };
    const tagged = try engine.events.resolutionFromResolverCallback(
        model.view.Args.fromOwnedSlice(&tagged_args),
    );
    try std.testing.expectEqualStrings("captp-session-severed", tagged.@"break".message);

    // The generic fallback still catches a payload with no usable text.
    const opaque_args = [_]model.Argument{
        .{ .symbol = "break" },
        .{ .integer = 7 },
    };
    const fallback = try engine.events.resolutionFromResolverCallback(
        model.view.Args.fromOwnedSlice(&opaque_args),
    );
    try std.testing.expectEqualStrings("remote promise broken", fallback.@"break".message);
}

test "view and decodeOwned agree on a V1.0 resolver-callback deliver" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.init(allocator);
    defer peer.deinit();
    peer.session_state.captp_version = model.CaptpVersion.v1_0;
    try peer.session_state.registerImport(.from(7));

    // An answered deliver mints resolver export 1 at encode time.
    try peer.sendBorrowed(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(7) } },
        .args = &.{.{ .bytes = "hi" }},
        .answer = .from(42),
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    {
        var outbound = peer.takeOutbound().?;
        outbound.deinit();
    }

    // The partner settles answer 42 through the resolver callback.
    const callback = try codec.syrup.encodeMessage(allocator, .{ .deliver = .{
        .target = .{ .far = model.FarRef.promise(1) },
        .args = &.{ .{ .symbol = "fulfill" }, .{ .integer = 17 } },
        .answer = null,
    } });
    try peer.feedOwned(callback);
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());

    var event = peer.pollEvent().?;
    defer event.deinit();
    try std.testing.expectEqual(engine.EventKind.resolve, event.kind());

    // The two projections may not disagree about what this frame is: both the
    // borrowed view and the owned materialization surface the translated
    // semantic Resolve, never the raw callback deliver.
    const view = event.view();
    try std.testing.expect(view.* == .resolve);
    try std.testing.expectEqual(@as(u64, 42), view.resolve.answer.int());

    const owned = try event.decodeOwned(allocator);
    defer model.freeMessage(allocator, owned);
    try std.testing.expect(owned == .resolve);
    try std.testing.expectEqual(@as(u64, 42), owned.resolve.answer.int());
    try std.testing.expect(owned.resolve.resolution == .fulfill);
    try std.testing.expectEqual(@as(i64, 17), owned.resolve.resolution.fulfill.integer);
}

test "a V1.0 settling listener hears an answer that resolves to the partner's own promise" {
    // Goblins listens with wants-partial #f and no paired shortening listener.
    // The far promise is the listener's own export, so the notification lets
    // it follow that promise locally; dropping it would leave the waiter hung.
    const allocator = std.testing.allocator;
    var peer = engine.testing.initRawOpenPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));
    try peer.session_state.registerImport(.from(12));

    try peer.recvBorrowed(.{
        .bytes = "<10'op:deliver<11'desc:export7+>[5:hello]11+<19'desc:import-promise99+>>",
        .shape = .byte,
    });
    var deliver_event = peer.pollEvent().?;
    deliver_event.deinit();

    var listen = try codec.syrup.encodeMessageForProfile(allocator, .v1_0, .{ .listen = .{
        .target = .{ .promise = .{ .answer_position = .from(11) } },
        .listener = .{ .near = model.NearRef.object(50) },
        .mode = .settling_only,
    } });
    defer listen.deinit();
    try peer.recvBorrowed(listen.view());
    var listen_event = peer.pollEvent().?;
    listen_event.deinit();

    try peer.sendBorrowed(.{ .resolve = .{
        .answer = .from(11),
        .resolution = .{ .fulfill = .{ .reference = .{ .far = model.FarRef.promise(12) } } },
    } });
    while ((try peer.step()) != .idle) {}

    var heard = false;
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        defer frame.deinit();
        const body = try codec.syrup.decodeBodyForProfile(.v1_0, frame.view());
        if (body != .deliver) continue;
        const target = body.deliver.target;
        if (target == .near and target.near.export_position.int() == 50) {
            try std.testing.expect(std.mem.indexOf(u8, frame.storage, "fulfill") != null);
            heard = true;
        }
    }
    try std.testing.expect(heard);
}
