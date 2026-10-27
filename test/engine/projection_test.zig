//! The `op:get` / `op:index` / `op:untag` responder (ADR-0004): an inbound
//! projection exports a promise at its new answer position and the engine
//! resolves it to the named field, element, or unwrapped Tagged payload once
//! the receiver settles, breaking on a non-container value, an absent field,
//! an out-of-bounds index, a mismatched tag, or a broken receiver, and
//! following a resolution that is itself a promise.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const session = glowcap.ocapn.session;
const syrup = glowcap.ocapn.codec.syrup;

const peer_fixture = @import("../support/peer_fixture.zig");

test "op:get on a pending answer resolves the projected answer to the Struct field" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeerWith(allocator, .{ .captp_version = .v1_0 });
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    try peer_fixture.receiveCallCreatingAnswer(&peer, "<10'op:deliver<11'desc:export7+>[]11+f>");
    try peer_fixture.receiveAnsweredOperation(&peer, "<6'op:get<11'desc:answer11+>4\"name12+>");
    // The projected answer is exported (installed) the moment the op:get lands.
    try std.testing.expect(peer.session_state.inboundAnswer(.from(12)) != null);
    try std.testing.expectEqual(@as(usize, 1), peer.session_state.inboundAnswer(.from(11)).?.projections);

    // The application resolves the receiver with a Struct; the engine resolves
    // the projection in the same turn.
    try peer.sendBorrowed(.{ .resolve = .{ .answer = .from(11), .resolution = .{ .fulfill = .{ .@"struct" = &.{
        .{ .key = "name", .value = .{ .string = "tabby" } },
        .{ .key = "age", .value = .{ .integer = 12 } },
    } } } } });
    const wire = try peer_fixture.drainOutbound(&peer, allocator);
    defer allocator.free(wire);
    try std.testing.expect(std.mem.indexOf(u8, wire, "op:resolve") == null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "tabby") != null);
    try std.testing.expectEqual(session.AnswerStatus.fulfilled, peer.session_state.inboundAnswer(.from(12)).?.status);
}

test "op:index on a pending answer resolves the projected answer to the List element" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeerWith(allocator, .{ .captp_version = .v1_0 });
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    try peer_fixture.receiveCallCreatingAnswer(&peer, "<10'op:deliver<11'desc:export7+>[]21+f>");
    try peer_fixture.receiveAnsweredOperation(&peer, "<8'op:index<11'desc:answer21+>1+22+>");

    try peer.sendBorrowed(.{ .resolve = .{ .answer = .from(21), .resolution = .{ .fulfill = .{ .list = &.{
        .{ .string = "zero" }, .{ .string = "one" }, .{ .string = "two" },
    } } } } });
    const wire = try peer_fixture.drainOutbound(&peer, allocator);
    defer allocator.free(wire);
    try std.testing.expect(std.mem.indexOf(u8, wire, "one") != null);
}

test "releasing an intermediate answer preserves its accepted projection" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeerWith(allocator, .{ .captp_version = .v1_0 });
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    try peer_fixture.receiveCallCreatingAnswer(&peer, "<10'op:deliver<11'desc:export7+>[]11+f>");
    try peer_fixture.receiveAnsweredOperation(&peer, "<8'op:untag<11'desc:answer11+>4\"task12+>");
    try peer_fixture.receiveAnsweredOperation(&peer, "<8'op:index<11'desc:answer12+>1+13+>");

    // Position 12 is unavailable to future pipeline operations, but
    // the index already accepted against this exact incarnation still owns a
    // consequence of its settlement.
    try peer.recvBorrowed(.{ .bytes = "<13'op:gc-answers[12+]>", .shape = .byte });
    while (peer.pollEvent()) |event_in| {
        var event = event_in;
        event.deinit();
    }
    try std.testing.expect(peer.session_state.inboundAnswer(.from(12)) == null);

    try peer.sendBorrowed(.{ .resolve = .{ .answer = .from(11), .resolution = .{ .fulfill = .{ .tagged = .{
        .tag = "task",
        .value = &.{.{ .list = &.{ .{ .string = "assigned" }, .{ .string = "alice" } } }},
    } } } } });
    const wire = try peer_fixture.drainOutbound(&peer, allocator);
    defer allocator.free(wire);

    try std.testing.expect(peer.session_state.inboundAnswer(.from(12)) == null);
    try std.testing.expectEqualStrings(
        "alice",
        peer.session_state.peekResolution(.from(13)).?.fulfill.string,
    );
}

