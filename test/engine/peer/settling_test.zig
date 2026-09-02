//! Application settling listeners and the op:listen export matrix: a
//! listener follows remote shortening, converging remote promises share one
//! callback, receive failure closes without partial convergence, and release
//! at every seam consumes rather than rearms.

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

test "inbound op:listen export matrix: refuse, fire live object, refuse bare promise" {
    // One table for the export-side listen chokepoint (validate → installExportListener).
    const allocator = std.testing.allocator;
    const wire = "<9'op:listen<11'desc:export7+><18'desc:import-object9+>3+>";

    {
        var features = model.FeatureSet.full();
        features.pipelining = false;
        var peer = peer_fixture.openPeerWith(allocator, .{ .features = features });
        defer peer.deinit();
        try peer.session_state.registerExport(.from(7));
        try peer.session_state.installInboundAnswer(.from(7));
        try std.testing.expectError(
            session.Error.FeatureNotNegotiated,
            peer.recvBorrowed(.{ .bytes = wire, .shape = .byte }),
        );
        try std.testing.expectEqual(@as(usize, 0), peer.session_state.inboundAnswer(.from(7)).?.listeners);
        try std.testing.expect(!peer.session_state.hasImport(.from(9)));
        try std.testing.expect(peer.pollEvent() == null);
    }
    {
        var peer = peer_fixture.openPeer(allocator);
        defer peer.deinit();
        try peer.session_state.installInboundAnswer(.from(7));
        try std.testing.expectError(
            session.Error.InvalidReference,
            peer.recvBorrowed(.{ .bytes = wire, .shape = .byte }),
        );
        try std.testing.expectEqual(@as(usize, 0), peer.session_state.inboundAnswer(.from(7)).?.listeners);
        try std.testing.expect(!peer.session_state.hasImport(.from(9)));
        try std.testing.expect(peer.pollEvent() == null);
    }
    {
        var peer = peer_fixture.openPeer(allocator);
        defer peer.deinit();
        try peer.session_state.registerExport(.from(7));
        try peer.recvBorrowed(.{ .bytes = wire, .shape = .byte });
        {
            var event = peer.pollEvent().?;
            defer event.deinit();
            try std.testing.expectEqual(engine.EventKind.listen, event.kind());
        }
        try std.testing.expect(peer.session_state.hasImport(.from(9)));
        try std.testing.expect(peer.session_state.inboundAnswer(.from(7)) == null);
        while ((try peer.step()) != .idle) {}
        const out = try peer_fixture.drainOutbound(&peer, allocator);
        defer allocator.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "op:deliver") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "fulfill") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "desc:import-object") != null);
    }
    {
        var peer = peer_fixture.openPeer(allocator);
        defer peer.deinit();
        const promise_export = try peer.session_state.allocatePromiseExport();
        try peer.session_state.registerExport(promise_export);
        const listen_bytes = try std.fmt.allocPrint(
            allocator,
            "<9'op:listen<11'desc:export{d}+><18'desc:import-object9+>3+>",
            .{promise_export.int()},
        );
        defer allocator.free(listen_bytes);
        try std.testing.expectError(
            session.Error.InvalidReference,
            peer.recvBorrowed(.{ .bytes = listen_bytes, .shape = .byte }),
        );
        try std.testing.expect(!peer.session_state.hasImport(.from(9)));
        try std.testing.expect(peer.pollEvent() == null);
    }
}

test "live object export listen: OOM during enqueue does not leak" {
    var fail_index: usize = 0;
    var saw_oom = false;
    while (fail_index < 32) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var peer = peer_fixture.openPeer(failing.allocator());
        defer peer.deinit();
        peer.session_state.registerExport(.from(7)) catch {
            saw_oom = true;
            continue;
        };
        const listen = peer.recvBorrowed(.{
            .bytes = "<9'op:listen<11'desc:export7+><18'desc:import-object9+>3+>",
            .shape = .byte,
        });
        if (listen) |_| {
            while (peer.pollEvent()) |event_value| {
                var event = event_value;
                event.deinit();
            }
            while (true) {
                const step = peer.step() catch {
                    saw_oom = true;
                    break;
                };
                if (step == .idle) break;
            }
        } else |_| {
            saw_oom = true;
        }
    }
    try std.testing.expect(saw_oom);
}

