//! What a Peer owns at its boundary: originated handoffs need distinct
//! sessions, the outbound waterline refuses before authority moves,
//! feedOwned transfers and recvBorrowed copies exactly once, sendBorrowed
//! encodes a deliver before the caller can mutate its bytes, and no failed
//! allocation advances session state.

const std = @import("std");
const glowcap = @import("glowcap");

const codec = glowcap.ocapn.codec;
const foundation = glowcap.foundation;
const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const session = glowcap.ocapn.session;
const peer_fixture = @import("../../support/peer_fixture.zig");

const harness = @import("harness.zig");
const FailAfterAllocator = harness.FailAfterAllocator;
const CountingAllocator = harness.CountingAllocator;

test "originated handoff transaction requires distinct peer sessions" {
    var peer = engine.Peer.init(std.testing.allocator);
    defer peer.deinit();

    try std.testing.expectError(error.AliasedHandoffPeers, engine.handoff_gifter.queueOriginatedGive(
        &peer,
        &peer,
        "gift",
        .{ .far = model.FarRef.object(1) },
        "give",
        .{ .name = .fromWire(.from(1)), .row_id = 1 },
    ));
}

test "failed withdraw construction does not consume its handoff count" {
    const allocator = std.testing.allocator;
    var pair = try engine.pairing.pairedV1_0Syrup(allocator);
    defer pair.deinit();
    const recipient_secret = foundation.crypto.SecretKey.fromSeed(@as([foundation.crypto.seed_bytes]u8, @splat(0x35)));

    try std.testing.expectError(
        codec.syrup.Error.MalformedFrame,
        pair.p1.sendWithdrawGift(recipient_secret, "not a signed give", .from(1)),
    );
    try std.testing.expectEqual(@as(u64, 0), pair.p1.giftRegistry().next_emitted_handoff_count);

    const exporter_location = try engine.encodePeerLocatorRecord(allocator, .{
        .transport = "tcp",
        .designator = "127.0.0.1:9000",
        .hints = model.Hints.emptyFalse(),
    });
    defer allocator.free(exporter_location);
    const gifter_secret = foundation.crypto.SecretKey.fromSeed(@as([foundation.crypto.seed_bytes]u8, @splat(0x36)));
    const give = try engine.handoff_gifter.buildSignedGive(
        allocator,
        gifter_secret,
        recipient_secret.publicKey().asBytes(),
        exporter_location,
        &(@as([32]u8, @splat(0x37))),
        &(@as([32]u8, @splat(0x38))),
        &(@as([model.handoff_gift_id_bytes]u8, @splat(0x39))),
    );
    defer allocator.free(give);

    try pair.p1.sendWithdrawGift(recipient_secret, give, .from(1));
    try std.testing.expectEqual(@as(u64, 1), pair.p1.giftRegistry().next_emitted_handoff_count);
    try pair.p1.stepToIdle();
    var frame = pair.p1.takeOutbound().?;
    defer frame.deinit();
    const body = try codec.syrup.decodeBodyForProfile(.v1_0, frame.view());
    const receive = (try (try body.deliver.args.at(1)).handoff.project()).receive;
    try std.testing.expectEqual(@as(u64, 0), receive.handoff_count);
}

test "outbound waterline refuses one arbitrarily large producer before authority moves" {
    const allocator = std.testing.allocator;
    var peer = engine.testing.initRawOpenPeer(allocator);
    defer peer.deinit();
    peer.outbound_budget = 256;
    try peer.session_state.registerImport(.from(7));

    const oversized = @as([512]u8, @splat(0x5a));
    try std.testing.expectError(error.OutboundBackpressure, peer.sendBorrowed(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &.{.{ .bytes = &oversized }},
        .answer = .from(19),
    } }));

    try std.testing.expect(peer.session_state.outboundAnswer(.from(19)) == null);
    try std.testing.expectEqual(engine.StepOutcome.idle, try peer.step());
    try std.testing.expect(peer.takeOutbound() == null);
}

