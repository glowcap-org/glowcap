//! Guaranteed projection settlement units (ADR-0255).
//!
//! Pressure deferral, resolve-once, and stale-stamp edge cases for
//! `Peer.settleAnswerTargetGuaranteed` on a local promise projection, and the
//! CapTP `desc:export` listen on a projected promise. The production
//! introducing-session path is `Node.proxyForeignPromiseFulfill`
//! (Host-driven). Node scenarios live in `test/engine/node/`.

const std = @import("std");
const glowcap = @import("glowcap");

const codec = glowcap.ocapn.codec;
const engine = glowcap.ocapn.engine;
const model = glowcap.ocapn.model;
const session = glowcap.ocapn.session;
const peer_fixture = @import("../support/peer_fixture.zig");
const projection_support = @import("../support/projection.zig");

/// A projection the partner holds, as after its near-promise rewrite crossed
/// the wire in a fulfill (an inbound `<desc:export>` requires wireHeld > 0).
fn allocateHeldProjection(peer: *engine.Peer) !session.Session.LocalPromiseProjection {
    const projection = try peer.session_state.allocateLocalPromiseProjection();
    peer.session_state.exports.retain(projection.export_position);
    return projection;
}

fn installListener(peer: *engine.Peer, answer: model.AnswerName, listener: u64, mode: model.ListenMode) !void {
    try peer.session_state.retainImportForSession(.from(listener));
    try peer.session_state.installListenerNamed(answer, .{
        .listener = model.FarRef.object(listener),
        .mode = mode,
    });
}

fn settle(peer: *engine.Peer, target: session.AnswerTarget, resolution: model.Resolution) !void {
    try peer.settleAnswerTargetGuaranteed(target, resolution);
}

fn expectListenerRelease(peer: *engine.Peer, expected_position: u64) !void {
    var frame = peer.takeOutbound() orelse return error.MissingListenerRelease;
    defer frame.deinit();
    const body = try codec.syrup.decodeBodyForProfile(peer.session_state.captp_version, frame.view());
    try std.testing.expect(body == .gc_export);
    try std.testing.expectEqual(@as(usize, 1), try body.gc_export.positions.len());
    try std.testing.expectEqual(expected_position, try body.gc_export.positions.at(0));
    try std.testing.expectEqual(@as(usize, 1), try body.gc_export.deltas.len());
    try std.testing.expectEqual(@as(u64, 1), try body.gc_export.deltas.at(0));
}

fn expectListenerFire(peer: *engine.Peer, expected_listener: u64, expected_bytes: []const u8) !void {
    var frame = peer.takeOutbound() orelse return error.MissingListenerFire;
    defer frame.deinit();
    // Decoding our own outbound frame applies the receiver-perspective flip:
    // the fire's `far` listener was encoded `<desc:export N>`, which decodes
    // to `.near{export_position=N}` (the partner's view of its own export).
    const view = try codec.syrup.decodeBodyForProfile(peer.session_state.captp_version, frame.view());
    try std.testing.expectEqual(expected_listener, view.deliver.target.near.export_position.int());
    try std.testing.expectEqualStrings(expected_bytes, (try view.deliver.args.at(1)).bytes);
}

test "a guaranteed settlement under outbound pressure stores the value and queues its carrier once pressure clears" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();

    const projection = try allocateHeldProjection(&peer);
    try installListener(&peer, projection.answer_name, 9, .settling_only);

    peer.outbound_budget = 1;
    try settle(&peer, projection.answer_target, .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "first") } });
    try std.testing.expectEqualStrings(
        "first",
        projection_support.resolution(&peer.session_state, projection.export_position).?.fulfill.bytes,
    );
    try std.testing.expectEqual(@as(u32, 1), peer.deferred_settlements);
    try std.testing.expect(peer.takeOutbound() == null);
    // The deferred carrier meets the same pressure at the next step.
    try std.testing.expectError(error.OutboundBackpressure, peer.step());
    try std.testing.expectEqual(@as(u32, 1), peer.deferred_settlements);

    peer.outbound_budget = std.math.maxInt(usize);
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    try std.testing.expectEqual(@as(u32, 0), peer.deferred_settlements);
    while ((try peer.step()) != .idle) {}
    try expectListenerFire(&peer, 9, "first");
    try expectListenerRelease(&peer, 9);
    try std.testing.expect(peer.takeOutbound() == null);
}