test "an application settling listener follows a remote promise shortening" {
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

    const answer = try engine.listen.listenOnFar(&peer, .{ .far = model.FarRef.promise(5) });
    const settling_resolver = peer.session_state.outbound_resolver_link.getByValue(.{
        .application_answer = answer,
    }).?;
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }

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
    var private = peer.takeOutbound().?;
    defer private.deinit();
    var rearmed = peer.takeOutbound().?;
    defer rearmed.deinit();
    const private_body = try codec.syrup.decodeBodyForProfile(.next, private.view());
    const rearmed_body = try codec.syrup.decodeBodyForProfile(.next, rearmed.view());
    try std.testing.expectEqual(model.ListenMode.shortening_only, private_body.listen.mode);
    try std.testing.expectEqual(model.ListenMode.settling_only, rearmed_body.listen.mode);
    try std.testing.expectEqual(@as(u64, 6), rearmed_body.listen.target.near.export_position.int());
    try std.testing.expectEqual(settling_resolver.int(), rearmed_body.listen.listener.far.import_position.int());

    const settlement_args = [_]model.Argument{
        .{ .symbol = "fulfill" },
        .{ .integer = 17 },
    };
    var settlement = try codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(settling_resolver.int()) },
        .args = &settlement_args,
    } });
    defer settlement.deinit();
    try peer.recvBorrowed(settlement.view());
    var event = peer.pollEvent().?;
    defer event.deinit();
    const resolved = try event.view();
    try std.testing.expectEqual(answer, resolved.resolve.answer);
}

test "converging remote promises share one settling callback across local answers" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(5));
    try peer.session_state.registerImport(.from(6));

    const shortening_five = model.ExportPosition.from(peer.session_state.next_export_position);
    try engine.listen.ensureShorteningListener(&peer, .from(5));
    const shortening_six = model.ExportPosition.from(peer.session_state.next_export_position);
    try engine.listen.ensureShorteningListener(&peer, .from(6));
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }

    const answer_five = try engine.listen.listenOnFar(&peer, .{ .far = model.FarRef.promise(5) });
    const resolver_five = peer.session_state.outbound_resolver_link.getByValue(.{
        .application_answer = answer_five,
    }).?;
    const answer_six = try engine.listen.listenOnFar(&peer, .{ .far = model.FarRef.promise(6) });
    const resolver_six = peer.session_state.outbound_resolver_link.getByValue(.{
        .application_answer = answer_six,
    }).?;
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }

    const shortening_args = [_]model.Argument{
        .{ .symbol = "fulfill" },
        .{ .reference = .{ .near = model.NearRef.promise(6) } },
    };
    var shortening = try codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(shortening_five.int()) },
        .args = &shortening_args,
    } });
    defer shortening.deinit();
    try peer.recvBorrowed(shortening.view());
    try std.testing.expect(peer.pollEvent() == null);
    while ((try peer.step()) != .idle) {}
    // Promise 6 already owns both permitted wire listeners. Convergence is a
    // local fan-out change and emits no second settling listener.
    try std.testing.expect(peer.takeOutbound() == null);
    try std.testing.expect(peer.session_state.sourceForShorteningResolver(shortening_six) != null);
    try std.testing.expect(peer.session_state.outbound_resolver_link.getByValue(.{
        .application_answer = answer_five,
    }) == null);
    try std.testing.expectEqual(resolver_six, peer.session_state.outbound_resolver_link.getByValue(.{
        .application_answer = answer_six,
    }).?);
    try std.testing.expect(peer.session_state.exportSlot(resolver_five) != null);

    const settlement_args = [_]model.Argument{
        .{ .symbol = "fulfill" },
        .{ .integer = 17 },
    };
    var settlement = try codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(resolver_six.int()) },
        .args = &settlement_args,
    } });
    defer settlement.deinit();
    try peer.recvBorrowed(settlement.view());
    var event = peer.pollEvent().?;
    defer event.deinit();
    const resolved = try event.view();
    try std.testing.expectEqual(answer_six, resolved.resolve.answer);
    try std.testing.expectEqualSlices(model.AnswerPosition, &.{answer_five}, event.resolveAliases());
    try std.testing.expectEqual(session.AnswerStatus.fulfilled, peer.session_state.outboundAnswer(answer_five).?.status);
    try std.testing.expectEqual(session.AnswerStatus.fulfilled, peer.session_state.outboundAnswer(answer_six).?.status);
    try std.testing.expect(peer.pollEvent() == null);
}

