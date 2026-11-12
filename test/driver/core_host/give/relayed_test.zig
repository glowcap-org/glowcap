//! Relayed promise settlement: projecting a nested capability tree through
//! an introducing-session proxy commits the recipient store without a Vat
//! actor on the home promise.

const std = @import("std");
const glowcap = @import("glowcap");
const test_host = @import("../../../support/core_host.zig");

const model = glowcap.ocapn.model;
const actors = glowcap.actors;
const driver = glowcap.driver;

const Host = driver.core.Host;
const HostSession = driver.core.HostSession;
const engine = glowcap.ocapn.engine;
const crypto = glowcap.foundation.crypto;
const stream_framing = glowcap.foundation.stream_framing;

const harness = @import("../harness.zig");
const projection_support = @import("../../../support/projection.zig");
const frame_cap = harness.frame_cap;
const Widget = harness.Widget;
const FairCounter = harness.FairCounter;
const Vendor = harness.Vendor;
const Introducer = harness.Introducer;
const host_pair = harness.host_pair;
const handshake_support = harness.handshake_support;
const Pair = harness.Pair;
const shuttle = harness.shuttle;
const shuttleAll = harness.shuttleAll;
const tcpLocator = harness.tcpLocator;
const publishAndOpenAccepted = harness.publishAndOpenAccepted;
const publishAndOpenAcceptedOver = harness.publishAndOpenAcceptedOver;
const tcpSturdyref = harness.tcpSturdyref;
const onionLocator = harness.onionLocator;
const onionSturdyref = harness.onionSturdyref;
const ParkedDial = harness.ParkedDial;
const drainActions = harness.drainActions;
const pumpToQuiescence = harness.pumpToQuiescence;
const CapturedRef = harness.CapturedRef;
const CapturedString = harness.CapturedString;
const openPair = harness.openPair;
const retireClosingSession = harness.retireClosingSession;
const retireClosedSession = harness.retireClosedSession;
const Tagged = harness.Tagged;
const keyedDesignator = harness.keyedDesignator;
const TraceLog = harness.TraceLog;

test "core host: relayed promise settlement projects a complete nested capability tree" {
    for ([_]model.CodecId{ .syrup, .capnp }) |codec_id|
        try runRelayedPromiseProjection(codec_id);
}

