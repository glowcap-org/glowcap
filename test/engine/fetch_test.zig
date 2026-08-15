const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const session = pancake.ocapn.session;

const fetch = engine.fetch;

test "prepareFetchSwissnum builds the canonical bootstrap-fetch deliver (next)" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .captp_version = model.CaptpVersion.next,
    });
    defer s.deinit();

    const prepared = try fetch.prepareFetchSwissnum(allocator, &s, "abc");
    defer model.freeMessage(allocator, prepared.message);

    try std.testing.expect(prepared.message == .deliver);
    const deliver = prepared.message.deliver;
    try std.testing.expect(deliver.target == .far);
    try std.testing.expectEqual(session.BOOTSTRAP_POSITION, deliver.target.far.import_position.int());
    try std.testing.expectEqual(@as(?model.AnswerPosition, prepared.answer_position), deliver.answer);
    try std.testing.expect(deliver.resolve_me_desc == null);
    try std.testing.expectEqual(@as(usize, 2), deliver.args.len);
    try std.testing.expectEqualStrings("fetch", deliver.args[0].symbol);
    try std.testing.expectEqualStrings("abc", deliver.args[1].bytes);
    try std.testing.expectEqual(@as(?model.ExportPosition, null), prepared.resolver_export);
}

test "prepareFetchSwissnum carries an object resolver desc on V1.0" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .captp_version = model.CaptpVersion.v1_0,
        .features = model.FeatureSet.full(),
    });
    defer s.deinit();

    const prepared = try fetch.prepareFetchSwissnum(allocator, &s, "abc");
    defer model.freeMessage(allocator, prepared.message);

    const rmd = prepared.message.deliver.resolve_me_desc orelse return error.TestUnexpectedResult;
    try std.testing.expect(rmd == .near);
    try std.testing.expectEqual(prepared.resolver_export.?, rmd.near.export_position);
    try std.testing.expectEqual(model.RefKind.object, rmd.near.kind);
}

test "sendPreparedFetch rolls back an unpublished V1.0 resolver on backpressure" {
    const allocator = std.testing.allocator;
    var peer = engine.testing.initRawOpenPeer(allocator);
    defer peer.deinit();
    peer.outbound_budget = 1;

    const prepared = try fetch.prepareFetchSwissnum(allocator, &peer.session_state, "abc");
    const resolver_export = prepared.resolver_export orelse return error.TestUnexpectedResult;
    try std.testing.expectError(error.OutboundBackpressure, peer.sendPreparedFetch(prepared));

    try std.testing.expect(!peer.session_state.hasExport(resolver_export));
    try std.testing.expectEqual(
        @as(?model.ExportPosition, null),
        peer.session_state.outbound_resolver_link.getByValue(.{
            .application_answer = prepared.answer_position,
        }),
    );
    try std.testing.expectEqual(engine.StepOutcome.idle, try peer.step());
}

test "tryMatchFetchOutcome settles on an op:resolve keyed to the answer" {
    const allocator = std.testing.allocator;
    const match = try fetch.tryMatchFetchOutcome(allocator, .from(5), .from(9), .{ .resolve = .{
        .answer = .from(9),
        .resolution = .{ .fulfill = .{ .reference = .{ .far = .{ .import_position = .from(3) } } } },
    } });
    try std.testing.expect(match == .settled);
    try std.testing.expect(match.settled == .fulfilled);
    try std.testing.expectEqual(@as(u64, 3), match.settled.fulfilled.far.import_position.int());
    model.freeReference(allocator, match.settled.fulfilled);
}

test "tryMatchFetchOutcome reports a partner-side break with its reason" {
    const allocator = std.testing.allocator;
    const msg = model.Message{ .resolve = .{
        .answer = .from(9),
        .resolution = .{ .@"break" = .{ .message = try allocator.dupe(u8, "unknown swissnum") } },
    } };
    const match = try fetch.tryMatchFetchOutcome(allocator, .from(5), .from(9), msg);
    try std.testing.expect(match.settled == .broken);
    try std.testing.expectEqualStrings("unknown swissnum", match.settled.broken);
    allocator.free(match.settled.broken);
}

test "tryMatchFetchOutcome settles on a resolver-callback deliver" {
    const allocator = std.testing.allocator;
    const args = try allocator.alloc(model.Argument, 2);
    args[0] = .{ .symbol = try allocator.dupe(u8, "fulfill") };
    args[1] = .{ .reference = .{ .far = .{ .import_position = .from(7) } } };
    const msg = model.Message{ .deliver = .{
        .target = .{ .near = .{ .export_position = .from(5) } },
        .args = args,
        .answer = null,
    } };
    const match = try fetch.tryMatchFetchOutcome(allocator, .from(5), .from(9), msg);
    try std.testing.expect(match.settled == .fulfilled);
    try std.testing.expectEqual(@as(u64, 7), match.settled.fulfilled.far.import_position.int());
    model.freeReference(allocator, match.settled.fulfilled);
}

test "tryMatchFetchOutcome reads a symbol-shaped resolver-callback break" {
    const allocator = std.testing.allocator;
    // The shape pancake itself emits on V1.0 (and Goblins accepts): the break
    // reason as a bare Symbol, mirroring the listener-fire payload.
    const args = try allocator.alloc(model.Argument, 2);
    args[0] = .{ .symbol = try allocator.dupe(u8, "break") };
    args[1] = .{ .symbol = try allocator.dupe(u8, "unknown swissnum") };
    const msg = model.Message{ .deliver = .{
        .target = .{ .near = .{ .export_position = .from(5) } },
        .args = args,
        .answer = null,
    } };
    const match = try fetch.tryMatchFetchOutcome(allocator, .from(5), .from(9), msg);
    try std.testing.expect(match.settled == .broken);
    try std.testing.expectEqualStrings("unknown swissnum", match.settled.broken);
    allocator.free(match.settled.broken);
}

