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
const foundation = pancake.foundation;
const engine = pancake.ocapn.engine;
const model = pancake.ocapn.model;
const peer_fixture = @import("../support/peer_fixture.zig");

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

// ── The recipient half: waiting on a promise the partner handed us ──────────
//
// Everything above is what a holder does with a relayed resolution once it has
// one. `engine.listen.listenOnPromise` is how a peer asks for one (ADR-0095):
// it nominates a fresh export as the listener and binds it to an outbound
// answer, so the partner's notification comes back as a resolve the caller
// observes exactly like a call's reply. Both negotiated profiles are exercised
// below, because `op:listen` and its notification are common CapTP, not a V1.0
// arrangement.

/// The profiles a session can negotiate. Both carry `op:listen`, and both
/// notify a listener the same way, so every test in this section runs on each.
const profiles = [_]model.CaptpVersion{ .v1_0, .next };

/// A paired session on `version` over Syrup, so a wire-shape assertion reads
/// one codec's bytes rather than whichever the native offer preferred.
fn syrupPair(allocator: std.mem.Allocator, version: model.CaptpVersion) !engine.pairing.Pair {
    return engine.pairing.pairedNegotiated(allocator, .{
        .captp_version = version,
        .codec = .syrup,
        .features = model.FeatureSet.full(),
    });
}

/// What `listenOnPromise` left behind: the answer it returned, the listener
/// export read back off the emitted frame, and that frame's bytes.
const Listening = struct {
    answer: model.AnswerPosition,
    listener: u64,
    frame: foundation.Frame,

    fn deinit(self: *Listening) void {
        self.frame.deinit();
    }
};

/// Hold import 5 as a promise the partner handed us, listen on it, and drain
/// the one frame that produced. Own-outbound decode flips near export to far
/// import, so the listener position read back is the export the sender minted.
fn listenOnImportFive(peer: *engine.Peer) !Listening {
    try peer.session_state.registerImport(.from(5));
    const answer = try engine.listen.listenOnPromise(peer, .{ .far = model.FarRef.promise(5) });
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    const frame = peer.takeOutbound().?;
    const view = try codec.syrup.decodeBody(frame.view());
    try std.testing.expect(view == .listen);
    return .{ .answer = answer, .listener = view.listen.listener.far.import_position.int(), .frame = frame };
}

/// Notify `peer`'s listener export the way CapTP says a listener is told: an
/// `op:deliver` carrying `['fulfill|'break, payload]`, with no answer of its own.
fn notify(partner: *engine.Peer, peer: *engine.Peer, listener: u64, args: []const model.Argument) !void {
    try partner.session_state.registerImport(.from(listener));
    try partner.sendCopying(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(listener) },
        .args = args,
        .answer = null,
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try partner.step());
    try peer.feedOwned(partner.takeOutbound().?);
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
}

test "listenOnPromise nominates a fresh export and binds it to the answer it returns" {
    const allocator = std.testing.allocator;
    for (profiles) |version| {
        var pair = try syrupPair(allocator, version);
        defer pair.deinit();

        var listening = try listenOnImportFive(&pair.p1);
        defer listening.deinit();

        // The listener export is bound to the answer, which is what makes the
        // partner's notification readable as a settlement of that answer.
        try std.testing.expectEqual(
            listening.answer,
            pair.p1.session_state.answerForResolverExport(.from(listening.listener)).?,
        );
        // And the answer is installed before the send, so the notification is
        // not refused as a resolve on an answer we do not hold.
        try std.testing.expect(pair.p1.session_state.outbound_answers.contains(listening.answer));
    }
}

test "listenOnPromise emits each profile's own op:listen, not one profile's shape on both" {
    const allocator = std.testing.allocator;

    var v1_0_pair = try syrupPair(allocator, .v1_0);
    defer v1_0_pair.deinit();
    var v1_0 = try listenOnImportFive(&v1_0_pair.p1);
    defer v1_0.deinit();

    var next_pair = try syrupPair(allocator, .next);
    defer next_pair.deinit();
    var next = try listenOnImportFive(&next_pair.p1);
    defer next.deinit();

    // Same semantic message on both: the promise it listens on, the export it
    // nominates, and a full (not partial) subscription.
    for ([_]*const Listening{ &v1_0, &next }) |listening| {
        const view = try codec.syrup.decodeBody(listening.frame.view());
        try std.testing.expectEqual(@as(u64, 5), view.listen.target.near.export_position.int());
        try std.testing.expectEqual(listening.listener, view.listen.listener.far.import_position.int());
        try std.testing.expect(!view.listen.wants_partial);
    }

    // Different bytes, and the difference is the operand count: V1.0's
    // `op:listen` carries `wants_partial` and the pre-ratified profile's does
    // not, so the V1.0 record is exactly one Syrup boolean longer. Both peers
    // minted the same listener position, so the two frames differ in nothing
    // else. The encodings themselves are pinned against the reference corpus
    // in `test/codec/syrup_test.zig`; what this pins is that the verb goes out
    // through the session's *negotiated* profile rather than a fixed one.
    try std.testing.expectEqual(v1_0.listener, next.listener);
    try std.testing.expectEqual(next.frame.bytes().len + 1, v1_0.frame.bytes().len);
}