test "one inbound frame admits its maintenance carriers as one outbound producer" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(9));
    try peer.session_state.registerExport(.from(7));

    // Park an older producer immediately below the waterline. The incoming
    // frame introduces two promises, so next owes two shortening listeners.
    // They are one consequence of one accepted frame: the first may cross the
    // line, but the second must not be mistaken for a new producer and refuse
    // the otherwise atomic inbound transaction.
    const ballast = @as([512]u8, @splat(0x5a));
    try peer.sendBorrowed(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(9) },
        .args = &.{.{ .bytes = &ballast }},
    } });
    peer.outbound_budget = peer.queuedOutboundBytes() + 1;

    var inbound = try codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &.{
            .{ .reference = .{ .near = model.NearRef.promise(5) } },
            .{ .reference = .{ .near = model.NearRef.promise(6) } },
        },
    } });
    defer inbound.deinit();
    try peer.recvBorrowed(inbound.view());
    var event = peer.pollEvent() orelse return error.MissingDeliverEvent;
    defer event.deinit();

    var shortening_listens: usize = 0;
    while (true) {
        const outcome = try peer.step();
        while (peer.takeOutbound()) |frame_in| {
            var frame = frame_in;
            defer frame.deinit();
            const body = try codec.syrup.decodeBodyForProfile(.next, frame.view());
            if (body == .listen and body.listen.mode == .shortening_only)
                shortening_listens += 1;
        }
        if (outcome == .idle) break;
    }
    try std.testing.expectEqual(@as(usize, 2), shortening_listens);
}

test "queued inbound backpressure aborts instead of dropping the frame" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));
    peer.outbound_budget = 1;

    const inbound = try codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &.{.{ .reference = .{ .near = model.NearRef.promise(5) } }},
    } });
    try peer.feedOwned(inbound);

    try std.testing.expectError(error.OutboundBackpressure, peer.step());
    try std.testing.expect(!peer.sessionIsOpen());
    var abort_frame = peer.takeOutbound() orelse return error.MissingAbort;
    defer abort_frame.deinit();
    const abort = try codec.syrup.decodeBodyForProfile(.next, abort_frame.view());
    try std.testing.expect(abort == .abort);
    try std.testing.expectEqual(model.AbortKind.resource_exhausted, abort.abort.kind);
    try std.testing.expect(peer.takeOutbound() == null);
}

test "outbound admission backpressure remains retryable and does not abort" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(7));

    peer.outbound_budget = 0;
    try std.testing.expectError(error.OutboundBackpressure, peer.sendBorrowed(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &.{.{ .bytes = "retry" }},
    } }));
    try std.testing.expect(peer.sessionIsOpen());
    try std.testing.expect(peer.lastAbort() == null);
    try std.testing.expect(peer.takeOutbound() == null);

    peer.outbound_budget = std.math.maxInt(usize);
    try peer.sendBorrowed(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &.{.{ .bytes = "retry" }},
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    var frame = peer.takeOutbound() orelse return error.MissingDeliverFrame;
    frame.deinit();
}

test "an admitted carrier encodes across the waterline instead of deadlocking" {
    // The waterline gates admission only (`peer/outbound/budget.zig`): once a
    // carrier is queued, its encode must proceed even with the budget already
    // saturated, because completion is the only way retained work drains. A
    // transfer-side refusal here once wedged a Host forever: the saturated
    // store refused the very encodes that would have emptied it.
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(7));

    try peer.sendBorrowed(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &.{.{ .bytes = "retry" }},
    } });
    peer.outbound_budget = 0;
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    var frame = peer.takeOutbound() orelse return error.MissingDeliverFrame;
    frame.deinit();
    try std.testing.expect(peer.sessionIsOpen());
    try std.testing.expect(peer.lastAbort() == null);
}

test "owned inbound frame moves into the surfaced event without copying its bytes" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.init(allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    const deliver_bytes = "<10'op:deliver<11'desc:export7+>[]11+f>";
    const storage = try allocator.dupe(u8, deliver_bytes);
    const fed_ptr = @intFromPtr(storage.ptr);
    const frame = try foundation.Frame.initOwned(allocator, storage, .byte, .fromByteUnits(1));

    try peer.feedOwned(frame);
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());

    var event = peer.pollEvent().?;
    defer event.deinit();
    try std.testing.expectEqual(fed_ptr, @intFromPtr(event.bytes().ptr));
}

