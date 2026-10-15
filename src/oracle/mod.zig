//! Canonical CapTP scenario drivers and the observable-trace oracle.
//!
//! Each `run*` function drives a `engine.Peer` through one fixed protocol
//! scenario (a Stage-0 abort, a driven deliver/resolve, a handshake-then-
//! bootstrap-fetch, an inbound dispatch mode) and returns the resulting wire
//! bytes. Those byte traces are the conformance evidence: the Zig oracle tests
//! (`test/oracle`) compare them for identical observable behavior. The drivers
//! live in their own `oracle` module, off the public `glowcap` namespace: the
//! tests import it directly, and no binding consumes it. The bindings prove
//! the C ABI by dogfood, not by oracle traces.
//!
//! The drivers are sync and codec-parameterized. They own no I/O and add no
//! protocol semantics the engine lacks.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");
const appendTraceLine = @import("trace.zig").appendLine;
const scenario_support = @import("scenario/support.zig");

pub const handoff = @import("scenario/handoff.zig");

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
            const decoded = event.view();
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

    try p1.sendBorrowed(.{ .abort = .{ .kind = .other, .message = "bye" } });
    _ = try p1.step();
    try out.appendSlice(allocator, "p1=sent:abort\n");

    const frame = p1.takeOutbound().?;
    try p2.feedOwned(frame);
    _ = try p2.step();

    if (p2.pollEvent()) |event_value| {
        var event = event_value;
        defer event.deinit();
        if (event.kind() == .abort) {
            const decoded = event.view();
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
/// deliver / answer / resolve state machine. Runs on `codec`. The trace is
/// codec-agnostic by construction, so a parity test asserts it is identical on
/// Syrup and Cap'n Proto.
pub fn runDrivenDeliverResolve(allocator: std.mem.Allocator, codec: model.CodecId) ![]u8 {
    var pair = try engine.pairing.pairedWithCodec(allocator, codec);
    defer pair.deinit();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "scenario=driven_deliver_resolve\n");

    try pair.p1.sendBorrowed(.{ .deliver = .{
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

    try pair.p2.sendBorrowed(.{ .resolve = .{
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
        const view = event.view();
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
/// for answer-side `op:listen` (ADR-0007). Codec-parameterized like
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

    try pair.p1.sendBorrowed(.{ .deliver = .{
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

    try pair.p1.sendBorrowed(.{ .listen = .{
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

    try pair.p2.sendBorrowed(.{ .resolve = .{
        .answer = .from(42),
        .resolution = .{ .fulfill = .{ .bytes = "ok" } },
    } });
    _ = try pair.p2.step();
    try out.appendSlice(allocator, "p2=sent:resolve:answer=42\n");
    try scenario_support.shuttleFrames(&pair.p2, &pair.p1);
    while (pair.p1.pollEvent()) |event_value| {
        var event = event_value;
        defer event.deinit();
        if (event.kind() == .deliver) {
            const view = event.view();
            try appendTraceLine(allocator, &out, "p1=event:deliver:listener={d}:fulfill={s}\n", .{
                view.deliver.target.near.export_position.int(),
                (try view.deliver.args.at(1)).bytes,
            });
        } else {
            try appendTraceLine(allocator, &out, "p1=event:{s}\n", .{@tagName(event.kind())});
        }
    }
    try out.appendSlice(allocator, "\n");

    return out.toOwnedSlice(allocator);
}

/// The peers hand-shake, the responder registers a bootstrap cap, the initiator
/// fetches it, and the responder auto-resolves with no hand-rolled reply. The exporter-side
/// proof for ADR-0006's responder half: serving an inbound `'fetch` lives in the
/// engine, not the test harness. The settlement rides back as a V1.0
/// resolver-callback and surfaces at the initiator as a `fulfilled` outcome.
/// Runs on `codec`. The trace is codec-agnostic by construction, so a parity
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
/// trio as whole-conversation behavior, not just per-frame fixtures.
/// Codec-parameterized like `runDrivenDeliverResolve`.
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
        try pair.p1.sendBorrowed(.{ .deliver = .{
            .target = .{ .far = .{ .import_position = .from(7) } },
            .args = &.{},
            .answer = .from(answer),
        } });
        _ = try pair.p1.step();
        try appendTraceLine(allocator, &out, "p1=sent:deliver:answer={d}\n", .{answer});
        try scenario_support.shuttleAndTraceEvents(allocator, &out, &pair.p1, &pair.p2, "p2");
    }

    const projections = [_]model.Message{
        .{ .get = .{ .receiver = .{ .promise = .{ .answer_position = .from(11) } }, .field = "name", .answer = .from(12) } },
        .{ .index = .{ .receiver = .{ .promise = .{ .answer_position = .from(21) } }, .index = .{ .integer = 1 }, .answer = .from(22) } },
        .{ .untag = .{ .receiver = .{ .promise = .{ .answer_position = .from(31) } }, .tag = "cm", .answer = .from(32) } },
    };
    for (projections) |message| {
        try pair.p1.sendBorrowed(message);
        _ = try pair.p1.step();
        try appendTraceLine(allocator, &out, "p1=sent:{s}\n", .{@tagName(message)});
        try scenario_support.shuttleAndTraceEvents(allocator, &out, &pair.p1, &pair.p2, "p2");
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
        try pair.p2.sendBorrowed(message);
        _ = try pair.p2.step();
        try appendTraceLine(allocator, &out, "p2=sent:resolve:answer={d}\n", .{message.resolve.answer.int()});
        try scenario_support.shuttleAndTraceEvents(allocator, &out, &pair.p2, &pair.p1, "p1");
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

    try pair.p1.sendBorrowed(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(3) } },
        .args = &.{},
        .answer = .from(21),
    } });
    _ = try pair.p1.step();
    try out.appendSlice(allocator, "p1=sent:deliver:answer=21\n");
    try scenario_support.shuttleAndTraceEvents(allocator, &out, &pair.p1, &pair.p2, "p2");

    try pair.p1.sendBorrowed(.{ .gc_export = .{ .positions = &.{3}, .deltas = &.{1} } });
    _ = try pair.p1.step();
    try out.appendSlice(allocator, "p1=sent:gc_export:position=3:delta=1\n");
    try scenario_support.shuttleAndTraceEvents(allocator, &out, &pair.p1, &pair.p2, "p2");
    // The partner's gc releases only its wire holds; the exporter's local
    // baseline floats until the exporter itself drops it, so the row survives
    // the partner's release and is reclaimed only by the local release.
    try appendTraceLine(allocator, &out, "p2=export3_refs={d}:live={}\n", .{
        pair.p2.session_state.exportRefcount(.from(3)),
        pair.p2.session_state.hasExport(.from(3)),
    });
    pair.p2.session_state.releaseUnsharedExport(.from(3));
    try appendTraceLine(allocator, &out, "p2=released:baseline:export3_live={}\n", .{pair.p2.session_state.hasExport(.from(3))});

    try pair.p1.sendBorrowed(.{ .gc_answer = .{ .positions = &.{21} } });
    _ = try pair.p1.step();
    try out.appendSlice(allocator, "p1=sent:gc_answer:position=21\n");
    try scenario_support.shuttleAndTraceEvents(allocator, &out, &pair.p1, &pair.p2, "p2");
    try appendTraceLine(allocator, &out, "p2=answer21_live={}\n", .{pair.p2.session_state.hasInboundAnswer(.from(21))});

    try out.appendSlice(allocator, "\n");

    return out.toOwnedSlice(allocator);
}

/// The two inbound entry points that converge on one dispatcher: the borrowed
/// zero-copy path and the owned-frame path.
pub const InboundMode = enum { borrowed, owned };

/// Drive one inbound frame through `mode` and trace the observable dispatcher
/// output (rejection error, surfaced events, outbound frame count + byte length,
/// session state). `Peer.feedOwned` and `Peer.recvBorrowed` funnel through the
/// same dispatch and abort machinery, so a parity test asserts byte-identical traces, which is the
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
