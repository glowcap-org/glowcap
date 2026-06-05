const std = @import("std");

const foundation = @import("../foundation/mod.zig");
const model = @import("../model/mod.zig");
const runtime = @import("../runtime/mod.zig");

pub fn runStage0Abort(allocator: std.mem.Allocator) ![]u8 {
    var peer = runtime.Peer.init(allocator);
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
    var p1 = runtime.Peer.init(allocator);
    defer p1.deinit();
    var p2 = runtime.Peer.init(allocator);
    defer p2.deinit();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "scenario=driven_abort\n");

    try p1.sendCopying(.{ .abort = .{ .kind = .other, .message = "bye" } });
    _ = try p1.step();
    try out.appendSlice(allocator, "p1=sent:abort\n");

    const frame = p1.takeOutbound().?;
    try p2.feedInbound(frame);
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

/// A full deliver → resolve round-trip across an in-process paired session
/// (ADR-0023 V1.0 resolver-callback translation under the hood): p1 asks p2's
/// bootstrap a question, p2 resolves it, and the resolution surfaces back at p1
/// as a semantic `Resolve`. Broadens conformance past the abort axis onto the
/// deliver / answer / resolve state machine. Runs on `codec`; the trace is
/// codec-agnostic by construction, so a parity test asserts it is identical on
/// Syrup and Cap'n Proto (Invariant 8's two-codec requirement).
pub fn runDrivenDeliverResolve(allocator: std.mem.Allocator, codec: model.CodecId) ![]u8 {
    var pair = try runtime.factories.pairedWithCodec(allocator, codec);
    defer pair.deinit();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "scenario=driven_deliver_resolve\n");

    // p1 imports p2's bootstrap export (id 0) and asks a question on answer 42.
    try pair.p1.session_state.registerImport(0);
    try pair.p1.sendCopying(.{ .deliver = .{
        .target = .{ .far = .{ .import_id = 0 } },
        .args = &.{.{ .bytes = "ping" }},
        .answer = 42,
    } });
    _ = try pair.p1.step();
    try out.appendSlice(allocator, "p1=sent:deliver:answer=42\n");

    {
        const frame = pair.p1.takeOutbound().?;
        try pair.p2.feedInbound(frame);
    }
    _ = try pair.p2.step();
    if (pair.p2.pollEvent()) |event_value| {
        var event = event_value;
        defer event.deinit();
        try appendTraceLine(allocator, &out, "p2=event:{s}\n", .{@tagName(event.kind())});
    }

    // p2 resolves the question with "pong".
    try pair.p2.sendCopying(.{ .resolve = .{
        .answer = 42,
        .resolution = .{ .fulfill = .{ .bytes = "pong" } },
    } });
    _ = try pair.p2.step();
    try out.appendSlice(allocator, "p2=sent:resolve:answer=42\n");

    {
        const frame = pair.p2.takeOutbound().?;
        try pair.p1.feedInbound(frame);
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

/// Handshake → register a bootstrap cap on the responder → the initiator fetches
/// it → the responder AUTO-resolves (no hand-rolled reply). The exporter-side
/// proof for ADR-0006's responder half: serving an inbound `'fetch` lives in the
/// runtime, not the test harness. The settlement rides back as a V1.0
/// resolver-callback and surfaces at the initiator as a `fulfilled` outcome.
/// Runs on `codec`; the trace is codec-agnostic by construction, so a parity
/// test asserts it is identical on Syrup and Cap'n Proto (Invariant 8).
pub fn runHandshakeThenBootstrapFetch(allocator: std.mem.Allocator, codec: model.CodecId) ![]u8 {
    var pair = try runtime.factories.pairedWithCodec(allocator, codec);
    defer pair.deinit();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "scenario=handshake_bootstrap_fetch\n");

    const export_id = try pair.p2.registerBootstrapCap("thermostat");
    try appendTraceLine(allocator, &out, "p2=registered:swissnum=thermostat:export={d}\n", .{export_id});

    const prepared = try runtime.fetch.prepareFetchSwissnum(allocator, &pair.p1.session_state, "thermostat");
    try pair.p1.send(prepared.message);
    _ = try pair.p1.step();
    try out.appendSlice(allocator, "p1=sent:fetch\n");

    {
        const frame = pair.p1.takeOutbound().?;
        try pair.p2.feedInbound(frame);
    }
    // p2 dispatches the inbound fetch: the deliver surfaces as an event and the
    // synthesized resolve is enqueued; a second step encodes that settlement.
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
        try pair.p1.feedInbound(frame);
    }
    _ = try pair.p1.step();
    {
        var settle = pair.p1.pollEvent().?;
        defer settle.deinit();
        const owned = try settle.decodeOwned(allocator);
        const match = try runtime.fetch.tryMatchFetchOutcome(allocator, prepared.resolver_export, prepared.answer_id, owned);
        switch (match) {
            .settled => |outcome| switch (outcome) {
                .fulfilled => |reference| {
                    defer model.freeReference(allocator, reference);
                    // The fulfilled cap is p2's export; the perspective flip lands
                    // it at p1 as the import it now holds. Trace its position
                    // (variant-agnostic) so the line is stable across codecs.
                    const position = switch (reference) {
                        .far => |far| far.import_id,
                        .near => |near| near.export_id,
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

/// The two inbound entry points that converge on one dispatcher (Invariant 14):
/// the borrowed zero-copy path and the owned-frame path.
pub const InboundMode = enum { borrowed, owned };

/// Drive one inbound frame through `mode` and trace the observable dispatcher
/// output (rejection error, surfaced events, outbound frame count + byte length,
/// session state). Both modes funnel through the same `dispatch_inbound`/abort
/// machinery, so a parity test asserts byte-identical traces — the load-bearing
/// proof that the borrowed and owned entry points run one state machine, not
/// two. The frame is a malformed one, so the trace also exercises the
/// abort-projection path ([`runtime.abort_projection`]) across both modes.
pub fn runInboundMode(allocator: std.mem.Allocator, mode: InboundMode) ![]u8 {
    var peer = runtime.Peer.init(allocator);
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
                const frame = foundation.Frame.initOwned(allocator, storage, .byte, .fromByteUnits(1)) catch |e| {
                    allocator.free(storage);
                    break :err e;
                };
                try peer.feedInbound(frame);
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
