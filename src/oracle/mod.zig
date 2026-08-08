//! Canonical CapTP scenario drivers — the observable-trace oracle.
//!
//! Each `run*` function drives a `engine.Peer` through one fixed protocol
//! scenario (a Stage-0 abort, a driven deliver/resolve, a handshake-then-
//! bootstrap-fetch, an inbound dispatch mode) and returns the resulting wire
//! bytes. Those byte traces are the conformance evidence: the Zig oracle tests
//! (`test/oracle`) compare them for identical observable behavior. The drivers
//! live in their own `oracle` module, off the public `pancake` namespace: the
//! tests import it directly, and no binding consumes it — the bindings prove
//! the C ABI by dogfood, not by oracle traces.
//!
//! The drivers are sync and codec-parameterized; they own no I/O and add no
//! protocol semantics the engine lacks.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");

pub fn runStage0Abort(allocator: std.mem.Allocator) ![]u8 {
    var peer = engine.Peer.init(allocator);
    defer peer.deinit();

    const inbound = "<8'op:abort3\"bye>";
    try peer.recvBorrowed(.{
        .bytes = inbound,
        .shape = foundation.FrameShape.byte,
    });

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "scenario=stage0_abort\n");

    if (peer.pollEvent()) |event_value| {
        var event = event_value;
        defer event.deinit();
        if (event.kind() == .abort) {
            const decoded = try event.view();
            try appendTraceLine(allocator, &out, "event=abort:{s}\n", .{decoded.abort.message});
        }
    }

    try out.appendSlice(allocator, "session=closed\n\n");

    return out.toOwnedSlice(allocator);
}

pub fn runDrivenAbort(allocator: std.mem.Allocator) ![]u8 {
    var p1 = engine.Peer.init(allocator);
    defer p1.deinit();
    var p2 = engine.Peer.init(allocator);
    defer p2.deinit();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "scenario=driven_abort\n");

    try p1.sendCopying(.{ .abort = .{ .kind = .other, .message = "bye" } });
    _ = try p1.step();
    try out.appendSlice(allocator, "p1=sent:abort\n");

    const frame = p1.takeOutbound().?;
    try p2.feedOwned(frame);
    _ = try p2.step();

    if (p2.pollEvent()) |event_value| {
        var event = event_value;
        defer event.deinit();
        if (event.kind() == .abort) {
            const decoded = try event.view();
            try appendTraceLine(allocator, &out, "p2=event:abort:{s}\n", .{decoded.abort.message});
        }
    }
    try out.appendSlice(allocator, "p2=session:closed\n\n");

    return out.toOwnedSlice(allocator);
}

/// A full deliver-then-resolve round-trip across an in-process paired session
/// (ADR-0010 V1.0 resolver-callback translation under the hood): p1 asks p2's
/// bootstrap a question, p2 resolves it, and the resolution surfaces back at p1
/// as a semantic `Resolve`. Broadens conformance past the abort axis onto the
/// deliver / answer / resolve state machine. Runs on `codec`; the trace is
/// codec-agnostic by construction, so a parity test asserts it is identical on
/// Syrup and Cap'n Proto.
pub fn runDrivenDeliverResolve(allocator: std.mem.Allocator, codec: model.CodecId) ![]u8 {
    var pair = try engine.pairing.pairedWithCodec(allocator, codec);
    defer pair.deinit();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "scenario=driven_deliver_resolve\n");

    try pair.p1.session_state.registerImport(.from(0));
    try pair.p1.sendCopying(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(0) } },
        .args = &.{.{ .bytes = "ping" }},
        .answer = .from(42),
    } });
    _ = try pair.p1.step();
    try out.appendSlice(allocator, "p1=sent:deliver:answer=42\n");

    {
        const frame = pair.p1.takeOutbound().?;
        try pair.p2.feedOwned(frame);
    }
    _ = try pair.p2.step();
    if (pair.p2.pollEvent()) |event_value| {
        var event = event_value;
        defer event.deinit();
        try appendTraceLine(allocator, &out, "p2=event:{s}\n", .{@tagName(event.kind())});
    }

    try pair.p2.sendCopying(.{ .resolve = .{
        .answer = .from(42),
        .resolution = .{ .fulfill = .{ .bytes = "pong" } },
    } });
    _ = try pair.p2.step();
    try out.appendSlice(allocator, "p2=sent:resolve:answer=42\n");

    {
        const frame = pair.p2.takeOutbound().?;
        try pair.p1.feedOwned(frame);
    }
    _ = try pair.p1.step();
    if (pair.p1.pollEvent()) |event_value| {
        var event = event_value;
        defer event.deinit();
        const view = try event.view();
        try appendTraceLine(allocator, &out, "p1=event:{s}:answer={d}:fulfill={s}\n", .{
            @tagName(event.kind()),
            view.resolve.answer,
            view.resolve.resolution.fulfill.bytes,
        });
    }
    try out.appendSlice(allocator, "\n");

    return out.toOwnedSlice(allocator);
}