test "borrowed inbound retains its own copy of the wire bytes exactly once" {
    const deliver_bytes = "<10'op:deliver<11'desc:export7+>[]11+f>";
    var counter = CountingAllocator{ .backing = std.testing.allocator };
    var peer = engine.Peer.init(counter.allocator());
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    // The one block holds the parse's head and its argument views in front
    // of the copied bytes.
    counter.count_size = try glowcap.foundation.Frame.headedBlockLen(
        engine.events.Head,
        model.view.Argument,
        engine.events.headViewsFor(deliver_bytes.len),
        deliver_bytes.len,
        .byte,
    );
    try peer.recvBorrowed(.{ .bytes = deliver_bytes, .shape = .byte });
    try std.testing.expectEqual(@as(usize, 1), counter.matching_allocs);

    var event = peer.pollEvent().?;
    defer event.deinit();
    try std.testing.expect(@intFromPtr(event.bytes().ptr) != @intFromPtr(deliver_bytes.ptr));
    try std.testing.expectEqualStrings(deliver_bytes, event.bytes());
}

test "a borrowed deliver copies no argument bytes" {
    var counter = CountingAllocator{ .backing = std.testing.allocator };
    var peer = engine.Peer.init(counter.allocator());
    defer peer.deinit();
    try peer.session_state.registerImport(.from(7));

    // The one allocation of the payload's size would be its clone. The
    // deliver is encoded at admission instead, so none happens.
    counter.count_size = "hello".len;
    try peer.sendBorrowed(.{
        .deliver = .{
            .target = .{ .far = .{ .import_position = .from(7) } },
            .args = &.{.{ .bytes = "hello" }},
            .answer = .from(42),
        },
    });
    try std.testing.expectEqual(@as(usize, 0), counter.matching_allocs);
    try std.testing.expect(peer.pending_send.peek().?.item == .encoded);
}

test "peer step encodes pending outbound message" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
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

    try std.testing.expectEqualSlices(
        u8,
        "<10'op:deliver<11'desc:export7+>[5:hello]42+<18'desc:import-object1+>3+>",
        outbound.bytes(),
    );
}

test "peer step uses session CapTP version for outbound encoding" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.init(allocator);
    defer peer.deinit();
    peer.session_state.captp_version = model.CaptpVersion.v1_0;
    try peer.session_state.registerImport(.from(7));
    try peer.session_state.registerExport(.from(99));

    try peer.sendBorrowed(.{
        .deliver = .{
            .target = .{ .far = .{ .import_position = .from(7) } },
            .args = &.{.{ .bytes = "hello" }},
            .answer = .from(42),
            .resolve_me_desc = .{ .near = .{ .export_position = .from(99) } },
        },
    });

    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());

    var outbound = peer.takeOutbound().?;
    defer outbound.deinit();

    try std.testing.expectEqualSlices(
        u8,
        "<10'op:deliver<11'desc:export7+>[5:hello]42+<18'desc:import-object99+>>",
        outbound.bytes(),
    );
}

test "a borrowed deliver's frame is complete before the caller mutates its arguments" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(7));

    var arg_bytes = [_]u8{ 'h', 'e', 'l', 'l', 'o' };
    const args = [_]model.Argument{.{ .bytes = arg_bytes[0..] }};

    try peer.sendBorrowed(.{
        .deliver = .{
            .target = .{ .far = .{ .import_position = .from(7) } },
            .args = args[0..],
            .answer = .from(42),
        },
    });
    arg_bytes[0] = 'j';

    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());

    var outbound = peer.takeOutbound().?;
    defer outbound.deinit();

    try std.testing.expectEqualSlices(
        u8,
        "<10'op:deliver<11'desc:export7+>[5:hello]42+<18'desc:import-object1+>3+>",
        outbound.bytes(),
    );
}

test "peer sendBorrowed deep-copies rich argument payloads" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(7));

    var keyword_bytes = [_]u8{ 'n', 'a', 'm', 'e' };
    var tag_bytes = [_]u8{ 'p', 'o', 'i', 'n', 't' };
    const tagged_values = [_]model.Argument{ .{ .integer = 1 }, .{ .integer = 2 } };
    const set_values = [_]model.Argument{ .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 3 } };
    const args = [_]model.Argument{
        .{ .keyword = keyword_bytes[0..] },
        .{ .tagged = .{ .tag = tag_bytes[0..], .value = tagged_values[0..] } },
        .{ .set = set_values[0..] },
    };

    try peer.sendBorrowed(.{
        .deliver = .{
            .target = .{ .far = .{ .import_position = .from(7) } },
            .args = args[0..],
            .answer = .from(42),
        },
    });
    keyword_bytes[0] = 'X';
    tag_bytes[0] = 'Y';

    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());

    var outbound = peer.takeOutbound().?;
    defer outbound.deinit();

    try std.testing.expectEqualSlices(
        u8,
        "<10'op:deliver<11'desc:export7+>[<2'kw4'name><11'user-record5'point[1+2+]>#1+2+3+$]42+<18'desc:import-object1+>3+>",
        outbound.bytes(),
    );
}

