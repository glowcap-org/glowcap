//! The `op:get` / `op:index` / `op:untag` responder (ADR-0050): an inbound
//! projection exports a promise at its new answer position and the engine
//! resolves it to the named field, element, or unwrapped Tagged payload once
//! the receiver settles, breaking on a non-container value, an absent field,
//! an out-of-bounds index, a mismatched tag, or a broken receiver, and
//! following a resolution that is itself a promise.

const std = @import("std");
const pancake = @import("pancake");

const engine = pancake.ocapn.engine;
const model = pancake.ocapn.model;
const session = pancake.ocapn.session;
const syrup = pancake.ocapn.codec.syrup;

const peer_fixture = @import("../support/peer_fixture.zig");

test "op:get on a pending answer resolves the projected answer to the Struct field" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    try peer_fixture.receiveCallCreatingAnswer(&peer, "<10'op:deliver<11'desc:export7+>[]11+f>");
    try peer.recvBorrowed(.{ .bytes = "<6'op:get<11'desc:answer11+>4\"name12+>", .shape = .byte });
    {
        var event = peer.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(engine.EventKind.get, event.kind());
    }
    // The projected answer is exported (installed) the moment the op:get lands.
    try std.testing.expect(peer.session_state.inboundAnswer(.from(12)) != null);
    try std.testing.expectEqual(@as(usize, 1), peer.session_state.inboundAnswer(.from(11)).?.projections);

    // The application resolves the receiver with a Struct; the engine resolves
    // the projection in the same turn.
    try peer.sendCopying(.{ .resolve = .{ .answer = .from(11), .resolution = .{ .fulfill = .{ .@"struct" = &.{
        .{ .key = "name", .value = .{ .string = "tabby" } },
        .{ .key = "age", .value = .{ .integer = 12 } },
    } } } } });
    const wire = try peer_fixture.drainOutbound(&peer, allocator);
    defer allocator.free(wire);
    try std.testing.expect(std.mem.indexOf(u8, wire, "<10'op:resolve11+") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "<10'op:resolve12+<15'resolve:fulfill5\"tabby>>") != null);
    try std.testing.expectEqual(session.AnswerStatus.fulfilled, peer.session_state.inboundAnswer(.from(12)).?.status);
}

test "op:index on a pending answer resolves the projected answer to the List element" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    try peer_fixture.receiveCallCreatingAnswer(&peer, "<10'op:deliver<11'desc:export7+>[]21+f>");
    try peer.recvBorrowed(.{ .bytes = "<8'op:index<11'desc:answer21+>1+22+>", .shape = .byte });
    {
        var event = peer.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(engine.EventKind.index, event.kind());
    }

    try peer.sendCopying(.{ .resolve = .{ .answer = .from(21), .resolution = .{ .fulfill = .{ .list = &.{
        .{ .string = "zero" }, .{ .string = "one" }, .{ .string = "two" },
    } } } } });
    const wire = try peer_fixture.drainOutbound(&peer, allocator);
    defer allocator.free(wire);
    try std.testing.expect(std.mem.indexOf(u8, wire, "<10'op:resolve22+<15'resolve:fulfill3\"one>>") != null);
}

test "op:untag on a pending answer unwraps the matching Tagged's single value" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    try peer_fixture.receiveCallCreatingAnswer(&peer, "<10'op:deliver<11'desc:export7+>[]11+f>");
    try peer.recvBorrowed(.{ .bytes = "<8'op:untag<11'desc:answer11+>2\"cm12+>", .shape = .byte });
    {
        var event = peer.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(engine.EventKind.untag, event.kind());
    }
    // The projected answer is exported (installed) the moment the op:untag lands.
    try std.testing.expect(peer.session_state.inboundAnswer(.from(12)) != null);
    try std.testing.expectEqual(@as(usize, 1), peer.session_state.inboundAnswer(.from(11)).?.projections);

    try peer.sendCopying(.{ .resolve = .{ .answer = .from(11), .resolution = .{ .fulfill = .{ .tagged = .{
        .tag = "cm",
        .value = &.{.{ .integer = 5 }},
    } } } } });
    const wire = try peer_fixture.drainOutbound(&peer, allocator);
    defer allocator.free(wire);
    try std.testing.expect(std.mem.indexOf(u8, wire, "<10'op:resolve12+<15'resolve:fulfill5+>") != null);
    try std.testing.expectEqual(session.AnswerStatus.fulfilled, peer.session_state.inboundAnswer(.from(12)).?.status);
}