fn runRelayedPromiseProjection(codec_id: model.CodecId) !void {
    const allocator = std.testing.allocator;
    var options = Host.Options.init(.unchecked, frame_cap);
    options.codec = codec_id;
    var relay = test_host.init(allocator, @as([32]u8, @splat(0x81)), options);
    defer relay.deinit();
    var home = test_host.init(allocator, @as([32]u8, @splat(0x82)), options);
    defer home.deinit();
    var recipient = test_host.init(allocator, @as([32]u8, @splat(0x83)), options);
    defer recipient.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer harness.deinitParked(allocator, &dials);

    const home_pair = try openPair(allocator, &relay, &home, "127.0.0.1:7181", &dials);
    const recipient_pair = try openPair(allocator, &relay, &recipient, "127.0.0.1:7182", &dials);

    // The relay already holds a promise imported from the home session. Giving
    // that Host identity to another session creates one introducing-session
    // proxy and one home listener.
    const source_export = try home_pair.b.served.port.peer.session_state.allocatePromiseExport();
    try home_pair.a.served.port.peer.session_state.registerImport(.from(source_export.int()));
    const source_token = try relay.node.enrollForeign(
        home_pair.a.peer_handle,
        model.FarRef.promise(source_export.int()),
    );
    const projected = (try relay.node.proxyForeignPromiseFulfill(
        recipient_pair.a.peer_handle,
        source_token.routed.id,
    )).?;
    const recipient_export = projected.near.export_position;
    // Hold the projection as the partner would once its message is sent.
    recipient_pair.a.served.port.peer.session_state.exports.retain(recipient_export);

    // Inspect and acknowledge the home op:listen exactly as a wire peer would.
    // Registering its listener import is enough for the manual
    // resolver fire below; the test does not need a home Vat actor.
    while (try relay.nextAction()) |_| {}
    var listen_frame = (try home_pair.a.takeOutbound()) orelse return error.MissingListen;
    defer listen_frame.deinit();
    const listen = (try glowcap.ocapn.codec.dispatch.decodeBodyForProfile(
        home_pair.a.served.port.peer.session_state.codec,
        home_pair.a.served.port.peer.session_state.captp_version,
        listen_frame.view(),
    )).listen;
    const listener_position = listen.listener.far.import_position;
    try home_pair.b.served.port.peer.session_state.registerImport(listener_position);

    const object_export = try home_pair.b.served.port.peer.session_state.allocateExport();
    const promise_export = try home_pair.b.served.port.peer.session_state.allocatePromiseExport();
    const nested_entries = [_]model.StructEntry{
        .{ .key = "object", .value = .{ .reference = .{ .near = model.NearRef.object(object_export.int()) } } },
        .{ .key = "promise", .value = .{ .list = &.{
            .{ .reference = .{ .near = model.NearRef.promise(promise_export.int()) } },
        } } },
    };
    const resolver_args = [_]model.Argument{
        .{ .symbol = "fulfill" },
        .{ .@"struct" = &nested_entries },
    };
    try home_pair.b.served.port.peer.sendBorrowed(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(listener_position.int()) },
        .args = &resolver_args,
        .resolve_me_desc = null,
    } });
    try home_pair.b.served.port.peer.stepToIdle();

    // Move only the resolver fire. Its nested promise projection queues a new
    // home listen, but this test's row-only home promise has no
    // Vat settlement source. The claim under test is already complete once
    // the relay answers entropy and commits the recipient store.
    try std.testing.expect(try shuttle(home_pair));
    while (try drainActions(allocator, &.{ &relay, &home, &recipient }, &dials)) {}
    try std.testing.expect(!relay.node.isProxyHomeListener(
        home_pair.a.peer_handle,
        listener_position.int(),
    ));

    const settled = projection_support.resolution(
        &recipient_pair.a.served.port.peer.session_state,
        recipient_export,
    ) orelse return error.MissingRelayedSettlement;
    try std.testing.expect(settled.* == .fulfill);
    try std.testing.expect(settled.fulfill == .@"struct");
    try std.testing.expectEqual(@as(usize, 2), settled.fulfill.@"struct".len);
    const projected_object = settled.fulfill.@"struct"[0].value;
    try std.testing.expect(projected_object == .handoff);
    try std.testing.expect(projected_object.handoff.* == .give);
    const projected_promise = settled.fulfill.@"struct"[1].value.list[0];
    try std.testing.expect(projected_promise == .reference);
    try std.testing.expect(projected_promise.reference == .near);
    try std.testing.expectEqual(.promise, projected_promise.reference.near.kind);
}

const PipelineTrace = struct {
    calls: usize = 0,
    replies: usize = 0,
    last_reply: i64 = 0,
    listener_seen: bool = false,
    order: [4]u8 = undefined,

    pub fn record(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *PipelineTrace = @ptrCast(@alignCast(ctx.?));
        if (resolution == .fulfilled and resolution.fulfilled == .integer) {
            self.replies += 1;
            self.last_reply = resolution.fulfilled.integer;
        }
    }
};

const PipelineCounter = struct {
    trace: *PipelineTrace,
    pub fn handle(self: *PipelineCounter, _: *actors.Turn, msg: actors.Delivery) !model.Argument {
        if (self.trace.calls == self.trace.order.len) return error.TooManyCalls;
        const tag: u8 = if (msg.is("call")) 'c' else if (msg.is("tell")) 't' else if (msg.is("late")) 'l' else return error.NoSuchMethod;
        self.trace.order[self.trace.calls] = tag;
        self.trace.calls += 1;
        return .{ .integer = @intCast(self.trace.calls) };
    }
};

const PipelineListener = struct {
    trace: *PipelineTrace,
    pub fn handle(self: *PipelineListener, _: *actors.Turn, msg: actors.Delivery) !model.Argument {
        if (!msg.is("fulfill")) return error.NotFulfilled;
        const value = try msg.args.at(0);
        if (value != .handoff or (try value.handoff.project()) != .give) return error.NotHandoff;
        self.trace.listener_seen = true;
        return .{ .void = {} };
    }
};

test "core host: a projected promise forwards queued call tell and late call while its listener gets a handoff" {
    for ([_]model.CodecId{ .syrup, .capnp }) |codec_id| {
        for ([_]Host.Options{ Host.Options.init(.unchecked, frame_cap), harness.nextRouteOptions() }) |base| {
            var options = base;
            options.codec = codec_id;
            try runPipeline(options);
        }
    }
}