test "converged settling callback promotes or removes a released local answer" {
    const allocator = std.testing.allocator;
    for ([_]bool{ false, true }) |release_primary| {
        var peer = peer_fixture.openPeer(allocator);
        defer peer.deinit();
        try peer.session_state.registerImport(.from(5));
        try peer.session_state.registerImport(.from(6));

        const shortening_five = model.ExportPosition.from(peer.session_state.next_export_position);
        try engine.listen.ensureShorteningListener(&peer, .from(5));
        try engine.listen.ensureShorteningListener(&peer, .from(6));
        while ((try peer.step()) != .idle) {}
        while (peer.takeOutbound()) |frame_in| {
            var frame = frame_in;
            frame.deinit();
        }

        const answer_five = try engine.listen.listenOnFar(&peer, .{ .far = model.FarRef.promise(5) });
        const answer_six = try engine.listen.listenOnFar(&peer, .{ .far = model.FarRef.promise(6) });
        const resolver_six = peer.session_state.outbound_resolver_link.getByValue(.{
            .application_answer = answer_six,
        }).?;
        while ((try peer.step()) != .idle) {}
        while (peer.takeOutbound()) |frame_in| {
            var frame = frame_in;
            frame.deinit();
        }

        var shortening = try codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
            .target = .{ .far = model.FarRef.object(shortening_five.int()) },
            .args = &.{
                .{ .symbol = "fulfill" },
                .{ .reference = .{ .near = model.NearRef.promise(6) } },
            },
        } });
        defer shortening.deinit();
        try peer.recvBorrowed(shortening.view());
        while ((try peer.step()) != .idle) {}
        while (peer.takeOutbound()) |frame_in| {
            var frame = frame_in;
            frame.deinit();
        }

        const released = if (release_primary) answer_six else answer_five;
        const survivor = if (release_primary) answer_five else answer_six;
        try peer.sendCopying(.{ .gc_answer = .{ .positions = &.{released.int()} } });
        while ((try peer.step()) != .idle) {}
        while (peer.takeOutbound()) |frame_in| {
            var frame = frame_in;
            frame.deinit();
        }
        try std.testing.expect(peer.session_state.outboundAnswer(released) == null);
        try std.testing.expectEqual(resolver_six, peer.session_state.outbound_resolver_link.getByValue(.{
            .application_answer = survivor,
        }).?);

        var settlement = try codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
            .target = .{ .far = model.FarRef.object(resolver_six.int()) },
            .args = &.{ .{ .symbol = "fulfill" }, .{ .integer = 17 } },
        } });
        defer settlement.deinit();
        try peer.recvBorrowed(settlement.view());
        var event = peer.pollEvent().?;
        defer event.deinit();
        const resolved = try event.view();
        try std.testing.expectEqual(survivor, resolved.resolve.answer);
        try std.testing.expectEqual(@as(usize, 0), event.resolveAliases().len);
    }
}

test "a settling callback racing answer release is consumed and its imports are released" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(5));

    try engine.listen.ensureShorteningListener(&peer, .from(5));
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }
    const answer = try engine.listen.listenOnFar(&peer, .{ .far = model.FarRef.promise(5) });
    const resolver = peer.session_state.outbound_resolver_link.getByValue(.{
        .application_answer = answer,
    }).?;
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }

    try peer.sendCopying(.{ .gc_answer = .{ .positions = &.{answer.int()} } });
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }
    try std.testing.expectEqual(session.RetiredResolverState.pending, peer.session_state.retiredResolverState(resolver).?);

    var callback = try codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(resolver.int()) },
        .args = &.{
            .{ .symbol = "fulfill" },
            .{ .reference = .{ .near = model.NearRef.object(77) } },
        },
    } });
    defer callback.deinit();
    try peer.recvBorrowed(callback.view());
    try std.testing.expect(peer.pollEvent() == null);
    try std.testing.expectEqual(session.RetiredResolverState.complete, peer.session_state.retiredResolverState(resolver).?);
    while ((try peer.step()) != .idle) {}
    var release = peer.takeOutbound().?;
    defer release.deinit();
    const release_body = try codec.syrup.decodeBodyForProfile(.next, release.view());
    try std.testing.expectEqual(@as(usize, 1), try release_body.gc_export.positions.len());
    try std.testing.expectEqual(@as(u64, 77), try release_body.gc_export.positions.at(0));
    try std.testing.expectEqual(@as(usize, 1), try release_body.gc_export.deltas.len());
    try std.testing.expectEqual(@as(u64, 1), try release_body.gc_export.deltas.at(0));
    try std.testing.expect(peer.takeOutbound() == null);

    try std.testing.expectError(session.Error.UnexpectedMessage, peer.recvBorrowed(callback.view()));
}