test "peer sendBorrowed does not advance session state when clone allocation fails" {
    var buffer: [512]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(buffer[0..]);
    var peer = engine.Peer.init(fixed.allocator());
    defer peer.deinit();
    try peer.session_state.registerImport(.from(7));

    const too_large = @as([4096]u8, @splat('x'));
    const args = [_]model.Argument{.{ .bytes = too_large[0..] }};

    try std.testing.expectError(error.OutOfMemory, peer.sendBorrowed(.{
        .deliver = .{
            .target = .{ .far = .{ .import_position = .from(7) } },
            .args = args[0..],
            .answer = .from(42),
        },
    }));
    try std.testing.expect(peer.session_state.outboundAnswer(.from(42)) == null);
    try std.testing.expectEqual(engine.StepOutcome.idle, try peer.step());
}

test "recvBorrowed dispatches abort without retaining inbound bytes" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.init(allocator);
    defer peer.deinit();

    var inbound_bytes = [_]u8{ '<', '8', '\'', 'o', 'p', ':', 'a', 'b', 'o', 'r', 't', '3', '"', 'b', 'y', 'e', '>' };
    const view = foundation.FrameView{
        .bytes = inbound_bytes[0..],
        .shape = .byte,
    };

    try peer.recvBorrowed(view);
    inbound_bytes[14] = 'x';

    var event = peer.pollEvent().?;
    defer event.deinit();
    try std.testing.expectEqual(engine.EventKind.abort, event.kind());
    try std.testing.expectEqualStrings("bye", event.view().abort.message);
}

test "feedOwned transfers an owned frame and defers dispatch until step" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.init(allocator);
    defer peer.deinit();

    const storage = try allocator.dupe(u8, "<8'op:abort3\"bye>");
    const frame = try foundation.Frame.initOwned(allocator, storage, .byte, .fromByteUnits(1));

    try peer.feedOwned(frame);
    try std.testing.expect(peer.pollEvent() == null);

    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());

    var event = peer.pollEvent().?;
    defer event.deinit();
    try std.testing.expectEqual(engine.EventKind.abort, event.kind());
    try std.testing.expectEqualStrings("bye", event.view().abort.message);
}

test "feedOwned and recvBorrowed apply decoded messages through the same session path" {
    const allocator = std.testing.allocator;
    var borrowed_peer = engine.Peer.init(allocator);
    defer borrowed_peer.deinit();
    try borrowed_peer.session_state.registerExport(.from(7));

    const deliver_bytes = "<10'op:deliver<11'desc:export7+>[]11+f>";
    try borrowed_peer.recvBorrowed(.{ .bytes = deliver_bytes, .shape = .byte });
    try std.testing.expect(borrowed_peer.session_state.inboundAnswer(.from(11)) != null);

    var owned_peer = engine.Peer.init(allocator);
    defer owned_peer.deinit();
    try owned_peer.session_state.registerExport(.from(7));
    const storage = try allocator.dupe(u8, deliver_bytes);
    const frame = try foundation.Frame.initOwned(allocator, storage, .byte, .fromByteUnits(1));

    try owned_peer.feedOwned(frame);
    try std.testing.expectEqual(engine.StepOutcome.progress, try owned_peer.step());
    try std.testing.expect(owned_peer.session_state.inboundAnswer(.from(11)) != null);
}