/// Deliver → listen on the answer → resolve → listener-fire. Scenario authority
/// for answer-side `op:listen` (ADR-0007); codec-parameterized like
/// `runDrivenDeliverResolve`.
pub fn runDrivenListenResolve(allocator: std.mem.Allocator, codec: model.CodecId) ![]u8 {
    var pair = try engine.pairing.pairedWithCodec(allocator, codec);
    defer pair.deinit();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "scenario=driven_listen_resolve\n");

    try pair.p1.session_state.registerImport(.from(7));
    try pair.p2.session_state.registerExport(.from(7));
    try pair.p1.session_state.registerExport(.from(9));

    try pair.p1.sendCopying(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(7) } },
        .args = &.{},
        .answer = .from(42),
    } });
    _ = try pair.p1.step();
    try out.appendSlice(allocator, "p1=sent:deliver:answer=42\n");
    {
        const frame = pair.p1.takeOutbound().?;
        try pair.p2.feedOwned(frame);
    }
    _ = try pair.p2.step();
    if (pair.p2.pollEvent()) |event_value| {
        var event = event_value;
        defer event.deinit();
        try appendTraceLine(allocator, &out, "p2=event:{s}\n", .{@tagName(event.kind())});
    }

    try pair.p1.sendCopying(.{ .listen = .{
        .target = .{ .promise = .{ .answer_position = .from(42) } },
        .listener = .{ .near = .{ .export_position = .from(9) } },
        .mode = .settling_only,
    } });
    _ = try pair.p1.step();
    try out.appendSlice(allocator, "p1=sent:listen:answer=42\n");
    {
        const frame = pair.p1.takeOutbound().?;
        try pair.p2.feedOwned(frame);
    }
    _ = try pair.p2.step();
    if (pair.p2.pollEvent()) |event_value| {
        var event = event_value;
        defer event.deinit();
        try appendTraceLine(allocator, &out, "p2=event:{s}\n", .{@tagName(event.kind())});
    }

    try pair.p2.sendCopying(.{ .resolve = .{
        .answer = .from(42),
        .resolution = .{ .fulfill = .{ .bytes = "ok" } },
    } });
    _ = try pair.p2.step();
    try out.appendSlice(allocator, "p2=sent:resolve:answer=42\n");
    {
        const frame = pair.p2.takeOutbound().?;
        try pair.p1.feedOwned(frame);
    }
    _ = try pair.p2.step();
    {
        const frame = pair.p2.takeOutbound().?;
        try pair.p1.feedOwned(frame);
    }

    _ = try pair.p1.step();
    if (pair.p1.pollEvent()) |event_value| {
        var event = event_value;
        defer event.deinit();
        try appendTraceLine(allocator, &out, "p1=event:{s}\n", .{@tagName(event.kind())});
    }
    _ = try pair.p1.step();
    if (pair.p1.pollEvent()) |event_value| {
        var event = event_value;
        defer event.deinit();
        const view = try event.view();
        try appendTraceLine(allocator, &out, "p1=event:{s}:listener={d}:fulfill={s}\n", .{
            @tagName(event.kind()),
            view.deliver.target.near.export_position.int(),
            (try view.deliver.args.at(1)).bytes,
        });
    }
    try out.appendSlice(allocator, "\n");

    return out.toOwnedSlice(allocator);
}

/// The peers hand-shake, the responder registers a bootstrap cap, the initiator
/// fetches it, and the responder auto-resolves with no hand-rolled reply. The exporter-side
/// proof for ADR-0006's responder half: serving an inbound `'fetch` lives in the
/// engine, not the test harness. The settlement rides back as a V1.0
/// resolver-callback and surfaces at the initiator as a `fulfilled` outcome.
/// Runs on `codec`; the trace is codec-agnostic by construction, so a parity
/// test asserts it is identical on Syrup and Cap'n Proto.
pub fn runHandshakeThenBootstrapFetch(allocator: std.mem.Allocator, codec: model.CodecId) ![]u8 {
    var pair = try engine.pairing.pairedWithCodec(allocator, codec);
    defer pair.deinit();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "scenario=handshake_bootstrap_fetch\n");

    const export_position = try pair.p2.registerBootstrapCap("thermostat");
    try appendTraceLine(allocator, &out, "p2=registered:swissnum=thermostat:export={d}\n", .{export_position});

    const prepared = try engine.fetch.prepareFetchSwissnum(allocator, &pair.p1.session_state, "thermostat");
    try pair.p1.send(prepared.message);
    _ = try pair.p1.step();
    try out.appendSlice(allocator, "p1=sent:fetch\n");

    {
        const frame = pair.p1.takeOutbound().?;
        try pair.p2.feedOwned(frame);
    }
    // The deliver surfaces as an event on the first step; the synthesized
    // resolve encodes on the second.
    _ = try pair.p2.step();
    if (pair.p2.pollEvent()) |event_value| {
        var event = event_value;
        defer event.deinit();
        try appendTraceLine(allocator, &out, "p2=event:{s}\n", .{@tagName(event.kind())});
    }
    _ = try pair.p2.step();
    try out.appendSlice(allocator, "p2=auto:resolved\n");

    {
        const frame = pair.p2.takeOutbound().?;
        try pair.p1.feedOwned(frame);
    }
    _ = try pair.p1.step();
    {
        var settle = pair.p1.pollEvent().?;
        defer settle.deinit();
        const owned = try settle.decodeOwned(allocator);
        const match = try engine.fetch.tryMatchFetchOutcome(allocator, prepared.resolver_export, prepared.answer_position, owned);
        switch (match) {
            .settled => |outcome| switch (outcome) {
                .fulfilled => |reference| {
                    defer model.freeReference(allocator, reference);
                    // The fulfilled cap is p2's export; the perspective flip lands
                    // it at p1 as the import it now holds. Trace its position
                    // (variant-agnostic) so the line is stable across codecs.
                    const position = switch (reference) {
                        .far => |far| far.import_position.int(),
                        .near => |near| near.export_position.int(),
                        else => return error.UnexpectedReferenceShape,
                    };
                    try appendTraceLine(allocator, &out, "p1=fulfilled:import={d}\n", .{position});
                },
                .broken => |reason| {
                    defer allocator.free(reason);
                    try appendTraceLine(allocator, &out, "p1=broken:{s}\n", .{reason});
                },
                .malformed => try out.appendSlice(allocator, "p1=malformed\n"),
            },
            .unrelated => |message| {
                model.freeMessage(allocator, message);
                try out.appendSlice(allocator, "p1=unrelated\n");
            },
        }
    }
    try out.appendSlice(allocator, "\n");

    return out.toOwnedSlice(allocator);
}