test "settling convergence OOM closes without partially shortening either subscription" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var peer = peer_fixture.openPeer(failing.allocator());
    defer peer.deinit();
    defer failing.fail_index = std.math.maxInt(usize);
    try peer.session_state.registerImport(.from(5));
    try peer.session_state.registerImport(.from(6));

    const shortening_five = model.ExportPosition.from(peer.session_state.next_export_position);
    try engine.listen.ensureShorteningListener(&peer, .from(5));
    try engine.listen.ensureShorteningListener(&peer, .from(6));
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }
    const answer_five = try engine.listen.listenOnFar(&peer, .{ .far = model.FarRef.promise(5) });
    const resolver_five = peer.session_state.outbound_resolver_link.getByValue(.{
        .application_answer = answer_five,
    }).?;
    const answer_six = try engine.listen.listenOnFar(&peer, .{ .far = model.FarRef.promise(6) });
    const resolver_six = peer.session_state.outbound_resolver_link.getByValue(.{
        .application_answer = answer_six,
    }).?;
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }

    const shortening_message: model.Message = .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(shortening_five.int()) },
        .args = &.{
            .{ .symbol = "fulfill" },
            .{ .reference = .{ .near = model.NearRef.promise(6) } },
        },
    } };
    var failed_frame = try codec.syrup.encodeMessageForProfile(std.testing.allocator, .next, shortening_message);
    defer failed_frame.deinit();
    // The borrowed-frame ownership copy succeeds; the next allocation belongs
    // to callback validation or the precommitted merged follower list.
    failing.fail_index = failing.alloc_index + 1;
    try std.testing.expectError(error.OutOfMemory, peer.recvBorrowed(failed_frame.view()));
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectEqual(session.State.closed, peer.session_state.state);

    try std.testing.expectEqual(resolver_five, peer.session_state.outbound_resolver_link.getByValue(.{
        .application_answer = answer_five,
    }).?);
    try std.testing.expectEqual(resolver_six, peer.session_state.outbound_resolver_link.getByValue(.{
        .application_answer = answer_six,
    }).?);
    try std.testing.expectEqual(
        model.ImportPosition.from(5),
        peer.session_state.shortenedPromiseTarget(.from(5)),
    );

    // `recvBorrowed` copied the caller's bytes into an owned carrier. That
    // carrier is consumed even when admission fails, so replaying the caller's
    // borrow on the same session would invent retry semantics the receive
    // boundary cannot honor.
    try std.testing.expectError(session.Error.SessionClosed, peer.recvBorrowed(failed_frame.view()));
    try std.testing.expectEqual(resolver_five, peer.session_state.outbound_resolver_link.getByValue(.{
        .application_answer = answer_five,
    }).?);
    try std.testing.expectEqual(resolver_six, peer.session_state.outbound_resolver_link.getByValue(.{
        .application_answer = answer_six,
    }).?);
}

test "an application settling listener starts at an already-shortened promise" {
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

    _ = try engine.listen.listenOnFar(&peer, .{ .far = model.FarRef.promise(5) });
    while ((try peer.step()) != .idle) {}
    var settling = peer.takeOutbound().?;
    defer settling.deinit();
    const body = try codec.syrup.decodeBodyForProfile(.next, settling.view());
    try std.testing.expectEqual(model.ListenMode.settling_only, body.listen.mode);
    try std.testing.expectEqual(@as(u64, 6), body.listen.target.near.export_position.int());
}