test "an arbitrary-precision op:index waits for the receiver then breaks out of bounds" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeerWith(allocator, .{ .captp_version = .v1_0 });
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    try peer_fixture.receiveCallCreatingAnswer(&peer, "<10'op:deliver<11'desc:export7+>[]21+f>");
    try peer.recvBorrowed(.{
        .bytes = "<8'op:index<11'desc:answer21+>9223372036854775808+22+>",
        .shape = .byte,
    });
    {
        var event = peer.pollEvent().?;
        defer event.deinit();
        const index = event.view().index.index;
        try std.testing.expect(index == .big_integer);
        try std.testing.expectEqualStrings("9223372036854775808", index.big_integer.digits);
    }
    try peer_fixture.receiveListenerForAnswer(&peer, .from(22));
    try std.testing.expectEqual(@as(usize, 1), peer.session_state.inboundAnswer(.from(21)).?.projections);

    try peer.sendBorrowed(.{ .resolve = .{ .answer = .from(21), .resolution = .{ .fulfill = .{ .list = &.{
        .{ .string = "only" },
    } } } } });
    const wire = try peer_fixture.drainOutbound(&peer, allocator);
    defer allocator.free(wire);
    try std.testing.expect(std.mem.indexOf(u8, wire, "op:index position is out of the List's bounds") != null);
    try std.testing.expectEqual(session.AnswerStatus.broken, peer.session_state.inboundAnswer(.from(22)).?.status);
}

test "op:untag on a pending answer unwraps the matching Tagged's single value" {
    const allocator = std.testing.allocator;
    // A silent peer means the Goblins-compatible feature baseline, but inbound
    // untag is still part of OCapN 1.0 and must be answered.
    var peer = peer_fixture.openPeerWith(allocator, .{
        .captp_version = .v1_0,
        .features = model.FeatureSet.baseline(),
    });
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    try peer_fixture.receiveCallCreatingAnswer(&peer, "<10'op:deliver<11'desc:export7+>[]11+f>");
    try peer_fixture.receiveAnsweredOperation(&peer, "<8'op:untag<11'desc:answer11+>2\"cm12+>");
    // The projected answer is exported (installed) the moment the op:untag lands.
    try std.testing.expect(peer.session_state.inboundAnswer(.from(12)) != null);
    try std.testing.expectEqual(@as(usize, 1), peer.session_state.inboundAnswer(.from(11)).?.projections);

    try peer.sendBorrowed(.{ .resolve = .{ .answer = .from(11), .resolution = .{ .fulfill = .{ .tagged = .{
        .tag = "cm",
        .value = &.{.{ .integer = 5 }},
    } } } } });
    const wire = try peer_fixture.drainOutbound(&peer, allocator);
    defer allocator.free(wire);
    try std.testing.expect(wire.len != 0);
    try std.testing.expect(std.mem.indexOf(u8, wire, "op:resolve") == null);
    const projected = peer.session_state.peekResolution(.from(12)).?.fulfill;
    try std.testing.expectEqual(@as(i64, 5), projected.integer);
    try std.testing.expectEqual(session.AnswerStatus.fulfilled, peer.session_state.inboundAnswer(.from(12)).?.status);
}