/// Deliver → `op:get` / `op:index` / `op:untag` against the pending answers →
/// the responder resolves each source and the engine resolves the projected
/// answers in the same turn (ADR-0050). Scenario authority for the projection
/// trio as whole-conversation behavior, not just per-frame fixtures;
/// codec-parameterized like `runDrivenDeliverResolve`.
pub fn runDrivenProjections(allocator: std.mem.Allocator, codec: model.CodecId) ![]u8 {
    var pair = try engine.pairing.pairedNegotiated(allocator, .{
        .captp_version = .next,
        .codec = codec,
        .features = model.FeatureSet.full(),
    });
    defer pair.deinit();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "scenario=driven_projections\n");

    try pair.p1.session_state.registerImport(.from(7));
    try pair.p2.session_state.registerExport(.from(7));

    // Three questions, one per projection kind: 11 resolves to a Struct
    // (op:get), 21 to a List (op:index), 31 to a Tagged (op:untag).
    const questions = [_]u64{ 11, 21, 31 };
    for (questions) |answer| {
        try pair.p1.sendCopying(.{ .deliver = .{
            .target = .{ .far = .{ .import_position = .from(7) } },
            .args = &.{},
            .answer = .from(answer),
        } });
        _ = try pair.p1.step();
        try appendTraceLine(allocator, &out, "p1=sent:deliver:answer={d}\n", .{answer});
        try shuttleAndTraceEvents(allocator, &out, &pair.p1, &pair.p2, "p2");
    }

    const projections = [_]model.Message{
        .{ .get = .{ .receiver = .{ .promise = .{ .answer_position = .from(11) } }, .field = "name", .answer = .from(12) } },
        .{ .index = .{ .receiver = .{ .promise = .{ .answer_position = .from(21) } }, .index = .{ .integer = 1 }, .answer = .from(22) } },
        .{ .untag = .{ .receiver = .{ .promise = .{ .answer_position = .from(31) } }, .tag = "cm", .answer = .from(32) } },
    };
    for (projections) |message| {
        try pair.p1.sendCopying(message);
        _ = try pair.p1.step();
        try appendTraceLine(allocator, &out, "p1=sent:{s}\n", .{@tagName(message)});
        try shuttleAndTraceEvents(allocator, &out, &pair.p1, &pair.p2, "p2");
    }

    const resolutions = [_]model.Message{
        .{ .resolve = .{ .answer = .from(11), .resolution = .{ .fulfill = .{ .@"struct" = &.{
            .{ .key = "name", .value = .{ .string = "tabby" } },
            .{ .key = "age", .value = .{ .integer = 12 } },
        } } } } },
        .{ .resolve = .{ .answer = .from(21), .resolution = .{ .fulfill = .{ .list = &.{
            .{ .string = "zero" }, .{ .string = "one" }, .{ .string = "two" },
        } } } } },
        .{ .resolve = .{ .answer = .from(31), .resolution = .{ .fulfill = .{ .tagged = .{
            .tag = "cm",
            .value = &.{.{ .integer = 5 }},
        } } } } },
    };
    for (resolutions) |message| {
        try pair.p2.sendCopying(message);
        _ = try pair.p2.step();
        try appendTraceLine(allocator, &out, "p2=sent:resolve:answer={d}\n", .{message.resolve.answer.int()});
        try shuttleAndTraceEvents(allocator, &out, &pair.p2, &pair.p1, "p1");
    }
    try out.appendSlice(allocator, "\n");

    return out.toOwnedSlice(allocator);
}