test "a settling listener follows shortening after its source import is released" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(5));

    const shortening_resolver = model.ExportPosition.from(peer.session_state.next_export_position);
    try engine.listen.ensureShorteningListener(&peer, .from(5));
    const answer = try engine.listen.listenOnFar(&peer, .{ .far = model.FarRef.promise(5) });
    const settling_resolver = peer.session_state.outbound_resolver_link.getByValue(.{
        .application_answer = answer,
    }).?;
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }

    try peer.sendCopying(.{ .gc_export = .{
        .positions = &.{5},
        .deltas = &.{1},
    } });
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }
    try std.testing.expect(!peer.session_state.holdsImport(.from(5)));

    var shortening = try codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(shortening_resolver.int()) },
        .args = &.{
            .{ .symbol = "fulfill" },
            .{ .reference = .{ .near = model.NearRef.promise(6) } },
        },
    } });
    defer shortening.deinit();
    try peer.recvBorrowed(shortening.view());
    try std.testing.expect(peer.pollEvent() == null);
    while ((try peer.step()) != .idle) {}

    var shortening_listen = peer.takeOutbound().?;
    defer shortening_listen.deinit();
    var settling_listen = peer.takeOutbound().?;
    defer settling_listen.deinit();
    var release_target = peer.takeOutbound().?;
    defer release_target.deinit();
    const shortening_body = try codec.syrup.decodeBodyForProfile(.next, shortening_listen.view());
    const settling_body = try codec.syrup.decodeBodyForProfile(.next, settling_listen.view());
    const release_body = try codec.syrup.decodeBodyForProfile(.next, release_target.view());
    try std.testing.expectEqual(model.ListenMode.shortening_only, shortening_body.listen.mode);
    try std.testing.expectEqual(model.ListenMode.settling_only, settling_body.listen.mode);
    try std.testing.expectEqual(settling_resolver.int(), settling_body.listen.listener.far.import_position.int());
    try std.testing.expectEqual(@as(u64, 6), try release_body.gc_export.positions.at(0));
    try std.testing.expect(!peer.session_state.holdsImport(.from(6)));
    try std.testing.expect(peer.takeOutbound() == null);

    var settlement = try codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(settling_resolver.int()) },
        .args = &.{ .{ .symbol = "fulfill" }, .{ .integer = 17 } },
    } });
    defer settlement.deinit();
    try peer.recvBorrowed(settlement.view());
    var event = peer.pollEvent().?;
    defer event.deinit();
    const resolved = try event.view();
    try std.testing.expectEqual(answer, resolved.resolve.answer);
    try std.testing.expectEqual(@as(i64, 17), resolved.resolve.resolution.fulfill.integer);
}

test "shortening does not rearm a settling listener after its answer is released" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(5));

    const shortening_resolver = model.ExportPosition.from(peer.session_state.next_export_position);
    try engine.listen.ensureShorteningListener(&peer, .from(5));
    const answer = try engine.listen.listenOnFar(&peer, .{ .far = model.FarRef.promise(5) });
    const settling_resolver = peer.session_state.outbound_resolver_link.getByValue(.{
        .application_answer = answer,
    }).?;
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }

    try peer.sendCopying(.{ .gc_answer = .{ .positions = &.{answer.int()} } });
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }
    try std.testing.expectEqual(session.RetiredResolverState.pending, peer.session_state.retiredResolverState(settling_resolver).?);

    var shortening = try codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(shortening_resolver.int()) },
        .args = &.{
            .{ .symbol = "fulfill" },
            .{ .reference = .{ .near = model.NearRef.promise(6) } },
        },
    } });
    defer shortening.deinit();
    try peer.recvBorrowed(shortening.view());
    while ((try peer.step()) != .idle) {}

    var only_shortening = peer.takeOutbound().?;
    defer only_shortening.deinit();
    const body = try codec.syrup.decodeBodyForProfile(.next, only_shortening.view());
    try std.testing.expectEqual(model.ListenMode.shortening_only, body.listen.mode);
    try std.testing.expect(peer.takeOutbound() == null);
    try std.testing.expectEqual(session.RetiredResolverState.complete, peer.session_state.retiredResolverState(settling_resolver).?);
}

test "a discarded shortening listener remains deduplicated until source release" {
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
    try std.testing.expect(peer.session_state.sourceForShorteningResolver(resolver).? == .complete);

    try engine.listen.ensureShorteningListener(&peer, .from(5));
    try std.testing.expect((try peer.step()) == .idle);
    try std.testing.expect(peer.takeOutbound() == null);

    const source_positions = [_]u64{5};
    const source_deltas = [_]u64{1};
    try peer.sendCopying(.{ .gc_export = .{ .positions = &source_positions, .deltas = &source_deltas } });
    try std.testing.expect(peer.session_state.sourceForShorteningResolver(resolver) == null);
}
