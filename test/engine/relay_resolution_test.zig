//! Relayed-resolution substrate units (ADR-0009).
//!
//! Stamp/GC and resolve-once edge cases for `Peer.applyRelayedResolution` and
//! `installThirdPartyImport`. The production introducing-session path is
//! `Node.proxyForeignPromiseFulfill` (Host-driven); Node scenarios live in
//! `test/engine/node/`. Enroll-stamped `row_id` covers the deferred
//! window these units open by applying after session mutation.

const std = @import("std");
const glowcap = @import("glowcap");

const codec = glowcap.ocapn.codec;
const foundation = glowcap.foundation;
const engine = glowcap.ocapn.engine;
const model = glowcap.ocapn.model;
const peer_fixture = @import("../support/peer_fixture.zig");

fn applyRelayed(peer: *engine.Peer, import_pos: u64, resolution: model.Resolution) !void {
    const position = model.ImportPosition.from(import_pos);
    const row_id = peer.session_state.importedPromiseRowId(position) orelse 0;
    try peer.applyRelayedResolution(position, row_id, resolution);
}

fn expectListenerRelease(peer: *engine.Peer, expected_position: u64) !void {
    var frame = peer.takeOutbound() orelse return error.MissingListenerRelease;
    defer frame.deinit();
    const body = try codec.syrup.decodeBody(frame.view());
    try std.testing.expect(body == .gc_export);
    try std.testing.expectEqual(@as(usize, 1), try body.gc_export.positions.len());
    try std.testing.expectEqual(expected_position, try body.gc_export.positions.at(0));
    try std.testing.expectEqual(@as(usize, 1), try body.gc_export.deltas.len());
    try std.testing.expectEqual(@as(u64, 1), try body.gc_export.deltas.at(0));
}

test "relayed settlement backpressure restores the store and every listener" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();

    try peer.session_state.installThirdPartyImport(.from(5), "exporter");
    try peer.session_state.registerImport(.from(9));
    try peer.session_state.installImportedPromiseListener(.from(5), .{
        .listener = model.FarRef.object(9),
        .mode = .settling_only,
    });

    peer.outbound_budget = 1;
    try std.testing.expectError(error.OutboundBackpressure, applyRelayed(
        &peer,
        5,
        .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "first") } },
    ));
    try std.testing.expect(peer.session_state.importedPromiseResolution(.from(5)) == null);
    const restored = try peer.session_state.takeImportedPromiseListeners(.from(5));
    try std.testing.expectEqual(@as(usize, 1), restored.len);
    peer.session_state.restoreImportedPromiseListeners(.from(5), restored);

    peer.outbound_budget = std.math.maxInt(usize);
    try applyRelayed(
        &peer,
        5,
        .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "retry") } },
    );
    try std.testing.expectEqualStrings(
        "retry",
        peer.session_state.importedPromiseResolution(.from(5)).?.fulfill.bytes,
    );
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    var frame = peer.takeOutbound() orelse return error.MissingListenerFire;
    frame.deinit();
    try expectListenerRelease(&peer, 9);
    try std.testing.expectEqual(engine.StepOutcome.idle, try peer.step());
    try std.testing.expect(peer.takeOutbound() == null);
}

test "relayed promise listener modes fire only their requested transition" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();

    try peer.session_state.installThirdPartyImport(.from(5), "exporter");
    try peer.session_state.registerImport(.from(9));
    try peer.session_state.registerImport(.from(10));
    try peer.session_state.registerImport(.from(12));
    try peer.session_state.installImportedPromiseListener(.from(5), .{
        .listener = model.FarRef.object(9),
        .mode = .settling_only,
    });
    try peer.session_state.installImportedPromiseListener(.from(5), .{
        .listener = model.FarRef.object(10),
        .mode = .shortening_only,
    });

    try applyRelayed(&peer, 5, .{ .fulfill = .{
        .reference = .{ .far = model.FarRef.promise(12) },
    } });
    try std.testing.expect(!peer.session_state.hasImport(.from(9)));
    try std.testing.expect(peer.session_state.hasImport(.from(10)));

    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    var callback = peer.takeOutbound().?;
    defer callback.deinit();
    const body = try codec.syrup.decodeBodyForProfile(
        peer.session_state.captp_version,
        callback.view(),
    );
    try std.testing.expectEqual(@as(u64, 10), body.deliver.target.near.export_position.int());
    try expectListenerRelease(&peer, 10);
    try std.testing.expect(!peer.session_state.hasImport(.from(10)));
    try std.testing.expect(peer.takeOutbound() == null);
}