/// Deliver (minting an answer) → `op:gc-exports` releasing the far import →
/// `op:gc-answers` releasing the answer. Scenario authority for wire GC as
/// whole-conversation behavior: the receiver's export and answer rows are
/// observably gone after the releases apply. Codec-parameterized like
/// `runDrivenDeliverResolve`.
pub fn runDrivenGcPair(allocator: std.mem.Allocator, codec: model.CodecId) ![]u8 {
    var pair = try engine.pairing.pairedWithCodec(allocator, codec);
    defer pair.deinit();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "scenario=driven_gc\n");

    try pair.p1.session_state.registerImport(.from(3));
    try pair.p2.session_state.registerExport(.from(3));

    try pair.p1.sendCopying(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(3) } },
        .args = &.{},
        .answer = .from(21),
    } });
    _ = try pair.p1.step();
    try out.appendSlice(allocator, "p1=sent:deliver:answer=21\n");
    try shuttleAndTraceEvents(allocator, &out, &pair.p1, &pair.p2, "p2");

    try pair.p1.sendCopying(.{ .gc_export = .{ .positions = &.{3}, .deltas = &.{1} } });
    _ = try pair.p1.step();
    try out.appendSlice(allocator, "p1=sent:gc_export:position=3:delta=1\n");
    try shuttleAndTraceEvents(allocator, &out, &pair.p1, &pair.p2, "p2");
    // The partner's gc releases only its wire holds; the exporter's local
    // baseline floats until the exporter itself drops it, so the row survives
    // the partner's release and is reclaimed only by the local release.
    try appendTraceLine(allocator, &out, "p2=export3_refs={d}:live={}\n", .{
        pair.p2.session_state.exportRefcount(.from(3)),
        pair.p2.session_state.hasExport(.from(3)),
    });
    pair.p2.session_state.releaseUnsharedExport(.from(3));
    try appendTraceLine(allocator, &out, "p2=released:baseline:export3_live={}\n", .{pair.p2.session_state.hasExport(.from(3))});

    try pair.p1.sendCopying(.{ .gc_answer = .{ .positions = &.{21} } });
    _ = try pair.p1.step();
    try out.appendSlice(allocator, "p1=sent:gc_answer:position=21\n");
    try shuttleAndTraceEvents(allocator, &out, &pair.p1, &pair.p2, "p2");
    try appendTraceLine(allocator, &out, "p2=answer21_live={}\n", .{pair.p2.session_state.hasInboundAnswer(.from(21))});

    try out.appendSlice(allocator, "\n");

    return out.toOwnedSlice(allocator);
}

/// The full three-party handoff as one driven wire conversation (ADR-0009,
/// ADR-0100): a gifter introduces a recipient to a capability it fetched from
/// an exporter, and the recipient redeems the introduction and calls the
/// exporter directly. Six peers on three keyed sessions carry it — gifter to
/// exporter, gifter to recipient, recipient to exporter — with real Ed25519
/// material from fixed seeds behind every certificate: the three keyed hellos,
/// the gifter's `desc:handoff-give`, and the recipient's
/// `desc:handoff-receive` all verify on the receiving side; nothing is
/// stubbed on the wire. The Node's local-target and gifter-directory seams use
/// deterministic test owners; production Host coverage separately constrains
/// those owners. The withdraw is shuttled before the deposit on purpose: the
/// two legs travel on different sessions, so the exporter parks the early
/// withdraw and settles it when the deposit lands — the arrival-order contract
/// the upstream OCapN suite pins. The deposit remains owned by the exporter's
/// Gifter-facing Peer; the Receiver-facing Peer resolves that live session
/// before verification and consumption (ADR-0100).
/// Codec-parameterized like `runDrivenDeliverResolve`; the handoff signing
/// domain stays Syrup on both codecs (ADR-0009).
const DrivenGiftSeams = struct {
    gifter_scope: engine.PeerId,
    recipient_scope: engine.PeerId,
    source_position: model.ExportPosition,
    gifter_peer: *engine.Peer,
    recipient_peer: *engine.Peer,
    projected_position: ?model.ExportPosition = null,

    const target: u64 = 1;

    fn resolveName(_: ?*anyopaque, _: engine.PeerId, _: []const u8) !?model.ExportPosition {
        return null;
    }

    fn capture(ctx: ?*anyopaque, scope: engine.PeerId, position: model.ExportPosition) ?u64 {
        const self: *DrivenGiftSeams = @ptrCast(@alignCast(ctx.?));
        if (scope != self.gifter_scope or position != self.source_position) return null;
        return target;
    }

    fn project(ctx: ?*anyopaque, scope: engine.PeerId, opaque_target: u64) !engine.bootstrap.ProjectedLocalTarget {
        const self: *DrivenGiftSeams = @ptrCast(@alignCast(ctx.?));
        if (scope != self.recipient_scope or opaque_target != target) return error.InvalidGiftTarget;
        const position: model.ExportPosition = .from(try self.recipient_peer.exportNextObject());
        self.projected_position = position;
        return .{ .export_position = position, .created = true };
    }

    fn releaseTarget(_: ?*anyopaque, _: u64) void {}

    fn rollback(ctx: ?*anyopaque, scope: engine.PeerId, opaque_target: u64, projected: engine.bootstrap.ProjectedLocalTarget) void {
        const self: *DrivenGiftSeams = @ptrCast(@alignCast(ctx.?));
        if (!projected.created or scope != self.recipient_scope or opaque_target != target) return;
        self.recipient_peer.session_state.releaseUnsharedExport(projected.export_position);
        self.projected_position = null;
    }

    fn resolveGifterSession(ctx: ?*anyopaque, gifter_side: [32]u8, session_name: []const u8) ?engine.bootstrap.GifterSession {
        const self: *DrivenGiftSeams = @ptrCast(@alignCast(ctx.?));
        if (!self.gifter_peer.verify_partner_handshake) return null;
        const key = engine.bootstrap.gifterKeyForSession(&self.gifter_peer.session_state, gifter_side, session_name) orelse return null;
        return .{ .peer_id = self.gifter_scope, .key = key, .gifts = self.gifter_peer.giftRegistry() };
    }
};