test "op:untag unwraps a variadic Goblins-shaped payload as its value List" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    // pancake's Tagged carries the user-record payload as a slice (ADR-0021);
    // a two-value payload unwraps to the List it is rather than guessing one.
    try peer_fixture.receiveCallCreatingAnswer(&peer, "<10'op:deliver<11'desc:export7+>[]21+f>");
    try peer.recvBorrowed(.{ .bytes = "<8'op:untag<11'desc:answer21+>5\"point22+>", .shape = .byte });
    {
        var event = peer.pollEvent().?;
        event.deinit();
    }
    try peer.sendCopying(.{ .resolve = .{ .answer = .from(21), .resolution = .{ .fulfill = .{ .tagged = .{
        .tag = "point",
        .value = &.{ .{ .integer = 1 }, .{ .integer = 2 } },
    } } } } });
    const wire = try peer_fixture.drainOutbound(&peer, allocator);
    defer allocator.free(wire);
    try std.testing.expect(std.mem.indexOf(u8, wire, "<10'op:resolve22+<15'resolve:fulfill[1+2+]>") != null);
}

test "op:untag breaks on a mismatched tag and on a non-Tagged receiver" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    // The asserted tag does not match the settled Tagged: spec-mandated break.
    try peer_fixture.receiveCallCreatingAnswer(&peer, "<10'op:deliver<11'desc:export7+>[]11+f>");
    try peer.recvBorrowed(.{ .bytes = "<8'op:untag<11'desc:answer11+>2\"cm12+>", .shape = .byte });
    {
        var event = peer.pollEvent().?;
        event.deinit();
    }
    try peer.sendCopying(.{ .resolve = .{ .answer = .from(11), .resolution = .{ .fulfill = .{ .tagged = .{
        .tag = "inches",
        .value = &.{.{ .integer = 5 }},
    } } } } });

    // The receiver settles to something that is not Tagged at all.
    try peer_fixture.receiveCallCreatingAnswer(&peer, "<10'op:deliver<11'desc:export7+>[]21+f>");
    try peer.recvBorrowed(.{ .bytes = "<8'op:untag<11'desc:answer21+>2\"cm22+>", .shape = .byte });
    {
        var event = peer.pollEvent().?;
        event.deinit();
    }
    try peer.sendCopying(.{ .resolve = .{ .answer = .from(21), .resolution = .{ .fulfill = .{ .integer = 9 } } } });

    const wire = try peer_fixture.drainOutbound(&peer, allocator);
    defer allocator.free(wire);
    try std.testing.expect(std.mem.indexOf(u8, wire, "op:resolve12+<13'resolve:break") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "does not match") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "op:resolve22+<13'resolve:break") != null);
    try std.testing.expectEqual(session.AnswerStatus.broken, peer.session_state.inboundAnswer(.from(12)).?.status);
    try std.testing.expectEqual(session.AnswerStatus.broken, peer.session_state.inboundAnswer(.from(22)).?.status);
}

test "sending op:untag installs the outbound answer so the partner's resolve admits" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(9));

    try peer.sendCopying(.{ .untag = .{
        .receiver = .{ .far = .{ .import_position = .from(9) } },
        .tag = "cm",
        .answer = .from(5),
    } });
    try std.testing.expect(peer.session_state.outboundAnswer(.from(5)) != null);

    try peer.recvBorrowed(.{ .bytes = "<10'op:resolve5+<15'resolve:fulfill5+>>", .shape = .byte });
    try std.testing.expectEqual(session.AnswerStatus.fulfilled, peer.session_state.outboundAnswer(.from(5)).?.status);
}

test "a late op:get against an already-settled answer resolves immediately" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    try peer_fixture.receiveCallCreatingAnswer(&peer, "<10'op:deliver<11'desc:export7+>[]11+f>");
    try peer.sendCopying(.{ .resolve = .{ .answer = .from(11), .resolution = .{ .fulfill = .{ .@"struct" = &.{
        .{ .key = "name", .value = .{ .string = "tabby" } },
    } } } } });
    {
        const first = try peer_fixture.drainOutbound(&peer, allocator);
        allocator.free(first);
    }

    try peer.recvBorrowed(.{ .bytes = "<6'op:get<11'desc:answer11+>4\"name12+>", .shape = .byte });
    {
        var event = peer.pollEvent().?;
        event.deinit();
    }
    const wire = try peer_fixture.drainOutbound(&peer, allocator);
    defer allocator.free(wire);
    try std.testing.expect(std.mem.indexOf(u8, wire, "<10'op:resolve12+<15'resolve:fulfill5\"tabby>>") != null);
}