test "op:untag unwraps a variadic Goblins-shaped payload as its value List" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeerWith(allocator, .{ .captp_version = .v1_0 });
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    // glowcap's Tagged carries the user-record payload as a slice (ADR-0005);
    // a two-value payload unwraps to the List it is rather than guessing one.
    try peer_fixture.receiveCallCreatingAnswer(&peer, "<10'op:deliver<11'desc:export7+>[]21+f>");
    try peer_fixture.receiveAnsweredOperation(&peer, "<8'op:untag<11'desc:answer21+>5\"point22+>");
    try peer.sendBorrowed(.{ .resolve = .{ .answer = .from(21), .resolution = .{ .fulfill = .{ .tagged = .{
        .tag = "point",
        .value = &.{ .{ .integer = 1 }, .{ .integer = 2 } },
    } } } } });
    const wire = try peer_fixture.drainOutbound(&peer, allocator);
    defer allocator.free(wire);
    try std.testing.expect(wire.len != 0);
    const projected = peer.session_state.peekResolution(.from(22)).?.fulfill.list;
    try std.testing.expectEqual(@as(usize, 2), projected.len);
    try std.testing.expectEqual(@as(i64, 1), projected[0].integer);
    try std.testing.expectEqual(@as(i64, 2), projected[1].integer);
}

test "op:untag breaks on a mismatched tag and on a non-Tagged receiver" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeerWith(allocator, .{ .captp_version = .v1_0 });
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    // The asserted tag does not match the settled Tagged: spec-mandated break.
    try peer_fixture.receiveCallCreatingAnswer(&peer, "<10'op:deliver<11'desc:export7+>[]11+f>");
    try peer_fixture.receiveAnsweredOperation(&peer, "<8'op:untag<11'desc:answer11+>2\"cm12+>");
    try peer.sendBorrowed(.{ .resolve = .{ .answer = .from(11), .resolution = .{ .fulfill = .{ .tagged = .{
        .tag = "inches",
        .value = &.{.{ .integer = 5 }},
    } } } } });

    // The receiver settles to something that is not Tagged at all.
    try peer_fixture.receiveCallCreatingAnswer(&peer, "<10'op:deliver<11'desc:export7+>[]21+f>");
    try peer_fixture.receiveAnsweredOperation(&peer, "<8'op:untag<11'desc:answer21+>2\"cm22+>");
    try peer.sendBorrowed(.{ .resolve = .{ .answer = .from(21), .resolution = .{ .fulfill = .{ .integer = 9 } } } });

    const wire = try peer_fixture.drainOutbound(&peer, allocator);
    defer allocator.free(wire);
    try std.testing.expect(std.mem.indexOf(u8, wire, "does not match") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "did not resolve to a Tagged") != null);
    try std.testing.expectEqual(session.AnswerStatus.broken, peer.session_state.inboundAnswer(.from(12)).?.status);
    try std.testing.expectEqual(session.AnswerStatus.broken, peer.session_state.inboundAnswer(.from(22)).?.status);
}

test "sending op:untag installs the outbound answer so the partner's resolve admits" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeerWith(allocator, .{ .captp_version = .v1_0 });
    defer peer.deinit();
    try peer.session_state.registerImport(.from(9));

    try peer.sendBorrowed(.{ .untag = .{
        .receiver = .{ .far = .{ .import_position = .from(9) } },
        .tag = "cm",
        .answer = .from(5),
    } });
    try std.testing.expect(peer.session_state.outboundAnswer(.from(5)) != null);
    {
        const sent = try peer_fixture.drainOutbound(&peer, allocator);
        allocator.free(sent);
    }
    try peer_fixture.receiveResolverCallback(&peer, .from(5), .{ .fulfill = .{ .integer = 5 } });
    try std.testing.expectEqual(session.AnswerStatus.fulfilled, peer.session_state.outboundAnswer(.from(5)).?.status);
}

test "a late op:get against an already-settled answer resolves immediately" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeerWith(allocator, .{ .captp_version = .v1_0 });
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    try peer_fixture.receiveCallCreatingAnswer(&peer, "<10'op:deliver<11'desc:export7+>[]11+f>");
    try peer.sendBorrowed(.{ .resolve = .{ .answer = .from(11), .resolution = .{ .fulfill = .{ .@"struct" = &.{
        .{ .key = "name", .value = .{ .string = "tabby" } },
    } } } } });
    {
        const first = try peer_fixture.drainOutbound(&peer, allocator);
        allocator.free(first);
    }

    try peer_fixture.receiveAnsweredOperation(&peer, "<6'op:get<11'desc:answer11+>4\"name12+>");
    const wire = try peer_fixture.drainOutbound(&peer, allocator);
    defer allocator.free(wire);
    try std.testing.expect(std.mem.indexOf(u8, wire, "tabby") != null);
}