pub fn runDrivenHandoff(allocator: std.mem.Allocator, codec_id: model.CodecId) ![]u8 {
    const crypto = foundation.crypto;

    // One Ed25519 identity per party, used for each session that party opens —
    // the node-identity shape `engine.Node` ships. The give must be signed by
    // the same key the exporter learned from the gifter's hello, and the
    // receive by the key the give names.
    const gifter_secret = crypto.SecretKey.fromSeed([_]u8{0x11} ** crypto.SEED_BYTES);
    const recipient_secret = crypto.SecretKey.fromSeed([_]u8{0x22} ** crypto.SEED_BYTES);
    const exporter_secret = crypto.SecretKey.fromSeed([_]u8{0x33} ** crypto.SEED_BYTES);

    var gifter_to_recipient = keyedNegotiatingPeer(allocator, codec_id);
    defer gifter_to_recipient.deinit();
    var recipient_to_gifter = keyedNegotiatingPeer(allocator, codec_id);
    defer recipient_to_gifter.deinit();
    var gifter_to_exporter = keyedNegotiatingPeer(allocator, codec_id);
    defer gifter_to_exporter.deinit();
    var recipient_to_exporter = keyedNegotiatingPeer(allocator, codec_id);
    defer recipient_to_exporter.deinit();

    var exporter_node = engine.Node.init(allocator, [_]u8{0x33} ** crypto.SEED_BYTES);
    defer exporter_node.deinit();
    const exporter_options: engine.Peer.NegotiatingOptions = .{
        .captp_version = .v1_0,
        .codec = codec_id,
        .features = model.FeatureSet.full(),
    };
    const exporter_gifter_id = try exporter_node.registerPeer(exporter_options);
    const exporter_recipient_id = try exporter_node.registerPeer(exporter_options);
    const exporter_to_gifter = exporter_node.peer(exporter_gifter_id).?;
    const exporter_to_recipient = exporter_node.peer(exporter_recipient_id).?;

    var seams = DrivenGiftSeams{
        .gifter_scope = exporter_gifter_id,
        .recipient_scope = exporter_recipient_id,
        .source_position = undefined,
        .gifter_peer = exporter_to_gifter,
        .recipient_peer = exporter_to_recipient,
    };
    exporter_node.setLocalObjectProjection(.{
        .ctx = &seams,
        .resolve_name = DrivenGiftSeams.resolveName,
        .capture = DrivenGiftSeams.capture,
        .project = DrivenGiftSeams.project,
        .rollback = DrivenGiftSeams.rollback,
        .release_target = DrivenGiftSeams.releaseTarget,
    });
    exporter_node.setGifterSessionResolver(.{ .ctx = &seams, .resolve = DrivenGiftSeams.resolveGifterSession });

    try openKeyedSession(&gifter_to_recipient, gifter_secret, "gifter", &recipient_to_gifter, recipient_secret, "recipient");
    try openKeyedSession(&gifter_to_exporter, gifter_secret, "gifter", exporter_to_gifter, exporter_secret, "exporter");
    try openKeyedSession(&recipient_to_exporter, recipient_secret, "recipient", exporter_to_recipient, exporter_secret, "exporter");

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "scenario=driven_handoff\n");

    // Publish only on the gifter-facing session. Deposit captures the exact
    // opaque target now; withdrawal projects it onto the recipient-facing
    // session without a swiss name there.
    const thermostat_gifter_session = try exporter_to_gifter.registerBootstrapCap("thermostat");
    seams.source_position = .from(thermostat_gifter_session);
    try appendTraceLine(allocator, &out, "exporter=registered:swissnum=thermostat:gifter_session={d}\n", .{thermostat_gifter_session});

    // The gifter fetches the capability it will later give away.
    const prepared = try engine.fetch.prepareFetchSwissnum(allocator, &gifter_to_exporter.session_state, "thermostat");
    try gifter_to_exporter.send(prepared.message);
    _ = try gifter_to_exporter.step();
    try out.appendSlice(allocator, "gifter=sent:fetch\n");
    try shuttleAndTraceEvents(allocator, &out, &gifter_to_exporter, exporter_to_gifter, "exporter");
    try shuttleFrames(exporter_to_gifter, &gifter_to_exporter);
    var fetched: model.Reference = undefined;
    {
        var settle = gifter_to_exporter.pollEvent() orelse return error.MissingFetchResolve;
        defer settle.deinit();
        const owned = try settle.decodeOwned(allocator);
        const match = try engine.fetch.tryMatchFetchOutcome(allocator, prepared.resolver_export, prepared.answer_position, owned);
        switch (match) {
            .settled => |outcome| switch (outcome) {
                .fulfilled => |reference| fetched = reference,
                .broken => |reason| {
                    allocator.free(reason);
                    return error.FetchBroken;
                },
                .malformed => return error.FetchMalformed,
            },
            .unrelated => |message| {
                model.freeMessage(allocator, message);
                return error.FetchUnrelated;
            },
        }
    }
    defer model.freeReference(allocator, fetched);
    switch (fetched) {
        .far => |far| try appendTraceLine(allocator, &out, "gifter=fetched:thermostat:import={d}\n", .{far.import_position.int()}),
        else => return error.UnexpectedFetchShape,
    }

    // The recipient asks the gifter for an introduction.
    try recipient_to_gifter.session_state.registerImport(.from(7));
    try gifter_to_recipient.session_state.registerExport(.from(7));
    try recipient_to_gifter.sendCopying(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(7) } },
        .args = &.{.{ .symbol = "introduce" }},
        .answer = .from(42),
    } });
    _ = try recipient_to_gifter.step();
    try out.appendSlice(allocator, "recipient=sent:deliver:answer=42\n");
    try shuttleAndTraceEvents(allocator, &out, &recipient_to_gifter, &gifter_to_recipient, "gifter");

    // The gifter originates the give: deposit on the exporter session, then
    // resolve the recipient's question with the signed give — the
    // `Node.originateGive` recipe, driven here frame by frame.
    const recipient_key = gifter_to_recipient.session_state.partnerSessionKey() orelse return error.NoRecipientKey;
    const exporter_key = gifter_to_exporter.session_state.partnerSessionKey() orelse return error.NoExporterKey;
    // The give names the exporter's location explicitly (`Node.setExporterLocation`'s
    // shape) rather than reading the session's verbatim hello span
    // (`partnerLocatorRaw`): a Cap'n Proto hello carries a structural locator
    // and keeps no Syrup span, and on Syrup this record is byte-identical to
    // the verbatim one, so the give — and the trace — is the same on both codecs.
    const exporter_location = try engine.encodePeerLocatorRecord(allocator, .{
        .transport = "tcp",
        .designator = "exporter",
        .hints = model.Hints.emptyFalse(),
    });
    defer allocator.free(exporter_location);
    const gifter_side = try engine.handoff_recipient.sideName(gifter_secret.publicKey().asBytes());
    const exporter_side = try engine.handoff_recipient.sideName(exporter_key);
    const gifter_exporter_session = engine.handoff_recipient.sessionName(gifter_side, exporter_side);
    const gift_id = [_]u8{0x6b} ** 32;
    const give_bytes = try engine.handoff_gifter.buildSignedGive(
        allocator,
        gifter_secret,
        recipient_key,
        exporter_location,
        &gifter_exporter_session,
        &gifter_side,
        &gift_id,
    );
    defer allocator.free(give_bytes);
    try gifter_to_exporter.sendDepositGift(&gift_id, fetched);
    try out.appendSlice(allocator, "gifter=sent:deposit_gift\n");
    try gifter_to_recipient.sendResolveHandoffGive(.from(42), give_bytes);
    try out.appendSlice(allocator, "gifter=sent:resolve_give:answer=42\n");

    // The give reaches the recipient first; the deposit stays queued on the
    // gifter-to-exporter session so the withdraw below arrives early.
    try shuttleFrames(&gifter_to_recipient, &recipient_to_gifter);
    var redeem_give: ?[]u8 = null;
    defer if (redeem_give) |bytes| allocator.free(bytes);
    {
        var event = recipient_to_gifter.pollEvent() orelse return error.MissingGiveResolve;
        defer event.deinit();
        const view = try event.view();
        try appendTraceLine(allocator, &out, "recipient=event:resolve:answer={d}:fulfill={s}\n", .{
            view.resolve.answer,
            @tagName(view.resolve.resolution.fulfill),
        });
        var projected = try engine.handoff_recipient.projectGiveForRedeem(
            allocator,
            view.resolve.resolution.fulfill.handoff.give,
        );
        defer projected.deinit(allocator);
        redeem_give = try allocator.dupe(u8, projected.bytes() orelse return error.GiveProjectionFailed);
    }

    // The recipient signs the receive and withdraws on its own exporter
    // session. The deposit has not shuttled yet, so the exporter parks it.
    try recipient_to_exporter.sendWithdrawGift(recipient_secret, redeem_give.?, .from(1));
    _ = try recipient_to_exporter.step();
    try out.appendSlice(allocator, "recipient=sent:withdraw_gift:answer=1\n");
    try shuttleAndTraceEvents(allocator, &out, &recipient_to_exporter, exporter_to_recipient, "exporter");
    try appendTraceLine(allocator, &out, "exporter=withdraw_parked={d}:gift_live={}\n", .{
        exporter_to_recipient.pendingWithdrawCount(),
        exporter_to_gifter.giftRegistry().giftLive(&gift_id),
    });

    // Now the deposit lands in the gifter session's registry. The recipient
    // session's next step resolves that live session and settles the parked
    // withdraw against its gift table.
    try shuttleAndTraceEvents(allocator, &out, &gifter_to_exporter, exporter_to_gifter, "exporter");
    try appendTraceLine(allocator, &out, "exporter=deposit_recorded:gift_live={}\n", .{exporter_to_gifter.giftRegistry().giftLive(&gift_id)});
    const changed = exporter_node.nextHandoffChange() orelse return error.MissingHandoffWake;
    var waiters = exporter_node.handoffWaiters(changed);
    while (waiters.next()) |receiver| exporter_node.peer(receiver).?.noteHandoffChange(changed);
    exporter_node.consumeHandoffChange(changed);
    try shuttleFrames(exporter_to_recipient, &recipient_to_exporter);
    try appendTraceLine(allocator, &out, "exporter=withdraw_settled:parked={d}:gift_live={}\n", .{
        exporter_to_recipient.pendingWithdrawCount(),
        exporter_to_gifter.giftRegistry().giftLive(&gift_id),
    });
    var direct_import: u64 = 0;
    {
        var event = recipient_to_exporter.pollEvent() orelse return error.MissingWithdrawResolve;
        defer event.deinit();
        const owned = try event.decodeOwned(allocator);
        defer model.freeMessage(allocator, owned);
        const reference = owned.resolve.resolution.fulfill.reference;
        direct_import = switch (reference) {
            .far => |far| far.import_position.int(),
            else => return error.UnexpectedWithdrawShape,
        };
        try appendTraceLine(allocator, &out, "recipient=event:resolve:answer={d}:fulfill=import={d}\n", .{
            owned.resolve.answer.int(),
            direct_import,
        });
    }

    // The redeemed capability is live: the recipient calls the exporter
    // directly, no gifter on the path.
    try recipient_to_exporter.sendCopying(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(direct_import) } },
        .args = &.{.{ .symbol = "read" }},
        .answer = .from(2),
    } });
    _ = try recipient_to_exporter.step();
    try out.appendSlice(allocator, "recipient=sent:deliver:answer=2:direct\n");
    try shuttleFrames(&recipient_to_exporter, exporter_to_recipient);
    {
        var event = exporter_to_recipient.pollEvent() orelse return error.MissingRedeemedDeliver;
        defer event.deinit();
        const view = try event.view();
        if (view != .deliver or view.deliver.target != .near) return error.MalformedRedeemedDeliver;
        if (view.deliver.target.near.export_position != (seams.projected_position orelse return error.GiftWasNotProjected))
            return error.RedeemedWrongTarget;
        try out.appendSlice(allocator, "exporter=event:deliver\n");
    }
    try exporter_to_recipient.sendCopying(.{ .resolve = .{
        .answer = .from(2),
        .resolution = .{ .fulfill = .{ .string = "72F" } },
    } });
    _ = try exporter_to_recipient.step();
    try out.appendSlice(allocator, "exporter=sent:resolve:answer=2\n");
    try shuttleAndTraceEvents(allocator, &out, exporter_to_recipient, &recipient_to_exporter, "recipient");
    try out.appendSlice(allocator, "\n");

    return out.toOwnedSlice(allocator);
}