test "the partner's fulfill on the listener export surfaces as a resolve on the listen's answer" {
    const allocator = std.testing.allocator;
    for (profiles) |version| {
        var pair = try syrupPair(allocator, version);
        defer pair.deinit();
        var listening = try listenOnImportFive(&pair.p1);
        defer listening.deinit();

        try notify(&pair.p2, &pair.p1, listening.listener, &.{
            .{ .symbol = "fulfill" },
            .{ .bytes = "settled elsewhere" },
        });

        var event = pair.p1.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(engine.EventKind.resolve, event.kind());
        const view = try event.view();
        try std.testing.expectEqual(listening.answer, view.resolve.answer);
        try std.testing.expectEqualStrings("settled elsewhere", view.resolve.resolution.fulfill.bytes);
    }
}

test "the partner's break on the listener export surfaces as a broken resolve" {
    const allocator = std.testing.allocator;
    for (profiles) |version| {
        var pair = try syrupPair(allocator, version);
        defer pair.deinit();
        var listening = try listenOnImportFive(&pair.p1);
        defer listening.deinit();

        // A break rides as a bare Symbol, the same payload shape pancake's own
        // listener fire emits.
        try notify(&pair.p2, &pair.p1, listening.listener, &.{
            .{ .symbol = "break" },
            .{ .symbol = "exporter vanished" },
        });

        var event = pair.p1.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(engine.EventKind.resolve, event.kind());
        const view = try event.view();
        try std.testing.expectEqual(listening.answer, view.resolve.answer);
        try std.testing.expectEqualStrings("exporter vanished", view.resolve.resolution.@"break".message);
    }
}

test "listenOnPromise refuses anything but a far this session holds" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.init(allocator);
    defer peer.deinit();

    // A near names an export of ours, whose settlement is ours to decide; a
    // promise, sturdy, or broken names nothing a partner could notify us about.
    try peer.session_state.registerExport(.from(3));
    const sturdy = model.SturdyRef{
        .peer = .{ .transport = "tcp", .designator = "127.0.0.1:1", .hints = model.Hints.emptyFalse() },
        .swissnum = "swiss",
    };
    const refused = [_]model.Reference{
        .{ .near = model.NearRef.object(3) },
        .{ .promise = .{ .answer_position = .from(1) } },
        .{ .sturdy = &sturdy },
        .{ .broken = .{ .message = "gone" } },
        // A far this session does not hold names a capability that does not
        // exist here, refused like any unheld target.
        .{ .far = model.FarRef.promise(77) },
    };
    for (refused) |target| {
        try std.testing.expectError(
            error.InvalidReference,
            engine.listen.listenOnPromise(&peer, target),
        );
    }
    // A refusal leaves nothing behind: no queued frame, and no listener export
    // bound to an answer nobody asked for.
    try std.testing.expectEqual(engine.StepOutcome.idle, try peer.step());
    try std.testing.expect(peer.takeOutbound() == null);
}

test "the listen's answer is installed before the op:listen is encoded" {
    const allocator = std.testing.allocator;
    for (profiles) |version| {
        var pair = try syrupPair(allocator, version);
        defer pair.deinit();

        try pair.p1.session_state.registerImport(.from(5));
        const answer = try engine.listen.listenOnPromise(&pair.p1, .{ .far = model.FarRef.promise(5) });

        // Nothing has been encoded yet, and the answer is already one we hold,
        // so the notification cannot arrive on an answer we do not.
        try std.testing.expect(pair.p1.takeOutbound() == null);
        try std.testing.expect(pair.p1.session_state.outbound_answers.contains(answer));

        try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p1.step());
        var frame = pair.p1.takeOutbound().?;
        frame.deinit();
    }
}