test "invalid inbound listen roles refuse before listener state mutates" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.init(allocator);
    defer peer.deinit();

    // A third-party import is live authority, but inbound `desc:import-promise`
    // is still the wrong target role. Refuse before registering the introduced
    // listener import or appending it to the relayed-promise row.
    try peer.session_state.installThirdPartyImport(.from(5), "exporter");
    const wrong_target = model.Message{ .listen = .{
        .target = .{ .far = model.FarRef.promise(5) },
        .listener = .{ .far = model.FarRef.object(9) },
        .mode = .settling_only,
    } };
    try std.testing.expectError(
        error.InvalidReference,
        engine.pipeline.maybeInstallInboundListener(&peer, model.view.Body.fromOwned(&wrong_target).listen),
    );
    try std.testing.expect(!peer.session_state.hasImport(.from(9)));
    const imported_listeners = try peer.session_state.takeImportedPromiseListeners(.from(5));
    defer if (imported_listeners.len > 0) allocator.free(imported_listeners);
    try std.testing.expectEqual(@as(usize, 0), imported_listeners.len);

    // A live answer target does not rescue a listener in the wrong descriptor
    // role. The answer's listener list and the candidate import stay untouched.
    try peer.session_state.registerExport(.from(1));
    try peer.session_state.registerExport(.from(10));
    try peer.session_state.recordRecv(.{ .deliver = .{
        .target = .{ .near = model.NearRef.object(1) },
        .args = &.{},
        .answer = .from(7),
    } });
    const wrong_listener = model.Message{ .listen = .{
        .target = .{ .promise = .{ .answer_position = .from(7) } },
        .listener = .{ .near = model.NearRef.object(10) },
        .mode = .settling_only,
    } };
    try std.testing.expectError(
        error.InvalidReference,
        engine.pipeline.maybeInstallInboundListener(&peer, model.view.Body.fromOwned(&wrong_listener).listen),
    );
    const answer_listeners = try peer.session_state.takePipelinedListeners(.from(7));
    defer if (answer_listeners.len > 0) allocator.free(answer_listeners);
    try std.testing.expectEqual(@as(usize, 0), answer_listeners.len);

    // Unknown desc:answer is rejected before its otherwise valid listener is
    // introduced.
    const dead_answer = model.Message{ .listen = .{
        .target = .{ .promise = .{ .answer_position = .from(99) } },
        .listener = .{ .far = model.FarRef.object(11) },
        .mode = .settling_only,
    } };
    try std.testing.expectError(
        error.InvalidReference,
        engine.pipeline.maybeInstallInboundListener(&peer, model.view.Body.fromOwned(&dead_answer).listen),
    );
    try std.testing.expect(!peer.session_state.hasImport(.from(11)));
}

test "listen descriptor selects export namespace when answer integer collides" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.init(allocator);
    defer peer.deinit();

    try peer.session_state.registerExport(.from(1));
    try peer.session_state.registerExport(.from(5));
    try peer.session_state.recordRecv(.{ .deliver = .{
        .target = .{ .near = model.NearRef.object(1) },
        .args = &.{},
        .answer = .from(5),
    } });

    // The target is desc:export 5 (`near` after decode), so export 5 wins even
    // though answer 5 is also live. A live object export fires immediately; it
    // must not append this listener to the numerically equal answer row.
    const listen = model.Message{ .listen = .{
        .target = .{ .near = model.NearRef.object(5) },
        .listener = .{ .far = model.FarRef.object(9) },
        .mode = .settling_only,
    } };
    try engine.pipeline.maybeInstallInboundListener(&peer, model.view.Body.fromOwned(&listen).listen);
    const answer_listeners = try peer.session_state.takePipelinedListeners(.from(5));
    defer if (answer_listeners.len > 0) allocator.free(answer_listeners);
    try std.testing.expectEqual(@as(usize, 0), answer_listeners.len);
    try std.testing.expect(peer.session_state.hasImport(.from(9)));
}