test "a .far deliver whose import id equals the resolver export is not consumed as the settlement" {
    const allocator = std.testing.allocator;
    // The resolver is one of *our* exports, so only a `.near` target settles
    // the fetch. A partner-named `.far` import that collides with the resolver
    // id (the same integer space) is unrelated traffic, not a settlement.
    const msg = model.Message{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(5) } },
        .args = &.{ .{ .symbol = "fulfill" }, .{ .reference = .{ .far = .{ .import_position = .from(7) } } } },
        .answer = null,
    } };
    const match = try fetch.tryMatchFetchOutcome(allocator, .from(5), .from(9), msg);
    try std.testing.expect(match == .unrelated);
}

test "tryMatchFetchOutcome hands back unrelated traffic" {
    const allocator = std.testing.allocator;
    const match = try fetch.tryMatchFetchOutcome(allocator, .from(5), .from(9), .{ .resolve = .{
        .answer = .from(100),
        .resolution = .{ .fulfill = .{ .void = {} } },
    } });
    try std.testing.expect(match == .unrelated);
    model.freeMessage(allocator, match.unrelated);
}

test "bootstrap fetch round-trips: prepare, send, partner resolves, match" {
    const allocator = std.testing.allocator;
    var p1 = engine.Peer.init(allocator);
    defer p1.deinit();
    var p2 = engine.Peer.init(allocator);
    defer p2.deinit();

    // p1 addresses p2's bootstrap (import 0), always reachable on an open
    // session, no explicit import needed; p2 holds it as export 0.
    try p2.session_state.registerExport(.from(session.BOOTSTRAP_POSITION));
    // Register the cap the fetch looks up so the runtime's auto-serve fulfills
    // (rather than `break`s) the inbound bootstrap-fetch.
    const cap_export = try p2.registerBootstrapCap("swiss");

    const prepared = try fetch.prepareFetchSwissnum(allocator, &p1.session_state, "swiss");
    const answer_position = prepared.answer_position;
    const resolver_export = prepared.resolver_export;
    try p1.send(prepared.message);
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
    try std.testing.expect(match.settled == .fulfilled);
    // The matcher returns the fulfilled reference as decoded; assert its
    // position (not its near/far variant) against the registered export.
    const position: u64 = switch (match.settled.fulfilled) {
        .near => |near| near.export_position.int(),
        .far => |far| far.import_position.int(),
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(cap_export, position);
    model.freeReference(allocator, match.settled.fulfilled);
}

test "a pipelined call to an already-resolved inbound answer redirects to the resolved export" {
    const allocator = std.testing.allocator;
    var p1 = engine.Peer.init(allocator);
    defer p1.deinit();
    var p2 = engine.Peer.init(allocator);
    defer p2.deinit();

    try p2.session_state.registerExport(.from(session.BOOTSTRAP_POSITION));
    const cap_export = try p2.registerBootstrapCap("swiss");

    // p1 fetches; p2 auto-serves and resolves the fetch answer to the cap export,
    // keeping the resolution so a later pipelined call can redirect to it.
    const prepared = try fetch.prepareFetchSwissnum(allocator, &p1.session_state, "swiss");
    const fetch_answer = prepared.answer_position;
    try p1.send(prepared.message);
    _ = try p1.step();
    try p2.feedOwned(p1.takeOutbound().?);
    _ = try p2.step(); // surfaces the fetch deliver event and enqueues the resolve
    {
        var fetch_event = p2.pollEvent().?;
        fetch_event.deinit();
    }
    _ = try p2.step(); // encode the resolve: p2's inbound answer is now resolved + stored
    // Discard p2's outbound resolve so p1's outbound answer stays pending and p1
    // can still pipeline against it.
    if (p2.takeOutbound()) |outbound| {
        var frame = outbound;
        frame.deinit();
    }

    // p1 pipelines a call against the fetch answer, which is already resolved on
    // p2's side. Before the redirect, this surfaced raw with its promise target;
    // now p2 redirects it to the resolved export.
    const call_answer: u64 = 77;
    try p1.sendCopying(.{ .deliver = .{
        .target = .{ .promise = .{ .answer_position = fetch_answer } },
        .args = &.{.{ .bytes = "ping" }},
        .answer = .from(call_answer),
        .resolve_me_desc = null,
    } });
    _ = try p1.step();
    try p2.feedOwned(p1.takeOutbound().?);
    _ = try p2.step();

    var event = p2.pollEvent() orelse return error.NoRedirectedDeliver;
    defer event.deinit();
    try std.testing.expectEqual(engine.EventKind.deliver, event.kind());
    const deliver = (try event.view()).deliver;
    const position: u64 = switch (deliver.target) {
        .near => |near| near.export_position.int(),
        .far => |far| far.import_position.int(),
        else => return error.PipelinedTargetNotRedirected,
    };
    try std.testing.expectEqual(cap_export, position);
    try std.testing.expectEqual(@as(?model.AnswerPosition, .from(call_answer)), deliver.answer);
}