test "projection breaks: wrong shape, absent field, out-of-bounds, inherited break, non-promise receiver" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeerWith(allocator, .{ .captp_version = .v1_0 });
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    // Receiver resolves to a non-Struct: the get breaks.
    try peer_fixture.receiveCallCreatingAnswer(&peer, "<10'op:deliver<11'desc:export7+>[]11+f>");
    try peer_fixture.receiveAnsweredOperation(&peer, "<6'op:get<11'desc:answer11+>4\"name12+>");
    try peer.sendBorrowed(.{ .resolve = .{ .answer = .from(11), .resolution = .{ .fulfill = .{ .integer = 5 } } } });

    // Absent field on a Struct.
    try peer_fixture.receiveCallCreatingAnswer(&peer, "<10'op:deliver<11'desc:export7+>[]21+f>");
    try peer_fixture.receiveAnsweredOperation(&peer, "<6'op:get<11'desc:answer21+>4\"name22+>");
    try peer.sendBorrowed(.{ .resolve = .{ .answer = .from(21), .resolution = .{ .fulfill = .{ .@"struct" = &.{
        .{ .key = "age", .value = .{ .integer = 12 } },
    } } } } });

    // Out-of-bounds index on a List.
    try peer_fixture.receiveCallCreatingAnswer(&peer, "<10'op:deliver<11'desc:export7+>[]31+f>");
    try peer_fixture.receiveAnsweredOperation(&peer, "<8'op:index<11'desc:answer31+>9+32+>");
    try peer.sendBorrowed(.{ .resolve = .{ .answer = .from(31), .resolution = .{ .fulfill = .{ .list = &.{.{ .integer = 1 }} } } } });

    // The receiver itself breaks: the projection inherits the reason.
    try peer_fixture.receiveCallCreatingAnswer(&peer, "<10'op:deliver<11'desc:export7+>[]41+f>");
    try peer_fixture.receiveAnsweredOperation(&peer, "<6'op:get<11'desc:answer41+>4\"name42+>");
    try peer.sendBorrowed(.{ .resolve = .{ .answer = .from(41), .resolution = .{ .@"break" = .{ .message = "upstream broke" } } } });

    // A receiver that is a plain export (not a promise) breaks immediately.
    try peer_fixture.receiveAnsweredOperation(&peer, "<6'op:get<11'desc:export7+>4\"name52+>");

    const wire = try peer_fixture.drainOutbound(&peer, allocator);
    defer allocator.free(wire);
    try std.testing.expect(std.mem.indexOf(u8, wire, "did not resolve to a Struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "field is absent") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "out of the List's bounds") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "upstream broke") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "projection receiver is not a promise") != null);
    try std.testing.expectEqual(session.AnswerStatus.broken, peer.session_state.inboundAnswer(.from(12)).?.status);
    try std.testing.expectEqual(session.AnswerStatus.broken, peer.session_state.inboundAnswer(.from(52)).?.status);
}

test "a projection follows a resolution that is itself a promise" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeerWith(allocator, .{ .captp_version = .v1_0 });
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    // The projection anchors on 11, which resolves to a local promise, so the
    // projection re-anchors on that promise's answer and settles when it does.
    try peer_fixture.receiveCallCreatingAnswer(&peer, "<10'op:deliver<11'desc:export7+>[]11+f>");
    try peer_fixture.receiveAnsweredOperation(&peer, "<6'op:get<11'desc:answer11+>4\"name12+>");

    const relay = try peer.session_state.allocateLocalPromiseProjection();
    try peer.sendBorrowed(.{ .resolve = .{ .answer = .from(11), .resolution = .{ .fulfill = .{
        .reference = .{ .near = model.NearRef.promise(relay.export_position.int()) },
    } } } });
    {
        // The drain runs at step (encode) time; step until idle, then the
        // projection has re-anchored onto the promise's answer without
        // settling 12.
        const first = try peer_fixture.drainOutbound(&peer, allocator);
        allocator.free(first);
    }
    try std.testing.expectEqual(@as(usize, 1), peer.session_state.inboundAnswerNamed(relay.answer_name).?.projections);
    try std.testing.expectEqual(session.AnswerStatus.pending, peer.session_state.inboundAnswer(.from(12)).?.status);

    try peer.sendAnswerResolutionCopying(relay.answer_name, .{ .fulfill = .{ .@"struct" = &.{
        .{ .key = "name", .value = .{ .string = "tabby" } },
    } } });
    const wire = try peer_fixture.drainOutbound(&peer, allocator);
    defer allocator.free(wire);
    try std.testing.expect(std.mem.indexOf(u8, wire, "tabby") != null);
}