/// A negotiating peer fixed to interop-floor `v1_0` on `codec_id` with the
/// full feature set, partner-handshake verification on — the keyed-session
/// profile `runDrivenHandoff`'s hellos must verify against.
fn keyedNegotiatingPeer(allocator: std.mem.Allocator, codec_id: model.CodecId) engine.Peer {
    return engine.Peer.initNegotiatingWith(allocator, .{
        .captp_version = .v1_0,
        .codec = codec_id,
        .features = model.FeatureSet.full(),
    });
}

/// Drive one keyed `op:start-session` exchange to an open session: each side
/// signs its own locator with real key material and verifies the partner's,
/// exactly as a live keyed handshake does. Handshake-artifact events are
/// drained so the caller starts from empty queues.
fn openKeyedSession(
    p1: *engine.Peer,
    p1_secret: foundation.crypto.SecretKey,
    p1_designator: []const u8,
    p2: *engine.Peer,
    p2_secret: foundation.crypto.SecretKey,
    p2_designator: []const u8,
) !void {
    // Both designators are `tcp` addresses, so neither hello claims a durable
    // identity.
    try p1.sendKeyedStartSession(
        .{ .transport = "tcp", .designator = p1_designator, .hints = model.Hints.emptyFalse() },
        p1_secret,
    );
    try p2.sendKeyedStartSession(
        .{ .transport = "tcp", .designator = p2_designator, .hints = model.Hints.emptyFalse() },
        p2_secret,
    );
    if (try engine.pairing.shuttleUntilQuiescent(p1, p2) != .quiescent) return error.HandshakeDidNotQuiesce;
    drainEvents(p1);
    drainEvents(p2);
}