test "a bare promise export does not infer an answer from numeric coincidence" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.init(allocator);
    defer peer.deinit();

    const promise_export = try peer.session_state.allocatePromiseExport();
    try peer.session_state.exports.retain(allocator, promise_export);
    const coincident_answer = promise_export.reinterpret(model.AnswerPosition);
    try peer.session_state.installInboundAnswer(coincident_answer);

    const listen = model.Message{ .listen = .{
        .target = .{ .near = model.NearRef.promise(promise_export.int()) },
        .listener = .{ .far = model.FarRef.object(9) },
        .mode = .settling_only,
    } };
    try std.testing.expectError(
        error.InvalidReference,
        engine.pipeline.maybeInstallInboundListener(&peer, model.view.Body.fromOwned(&listen).listen),
    );
    const listeners = try peer.session_state.takePipelinedListeners(coincident_answer);
    defer if (listeners.len > 0) allocator.free(listeners);
    try std.testing.expectEqual(@as(usize, 0), listeners.len);
    try std.testing.expect(!peer.session_state.hasImport(.from(9)));
}

test "listen on a local promise export installs on its backing answer" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.init(allocator);
    defer peer.deinit();

    const projection = try peer.session_state.allocateLocalPromiseProjection();
    const promise_export = projection.export_position;
    try peer.session_state.exports.retain(allocator, promise_export);
    const answer = projection.answer_name;

    const listen = model.Message{ .listen = .{
        .target = .{ .near = model.NearRef.promise(promise_export.int()) },
        .listener = .{ .far = model.FarRef.object(9) },
        .mode = .settling_only,
    } };
    try engine.pipeline.maybeInstallInboundListener(&peer, model.view.Body.fromOwned(&listen).listen);
    const listeners = try peer.session_state.takePipelinedListenersNamed(answer);
    defer allocator.free(listeners);
    try std.testing.expectEqual(@as(usize, 1), listeners.len);
    try std.testing.expectEqual(@as(u64, 9), listeners[0].listener.import_position.int());
}

test "CapTP-normal desc:export listen on a proxied promise export installs a relayed-resolution listener" {
    const allocator = std.testing.allocator;
    var holder = engine.Peer.init(allocator);
    defer holder.deinit();
    var partner = engine.Peer.init(allocator);
    defer partner.deinit();

    // Introducing-session proxy mint: promise export + third-party import at
    // the same position (what `proxyForeignPromiseFulfill` installs). Grant
    // wire addressability as if the near-promise rewrite already crossed the
    // wire in a fulfill (inbound `<desc:export>` requires wireHeld > 0).
    const export_pos = try holder.session_state.allocatePromiseExport();
    try holder.session_state.exports.retain(allocator, export_pos);
    try holder.session_state.installThirdPartyImport(.from(export_pos.int()), "home");
    try partner.session_state.registerImport(.from(export_pos.int()));
    try partner.session_state.registerExport(.from(9));

    // Partner holds import N and listens with Goblins/suite encoding:
    // sender `.far` → wire `<desc:export N>` → holder receives `.near`.
    try partner.sendCopying(.{ .listen = .{
        .target = .{ .far = model.FarRef.promise(export_pos.int()) },
        .listener = .{ .near = .{ .export_position = .from(9) } },
        .mode = .settling_only,
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try partner.step());
    try holder.feedOwned(partner.takeOutbound().?);
    try std.testing.expectEqual(engine.StepOutcome.progress, try holder.step());
    {
        var event = holder.pollEvent().?;
        event.deinit();
    }

    try applyRelayed(&holder, export_pos.int(), .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "via-export") } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try holder.step());
    try partner.feedOwned(holder.takeOutbound().?);
    try expectListenerRelease(&holder, 9);
    try std.testing.expectEqual(engine.StepOutcome.progress, try partner.step());

    var fire_event = partner.pollEvent().?;
    defer fire_event.deinit();
    const view = try fire_event.view();
    try std.testing.expect(view.deliver.target == .near);
    try std.testing.expectEqual(@as(u64, 9), view.deliver.target.near.export_position.int());
    try std.testing.expectEqualStrings("via-export", (try view.deliver.args.at(1)).bytes);
}