test "sending op:get installs the outbound answer so the partner's resolve admits" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeerWith(allocator, .{ .captp_version = .v1_0 });
    defer peer.deinit();
    try peer.session_state.registerImport(.from(9));

    try peer.sendBorrowed(.{ .get = .{
        .receiver = .{ .far = .{ .import_position = .from(9) } },
        .field = "name",
        .answer = .from(5),
    } });
    try std.testing.expect(peer.session_state.outboundAnswer(.from(5)) != null);

    // The partner invokes the mandatory listener; an unknown resolver would be
    // refused, so admission proves both the answer and resolver link install.
    {
        const sent = try peer_fixture.drainOutbound(&peer, allocator);
        allocator.free(sent);
    }
    try peer_fixture.receiveResolverCallback(&peer, .from(5), .{ .fulfill = .{ .string = "tabby" } });
    try std.testing.expectEqual(session.AnswerStatus.fulfilled, peer.session_state.outboundAnswer(.from(5)).?.status);
}

test "projections chained on projections all settle, one queued message per step" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeerWith(allocator, .{ .captp_version = .v1_0 });
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    // Each projected answer carries the next projection; encode deferral makes
    // the drain iterative (a projected resolve is queued, never recursed), so
    // the whole chain settles without growing the native stack.
    try peer_fixture.receiveCallCreatingAnswer(&peer, "<10'op:deliver<11'desc:export7+>[]11+f>");
    try peer_fixture.receiveAnsweredOperation(&peer, "<6'op:get<11'desc:answer11+>1\"a12+>");
    try peer_fixture.receiveAnsweredOperation(&peer, "<6'op:get<11'desc:answer12+>1\"a13+>");
    try peer_fixture.receiveAnsweredOperation(&peer, "<6'op:get<11'desc:answer13+>1\"a14+>");

    try peer.sendBorrowed(.{ .resolve = .{ .answer = .from(11), .resolution = .{ .fulfill = .{ .@"struct" = &.{
        .{ .key = "a", .value = .{ .@"struct" = &.{
            .{ .key = "a", .value = .{ .@"struct" = &.{
                .{ .key = "a", .value = .{ .integer = 5 } },
            } } },
        } } },
    } } } } });

    const wire = try peer_fixture.drainOutbound(&peer, allocator);
    defer allocator.free(wire);
    try std.testing.expectEqual(session.AnswerStatus.fulfilled, peer.session_state.inboundAnswer(.from(12)).?.status);
    try std.testing.expectEqual(session.AnswerStatus.fulfilled, peer.session_state.inboundAnswer(.from(13)).?.status);
    try std.testing.expectEqual(session.AnswerStatus.fulfilled, peer.session_state.inboundAnswer(.from(14)).?.status);
    try std.testing.expect(wire.len != 0);
    try std.testing.expectEqual(@as(i64, 5), peer.session_state.peekResolution(.from(14)).?.fulfill.integer);
}