test "projection listener modes fire only their requested transition" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();

    const projection = try allocateHeldProjection(&peer);
    try peer.session_state.registerImport(.from(12));
    try installListener(&peer, projection.answer_name, 9, .settling_only);
    try installListener(&peer, projection.answer_name, 10, .shortening_only);

    try settle(&peer, projection.answer_target, .{ .fulfill = .{
        .reference = .{ .far = model.FarRef.promise(12) },
    } });
    // The settlement's carrier drains, firing only the shortening listener,
    // whose one-shot mention is then released.
    while ((try peer.step()) != .idle) {}
    try std.testing.expect(!peer.session_state.hasImport(.from(9)));

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

    // A held import is live authority, but inbound `desc:import-promise` is
    // still the wrong target role. Refuse before registering the introduced
    // listener import.
    try peer.session_state.registerImport(.from(5));
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
    peer.session_state.exports.retain(promise_export);
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
    peer.session_state.exports.retain(promise_export);
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

test "CapTP-normal desc:export listen on a projected promise installs on its backing answer and fires on settlement" {
    const allocator = std.testing.allocator;
    var holder = engine.Peer.init(allocator);
    defer holder.deinit();
    var partner = engine.Peer.init(allocator);
    defer partner.deinit();

    const projection = try allocateHeldProjection(&holder);
    const export_pos = projection.export_position;
    try partner.session_state.registerImport(.from(export_pos.int()));
    try partner.session_state.registerExport(.from(9));

    // Partner holds import N and listens with Goblins/suite encoding:
    // sender `.far` → wire `<desc:export N>` → holder receives `.near`.
    try partner.sendBorrowed(.{ .listen = .{
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

    try settle(&holder, projection.answer_target, .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "via-export") } });
    while ((try holder.step()) != .idle) {}
    try partner.feedOwned(holder.takeOutbound().?);
    try expectListenerRelease(&holder, 9);
    try std.testing.expectEqual(engine.StepOutcome.progress, try partner.step());

    var fire_event = partner.pollEvent().?;
    defer fire_event.deinit();
    const view = fire_event.view();
    try std.testing.expect(view.deliver.target == .near);
    try std.testing.expectEqual(@as(u64, 9), view.deliver.target.near.export_position.int());
    try std.testing.expectEqualStrings("via-export", (try view.deliver.args.at(1)).bytes);
}

test "a listen on an already-settled projection fires immediately" {
    const allocator = std.testing.allocator;
    var p1 = engine.Peer.init(allocator);
    defer p1.deinit();
    var p2 = engine.Peer.init(allocator);
    defer p2.deinit();

    const projection = try allocateHeldProjection(&p2);
    const export_pos = projection.export_position;
    try p1.session_state.registerImport(.from(export_pos.int()));
    try p1.session_state.registerExport(.from(9));

    // Settle before any listener exists: the value is stored, nothing fires.
    try settle(&p2, projection.answer_target, .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "early") } });
    while ((try p2.step()) != .idle) {}
    try std.testing.expect(p2.takeOutbound() == null);

    // p1 listens; p2 installs the listener and fires it immediately from the
    // stored resolution.
    try p1.sendBorrowed(.{ .listen = .{
        .target = .{ .far = model.FarRef.promise(export_pos.int()) },
        .listener = .{ .near = .{ .export_position = .from(9) } },
        .mode = .settling_only,
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    try p2.feedOwned(p1.takeOutbound().?);
    // The listen installs and fires immediately from the store.
    while ((try p2.step()) != .idle) {}
    {
        var event = p2.pollEvent().?;
        event.deinit();
    }

    try p1.feedOwned(p2.takeOutbound().?);
    try expectListenerRelease(&p2, 9);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    var fire_event = p1.pollEvent().?;
    defer fire_event.deinit();
    const view = fire_event.view();
    // The fire targets our own export 9, so it arrives as `.near` post-flip.
    try std.testing.expect(view.deliver.target == .near);
    try std.testing.expectEqual(@as(u64, 9), view.deliver.target.near.export_position.int());
    try std.testing.expectEqualStrings("early", (try view.deliver.args.at(1)).bytes);
}

test "a second guaranteed settlement is refused: a projection resolves once" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();

    const projection = try allocateHeldProjection(&peer);
    try installListener(&peer, projection.answer_name, 9, .settling_only);

    // The first settlement fires the listener (far 9) and stores the value.
    try settle(&peer, projection.answer_target, .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "first") } });
    while ((try peer.step()) != .idle) {}
    try expectListenerFire(&peer, 9, "first");
    try expectListenerRelease(&peer, 9);

    // A second settlement for the settled projection is refused (a promise
    // resolves once, mirroring the answer-side rule), the refused resolution
    // is freed (the testing allocator holds the no-leak contract), and the
    // stored value is untouched. A listener installed after the settlement
    // fires from the store, never from the refused value.
    try std.testing.expectError(
        error.UnexpectedMessage,
        settle(&peer, projection.answer_target, .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "second") } }),
    );
    try std.testing.expectEqual(engine.StepOutcome.idle, try peer.step());
    try std.testing.expect(peer.takeOutbound() == null);
    try std.testing.expectEqualStrings(
        "first",
        projection_support.resolution(&peer.session_state, projection.export_position).?.fulfill.bytes,
    );
}