test "a listen on an already-resolved handoff-imported promise fires immediately" {
    const allocator = std.testing.allocator;
    var p1 = engine.Peer.init(allocator);
    defer p1.deinit();
    var p2 = engine.Peer.init(allocator);
    defer p2.deinit();

    const export_pos = try p2.session_state.allocatePromiseExport();
    try p2.session_state.exports.retain(allocator, export_pos);
    try p2.session_state.installThirdPartyImport(.from(export_pos.int()), "exporter");
    try p1.session_state.registerImport(.from(export_pos.int()));
    try p1.session_state.registerExport(.from(9));

    // Relay the resolution before any listener exists: it is stored, nothing fires.
    try applyRelayed(&p2, export_pos.int(), .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "early") } });
    try std.testing.expect(p2.takeOutbound() == null);

    // p1 listens; p2 installs the listener and fires it immediately from the
    // stored resolution.
    try p1.sendCopying(.{ .listen = .{
        .target = .{ .far = model.FarRef.promise(export_pos.int()) },
        .listener = .{ .near = .{ .export_position = .from(9) } },
        .mode = .settling_only,
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    try p2.feedOwned(p1.takeOutbound().?);
    // Step 1 processes the listen and enqueues the immediate fire; step 2 encodes it.
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    {
        var event = p2.pollEvent().?;
        event.deinit();
    }
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());

    try p1.feedOwned(p2.takeOutbound().?);
    try expectListenerRelease(&p2, 9);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    var fire_event = p1.pollEvent().?;
    defer fire_event.deinit();
    const view = try fire_event.view();
    // The fire targets our own export 9, so it arrives as `.near` post-flip.
    try std.testing.expect(view.deliver.target == .near);
    try std.testing.expectEqual(@as(u64, 9), view.deliver.target.near.export_position.int());
    try std.testing.expectEqualStrings("early", (try view.deliver.args.at(1)).bytes);
}

test "a second relayed resolution is refused — a handoff-imported promise resolves once" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.init(allocator);
    defer peer.deinit();

    try peer.session_state.installThirdPartyImport(.from(5), "exporter");
    try peer.session_state.registerImport(.from(9));
    try peer.session_state.installImportedPromiseListener(.from(5), .{ .listener = .{ .import_position = .from(9) }, .mode = .settling_only });

    // First relay fires the listener (far 9) and stores the resolution.
    try applyRelayed(&peer, 5, .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "first") } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    {
        var frame = peer.takeOutbound().?;
        defer frame.deinit();
        // Decoding our own outbound frame applies the receiver-perspective flip:
        // the fire's `far` import 9 was encoded `<desc:export 9>`, which decodes
        // to `.near{export_position=9}` (the partner's view of its own export).
        const view = try codec.syrup.decodeBody(frame.view());
        try std.testing.expectEqual(@as(u64, 9), view.deliver.target.near.export_position.int());
        try std.testing.expectEqualStrings("first", (try view.deliver.args.at(1)).bytes);
    }
    try expectListenerRelease(&peer, 9);

    // A second relay for the already-settled promise is refused (a promise
    // resolves once, mirroring the answer-side rule), the refused resolution
    // is freed (the testing allocator holds the no-leak contract), and the
    // stored value is untouched. A listener installed after the settlement
    // never fires from the refused relay.
    try peer.session_state.registerImport(.from(10));
    try peer.session_state.installImportedPromiseListener(.from(5), .{ .listener = .{ .import_position = .from(10) }, .mode = .settling_only });
    try std.testing.expectError(
        error.UnexpectedMessage,
        applyRelayed(&peer, 5, .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "second") } }),
    );
    try std.testing.expectEqual(engine.StepOutcome.idle, try peer.step());
    try std.testing.expect(peer.takeOutbound() == null);
    try std.testing.expectEqualStrings("first", peer.session_state.importedPromiseResolution(.from(5)).?.fulfill.bytes);
}