test "a cyclic stored-resolution walk reports the cycle" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeerWith(allocator, .{ .captp_version = .v1_0 });
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    // Answer 11 settles to a local promise whose own answer settles back to
    // that promise. A late get anchoring on 11 walks the stored resolutions
    // synchronously; the hop bound breaks it instead of spinning.
    try peer_fixture.receiveCallCreatingAnswer(&peer, "<10'op:deliver<11'desc:export7+>[]11+f>");
    const relay = try peer.session_state.allocateLocalPromiseProjection();
    const relay_ref: model.Reference = .{ .near = model.NearRef.promise(relay.export_position.int()) };
    try peer.sendBorrowed(.{ .resolve = .{ .answer = .from(11), .resolution = .{ .fulfill = .{ .reference = relay_ref } } } });
    try peer.sendAnswerResolutionCopying(relay.answer_name, .{ .fulfill = .{ .reference = relay_ref } });
    {
        const settled = try peer_fixture.drainOutbound(&peer, allocator);
        allocator.free(settled);
    }

    try peer_fixture.receiveAnsweredOperation(&peer, "<6'op:get<11'desc:answer11+>4\"name12+>");
    const wire = try peer_fixture.drainOutbound(&peer, allocator);
    defer allocator.free(wire);
    try std.testing.expectEqual(session.AnswerStatus.broken, peer.session_state.inboundAnswer(.from(12)).?.status);
    try std.testing.expect(std.mem.indexOf(u8, wire, "promise resolution cycle") != null);
}

test "a distinct stored-resolution chain obeys max_resolution_chain" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeerWith(allocator, .{ .captp_version = .v1_0 });
    defer peer.deinit();
    peer.session_state.limits.max_resolution_chain = 1;
    try peer.session_state.registerExport(.from(7));

    // Answer 11 settles to one local promise, whose answer settles to a
    // second, whose answer stays pending: two hops over a bound of one.
    try peer_fixture.receiveCallCreatingAnswer(&peer, "<10'op:deliver<11'desc:export7+>[]11+f>");
    const first = try peer.session_state.allocateLocalPromiseProjection();
    const second = try peer.session_state.allocateLocalPromiseProjection();
    try peer.sendBorrowed(.{ .resolve = .{ .answer = .from(11), .resolution = .{ .fulfill = .{
        .reference = .{ .near = model.NearRef.promise(first.export_position.int()) },
    } } } });
    try peer.sendAnswerResolutionCopying(first.answer_name, .{ .fulfill = .{
        .reference = .{ .near = model.NearRef.promise(second.export_position.int()) },
    } });
    {
        const settled = try peer_fixture.drainOutbound(&peer, allocator);
        allocator.free(settled);
    }

    try peer_fixture.receiveAnsweredOperation(&peer, "<6'op:get<11'desc:answer11+>4\"name12+>");
    const wire = try peer_fixture.drainOutbound(&peer, allocator);
    defer allocator.free(wire);
    try std.testing.expectEqual(session.AnswerStatus.broken, peer.session_state.inboundAnswer(.from(12)).?.status);
    try std.testing.expect(std.mem.indexOf(u8, wire, "max_resolution_chain") != null);
}

test "a late projection follows a stored local promise to its backing answer" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeerWith(allocator, .{ .captp_version = .v1_0 });
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    try peer_fixture.receiveCallCreatingAnswer(&peer, "<10'op:deliver<11'desc:export7+>[]11+f>");
    const relay = try peer.session_state.allocateLocalPromiseProjection();
    try peer.sendBorrowed(.{ .resolve = .{ .answer = .from(11), .resolution = .{ .fulfill = .{
        .reference = .{ .near = model.NearRef.promise(relay.export_position.int()) },
    } } } });
    {
        const sent = try peer_fixture.drainOutbound(&peer, allocator);
        allocator.free(sent);
    }

    // The projection arrives after 11 settled and anchors on the backing
    // answer, settling only when the application resolves it.
    try peer_fixture.receiveAnsweredOperation(&peer, "<6'op:get<11'desc:answer11+>4\"name12+>");
    try std.testing.expectEqual(session.AnswerStatus.pending, peer.session_state.inboundAnswer(.from(12)).?.status);
    try std.testing.expectEqual(@as(usize, 1), peer.session_state.inboundAnswerNamed(relay.answer_name).?.projections);

    try peer.sendAnswerResolutionCopying(relay.answer_name, .{ .fulfill = .{ .@"struct" = &.{
        .{ .key = "name", .value = .{ .string = "original" } },
    } } });
    const wire = try peer_fixture.drainOutbound(&peer, allocator);
    defer allocator.free(wire);
    try std.testing.expectEqual(session.AnswerStatus.fulfilled, peer.session_state.inboundAnswer(.from(12)).?.status);
    try std.testing.expectEqualStrings(
        "original",
        peer.session_state.peekResolution(.from(12)).?.fulfill.string,
    );
    try std.testing.expect(peer.sessionIsOpen());
}