test "recvBorrowed surfaces inbound deliver as an application event" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.init(allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    var inbound_bytes = [_]u8{
        '<', '1', '0', '\'', 'o', 'p', ':', 'd', 'e', 'l', 'i', 'v', 'e', 'r',
        '<', '1', '1', '\'', 'd', 'e', 's', 'c', ':', 'e', 'x', 'p', 'o', 'r',
        't', '7', '+', '>',  '[', '5', ':', 'h', 'e', 'l', 'l', 'o', ']', '1',
        '1', '+', 'f', '>',
    };
    try peer.recvBorrowed(.{ .bytes = inbound_bytes[0..], .shape = .byte });
    inbound_bytes[35] = 'j';

    var event = peer.pollEvent().?;
    defer event.deinit();
    try std.testing.expectEqual(engine.EventKind.deliver, event.kind());
    const deliver = event.view().deliver;
    // `<desc:export 7>` (deliver to our export) decodes to `.near` post-flip.
    try std.testing.expectEqual(@as(u64, 7), deliver.target.near.export_position.int());
    try std.testing.expectEqualStrings("hello", (try deliver.args.at(0)).bytes);
    try std.testing.expectEqual(@as(u64, 11), deliver.answer.?.int());
}

test "recvBorrowed does not advance session state when event allocation fails" {
    var failing = FailAfterAllocator{
        .backing = std.testing.allocator,
        .fail_after = std.math.maxInt(usize),
    };
    var peer = engine.Peer.init(failing.allocator());
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));
    failing.fail_after = failing.allocation_count + 1;

    const deliver_bytes = "<10'op:deliver<11'desc:export7+>[]11+f>";
    try std.testing.expectError(
        error.OutOfMemory,
        peer.recvBorrowed(.{ .bytes = deliver_bytes, .shape = .byte }),
    );
    try std.testing.expect(peer.session_state.inboundAnswer(.from(11)) == null);
    try std.testing.expect(peer.pollEvent() == null);
}

test "feedOwned step does not advance session state when event allocation fails" {
    var failing = FailAfterAllocator{
        .backing = std.testing.allocator,
        .fail_after = std.math.maxInt(usize),
    };
    var peer = engine.Peer.init(failing.allocator());
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    const deliver_bytes = "<10'op:deliver<11'desc:export7+>[]11+f>";
    const storage = try std.testing.allocator.dupe(u8, deliver_bytes);
    const frame = try foundation.Frame.initOwned(
        std.testing.allocator,
        storage,
        .byte,
        .fromByteUnits(1),
    );
    try peer.feedOwned(frame);
    failing.fail_after = failing.allocation_count + 1;

    try std.testing.expectError(error.OutOfMemory, peer.step());
    try std.testing.expect(peer.session_state.inboundAnswer(.from(11)) == null);
    try std.testing.expect(peer.pollEvent() == null);
}

test "recvBorrowed surfaces inbound get, index, and listen events" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeerWith(allocator, .{ .captp_version = .v1_0 });
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));
    try peer.session_state.registerImport(.from(9));
    try peer.session_state.registerImport(.from(99));

    try peer.recvBorrowed(.{ .bytes = "<6'op:get<11'desc:export7+>4\"name11+>", .shape = .byte });
    {
        var event = peer.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(engine.EventKind.get, event.kind());
        try std.testing.expectEqualStrings("name", event.view().get.field);
    }
    // The responder (ADR-0050) exports the projected answer immediately. The
    // receiver here is a plain export, which can never settle to a value, so
    // the projection breaks rather than hanging the requester.
    try std.testing.expect(peer.session_state.inboundAnswer(.from(11)) != null);

    try peer.recvBorrowed(.{ .bytes = "<8'op:index<11'desc:export7+>5+12+>", .shape = .byte });
    {
        var event = peer.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(engine.EventKind.index, event.kind());
        try std.testing.expectEqual(@as(i64, 5), event.view().index.index.integer);
    }
    // Likewise op:index is surfaced and its projected answer exported.
    try std.testing.expect(peer.session_state.inboundAnswer(.from(12)) != null);

    try peer.recvBorrowed(.{ .bytes = "<9'op:listen<11'desc:export7+><18'desc:import-object9+>t>", .shape = .byte });
    {
        var event = peer.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(engine.EventKind.listen, event.kind());
        // `<desc:import-object 9>` listener decodes to `.far` post-flip.
        try std.testing.expectEqual(@as(u64, 9), event.view().listen.listener.far.import_position.int());
    }
    // Live object export 7 has no inbound answer row: CapTP already-settled
    // target fires fulfill(near 7) to the listener immediately.
    while ((try peer.step()) != .idle) {}
    {
        const out = try peer_fixture.drainOutbound(&peer, allocator);
        defer allocator.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "fulfill") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "desc:import-object") != null or std.mem.indexOf(u8, out, "desc:export") != null);
    }
}