test "a second relay before the first fire encodes is refused and every listener hears the one settled value" {
    const allocator = std.testing.allocator;
    var p1 = engine.Peer.init(allocator);
    defer p1.deinit();
    var p2 = engine.Peer.init(allocator);
    defer p2.deinit();

    const export_pos = try p2.session_state.allocatePromiseExport();
    try p2.session_state.exports.retain(allocator, export_pos);
    try p2.session_state.installThirdPartyImport(.from(export_pos.int()), "exporter");
    try p2.session_state.registerImport(.from(9));
    try p2.session_state.installImportedPromiseListener(.from(export_pos.int()), .{ .listener = .{ .import_position = .from(9) }, .mode = .settling_only });
    try p1.session_state.registerImport(.from(export_pos.int()));
    try p1.session_state.registerExport(.from(9));

    // First relay queues listener 9's fire carrier — nothing steps yet, so
    // the fire has not encoded.
    try applyRelayed(&p2, export_pos.int(), .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "first") } });

    // A second relay in the encode window is refused before anything more
    // fires: the store still holds "first".
    try std.testing.expectError(
        error.UnexpectedMessage,
        applyRelayed(&p2, export_pos.int(), .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "second") } }),
    );

    // The queued fire encodes the stored "first".
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    {
        var frame = p2.takeOutbound().?;
        defer frame.deinit();
        const view = try codec.syrup.decodeBody(frame.view());
        try std.testing.expectEqual(@as(u64, 9), view.deliver.target.near.export_position.int());
        try std.testing.expectEqualStrings("first", (try view.deliver.args.at(1)).bytes);
    }
    try expectListenerRelease(&p2, 9);

    // A late wire `op:listen` (installed after both relays) converges on the
    // same settled value: it fires immediately from the store with "first".
    try p1.sendCopying(.{ .listen = .{
        .target = .{ .far = model.FarRef.promise(export_pos.int()) },
        .listener = .{ .near = .{ .export_position = .from(9) } },
        .mode = .settling_only,
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    try p2.feedOwned(p1.takeOutbound().?);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    {
        var event = p2.pollEvent().?;
        event.deinit();
    }
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    {
        var frame = p2.takeOutbound().?;
        defer frame.deinit();
        const view = try codec.syrup.decodeBody(frame.view());
        try std.testing.expectEqual(@as(u64, 9), view.deliver.target.near.export_position.int());
        try std.testing.expectEqualStrings("first", (try view.deliver.args.at(1)).bytes);
    }
    try expectListenerRelease(&p2, 9);
    try std.testing.expect(p2.takeOutbound() == null);
    try std.testing.expectEqualStrings("first", p2.session_state.importedPromiseResolution(.from(export_pos.int())).?.fulfill.bytes);
}

test "a fire staled by row teardown and re-registration at the same import position drops instead of leaking the new promise's value" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.init(allocator);
    defer peer.deinit();

    try peer.session_state.installThirdPartyImport(.from(5), "exporter");
    try peer.session_state.registerImport(.from(9));
    try peer.session_state.installImportedPromiseListener(.from(5), .{ .listener = .{ .import_position = .from(9) }, .mode = .settling_only });

    // Apply stamps this row instance; the fire carrier sits until step.
    try applyRelayed(&peer, 5, .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "old-promise") } });

    // Sending `op:gc-exports` for import 5 releases it fully; the imported-
    // promise row (and its stored payload) is co-evicted at record time,
    // while listener 9's carrier still sits in the send queue.
    try peer.sendCopying(.{ .gc_export = .{ .positions = &.{5}, .deltas = &.{1} } });

    // A *different* third-party promise is then registered at the reused
    // position and relays its own value before the stale carrier encodes.
    try peer.session_state.installThirdPartyImport(.from(5), "other-exporter");
    try applyRelayed(&peer, 5, .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "new-promise") } });

    // The stale fire's row-identity stamp misses the re-registered row, so
    // listener 9 — a listener on the dead promise, not this one — never
    // receives "new-promise". Its consumed one-shot listener mention is still
    // released before the explicitly queued release of import 5.
    while ((try peer.step()) != .idle) {}
    var frames: usize = 0;
    const expected_positions = [_]u64{ 9, 5 };
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        defer frame.deinit();
        const view = try codec.syrup.decodeBody(frame.view());
        try std.testing.expect(view == .gc_export);
        try std.testing.expectEqual(@as(usize, 1), try view.gc_export.positions.len());
        try std.testing.expectEqual(expected_positions[frames], try view.gc_export.positions.at(0));
        try std.testing.expectEqual(@as(u64, 1), try view.gc_export.deltas.at(0));
        frames += 1;
    }
    try std.testing.expectEqual(expected_positions.len, frames);
    try std.testing.expectEqualStrings("new-promise", peer.session_state.importedPromiseResolution(.from(5)).?.fulfill.bytes);
}