test "projection breaks: wrong shape, absent field, out-of-bounds, inherited break, non-promise receiver" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    // Receiver resolves to a non-Struct: the get breaks.
    try peer_fixture.receiveCallCreatingAnswer(&peer, "<10'op:deliver<11'desc:export7+>[]11+f>");
    try peer.recvBorrowed(.{ .bytes = "<6'op:get<11'desc:answer11+>4\"name12+>", .shape = .byte });
    {
        var event = peer.pollEvent().?;
        event.deinit();
    }
    try peer.sendCopying(.{ .resolve = .{ .answer = .from(11), .resolution = .{ .fulfill = .{ .integer = 5 } } } });

    // Absent field on a Struct.
    try peer_fixture.receiveCallCreatingAnswer(&peer, "<10'op:deliver<11'desc:export7+>[]21+f>");
    try peer.recvBorrowed(.{ .bytes = "<6'op:get<11'desc:answer21+>4\"name22+>", .shape = .byte });
    {
        var event = peer.pollEvent().?;
        event.deinit();
    }
    try peer.sendCopying(.{ .resolve = .{ .answer = .from(21), .resolution = .{ .fulfill = .{ .@"struct" = &.{
        .{ .key = "age", .value = .{ .integer = 12 } },
    } } } } });

    // Out-of-bounds index on a List.
    try peer_fixture.receiveCallCreatingAnswer(&peer, "<10'op:deliver<11'desc:export7+>[]31+f>");
    try peer.recvBorrowed(.{ .bytes = "<8'op:index<11'desc:answer31+>9+32+>", .shape = .byte });
    {
        var event = peer.pollEvent().?;
        event.deinit();
    }
    try peer.sendCopying(.{ .resolve = .{ .answer = .from(31), .resolution = .{ .fulfill = .{ .list = &.{.{ .integer = 1 }} } } } });

    // The receiver itself breaks: the projection inherits the reason.
    try peer_fixture.receiveCallCreatingAnswer(&peer, "<10'op:deliver<11'desc:export7+>[]41+f>");
    try peer.recvBorrowed(.{ .bytes = "<6'op:get<11'desc:answer41+>4\"name42+>", .shape = .byte });
    {
        var event = peer.pollEvent().?;
        event.deinit();
    }
    try peer.sendCopying(.{ .resolve = .{ .answer = .from(41), .resolution = .{ .@"break" = .{ .message = "upstream broke" } } } });

    // A receiver that is a plain export (not a promise) breaks immediately.
    try peer.recvBorrowed(.{ .bytes = "<6'op:get<11'desc:export7+>4\"name52+>", .shape = .byte });
    {
        var event = peer.pollEvent().?;
        event.deinit();
    }

    const wire = try peer_fixture.drainOutbound(&peer, allocator);
    defer allocator.free(wire);
    try std.testing.expect(std.mem.indexOf(u8, wire, "op:resolve12+<13'resolve:break") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "op:resolve22+<13'resolve:break") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "op:resolve32+<13'resolve:break") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "upstream broke") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "op:resolve52+<13'resolve:break") != null);
    try std.testing.expectEqual(session.AnswerStatus.broken, peer.session_state.inboundAnswer(.from(12)).?.status);
    try std.testing.expectEqual(session.AnswerStatus.broken, peer.session_state.inboundAnswer(.from(52)).?.status);
}

test "a projection follows a resolution that is itself a promise" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    // Two pending answers; the projection anchors on 11, which resolves to the
    // promise for 21, so the projection re-anchors and settles when 21 does.
    try peer_fixture.receiveCallCreatingAnswer(&peer, "<10'op:deliver<11'desc:export7+>[]11+f>");
    try peer_fixture.receiveCallCreatingAnswer(&peer, "<10'op:deliver<11'desc:export7+>[]21+f>");
    try peer.recvBorrowed(.{ .bytes = "<6'op:get<11'desc:answer11+>4\"name12+>", .shape = .byte });
    {
        var event = peer.pollEvent().?;
        event.deinit();
    }

    try peer.sendCopying(.{ .resolve = .{ .answer = .from(11), .resolution = .{ .fulfill = .{
        .reference = .{ .promise = .{ .answer_position = .from(21) } },
    } } } });
    {
        // The drain runs at step (encode) time; step until idle, then the
        // projection has re-anchored onto 21 without settling 12.
        const first = try peer_fixture.drainOutbound(&peer, allocator);
        allocator.free(first);
    }
    try std.testing.expectEqual(@as(usize, 1), peer.session_state.inboundAnswer(.from(21)).?.projections);
    try std.testing.expectEqual(session.AnswerStatus.pending, peer.session_state.inboundAnswer(.from(12)).?.status);

    try peer.sendCopying(.{ .resolve = .{ .answer = .from(21), .resolution = .{ .fulfill = .{ .@"struct" = &.{
        .{ .key = "name", .value = .{ .string = "tabby" } },
    } } } } });
    const wire = try peer_fixture.drainOutbound(&peer, allocator);
    defer allocator.free(wire);
    try std.testing.expect(std.mem.indexOf(u8, wire, "<10'op:resolve12+<15'resolve:fulfill5\"tabby>>") != null);
}