test "a second settlement before the first fire encodes is refused and every listener hears the one settled value" {
    const allocator = std.testing.allocator;
    var p1 = engine.Peer.init(allocator);
    defer p1.deinit();
    var p2 = engine.Peer.init(allocator);
    defer p2.deinit();

    const projection = try allocateHeldProjection(&p2);
    const export_pos = projection.export_position;
    try installListener(&p2, projection.answer_name, 9, .settling_only);
    try p1.session_state.registerImport(.from(export_pos.int()));
    try p1.session_state.registerExport(.from(9));

    // The first settlement queues listener 9's fire carrier. Nothing steps
    // yet, so the fire has not encoded.
    try settle(&p2, projection.answer_target, .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "first") } });

    // A second settlement in the encode window is refused before anything
    // more fires: the store still holds "first".
    try std.testing.expectError(
        error.UnexpectedMessage,
        settle(&p2, projection.answer_target, .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "second") } }),
    );

    // The queued carrier fires the stored "first".
    while ((try p2.step()) != .idle) {}
    try expectListenerFire(&p2, 9, "first");
    try expectListenerRelease(&p2, 9);

    // A late wire `op:listen` (installed after both settlements) converges on
    // the same settled value: it fires immediately from the store with "first".
    try p1.sendBorrowed(.{ .listen = .{
        .target = .{ .far = model.FarRef.promise(export_pos.int()) },
        .listener = .{ .near = .{ .export_position = .from(9) } },
        .mode = .settling_only,
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    try p2.feedOwned(p1.takeOutbound().?);
    while ((try p2.step()) != .idle) {}
    {
        var event = p2.pollEvent().?;
        event.deinit();
    }
    try expectListenerFire(&p2, 9, "first");
    try expectListenerRelease(&p2, 9);
    try std.testing.expect(p2.takeOutbound() == null);
    try std.testing.expectEqualStrings(
        "first",
        projection_support.resolution(&p2.session_state, export_pos).?.fulfill.bytes,
    );
}

// The stamp hazard: a settlement held across the window a Node opens between
// admitting a recipient and the home-listen fire. If the batch fails in that
// window, the Node withdraws and abandons the projection, and a later
// projection on the same session takes a fresh row. The held target's row
// stamp misses, so the stale settlement is moot: neither written to any
// projection nor fired to its listeners, exactly as `settled_answer` and
// `listener_fire` carriers check their stamp at encode.
test "a settlement staled by an abandoned projection is refused, not written to a later projection" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();

    // The first projection (row R1) is admitted, then abandoned by its
    // withdrawn batch.
    const stale_projection = try peer.session_state.allocateLocalPromiseProjection();
    const stale = model.Resolution{ .fulfill = .{ .bytes = try allocator.dupe(u8, "stale-promise") } };
    peer.session_state.abandonLocalPromiseProjection(stale_projection.export_position);
    try std.testing.expect(peer.session_state.answerForLocalPromiseExport(stale_projection.export_position) == null);

    // A later projection (row R2) has its own listener.
    const fresh_projection = try allocateHeldProjection(&peer);
    try std.testing.expect(!std.meta.eql(stale_projection.answer_target, fresh_projection.answer_target));
    try installListener(&peer, fresh_projection.answer_name, 11, .settling_only);

    // Settling R1's target is refused: nothing is written to R2, and the
    // stale value is freed.
    try std.testing.expectError(error.InvalidReference, settle(&peer, stale_projection.answer_target, stale));
    try std.testing.expect(projection_support.resolution(&peer.session_state, fresh_projection.export_position) == null);

    // Nothing fired to R2's listener 11, and the stale payload never touches
    // the wire.
    while ((try peer.step()) != .idle) {}
    try std.testing.expect(peer.takeOutbound() == null);
    try std.testing.expect(peer.session_state.hasImport(.from(11)));
}