// F-A apex: the RECORD side of the same hazard the test above pins for the FIRE
// side. A relayed resolution stamped against a third-party import row, then
// applied after that row is torn down and a *different* third-party promise
// re-registers at the position, must be dropped as moot — never written to the
// new promise's row nor fired to its listeners. `recordRelayedResolution`
// checks the enroll stamp, exactly as `settled_answer` / `listener_fire` do at
// encode. The test opens the enroll→apply window a production Node opens by
// the home-session round-trip.
test "a relayed resolution staled by row teardown and re-registration at the same import position is dropped, not written to the new promise" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.init(allocator);
    defer peer.deinit();

    // Import 5 is a third-party promise (row R1) with a listener.
    try peer.session_state.installThirdPartyImport(.from(5), "exporter");
    try peer.session_state.registerImport(.from(9));
    try peer.session_state.installImportedPromiseListener(.from(5), .{ .listener = .{ .import_position = .from(9) }, .mode = .settling_only });

    // Capture R1's stamp, then hold the resolution without applying — the
    // window Node opens between enroll and home-listen fire.
    const stale_row_id = peer.session_state.importedPromiseRowId(.from(5)).?;
    const stale = model.Resolution{ .fulfill = .{ .bytes = try allocator.dupe(u8, "stale-promise") } };

    // Tear R1 down (op:gc-exports releases import 5 fully; the imported-promise
    // row and its listener co-evict), then re-register a DIFFERENT third-party
    // promise (row R2, a fresh row id) at the reused position, with its own
    // listener.
    try peer.sendCopying(.{ .gc_export = .{ .positions = &.{5}, .deltas = &.{1} } });
    try peer.session_state.installThirdPartyImport(.from(5), "other-exporter");
    try peer.session_state.registerImport(.from(11));
    try peer.session_state.installImportedPromiseListener(.from(5), .{ .listener = .{ .import_position = .from(11) }, .mode = .settling_only });

    // Applying the stale stamp against R2: moot — neither stored on R2 nor
    // fired to R2's listener.
    try peer.applyRelayedResolution(.from(5), stale_row_id, stale);

    // R2 was never resolved by the stale relay: no wrong payload written.
    try std.testing.expect(peer.session_state.importedPromiseResolution(.from(5)) == null);

    // Nothing fired to R2's listener 11 — only the gc frame, and the stale
    // payload never touches the wire.
    while ((try peer.step()) != .idle) {}
    var frames: usize = 0;
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        defer frame.deinit();
        const view = try codec.syrup.decodeBody(frame.view());
        try std.testing.expect(view == .gc_export);
        try std.testing.expect(std.mem.indexOf(u8, frame.bytes(), "stale-promise") == null);
        frames += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), frames);
}