test "sending op:get installs the outbound answer so the partner's resolve admits" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(9));

    try peer.sendCopying(.{ .get = .{
        .receiver = .{ .far = .{ .import_position = .from(9) } },
        .field = "name",
        .answer = .from(5),
    } });
    try std.testing.expect(peer.session_state.outboundAnswer(.from(5)) != null);

    // The partner resolves the projected answer; an unknown answer would be
    // refused (`InvalidReference`), so admission proves the install.
    try peer.recvBorrowed(.{ .bytes = "<10'op:resolve5+<15'resolve:fulfill5\"tabby>>", .shape = .byte });
    try std.testing.expectEqual(session.AnswerStatus.fulfilled, peer.session_state.outboundAnswer(.from(5)).?.status);
}

test "projections chained on projections all settle, one queued message per step" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    // Each projected answer carries the next projection; encode deferral makes
    // the drain iterative (a projected resolve is queued, never recursed), so
    // the whole chain settles without growing the native stack.
    try peer_fixture.receiveCallCreatingAnswer(&peer, "<10'op:deliver<11'desc:export7+>[]11+f>");
    try peer.recvBorrowed(.{ .bytes = "<6'op:get<11'desc:answer11+>1\"a12+>", .shape = .byte });
    try peer.recvBorrowed(.{ .bytes = "<6'op:get<11'desc:answer12+>1\"a13+>", .shape = .byte });
    try peer.recvBorrowed(.{ .bytes = "<6'op:get<11'desc:answer13+>1\"a14+>", .shape = .byte });
    while (peer.pollEvent()) |event_value| {
        var event = event_value;
        event.deinit();
    }

    try peer.sendCopying(.{ .resolve = .{ .answer = .from(11), .resolution = .{ .fulfill = .{ .@"struct" = &.{
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
    try std.testing.expect(std.mem.indexOf(u8, wire, "<10'op:resolve14+<15'resolve:fulfill5+>") != null);
}

test "a cyclic stored-resolution walk breaks at max_projection_chain hops" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    // Two answers settled into a promise cycle: 11 stored promise(21), 21
    // stored promise(11). A late get anchoring on 11 walks the stored
    // resolutions synchronously; the hop bound breaks it instead of spinning.
    try peer_fixture.receiveCallCreatingAnswer(&peer, "<10'op:deliver<11'desc:export7+>[]11+f>");
    try peer_fixture.receiveCallCreatingAnswer(&peer, "<10'op:deliver<11'desc:export7+>[]21+f>");
    try peer.sendCopying(.{ .resolve = .{ .answer = .from(11), .resolution = .{ .fulfill = .{
        .reference = .{ .promise = .{ .answer_position = .from(21) } },
    } } } });
    try peer.sendCopying(.{ .resolve = .{ .answer = .from(21), .resolution = .{ .fulfill = .{
        .reference = .{ .promise = .{ .answer_position = .from(11) } },
    } } } });
    {
        const settled = try peer_fixture.drainOutbound(&peer, allocator);
        allocator.free(settled);
    }

    try peer.recvBorrowed(.{ .bytes = "<6'op:get<11'desc:answer11+>4\"name12+>", .shape = .byte });
    {
        var event = peer.pollEvent().?;
        event.deinit();
    }
    const wire = try peer_fixture.drainOutbound(&peer, allocator);
    defer allocator.free(wire);
    try std.testing.expectEqual(session.AnswerStatus.broken, peer.session_state.inboundAnswer(.from(12)).?.status);
    try std.testing.expect(std.mem.indexOf(u8, wire, "max_projection_chain") != null);
}

test "the projection cap refuses the overflowing op:get loudly" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
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
