//! The private shortening callback: it rewrites future sends onto the
//! shortened position while staying on one wire, cannot rewrite a reused
//! import, leaves protocol maintenance uncommitted on OOM, and its
//! introduced target dies with the shortened source.

const std = @import("std");
const pancake = @import("pancake");

const codec = pancake.ocapn.codec;
const foundation = pancake.foundation;
const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const session = pancake.ocapn.session;
const peer_fixture = @import("../../support/peer_fixture.zig");

const harness = @import("harness.zig");
const FailAfterAllocator = harness.FailAfterAllocator;
const CountingAllocator = harness.CountingAllocator;

test "a private shortening callback rewrites future sends and subscribes to the returned promise" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(5));

    const resolver = model.ExportPosition.from(peer.session_state.next_export_position);
    try engine.listen.ensureShorteningListener(&peer, .from(5));
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }

    const callback_args = [_]model.Argument{
        .{ .symbol = "fulfill" },
        .{ .reference = .{ .near = model.NearRef.promise(6) } },
    };
    var callback = try codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(resolver.int()) },
        .args = &callback_args,
    } });
    defer callback.deinit();
    try peer.recvBorrowed(callback.view());
    try std.testing.expect(peer.pollEvent() == null);
    try std.testing.expect(peer.session_state.holdsImport(.from(6)));

    while ((try peer.step()) != .idle) {}
    var recursive = peer.takeOutbound().?;
    defer recursive.deinit();
    const recursive_body = try codec.syrup.decodeBodyForProfile(.next, recursive.view());
    try std.testing.expect(recursive_body == .listen);
    try std.testing.expectEqual(@as(u64, 6), recursive_body.listen.target.near.export_position.int());
    try std.testing.expectEqual(model.ListenMode.shortening_only, recursive_body.listen.mode);
    try std.testing.expect(peer.takeOutbound() == null);

    try peer.sendCopying(.{ .deliver = .{
        .target = .{ .far = model.FarRef.promise(5) },
        .args = &.{.{ .integer = 1 }},
    } });
    while ((try peer.step()) != .idle) {}
    var forwarded = peer.takeOutbound().?;
    defer forwarded.deinit();
    const forwarded_body = try codec.syrup.decodeBodyForProfile(.next, forwarded.view());
    try std.testing.expect(forwarded_body == .deliver);
    try std.testing.expectEqual(@as(u64, 6), forwarded_body.deliver.target.near.export_position.int());
    try std.testing.expect(peer.takeOutbound() == null);

    try std.testing.expectError(session.Error.UnexpectedMessage, peer.recvBorrowed(callback.view()));
}

test "a shortened deliver moves to the new position and stays on one wire" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(5));

    const shortening_resolver = model.ExportPosition.from(peer.session_state.next_export_position);
    try engine.listen.ensureShorteningListener(&peer, .from(5));
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }

    const before_args = [_]model.Argument{.{ .symbol = "before" }};
    try peer.sendCopying(.{ .deliver = .{
        .target = .{ .far = model.FarRef.promise(5) },
        .args = &before_args,
    } });
    while ((try peer.step()) != .idle) {}
    var before = peer.takeOutbound() orelse return error.MissingDeliverBeforeShortening;
    defer before.deinit();

    // The partner shortens promise 5 onto promise 6.
    const shortening_args = [_]model.Argument{
        .{ .symbol = "fulfill" },
        .{ .reference = .{ .near = model.NearRef.promise(6) } },
    };
    var shortening = try codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(shortening_resolver.int()) },
        .args = &shortening_args,
    } });
    defer shortening.deinit();
    try peer.recvBorrowed(shortening.view());
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }
    try std.testing.expectEqual(
        model.ImportPosition.from(6),
        peer.session_state.shortenedPromiseTarget(.from(5)),
    );

    const after_args = [_]model.Argument{.{ .symbol = "after" }};
    try peer.sendCopying(.{ .deliver = .{
        .target = .{ .far = model.FarRef.promise(5) },
        .args = &after_args,
    } });
    while ((try peer.step()) != .idle) {}
    var after = peer.takeOutbound() orelse return error.MissingDeliverAfterShortening;
    defer after.deinit();

    // The send chokepoint retargets the later deliver onto the shortened
    // position, and that position is an import of this same session. Both
    // frames therefore leave on one wire in send order, the local half of the
    // end-to-end reference FIFO order OCapN PR 281 asks to survive shortening.
    // An edge naming another session would split the pair across two wires.
    const before_body = try codec.syrup.decodeBodyForProfile(.next, before.view());
    const after_body = try codec.syrup.decodeBodyForProfile(.next, after.view());
    try std.testing.expectEqual(@as(u64, 5), before_body.deliver.target.near.export_position.int());
    try std.testing.expectEqual(@as(u64, 6), after_body.deliver.target.near.export_position.int());
    try std.testing.expect(peer.session_state.holdsImport(.from(6)));
    try std.testing.expect(std.mem.indexOf(u8, before.storage, "before") != null);
    try std.testing.expect(std.mem.indexOf(u8, after.storage, "after") != null);
}

