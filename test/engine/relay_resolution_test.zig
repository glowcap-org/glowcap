//! Relayed-resolution substrate units (ADR-0009).
//!
//! Stamp/GC and resolve-once edge cases for `Peer.applyRelayedResolution` and
//! `installThirdPartyImport`. The production introducing-session path is
//! `Node.proxyForeignPromiseFulfill` (Host-driven); Node scenarios live in
//! `test/engine/node_test.zig`. Enroll-stamped `row_id` covers the deferred
//! window these units open by applying after session mutation.

const std = @import("std");
const pancake = @import("pancake");

const codec = pancake.ocapn.codec;
const engine = pancake.ocapn.engine;
const model = pancake.ocapn.model;

fn applyRelayed(peer: *engine.Peer, import_pos: u64, resolution: model.Resolution) !void {
    const position = model.ImportPosition.from(import_pos);
    const row_id = peer.session_state.importedPromiseRowId(position) orelse 0;
    try peer.applyRelayedResolution(position, row_id, resolution);
}

test "cross-peer relayed resolution fires a handoff-imported promise listener" {
    const allocator = std.testing.allocator;
    var p1 = engine.Peer.init(allocator);
    defer p1.deinit();
    var p2 = engine.Peer.init(allocator);
    defer p2.deinit();

    // p2 holds a promise imported from a third party (import 5). p1 reaches its
    // listener (p1's export 9) when the relayed resolution fires.
    try p2.session_state.installThirdPartyImport(.from(5), "exporter");
    try p1.session_state.registerExport(.from(5));
    try p1.session_state.registerExport(.from(9));

    // p1 listens on the imported promise (desc:import-promise 5), nominating its
    // export 9 as the listener. Sender `.near` → wire desc:import-promise →
    // receiver `.far`.
    try p1.sendCopying(.{ .listen = .{
        .target = .{ .near = .{ .export_position = .from(5), .kind = .promise } },
        .listener = .{ .near = .{ .export_position = .from(9) } },
        .wants_partial = false,
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    try p2.feedOwned(p1.takeOutbound().?);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    {
        var event = p2.pollEvent().?;
        event.deinit();
    }

    try applyRelayed(&p2, 5, .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "done") } });

    // The synthesized fire deliver encodes and reaches p1's export 9.
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    try p1.feedOwned(p2.takeOutbound().?);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());

    var fire_event = p1.pollEvent().?;
    defer fire_event.deinit();
    try std.testing.expectEqual(engine.EventKind.deliver, fire_event.kind());
    const view = try fire_event.view();
    // The fire targets our own export 9, so it arrives as `.near` post-flip.
    try std.testing.expect(view.deliver.target == .near);
    try std.testing.expectEqual(@as(u64, 9), view.deliver.target.near.export_position.int());
    try std.testing.expectEqualStrings("fulfill", (try view.deliver.args.at(0)).symbol);
    try std.testing.expectEqualStrings("done", (try view.deliver.args.at(1)).bytes);
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
        .wants_partial = false,
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

    try p2.session_state.installThirdPartyImport(.from(5), "exporter");
    try p1.session_state.registerExport(.from(5));
    try p1.session_state.registerExport(.from(9));

    // Relay the resolution before any listener exists: it is stored, nothing fires.
    try applyRelayed(&p2, 5, .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "early") } });
    try std.testing.expect(p2.takeOutbound() == null);

    // p1 listens; p2 installs the listener and fires it immediately from the
    // stored resolution.
    try p1.sendCopying(.{ .listen = .{
        .target = .{ .near = .{ .export_position = .from(5), .kind = .promise } },
        .listener = .{ .near = .{ .export_position = .from(9) } },
        .wants_partial = false,
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
    try peer.session_state.installImportedPromiseListener(.from(5), .{ .listener = .{ .import_position = .from(9) }, .wants_partial = false });

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

    // A second relay for the already-settled promise is refused (a promise
    // resolves once, mirroring the answer-side rule), the refused resolution
    // is freed (the testing allocator holds the no-leak contract), and the
    // stored value is untouched. A listener installed after the settlement
    // never fires from the refused relay.
    try peer.session_state.registerImport(.from(10));
    try peer.session_state.installImportedPromiseListener(.from(5), .{ .listener = .{ .import_position = .from(10) }, .wants_partial = false });
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

    try p2.session_state.installThirdPartyImport(.from(5), "exporter");
    try p2.session_state.registerImport(.from(9));
    try p2.session_state.installImportedPromiseListener(.from(5), .{ .listener = .{ .import_position = .from(9) }, .wants_partial = false });
    try p1.session_state.registerExport(.from(5));
    try p1.session_state.registerExport(.from(9));

    // First relay queues listener 9's fire carrier — nothing steps yet, so
    // the fire has not encoded.
    try applyRelayed(&p2, 5, .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "first") } });

    // A second relay in the encode window is refused before anything more
    // fires: the store still holds "first".
    try std.testing.expectError(
        error.UnexpectedMessage,
        applyRelayed(&p2, 5, .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "second") } }),
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

    // A late wire `op:listen` (installed after both relays) converges on the
    // same settled value: it fires immediately from the store with "first".
    try p1.sendCopying(.{ .listen = .{
        .target = .{ .near = .{ .export_position = .from(5), .kind = .promise } },
        .listener = .{ .near = .{ .export_position = .from(9) } },
        .wants_partial = false,
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
    try std.testing.expect(p2.takeOutbound() == null);
    try std.testing.expectEqualStrings("first", p2.session_state.importedPromiseResolution(.from(5)).?.fulfill.bytes);
}

test "a fire staled by row teardown and re-registration at the same import position drops instead of leaking the new promise's value" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.init(allocator);
    defer peer.deinit();

    try peer.session_state.installThirdPartyImport(.from(5), "exporter");
    try peer.session_state.registerImport(.from(9));
    try peer.session_state.installImportedPromiseListener(.from(5), .{ .listener = .{ .import_position = .from(9) }, .wants_partial = false });

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

    // Draining emits only the gc frame: the stale fire's row-identity stamp
    // misses the re-registered row, so listener 9 — a listener on the dead
    // promise, not this one — never receives "new-promise".
    while ((try peer.step()) != .idle) {}
    var frames: usize = 0;
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        defer frame.deinit();
        const view = try codec.syrup.decodeBody(frame.view());
        try std.testing.expect(view == .gc_export);
        frames += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), frames);
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
    try peer.session_state.installImportedPromiseListener(.from(5), .{ .listener = .{ .import_position = .from(9) }, .wants_partial = false });

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
    try peer.session_state.installImportedPromiseListener(.from(5), .{ .listener = .{ .import_position = .from(11) }, .wants_partial = false });

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