test "a notification naming an answer the session does not hold is refused loudly" {
    const allocator = std.testing.allocator;
    var pair = try syrupPair(allocator, .next);
    defer pair.deinit();

    // The hazard the install ordering exists for, built by hand: a listener
    // export bound to an answer nothing ever installed.
    try pair.p1.session_state.registerExport(.from(7));
    try pair.p1.session_state.installOutboundResolver(.from(4242), .from(7));

    try pair.p2.session_state.registerImport(.from(7));
    try pair.p2.sendCopying(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &.{ .{ .symbol = "fulfill" }, .{ .bytes = "settled elsewhere" } },
        .answer = null,
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p2.step());
    try pair.p1.feedOwned(pair.p2.takeOutbound().?);

    // `validateInboundResolve` refuses it, and the refusal is a typed
    // protocol_error the partner is told about rather than a silent drop. No
    // resolve surfaces for an answer nobody asked for.
    try std.testing.expectError(error.InvalidReference, pair.p1.step());
    try std.testing.expectEqual(model.AbortKind.protocol_error, pair.p1.lastAbort().?.kind.?);
    try std.testing.expect(pair.p1.pollEvent() == null);
}

// The rollback paths. Every refusal in the test above returns at the target
// check, before anything is reserved, so this sweep is the only thing that runs
// `nominateResolverExport`'s undo and `listenOnPromise`'s. It arms the failure
// at a fixed offset into the call itself, so each offset names one allocation
// the call makes, and the offsets past the last one succeed — which is how the
// sweep proves it covered them all.
//
// Validated by injection. Caught: dropping the export release from
// `abandonResolverExport`, dropping either the release errdefer in
// `bindFreshResolverExport` or the link removal, installing the answer
// after the send (which the session-side pin
// `nominateResolverExport installs the answer it hands back` also names
// directly), and narrowing `listenOnPromise`'s errdefer to the export-only
// `abandonResolverExport`, which strands the answer row (the session pin
// catches the sibling: a nomination undo that skips its answer half).
// Escaped: swapping the two statements in
// `abandonResolverExport`, because a single decrement's outcome does not depend
// on the link, so the two orders leave identical state and no test can tell
// them apart. States it does not reach: a failure during `step`'s encode (a
// failed attempt is never stepped under the armed allocator), and resize-path
// failures (`resize_fail_index` is left unarmed).
test "every allocation failure inside listenOnPromise rolls the whole nomination back" {
    for (profiles) |version| {
        var successes: usize = 0;
        var failures: usize = 0;
        var offset: usize = 0;
        while (offset < 12) : (offset += 1) {
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
            var peer = peer_fixture.openPeerWith(failing.allocator(), .{ .captp_version = version });
            defer peer.deinit();
            try peer.session_state.registerImport(.from(5));

            // The two rows the attempt is about to reserve, read off the
            // session's own allocators before it runs.
            const listener = model.ExportPosition.from(peer.session_state.next_export_position);
            const answer = model.AnswerPosition.from(peer.session_state.next_outbound_answer);

            failing.fail_index = failing.alloc_index + offset;
            const attempt = engine.listen.listenOnPromise(&peer, .{ .far = model.FarRef.promise(5) });
            failing.fail_index = std.math.maxInt(usize);

            if (attempt) |returned| {
                successes += 1;
                try std.testing.expectEqual(answer, returned);
                try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
                var frame = peer.takeOutbound().?;
                frame.deinit();
                continue;
            } else |_| {}
            try std.testing.expectError(error.OutOfMemory, attempt);
            failures += 1;

            // Nothing of the nomination survives: no export row, no answer
            // row, neither direction of the resolver link, and no `op:listen`
            // to encode.
            try std.testing.expectEqual(@as(u64, 0), peer.session_state.exportRefcount(listener));
            try std.testing.expect(!peer.session_state.outbound_answers.contains(answer));
            try std.testing.expectEqual(
                @as(?model.AnswerPosition, null),
                peer.session_state.answerForResolverExport(listener),
            );
            try std.testing.expectEqual(
                @as(?model.ExportPosition, null),
                peer.session_state.outbound_resolver_link.getByValue(answer),
            );
            try std.testing.expectEqual(engine.StepOutcome.idle, try peer.step());
            try std.testing.expect(peer.takeOutbound() == null);

            // And the session still listens: the retry gets its own export and
            // a fresh answer, bound to each other.
            const retry_listener = model.ExportPosition.from(peer.session_state.next_export_position);
            const retry = try engine.listen.listenOnPromise(&peer, .{ .far = model.FarRef.promise(5) });
            try std.testing.expect(retry.int() > answer.int());
            try std.testing.expectEqual(retry, peer.session_state.answerForResolverExport(retry_listener).?);
            try std.testing.expect(peer.session_state.outbound_answers.contains(retry));
            try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
            var retry_frame = peer.takeOutbound().?;
            retry_frame.deinit();
        }
        // The sweep ran past the last allocation the call makes, so every one of
        // them was injected.
        try std.testing.expect(failures > 0);
        try std.testing.expect(successes > 0);
    }
}