test "a delayed shortening callback cannot rewrite a reused import position" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(5));

    const stale_resolver = model.ExportPosition.from(peer.session_state.next_export_position);
    try engine.listen.ensureShorteningListener(&peer, .from(5));
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }

    const positions = [_]u64{5};
    const deltas = [_]u64{1};
    try peer.sendCopying(.{ .gc_export = .{ .positions = &positions, .deltas = &deltas } });
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }
    try std.testing.expect(!peer.session_state.holdsImport(.from(5)));

    // The partner may now reuse position 5 for a distinct promise. Its private
    // listener carries a fresh row stamp even though the wire integer is the
    // same.
    try peer.session_state.registerImport(.from(5));
    try engine.listen.ensureShorteningListener(&peer, .from(5));
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }

    const callback_args = [_]model.Argument{
        .{ .symbol = "fulfill" },
        .{ .reference = .{ .near = model.NearRef.promise(6) } },
    };
    var callback = try codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(stale_resolver.int()) },
        .args = &callback_args,
    } });
    defer callback.deinit();
    try peer.recvBorrowed(callback.view());
    try std.testing.expect(peer.pollEvent() == null);
    try std.testing.expect(peer.session_state.holdsImport(.from(5)));
    try std.testing.expect(!peer.session_state.holdsImport(.from(6)));

    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }
    try peer.sendCopying(.{ .deliver = .{
        .target = .{ .far = model.FarRef.promise(5) },
        .args = &.{},
    } });
    while ((try peer.step()) != .idle) {}
    var sent = peer.takeOutbound().?;
    defer sent.deinit();
    const body = try codec.syrup.decodeBodyForProfile(.next, sent.view());
    try std.testing.expectEqual(@as(u64, 5), body.deliver.target.near.export_position.int());
}

test "shortening callback OOM leaves protocol maintenance uncommitted" {
    const allocator = std.testing.allocator;
    const callback_args = [_]model.Argument{
        .{ .symbol = "fulfill" },
        .{ .reference = .{ .near = model.NearRef.promise(6) } },
    };
    var callback = try codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(1) },
        .args = &callback_args,
    } });
    defer callback.deinit();

    var saw_callback_oom = false;
    var reached_success = false;
    var fail_index: usize = 0;
    while (fail_index < 128 and !reached_success) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        var peer = peer_fixture.openPeer(failing.allocator());
        defer peer.deinit();
        // Teardown may allocate after an injected failure leaves the counter
        // parked, so disarm before the peer's defer runs.
        defer failing.fail_index = std.math.maxInt(usize);

        peer.session_state.registerImport(.from(5)) catch continue;
        engine.listen.ensureShorteningListener(&peer, .from(5)) catch continue;
        while (true) {
            const outcome = peer.step() catch break;
            if (outcome == .idle) break;
        }
        while (peer.takeOutbound()) |frame_in| {
            var frame = frame_in;
            frame.deinit();
        }
        if (peer.session_state.sourceForShorteningResolver(.from(1)) == null) continue;

        if (peer.recvBorrowed(callback.view())) |_| {
            reached_success = true;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            saw_callback_oom = true;
            try std.testing.expect(!peer.session_state.holdsImport(.from(6)));
            switch (peer.session_state.sourceForShorteningResolver(.from(1)).?) {
                .pending => |source| try std.testing.expectEqual(model.ImportPosition.from(5), source.position),
                .complete => return error.TestExpectedPendingShortening,
            }
            try std.testing.expect(peer.session_state.findImportedPromise(.from(6)) == null);
        }
    }
    try std.testing.expect(saw_callback_oom);
    try std.testing.expect(reached_success);
}

test "late shortening callback OOM does not retain its introduced promise" {
    const allocator = std.testing.allocator;
    const callback_args = [_]model.Argument{
        .{ .symbol = "fulfill" },
        .{ .reference = .{ .near = model.NearRef.promise(6) } },
    };
    var callback = try codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(1) },
        .args = &callback_args,
    } });
    defer callback.deinit();

    var saw_callback_oom = false;
    var reached_success = false;
    var fail_index: usize = 0;
    while (fail_index < 128 and !reached_success) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        var peer = peer_fixture.openPeer(failing.allocator());
        defer peer.deinit();
        defer failing.fail_index = std.math.maxInt(usize);

        peer.session_state.registerImport(.from(5)) catch continue;
        engine.listen.ensureShorteningListener(&peer, .from(5)) catch continue;
        while (true) {
            const outcome = peer.step() catch break;
            if (outcome == .idle) break;
        }
        while (peer.takeOutbound()) |frame_in| {
            var frame = frame_in;
            frame.deinit();
        }
        if (peer.session_state.sourceForShorteningResolver(.from(1)) == null) continue;

        const positions = [_]u64{5};
        const deltas = [_]u64{1};
        peer.session_state.recordSend(.{ .gc_export = .{
            .positions = @constCast(&positions),
            .deltas = @constCast(&deltas),
        } }) catch continue;
        try std.testing.expect(!peer.session_state.holdsImport(.from(5)));

        if (peer.recvBorrowed(callback.view())) |_| {
            reached_success = true;
            try std.testing.expect(!peer.session_state.holdsImport(.from(6)));
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            saw_callback_oom = true;
            try std.testing.expect(!peer.session_state.holdsImport(.from(6)));
            switch (peer.session_state.sourceForShorteningResolver(.from(1)).?) {
                .pending => |source| try std.testing.expectEqual(model.ImportPosition.from(5), source.position),
                .complete => return error.TestExpectedPendingShortening,
            }
        }
    }
    try std.testing.expect(saw_callback_oom);
    try std.testing.expect(reached_success);
}