fn drainEvents(peer: *engine.Peer) void {
    while (peer.pollEvent()) |event_value| {
        var event = event_value;
        event.deinit();
    }
}

/// Move every queued outbound frame from `sender` into `receiver`, then trace
/// each event the receiver surfaces. A resolve event's fulfilled payload is
/// rendered by arm — scalar payloads by value, container payloads by tag — so
/// the trace stays codec-agnostic and byte-stable.
fn shuttleAndTraceEvents(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    sender: *engine.Peer,
    receiver: *engine.Peer,
    receiver_name: []const u8,
) !void {
    try shuttleFrames(sender, receiver);
    try traceReceiverEvents(allocator, out, receiver, receiver_name);
}

/// Move every queued outbound frame from `sender` into `receiver`, leaving the
/// receiver's surfaced events for the caller. A synthesized reply (a projection
/// resolve, an auto-served fetch) may encode on a later step, so keep stepping
/// the sender until a step yields no new frame.
fn shuttleFrames(sender: *engine.Peer, receiver: *engine.Peer) !void {
    while (true) {
        const result = try sender.step();
        var moved = false;
        while (sender.takeOutbound()) |frame| {
            try receiver.feedOwned(frame);
            _ = try receiver.step();
            moved = true;
        }
        if (result == .idle and !moved) return;
    }
}