test "the projection cap refuses the overflowing op:get loudly" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeerWith(allocator, .{ .captp_version = .v1_0 });
    defer peer.deinit();
    peer.session_state.limits.max_listeners_per_target = 2;
    try peer.session_state.registerExport(.from(7));

    try peer_fixture.receiveCallCreatingAnswer(&peer, "<10'op:deliver<11'desc:export7+>[]11+f>");
    try peer.recvBorrowed(.{ .bytes = "<6'op:get<11'desc:answer11+>1\"a12+>", .shape = .byte });
    try peer.recvBorrowed(.{ .bytes = "<6'op:get<11'desc:answer11+>1\"b13+>", .shape = .byte });
    try std.testing.expectError(
        session.Error.ProjectionCapExceeded,
        peer.recvBorrowed(.{ .bytes = "<6'op:get<11'desc:answer11+>1\"c14+>", .shape = .byte }),
    );
}

test "a released projection settles detached without touching a reused position" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeerWith(allocator, .{ .captp_version = .v1_0 });
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    // The partner asks a question (answer 11), then projects a field of it
    // onto answer 12.
    try peer_fixture.receiveCallCreatingAnswer(&peer, "<10'op:deliver<11'desc:export7+>[]11+f>");
    try peer_fixture.receiveAnsweredOperation(&peer, "<6'op:get<11'desc:answer11+>4\"name12+>");
    try std.testing.expect(peer.session_state.inboundAnswer(.from(12)) != null);

    // It then releases 12 and asks something else at the same number. A partner
    // names its own answer positions, so reusing one is its right.
    try peer.recvBorrowed(.{ .bytes = "<13'op:gc-answers[12+]>", .shape = .byte });
    while (peer.pollEvent()) |ev| {
        var e = ev;
        e.deinit();
    }
    try std.testing.expect(peer.session_state.inboundAnswer(.from(12)) == null);
    try peer_fixture.receiveCallCreatingAnswer(&peer, "<10'op:deliver<11'desc:export7+>[]12+f>");
    try std.testing.expect(peer.session_state.inboundAnswer(.from(12)) != null);

    // The old projection still owes its already-accepted listener, but its row status-allow: replacement state identity
    // stamp routes that settlement through the detached incarnation. It cannot
    // answer the new question that happens to use position 12.
    try peer.sendBorrowed(.{ .resolve = .{ .answer = .from(11), .resolution = .{ .fulfill = .{ .@"struct" = &.{
        .{ .key = "name", .value = .{ .string = "tabby" } },
    } } } } });
    const wire = try peer_fixture.drainOutbound(&peer, allocator);
    defer allocator.free(wire);
    // The detached callbacks carry the projected value, while answer 12 remains
    // the partner's new pending question.
    try std.testing.expect(std.mem.indexOf(u8, wire, "tabby") != null);
    try std.testing.expectEqual(session.AnswerStatus.pending, peer.session_state.inboundAnswer(.from(12)).?.status);

    // And the new question can still be answered, which is the whole point.
    try peer.sendBorrowed(.{ .resolve = .{ .answer = .from(12), .resolution = .{ .fulfill = .{ .string = "the real reply" } } } });
    const second = try peer_fixture.drainOutbound(&peer, allocator);
    defer allocator.free(second);
    try std.testing.expect(std.mem.indexOf(u8, second, "the real reply") != null);
}