test "a shortening callback crossing source release returns its introduced promise" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(5));

    const resolver = model.ExportPosition.from(peer.session_state.next_export_position);
    try engine.listen.ensureShorteningListener(&peer, .from(5));
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }

    const source_positions = [_]u64{5};
    const source_deltas = [_]u64{1};
    try peer.sendCopying(.{ .gc_export = .{ .positions = &source_positions, .deltas = &source_deltas } });
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }
    try std.testing.expect(!peer.session_state.holdsImport(.from(5)));

    const callback_args = [_]model.Argument{
        .{ .symbol = "fulfill" },
        .{ .reference = .{ .near = model.NearRef.promise(6) } },
    };
    var callback = try codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(resolver.int()) },
        .args = &callback_args,
    } });
    defer callback.deinit();
    try peer.recvBorrowed(callback.view());
    try std.testing.expect(peer.pollEvent() == null);
    try std.testing.expect(!peer.session_state.holdsImport(.from(6)));

    while ((try peer.step()) != .idle) {}
    var released_target = peer.takeOutbound().?;
    defer released_target.deinit();
    const released_body = try codec.syrup.decodeBodyForProfile(.next, released_target.view());
    try std.testing.expect(released_body == .gc_export);
    try std.testing.expectEqual(@as(usize, 1), try released_body.gc_export.positions.len());
    try std.testing.expectEqual(@as(u64, 6), try released_body.gc_export.positions.at(0));
    try std.testing.expect(peer.takeOutbound() == null);

    const resolver_positions = [_]u64{resolver.int()};
    const resolver_deltas = [_]u64{1};
    var release_resolver = try codec.syrup.encodeMessageForProfile(allocator, .next, .{ .gc_export = .{
        .positions = &resolver_positions,
        .deltas = &resolver_deltas,
    } });
    defer release_resolver.deinit();
    try peer.recvBorrowed(release_resolver.view());
    var gc_event = peer.pollEvent().?;
    gc_event.deinit();
    try std.testing.expect(peer.session_state.exportSlot(resolver) == null);
    try std.testing.expect(peer.session_state.sourceForShorteningResolver(resolver) == null);
    try std.testing.expect(peer.session_state.findImportedPromise(.from(5)) == null);
}

test "releasing a shortened source also releases the callback-introduced target" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(5));

    const resolver = model.ExportPosition.from(peer.session_state.next_export_position);
    try engine.listen.ensureShorteningListener(&peer, .from(5));
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }

    const callback_args = [_]model.Argument{
        .{ .symbol = "fulfill" },
        .{ .reference = .{ .near = model.NearRef.promise(6) } },
    };
    var callback = try codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(resolver.int()) },
        .args = &callback_args,
    } });
    defer callback.deinit();
    try peer.recvBorrowed(callback.view());
    try std.testing.expect(peer.session_state.holdsImport(.from(6)));

    // Drain the recursive shortening subscription before observing the GC.
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }

    const source_positions = [_]u64{5};
    const source_deltas = [_]u64{1};
    try peer.sendCopying(.{ .gc_export = .{ .positions = &source_positions, .deltas = &source_deltas } });
    try std.testing.expect(!peer.session_state.holdsImport(.from(5)));
    try std.testing.expect(!peer.session_state.holdsImport(.from(6)));

    while ((try peer.step()) != .idle) {}
    var release = peer.takeOutbound().?;
    defer release.deinit();
    const body = try codec.syrup.decodeBodyForProfile(.next, release.view());
    try std.testing.expect(body == .gc_export);
    try std.testing.expectEqual(@as(usize, 2), try body.gc_export.positions.len());
    try std.testing.expectEqual(@as(u64, 5), try body.gc_export.positions.at(0));
    try std.testing.expectEqual(@as(u64, 6), try body.gc_export.positions.at(1));
    try std.testing.expect(peer.takeOutbound() == null);
}