fn runPipeline(options: Host.Options) !void {
    const allocator = std.testing.allocator;
    var relay = test_host.init(allocator, @splat(0x91), options);
    defer relay.deinit();
    var home = test_host.init(allocator, @splat(0x92), options);
    defer home.deinit();
    var recipient = test_host.init(allocator, @splat(0x93), options);
    defer recipient.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer harness.deinitParked(allocator, &dials);
    const home_pair = try openPair(allocator, &relay, &home, "127.0.0.1:7191", &dials);
    const recipient_pair = try openPair(allocator, &relay, &recipient, "127.0.0.1:7192", &dials);
    const hosts = [_]*Host{ &relay, &home, &recipient };
    const pairs = [_]Pair{ home_pair, recipient_pair };
    var trace = PipelineTrace{};
    const object = try home_pair.b.served.spawn(&home.vat, PipelineCounter, .{ .trace = &trace });
    const listener = try recipient_pair.b.served.spawn(&recipient.vat, PipelineListener, .{ .trace = &trace });
    const source = try home_pair.b.served.port.peer.session_state.allocateLocalPromiseProjection();
    home_pair.b.served.port.peer.session_state.exports.retain(source.export_position);
    try home_pair.a.served.port.peer.session_state.registerImport(.from(source.export_position.int()));
    if (options.captp_version == .next)
        try engine.listen.ensureShorteningListener(home_pair.a.served.port.peer, .from(source.export_position.int()));
    const route = try relay.node.enrollForeign(home_pair.a.peer_handle, model.FarRef.promise(source.export_position.int()));
    const projected = (try relay.node.proxyForeignPromiseFulfill(recipient_pair.a.peer_handle, route.routed.id)).?;
    recipient_pair.a.served.port.peer.session_state.exports.retain(projected.near.export_position);
    try recipient_pair.b.served.port.peer.session_state.registerImport(.from(projected.near.export_position.int()));
    if (options.captp_version == .next)
        try engine.listen.ensureShorteningListener(recipient_pair.b.served.port.peer, .from(projected.near.export_position.int()));
    const target: model.Reference = .{ .far = model.FarRef.promise(projected.near.export_position.int()) };
    const call = try recipient.queueSend(recipient_pair.b, target, .{ .verb = "call", .args = &.{} });
    try recipient.vowOn(call, .{ .ctx = &trace, .func = PipelineTrace.record });
    try recipient.tell(recipient_pair.b, target, .{ .verb = "tell", .args = &.{} });
    try recipient_pair.b.served.port.peer.sendBorrowed(.{ .listen = .{
        .target = target,
        .listener = .{ .near = model.NearRef.object(listener.position) },
        .mode = .settling_only,
    } });
    try recipient_pair.b.served.port.peer.stepToIdle();
    try pumpToQuiescence(allocator, &hosts, &pairs, &dials);
    try std.testing.expectEqual(@as(usize, 0), trace.calls);
    try home_pair.b.served.port.peer.sendAnswerTargetResolutionCopying(source.answer_target, .{
        .fulfill = .{ .reference = .{ .near = model.NearRef.object(object.position) } },
    });
    try home_pair.b.served.port.peer.stepToIdle();
    try pumpToQuiescence(allocator, &hosts, &pairs, &dials);
    try std.testing.expectEqualStrings("ct", trace.order[0..trace.calls]);
    try std.testing.expectEqual(@as(usize, 1), trace.replies);
    try std.testing.expectEqual(@as(i64, 1), trace.last_reply);
    try std.testing.expect(trace.listener_seen);
    const late = try recipient.queueSend(recipient_pair.b, target, .{ .verb = "late", .args = &.{} });
    try recipient.vowOn(late, .{ .ctx = &trace, .func = PipelineTrace.record });
    try pumpToQuiescence(allocator, &hosts, &pairs, &dials);
    try std.testing.expectEqualStrings("ctl", trace.order[0..trace.calls]);
    try std.testing.expectEqual(@as(usize, 2), trace.replies);
    try std.testing.expectEqual(@as(i64, 3), trace.last_reply);
    try std.testing.expectEqual(@as(usize, 0), dials.items.len);
}