/// Trace and drain every event `receiver` has surfaced, in the rendering
/// `shuttleAndTraceEvents` documents.
fn traceReceiverEvents(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    receiver: *engine.Peer,
    receiver_name: []const u8,
) !void {
    while (receiver.pollEvent()) |event_value| {
        var event = event_value;
        defer event.deinit();
        if (event.kind() == .resolve) {
            const view = try event.view();
            switch (view.resolve.resolution) {
                .fulfill => |payload| switch (payload) {
                    .string => |text| try appendTraceLine(allocator, out, "{s}=event:resolve:answer={d}:fulfill={s}\n", .{ receiver_name, view.resolve.answer, text }),
                    .integer => |value| try appendTraceLine(allocator, out, "{s}=event:resolve:answer={d}:fulfill={d}\n", .{ receiver_name, view.resolve.answer, value }),
                    else => try appendTraceLine(allocator, out, "{s}=event:resolve:answer={d}:fulfill={s}\n", .{ receiver_name, view.resolve.answer, @tagName(payload) }),
                },
                else => try appendTraceLine(allocator, out, "{s}=event:resolve:answer={d}:{s}\n", .{ receiver_name, view.resolve.answer, @tagName(view.resolve.resolution) }),
            }
        } else {
            try appendTraceLine(allocator, out, "{s}=event:{s}\n", .{ receiver_name, @tagName(event.kind()) });
        }
    }
}

/// The two inbound entry points that converge on one dispatcher: the borrowed
/// zero-copy path and the owned-frame path.
pub const InboundMode = enum { borrowed, owned };

/// Drive one inbound frame through `mode` and trace the observable dispatcher
/// output (rejection error, surfaced events, outbound frame count + byte length,
/// session state). Both modes funnel through the same `dispatch_inbound`/abort
/// machinery, so a parity test asserts byte-identical traces, the load-bearing
/// proof that the borrowed and owned entry points run one state machine, not
/// two. The frame is a malformed one, so the trace also exercises the
/// abort-projection path (`engine.abort_projection`) across both modes.
pub fn runInboundMode(allocator: std.mem.Allocator, mode: InboundMode) ![]u8 {
    var peer = engine.Peer.init(allocator);
    defer peer.deinit();

    const garbage = "this is not a syrup frame";

    const dispatch_err: ?anyerror = err: {
        switch (mode) {
            .borrowed => {
                peer.recvBorrowed(.{ .bytes = garbage, .shape = foundation.FrameShape.byte }) catch |e|
                    break :err e;
                break :err null;
            },
            .owned => {
                const storage = try allocator.dupe(u8, garbage);
                const frame = foundation.Frame.initOwned(allocator, storage, .byte, .fromByteUnits(1)) catch |e|
                    break :err e;
                try peer.feedOwned(frame);
                _ = peer.step() catch |e| break :err e;
                break :err null;
            },
        }
    };

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try appendTraceLine(allocator, &out, "dispatch_error={s}\n", .{
        if (dispatch_err) |e| @errorName(e) else "none",
    });

    var event_count: usize = 0;
    while (peer.pollEvent()) |event_value| {
        var event = event_value;
        event.deinit();
        event_count += 1;
    }
    try appendTraceLine(allocator, &out, "events={d}\n", .{event_count});

    var outbound_frames: usize = 0;
    var outbound_bytes: usize = 0;
    while (peer.takeOutbound()) |frame_value| {
        var frame = frame_value;
        outbound_bytes += frame.bytes().len;
        frame.deinit();
        outbound_frames += 1;
    }
    try appendTraceLine(allocator, &out, "outbound_frames={d}\n", .{outbound_frames});
    try appendTraceLine(allocator, &out, "outbound_bytes={d}\n", .{outbound_bytes});
    try appendTraceLine(allocator, &out, "session_closed={}\n", .{peer.session_state.state == .closed});

    return out.toOwnedSlice(allocator);
}

fn appendTraceLine(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    comptime format: []const u8,
    args: anytype,
) !void {
    var buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, format, args);
    try out.appendSlice(allocator, line);
}
